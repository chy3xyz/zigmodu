//! Scheduler — the *pooled* execution mode of `Runtime.spawn`
//! (docs/RUNTIME.md §12; Phase 1: one pool thread, `queued`/`claimed`, a ready
//! ring).
//!
//! ## What problem it solves
//!
//! `spawn` gives every worker its own OS thread. That is right for a
//! latency-critical chain (`行情 → 订单簿 → 风控 → 执行`) and wrong for the long
//! tail: one worker per symbol, per room, per session turns "worker count =
//! module count" into "worker count = data dimensionality", and each one costs a
//! stack, a scheduler entity and a context switch.
//!
//! A pooled worker is the same `W` (same `handle`, same mailbox, same contract)
//! run by a shared pool thread instead of its own. What that changes is *who*
//! guarantees §12.3's state exclusivity: with a dedicated thread it is thread
//! identity; here it is an exclusive declaration (`claimed`).
//!
//! ## The two bits, and why there are two
//!
//! | bit | means |
//! |-----|-------|
//! | `queued` | a token for this worker is in the ready ring (or a producer has committed to pushing one) |
//! | `claimed` | a pool thread is executing this worker *right now* |
//!
//! They are independent and can both be true. `claimed` is §12.3's "one thread
//! runs one worker"; `queued` is what makes the ring hold **at most one token
//! per worker** (D4) — which is in turn what makes the ring's capacity bound,
//! and its FIFO order, a fairness property instead of a bookkeeping exercise.
//!
//! ## The capacity invariant (the load-bearing one)
//!
//! **A token is a worker, not a message.** Losing one does not lose a message:
//! it loses *the worker*, which is then never scheduled again — the mailbox
//! keeps accepting, `send` keeps succeeding, and nothing ever runs. So:
//!
//! ```
//! D4: a worker has at most one token in the ring at a time
//!   ⟹ ring occupancy ≤ number of pooled workers
//!   ⟹ capacity ≥ max_pooled_workers makes `push` infallible
//! ```
//!
//! Two consequences, both deliberate:
//!
//! * the capacity is **derived from the declared bound** (`SchedulerConfig`
//!   `max_pooled_workers`, rounded up to a power of two for mask indexing) — not
//!   a constant that could be smaller than the number of workers someone
//!   declares;
//! * the (max+1)-th pooled `spawn` is **refused** (`error.PoolCapacityExceeded`),
//!   at startup, where a configuration mistake belongs. The alternative —
//!   accepting the spawn and dropping the push — is what the invariant exists to
//!   rule out.
//!
//! A `push` that fails anyway is therefore *not* backpressure. It is counted
//! (`Stats.ready_push_failures`), asserted in Debug/ReleaseSafe, and never
//! silently dropped: "the ring was full" is not a reason to stop running a
//! worker, it is a bug with a number attached.
//!
//! ## The hand-back order (the easy thing to get wrong)
//!
//! A claim is released through **one** path, in this order (D5):
//!
//! ```
//! drain ≤ batch messages                      (D3: bounded claim hold)
//! queue  := false     1. nobody owns a token for this worker any more
//! claim  := false     2. anybody may run it again
//! if mailbox has work and !queued.swap(true)  3. re-check, and only then push
//! ```
//!
//! Step 3 is what closes the lost-wakeup window: a producer that sent *during*
//! the batch saw `queued == true` and did not push, so the runner has to. A
//! producer that sends after step 1 finds `queued == false` and pushes for
//! itself; one that sends between 1 and 2 finds `claimed == false` and is only
//! relying on the claim being free again. And because the batch is bounded and
//! the worker goes back through the same hand-back, a busy worker re-enters the
//! ring *behind* whatever else is ready (D4's round robin) instead of holding
//! the claim until its mailbox drains.

const std = @import("std");
const clock_mod = @import("clock.zig");

/// How many pooled workers a runtime declares, and how much work one claim may
/// run before the worker goes back into the ready ring.
pub const SchedulerConfig = struct {
    /// Upper bound on `.pooled` workers this runtime will spawn. `0` = no pool:
    /// the runtime starts no pool thread, and `.mode = .pooled` is a
    /// configuration error at `spawn`.
    max_pooled_workers: usize = 0,
    /// D3's starting point. `1` is the latency end (one message per claim, every
    /// message pays a ring round trip), the mailbox capacity the throughput end
    /// (one slow handler starves every other ready worker). 16 is a first
    /// measurement, not a conclusion — see docs/RUNTIME.md §12.9.
    batch: usize = default_batch,
};

