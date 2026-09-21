# 集群入站零认证 —— 设计（未实现）

> 状态：**§3（L1 逐帧 HMAC 认证）与 §3.5（fail-closed 门禁）已实现并验证；
> §4（L2 成员校验）已实现 —— 它当初被 §10 的缺陷阻断，§10 修完后随之解锁。**
> 来源是 `docs/dev/security-audit-cluster.md` 的第 3 条高危，
> 以及本次评估中对 `handleVoteRequest` / `handleAppendEntries` 的复核。
> 所有事实都带 `文件:行`；推测的地方显式标注"未验证"。

## 0. 结论（一句话）

今天**TCP 可达即集群成员**：`TlsTransport.ClusterAuth`（HMAC-PSK）定义在案、有单测，
但**全仓库零调用点**，连"打开它"的入口都不存在。要用 HS256 把每个入站帧按
`[len][tag][payload][mac32]` 验一遍，并在 `ClusterBootstrap.start()` 上按既有
`allow_stub_raft_transport` 的同一种"拒绝 + 显式承认"惯用法做 fail-closed。
**成员校验（L2）必须与认证（L1）同批上 —— 单独上 L2 是安全剧场。**

---

## 1. 威胁模型：对端今天能做什么

前提：攻击者只是**能连到集群端口**（默认 `0.0.0.0:9000`，`ClusterBootstrap.zig:144`），
不需要任何凭证、不需要是集群成员。以下每条都已复核：

| # | 能做 | 证据 |
|---|---|---|
| 1 | **拿到投票**，从而把任意候选人推成 leader | `RaftElection.zig:351-384` `handleVoteRequest` **没有成员校验**：只看 `req.term` 与"日志是否够新"，而 `last_log_index` / `last_log_term` 都是**对端自己填的** |
| 2 | **冒充 leader 灌日志**，并把自己写成本节点的 leader | `:416-417` 只 `dupe(req.leader_id)`，从不校验它是不是已知 peer；`:405-410` 只要 `term >= current_term` 就把本节点变 follower |
| 3 | **清空全量日志** | `:894-899` `handleInstallSnapshot` 在 `last_included_index` 更大时 free 掉所有 log 条目（无需 OOM） |
| 4 | **让日志无界增长** | inbound 不校验 `req.entries.len`，也不限日志长度；`compactLog`（`:845`）在 `src/` 内**零调用点** |
| 5 | 在同进程另一个端口上冒充总线成员 | `src/core/DistributedEventBus.zig:117`（自己的 listener）、`:149`（accept 环）、`:198`（`handleConnection`，同样零认证） |

**对照**：`handleVoteResponse`（`:735-740`）**有**成员校验（`peerId(from_peer) orelse return`）。
同一族的两个 handler 一个有一个没有 —— 这是漏检，不是设计。

**已核对不在范围内**：`ClusterMembership`（`src/core/ClusterMembership.zig`）**没有**
`listen()` / `accept()`，所以 gossip 不构成独立入站面。

**文档现状**：`docs/DISTRIBUTED.md` 里 `认证` / `密钥` / `secret` / `威胁` / `安全`
**零命中** —— 集群侧从来没有写下来的安全口径。本设计落地时要往那里补一节威胁模型。

---

## 2. 为什么 L2（成员校验）不能单独上

把 `handleVoteRequest` 改成"只认 `self.peers` 里的 `candidate_id`"，**在没有认证的前提下几乎不提高门槛**：

- `candidate_id` 是**明文的自述**，攻击者填一个成员 id 就行；
- 成员 id 通常可猜（`node-1`、`node-a`），且**地址簿里的 id 本来就互相公开**。

所以 L2 的真实价值是别的东西（见 §4.2），**它不能替代 L1**。反过来 L1 也不能替代 L2：
认证只回答"你确实是 node-3"，不回答"node-3 该不该发这条 RPC"（例如已被移出集群的节点）。

**顺序：L1 与 L2 同批，L1 是实现 L2 语义的前提。**

---

## 3. L1：逐帧 HMAC 认证

### 3.1 帧形状

现在：`[4-byte BE len][tag: u8][payload...]`，tag 用 `MessageTag`（1..6，`RaftTransport.zig:49-56`），
`len` 由 `NetworkTransport.ClusterConnection.recv` 消费（`NetworkTransport.zig:39-49`）。

改为：`[4-byte BE len][tag][payload][mac: 32 raw bytes]`，**MAC 覆盖 `[tag][payload]`**。

- `len` 因此要**包含** 32 字节 MAC —— 由 `send` 侧算，`recv` 侧不用改（它只读 `len` 个字节）。
- **验证与剥离在解码之前**：`handleConnection` 拿到整帧后切掉尾部 32 字节、验签、把
  `frame[0..len-32]` 交给**原封不动的** `tagOf` / `payloadOf` / `decode*`。
  所以 **6 个 `decode*` 一个字节都不用改**。
- 否决的替代方案：把 MAC 塞进 payload（JSON 字段）—— 会逼所有 codec 改动，而且 MAC 覆盖的是
  **重新序列化**的形态，语义更弱。

### 3.2 `ClusterAuth` 需要补什么

现有 `ClusterAuth`（`TlsTransport.zig:28-75`）够用但缺两件：

1. **`sign` 返回的是 hex（64 字节，`:48-59`）**，帧里要的是 **raw 32 字节**。
   加一个 `mac(self, payload) ![32]u8`（直接 `HmacSha256.create` 到 `[32]u8`），
   hex 那版留给人和 JSON 用。
2. **收发一对 helper**，让三个调用点各改**一行**：
   - `sendSigned(conn, frame)` —— 算 MAC、拼 `[len][frame][mac]`、写；
   - `verifiedRecv(conn, buf) ![]const u8` —— `conn.recv` 后切尾、验签（**constant-time，
     复用 `:62-67` 已有的 `timingSafeEql`**）、返回剥离后的 `frame`。
   - 失败一律 `error.ClusterAuthFailed`，调用方按"丢弃这个对端"处理。

### 3.3 验签点

`NetworkTransport.ClusterServer.start`（`NetworkTransport.zig:76-90`）只是一个 accept 环，
**它自己没有配置**（handler 签名是 `fn (ClusterConnection) void`，无法传 auth）。所以 handler 各自验：

| 调用点 | 文件 | 说明 |
|---|---|---|
| Raft 入站 | `RaftTransport.zig:588` `handleConnection` | **唯一的 Raft 咽喉**：已有 `raft` 参数，auth 挂在 `RaftElection`（或 `ElectionConfig`）上最省事 |
| Bootstrap 入站 | `ClusterBootstrap.zig:292-301` `onInboundConnection` | **只是转发**（`:300` 调 `RaftTransport.handleConnection`）—— 所以上面那一个咽喉就覆盖了它，不必单独改 |
| 总线入站 | `DistributedEventBus.zig:198` `handleConnection` | 自己的 listener（`:117`/`:149`），需要自己的 secret |

> 所以 Raft 侧是**一处实现**（`RaftTransport.handleConnection`），另加总线那一处独立实现。
> 两处都调 `verifiedRecv` —— 是"一处 helper、两处一行"的形状，不是两份逻辑。

### 3.4 密钥来源

- `BootstrapConfig` 加 **`cluster_secret: ?[32]u8 = null`**（与既有 `transport` / `allow_stub_*` 同处，`ClusterBootstrap.zig:49-72`）。
- **应用自己从 `SecretsManager` 取**（env > file > vault KV v2）再填进来 —— 不在框架里新造一条密钥通道，
  也不让 secret 出现在源码里。文档给一句示例即可。
- 16/24/32 字节都接受（HS256 用 32）；短于 16 直接拒。

### 3.5 fail-closed（复用既有惯用法）

`ClusterBootstrap.zig:159-168` 已经有这个形状：

```zig
if (self.config.transport == null and self.config.raft_cluster_size > 1 and !self.config.allow_stub_raft_transport) {
    log.err(...);
    return error.RaftTransportUnavailable;
}
```

照抄一条：

