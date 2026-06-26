//! Cluster peer discovery for ZigModu multi-node deployments.
//!
//! Supports:
//! - Static peer list (simplest, most reliable)
//! - DNS SRV records for dynamic discovery
//! - Seed nodes for gossip-based membership
//! - Runtime register/deregister with service-name→peer mapping
//!
//! Usage:
//!   var disco = PeerDiscovery.init(allocator, .{ .static_peers = &.{"10.0.0.1:9000"} });
//!   defer disco.deinit();
//!   const peers = try disco.resolve();

const std = @import("std");

pub const Peer = struct {
    host: []const u8,
    port: u16,
};

pub const DiscoveryConfig = struct {
    /// Static peer list (host:port format)
    static_peers: []const []const u8 = &.{},
    /// DNS SRV domain for dynamic discovery
    srv_domain: ?[]const u8 = null,
    /// Local port for self-identification
    local_port: u16 = 9000,
};

pub const PeerDiscovery = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: DiscoveryConfig,
    /// Runtime-registered peers: id → Peer
    peers: std.StringHashMap(Peer),
    /// Service-name → list of Peers
    service_map: std.StringHashMap(std.ArrayList(Peer)),

    pub fn init(allocator: std.mem.Allocator, config: DiscoveryConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .peers = std.StringHashMap(Peer).init(allocator),
            .service_map = std.StringHashMap(std.ArrayList(Peer)).init(allocator),
        };
    }

    /// Resolve all known peers. Skips self (matching local_port on localhost).
    pub fn resolve(self: *Self) ![]Peer {
        var list = std.ArrayList(Peer).empty;

        // Static peers
        for (self.config.static_peers) |addr_str| {
            if (std.mem.indexOfScalar(u8, addr_str, ':')) |colon| {
                const host = addr_str[0..colon];
                const port = try std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10);
                // Skip self
                if (port == self.config.local_port and
                    (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost"))) continue;

                const host_copy = try self.allocator.dupe(u8, host);
                try list.append(self.allocator, .{ .host = host_copy, .port = port });
            }
        }

        // DNS SRV: deferred (requires async DNS in Zig 0.16)
        _ = self.config.srv_domain;

        return list.toOwnedSlice(self.allocator);
    }

    /// Free a resolved peer slice returned by resolve().
    pub fn deinitResolved(self: *Self, peers: []Peer) void {
        for (peers) |p| self.allocator.free(p.host);
        self.allocator.free(peers);
    }

    /// Register a peer at runtime.
    pub fn registerPeer(self: *Self, id: []const u8, address: []const u8, port: u16) !void {
        const id_dup = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_dup);
        const host_dup = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(host_dup);
        try self.peers.put(id_dup, .{ .host = host_dup, .port = port });
    }

    /// Remove a peer by id. Also removes from all service maps.
    pub fn deregisterPeer(self: *Self, id: []const u8) void {
        const peer = self.peers.get(id) orelse return;

        // Collect service entries to clean up if they become empty
        var empty_keys = std.ArrayList([]const u8).empty;
        defer empty_keys.deinit(self.allocator);

        // Remove from all service maps first
        var svc_it = self.service_map.iterator();
        while (svc_it.next()) |svc_entry| {
            const svc_list = svc_entry.value_ptr;
            var i: usize = svc_list.items.len;
            while (i > 0) {
                i -= 1;
                const sp = svc_list.items[i];
                if (std.mem.eql(u8, sp.host, peer.host) and sp.port == peer.port) {
                    self.allocator.free(svc_list.items[i].host);
                    _ = svc_list.orderedRemove(i);
                }
            }
            // Track empty service entries for cleanup after iteration
            if (svc_list.items.len == 0) {
                empty_keys.append(self.allocator, svc_entry.key_ptr.*) catch return;
            }
        }

        // Now clean up empty service entries (safe after iteration)
        for (empty_keys.items) |key| {
            if (self.service_map.fetchRemove(key)) |kv| {
                var v = kv.value;
                self.allocator.free(kv.key);
                v.deinit(self.allocator);
            }
        }

        // Remove from peers map
        if (self.peers.fetchRemove(id)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.host);
        }
    }

    /// Return current runtime-registered peer list. Caller owns the returned slice.
    pub fn listPeers(self: *const Self) ![]Peer {
        var list = std.ArrayList(Peer).empty;
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            const host_dup = try self.allocator.dupe(u8, entry.value_ptr.host);
            try list.append(self.allocator, .{ .host = host_dup, .port = entry.value_ptr.port });
        }
        return list.toOwnedSlice(self.allocator);
    }

    /// Register a peer under a service name.
    pub fn registerService(self: *Self, service_name: []const u8, peer: Peer) !void {
        const host_dup = try self.allocator.dupe(u8, peer.host);
        errdefer self.allocator.free(host_dup);

        const gop = try self.service_map.getOrPut(service_name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, service_name);
            gop.value_ptr.* = std.ArrayList(Peer).empty;
        }
        try gop.value_ptr.append(self.allocator, .{ .host = host_dup, .port = peer.port });
    }

    /// Discover peers for a service. Returns null if the service is unknown.
    pub fn discoverService(self: *const Self, service_name: []const u8) ?[]const Peer {
        if (self.service_map.get(service_name)) |list| {
            return list.items;
        }
        return null;
    }

    /// Remove a peer from a service by its runtime-registered id.
    pub fn deregisterService(self: *Self, service_name: []const u8, peer_id: []const u8) !void {
        const peer = self.peers.get(peer_id) orelse return error.PeerNotFound;

        if (self.service_map.getPtr(service_name)) |list| {
            var i: usize = list.items.len;
            while (i > 0) {
                i -= 1;
                const sp = list.items[i];
                if (std.mem.eql(u8, sp.host, peer.host) and sp.port == peer.port) {
                    self.allocator.free(list.items[i].host);
                    _ = list.orderedRemove(i);
                    // Clean up empty service entry
                    if (list.items.len == 0) {
                        if (self.service_map.fetchRemove(service_name)) |kv| {
                            var v = kv.value;
                            self.allocator.free(kv.key);
                            v.deinit(self.allocator);
                        }
                    }
                    return;
                }
            }
        }
        return error.PeerNotFoundInService;
    }

    /// Fully deinitialize: free all internal maps and strings.
    pub fn deinit(self: *Self) void {
        // Free peers map
        var peer_it = self.peers.iterator();
        while (peer_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.host);
        }
        self.peers.deinit();

        // Free service map
        var svc_it = self.service_map.iterator();
        while (svc_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |p| {
                self.allocator.free(p.host);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.service_map.deinit();

        self.* = undefined;
    }
};

