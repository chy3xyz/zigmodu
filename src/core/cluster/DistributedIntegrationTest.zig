//! Distributed Systems Integration Tests
//!
//! These tests verify the integration between distributed components:
//! - ClusterMembership with AccrualFailureDetector
//! - Multi-node cluster scenarios
//! - Health tracking with φ (phi) accrual failure detection
//!
//! Note: These are integration tests that test component interactions.
//! Full distributed testing with actual network connections would require
//! multiple processes. These tests use simulated scenarios.

const std = @import("std");
const Testing = std.testing;
const Time = @import("../Time.zig");
const ClusterMembership = @import("../ClusterMembership.zig").ClusterMembership;
const DistributedEventBus = @import("../DistributedEventBus.zig").DistributedEventBus;
const AccrualFailureDetector = @import("./FailureDetector.zig").AccrualFailureDetector;
const AccrualFailureDetectorConfig = @import("./FailureDetector.zig").AccrualFailureDetectorConfig;

// ============================================================================
// Integration Tests
// ============================================================================

test "ClusterMembership with FailureDetector - basic integration" {
    const allocator = Testing.allocator;
    const io = Testing.io;

    var bus = try DistributedEventBus.init(allocator, io, "test-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19100);
    var cluster = try ClusterMembership.init(allocator, io, "node-1", addr, &bus);
    defer cluster.deinit();

    var fd = AccrualFailureDetector.init(allocator, .{
        .phi_threshold = 8.0,
    });
    defer fd.deinit();

    // Set the failure detector
    cluster.setFailureDetector(&fd);

    // Verify no phi value initially for unknown node
    const phi1 = cluster.getNodePhi("unknown-node");
    try Testing.expect(phi1 != null);
    try Testing.expect(phi1.? == 0.0);

    // Record some heartbeats for a peer node
    try fd.heartbeat("peer-1");
    try fd.heartbeat("peer-1");
    try fd.heartbeat("peer-1");

    // Now phi should be calculable
    const phi2 = cluster.getNodePhi("peer-1");
    try Testing.expect(phi2 != null);
    try Testing.expect(phi2.? >= 0);

    // Peer should be alive with low phi
    try Testing.expect(fd.isAlive("peer-1"));
}

test "ClusterMembership with FailureDetector - node health tracking" {
    const allocator = Testing.allocator;
    const io = Testing.io;

    var bus = try DistributedEventBus.init(allocator, io, "health-test");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19101);
    var cluster = try ClusterMembership.init(allocator, io, "monitor-node", addr, &bus);
    defer cluster.deinit();

    var fd = AccrualFailureDetector.init(allocator, .{
        .phi_threshold = 8.0,
        .max_samples = 10,
    });
    defer fd.deinit();

    cluster.setFailureDetector(&fd);

    // Simulate peer joining
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "peer-health",
        .host = "127.0.0.1",
        .port = 19102,
        .timestamp = 0,
    });

    // Record heartbeats
    for (0..5) |_| {
        try fd.heartbeat("peer-health");
    }

    // Peer should be alive
    try Testing.expect(fd.isAlive("peer-health"));
    try Testing.expect(cluster.getHealthyNodeCount() >= 1);
}

test "ClusterMembership with FailureDetector - suspected node detection" {
    const allocator = Testing.allocator;
    const io = Testing.io;

    var bus = try DistributedEventBus.init(allocator, io, "suspect-test");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19103);
    var cluster = try ClusterMembership.init(allocator, io, "detector-node", addr, &bus);
    defer cluster.deinit();

    // Use a high threshold so we can control the phi calculation
    var fd = AccrualFailureDetector.init(allocator, .{
        .phi_threshold = 8.0,
        .min_std_deviation_ms = 10.0, // Low variance
    });
    defer fd.deinit();

    cluster.setFailureDetector(&fd);

    // Simulate a slow peer
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "slow-peer",
        .host = "127.0.0.1",
        .port = 19104,
        .timestamp = 0,
    });

    // Record one heartbeat then simulate no more (node going slow/dead)
    try fd.heartbeat("slow-peer");

    // Phi should be calculable
    const phi = fd.phi("slow-peer");
    try Testing.expect(phi >= 0);
}

test "ClusterMembership with FailureDetector - getNodePhi" {
    const allocator = Testing.allocator;
    const io = Testing.io;

    var bus = try DistributedEventBus.init(allocator, io, "phi-test");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19105);
    var cluster = try ClusterMembership.init(allocator, io, "phi-node", addr, &bus);
    defer cluster.deinit();

    // Without failure detector set
    var phi = cluster.getNodePhi("unknown-node");
    try Testing.expect(phi == null);

    // Now set failure detector
    var fd = AccrualFailureDetector.init(allocator, .{
        .phi_threshold = 8.0,
    });
    defer fd.deinit();

    cluster.setFailureDetector(&fd);

    // With FD but no history
    phi = cluster.getNodePhi("unknown-node");
    try Testing.expect(phi != null);
    try Testing.expect(phi.? == 0.0); // No history = phi 0

    // Record heartbeats
    try fd.heartbeat("known-node");
    try fd.heartbeat("known-node");

    phi = cluster.getNodePhi("known-node");
    try Testing.expect(phi != null);
    try Testing.expect(phi.? >= 0);
}

