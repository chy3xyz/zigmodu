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
//!   ⟹ every token a producer can want to push has a slot
//! ```
//!
//! Two consequences, both deliberate:
//!
//! * the capacity is **derived from the declared bound** (`SchedulerConfig`
//!   `max_pooled_workers`, rounded up to a power of two for mask indexing) — not
//!   a constant that could be smaller than the number of workers someone
//!   declares. And it is derived from the bound **plus the pool threads**: a
//!   consumer that is inside `tryPop` still owns its slot (see `push`), so the
//!   ring has to have room for one token per worker *and* one per consumer
//!   sitting in that window;
//! * the (max+1)-th pooled `spawn` is **refused** (`error.PoolCapacityExceeded`),
//!   at startup, where a configuration mistake belongs. The alternative —
//!   accepting the spawn and dropping the push — is what the invariant exists to
//!   rule out.
//!
//! A `push` that fails anyway is therefore *not* backpressure. It is counted
//! (`Stats.ready_push_failures`), asserted in Debug/ReleaseSafe, and never
//! silently dropped: "the ring was full" is not a reason to stop running a
//! worker, it is a bug with a number attached. Before it counts anything, `push`
//! waits the dequeue window out (below) — the one reading that *looks* like
//! "full" without being it.
//!
//! ## The dequeue window (why a push retries)
//!
//! Vyukov's producer decides "full" from the slot's sequence number, and
//! `tryPop` releases that sequence a couple of instructions *after* it has
//! advanced `dequeue_pos`. A producer whose read lands in between sees the
//! previous round's sequence and is told the ring is full — while the ring is
//! one slot short of full and the release is about to land. In a plain bounded
//! queue that is a conservative answer and the caller waits. Here, returning it
//! would drop a token, so `push` spins over the window instead: the retry is
//! what makes "the ring was full" mean *full*, and only that, before the assert
//! fires.
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

/// How many pool threads this phase runs (docs/RUNTIME.md §12.9). It is also the
/// number of ring slots that can be *held by a consumer inside `tryPop`* at one
/// instant — the window `push` retries over — which is why the ready ring's
/// capacity is derived from `max_pooled_workers + pool_threads` and not from the
/// workers alone.
pub const pool_threads: usize = 1;

