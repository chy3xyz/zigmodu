//! Scheduler — the *pooled* execution mode of `Runtime.spawn`
//! (docs/RUNTIME.md §12; `queued`/`claimed`, a ready ring, `pool_threads` pool
//! threads — Phase 2; the default width of 1 is the Phase 1 shape, so an
//! app that declares a pool and no width keeps running exactly what it ran
//! before).
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
//! ## One protocol, one or two pools (docs/RUNTIME.md §6)
//!
//! This type is the whole pool: ring, threads, admission bound, protocol. A
//! runtime that declares a *blocking* pool (`SchedulerConfig.blocking_threads`)
//! builds a **second instance** of it rather than widening this one — a
//! `handle` that blocks on a DB round trip holds the pool thread it was given,
//! and the only way to guarantee it cannot hold the one a `.cpu` worker needs is
//! for the two to share nothing. Each instance keeps every invariant below
//! unchanged (per-worker claim, one token per worker, infallible push), because
//! each is sized and admitted from its own declared bound.
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
///
/// **Two pools, one protocol.** A runtime may declare a *blocking* pool as well
/// (docs/RUNTIME.md §6): a `.blocking` worker runs on a second `Scheduler` built
/// from `blocking_threads` / `max_blocking_workers`, with its own ready ring,
/// its own threads and its own admission bound. Nothing about the protocol
/// changes — the two rings share no state — which is exactly what makes "a
/// blocked blocking worker cannot occupy a CPU-pool thread" a structural fact
/// rather than a hope. Left undeclared (`blocking_threads = 0`) there is only the
/// pool that existed before the class was introduced, and `.blocking` is a
/// configuration error at `spawn`.
pub const SchedulerConfig = struct {
    /// Upper bound on `.pooled` workers of the **`.cpu`** class this runtime will
    /// spawn. `0` = no pool: the runtime starts no pool thread, and
    /// `.mode = .pooled` is a configuration error at `spawn`.
    max_pooled_workers: usize = 0,
    /// How many threads consume the ready ring (docs/RUNTIME.md §12.12). It is
    /// also the number of ring slots that can be *held by a consumer inside
    /// `tryPop`* at one instant — the window `push` retries over — which is why
    /// the ready ring's capacity is derived from `max_pooled_workers +
    /// pool_threads` and not from the workers alone. `1` (the default) is the
    /// Phase 1 shape: one thread, one consumer of the ring.
    pool_threads: usize = default_pool_threads,
    /// D3's starting point. `1` is the latency end (one message per claim, every
    /// message pays a ring round trip), the mailbox capacity the throughput end
    /// (one slow handler starves every other ready worker). 16 is a first
    /// measurement, not a conclusion — see docs/RUNTIME.md §12.9.
    batch: usize = default_batch,
    /// How many threads run workers declared `.execution_class = .blocking`, i.e.
    /// whether this runtime has a blocking pool at all (docs/RUNTIME.md §6).
    /// `0` (the default) = none, and `.blocking` is then refused at `spawn`
    /// (`error.BlockingPoolNotConfigured`) instead of quietly sharing the pool a
    /// handler that blocks would hold down — the same discipline D2 applies to
    /// `.pooled` without a declared pool.
    blocking_threads: usize = 0,
    /// Upper bound on `.blocking` workers, the way `max_pooled_workers` bounds the
    /// `.cpu` class: the blocking pool's ring is sized from it and the (N+1)-th
    /// `.blocking` spawn is refused (`error.PoolCapacityExceeded`).
    ///
    /// `0` = "the same number as `max_pooled_workers`", so a runtime that declares
    /// one bound gets two pools of that declared size. The two bounds are
    /// separate admissions, not a split of one: `max_pooled_workers` no longer
    /// describes the blocking class once a blocking pool is declared, and the
    /// runtime's total is bounded by the sum. Declaring the second bound — and
    /// stating the rule here — is the alternative to silently widening a limit
    /// someone already relies on.
    max_blocking_workers: usize = 0,
};

pub const default_batch: usize = 16;

/// Phase 1's pool width, and the default: a runtime that declares a pool but not
/// a width runs exactly one pool thread (docs/RUNTIME.md §12.12).
pub const default_pool_threads: usize = 1;

/// How long `push` waits for a slot it was told is full, in spin rounds, before
/// it concludes the ring really is full (which, per the capacity invariant, is a
/// bug). The window it exists for is two instructions wide on the consumer side;
/// the budget is orders of magnitude larger so that a *preempted* consumer is
/// still waited out rather than blamed.
const push_retry_rounds: usize = 1 << 20;

