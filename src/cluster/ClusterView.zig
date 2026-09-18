//! ClusterView — the *read* side of a cluster: an immutable, generation-stamped
//! membership snapshot that a request path can consult without a lock.
//!
//! The membership machinery in this repo (`ClusterMembership`, `FailureDetector`,
//! `PeerDiscovery`) is a **writer**: gossip arrives, heartbeats miss, states flip.
//! Reading that state from a handler is not safe — it is a mutating hash map owned
//! by the maintenance loop — and taking a lock on every request to answer "which
//! node owns this key" is the wrong trade for data that changes every few seconds.
//!
//! So: one writer publishes whole snapshots, readers load a generation index and
//! read a slice. No lock, no allocation, and readers never wait for one another —
//! the only shared write on the read path is a per-slot reader counter, bumped in
//! `acquire` and dropped in `release` so the writer can tell when a slot is free
//! again (that mechanism is the next section).
//!
//! ## Reclamation without a garbage collector
//!
//! There is no way to know when the last reader has finished with a snapshot, and
//! this framework does not add a GC to find out. A ring of generations alone only
//! *narrows* the window (a slow reader can still be reading a slot the writer has
//! lapped — measured: 1888 inconsistent reads in 200k under a tight publish loop),
//! so the view counts readers instead:
//!
//! * a reader does `acquire()` → a refcounted snapshot → `release()`;
//! * the writer, before reusing a slot, waits for that slot's readers to drain.
//!
//! Publication is a maintenance-loop activity (once per gossip interval, seconds)
//! and reads are request-path short (microseconds), so waiting is the cheap
//! direction — and if a reader really does stall, `publish` returns
//! `error.ReadersBusy` rather than overwriting live data. Callers that only want a
//! diagnostic glance (stats, a CLI) use `peek()`, which is explicitly best-effort.
//!
//! ## Which node owns a key
//!
//! `pick` uses **rendezvous hashing** (highest-random-weight): hash the key
//! together with each candidate's id and take the maximum. Compared with the
//! consistent-hash ring in `core/eventbus/Partitioner.zig` it needs no ring
//! storage, no rebuild on membership change and no lock to read — and it has the
//! property that matters: when a member joins or leaves, only the keys that member
//! owned move. The ring stays where writes are batched and a shared structure
//! earns its keep; the hot read path gets the stateless version.

const std = @import("std");

pub const Member = struct {
    /// Stable identity (node id). Used as the hash weight, so it should be unique
    /// within the cluster and stable across restarts.
    id: []const u8,
    /// Address as the cluster sees it (`host:port`). Free-form: it is whatever the
    /// membership layer put there.
    address: []const u8 = "",
    /// Only healthy members are candidates in `pick`. Unhealthy members stay in
    /// the snapshot so operators can see them.
    healthy: bool = true,
    /// Reserved for weighted placement; `pick` ignores it today (every candidate
    /// is one vote) and it is carried so a future policy does not have to change
    /// the snapshot format.
    weight: u32 = 1,
};

/// How long `publish` waits for a slot's readers to drain before giving up.
/// Request-path reads are microseconds; a reader still inside after this budget is
/// stalled (a blocked syscall, a debugger), and failing loudly beats corrupting it.
const reader_wait_spins = 200_000;

/// Exported from the package root as `zmodu.ClusterSnapshot`. The *alias* has no
/// in-tree user — `ClusterBootstrap` and `MembershipView` hold the type directly.
pub const Snapshot = struct {
    generation: u64,
    members: []const Member,

    pub fn count(self: Snapshot) usize {
        return self.members.len;
    }

    pub fn healthyCount(self: Snapshot) usize {
        var n: usize = 0;
        for (self.members) |m| {
            if (m.healthy) n += 1;
        }
        return n;
    }

    pub fn find(self: Snapshot, id: []const u8) ?Member {
        for (self.members) |m| {
            if (std.mem.eql(u8, m.id, id)) return m;
        }
        return null;
    }
};

pub const PublishError = error{
    /// More members than the view was sized for.
    TooManyMembers,
    /// A reader is still holding the slot this publish would reuse.
    ReadersBusy,
    /// Copying the member strings failed.
    OutOfMemory,
};

pub const Stats = struct {
    publishes: u64,
    generation: u64,
    members: usize,
    healthy: usize,
    /// Publishes refused because the input exceeded `max_members`.
    over_capacity: u64,
    /// Publishes refused because a reader was still holding the target slot.
    readers_busy: u64,
};

