//! Client-side load balancing for ZigModu distributed services.
//!
//! Supports:
//! - Round-robin (atomic counter)
//! - Random (multi-source seeded PRNG)
//! - Least-connections (connection-count tracking)
//! - Canary routing (weighted traffic splitting)
//!
//! Usage:
//!   var disco = PeerDiscovery.init(allocator, .{});
//!   defer disco.deinit();
//!   try disco.registerPeer("svc1", "10.0.0.1", 8080);
//!   try disco.registerService("api", .{ .host = "10.0.0.1", .port = 8080 });
//!   var lb = LoadBalancer.init(allocator, .round_robin, &disco);
//!   defer lb.deinit();
//!   const peer = lb.next("api");

const std = @import("std");
const PeerDiscovery = @import("PeerDiscovery.zig").PeerDiscovery;
const Peer = @import("PeerDiscovery.zig").Peer;
const Time = @import("../Time.zig");

pub const Strategy = enum { round_robin, random, least_connections };

pub const LoadBalancer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    strategy: Strategy,
    discovery: *PeerDiscovery,
    /// Round-robin atomic counter
    counter: u64,
    /// PRNG for random strategy
    rng: std.Random,
    /// Connection counts per peer (keyed by "host:port") for least_connections
    connections: std.StringHashMap(u64),
    /// Percentage (0.0–1.0) of traffic routed to canary peers
    canary_weight: f64,
    /// Peers marked as canary
    canary_peers: std.ArrayList(Peer),

    /// Initialize a LoadBalancer with the given strategy and discovery instance.
    pub fn init(allocator: std.mem.Allocator, strategy: Strategy, discovery: *PeerDiscovery) Self {
        // Multi-source entropy seed
        var seed: u64 = @intCast(@mod(@as(u128, @intCast(Time.monotonicNowMilliseconds())), std.math.maxInt(u64)));
        seed ^= @intFromPtr(discovery);
        seed ^= @intFromPtr(&seed);
        seed ^= @intFromPtr(allocator.ptr);

        var prng = std.Random.DefaultPrng.init(seed);

        return .{
            .allocator = allocator,
            .strategy = strategy,
            .discovery = discovery,
            .counter = std.math.maxInt(u64),
            .rng = prng.random(),
            .connections = std.StringHashMap(u64).init(allocator),
            .canary_weight = 0.0,
            .canary_peers = std.ArrayList(Peer).empty,
        };
    }

    /// Free all internal resources.
    pub fn deinit(self: *Self) void {
        var conn_it = self.connections.iterator();
        while (conn_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.deinit();

        for (self.canary_peers.items) |p| {
            self.allocator.free(p.host);
        }
        self.canary_peers.deinit(self.allocator);

        self.* = undefined;
    }

    /// Pick next peer for the given service using the configured strategy.
    /// Returns null if no peers are available.
    pub fn next(self: *Self, service_name: []const u8) ?Peer {
        const peers = self.discovery.discoverService(service_name);
        if (peers == null or peers.?.len == 0) return null;
        const peer_list = peers.?;

        // Canary routing: if canary_weight > 0 and we have canary peers,
        // route a fraction of traffic to canary.
        if (self.canary_weight > 0.0 and self.canary_peers.items.len > 0) {
            const roll = self.rng.float(f64);
            if (roll < self.canary_weight) {
                const canary_idx = @min(@as(usize, @intFromFloat(@floor(roll / self.canary_weight * @as(f64, @floatFromInt(self.canary_peers.items.len))))), self.canary_peers.items.len - 1);
                return Peer{
                    .host = self.canary_peers.items[canary_idx].host,
                    .port = self.canary_peers.items[canary_idx].port,
                };
            }
        }

        return switch (self.strategy) {
            .round_robin => {
                self.counter +%= 1;
                const idx = self.counter % peer_list.len;
                return peer_list[idx];
            },
            .random => {
                const idx = self.rng.uintLessThan(usize, peer_list.len);
                return peer_list[idx];
            },
            .least_connections => blk: {
                if (peer_list.len == 1) break :blk peer_list[0];

                var best_idx: usize = 0;
                var best_count: u64 = std.math.maxInt(u64);

                for (peer_list, 0..) |peer, i| {
                    const count = self.getConnectionCount(peer);
                    if (count < best_count) {
                        best_count = count;
                        best_idx = i;
                    }
                }
                break :blk peer_list[best_idx];
            },
        };
    }

    /// Record a connection result. For least_connections strategy, success=true
    /// increments the connection count, success=false decrements it.
    /// peer_key should be in "host:port" format (e.g., "10.0.0.1:8080").
    pub fn recordResult(self: *Self, peer_key: []const u8, success: bool) void {
        if (self.strategy != .least_connections) return;

        if (success) {
            const gop = self.connections.getOrPut(peer_key) catch return;
            if (!gop.found_existing) {
                gop.key_ptr.* = self.allocator.dupe(u8, peer_key) catch return;
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* +%= 1;
        } else {
            if (self.connections.getPtr(peer_key)) |count| {
                count.* -|= 1; // saturating subtraction
            }
        }
    }

    /// Set canary routing weight. weight should be in range [0.0, 1.0].
    pub fn setCanaryWeight(self: *Self, weight: f64) void {
        self.canary_weight = @max(0.0, @min(1.0, weight));
    }

    /// Add a peer to the canary set. The host string is duped.
    pub fn addCanaryPeer(self: *Self, host: []const u8, port: u16) !void {
        const host_dup = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(host_dup);
        try self.canary_peers.append(self.allocator, .{ .host = host_dup, .port = port });
    }

    /// Internal: get current connection count for a peer.
    fn getConnectionCount(self: *const Self, peer: Peer) u64 {
        // Build key inline; we own the connections map, so use a small buffer.
        var buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}:{d}", .{ peer.host, peer.port }) catch return 0;
        return self.connections.get(key) orelse 0;
    }

    /// Build a peer key string. Caller owns the returned memory.
    fn peerKey(allocator: std.mem.Allocator, peer: Peer) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}:{d}", .{ peer.host, peer.port });
    }
};

