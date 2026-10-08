//! Process-wide, comptime-bounded slot pools for bare function pointers.
//!
//! A Zig `*const fn` carries no context, so several public factories
//! (middleware / permission loader / OpenAPI binding) hand each call its own
//! trampoline that reads its own slot and nothing else. Slots are claimed at
//! wiring time and never released: the bound caps how many *instances an
//! application builds*, never how many requests it serves.
//!
//! One tested implementation lives here so the four pools cannot drift apart.
//! Two facts about the claim protocol are load-bearing and were once per-file:
//!
//!   1. A failed claim still consumed an index (`fetchAdd` runs before the
//!      bounds check), so the raw counter can exceed `max`. Every read loop
//!      must clamp to the array — otherwise a single over-limit claim turns
//!      every later call into an out-of-bounds read (panic in safe builds,
//!      UB in ReleaseFast).
//!   2. `claimOrReuse` overwrites the matched slot with the new item: same
//!      owner, refreshed config. Re-registration updates in place instead of
//!      eating a second slot.

const std = @import("std");

pub fn SlotPool(comptime T: type, comptime max: usize) type {
    return struct {
        slots: [max]?T = @splat(null),
        claimed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        const Self = @This();

        /// Slots handed out so far (monotonic, never released), clamped to
        /// `max`: failed claims consume an index without producing a reachable
        /// slot. Wiring-time budget assertions go through this
        /// (`std.debug.assert(pool.count() <= expected)` after wiring).
        pub fn count(self: *const Self) usize {
            return @min(self.claimed.load(.seq_cst), max);
        }

        /// Read slot `i` (`null` when unclaimed or out of range). Only slots
        /// `< count()` are reachable through a trampoline.
        pub fn get(self: *const Self, i: usize) ?T {
            if (i >= max) return null;
            return self.slots[i];
        }

        /// Claim a fresh slot for `item`.
        pub fn claim(self: *Self, item: T) error{SlotPoolExhausted}!usize {
            const i = self.claimed.fetchAdd(1, .seq_cst);
            if (i >= max) return error.SlotPoolExhausted;
            self.slots[i] = item;
            return i;
        }

        /// Reuse the slot whose item satisfies `same(existing, item)` —
        /// overwriting it with `item` (same owner, refreshed config) — or
        /// claim a fresh one. The scan is clamped to the array (see the file
        /// header): a counter pushed past `max` by an earlier failed claim
        /// must not turn this call into an out-of-bounds read.
        pub fn claimOrReuse(self: *Self, item: T, same: *const fn (T, T) bool) error{SlotPoolExhausted}!usize {
            const n = @min(self.claimed.load(.seq_cst), max);
            for (0..n) |i| {
                if (self.slots[i]) |existing| {
                    if (same(existing, item)) {
                        self.slots[i] = item;
                        return i;
                    }
                }
            }
            return self.claim(item);
        }
    };
}

// --- tests (local instances only — the process-global pools are never
// touched, so an exhaustion run here cannot poison a sibling test) ---

test "claim fills to max, then fails; count clamps at max" {
    var pool: SlotPool(u8, 2) = .{};
    try std.testing.expectEqual(@as(usize, 0), pool.count());
    try std.testing.expectEqual(@as(usize, 0), try pool.claim(10));
    try std.testing.expectEqual(@as(usize, 1), try pool.claim(20));
    try std.testing.expectEqual(@as(usize, 2), pool.count());
    try std.testing.expectError(error.SlotPoolExhausted, pool.claim(30));
    // A failed claim consumed an index, but the reachable set did not grow,
    // and repeated failures keep failing cleanly.
    try std.testing.expectError(error.SlotPoolExhausted, pool.claim(40));
    try std.testing.expectEqual(@as(usize, 2), pool.count());
    try std.testing.expectEqual(@as(?u8, 10), pool.get(0));
    try std.testing.expectEqual(@as(?u8, 20), pool.get(1));
    try std.testing.expectEqual(@as(?u8, null), pool.get(2));
}

test "claimOrReuse reuses by predicate and refreshes the stored item" {
    const Item = struct { id: u8, config: u8 };
    const same = struct {
        fn f(a: Item, b: Item) bool {
            return a.id == b.id;
        }
    }.f;

    var pool: SlotPool(Item, 2) = .{};
    _ = try pool.claim(.{ .id = 1, .config = 100 });
    _ = try pool.claim(.{ .id = 2, .config = 200 });

    // Same owner → same slot, config updated in place, no new claim.
    const again = try pool.claimOrReuse(.{ .id = 2, .config = 222 }, same);
    try std.testing.expectEqual(@as(usize, 1), again);
    try std.testing.expectEqual(@as(usize, 2), pool.count());
    try std.testing.expectEqual(@as(u8, 222), pool.get(1).?.config);

    // New owner → fresh slot; the pool is then full.
    try std.testing.expectError(error.SlotPoolExhausted, pool.claimOrReuse(.{ .id = 3, .config = 0 }, same));
}

test "claimOrReuse after an overflow does not read out of bounds" {
    // Regression: the per-pool scan used to iterate `0..claimed` raw. Once a
    // failed claim had pushed the counter past `max`, the next call indexed
    // `slots[max]` — a panic in safe builds, UB in ReleaseFast. The scan must
    // clamp and answer SlotPoolExhausted instead.
    const same = struct {
        fn f(a: u8, b: u8) bool {
            return a == b;
        }
    }.f;
    var pool: SlotPool(u8, 1) = .{};
    _ = try pool.claim(7);
    try std.testing.expectError(error.SlotPoolExhausted, pool.claim(8));
    // Counter is now 2 with max 1. Reuse of the live item still works…
    try std.testing.expectEqual(@as(usize, 0), try pool.claimOrReuse(7, same));
    // …and a miss fails cleanly instead of walking past the array.
    try std.testing.expectError(error.SlotPoolExhausted, pool.claimOrReuse(9, same));
    try std.testing.expectEqual(@as(usize, 1), pool.count());
}

test "concurrent claims hand out each slot at most once" {
    var pool: SlotPool(usize, 8) = .{};
    const Worker = struct {
        fn run(p: *SlotPool(usize, 8), item: usize, ok: *std.atomic.Value(usize), full: *std.atomic.Value(usize)) void {
            if (p.claim(item)) |_| {
                _ = ok.fetchAdd(1, .seq_cst);
            } else |_| {
                _ = full.fetchAdd(1, .seq_cst);
            }
        }
    };
    var ok: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    var full: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    var threads: [12]std.Thread = undefined;
    for (0..12) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{ &pool, i, &ok, &full });
    }
    for (&threads) |*t| t.join();
    // Deterministic under any interleaving: exactly `max` succeed.
    try std.testing.expectEqual(@as(usize, 8), ok.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 4), full.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 8), pool.count());
    var seen: [12]bool = @splat(false);
    for (0..8) |i| {
        const item = pool.get(i).?;
        try std.testing.expect(!seen[item]);
        seen[item] = true;
    }
}