/// A pool thread's spin budget before it parks, and how long it parks. Parking is
/// a poll rather than a signal on purpose: a `signal` per publish would put a
/// mutex (or a syscall) on the producer path this whole design keeps free.
///
/// One budget covers **both** ways a turn can end without running anything — an
/// empty ring and a token whose worker another thread is already executing — so
/// a worker that is busy cannot keep N-1 threads spinning (§12.12). The cost of
/// the poll is that the token a claim-holder re-arms can be picked up one
/// `idle_wait_ms` later instead of immediately.
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
/// invariant at the top of this file. Any number of producers, and any number of
/// consumers: `pool_threads` (§12.12; the ring is MPMC, and the multi-consumer
/// tests below are what keeps it that way).
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
                const seen = self.dequeue_pos.load(.monotonic);
                // Read the consumer's cursor **before** publishing, not after.
                // `high_water` only ever grows, so one underflow poisons it for
                // the life of the ring — and the subtraction *can* underflow:
                // once this store is visible, a consumer may drain this slot
                // and another producer's higher-numbered one, pushing
                // `dequeue_pos` past `pos + 1`. Reading first makes the depth a
                // safe over-estimate: before the store no consumer can see this
                // slot, so `dequeue_pos <= pos` and `pos + 1 - dequeue_pos` is
                // at least 1. (Measured: with two producers this read
                // 18446744073709551615 on every run of
                // `zig build runtime-stress`, and that value is published as
                // `zigmodu_runtime_pool_ready_high_water`.)
                slot.value = item;
                slot.sequence.store(pos +% 1, .release);
                const depth = (pos +% 1) -% seen;
                if (depth > self.high_water.load(.monotonic)) self.high_water.store(depth, .monotonic);
                return true;
            } else if (diff < 0) {
                return false;
            } else {
                pos = self.enqueue_pos.load(.monotonic);
            }
        }
    }

    /// Any thread, and by any number of them. Null when empty, or when the slot
    /// this consumer was looking at is not ready yet.
    ///
    /// **Multi-consumer by construction** (§12.12). Phase 1 claimed the position,
    /// read the slot and stored `pos + 1` — three steps that only one consumer
    /// could take: two threads reading the same position both found the token
    /// ready and both handed it out, running one worker twice (§12.3), and the
    /// double store of the slot's sequence left a token that no consumer could
    /// ever pop again (the worker then stops being scheduled while its mailbox
    /// keeps accepting). The claim is a CAS on `dequeue_pos` here, so exactly one
    /// consumer takes a given position, and the slot is released only after the
    /// value has been copied out.
    fn tryPop(self: *Self) ?Ready {
        var pos = self.dequeue_pos.load(.monotonic);
        while (true) {
            const slot = &self.slots[pos & self.mask];
            const seq = slot.sequence.load(.acquire);
            const diff = @as(isize, @bitCast(seq -% (pos +% 1)));
            if (diff == 0) {
                if (self.dequeue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                    pos = actual;
                    continue;
                }
                const item = slot.value;
                slot.sequence.store(pos +% self.slots.len, .release);
                return item;
            } else if (diff < 0) {
                return null;
            } else {
                pos = self.dequeue_pos.load(.monotonic);
            }
        }
    }

    fn len(self: *const Self) usize {
        return self.enqueue_pos.load(.acquire) -% self.dequeue_pos.load(.acquire);
    }
};

