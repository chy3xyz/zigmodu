// ⚠️ EXPERIMENTAL: This module is incomplete and not production-ready.
// PasRaft Consensus Adapter for ZigModu
// Provides integration between ZigModu's module system and PasRaft consensus algorithm
// for cluster-wide coordination and state management
// Provides integration between ZigModu's module system and PasRaft consensus algorithm
// for cluster-wide coordination and state management

const std = @import("std");
const Allocator = std.mem.Allocator;
const DistributedEventBus = @import("core/DistributedEventBus.zig").DistributedEventBus;
const ClusterMembership = @import("core/ClusterMembership.zig").ClusterMembership;

pub const PasRaftAdapter = struct {
    const Self = @This();

    allocator: Allocator,
    cluster: *ClusterMembership,
    bus: *DistributedEventBus,
    module_states: std.StringHashMap(ModuleState),
    log_index: u64 = 0,
    commit_index: u64 = 0,
    last_applied: u64 = 0,

    pub const ModuleState = enum {
        active,
        pending,
        failed,
        removed,
    };

    pub const LogEntry = struct {
        term: u64,
        index: u64,
        command: []const u8, // Serialized module operation
        timestamp: i64,
    };

    pub const Config = struct {
        heartbeat_interval_ms: u32 = 100,
        election_timeout_ms: u32 = 500,
        replication_batch_size: usize = 10,
    };

    pub fn init(
        allocator: Allocator,
        cluster: *ClusterMembership,
        bus: *DistributedEventBus,
        config: Config,
    ) !Self {
        _ = config; // Currently unused, reserved for future configuration
        return .{
            .allocator = allocator,
            .cluster = cluster,
            .bus = bus,
            .module_states = std.StringHashMap(ModuleState){},
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.module_states.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.module_states.deinit();
    }

    /// Propose a module operation to the cluster via consensus
    pub fn proposeModuleOperation(
        self: *Self,
        module_name: []const u8,
        operation: []const u8, // JSON-serialized operation
    ) !void {
        _ = module_name; // For future use
        const entry = LogEntry{
            .term = 1, // Current term (simplified)
            .index = self.log_index + 1,
            .command = try self.allocator.dupe(u8, operation),
            .timestamp = 0,
        };
        defer self.allocator.free(entry.command);

        // Replicate to cluster nodes
        try self.replicateLogEntry(entry);

        // Apply locally once majority replicated
        self.log_index += 1;
        try self.applyLogEntry(entry);
    }

    fn replicateLogEntry(self: *Self, entry: LogEntry) !void {
        const message = try std.fmt.allocPrint(
            self.allocator,
            "{{\"type\":\"raft_log\",\"term\":{d},\"index\":{d},\"command\":\"{s}\",\"ts\":{d}}}",
            .{ entry.term, entry.index, entry.command, entry.timestamp },
        );
        defer self.allocator.free(message);

        try self.bus.publish("raft.log", message);
    }

    fn applyLogEntry(self: *Self, entry: LogEntry) !void {
        // Parse and execute the module operation
        // This would integrate with ZigModu's module lifecycle management
        self.last_applied = entry.index;
        try self.module_states.put(
            try self.allocator.dupe(u8, std.fmt.allocPrint(
                self.allocator,
                "module_op_{d}",
                .{entry.index},
            )),
            .active,
        );
    }

    /// Get current cluster membership status for consensus
    pub fn getClusterStatus(self: *Self) ![]const u8 {
        var status = std.ArrayList(u8).empty;
        defer status.deinit();

        const writer = status.writer();
        try writer.print("{{\"node_id\":\"{s}\",\"term\":{d},\"log_index\":{d},\"commit_index\":{d}}}", .{
            self.cluster.node_id,
            1, // current term
            self.log_index,
            self.commit_index,
        });

        return status.toOwnedSlice();
    }
};

test "PasRaftAdapter initialization" {
    const allocator = std.testing.allocator;
    var bus = DistributedEventBus.init(allocator);
    defer bus.deinit();

    var cluster = try ClusterMembership.init(allocator, "node-1", try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18081), &bus);
    defer cluster.deinit();

    var adapter = try PasRaftAdapter.init(allocator, &cluster, &bus, .{});
    defer adapter.deinit();

    try std.testing.expectEqual(@as(usize, 0), adapter.module_states.count());
}

test "PasRaftAdapter propose operation" {
    const allocator = std.testing.allocator;
    var bus = DistributedEventBus.init(allocator);
    defer bus.deinit();

    var cluster = try ClusterMembership.init(allocator, "node-1", try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18081), &bus);
    defer cluster.deinit();

    var adapter = try PasRaftAdapter.init(allocator, &cluster, &bus, .{});
    defer adapter.deinit();

    try adapter.proposeModuleOperation("order", "{\"action\":\"create\",\"name\":\"test\"}");
    try std.testing.expectEqual(@as(u64, 1), adapter.log_index);
}

test "PasRaftAdapter cluster status" {
    const allocator = std.testing.allocator;
    var bus = DistributedEventBus.init(allocator);
    defer bus.deinit();

    var cluster = try ClusterMembership.init(allocator, "node-1", try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18081), &bus);
    defer cluster.deinit();

    var adapter = try PasRaftAdapter.init(allocator, &cluster, &bus, .{});
    defer adapter.deinit();

    const status = try adapter.getClusterStatus();
    defer allocator.free(status);
    try std.testing.expect(std.mem.containsAtLeast(u8, status, 1, "node_id"));
}
