//! Cluster membership via gossip over DistributedEventBus.
//!
//! Uses `subscribeWithContext` so membership events update this node's table
//! (join / heartbeat / leave / leader_election). Suitable for small clusters
//! (documented guidance: 3–7 nodes) behind an external load balancer.

const std = @import("std");
const Time = @import("Time.zig");
const DistributedEventBus = @import("DistributedEventBus.zig").DistributedEventBus;
const AccrualFailureDetector = @import("cluster/FailureDetector.zig").AccrualFailureDetector;
const ArrayList = std.array_list.Managed;

/// Cluster Membership Service using gossip protocol
/// Tracks node health, handles join/leave events, and performs leader election
pub const ClusterMembership = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    node_id: []const u8,
    address: std.Io.net.IpAddress,
    bus: *DistributedEventBus,
    failure_detector: ?*AccrualFailureDetector = null,
    nodes: std.StringHashMap(ClusterNode),
    is_running: bool,
    on_node_join_cb: ?*const fn ([]const u8, std.Io.net.IpAddress) void,
    on_node_leave_cb: ?*const fn ([]const u8) void,
    on_leader_change_cb: ?*const fn (?[]const u8) void,
    mutex: std.Io.Mutex,
    gossip_interval_ms: u32,
    health_check_interval_ms: u32,
    node_timeout_ms: u32,
    current_leader: ?[]const u8,

    pub const ClusterNode = struct {
        id: []const u8,
        address: std.Io.net.IpAddress,
        state: NodeState,
        last_seen: i64,
        joined_at: i64,
    };

    pub const NodeState = enum {
        healthy,
        suspect,
        failed,
        leaving,
    };

    pub const GossipEvent = struct {
        event_type: EventType,
        node_id: []const u8,
        host: []const u8,
        port: u16,
        timestamp: i64,
    };

    pub const EventType = enum(u8) {
        join = 1,
        heartbeat = 2,
        suspect = 3,
        leave = 4,
        leader_election = 5,
    };

    pub const Config = struct {
        gossip_interval_ms: u32 = 1000,
        health_check_interval_ms: u32 = 3000,
        node_timeout_ms: u32 = 10000,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, node_id: []const u8, address: std.Io.net.IpAddress, bus: *DistributedEventBus) !Self {
        const id_copy = try allocator.dupe(u8, node_id);
        errdefer allocator.free(id_copy);

        var nodes = std.StringHashMap(ClusterNode).init(allocator);

        // Add self to cluster
        try nodes.put(id_copy, .{
            .id = id_copy,
            .address = address,
            .state = .healthy,
            .last_seen = 0,
            .joined_at = 0,
        });

        return .{
            .allocator = allocator,
            .io = io,
            .node_id = id_copy,
            .address = address,
            .bus = bus,
            .failure_detector = null,
            .nodes = nodes,
            .is_running = false,
            .on_node_join_cb = null,
            .on_node_leave_cb = null,
            .on_leader_change_cb = null,
            .mutex = std.Io.Mutex.init,
            .gossip_interval_ms = 1000,
            .health_check_interval_ms = 3000,
            .node_timeout_ms = 10000,
            .current_leader = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        if (self.current_leader) |leader| {
            self.allocator.free(leader);
        }

        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, self.node_id)) {
                self.allocator.free(entry.value_ptr.id);
            }
        }
        self.nodes.deinit();
        self.allocator.free(self.node_id);
        self.* = undefined;
    }

    /// Start membership: subscribe to gossip and announce join.
    /// Drive periodic heartbeat/health via `runOnce()` (Zig 0.17 Io has no
    /// blocking sleep; do not spawn OS threads with `std.Io.Mutex`).
    pub fn start(self: *Self, config: Config) !void {
        if (self.is_running) return;

        self.gossip_interval_ms = config.gossip_interval_ms;
        self.health_check_interval_ms = config.health_check_interval_ms;
        self.node_timeout_ms = config.node_timeout_ms;
        self.is_running = true;

        // Subscribe with context so gossip events mutate this instance.
        try self.bus.subscribeWithContext("cluster.membership", @ptrCast(self), onBusEvent);

        // Announce join
        self.broadcastEvent(.join) catch |err| {
            std.log.err("[ClusterMembership] Failed to broadcast join: {}", .{err});
        };

        // Initial leader election (self is leader if no other nodes)
        self.electLeader();

        std.log.info("[ClusterMembership] Node {s} joined cluster at {any}", .{ self.node_id, self.address });
    }

    pub fn stop(self: *Self) void {
        if (!self.is_running) return;

        self.is_running = false;

        // Broadcast leave
        self.broadcastEvent(.leave) catch {};
        self.bus.unsubscribeContext("cluster.membership", @ptrCast(self));
    }

    /// Run a single synchronous gossip + health check pass.
    /// Useful for testing and for driving the membership loop externally.
    pub fn runOnce(self: *Self) !void {
        // Record heartbeat
        if (self.failure_detector) |fd| {
            fd.heartbeat(self.node_id) catch |err| {
                std.log.err("[ClusterMembership] Failed to record heartbeat: {}", .{err});
            };
        }
        self.broadcastEvent(.heartbeat) catch |err| {
            std.log.err("[ClusterMembership] Gossip error: {}", .{err});
        };
        self.checkNodeHealth();
    }

    fn checkNodeHealth(self: *Self) void {
        const now = Time.monotonicNowSeconds();
        const timeout_secs = @divFloor(self.node_timeout_ms, 1000);
        var should_broadcast_leader = false;

        self.mutex.lock(self.io) catch return;
        {
            defer self.mutex.unlock(self.io);

            var iter = self.nodes.iterator();
            while (iter.next()) |entry| {
                const node = entry.value_ptr;
                if (std.mem.eql(u8, node.id, self.node_id)) continue;

                const elapsed = now - node.last_seen;
                if (node.state == .healthy) {
                    const is_alive = if (self.failure_detector) |fd| fd.isAlive(node.id) else (elapsed <= timeout_secs);
                    if (!is_alive) {
                        node.state = .suspect;
                        std.log.warn("[Cluster] Node {s} suspect", .{node.id});
                    }
                } else if (node.state == .suspect) {
                    const is_dead = if (self.failure_detector) |fd| !fd.isAlive(node.id) else (elapsed > timeout_secs * 2);
                    if (is_dead) {
                        node.state = .failed;
                        if (self.on_node_leave_cb) |cb| cb(node.id);

                        if (self.current_leader) |leader| {
                            if (std.mem.eql(u8, leader, node.id)) {
                                self.allocator.free(leader);
                                self.current_leader = null;
                                should_broadcast_leader = self.electLeaderLocked();
                            }
                        }
                    }
                }
            }
        }

        // Never broadcast while holding mutex — publish invokes onBusEvent → handleGossipEvent.
        if (should_broadcast_leader) {
            self.broadcastEvent(.leader_election) catch {};
        }
    }

    fn broadcastEvent(self: *Self, event_type: EventType) !void {
        // Use a static-sized buffer on stack to avoid heap allocation per broadcast
        var buf: [1024]u8 = undefined;

        var addr_buf: [64]u8 = undefined;
        const addr_str = try std.fmt.bufPrint(&addr_buf, "{any}", .{self.address});
        const host = if (std.mem.indexOf(u8, addr_str, ":")) |colon| addr_str[0..colon] else addr_str;

        const payload = try std.fmt.bufPrint(&buf, "{{\"t\":{d},\"id\":\"{s}\",\"h\":\"{s}\",\"p\":{d},\"ts\":{d}}}", .{ @intFromEnum(event_type), self.node_id, host, self.address.ip4.port, Time.monotonicNowSeconds() });

        try self.bus.publish("cluster.membership", payload);
    }

    fn onBusEvent(ctx: *anyopaque, event: DistributedEventBus.NetworkEvent) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const gossip = parseGossipPayload(event.payload) orelse {
            std.log.warn("[ClusterMembership] Ignoring malformed gossip payload from {s}", .{event.source_node});
            return;
        };
        self.handleGossipEvent(gossip);
    }

    fn parseGossipPayload(payload: []const u8) ?GossipEvent {
        // Payload format from broadcastEvent:
        // {"t":N,"id":"...","h":"...","p":N,"ts":N}
        const t = extractJsonInt(payload, "t") orelse return null;
        const id = extractJsonString(payload, "id") orelse return null;
        const host = extractJsonString(payload, "h") orelse return null;
        const port_i = extractJsonInt(payload, "p") orelse return null;
        const ts = extractJsonInt(payload, "ts") orelse return null;
        if (t < 1 or t > 5) return null;
        return .{
            .event_type = @enumFromInt(@as(u8, @intCast(t))),
            .node_id = id,
            .host = host,
            .port = @intCast(port_i),
            .timestamp = ts,
        };
    }

    fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
        var key_buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&key_buf, "\"{s}\":\"", .{key}) catch return null;
        const pos = std.mem.indexOf(u8, json, needle) orelse return null;
        const val_start = pos + needle.len;
        const val_end = std.mem.indexOfScalarPos(u8, json, val_start, '"') orelse return null;
        return json[val_start..val_end];
    }

    fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
        var key_buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
        const pos = std.mem.indexOf(u8, json, needle) orelse return null;
        var i = pos + needle.len;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
        var end = i;
        if (end < json.len and json[end] == '-') end += 1;
        while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
        if (end == i) return null;
        return std.fmt.parseInt(i64, json[i..end], 10) catch null;
    }

    pub fn handleGossipEvent(self: *Self, event: GossipEvent) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        if (std.mem.eql(u8, event.node_id, self.node_id)) return;

        const now = Time.monotonicNowSeconds();
        const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = event.port } };

        // Record heartbeat in failure detector if available
        if (self.failure_detector) |fd| {
            fd.heartbeat(event.node_id) catch {};
        }

        if (self.nodes.getPtr(event.node_id)) |node| {
            node.last_seen = now;
            if (node.state == .suspect or node.state == .failed or node.state == .leaving) {
                node.state = .healthy;
                std.log.info("[ClusterMembership] Node {s} is back healthy", .{event.node_id});
            }
        } else {
            const id_copy = self.allocator.dupe(u8, event.node_id) catch return;
            self.nodes.put(id_copy, .{
                .id = id_copy,
                .address = addr,
                .state = .healthy,
                .last_seen = now,
                .joined_at = now,
            }) catch {
                self.allocator.free(id_copy);
                return;
            };

            std.log.info("[ClusterMembership] Node {s} joined at {s}:{d}", .{ event.node_id, event.host, event.port });
            if (self.on_node_join_cb) |cb| {
                cb(event.node_id, addr);
            }
        }

        if (event.event_type == .leave) {
            if (self.nodes.getPtr(event.node_id)) |node| {
                node.state = .leaving;
            }
            if (self.on_node_leave_cb) |cb| {
                cb(event.node_id);
            }
        }

        if (event.event_type == .leader_election) {
            if (self.current_leader) |leader| {
                self.allocator.free(leader);
            }
            self.current_leader = self.allocator.dupe(u8, event.node_id) catch return;
            if (self.on_leader_change_cb) |cb| {
                cb(self.current_leader);
            }
        }
    }

    pub fn connectToSeed(self: *Self, node_id: []const u8, address: std.Io.net.IpAddress) !void {
        try self.bus.connectToNode(node_id, address);
        std.log.info("[ClusterMembership] Connected to seed node {s} at {any}", .{ node_id, address });
    }

    pub fn getNodeCount(self: *Self) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.nodes.count();
    }

    pub fn getHealthyNodeCount(self: *Self) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);

        var count: usize = 0;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.state == .healthy) {
                count += 1;
            }
        }
        return count;
    }

    pub fn getLeader(self: *Self) ?[]const u8 {
        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);
        return self.current_leader;
    }

    pub fn isLeader(self: *Self) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        if (self.current_leader) |leader| {
            return std.mem.eql(u8, leader, self.node_id);
        }
        // If no leader elected yet and we're the only node, we're leader
        return self.nodes.count() == 1;
    }

    pub fn electLeader(self: *Self) void {
        const should_broadcast = blk: {
            self.mutex.lock(self.io) catch return;
            defer self.mutex.unlock(self.io);
            break :blk self.electLeaderLocked();
        };
        // broadcastEvent → publish → onBusEvent → handleGossipEvent locks mutex;
        // Io.Mutex is not recursive — broadcast only after unlock.
        if (should_broadcast) {
            self.broadcastEvent(.leader_election) catch {};
        }
    }

    /// Update current_leader under lock. Returns true if caller should broadcast
    /// `.leader_election` (this node is the new leader).
    fn electLeaderLocked(self: *Self) bool {
        // Simple leader election: lowest node_id wins
        var leader_id: ?[]const u8 = null;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr;
            if (node.state != .healthy and node.state != .suspect) continue;
            if (leader_id == null or std.mem.lessThan(u8, node.id, leader_id.?)) {
                leader_id = node.id;
            }
        }

        if (leader_id) |new_leader| {
            if (self.current_leader == null or !std.mem.eql(u8, self.current_leader.?, new_leader)) {
                if (self.current_leader) |old| {
                    self.allocator.free(old);
                }
                self.current_leader = self.allocator.dupe(u8, new_leader) catch return false;
                std.log.info("[ClusterMembership] New leader elected: {s}", .{new_leader});

                if (self.on_leader_change_cb) |cb| {
                    cb(self.current_leader);
                }

                return std.mem.eql(u8, new_leader, self.node_id);
            }
        }
        return false;
    }

    /// Set the failure detector for advanced health checking
    /// Must be called before start() for best results
    pub fn setFailureDetector(self: *Self, fd: *AccrualFailureDetector) void {
        self.failure_detector = fd;
    }

    /// Get phi value for a node (requires failure detector)
    pub fn getNodePhi(self: *Self, node_id: []const u8) ?f64 {
        if (self.failure_detector) |fd| {
            return fd.phi(node_id);
        }
        return null;
    }

    pub fn onNodeJoin(self: *Self, callback: *const fn ([]const u8, std.Io.net.IpAddress) void) void {
        self.on_node_join_cb = callback;
    }

    pub fn onNodeLeave(self: *Self, callback: *const fn ([]const u8) void) void {
        self.on_node_leave_cb = callback;
    }

    pub fn onLeaderChange(self: *Self, callback: *const fn (?[]const u8) void) void {
        self.on_leader_change_cb = callback;
    }
};