pub const default_batch: usize = 16;

/// The pool thread's spin before it parks, and how long it parks. Parking is a
/// poll rather than a signal on purpose: a `signal` per publish would put a
/// mutex (or a syscall) on the producer path this whole design keeps free.
const spin_rounds = 64;
const idle_wait_ms: u32 = 1;

/// What a producer and the pool need to know about one pooled worker, without
/// knowing its type. Built once at `spawn`; the thunks are comptime-specialised
/// per worker type (no vtable on the hot path).
pub const Ready = struct {
    scheduler: *Scheduler,
    /// The type-erased `*Handle`. `claimed`/`queued` point *into* it, so the
    /// bits and the worker cannot drift apart.
    ctx: *anyopaque,
    /// True while a pool thread is executing this worker (§12.3's exclusive
    /// declaration, the replacement for thread identity).
    claimed: *std.atomic.Value(bool),
    /// True while a token for this worker is in the ready ring.
    queued: *std.atomic.Value(bool),
    /// Run at most `max` messages of this worker. Returns true when the mailbox
    /// gave nothing — empty, or closed and drained; false when the batch bound
    /// ended the call and work may remain. Must not block (§12.3).
    dispatch: *const fn (ctx: *anyopaque, max: usize) bool,
    /// Messages waiting in the mailbox right now. Read exactly once per
    /// hand-back, as step 3 above.
    pending: *const fn (ctx: *anyopaque) usize,
};

/// Producer side of the ready hand-off: called after a successful
/// `mailbox.send`. Lock-free and allocation-free.
///
/// The fast path is for a worker that is already queued: one acquire load, no
/// RMW and no ring traffic. The `swap` is what makes "who pushes the token"
/// unambiguous when two producers arrive at once (`swap` returning `true` means
/// somebody else already owns it).
pub fn announce(item: Ready) void {
    if (item.queued.load(.acquire)) return;
    if (item.queued.swap(true, .acq_rel)) return;
    item.scheduler.push(item);
}

/// The ready ring: Vyukov's bounded queue (the algorithm `MpscRing` implements)
/// over a **heap** slice.
///
/// It is a slice rather than `MpscRing(Ready, N)` because the capacity has to
/// follow the *declared* bound, which is a runtime value — see the capacity
/// invariant at the top of this file. One consumer (the pool thread), any number
/// of producers.
const ReadyRing = struct {
    const Self = @This();

    const Slot = struct {
        sequence: std.atomic.Value(usize),
        value: Ready = undefined,
    };

    slots: []Slot,
    mask: usize,
    enqueue_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    dequeue_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    high_water: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn init(allocator: std.mem.Allocator, capacity_pow2: usize) !Self {
        std.debug.assert(capacity_pow2 >= 2); // 1 slot cannot tell "free" from "unread"
        const slots = try allocator.alloc(Slot, capacity_pow2);
        for (slots, 0..) |*slot, i| slot.sequence = std.atomic.Value(usize).init(i);
        return .{ .slots = slots, .mask = capacity_pow2 - 1 };
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
    }

    fn capacity(self: *const Self) usize {
        return self.slots.len;
    }

    /// Any thread. False when full — which, per the capacity invariant, is a bug
    /// rather than a state to handle.
    fn tryPush(self: *Self, item: Ready) bool {
        var pos = self.enqueue_pos.load(.monotonic);
        while (true) {
            const slot = &self.slots[pos & self.mask];
            const seq = slot.sequence.load(.acquire);
            const diff = @as(isize, @bitCast(seq -% pos));
            if (diff == 0) {
                if (self.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                    pos = actual;
                    continue;
                }
                slot.value = item;
                slot.sequence.store(pos +% 1, .release);
                const depth = (pos +% 1) -% self.dequeue_pos.load(.monotonic);
                if (depth > self.high_water.load(.monotonic)) self.high_water.store(depth, .monotonic);
                return true;
            } else if (diff < 0) {
                return false;
            } else {
                pos = self.enqueue_pos.load(.monotonic);
            }
        }
    }

    /// **The pool thread only.** Null when empty.
    fn tryPop(self: *Self) ?Ready {
        const pos = self.dequeue_pos.load(.monotonic);
        const slot = &self.slots[pos & self.mask];
        const seq = slot.sequence.load(.acquire);
        if (seq != pos +% 1) return null;
        const item = slot.value;
        self.dequeue_pos.store(pos +% 1, .monotonic);
        slot.sequence.store(pos +% self.slots.len, .release);
        return item;
    }

    fn len(self: *const Self) usize {
        return self.enqueue_pos.load(.acquire) -% self.dequeue_pos.load(.acquire);
    }
};