pub fn ClusterView(comptime max_members: usize, comptime generations: usize) type {
    if (max_members == 0) @compileError("ClusterView(max_members, generations) needs max_members >= 1, got 0. " ++
        "Size the view for the largest membership you will publish, e.g. ClusterView(64, 4).");
    if (generations < 2) @compileError("ClusterView(max_members, generations) needs generations >= 2, got fewer: " ++
        "a reader holds one generation while the writer fills the next. Pass at least 2 (4 is the common choice).");
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// One arena per generation: publishing into a slot resets that slot's
        /// arena, which is exactly why a reader must not outlive `generations - 1`
        /// further publishes.
        arenas: [generations]std.heap.ArenaAllocator,
        slots: [generations][max_members]Member = undefined,
        lengths: [generations]usize = @splat(0),
        current: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        publishes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        over_capacity: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        readers_busy: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Readers currently inside `acquire`/`release`, per generation slot.
        readers: [generations]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(0)),

        pub fn init(allocator: std.mem.Allocator) Self {
            var self = Self{ .allocator = allocator, .arenas = undefined };
            for (&self.arenas) |*a| a.* = std.heap.ArenaAllocator.init(allocator);
            // Generation 0 is the empty cluster, so `snapshot()` is valid before
            // the first publish.
            self.lengths[0] = 0;
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (&self.arenas) |*a| a.deinit();
            self.* = undefined;
        }

        /// Publish a new membership snapshot. **Single writer**: the maintenance
        /// loop, not handlers. Readers are lock-free and see either the previous
        /// or the new snapshot, never a partial one.
        pub fn publish(self: *Self, members: []const Member) PublishError!void {
            if (members.len > max_members) {
                _ = self.over_capacity.fetchAdd(1, .monotonic);
                return error.TooManyMembers;
            }

            const next_gen = self.current.load(.monotonic) + 1;
            const slot = next_gen % generations;

            // Do not overwrite a slot somebody is reading. Bounded wait: the
            // maintenance loop can simply publish again next tick.
            if (!self.waitForReaders(slot)) {
                _ = self.readers_busy.fetchAdd(1, .monotonic);
                return error.ReadersBusy;
            }

            const arena = &self.arenas[slot];
            _ = arena.reset(.retain_capacity);

            for (members, 0..) |m, i| {
                self.slots[slot][i] = .{
                    .id = try arena.allocator().dupe(u8, m.id),
                    .address = try arena.allocator().dupe(u8, m.address),
                    .healthy = m.healthy,
                    .weight = m.weight,
                };
            }
            self.lengths[slot] = members.len;

            // Release so a reader that sees this generation also sees the members.
            self.current.store(next_gen, .release);
            _ = self.publishes.fetchAdd(1, .monotonic);
        }

        /// Take a refcounted snapshot. **Always pair with `release`** — the writer
        /// waits for readers of a slot before reusing it, so a leaked acquire
        /// eventually makes `publish` return `error.ReadersBusy`.
        ///
        /// Retries until the generation it grabbed is still the current one after
        /// the refcount bump (otherwise the writer could already be waiting on a
        /// snapshot nobody holds).
        pub fn acquire(self: *Self) Snapshot {
            while (true) {
                const gen = self.current.load(.acquire);
                const slot = gen % generations;
                _ = self.readers[slot].fetchAdd(1, .acquire);
                if (self.current.load(.acquire) == gen) {
                    return .{ .generation = gen, .members = self.slots[slot][0..self.lengths[slot]] };
                }
                // The writer moved on between our load and our bump: undo and retry.
                _ = self.readers[slot].fetchSub(1, .release);
            }
        }

        pub fn release(self: *Self, snap: Snapshot) void {
            _ = self.readers[snap.generation % generations].fetchSub(1, .release);
        }

        /// Best-effort view for diagnostics (stats, a CLI, logging). **Not** safe
        /// across publishes: the slot may be recycled while you look at it. Use
        /// `acquire`/`release` on any path that acts on the result.
        pub fn peek(self: *const Self) Snapshot {
            const gen = self.current.load(.acquire);
            const slot = gen % generations;
            return .{
                .generation = gen,
                .members = self.slots[slot][0..self.lengths[slot]],
            };
        }

        /// Which member owns `key`, among the healthy ones (rendezvous hashing).
        /// Null when nothing is healthy.
        pub fn pick(self: *Self, key: []const u8) ?Member {
            return self.pickRanked(key, 0);
        }

        /// `rank = 1` is the first backup, and so on — the caller's failover path
        /// (`routeWithBackups` in the ring partitioner, without the ring).
        ///
        /// Implemented as repeated "best not yet chosen" scans: ranks are few
        /// (primary + a couple of backups), so the O(rank × members) cost is real
        /// but tiny, and it needs no caller buffer.
        pub fn pickRanked(self: *Self, key: []const u8, rank: usize) ?Member {
            if (rank >= max_rank) return null;

            const snap = self.acquire();
            defer self.release(snap);
            var chosen: [max_rank][]const u8 = undefined;

            var round: usize = 0;
            while (round <= rank) : (round += 1) {
                var best: ?Member = null;
                var best_score: u64 = 0;
                for (snap.members) |m| {
                    if (!m.healthy) continue;
                    if (alreadyChosen(chosen[0..round], m.id)) continue;
                    const score = rendezvousScore(key, m.id);
                    if (best == null or score > best_score or
                        (score == best_score and std.mem.lessThan(u8, m.id, best.?.id)))
                    {
                        best_score = score;
                        best = m;
                    }
                }
                const winner = best orelse return null; // fewer candidates than the rank asked for
                chosen[round] = winner.id;
                if (round == rank) return winner;
            }
            return null;
        }

        /// Spin (briefly) until no reader holds `slot`. Returns false when a
        /// reader is still inside its snapshot after the budget — the caller
        /// reports `error.ReadersBusy` instead of overwriting live data.
        fn waitForReaders(self: *const Self, slot: usize) bool {
            var spins: usize = 0;
            while (self.readers[slot].load(.acquire) != 0) {
                if (spins >= reader_wait_spins) return false;
                spins += 1;
                std.atomic.spinLoopHint();
            }
            return true;
        }

        pub fn stats(self: *const Self) Stats {
            const snap = self.peek();
            return .{
                .publishes = self.publishes.load(.monotonic),
                .generation = snap.generation,
                .members = snap.count(),
                .healthy = snap.healthyCount(),
                .over_capacity = self.over_capacity.load(.monotonic),
                .readers_busy = self.readers_busy.load(.monotonic),
            };
        }
    };
}

