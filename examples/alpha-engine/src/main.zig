//! alpha-engine (P0) — a replay-driven trading pipeline on the runtime.
//!
//! ```text
//!   feed (thread)      OrderBook        Alpha          Risk           Execution ─▶ PaperExchange
//!   fixed replay  ─▶   top of book  ─▶  mean rev  ─▶   limits    ─▶   adapter   ─▶ instant fills
//!   (200 points)       mailbox 256      mailbox 256    mailbox 256    mailbox 256
//! ```
//!
//! What this stage proves, in the order `docs/RUNTIME.md` introduces it:
//!
//! 1. **State ownership** — every worker's fields (`OrderBook` quotes,
//!    `Alpha.window`, `Risk.position`, `Execution.exchange`) are touched by exactly
//!    one thread. There is no mutex in this file; the mailbox is the only hand-off.
//! 2. **Bounded backpressure** — a producer that outruns its consumer gets
//!    `error.Full` and decides what to do (here: shed the message and count it).
//!    The queue is comptime-bounded, so it can never grow instead.
//! 3. **Timers deliver messages** — the snapshot is `book.after(200, .{ .kind = .snapshot })`,
//!    so it runs on the book's thread with the book's state, never on the ticker's.
//! 4. **Lifecycle** — the workers are spawned by the `Pipeline` module's `initWith`
//!    through `ctx.runtime()`, so `app.stop()` joins them and `main` only
//!    assembles and observes.
//!
//! Deliberately **not** here (P1/P2 of `docs/dev/alpha-engine-spec.md`): the
//! HotBus fan-out (audit/metrics), a supervised faulty actor, the per-stage
//! module split. This is the skeleton, and it stays runnable on its own.
//!
//! Run: `zig build run`.

const std = @import("std");
const zmodu = @import("zigmodu");
const runtime = zmodu.runtime;

// ── messages ─────────────────────────────────────────────────────────────────
// One type per hop: each worker's input is a shape it can own. The shutdown
// marker rides the *same* FIFO as the data it must follow, which is what makes
// it a drain barrier rather than a racing shutdown flag.

const Side = enum { buy, sell };

/// feed → OrderBook. `.snapshot` is the timer message, `.shutdown` the marker.
const MarketData = struct {
    kind: Kind = .tick,
    seq: u32 = 0,
    price: i64 = 0,
    qty: i64 = 0,
    side: Side = .buy,

    const Kind = enum { tick, snapshot, shutdown };
};

/// OrderBook → Alpha: the top of book the alpha gets to see.
const Quote = struct {
    seq: u32 = 0,
    bid: i64 = 0,
    ask: i64 = 0,
    mid: i64 = 0,
    shutdown: bool = false,
};

/// Alpha → Risk: a directional *view*, still unsized for risk to veto.
const Signal = struct {
    seq: u32 = 0,
    side: Side = .buy,
    qty: i64 = 0,
    price: i64 = 0,
    /// How stretched the price is against the alpha's mean (signed).
    pull: i64 = 0,
    shutdown: bool = false,
};

/// Risk → Execution: an approved order; risk owns the size limits.
const Order = struct {
    id: u64 = 0,
    seq: u32 = 0,
    side: Side = .buy,
    qty: i64 = 0,
    price: i64 = 0,
    shutdown: bool = false,
};

/// What the exchange hands back. Not a message: it never crosses a mailbox.
const Fill = struct { order_id: u64, price: i64, qty: i64 };

// ── observation ──────────────────────────────────────────────────────────────

