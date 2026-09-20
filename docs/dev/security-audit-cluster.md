# 安全审计 ②：集群 / Raft 帧解码（只读）

> 只读静态审计，无端到端 PoC。这一轮**在上一份审计明确跳过的代码里**做。
> 三条高危已由仓库维护者逐条验证成立：`entry.index == 0` 的无符号下溢（解码侧无 `>= 1` 校验，而 `getLogEntry` 反而校验了 —— 是漏检不是约定）、以及 `ClusterAuth` 全仓库零调用点（零认证）。
>
> **本文写于审计当时。第 1、2 条已在 v0.32.0 修复，并且"实际爆炸形状"已由编译+运行实测取代推测 ——
> 第 5 节是唯一的现状口径，下面 1.1 / 1.2 的推测部分按第 5 节读。**


1. **高危、可远程单人触发**：`RaftElection.handleAppendEntries` 用对端给的 `entry.index` 直接算 `items[entry.index - 1]`，**`entry.index == 0` 时 `-1` 无符号下溢** —— 一个 56 字节、无需认证的 TCP 帧就能打死/越界读节点(`RaftElection.zig:442-443`)。**【v0.32.0 已修，实测形状见第 5 节】**
2. **高危可用性**：入站 accept 环在同一条线程上**内联**处理连接(`NetworkTransport.zig:88`)，而 `handleConnection` 的 `recv` **没有 `setRecvTimeout`**（全仓库只有出站侧设了）——一个只发 4 字节长度前缀就挂住的连接，能停掉整个节点的 Raft 入站；连 `ClusterBootstrap.stop()` 都会卡死在 `thread.join()`。**【v0.32.0 已修；吞吐那一半仍未改】**
3. **高危结构**：这条线上**零认证**——`TlsTransport.ClusterAuth`(HMAC-PSK) 全仓库无任何调用点；于是 TCP 可达即"是集群成员"，可代任意（非成员的）候选人投票、冒充 leader 灌日志。**【未修】**

---

## 1. 真实发现

### 高危 · `src/core/cluster/RaftElection.zig:442-443`（解码侧在 `RaftTransport.zig:232-237`）
对端控制的 `entry.index` 未做 `>= 1` 校验，`entry.index == 0` 时 `entry.index - 1` 下溢成 `0xFFFF_FFFF_FFFF_FFFF`，随后 `self.log.items[<巨值>]` 越界（Debug/ReleaseSafe = **panic → 进程 abort**；ReleaseFast = **野指针读**，`existing.term` 从任意地址取）。

证据：
```zig
// RaftElection.zig:441-446
for (req.entries) |entry| {
    if (entry.index <= self.log.items.len) {        // 0 <= len 恒真（空日志也为真）
        const existing = self.log.items[entry.index - 1];  // 0 - 1 → u64 下溢
```
`entry.index` 就是线上读出来的 u64，解码侧不校验：`RaftTransport.zig:233-237`（`entry.index = try cur.u64v()`）。同文件 `getLogEntry` 反而做了 `if (index == 0 ...) return null`(`RaftElection.zig:788`)，说明这是一处漏检而不是约定。

**触发路径（对端只需 TCP 可达集群端口）**，帧体 56 字节：
```
tag=03 | term=0xFFFF..FF | leader_id="x" | prev_log_index=0 | prev_log_term=0
| leader_commit=0 | count=1 | entry.term=1 | entry.index=0 | entry.command=""
```
`term` 取 `u64::MAX` → 过 `req.term < current_term`(396) 与 `>` 分支(405)；`prev_log_index=0` → 跳过 420-438 的前置检查 → 直接进 441 的循环。
**前置条件**：仅"能连到该节点的集群端口"（`ClusterBootstrap.zig:144` 绑 `0.0.0.0:<port>`，默认 9000），不需要是集群成员、不需要任何 token。

