//! Hierarchical timer wheel — O(1) schedule/cancel, bounded work per tick.
//!
//! A sorted list of deadlines gives O(log n) insert and moves every entry on
//! every insert; a single-level wheel degenerates to a linear scan for long
//! timeouts. The classic answer is a *hierarchy*: a timer 40 ms out lives in a
//! fine-grained slot, a timer 40 minutes out lives in a coarse one, and coarse
//! slots are only descended ("cascaded") into the finer level when their
//! interval comes around. Insert and cancel are then O(1) regardless of the
//! timeout, and the work done per `advance` is proportional to the elapsed time,
//! not to the number of pending timers.
//!
//! Geometry (see `slot_ms` / `spokes` / `levels`): 10 ms per level-0 spoke, 64
//! spokes per level, 5 levels → resolutions 10 ms / 640 ms / 41 s / 43.8 min /
//! 46.6 h, and a maximum timeout of ~124 days. A deadline beyond that is clamped
//! to the last level (fires late rather than never).
//!
//! Long pauses: if `advance` is called after a jump larger than one level-0
//! rotation, walking slot by slot would be a busy loop. That path instead scans
//! the live timers once (O(pending)) and fires the due ones — the honest cost of
//! a stall, and it is only taken when the runtime was starved.
//!
//! Payload is comptime so the wheel allocates nothing per fire and knows nothing
//! about what a timer means: the runtime passes "deliver this message to that
//! worker", a test passes a counter.

const std = @import("std");

pub const slot_ms: i64 = 10;
pub const spokes: u32 = 64;
pub const levels: u32 = 5;
const spokes_mask: u64 = spokes - 1;
/// Millisecond span of level 0 — the largest delta `advance` walks slot by slot.
pub const max_cascade_ms: i64 = slot_ms * @as(i64, spokes);
/// Largest timeout the wheel represents exactly; beyond it, deadlines clamp to
/// the top level and fire late.
pub const max_timeout_ms: i64 = blk: {
    var span: i64 = slot_ms;
    for (0..levels) |_| span *= spokes;
    break :blk span;
};