/// The pool. Owned by `Runtime`, created when the pool is declared, and it
/// starts no thread until a pooled worker is actually spawned.
///
/// A runtime owns one of these per execution class it declares: `Runtime.scheduler`
/// for `.cpu`, `Runtime.blocking_scheduler` for `.blocking` (docs/RUNTIME.md §6).
/// A worker is admitted by exactly one of them, and its `pool` link points at that
/// one — so `announce`, the hand-back re-check and `join` all stay in the pool
/// that owns it, with no class anywhere in the protocol.
pub const Scheduler = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    ready: ReadyRing,
    /// The declared bound the ring's capacity was derived from.
    max_pooled_workers: usize,
    /// How many pool threads this scheduler runs, and how many of them consume
    /// the ready ring concurrently. Fixed at construction (§12.12).
    pool_threads: usize,
    batch: usize,
    /// Slots taken by `spawn`, never more than `max_pooled_workers`.
    spawned: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Workers a pool thread is executing *right now* — one per claim held.
    /// §12.3's exclusivity is what makes this readable: a claimed worker is
    /// owned by exactly one thread, so the count cannot be double-taken, and its
    /// ceiling is `pool_threads`.
    claimed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// One slot per declared pool thread, allocated here — once, off the
    /// scheduling path (the zero-allocation contract in
    /// `src/runtime/alloc_contract_test.zig` covers this file).
    threads: []std.Thread,
    /// How many of `threads` are live, published by whoever wins `start_claim`
    /// (and zeroed by whoever wins `joins` in `shutdown`). This is the count
    /// `stats().pool_threads` reports: with more than one thread, "the pool is
    /// deployed" and "how wide is it" are two different questions, and a reading
    /// that answered the first one for both would make `claimed ≤ pool_threads`
    /// meaningless.
    started: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Who is inside `start` right now. `start` is called lazily by the first
    /// pooled `spawn` (D2), so two concurrent spawns arrive together: without
    /// this bit both would pass the "already started" check and both spawn pool
    /// threads, and only the last set of handles would be remembered (the others
    /// would outlive `deinit`, which is a use-after-free rather than a leak).
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
    /// Tokens that entered the ring, monotonically. A pool thread reads it before
    /// a scheduling attempt and again before parking: unchanged means the ring
    /// holds exactly what that attempt already looked at (see `poolMain`), which
    /// is the one condition under which sleeping cannot miss work — a skipped
    /// token, an empty ring and a ring whose tokens are all claimed by other
    /// threads are all "nothing changed".
    pushes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
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
        // A pool with no consumer can only strand tokens, so one thread is the
        // floor whatever was declared (§12.12).
        const threads_n = @max(config.pool_threads, 1);
        // Round the declared bound *up*, and add the pool threads: the index
        // arithmetic needs a power of two, rounding down would break the capacity
        // invariant, and a consumer that is inside `tryPop` still owns its slot —
        // so the producers need room for one token per worker *plus* one per
        // consumer in the dequeue window (see `push`). The floor of two is the
        // ring's own minimum (a 1-slot ring cannot tell "free" from "not read
        // yet"), and it rounds *up*, never down.
        const capacity = @max(std.math.ceilPowerOfTwo(usize, config.max_pooled_workers + threads_n) catch
            return error.PoolTooLarge, 2);
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        const threads = try allocator.alloc(std.Thread, threads_n);
        errdefer allocator.free(threads);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .ready = try ReadyRing.init(allocator, capacity),
            .max_pooled_workers = config.max_pooled_workers,
            .pool_threads = threads_n,
            .batch = config.batch,
            .threads = threads,
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
        /// How many pool threads this scheduler has running: the declared width
        /// once the pool is up, `0` before the first pooled worker (or after
        /// `shutdown`) — which is also the ceiling `claimed` cannot exceed
        /// (§12.9 · 4). Two readings of one fact, so `running` is `pool_threads
        /// != 0` and a scrape cannot see them disagree.
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
        ///
        /// **With one pool thread this is provably 0** — the only thread that can
        /// hand a claim back is the only one that can pop again, and by then the
        /// claim is free — so it reads as a defect signal. With more than one it
        /// is a normal reading: two threads can be at the same worker's token at
        /// once (one running it, one arriving after the hand-back started), and
        /// the skip is the protocol working (docs/RUNTIME.md §12.12).
        claim_misses: u64,
        /// Must stay 0. See the capacity invariant.
        ready_push_failures: u64,
        idle_waits: u64,
        ready_high_water: usize,
    };

    pub fn deinit(self: *Self) void {
        self.shutdown();
        self.ready.deinit(self.allocator);
        self.allocator.free(self.threads);
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

    /// Start the pool threads. Idempotent — including for two callers arriving at
    /// the **first** start together, which is the shape the lazy start invites:
    /// the first pooled `spawn` starts it, so two concurrent spawns race here.
    /// Called lazily, so declaring a pool that is never used still costs no
    /// thread (§12.8 D2).
    ///
    /// The width comes from `SchedulerConfig.pool_threads` and is fixed here: the
    /// whole set is spawned under one `start_claim`, so "started" stays a single
    /// yes/no fact rather than a count racing N spawns.
    pub fn start(self: *Self) !void {
        while (true) {
            if (self.started.load(.acquire) != 0) return; // already running
            if (self.start_claim.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                defer self.start_claim.store(false, .release);
                return self.spawnThreads();
            }
            // Another thread is in the middle of starting it: wait for that
            // attempt to conclude (the count published, or the claim released
            // again by its failure). Spawning our own is what leaves a pool
            // thread nobody's handle points at.
            while (self.start_claim.load(.acquire)) std.atomic.spinLoopHint();
            if (self.started.load(.acquire) == 0) return error.PoolStartFailed;
        }
    }

    /// Spawn the declared set. Called under `start_claim`.
    fn spawnThreads(self: *Self) !void {
        var up: usize = 0;
        while (up < self.threads.len) : (up += 1) {
            self.threads[up] = std.Thread.spawn(.{}, poolMain, .{self}) catch |err| {
                // A half-started pool is one no reading can describe: wind the
                // threads that are already up back down and report the failure,
                // so `start` stays all-or-nothing. `stopping` is put back so a
                // later attempt can still succeed.
                self.stopThreads(up);
                self.stopping.store(false, .release);
                return err;
            };
        }
        self.started.store(up, .release);
    }

    /// Ask threads `[0..n)` to finish and wait for them. Used by `shutdown` and
    /// by `spawnThreads`' failure path.
    fn stopThreads(self: *Self, n: usize) void {
        self.stopping.store(true, .release);
        self.wakeIdle();
        for (self.threads[0..n]) |t| t.join();
    }

    /// Wake every parked pool thread so it re-reads `stopping`.
    fn wakeIdle(self: *Self) void {
        self.mu.lock(self.io) catch return;
        self.idle.broadcast(self.io);
        self.mu.unlock(self.io);
    }

    /// Ask the pool threads to finish, then wait for them. A batch in flight is
    /// allowed to complete: a worker that never returns still blocks shutdown
    /// (§4's rule for dedicated workers, kept for pooled ones).
    ///
    /// Safe for two threads at once: one of them joins the threads, the other
    /// waits behind `joins` and then finds no handles left to join — the count is
    /// *taken* (swapped to zero) rather than read, so a handle is joined exactly
    /// once. Without that, both callers iterate the same handles and the second
    /// `join` of the same handle is `EINVAL` → `unreachable` → abort (measured;
    /// see the test below).
    pub fn shutdown(self: *Self) void {
        self.stopping.store(true, .release);
        self.wakeIdle();
        self.joins.lockUncancelable(self.io);
        defer self.joins.unlock(self.io);
        // A `start` in flight holds `start_claim` while it spawns: publishing a
        // handle after this function has decided what to join is the one shape
        // that leaves a pool thread running into `deinit`'s frees, so wait that
        // attempt out first (`stopping` above already tells it to give up).
        while (self.start_claim.load(.acquire)) std.atomic.spinLoopHint();
        const n = self.started.swap(0, .acq_rel);
        for (self.threads[0..n]) |t| t.join();
    }

    pub fn stats(self: *Self) Stats {
        // Read once: `running` and `pool_threads` are two readings of the same
        // fact, and a scrape should not be able to see them disagree.
        const live = self.started.load(.monotonic);
        return .{
            .max_pooled_workers = self.max_pooled_workers,
            .ready_capacity = self.ready.capacity(),
            .ready_len = self.ready.len(),
            .spawned = self.spawned.load(.monotonic),
            .running = live != 0,
            .pool_threads = live,
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
            if (self.ready.tryPush(item)) {
                // Published *after* the token is in the ring, so a pool thread
                // that read a different value is looking at a ring that changed
                // (`poolMain`'s park guard). Only a successful push counts:
                // the reading is "the ring gained a token", not "somebody tried".
                _ = self.pushes.fetchAdd(1, .release);
                return;
            }
            round += 1;
            if (round > push_retry_rounds) break;
            std.atomic.spinLoopHint();
        }
        _ = self.ready_push_failures.fetchAdd(1, .monotonic);
        std.debug.assert(false);
    }

    /// What one scheduling turn did. `poolMain` needs the difference between the
    /// last two: an empty ring and a ring full of tokens it cannot run are the
    /// same thing to a spinner and different things to a scheduler (§12.12).
    const Turn = enum {
        /// A token was popped and its worker ran.
        ran,
        /// A token was popped whose worker another pool thread is executing: it
        /// went back into the ring (see below).
        skipped,
        /// The ring was empty.
        empty,
    };

    /// One scheduling turn: pop a token, run its worker. The pool loop calls this;
    /// tests call it directly, without a thread, which is how the protocol below
    /// is pinned down. `step` is the `bool` view of `turn` ("did anything
    /// happen?") that those tests were written against.
    fn step(self: *Self) bool {
        return self.turn() != .empty;
    }

    fn turn(self: *Self) Turn {
        const item = self.ready.tryPop() orelse return .empty;
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
            return .skipped;
        }
        _ = self.dispatches.fetchAdd(1, .monotonic);
        _ = self.claimed.fetchAdd(1, .monotonic);
        self.runOne(item);
        return .ran;
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
            // Read before the attempt: a token published after this point is what
            // makes the park below unnecessary.
            const published = self.pushes.load(.acquire);
            if (self.turn() == .ran) {
                spun = 0;
                continue;
            }
            // Nothing ran, and there are two shapes of that: the ring is empty
            // (somebody has to send), or it holds tokens whose workers are being
            // executed *right now* by other pool threads (somebody has to hand a
            // claim back). Neither is sped up by spinning harder, and the second
            // one used to reset the budget — so a token nobody could claim kept
            // N-1 threads at full speed for as long as the batch took (§12.12:
            // 1 thread → 0 skip-turns/s, 4 threads → ~2.7M/s). Sharing the budget
            // between both shapes is what turns that into a park.
            if (spun < spin_rounds) {
                spun += 1;
                std.atomic.spinLoopHint();
                continue;
            }
            // Park on the condition until `shutdown` broadcasts or the poll times
            // out. Same shape as the ticker's idle loop — and a poll rather than a
            // signal on purpose: the producers' path stays free of mutexes, so the
            // cost of a missed wake-up is one poll interval.
            self.mu.lock(self.io) catch return;
            // Sleep only if the ring is exactly what the attempt above saw: a push
            // that landed while we were spinning (including one for a token that
            // just became claimable) is work to look at, not a reason to sleep.
            if (self.pushes.load(.acquire) == published and !self.stopping.load(.acquire)) {
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
            spun = 0;
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

// ─────────────────────────────────────────────────
// The ring under N consumers (Phase 2, docs/RUNTIME.md §12.12)
// ─────────────────────────────────────────────────
//
// Every test above drives the ring from **one** consumer, which is what Phase 1
// shipped and what its `dequeue_pos` handling was written for: load the
// position, read the slot, store `pos + 1`. Two threads doing that can both read
// the same position before either stores, hand the *same* token to two pool
// threads, and leave a slot sequence that makes some other token unpoppable
// forever. Token identity is what makes both halves visible: a duplicate means §12.3's
// state exclusivity has already been violated (two threads will run one worker),
// and a loss means that worker is never scheduled again.

/// A `Ready` that carries its own identity — the token number in `ctx` — with
/// none of the worker machinery behind it. These tests exercise the ring, and a
/// ring hands back values, not workers: nothing here dereferences `scheduler`,
/// `dispatch` or `pending`.
fn numberedToken(id: usize) Ready {
    return .{
        .scheduler = undefined,
        .ctx = @ptrFromInt(id + 1), // the id is the payload
        .claimed = &numbered_claimed,
        .queued = &numbered_queued,
        .dispatch = numberedDispatch,
        .pending = numberedPending,
    };
}

var numbered_claimed = std.atomic.Value(bool).init(false);
var numbered_queued = std.atomic.Value(bool).init(false);

fn numberedDispatch(_: *anyopaque, _: usize) bool {
    return true;
}

fn numberedPending(_: *anyopaque) usize {
    return 0;
}

fn tokenId(item: Ready) usize {
    return @intFromPtr(item.ctx) - 1;
}

/// How long a producer retries a full ring before it records a give-up, and how
/// long a consumer spins over a ring that has stopped moving. Both are
/// *budgets*, not timeouts: they exist so a wedged ring reports a failed
/// assertion instead of hanging the suite — and they stay small enough that the
/// failing case costs milliseconds, not minutes.
const ring_retry_budget: usize = 1 << 20;

/// How long a *test* producer waits for room in a mailbox before it counts the
/// message as refused backpressure. Same purpose as `ring_retry_budget`, and it
/// keeps the live runs carrying traffic instead of bouncing off the mailbox
/// capacity (a producer that gives up immediately measures the mailbox, not the
/// pool).
const producer_retry_budget: usize = 1 << 22;

test "scheduler: two consumers race one token and exactly one of them gets it" {
    // The sharpest form of the multi-consumer defect, and the one nothing above
    // can see: one token in the ring, two consumers released at the same instant.
    // A second `Some` in the same round is the ring handing one token to two
    // threads — the state exclusivity §12.3 rests on is already gone by then.
    const rounds = 50_000;
    var sched = try testScheduler(.{ .max_pooled_workers = 1, .pool_threads = 2 });
    defer sched.deinit();
    const ring = &sched.ready;

    const stop_marker = std.math.maxInt(u32);
    // The gate counts *releases*, not rounds: it starts at 0, which has to mean
    // "no round is open yet" — storing the round number itself would make the
    // initial value indistinguishable from "round 0 is open", and a consumer that
    // ran round 0 before the push would tell the main thread it had looked when
    // there was nothing to look at (measured: `expected 1, found 0`).
    var gate = std.atomic.Value(u32).init(0);
    var done = std.atomic.Value(u32).init(0);
    var wins = std.atomic.Value(u32).init(0);

    const Consumer = struct {
        const stop = std.math.maxInt(u32);
        fn run(r: *ReadyRing, g: *std.atomic.Value(u32), d: *std.atomic.Value(u32), w: *std.atomic.Value(u32), n: usize) void {
            var round: usize = 0;
            while (round < n) : (round += 1) {
                const released: u32 = @intCast(round + 1);
                while (g.load(.acquire) != released) {
                    if (g.load(.acquire) == stop) return;
                    std.atomic.spinLoopHint();
                }
                if (r.tryPop() != null) _ = w.fetchAdd(1, .acq_rel);
                _ = d.fetchAdd(1, .acq_rel);
            }
        }
    };
    const a = try std.Thread.spawn(.{}, Consumer.run, .{ ring, &gate, &done, &wins, rounds });
    defer a.join();
    const b = try std.Thread.spawn(.{}, Consumer.run, .{ ring, &gate, &done, &wins, rounds });
    defer b.join();
    // Registered after the joins, so it runs *before* them (LIFO): a failed
    // assertion must release both consumers, or the joins would wait on a gate
    // value that never arrives.
    errdefer gate.store(stop_marker, .release);

    for (0..rounds) |round| {
        try std.testing.expect(ring.tryPush(numberedToken(round)));
        gate.store(@intCast(round + 1), .release);
        var spins: usize = 0;
        while (done.load(.acquire) != 2 * (round + 1)) : (spins += 1) {
            try std.testing.expect(spins < 1 << 32);
            std.atomic.spinLoopHint();
        }
        try std.testing.expectEqual(@as(u32, @intCast(round + 1)), wins.load(.acquire));
    }
}

test "scheduler: a hammered ring hands every token to exactly one consumer" {
    // The rate version of the same thing, and the shape the defect is measured
    // in: many producers, many consumers, no per-round synchronisation. Every
    // token must come out **exactly once** — twice is two threads handed one
    // token, zero times is a token the ring swallowed.
    const producers = 4;
    const consumers = 4;
    const per_producer = 5_000;
    const total = producers * per_producer;

    var sched = try testScheduler(.{
        .max_pooled_workers = 1,
        .pool_threads = consumers,
    });
    defer sched.deinit();
    const ring = &sched.ready;

    const seen = try std.testing.allocator.alloc(std.atomic.Value(u32), total);
    defer std.testing.allocator.free(seen);
    for (seen) |*s| s.* = std.atomic.Value(u32).init(0);
    var popped = std.atomic.Value(u64).init(0);
    var push_failures = std.atomic.Value(u64).init(0);
    var producers_done = std.atomic.Value(u32).init(0);

    const Producer = struct {
        fn run(r: *ReadyRing, base: usize, n: usize, fails: *std.atomic.Value(u64), done: *std.atomic.Value(u32)) void {
            for (0..n) |k| {
                const item = numberedToken(base + k);
                var spins: usize = 0;
                while (!r.tryPush(item)) {
                    spins += 1;
                    if (spins > ring_retry_budget) {
                        // Stop at the first give-up: a ring that refuses a push
                        // for this long is already the finding, and hammering it
                        // for the rest of the batch would only make the failure
                        // slow to report.
                        _ = fails.fetchAdd(1, .monotonic);
                        _ = done.fetchAdd(1, .acq_rel);
                        return;
                    }
                    std.atomic.spinLoopHint();
                }
            }
            _ = done.fetchAdd(1, .acq_rel);
        }
    };
    const Consumer = struct {
        fn run(
            r: *ReadyRing,
            seen_: []std.atomic.Value(u32),
            popped_: *std.atomic.Value(u64),
            total_: usize,
            done: *std.atomic.Value(u32),
            n_producers: u32,
        ) void {
            while (true) {
                if (popped_.load(.acquire) >= total_) return;
                if (r.tryPop()) |item| {
                    _ = seen_[tokenId(item)].fetchAdd(1, .monotonic);
                    _ = popped_.fetchAdd(1, .acq_rel);
                    continue;
                }
                // Nothing came out. Once every producer has finished, a ring that
                // keeps yielding nothing is not going to yield anything: report
                // the shortfall (the assertions below) instead of spinning.
                if (done.load(.acquire) == n_producers) {
                    var spins: usize = 0;
                    while (spins <= ring_retry_budget) : (spins += 1) {
                        if (r.tryPop()) |item| {
                            _ = seen_[tokenId(item)].fetchAdd(1, .monotonic);
                            _ = popped_.fetchAdd(1, .acq_rel);
                            break;
                        }
                        std.atomic.spinLoopHint();
                    }
                    if (spins > ring_retry_budget) return;
                    continue;
                }
                std.atomic.spinLoopHint();
            }
        }
    };

    var consumer_threads: [consumers]std.Thread = undefined;
    for (&consumer_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Consumer.run, .{
            ring, seen, &popped, total, &producers_done, producers,
        });
    }
    var producer_threads: [producers]std.Thread = undefined;
    for (&producer_threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Producer.run, .{
            ring, i * per_producer, per_producer, &push_failures, &producers_done,
        });
    }
    for (producer_threads) |t| t.join();
    for (consumer_threads) |t| t.join();

    // Identity first: "came out twice" and "never came out" are the two ways the
    // contract breaks, and both are worth reporting before the counters below.
    for (seen, 0..) |s, i| {
        if (s.load(.acquire) != 1) {
            std.debug.print("ring: token {d} came out {d} times\n", .{ i, s.load(.acquire) });
            return error.TokenNotDeliveredExactlyOnce;
        }
    }
    try std.testing.expectEqual(@as(u64, total), popped.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), push_failures.load(.acquire));
}

