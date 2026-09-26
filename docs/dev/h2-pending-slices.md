# H2: 响应体大于 `max_pending_bytes`（**已修**，第 61 批）

> 状态：**已修并回归**。曾经是同一条路由在 HTTP/1.1 上能返回任意大小、在 HTTP/2 上超过 4 MiB
> 直接失败的**行为不一致**。修完发现它其实是**两个叠在一起的缺陷**——第二层才是真因，它同时
> 解释了那张表里的 `INTERNAL_ERROR`。
> 本文件保留实测、根因、修法与验收，供以后动 H2 写路径时对照。

## 现象（2026-09-26 实测，macOS 回环，`zig build test` 里 H2 测试同款客户端）

一个 GET 请求要 N 字节响应，客户端正常读：

| 响应体 | 修复前 | 修复后 |
|-------|------|------|
| 3 MiB | 正常服务 | 正常服务 |
| 6 MiB | `RST_STREAM`，error_code = **10 = ENHANCE_YOUR_CALM** | 完整到达，无 RST / GOAWAY |
| 16 MiB | `RST_STREAM`，error_code = **2 = INTERNAL_ERROR** | 完整到达（本批只测 6 MiB；16 MiB 由"按帧切"结构保证，见下） |

修复前客户端在线缆上依次看到 `SETTINGS`（服务器自己的）→ `SETTINGS ACK` → **`RST_STREAM(stream 1)`**，
**一个 HEADERS/DATA 帧都没有** —— 响应根本没开始写就被拒了。

## 根因（两层，第二层是修第一层时才暴露的）

**第一层：入队把整份响应一次性铺进队列。** 上限是 `ServeOptions.max_pending_bytes`（默认 4 MiB，
注释写的是 "Cap total pending outbound wire bytes"），而检查发生在 `OutboundScheduler.enqueue`
—— 一次响应编成帧后作为**一个** `PendingOutbound` 入队，`pending_bytes + wire.len > max_bytes`
就报错，调用方 (`streamErrorFromAny`) 把它转成 `RST_STREAM`。于是这个 backpressure 上限**实际
成了响应体大小上限**，而这**不是**它的语义：调度器本来是边排边发的。

**第二层：site 响应线把整个 body 编成"一个" DATA 帧。** 只在第一层改成"按帧切片"之后才暴露出来
——切片要以**帧**为单位，而 `encodeSiteResponseWire` 走的是
`Http2.encodeData(allocator, stream_id, body, true)`：整段 body 一帧。后果三条：

1. 帧长字段是 24 位 → **16 MiB 的 body 根本编不出来**（`encodeFrame` 返回 `PayloadTooLarge`，
   上层转成 `INTERNAL_ERROR`）。表里第三行就是它。
2. 该帧声明的长度远超服务器自己在 SETTINGS 里广告的 `SETTINGS_MAX_FRAME_SIZE`（默认 16384）——
   上线路前会被 `writeNextWireFrame` 切碎，所以对端看不到，但**任何按帧遍历这段 wire 的代码都会
   相信那个声明长度**（`canSendNextFrame`、切片器都是），这正是切片器卡住的原因：一帧 6 MiB，
   永远塞不进 `max_pending_bytes` 的预算。
3. `shrinkDataFrameInPlace` 在**每次部分发送**后 memmove 该帧的未发余量 → 对一个 6 MiB 的单帧
   是 O(n²) 的搬运（6 MiB / 16 KiB ≈ 384 次，每次最多搬 6 MiB）。

对照：gRPC 路径的 `Http2.encodeGrpcServerStream` 一直是**按 16 KiB 切 DATA 帧**的
（注释 "chunk ≤ 16KiB for realism"），只有 site 响应这条路径没切。

## 修法（已落地）

1. **`encodeSiteResponseWire` 按 `conn_max_frame_size` 切 DATA 帧**（`Http2Server.zig` §7），与
   gRPC 路径同心；空 body 仍发一个空 DATA 帧收尾，`HEAD` 仍只有 HEADERS（`no_body` 分支不变）。
2. **`OutboundScheduler` 改成"帧对齐的续发游标"**：`PendingOutbound` 加 `committed`
   （`offset <= committed <= end`，永远落在帧边界），`enqueue` 只铺第一片、`refill` 在每帧发出后
   逐帧补，`pending_bytes` 记的是**队列**占用。单流一次最多占 `min(max_pending_bytes,
   conn_max_frame_size × 16)`，所以一个巨大响应不会把队列全占死。
3. **被预算饿死的流至少能发一帧**：预算约束的是"这个队列一次推多少"，不是"已接收的响应能不能开始"
   （那份 wire 无论如何都已分配）。没有这条，一个大响应把预算占满且窗口关闭时，复用在它后面的小
   响应会被饿住。
4. **上限只在 `max_bytes == 0` 时拒绝**（退化配置：永远切不出片，停着就是挂死），仍是
   `ENHANCE_YOUR_CALM`。其余情况下 `pending_bytes` 由预算维持在 `max_bytes` 内，
   `max_pending_streams`（默认 64，超了 `REFUSED_STREAM`）不变。
5. 窗口为 0 时**不忙等**：切完没有窗口就回到 `canSendNextFrame` + 等 `WINDOW_UPDATE`/读事件唤醒的路
   径（`WINDOW_UPDATE` 处理里本来就带一次 `drain`）。

## 验收（已进测试）

* **正面** `h2 server sends a response larger than max_pending_bytes to a reading client`
  （`Http2Server.zig` §9）：回环 + 会读的客户端 + 把发送窗口开大的 `WINDOW_UPDATE`，请求 6 MiB →
  全部字节到达（逐字节比对 + 首末字节）、`END_STREAM` 收到、无 `RST_STREAM`、无 `GOAWAY`、
  多于一个 DATA 帧。测试先断言 `(ServeOptions{}).max_pending_bytes < 6 MiB`，否则它对着旧行为也会绿。
* **反面** `h2: a non-reading client is ended by the write budget, not by the pending cap`：同一个
  6 MiB + **不读**的客户端 → 会话由 `response_write_timeout_ms`（200 ms）结束
  （`active_connections` 归零），客户端拿到的是**被截断的 body**，且**没有** `RST_STREAM` /
  `GOAWAY` —— 两条失败的**形状不同**。`header_timeout_ms` 保持默认 10 s，免得读空闲预算抢先。
* **单元** `encodeSiteResponseWire splits the body into SETTINGS_MAX_FRAME_SIZE chunks`：
  40 KiB body + 16 KiB 帧长 → 3 个 DATA 帧、每帧 ≤ 16384、只有最后一帧带 `END_STREAM`。
* **单元** `OutboundScheduler stages a response larger than max_pending_bytes instead of refusing it`
  与 `... lets a budget-starved stream start, then holds it to the budget`：切片游标逐轮推进、
  队列占用不超预算、被饿死的流也只多占一帧。

## 相关

* 上游修复（本批之前）：新流的发送窗口按对端 `SETTINGS_INITIAL_WINDOW_SIZE` 起
  （`Http2.FlowControlState.initStream`，RFC 9113 §6.5.2），见 CHANGELOG 第 57 批；本批的切片在它
  之上做。
* H2 写路径的上界本身已在 CHANGELOG 第 56 批接好（`ConnWriter.writeDirect` →
  `sockread.writeFullBounded`）。
* `max_pending_bytes` 的语义修正同步进了 `docs/API.md` 的 HTTP/2 limits 表。
