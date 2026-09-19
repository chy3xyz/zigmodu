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
//! Delivery timing: `advance(now)` fires exactly what is due at `now`. Slots the
//! wheel has already passed are expired whole (their end is behind `now`, so
//! every node in them is due), and the slot `now` sits inside is swept for what
//! is due while the rest waits there for the next tick. A timer therefore fires
//! at the first `advance` that reaches its deadline — never early (firing up to
//! `slot_ms` early was what the old `now + slot_ms` threshold did), never a
//! rotation late (reinserting into the slot just walked cost 640 ms). Work per
//! `advance` is the elapsed slots plus the nodes in the current one, so it still
//! grows with time elapsed rather than with the number of pending timers.
//!
//! Long pauses: if `advance` is called after a jump larger than one level-0
//! rotation, walking slot by slot would be a busy loop. That path instead scans
//! the live timers once (O(pending)) and fires the due ones — the honest cost of
//! a stall, and it is only taken when the runtime was starved.
//!
//! Payload is comptime so the wheel allocates nothing per fire and knows nothing
//! about what a timer means: the runtime passes "deliver this message to that
//! worker", a test passes a counter.
//!
//! ## Ownership: one thread at a time
//!
//! The wheel has no lock, and that is a contract, not an oversight: **only the
//! thread that drives it may call `schedule` / `cancel` / `advance` /
//! `drainAll`.** Every field (`now_ms`, `slots`, `nodes`, and the id counter) is
//! single-writer state.
//!
//! The runtime holds up its end by making the driver the only writer: `after()`
//! from any thread turns into a command on the runtime's bounded queue, and the
//! ticker (or whoever calls `Runtime.tick()`) is the one thread that drains that
//! queue into the wheel. Direct users (a test, the benchmark harness, a custom
//! loop) own the wheel implicitly because they are the only ones holding it.
//!
//! `claimOwner` publishes that thread and `assertOwner` — Debug/ReleaseSafe only,
//! compiled out of ReleaseFast — turns "someone called this from a second
//! thread" into a panic at the call site instead of a corrupted hash map three
//! layers down. An unclaimed wheel (owner 0) asserts nothing, which is what
//! keeps a directly-held wheel usable.

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
        /// The one thread allowed to touch this wheel. 0 = not claimed: either a
        /// wheel held directly by a test/harness, or the window before the
        /// runtime's driver publishes itself. See the module doc comment.
        owner: std.atomic.Value(std.Thread.Id) = std.atomic.Value(std.Thread.Id).init(0),
        /// Absolute slot index per level, as of `now_ms`: the slot that *contains*
        /// `now_ms` at that level's resolution. At level 0 every slot strictly
        /// before `index[0]` has been expired whole, and the slot `index[0]` names
        /// has been swept for what was due then. The coarser entries are written
        /// when the walk enters a new rotation of the level below; that is what
        /// makes "which coarse slot covers the slots about to be walked" a
        /// derivation (`index[0] / 64^l`) instead of incremental bookkeeping that
        /// can drift.
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

        /// Publish the calling thread as the wheel's owner. Idempotent for that
        /// thread; a *second* thread claiming a wheel that is already owned is
        /// the bug the whole ownership story exists to prevent, so it panics.
        pub fn claimOwner(self: *Self) void {
            const me = std.Thread.getCurrentId();
            if (self.owner.cmpxchgStrong(0, me, .acq_rel, .acquire)) |current| {
                if (current != me) @panic("timer wheel: claimed by a second thread");
            }
        }

        /// The wheel's owner (0 = unclaimed).
        pub fn ownerThread(self: *const Self) std.Thread.Id {
            return self.owner.load(.acquire);
        }

        /// Owner-only in Debug/ReleaseSafe. Compiled out of ReleaseFast, where it
        /// would show up in the benchmark's `advance` loop.
        inline fn assertOwner(self: *const Self) void {
            if (!std.debug.runtime_safety) return;
            const owner = self.owner.load(.acquire);
            if (owner == 0 or owner == std.Thread.getCurrentId()) return;
            @panic("timer wheel: touched from a thread that does not own it");
        }

        /// Move the wheel's clock to `now_ms`. Owner-thread bookkeeping between
        /// `init` and the first `advance` (a driver that starts late must not
        /// walk the slots the process spent starting up).
        pub fn alignNow(self: *Self, now_ms: i64) void {
            self.assertOwner();
            self.now_ms = now_ms;
            for (0..levels) |l| self.index[l] = slotIndex(@intCast(l), now_ms);
        }

        /// Schedule `payload` to fire at `deadline_ms`. Returns a handle for
        /// `cancel`. Allocates one node (bounded by the number of live timers).
        pub fn schedule(self: *Self, deadline_ms: i64, payload: Payload) !Id {
            const id = self.next_id;
            try self.scheduleWithId(id, deadline_ms, payload);
            self.next_id = id + 1;
            return id;
        }

        /// `schedule` with an id the caller already minted.
        ///
        /// The runtime takes its ids from a lock-free `Sequencer` on the
        /// *producer* side, because `after()` has to return an id to a caller
        /// that must not wait for the ticker. That splits id minting from node
        /// creation, so this is the entry point that takes the pre-minted one —
        /// uniqueness stays the caller's obligation (it has the sequencer).
        pub fn scheduleWithId(self: *Self, id: Id, deadline_ms: i64, payload: Payload) !void {
            self.assertOwner();
            const clamped_deadline = @max(deadline_ms, self.now_ms);
            const node = try self.allocator.create(Node);
            errdefer self.allocator.destroy(node);
            node.* = .{
                .id = id,
                .deadline_ms = clamped_deadline,
                .payload = payload,
            };
            // A duplicate id would silently orphan the earlier node (the map
            // keeps one node per id, the slot lists keep both), so with runtime
            // safety on this is a hard failure rather than a slow leak. The whole
            // check is gone in ReleaseFast — the benchmark's 100k-insert loop
            // must not pay for a hash lookup per timer.
            if (std.debug.runtime_safety) {
                if (self.nodes.contains(id)) @panic("timer wheel: id handed out twice");
            }
            try self.nodes.put(self.allocator, node.id, node);
            self.insert(node);
        }

        /// Drop a pending timer. False when it already fired or was cancelled.
        ///
        /// The payload is not touched: if it owns memory, use `cancelWith`.
        pub fn cancel(self: *Self, id: Id) bool {
            self.assertOwner();
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
            self.assertOwner();
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

        /// Release every timer still pending, without firing any of them.
        ///
        /// The third exit from the wheel next to fire and cancel: a driver that
        /// is about to stop can hand every remaining payload to `on_drop`, which
        /// is the same hook the other two exits call (as `cancelWith`'s
        /// `on_cancel`) — that is what keeps "a payload is released exactly once"
        /// true on all three paths. Returns how many timers were released.
        ///
        /// Owner thread only, like the rest of the mutating surface: the runtime
        /// reaches it from the ticker (which owns the wheel) or, when the caller
        /// drives `tick()` itself, from that caller's thread.
        ///
        /// Idempotent — a second call finds empty slots and reports 0 — which is
        /// what lets the runtime's `shutdown()` stay idempotent.
        pub fn drainAll(
            self: *Self,
            ctx: anytype,
            comptime on_drop: fn (@TypeOf(ctx), Id, Payload) void,
        ) usize {
            self.assertOwner();
            var dropped: usize = 0;
            for (0..levels) |l| {
                for (0..spokes) |s| {
                    var it = self.slots[l][s];
                    self.slots[l][s] = null;
                    while (it) |node| {
                        it = node.next;
                        node.next = null;
                        node.prev = null;
                        on_drop(ctx, node.id, node.payload);
                        self.allocator.destroy(node);
                        dropped += 1;
                    }
                }
            }
            // Every live node was reachable from a slot, so what is left in the
            // map is dangling keys. Cleared rather than deinit'd: the wheel stays
            // usable without giving up the bucket allocation, and `deinit` still
            // releases it.
            self.nodes.clearRetainingCapacity();
            return dropped;
        }

        /// Move time forward, firing everything due at `now_ms` — every timer with
        /// `deadline_ms <= now_ms` and not one before its deadline.
        /// `on_fire` is called for each due timer with the payload — synchronous,
        /// on the caller's thread, so keep it short (the runtime's hook posts a
        /// message, it does not run application work here).
        ///
        /// Owner thread only.
        pub fn advance(
            self: *Self,
            now_ms: i64,
            ctx: anytype,
            comptime on_fire: fn (@TypeOf(ctx), Id, Payload) void,
        ) usize {
            self.assertOwner();
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

        /// Fire or cascade every node in one slot, and empty it.
        ///
        /// `fire_before` is the inclusive deadline threshold for firing. What the
        /// caller passes is what makes a timer's delivery time honest: a slot the
        /// wheel has left behind passes its own end (every node in it is due), a
        /// coarse slot passes `now` (fire what is already overdue, cascade the
        /// rest down), and the slot `now` sits inside is not worked by this
        /// function at all (`sweepDue` handles it, because that one has to keep
        /// the nodes it cannot fire yet).
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

        /// Fire the nodes of one slot that are due by `deadline_limit`, leaving
        /// the rest linked in place.
        ///
        /// This is how the slot `now_ms` sits inside is handled. Its end is still
        /// in the future, so a node in it may well not be due yet — firing it
        /// would break the "at least `delay_ms`" half of the contract, and moving
        /// it elsewhere has nowhere correct to put it: its deadline belongs to
        /// *this* slot, which the wheel has just arrived at. So it stays, and the
        /// next tick looks again. That is what bounds the delivery lag by the
        /// tick interval instead of a whole rotation, and it is also why the
        /// nodes left here are at most one slot behind the wheel's position.
        ///
        /// Fire order matches `expireSlot` (list order, head first) and nothing is
        /// allocated: a node that is not due keeps its `next`/`prev`/`level`/`slot`
        /// exactly as they were, so `cancel` and `drainAll` still find it.
        fn sweepDue(
            self: *Self,
            level: u32,
            slot: usize,
            deadline_limit: i64,
            ctx: anytype,
            comptime on_fire: fn (@TypeOf(ctx), Id, Payload) void,
        ) usize {
            var fired_now: usize = 0;
            var prev: ?*Node = null;
            var it = self.slots[level][slot];
            while (it) |node| {
                const next = node.next;
                if (node.deadline_ms <= deadline_limit) {
                    if (prev) |p| {
                        p.next = next;
                    } else {
                        self.slots[level][slot] = next;
                    }
                    if (next) |n| n.prev = prev;
                    node.prev = null;
                    node.next = null;
                    _ = self.nodes.remove(node.id);
                    on_fire(ctx, node.id, node.payload);
                    self.allocator.destroy(node);
                    fired_now += 1;
                } else {
                    prev = node;
                }
                it = next;
            }
            return fired_now;
        }

        /// Descend the coarse slots that cover the fine rotation starting at
        /// `first_fine` (a multiple of `spokes` — the fine wheel is entering a new
        /// rotation).
        ///
        /// Level 1's slot `|first_fine| / spokes` covers exactly the 64 fine slots
        /// about to be walked, so it has to be emptied into them *before* the walk
        /// starts: anything it hands down lands in a slot the wheel has not
        /// reached yet. Doing it the other way round was the second half of the
        /// same bug — a cascaded timer whose deadline lay in the first `slot_ms`
        /// of the rotation was dropped into a slot already walked and waited a
        /// rotation. The loop then climbs: a level whose own index is a multiple of
        /// `spokes` is itself the start of a rotation one level up.
        fn cascade(
            self: *Self,
            first_fine: u64,
            now_ms: i64,
            ctx: anytype,
            comptime on_fire: fn (@TypeOf(ctx), Id, Payload) void,
        ) usize {
            var fired_now: usize = 0;
            var level: u32 = 1;
            var abs = first_fine / spokes;
            while (true) {
                self.index[level] = abs;
                // `now_ms`, not the slot's start: a coarse slot can be reached by a
                // jump that lands past part of its window, and everything already
                // overdue fires now rather than waiting for a finer walk that this
                // call is about to perform anyway.
                fired_now += self.expireSlot(level, @intCast(abs & spokes_mask), now_ms, ctx, on_fire);
                if (level + 1 >= levels or (abs & spokes_mask) != 0) break;
                abs /= spokes;
                level += 1;
            }
            return fired_now;
        }

        /// Walk the slots between the last position and `now_ms` (≤ one level-0
        /// rotation), firing due timers and cascading coarse slots down.
        ///
        /// Two halves, and both matter for "fires at `deadline`, never before":
        ///
        /// * Slots the wheel has **left behind** (`index[0] < target0`) are expired
        ///   whole — their end is already in the past, so every node in them is
        ///   due. Walking the slot *before* stepping onto it is what stops a node
        ///   from being reinserted into the slot the wheel just passed (that cost
        ///   a full rotation: 64 × `slot_ms` = 640 ms).
        /// * The slot `now_ms` **sits inside** is only swept for what is due at
        ///   `now_ms`; the rest stays there for the next tick (`sweepDue`).
        ///
        /// Together they make `advance(now)` mean exactly "everything due at `now`
        /// has fired, and nothing before its deadline has": the second half is what
        /// the old `now + slot_ms` threshold got wrong in the *early* direction
        /// (it fired a node due up to `slot_ms` later), and the first half is what
        /// it got wrong in the late direction.
        fn advanceFine(
            self: *Self,
            now_ms: i64,
            ctx: anytype,
            comptime on_fire: fn (@TypeOf(ctx), Id, Payload) void,
        ) usize {
            var fired_now: usize = 0;
            // The walk reinserts cascaded nodes, and `insert` picks their level
            // from `deadline_ms - now_ms`: it has to be the real `now_ms`, not the
            // time of some slot in the middle of the walk, or a node is filed a
            // level too high and pays an extra cascade before it can fire.
            self.now_ms = now_ms;
            const target0 = slotIndex(0, now_ms);
            while (self.index[0] < target0) {
                // Entering a rotation: cascade the coarse slot covering it first,
                // so its nodes land in slots this walk has not reached yet.
                if ((self.index[0] & spokes_mask) == 0) {
                    // The fine index is the rotation's start; `cascade` derives the
                    // level-1 slot from it (`first_fine / spokes`).
                    fired_now += self.cascade(self.index[0], now_ms, ctx, on_fire);
                }
                // Safe to expire whole: `index[0] < target0` means this slot's end
                // is at or before `now_ms`, so every node in it is due.
                fired_now += self.expireSlot(
                    0,
                    @intCast(self.index[0] & spokes_mask),
                    @as(i64, @intCast(self.index[0] + 1)) * slot_ms,
                    ctx,
                    on_fire,
                );
                self.index[0] += 1;
            }
            // What is left is inside slot `target0`, the one `now_ms` falls in.
            fired_now += self.sweepDue(0, @intCast(target0 & spokes_mask), now_ms, ctx, on_fire);
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

/// One ticker step: the runtime reads its clock every `tick_interval_ms` (5 ms)
/// and hands the value to `advance`, so that — not `slot_ms` — is the grid a
/// timer's delivery can be observed on.
const tick_ms: i64 = 5;

/// Drive `wheel` like the ticker does — one `advance` per tick, from `from` to
/// `until` — and report the first tick at which anything fired.
fn runTicker(
    comptime Payload: type,
    wheel: *Wheel(Payload),
    rec: *Recorder(Payload),
    from: i64,
    until: i64,
) ?i64 {
    var t = from;
    while (t <= until) : (t += tick_ms) {
        _ = wheel.advance(t, rec, Recorder(Payload).on_fire);
        if (rec.fired.items.len > 0) return t;
    }
    return null;
}

test "Wheel fires a timer the moment it is due, unaligned deadlines included" {
    // The regression, stated as a property: whatever the offset inside a slot,
    // `advance(now)` fires everything due at `now` — never earlier, and never a
    // rotation later. The old `advanceFine` stepped onto a slot and then used
    // that slot's *start* as its firing threshold, so a deadline sitting inside
    // it was reinserted into the slot the wheel had just walked and was not seen
    // again for 64 slots (640 ms).
    const deadlines = [_]i64{ 1, 4, 5, 9, 10, 11, 14, 16, 19, 20, 24, 630, 635, 639, 640, 641, 700 };
    for (deadlines) |delay| {
        var wheel = Wheel(u32).init(std.testing.allocator, 1_000);
        defer wheel.deinit();
        var rec = Recorder(u32){};
        defer rec.deinit();

        const deadline = 1_000 + delay;
        _ = try wheel.schedule(deadline, @intCast(delay));

        const fired_at = runTicker(u32, &wheel, &rec, 1_000, deadline + 200);
        try std.testing.expect(fired_at != null); // it fired at all
        try std.testing.expectEqual(@as(usize, 1), rec.fired.items.len);
        try std.testing.expectEqual(@as(u32, @intCast(delay)), rec.fired.items[0]);
        try std.testing.expect(fired_at.? >= deadline); // never before the deadline
        try std.testing.expect(fired_at.? <= deadline + tick_ms); // never past the next tick
        try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());
    }
}

test "Wheel: a single advance fires what is due inside the slot it lands in" {
    // The bare report: 24 ms out, advanced to 40 ms. The timer lives in the slot
    // covering [20, 30), which the walk reaches with `now` already past its end.
    var wheel = Wheel(u32).init(std.testing.allocator, 0);
    defer wheel.deinit();
    var rec = Recorder(u32){};
    defer rec.deinit();

    _ = try wheel.schedule(24, 1);
    try std.testing.expectEqual(@as(usize, 1), wheel.advance(40, &rec, Recorder(u32).on_fire));
    try std.testing.expectEqualSlices(u32, &.{1}, rec.fired.items);
    try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());
}

test "Wheel: a deadline is due the moment `now` reaches it (slot edges)" {
    // On the boundary between slots, on the last millisecond of a slot, one past
    // the boundary, and inside the slot `now` falls in — `advance(deadline)`
    // means exactly "everything due at `deadline` has fired".
    for ([_]i64{ 1_010, 1_014, 1_019, 1_020, 1_030, 1_039, 1_040 }) |deadline| {
        var wheel = Wheel(u32).init(std.testing.allocator, 1_000);
        defer wheel.deinit();
        var rec = Recorder(u32){};
        defer rec.deinit();

        _ = try wheel.schedule(deadline, 9);
        // One tick before the deadline: nothing may fire.
        _ = wheel.advance(deadline - 1, &rec, Recorder(u32).on_fire);
        try std.testing.expectEqual(@as(usize, 0), rec.fired.items.len);
        try std.testing.expectEqual(@as(usize, 1), wheel.pendingCount());

        try std.testing.expectEqual(@as(usize, 1), wheel.advance(deadline, &rec, Recorder(u32).on_fire));
        try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());
    }
}

