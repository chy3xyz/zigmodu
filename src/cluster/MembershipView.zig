//! Feed the read side from the write side.
//!
//! `ClusterView` is the refcounted, lock-free snapshot that request paths read;
//! `ClusterMembership` is the write side (a mutex-guarded hash map that gossip
//! mutates). Nothing connected them — the view had **no publisher**, so it was a
//! tested component nobody could actually use. This file is that connection:
//!
//! ```text
//!   gossip / health (membership)   →   sync()   →   ClusterView.publish()   →   request path
//!        mutex-guarded map               snapshot+format     refcounted slots        acquire / pick
//! ```
//!
//! `sync()` is pull-based on purpose. The membership loop is driven *externally*
//! (`ClusterMembership.runOnce`, per its own doc), so the same tick that advances
//! gossip also refreshes the view: one loop, no callbacks, no userdata plumbing
//! (the membership's `onNodeJoin`-style hooks carry no context pointer).
//!
//! Feeding it two ways:
//! * `publishNodes(...)` — you already have a node list (tests, a different
//!   discovery source, a config-driven static cluster).
//! * `sync(membership)` — the real path: snapshot the map, format addresses,
//!   publish. Steady state allocates nothing here (the view owns its strings).
//!
//! Request paths read through `acquire`/`release` and route with `pick`
//! (rendezvous): the membership hash map is never touched from a handler.

const std = @import("std");
const view_mod = @import("ClusterView.zig");
const membership_mod = @import("../core/ClusterMembership.zig");
const ClusterMembership = membership_mod.ClusterMembership;

/// One member as the bridge sees it. `address` is `host:port` and informational
/// (`pick` scores on `id`).
///
/// Exported from the package root as `zmodu.ClusterNodeView`. The *alias* has no
/// in-tree user — this file and `ClusterBootstrap` pass the type around as
/// `MembershipView.Node`.
pub const Node = struct {
    id: []const u8,
    address: []const u8 = "",
    healthy: bool = true,
};

pub fn MembershipView(comptime max_members: usize, comptime generations: usize) type {
    if (max_members == 0) @compileError("MembershipView needs room for at least one member");
    return struct {
        const Self = @This();
        pub const View = view_mod.ClusterView(max_members, generations);

        view: View,
        /// Scratch reused by every `sync` (bounded, so no allocation per tick).
        nodes: [max_members]ClusterMembership.ClusterNode = undefined,
        addresses: [max_members][addr_len]u8 = undefined,
        /// Last publish that was refused, kept so a health endpoint can say why.
        last_error: ?view_mod.PublishError = null,
        syncs: u64 = 0,

        /// `host:port` fits well under this for both ip4 and ip6.
        pub const addr_len = 64;

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .view = View.init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.view.deinit();
            self.* = undefined;
        }

        /// Publish a node list as the next view generation. Strings are copied
        /// into the view's slot, so `nodes` only has to live for this call.
        pub fn publishNodes(self: *Self, nodes: []const Node) view_mod.PublishError!void {
            if (nodes.len > max_members) {
                self.last_error = error.TooManyMembers;
                return error.TooManyMembers;
            }
            var members: [max_members]view_mod.Member = undefined;
            for (nodes, 0..) |n, i| {
                members[i] = .{ .id = n.id, .address = n.address, .healthy = n.healthy };
            }
            self.view.publish(members[0..nodes.len]) catch |err| {
                self.last_error = err;
                return err;
            };
            self.syncs += 1;
            self.last_error = null;
        }

        /// Snapshot the membership and publish it. Returns `error.ReadersBusy`
        /// when a request path is mid-read — publish again next tick (the view
        /// deliberately refuses to overwrite a slot somebody holds).
        pub fn sync(self: *Self, membership: *ClusterMembership) view_mod.PublishError!void {
            const n = @min(membership.nodesSnapshot(&self.nodes), max_members);
            var members: [max_members]view_mod.Member = undefined;
            for (self.nodes[0..n], 0..) |node, i| {
                // `{f}` (not `{}`/`{any}`): those render the structural dump
                // `.{ .ip4 = .{ .bytes = … } }`, which is what the membership's
                // own gossip payload used to carry. `{f}` calls the type's
                // `format` → `host:port`. Truncation is cosmetic (`pick` scores
                // on `id`), so a full buffer is not turned into a failed tick.
                var w = std.Io.Writer.fixed(&self.addresses[i]);
                w.print("{f}", .{node.address}) catch |err| {
                    std.log.debug("[MembershipView] address format failed: {}", .{err});
                };
                members[i] = .{
                    .id = node.id,
                    .address = w.buffered(),
                    // A suspect node is *not* healthy: `pick` only routes to
                    // healthy members, and "maybe down" must not get traffic.
                    .healthy = node.state == .healthy,
                };
            }
            self.view.publish(members[0..n]) catch |err| {
                self.last_error = err;
                return err;
            };
            self.syncs += 1;
            self.last_error = null;
        }

        /// Request-path read. **Always pair with `release`.**
        pub fn acquire(self: *Self) view_mod.Snapshot {
            return self.view.acquire();
        }

        pub fn release(self: *Self, snap: view_mod.Snapshot) void {
            self.view.release(snap);
        }

        /// Rendezvous: the same key lands on the same healthy member.
        pub fn pick(self: *Self, key: []const u8) ?view_mod.Member {
            return self.view.pick(key);
        }

        pub fn stats(self: *Self) view_mod.Stats {
            return self.view.stats();
        }
    };
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "MembershipView: publishNodes feeds the read path, pick skips unhealthy" {
    const allocator = std.testing.allocator;
    var mv = MembershipView(8, 2).init(allocator);
    defer mv.deinit();

    // Generation 0 is the empty cluster: reading before the first publish is safe.
    try std.testing.expectEqual(@as(usize, 0), mv.stats().members);
    try std.testing.expectEqual(@as(?view_mod.Member, null), mv.pick("order-1"));

    const nodes = [_]Node{
        .{ .id = "node-a", .address = "127.0.0.1:9001" },
        .{ .id = "node-b", .address = "127.0.0.1:9002", .healthy = false },
        .{ .id = "node-c", .address = "127.0.0.1:9003" },
    };
    try mv.publishNodes(&nodes);

    const snap = mv.acquire();
    defer mv.release(snap);
    try std.testing.expectEqual(@as(usize, 3), snap.count());
    try std.testing.expectEqual(@as(usize, 2), snap.healthyCount());
    try std.testing.expectEqualStrings("127.0.0.1:9002", snap.find("node-b").?.address);

    // Rendezvous is stable per key and never lands on an unhealthy member.
    const first = mv.pick("order-1").?;
    try std.testing.expect(!std.mem.eql(u8, "node-b", first.id));
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expectEqualStrings(first.id, mv.pick("order-1").?.id);
    }
    try std.testing.expectEqual(@as(u64, 1), mv.stats().publishes);
}

