# Distributed Modules — Production Readiness

## Status Overview

All distributed modules are **Ready** for single-node testing and development.
For multi-node production, see the caveats below.

| Module | Tests | Notes |
|--------|:-----:|-------|
| **FailureDetector** | 7 | Phi-accrual detector. Adaptive threshold. |
| **KafkaConnector** | 7 | Producer/Consumer + wire format. Requires Kafka broker for full integration. |
| **SagaOrchestrator** | 6 | Auto-compensation with reverse-order rollback. |
| **RaftElection** | 5 | Leader election + vote counting. Multi-candidate split-vote tested. |
| **DistributedTransaction** | 4 | 2PC protocol (commit + abort). |
| **ClusterMembership** | 4 | Gossip protocol + health checks. Join/leave/rejoin tested. |
| **DistributedEventBus** | 3 | Cross-node pub/sub with heartbeat. |
| **WAL** (eventbus/) | 2 | Write-ahead log. Zig 0.16 Io.Dir + binary serialization. |
| **DLQ** (eventbus/) | 3 | Dead-letter queue. Expiry + requeue with cooldown. |
| **Partitioner** | 3 | Consistent hash ring. Node add/remove + routing. |

## Production Deployment Checklist

### Single-node: All modules are ready.

### Multi-node (3-5 nodes):
1. ✅ `ClusterMembership` — node discovery, gossip, health tracking
2. ✅ `DistributedEventBus` — cross-node pub/sub
3. ✅ `RaftElection` — leader election (test with 3+ real nodes)
4. ✅ `SagaOrchestrator` — compensation workflows
5. ✅ `DistributedTransaction` — 2PC (add persistence for production durability)
6. ✅ `KafkaConnector` — wire format ready (needs broker for full integration)
7. 🔬 WAL/DLQ — add durability layer for event bus (requires Zig 0.16 fs API)

### Recommended cluster size: 3-5 nodes

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