test "scheduler: four consumers released together still hand one token out once" {
    // The two-consumer test above is the minimal shape of the race; this is the
    // same race widened. The protocol has no count in it, but the number of
    // *pairs* that can read one position before either claims it grows with the
    // consumers, so a dequeue that claims by store (`load -> read -> store`) is
    // caught in fewer rounds here. It fails the same way: a second winner in a
    // round is one token handed to two threads (§12.3's state exclusivity is
    // already gone by the time the worker runs).
    const consumers = 4;
    const rounds = 20_000;
    var sched = try testScheduler(.{ .max_pooled_workers = 1, .pool_threads = consumers });
    defer sched.deinit();
    const ring = &sched.ready;

    const stop_marker = std.math.maxInt(u32);
    var gate = std.atomic.Value(u32).init(0);
    var done = std.atomic.Value(u32).init(0);
    var wins = std.atomic.Value(u32).init(0);

    const Consumer = struct {
        const stop = std.math.maxInt(u32);
        fn run(r: *ReadyRing, g: *std.atomic.Value(u32), d: *std.atomic.Value(u32), w: *std.atomic.Value(u32), n: usize) void {
            var round: usize = 0;
            while (round < n) : (round += 1) {
                const released: u32 = @intCast(round + 1);
                while (g.load(.acquire) != released) {
                    if (g.load(.acquire) == stop) return;
                    std.atomic.spinLoopHint();
                }
                if (r.tryPop() != null) _ = w.fetchAdd(1, .acq_rel);
                _ = d.fetchAdd(1, .acq_rel);
            }
        }
    };
    var threads: [consumers]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Consumer.run, .{ ring, &gate, &done, &wins, rounds });
    defer {
        for (threads) |t| t.join();
    }
    // Registered after the joins, so it runs *before* them (LIFO): a failed
    // assertion must release every consumer, or the joins would wait on a gate
    // value that never arrives.
    errdefer gate.store(stop_marker, .release);

    for (0..rounds) |round| {
        try std.testing.expect(ring.tryPush(numberedToken(round)));
        gate.store(@intCast(round + 1), .release);
        var spins: usize = 0;
        while (done.load(.acquire) != consumers * (round + 1)) : (spins += 1) {
            try std.testing.expect(spins < 1 << 32);
            std.atomic.spinLoopHint();
        }
        // One token, `consumers` consumers, one winner — every round.
        try std.testing.expectEqual(@as(u32, @intCast(round + 1)), wins.load(.acquire));
    }
}

