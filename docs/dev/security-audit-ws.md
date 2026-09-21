# 安全审计 ②：WebSocket 帧解析 / 握手（只读）

> 只读静态审计，无端到端 PoC。这一轮**在上一份审计明确跳过的代码里**做。
> 最重的那条（握手把未校验长度的 key memcpy 进固定栈缓冲）已修，见 CHANGELOG；
> 其余各条仍在，含 ConnectionRegistry 的悬挂指针与对象池只出不进。

---

## 处置状态（2026-09 更新，非审计原文）

审计原文保留在下方未改动。以下条目已落地，逐条见 `CHANGELOG.md` 的
「WebSocket ②：io_uring 那条解析路径不再"编译不过所以安全"…」。

| 审计条目 | 状态 |
|---|---|
| §1.1 `WsFramer.handshake` 的 128 字节栈缓冲 | 已修（改增量 SHA-1，缓冲整个删掉） |
| §1.5 未掩码客户端帧被接受（两个解析器） | 已修 —— MASK 必需成为 `WsFramer.validateFrameHeader` 的一条，两个解析器共用 |
| §1.6 FIN / 分片 / 控制帧 / RSV / UTF-8 | 已修 —— 同上；分片重组与 UTF-8 规则收进 `WsFramer.Assembler`，两边共用 |
| §1.7 `ws_uring` 64-bit 长度溢出 + ping `@intCast` | 已修 —— **并且先修了 `start()` 的编译错误**：`processData` 原先不可达（惰性分析），只修溢出等于把潜伏缺陷变成活漏洞 |
| §3 4KB 隐式协议常量 | 部分修 —— **fiber 路径**（`Server.zig`）现在能收满 `max_message_bytes` 的单帧，≤4 KiB 常见路径仍零分配。**io_uring 路径单帧仍限 4 KiB**（超出即 1009 关闭，不再静默挂起）：该路径在 Linux 上，本机无法实测 |
| §3 握手不校验 version / Connection | 已修 —— `Sec-WebSocket-Version: 13` + `Connection` 必须含 `upgrade` token，失败即 400 且不升级 |
| §1.2 `extensions/WebSocket.zig` 的 `[60]u8` 握手缓冲 | **未动**（不在本次改动面内；它只经 `root.zig` 公开导出，仓内无内部使用者） |
| §1.3 / §1.4 `ConnectionRegistry` 的 id-0 哨兵与对象池只出不进 | 已由另一条工作流修（见 `ConnectionRegistry.zig` 底部的测试） |
| §3 帧解析器没有测试 | 已修 —— `im.WsFramer` 20 条、`im.ws_uring` 6 条（解析器本身是纯字节函数，**在 macOS 上就能跑**），另有 3 条端到端握手 / 大帧用例 |

一处判断需要更正：同一类潜伏问题不止解析器。`ws_uring` 里
`connections.getPtr` 的返回类型（`**Conn`）与 `conn.on_message != 0`
（0.17 起函数指针不能与整数比较）同样是"从未被分析"才留下的 —— 修好 `start()` 的编译错误后
它们一次性暴露出来。

---

**结论：帧解析器没有任何 RFC 6455 负面路径校验（掩码、RSV、opcode、FIN/分片、控制帧约束、UTF-8、关闭码全线缺失），
但真正的**高**是握手：`Sec-WebSocket-Key` 长度未校验就 memcpy 进固定栈缓冲，**未认证**一发即崩（ReleaseFast 下是栈溢出）；
其次是 `ConnectionRegistry` 里 `conn_id == 0` 同时被当作"错误哨兵"和分片 0 的首个合法 id，注册失败时不回滚 →
注册表留下指向已释放 session 的悬挂指针。**

## 1. 真实发现

### 1.1 高 —— `WsFramer.handshake` 把未校验长度的 `Sec-WebSocket-Key` memcpy 进 128 字节栈缓冲
`src/im/WsFramer.zig:49-52`（调用点 `src/api/Server.zig:2766-2771`）

