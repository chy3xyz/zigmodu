//! quant-replay — Deterministic Runtime Phase D: one recorded trading day,
//! replayed byte-identically (`docs/RUNTIME.md` §15.1, design
//! `docs/dev/deterministic-runtime-design.md` §4.2/§5).
//!
//! The pipeline is the shape of a real trading stack, five pooled workers deep:
//!
//! ```
//! market ──md──▶ book ──top──▶ alpha ──signal──▶ risk ──order──▶ exec ──fill──▶ ledger
//! (external)     top of book   mean reversion    limits          paper         clearing
//!                   │                                │                            ▲
//!                   └──────────── mark (timer) ──────┴────────── reject ──────────┘
//! ```
//!
//! The day is run twice in one process:
//!
//! * **record** — a det runtime (manual clock, `pool_threads = 1`, seed 42)
//!   drives the pipeline while an *external* feed (its own Prng, outside the
//!   deterministic domain) walks a price series into the book. Only the `md`
//!   track — the input boundary — is recorded to a `ZDL1` delivery log. The
//!   ledger's entry stream is the day's artifact.
//! * **replay** — a fresh det runtime runs the same pipeline code while
//!   `replay.Driver` opens the log back: `.message` records are delivered,
//!   `.timer` records are *reproduced by the wheel* (never re-posted), and
//!   every cascade (top/signal/order/fill/reject/mark) is recomputed, not
//!   replayed from tape. The artifact must be byte-identical.
//!
//! The six `[assert]` lines are the acceptance gate: identical ledger, identical
//! book state, identical counters, a scenario that actually exercised every
//! path (signals, fills, rejects, marks all > 0), and a legal fork on seed 43
//! (two seed-43 replays agree with each other and disagree with seed 42 — the
//! anti "random source pinned to a constant" check). Any FAIL exits non-zero.
//!
//! The recorded day is left in `./quant-replay-day/` — point the offline
//! inspector at it: `../../zig-out/bin/replay-inspect quant-replay-day --track md`.
//!
//! Run: `zig build run`.

const std = @import("std");
const zmodu = @import("zigmodu");

const runtime = zmodu.runtime;
const dlog = runtime.delivery_log;
const recorder = runtime.recorder;
const replay = runtime.replay_driver;
const Runtime = runtime.Runtime;
const Clock = runtime.Clock;
const Handle = runtime.Handle;

pub const std_options: std.Options = .{ .log_level = .info };

// ── contracts ────────────────────────────────────────────────────────────────

const Side = enum(u8) { buy, sell };

/// The external print — the only message type that ever touches the log.
const Trade = struct { price: u32, qty: u32 };
const BookTop = struct { mid: u32, prints: u64 };
const Signal = struct { side: Side, qty: u32, price: u32 };
const Order = struct { side: Side, qty: u32, price: u32 };
const Fill = struct { side: Side, qty: u32, price: u32, pos_after: i64 };
const Reject = struct { side: Side, qty: u32, price: u32, reason: u8 };
const Mark = struct { mid: u32, vwap: u32, prints: u64 };

const reject_notional: u8 = 1;
const reject_position: u8 = 2;

// ── tuning ───────────────────────────────────────────────────────────────────
// Every constant below is part of the scenario, not of the framework: they size
// the day so that all four downstream paths (signal, fill, notional reject,
// position reject) actually fire — assert 4 makes a vacuous run a failure.

const trade_count: u32 = 240; // prints in the day
const mark_interval_ms: i64 = 100; // book re-marks the day on the wheel
const alpha_window = 8; // mean-reversion lookback
const alpha_threshold = 3; // |mid - mean| that opens a signal
const alpha_qty_cap = 24; // beyond this the notional limit binds
const risk_notional_limit = 200_000; // per order, qty * price
const risk_position_limit = 40; // |net position| the desk tolerates
const det_seed = 42; // the deterministic domain's seed
const market_seed = 0xBEEF; // the external feed's seed — outside the domain