### 高危 · `NetworkTransport.zig:76-89` + `RaftTransport.zig:588-591`（共用 `sockread.zig:22-29`）
accept 循环**在接收线程上同步调用 handler**，而 `handleConnection` 的 `conn.recv(&in)` 读的是长度前缀 + 定长体，**没有任何 recv 超时**：`grep -rn setRecvTimeout src/` 只命中 `RaftTransport.zig:523`（出站客户端侧）。对端连上、发 4 字节长度（如 `0x000FFFFF`）、然后一个字节都不发 → 接收线程死在 `readFull` → **该节点再也收不到/回不了任何 vote/AppendEntries**（选主、心跳、日志复制全停）。

证据：
```zig
// NetworkTransport.zig:81-89 —— 一次一个、内联处理
const stream = (self.listener orelse break).accept(self.io) catch |err| { ... };
const conn = ClusterConnection.init(self.allocator, stream, self.io);
handler(conn);                       // 阻塞在这里，accept 环不再前进
```
```zig
// NetworkTransport.zig:39-48 —— 先 resize 再阻塞读
const msg_len = std.mem.readInt(u32, &len_buf, .big);
if (msg_len > MAX_MESSAGE_SIZE) return error.MessageTooLarge;   // 长度有 1MB 上限：好
try buf.resize(self.allocator, msg_len);                        // 先按声明分配（≤1MB）：可接受
try sockread.readFull(self.stream, buf.items[0..msg_len]);      // 无超时：坏
```
**额外后果**：`ClusterBootstrap.stop()`(247-256) 靠 `wakeAccept` 唤醒"卡在 accept"的环，但环此刻在 `readFull` 里 → 唤醒连接只进 backlog，`thread.join()` **永久阻塞**，节点无法优雅停机（`docs/DISTRIBUTED.md` 承诺的停机会挂）。
**内部不一致的证据**：`DistributedEventBus.zig:156-164` 明确为同一个问题把连接处理挪进 `concurrent` fiber（注释原话："`handleConnection` blocks on peer reads … would run it on the accept thread and freeze the accept loop"）——集群 accept 环没做同等处理。

### 高危 · 入站路径零认证（`RaftTransport.zig:588-640`，`ClusterBootstrap.zig:211-233,300`）
`handleConnection` 从解码到 dispatch 全程不看来源身份：任何 TCP 对端都是完整 Raft 参与者。可做三件事，全部不需要集群身份：
- **替非成员投票/烧掉任期**：`handleVoteRequest`(351-384) 只比 term 与日志新旧，**不检查 `candidate_id` 是否成员**（对比 `handleVoteResponse` 的 `peerId` 成员校验 702 —— 一侧有、一侧没有）。对端发 term=huge + 任意 `candidate_id` → 本节点 `voted_for = 对端字符串`，真正的候选人在该任期拿不到票 → 选举反复失败。
- **冒充 leader 灌日志**：`handleAppendEntries`(391-473) 不校验 `leader_id`。任意对端可 append 任意 command，并把 `leader_commit` 推到日志尾 → 本节点把这些当成已提交。
- **抹掉本节点日志**：`prev_log_index=0`（跳检）+ 一条 `index=1, term=≠现term` 的 entry → 走 `truncateLog(0)`(431/446) → **整份日志被清空**（含已提交项）。

证据：`ClusterAuth`（HMAC-PSK 验证器，`TlsTransport.zig:28-75`）**没有任何调用点**：
```
$ grep -rn "ClusterAuth|pre_shared" src/ examples/   → 只命中 TlsTransport.zig 自身与其测试、以及 src/tests.zig:73 的 _ = @import
```
框架自己的测试就是证据：`ClusterBootstrap.zig:549` 的用例用一条裸 TCP 连接、`candidate_id="peer-node"`（不在 peers 里）换到了 `vote_granted == true`。
**前置条件**：TCP 可达集群端口。**这是网络暴露问题**：端口绑 `0.0.0.0`，文档（`docs/DISTRIBUTED.md`）只说"对端发来的投票/复制消息"，没有写任何信任边界或"必须放内网/防火墙"的运维前提。