```zig
// 多节点 + 真传输 + 没有密钥 → 拒绝启动
if (self.config.transport != null and self.config.raft_cluster_size > 1
    and self.config.cluster_secret == null and !self.config.allow_unauthenticated_cluster)
{
    log.err("cluster_secret is required for a multi-node cluster; set it from SecretsManager, "
        ++ "or acknowledge with `.allow_unauthenticated_cluster = true`", .{});
    return error.ClusterAuthRequired;
}
```

- `raft_cluster_size <= 1`（单节点）不需要密钥 —— 没有对端要对。
- `allow_unauthenticated_cluster` 是**大声承认**，与 `allow_stub_raft_transport` 同一种诚实。
- `DistributedEventBus.start(port)` 是另一个入口，需要它自己那份（同一个 secret 传进去即可）。

### 3.6 重放：**接受，但写下来**

裸 MAC 覆盖 `[tag][payload]`，所以**能被线路上的旁观者重放**（本传输是明文，见 §5）。
判断：**Raft 本身对重放基本免疫**，逐条：

- 陈旧的 `vote_request` / `append_entries` —— `term` 单调：投票的授予被 `:364` 的
  `req.term >= self.current_term` 门住，append 被 `:396` 的 `term < current_term` 直接拒；
- 重复的 `append_entries` —— `prev_log_index/term` 匹配 + `entry.index <= log.len && term 相同` → `continue`（`:456-465`），幂等；
- 重复的 `install_snapshot` —— 只在 `last_included_index >` 当前值时生效（`:894`），第二次不再触发；
- 重复的 `vote_response` —— `votes_received` 是集合（`:740`），重复计数不变。

**代价**：要彻底消掉重放得给每个 peer 维护单调计数器（对端状态 + 窗口），
而它挡掉的是 Raft 已经会拒的一类帧。**建议接受，并在 `docs/DISTRIBUTED.md` 写成明示的残留风险**，
而不是默默假设。若以后要关掉：给 MAC 加"时间戳 + 偏移窗口"（简单，不引入 per-peer 状态）。

---

## 4. L2：成员校验

### 4.1 三个 handler 加对称校验

| Handler | 改动 | 依据 |
|---|---|---|
| `handleVoteRequest`（`:351`） | `self.peerId(req.candidate_id) orelse return .{ .term = self.current_term, .vote_granted = false }` | 与 `handleVoteResponse:739` 对称 |
| `handleAppendEntries`（`:391`） | `leader_id` 不是已知 peer **且不是自己** → 拒绝（`success = false`，不动日志） | 现在只 `dupe`（`:416`） |
| `handleInstallSnapshot`（`:894`） | 同上 | 这是清日志那条路 |

### 4.2 L2 的真实价值（不是"挡住攻击者"）

1. **挡住不再合法的成员**：已被移出集群 / 已退役的节点，其 id 不再是成员 —— 认证只能证明"你是 node-3"，
   证明不了"node-3 还该投票"。
2. **把一整类 bug 变成干净的拒绝**（`handleVoteRequest` 与 `handleVoteResponse` 现在不对称这件事本身）。
3. **不作为唯一屏障**：它是纵深防御的第二层，第一层是 L1。

### 4.3 ⚠️ 一个必须先在实现里回答的问题：动态成员加入

`addPeer`（`:809`）允许运行期加 peer。**未验证**：`ClusterBootstrap` 的加入路径是否
**在任何 `AppendEntries` 到达之前**就把新成员写进本地 `peers`？

- 若**是** —— L2 无副作用。
- 若**否** —— 新节点会拒掉现任 leader 的心跳，永远加不进来。

**所以 Phase 5 的第一件事是读加入路径并补一条用例，而不是先改代码。**

---

## 5. 爆炸半径与迁移（**这条最需要有意识的决定**）

帧形状变了 ⇒ **混合版本集群里，旧节点与新节点互相听不懂**。

**建议：不协商，硬切。** 理由：这是 fail-closed 的安全特性，协商一个"降级到不认证"的路径
等于把整条修复作废。让失败形态是**响的**：

- 配了 secret 的节点收到**没有 MAC / MAC 不对**的帧 → **丢弃 + 日志**（`error.ClusterAuthFailed`）；
- 后果是**选不出 leader**，而不是**静默地不认证地运行**。

这个失败形态（"集群起不来"）比"看起来正常但不设防"好得多，也是本仓库一贯的取向。

**未验证**：`DistributedEventBus` 与新节点混跑时，总线侧是否也需要独立处理跨版本 —— 实现时确认。

**不做加密**：MAC 给的是**完整性 + 身份**，不是**机密性**。帧仍然明文。要机密性得走
TLS/边车（`TlsTransport.zig:1-8` 的文件头已经写明 mTLS 目前要边车）。这是另一件事，本设计**不声称**覆盖它。

---

## 6. 明确不做

- 不做授权（"哪个节点有权做什么"）—— 只做认证。
- 不加密（见 §5）。
- 不顺手修 §1 表里的 #4（无界日志 / `compactLog` 零调用点）与 `free` 后 `try dupe` 的 5 处
  —— 是独立项，混进来会让"认证"这次改动的判据变模糊。
- 不改 `ClusterMembership`（它没有入站面，已核对）。

---

## 7. 实现时的红证据清单（先写红，再动代码）

| # | 用例 | 期望 | 变异（红的样子） |
|---|---|---|---|
| 1 | 一帧带合法 MAC | 被处理 | 去掉验签 → **投票被授予** |
| 2 | 无 MAC 的帧 | 丢弃，handler 不进入 | 同上 |
| 3 | 用**另一个密钥**签的帧 | 丢弃 | 把 verify 改成恒真 → 红 |
| 4 | MAC 正确但 payload 翻了一字节 | 丢弃 | 只覆盖 payload 不覆盖 tag → 红 |
| 5 | `handleVoteRequest` 传 `candidate_id = "outsider"` | `vote_granted == false` | 删掉 `peerId` 守卫 → **现在会授予**（这条是 L2 的判据） |
| 6 | `raft_cluster_size = 3` + `.transport` + 无 secret | `start()` 返回 `error.ClusterAuthRequired` | 去掉门禁 → 红 |
| 7 | 单节点（`raft_cluster_size = 1`）无 secret | 正常启动 | — |

> #5 是**当前就会红**的一条：它在改之前先失败，正是 L2 的存在理由。
> 另：`ClusterAuth` 的两个既有单测（`TlsTransport.zig:77-108`）用
> `@intFromPtr` 种 `DefaultCsprng`（`:80-86`）—— 那是**测试种子、不是安全边界**，
> 但既然 `AGENTS.md` 刚把"`@intFromPtr` 不是熵源"写进 DO/DON'T，顺手改成固定字面量更干净。

---

## 8. 工作拆分（若批准）

| 阶段 | 内容 | 判据 |
|---|---|---|
| 1 | `ClusterAuth.mac()` + `sendSigned` / `verifiedRecv` + 单向自测 | 第 1–4 条红证据 |
| 2 | 接进 `RaftTransport.handleConnection` + 出站发送侧 | 真实环回的选举仍能选出 leader（现有测试必须继续绿） |
| 3 | `BootstrapConfig.cluster_secret` + `start()` 门禁 + `allow_unauthenticated_cluster` | 第 6–7 条 |
| 4 | `DistributedEventBus` 自己的 listener | 同 1–4 的形态 |
| 5 | L2 三个 handler 的成员校验 **（先读加入路径）** | 第 5 条 + 加入路径用例 |
| 6 | `docs/DISTRIBUTED.md` 补威胁模型与残留风险（重放、明文） | 文档门禁 |

阶段 1–3 是一件事（Raft 侧闭环），4 独立，5 依赖 1。

---

## 9. 需要你定的四个问题

1. **混合版本**：硬切（建议）还是加一段协商？协商会引入"降级到不认证"的路径，我不建议。
2. **范围**：这次只做 Raft 侧，还是连 `DistributedEventBus` 的 listener 一起（阶段 4）？
3. **重放**：接受并在文档写明（建议），还是直接上时间戳 + 偏移窗口？
4. **密钥**：`BootstrapConfig` 收 `?[32]u8`、应用自己从 `SecretsManager` 取（建议），
   还是让配置写 SecretsManager 的 key 名、由框架去取？

另外：**是否单开一个版本**（这是破坏性的 wire 变更，够一个 `!`）。