test "scheduler: the declared occupancy pushes cleanly, round after round" {
    // `push` is infallible at the occupancy the capacity was declared for, and
    // that has to survive repetition: `max_pooled_workers + pool_threads` tokens
    // fit, every round, with no refusal. The `+ pool_threads` half is what keeps a
    // consumer inside `tryPop` from costing a producer its slot — the Phase 1
    // sizing (the bound alone) refuses the same script in its first round, which
    // is asserted below.
    const bound = 4;
    const width = 3; // bound + width = 7 > ceilPowerOfTwo(bound) = 4
    const rounds = 500;
    const phase1_capacity = @max(try std.math.ceilPowerOfTwo(usize, bound), 2);
    const consumer_capacity = @max(try std.math.ceilPowerOfTwo(usize, bound + width), 2);
    try std.testing.expect(phase1_capacity < bound + width);

    var sched = try testScheduler(.{ .max_pooled_workers = bound, .pool_threads = width });
    defer sched.deinit();
    const ring = &sched.ready;
    // The Scheduler's ring is the one the declared width pays for, not a ring
    // built by hand in the test.
    try std.testing.expectEqual(consumer_capacity, ring.capacity());

    for (0..rounds) |_| {
        for (0..bound + width) |i| {
            try std.testing.expect(ring.tryPush(numberedToken(i)));
        }
        // ...and every one of them comes back, in order, exactly once.
        for (0..bound + width) |i| {
            try std.testing.expectEqual(i, tokenId(ring.tryPop().?));
        }
        try std.testing.expectEqual(@as(usize, 0), ring.len());
    }
    try std.testing.expectEqual(@as(u64, 0), sched.stats().ready_push_failures);

    var legacy = try ReadyRing.init(std.testing.allocator, phase1_capacity);
    defer legacy.deinit(std.testing.allocator);
    for (0..bound + width) |i| {
        // The rings hold the same token count; only the sizing differs.
        if (i < phase1_capacity) {
            try std.testing.expect(legacy.tryPush(numberedToken(i)));
        } else {
            try std.testing.expect(!legacy.tryPush(numberedToken(i)));
        }
    }
}