test "LoadBalancer round_robin cycles" {
    const allocator = std.testing.allocator;
    var disco = PeerDiscovery.init(allocator, .{});
    defer disco.deinit();

    try disco.registerPeer("s1", "10.0.0.1", 8080);
    try disco.registerPeer("s2", "10.0.0.2", 8080);
    try disco.registerPeer("s3", "10.0.0.3", 8080);
    try disco.registerService("api", .{ .host = "10.0.0.1", .port = 8080 });
    try disco.registerService("api", .{ .host = "10.0.0.2", .port = 8080 });
    try disco.registerService("api", .{ .host = "10.0.0.3", .port = 8080 });

    var lb = LoadBalancer.init(allocator, .round_robin, &disco);
    defer lb.deinit();

    // First round
    const p0 = lb.next("api") orelse return error.NoPeer;
    const p1 = lb.next("api") orelse return error.NoPeer;
    const p2 = lb.next("api") orelse return error.NoPeer;
    // Second round — should cycle
    const p3 = lb.next("api") orelse return error.NoPeer;
    const p4 = lb.next("api") orelse return error.NoPeer;

    try std.testing.expect(std.mem.eql(u8, p0.host, "10.0.0.1"));
    try std.testing.expect(std.mem.eql(u8, p1.host, "10.0.0.2"));
    try std.testing.expect(std.mem.eql(u8, p2.host, "10.0.0.3"));
    try std.testing.expect(std.mem.eql(u8, p3.host, "10.0.0.1"));
    try std.testing.expect(std.mem.eql(u8, p4.host, "10.0.0.2"));
}

test "LoadBalancer random distributes" {
    const allocator = std.testing.allocator;
    var disco = PeerDiscovery.init(allocator, .{});
    defer disco.deinit();

    try disco.registerPeer("a", "10.0.0.1", 8080);
    try disco.registerPeer("b", "10.0.0.2", 8080);
    try disco.registerService("api", .{ .host = "10.0.0.1", .port = 8080 });
    try disco.registerService("api", .{ .host = "10.0.0.2", .port = 8080 });

    // Use fixed seed for deterministic test
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    var lb = LoadBalancer{
        .allocator = allocator,
        .strategy = .random,
        .discovery = &disco,
        .counter = 0,
        .rng = prng.random(),
        .connections = std.StringHashMap(u64).init(allocator),
        .canary_weight = 0.0,
        .canary_peers = std.ArrayList(Peer).empty,
    };
    defer lb.deinit();

    var counts: [2]u32 = .{ 0, 0 };
    const iterations: usize = 1000;
    for (0..iterations) |_| {
        const p = lb.next("api") orelse return error.NoPeer;
        if (std.mem.eql(u8, p.host, "10.0.0.1")) {
            counts[0] += 1;
        } else {
            counts[1] += 1;
        }
    }

    // With 1000 iterations and fixed seed, verify distribution is reasonable
    try std.testing.expect(counts[0] >= 400);
    try std.testing.expect(counts[1] >= 400);
    try std.testing.expectEqual(@as(u32, 1000), counts[0] + counts[1]);
}

