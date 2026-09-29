# Distributed Modules — Production Readiness

> Modulith day-one concurrency (single process, multi-instance, when to use RobustMQ): **[MODULITH.md](MODULITH.md)**.

## Status Overview

All distributed modules are **Ready** for single-node testing and development.
For multi-node production, see the caveats below.

| Module | Tests | Notes |
|--------|:-----:|-------|
| **FailureDetector** | 7 | Phi-accrual detector. Adaptive threshold. |
| **KafkaConnector** | 12+ | RobustMQ / Kafka TCP Produce+Fetch + RecordBatch parse. Live: `ROBUSTMQ_URL`/`KAFKA_BOOTSTRAP`. |
| **GrpcTransport** | 10+ | Unary framing + registry; unary / server / client / bidi (+ pump interleaved); HTTP/1.1 + HTTP/2 packaging |
| **SagaOrchestrator** | 9 | Auto-compensation with reverse-order rollback. |
| **RaftElection** | 11 | Leader election + vote counting. Multi-candidate split-vote tested. |
| **DistributedTransaction** | 10 | 2PC protocol (commit + abort) + durable coordinator journal (`TransactionJournal.recover`). ⚠ Participants have no journal (see caveats). |
| **ClusterMembership** | 4 | Gossip over bus with `subscribeWithContext` (join/leave/heartbeat converge). |
| **DistributedEventBus** | 22 | Cross-node pub/sub + soft backpressure (quarantine after send failures); length-prefixed frames, **per-node keys + challenge-response handshake** (`setOwnKey`/`setPeerKey`), `source` bound to the connection, strictly increasing `"seq"` per claim (replay), per-node write lock, idle read bound. |
| **ClusterView** (cluster/) | 6 | Reference-counted read-side snapshot + rendezvous pick. |
| **WAL** (eventbus/) | 2 | Write-ahead log. Zig 0.16 Io.Dir + binary serialization. |
| **DLQ** (eventbus/) | 3 | Dead-letter queue. Expiry + requeue with cooldown. |
| **Partitioner** | 3 | Consistent hash ring. Node add/remove + routing. |

> 计数口径：各文件内 `grep -c '^test '`。本表会随版本漂移，**以代码为准**（`docs/AGENTS.md` 同款原则）。
> `src/core/cluster/` 下的构建块现已从 `root.zig` 平铺导出：`RaftElection` / `RaftTransport` /
> `PeerDiscovery` / `LoadBalancer` / `AccrualFailureDetector`（供应用自行拼拓扑）。**门面就是
> `ClusterBootstrap`**：它自己组装这些零件，并给出请求路径该用的入口 —— `pick(key)` / `getView()` /
> `healthJson(alloc)` / `tick()`，**不要再自己拼一套**（详见下一节）。
> `ClusterHealth` **不是类型**：导出的是 `cluster_health` 模块 + 两个函数 `clusterHealthJson(alloc, cluster)` /
> `clusterHealthHandler(cluster)`，路由要应用自己挂。`DistributedIntegrationTest.zig` 仍无人 import
> （不编译、测试不运行）。读侧的两个根导出名 `ClusterSnapshot`（= `ClusterView.Snapshot`）与
> `ClusterNodeView`（= `MembershipView.Node`）是给应用的别名；框架内部只用后两个名字，这正是
> 这两个别名在树内"零使用"的原因 —— 没有失效的类型，只有没被内部代码用到的名字。

## 总线入站：帧、身份与重放（接线者要知道的四件事）

`DistributedEventBus` 的监听端口是**集群内部面**。配了凭证（`cluster_secret` / `setOwnKey` /
`setPeerKey` 任一）就走认证路径。帧：

```text
[4-byte BE len][mac: 32][json]
入站 mac = HMAC(peer_keys[bound_id], json)     出站 mac = HMAC(own_key, json)
```

**身份是握手钉住的，不是帧自述的**（`docs/dev/cluster-identity-design.md`）。每条连接在**任何事件帧之前**
先跑一次：

```text
① receiver → dialer   [len][rc: 16]                        rc 每条连接新取（randomSecure）
② dialer   → receiver [len][dc: 16][claim_id][mac: 32]     mac  = HMAC(own_key, claim_id ++ rc ++ dc)
③ receiver → dialer   [len][receiver_id][mac2: 32]         mac2 = HMAC(own_key, receiver_id ++ dc)
```

1. **接收方先发挑战**，所以握手本身不可重放（捕获的应答带着上一轮的 `rc`，对不上新的）；
   **③ 是互证** —— 拨号方同样要求对端证明它是它。两处 MAC 都是常时比较
   （`ClusterAuth.timingSafeEql`）。签名一律用**自己的** key、验签一律用**发送方的** key，
   `setPeerKey(id, key)` 里的 `key` 就是 `id` 那个节点自己的 key。
2. **绑定后 `source` 必须等于 `bound_id`**，不等就**关连接**（不是丢帧）。于是 `source_node` 第一次是
   **可验证的事实**，不是自述。**这把 §14 的残留关掉了**：持自己 key 的节点不能再以别人出现。
3. **`"seq"` 必带且对同一 bound id 严格递增**（高水位跨重连存活），所以捕获到的帧重放不了。
   **残留**：从未被接受过的帧（连接断掉之后才发出的那些）仍可重放一次；**宿主机重启**会让发送方
   序号回退 → 被对端拒绝，需要 `forgetPeerSeq(id)` 人工放行（或对端重启）。没有自动接受重置。
4. **入站读有 30s 空闲上界**（`inbound_idle_timeout_ms`，= 6 × 心跳间隔）：沉默对端不会占住连接，
   `stop()` 也就不再被它卡住；健康对端在两次心跳之间本来就是安静的，30s 不会误杀。这条也施加于
   **拨号方刚建好的 socket**（它的第一次读同样是"对端可以不回答"的读）。

fail-closed 是**整条路径**的，没有降级口：配了凭证但拨号到没有 `peer_key` 的对端 →
`error.PeerKeyMissing`（在 dial **之前**）；握手 claim 不认识 / MAC 不对 / 重放 → 关；
认证端口上出现**裸帧** → 关（那不是"没有 MAC 的帧"，是格式错的握手应答）。
完全没配凭证才是既有的裸帧路径（单节点/开发，`start()` 有 warn）。

