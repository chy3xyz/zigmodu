//! Cluster-wide metrics for multi-node deployments.
//!
//! Exposes node count, message rates, and partition distribution
//! as Prometheus-compatible gauges and counters.

const std = @import("std");

pub const ClusterMetrics = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    node_count: std.atomic.Value(u64),
    leader_epoch: std.atomic.Value(u64),
    messages_sent: std.atomic.Value(u64),
    messages_received: std.atomic.Value(u64),
    messages_failed: std.atomic.Value(u64),
    bytes_sent: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),
    partition_count: std.atomic.Value(u64),
    /// Inbound frames dropped on MAC verification failure, across both cluster
    /// planes (Raft port and event bus). A rising counter is the telltale of a
    /// key mismatch, a revoked peer still sending, or forgery attempts — before
    /// this it was a `log.debug` nobody saw.
    auth_failures: std.atomic.Value(u64),
    /// §7: local log compactions completed (`maybeCompactLog`), InstallSnapshot
    /// chunks sent to peers, and InstallSnapshot chunks received from a leader.
    snapshots_compacted: std.atomic.Value(u64),
    snapshots_sent: std.atomic.Value(u64),
    snapshots_received: std.atomic.Value(u64),

    pub fn init(_: std.mem.Allocator) Self {
        return .{
            .allocator = undefined,
            .node_count = std.atomic.Value(u64).init(0),
            .leader_epoch = std.atomic.Value(u64).init(0),
            .messages_sent = std.atomic.Value(u64).init(0),
            .messages_received = std.atomic.Value(u64).init(0),
            .messages_failed = std.atomic.Value(u64).init(0),
            .bytes_sent = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
            .partition_count = std.atomic.Value(u64).init(0),
            .auth_failures = std.atomic.Value(u64).init(0),
            .snapshots_compacted = std.atomic.Value(u64).init(0),
            .snapshots_sent = std.atomic.Value(u64).init(0),
            .snapshots_received = std.atomic.Value(u64).init(0),
        };
    }

    pub fn setNodeCount(self: *Self, n: u64) void {
        self.node_count.store(n, .monotonic);
    }
    pub fn incMessagesSent(self: *Self, bytes: u64) void {
        _ = self.messages_sent.fetchAdd(1, .monotonic);
        _ = self.bytes_sent.fetchAdd(bytes, .monotonic);
    }
    pub fn incMessagesReceived(self: *Self, bytes: u64) void {
        _ = self.messages_received.fetchAdd(1, .monotonic);
        _ = self.bytes_received.fetchAdd(bytes, .monotonic);
    }
    pub fn incMessagesFailed(self: *Self) void {
        _ = self.messages_failed.fetchAdd(1, .monotonic);
    }
    pub fn setLeaderEpoch(self: *Self, epoch: u64) void {
        self.leader_epoch.store(epoch, .monotonic);
    }
    pub fn setPartitionCount(self: *Self, n: u64) void {
        self.partition_count.store(n, .monotonic);
    }
    pub fn incAuthFailures(self: *Self) void {
        _ = self.auth_failures.fetchAdd(1, .monotonic);
    }
    pub fn incSnapshotsCompacted(self: *Self) void {
        _ = self.snapshots_compacted.fetchAdd(1, .monotonic);
    }
    pub fn incSnapshotsSent(self: *Self) void {
        _ = self.snapshots_sent.fetchAdd(1, .monotonic);
    }
    pub fn incSnapshotsReceived(self: *Self) void {
        _ = self.snapshots_received.fetchAdd(1, .monotonic);
    }

    /// Export in Prometheus text format.
    pub fn toPrometheus(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        return allocator.print(
            \\# HELP zigmodu_cluster_nodes_active Number of active cluster nodes
            \\# TYPE zigmodu_cluster_nodes_active gauge
            \\zigmodu_cluster_nodes_active {d}
            \\# HELP zigmodu_cluster_leader_epoch Current leader election term
            \\# TYPE zigmodu_cluster_leader_epoch counter
            \\zigmodu_cluster_leader_epoch {d}
            \\# HELP zigmodu_cluster_messages_sent_total Total cluster messages sent
            \\# TYPE zigmodu_cluster_messages_sent_total counter
            \\zigmodu_cluster_messages_sent_total {d}
            \\# HELP zigmodu_cluster_messages_received_total Total cluster messages received
            \\# TYPE zigmodu_cluster_messages_received_total counter
            \\zigmodu_cluster_messages_received_total {d}
            \\# HELP zigmodu_cluster_messages_failed_total Failed cluster message deliveries
            \\# TYPE zigmodu_cluster_messages_failed_total counter
            \\zigmodu_cluster_messages_failed_total {d}
            \\# HELP zigmodu_cluster_bytes_sent_total Total bytes sent over cluster transport
            \\# TYPE zigmodu_cluster_bytes_sent_total counter
            \\zigmodu_cluster_bytes_sent_total {d}
            \\# HELP zigmodu_cluster_bytes_received_total Total bytes received over cluster transport
            \\# TYPE zigmodu_cluster_bytes_received_total counter
            \\zigmodu_cluster_bytes_received_total {d}
            \\# HELP zigmodu_cluster_partitions Number of consistent hash partitions
            \\# TYPE zigmodu_cluster_partitions gauge
            \\zigmodu_cluster_partitions {d}
            \\# HELP zigmodu_cluster_auth_failures_total Inbound cluster frames dropped on MAC verification failure (Raft port + event bus)
            \\# TYPE zigmodu_cluster_auth_failures_total counter
            \\zigmodu_cluster_auth_failures_total {d}
            \\# HELP zigmodu_cluster_snapshots_compacted_total Raft log compactions completed on this node
            \\# TYPE zigmodu_cluster_snapshots_compacted_total counter
            \\zigmodu_cluster_snapshots_compacted_total {d}
            \\# HELP zigmodu_cluster_snapshots_sent_total Raft InstallSnapshot chunks this node sent to peers
            \\# TYPE zigmodu_cluster_snapshots_sent_total counter
            \\zigmodu_cluster_snapshots_sent_total {d}
            \\# HELP zigmodu_cluster_snapshots_received_total Raft InstallSnapshot chunks this node received from a leader
            \\# TYPE zigmodu_cluster_snapshots_received_total counter
            \\zigmodu_cluster_snapshots_received_total {d}
            \\
        , .{
            self.node_count.load(.monotonic),
            self.leader_epoch.load(.monotonic),
            self.messages_sent.load(.monotonic),
            self.messages_received.load(.monotonic),
            self.messages_failed.load(.monotonic),
            self.bytes_sent.load(.monotonic),
            self.bytes_received.load(.monotonic),
            self.partition_count.load(.monotonic),
            self.auth_failures.load(.monotonic),
            self.snapshots_compacted.load(.monotonic),
            self.snapshots_sent.load(.monotonic),
            self.snapshots_received.load(.monotonic),
        });
    }
};