test "MembershipView: an oversized list is refused, and the live generation survives" {
    const allocator = std.testing.allocator;
    var mv = MembershipView(2, 2).init(allocator);
    defer mv.deinit();

    const ok = [_]Node{ .{ .id = "a" }, .{ .id = "b" } };
    try mv.publishNodes(&ok);

    const too_many = [_]Node{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    try std.testing.expectError(error.TooManyMembers, mv.publishNodes(&too_many));
    try std.testing.expectEqual(@as(?view_mod.PublishError, error.TooManyMembers), mv.last_error);
    // The refusal happens before `ClusterView.publish`, so the view's own
    // `over_capacity` counter stays 0 — this bridge refuses, it does not truncate.
    try std.testing.expectEqual(@as(u64, 0), mv.stats().over_capacity);
    try std.testing.expectEqual(@as(u64, 1), mv.syncs);

    // Readers keep seeing the last good generation.
    const snap = mv.acquire();
    defer mv.release(snap);
    try std.testing.expectEqual(@as(usize, 2), snap.count());
}

test "MembershipView: sync copies the membership map, addresses included" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var bus = try @import("../core/DistributedEventBus.zig").DistributedEventBus.init(
        allocator,
        std.testing.io,
        "mv-node",
    );
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19011);
    var membership = try ClusterMembership.init(allocator, std.testing.io, "mv-node", addr, &bus);
    defer membership.deinit(); // never started: init alone seeds the local node

    var mv = MembershipView(8, 2).init(allocator);
    defer mv.deinit();
    try mv.sync(&membership);

    const snap = mv.acquire();
    defer mv.release(snap);
    try std.testing.expectEqual(@as(usize, 1), snap.count());
    const self_member = snap.find("mv-node").?;
    try std.testing.expect(self_member.healthy);
    // A real `host:port` string, not a struct dump.
    if (!std.mem.endsWith(u8, self_member.address, ":19011")) {
        std.debug.print("[diag] address = '{s}'\n", .{self_member.address});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(u64, 1), mv.stats().publishes);
}