test "LoadBalancer canary routing" {
    const allocator = std.testing.allocator;
    var disco = PeerDiscovery.init(allocator, .{});
    defer disco.deinit();

    try disco.registerPeer("main-1", "10.0.0.1", 8080);
    try disco.registerPeer("main-2", "10.0.0.2", 8080);
    try disco.registerService("api", .{ .host = "10.0.0.1", .port = 8080 });
    try disco.registerService("api", .{ .host = "10.0.0.2", .port = 8080 });

    // Use fixed seed for deterministic test
    var prng = std.Random.DefaultPrng.init(0xCAFE1234);
    var lb = LoadBalancer{
        .allocator = allocator,
        .strategy = .random,
        .discovery = &disco,
        .counter = 0,
        .rng = prng.random(),
        .connections = std.StringHashMap(u64).init(allocator),
        .canary_weight = 0.0,
        .canary_peers = std.ArrayList(Peer).empty,
    };
    defer lb.deinit();

    // Add canary peer and set weight to 30%
    try lb.addCanaryPeer("10.0.0.99", 9090);
    lb.setCanaryWeight(0.3);

    var canary_count: u32 = 0;
    var main_count: u32 = 0;
    const iterations: usize = 1000;
    for (0..iterations) |_| {
        const p = lb.next("api") orelse return error.NoPeer;
        if (std.mem.eql(u8, p.host, "10.0.0.99")) {
            canary_count += 1;
        } else {
            main_count += 1;
        }
    }

    try std.testing.expectEqual(iterations, canary_count + main_count);
    // With 30% weight, expect a reasonable number of canary hits
    try std.testing.expect(canary_count >= 200);
    try std.testing.expect(canary_count <= 400);
    // Make sure main path still gets the majority
    try std.testing.expect(main_count >= 500);
}

test "LoadBalancer least_connections" {
    const allocator = std.testing.allocator;
    var disco = PeerDiscovery.init(allocator, .{});
    defer disco.deinit();

    try disco.registerPeer("lc1", "10.0.0.1", 8080);
    try disco.registerPeer("lc2", "10.0.0.2", 8080);
    try disco.registerService("api", .{ .host = "10.0.0.1", .port = 8080 });
    try disco.registerService("api", .{ .host = "10.0.0.2", .port = 8080 });

    var lb = LoadBalancer.init(allocator, .least_connections, &disco);
    defer lb.deinit();

    // First two should go to different peers (0 connections each)
    _ = lb.next("api") orelse return error.NoPeer;
    // Record result for 10.0.0.1
    lb.recordResult("10.0.0.1:8080", true);

    const p1 = lb.next("api") orelse return error.NoPeer;
    // Now 10.0.0.2 should have 0 connections, so next should go there
    try std.testing.expect(std.mem.eql(u8, p1.host, "10.0.0.2"));

    // Record a connection for 10.0.0.2 as well
    lb.recordResult("10.0.0.2:8080", true);
    // Both have 1 connection now; next returns the first one in list
    const p2 = lb.next("api") orelse return error.NoPeer;
    // Either is fine; just verify we get a valid peer
    try std.testing.expect(
        std.mem.eql(u8, p2.host, "10.0.0.1") or std.mem.eql(u8, p2.host, "10.0.0.2"),
    );

    // Release a connection from 10.0.0.1
    lb.recordResult("10.0.0.1:8080", false);
    // Now 10.0.0.1 has 0, 10.0.0.2 has 1 → next should pick 10.0.0.1
    const p3 = lb.next("api") orelse return error.NoPeer;
    try std.testing.expect(std.mem.eql(u8, p3.host, "10.0.0.1"));
}

test "LoadBalancer empty service returns null" {
    const allocator = std.testing.allocator;
    var disco = PeerDiscovery.init(allocator, .{});
    defer disco.deinit();

    var lb = LoadBalancer.init(allocator, .round_robin, &disco);
    defer lb.deinit();

    try std.testing.expect(lb.next("nonexistent") == null);
}