---

## 10. 实现前的核查结果（2026-09-21）：**L2 被一个更严重的既有缺陷挡住**

§4.3 说"阶段 5 的第一件事是读加入路径并补用例，而不是先改代码"。读了，结论比预想严重：
**peer id 空间不一致，导致 `ClusterBootstrap` 配出来的多节点集群今天选不出 leader。**

### 证据链（逐条可核对）

1. `ClusterBootstrap.zig:201-203`：`try raft.addPeer(p.host);` —— **peer 的 id 是 host 字符串**
   （`config.peers = &.{"127.0.0.1:19005"}` 经 `PeerDiscovery.resolve()` 得到 `Peer{.host="127.0.0.1", .port=19005}`），
   地址簿另存 `host:port`。`docs/DISTRIBUTED.md` 的样例配置就是这个形状。
2. 但节点自己的 `local_id` 是 **`config.node_id`**（`ClusterBootstrap.zig:195`）。
3. 投票回复上线时带的是 `raft.local_id`（`RaftTransport.zig:634`：`encodeVoteResponse(&out, allocator, resp, raft.local_id)`）。
4. 候选人计数时把它交给 `peerId(from_peer)`（`RaftElection.zig:762`），而 `peerId` 只在 **`self.peers[].id`** 里找 ——
   也就是 **host 字符串**。`"node-b"` 在 `{"127.0.0.1"}` 里找不到 → `orelse return` → **这一票被丢弃**。
5. `quorumSize() = clusterSize/2 + 1`（`:970-972`）且 `votes_received` **只数 peer 的票**，
   所以多节点集群**永远到不了多数** → 永远选不出 leader。
6. `ClusterBootstrap` 的测试里**没有一处断言过 leader**（`isLeader`/`getLeader` 在测试区零命中）——
   与这个结论一致，所以它一直没被发现。

> **为什么这对 L2 是阻断性的**：`handleAppendEntries` 现在**不校验** `leader_id`，
> 这正是 leader→follower 的日志复制**唯一还能工作**的原因。若照 §4.1 给三个 handler 加成员校验，
> 合法的 leader（`"node-a"`）同样会被拒 —— **把唯一能走的路也堵死**。

### 因此的排序修正

```text
① 修 peer id 空间（peer id = node_id；地址簿单独承载 host:port）
      ↓  （这是选举能不能工作的前置，也是 L2 的前置）
② L1 逐帧 HMAC 认证（与 id 空间正交，可以并行/先落）
      ↓
③ L2 三个 handler 的成员校验
```

**L1 不受影响**，所以本次照 §3 实现 L1 + §3.5 的 fail-closed 门禁；**L2 留到 ① 之后**。
§4.1 的三个校验点、§7 的第 5 条红证据，都要等 ① 落地。

### §10 修复记录（2026-09-21）—— **① 已落地，本缺陷关闭**

取 **(a) 配置带显式 id**。理由就是 §10 的前提：`BootstrapConfig` 没有 host/advertise 字段（只 `node_id` +
`port`，且 `ClusterBootstrap` 绑 `0.0.0.0`），所以 (b)"人人以 `host:port` 为身份"既做不到，也把身份与地址
混成一件事 —— 而这正是缺陷的根。

| 文件 | 改动 |
|---|---|
| `PeerDiscovery.zig` | `Peer` 增 `id`（与 `host` 同为自有拷贝）；静态语法 `"<id>@<host>:<port>"`，`@<id>` 可省（`id` 回落成 host，旧配置照常解析）；`id` 的一切 free（`deinitResolved` / `registerPeer` / `listPeers` / `registerService` / `deregisterPeer` / `deregisterService` / `deinit`）与 `host` 同进同出 |
| `ClusterBootstrap.zig` | `raft.addPeer(p.id)` + `addresses.add(p.id, p.host, p.port)`（**曾是 `p.host`**）；新增第三道门禁：`raft_cluster_size > 1` 且任一 peer 的 `id == host` → `log.warn` + `error.PeerIdRequired` |
| `LoadBalancer.zig` | 金丝雀 peer 与 `registerService` 调用点补齐 `id`（金丝雀按地址选，`id` 取 host —— 与静态 peer 的回落同一条规则） |

**门禁为什么不是回归**：`id == host` 的 peer 投出的票**一张也计不进来**（§10 的证据链），所以那种集群
**本来就是死的**；拒绝它只是把"静默地永不选主"变成启动错误。单节点（`raft_cluster_size <= 1`）没有票要计，不受影响。

**验证**（全量 1494/1515，21 skipped，0 failed；`zig fmt --check` + 6 道门禁全绿）：新增 4 条用例 ——
`PeerDiscovery` 两种语法的解析、`PeerIdRequired` 门禁（带正对照）、
`a ClusterBootstrap-configured cluster elects a leader (peers credited by id)`、以及 mirror 该接线的
`RaftElection` 版（走 `addPeer`，即 `start()` 用的那条路）。**两条变异验过红**：
`addPeer(p.id)` 改回 `addPeer(p.host)` → 选举用例 `FAIL (TestUnexpectedResult)`；
门禁条件改成永不触发 → `expected error.PeerIdRequired, found void`。都是断言红、非编译错，且已按字节还原。

**为什么此前没被发现**：`ClusterBootstrap` 的测试没有一处断言过 leader（`isLeader`/`getLeader` 在测试区零命中）——
用例只验"起来了"。新的那条用例连同"candidate → 收到一张票 → leader"一起断言，这个空洞才闭上。

**仍未做**：§4/L2 的三个成员校验点 —— 现在排位正确了（① 已落地），但它会动到 `handleVoteRequest` /
`handleAppendEntries` / `handleInstallSnapshot` 的拒绝语义，单独一步。

---

## 11. L1 实现记录（2026-09-21）

§3 + §3.5 已落地。落在四个文件：

| 文件 | 改动 |
|---|---|
| `TlsTransport.zig` | 新增 `ClusterAuth.mac()` —— 返回**原始 32 字节** HMAC（`sign` 返回的 64 字节 hex 是给人和 JSON 用的，不能直接上线）；`timingSafeEql` 改为 `pub` 以便复用 |
| `RaftTransport.zig` | 帧形状 `[len][tag][payload][mac32]`；`sendSigned` / `verifiedRecv` / `writeFrameAuth` / `readFrameAuth`；入站验签在**任何 decoder 之前**完成并剥离，所以 6 个 `decode*` 一字未改 |
| `RaftElection.zig` | `ElectionConfig.cluster_secret: ?[32]u8 = null` |
| `ClusterBootstrap.zig` | `BootstrapConfig.cluster_secret` + `allow_unauthenticated_cluster`；门禁紧邻 `allow_stub_raft_transport` 那块，返回 `error.ClusterAuthRequired` |

### 实现期对设计的两处收紧

1. **密钥按值传，不建 `ClusterAuth`。** 第一版每帧 `ClusterAuth.init`（内部 `dupe` 一次 `node_id`）再 `deinit` ——
   而 MAC 只用 `pre_shared_key`，那个 `node_id` 从头到尾没被用过。代价有两个：每帧一次分配，
   以及**分配失败会把一票静默丢掉**（投票/心跳路径上的一个新失败模式）。现在 helper 收 `?[32]u8`，
   `authFor` 整个删掉。这条是 brief 的设计不够好，不是实现的问题。
2. **门禁用 `log.warn` 而不是设计稿里写的 `log.err`。** `scripts/test-runner.zig:176-179` 把
   **任何 err 级日志**本身算作测试失败（`log_err_count != 0` → 判红），所以 `err` 会让门禁测试
   和既有的 `RaftTransportUnavailable` 测试一起失败。错误本身就是响的那部分。

### 顺带必须一起签的三处（否则配了密钥的集群不工作）

入站**回复**、投票响应**中继**、以及 `sendAppendEntries` 对**同一连接回复**的读取。
候选人会验证自己的入站帧，所以未签名的**中继**等于一票被丢；而未验签的回复读取会让 decoder
接受一段从未被认证过的尾部字节。`writeFrameAuth`/`readFrameAuth` 是这两条路唯一的决策点。

### 两个既有测试被改（有意，非弱化）

