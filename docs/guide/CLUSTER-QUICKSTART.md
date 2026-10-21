# Cluster Quick Start (Single Node)

> Before adding multiple nodes, read [Distributed Systems](../reference/DISTRIBUTED.md). Multi-node clusters (`raft_cluster_size > 1`) fail closed at startup (`error.RaftTransportUnavailable`) unless you supply a real `.transport` (or explicitly set `.allow_stub_raft_transport = true` for membership-only operation) and configure authentication credentials (`own_key`/`peer_keys` or `cluster_secret`).

## 1. Bootstrapping a Single Node

```zig
const std = @import("std");
const zmodu = @import("zmodu");

var cluster: *zmodu.ClusterBootstrap = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var boot = try zmodu.ClusterBootstrap.init(allocator, io, .{
        .node_id = "node-1",
        .port = 9001,
        .peers = &.{},
        .raft_cluster_size = 1,
    });
    defer boot.deinit();
    try boot.start();
    cluster = &boot;

    // `tick()` runs one gossip/health pass, republishes the read-side ClusterView,
    // and advances `raft.tick()`. `error.ReadersBusy` means a request is reading
    // the previous snapshot slot and is safe to ignore until the next tick.
    while (true) {
        boot.tick() catch |err| switch (err) {
            error.ReadersBusy => {},
            else => return err,
        };
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake);
    }
}
```

Request handlers must read cluster membership through the lock-free read-side snapshot (`cluster.pick(key)` or `cluster.getView().acquire()`), never by locking the mutable membership map.

## 2. Mounting Health and Metrics Endpoints

```zig
fn clusterHealth(ctx: *zmodu.http.Context) anyerror!void {
    const json = try zmodu.clusterHealthJson(ctx.allocator, cluster);
    defer ctx.allocator.free(json);
    try ctx.json(200, json);
}

fn clusterMetrics(ctx: *zmodu.http.Context) anyerror!void {
    const text = try cluster.getMetrics().toPrometheus(ctx.allocator);
    defer ctx.allocator.free(text);
    try ctx.text(200, text);
}

// Register routes on your HTTP server:
var server = zmodu.http.Server.init(io, allocator, 8080);
defer server.deinit();
try server.addRoute(.{ .method = .GET, .path = "/cluster/health", .handler = clusterHealth });
try server.addRoute(.{ .method = .GET, .path = "/cluster/metrics", .handler = clusterMetrics });
try server.start();
```

Verify the endpoints:

```bash
curl -s http://127.0.0.1:8080/cluster/health
# {"status":"UP","node_id":"node-id","cluster":{"nodes_active":1,"raft_term":0,"raft_state":"follower"}}

curl -s http://127.0.0.1:8080/cluster/metrics
# zigmodu_cluster_nodes_active 1
# zigmodu_cluster_leader_epoch 0
# zigmodu_cluster_messages_sent_total 0
```
