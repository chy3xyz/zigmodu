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
```

## Stop

```bash
docker compose down
```