代价：**每条连接建立时多一个 RTT**（帧形状与稳态投递不变）。树内连接是"每对端一条、长期复用"
（`self.nodes` 每个 id 一条 socket，`connectToNode` 对已注册的 id 直接返回），所以只在节点加入/
重连时多付一次。另有每个 node 一把写锁（`publish` 的请求线程与 `heartbeatLoop` 的 fiber 不会在
同一个 socket 上交错帧）。完整改动、残留清单与变异证据：`docs/dev/cluster-identity-design.md` §11。

## Raft 端口：per-node 身份（A-1，对齐总线语义）

总线用「挑战-应答握手 + 连接期绑定 id」钉住身份；Raft 端口是**短连接请求-响应**，同一形状会让每条
RPC 多付一个 RTT，所以这里把身份钉在**每一帧**上：请求/应答帧里本就有自述 id（`candidate_id` /
`leader_id` / `responder_id`），且在 MAC 覆盖之内 —— 验签改用 `peer_keys[自述id]`，伪造 id 就是
MAC 不对。线格式不变：`[len][tag][payload][mac]`。

```zig
var cluster = try ClusterBootstrap.init(allocator, io, .{
    .node_id = "n1",
    .port = 9000,
    .peers = &.{ "n2@10.0.0.2:9001", "n3@10.0.0.3:9002" },
    .transport = my_transport,
    // 对称预共享：n1 的 own_key 就是对端 peer_keys["n1"] 里那把。
    .own_key = key_n1,
    .peer_keys = &.{ .{ .id = "n2", .key = key_n2 }, .{ .id = "n3", .key = key_n3 } },
});
```

- **模式判定**（`RaftTransport.zig` 文件头 §A-1）：`own_key` / `peer_keys` 任一配置 → per-node
  （**优先于 `cluster_secret`，两者同配时共享钥匙被忽略** —— 回落会重开"任一持钥者冒充任一节点"的
  洞）；只配 `cluster_secret` → 既有共享路径，**逐字节不变**（它认证帧但不绑身份）；都不配 → 裸帧
  （dev，多节点仍被 `start()` 的门拦下）。
- **签名一律自己的 key、验签一律发送方的 key**：入站按帧自述 id 查 `peer_keys`（id 没配 key → 拒，
  **先于** L2 成员检查；relay 回推前也查 candidate 的 key）；同步 RPC 的应答帧没有 id，按**拨号
  目标**的 key 验。
- **fail-closed 没有降级口**：per-node 下本节点没配 `own_key` → 入站连接直接拒、出站丢消息（绝不发
  裸帧）；对端没配 key → dial **之前**就丢（`TransportImpl.outboundKeys`），Raft 按丢消息重发。
- **重放**：Raft 不需要总线那样的 seq —— term/index 单调 + AppendEntries/InstallSnapshot 幂等已拒旧
  （`docs/dev/cluster-auth-design.md` §3.6）；总线要 seq 是因为它没有 term 的等价物。
- **作用域**：这套 key 只管 **Raft 端口**。总线是另一个监听面、另一套握手机制，仍需自己的
  `setOwnKey` / `setPeerKey`（`ClusterBootstrap` 只把 `cluster_secret` 传给总线，per-node key 不进
  总线）。

## 密钥轮换与撤销（A-3，两面同 API）

per-node key 的运行时运维钩子。**源真相仍是 SecretsManager**（框架不替你读 key，同 `cluster_secret`
的约定）；下面是 key 变更/泄露时把它落到运行中集群的调用。线格式不变：`[len][tag][payload][mac]`，
没有 kid，轮换窗**只改"哪把 key 能验"**，不改帧形状。

两面（总线 `DistributedEventBus`、Raft 端口 `RaftElection`）各有同名 API，`ClusterBootstrap` 一次
打到两面（缺的面跳过）：

| 操作 | 总线 | Raft | Bootstrap |
|------|------|------|-----------|
| 换自己签名 key | `rotateOwnKey(new)` | 同名 | 同名（两面） |
| 轮换 peer key（开窗） | `rotatePeerKey(id, new)` | 同名 | 同名（两面） |
| 覆盖写并**关窗** | `setPeerKey(id, key)` | 同名 | 同名（两面） |
| 显式关窗 | `dropPreviousPeerKey(id) bool` | 同名 | 同名（存在任一面即 true） |
| 撤销 | `removePeerKey(id) bool`（**并断开该 id 的现存连接**） | `revokePeerKey(id) !bool`（帧/RPC fail-closed，无长连接可关） | `revokePeerKey(id) !bool`（两面，任一存在即 true） |

**轮换窗（双 key 验收）**：验签先试 `current`、失败再试 `previous`；签名永远只用 `current`。
窗口内每帧最多两次 HMAC。`rotatePeerKey(id, new)` = current←new、previous←旧 current；
`setPeerKey` 覆盖写且清空 previous；`dropPreviousPeerKey` 不动 current 只关窗。
**无分区轮换 B 的 key（K1→K2）三阶段**：

1. 各节点 `rotatePeerKey(B, K2)` —— B 的旧签（K1）仍被 previous 收，新签（K2）已是 current；
2. B `rotateOwnKey(K2)` —— B 改签 K2，对端按 current=K2 收（在途 K1 帧按 previous 收）；
3. 各节点 `setPeerKey(B, K2)` 或 `dropPreviousPeerKey(B)` 关窗 —— K1 停止验收。

**撤销**：总线侧 `removePeerKey` 在 `peer_keys_lock` 下删表项，然后 `disconnectNode(id)` 关掉注册表里
该 id 的连接（正在拨号的也由 `settleConnect` 收尾关掉）；入站长连接（不在注册表）由**逐帧查表**兜住
——撤销后下一帧查不到 key 即断连，重握手在 `bindInbound` 被拒。Raft 侧没有长连接要关：RPC 一次一短
连接，撤销后该 id 的入站帧在 key 查找处被拒、出站 RPC 在 dial 前丢（既有 fail-closed 路径免费得到）。

**fail-closed 不变**：无 key 对端仍 dial 前丢（`error.PeerKeyMissing`）；无 `own_key` 仍拒发拒答；
删掉最后一把 peer key **不会**把端口降回裸帧（`credentials_configured` 是粘性的）。

**同步纪律**（为什么要一把新锁）：Raft 入站读侧（`RaftTransport.handleConnection`，accept 线程）
在 dispatch 之前验签，**有意不持 `RaftLock`**；出站由 `tick()` 在 `RaftLock` 内查 key。所以轮换/撤销
不走 `RaftLock`，而是专用的叶子锁 `RaftElection.key_lock`：读侧锁内按值拷出 key（[32]u8），变更侧整个
重建在锁内完成（alloc + 换 + 释放旧 slice），读者从不持有 slice 指针，因此无 UAF、无 RCU。锁序：
`RaftLock` → `key_lock`；`key_lock` 内不取主锁、不分配热路径、不 IO。总线侧沿用既有
`peer_keys_lock`（现在同时护 `own_key`），逐帧查表的开销是一次哈希查找 + 锁内 32–64 字节拷贝。

