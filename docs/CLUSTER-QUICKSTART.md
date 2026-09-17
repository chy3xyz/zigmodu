# Cluster Quick Start — Single Node

> **Read this before adding a second node.** The built-in Raft transport is a stub, so a cluster with
> `raft_cluster_size > 1` refuses to start (`error.RaftTransportUnavailable`) unless you pass a real
> `.transport` — or acknowledge `.allow_stub_raft_transport = true` to run membership + the read side only.
> What exists today (transport ✅, election state machine still gapped) and the contract a real transport
> must satisfy are written out in [`DISTRIBUTED.md`](DISTRIBUTED.md), sections
> *"multi-node startup is fail-closed"* and *"what real leader election needs"*.
> The walkthrough below is the single-node path that works today.

## 1. One node, no peers

```zig
// node.zig
const std = @import("std");
const zmodu = @import("zigmodu");

// The HTTP handler below is a plain fn (Zig has no closures), so the node lives at file scope.
var cluster: *zmodu.ClusterBootstrap = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var boot = try zmodu.ClusterBootstrap.init(allocator, io, .{
        .node_id = "node-1",
        .port = 9001,             // membership / transport port
        .peers = &.{},
        .raft_cluster_size = 1,   // >1 without a real `.transport` → error.RaftTransportUnavailable
    });
    defer boot.deinit();
    try boot.start();
    cluster = &boot;

    // Nothing drives the membership loop for you: tick() is one gossip/health pass
    // plus a read-side republish. `error.ReadersBusy` is not a failure (a request path
    // was mid-read; the previous view stays published and the next tick retries).
    while (true) {
        try boot.tick();
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake);
    }
}
```

Request paths read the **view**, never the membership map
(`ClusterBootstrap.getView().acquire()` / `.pick(key)` / `.release(snap)` — see
[`DISTRIBUTED.md`](DISTRIBUTED.md) reading side notes).

## 2. HTTP health endpoint (you mount it)

`ClusterHealth` is a pair of functions, not a route: `clusterHealthJson(allocator, cluster)` renders the
JSON and your handler decides the path. (`clusterHealthHandler(cluster)` exists, but its signature takes
`*anyopaque` and returns bytes — it is not a `http.Context` handler.)

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

// in main, after `cluster = &boot;`:
var server = zmodu.http.Server.init(io, allocator, 8080);
defer server.deinit();
try server.addRoute(.{ .method = .GET, .path = "/cluster/health", .handler = clusterHealth });
try server.addRoute(.{ .method = .GET, .path = "/cluster/metrics", .handler = clusterMetrics });
try server.start();
```

```bash
curl -s http://localhost:8080/cluster/health
# {"status":"UP","node_id":"node-id","cluster":{"nodes_active":1,"raft_term":0,"raft_state":"follower"}, …}
```

Two honest notes on that output:

- `node_id` is currently the literal string `"node-id"` — `ClusterHealth.healthJson` does not use the
  configured id yet (it is on the fix list, not implemented).
- A single node has no peer to vote for it, so `raft_term` stays `0` and `raft_state` stays
  `follower`/`candidate`; real leadership needs a transport plus the missing vote counting
  ([`DISTRIBUTED.md`](DISTRIBUTED.md)).

```bash
curl -s http://localhost:8080/cluster/metrics
# zigmodu_cluster_nodes_active 1
# zigmodu_cluster_leader_epoch 0
# zigmodu_cluster_messages_sent_total 0
```
