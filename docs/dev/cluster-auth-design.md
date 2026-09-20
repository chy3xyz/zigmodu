# 集群入站零认证 —— 设计（未实现）

> 状态：**设计草案，未实现**。来源是 `docs/dev/security-audit-cluster.md` 的第 3 条高危，
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