// ── workers ──────────────────────────────────────────────────────────────────

/// The clearing house: every outcome of the day lands here, in delivery order.
/// Its entry stream is the artifact the two runs compare — fills, rejects and
/// timer marks alike, so a replay that dropped any of them reads differently.
const Ledger = struct {
    pub const Message = union(enum) { fill: Fill, reject: Reject, mark: Mark };

    const Entry = struct { tag: u8, a: i64, b: i64, c: i64 };
    const max_entries = 1024;

    entries: [max_entries]Entry = undefined,
    len: usize = 0,
    fills: u64 = 0,
    rejects: u64 = 0,
    marks: u64 = 0,

    fn put(self: *@This(), e: Entry) !void {
        if (self.len >= max_entries) return error.LedgerOverflow;
        self.entries[self.len] = e;
        self.len += 1;
    }

    pub fn handle(self: *@This(), msg: Message, ctx: anytype) anyerror!void {
        _ = ctx;
        switch (msg) {
            .fill => |f| {
                self.fills += 1;
                try self.put(.{ .tag = 1, .a = signed(f.side, f.qty), .b = f.price, .c = f.pos_after });
            },
            .reject => |r| {
                self.rejects += 1;
                try self.put(.{ .tag = 2, .a = signed(r.side, r.qty), .b = r.price, .c = r.reason });
            },
            .mark => |m| {
                self.marks += 1;
                try self.put(.{ .tag = 3, .a = m.mid, .b = m.vwap, .c = @intCast(m.prints) });
            },
        }
    }
};

/// The paper exchange: fills instantly at the order price and reports the fill
/// downstream. Its position/cash are part of the compared state.
const Exec = struct {
    pub const Message = Order;

    ledger: *LedgerH,
    position: i64 = 0,
    cash: i64 = 0,
    fills: u64 = 0,

    pub fn handle(self: *@This(), o: Order, ctx: anytype) anyerror!void {
        _ = ctx;
        const q = signed(o.side, o.qty);
        self.position += q;
        self.cash -= q * @as(i64, o.price);
        self.fills += 1;
        try self.ledger.send(.{ .fill = .{ .side = o.side, .qty = o.qty, .price = o.price, .pos_after = self.position } });
    }
};

/// The desk's limits: per-order notional and net position. Approvals go to the
/// exchange, rejections to the ledger — a reject the replay forgot would shift
/// every later fill's `pos_after`, so it cannot hide.
const Risk = struct {
    pub const Message = Signal;

    exec: *ExecH,
    ledger: *LedgerH,
    pos: i64 = 0,
    approved: u64 = 0,
    rejected: u64 = 0,

    pub fn handle(self: *@This(), s: Signal, ctx: anytype) anyerror!void {
        _ = ctx;
        const q = signed(s.side, s.qty);
        const notional = @as(u64, s.qty) * s.price;
        if (notional > risk_notional_limit) {
            self.rejected += 1;
            try self.ledger.send(.{ .reject = .{ .side = s.side, .qty = s.qty, .price = s.price, .reason = reject_notional } });
            return;
        }
        if (@abs(self.pos + q) > risk_position_limit) {
            self.rejected += 1;
            try self.ledger.send(.{ .reject = .{ .side = s.side, .qty = s.qty, .price = s.price, .reason = reject_position } });
            return;
        }
        self.pos += q;
        self.approved += 1;
        try self.exec.send(.{ .side = s.side, .qty = s.qty, .price = s.price });
    }
};