pub fn Wheel(comptime Payload: type) type {
    return struct {
        const Self = @This();
        pub const Id = u64;

        const Node = struct {
            id: Id,
            deadline_ms: i64,
            payload: Payload,
            next: ?*Node = null,
            prev: ?*Node = null,
            /// Which slot's list currently owns this node. Needed by `cancel`:
            /// unlinking the head has to clear the slot pointer, or the next
            /// `advance` walks (and writes to) freed memory.
            level: u32 = 0,
            slot: usize = 0,
        };

        allocator: std.mem.Allocator,
        /// Absolute slot index per level, as of `now_ms`.
        index: [levels]u64 = @splat(0),
        now_ms: i64 = 0,
        slots: [levels][spokes]?*Node = @splat(@splat(null)),
        nodes: std.AutoHashMapUnmanaged(Id, *Node) = .empty,
        next_id: Id = 1,
        fired: u64 = 0,
        cancelled: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, now_ms: i64) Self {
            var self = Self{ .allocator = allocator, .now_ms = now_ms };
            // Consistent starting position: index[l] tracks `now_ms` at that
            // level's resolution so the first advance() only walks real slots.
            for (0..levels) |l| self.index[l] = slotIndex(@intCast(l), now_ms);
            return self;
        }

        pub fn deinit(self: *Self) void {
            var it = self.nodes.valueIterator();
            while (it.next()) |node| self.allocator.destroy(node.*);
            self.nodes.deinit(self.allocator);
            self.slots = @splat(@splat(null));
            self.* = undefined;
        }

        /// Schedule `payload` to fire at `deadline_ms`. Returns a handle for
        /// `cancel`. Allocates one node (bounded by the number of live timers).
        pub fn schedule(self: *Self, deadline_ms: i64, payload: Payload) !Id {
            const clamped_deadline = @max(deadline_ms, self.now_ms);
            const node = try self.allocator.create(Node);
            errdefer self.allocator.destroy(node);
            node.* = .{
                .id = self.next_id,
                .deadline_ms = clamped_deadline,
                .payload = payload,
            };
            self.next_id += 1;
            try self.nodes.put(self.allocator, node.id, node);
            self.insert(node);
            return node.id;
        }

        /// Drop a pending timer. False when it already fired or was cancelled.
        ///
        /// The payload is not touched: if it owns memory, use `cancelWith`.
        pub fn cancel(self: *Self, id: Id) bool {
            const node = self.nodes.fetchRemove(id) orelse return false;
            self.unlink(node.value);
            self.allocator.destroy(node.value);
            self.cancelled += 1;
            return true;
        }

        /// `cancel` plus a hook, so a payload that owns heap memory can be
        /// released on the cancel path exactly as it is on the fire path.
        /// Without this, cancelling a timer is a leak waiting to be noticed.
        pub fn cancelWith(
            self: *Self,
            id: Id,
            ctx: anytype,
            comptime on_cancel: fn (@TypeOf(ctx), Id, Payload) void,
        ) bool {
            const node = self.nodes.fetchRemove(id) orelse return false;
            const payload = node.value.payload;
            self.unlink(node.value);
            self.allocator.destroy(node.value);
            self.cancelled += 1;
            on_cancel(ctx, id, payload);
            return true;
        }

        pub fn pendingCount(self: *const Self) usize {
            return self.nodes.count();
        }

        /// Move time forward, firing everything due. `on_fire` is called for each
        /// due timer with the payload — synchronous, on the caller's thread, so
        /// keep it short (the runtime's hook posts a message, it does not run
        /// application work here).
        pub fn advance(
            self: *Self,
            now_ms: i64,
            ctx: anytype,
            comptime on_fire: fn (@TypeOf(ctx), Id, Payload) void,
        ) usize {
            if (now_ms < self.now_ms) return 0; // time does not go backwards
            const delta = now_ms - self.now_ms;
            if (delta < max_cascade_ms) {
                return self.advanceFine(now_ms, ctx, on_fire);
            }
            return self.advanceCoarse(now_ms, ctx, on_fire);
        }

        // ── internals ────────────────────────────────────────────────────

        /// Slot index of `t` at level `l`. Level 0 advances every `slot_ms`; each
        /// level above advances once per full rotation of the one below.
        fn slotIndex(l: u32, t: i64) u64 {
            var span: u64 = @intCast(slot_ms);
            var i: u32 = 0;
            while (i < l) : (i += 1) span *= spokes;
            return @as(u64, @intCast(@divFloor(t, @as(i64, @intCast(span)))));
        }

        /// Level that can express this delay exactly (its span covers it).
        fn levelFor(delay_ms: i64) u32 {
            var level: u32 = 0;
            var span: i64 = max_cascade_ms;
            while (level + 1 < levels and delay_ms >= span) : (level += 1) span *= spokes;
            return level;
        }

        fn insert(self: *Self, node: *Node) void {
            const delay = node.deadline_ms - self.now_ms;
            const level = levelFor(delay);
            const slot: u64 = @intCast(slotIndex(level, node.deadline_ms) & spokes_mask);
            self.pushNode(level, @intCast(slot), node);
        }

        fn pushNode(self: *Self, level: u32, slot: usize, node: *Node) void {
            const head = self.slots[level][slot];
            node.level = level;
            node.slot = slot;
            node.prev = null;
            node.next = head;
            if (head) |h| h.prev = node;
            self.slots[level][slot] = node;
        }

        fn unlink(self: *Self, node: *Node) void {
            if (node.prev) |p| {
                p.next = node.next;
            } else {
                // Head of its slot: the slot pointer must stop referring to it.
                self.slots[node.level][node.slot] = node.next;
            }
            if (node.next) |n| n.prev = node.prev;
            node.prev = null;
            node.next = null;
        }

        /// Fire or cascade every node in one slot.
        ///
        /// `fire_before` is the inclusive deadline threshold for firing: level 0
        /// fires anything due within the tick it just walked (`now + slot_ms`,
        /// which is the wheel's resolution), while coarser slots only fire what
        /// is *already* overdue — everything else cascades down to a finer level.
        fn expireSlot(
            self: *Self,
            level: u32,
            slot: usize,
            fire_before: i64,
            ctx: anytype,
            comptime on_fire: fn (@TypeOf(ctx), Id, Payload) void,
        ) usize {
            var fired_now: usize = 0;
            var it = self.slots[level][slot];
            self.slots[level][slot] = null;
            while (it) |node| {
                it = node.next;
                node.next = null;
                node.prev = null;
                if (node.deadline_ms <= fire_before) {
                    _ = self.nodes.remove(node.id);
                    on_fire(ctx, node.id, node.payload);
                    self.allocator.destroy(node);
                    fired_now += 1;
                } else {
                    self.insert(node);
                }
            }
            return fired_now;
        }

        /// Walk the slots between the last position and `now_ms` (≤ one level-0
        /// rotation), firing due timers and cascading coarse slots down.
        fn advanceFine(
            self: *Self,
            now_ms: i64,
            ctx: anytype,
            comptime on_fire: fn (@TypeOf(ctx), Id, Payload) void,
        ) usize {
            var fired_now: usize = 0;
            const target0 = slotIndex(0, now_ms);
            while (self.index[0] < target0) {
                self.index[0] += 1;
                // Level 0 fires whatever is due within the tick just walked.
                fired_now += self.expireSlot(0, @intCast(self.index[0] & spokes_mask), self.now_ms + slot_ms, ctx, on_fire);

                // Each wrap of a level rotates the next one up. Coarse slots hold
                // timers that are still far away, so they cascade instead of firing.
                var level: u32 = 0;
                while (level + 1 < levels and (self.index[level] & spokes_mask) == 0) : (level += 1) {
                    self.index[level + 1] += 1;
                    fired_now += self.expireSlot(level + 1, @intCast(self.index[level + 1] & spokes_mask), self.now_ms, ctx, on_fire);
                }
                self.now_ms += slot_ms;
            }
            self.now_ms = now_ms;
            return fired_now;
        }

        /// Long pause: fire everything due in one scan and reinsert the rest.
        fn advanceCoarse(
            self: *Self,
            now_ms: i64,
            ctx: anytype,
            comptime on_fire: fn (@TypeOf(ctx), Id, Payload) void,
        ) usize {
            var still_pending = std.ArrayList(*Node).empty;
            defer still_pending.deinit(self.allocator);
            for (0..levels) |l| {
                for (0..spokes) |s| {
                    var it = self.slots[l][s];
                    self.slots[l][s] = null;
                    while (it) |node| : (it = node.next) {
                        node.next = null;
                        node.prev = null;
                        still_pending.append(self.allocator, node) catch {
                            // Out of memory while deferring: fire instead of losing.
                            _ = self.nodes.remove(node.id);
                            on_fire(ctx, node.id, node.payload);
                            self.allocator.destroy(node);
                            continue;
                        };
                    }
                }
            }
            self.now_ms = now_ms;
            for (0..levels) |l| self.index[l] = slotIndex(@intCast(l), now_ms);

            var fired_now: usize = 0;
            for (still_pending.items) |node| {
                if (node.deadline_ms <= now_ms) {
                    _ = self.nodes.remove(node.id);
                    on_fire(ctx, node.id, node.payload);
                    self.allocator.destroy(node);
                    fired_now += 1;
                } else {
                    self.insert(node); // new level, new slot — nothing to move manually
                }
            }
            return fired_now;
        }
    };
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "Wheel fires a timer only once its deadline has passed" {
    var wheel = Wheel(u32).init(std.testing.allocator, 1_000);
    defer wheel.deinit();
    var rec = Recorder(u32){};
    defer rec.deinit();

    _ = try wheel.schedule(1_050, 42);
    try std.testing.expectEqual(@as(usize, 1), wheel.pendingCount());

    // 40 ms in: not yet.
    _ = wheel.advance(1_040, &rec, Recorder(u32).on_fire);
    try std.testing.expectEqual(@as(usize, 0), rec.fired.items.len);

    // 60 ms in: fired exactly once, and no longer pending.
    _ = wheel.advance(1_060, &rec, Recorder(u32).on_fire);
    try std.testing.expectEqual(@as(usize, 1), rec.fired.items.len);
    try std.testing.expectEqual(@as(u32, 42), rec.fired.items[0]);
    try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());

    _ = wheel.advance(1_500, &rec, Recorder(u32).on_fire);
    try std.testing.expectEqual(@as(usize, 1), rec.fired.items.len); // never re-fires
}