/// The pipeline's observation surface, and the only synchronized cell in the
/// file — deliberately, because `main` (another thread) reads it. The barrier
/// flags live here; worker state stays single-owner, so nothing below needs a
/// lock. `runtime-workers` reads raw worker fields instead; making the flags
/// atomic is what turns "usually fine in practice" into a happens-before edge.
const Metrics = struct {
    var risk_done = std.atomic.Value(bool).init(false);
    var exec_done = std.atomic.Value(bool).init(false);
    var snapshot_taken = std.atomic.Value(bool).init(false);

    /// Wait for a flag. Sleeping (rather than spinning) keeps a waiting `main`
    /// off a core, and the deadline keeps a stuck stage as a *truncated report*
    /// instead of a hung example.
    fn await(flag: *const std.atomic.Value(bool), io: std.Io, clock: runtime.Clock, deadline_ms: i64) void {
        while (!flag.load(.acquire)) {
            if (clock.nowMs() > deadline_ms) return;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
    }
};

// ── exchange adapter ─────────────────────────────────────────────────────────

/// The adapter for Replay/Paper mode: fills instantly at the price the order
/// carried (the mid the book quoted), no slippage, no fees. It is an adapter,
/// not a backtester (`docs/dev/alpha-engine-spec.md` §5) — a real venue would
/// replace `submit` and nothing else in this file.
const PaperExchange = struct {
    fills: u64 = 0,
    filled_qty: i64 = 0,
    position: i64 = 0,
    cash: i64 = 0,
    last_mid: i64 = 0,

    fn submit(self: *@This(), order: Order) Fill {
        self.fills += 1;
        self.filled_qty += order.qty;
        self.last_mid = order.price;
        switch (order.side) {
            .buy => {
                self.position += order.qty;
                self.cash -= order.qty * order.price;
            },
            .sell => {
                self.position -= order.qty;
                self.cash += order.qty * order.price;
            },
        }
        return .{ .order_id = order.id, .price = order.price, .qty = order.qty };
    }

    /// Mark-to-market: cash plus inventory valued at the last print.
    fn pnl(self: *const @This()) i64 {
        return self.cash + self.position * self.last_mid;
    }
};

// ── workers ──────────────────────────────────────────────────────────────────

const OrderBook = struct {
    pub const Message = MarketData;

    /// Half-spread the book quotes around the last print, in price units.
    const half_spread: i64 = 1;

    best_bid: i64 = 0,
    best_ask: i64 = 0,
    bids: u64 = 0, // prints that came in on the bid side
    asks: u64 = 0, // prints that came in on the ask side
    snapshots: u64 = 0,
    coalesced: u64 = 0,
    alpha: *runtime.Handle(Alpha, 256),

    pub fn handle(self: *@This(), md: MarketData, ctx: anytype) anyerror!void {
        _ = ctx;
        switch (md.kind) {
            .snapshot => {
                self.snapshots += 1;
                std.log.info("[book] snapshot #{d}: bid={d} ask={d} mid={d} prints={d}", .{
                    self.snapshots, self.best_bid, self.best_ask, self.mid(), self.bids + self.asks,
                });
                Metrics.snapshot_taken.store(true, .release);
            },
            .shutdown => {
                std.log.info("[book] marker in: prints={d} coalesced={d}", .{ self.bids + self.asks, self.coalesced });
                // `sendBlocking`: the marker is the barrier and must not be the
                // one message that gets dropped, or `main` waits for a marker
                // that never comes.
                self.alpha.sendBlocking(.{ .shutdown = true }, 5_000) catch {};
                // The book does *not* stop here — its mailbox has to stay open
                // for the snapshot timer. `app.stop()` owns the shutdown.
            },
            .tick => {
                if (md.side == .buy) self.bids += 1 else self.asks += 1;
                self.best_bid = md.price - half_spread;
                self.best_ask = md.price + half_spread;

                self.alpha.send(.{
                    .seq = md.seq,
                    .bid = self.best_bid,
                    .ask = self.best_ask,
                    .mid = self.mid(),
                }) catch |err| switch (err) {
                    // Bounded queue: "alpha is behind" is a decision (shed this
                    // quote, count it), not an accident — and it never grows.
                    error.Full, error.Timeout => self.coalesced += 1,
                    error.Closed => {},
                };
            },
        }
    }

    fn mid(self: *const @This()) i64 {
        return @divTrunc(self.best_bid + self.best_ask, 2);
    }
};

const Alpha = struct {
    pub const Message = Quote;

    /// Fixed-window mean of the mid. A real strategy would carry its own state
    /// (vol, depth, signals); what matters here is that one thread owns it.
    const window_len = 8;

    window: [window_len]i64 = @splat(0),
    head: usize = 0,
    filled: usize = 0,
    signals: u64 = 0,
    shed: u64 = 0,
    risk: *runtime.Handle(Risk, 256),

    pub fn handle(self: *@This(), q: Quote, ctx: anytype) anyerror!void {
        _ = ctx;
        if (q.shutdown) {
            std.log.info("[alpha] drained: signals={d} shed={d}", .{ self.signals, self.shed });
            self.risk.sendBlocking(.{ .shutdown = true }, 5_000) catch {};
            return;
        }

        self.window[self.head] = q.mid;
        self.head = (self.head + 1) % window_len;
        if (self.filled < window_len) {
            self.filled += 1; // no mean without history
            return;
        }

        var sum: i64 = 0;
        for (self.window) |p| sum += p;
        const pull = @divTrunc(sum, window_len) - q.mid;
        if (pull == 0) return;

        self.signals += 1;
        // Mean reversion: below the mean is a buy, above it a sell. The worker
        // publishes a *view*; sizing and the veto belong to risk.
        self.risk.send(.{
            .seq = q.seq,
            .side = if (pull > 0) .buy else .sell,
            .qty = 1 + @min(@divTrunc(@abs(pull), 2), 4),
            .price = q.mid,
            .pull = pull,
        }) catch |err| switch (err) {
            error.Full, error.Timeout => self.shed += 1,
            error.Closed => {},
        };
    }
};

const Risk = struct {
    pub const Message = Signal;

    /// Size limit per side. A real risk worker checks margin, symbol and
    /// strategy limits; one number is enough to show the stage that says "no".
    const max_position: i64 = 24;

    position: i64 = 0,
    checked: u64 = 0,
    rejected: u64 = 0,
    shed: u64 = 0,
    exec: *runtime.Handle(Execution, 256),

    pub fn handle(self: *@This(), s: Signal, ctx: anytype) anyerror!void {
        _ = ctx;
        if (s.shutdown) {
            std.log.info("[risk] drained: checked={d} rejected={d} position={d} shed={d}", .{
                self.checked, self.rejected, self.position, self.shed,
            });
            // Flip the barrier only once the marker is accounted for; a waiter
            // that observes it also observes everything the marker followed.
            Metrics.risk_done.store(true, .release);
            self.exec.sendBlocking(.{ .shutdown = true }, 5_000) catch {};
            return;
        }

        self.checked += 1;
        const signed = if (s.side == .buy) s.qty else -s.qty;
        if (@abs(self.position + signed) > max_position) {
            self.rejected += 1; // the stage that can say no — and says it once
            return;
        }
        self.position += signed;

        self.exec.send(.{
            .id = self.checked,
            .seq = s.seq,
            .side = s.side,
            .qty = s.qty,
            .price = s.price,
        }) catch |err| switch (err) {
            error.Full, error.Timeout => self.shed += 1,
            error.Closed => {},
        };
    }
};

const Execution = struct {
    pub const Message = Order;

    exchange: PaperExchange,
    routed: u64 = 0,
    last_fill: Fill = .{ .order_id = 0, .price = 0, .qty = 0 },

    pub fn handle(self: *@This(), o: Order, ctx: anytype) anyerror!void {
        _ = ctx;
        if (o.shutdown) {
            std.log.info("[exec] drained: routed={d} fills={d} last={d} position={d} pnl={d}", .{
                self.routed, self.exchange.fills, self.last_fill.price, self.exchange.position, self.exchange.pnl(),
            });
            Metrics.exec_done.store(true, .release);
            return;
        }

        self.routed += 1;
        // The adapter boundary: the worker routes, the exchange prices.
        self.last_fill = self.exchange.submit(o);
    }
};

// ── replay driver ────────────────────────────────────────────────────────────

const replay_points: usize = 200;

/// A triangle wave around 10_000 with a 40-point period — no RNG anywhere. The
/// point of a replay driver is that the same input always prints the same
/// snapshot.
fn replayPrice(i: usize) i64 {
    const period: usize = 40;
    const half = period / 2;
    const phase = i % period;
    const ramp: i64 = @intCast(if (phase < half) phase else period - phase);
    return 10_000 + ramp * 5;
}

/// Replay mode's feed: not a worker — it owns no state and has nothing to be
/// scheduled for. A plain thread pushing a file-shaped series, then the marker.
const ReplayFeed = struct {
    fn run(book: *runtime.Handle(OrderBook, 256)) void {
        for (0..replay_points) |i| {
            book.send(.{
                .seq = @intCast(i),
                .price = replayPrice(i),
                .qty = 1 + @as(i64, @intCast(i % 5)),
                .side = if (i % 3 == 0) .sell else .buy,
            }) catch |err| switch (err) {
                // The book is behind: shed this point rather than grow a queue.
                // The queue is comptime-bounded, so `error.Full` is its only exit
                // and this decision is the whole backpressure story.
                error.Full, error.Timeout => {},
                error.Closed => return,
            };
        }
        book.sendBlocking(.{ .kind = .shutdown }, 5_000) catch {};
    }
};

// ── the pipeline as a module ─────────────────────────────────────────────────

/// The app hands the module its runtime in `initWith`, so the workers belong to
/// the module lifecycle: `app.stop()` joins them and `main` never has to
/// remember to. Handles are send portals, not shared state — `send` *is* the
/// hand-off, so `main` may drive the feed while each worker keeps its fields.
pub const Pipeline = struct {
    pub const info = zmodu.api.Module{
        .name = "pipeline",
        .description = "replay feed -> order book -> alpha -> risk -> execution -> paper exchange",
        .dependencies = &.{},
    };

    var book: ?*runtime.Handle(OrderBook, 256) = null;
    var alpha: ?*runtime.Handle(Alpha, 256) = null;
    var risk: ?*runtime.Handle(Risk, 256) = null;
    var exec: ?*runtime.Handle(Execution, 256) = null;

    pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        const rt = try ctx.runtime(); // the app's runtime, joined by app.stop()

        // Spawned downstream-first: each stage needs the handle of the one it
        // feeds, which is the whole "wiring the pipeline is the module's job".
        exec = try rt.spawn(Execution, .{ .exchange = .{} }, 256);
        risk = try rt.spawn(Risk, .{ .exec = exec.? }, 256);
        alpha = try rt.spawn(Alpha, .{ .risk = risk.? }, 256);
        book = try rt.spawn(OrderBook, .{ .alpha = alpha.? }, 256);

        // Deferred work is a message: the snapshot runs on the book's thread,
        // with the book's state, not on the ticker's.
        _ = try book.?.after(200, .{ .kind = .snapshot });
    }

    pub fn deinit() void {}
};