`ClusterBootstrap accepts an app-supplied Raft transport` 加 `.cluster_secret`（它的配置正是新门禁要拒的
"多节点 + 真 transport + 无密钥"）；`ClusterBootstrap drives raft.tick and serves inbound Raft RPCs` 加
`.allow_unauthenticated_cluster = true`（它**手工写裸投票请求**，必须走裸帧路径）。
两处断言都未被削弱。设计稿点名的 `real loopback election…` 与 `a half-frame on the inbound side…`
**未改动**且通过 —— 它们不带密钥，走的正是裸帧路径。

### 验证

全量 **1489/1510（21 skipped，0 failed）**（比上一版 +11），`zig fmt --check` + **6 道门禁全绿**。
变异逐条验过红：把 `verifiedRecv` 的验签去掉（第一版直接 `return conn.recv`）→ 裸帧测试
`expected error.ClusterAuthFailed, found { …帧字节… }`；把常时比较那行改成不生效 →
`a frame signed with another key is refused` 同形红；删掉 `start()` 门禁 →
`expected error.ClusterAuthRequired, found void`。三条**都是断言红，不是编译错**。

### 未做

- **L2 当时未实现**，因为 §10 的 id 空间缺陷未修：`handleAppendEntries` 那时**不校验** `leader_id`，
  而那正是 leader→follower 复制唯一还能工作的原因 —— 先加 L2 会把唯一能走的路也堵死。
  §10 修完后 L2 已落地，见 §13。
- `DistributedEventBus` 自己的 listener（§3.3 第三个调用点）**未做** —— 独立于 Raft 端口，单独一项。
  **（2026-09-21 已落地，见 §14。）**
- §3.6 的重放残留**按设计接受**（Raft 的 term 单调 + 幂等已覆盖），未做时间戳/窗口。
- **混合版本集群未实测**：设计上硬切（不匹配的帧被丢弃 + debug 日志），但没有真的拿新旧两个二进制对跑。
- 密钥的来源（`SecretsManager`）只有文档约定，**没有代码强制** —— `?[32]u8` 由应用自己填。

---

## 12. 核查中发现的第二条独立缺陷：票数约定差一票（N=2 结构上不可能选出 leader）—— **已修**

§10 是 id 空间的问题。查它的时候顺手验了 `handleVoteResponse` 的计票口径，**是另一条独立的缺陷**，
不需要 id 空间问题也能单独触发。

### 机制

```zig
// RaftElection.zig:769-771
try self.votes_received.put(peer_id, {});
if (@as(usize, self.votes_received.count()) >= self.quorumSize()) self.becomeLeader();

// :976-978 —— 这个数**包含自己**
pub fn quorumSize(self: *const Self) usize { return (self.clusterSize() / 2) + 1; }
// :971-973
pub fn clusterSize(self: *const Self) usize { return 1 + self.peers.items.len; }
```

而 `votes_received` **只记 peer 的票**（`:982-986` 的注释把这当成约定明说了：
"the candidate's own vote is not part of the tally, so a multi-node candidate needs
`quorumSize()` peers behind it"）—— 于是实际要求是 `1 + quorumSize()` 票，而分母只有 `clusterSize()`。
**比 Raft 的多数多要一票。**

### 实测（不是推演）

一条临时探针，2 节点集群（自己 + 1 个 id 匹配的 peer），`startElection()` 后让那唯一的 peer 授予投票：

```
[PROBE] N=2 clusterSize=2 quorumSize=2
[PROBE] after 1/1 peer grants: leader=false
```

**N=2 时 `quorumSize()=2`，而 peer 只有 1 个 —— 结构上不可能达成**，那条集群永远选不出 leader。

### 影响面

| N | Raft 多数 | 本代码要求 peer 票 | 实际总票 | 后果 |
|---|---|---|---|---|
| 2 | 2 | 2 | 3 | **不可能**（只有 1 个 peer） |
| 3 | 2 | 2 | 3 | 需要**全体一致** —— 任一 peer 不可达即无法选举，**零容错** |
| 5 | 3 | 3 | 4 | 需要 4/5，比多数多一票 |

即**整体少一个节点的容错度**，且 N=2 完全不可用。

### 为什么既有的 3 节点用例没抓到

`real loopback election…` 用 3 个节点、两个 peer 都活着 → 2 票拿得到 → 通过。
它甚至把 `hasQuorum(2)` 写进了断言（`:98`），**把这条偏差固化成"期望值"**了。
N=2 的路径没有任何用例经过。

### 修法（一行，但会动到既有断言）

按 Raft 的多数，自己的票要在里面：

```zig
if (@as(usize, self.votes_received.count()) + 1 >= self.quorumSize()) self.becomeLeader();
// 以及 hasQuorum(votes_received) 同步改成 votes_received + 1 >= quorumSize()
```

验算：N=2 → `1+1>=2` ✓；N=3 → `1+1>=2` ✓（需要 1 个 peer）；N=5 → `2+1>=3` ✓（需要 2 个 peer）。
`real loopback election…` 的 `hasQuorum(2)` 要改成 `hasQuorum(1)`；
`:982-986` 的注释必须一起改，否则它继续描述旧口径。

### 与 §10 的关系：两条独立

- §10（id 空间）让 **`ClusterBootstrap` 配出来的**集群选不出 leader —— 票投出去了但计不进来。
- §12（差一票）让 **N=2** 集群选不出 leader —— 票计得进来但门槛够不到。

**两条都要修**，且 §12 是**不需要任何配置决策**的那一条（纯 off-by-one）。
本次**只记录未修**：它会改选举语义与一条既有断言，且 §10 那个配置形状的决定还没定 ——
两件事叠在一起改，判据会糊。

### §12 修复记录

修法就是这一行（`handleVoteResponse` 与 `hasQuorum` 各一处）：

```zig
if (@as(usize, self.votes_received.count()) + 1 >= self.quorumSize()) self.becomeLeader();
pub fn hasQuorum(self: *const Self, votes_received: usize) bool { return votes_received + 1 >= self.quorumSize(); }
```

**三处描述旧口径的注释与断言一并改了**（否则它们继续把偏差当规范）：

| 位置 | 旧 | 新 |
|---|---|---|
| `RaftElection.zig` `startElection` 的口径注释 | "a candidate needs `quorumSize()` distinct peers" | 明说自己那一票要算进去，tally = `clusterSize()` 的普通多数 |
| `hasQuorum` 的文档注释 | "the candidate's own vote is not part of the tally … needs `quorumSize()` peers" | "the +1 here is that vote"，并给出 N=2/3/5 的需求数 |
| `RaftElection quorum calculation` 的断言 | `!hasQuorum(1)`（N=3） | `hasQuorum(1)`，并补 N=2/3/5/N=1 四组算术 |
| `DistributedIntegrationTest` `:392-393` | `hasQuorum(2)` / `!hasQuorum(1)` | `hasQuorum(1)` / `!hasQuorum(0)` |
| `RaftTransport` 环回选举 `:1297` | `hasQuorum(2)` | `hasQuorum(1)` + `!hasQuorum(0)` |

**`RaftElection three-node candidate needs two peer grants, not its self-vote` 这个测试名本身就是那条 bug。**
它的注释写着"a 3-node cluster is only won with 2 of 3 votes"（**正确的 Raft 规则**），
而断言要求的是 **2 个 peer** 的票（= 3 票全拿）—— 注释说的是意图，断言记的是实现，两者矛盾。
已改名成 `a three-node candidate wins with its self-vote plus ONE peer grant`。

`vote counting` 那条从 3 节点换成 **5 节点**：`quorumSize()=3`、自己占一票，所以需要 **2 个 peer** 的票 ——
这才留出"重复票/非成员票落在 tally 里但还没到多数"的观察空间。3 节点下第一票就当选，
根本观察不到重复计票，**这正是它当初被写成旧口径的原因**。

**验证**：全量 **1490/1511（21 skipped，0 failed）**，fmt + 6 道门禁全绿。
新的 `a 2-node cluster elects a leader with its single peer's grant` 我亲自做了变异：
把 `+ 1` 去掉 → `try testing.expect(e.isLeader())` 处 `FAIL (TestUnexpectedResult)`，**断言红不是编译错**。

### §10 已修（2026-09-21）