test "Wheel cascades a long timer down through the levels" {
    var wheel = Wheel(u32).init(std.testing.allocator, 0);
    defer wheel.deinit();
    var rec = Recorder(u32){};
    defer rec.deinit();

    // 5 s out: too far for level 0, so it starts coarse and must cascade as the
    // fine wheel rotates underneath it.
    _ = try wheel.schedule(5_000, 7);
    var t: i64 = 0;
    while (t < 5_100) : (t += slot_ms) {
        _ = wheel.advance(t, &rec, Recorder(u32).on_fire);
    }
    try std.testing.expectEqual(@as(usize, 1), rec.fired.items.len);
    try std.testing.expectEqual(@as(u32, 7), rec.fired.items[0]);
}

test "Wheel fires same-slot timers in insertion order" {
    var wheel = Wheel(u32).init(std.testing.allocator, 0);
    defer wheel.deinit();
    var rec = Recorder(u32){};
    defer rec.deinit();

    _ = try wheel.schedule(100, 1);
    _ = try wheel.schedule(100, 2);
    _ = try wheel.schedule(100, 3);
    _ = wheel.advance(200, &rec, Recorder(u32).on_fire);
    try std.testing.expectEqualSlices(u32, &.{ 3, 2, 1 }, rec.fired.items); // list is LIFO
}

