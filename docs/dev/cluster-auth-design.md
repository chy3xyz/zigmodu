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
- §3.6 的重放残留**按设计接受**（Raft 的 term 单调 + 幂等已覆盖），未做时间戳/窗口。
- 混合版本集群未实测对跑（设计上硬切）。
- 密钥来源（`SecretsManager`）只有文档约定，无代码强制。
- `scripts/ci-integration.sh` 未跑（不在本次要求的命令里）。