/// The pool. Owned by `Runtime`, created when the pool is declared, and it
/// starts no thread until a pooled worker is actually spawned.
pub const Scheduler = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    ready: ReadyRing,
    /// The declared bound the ring's capacity was derived from.
    max_pooled_workers: usize,
    batch: usize,
    /// Slots taken by `spawn`, never more than `max_pooled_workers`.
    spawned: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Workers a pool thread is executing *right now* — one per claim held.
    /// §12.3's exclusivity is what makes this readable: a claimed worker is
    /// owned by exactly one thread, so the count cannot be double-taken, and its
    /// ceiling is the number of pool threads (Phase 1: 1).
    claimed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mu: std.Io.Mutex = .init,
    idle: std.Io.Condition = .init,
    dispatches: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    claim_misses: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    ready_push_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    idle_waits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: SchedulerConfig,
    ) !*Self {
        std.debug.assert(config.max_pooled_workers > 0); // the runtime only creates a pool it was asked for
        std.debug.assert(config.batch > 0);
        // Round the declared bound *up*: the index arithmetic needs a power of
        // two, and rounding down would break the capacity invariant. The floor
        // of two is the ring's own minimum (a 1-slot ring cannot tell "free"
        // from "not read yet"), and it rounds *up*, never down.
        const capacity = @max(std.math.ceilPowerOfTwo(usize, config.max_pooled_workers) catch
            return error.PoolTooLarge, 2);
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .ready = try ReadyRing.init(allocator, capacity),
            .max_pooled_workers = config.max_pooled_workers,
            .batch = config.batch,
        };
        return self;
    }

    pub const Stats = struct {
        max_pooled_workers: usize,
        /// Ring slots. `>= max_pooled_workers` by construction (`ceilPowerOfTwo`),
        /// which is what makes `push` infallible.
        ready_capacity: usize,
        ready_len: usize,
        spawned: usize,
        running: bool,
        /// How many pool threads this scheduler runs. Phase 1 spawns exactly one
        /// (`0` before the first pooled worker, never more), so it reads as
        /// "is the pool deployed" today and as a count once Phase 2 adds
        /// threads — which is also the ceiling `claimed` cannot exceed (§12.9).
        pool_threads: usize,
        /// Workers a pool thread is executing right now: §12.3's exclusive
        /// declaration, counted. Zero between batches, never above
        /// `pool_threads`.
        claimed: usize,
        /// Scheduling turns that entered a worker (`claim_misses` counts the ones
        /// that popped a token and found the claim taken).
        dispatches: u64,
        /// Pops whose claim was already held: the token went back into the ring
        /// instead of being run (see `runOne`).
        claim_misses: u64,
        /// Must stay 0. See the capacity invariant.
        ready_push_failures: u64,
        idle_waits: u64,
        ready_high_water: usize,
    };

    pub fn deinit(self: *Self) void {
        self.shutdown();
        self.ready.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Reserve one of the declared slots. Refused when the declaration is full:
    /// a runtime that was told "at most N pooled workers" must not accept the
    /// (N+1)-th and then have nowhere to put its token.
    pub fn reserve(self: *Self) !void {
        const taken = self.spawned.fetchAdd(1, .acq_rel) + 1;
        if (taken > self.max_pooled_workers) {
            _ = self.spawned.fetchSub(1, .acq_rel);
            return error.PoolCapacityExceeded;
        }
    }

    /// Give a reserved slot back (a `spawn` that failed after reserving).
    pub fn release(self: *Self) void {
        _ = self.spawned.fetchSub(1, .acq_rel);
    }

    /// Start the pool thread. Idempotent. Called lazily by the first pooled
    /// `spawn`, so declaring a pool that is never used still costs no thread
    /// (§12.8 D2).
    pub fn start(self: *Self) !void {
        if (self.thread != null) return;
        self.thread = try std.Thread.spawn(.{}, poolMain, .{self});
    }

    /// Ask the pool thread to finish, then wait for it. A batch in flight is
    /// allowed to complete: a worker that never returns still blocks shutdown
    /// (§4's rule for dedicated workers, kept for pooled ones).
    pub fn shutdown(self: *Self) void {
        self.stopping.store(true, .release);
        self.mu.lock(self.io) catch return;
        self.idle.broadcast(self.io);
        self.mu.unlock(self.io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn stats(self: *Self) Stats {
        // Read once: `running` and `pool_threads` are two readings of the same
        // fact, and a scrape should not be able to see them disagree.
        const thread_live = self.thread != null;
        return .{
            .max_pooled_workers = self.max_pooled_workers,
            .ready_capacity = self.ready.capacity(),
            .ready_len = self.ready.len(),
            .spawned = self.spawned.load(.monotonic),
            .running = thread_live,
            .pool_threads = @intFromBool(thread_live),
            .claimed = self.claimed.load(.monotonic),
            .dispatches = self.dispatches.load(.monotonic),
            .claim_misses = self.claim_misses.load(.monotonic),
            .ready_push_failures = self.ready_push_failures.load(.monotonic),
            .idle_waits = self.idle_waits.load(.monotonic),
            .ready_high_water = self.ready.high_water.load(.monotonic),
        };
    }

    /// How many tokens are in the ring. For tests and stats: a dedicated worker
    /// never puts one there.
    pub fn readyLen(self: *Self) usize {
        return self.ready.len();
    }

    /// Push a token. Infallible by construction — see the capacity invariant at
    /// the top of this file. A failure here is counted (and asserted in
    /// Debug/ReleaseSafe) rather than swallowed, because a dropped token is a
    /// worker that stops being scheduled, not a message that gets lost.
    fn push(self: *Self, item: Ready) void {
        const pushed = self.ready.tryPush(item);
        std.debug.assert(pushed);
        if (!pushed) _ = self.ready_push_failures.fetchAdd(1, .monotonic);
    }

    /// One scheduling turn: pop a token, run its worker. False when the ring is
    /// empty. The pool loop calls this; tests call it directly, without a
    /// thread, which is how the protocol below is pinned down.
    fn step(self: *Self) bool {
        const item = self.ready.tryPop() orelse return false;
        if (item.claimed.swap(true, .acq_rel)) {
            // Another pool thread is running this worker right now, so this
            // token is redundant — its hand-back owns the `queued` bit and
            // re-checks the mailbox before it lets go (see `runOne`). What it
            // must not do is *disappear*: a dropped token is a worker that stops
            // being scheduled while its mailbox keeps accepting messages, and
            // `queued` staying true would keep every producer from pushing
            // another. Putting it back turns the skip into a retry.
            _ = self.claim_misses.fetchAdd(1, .monotonic);
            self.push(item);
            return true;
        }
        _ = self.dispatches.fetchAdd(1, .monotonic);
        _ = self.claimed.fetchAdd(1, .monotonic);
        self.runOne(item);
        return true;
    }

    /// Run one claimed batch and hand the worker back.
    fn runOne(self: *Self, item: Ready) void {
        // D3: a bounded batch. The bound is what keeps the claim's hold time a
        // function of the runtime rather than of the slowest handler.
        _ = item.dispatch(item.ctx, self.batch);

        // D5's hand-back, in this exact order. `queued` first (the token we
        // consumed is gone; a producer that sends from here on pushes its own),
        // then `claimed` (anybody may run this worker again), then the mailbox
        // re-check that closes the lost-wakeup window: a producer that sent
        // *during* the batch saw `queued == true` and did not push, so this is
        // the only place that can still notice it. Losing the swap means a
        // producer got there first and pushed for us — pushing again would leave
        // two tokens for one worker, which is exactly what the ring's capacity
        // does not have room for (see the capacity invariant above).
        item.queued.store(false, .release);
        item.claimed.store(false, .release);
        if (item.pending(item.ctx) != 0 and !item.queued.swap(true, .acq_rel)) self.push(item);
        // Counted last, and only after the claim is really back: the reading
        // "N workers are being executed" must never be taken while a worker's
        // ownership is still in this frame.
        _ = self.claimed.fetchSub(1, .monotonic);
    }

    fn poolMain(self: *Self) void {
        var spun: u32 = 0;
        while (!self.stopping.load(.acquire)) {
            if (self.step()) {
                spun = 0;
                continue;
            }
            if (spun < spin_rounds) {
                spun += 1;
                std.atomic.spinLoopHint();
                continue;
            }
            // Nothing to run: park on the condition until `shutdown` broadcasts
            // or the poll times out. Same shape as the ticker's idle loop.
            self.mu.lock(self.io) catch return;
            if (!self.stopping.load(.acquire) and self.ready.len() == 0) {
                _ = self.idle_waits.fetchAdd(1, .monotonic);
                self.idle.waitTimeout(self.io, &self.mu, .{
                    .duration = clock_mod.duration(idle_wait_ms),
                }) catch |err| switch (err) {
                    // Expected on every idle poll: the timeout *is* the sleep.
                    error.Timeout => {},
                    // Anything else cut the wait short; either way the next
                    // iteration re-checks the ring, so nothing is lost.
                    else => {},
                };
            }
            self.mu.unlock(self.io);
        }
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────
//
// The protocol is tested *without* the pool thread: `step` is driven directly,
// so what is asserted is the hand-back and the claim — not "it happened to work
// with one thread". The fake below is a real mailbox (so `pending` means what it
// means in production) plus the two protocol bits, and its `dispatch` can inject
// a message **at the end of a batch** — the window §12.8 D5 exists for, made
// deterministic instead of hoped for.

const mbox = @import("mailbox.zig");

/// A pooled worker without a runtime behind it. `produce` is the producer path
/// `Handle.send*` runs (mailbox first, then `announce`), so the test exercises
/// the shipped hand-off rather than a description of it.
const FakeWorker = struct {
    const cap = 8;

    mailbox: mbox.Mailbox(u32, cap) = .init(std.testing.io),
    claimed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    queued: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scheduler: *Scheduler = undefined,
    /// What the runner saw, in order.
    handled: [16]u32 = undefined,
    handled_len: usize = 0,
    dispatches: usize = 0,
    /// A message to inject at the end of the next `dispatch` — i.e. after the
    /// runner has observed the mailbox empty and before it hands the worker
    /// back.
    inject: ?u32 = null,

    fn ready(self: *@This()) Ready {
        return .{
            .scheduler = self.scheduler,
            .ctx = @ptrCast(self),
            .claimed = &self.claimed,
            .queued = &self.queued,
            .dispatch = dispatch,
            .pending = pending,
        };
    }

    fn produce(self: *@This(), msg: u32) void {
        self.mailbox.send(msg) catch return;
        announce(self.ready());
    }

    fn dispatch(ctx: *anyopaque, max: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.dispatches += 1;
        var n: usize = 0;
        while (n < max) {
            const msg = self.mailbox.tryRecv() orelse {
                if (self.inject) |injected| {
                    self.inject = null;
                    self.produce(injected);
                }
                return true;
            };
            self.handled[self.handled_len] = msg;
            self.handled_len += 1;
            n += 1;
        }
        return false;
    }

    fn pending(ctx: *anyopaque) usize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.mailbox.len();
    }
};

fn testScheduler(config: SchedulerConfig) !*Scheduler {
    return Scheduler.init(std.testing.allocator, std.testing.io, config);
}

test "scheduler: a token runs its worker and the worker is re-armed while work remains" {
    var sched = try testScheduler(.{ .max_pooled_workers = 1, .batch = 2 });
    defer sched.deinit();

    var fake = FakeWorker{};
    fake.scheduler = sched;
    for (1..4) |i| fake.produce(@intCast(i));

    // batch = 2: the first turn runs two messages, keeps the worker schedulable
    // (its mailbox still holds one), the second turn runs the rest.
    try std.testing.expect(sched.step());
    try std.testing.expectEqual(@as(usize, 2), fake.handled_len);
    try std.testing.expect(sched.readyLen() != 0);
    try std.testing.expect(sched.step());
    try std.testing.expectEqual(@as(usize, 3), fake.handled_len);
    try std.testing.expectEqual(@as(usize, 0), sched.readyLen());

    // Order is the mailbox's: pooling adds a scheduling hop, never a reorder.
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, fake.handled[0..3]);
    try std.testing.expect(!fake.claimed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), sched.stats().ready_push_failures);
}

test "scheduler: a claimed worker is never run by a second scheduling turn" {
    var sched = try testScheduler(.{ .max_pooled_workers = 1, .batch = 8 });
    defer sched.deinit();

    var fake = FakeWorker{};
    fake.scheduler = sched;
    fake.produce(7);

    // A runner is inside this worker right now (its `claimed` is set, which is
    // what a batch in flight looks like from outside). A turn must not enter it:
    // that is §12.3's state exclusivity resting on `claimed` rather than on
    // "there happens to be one pool thread".
    fake.claimed.store(true, .release);
    try std.testing.expect(sched.step());
    try std.testing.expectEqual(@as(usize, 0), fake.handled_len);
    try std.testing.expectEqual(@as(usize, 0), fake.dispatches);

    // ...and the token must survive the skip: a dropped token is a worker that
    // stops being scheduled while its mailbox keeps accepting.
    try std.testing.expect(sched.readyLen() != 0);
    try std.testing.expectEqual(@as(u64, 1), sched.stats().claim_misses);

    // With the claim free again the same token runs the worker.
    fake.claimed.store(false, .release);
    try std.testing.expect(sched.step());
    try std.testing.expectEqualSlices(u32, &.{7}, fake.handled[0..1]);
}

test "scheduler: the ready ring's capacity follows the declared bound" {
    // Not a constant: every declared bound gets a ring that can hold one token
    // per worker, which is what makes `push` infallible (see the file header).
    for ([_]usize{ 1, 2, 5, 8, 17, 64, 1000 }) |bound| {
        var sched = try testScheduler(.{ .max_pooled_workers = bound });
        defer sched.deinit();
        const s = sched.stats();
        try std.testing.expectEqual(bound, s.max_pooled_workers);
        try std.testing.expect(s.ready_capacity >= bound);
        try std.testing.expect(std.math.isPowerOfTwo(s.ready_capacity));

        // The declared bound is also the pool's admission limit: the (bound+1)-th
        // reservation is refused here, at startup, instead of overflowing the
        // ring later.
        for (0..bound) |_| try sched.reserve();
        try std.testing.expectError(error.PoolCapacityExceeded, sched.reserve());
    }
}

test "scheduler: `bound` tokens all fit — a push is never refused" {
    const bound = 5;
    var sched = try testScheduler(.{ .max_pooled_workers = bound });
    defer sched.deinit();

    var fakes: [bound]FakeWorker = @splat(FakeWorker{});
    for (&fakes) |*fake| {
        fake.scheduler = sched;
        fake.produce(1);
    }
    // One token per worker (D4), which is the occupancy the capacity is derived
    // from — and none of the pushes was refused.
    try std.testing.expectEqual(@as(usize, bound), sched.readyLen());
    const s = sched.stats();
    try std.testing.expectEqual(@as(u64, 0), s.ready_push_failures);
    try std.testing.expectEqual(@as(usize, bound), s.ready_high_water);

    for (&fakes) |*fake| {
        try std.testing.expect(sched.step());
        try std.testing.expectEqual(@as(usize, 1), fake.handled_len);
    }
    try std.testing.expectEqual(@as(usize, 0), sched.readyLen());
}

test "scheduler: a message arriving as the batch ends is never lost" {
    // The lost-wakeup window, deterministically: a producer sends *after* the
    // runner has observed the mailbox empty and *before* the hand-back lets go.
    // The runner is the one that has to notice it — the producer saw
    // `queued == true` and did not push.
    var sched = try testScheduler(.{ .max_pooled_workers = 1, .batch = 8 });
    defer sched.deinit();

    var fake = FakeWorker{};
    fake.scheduler = sched;
    fake.inject = 2; // lands in the window
    fake.produce(1);

    try std.testing.expect(sched.step());
    try std.testing.expectEqual(@as(usize, 1), fake.handled_len);

    // Whatever the runner did on the way out, the worker must still be
    // schedulable: either a token is in the ring, or a runner still holds it.
    const schedulable = fake.claimed.load(.acquire) or sched.readyLen() != 0;
    try std.testing.expect(schedulable);

    // And the message is not just "maybe later": it runs.
    try std.testing.expect(sched.step());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, fake.handled[0..2]);
}