test "Wheel: coarse deadlines (level promotion) fire at the first tick at or after them" {
    // 41 s out sits two levels up, so it only reaches level 0 by cascading — the
    // path where an off-by-one puts the timer into a slot the fine wheel has
    // already walked.
    const delays = [_]i64{ 41_000, 41_003, 4_096, 4_103 };
    for (delays) |delay| {
        var wheel = Wheel(u32).init(std.testing.allocator, 1_000);
        defer wheel.deinit();
        var rec = Recorder(u32){};
        defer rec.deinit();

        const deadline = 1_000 + delay;
        _ = try wheel.schedule(deadline, 5);
        const fired_at = runTicker(u32, &wheel, &rec, 1_000, deadline + 200);
        try std.testing.expect(fired_at != null); // it fired at all
        try std.testing.expect(fired_at.? >= deadline);
        try std.testing.expect(fired_at.? <= deadline + tick_ms);
        try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());
    }
}

test "Wheel: a timer waiting inside the current slot can still be cancelled or drained" {
    // Timers that are not due yet stay linked in the slot `now` sits inside
    // (that is what keeps them from being pushed a rotation out), so `cancel`
    // and `drainAll` have to keep working on a list that was only partially
    // consumed.
    var wheel = Wheel(u32).init(std.testing.allocator, 1_000);
    defer wheel.deinit();
    var rec = Recorder(u32){};
    defer rec.deinit();

    const head = try wheel.schedule(1_014, 1);
    const middle = try wheel.schedule(1_016, 2);
    _ = try wheel.schedule(1_019, 3);

    _ = wheel.advance(1_010, &rec, Recorder(u32).on_fire); // inside slot 101: nothing is due
    try std.testing.expectEqual(@as(usize, 0), rec.fired.items.len);
    try std.testing.expectEqual(@as(usize, 3), wheel.pendingCount());

    try std.testing.expect(wheel.cancel(head)); // head of the partially walked slot
    try std.testing.expect(wheel.cancel(middle)); // middle of it

    var dropped: usize = 0;
    const Dropper = struct {
        fn onDrop(count: *usize, _: u64, _: u32) void {
            count.* += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 1), wheel.drainAll(&dropped, Dropper.onDrop));
    try std.testing.expectEqual(@as(usize, 1), dropped);
    try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());

    // The slot is still usable afterwards (no stale head, no skipped node).
    _ = try wheel.schedule(1_017, 4);
    try std.testing.expectEqual(@as(usize, 1), wheel.advance(1_020, &rec, Recorder(u32).on_fire));
    try std.testing.expectEqualSlices(u32, &.{4}, rec.fired.items);
}

