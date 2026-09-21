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
| **DistributedEventBus** | 22 | Cross-node pub/sub + soft backpressure (quarantine after send failures); length-prefixed frames, per-identity HMAC (`setClusterSecret`), strictly increasing `"seq"` per claim (replay), per-node write lock, idle read bound. |
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

## 总线入站：帧、身份与重放（`Unreleased` 起，接线者要知道的三件事）

`DistributedEventBus` 的监听端口是**集群内部面**。配了 `cluster_secret` 就有 L1：

```text
[4-byte BE len][mac: 32][json]
mac = HMAC-SHA256( HMAC-SHA256(cluster_secret, json "source"), json )
```

1. **密钥按"声称的身份"派生**（`key(claim) = HMAC(cluster_secret, claim)`）：声称 `node-b` 的对端
   必须持有 `node-b` 的密钥。**残留**：集群级 PSK 意味着**持有 `cluster_secret` 的人可以冒充任何
   节点** —— 这是 PSK 的性质，不是实现缺陷。
2. **`"seq"` 必带且对同一 claim 严格递增**（高水位跨重连存活），所以捕获到的帧重放不了。
   **残留**：从未被接受过的帧（连接断掉之后才发出的那些）仍可重放一次；**宿主机重启**会让发送方
   序号回退 → 被对端拒绝，需要 `forgetPeerSeq(id)` 人工放行（或对端重启）。没有自动接受重置。
3. **入站读有 30s 空闲上界**（`inbound_idle_timeout_ms`，= 6 × 心跳间隔）：沉默对端不会占住连接，
   `stop()` 也就不再被它卡住；健康对端在两次心跳之间本来就是安静的，30s 不会误杀。

另外两点：每个 node 一把写锁（`publish` 的请求线程与 `heartbeatLoop` 的 fiber 不会在同一个 socket 上
交错）；`source_node` **仍然只是自述**，没有与成员表比对（accept 侧拿不到"连接 → id"的映射）——
L1 认证的是"哪台主机 + 它证明了它声称的那个密钥"，L2 不覆盖这一面。
完整改动与残留清单：`docs/dev/cluster-auth-design.md` §14。

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

同一条路上还有两道门：多节点 + 真传输但**没有** `cluster_secret` → `error.ClusterAuthRequired`
（或显式 `.allow_unauthenticated_cluster = true`）；`.peers` 里有 peer **没写 `@id`** →
`error.PeerIdRequired`（见下文「peer id 与地址是两份事实」）。

### 真选主要什么（transport 契约）

框架里已有全部零件，接线的这层在 v0.23.0 起由 `src/core/cluster/RaftTransport.zig` 提供
（`TransportImpl(N)` 出站同步/异步 · `handleConnection` + `InboundServer` 入站分发与同连接回包 · `AddressBook`；
投票应答另走「应答走入站」回推，loopback 用例见该文件）。下表既是它替你完成的契约，也是你自带传输时要实现的部分：