// ── assembly and observation ─────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("alpha-engine: replay -> book -> alpha -> risk -> execution -> paper exchange", .{});

    var b = zmodu.builder(allocator, io);
    defer b.deinit();
    var app = try b.withName("alpha-engine").build(.{Pipeline});
    defer app.deinit();
    try app.start(); // Pipeline.initWith spawned the pipeline and the snapshot timer
    defer app.stop();

    const rt = try app.runtime();
    const book = Pipeline.book.?;
    const exec = Pipeline.exec.?;

    const feed = try std.Thread.spawn(.{}, ReplayFeed.run, .{book});
    feed.join();

    // Drain barrier. The marker travels feed → book → alpha → risk → execution
    // and every mailbox is FIFO per producer, so once the tail stages have seen
    // it, every earlier point has been handled by the whole chain — no sleep,
    // no guessing at a count that shed messages could never reach. Acquiring
    // those flags is also what orders the state reads below after the writes
    // they report on.
    const deadline = rt.clock.nowMs() + 5_000;
    Metrics.await(&Metrics.risk_done, io, rt.clock, deadline);
    Metrics.await(&Metrics.exec_done, io, rt.clock, deadline);

    // The snapshot timer is a message too, so it lands on the book's thread
    // after the replay ended; waiting for it is what makes `timer_fires > 0`
    // part of the run rather than a hope.
    Metrics.await(&Metrics.snapshot_taken, io, rt.clock, deadline);

    std.log.info("[snapshot] bids={d} asks={d} best_bid={d} best_ask={d} mid={d} fills={d} pnl={d} timer_snapshots={d}", .{
        book.state.bids,           book.state.asks,
        book.state.best_bid,       book.state.best_ask,
        book.state.mid(),          exec.state.exchange.fills,
        exec.state.exchange.pnl(), book.state.snapshots,
    });

    const s = rt.stats();
    std.log.info("[stats] workers={d} sent={d} received={d} dropped={d} timer_fires={d} timer_lag_max_ms={d}", .{
        s.workers,          s.messages_sent, s.messages_received,
        s.messages_dropped, s.timer_fires,   s.timer_lag_max_ms,
    });
    const bs = book.stats();
    std.log.info("[book] mailbox cap={d} len={d} dropped_full={d} coalesced={d} | alpha signals={d} shed={d} | risk rejected={d}", .{
        bs.mailbox_capacity,            bs.mailbox_len,                 bs.dropped_full,
        book.state.coalesced,           Pipeline.alpha.?.state.signals, Pipeline.alpha.?.state.shed,
        Pipeline.risk.?.state.rejected,
    });

    app.stop(); // requests stop, wakes blocked recvs, joins
    std.log.info("[done] every worker joined", .{});
}
