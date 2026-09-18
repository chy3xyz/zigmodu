//! Cluster health HTTP endpoint for multi-node deployments.
//!
//! Exposes /cluster/health with JSON status including:
//! - Node count and leader status
//! - Peer health from ClusterMembership
//! - Message rates from ClusterMetrics
//! - RaftElection term and state
//!
//! Positioning: user-facing; no in-tree consumer, deliberately. `healthJson` /
//! `clusterHealthHandler` are handed to the application to mount on whatever path
//! it likes (the framework adds no route for them), and
//! `ClusterBootstrap.healthJson` forwards to the former.

const std = @import("std");
const ClusterBootstrap = @import("ClusterBootstrap.zig").ClusterBootstrap;

/// Generate a JSON health report for the cluster.
pub fn healthJson(alloc: std.mem.Allocator, cluster: *ClusterBootstrap) ![]const u8 {
    const m = cluster.getMetrics();
    const raft = cluster.getRaft() orelse return error.ClusterNotStarted;

    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "status":"UP",
        \\  "node_id":"{s}",
        \\  "cluster":{{
        \\    "nodes_active":{d},
        \\    "raft_term":{d},
        \\    "raft_state":"{s}"
        \\  }},
        \\  "messages":{{
        \\    "sent":{d},
        \\    "received":{d},
        \\    "failed":{d}
        \\  }},
        \\  "transport":{{
        \\    "bytes_sent":{d},
        \\    "bytes_received":{d}
        \\  }}
        \\}}
    , .{
        cluster.getConfig().node_id,
        m.node_count.load(.monotonic),
        raft.getTerm(),
        @tagName(raft.getState()),
        m.messages_sent.load(.monotonic),
        m.messages_received.load(.monotonic),
        m.messages_failed.load(.monotonic),
        m.bytes_sent.load(.monotonic),
        m.bytes_received.load(.monotonic),
    });
}

/// HTTP handler for /cluster/health.
pub fn clusterHealthHandler(cluster: *ClusterBootstrap) *const fn (*anyopaque) anyerror![]const u8 {
    const S = struct {
        var c: *ClusterBootstrap = undefined;

        fn handler(alloc: ?*anyopaque) anyerror![]const u8 {
            const allocator: std.mem.Allocator = @ptrCast(@alignCast(alloc orelse return error.NoAllocator));
            return healthJson(allocator, c);
        }
    };
    S.c = cluster;
    return S.handler;
}

test "ClusterHealth JSON output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cluster = try ClusterBootstrap.init(allocator, io, .{
        .node_id = "health-test",
        .port = 19001,
        // This test exercises the health report, not elections: a single node has
        // nothing to elect, so the stub Raft transport is fine (multi-node boots
        // are refused — see the ClusterBootstrap tests).
        .raft_cluster_size = 1,
    });
    defer cluster.deinit();

    try cluster.start();

    const json = try healthJson(allocator, &cluster);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "UP") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "nodes_active") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "raft_term") != null);
}

test "ClusterHealth reports the configured node_id" {
    const allocator = std.testing.allocator;

    var cluster = try ClusterBootstrap.init(allocator, std.testing.io, .{
        .node_id = "health-node-id",
        .port = 19006,
        .raft_cluster_size = 1,
    });
    defer cluster.deinit();

    try cluster.start();

    const json = try healthJson(allocator, &cluster);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("health-node-id", parsed.value.object.get("node_id").?.string);
    try std.testing.expectEqualStrings(cluster.getConfig().node_id, parsed.value.object.get("node_id").?.string);
}
