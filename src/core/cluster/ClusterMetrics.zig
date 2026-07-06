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

    /// Export in Prometheus text format.
    pub fn toPrometheus(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator,
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

test "ClusterMetrics toPrometheus" {
    const allocator = std.testing.allocator;
    var m = ClusterMetrics.init(allocator);
    m.setNodeCount(5);

    const out = try m.toPrometheus(allocator);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_cluster_nodes_active 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# HELP") != null);
}