peer id 空间那条选 **(a) 配置带显式 id**，记录在 §10 的「§10 修复记录」。
§12 与 §10 是两条独立缺陷，**现在两条都关了**。

---

## 13. L2 实现记录（2026-09-21）

§4.1 的三个校验点已落地（`RaftElection.zig`）：

| 位置 | 改动 |
|---|---|
| `handleVoteRequest` `:367` | `self.peerId(req.candidate_id) == null` → 返回 `vote_granted = false`。位置是**拿到锁之后、任何状态修改之前** —— 冒名者连我们的 term 都推不动 |
| `handleAppendEntries` `:431` | `leader_id` 既不是已知 peer **也不是自己** → `success = false`，且**先于 term 更新**，所以伪造者到不了日志 |
| `handleInstallSnapshot` `:961` | 同上；这条是**清空整个日志**的那条路 |

「也不是自己」是必要的：`becomeLeader` 会把 `leader_id` 设成自己的 `local_id`。

### 一处与 brief 相左、但子代理是对的

brief 说 `ClusterBootstrap drives raft.tick and serves inbound Raft RPCs` 里 `candidate_id = "peer-node"`
**断言了漏洞**（未列成员却拿到票），要求把它翻成 `false`。**这条已经在 §10 的修复里失效了**：
`d84a31c` 把那个 fixture 改成了 `.peers = &.{"peer-node@127.0.0.1:19731"}`（`:792`），
`peer-node` **现在就是成员** —— 再断言 `false` 反而会对着**正确**的代码失败。
已核实：保留了那条正向断言（并注明"是 `@id` 让它成立"），另外补了**反向**方向
（`unlisted-node` 带 `term = current + 100`，断言 `!vote_granted` 且 `getTerm()` 不变）。

### 三处 L2 之外的必须连带（否则既有用例会红）

**fixture 必须补上发送方**：L2 之前，空 peer 列表的 follower 也接受任何 `leader_id`。
多个既有用例的 follower 是 `RaftElection.init(..., &.{}, ...)`，现在会拒掉合法 leader ——
所以改的是 **fixture 而不是断言**。动了 `RaftElection` 的 8 处与 `RaftTransport` 的 4 处环回 fixture；
一处特别值得记：`real loopback replication` 的第 3 步断言 `voted_for == "node-z"`，
所以 `node-z` 必须**被命名为成员**，否则那条断言会因为"未知候选人"而失败、而不是因为它在测的原因。

### 验证

全量 **1499/1520（21 skipped，0 failed）**（+5，即新增用例），fmt + 6 道门禁全绿。
两条变异逐条验过红（`handleVoteRequest` 那条我亲自重做，md5 与失败断言一致）：
删掉投票校验 → `an unlisted candidate is denied a vote and cannot move the term` 在
`try testing.expect(!denied.vote_granted)` 处 `FAIL (TestUnexpectedResult)`；
删掉 AppendEntries 校验 → `an unlisted leader is refused and mutates nothing` 同形红。
另外独立核过：整个 diff **没有删除任何 `expect`/`assert` 行**；§12 的 `+ 1` 两处（`:801` / `:1029`）未动。

### L2 挡不住什么（写在明处）

`leader_id == local_id` 是**按设计放行**的，所以一个自称**我们自己 id** 的对端仍然过 L2 ——
这符合预期：**身份层是 L1（HMAC）**，而 id 在线上依然是自述的。
挡的是"已不在成员表里的节点"与"随便报一个成员 id 的陌生人"（后者只能靠 L1）。

### 仍未做

- `DistributedEventBus` 自己的 listener（§3.3 第三个调用点）—— 独立于 Raft 端口，单独一项。
  **（2026-09-21 已落地，见 §14。）**
- §3.6 的重放残留**按设计接受**（Raft 的 term 单调 + 幂等已覆盖），未做时间戳/窗口。
- 混合版本集群未实测对跑（设计上硬切）。
- 密钥来源（`SecretsManager`）只有文档约定，无代码强制。
- `scripts/ci-integration.sh` 未跑（不在本次要求的命令里）。

---

## 14. 总线侧入站（§3.3 第三个调用点）实现记录（2026-09-21）

§1 表里的第 5 条 —— `DistributedEventBus` 自己的 listener、自己的 accept 环、自己的
`handleConnection`，**零认证** —— 已落地。这是审计项 ③ 的最后一个面。

**动工前先修的是帧**，因为 MAC 挂在没有帧的消息上无法可靠验证：一条被两次读切开的
消息给出的是半个 body，MAC 必然失败，于是**合法**事件被丢。帧是认证的前提，不是偏好。

### 三个既有缺陷（帧把它们一起关掉）

| # | 缺陷 | 旧行为 |
|---|---|---|
| 1 | **一条消息被两次读切开** | 第一次读到的半个 JSON 解析失败 → 丢（或进 DLQ）。**数据丢失** |
| 2 | **两条消息落在一次读里** | `parseEvent` 只认第一条，第二条**静默丢弃** |
| 3 | **固定 4096 字节栈缓冲** | 超过它的 payload → `serializeEvent` 返回空切片 → `writeAll("")` **什么都没发**，且不记失败 |

### 帧形状（双向）

```text
[4-byte BE len][mac: 32 raw bytes][json]    配了 cluster_secret
[4-byte BE len][json]                       没配（"bare"）
```

- `len` 覆盖它之后的一切（MAC + json），所以接收侧一次 `readFull(len)` 拿到整条消息；
  长度先读、再读 body，**校验在任何解析之前**完成。
- MAC 只覆盖 **json 字节**：这个面**没有 tag 字节**（JSON 自带 `"topic"`），
  和 Raft 的 `[tag][payload][mac]` 不同 —— 那边 MAC 在尾部覆盖 `[tag][payload]`，
  这边 MAC 在头部覆盖 json。常量时间比较复用 `ClusterAuth.timingSafeEql`。
- 上下界：`len == 0` 与 `len > NetworkTransport.MAX_MESSAGE_SIZE`（1 MiB）**在缓冲之前**拒绝并
  断开连接 —— 流已经失步（或对端是另一个 wire 版本），猜下一个帧的起点等于把任意字节交给解析器。
- 任何失败都是 `std.log.debug` + `break`（丢连接），与 `RaftTransport.handleConnection` 同形。
  认证失败**不是解析失败**，所以不进 DLQ。

### 改动面

| 文件 | 改动 |
|---|---|
| `src/core/DistributedEventBus.zig` | `cluster_secret: ?[32]u8` + `setClusterSecret`（`:65` / `:610`）；`sendEventFrame`（`:262`，一个入口同时给 `sendToNode` 与 `sendHeartbeat`）；`openEventFrame`（`:293`）；`handleConnection` 改成**定长帧循环**（`:311`，读帧 `:330-356`）；`serializeEventAlloc`（`:596`）按事件大小分配，替掉三处 `[4096]u8`；`start()` 在没有密钥时 `log.warn`（`:166`） |
| `src/core/cluster/ClusterBootstrap.zig` | `:167` 把 `config.cluster_secret` 交给 bus（`setClusterSecret`）—— 密钥**只有一个来源**，就是门禁刚判过的那个配置项，不新造第二条 |

`sendEventFrame` 是**一个** helper：拼帧 + 一次 `writeAll`（帧整体一次写出，MAC 也在里面）。
发送侧因此不再有"渲染进固定数组"那一步 —— 缺陷 3 在线上路径上不可达了。
（`serializeEvent` 自己仍然是"缓冲不够就返回空切片"的契约，见下面的未做清单。）

### 门禁的位置：为什么 `start()` 只 warn

`start(port)` 是**独立入口**，它不知道集群的形状（单节点 bus 完全合法，没有对端要认证），
所以这里**不拒绝**，只把风险喊出来。**强制门禁在 `ClusterBootstrap.start()`**（多节点 + 真 transport +
无密钥 → `error.ClusterAuthRequired`），那里才知道该拒谁。warn 的措辞：

> `[DistributedEventBus] node '{s}' listening on port {d} WITHOUT a cluster_secret: any host that can reach this port may publish events, and every frame is trusted as whatever `source` it claims — `__heartbeat` included. Call `setClusterSecret` (`ClusterBootstrap` does it for an enforced configuration).`

