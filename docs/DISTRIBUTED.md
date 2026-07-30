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
| **SagaOrchestrator** | 6 | Auto-compensation with reverse-order rollback. |
| **RaftElection** | 5 | Leader election + vote counting. Multi-candidate split-vote tested. |
| **DistributedTransaction** | 4 | 2PC protocol (commit + abort). |
| **ClusterMembership** | 5 | Gossip over bus with `subscribeWithContext` (join/leave/heartbeat converge). |
| **DistributedEventBus** | 3 | Cross-node pub/sub + soft backpressure (quarantine after send failures). |
| **WAL** (eventbus/) | 2 | Write-ahead log. Zig 0.16 Io.Dir + binary serialization. |
| **DLQ** (eventbus/) | 3 | Dead-letter queue. Expiry + requeue with cooldown. |
| **Partitioner** | 3 | Consistent hash ring. Node add/remove + routing. |

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