证据：
```zig
var hash_input: [128]u8 = undefined;          // :49
const hash_len = ws_key.len + magic.len;      // :50  magic.len == 36
@memcpy(hash_input[0..ws_key.len], ws_key);   // :51  无长度校验
@memcpy(hash_input[ws_key.len..hash_len], magic); // :52
```
`ws_key` 直接来自请求头，唯一的前置检查是"非空"：
```zig
// src/api/Server.zig:2766-2771
const ws_key = ctx.headers.get("sec-websocket-key") orelse "";
if (ws_key.len > 0) { ... framer.handshake(ws_key) catch { ... } }
```
`HeaderLimits.max_total_bytes = 16 * 1024`（`src/api/Server.zig:1408`）→ 攻击者可控长度上限约 16KB。
`ws_key.len > 92` 时第二个 `@memcpy` 越界：Debug/ReleaseSafe 是 `panic`（Zig panic = abort，**整个进程**，连
`zmodu.panicHook` 也只是打印后 abort）；ReleaseFast/ReleaseSmall 关掉边界检查 → 把攻击者自己的字节写出栈帧之外。

要利用它，攻击者需要满足：能对**任一注册了 WS 路由的进程**发一个 TCP 连接；`GET <ws路径> HTTP/1.1` +
`Upgrade: websocket` + `Sec-WebSocket-Key: <93 字节以上>`。**不需要任何凭据** —— 升级在 `router.match` 与全部中间件之前处理
（`src/api/ComptimeRouter.zig:717-758` 已把这件事写成注释并强制 `.auth = .public`），所以这就是互联网正面可达的预认证路径。
另外握手不做 `Sec-WebSocket-Version: 13` / `Connection: Upgrade` / base64 校验，垃圾 key 也会回 101。

### 1.2 高 —— 同一漏洞在 `extensions/WebSocket.zig` 更严重：缓冲只有 60 字节
`src/extensions/WebSocket.zig:171-174`
```zig
var hash_input: [60]u8 = undefined;   // :171  24 + 36，正好只放得下 RFC 示例 key
const hash_len = ws_key.len + magic.len;
@memcpy(hash_input[0..ws_key.len], ws_key);
@memcpy(hash_input[ws_key.len..hash_len], magic);
```
`ws_key` 来自 `extractHeaderValue`（`:237-245`，取到 `\r\n` 为止、无长度限制，请求缓冲 4096）。
**25 字节的 key 就越界**，最大可溢出约 4KB。

要利用它：目标用这个 `WebSocketServer` 监听（`src/root.zig:315` 公开导出，仓库内没有内部使用者，所以是"库调用方踩到"）。
同 1.1：安全构建 abort，ReleaseFast 是栈溢出。

### 1.3 高 —— `conn_id == 0` 既是错误哨兵又是分片 0 的合法首个 id；失败不回滚 → 悬挂指针
`src/im/ConnectionRegistry.zig:192-196, 210-225`，与生成模板 `tools/zmodu/src/main.zig:7894-7898`

证据（注册表**先入表再返回**）：
```zig
// ConnectionRegistry.zig:156   .next_id_base = @as(u32, id) << 26,   // shard 0 → 0
fn nextId(...) { const id = self.next_id_base; self.next_id_base += 1; return id; } // :192-196
...
const entry = self.acquireEntry() orelse return 0;      // :210  这一条是安全的（未入表）
const conn_id = self.nextId();                          // :211  分片 0 首次 → 0
self.by_user.putAssumeCapacity(user_id, entry);         // :223  ← 已经写进表了
self.by_conn.putAssumeCapacity(conn_id, entry);         // :224
return conn_id;                                         // :225
```
调用方把 0 当失败并**释放 session**：
```zig
const conn_id = self.registry.register(user_id, @ptrCast(session), sendViaWsFramer);
if (conn_id == 0) { self.allocator.destroy(session); return null; }   // main.zig:7894-7898
```
于是分片 0 的 `by_user` 里留下一个指向已释放 `WsSession` 的 `*ConnectionEntry`。后续 `sendToUser` →
`entry.*.send_fn(entry.*.ctx, msg)`（`:260`）调用已释放对象上的函数指针；`tickAndCleanup`（`:296`）先做 UAF 读。

要利用它：`user_id & 63 == 0`（64 的倍数）的用户成为**该进程分片 0 的第一次注册**时触发（该连接被拒 + 留悬挂项）；
之后任何人给该 user 推一条消息（走 `relay.deliver` → `registry.sendToUser`）就走到已释放的 session。
`user_id` 由应用自己的 `verifier` 决定，所以不是纯匿名可控，但触发后是内存安全事件而不是功能错。
现有 5 个 registry 测试全用 `user_id ∈ {1,42,65,...}`，**没有一个落在分片 0**（1&63=1、42&63=42、65&63=1），
所以 `register` 返回 0 这条分支从来没被执行过。