/// Mean reversion over the last `alpha_window` mids. The order size draws on
/// `ctx.runtime.rng()` — the deterministic domain's seeded stream — which is
/// what makes the seed-43 fork a *legal* difference instead of a bug.
const Alpha = struct {
    pub const Message = BookTop;

    risk: *RiskH,
    window: [alpha_window]u32 = undefined,
    idx: usize = 0,
    count: usize = 0,
    sum: u64 = 0,
    signals: u64 = 0,

    pub fn handle(self: *@This(), top: BookTop, ctx: anytype) anyerror!void {
        if (self.count == alpha_window) self.sum -= self.window[self.idx];
        self.window[self.idx] = top.mid;
        self.sum += top.mid;
        self.idx = (self.idx + 1) % alpha_window;
        if (self.count < alpha_window) {
            self.count += 1;
            if (self.count < alpha_window) return;
        }
        const mean: i64 = @intCast(self.sum / alpha_window);
        const dev: i64 = @as(i64, top.mid) - mean;
        if (@abs(dev) < alpha_threshold) return;
        const jitter = ctx.runtime.rng().intRangeAtMost(u32, 0, 2);
        const qty: u32 = @min(@as(u32, @intCast(@abs(dev))), alpha_qty_cap) + 1 + jitter;
        self.signals += 1;
        try self.risk.send(.{ .side = if (dev > 0) .sell else .buy, .qty = qty, .price = top.mid });
    }
};

/// Top of book from the print tape, plus the mark timer: armed on the first
/// trade, re-armed on every fire. The mark is the day's *timer* evidence — the
/// replay never re-posts it, the wheel reproduces it (RUNTIME.md §15.1).
const Book = struct {
    pub const Message = union(enum) { trade: Trade, mark: void };

    alpha: *AlphaH,
    ledger: *LedgerH,
    best_bid: u32 = 0,
    best_ask: u32 = 0,
    vwap_num: u64 = 0,
    vwap_cnt: u64 = 0,
    prints: u64 = 0,
    mark_armed: bool = false,

    fn mid(self: *const @This()) u32 {
        return (self.best_bid + self.best_ask) / 2;
    }

    pub fn handle(self: *@This(), msg: Message, ctx: anytype) anyerror!void {
        switch (msg) {
            .trade => |t| {
                self.prints += 1;
                self.vwap_num += @as(u64, t.price) * t.qty;
                self.vwap_cnt += t.qty;
                self.best_bid = t.price -| (t.qty % 3);
                self.best_ask = t.price +| ((t.qty * 7) % 3);
                try self.alpha.send(.{ .mid = self.mid(), .prints = self.prints });
                if (!self.mark_armed) {
                    self.mark_armed = true;
                    _ = try ctx.handle.after(mark_interval_ms, .{ .mark = {} });
                }
            },
            .mark => {
                try self.ledger.send(.{ .mark = .{
                    .mid = self.mid(),
                    .vwap = @intCast(self.vwap_num / self.vwap_cnt),
                    .prints = self.prints,
                } });
                _ = try ctx.handle.after(mark_interval_ms, .{ .mark = {} });
            },
        }
    }
};

const LedgerH = Handle(Ledger, 256);
const ExecH = Handle(Exec, 256);
const RiskH = Handle(Risk, 256);
const AlphaH = Handle(Alpha, 256);
const BookH = Handle(Book, 64);

fn signed(side: Side, qty: u32) i64 {
    return if (side == .buy) qty else -@as(i64, qty);
}

/// The `md` track's codec: tag byte + little-endian fields. Timer payloads
/// (`.mark`) drain through it too; the replay never decodes those (reproduce
/// mode skips them), but the drain writes every record on the track.
const MdCodec = struct {
    pub const name: []const u8 = "quant-replay:md";
    pub const version: u16 = 1;

    pub fn encode(alloc: std.mem.Allocator, value: Book.Message) ![]u8 {
        const bytes = try alloc.alloc(u8, 9);
        switch (value) {
            .trade => |t| {
                bytes[0] = 0;
                std.mem.writeInt(u32, bytes[1..5], t.price, .little);
                std.mem.writeInt(u32, bytes[5..9], t.qty, .little);
            },
            .mark => bytes[0] = 1,
        }
        return bytes;
    }

    pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !Book.Message {
        _ = alloc;
        if (bytes.len < 1) return error.BadPayloadLength;
        return switch (bytes[0]) {
            0 => if (bytes.len < 9) error.BadPayloadLength else .{ .trade = .{
                .price = std.mem.readInt(u32, bytes[1..5], .little),
                .qty = std.mem.readInt(u32, bytes[5..9], .little),
            } },
            1 => .{ .mark = {} },
            else => error.BadPayloadTag,
        };
    }
};