test "Wheel: a mixed batch of unaligned deadlines each fire inside their own tick" {
    // The property the two bugs broke, at batch scale: 200 deadlines with every
    // offset mod 10, spanning plain fine slots and a level promotion, driven one
    // tick at a time. Each timer must come out exactly once, never before its
    // deadline, and never more than one tick after it.
    const count = 200;
    const Stamped = struct {
        fire_at: [count]?i64 = @splat(null),
        now: i64 = 0,
        fn onFire(self: *@This(), _: u64, payload: u32) void {
            self.fire_at[payload] = self.now;
        }
    };

    var wheel = Wheel(u32).init(std.testing.allocator, 1_000);
    defer wheel.deinit();
    var stamped = Stamped{};

    for (0..count) |i| {
        const delay: i64 = 1 + @as(i64, @intCast(i)) * 7;
        _ = try wheel.schedule(1_000 + delay, @intCast(i));
    }

    var t: i64 = 1_000;
    var fired: usize = 0;
    while (fired < count and t <= 1_000 + count * 7 + 200) : (t += tick_ms) {
        stamped.now = t;
        fired += wheel.advance(t, &stamped, Stamped.onFire);
    }
    try std.testing.expectEqual(@as(usize, count), fired);
    try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());

    for (0..count) |i| {
        const delay: i64 = 1 + @as(i64, @intCast(i)) * 7;
        const at = stamped.fire_at[i] orelse return error.TimerNeverFired;
        try std.testing.expect(at >= 1_000 + delay); // never early
        try std.testing.expect(at <= 1_000 + delay + tick_ms); // never past the next tick
    }
}