| 方向 | 用什么 | 要做的事 |
|------|--------|---------|
| 出站 · 投票 | `NetworkTransport.connect(host, port)` → `ClusterConnection.send(payload)` | `sendVoteRequest` 返回 `void`（fire-and-forget）：把 `VoteRequest` 编码后发给每个 peer 即可，**应答走入站** |
| 出站 · 日志复制 | 同上 | `sendAppendEntries` 是**同步**的：发出去、读回 `AppendEntriesResponse`（同一条连接 `recv`） |
| 入站 · 分发 | **`ClusterBootstrap.start()` 已经替你挂好**（给了 `.transport` 就在 `port` 上监听，走 `RaftTransport.handleConnection`）；不用 `ClusterBootstrap` 时才需要自己用 `ClusterServer.start(handler)` / `RaftTransport.InboundServer` | 解码后分别调 `RaftElection.handleVoteRequest` / `handleAppendEntries` / `handleVoteResponse` / `handleInstallSnapshot`，把返回值编码后**在同一连接上回包** |
| 地址簿 | **`ClusterBootstrap` 从 `config.peers` 建**（`RaftTransport.AddressBook`，键 = `peers` 里 `@` 前的 id，与 `raft.addPeer(p.id)` 同口径） | peer id → `host:port` 的映射（今天 `BootstrapConfig.peers` 是唯一来源；`ClusterMembership` 的 `nodes` 只有 loopback + 端口） |
| 失败语义 | 你自己 | Raft 能容忍丢包与重发：`AppendEntriesResponse{ .success = false }` 是**正常应答**而不是错误；连接失败按"这条消息丢了"处理即可，别把节点判死（那是 `AccrualFailureDetector` 的活） |

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
  所以这把锁**在 `RaftElection` 自己身上**（`RaftElection.RaftLock`，原子自旋，与 `scheduler.zig`
  协调池线程同口径）：每个碰共享状态的公开入口（`tick` / `handleVoteRequest` / `handleAppendEntries` /
  `handleVoteResponse` / `handleInstallSnapshot` / `appendEntry` / `addPeer` / `compactLog` 以及状态
  访问器）自己取放一次，私有的步骤函数（`startElection` / `sendHeartbeats` / `becomeLeader` / …）
  假设锁已在手。**门面不再持锁**（`ClusterBootstrap.raft_lock` 已删）：`ClusterBootstrap` 直接驱动、
  `RaftTransport.InboundServer` 单独用、或应用自己调 `raft.tick()` / 在其它线程读它，都被同一把锁串起来，
  不再取决于调用方记得住哪两处不能重叠。
  锁的窗口是入站那一帧的 **decode → dispatch → encode** 里那次 `handle*`（dispatch 本身即窗口）；
  decode/encode 只碰 arena 缓冲与 init 之后再不改的 `local_id`，而 **socket 读 / 回包 / 回推仍在锁外**
  （对端 connect 超时不该卡住 `tick()`）。不给 `.transport` 的节点没有 accept 线程，锁是零成本的一条取指。
  **但这条原则在出站方向曾经是反的**，而且这里必须写清是哪一半修了、哪一半没有：

  * `tick()` 的出站轮次（`sendHeartbeats` → `transport.sendAppendEntries`、`startElection` 的
    `sendVoteRequest`）**整段在锁内**跑，而 `RaftLock` 是**自旋**锁 —— 一个不响应的对端不是"慢一轮"，
    是让每个想碰状态的线程（accept 线程的入站 RPC、`appendEntry`、所有访问器）在
    `spinLoopHint` 上**烧核**，时间为这一次 RPC 的等待时间。
  * **已修的一半是回包等待**：`sockread.setRecvTimeout`（新，`SO_RCVTIMEO`，镜像已有的
    `setSendTimeout`）由 `ElectionConfig.rpc_timeout_ms`（新，默认 100 ms）驱动，套在发送方的
    连接上。它覆盖的正是生产里更常见的那种黑洞：**握手成功、然后永不回包**
    （对端 GC 长停顿 / accept 队列打满 / 机器过载）。这种对端 connect 侧的界**本来就管不到**。
    回归测试：`RaftTransport.zig` 的
    `a peer that accepts and never replies costs rpc_timeout_ms, not the peer's patience`
    —— 一个"收下请求、绝不回复、把连接按住 2 秒"的监听者，断言调用在
    `rpc_timeout_ms` 内以"消息丢失"返回、**且真的到达过对端**（证明等的是回包而不是握手），
    并把上界卡在 1500 ms（无界时会等到对方那 2 秒）。变异（`rpc_timeout_ms = 0`）验过红。
  * **未修的一半是 dial**：`IpAddress.ConnectOptions` 声称有 `.timeout`，但 CI 锁定的 Zig 0.17 里
    `std.Io.Threaded` 的 `netConnectIpPosix` 是
    `if (options.timeout != .none) @panic("TODO implement netConnectIpPosix with timeout")`
    —— **实测**，不是读来的。传进去等于让每次 dial 直接 abort 进程，所以 `dialTo` 没传。
    SYN 被丢的对端仍然要付 OS 默认的 connect 超时。要补这一半得自己写带 deadline 的
    非阻塞 connect + poll（平台相关），不是 endpoint 接线该放的东西。
  * **锁范围本身仍未收窄**（见下面"出站 IO 与锁"一节的设计）：上面两条只是把代价**有界化**，
    没有把 IO 挪出锁。
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