test "Wheel cancel removes a timer and frees it" {
    var wheel = Wheel(u32).init(std.testing.allocator, 0);
    defer wheel.deinit();
    var rec = Recorder(u32){};
    defer rec.deinit();

    const id = try wheel.schedule(1_000, 9);
    try std.testing.expect(wheel.cancel(id));
    try std.testing.expect(!wheel.cancel(id)); // idempotent
    _ = wheel.advance(2_000, &rec, Recorder(u32).on_fire);
    try std.testing.expectEqual(@as(usize, 0), rec.fired.items.len);
    try std.testing.expectEqual(@as(u64, 1), wheel.cancelled);
}

test "Wheel survives a long stall and fires everything due" {
    var wheel = Wheel(u32).init(std.testing.allocator, 0);
    defer wheel.deinit();
    var rec = Recorder(u32){};
    defer rec.deinit();

    _ = try wheel.schedule(100, 1);
    _ = try wheel.schedule(3_000, 2);
    _ = try wheel.schedule(60_000, 3);
    // The ticker was starved for two minutes: one advance covers all of it.
    _ = wheel.advance(120_000, &rec, Recorder(u32).on_fire);

    try std.testing.expectEqual(@as(usize, 3), rec.fired.items.len);
    try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());

    // And the wheel still works afterwards.
    _ = try wheel.schedule(120_100, 4);
    _ = wheel.advance(120_200, &rec, Recorder(u32).on_fire);
    try std.testing.expectEqual(@as(u32, 4), rec.fired.items[rec.fired.items.len - 1]);
}

test "Wheel keeps long timers pending across many fine advances" {
    var wheel = Wheel(u32).init(std.testing.allocator, 0);
    defer wheel.deinit();
    var rec = Recorder(u32){};
    defer rec.deinit();

    _ = try wheel.schedule(max_timeout_ms + 1_000, 5); // beyond range: clamped, fires late
    try std.testing.expectEqual(@as(usize, 1), wheel.pendingCount());
    var t: i64 = 0;
    while (t < 1_000_000) : (t += 1_000) {
        _ = wheel.advance(t, &rec, Recorder(u32).on_fire);
        try std.testing.expectEqual(@as(usize, 1), wheel.pendingCount());
    }
    try std.testing.expectEqual(@as(usize, 0), rec.fired.items.len);
}

test "Wheel cancel removes a middle node, keeping the others" {
    var wheel = Wheel(u32).init(std.testing.allocator, 0);
    defer wheel.deinit();
    var rec = Recorder(u32){};
    defer rec.deinit();

    const first = try wheel.schedule(100, 1);
    _ = try wheel.schedule(100, 2);
    const third = try wheel.schedule(100, 3);
    try std.testing.expect(wheel.cancel(first)); // head
    try std.testing.expect(wheel.cancel(third)); // tail
    try std.testing.expectEqual(@as(usize, 1), wheel.pendingCount());

    _ = wheel.advance(200, &rec, Recorder(u32).on_fire);
    try std.testing.expectEqualSlices(u32, &.{2}, rec.fired.items); // the middle one survived

    // And the slot can be reused afterwards (no stale head pointer).
    _ = try wheel.schedule(300, 4);
    _ = wheel.advance(400, &rec, Recorder(u32).on_fire);
    try std.testing.expectEqual(@as(u32, 4), rec.fired.items[rec.fired.items.len - 1]);
    try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());
}

/// Records fires in order so tests can assert *which* timers fired and when.
fn Recorder(comptime Payload: type) type {
    return struct {
        const Self = @This();
        fired: std.ArrayList(Payload) = .empty,

        fn on_fire(self: *Self, _: u64, payload: Payload) void {
            // OOM is the only failure here; abort with a message instead of UB
            // (`catch unreachable` is undefined behaviour in ReleaseFast builds).
            self.fired.append(std.testing.allocator, payload) catch @panic("timer_wheel test Recorder: out of memory");
        }

        fn deinit(self: *Self) void {
            self.fired.deinit(std.testing.allocator);
        }
    };
}
