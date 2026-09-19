//! runtime-workers — the v0.16 runtime in one runnable pipeline.
//!
//! ```text
//!   feed (thread)        book (worker)        risk (worker)      timer
//!   random deltas   →    order book      →    position check →   snapshot every 200 ms
//!                        (mailbox 256)        (mailbox 256)
//!                             │
//!                             └── HotBus fan-out → audit (worker, .pooled → pool thread) + metrics sink
//! ```
//!
//! What it demonstrates, in the order the runtime docs introduce it:
//!
//! 1. **State ownership** — `OrderBook.bids/asks` and `Risk.exposure` are touched by
//!    exactly one thread. There is no mutex anywhere in this file, and that is the
//!    point: the mailbox is the only hand-off.
//! 1b. **Fan-out (v0.17 `HotBus`)** — the same delta also goes to an audit worker,
//!    wired at startup then `freeze()`d, so publishing is a lock-free slice walk and
//!    a slow audit trail drops instead of stalling the book.
//! 1c. **Supervision (v0.17 Actor)** — `FaultyReporter` errors on every message with a
//!    3-error budget: the runtime stops it and closes its mailbox, instead of logging
//!    forever. That is the difference between `spawn` and `spawnActor`.
//! 2. **Bounded backpressure** — the feed pushes faster than the book drains and
//!    gets `error.Full`; it *coalesces* (drops the delta, keeps the last price)
//!    rather than growing a queue. `stats().dropped_full` records the choice.
//! 3. **Timers deliver messages** — the snapshot timer is `book.after(...)`, so it
//!    runs on the book's thread with the book's state, not on the ticker's.
//! 3b. **Pooled workers (`Scheduler`, docs/RUNTIME.md §12)** — the audit worker is the long tail
//!    of this pipeline (message-driven, slow on purpose, and off the critical
//!    path: the bus drops for it rather than slowing the book down), so it is
//!    spawned `.mode = .pooled` and its batches run on the pool thread instead of
//!    a thread of its own. `[pool] … dispatched=N` is the runtime saying that
//!    path really was taken — see `docs/RUNTIME.md` §12.5 for the boundary.
//! 4. **Graceful stop** — `app.stop()` requests stop, wakes every blocked
//!    `recv`, then joins. Nothing is abandoned.
//!
//! Run: `zig build run` (add `--summary all` to see the runtime stats table).

const std = @import("std");
const zmodu = @import("zigmodu");
const runtime = zmodu.runtime;

const Delta = struct { price: i64, qty: i64, bid: bool };

const Snapshot = struct { bids: usize, asks: usize, exposure: i64 };

const OrderBook = struct {
    pub const Message = Delta;

    bids: usize = 0,
    asks: usize = 0,
    last_price: i64 = 0,
    coalesced: u64 = 0,
    /// Set when the feed's shutdown marker arrives. Because a mailbox is FIFO per
    /// producer, seeing it means *everything the feed sent* has been handled —
    /// that is the drain barrier this example waits on (rather than guessing with
    /// a sleep, or waiting for a count that dropped messages can never reach).
    done: bool = false,
    risk: *runtime.Handle(Risk, 256),
    bus: *runtime.HotBus(Delta, 4),
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,

    pub fn init(self: *@This(), ctx: anytype) !void {
        self.io = ctx.io;
        self.allocator = ctx.allocator;
        std.log.info("[book] started: mailbox capacity {d}", .{ctx.handle.mailbox.maxMessages()});
    }

    pub fn handle(self: *@This(), d: Delta, ctx: anytype) !void {
        self.last_price = d.price;
        if (d.bid) self.bids += 1 else self.asks += 1;

        // Hand off to risk *by value*: no shared state, no lock.
        self.risk.send(d) catch |err| switch (err) {
            // Bounded queue: "risk is behind" is a decision, not an accident.
            error.Full, error.Timeout => self.coalesced += 1,
            error.Closed => {},
        };

        // Fan out to audit + metrics. `publish` never blocks and never allocates:
        // subscribers that cannot keep up drop this delta and count it.
        _ = self.bus.publish(d) catch {};

        // Every 50 deltas, ask the runtime to wake us for a snapshot.
        if ((self.bids + self.asks) % 50 == 0) {
            _ = try ctx.handle.after(200, .{ .price = 0, .qty = 0, .bid = true });
        }

        if (d.price == -1) {
            std.log.info("[book] shutdown marker: bids={d} asks={d} coalesced={d}", .{ self.bids, self.asks, self.coalesced });
            // Forward the barrier so the snapshot below also sees a drained risk
            // worker, then finish. `sendBlocking` is right here: the marker must
            // not be the one message that gets dropped, or main() waits forever.
            self.risk.sendBlocking(d, 5_000) catch {};
            self.done = true;
            ctx.handle.stop();
        }
    }
};