// ── the pipeline ─────────────────────────────────────────────────────────────

const Pipeline = struct {
    book: *BookH,
    alpha: *AlphaH,
    risk: *RiskH,
    exec: *ExecH,
    ledger: *LedgerH,
};

/// Same code, same spawn order, on both runs — the topology is part of the
/// deterministic contract. Only the record run asks for the `md` track.
fn spawnPipeline(rt: *Runtime, record_md: bool) !Pipeline {
    const ledger = try rt.spawn(Ledger, .{}, .{ .capacity = 256, .mode = .pooled });
    const exec = try rt.spawn(Exec, .{ .ledger = ledger }, .{ .capacity = 256, .mode = .pooled });
    const risk = try rt.spawn(Risk, .{ .exec = exec, .ledger = ledger }, .{ .capacity = 256, .mode = .pooled });
    const alpha = try rt.spawn(Alpha, .{ .risk = risk }, .{ .capacity = 256, .mode = .pooled });
    const book = if (record_md)
        try rt.spawn(Book, .{ .alpha = alpha, .ledger = ledger }, .{ .capacity = 64, .mode = .pooled, .record = .{ .id = "md", .capacity = 4096 } })
    else
        try rt.spawn(Book, .{ .alpha = alpha, .ledger = ledger }, .{ .capacity = 64, .mode = .pooled });
    return .{ .book = book, .alpha = alpha, .risk = risk, .exec = exec, .ledger = ledger };
}

fn initRuntime(allocator: std.mem.Allocator, io: std.Io, clk: *Clock.Manual, seed: u64) !Runtime {
    return Runtime.initWithOptions(allocator, io, .{
        .clock = .{ .manual = clk },
        .scheduler = .{ .max_pooled_workers = 8 }, // det forces pool_threads = 1
        .deterministic = .{ .seed = seed },
    });
}

// ── the day's artifact ───────────────────────────────────────────────────────

const Artifact = struct {
    entries: []Ledger.Entry,
    bid: u32,
    ask: u32,
    vwap: u32,
    prints: u64,
    signals: u64,
    approved: u64,
    rejected: u64,
    position: i64,
    cash: i64,
    fills: u64,
    marks: u64,
    delivered: usize, // driver: .message records posted (record run: trades sent)
    timer_steps: u64, // driver: .timer records the wheel reproduced

    fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    /// xxhash64 over the field-explicit serialization (struct padding never
    /// feeds the hash — it is not part of the contract).
    fn digest(self: *const Artifact) u64 {
        var h = std.hash.XxHash64.init(0);
        var tmp: [8]u8 = undefined;
        for (self.entries) |e| {
            h.update(&[_]u8{e.tag});
            std.mem.writeInt(i64, &tmp, e.a, .little);
            h.update(&tmp);
            std.mem.writeInt(i64, &tmp, e.b, .little);
            h.update(&tmp);
            std.mem.writeInt(i64, &tmp, e.c, .little);
            h.update(&tmp);
        }
        return h.final();
    }
};

fn takeArtifact(allocator: std.mem.Allocator, p: Pipeline, delivered: usize, timer_steps: u64) !Artifact {
    const ls = p.ledger.state;
    const bs = p.book.state;
    return .{
        .entries = try allocator.dupe(Ledger.Entry, ls.entries[0..ls.len]),
        .bid = bs.best_bid,
        .ask = bs.best_ask,
        .vwap = @intCast(bs.vwap_num / bs.vwap_cnt),
        .prints = bs.prints,
        .signals = p.alpha.state.signals,
        .approved = p.risk.state.approved,
        .rejected = p.risk.state.rejected,
        .position = p.exec.state.position,
        .cash = p.exec.state.cash,
        .fills = p.exec.state.fills,
        .marks = ls.marks,
        .delivered = delivered,
        .timer_steps = timer_steps,
    };
}