/// How long `push` waits for a slot it was told is full, in spin rounds, before
/// it concludes the ring really is full (which, per the capacity invariant, is a
/// bug). The window it exists for is two instructions wide on the consumer side;
/// the budget is orders of magnitude larger so that a *preempted* consumer is
/// still waited out rather than blamed.
const push_retry_rounds: usize = 1 << 20;

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

    /// Any thread. False when full — which means one of two things, and only
    /// `Scheduler.push` can tell them apart: the ring *is* full (per the capacity
    /// invariant, a bug rather than a state to handle), or the consumer is
    /// between the two stores of `tryPop` and the slot is about to come back.
    /// The second is why `push` retries instead of counting.
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
    /// The pool thread, published by whoever wins `start_claim`. Only written by
    /// `start` and by the one caller `joins` lets into `shutdown`.
    thread: ?std.Thread = null,
    /// Who is inside `start` right now. `start` is called lazily by the first
    /// pooled `spawn` (D2), so two concurrent spawns arrive together: without
    /// this bit both would pass `thread != null` and both spawn a pool thread,
    /// and only the last handle would be remembered (the other would outlive
    /// `deinit`, which is a use-after-free rather than a leak).
    start_claim: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Serialises the join in `shutdown`. `shutdown` is documented as idempotent
    /// and every caller may reach it — `Application.stop`, an admin endpoint, a
    /// worker winding itself down — so "two callers at once" is a real shape, not
    /// a hypothetical. Two joiners are a double `std.Thread.join` on one handle:
    /// `EINVAL` → `unreachable` → abort.
    joins: std.Io.Mutex = .init,
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
        // Round the declared bound *up*, and add the pool threads: the index
        // arithmetic needs a power of two, rounding down would break the capacity
        // invariant, and a consumer that is inside `tryPop` still owns its slot —
        // so the producers need room for one token per worker *plus* one per
        // consumer in the dequeue window (see `push`). The floor of two is the
        // ring's own minimum (a 1-slot ring cannot tell "free" from "not read
        // yet"), and it rounds *up*, never down.
        const capacity = @max(std.math.ceilPowerOfTwo(usize, config.max_pooled_workers + pool_threads) catch
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
        /// Ring slots. `>= max_pooled_workers + pool_threads` by construction
        /// (`ceilPowerOfTwo`), which is what makes `push` infallible: room for one
        /// token per worker, plus one per consumer sitting in the dequeue window.
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

    /// Start the pool thread. Idempotent — including for two callers arriving at
    /// the **first** start together, which is the shape the lazy start invites:
    /// the first pooled `spawn` starts it, so two concurrent spawns race here.
    /// Called lazily, so declaring a pool that is never used still costs no
    /// thread (§12.8 D2).
    pub fn start(self: *Self) !void {
        while (true) {
            if (self.thread != null) return; // already running
            if (self.start_claim.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                defer self.start_claim.store(false, .release);
                self.thread = try std.Thread.spawn(.{}, poolMain, .{self});
                return;
            }
            // Another thread is in the middle of starting it: wait for that
            // attempt to conclude (the handle published, or the claim released
            // again by its failure). Spawning our own is what leaves a pool
            // thread nobody's handle points at.
            while (self.start_claim.load(.acquire)) std.atomic.spinLoopHint();
            if (self.thread == null) return error.PoolStartFailed;
        }
    }

    /// Ask the pool thread to finish, then wait for it. A batch in flight is
    /// allowed to complete: a worker that never returns still blocks shutdown
    /// (§4's rule for dedicated workers, kept for pooled ones).
    ///
    /// Safe for two threads at once: one of them joins the pool thread, the other
    /// waits behind `joins` and then finds no handle left to join. Without that,
    /// both read `self.thread` and both call `t.join()` — and a second `join` of
    /// the same handle is `EINVAL` → `unreachable` → abort (measured; see the
    /// test below).
    pub fn shutdown(self: *Self) void {
        self.stopping.store(true, .release);
        self.mu.lock(self.io) catch return;
        self.idle.broadcast(self.io);
        self.mu.unlock(self.io);
        self.joins.lockUncancelable(self.io);
        defer self.joins.unlock(self.io);
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

    /// Push a token. Infallible — see the capacity invariant at the top of this
    /// file. A failure here is counted (and asserted in Debug/ReleaseSafe) rather
    /// than swallowed, because a dropped token is a worker that stops being
    /// scheduled, not a message that gets lost.
    ///
    /// The retry is not backpressure and not a second chance: it is the only way
    /// to tell "the ring is full" from "the consumer has advanced `dequeue_pos`
    /// and has not released the slot yet" (the window `tryPop` leaves open, two
    /// instructions wide). Both readings come back as `false` from Vyukov's check,
    /// and the second one clears itself — so waiting is exactly what the first
    /// one cannot do, and treating them alike is what eats the token.
    fn push(self: *Self, item: Ready) void {
        var round: usize = 0;
        while (true) {
            if (self.ready.tryPush(item)) return;
            round += 1;
            if (round > push_retry_rounds) break;
            std.atomic.spinLoopHint();
        }
        _ = self.ready_push_failures.fetchAdd(1, .monotonic);
        std.debug.assert(false);
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
    // per worker — plus the slot a consumer holds while it is inside `tryPop` —
    // which is what makes `push` infallible (see the file header).
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

// ─────────────────────────────────────────────────
// The dequeue window, and the token it must not eat
// ─────────────────────────────────────────────────
//
// `ReadyRing.tryPop` advances `dequeue_pos` and *then* releases the slot
// (`slot.sequence = pos + capacity`). A producer that reads the slot inside
// those few instructions sees the **previous round's** sequence, which Vyukov's
// algorithm reads as "the ring is full" — while in fact the consumer has already
// left and the slot is about to be free. In a plain bounded queue that is a
// conservative answer the caller retries. Here it is not backpressure: the token
// is dropped, the worker's `queued` bit stays true, and no producer will ever
// push for it again — the worker stops being scheduled while its mailbox keeps
// accepting (see the capacity invariant at the top of this file).
//
// So `Scheduler.push` has to wait the window out. These two tests pin that: the
// first holds the window open on purpose, the second hits it for real.

/// How long a test's stand-in consumer takes between the two halves of
/// `tryPop`, in spin rounds: long enough that the producer's first read is
/// certainly in the past, short enough that a retrying push is still inside its
/// budget.
const release_delay_rounds: usize = 1 << 14;

test "scheduler: a producer waits out the slot its consumer is mid-release on" {
    var sched = try testScheduler(.{ .max_pooled_workers = 1 }); // ring capacity 2
    defer sched.deinit();
    const ring = &sched.ready;

    var a = FakeWorker{ .scheduler = sched };
    var b = FakeWorker{ .scheduler = sched };
    try std.testing.expect(ring.tryPush(a.ready()));
    try std.testing.expect(ring.tryPush(b.ready()));

    // `tryPop`, split in half by hand: the consumer has copied the value out and
    // moved `dequeue_pos` on, and has *not* released the slot yet. That is the
    // state a producer can catch it in — the window is a couple of instructions
    // wide in production, and holding it open is the only way to make the
    // interleaving an assertion instead of a hope.
    const taken = ring.slots[0].value;
    ring.dequeue_pos.store(1, .monotonic);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&a)), taken.ctx);
    // One token left in a two-slot ring: there is room, and the ring says so.
    try std.testing.expectEqual(@as(usize, 1), ring.len());
    try std.testing.expect(ring.len() < ring.capacity());

    const HalfPop = struct {
        fn run(r: *ReadyRing, entered: *std.atomic.Value(bool)) void {
            while (!entered.load(.acquire)) std.atomic.spinLoopHint();
            var i: usize = 0;
            while (i < release_delay_rounds) : (i += 1) std.atomic.spinLoopHint();
            r.slots[0].sequence.store(0 +% r.slots.len, .release); // the second half
        }
    };
    var entered = std.atomic.Value(bool).init(false);
    const releaser = try std.Thread.spawn(.{}, HalfPop.run, .{ ring, &entered });

    var c = FakeWorker{ .scheduler = sched };
    entered.store(true, .release);
    sched.push(c.ready()); // must wait for the release, not report "full"
    releaser.join();

    // The push landed: the third token is in the ring, and the counter that says
    // "a worker stopped being scheduled" reads zero.
    try std.testing.expectEqual(@as(usize, 2), sched.readyLen());
    try std.testing.expectEqual(@as(u64, 0), sched.stats().ready_push_failures);
}