const Risk = struct {
    pub const Message = Delta;

    exposure: i64 = 0,
    checks: u64 = 0,
    rejected: u64 = 0,
    done: bool = false,

    pub fn handle(self: *@This(), d: Delta, ctx: anytype) !void {
        _ = ctx;
        if (d.price == -1) {
            self.done = true; // barrier: everything before it is already accounted
            return;
        }
        self.checks += 1;
        const signed = if (d.bid) d.qty else -d.qty;
        self.exposure += signed;
        // A real risk worker would reject and publish; here it just counts.
        if (@abs(self.exposure) > 10_000) self.rejected += 1;
    }
};

/// Fan-out target: keeps the last N prices as an "audit trail". Slow by design
/// (it appends), which is what makes the drop counter move — and why it is the
/// one worker here that is **pooled** rather than given a thread of its own
/// (docs/RUNTIME.md §12.5: message-driven, long tail, not the latency chain).
const Audit = struct {
    pub const Message = Delta;
    kept: usize = 0,
    last_price: i64 = 0,

    pub fn handle(self: *@This(), d: Delta, ctx: anytype) anyerror!void {
        _ = ctx;
        if (d.price == -1) return;
        self.kept += 1;
        self.last_price = d.price;
        var spins: usize = 0;
        while (spins < 200_000) : (spins += 1) std.atomic.spinLoopHint(); // pretend work
    }
};

/// A non-worker subscriber: anything with a `deliver` thunk can ride the bus
/// (metrics today, a websocket broadcaster tomorrow).
const MetricsSink = struct {
    deltas: u64 = 0,
    last_price: i64 = 0,

    fn sink(self: *@This()) runtime.HotBus(Delta, 4).Sink {
        return .{
            .ctx = @ptrCast(self),
            .deliver = struct {
                fn deliver(ctx: *anyopaque, d: Delta) bool {
                    const m: *MetricsSink = @ptrCast(@alignCast(ctx));
                    if (d.price != -1) {
                        m.deltas += 1;
                        m.last_price = d.price;
                    }
                    return true; // always accepts: it does O(1) work
                }
            }.deliver,
        };
    }
};

/// An actor that always fails, to show the supervisor's budget in action.
const FaultyReporter = struct {
    pub const Message = Delta;
    attempts: u32 = 0,

    pub fn handle(self: *@This(), d: Delta, ctx: anytype) anyerror!void {
        _ = d;
        _ = ctx;
        self.attempts += 1;
        return error.UpstreamUnavailable;
    }
};