// ── the record run's settle (the driver has its own; a recording has no loader)
// RUNTIME.md §15.1: first park of the single pool thread means the cascade has
// quiesced. Iteration-counted, never clock-read — the det domain bans Time.zig.

const wedged_wait_iters: u64 = 300_000;
const settle_poll_ns: u64 = 200 * std.time.ns_per_us;

fn settlePool(rt: *Runtime, io: std.Io) error{PoolWedged}!void {
    const before = rt.poolStats().?;
    var iters: u64 = 0;
    while (true) {
        const now = rt.poolStats().?;
        if (now.idle_waits != before.idle_waits) return;
        iters += 1;
        if (iters >= wedged_wait_iters) return error.PoolWedged;
        std.Io.sleep(io, .{ .nanoseconds = settle_poll_ns }, .awake) catch |err| switch (err) {
            error.Canceled => {},
        };
    }
}

// ── the two runs ─────────────────────────────────────────────────────────────

const log_dir = "quant-replay-day";

const log_config: dlog.Config = .{
    .dir_path = log_dir,
    .max_segment_bytes = 1 << 20,
    .max_record_bytes = 4096,
    .sync_mode = .none,
};

fn recordDay(allocator: std.mem.Allocator, io: std.Io) !Artifact {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try initRuntime(allocator, io, &clk, det_seed);
    defer rt.deinit();
    const p = try spawnPipeline(&rt, true);

    // The market: an external random walk with its own Prng — outside the
    // deterministic domain. Its randomness enters the domain only through the
    // recorded log; `rt.rng()` is never drawn here (RUNTIME.md §15.1's
    // recording discipline).
    var mkt = std.Random.DefaultPrng.init(market_seed);
    const rnd = mkt.random();
    var price: i64 = 10_000;
    var t: i64 = 0;
    for (0..trade_count) |_| {
        price = @max(1_000, price + rnd.intRangeAtMost(i32, -6, 7));
        const qty = 1 + rnd.intRangeAtMost(u32, 0, 9);
        t += 1 + rnd.intRangeAtMost(u32, 0, 6);
        clk.set(t);
        _ = rt.tick();
        try p.book.send(.{ .trade = .{ .price = @intCast(price), .qty = qty } });
        try settlePool(&rt, io);
    }

    // Drain the boundary track to ZDL1. The report doubles as a gate: a hole
    // here would mean the ring was out-paced, which the settle loop forbids.
    const log = rt.deliveryLog().?;
    try log.setCodecRef(p.book.track.?, MdCodec, Book.Message);
    var writer = try dlog.Writer.open(allocator, io, log_config);
    const drained = try log.drainTo(&writer);
    writer.deinit();
    std.log.info("[record] day done: trades={d} log_records={d} holes={d} (entries={d})", .{
        trade_count, drained.records, drained.holes, p.ledger.state.len,
    });

    return takeArtifact(allocator, p, trade_count, 0);
}

fn replayDay(allocator: std.mem.Allocator, io: std.Io, records: []const dlog.Record, seed: u64) !Artifact {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try initRuntime(allocator, io, &clk, seed);
    defer rt.deinit();
    const p = try spawnPipeline(&rt, false);

    var loader = try recorder.ReplayFromLog.init(allocator, &clk, records);
    defer loader.deinit();
    try loader.setCodec("md", MdCodec, Book.Message);
    try loader.bindDecoded("md", p.book);

    var driver = try replay.Driver.init(&rt, io, &loader);
    const report = try driver.runToEnd();
    std.log.info("[replay seed={d}] {d} records: delivered={d} timer_steps={d} stopped_on={s}", .{
        seed, report.iterations, report.delivered, loader.timerRecords(), @tagName(report.stopped_on),
    });

    return takeArtifact(allocator, p, report.delivered, loader.timerRecords());
}