### 验证

全量 **1505/1526（21 skipped，0 failed）**（+6，即本次新增用例），`zig fmt --check` + `check-production.sh` +
`check-deadcode.sh` 全绿。Raft 侧未动且仍绿：`-Dtest-filter=RaftTransport` 14/14、`-Dtest-filter=RaftElection` 31/31。

新增 6 条用例（`DistributedEventBus.zig:1182` 起）：split-write 只投一次、一次写两条都投、
带密钥的 publish→线上→订阅者（**逐字节**断言 `[len][mac][json]`）、另一把密钥签的帧被丢（带正对照）、
签名后改过 json 的帧被丢（带正对照）、无密钥的 bare 帧仍被接受（断言"**有长度前缀、没有 MAC**"：
`body.len == eventJsonSize(parsed)`，多一个字节都过不了）。

**两条变异逐条验红，都是断言红不是编译错**（都按字节还原，md5 前后一致 `2dab557473bb8bf7c3b5418b7eaf528e`，
`grep -c MUTATION` → 0）：

1. 删掉 MAC 不匹配时的 `return null` →
   `core.DistributedEventBus.test.a frame signed with another key is dropped...expected 0, found 1` /
   `FAIL (TestExpectedEqual)`；
2. 把接收环换回"一次 `readSome` = 一条消息" →
   `...a frame split across two writes delivers exactly one event...expected 1, found 0` /
   `FAIL (TestExpectedEqual)`。

**实现期自己抓到的一个错**（值得记，因为它是"测试先红"的样本）：第一版 `openEventFrame`
照 Raft 的形状把 MAC 当成**尾部**剥离（`body[len-32..]`），于是 MAC 覆盖的是 MAC 自己 —— 三条带密钥的用例
当场红（`expected 1, found 0`），改成头部剥离后全绿。**抄帧形状不能抄一半。**

### 未做（逐条）

> 下面这五条已在同日的第二轮**全部关闭**，见本节末「第二轮」；原文保留，用来记录当时的状态。

- **`serializeEvent`（改动前 `:434-441`，现 `:571`）自己没有修**：它仍以"返回空切片"报告缓冲不足。
  本次只是把**发送路径**换成按事件大小分配的 `serializeEventAlloc`，所以线上不可达；这个契约留给
  下一个调用者时仍是个坑（`catch buf[0..0]` 静默）。
- **`extractJsonValue`（改动前 `:241-254`，现 `:380`）仍是子串匹配器，不是 JSON 解析器**：payload 里
  出现字面量 `"topic"` 就能**改变解析方向**。L1 不依赖它（验签在解析之前），所以本次只记录。
  **顺带发现的一个交互**：正因为它匹配子串，**旧**对端读到新帧时未必"干净地丢弃" —— 它可能解析出
  一个**错的事件**（长度前缀与 MAC 是前导字节，JSON 跟在后头）。所以混合版本的正确口径是：
  **新侧丢弃一切非帧字节（有日志），旧侧可能误解析** —— 这不是"两边都安静地不工作"，
  而是"旧侧必须一起升级"。
- **`source_node` 仍未与 `self.nodes` 对照 —— 记为 open，没有关**。`parseEvent`（`:395-405`）把
  `"source"` 直接 `dupe` 成 `source_node`（`:398` / `:404`），从不查它是不是已知成员：
  **L1 认证的是"哪台主机"，不是"它自称是哪个节点"**，所以配了密钥的对端仍然可以在 payload 里冒用
  任何成员的 id（`__heartbeat` 也一样）。为什么没顺手关：**accept 侧没有把连接映射回 id 的手段**。
  `self.nodes` 以 id 为键，而入站连接的对端地址是 `dialer_ip:临时端口` —— 与节点表里登记的
  `host:监听端口` **天然不等**（NAT 之后更不可能）。要真关掉得先有握手（连接上先自报 id 并证明），
  那是 §4 形状的另一件事，不是一次校验能补的。
- §3.6 的重放残留**按设计接受**（总线侧的重放语义没有 Raft 的 term 单调兜底，见下一条）。
- **总线侧没有重放防护**：这次上的是 MAC（完整性 + 主机身份），没有时间戳/序号窗口，
  所以线路旁观者可以重放一条事件帧，订阅者会**再看到一次**。Raft 侧靠 term 单调 + 幂等挡住，
  总线侧没有这个性质 —— **残留风险，明写在这里**，要关掉需要 per-peer 序号窗口。
- **混合版本集群仍未实测对跑**（设计上硬切）。
- **并发写在同一个 socket 上未加锁**：`publish`（请求线程）与 `heartbeatLoop`（fiber）可能同时
  `writeAll` 到同一个对端。帧化之后这种交错的后果从"静默乱解析"降级为"帧校验失败 → 丢连接"，
  但**没有**用互斥把它消掉。
- **入站读没有超时**：一个连上总线端口、一个字节都不发的对端会把该连接的 fiber 一直占住，
  而 `stop()` 要等这些 fiber（`fiber_group.await`）。树里已经有 `sockread.setRecvTimeout`
  （Raft 入站在用，`:678`），总线这一次**没接** —— 是独立的一项，不带密钥时它同时是一条
  廉价的拒绝服务路径。

---

### 第二轮（同日）：上面五项全部关闭（2026-09-21）

上一节那五条是**记下但没动**的；这一轮逐条关掉，改动**全部**在
`src/core/DistributedEventBus.zig`（`ClusterBootstrap` 未动 —— 没有新配置项；Raft、
`src/im/**`、`src/api/**` 未动）。

#### 1. `extractJsonValue` → `std.json` 真解析

`parseEvent` 不再找子串：`std.json.parseFromSlice(std.json.Value, allocator, data, .{})` 读字段，
再把四个字段 `dupe` 进调用方的 allocator。分配口径：**每消息多一棵 json 树，落在本来就有、
每消息 `reset(.retain_capacity)` 的 arena 里** —— 是容量不是增长；`Parsed.deinit` 在返回前释放，
所以 `std.testing.allocator` 也平衡。`parseEvent` 的契约（解析进调用方 arena、返回 `?NetworkEvent`、
失败落 DLQ 路径）不变，帧循环不变（一次读里的第二条消息仍然不会被丢）。

两处顺带的效果，都是收紧：

| 输入 | 旧（子串） | 新（解析） |
|---|---|---|
| payload 值是 `say \"topic\" from \"source\"`（合法 JSON） | payload 被截成 `say \`，`source` 从 payload 里的**字面量**读出 | 完整 payload + 真正的 `source` |
| payload 注入 `y","source":"node-b`（`serializeEvent` 不转义引号） | **投递**一个 `source_node = "node-b"` 的事件 | `DuplicateField` → 解析失败 → DLQ，**不投递** |

第二条同时说明：**`serializeEvent` 不转义引号**（本轮未动）在旧行为下是"静默截断 / 改掉来源"，
现在是"进 DLQ"，即 fail-closed。含 `"` 的 payload 从来没有被正确传过，这里没有回归。

#### 2. `source_node` 绑定：MAC 密钥由**声称的身份**派生

```text
claim      = json 里的 "source"
key(claim) = HMAC-SHA256(cluster_secret, claim)
mac        = HMAC-SHA256(key(claim), json)      // 仍只覆盖 json 字节
```

发送侧（`sendEventFrame` 多一个 `identity` 形参，两个调用点传 `self.node_id`）与接收侧
（`openEventFrame` 先从**未验证**的字节里只读一个字段 —— 声称的 source —— 用它派生密钥）
同时改，否则谁都不验。`ClusterAuth.timingSafeEql` 的常量时间比较不变。

「验证在解析之前」要**精确**表述，因为密钥派生必须先知道 claim：**解析先于验证的只有 claim 这一个
字段，它只作 KDF 输入；投递给订阅者的事件仍然从 MAC 验过的字节重新解析**（因此认证路径每帧解析两次，
都落在同一个 per-message arena 里）。伪造 claim 只会派生出拿不到 tag 的密钥。

