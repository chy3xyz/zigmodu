# H2: 响应体超过 `max_pending_bytes` 被拒绝（待做）

> 状态：**未修**，已实测、已定位、已定形状。这是一条**已确认的行为不一致**：同一个路由在
> HTTP/1.1 上能返回任意大小的响应，在 HTTP/2 上超过 4 MiB 会直接失败。
> 记录在这里是因为修它要动 H2 的调度器（`Http2Server.zig` 的 `OutboundScheduler`），
> 而这是整套写路径里最后一块没有上界/没有被证明的地方。

## 现象（2026-09-26 实测，macOS 回环，`zig build test` 里的 H2 stall 测试同款客户端）

一个 GET 请求要 N 字节响应，客户端正常读：

| 响应体 | 结果 |
|-------|------|
| 3 MiB | 正常服务（全部字节到达） |
| 6 MiB | `RST_STREAM`，error_code = **10 = ENHANCE_YOUR_CALM** |
| 16 MiB | `RST_STREAM`，error_code = **2 = INTERNAL_ERROR** |

客户端在线缆上看到的依次是：`SETTINGS`（服务器自己的）→ `SETTINGS ACK` → **`RST_STREAM(stream 1)`**，
**一个 HEADERS/DATA 帧都没有** —— 也就是说响应根本没开始写就被拒了。

## 定位

* 上限是 `ServeOptions.max_pending_bytes`，**默认 4 MiB**，注释写的是
  "Cap total pending outbound wire bytes (ENHANCE_YOUR_CALM when exceeded)"。
  `Server.http2ServeOptions` 不覆盖它，所以应用看到的就是 4 MiB。
* 拒绝发生在**入队**这一步：一次响应被整体编成帧、作为**一个** `PendingOutbound`
  入队（`OutboundScheduler.enqueue(stream_id, wire, st.flow)`），入队时的字节数检查超过
  `max_pending_bytes` 就报错，调用方把它转成 `RST_STREAM`。
* 于是这个"backpressure 上限"实际变成了"响应体大小上限"，而这**不是**它的语义：
  调度器本来是**边排边发**的（窗口一放开就 drain 下一片），完全可以在队列里只驻留
  一个窗口量级的字节、边发边补。

## 修法（形状）

把响应体从"一次性入队"改成"**按窗口切片、边发边补**"：

1. `OutboundScheduler` 里给每个流保留一个**续发游标**（`next_offset`）与它那份 body 的所有权，
   而不是把所有帧一次性铺进 `wire`。
2. `enqueue` 只放**至多** `min(max_pending_bytes, 一片的大小)` 的帧；`drain` 把这批发完之后，
   在同一个锁内续排下一片（`drain` 已经在窗口约束下逐帧取用，续排点就放在"这批发完"处）。
3. 上限语义随之恢复成它注释里说的那样：**队列**不超过 `max_pending_bytes`，与响应体大小无关。
   `max_pending_streams`（默认 64，超了 `REFUSED_STREAM`）保持原样。
4. 注意别把"窗口为 0 时的等待"变成忙等：切片排空后如果没有窗口，就回到现在的
   `canSendNextFrame` 判定 + 等 `WINDOW_UPDATE`/读事件唤醒的路径。

## 验收（新增测试）

* **正面**：回环 + 一个**会读**的客户端，请求 6 MiB（> 4 MiB）→ 全部字节到达、
  无 `RST_STREAM`、无 `GOAWAY`。这条就是上面那张表第二行的回归测试。
* **反面**：同一个 6 MiB 请求 + **不读**的客户端 → 仍然由写预算结束
  （`response_write_timeout_ms`，见 `Server.zig` 的 H2 stall 测试），而不是被
  `max_pending_bytes` 拒掉 —— 两条失败的**形状不同**，别让新测试把二者混起来。
* 顺带核对：`max_pending_bytes` 调小时，< 4 MiB 的响应也仍应能服务（只是发送变慢），
  即"上限管队列、不管响应大小"。

## 相关

* 同一批实测还发现并已修：新流的发送窗口过去固定从 65535 起、不采用对端
  `SETTINGS_INITIAL_WINDOW_SIZE`（RFC 9113 §6.5.2）——见 CHANGELOG 第 57 批与
  `Http2.FlowControlState.initStream`。本文件的切片方案要在那个修复之上做（流窗口可能是
  16 MiB，切片大小取 `min(max_pending_bytes, conn_max_frame_size * N)` 更合适）。
* H2 写路径的上界本身已在 CHANGELOG 第 56 批接好（`ConnWriter.writeDirect` →
  `sockread.writeFullBounded`）。
