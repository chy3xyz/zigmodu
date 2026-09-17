# Cluster Demo — 3-Node ZigModu Cluster

## Start

```bash
docker compose up -d
```

## Verify

```bash
# Node 1 health
curl http://localhost:8081/cluster/health
# {"status":"UP","node_id":"node-1","cluster":{"nodes_active":3,"raft_term":1,...}}

# Node 2 health
curl http://localhost:8082/cluster/health

# Node 3 metrics
curl http://localhost:8083/metrics | grep zigmodu_cluster
```

## Architecture

```
  node1:9001 ──gossip── node2:9002
       │                    │
       └────gossip── node3:9003

  Each node runs: ClusterBootstrap (DEB + Membership + Raft + Metrics)

> **现状提醒（2026-09-17）**：本示例在仓里只有 `docker-compose.yml` + 本文档（没有 source），而
> `ClusterBootstrap` 的 Raft 传输目前是**桩** —— `raft_cluster_size > 1` 时它**拒绝启动**
> （`error.RaftTransportUnavailable`，见 `docs/DISTRIBUTED.md`「多节点启动 fail-closed」）。
> 也就是说本文描述的多节点选主**尚未实现**；现在真实可用的是 membership + 读侧
> （`MembershipView` / `ClusterView`，请求路径用 `acquire`/`pick`）。
```

## Stop

```bash
docker compose down
```