**残留（明写）**：`cluster_secret` 是集群级 PSK，**持有它的人仍可冒充任何节点**（能派生出任意 id 的
密钥）—— 这是 PSK 的固有性质，在 L1 威胁模型之外。这一项买到的是"声称被绑进帧里、接收侧不再相信
一个从未校验的自述"，**不是**"冒充不可能"。

#### 3. 重放：每 claim 严格递增的序号（有界，残留明写）

帧多一个 `"seq"`（**在 MAC 覆盖区内**）；`nextSeq()` 每帧自增；`peer_seqs: StringHashMap(u64)`
记每个 claim 的高水位；`seq <= 高水位` 的帧丢弃并 debug 记录。只在**配了密钥**时生效 ——
裸帧没有可放序号的认证区。

- **重连不重置水位**。连接不是新鲜度的单位（旁观者可以自己开一条连接重放捕获到的字节），
  所以水位按 **claim** 记、跨 socket 存活；发送侧的重连也不重置计数器（进程内单调）。
- **序号种子**取 `Time.monotonicNowMilliseconds()`（进程启动时的单调毫秒），每帧 +1：
  同一台机器上**进程重启**通常往前进（经过的毫秒数大于发出的帧数），对端因此不会拒绝它。
- **残留 1（明写）**：捕获到但**从未被你接受过**的帧（连接已经断了之后才发出的那些）仍可重放一次 ——
  防御的边界是"高水位之上的那段捕获窗口"，不是"所有捕获字节"。
- **残留 2（明写）**：**宿主机重启**把单调时钟打回 0，重启后该节点的帧会全部低于对端高水位而被拒。
  出路只有 `forgetPeerSeq(claim)`（人工、显式，会重开该 claim 的重放窗口）或对端重启；
  **没有任何自动的"接受重置"** —— 那正是"看起来像防护"的形状。
- 高水位表只可能被**持有密钥的对端**写入（写它之前 MAC 已验过），所以它不能被陌生人撑大。

#### 4. 同一 socket 的并发写：每节点一把 `std.Io.Mutex`

`Node.write_lock`；`sendFramed`（`publish` 与 `heartbeatLoop` 共用的唯一出口）持锁写整帧。
用 `Io.Mutex` 而不是 `SpinLock`：临界区里是阻塞的 `writeAll`，而 `core/SpinLock.zig` 的文档
明确把这种形状排除在外。锁覆盖的是"两个写者"，不覆盖"另一个线程 close 这个 socket"（既有行为）。

#### 5. 入站读的空闲上界

`inbound_idle_timeout_ms = 30_000`（= 6 × `heartbeat_interval_ms`，心跳间隔这次也提成常量），
经 `SO_RCVTIMEO` 施加，0 关闭。**为什么是空闲式而不是每消息**：这条流是长寿命的 —— 健康对端在两次
心跳之间本来就是安静的，安静期可能长达几分钟；任何**紧于心跳间隔**的界都会把健康连接拆掉，
6× 只对真正沉默的对端生效（`stop()` 也就不再被一条空连接卡住）。

**实现期发现的一个真缺陷（在允许改动范围外，记为待办）**：`sockread.setRecvTimeout` 的 `catch`
**永远不会触发** —— `std.posix.setsockopt` 把 `EINVAL` 映射成 `unreachable`，而 macOS 对**对端已关闭**
的 AF_UNIX socket 上的 `SO_RCVTIMEO` 恰好返回 `EINVAL`（本机实测：对端开着 rc=0；对端 close 之后
rc=-1 / errno 22）。于是"连上就立刻消失"的对端会让**调用方 panic**，而不是被兜住。总线因此在
`boundInboundRead` 里自己发同一个 `setsockopt`、失败只 `log.warn`（对端已经走了的话下一次读立刻
EOF，所以这个失败是良性的）。`src/core/sockread.zig` 没有动。

#### 门禁与验证

| 命令 | 结果 |
|---|---|
| `zig fmt --check src tools examples` | 0 |
| `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test --summary all -Dtest-force-run=true` | `15/15 steps succeeded; 1529/1550 tests passed (21 skipped)`（0 failed），主产物 1414 pass + 21 skip（1435） |
| `bash scripts/check-production.sh` | 0（无裸 `catch {}`） |
| `bash scripts/check-deadcode.sh` | 0 |
| `-Dtest-filter=DistributedEventBus` | **改前 16/16（主产物 1429）→ 改后 22/22（主产物 1435）** |

新增 6 条用例（`src/core/DistributedEventBus.zig` 末尾）：带转义引号的 payload 不被劫持、
注入重复字段的 payload 不投递、密钥按自称派生（含"用集群密钥签的帧必须验不过"）、
重放被丢（**每次 `feedFrame` 都是新连接**，即重连场景）而前进的序号仍被接受、
两个写者同 socket 只产生整帧、静默对端被空闲界放掉。

被改的 fixture（有意，非弱化）：

| fixture | 为什么 |
|---|---|
| `testFrame(allocator, secret, claim, json)` | 帧必须用**声称身份派生**的密钥签，否则"合法帧"在新接收侧本来就不该验过 |
| `testFrameRaw(allocator, key, json)`（新） | 保留"用原始密钥签"的形状，正是为了能**断言它不被接受** |
| `a signed frame round-trips` 的 `expected_mac` 改用 `identityKey(secret, "sender-node")`，并新增 `expect(!eql(HMAC(secret, json), mac))` | 同一条契约在发送侧的证据 |
| JSON 形状（`event_json_fmt` 加 `"seq"`） | `eventJsonSize` 与 `serializeEvent` 共用同一格式串，所以两者同步 |

**四条变异逐条验红，都是断言红不是编译错**（都按字节还原，md5 前后一致
`e9ff4838f19f7ca07d71a914d175b7a2`，`grep -c MUTATION` → 0）：