// ── the acceptance gate ──────────────────────────────────────────────────────

var failures: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        std.log.info("[assert] " ++ fmt ++ ": PASS", args);
    } else {
        std.log.info("[assert] " ++ fmt ++ ": FAIL", args);
        failures += 1;
    }
}

fn entriesEqual(a: []const Ledger.Entry, b: []const Ledger.Entry) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.tag != y.tag or x.a != y.a or x.b != y.b or x.c != y.c) return false;
    }
    return true;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("quant-replay: market -> book -> alpha -> risk -> exec -> ledger, one day, twice", .{});

    // A stale log from a previous run is not a day worth recording over
    // (deleteTree on a missing tree is a success, not an error).
    try std.Io.Dir.cwd().deleteTree(io, log_dir);

    var a = try recordDay(allocator, io);
    defer a.deinit(allocator);

    var scanned = try dlog.scan(allocator, io, log_config);
    defer scanned.deinit(allocator);
    try scanned.expectClean();
    check(
        scanned.records.len > trade_count,
        "log holds the whole boundary: {d} records for {d} trades (the rest are wheel marks), clean",
        .{ scanned.records.len, trade_count },
    );

    var b1 = try replayDay(allocator, io, scanned.records, det_seed);
    defer b1.deinit(allocator);
    var b2 = try replayDay(allocator, io, scanned.records, det_seed);
    defer b2.deinit(allocator);

    check(
        entriesEqual(a.entries, b1.entries) and entriesEqual(b1.entries, b2.entries),
        "ledger byte-identical: record={d} entries digest=0x{x:0>16}, replay x2 agree",
        .{ a.entries.len, a.digest() },
    );
    check(
        a.bid == b1.bid and a.ask == b1.ask and a.vwap == b1.vwap and a.prints == b1.prints,
        "book state identical: bid={d} ask={d} vwap={d} prints={d}",
        .{ b1.bid, b1.ask, b1.vwap, b1.prints },
    );
    check(
        a.signals == b1.signals and a.approved == b1.approved and a.rejected == b1.rejected and
            a.position == b1.position and a.cash == b1.cash and a.fills == b1.fills and a.marks == b1.marks and
            b1.delivered == trade_count and b1.timer_steps > 0,
        "counters identical: signals={d} approved={d} rejected={d} fills={d} position={d} pnl={d} marks={d} (wheel-reproduced)",
        .{ b1.signals, b1.approved, b1.rejected, b1.fills, b1.position, b1.cash + b1.position * b1.vwap, b1.marks },
    );
    check(
        a.signals > 0 and a.fills > 0 and a.rejected > 0 and a.marks > 0,
        "the day was non-vacuous: every downstream path fired (signals/fills/rejects/marks all > 0)",
        .{},
    );

    // §4.3-2: another seed forks legally — alpha's order-size jitter draws on
    // rng(), so seed 43 must differ from 42 while agreeing with itself.
    var c1 = try replayDay(allocator, io, scanned.records, det_seed + 1);
    defer c1.deinit(allocator);
    var c2 = try replayDay(allocator, io, scanned.records, det_seed + 1);
    defer c2.deinit(allocator);
    check(
        entriesEqual(c1.entries, c2.entries) and !entriesEqual(a.entries, c1.entries),
        "seed fork is legal: seed {d} digest=0x{x:0>16} != seed {d}'s 0x{x:0>16}, and two seed-{d} runs agree",
        .{ det_seed + 1, c1.digest(), det_seed, a.digest(), det_seed + 1 },
    );

    if (failures > 0) {
        std.log.info("[done] {d} assertion(s) FAILED — the recorded day is kept at ./{s}/ for inspection", .{ failures, log_dir });
        std.process.exit(1);
    }
    std.log.info("[done] every worker joined; the recorded day is at ./{s}/ (try: replay-inspect {s} --track md)", .{ log_dir, log_dir });
}