### 中 · `RaftTransport.zig:232` + `RaftElection.zig:441-460` —— 内存放大与无界日志增长
`const entries = try allocator.alloc(LogEntry, try cur.u16v());` **先按对端声明的数量分配，再校验剩余字节**：约 40 字节的帧可换 65535 × 24B ≈ **1.5MB** 暂态分配（arena 随连接结束释放，故只算中）。更实质的是**保留侧**：解码出的每条 entry 都 `dupe` 进 `raft.log` 永久保留（`RaftElection.zig:453-459`），而 `entries.len` 与日志长度**都没有上限**（`config.max_append_entries` 只用在出站 499-509）。1MB 一帧、空 command 时可塞约 5.8 万条 → 每帧约 2.4MB 常驻增长，连接可循环 → 单对端把节点堆到 OOM；日志只在 app 主动 `compactLog` 时才收缩。**前置条件**：TCP 可达（同样零认证）。

### 低 · `RaftElection.zig:416-417`（同形：374-375、839-840）—— 先 free 再 `try dupe`，失败留悬垂指针
```zig
if (self.leader_id) |l| self.allocator.free(l);
self.leader_id = try self.allocator.dupe(u8, req.leader_id);  // dupe 失败 → 赋值不发生
```
`try` 失败时 `self.leader_id` 仍指向已释放内存 → `getLeader()` 返回悬垂切片，`deinit`(276 附近) 二次 free。**需要分配失败**（OOM）才触发，而 OOM 恰好可被上一条（无界日志）驱动。**前置条件**：TCP 可达 + 能诱发 OOM。

### 信息 · 其余解码面**没有**发现"先 resize 再读"式漏洞（值得记下来，避免下一步重复排查）
`Cursor.take`(`RaftTransport.zig:79-83`) 的边界检查是**正确**的（`n > bytes.len - pos`，且 `pos` 单调、只按已校验的 `n` 前进，不存在下溢或死循环）；`str()` 走 `take` 后才 dupe；帧长在 `NetworkTransport.zig:44` 有 1MB 硬上限、`u32` 不做窄化；流内所有**会被保留**的字符串（`voted_for`/`leader_id`/`snapshot_data`/`command`）都显式 dupe，arena 释放后无悬垂。缺陷全在"解码值被当作可信语义"这一层。

---

## 2. 值得怀疑但未能确认

- **`ClusterMembership.zig:263` `@intCast(port_i)` 无范围检查**（`port` 字段是 `u16`，`port_i` 是 JSON 里来的 `i64`）：`{"p":-1}` 或 `{"p":99999}` 会在 Debug/ReleaseSafe panic。`t` 有 `1..5` 校验(258)、`ts` 只是 i64，唯独 `p` 没有。
  **为什么无法确认**：我找不到可达路径。合法发送方（`ClusterMembership.broadcastEvent:236`）的 `port` 来自 `IpAddress.ip4.port`(u16)；而经总线注入时，`DistributedEventBus.extractJsonValue`(241-254) 扫描到第一个 `"` 就截断，攻击者嵌在 `"payload":"…"` 里的 `{"p":-1}` 只能还原成 `{`（`serializeEvent`(434-441) 不做转义，所以内层引号必然先被吃掉），gossip 解析随即返回 null。**要么我漏了一条注入通道，要么这是"等协议一变就炸"的潜伏点。**
- **`entry.index` 非连续/任意值**是否还有除"清空日志"以外的安全后果：`handleAppendEntries` 完全接受不连续 index 并据此 append(455-459)，`advanceCommitIndex`(562-582) 又用 `log.items[n-1]` 位置寻址。我确认了单个帧能清日志，但**没有完整推演** leader 侧 `match_index`/`next_index` 被这些畸形 index 污染后的全部后果（需要跟 `sendAppendEntries`:485-558 的收敛逻辑一起跑才敢下结论）。
- **README/docs 的"生产部署"是否要求把集群端口放内网**：我 grep 了 `docs/DISTRIBUTED.md` 未见任何信任边界声明，但没读全 `examples/production-deploy/**`（nginx/envoy/k8s）——如果那里已经强制内网隔离，第 3 条的严重度应下调。

---

## 3. 结构性观察