**不在范围**：kid 帧内协商、控制面自动下发、轮换状态持久化（进程重启后 key 表以来源
SecretsManager/启动配置为准）——都不做，见 `docs/dev/v1.0-readiness-v0.35.md` §七 A-3 注记。

## 读侧怎么被喂（membership → view → 请求路径）

`ClusterView` 是**读侧**：引用计数快照 + rendezvous 选点，请求路径读它、不读 membership 的哈希表。
它长期**没有发布者**（组件齐、没人喂）—— 现在是 `src/cluster/MembershipView.zig`：

```text
  gossip / health (ClusterMembership, 写侧)  →  sync()  →  ClusterView.publish()  →  请求路径
        mutex 保护的 hash map                  快照+格式化       引用计数槽位           acquire / pick
```

```zig
// 组装：ClusterBootstrap —— 门面。它自带 view、membership、raft、metrics。
// 单节点必须显式 raft_cluster_size = 1：Config 默认是 3，而内置 Raft 传输是桩，
// start() 会拒绝启动（见下文 fail-closed）。
// 多节点的 `.peers` 每项是 `"<id>@<host>:<port>"`（例：`"n2@10.0.0.2:9001"`）：
// `@<id>` 是节点自报的 `node_id`，**多节点必须写** —— 不写则 `id` 回落成 host，
// start() 直接返回 error.PeerIdRequired（那种集群永远选不出 leader，见下文）。
var cluster = try ClusterBootstrap.init(allocator, io, .{
    .node_id = "n1",
    .port = 9000,
    .peers = &.{},
    .raft_cluster_size = 1,
});
defer cluster.deinit();
try cluster.start();

// 驱动：membership 与 raft 两条循环都是**外部驱动**的（runOnce / RaftElection.tick），
// tick() 一次做完三件事 —— 这就是"一处可用"的那个点：
try cluster.tick();                       // gossip/health + 刷新读侧 + raft.tick()

// 请求路径一：rendezvous 选点（最常用，一个调用，不用自己 acquire/release）
const node = cluster.pick(order_id) orelse return error.NoHealthyNode;

// 请求路径二：需要整份快照时（例如列出全部成员、或自己排故障转移）走 view
const view = cluster.getView();
const snap = view.acquire();
defer view.release(snap);
const backup = view.pickRanked(order_id, 1);

// 运维：健康报告（ClusterHealth.healthJson 的门面转发，调用方负责 free）
const json = try cluster.healthJson(allocator);
defer allocator.free(json);               // 挂到 /cluster/health 或 metrics scrape hook
```

> 多节点（`raft_cluster_size > 1`）需要 `.transport = <ElectionTransport>`，或显式
> `.allow_stub_raft_transport = true` 只跑 membership + 读侧（见下文「多节点启动 fail-closed」）。
> 给了 `.transport` 之后，**入站也不用管**：`start()` 在 `port` 上起监听，用
> `RaftTransport.handleConnection` 分发对端的投票/复制消息并在同一连接回包；端口起不来会
> 返回 `error.RaftInboundListenFailed`（宁可启动失败，也不装作在线却收不到票）。

- `tick()` 里的 `error.ReadersBusy` **不算失败**：请求路径正在读，view 保留上一代，下一个 tick 再发布
  （视图刻意不覆盖有人持有的槽位）。
- 想把 `tick()` 挂到运行时定时器：`_ = try worker.after(1000, .tick);`（见 `docs/RUNTIME.md` §3d 的模块用法）。
- `suspect` 状态的节点**不进 `pick`**（"可能挂了"不该收流量），但仍留在快照里给运维看。
- **LB（`LoadBalancer`）的接入点**：请求路径选节点用 `pick` / `view.pickRanked`，不要往 `LoadBalancer`
  上靠 —— 它的数据源是 `PeerDiscovery` 的「服务名 → Peer 列表」（还含 canary / least_connections 连接计数），
  和读侧的「成员 id → 地址 + 健康度」是**两份事实**；要它由 view 驱动，就得每个 tick 把快照镜像回
  discovery，多一份状态、多一次分配，而且 `sync()` 稳态零分配这条性质会丢。真要用 LB 的 canary/LC 策略，
  自己建 `PeerDiscovery` + `LoadBalancer`（`docs/API.md`、`src/core/cluster/LoadBalancer.zig`），
  与 `ClusterBootstrap` 各管一段：前者管按服务名的出站负载，后者管集群成员与读侧。

**已知限制（跨主机发现）**：gossip 负载里带着对端 host，但接收侧没有解析器 —— 被发现的节点一律按
`127.0.0.1 + 它自报的端口` 记账（`ClusterMembership.handleGossipEvent`，代码注释里写明了）。所以
**同主机 / 共享容器网络**的发现可用，**跨主机**要用显式 seed（`connectToSeed` 带真实地址，不受影响）。

**多节点启动 fail-closed，但可自带传输**：`ClusterBootstrap` 内置的 Raft 传输是桩（`sendVoteRequest` 空函数、
`sendAppendEntries` 恒 false），所以 `raft_cluster_size > 1` 时 `start()` 返回 `error.RaftTransportUnavailable` ——
宁可不启动，也不选出一个"没人投过票"的 leader。两条出路：

1. **自带传输**：`BootstrapConfig.transport = <RaftElection.ElectionTransport>`。这是框架给缝、不给实现的地方 ——
   契约在下一节。
2. **只要 membership + 读侧**：`.allow_stub_raft_transport = true` 显式承认；单节点用 `raft_cluster_size = 1`。

同一条路上还有两道门：多节点 + 真传输但**没有任何凭证**（`cluster_secret` 与 per-node
`own_key`/`peer_keys` 都空 —— 任一组配置都满足这道门）→ `error.ClusterAuthRequired`
（或显式 `.allow_unauthenticated_cluster = true`）；`.peers` 里有 peer **没写 `@id`** →
`error.PeerIdRequired`（见下文「peer id 与地址是两份事实」）。

### 真选主要什么（transport 契约）