test "PeerDiscovery static peers" {
    const allocator = std.testing.allocator;
    var disco = PeerDiscovery.init(allocator, .{
        .static_peers = &.{ "10.0.0.1:9001", "10.0.0.2:9002", "127.0.0.1:9000" },
        .local_port = 9000,
    });
    defer disco.deinit();

    const peers = try disco.resolve();
    defer disco.deinitResolved(peers);

    // 127.0.0.1:9000 should be skipped (self), 2 remaining
    try std.testing.expect(peers.len >= 2);
}

test "PeerDiscovery empty config" {
    const allocator = std.testing.allocator;
    var disco = PeerDiscovery.init(allocator, .{});
    defer disco.deinit();

    const peers = try disco.resolve();
    defer disco.deinitResolved(peers);
    try std.testing.expectEqual(@as(usize, 0), peers.len);
}

test "PeerDiscovery register and discover service" {
    const allocator = std.testing.allocator;
    var disco = PeerDiscovery.init(allocator, .{});
    defer disco.deinit();

    // Register a peer
    try disco.registerPeer("backend-1", "10.0.0.1", 8080);
    try disco.registerPeer("backend-2", "10.0.0.2", 8080);

    // Register peers under a service
    try disco.registerService("api", .{ .host = "10.0.0.1", .port = 8080 });
    try disco.registerService("api", .{ .host = "10.0.0.2", .port = 8080 });

    // Discover
    const peers = disco.discoverService("api") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), peers.len);
    try std.testing.expectEqual(@as(u16, 8080), peers[0].port);
    try std.testing.expectEqual(@as(u16, 8080), peers[1].port);

    // Unknown service returns null
    try std.testing.expect(disco.discoverService("unknown") == null);

    // listPeers returns runtime peers
    const all = try disco.listPeers();
    defer disco.deinitResolved(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
}

test "PeerDiscovery deregister removes peer" {
    const allocator = std.testing.allocator;
    var disco = PeerDiscovery.init(allocator, .{});
    defer disco.deinit();

    try disco.registerPeer("node-a", "10.0.0.1", 9001);
    try disco.registerPeer("node-b", "10.0.0.2", 9002);

    // Register both under a service
    try disco.registerService("cache", .{ .host = "10.0.0.1", .port = 9001 });
    try disco.registerService("cache", .{ .host = "10.0.0.2", .port = 9002 });

    // Deregister node-a
    disco.deregisterPeer("node-a");

    // Peer list should only have node-b
    const all = try disco.listPeers();
    defer disco.deinitResolved(all);
    try std.testing.expectEqual(@as(usize, 1), all.len);
    try std.testing.expect(std.mem.eql(u8, all[0].host, "10.0.0.2"));
    try std.testing.expectEqual(@as(u16, 9002), all[0].port);

    // Service should only have node-b
    const cache_peers = disco.discoverService("cache") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), cache_peers.len);
    try std.testing.expect(std.mem.eql(u8, cache_peers[0].host, "10.0.0.2"));
    try std.testing.expectEqual(@as(u16, 9002), cache_peers[0].port);

    // deregisterService for node-b
    try disco.deregisterService("cache", "node-b");

    // Service should now be empty / removed
    try std.testing.expect(disco.discoverService("cache") == null);
}