### 1.4 中 —— 对象池只出不进：`unregisterByConn` / `tickAndCleanup` 用 `destroy` 而不是回 free_list
`src/im/ConnectionRegistry.zig:247`、`:307`（对比 `:186-190` 的 `releaseEntry`）

```zig
if (self.by_conn.fetchRemove(conn_id)) |kv| { ...; allocator.destroy(kv.value); return true; } // :244-248
```
而池是 init 时一次性预分配的（`:143-148`，`capacity_per_shard` 默认 1024），只有 `unregister(user_id)`（`:233-237`）会归还。
生成模板的断开路径恰恰走销毁分支：
```zig
pub fn onClose(session_ptr: ?*anyopaque) void { ... session.gateway.registry.unregisterByConn(session.conn_id); ... } // main.zig:7920-7923
pub fn cleanup(self: *ImGateway) usize { return self.registry.tickAndCleanup(3); }                                   // main.zig:7849
```
后果：同一分片上每发生一次"正常断开"，该分片可用条目永久 -1。**同一个账号**（同 user_id → 同 shard）反复连断 1024 次，
或 1024 个落在同一分片的用户断开，`register` 就永久返回 0（`:210`）→ 该分片上的所有用户再也无法建立 WS（重启才恢复）。

要利用它：需要一个通过 `verifier` 的合法身份（默认 `verifier == null` 时升级被拒，见 `main.zig:7837,7880`），
然后循环 connect/disconnect。测试 `ConnectionRegistry.zig:424-436`（"sharded unregisterByConn"）destroy 之后**没有再注册一次**，
所以池被抽干这件事测不出来。

### 1.5 中 —— 未掩码的客户端帧被接受（RFC 6455 §5.1 要求服务端必须断开）
`src/im/WsFramer.zig:87, 100-112`；`src/im/ws_uring.zig:198, 213-233`
```zig
const masked = (header[1] & 0x80) != 0;   // 读到了
...
if (masked) { try self.readFull(&mask_key); }   // :100-103  没掩码就跳过
...
if (masked) { for (buf[0..payload_len], 0..) |*b, i| b.* ^= mask_key[i % 4]; }  // :108-112
```
`masked == false` 时既不拒绝也不报错，只是不解掩码。两个解析器完全同构（ws_uring `:198/:213/:229`）。
掩码 key 的 4 字节读取位置、以及逐字节 `i % 4` 的解掩码逻辑本身是**对的**（游标顺序 header→ext→mask→payload 符合 RFC）。

要利用它：任何原始 TCP 客户端（浏览器 WS API 做不到，只影响非浏览器/代理场景）可以发未掩码帧，服务端照常当合法消息分发。
实际危害是"服务端接受了一段本应被判非法的字节流"：跨协议/中间设备缓存混淆类问题所需要的那个缺口。

### 1.6 中 —— FIN / 分片 / 控制帧约束 / RSV / UTF-8 / 关闭码：全部不校验
`src/im/WsFramer.zig:86, 105, 114`；`src/im/ws_uring.zig:197, 236-253`；`src/api/Server.zig:2807-2819`

- FIN 位从不读：`const opcode = header[0] & 0x0F;`（`WsFramer.zig:86`）丢掉了 `0x80`；`0x70`（RSV1-3）同样不看。
  → 一条 FIN=0 的起始帧 payload 被当作**完整消息**交给 `on_message`（`Server.zig:2811`）。
- continuation（0x0）落进 `else => {}`（`Server.zig:2818`）被**静默丢弃**。
  两者合起来：按 RFC 正常分片的客户端（OpenIM protobuf 大包、任何标准库的分片实现）会得到"第一段被当完整消息、其余静默消失"
  —— 下游看到的是被截断的 protobuf/JSON，且没有任何错误信号。这是消息完整性缺陷，不是内存耗尽：**没有累积器，所以也没有累积上界问题**（框架层不存在 reassembly）。
- 控制帧：0x9 ping 的 payload 无 ≤125 / FIN=1 约束，直接回显 `framer.writePong(frame.payload)`（`Server.zig:2816`，`WsFramer.zig:187-189`），
  即服务端会发出 >125 字节的"控制帧"，违反 RFC。
- 0x8 关闭帧：payload 完全不解析 → 长度 1（非法）与非法关闭码都不会被发现（`Server.zig:2814` 直接 break）。
- 文本帧不做 UTF-8 校验（`src/im/` 与 Server WS 块内 grep 无任何 utf8 检查），无效 UTF-8 直接交给应用。