1. `parseEvent` 换回子串匹配器 →
   `a payload containing quoted field names cannot steer the parse`：
   `expected: say "topic" from "source"` / `instead found: say \` → `FAIL (TestExpectedEqual)`；
   同一次运行里 `a payload that injects a duplicate field is not delivered as somebody else`：
   `expected 0, found 1` → `FAIL (TestExpectedEqual)`。
2. 去掉 `sendFramed` 的锁（`writeAll` 照旧）→
   `two writers on one socket produce only whole frames`: `expected 10, found 0` →
   `FAIL (TestExpectedEqual)`（连跑两次一致；还原后同一条用例 OK）。
3. 不施加 `SO_RCVTIMEO` →
   `a peer that connects and then says nothing costs the idle bound, not the fiber`:
   `FAIL (TestUnexpectedResult)`，位置是 `try std.testing.expect(returned.load(.acquire))`
   （用例本身不会挂死：defer 会关掉对端让 mutate 版本也退得出来）。
4. 接收侧换回集群级单一密钥 →
   `a frame is keyed by the source it claims, not by the cluster secret`: `expected 0, found 1` →
   `FAIL (TestExpectedEqual)`。

#### 这一轮仍未做

- **混合版本集群仍未实测对跑**：这一轮的帧形状变化（按身份派生密钥 + 必带 `"seq"`）让硬切**更硬**
  —— 双向都不通，而且旧侧的"子串解析"会把 `[len][mac]` 之后的内容当事件误解析（见上一轮记录）。
- **`serializeEvent` 仍不转义引号**（上一轮就记着）：现在它的后果是进 DLQ，而不是静默截断。
- **`sockread.setRecvTimeout` / `setSendTimeout` 的 `catch` 不可达**（`EINVAL` → `unreachable`），
  实测能 panic 调用方；总线绕过了它，Raft 入站仍直接用它（对端活着时不会触发）。**建议单独修
  `src/core/sockread.zig`**（`SETSOCKOPT_ERROR`/`E` 里把 `INVAL` 从 `unreachable` 摘出来，或改用
  裸 `std.posix.system.setsockopt` 判返回值）。
- **`nextSeq` 的种子是启发式**：同机进程重启通常前进，但**高事件率 + 短间隔重启**仍可能回退
  （经过的毫秒数 < 发出的帧数）→ 被对端拒绝。要彻底关掉需要持久化序号或重入握手。
- **`peer_seqs` 没有上界**：只有持密钥的对端能往里加 claim，所以不是陌生人可撑大的表；
  但没有 TTL / 淘汰。


---

## 15. 入站并发与入站 `AppendEntries` 的上界（2026-09-21）

本节与 §3/§13 的认证无关，关的是 §1 表里的两件结构性问题：**#4（日志无界增长）的一半**，
以及"慢对端串行占用 accept 环"。两者同批做，因为**它们动的是同一个函数的两侧**：
`ClusterServer` 怎么把连接交出去，以及交出去之后 `handleAppendEntries` 接受多少。

### 15.1 为什么"并发"必须先把 handler 的形参改掉

`ClusterServer.start` 的 handler 是 `*const fn (ClusterConnection) void` —— **没有上下文**。
owner（`RaftTransport.InboundServer.current`、`ClusterBootstrap.inbound_owner`）因此只能挂在
`threadlocal` 上，而那只在"handler 跑在 accept 线程上"时成立。**把 handler 挪到别的线程 =
`current` 为 null = 每个入站连接都被丢掉**。所以顺序只能是"先给 handler 上下文，再并发"，
不能反过来。

改为 `start(self, handler: Handler, context: ?*anyopaque)`，`Handler = *const fn (?*anyopaque, ClusterConnection) void`：

- **上下文走形参而不是字段**：字段可以在没启动的 server 上被设置，也可以在运行中被改，
  而形参只有一处赋值点，就是那个知道 handler 用途的地方。
- **两处 `threadlocal` 都删了**：`RaftTransport.InboundServer.current` 与 `ClusterBootstrap.inbound_owner`。
  两者是同一个 bug 的两个实例。`onConnection` / `onInboundConnection` 改成收 `context`，
  `@ptrCast(@alignCast(ctx))`，null 时 debug 日志 + 返回（不是 `unreachable`：形参来自框架自己，
  但这条路径上没有理由用 UB 表示它）。
- **分发用 `Group.concurrent`，不是 `async`**：handler 会阻塞在对端读上，`async` 在
  `async_limit` 上会**回落成在 accept 线程上跑**——那正是要修的东西。形状与
  `DistributedEventBus.acceptLoop` 一致（`ConcurrentError` 分支关连接 + `log.warn`）。
- **`stop()` 等 group**（`Group.await`）。`Io.Group.await` **不是线程安全的**，所以**只有一个 awaiter**：
  只有 `stop()` 等。一开始我在 `start()` 的循环出口也加了一次 await —— 两次 await 在 `Threaded.groupAwait`
  的 `assert(!pre_await_status.have_awaiter)` 上直接 abort（实测 `signal ABRT`，测试进程没了）。
  这条是**实现期实测到的**，不是推演。
- **"`stop()` 返回后不会再有 handler"要一个握手**：accept 成功与 `Group.concurrent` 之间有个窗口。
  用 `dispatching` 原子 + **claim 后重查 `running`**：

  ```text
  accept 侧： dispatching.store(true, .seq_cst); if (!running.load(.seq_cst)) { 丢弃并退出 }
  stop 侧：   running.store(false, .seq_cst); while (dispatching.load(.seq_cst)) spin; await(group)
  ```

  两个 `.seq_cst` 是这条推理的全部依据：若 claim 落在 `stop` 的 store 之后，它必然在重查里看见
  `running == false`（顺序一致的全局序把"读 `dispatching` 得 false"排在"写 `dispatching` true"之前，
  于是 `running` 的 store 也排在这次 load 之前）；若 claim 落在它之前，`stop` 的自旋会等到
  `concurrent` 返回之后才 await，那个 fiber 因此被 await 覆盖。

### 15.2 入站 `AppendEntries`：clamp，不是拒收

`max_append_entries` 原来只在 `sendAppendEntries`（发送方）读。入站什么都不限，所以一个帧能带多少
条目就应用多少；`decodeAppendEntries` 更早就 `allocator.alloc(LogEntry, count)` —— `count` 是 u16，
**65535 × 32 B ≈ 2 MB，在 `count` 之后一个字节都没校验之前就分配**（帧内声明数与帧大小无关）。

1. **应用侧 clamp**：`handleAppendEntries` 取 `@max(1, config.max_append_entries)` 条，多出来的不应用。
   **为什么是 clamp 而不是拒绝**：应用一个前缀在 Raft 里是合法的 —— follower 从 `prev_log_index + 1`
   顺序追加，回复的 `match_index` 是它**真正到达的位置**，leader 下一轮从那里继续。拒收则需要两端
   `max_append_entries` 相同，否则 "leader 比 follower 大" 的那个 follower 会拒掉 leader 能构造的每一个批，
   复制永远停在那里；clamp 只是多花一轮，**配置不一致能自愈**。
   被截掉的尾部也跳过了 `entry.index == 0` 扫描 —— 有意且安全：越过前缀的条目根本不会进入
   `entry.index - 1` 那个循环，而那条守卫存在的理由正是那个循环。
2. **回复必须说真话**：`success = true` + `match_index = log.items.len`（= 真的应用到哪里）。
   同时**leader 的成功分支要以 `resp.match_index` 为下限**（`@min(发出去的尾, 它确认的尾)`）——
   原来成功分支只信"我发了什么"，那样一个 clamp 过的 follower 会被记成持有整批，
   而 `advanceCommitIndex` 是拿 `match_index` 算多数的：**这是 safety 问题，不是记账问题**。
   follower 整批收下时 `@min` 是恒等，所以正常路径零变化。
3. **解码侧硬顶**：新增 `RaftTransport.MAX_ENTRIES_PER_FRAME = 4096`，`count` 超过它直接
   `error.EntryCountTooLarge`，**在任何 entries 分配之前**（于是"声明 65535 条、一条都不带"的帧
   不是 `TruncatedMessage` 也不是 `OutOfMemory`，而是这一条错误）。
   **耦合的选择**：4096 是默认 `max_append_entries`（100）的 40 倍，即"远高于任何合理的 chunk 大小"，
   **同时**把 `ElectionConfig.max_append_entries` 的文档写成"受这个常量约束、每个节点都要 ≤ 它"。
   两者都做，因为这是**跨端**的硬线：发送方高于接收方的硬顶时，帧在接收侧被丢、发送方读超时、
   同一批被无限重发 —— 那条 follower 永远追不上。框架里无法为一个**别的进程**的配置做检查，
   所以只能是"常量足够高 + 文档写清上界"。

### 15.3 验证

全量、`zig fmt --check`、`check-production.sh`、`check-deadcode.sh` 的读数见 `CHANGELOG.md`
的 `Unreleased` 条目。判据：

| # | 用例 | 变异（红的样子） |
|---|---|---|
| 1 | `two stalled peers do not stop a third connection from being answered` | 分发改回内联 → `elapsed < concurrent_stall_ms / 2` 断言红（第三个对端的回复要等两个 stall 各一次超时） |
| 2 | `an inbound AppendEntries applies at most max_append_entries entries, and says so` | 删掉 clamp → `expected 3, found 10`（`match_index`）与 `logLen()` 断言红 |
| 3 | `a follower that acknowledged only part of a batch rewinds the leader to what it acked` | leader 成功分支不信 `resp.match_index` → `next_index` 断言红 |
| 4 | `an append_entries frame above the decode cap is dropped without allocating` | 去掉解码上限 → `expected error.EntryCountTooLarge, found error.OutOfMemory`（`fail_index = 1` 让"确实分配了"变成另一种错误） |

**被改的 fixture（有意，非弱化）**：
`a half-frame on the inbound side costs rpc_timeout_ms, not the whole node` 原来把"B 是被 A 的超时释放的"
写成 `elapsed >= timeout_ms - 50` —— 内联分发下这句话成立，**每连接一个 fiber 之后它就是错的**
（B 立即被服务）。两条界都保留，只是移到**真正该被界住的那个对端**（A）身上：B 改为断言
`elapsed < timeout_ms - 50`（在 A 的超时之前就被服务），A 补上 `>= timeout_ms - 50` 与
`< stalled_peer_patience_ms - 500`。另外该用例与黑洞用例的收尾都补了一条**唤醒连接**：
accept 环现在真的可能停在 `accept()` 里（以前它总是卡在 handler 体内），而关掉 listener
不保证唤醒它 —— 与 `stopInbound` / `ClusterBootstrap.stop` 已有的做法一致。