/// The pipeline as a module: the app hands it the runtime in `initWith`, so the
/// workers belong to the module lifecycle — `app.stop()` joins them, and
/// nothing in `main` has to remember to.
pub const Pipeline = struct {
    pub const info = zmodu.api.Module{
        .name = "pipeline",
        .description = "order book + risk + audit workers",
        .dependencies = &.{},
    };

    /// Handles are send portals, not shared state: `send` *is* the hand-off, so
    /// `main` may drive the feed through `book` while the book keeps its state.
    var risk: ?*runtime.Handle(Risk, 256) = null;
    var book: ?*runtime.Handle(OrderBook, 256) = null;
    var audit: ?*runtime.Handle(Audit, 64) = null;
    var faulty: ?*runtime.Handle(FaultyReporter, 32) = null;
    var bus: runtime.HotBus(Delta, 4) = undefined;
    var metrics: MetricsSink = .{};

    pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        const rt = try ctx.runtime(); // the app's runtime, not a private one

        risk = try rt.spawn(Risk, .{}, 256);

        // L0 fan-out (v0.17): wired during startup, frozen before traffic. The
        // book publishes every accepted delta; a slow subscriber is *dropped and
        // counted* rather than allowed to slow the book down.
        //
        // The audit worker is spawned **pooled** (docs/RUNTIME.md §12): it is the long tail of
        // this pipeline — slow by design, and the bus already drops for it
        // instead of letting it hold up the book — so it runs its batches on the
        // shared pool thread. The declaration it needs (`max_pooled_workers`) is
        // on the app builder in `main`. The book and risk stay `.dedicated`:
        // every hop of `feed → book → risk` is on the critical path, and the
        // scheduled path costs one ready-ring round trip per message (§12.5).
        bus = runtime.HotBus(Delta, 4).init();
        audit = try rt.spawn(Audit, .{}, .{ .capacity = 64, .mode = .pooled });
        try bus.subscribe(audit.?); // a real worker (slow, deliberately)
        try bus.subscribeSink(metrics.sink()); // a plain sink, no worker needed
        bus.freeze();

        // Supervised actor (v0.17): 3 errors inside the window means "stop", not
        // "log forever" — the difference between spawnActor and spawn.
        faulty = try rt.spawnActor(FaultyReporter, .{}, 32, .{ .max_errors = 3, .window_ms = 60_000 });
        for (0..10) |_| faulty.?.send(.{ .price = 1, .qty = 1, .bid = true }) catch break;

        // The book needs the risk handle, so it is spawned with a placeholder
        // and wired in `init` — hence the two-step (a real app would pass a
        // service locator, or spawn risk from inside the book's init).
        book = try rt.spawn(OrderBook, .{ .risk = risk.?, .bus = &bus }, 256);
    }

    pub fn deinit() void {}
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("runtime-workers: no locks, no shared mutable state below this line", .{});

    // The app owns the runtime: created on first use, ticker started for you,
    // and joined by `app.stop()` — one lifecycle for the process, no stray
    // threads. (A runtime can also stand alone in a test: then you drive
    // `rt.tick()` with a Manual clock and own `rt.deinit()`.)
    //
    // `withMaxPooledWorkers` is the pool declaration docs/RUNTIME.md §12.8 D2
    // asks for: the runtime behind `app.runtime()` is sized for it, and the
    // pool thread appears with the first `.pooled` spawn (here: the audit
    // worker, in `Pipeline.initWith`). Without the declaration `.pooled` is a
    // configuration error at `spawn` — not a thread appearing behind your back.
    var b = zmodu.builder(allocator, io);
    defer b.deinit();
    var app = try b.withName("runtime-workers").withMaxPooledWorkers(1).build(.{Pipeline});
    defer app.deinit();
    try app.start(); // Pipeline.initWith spawned the whole pipeline
    const rt = try app.runtime();

    // Local aliases so the run below reads like the single-process pipeline it is.
    const risk = Pipeline.risk.?;
    const book = Pipeline.book.?;
    const audit = Pipeline.audit.?;
    const faulty = Pipeline.faulty.?;
    const bus = &Pipeline.bus;
    const metrics = &Pipeline.metrics;

    // Feed: a plain thread, deliberately faster than the pipeline drains, to make
    // the backpressure path visible in the counters.
    const Feed = struct {
        fn run(h: *runtime.Handle(OrderBook, 256)) void {
            var price: i64 = 100;
            for (0..5_000) |i| {
                price += if (i % 2 == 0) 1 else -1;
                h.send(.{ .price = price, .qty = 1 + @as(i64, @intCast(i % 7)), .bid = i % 2 == 0 }) catch |err| switch (err) {
                    error.Full, error.Timeout => {}, // the feed sheds; the book counts it
                    error.Closed => return,
                };
            }
            h.send(.{ .price = -1, .qty = 0, .bid = true }) catch {};
        }
    };
    const feed = try std.Thread.spawn(.{}, Feed.run, .{book});
    feed.join();

    // Drain barrier: the marker travels feed → book → risk, so once risk has seen
    // it, every earlier delta has been processed by both workers.
    var spins: usize = 0;
    while (!book.state.done and spins < 200_000_000) : (spins += 1) std.atomic.spinLoopHint();
    spins = 0;
    while (!risk.state.done and spins < 200_000_000) : (spins += 1) std.atomic.spinLoopHint();

    const snap = Snapshot{ .bids = book.state.bids, .asks = book.state.asks, .exposure = risk.state.exposure };
    std.log.info("[snapshot] bids={d} asks={d} risk_exposure={d} checks={d} rejected={d}", .{
        snap.bids, snap.asks, snap.exposure, risk.state.checks, risk.state.rejected,
    });

    std.log.info("[v0.17] bus: subscribers={d} published={d} delivered={d} dropped={d} | metrics deltas={d} | audit kept={d}", .{
        bus.stats().subscribers, bus.stats().published, bus.stats().delivered, bus.stats().dropped,
        metrics.deltas,          audit.state.kept,
    });
    std.log.info("[v0.17] supervised actor: attempts={d} stopped_by_supervisor={} mailbox_closed={}", .{
        faulty.state.attempts, faulty.stats().stopped_by_supervisor, faulty.mailbox.isClosed(),
    });

    const s = rt.stats();
    std.log.info("[stats] workers={d} sent={d} received={d} dropped={d} handler_errors={d} timer_fires={d} timer_lag_max_ms={d}", .{
        s.workers,        s.messages_sent, s.messages_received, s.messages_dropped,
        s.handler_errors, s.timer_fires,   s.timer_lag_max_ms,
    });
    const bs = book.stats();
    std.log.info("[book] mailbox cap={d} len={d} dropped_full={d} coalesced={d}", .{
        bs.mailbox_capacity, bs.mailbox_len, bs.dropped_full, book.state.coalesced,
    });

    // Pooled path, read off the *running* runtime (docs/RUNTIME.md §12.10). The
    // audit worker is the only `.pooled` spawn here, and the pool puts a token in
    // the ready ring on every send it accepts — so `spawned=1` plus
    // `dispatched>0` says the audit worker's batches ran on the pool thread,
    // not on a thread of its own. A dedicated worker would leave all of these at
    // zero. (The first publish cannot be dropped: the audit mailbox is empty and
    // 64 slots wide, so a token exists as soon as the book has handled a delta.)
    spins = 0;
    while (rt.poolStats().?.dispatches == 0 and spins < 200_000_000) : (spins += 1) std.atomic.spinLoopHint();
    const pool = rt.poolStats().?;
    std.log.info("[pool] declared={d} threads={d} spawned={d} dispatched={d} claimed={d} ready_len={d} push_failures={d}", .{
        pool.max_pooled_workers, pool.pool_threads, pool.spawned,             pool.dispatches,
        pool.claimed,            pool.ready_len,    pool.ready_push_failures,
    });
    // Exit code is the conclusion, as with `[done]` below: a `.pooled` worker
    // that never reached the pool thread, or a token the ring refused to take,
    // is a failure of the one thing this example now demonstrates.
    if (pool.dispatches == 0) return error.PooledWorkerNeverDispatched;
    if (pool.spawned == 0 or pool.pool_threads == 0) return error.PoolNeverDeployed;
    if (pool.ready_push_failures != 0) return error.PoolTokenRefused;

    app.stop(); // requests stop, wakes blocked recvs, joins
    std.log.info("[done] every worker joined", .{});
}