框架里已有全部零件，接线的这层在 v0.23.0 起由 `src/core/cluster/RaftTransport.zig` 提供
（`TransportImpl(N)` 出站同步/异步 · `handleConnection` + `InboundServer` 入站分发与同连接回包 · `AddressBook`；
投票应答另走「应答走入站」回推，loopback 用例见该文件）。下表既是它替你完成的契约，也是你自带传输时要实现的部分：

| 方向 | 用什么 | 要做的事 |
|------|--------|---------|
| 出站 · 投票 | `NetworkTransport.connect(host, port)` → `ClusterConnection.send(payload)` | `sendVoteRequest` 返回 `void`（fire-and-forget）：把 `VoteRequest` 编码后发给每个 peer 即可，**应答走入站** |
| 出站 · 日志复制 | 同上 | `sendAppendEntries` 是**同步**的：发出去、读回 `AppendEntriesResponse`（同一条连接 `recv`）；`sendInstallSnapshot`（§7，见下「日志压缩」）同模型 |
| 入站 · 分发 | **`ClusterBootstrap.start()` 已经替你挂好**（给了 `.transport` 就在 `port` 上监听，走 `RaftTransport.handleConnection`）；不用 `ClusterBootstrap` 时才需要自己用 `ClusterServer.start(handler, context)` / `RaftTransport.InboundServer` | 解码后分别调 `RaftElection.handleVoteRequest` / `handleAppendEntries` / `handleVoteResponse` / `handleInstallSnapshot`，把返回值编码后**在同一连接上回包**。`append_entries_response` / `install_snapshot_response` 两个 tag **入站不消费**（发送方已同步读过），直接丢 |
| 地址簿 | **`ClusterBootstrap` 从 `config.peers` 建**（`RaftTransport.AddressBook`，键 = `peers` 里 `@` 前的 id，与 `raft.addPeer(p.id)` 同口径） | peer id → `host:port` 的映射（今天 `BootstrapConfig.peers` 是唯一来源；`ClusterMembership` 的 `nodes` 只有 loopback + 端口） |
| 失败语义 | 你自己 | Raft 能容忍丢包与重发：`AppendEntriesResponse{ .success = false }` 是**正常应答**而不是错误；连接失败按"这条消息丢了"处理即可，别把节点判死（那是 `AccrualFailureDetector` 的活） |

> **入站每连接一个 fiber（`Unreleased` 起）。** `ClusterServer` 把 accept 到的连接交给 `std.Io.Group`
> 的一个任务，handler 从 `start(handler, context)` 的形参拿回它的 owner（`RaftTransport.InboundServer`
> 或 `ClusterBootstrap`）——此前 handler 是**在 accept 线程上内联**跑的，owner 只能靠 `threadlocal`
> 找回来，所以既"一个慢对端串行挡住所有人"，也不可能真的并发。现在 `rpc_timeout_ms` 只界定
> **一个对端能占用多久**，不再决定"后面的人要不要等它"（两个半帧对端不挡第三个连接）。`stop()`
> 会等这些 fiber 结束 —— 它们握着 `raft` 与地址簿。

> **`max_append_entries` 现在两个方向都读（`Unreleased` 起）。** 出站按它切批，入站按它**截断**只应用
> 前 N 条（**clamp 而非拒收**：拒收要求两端同值，否则那个 follower 永远追不上；截断只多花一轮，
> 配置不一致能自愈）。回复里的 `match_index` 就是真的应用到哪里，leader 以它为下限推进 `next_index`
> —— 所以批里没被应用的部分不会被记成"已复制"。解码侧另有硬顶
> `RaftTransport.MAX_ENTRIES_PER_FRAME`（4096 条）：声明数超过它的帧在**分配之前**就被丢弃，
> 所以 `max_append_entries` 要保持在它以下。

**门面已闭上的两个洞**（`ClusterBootstrap`）：

- `RaftElection.tick()` 不再"没人调用"：`ClusterBootstrap.tick()` 一次做完三件事
  (`src/core/cluster/ClusterBootstrap.zig` 的 `tick()`：`runOnce()` → `view.sync()` → `raft.tick()`),
  所以"自带传输"只需要把传输交出去，不再需要自己找地方挂 `raft.tick()`。
- 入站不再"没人接"：给了 `.transport` 的节点在 `start()` 里就开始监听（`port`），
  对端发来的投票/复制消息由 `RaftTransport.handleConnection` 分发并同连接回包，`stop()` 时对应关掉。
  端口起不来 → `error.RaftInboundListenFailed`（不静默降级）；不给 `.transport` 的行为与以前一致（多节点 fail-closed）。
- **peer id 与地址是两份事实，`.peers` 里都要写**：每项是 `"<id>@<host>:<port>"`（`@<id>` 是那个节点的
  `node_id`），`start()` 用 id 调 `raft.addPeer(p.id)`、把 `host:port` 放进地址簿 —— 投票应答的回推按
  `candidate_id`（= 对端的 `node_id`）查地址簿，两边口径因此一致。**没写 `@id` 时 `id` 回落到 host**，
  多节点集群（`raft_cluster_size > 1`）会被 `start()` 拒掉（`error.PeerIdRequired`）：Raft 只把票记给
  `raft.peers[].id`，而节点在线上自报的是 `node_id`，用 host 当 id 的 peer 投的票一张也计不进来 ——
  那种集群**永远选不出 leader**（`docs/dev/cluster-auth-design.md` §10）。单节点不受影响。