test "Wheel survives a long stall with unaligned deadlines, and stays exact afterwards" {
    var wheel = Wheel(u32).init(std.testing.allocator, 1_000);
    defer wheel.deinit();
    var rec = Recorder(u32){};
    defer rec.deinit();

    _ = try wheel.schedule(1_006, 1);
    _ = try wheel.schedule(1_014, 2); // inside a slot, like the fine path's hard case
    _ = try wheel.schedule(1_640, 3); // needs a level promotion to get here

    // One tick before the earliest deadline: still nothing, even though the two
    // timers live in different slots.
    _ = wheel.advance(1_005, &rec, Recorder(u32).on_fire);
    try std.testing.expectEqual(@as(usize, 0), rec.fired.items.len);

    // The ticker was starved for two minutes: the rescan path fires all three at
    // once, and none of them before its deadline.
    try std.testing.expectEqual(@as(usize, 3), wheel.advance(121_000, &rec, Recorder(u32).on_fire));
    try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());

    // ...and the fine walk is still exact after the rescan reset the indices.
    _ = try wheel.schedule(121_014, 4);
    _ = wheel.advance(121_010, &rec, Recorder(u32).on_fire);
    try std.testing.expectEqual(@as(usize, 3), rec.fired.items.len); // 121_014 is not due yet
    try std.testing.expectEqual(@as(usize, 1), wheel.advance(121_015, &rec, Recorder(u32).on_fire));
    try std.testing.expectEqual(@as(u32, 4), rec.fired.items[rec.fired.items.len - 1]);
}

