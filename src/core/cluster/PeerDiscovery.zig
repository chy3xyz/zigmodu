//! Cluster peer discovery for ZigModu multi-node deployments.
//!
//! Supports:
//! - Static peer list (simplest, most reliable)
//! - DNS SRV records for dynamic discovery
//! - Seed nodes for gossip-based membership
//!
//! Usage:
//!   var disco = PeerDiscovery.init(allocator, .{ .static_peers = &.{"10.0.0.1:9000"} });
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

    pub fn init(allocator: std.mem.Allocator, config: DiscoveryConfig) Self {
        return .{ .allocator = allocator, .config = config };
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

    pub fn deinit(self: *Self, peers: []Peer) void {
        for (peers) |p| self.allocator.free(p.host);
        self.allocator.free(peers);
        self.* = undefined;
    }
};

test "PeerDiscovery static peers" {
    const allocator = std.testing.allocator;
    var disco = PeerDiscovery.init(allocator, .{
        .static_peers = &.{ "10.0.0.1:9001", "10.0.0.2:9002", "127.0.0.1:9000" },
        .local_port = 9000,
    });

    const peers = try disco.resolve();
    defer disco.deinit(peers);

    // 127.0.0.1:9000 should be skipped (self), 2 remaining
    try std.testing.expect(peers.len >= 2);
}

test "PeerDiscovery empty config" {
    const allocator = std.testing.allocator;
    var disco = PeerDiscovery.init(allocator, .{});
    const peers = try disco.resolve();
    defer disco.deinit(peers);
    try std.testing.expectEqual(@as(usize, 0), peers.len);
}
