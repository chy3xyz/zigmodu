//! runtime-workers — the v0.16 runtime in one runnable pipeline.
//!
//! ```text
//!   feed (thread)        book (worker)        risk (worker)      timer
//!   random deltas   →    order book      →    position check →   snapshot every 200 ms
//!                        (mailbox 256)        (mailbox 256)
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
//! 4. **Graceful stop** — `rt.shutdown()` requests stop, wakes every blocked
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
/// (it appends), which is what makes the drop counter move.
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("runtime-workers: no locks, no shared mutable state below this line", .{});

    // A runtime can stand alone; `app.runtime()` gives you one wired to an app
    // (created on first call, shut down by `app.stop()`).
    var rt = runtime.Runtime.init(allocator, io, .monotonic);
    defer rt.deinit();
    // Timers need the ticker. Skip `start()` and `handle.after(...)` stays
    // pending until you call `rt.tick()` yourself (which is what a test with a
    // Manual clock does).
    try rt.start();

    const risk = try rt.spawn(Risk, .{}, 256);

    // L0 fan-out (v0.17): wired during startup, frozen before traffic. The book
    // publishes every accepted delta; a slow subscriber is *dropped and counted*
    // rather than allowed to slow the book down.
    var bus = runtime.HotBus(Delta, 4).init();
    const audit = try rt.spawn(Audit, .{}, 64);
    try bus.subscribe(audit); // a real worker (slow, deliberately)
    var metrics = MetricsSink{};
    try bus.subscribeSink(metrics.sink()); // a plain sink, no worker needed
    bus.freeze();

    // Supervised actor (v0.17): 3 errors inside the window means "stop", not
    // "log forever" — the difference between spawnActor and spawn.
    const faulty = try rt.spawnActor(FaultyReporter, .{}, 32, .{ .max_errors = 3, .window_ms = 60_000 });
    for (0..10) |_| faulty.send(.{ .price = 1, .qty = 1, .bid = true }) catch break;

    // The book needs the risk handle, so it is spawned with a placeholder and
    // wired in `init` — hence the two-step here (a real app would pass a
    // service locator or spawn risk from inside the book's init).
    const book_init = OrderBook{ .risk = risk, .bus = &bus };
    const book = try rt.spawn(OrderBook, book_init, 256);

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

    rt.shutdown(); // requests stop, wakes blocked recvs, joins
    std.log.info("[done] every worker joined", .{});
}