- **两个线程碰的同一个 `RaftElection`，由 raft 自己串起来**：`tick()` 在**你的线程**上跑
  `raft.tick()`，而入站分发在 `start()` 起的 accept 线程上跑 `raft.handleVoteRequest` /
  `handleAppendEntries` —— 两边都会 free/dupe `voted_for`、推 `log`、改 `next_index`/`match_index`。
  所以这把锁**在 `RaftElection` 自己身上**（`RaftElection.RaftLock`，快路径 `cmpxchgWeak` +
  有界自旋 + `poll` 睡眠的三档，与 `scheduler.zig` 协调池线程同口径）：每个碰共享状态的公开入口（`tick` / `handleVoteRequest` / `handleAppendEntries` /
  `handleVoteResponse` / `handleInstallSnapshot` / `handleInstallSnapshotResponse` / `appendEntry` / `addPeer` / `compactLog` 以及状态
  访问器）自己取放一次，私有的步骤函数（`startElection` / `sendHeartbeats` / `becomeLeader` / …）
  假设锁已在手。**门面不再持锁**（`ClusterBootstrap.raft_lock` 已删）：`ClusterBootstrap` 直接驱动、
  `RaftTransport.InboundServer` 单独用、或应用自己调 `raft.tick()` / 在其它线程读它，都被同一把锁串起来，
  不再取决于调用方记得住哪两处不能重叠。
  锁的窗口是入站那一帧的 **decode → dispatch → encode** 里那次 `handle*`（dispatch 本身即窗口）；
  decode/encode 只碰 arena 缓冲与 init 之后再不改的 `local_id`，而 **socket 读 / 回包 / 回推仍在锁外**
  （对端 connect 超时不该卡住 `tick()`）。不给 `.transport` 的节点没有 accept 线程，锁是零成本的一条取指。
  **但这条原则在出站方向曾经是反的**，而且这里必须写清是哪一半修了、哪一半没有：

  * `tick()` 的出站轮次（`sendHeartbeats` → `transport.sendAppendEntries`、`startElection` 的
    `sendVoteRequest`）**整段在锁内**跑，而 `RaftLock` 曾经是**无界自旋**锁 —— 一个不响应的对端
    不是"慢一轮"，是让每个想碰状态的线程（accept 线程的入站 RPC、`appendEntry`、所有访问器）
    在 `spinLoopHint` 上**烧核**，时间为这一次 RPC 的等待时间。
    现在 `RaftLock.acquire` 是三档：`cmpxchgWeak` 快路径（无竞争不写）→ 32 轮 `spinLoopHint`
    → 128 轮 `Thread.yield` → 每轮 1 ms 的 `std.posix.poll(&.{}, 1)` 睡眠（该文件拿不到 `io`，
    所以不能用 `std.Io.sleep`；Windows/WASI 无 `poll` 时退化为 `yield`）。实测：持锁者睡
    120 ms 时，等待者自身 CPU 从 **120 ms → 0 ms**；代价是等待超过 ~160 轮后引入 ≤1 ms 的
    释放→获取交接延迟。回归测试在 `RaftElection.zig`。
  * **已修的一半是回包等待**：`sockread.setRecvTimeout`（新，`SO_RCVTIMEO`，镜像已有的
    `setSendTimeout`）由 `ElectionConfig.rpc_timeout_ms`（新，默认 100 ms）驱动，套在发送方的
    连接上。它覆盖的正是生产里更常见的那种黑洞：**握手成功、然后永不回包**
    （对端 GC 长停顿 / accept 队列打满 / 机器过载）。这种对端 connect 侧的界**本来就管不到**。
    回归测试：`RaftTransport.zig` 的
    `a peer that accepts and never replies costs rpc_timeout_ms, not the peer's patience`
    —— 一个"收下请求、绝不回复、把连接按住 2 秒"的监听者，断言调用在
    `rpc_timeout_ms` 内以"消息丢失"返回、**且真的到达过对端**（证明等的是回包而不是握手），
    并把上界卡在 1500 ms（无界时会等到对方那 2 秒）。变异（`rpc_timeout_ms = 0`）验过红。
  * **dial 一半现在也补上了（第 29 批）**：`IpAddress.ConnectOptions` 声称有 `.timeout`，但 CI 锁定的 Zig 0.17 里
    `std.Io.Threaded` 的 `netConnectIpPosix` 是
    `if (options.timeout != .none) @panic("TODO implement netConnectIpPosix with timeout")`
    —— **实测**，不是读来的：传进去等于让每次 dial 直接 abort 进程（`exit=134`），所以那个字段是**陷阱而不是旋钮**，
    `dialTo` 仍然不传它。界改由 `RaftTransport.connectTimeout(io, addr, timeout_ms)` 提供：raw socket +
    `O_NONBLOCK` connect + `poll(POLLOUT)` + 单调时钟 deadline + `getsockopt(SO_ERROR)` 还原真实错误名
    （走 raw 系统调用而非 `std.posix.poll`，后者把 `.FAULT/.INVAL` 映射成 `unreachable` —— 与 `sockread` 同一个理由）。
    三处生产 dial 都走它。实测：SYN 被丢的对端（`169.254.255.254`，本机 OS 默认 ≥25 s 不返回）现在
    **702 ms 返回 `error.ConnectTimeout`**；回落约定是 `timeout_ms = 0` → 无界，老配置 `rpc_timeout_ms = 0` 行为不变。
    界只覆盖 POSIX（Windows 回落无界，`poll` 在那里不存在）。
  * **锁范围本身仍未收窄**（见下面"出站 IO 与锁"一节的设计）：上面两条只是把代价**有界化**，
    没有把 IO 挪出锁 —— 而且这一条对 dial 同样成立：**有界的** IO 在 spin lock 下仍是有界 IO 在 spin lock 下，
    `rpc_timeout_ms` 照样能被持锁烧满。
  不这么做的实际症状是**进程级 ABRT**（`voted_for` 的 read-then-free 交错 →
  `double free of [addr: …]`，两边都是 `RaftElection.zig` 的 `handleVoteRequest` / `startElection`），
  另一种交错顺序只是漏掉那一小段（`SafeAllocator` 报 leaked）—— 两种都在 12 次里各撞到过。
- **`getRaft()` 的契约**（裸指针，锁保护不了它，所以不装锁、只写清楚）：一个 `RaftElection` 只允许一个
  **驱动线程**；`tick()` / `handle*` 各自持锁，但调用方若从别的线程去驱动它，就得自己同步（要么仍由同一个
  线程驱动，要么把整段要原子化的序列包在 `raft.lock` 里）。访问器是**单次读**而不是事务：要多个值一致，
  得自己安排；`getLogEntry().command`、`getLeader()` 返回的是借来的切片，下一次调用后就可能失效。
  `stop()` 会销毁它，之后指针不可再用；`deinit()` 不同步。契约写在
  `ClusterBootstrap.getRaft()` 的 doc 上，同一条也写在 `RaftElection.deinit` / `getLogEntry` /
  `getLeader` 的 doc 上。