- **一层的正确性依赖另一层的"记得"**：`Cursor` 把长度/边界做得干净，但它交出的**语义值**（`index`、`term`、`leader_id`、`candidate_id`）被上层无条件信任；`handleVoteResponse` 有成员校验、`handleVoteRequest` 没有 —— 同类检查在两个 handler 间不一致，正是"靠记得"而非"编译期强制"的典型形状。
- **入站与出站的韧性不对称**：出站侧把 `rpc_timeout_ms` 用在了 `setSockopt(SO_SNDTIMEO/SO_RCVTIMEO)`(477/515/523)，入站侧一条都没有；`sockread.setRecvTimeout` 的文档注释本身就在描述"对端接受后不应答"这个入站场景。
- **环形拓扑假设未文档化**：`ClusterServer.start` 是"单线程串行处理 + 内联业务"，即"集群 RPC 量小、对端都善意"；这个假设没有写在 `ClusterServer` 的文档注释里（对比 `DistributedEventBus` 就写了为什么必须并发）。
- **OOM 路径被当成"不会发生"**：`free 后 try dupe` 的模式出现 3 处，而同一进程里存在对端可驱动的无界分配。错误路径没人测。
- **测试面的缺口（重要）**：`decode*` 只有"自己编码→自己解码"的闭环（`RaftTransport.zig:721` "wire format round-trips every Raft RPC"），它确实覆盖了错 tag → `UnexpectedMessageTag`、未知 tag → null(797-798)，但**没有一条恶意字节用例**：`error.TruncatedMessage` 全仓库只出现在定义与抛出点(`RaftTransport.zig:65,80`)，**没有任何测试断言过它**；也没有 index=0、超大 count、零长字段的用例。

---

## 4. 我读了什么 / 我没读什么

**逐行读了**：`sockread.zig`(全) · `NetworkTransport.zig`(全) · `RaftTransport.zig`(全 1281 行，含测试) · `ClusterMessage.zig`(全) · `TlsTransport.zig`(全) · `RaftElection.zig` 第 80-920 行（全部 `handle*` + 状态访问器 + 私有 helper）与 1600-1640 · `ClusterBootstrap.zig` 40-320、380-620 · `ClusterMembership.zig` 200-320（gossip 解析）· `DistributedEventBus.zig` 120-270、434-441。

**只做了 grep 级检查（未逐行读，因此"没找到"≠"安全"）**：`LoadBalancer.zig`、`PeerDiscovery.zig`、`FailureDetector.zig` —— 在它们里 grep `recv|readFull|readSome|readInt|@intCast|@truncate|fromJson|resize|alloc(` 只命中 `LoadBalancer.zig:52` 一行本地时间取模（无对端字节解码）；`PeerDiscovery.zig:57` 只解析**本进程配置**里的 `host:port`。**结论：这三个文件不接触对端字节，但我没有通读它们的逻辑。**

**明确没覆盖**：
- `RaftElection.zig` 其余约 1200 行：`tick()`/`startElection`/`becomeLeader` 的选举时序、`RaftLock` 自旋锁本身的正确性、以及全部测试体（第 920-2156 行）。
- `DistributedEventBus.zig` 其余约 680 行（总线自身的帧格式、`pushParseFailureToDlq`、连接方向的路由与并发上限）——它的入站端口同样无认证，**我只读了 120-270 与 434-441**。
- `ClusterMembership.zig` 其余约 300 行（`runOnce`/gossip 广播/leader 选举/`nodes` 表）；`ClusterHealth.zig`/`ClusterMetrics.zig`；`cluster/MembershipView.zig`/`ClusterView.zig`；`DistributedTransaction.zig`/`DistributedLock.zig`（不在本次点名的文件集里）。
- **`WsFramer`/`im/**` 完全没碰**（审计报告并列的另一段高风险未审计代码）。
- **没有运行任何东西**：全部结论来自静态阅读；`MAX_MESSAGE_SIZE`/索引下溢/accept 环阻塞这几条的"实际爆炸形状"取决于构建模式（Debug/ReleaseSafe = panic abort；ReleaseFast = 越界读/UB），我**没有编译或运行验证**——按只读纪律，也没有为它造临时测试文件。若需要"能跑出来的证据"，最小验证是给 `RaftElection.handleAppendEntries` 加一条 index=0 的单测（会 panic）和一条 `handleConnection` 半帧连接的单测（accept 环停摆）。
---

