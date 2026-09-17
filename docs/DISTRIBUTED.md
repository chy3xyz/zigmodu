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
| **DistributedTransaction** | 6 | 2PC protocol (commit + abort). ⚠ No persistence (see caveats). |
| **ClusterMembership** | 4 | Gossip over bus with `subscribeWithContext` (join/leave/heartbeat converge). |
| **DistributedEventBus** | 10 | Cross-node pub/sub + soft backpressure (quarantine after send failures). |
| **ClusterView** (cluster/) | 6 | Reference-counted read-side snapshot + rendezvous pick. |
| **WAL** (eventbus/) | 2 | Write-ahead log. Zig 0.16 Io.Dir + binary serialization. |
| **DLQ** (eventbus/) | 3 | Dead-letter queue. Expiry + requeue with cooldown. |
| **Partitioner** | 3 | Consistent hash ring. Node add/remove + routing. |

> 计数口径：各文件内 `grep -c '^test '`。本表会随版本漂移，**以代码为准**（`docs/AGENTS.md` 同款原则）。
> `src/core/cluster/` 下另有 PeerDiscovery(4) / LoadBalancer(5) / ClusterHealth(1) / ClusterBootstrap(1)，
> 但**均未从 `root.zig` 导出、无请求路径接入**；`DistributedIntegrationTest.zig` 无人 import（不编译、测试不运行）。

## 读侧怎么被喂（membership → view → 请求路径）

`ClusterView` 是**读侧**：引用计数快照 + rendezvous 选点，请求路径读它、不读 membership 的哈希表。
它长期**没有发布者**（组件齐、没人喂）—— 现在是 `src/cluster/MembershipView.zig`：

```text
  gossip / health (ClusterMembership, 写侧)  →  sync()  →  ClusterView.publish()  →  请求路径
        mutex 保护的 hash map                  快照+格式化       引用计数槽位           acquire / pick
```

```zig
// 组装：ClusterBootstrap 自带一个 view
var cluster = try ClusterBootstrap.init(allocator, io, .{ .node_id = "n1", .port = 9000, .peers = &.{} });
defer cluster.deinit();
try cluster.start();

// 驱动：membership 的循环是**外部驱动**的（runOnce），tick() 一次做完两件事
try cluster.tick();                       // gossip/health 一遍 + 刷新读侧

// 请求路径：
const view = cluster.getView();
const snap = view.acquire();
defer view.release(snap);
const node = view.pick(order_id) orelse return error.NoHealthyNode;
```

- `tick()` 里的 `error.ReadersBusy` **不算失败**：请求路径正在读，view 保留上一代，下一个 tick 再发布
  （视图刻意不覆盖有人持有的槽位）。
- 想把 `tick()` 挂到运行时定时器：`_ = try worker.after(1000, .tick);`（见 `docs/RUNTIME.md` §3d 的模块用法）。
- `suspect` 状态的节点**不进 `pick`**（"可能挂了"不该收流量），但仍留在快照里给运维看。

**已知限制（跨主机发现）**：gossip 负载里带着对端 host，但接收侧没有解析器 —— 被发现的节点一律按
`127.0.0.1 + 它自报的端口` 记账（`ClusterMembership.handleGossipEvent`，代码注释里写明了）。所以
**同主机 / 共享容器网络**的发现可用，**跨主机**要用显式 seed（`connectToSeed` 带真实地址，不受影响）。

**多节点启动 fail-closed，但可自带传输**：`ClusterBootstrap` 内置的 Raft 传输是桩（`sendVoteRequest` 空函数、
`sendAppendEntries` 恒 false），所以 `raft_cluster_size > 1` 时 `start()` 返回 `error.RaftTransportUnavailable` ——
宁可不启动，也不选出一个"没人投过票"的 leader。两条出路：

1. **自带传输**：`BootstrapConfig.transport = <RaftElection.ElectionTransport>`。这是框架给缝、不给实现的地方 ——
   契约在下一节。
2. **只要 membership + 读侧**：`.allow_stub_raft_transport = true` 显式承认；单节点用 `raft_cluster_size = 1`。

### 真选主要什么（transport 契约）

框架里已有全部零件，缺的是把它们接起来的那层（本仓未提供）：

| 方向 | 用什么 | 要做的事 |
|------|--------|---------|
| 出站 · 投票 | `NetworkTransport.connect(host, port)` → `ClusterConnection.send(payload)` | `sendVoteRequest` 返回 `void`（fire-and-forget）：把 `VoteRequest` 编码后发给每个 peer 即可，**应答走入站** |
| 出站 · 日志复制 | 同上 | `sendAppendEntries` 是**同步**的：发出去、读回 `AppendEntriesResponse`（同一条连接 `recv`） |
| 入站 · 分发 | `ClusterServer.start(handler)`（handler 拿到 `ClusterConnection`） | 解码后分别调 `RaftElection.handleVoteRequest` / `handleAppendEntries` / `handleVoteResponse` / `handleInstallSnapshot`，把返回值编码后**在同一连接上回包** |
| 地址簿 | 你自己 | peer id → `host:port` 的映射（今天 `BootstrapConfig.peers` 是唯一来源；`ClusterMembership` 的 `nodes` 只有 loopback + 端口） |
| 失败语义 | 你自己 | Raft 能容忍丢包与重发：`AppendEntriesResponse{ .success = false }` 是**正常应答**而不是错误；连接失败按"这条消息丢了"处理即可，别把节点判死（那是 `AccrualFailureDetector` 的活） |

`RaftElection.tick()` 现在**没有任何人调用**（和 `ClusterMembership.runOnce` 一样是外部驱动）——
自带传输的同时要把它挂进你的循环（例如 `ClusterBootstrap.tick()` 里加一行）。

上面「本仓未提供」已不成立：实现于 `RaftTransport.zig`（`TransportImpl(N)` 出站同步/异步 · `handleConnection` + `InboundServer` 入站分发与同连接回包 · `AddressBook`；投票应答另走「应答走入站」回推，loopback 用例见该文件）。

## Production Deployment Checklist

### Single-node: All modules are ready.

### Multi-node (3-7 nodes):
1. ✅ `ClusterMembership` — gossip converges via `DistributedEventBus.subscribeWithContext`
2. ✅ `DistributedEventBus` — cross-node pub/sub with soft backpressure
3. ✅ `RaftElection` — leader election (test with 3+ real nodes)
4. ✅ `SagaOrchestrator` — compensation workflows
5. ✅ `DistributedTransaction` — 2PC (add persistence for production durability)
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
- `RaftElection` / `DistributedTransaction` 仍是 **experimental**：前者未接入服务发现，后者缺持久化日志。
- 快照的 `weight` 字段已带但 `pick` 未使用（留位，避免以后改快照格式）。