/// One consumer stopped halfway through `tryPop`: the value is copied out and
/// `dequeue_pos` has moved on, and the slot is not released yet. That is the
/// state the ring's capacity has to leave room for — holding it open by hand is
/// what turns "how many slots do N consumers need" into an assertion.
fn halfPop(ring: *ReadyRing) Ready {
    const pos = ring.dequeue_pos.load(.monotonic);
    const slot = &ring.slots[pos & ring.mask];
    const item = slot.value;
    ring.dequeue_pos.store(pos +% 1, .monotonic);
    return item;
}

test "scheduler: the ring is sized for its consumers' windows (the Phase 1 size would refuse)" {
    const bound = 3;
    const width = 2;
    // The two derivations, side by side: Phase 1's `ceilPowerOfTwo(bound)`
    // (before d2a1cd6 added even one consumer slot) and the N-consumer one.
    const phase1_capacity = @max(try std.math.ceilPowerOfTwo(usize, bound), 2);
    const consumer_capacity = @max(try std.math.ceilPowerOfTwo(usize, bound + width), 2);
    try std.testing.expect(phase1_capacity < bound + width); // short by one slot per extra consumer
    try std.testing.expect(consumer_capacity >= bound + width);

    var legacy = try ReadyRing.init(std.testing.allocator, phase1_capacity);
    defer legacy.deinit(std.testing.allocator);
    var sized = try ReadyRing.init(std.testing.allocator, consumer_capacity);
    defer sized.deinit(std.testing.allocator);

    // The same script on both rings: two tokens in, two consumers held in the
    // dequeue window, two tokens in — `bound` tokens in flight plus `width` slots
    // that only the consumers will give back.
    inline for (.{ &legacy, &sized }) |ring| {
        try std.testing.expect(ring.tryPush(numberedToken(0)));
        try std.testing.expect(ring.tryPush(numberedToken(1)));
        try std.testing.expectEqual(@as(usize, 0), tokenId(halfPop(ring)));
        try std.testing.expectEqual(@as(usize, 1), tokenId(halfPop(ring)));
        try std.testing.expect(ring.tryPush(numberedToken(2)));
        try std.testing.expect(ring.tryPush(numberedToken(3)));
    }

    // The fourth token has nowhere to go on the Phase 1 size: the two slots its
    // consumers are still inside are the ones the producer wants back.
    try std.testing.expect(!legacy.tryPush(numberedToken(4)));
    // Hand the windows back and the same push lands — the refusal was the
    // window, not a ring that was genuinely full.
    legacy.slots[0].sequence.store(0 +% legacy.slots.len, .release);
    legacy.slots[1].sequence.store(1 +% legacy.slots.len, .release);
    try std.testing.expect(legacy.tryPush(numberedToken(4)));

    // The ring that was sized for its consumers never had to wait for them.
    try std.testing.expect(sized.tryPush(numberedToken(4)));
}