test "scheduler: a hammered ring never eats a token" {
    // The rate version: producers hammer `push` while a consumer drains, so the
    // window is met for real. Every refusal in this ring is a token the pool
    // would never see again — nothing here is backpressure.
    const producers = 4;
    const per_producer = 20_000;
    var sched = try testScheduler(.{ .max_pooled_workers = 3 }); // ring capacity 4
    defer sched.deinit();

    var fakes: [4]FakeWorker = @splat(FakeWorker{});
    var items: [4]Ready = undefined;
    for (&fakes, &items) |*fake, *item| {
        fake.scheduler = sched;
        item.* = fake.ready();
    }

    var stop = std.atomic.Value(bool).init(false);
    const Drain = struct {
        fn run(s: *Scheduler, done: *std.atomic.Value(bool)) void {
            while (!done.load(.acquire)) {
                if (s.ready.tryPop() == null) std.atomic.spinLoopHint();
            }
        }
    };
    const drain = try std.Thread.spawn(.{}, Drain.run, .{ sched, &stop });

    const Hammer = struct {
        fn run(s: *Scheduler, batch: []const Ready, n: usize) void {
            for (0..n) |i| s.push(batch[i % batch.len]);
        }
    };
    var threads: [producers]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Hammer.run, .{ sched, &items, per_producer });
    for (threads) |t| t.join();
    stop.store(true, .release);
    drain.join();

    try std.testing.expectEqual(@as(u64, 0), sched.stats().ready_push_failures);
}