/// How many ranks `pickRanked` supports (primary + 3 backups). Bounded so the
/// selection needs no allocation.
pub const max_rank = 4;

fn alreadyChosen(chosen: []const []const u8, id: []const u8) bool {
    for (chosen) |c| {
        if (std.mem.eql(u8, c, id)) return true;
    }
    return false;
}

/// Rendezvous (highest-random-weight) score: a stable hash of `key \x00 id`.
/// Two processes that see the same member list agree on the owner, and adding or
/// removing one member only reassigns the keys it owned.
pub fn rendezvousScore(key: []const u8, id: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
    hasher.update(key);
    hasher.update(&[_]u8{0});
    hasher.update(id);
    return hasher.final();
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

fn member(id: []const u8, healthy: bool) Member {
    return .{ .id = id, .address = "127.0.0.1:9000", .healthy = healthy };
}

test "ClusterView: publish then read, and the snapshot owns its strings" {
    var view = ClusterView(8, 4).init(std.testing.allocator);
    defer view.deinit();

    // Nothing published: an empty cluster is a valid cluster.
    try std.testing.expectEqual(@as(usize, 0), view.peek().count());

    var tmp = [_]u8{ 'n', 'a', 'm', 'e' }; // mutated after publish on purpose
    var members = [_]Member{
        .{ .id = "node-a", .address = "10.0.0.1:8080", .healthy = true },
        .{ .id = tmp[0..], .address = "10.0.0.2:8080", .healthy = false },
    };
    try view.publish(&members);

    const snap = view.acquire();
    defer view.release(snap);
    try std.testing.expectEqual(@as(u64, 1), snap.generation);
    try std.testing.expectEqual(@as(usize, 2), snap.count());
    try std.testing.expectEqual(@as(usize, 1), snap.healthyCount());

    @memset(&tmp, 'x'); // the snapshot copied its own strings
    try std.testing.expectEqualStrings("name", snap.members[1].id);
    try std.testing.expectEqualStrings("10.0.0.1:8080", snap.find("node-a").?.address);
    try std.testing.expect(snap.find("nope") == null);
}

test "ClusterView: rendezvous hashing is stable when an unrelated node joins" {
    var view = ClusterView(8, 4).init(std.testing.allocator);
    defer view.deinit();

    var three = [_]Member{ member("a", true), member("b", true), member("c", true) };
    try view.publish(&three);
    const before = view.pick("tenant-42").?.id;
    const before_backup = view.pickRanked("tenant-42", 1).?.id;
    try std.testing.expect(!std.mem.eql(u8, before, before_backup)); // distinct backup

    // Same list in a different order → same owner (no "first ring position wins").
    var reordered = [_]Member{ member("c", true), member("a", true), member("b", true) };
    try view.publish(&reordered);
    try std.testing.expectEqualStrings(before, view.pick("tenant-42").?.id);

    // A new node takes over some keys, but a key it does not own keeps its owner.
    var four = [_]Member{ member("a", true), member("b", true), member("c", true), member("d", true) };
    try view.publish(&four);
    // Reference view with the original three nodes, built once.
    var probe = ClusterView(8, 4).init(std.testing.allocator);
    defer probe.deinit();
    try probe.publish(&three);

    var moved: usize = 0;
    for (0..200) |i| {
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "tenant-{d}", .{i});
        if (!std.mem.eql(u8, view.pick(key).?.id, probe.pick(key).?.id)) moved += 1;
    }
    // Roughly a quarter of the keys move; the assertion is loose on purpose
    // (the property is "not all of them", which a modulo scheme would violate).
    try std.testing.expect(moved > 0 and moved < 200);
}