## 5. 修复状态（v0.32.0）

本文第 4 节最后一段提出的"最小验证"已经做了，两条高危也已修：

| # | 发现 | 状态 |
|---|------|------|
| 1 | `entry.index == 0` 下溢（`RaftElection.zig`） | **已修** + 单测 + 变异 |
| 2 | 入站 `recv` 无超时（`RaftTransport.zig`） | **已修** + 单测 + 变异 |
| 3 | 入站路径零认证 | **未修**（本次未动；`ClusterAuth` 全仓库零调用点已复核） |
| 中 | 无界日志增长 / `count` 内存放大 | **未修**（`config.max_append_entries` 只用在出站） |
| 低 | 先 free 再 `try dupe`（3 处） | **未修** |

### 第 1 条的实测形状（**更正本文 1.1 节的判断**）

修法是**在任何日志改动之前**拒绝 `index == 0`（`error.InvalidLogIndex`），并且检查必须在条目循环**之外** ——
循环体内先 `truncateLog` 再 append，放进去会让畸形请求在失败路上先删掉已提交的条目。

去掉守卫、两次独立实测后，本文原来写的"Debug/ReleaseSafe = panic abort；ReleaseFast = 野指针读"
**只对了一半**：

- **Debug / ReleaseSafe**：`panic: integer overflow` → `signal ABRT`。注意**不是**下标越界 ——
  `entry.index - 1` 是运行时 `u64` 减法，**溢出检查先于任何下标使用触发**。
- **ReleaseFast**：**不是野指针**。没有溢出检查，减法绕成 `0xFFFF_FFFF_FFFF_FFFF`，而地址运算
  把 `items[那个值]` 折到 **`items.ptr - 32`**：独立探针实测 `sizeof(LogEntry) == 32`、`delta = -32`，
  也就是**正好往回一个条目**（落在同一块分配的紧邻位置）—— 这也解释了它为什么不 segfault。
  于是循环拿到的是越界的 `term`，实测里**这条畸形请求被接受了**：一条两条条目的日志
  （index 1、index 0）返回 `.{ .success = true, .match_index = 2 }`，即**向 leader 报告 index 2 已复制**。
  **这是 Raft 状态机的 safety 违背**，比"崩溃"更值钱的部分在这里。

所以"越界读"这个说法要改成"**越界读一个条目 + 静默接受**"；而安全构建是 **abort**，不是可捕获的错误 ——
对端一个帧、无需认证，节点直接没了。

### 第 2 条的修法与边界

入站 `handleConnection` 现在也设 `setRecvTimeout` / `setSendTimeout`，复用出站那个
`ElectionConfig.rpc_timeout_ms`（默认 100ms）—— 它从此同时约束一次 RPC 的**两个方向**。
WAN 觉得紧就把两端一起调大（没有新开字段：与出站同源）。

**这条修的是"挂死"，不是"吞吐"**：`ClusterServer.start` 仍然在**单线程内联**跑 handler，
一个慢对端仍然串行占用 accept 环。本文 3 节里"入站与出站的韧性不对称"这条观察现在只剩
这一半成立。

### 两条判据

- `src/core/cluster/RaftElection.zig` —— `an AppendEntries entry with index 0 is refused before the log is touched`。
  去掉守卫 → **abort**（进程级，不是断言红，报告里如实标了）。
- `src/core/cluster/RaftTransport.zig` —— `a half-frame on the inbound side costs rpc_timeout_ms, not the whole node`。
  第二个对端发一个完整但 tag 未知的帧；判据是它**被服务**（拿到 `error.ConnectionClosed`）而不是
  自己超时（`error.ConnectionError`）。变异 `rpc_timeout_ms = 0` →
  `expected error.ConnectionClosed, found error.ConnectionError`，**断言红**。
  依赖环回 TCP（`NetworkProbe.available()`，受限环境下 skip）。

**没锁住的**：`error.InvalidLogIndex` 在 `handleConnection` 里落到 `logDrop`（debug 日志 + 断开、
不回包）—— 这是对恶意帧的正确行为，但没有用例钉住它。