test "ClusterMetrics counters" {
    const allocator = std.testing.allocator;
    var m = ClusterMetrics.init(allocator);

    m.setNodeCount(3);
    m.incMessagesSent(100);
    m.incMessagesReceived(200);
    m.incMessagesFailed();
    m.setLeaderEpoch(5);

    try std.testing.expectEqual(@as(u64, 3), m.node_count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.messages_sent.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.messages_received.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.messages_failed.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 100), m.bytes_sent.load(.monotonic));
}

test "ClusterMetrics auth failure and snapshot counters" {
    const allocator = std.testing.allocator;
    var m = ClusterMetrics.init(allocator);

    m.incAuthFailures();
    m.incAuthFailures();
    m.incSnapshotsCompacted();
    m.incSnapshotsSent();
    m.incSnapshotsReceived();
    m.incSnapshotsReceived();

    try std.testing.expectEqual(@as(u64, 2), m.auth_failures.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.snapshots_compacted.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.snapshots_sent.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), m.snapshots_received.load(.monotonic));

    const out = try m.toPrometheus(allocator);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_cluster_auth_failures_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_cluster_snapshots_compacted_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_cluster_snapshots_sent_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_cluster_snapshots_received_total 2") != null);
}

test "ClusterMetrics toPrometheus" {
    const allocator = std.testing.allocator;
    var m = ClusterMetrics.init(allocator);
    m.setNodeCount(5);

    const out = try m.toPrometheus(allocator);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_cluster_nodes_active 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# HELP") != null);
}