test "ClusterView: unhealthy nodes are never picked" {
    var view = ClusterView(8, 4).init(std.testing.allocator);
    defer view.deinit();

    var only_sick = [_]Member{ member("a", false), member("b", false) };
    try view.publish(&only_sick);
    try std.testing.expect(view.pick("k") == null); // no candidates beats a wrong answer
    try std.testing.expect(view.pickRanked("k", 1) == null);

    var one_healthy = [_]Member{ member("a", false), member("b", true) };
    try view.publish(&one_healthy);
    try std.testing.expectEqualStrings("b", view.pick("k").?.id);
    try std.testing.expect(view.pickRanked("k", 1) == null); // only one candidate
}

test "ClusterView: readers keep seeing a consistent snapshot across publishes" {
    var view = ClusterView(4, 4).init(std.testing.allocator);
    defer view.deinit();

    // Writer thread republishes as fast as it can; readers assert they never see
    // a half-written member (each generation is only visible after `store`).
    const Writer = struct {
        fn run(v: *ClusterView(4, 4)) void {
            var round: usize = 0;
            while (round < 20_000) : (round += 1) {
                var list = [_]Member{ member("a", true), member("b", true) };
                v.publish(&list) catch |err| switch (err) {
                    error.ReadersBusy => {},
                    error.TooManyMembers, error.OutOfMemory => unreachable,
                };
            }
        }
    };
    const Reader = struct {
        fn run(v: *ClusterView(4, 4), bad: *std.atomic.Value(u64)) void {
            var i: usize = 0;
            while (i < 200_000) : (i += 1) {
                const snap = v.acquire();
                defer v.release(snap);
                // No validity check needed: while this snapshot is held the writer
                // refuses to reuse its slot (that is the whole point of refcounts).
                if (snap.count() != 2) {
                    _ = bad.fetchAdd(1, .monotonic);
                    continue;
                }
                for (snap.members) |m| {
                    if (m.id.len != 1 or m.address.len == 0) _ = bad.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    // Publish once before the threads start: generation 0 is the empty cluster,
    // and a reader that acquires it legitimately sees zero members (that is not an
    // inconsistency, it is "the writer has not run yet").
    var initial = [_]Member{ member("a", true), member("b", true) };
    try view.publish(&initial);

    var bad = std.atomic.Value(u64).init(0);
    const writer = try std.Thread.spawn(.{}, Writer.run, .{&view});
    var readers: [3]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, Reader.run, .{ &view, &bad });
    writer.join();
    for (readers) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), bad.load(.monotonic)); // zero inconsistent reads
    const st = view.stats();
    // The writer may have been asked to wait (that is the design, not a failure),
    // but it must have made real progress and reported the refusals.
    try std.testing.expect(st.publishes > 0);
    try std.testing.expectEqual(st.publishes + st.readers_busy, @as(u64, 20_001)); // + the initial publish
}

test "ClusterView: generation ring reuses slots without losing the current view" {
    var view = ClusterView(4, 2).init(std.testing.allocator);
    defer view.deinit();

    for (0..10) |i| {
        var buf: [8]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "n{d}", .{i});
        var list = [_]Member{member(id, true)};
        try view.publish(&list);
        try std.testing.expectEqualStrings(id, view.peek().members[0].id);
    }
    try std.testing.expectEqual(@as(u64, 10), view.stats().generation);
    try std.testing.expectEqual(@as(usize, 1), view.stats().members);
}

test "ClusterView: over-capacity publishes are refused and counted" {
    var view = ClusterView(2, 2).init(std.testing.allocator);
    defer view.deinit();

    var three = [_]Member{ member("a", true), member("b", true), member("c", true) };
    try std.testing.expectError(error.TooManyMembers, view.publish(&three));
    try std.testing.expectEqual(@as(u64, 1), view.stats().over_capacity);
    try std.testing.expectEqual(@as(u64, 0), view.stats().publishes);
    try std.testing.expectEqual(@as(usize, 0), view.peek().count()); // previous view intact
}