要利用它：任何能完成升级的客户端。这些单独看多为协议违规；1.6 的分片语义是最有实际后果的一条（静默截断）。

### 1.7 高（潜在，当前不可达）—— `ws_uring` 的 64-bit 长度无上界，`frame_total` 可整数溢出
`src/im/ws_uring.zig:208, 218, 275-278`
```zig
payload_len = @intCast(std.mem.readInt(u64, buf[2..10], .big));  // :208  64 位平台上 @intCast 是恒等
...
const frame_total = header_len + mask_offset + payload_len;       // :218  10 + 0 + 0xFFFF_FFFF_FFFF_FFFF → 溢出
```
一个 10 字节的未掩码帧（`127` 扩展长度）就能让 `+` 溢出：安全构建 panic，ReleaseFast 回绕成 9 →
`buf[10..9]` 构造 start>end 的切片（内存不安全）。同一文件 `sendPong` 里 `header[1] = @intCast(payload.len)`（`:276`）
对 >255 字节的 ping payload 同样 panic（而 0x9 的 payload 上限在这里是 ~4094）。

**可达性必须说清楚**：这条路径今天跑不起来 —— `runLoop` 调用的 `std.time.sleep`（`:131, :136`）在 Zig 0.17.0-dev.2151 里
**不存在**（`std/time.zig` 无 `sleep`，`std.Thread.sleep` 已移除；只有 `std.Io.sleep(io, ...)`）。所以 `WsUring.start()` 编译不过，
`processData` 不可达，仓库内没有任何测试/示例引用 `WsUring`。这些是"修好编译错误后立刻变成活漏洞"的潜伏缺陷。
相对地，fiber 路径（`WsFramer.readFrame`）的 64 位长度后面紧跟 `if (payload_len > buf.len) return error.PayloadTooLarge;`（`WsFramer.zig:105`），
所以**主路径在长度上是有界的**：单个帧硬上限 = 调用方缓冲 4096 字节（`Server.zig:2799-2802`），不会是内存耗尽面。
（32 位目标上 `WsFramer.zig:97` 的 `@intCast` 才是截断/panic 面，属边角。）

## 2. 值得怀疑但未能确认

- **同一 socket 上存在绕过 per-session 锁的写路径**。`WsSession.sendFrame` 持 `session.mutex`（`main.zig:7818-7820`），
  但服务端读循环里的 pong 用的是**自己那份** `framer`：`framer.writePong(frame.payload)`（`Server.zig:2816`），没拿 session 锁。
  而 session 里的 framer 是**拷贝**（`main.zig:7889 framer = framer.*`），两者共享同一个 fd。
  两条 `writevAll` 并发时是否会撕裂帧字节，取决于内核对这些大小的写行为 —— **为什么无法确认**：需要在真实并发下观测
  `writev` 是否部分写入，仓库里的 WS 测试都是自己发自己收的单连接闭环，没有并发推送 + pong 的同时场景。
- **`handshake` 的 101 与 `on_connect` 拒绝之间的语义**：`handshake` 先回 101，`on_connect` 返回 null 时再 `writeClose()`
  （`Server.zig:2779-2783`）。也就是说**认证失败发生在协议升级成功之后**，客户端会先看到 101 再看到 close。
  这是否被应用当作可利用（例如某些客户端在 101 之后就把连接当已认证）**无法从框架内确认**，取决于各应用前端。
  顺带：这条路径上 `ws_key` 已参与过 1.1 的 memcpy。
- **`std.Io.net.Stream` 被两个对象持有**（Server 的 `framer`、session 的拷贝），谁负责 `close`。
  `server` 侧 WS 分支不显式关流（`return` 后由外层 fiber 收尾），而 `WsSession.deinit` 里 `self.stream.close(io)`
  （`extensions/WebSocket.zig:294` 是另一套）。**为什么无法确认**：需要追 `connFiber` 的所有权收尾逻辑，本次未读完。

## 3. 结构性观察

- **信任边界在握手之后就不存在了**。`Server.zig:2760-2823` 的整块在 `router.match` 之前、全局中间件之前执行
  （`ComptimeRouter.zig:717-758` 的注释自己也承认"WS 路由没有执行点"），所以 1.1 的预认证溢出和 1.5/1.6 的裸字节都发生在
  任何鉴权、任何日志中间件之外。修法已经把"身份从 on_connect 拿"写进模板，但**帧字节层面的加固没有对应的那个"点"**。