- **仓库内回归测试**（进 `zig build test`，实测 2000 轮 = **230 ms**）：
  `RaftElection: a tick and an inbound RPC cannot both free voted_for`
  （`src/core/cluster/RaftElection.zig` 末尾）。两个线程 + 显式 barrier 复刻文档接线（一个线程 `tick()`，
  一个线程 `handleVoteRequest` / `handleAppendEntries`），并用一层 allocator 包装（`WindowGate`）把
  `voted_for` 的 read-then-free 窗口变成**会合点**：第一个 free 会把窗口按住，直到第二个线程也到达同一个
  free —— 也就是"两个线程真的同时在这个窗口里"，这正是锁要禁止的状态。不带锁的构建 → 第一轮就确定性
  ABRT（`double free of [addr: …, len: 6]`，`alloc:` 在 `handleVoteRequest`、`first free:` 在
  `startElection`，3 次独立运行都红）；带锁构建 → 会合点由"窗口的持有者确实握着锁"这一**状态**直接解开
  （没有 sleep、没有超时、不撞概率，所以不引入新的 flaky）。
  这条释放条件（`lock.isHeld()`）是**精确**判据，不是近似：能进这个窗口的只有 `tick`（持锁整段）
  与 `handleVoteRequest`（同）两条路径，所以 free `voted_for` 的线程**必然正持着锁**，于是
  `isHeld() == true ⟺ 观察者自己持锁 ⟺ 对方被挡在 acquire ⟺ 不可能重叠`。它依赖两个前提 ——
  **测试里只有那两个驱动线程**、**mutator 是唯一的取锁者**（全文 15 个取锁入口：8 个 mutator +
  7 个状态访问器）—— 这两条以前只是隐含的，别在测试里加第三个线程。
- **阳性对照**：`RaftElection: the window rendezvous fires iff nothing serializes the entry`
  （同文件末尾，紧随上一条）。上一条只证明"锁让它不响"，而健康构建里 `overlapped` 本来就**不可能**
  为真（互斥性让两个线程进不了同一窗口），所以那句断言在锁正确时接近同义反复 —— 这条测试的牙齿
  主要是"删掉锁 → ABRT"，那是手工实验。阳性对照把这件事钉进仓库：两个线程直接驱动 `WindowGate`，
  两半**只差一件事**（入口取不取锁）。第一半 `lock = null`，第一个线程没有可退出的条件，
  **必然**等到第二个（`overlapped` 为真是确定性的）；第二半各自持锁进门，`overlapped` 保持 false
  且**有理由**（第一半改成串行化即变红 —— 验过的红）。

### 出站 IO 与锁 —— 设计已定，**尚未落地**

`tick()` 的出站轮次在锁内跑（见上）。把它收窄到"算法状态转移在锁内、IO 在锁外"是本文件写下这条
原则时就该有的一半，设计已经定死，但**没有实现** —— 这里写的是契约与三条义务，不是"已完成"。

**形状**：`tick()` 拆三段。

```
第一段（持锁）：判定 + 把这一轮要发的东西**做成自足的请求**放进本节点的暂存
第二段（不持锁）：做 IO，收响应
第三段（持锁）：应用响应，带校验
```

**三条义务**（缺一条都会引入比它修掉的那个更糟的 bug）：

1. **第二段的请求必须自足。** `AppendEntriesRequest.entries` 借的是 `self.log`，而
   `LogEntry.command` 是堆内存、**由 `truncateLog` 释放**（`RaftElection.zig` 的 `truncateLog`）。
   锁一放，入站的 `handleAppendEntries` 就可能截断日志、把那批字节还给分配器 —— 于是传输层
   在读一段已释放的内存。这正是当初加锁要禁的那类交错。所以第一段必须把 entries（含 command 字节）
   **拷进本节点自己的暂存**，且该暂存**稳态不分配**（`clearRetainingCapacity` 复用；心跳轮
   entries 为空，零拷贝 —— 出账只在追日志那条路上，且拷的就是本来要序列化出去的字节）。
2. **第三段必须校验响应是不是这一轮的。** 两段之间另一个线程可能已经：把 `current_term` 抬上去
   （入站更高任期）、把我们降成 follower、或者让我们重新当选。所以第一段要记下
   `(state, current_term)`，第三段要求 `state == .leader and current_term == 等于建轮时的任期`，
   否则**整批丢弃**，不做"尽力而为地应用"。
3. **`next_index` / `match_index` 在第三段读，不跨段携带。** 有义务 2 的守卫时它们不可能变
   （单驱动线程 + 任期未变），但"在第三段读"是把这件事变成**构造上证成**，而不是靠论证。

**顺带必须一起改的**：`becomeLeader` 现在直接 `sendHeartbeats()`（真发），而它从 `startElection`
（`tick` 第一段内）和 `handleVoteResponse`（入站路径、同样持锁）两处被调到。所以它要改成**只登记
"欠一次心跳"**，由 `flushOutgoing()` 这个新入口来做"取锁→快照→放锁→发→取锁→应用"，`tick()` 与
`handleVoteResponse` 各自在放锁之后调它。这样入站路径不必改 `RaftTransport` 的 dispatch。

**护栏**：上面那条阳性对照（`the window rendezvous fires iff nothing serializes the entry`）只管
"窗口有没有被串行化"，**管不到义务 1 和 2** —— 现有测试用的传输层全是立即返回的假实现，
撞不出"锁放开期间日志被截断"和"响应过期"。所以落地时必须**另配两条红测试**：一条让
`sendAppendEntries` 阻塞住、另一个线程同时截断日志，断言发出去的请求仍读到有效字节；
一条让响应在"任期已变"之后才回，断言它被丢弃而不是写进 `next_index`。没有这两条就不要动这段代码。

### 日志压缩（§7 InstallSnapshot，Unreleased 起为可用闭环）

`compactLog` / `handleInstallSnapshot` 的类型与桩存在已久，但生产路径上没人调用（阈值、hook、
leader 侧发送都是缺的），且压缩后全文件把 `log.items.len` / `log.items[i]` 当绝对 index 用的换算
是错的。现在闭环了，约定如下。

**坐标约定**：`log` 只存快照边界之后的**活条目**——绝对 index `i` 位于
`log.items[i - last_included_index - 1]`，`log.items.len` 是**条数**而不是末 index。所有换算集中在
`RaftElection.zig` 的三个私有 helper（`lastLogIndex` / `lastLogTerm` / `termAt`）；append、prev 检查、
冲突截断、commit 推进、投票完整性、复制批次构造全部在绝对坐标上做。follower 侧的 prev 检查分三支：
prev 在边界**上**→ 对 `last_included_term`（不符则拒绝但**不截断**——快照是已提交历史）；prev 在边界
**内**→ 隐式匹配（该区域已提交，由 leader completeness 保证一致），批次里被快照覆盖的条目跳过；
prev 在边界**外**→ 活条目比对，冲突照常截断（截不到快照里）。