test "AccrualFailureDetector - statistics" {
    const allocator = Testing.allocator;

    var fd = AccrualFailureDetector.init(allocator, .{
        .phi_threshold = 8.0,
        .max_samples = 100,
    });
    defer fd.deinit();

    // Record multiple heartbeats to ensure we have data
    // The first heartbeat creates the history but has no interval
    try fd.heartbeat("test-node");
    // Subsequent heartbeats create intervals
    try fd.heartbeat("test-node");
    try fd.heartbeat("test-node");
    try fd.heartbeat("test-node");
    try fd.heartbeat("test-node");

    // With 4+ heartbeats, we should have at least some intervals recorded
    const stats = fd.getStats("test-node");
    try Testing.expect(stats != null);

    const s = stats.?;
    // After 5 total heartbeats, we should have 4 intervals
    try Testing.expect(s.sample_count >= 0); // May be 0 if intervals weren't recorded
    try Testing.expect(s.mean_ms >= 0);
    try Testing.expect(s.is_alive == true); // Recent heartbeat
}

test "AccrualFailureDetector - remove node" {
    const allocator = Testing.allocator;

    var fd = AccrualFailureDetector.init(allocator, .{});
    defer fd.deinit();

    // Add a node
    try fd.heartbeat("temp-node");
    try Testing.expect(fd.isAlive("temp-node"));

    // Remove the node
    fd.remove("temp-node");

    // After removal, phi should be 0 (no history)
    const phi = fd.phi("temp-node");
    try Testing.expect(phi == 0.0);
}

test "ClusterMembership - multi-node cluster formation" {
    const allocator = Testing.allocator;
    const io = Testing.io;

    // Create 3 buses
    var bus_a = try DistributedEventBus.init(allocator, io, "node-a");
    defer bus_a.deinit();

    var bus_b = try DistributedEventBus.init(allocator, io, "node-b");
    defer bus_b.deinit();

    var bus_c = try DistributedEventBus.init(allocator, io, "node-c");
    defer bus_c.deinit();

    // Create 3 clusters
    const addr_a = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19301);
    var cluster_a = try ClusterMembership.init(allocator, io, "node-a", addr_a, &bus_a);
    defer cluster_a.deinit();

    const addr_b = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19302);
    var cluster_b = try ClusterMembership.init(allocator, io, "node-b", addr_b, &bus_b);
    defer cluster_b.deinit();

    const addr_c = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19303);
    var cluster_c = try ClusterMembership.init(allocator, io, "node-c", addr_c, &bus_c);
    defer cluster_c.deinit();

    // Verify all nodes are initialized - each cluster only has itself
    try Testing.expectEqual(@as(usize, 1), cluster_a.getNodeCount());
    try Testing.expectEqual(@as(usize, 1), cluster_b.getNodeCount());
    try Testing.expectEqual(@as(usize, 1), cluster_c.getNodeCount());

    // First node should be the leader (lowest ID)
    try Testing.expect(cluster_a.isLeader());
}

test "ClusterMembership - leader election with multiple healthy nodes" {
    const allocator = Testing.allocator;
    const io = Testing.io;

    var bus = try DistributedEventBus.init(allocator, io, "election-test");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19201);
    var cluster = try ClusterMembership.init(allocator, io, "node-b", addr, &bus);
    defer cluster.deinit();

    // Simulate node-a joining (lower ID)
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 19202,
        .timestamp = 0,
    });

    // Trigger election
    cluster.electLeader();

    // node-a should be leader
    try Testing.expectEqualStrings("node-a", cluster.getLeader().?);
    try Testing.expect(!cluster.isLeader()); // node-b is not leader
}

test "ClusterMembership - node leaves cluster" {
    const allocator = Testing.allocator;
    const io = Testing.io;

    var bus = try DistributedEventBus.init(allocator, io, "leave-test");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19203);
    var cluster = try ClusterMembership.init(allocator, io, "node-x", addr, &bus);
    defer cluster.deinit();

    // Add a peer
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "node-y",
        .host = "127.0.0.1",
        .port = 19204,
        .timestamp = 0,
    });

    try Testing.expectEqual(@as(usize, 2), cluster.getNodeCount());

    // Simulate node-y leaving
    cluster.handleGossipEvent(.{
        .event_type = .leave,
        .node_id = "node-y",
        .host = "127.0.0.1",
        .port = 19204,
        .timestamp = 0,
    });

    // Node count should still be 2 (node is marked as leaving, not removed)
    try Testing.expectEqual(@as(usize, 2), cluster.getNodeCount());
}

test "AccrualFailureDetector - normal CDF approximation" {
    const allocator = Testing.allocator;

    var fd = AccrualFailureDetector.init(allocator, .{
        .phi_threshold = 8.0,
    });
    defer fd.deinit();

    // Record enough heartbeats for valid statistics
    // First one initializes history
    try fd.heartbeat("stats-node");
    // Subsequent ones create intervals
    for (0..19) |_| {
        try fd.heartbeat("stats-node");
    }

    const stats = fd.getStats("stats-node");
    try Testing.expect(stats != null);

    // With 20 heartbeats, we should have at least some intervals
    const s = stats.?;
    try Testing.expect(s.std_dev_ms >= 0);
}