/// A pooled-worker stand-in that the *pool* runs: `FakeWorker`'s protocol bits,
/// with every reading atomic, because real pool threads are inside it.
///
/// `running` is the overlap witness §12.3 is about: it is set for the whole of a
/// batch, so a second thread entering the same worker while it is set is the
/// state-exclusivity violation the claim exists to prevent — counted, not
/// assumed.
const LiveFake = struct {
    /// Mailbox capacity per fake: wider than `FakeWorker`'s on purpose, because
    /// these runs are producer-driven and a 2-slot mailbox would measure the
    /// producer's retry loop rather than the pool.
    mailbox: mbox.Mailbox(u32, 16) = .init(std.testing.io),
    claimed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    queued: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scheduler: *Scheduler = undefined,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    overlaps: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

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

    /// The producer path `Handle.send*` runs: mailbox first, then `announce`.
    /// False = the mailbox refused the message (`error.Full`), which is
    /// backpressure and is counted as such.
    fn produce(self: *@This(), msg: u32) bool {
        self.mailbox.send(msg) catch return false;
        announce(self.ready());
        return true;
    }

    /// The producer path a real caller under backpressure takes: a full mailbox
    /// is waited out instead of dropped, so the run carries traffic *through* the
    /// pool rather than bouncing off the mailbox capacity. Only a whole budget of
    /// waiting becomes a counted drop.
    fn produceWaiting(self: *@This(), msg: u32) bool {
        var spins: usize = 0;
        while (true) {
            if (self.produce(msg)) return true;
            spins += 1;
            if (spins > producer_retry_budget) return false;
            std.atomic.spinLoopHint();
        }
    }

    fn dispatch(ctx: *anyopaque, max: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.running.swap(true, .acq_rel)) _ = self.overlaps.fetchAdd(1, .monotonic);
        defer self.running.store(false, .release);
        var n: usize = 0;
        while (n < max) : (n += 1) {
            _ = self.mailbox.tryRecv() orelse return true;
            _ = self.received.fetchAdd(1, .monotonic);
        }
        return false;
    }

    fn pending(ctx: *anyopaque) usize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.mailbox.len();
    }
};

/// What one live run produced, for the assertions below.
const PoolLoad = struct {
    /// Messages the producers attempted (`sent == received + dropped_full`).
    sent: u64,
    dropped_full: u64,
    received: u64,
    overlaps: u32,
    claim_misses: u64,
    dispatches: u64,
    pool_threads: usize,
    ready_capacity: usize,
    ready_push_failures: u64,
    max_pooled_workers: usize,
};

/// Drive `workers` pooled workers from `producers` producer threads, with `width`
/// pool threads consuming the ring and `batch` messages per claim, then wind the
/// pool down and report what happened. The counters are read while the pool is
/// still up (`pool_threads` is 0 once it is stopped); everything that has to be a
/// settled fact — no claim outstanding, no batch in flight, no mailbox left
/// behind — is checked after `shutdown`, which is the only moment it is one.
fn runPoolLoad(
    allocator: std.mem.Allocator,
    workers: usize,
    width: usize,
    batch: usize,
    producers: usize,
    per_producer: usize,
) !PoolLoad {
    const sched = try Scheduler.init(allocator, std.testing.io, .{
        .max_pooled_workers = workers,
        .pool_threads = width,
        .batch = batch,
    });
    errdefer sched.deinit();

    const fakes = try allocator.alloc(LiveFake, workers);
    defer allocator.free(fakes);
    for (fakes) |*f| f.* = .{ .scheduler = sched };
    try sched.start();

    const Sender = struct {
        fn run(
            workers_: []LiveFake,
            base: usize,
            n: usize,
            attempted: *std.atomic.Value(u64),
            refused: *std.atomic.Value(u64),
        ) void {
            var attempts: u64 = 0;
            var refused_n: u64 = 0;
            for (0..n) |k| {
                const msg: u32 = @intCast(base + k);
                attempts += 1;
                if (!workers_[(base + k) % workers_.len].produceWaiting(msg)) refused_n += 1;
            }
            _ = attempted.fetchAdd(attempts, .monotonic);
            _ = refused.fetchAdd(refused_n, .monotonic);
        }
    };

    var attempted = std.atomic.Value(u64).init(0);
    var refused = std.atomic.Value(u64).init(0);
    const threads = try allocator.alloc(std.Thread, producers);
    defer allocator.free(threads);
    for (threads, 0..) |*t, i| {
        t.* = std.Thread.spawn(.{}, Sender.run, .{
            fakes, i * per_producer, per_producer, &attempted, &refused,
        }) catch |err| {
            // Leave no producer behind: this frame's `errdefer` frees the
            // scheduler the running ones are sending into.
            for (threads[0..i]) |up| up.join();
            return err;
        };
    }
    for (threads) |t| t.join();

    // Drain: every accepted message must be handled before the pool is stopped.
    // The budget is a failure reporter, not a timeout — a stalled pool makes the
    // assertions below fail instead of hanging the suite.
    const accepted = attempted.load(.acquire) - refused.load(.acquire);
    var handled: u64 = 0;
    var idle: usize = 0;
    while (idle < ring_retry_budget) : (idle += 1) {
        handled = 0;
        for (fakes) |*f| handled += f.received.load(.monotonic);
        if (handled >= accepted) break;
        std.atomic.spinLoopHint();
    }

    // Counters first, while the pool is still up: `pool_threads` is 0 once it is
    // stopped, and that is the reading the "is the pool deployed" question is
    // about.
    const stats = sched.stats();
    const load: PoolLoad = .{
        .sent = attempted.load(.acquire),
        .dropped_full = refused.load(.acquire),
        .received = handled,
        .overlaps = blk: {
            var n: u32 = 0;
            for (fakes) |*f| n += f.overlaps.load(.monotonic);
            break :blk n;
        },
        .claim_misses = stats.claim_misses,
        .dispatches = stats.dispatches,
        .pool_threads = stats.pool_threads,
        .ready_capacity = stats.ready_capacity,
        .ready_push_failures = stats.ready_push_failures,
        .max_pooled_workers = stats.max_pooled_workers,
    };

    sched.shutdown();
    for (fakes) |*f| {
        // After the join every claim is back, nothing is in flight, and every
        // mailbox is empty: a message left behind here was accepted and never
        // handled. This is also the only moment at which "no batch is in flight"
        // is a settled fact rather than a snapshot.
        try std.testing.expect(!f.claimed.load(.acquire));
        try std.testing.expect(!f.running.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), f.mailbox.len());
    }
    sched.deinit();
    return load;
}