/// The live thread count, with a linger guard: a thread that has just returned
/// can still be listed for a moment, and this measurement is used as a *delta*,
/// so a body being reaped must not read as a live one. Two readings, the lower.
fn settledThreadCount() ?usize {
    const first = liveThreadCount() orelse return null;
    var spins: usize = 0;
    while (spins < 200_000) : (spins += 1) std.atomic.spinLoopHint();
    return @min(first, liveThreadCount() orelse return null);
}

/// How many OS threads this process runs right now, or null where the platform
/// cannot be asked. The lazy start's race leaks a pool thread whose handle was
/// never stored, so no counter inside the scheduler can see it: the OS is the
/// only witness.
fn liveThreadCount() ?usize {
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .macos => {
            var ports: std.c.mach_port_array_t = undefined;
            var count: std.c.mach_msg_type_number_t = 0;
            if (std.c.task_threads(std.c.mach_task_self(), &ports, &count) != 0) return null;
            // The port array is handed to us; releasing it is our job.
            _ = std.c.vm_deallocate(
                std.c.mach_task_self(),
                @intFromPtr(ports),
                @as(std.c.vm_size_t, count) * @sizeOf(std.c.mach_port_t),
            );
            return count;
        },
        .linux => {
            const dir = std.c.opendir("/proc/self/task") orelse return null;
            defer _ = std.c.closedir(dir);
            var n: usize = 0;
            while (std.c.readdir(dir)) |entry| {
                if (std.ascii.isDigit(entry.name[0])) n += 1;
            }
            return n;
        },
        else => return null,
    }
}

test "scheduler: two concurrent first starts spawn exactly one pool thread" {
    // `start()` is lazy (D2: a declared pool costs no thread until it is used),
    // so two threads can arrive at the *first* start together — two `.pooled`
    // spawns racing. `if (self.thread != null) return` is a check and an act with
    // a thread spawn in between: both pass it and both spawn. Only one handle is
    // remembered, so `shutdown` joins one, and the other keeps running into
    // `Scheduler.deinit`'s frees.
    // Both callers stay alive until the counting is done, so the delta is only
    // "what the two `start()` calls spawned" — a joined thread's bookkeeping
    // cannot blur it.
    const Race = struct {
        fn run(
            s: *Scheduler,
            gate: *std.atomic.Value(u32),
            done: *std.atomic.Value(u32),
            release: *std.atomic.Value(bool),
            ok: *std.atomic.Value(bool),
        ) void {
            _ = gate.fetchAdd(1, .acq_rel);
            while (gate.load(.acquire) < 2) std.atomic.spinLoopHint();
            s.start() catch ok.store(false, .release);
            _ = done.fetchAdd(1, .acq_rel);
            while (!release.load(.acquire)) std.atomic.spinLoopHint();
        }
    };

    for (0..4) |_| {
        var sched = try testScheduler(.{ .max_pooled_workers = 1 });
        const before = settledThreadCount() orelse {
            // No way to count on this platform: the race still runs, it just
            // cannot be asserted on.
            sched.deinit();
            return;
        };

        var gate = std.atomic.Value(u32).init(0);
        var done = std.atomic.Value(u32).init(0);
        var release = std.atomic.Value(bool).init(false);
        var ok = std.atomic.Value(bool).init(true);
        const a = try std.Thread.spawn(.{}, Race.run, .{ sched, &gate, &done, &release, &ok });
        const b = try std.Thread.spawn(.{}, Race.run, .{ sched, &gate, &done, &release, &ok });
        gate.store(2, .release);
        var spins: usize = 0;
        while (done.load(.acquire) < 2) : (spins += 1) {
            if (spins > 1_000_000_000) return error.StartNeverReturned;
            std.atomic.spinLoopHint();
        }

        // Two callers, one pool thread: `before + 2 (the callers) + 1`.
        try std.testing.expectEqual(before + 3, settledThreadCount().?);
        try std.testing.expect(ok.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), sched.stats().pool_threads);

        release.store(true, .release);
        a.join();
        b.join();
        sched.deinit();
    }
}