- **手动**：`raft.compactLog(up_to_index, snapshot_bytes)`。边界**必须已提交**：
  `up_to_index > commit_index` 返 `error.NotCommitted`——把未提交条目折进快照会让少数派的未提交
  状态变得可存活，正是 §7 禁止的。`up_to_index <= last_included_index` 是 no-op。
- **自动**：`ElectionConfig.snapshot_threshold_entries`（**默认 0 = 关**，存量集群行为不变）。leader 的
  每次 `tick()` 在心跳之后检查 `log.items.len > threshold`，触发时压缩到 `commit_index` 为止
  （`maybeCompactLog`；hook/OOM 错误只记 `std.log.err`，不打断心跳循环）。`BootstrapConfig` 同名透传
  （`snapshot_threshold_entries` / `snapshotter` / `snapshotter_ctx` / `snapshot_chunk_bytes`）。
- **快照字节从哪来**：`ElectionConfig.snapshotter`
  （`Snapshotter = *const fn (ctx: ?*anyopaque, up_to_index: u64, allocator) anyerror![]u8`；在**锁内**
  调用，保持轻量；返回切片用传入 allocator 分配，归 raft 释放）。**不给 hook 时存的是占位摘要**
  （`zigmodu-raft-snapshot:v1:last_included_index=…:last_included_term=…:compacted_entries=…`）——框架
  没有应用状态机，这些字节**恢复不了应用状态**；要真快照的应用自己供 hook 产字节，并在 follower 侧
  从 `snapshot_data` 消费它们。
- **leader → 落后的 follower**：`next_index[peer] <= last_included_index` 时这一轮改发 InstallSnapshot，
  按 `snapshot_chunk_bytes` 分帧（默认 16 KiB；wire 是 u16 长度前缀，clamp 到 65535）。应答**同步**
  消费（与 `sendAppendEntries` 同连接同模型）：成功后 `match_index[peer] = last_included_index`、
  `next_index[peer] = last_included_index + 1`，下一轮回到 AppendEntries；term 更大的应答让节点当场
  退成 follower。走异步传输的应答用公共入口
  `handleInstallSnapshotResponse(resp, from_peer, last_included_index)`——boundary 与当前不符的是
  陈旧应答，只有 term 半步生效（可能退位），`next_index` 不动。
- **follower 侧组装**：分帧按 `(last_included_index, last_included_term)` 归属同一次传输，`offset` 必须
  恰好落在已组装长度上，错位即丢弃等 leader 重传（幂等）；`done` 帧才应用。应用时**保留延续快照的
  日志后缀**（§7 原文语义：边界条目在日志里存在且 term 一致 → 只丢被覆盖的前缀；否则全清）。
  `commit_index` / `last_applied` 取 `@max` 推进。
- **已知坑**：快照发送沿用上节记录的既有模型——出站 IO（含逐帧 chunk）在 `RaftLock` 内同步跑，
  受 `rpc_timeout_ms` 界定但**没有收窄锁范围**；大快照 × 多落后 follower 时这一债会被放大，
  「出站 IO 与锁」一节落地前，巨型快照应调大 `snapshot_chunk_bytes`（少几帧）而不是调小。
  follower 侧主动压缩（非 leader 触发）不在当前闭环内。

## Production Deployment Checklist

### Single-node: All modules are ready.

### Multi-node (3-7 nodes):
1. ✅ `ClusterMembership` — gossip converges via `DistributedEventBus.subscribeWithContext`
2. ✅ `DistributedEventBus` — cross-node pub/sub with soft backpressure
3. ✅ `RaftElection` + `RaftTransport` + `ClusterBootstrap` — votes are counted **per peer to quorum**,
   the outbound transport is `RaftTransport.TransportImpl(N)`, and the inbound listener + `raft.tick()`
   are wired by `ClusterBootstrap` (`tick()`, `start()`); a real operation still needs eyeballs on
   membership/latency, and `raft_cluster_size > 1` refuses to start without a real `.transport`
   (`error.RaftTransportUnavailable`) — see 「多节点启动 fail-closed」与「真选主要什么」
4. ✅ `SagaOrchestrator` — compensation workflows
5. ✅ `DistributedTransaction` — 2PC, coordinator decisions are durable (`TransactionJournal`); participants still hold no journal — see 「2PC 的持久化协调日志」
6. ✅ `KafkaConnector` — Kafka wire client for **RobustMQ** (`initWithIo`, default `127.0.0.1:9092`)
7. 🔬 WAL/DLQ — durability layer for event bus

> **滚动升级（新旧版本混跑）**：集群认证线（raft 帧 HMAC + bus 握手）是**硬切换、无协商** ——
> v0.32.x 及更早的裸线节点发来的帧会被新节点**拒绝**（这是设计，不是回归），混跑期间旧节点
> 选不了主、进不了 membership。对跑证据与 harness：`src/cluster_node.zig` +
> `scripts/ci-mixed-version.sh`（同版本三节点选主/复制 + v0.32.0↔master 混合对跑；夜间 CI
> `soak` job 的 "Mixed-version cluster gate" 步骤，见 `docs/dev/v1.0-readiness-v0.35.md` B-11）。
>
> **平台边界**：集群传输层（`src/core/sockread.zig`、`RaftTransport` 帧写路径）
> 目前是 **POSIX-only**（raw `posix.read` / `send(MSG_NOSIGNAL)` / `sendmsg`）——Linux 与 macOS
> 可用；Windows 上整个集群面不可编译（CI 的 windows-cross 门禁因此不编译 `cluster-node`，
> 见 `build.zig` 该 artifact 的注释）。Windows 可移植化是独立工作项，不在当前路线图上。

### Recommended cluster size: 3-7 nodes

### RobustMQ messaging

```zig
var producer = zigmodu.KafkaProducer.initWithIo(allocator, io, .{
    .bootstrap_servers = "127.0.0.1:9092", // RobustMQ Kafka listener
    .client_id = "my-app",
});
defer producer.deinit();
try producer.send(.{
    .topic = "orders",
    .key = null,
    .value = payload,
    .headers = &.{},
    .timestamp = zigmodu.time.monotonicNowSeconds(),
});
```

Live smoke test: `ROBUSTMQ_URL=127.0.0.1:9092 zig build test`

## Usage Example

```zig
// Node A (port 18080)
var cluster_a = try ClusterMembership.init(allocator, io, "node-a", addr_a, &bus_a);
// Node B (port 18081)
var cluster_b = try ClusterMembership.init(allocator, io, "node-b", addr_b, &bus_b);

// Publish event on A, subscribe on B
try debus_b.subscribe("order.created", handleOrderCreated);
try debus_a.publish("order.created", order_data);
```