test "scheduler: N pool threads conserve messages and never run one worker twice" {
    const workers = 4;
    const width = 4;
    const producers = 4;
    const per_producer = 2_000;
    // One message per claim on purpose: the hand-back is the only place a skip
    // can be observed, and a batch of 1 exercises it once per message instead of
    // once per `batch` — the densest form of the shape this test is about.
    const batch = 1;

    const load = try runPoolLoad(std.testing.allocator, workers, width, batch, producers, per_producer);

    try std.testing.expectEqual(@as(usize, width), load.pool_threads);
    try std.testing.expectEqual(@as(usize, workers), load.max_pooled_workers);
    try std.testing.expect(load.ready_capacity >= workers + width);
    // The pool really ran: a run where nothing reached the ring would satisfy
    // every conservation identity below vacuously.
    try std.testing.expect(load.dispatches > 0);
    // §12.3's state exclusivity, measured rather than asserted: no worker was
    // entered by two pool threads at once.
    try std.testing.expectEqual(@as(u32, 0), load.overlaps);
    // Every attempted message was either handled or refused as backpressure.
    try std.testing.expectEqual(load.sent, load.received + load.dropped_full);
    // The producer side never lost a token: refused pushes are a scheduler
    // desync (a worker that stops being scheduled), not backpressure.
    try std.testing.expectEqual(@as(u64, 0), load.ready_push_failures);
    // With more than one consumer a skip is a normal reading (two threads at the
    // same worker's token: one running it, one arriving after the hand-back
    // started), and this is the run the docs' N>1 baseline comes from. The bound
    // asserted here is the structural one: a skip consumes a token, tokens come
    // from a producer's `send` or from a batch hand-back, so skips ≤ sent +
    // dispatches. What must hold absolutely is that the *protocol* never broke —
    // the conservation identities above.
    // With more than one consumer a skip is a *normal* reading: the hand-back
    // clears `queued` two instructions before it clears `claimed`, so a producer
    // that lands in that gap (the thread being preempted is what makes the gap
    // wide) puts a token in the ring for a worker that is still claimed. This test
    // bounds it structurally — a skip consumes a token, and tokens come from a
    // producer's send or from a batch hand-back — while the identities above are
    // what must hold absolutely. At width 1 the same counter is a defect signal;
    // see the test below.
    try std.testing.expect(load.claim_misses <= load.sent + load.dispatches);
}

test "scheduler: with one pool thread a claim is never missed (the Phase 1 reading)" {
    // The width-1 reading is a *defect* signal, and it has to stay one: a claim
    // is only ever held by the thread that popped the token, and that same thread
    // is the only consumer that can pop again — by the time it does, its own
    // hand-back has already released the claim. So `claim_misses` is 0 by
    // construction here, whatever the load (§12.12). "Whatever the load" is the
    // part worth asserting: the batch size moves *when* the hand-back happens and
    // the worker count moves how often a worker is re-armed, so one shape is a
    // reading and several are the contract.
    const Shape = struct { workers: usize, batch: usize, producers: usize, per_producer: usize };
    const shapes = [_]Shape{
        .{ .workers = 4, .batch = 1, .producers = 4, .per_producer = 1_000 },
        .{ .workers = 2, .batch = 8, .producers = 2, .per_producer = 1_000 },
        .{ .workers = 6, .batch = 16, .producers = 3, .per_producer = 500 },
    };
    for (shapes) |shape| {
        const load = try runPoolLoad(
            std.testing.allocator,
            shape.workers,
            1,
            shape.batch,
            shape.producers,
            shape.per_producer,
        );

        try std.testing.expectEqual(@as(usize, 1), load.pool_threads);
        try std.testing.expectEqual(@as(usize, shape.workers), load.max_pooled_workers);
        try std.testing.expect(load.dispatches > 0);
        try std.testing.expectEqual(@as(u64, 0), load.claim_misses);
        try std.testing.expectEqual(@as(u32, 0), load.overlaps);
        try std.testing.expectEqual(load.sent, load.received + load.dropped_full);
        try std.testing.expectEqual(@as(u64, 0), load.ready_push_failures);
    }
}

test "scheduler: the declared width is the number of threads started — and all of them are joined" {
    const width = 3;
    var sched = try testScheduler(.{ .max_pooled_workers = 8, .pool_threads = width });
    defer sched.deinit();

    try std.testing.expectEqual(@as(usize, 0), sched.stats().pool_threads);
    try std.testing.expect(!sched.stats().running);

    const before = settledThreadCount();
    try sched.start();
    // The count is the declared width, not "one if anything is running".
    try std.testing.expectEqual(@as(usize, width), sched.stats().pool_threads);
    try std.testing.expect(sched.stats().running);
    if (before) |n| try std.testing.expectEqual(n + width, settledThreadCount().?);

    // Idempotent with a width too: a second `start` must not widen the pool.
    try sched.start();
    try std.testing.expectEqual(@as(usize, width), sched.stats().pool_threads);
    if (before) |n| try std.testing.expectEqual(n + width, settledThreadCount().?);

    // Every thread is joined, not just the last one: `shutdown` takes the count
    // and joins that many, and `pool_threads` reads 0 once it is done.
    sched.shutdown();
    try std.testing.expectEqual(@as(usize, 0), sched.stats().pool_threads);
    try std.testing.expect(!sched.stats().running);
    if (before) |n| try std.testing.expectEqual(n, settledThreadCount().?);
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
