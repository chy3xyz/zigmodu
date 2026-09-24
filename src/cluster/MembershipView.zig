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
//!   It sizes itself to the view (`max_members`): when the census outgrows that,
//!   the members left out are the dead ones first, deterministically, and the drop
//!   is counted — see `sync`.
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
        /// How many census entries the last `sync` had to leave out (0 when the
        /// whole census fit). See `sync` for the drop policy.
        dropped: usize = 0,
        /// `sync` calls that had to leave at least one census entry out.
        truncated_ticks: u64 = 0,
        /// One warning per process about a view too small for the census.
        warned_truncation: bool = false,

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
        ///
        /// A list that does not fit is refused outright (`error.TooManyMembers`,
        /// the view generation stays where it was) — the caller controls that list.
        /// `sync` cannot make that trade, see there.
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
            // This path never truncates, so a `dropped` reading from an earlier
            // `sync` must not survive the generation that replaced it.
            self.dropped = 0;
            self.syncs += 1;
            self.last_error = null;
        }

        /// Snapshot the membership and publish it. Returns `error.ReadersBusy`
        /// when a request path is mid-read — publish again next tick (the view
        /// deliberately refuses to overwrite a slot somebody holds).
        ///
        /// ## Over capacity: drop the dead, deterministically, and say so
        ///
        /// The census (`ClusterMembership.nodes`) never shrinks while this view is
        /// sized once, at startup (`ClusterBootstrap` sizes it at
        /// `view_members = 16` for the documented 3–7 node cluster). So the census
        /// can outgrow it without anyone doing anything wrong — and then
        /// *something* is left out. Which entries is `nodesSnapshot`'s decision,
        /// and it is never hash order: `healthy` first, then `suspect`, then
        /// `failed`/`leaving`, ascending `id` inside each class. That buys the two
        /// properties a routing view needs: a dead peer cannot take the slot a live
        /// one needed (`pick` keeps routing to what is up; an arbitrary subset could
        /// hand it nothing but dead members while healthy ones existed), and the
        /// same census always publishes the same view (no member flutters in and out
        /// of `pick` as unrelated peers are discovered).
        ///
        /// Truncation is **not** a refused tick, unlike `publishNodes` above: a
        /// caller-supplied list's size is the caller's to control, while the census
        /// is not — and refusing here would freeze the read side on a stale
        /// generation forever (the census does not shrink) while `pick` kept routing
        /// to peers that had since died. So the tick publishes, `dropped` /
        /// `truncated_ticks` record what was left out, and the first occurrence logs
        /// once (per-tick logging would be noise: a view too small for the cluster
        /// is a sizing decision, not a transient).
        pub fn sync(self: *Self, membership: *ClusterMembership) view_mod.PublishError!void {
            // `nodesSnapshot` is already bounded by `self.nodes.len == max_members`
            // — the `@min(…, max_members)` that used to sit here was a no-op that
            // read like a guard. What it may have left out is reported by the
            // membership instead: the census only grows, so `getNodeCount()` can
            // over-count against this snapshot but can never hide a drop.
            const n = membership.nodesSnapshot(&self.nodes);
            const census = membership.getNodeCount();
            self.dropped = if (census > n) census - n else 0;
            if (self.dropped != 0) {
                self.truncated_ticks += 1;
                if (!self.warned_truncation) {
                    self.warned_truncation = true;
                    std.log.warn(
                        "[MembershipView] census ({d}) exceeds the view capacity ({d}): publishing {d} and dropping {d} — healthy members first, then suspect, then failed/leaving, ascending id inside each class. Size the view for the cluster you actually run (`MembershipView(max_members, generations)` / `ClusterBootstrap.view_members`).",
                        .{ census, max_members, n, self.dropped },
                    );
                }
            }
            var members: [max_members]view_mod.Member = undefined;
            for (self.nodes[0..n], 0..) |node, i| {
                // `{f}` (not `{}`/`{any}`): those render the structural dump
                // `.{ .ip4 = .{ .bytes = … } }`, which is what the membership's
                // own gossip payload used to carry. `{f}` calls the type's
                // `format` → `host:port`; an address longer than the buffer is cut
                // short and that is cosmetic only (`pick` scores on `id`, the
                // address is informational), so a full buffer is not a failed tick.
                // This is the *address* buffer — the member-count drop policy is in
                // `sync` above and is counted, not silent.
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

// `sync` handed `@min(nodesSnapshot(…), max_members)` to the view — a no-op,
// because the snapshot's own buffer *is* `max_members` — so once the census
// outgrew the view the published subset was simply whatever the hash map yielded
// first. The census only grows (`ClusterMembership` never retires an entry) while
// the view is sized once at startup, so this is reachable without anyone doing
// anything wrong: past capacity an arbitrary subset lets a *dead* peer take the
// slot a live one needed, and `pick` silently stops routing to a live member.
// Pinned here: healthy members win, the selection is deterministic and stable
// across ticks.
test "MembershipView: sync over capacity keeps the healthy members" {
    const allocator = std.testing.allocator;

    var bus = try @import("../core/DistributedEventBus.zig").DistributedEventBus.init(
        allocator,
        std.testing.io,
        "mv-cap-bus",
    );
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19012);
    // `init` seeds this node ("mv-self", healthy); the census below adds six more.
    var membership = try ClusterMembership.init(allocator, std.testing.io, "mv-self", addr, &bus);
    defer membership.deinit();

    const Census = struct { id: []const u8, state: ClusterMembership.NodeState };
    const census = [_]Census{
        .{ .id = "mv-live", .state = .healthy },
        .{ .id = "mv-dead-a", .state = .failed },
        .{ .id = "mv-dead-b", .state = .failed },
        .{ .id = "mv-dead-c", .state = .failed },
        .{ .id = "mv-dead-d", .state = .failed },
        .{ .id = "mv-dead-e", .state = .failed },
    };
    for (census) |peer| {
        const owned = try allocator.dupe(u8, peer.id);
        try membership.nodes.put(owned, .{
            .id = owned,
            .address = addr,
            .state = peer.state,
            .last_seen = 0,
            .joined_at = 0,
        });
    }

    var mv = MembershipView(2, 2).init(allocator);
    defer mv.deinit();
    try mv.sync(&membership);

    const snap = mv.acquire();
    defer mv.release(snap);
    // Seven in the census, two slots — and both slots went to the live members.
    try std.testing.expectEqual(@as(usize, 2), snap.count());
    try std.testing.expectEqual(@as(usize, 2), snap.healthyCount());
    // Deterministic: the survivors are the lowest ids *within* the healthy class,
    // so one census always publishes one view (and every replica that sees that
    // census publishes the same one). A `.failed` peer is never preferred.
    try std.testing.expect(snap.find("mv-live") != null);
    try std.testing.expect(snap.find("mv-self") != null);
    try std.testing.expect(snap.find("mv-dead-a") == null);

    // Stable across ticks: same census, same view.
    try mv.sync(&membership);
    const again = mv.acquire();
    defer mv.release(again);
    try std.testing.expectEqual(@as(usize, 2), again.count());
    try std.testing.expect(again.find("mv-live") != null);
    try std.testing.expect(again.find("mv-dead-a") == null);
}

// The drop is *reported*, not silent, and it is not a refused tick: refusing
// would freeze the read side on a stale generation forever (the census does not
// shrink) while `pick` kept routing to peers that had since died.
test "MembershipView: sync over capacity counts the drop instead of refusing" {
    const allocator = std.testing.allocator;

    var bus = try @import("../core/DistributedEventBus.zig").DistributedEventBus.init(
        allocator,
        std.testing.io,
        "mv-drop-bus",
    );
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19013);
    var membership = try ClusterMembership.init(allocator, std.testing.io, "mv-self", addr, &bus);
    defer membership.deinit();

    const peers = [_][]const u8{ "mv-p1", "mv-p2", "mv-p3", "mv-p4" };
    for (peers) |id| {
        const owned = try allocator.dupe(u8, id);
        try membership.nodes.put(owned, .{
            .id = owned,
            .address = addr,
            .state = .failed,
            .last_seen = 0,
            .joined_at = 0,
        });
    }

    // Sized for the census: nothing is dropped, and nothing is reported.
    var mv = MembershipView(8, 2).init(allocator);
    defer mv.deinit();
    try mv.sync(&membership);
    try std.testing.expectEqual(@as(usize, 0), mv.dropped);
    try std.testing.expectEqual(@as(u64, 0), mv.truncated_ticks);
    try std.testing.expectEqual(@as(usize, 5), mv.stats().members);

    // Five in the census, three slots → two left out, counted.
    var mv_small = MembershipView(3, 2).init(allocator);
    defer mv_small.deinit();
    try mv_small.sync(&membership);
    try std.testing.expectEqual(@as(usize, 2), mv_small.dropped);
    try std.testing.expectEqual(@as(u64, 1), mv_small.truncated_ticks);
    try mv_small.sync(&membership);
    try std.testing.expectEqual(@as(u64, 2), mv_small.truncated_ticks);
    // A drop is not a refusal: the tick published, and the view is live.
    try std.testing.expectEqual(@as(?view_mod.PublishError, null), mv_small.last_error);
    try std.testing.expectEqual(@as(u64, 2), mv_small.syncs);
    try std.testing.expectEqual(@as(usize, 3), mv_small.stats().members);
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