## 2PC 的持久化协调日志（`TransactionJournal`）

2PC 的协调者是唯一知道结果的角色：参与者投出 YES 之后、收到 commit/abort 之前，它们处于 **in-doubt**
（怀疑中）。协调者只有内存状态时，崩溃 = 这份知识消失，参与者永远等不到结论。`TransactionJournal`
补的就是这块：**append-only** 的协调者日志，决定**先落盘、再执行**。

```zig
var journal = zigmodu.TransactionJournal.initWithBackend(allocator, backend); // data.SqlxBackend
defer journal.deinit();
try journal.migrate();                        // CREATE TABLE IF NOT EXISTS zigmodu_tx_journal

var tpc = zigmodu.TwoPhaseCommit.init(allocator);
defer tpc.deinit();
tpc.setJournal(&journal);                     // 不设置 = 纯内存协调者（旧行为，零破坏）

try tpc.createCoordinator("tx-1");
try tpc.addParticipant("tx-1", "orders", prepareOrder, commitOrder, rollbackOrder);
if (try tpc.preparePhase("tx-1")) {           // 全 YES：prepared 先落盘，再返回
    // ← 崩溃窗口就在这里：盘上是 prepared、没有终态，重启后 recover 会报告它
    try tpc.commitPhase("tx-1");
} else {
    try tpc.abortPhase("tx-1");               // aborted 先落盘，再回滚
}

// 崩溃之后的新进程：只报告，不决策
const in_doubt = try tpc.recover(allocator);
defer zigmodu.TransactionJournal.freeInDoubt(allocator, in_doubt);
for (in_doubt) |tx| { /* tx.tx_id / tx.participants / tx.updated_at */ }
```

`execute()` 仍是"两阶段一次跑完"（`preparePhase` + `commitPhase` / `abortPhase`），行为未变；需要那个
崩溃窗口的调用方走三段式。

**表**：`zigmodu_tx_journal(tx_id VARCHAR(191), state VARCHAR(16), participants TEXT, updated_at BIGINT)`，
一行一次状态迁移（`begun` / `prepared` / `committed` / `aborted`），**只 INSERT、不 UPDATE** ——
崩溃最多丢掉末尾一条记录，写不坏前面任何一条。DDL 方言中立（无 `AUTOINCREMENT`、无索引），入库走
`data` 领域缝（`data.SqlxBackend`），core 不 import 驱动层。

**写点**：`createCoordinator` / `addParticipant` 写 `begun`（带当时的完整参与者名单）→ 全部 YES 时写
`prepared`（**在任何参与者被通知 commit 之前**）→ 全体 ack 后写 `committed`；任一 NO 或 `abortPhase`
先写 `aborted` 再回滚。配了日志就 **fail-closed**：决定落不了盘，协调者不前进 —— 未落盘的决定正是这个
日志要堵的洞。

**`recover` 只报告、不决策**：返回「`prepared` 且没有 `committed`/`aborted`」的事务（`tx_id` + 参与者 id
列表 + `updated_at`），**不重试、不回滚、不设超时、也不去问参与者到底做了什么** —— 策略属于调用方
（典型：按 id 重新登记回调后 `commitPhase` 收尾，或按业务回滚）。日志里只有 id，**回调不会被持久化**。

**本版边界**（别把它当分布式事务的全套）：

- **参与者侧没有日志**：`recover` 告诉你"谁在怀疑中"，但不能替你保证重试 commit 幂等 ——
  参与者的 prepare / commit 仍必须可重放。
- 写 `aborted` 之后若在回滚途中崩溃：日志有决定，但**没有"每个参与者是否已回滚"**的记录，重放回滚不在本版。
- 表是 append-only 且**没有 GC**：保留窗口与清理任务由调用方自己定。
- `updated_at` 用 `core/Time` 的单调秒（同机跨进程可比，跨重启不可比），不是墙钟。

## 集群读侧：`ClusterView`（v0.19+）

写入侧（`ClusterMembership` / `FailureDetector` / `PeerDiscovery`）是**维护循环**的状态：gossip 到达、
心跳丢失、状态翻转。**请求路径不该读它** —— 那是一个由维护循环拥有的可变哈希表，为它加锁又是错误
的取舍（数据每几秒才变一次，而请求是微秒级的）。

```zig
var view = zigmodu.ClusterView(64, 4).init(allocator);
defer view.deinit();

// 维护循环（单写者）：整份发布，读者要么看到旧的、要么看到新的，绝不看到半份
try view.publish(&.{ .{ .id = "node-a", .address = "10.0.0.1:8080" }, ... });

// 请求路径：引用计数的快照，无锁
const snap = view.acquire();
defer view.release(snap);
const owner = view.pick(key) orelse return error.NoHealthyNode;   // rendezvous 哈希
const backup = view.pickRanked(key, 1);                           // 故障转移用
```

**回收没有 GC 也要说清楚**：只有"分代环"是不够的 —— 慢读者仍可能读到写者已经绕回的槽位
（实测：20 万次读里 1888 次不一致）。所以读侧是**引用计数**：`acquire()` 拿一份带计数的快照，
`release()` 归还；写者在复用槽位前**等该槽读者清零**，等不到就返回 `error.ReadersBusy` 而不是覆盖活数据。
发布是秒级的维护活动、读是微秒级的请求活动 —— 等，是便宜的那个方向。

**选节点用 rendezvous 哈希**（`hash(key ‖ id)` 取最大），而不是 `core/eventbus/Partitioner.zig` 的
一致性哈希环：环需要在每次成员变化时重建、且读它要加锁；rendezvous 无状态、无存储、无锁，
而"成员变化时只有它拥有的 key 迁移"这条要紧的性质同样成立。环仍留在事件总线那种**批量写**的场景。

**本版刻意不做**（避免把未验证的东西当能力卖）：

- 不发明新协议：成员传播/心跳仍走既有 `NetworkTransport` / 既有 gossip 消息格式。
- 不做跨节点一致性：需要强一致的编排继续用 Postgres（见 `docs/BEST_PRACTICES.md`「分布式建议」）。
- `RaftElection` 仍是 **experimental**（未接入服务发现）。`DistributedTransaction` 的**协调者**决策已落盘
  （见下文「2PC 的持久化协调日志」），但 `recover` 只报告不决策，且**参与者侧仍无日志**。
- 快照的 `weight` 字段已带但 `pick` 未使用（留位，避免以后改快照格式）。