test "Wheel: multi-day deadlines cascade down through every level and fire on time" {
    // Delays whose first home is level 2, 3 or 4: they only reach level 0 by
    // cascading, and every hop has to hand the node to a window the wheel has not
    // walked yet. Driven 500 ms per advance, so the fine path does the cascading
    // rather than the stall rescan.
    const step_ms: i64 = 500;
    const delays = [_]i64{ 3_600_000, 3_600_003, 90_000_000, 200_000_000 };
    for (delays) |delay| {
        var wheel = Wheel(u32).init(std.testing.allocator, 0);
        defer wheel.deinit();
        var rec = Recorder(u32){};
        defer rec.deinit();

        _ = try wheel.schedule(delay, 1);
        var fire_at: ?i64 = null;
        var t: i64 = 0;
        while (fire_at == null and t <= delay + step_ms) : (t += step_ms) {
            if (wheel.advance(t, &rec, Recorder(u32).on_fire) > 0) fire_at = t;
        }
        try std.testing.expect(fire_at != null); // it fired at all
        try std.testing.expect(fire_at.? >= delay); // never early
        try std.testing.expect(fire_at.? <= delay + step_ms); // never past the next advance
        try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());
    }
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

test "Wheel scheduleWithId keeps the caller's id (the runtime mints its own)" {
    var wheel = Wheel(u32).init(std.testing.allocator, 0);
    defer wheel.deinit();
    var rec = Recorder(u32){};
    defer rec.deinit();

    // Ids that a `Sequencer` on the producer side already handed out — the wheel
    // must not renumber them, or `after()` could not return an id without
    // waiting for the driver.
    try wheel.scheduleWithId(7_000_000_000, 100, 5);
    try std.testing.expect(wheel.cancel(7_000_000_000));
    try std.testing.expect(!wheel.cancel(1)); // nothing was minted for id 1

    // Mixing both entry points keeps them distinct: `schedule` still mints.
    const minted = try wheel.schedule(100, 6);
    try std.testing.expectEqual(@as(u64, 1), minted);
    try std.testing.expectEqual(@as(usize, 1), wheel.pendingCount());
}