- **帧解析器没有任何测试**。`WsFramer.zig:197-211` 的三个测试里有两个是 `_ = WsFramer.init(undefined, undefined);`
  —— 连一个字节都不解析、不断言任何东西；且 `handshake`/`write with and without buffer` 两个测试名与内容不符。
  仓库里唯一真正走帧解析的测试是 `Server.zig:4080`（"WebSocket fiber path receives client frames and fires on_close"），
  它**自己构造掩码帧**（`:4152-4159`）、用 RFC 的 24 字节示例 key
  （`dGhlIHNhbXBsZSBub25jZQ==`，正好 24 → 恰好塞满 `extensions` 那个 `[60]u8`）—— 是闭环，验证的是"合法形状能通"，
  对**恶意字节**零覆盖。`ConnectionRegistry` 的测试同样覆盖不到走错的分支（见 1.3、1.4）。
  这解释了为什么四个高危能同时存在。
- **4KB 是隐式协议常量，且没有文档化**。`WsFramer.readFrame` 的 `payload_len > buf.len`（`:105`）与 `Server.zig:2799-2802`
  的 4096 字节缓冲耦合：任何 >4KB 的合法帧（含合法的 16KB 文本）会让 `readFrame` 返回 `error.PayloadTooLarge` → `break`
  （`Server.zig:2806`）→ 连接**静默断开**。这是功能上限而非漏洞，但对"OpenIM protobuf"这类声明的支持场景是硬约束。
- **池容量是"有界但会漏"的设计**：上界存在（64 shard × 1024 条目），但只有 `unregister(user_id)` 这条路径归还；
  生成的模板偏偏用 `unregisterByConn`，`destroy` 而非 `releaseEntry` 在**同一 struct 里就有个正确的对照实现**（`:186-190`），
  更像"两条清理路径各写一遍"导致的漂移。

## 4. 我读了什么 / 我没读什么

**读了**：
- `src/im/WsFramer.zig`（全文 211 行，帧解析 + 握手 + 写帧）、`src/im/ws_uring.zig`（全文 296 行，io_uring 解析器）、
  `src/im/ConnectionRegistry.zig`（全文 441 行，含全部测试）、`src/im/BufferPool.zig`（全文）、`src/core/sockread.zig:1-80`。
- `src/api/Server.zig`：WS 升级块与读循环 `:2745-2820`、`WsRoute`/配置字段 `:187-225, 2098-2123`、`HeaderLimits` `:1405-1450`、
  WS 测试 `:4080-4159`。
- `src/extensions/WebSocket.zig:110-430`（第二个有同样缺陷的握手/解析器）。
- `src/api/ComptimeRouter.zig:700-780`（ws_routes 的 auth 强制 public）。
- `tools/zmodu/src/main.zig:7172-7928`（`generateImModule` 生成的 gateway 模板与 README/PERF，其中 `:7496-7502` 教用户开 io_uring）。
- 只读命令：`git status --porcelain`（干净，无未提交改动）、`grep` 全仓 `WsUring`/`readFrame`/`258EAFA5`/`ws_key` 调用点、
  Zig 安装目录 `lib/std/time.zig` 与 `lib/std/Io.zig` 的 `sleep` 声明。**没有跑 `zig build`/测试**（未占用机器、未改任何文件）。

**没读**：
- `Server.zig` 的 `connFiber` 收尾/所有权与 `accept` 循环（约 5000 行文件的大部分），所以 §2 最后一条的 fd 归属只有怀疑。
- `WsUring` 在 Linux 上的实际可运行性未实测（结论基于"`std.time.sleep` 不存在于本标准库"这一静态证据）。
- 各示例应用（`examples/**`、`examples/ai-ops` 等）里手写的 WS 网关是否自行加了掩码/长度校验，未逐个读。
- relay / `ImRelay` 的投递路径只看了模板里的调用（`registry.sendToUser` → `sendViaWsFramer`），没有读生成后的完整 relay 实现。

**一个提醒**：我在两次读取之间观察到 `src/api/Server.zig` 的行号发生过约 6 行漂移（`git status` 现在是干净的）。
本报告所有 Server.zig 行号以**最后核实的一遍**为准（WS 块 = `:2760-2827`）；引用代码片段原文可以兜底定位。