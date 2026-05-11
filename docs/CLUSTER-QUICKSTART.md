# Multi-Node Cluster Quick Start

## 3-Node Local Cluster

### 1. Start Node 1 (port 9001)

```zig
// node1.zig
const std = @import("std");
const zmodu = @import("zigmodu");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var cluster = try zmodu.ClusterBootstrap.init(allocator, init.io, .{
        .node_id = "node-1",
        .port = 9001,
        .peers = &.{ "127.0.0.1:9002", "127.0.0.1:9003" },
    });
    defer cluster.deinit();

    try cluster.start();
    std.log.info("Node 1 started. Leader: {?s}", .{cluster.getRaft().?.getLeader()});

    // Block until signal
    while (true) { std.Thread.sleep(1_000_000_000); }
}
```

### 2. Start Node 2 (port 9002)
```zig
// Same config, different node_id and port
.cluster(.{ .node_id = "node-2", .port = 9002, .peers = &.{"127.0.0.1:9001", "127.0.0.1:9003"} })
```

### 3. Start Node 3 (port 9003)
```zig
.cluster(.{ .node_id = "node-3", .port = 9003, .peers = &.{"127.0.0.1:9001", "127.0.0.1:9002"} })
```

## HTTP + Cluster Health

```zig
var server = Server.init(io, allocator, 8080);
var cluster = try ClusterBootstrap.init(allocator, io, .{
    .node_id = "api-1", .port = 9001, .peers = &.{},
});
try cluster.start();

// Register cluster health endpoint
server.addRoute(.{
    .method = .GET,
    .path = "/cluster/health",
    .handler = struct {
        fn h(ctx: *Context) !void {
            const json = try healthJson(ctx.allocator, &cluster);
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
        }
    }.h,
});
```

## Docker Compose (3 nodes)

```yaml
services:
  node1:
    build: .
    command: zig build run -- -node=node-1 -port=9001 -peers=node2:9002,node3:9003
    ports: ["8081:8080", "9001:9000"]
  node2:
    build: .
    command: zig build run -- -node=node-2 -port=9002 -peers=node1:9001,node3:9003
    ports: ["8082:8080", "9002:9000"]
  node3:
    build: .
    command: zig build run -- -node=node-3 -port=9003 -peers=node1:9001,node2:9002
    ports: ["8083:8080", "9003:9000"]
```

## Health Check

```bash
curl http://localhost:8081/cluster/health
# {"status":"UP","node_id":"node-1","cluster":{"nodes_active":3,"raft_term":1,...}}
```

## Prometheus Metrics

```bash
curl http://localhost:8081/metrics
# zigmodu_cluster_nodes_active 3
# zigmodu_cluster_leader_epoch 1
# zigmodu_cluster_messages_sent_total 42
```