// ========================================
// Tests
// ========================================

test "ClusterMembership bus gossip converges via subscribeWithContext" {
    const allocator = std.testing.allocator;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "bus-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19001);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-local", addr, &bus);
    defer cluster.deinit();

    try cluster.start(.{});
    defer cluster.stop();

    // Simulate remote gossip arriving through the bus (same path as network receive).
    try bus.publish("cluster.membership", "{\"t\":1,\"id\":\"node-remote\",\"h\":\"127.0.0.1\",\"p\":19002,\"ts\":1}");

    try std.testing.expect(cluster.getNodeCount() >= 2);
    try std.testing.expect(cluster.nodes.contains("node-remote"));
}

test "ClusterMembership leader election" {
    const allocator = std.testing.allocator;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18082);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-b", addr, &bus);
    defer cluster.deinit();

    // Simulate node-a joining (lower id should win)
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18083,
        .timestamp = 0,
    });

    cluster.electLeader();

    try std.testing.expectEqualStrings("node-a", cluster.getLeader().?);
    try std.testing.expect(!cluster.isLeader());
}

test "ClusterMembership node health tracking" {
    const allocator = std.testing.allocator;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18084);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-1", addr, &bus);
    defer cluster.deinit();

    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "node-2",
        .host = "127.0.0.1",
        .port = 18085,
        .timestamp = 0,
    });

    try std.testing.expectEqual(@as(usize, 2), cluster.getHealthyNodeCount());
}

test "ClusterMembership node leave and rejoin" {
    const allocator = std.testing.allocator;
    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-bus");
    defer bus.deinit();
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18090);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "test-3", addr, &bus);
    defer cluster.deinit();

    // Add 2 nodes
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "n1",
        .host = "127.0.0.1",
        .port = 1,
        .timestamp = 0,
    });
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "n2",
        .host = "127.0.0.1",
        .port = 2,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 3), cluster.getHealthyNodeCount());

    // Node leaves
    cluster.handleGossipEvent(.{
        .event_type = .leave,
        .node_id = "n1",
        .host = "127.0.0.1",
        .port = 1,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 2), cluster.getHealthyNodeCount());

    // Node rejoins
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "n1",
        .host = "127.0.0.1",
        .port = 1,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 3), cluster.getHealthyNodeCount());
}
