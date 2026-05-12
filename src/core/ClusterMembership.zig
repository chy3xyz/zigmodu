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
    gossip_thread: ?std.Thread,
    health_check_thread: ?std.Thread,
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
            .gossip_thread = null,
            .health_check_thread = null,
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
    }

    pub fn start(self: *Self, config: Config) !void {
        if (self.is_running) return;

        self.gossip_interval_ms = config.gossip_interval_ms;
        self.health_check_interval_ms = config.health_check_interval_ms;
        self.node_timeout_ms = config.node_timeout_ms;
        self.is_running = true;

        // Subscribe to bus events
        try self.bus.subscribe("cluster.membership", handleBusEvent);

        self.gossip_thread = try std.Thread.spawn(.{}, gossipLoop, .{self});
        self.health_check_thread = try std.Thread.spawn(.{}, healthCheckLoop, .{self});

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

        if (self.gossip_thread) |t| {
            t.join();
            self.gossip_thread = null;
        }
        if (self.health_check_thread) |t| {
            t.join();
            self.health_check_thread = null;
        }
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

    fn gossipLoop(self: *Self) void {
        while (self.is_running) {
            // Record our own heartbeat for failure detection
            if (self.failure_detector) |fd| {
                fd.heartbeat(self.node_id) catch |err| {
                    std.log.err("[ClusterMembership] Failed to record heartbeat: {}", .{err});
                };
            }
            self.broadcastEvent(.heartbeat) catch |err| {
                std.log.err("[ClusterMembership] Gossip error: {}", .{err});
            };
            // Note: Blocking sleep unavailable in Zig 0.16.0 sync context
            break; // Exit in sync context
        }
    }

    fn healthCheckLoop(self: *Self) void {
        while (self.is_running) {
            self.checkNodeHealth();
            // Note: Blocking sleep unavailable in Zig 0.16.0 sync context
            break; // Exit in sync context
        }
    }

    fn checkNodeHealth(self: *Self) void {
        const now = Time.monotonicNowSeconds();
        const timeout_secs = @divFloor(self.node_timeout_ms, 1000);

        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr;
            if (std.mem.eql(u8, node.id, self.node_id)) continue; // Robust comparison

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
                            self.electLeaderLocked();
                        }
                    }
                }
            }
        }
    }

    fn broadcastEvent(self: *Self, event_type: EventType) !void {
        // Use a static-sized buffer on stack to avoid heap allocation per broadcast
        var buf: [1024]u8 = undefined;
        
        var addr_buf: [64]u8 = undefined;
        const addr_str = try std.fmt.bufPrint(&addr_buf, "{any}", .{self.address});
        const host = if (std.mem.indexOf(u8, addr_str, ":")) |colon| addr_str[0..colon] else addr_str;

        const payload = try std.fmt.bufPrint(&buf, "{{\"t\":{d},\"id\":\"{s}\",\"h\":\"{s}\",\"p\":{d},\"ts\":{d}}}", .{ 
            @intFromEnum(event_type), 
            self.node_id, 
            host, 
            self.address.ip4.port, 
            Time.monotonicNowSeconds() 
        });

        try self.bus.publish("cluster.membership", payload);
    }

    fn handleBusEvent(event: DistributedEventBus.NetworkEvent) void {
        _ = event;
        // In a real implementation, parse the event and update node state
        // For now, this is a placeholder since DistributedEventBus.subscribe
        // takes a callback but doesn't pass context. In production, you'd use
        // a context pointer or closure pattern.
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
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        self.electLeaderLocked();
    }

    fn electLeaderLocked(self: *Self) void {
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
                self.current_leader = self.allocator.dupe(u8, new_leader) catch return;
                std.log.info("[ClusterMembership] New leader elected: {s}", .{new_leader});

                if (self.on_leader_change_cb) |cb| {
                    cb(self.current_leader);
                }

                // Broadcast leader election if we are the leader
                if (std.mem.eql(u8, new_leader, self.node_id)) {
                    self.broadcastEvent(.leader_election) catch {};
                }
            }
        }
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

test "ClusterMembership initialization" {
    const allocator = std.testing.allocator;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18081);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-1", addr, &bus);
    defer cluster.deinit();

    try std.testing.expectEqual(@as(usize, 1), cluster.getNodeCount());
    try std.testing.expect(cluster.isLeader());
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
        .event_type = .join, .node_id = "n1", .host = "127.0.0.1", .port = 1, .timestamp = 0,
    });
    cluster.handleGossipEvent(.{
        .event_type = .join, .node_id = "n2", .host = "127.0.0.1", .port = 2, .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 3), cluster.getHealthyNodeCount());

    // Node leaves
    cluster.handleGossipEvent(.{
        .event_type = .leave, .node_id = "n1", .host = "127.0.0.1", .port = 1, .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 2), cluster.getHealthyNodeCount());

    // Node rejoins
    cluster.handleGossipEvent(.{
        .event_type = .join, .node_id = "n1", .host = "127.0.0.1", .port = 1, .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 3), cluster.getHealthyNodeCount());
}