test "Wheel ownership: claiming is publish-and-idempotent" {
    var wheel = Wheel(u32).init(std.testing.allocator, 0);
    defer wheel.deinit();
    try std.testing.expectEqual(@as(std.Thread.Id, 0), wheel.ownerThread()); // unclaimed: assertOwner is a no-op

    wheel.claimOwner();
    try std.testing.expectEqual(std.Thread.getCurrentId(), wheel.ownerThread());
    wheel.claimOwner(); // same thread again: fine
    try std.testing.expectEqual(std.Thread.getCurrentId(), wheel.ownerThread());
}

test "Wheel drainAll releases every pending payload once, and only once" {
    const W = Wheel(*u32);
    const Freed = struct {
        count: usize = 0,
        fn onDrop(self: *@This(), _: W.Id, payload: *u32) void {
            std.testing.allocator.destroy(payload);
            self.count += 1;
        }
    };

    var wheel = W.init(std.testing.allocator, 0);
    defer wheel.deinit();
    var freed = Freed{};

    // One per level: 5 s and 60 s sit in coarser slots, so the drain has to walk
    // the whole hierarchy rather than just level 0.
    for ([_]i64{ 100, 5_000, 60_000 }) |deadline| {
        const payload = try std.testing.allocator.create(u32);
        payload.* = @intCast(deadline);
        _ = try wheel.schedule(deadline, payload);
    }
    try std.testing.expectEqual(@as(usize, 3), wheel.pendingCount());

    try std.testing.expectEqual(@as(usize, 3), wheel.drainAll(&freed, Freed.onDrop));
    try std.testing.expectEqual(@as(usize, 3), freed.count);
    try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());

    // Idempotent: nothing is pending, so nothing may be handed to the hook again
    // (that second call is where a double free would come from).
    try std.testing.expectEqual(@as(usize, 0), wheel.drainAll(&freed, Freed.onDrop));
    try std.testing.expectEqual(@as(usize, 3), freed.count);

    // And the wheel is still usable: drained slots must not leave stale heads.
    const after = try std.testing.allocator.create(u32);
    after.* = 7;
    _ = try wheel.schedule(200, after);
    var rec = Recorder(*u32){};
    defer rec.deinit();
    _ = wheel.advance(300, &rec, Recorder(*u32).on_fire);
    try std.testing.expectEqualSlices(*u32, &.{after}, rec.fired.items);
    std.testing.allocator.destroy(after);
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
