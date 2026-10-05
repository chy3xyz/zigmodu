//! `replay.Driver` — the deterministic (S-level) replay driver: plays a
//! delivery-log file back through a **det-mode** runtime, one recorded step at
//! a time, letting each step's cascade quench before the next one starts
//! (docs/dev/deterministic-runtime-design.md §4.2, docs/RUNTIME.md §15).
//!
//! ## What this is
//!
//! `ReplayFromLog` (§13.10) is the D-level reader: it hands records over in
//! global `seq` order and lets the *caller* decide what happens between them.
//! The driver is the S-level counterpart for a runtime built with
//! `Runtime.InitOptions.deterministic`: it owns the whole per-step cadence —
//!
//! ```
//! loader.step()      → clock moves to the record's stamp; a `.message`
//!                      record is delivered into its worker's mailbox
//!                      (a `.timer` record is *not* — see reproduce mode)
//! rt.tick()          → the wheel drains arm/cancel commands and fires every
//!                      timer the moved clock has reached — the recorded
//!                      `.timer` deliveries are *reproduced* by the replayed
//!                      runtime itself, not re-posted from the file
//! settle()           → waits until the single pool thread parks, which (see
//!                      below) means the step's whole cascade has quenched
//! ```
//!
//! — so the replayed run's event order is a pure function of the log, the
//! seed, and the topology. Replaying the same log through the same graph ten
//! times produces ten byte-identical recorder streams (the design's §4.3-1
//! acceptance; the test at the bottom of this file is the proof).
//!
//! ## Timer deliveries are reproduced, not re-posted
//!
//! `init` puts the loader in reproduce mode (`ReplayFromLog.reproduceTimers`):
//! a `.timer` record still moves the clock, still anchors the seq chain, and
//! is still counted (`timerRecords()`) — but it is not delivered, because the
//! replayed runtime's handlers re-arm the same timers for the same reasons,
//! and the driver's `tick()` fires them at the recorded deadline. Re-posting
//! the file's copy as well would hand every timer payload to its worker
//! twice. The file's `.timer` records are the *evidence* the reproduction is
//! checked against (compare the replayed run's own recording with the input
//! log — the acceptance digest does exactly that).
//!
//! ## Why `settle` is exact (the single-thread argument)
//!
//! Det mode guarantees `pool_threads == 1`, `batch == 1`, no dedicated workers
//! and no blocking pool (`initWithOptions` refuses anything else). With one
//! consumer of the ready ring:
//!
//! * the driver is the only producer outside the pool, and it does not produce
//!   while it waits;
//! * a park happens only after a `turn()` that found the ring empty — and a
//!   `turn()` is pop → claim → run → hand-back inside one loop iteration, so
//!   at park time no claim is held and no phantom token can be outstanding
//!   (a phantom is pushed from *inside* a claim and is drained by the next
//!   turn, before any park);
//! * therefore the **first** `idle_waits` increment after the driver's own
//!   push proves the ring is empty and every cascade the step started has been
//!   claimed and handed back.
//!
//! The wait costs at most one idle poll (`idle_wait_ms == 1`) per step beyond
//! the work itself. A pool that never parks is a wedged handler, not a slow
//! one: after `wedged_wait_iters` polls the driver returns `error.PoolWedged`.
//! The bound is counted in *iterations*, never read off a clock — a timeout
//! must not become a time source inside the deterministic perimeter (the
//! `dettime` production scan keeps `core/Time.zig` out of this file).
//!
//! ## Contracts the caller keeps
//!
//! * The runtime must be det mode (`error.NotDeterministic` otherwise): the
//!   single-consumer proof above needs `pool_threads == 1`, and a seeded
//!   `rng()` needs the det config. A hand-rolled single-thread runtime would
//!   run the mechanics but void the guarantee the driver exists for.
//! * The ticker must not be running (`error.TickerRunning`): `tick()` and the
//!   ticker are two owners of one wheel, and the wheel reports the mix.
//! * The loader stays the caller's: codecs declared, tracks bound, holes
//!   policy chosen. `init` only switches it to reproduce mode. A refusal
//!   (`error.LogHasHoles`, `error.UnboundTrack`, …) propagates out of a `run*`
//!   call; the run is *resumable* — handle the refusal (`allowHoles()`, bind
//!   what was missing) and call again, the loader's cursor never moved.
//! * Side effects (socket/DB/file) are the application's to mock (design D6):
//!   the driver guarantees the delivery chain, not the world outside it.

const std = @import("std");
const runtime_impl = @import("runtime.zig");
const recorder_mod = @import("recorder.zig");
const dlog = @import("delivery_log.zig");

const Runtime = runtime_impl.Runtime;

/// Polls the driver makes before calling a pool wedged. Each poll sleeps
/// `settle_poll_ns`, so the budget is ~60 s of a pool that never parks — a
/// wedged handler, by any definition. Iteration-counted on purpose (see the
/// module doc): no clock is read inside the deterministic perimeter.
const wedged_wait_iters: u64 = 300_000;
const settle_poll_ns: u64 = 200 * std.time.ns_per_us;

pub const InitError = error{
    /// The runtime was not built with `InitOptions.deterministic` — the
    /// driver is the S-level replay of a det-mode recording, and a runtime
    /// without the det invariants (single pool thread, seeded `rng()`, no
    /// second scheduling domain) has nothing for it to guarantee.
    NotDeterministic,
    /// The runtime has no pool at all (a dedicated-only shape) — there is no
    /// ready ring whose park would prove a cascade quenched.
    NoPool,
    /// The ticker thread is running. `tick()` and the ticker are two drivers
    /// of one wheel; the deterministic one must be the only one.
    TickerRunning,
};

/// What stopped a `run*` call.
pub const StoppedOn = enum {
    /// The loader was exhausted (`step()` handed over nothing more).
    end,
    /// `runUntilSeq`: a step with `seq >=` the bound completed (inclusive —
    /// "stop the world right after this seq has landed").
    seq,
    /// `runUntilClock`: a step with `clock_ms >=` the bound completed.
    clock,
};

pub const RunReport = struct {
    /// Steps the loop ran — deliveries **and** reproduce-mode timer steps.
    iterations: usize = 0,
    /// Records actually delivered into mailboxes. `iterations - delivered` is
    /// how many timer steps the wheel was left to reproduce.
    delivered: usize = 0,
    /// The last step the loop completed, or null when there was nothing to do.
    last_step: ?recorder_mod.LogStep = null,
    stopped_on: StoppedOn = .end,
};

pub const Driver = struct {
    const Self = @This();

    rt: *Runtime,
    io: std.Io,
    loader: *recorder_mod.ReplayFromLog,

    /// Bind `rt` and `loader` into the deterministic cadence. The loader is
    /// switched to reproduce mode (see the module doc); everything else about
    /// it — codecs, bindings, window, filter, holes policy — stays the
    /// caller's. Borrows both; the caller keeps them alive.
    pub fn init(rt: *Runtime, io: std.Io, loader: *recorder_mod.ReplayFromLog) InitError!Self {
        if (rt.det == null) return error.NotDeterministic;
        if (rt.poolStats() == null) return error.NoPool;
        if (rt.ticker_running.load(.acquire)) return error.TickerRunning;
        loader.reproduceTimers();
        return .{ .rt = rt, .io = io, .loader = loader };
    }

    /// Play the log to its end (or to the loader's window edge).
    pub fn runToEnd(self: *Self) anyerror!RunReport {
        return self.run(.end, 0);
    }

    /// Play until the step whose `seq` is `>= seq_bound` has completed —
    /// inclusive: the bound's seq *lands*, then the world stops. With the
    /// loader's `[from, to)` window this is the other bracket: the window
    /// picks the prefix, the bound picks the moment inside it.
    pub fn runUntilSeq(self: *Self, seq_bound: u64) anyerror!RunReport {
        return self.run(.seq, seq_bound);
    }

    /// Play until the step whose recorded stamp is `>= clock_bound` ms has
    /// completed. The manual clock ends at that step's stamp, not at the
    /// bound: time here moves in recorded increments, not continuous ones.
    pub fn runUntilClock(self: *Self, clock_bound: i64) anyerror!RunReport {
        return self.run(.clock, clock_bound);
    }

    fn run(self: *Self, comptime bound: enum { end, seq, clock }, limit: anytype) anyerror!RunReport {
        var report: RunReport = .{};
        while (try self.loader.step()) |step| {
            // The step moved the manual clock to the record's stamp and — for
            // a `.message` record — posted the delivery. Now the wheel: drain
            // the arm/cancel commands the last cascade issued, then fire
            // every timer the moved clock has reached. Order inside the
            // iteration is deliver-then-tick, so a message and a timer that
            // share a stamp are handled in the file's order (the message's
            // token reached the ready ring first).
            _ = self.rt.tick();
            try self.settle();
            report.iterations += 1;
            if (step.kind != .timer) report.delivered += 1;
            report.last_step = step;
            switch (bound) {
                .end => {},
                .seq => if (step.seq >= limit) {
                    report.stopped_on = .seq;
                    return report;
                },
                .clock => if (step.clock_ms >= limit) {
                    report.stopped_on = .clock;
                    return report;
                },
            }
        }
        return report;
    }

    /// Wait until the pool parks — the first `idle_waits` increment after the
    /// push that preceded this call. The module doc has the single-thread
    /// argument for why that one increment proves the cascade quenched.
    fn settle(self: *Self) error{PoolWedged}!void {
        const before = self.rt.poolStats() orelse unreachable; // init checked
        var iters: u64 = 0;
        while (true) {
            const now = self.rt.poolStats().?;
            if (now.idle_waits != before.idle_waits) return;
            iters += 1;
            if (iters >= wedged_wait_iters) return error.PoolWedged;
            std.Io.sleep(self.io, .{ .nanoseconds = settle_poll_ns }, .awake) catch |err| switch (err) {
                // A cancelled sleep is not a stopped pool: keep waiting, the
                // next poll reads the same counters.
                error.Canceled => {},
            };
        }
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

const Clock = @import("clock.zig").Clock;
const DeliveryLog = recorder_mod.DeliveryLog;

/// The recording run's payload format — u32 on every track, so one codec
/// serves the drain and every `setCodec` on the reader side.
const U32Codec = struct {
    pub const name: []const u8 = "replay-driver:u32";
    pub const version: u16 = 1;

    pub fn encode(alloc: std.mem.Allocator, value: u32) ![]u8 {
        const bytes = try alloc.alloc(u8, @sizeOf(u32));
        std.mem.writeInt(u32, bytes[0..4], value, .little);
        return bytes;
    }

    pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !u32 {
        _ = alloc;
        if (bytes.len != @sizeOf(u32)) return error.BadPayloadLength;
        return std.mem.readInt(u32, bytes[0..4], .little);
    }
};

/// The downstream worker: pure cascade target. Its own deliveries are what
/// "reproduced, not re-posted" means for plain messages — the file the tests
/// build never carries one, yet every replay must produce them identically.
const Back = struct {
    pub const Message = u32;
    received: u64 = 0,

    pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
        _ = msg;
        _ = ctx;
        self.received += 1;
    }
};

/// The ingress worker, and the file's only track: external sends land here,
/// each one cascades a `rng()`-mixed payload downstream and arms a timer that
/// fires back into this same worker. Everything the S-level claim needs in one
/// handler: a cascade, a timer, and the seeded random source.
const Front = struct {
    pub const Message = u32;
    const BackHandle = runtime_impl.Handle(Back, 64);
    back: *BackHandle,

    pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
        if (msg >= 1000) {
            // The timer's own delivery: cascade downstream, arm nothing new.
            try self.back.send(msg *% 3);
            return;
        }
        const r = ctx.runtime.rng().int(u32);
        try self.back.send(msg ^ r);
        _ = try ctx.handle.after(30, msg + 1000);
    }
};

/// How many external sends a recording holds. Twelve iterations keep the whole
/// acceptance under a second while long enough for timer/cascade interleaving.
const ext_count: u32 = 12;

/// Wait for the pool to park — the recording drive's copy of the driver's
/// settle (the driver itself needs a loader, which a recording does not have).
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

/// One runtime's recording, reduced to bytes: per named track (in the order
/// given), per entry, the ordering stamps and the payload. `with_seq` is the
/// replay-vs-replay form (the runtime's own seqs ride along); without it the
/// bytes compare across *different* runtimes, whose sequencers count their own
/// deliveries.
fn digestLog(
    allocator: std.mem.Allocator,
    log: *DeliveryLog,
    ids: []const []const u8,
    with_seq: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var tmp: [8]u8 = undefined;
    for (ids) |id| {
        const track = log.find(id) orelse return error.MissingTrack;
        try buf.appendSlice(allocator, id);
        try buf.append(allocator, 0);
        const n = track.len(track);
        std.mem.writeInt(u64, &tmp, @intCast(n), .little);
        try buf.appendSlice(allocator, &tmp);
        for (0..n) |i| {
            const e = track.entry(track, i);
            if (with_seq) {
                std.mem.writeInt(u64, &tmp, e.seq, .little);
                try buf.appendSlice(allocator, &tmp);
            }
            std.mem.writeInt(u64, &tmp, @bitCast(e.clock_ms), .little);
            try buf.appendSlice(allocator, &tmp);
            std.mem.writeInt(u16, tmp[0..2], @backingInt(e.kind), .little);
            try buf.appendSlice(allocator, tmp[0..2]);
            const p: *const u32 = @ptrCast(@alignCast(e.payload));
            std.mem.writeInt(u32, tmp[0..4], p.*, .little);
            try buf.appendSlice(allocator, tmp[0..4]);
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// The expected `back` stream, computed from first principles: a local Prng
/// with the run's seed reproduces the `rng()` stream the handlers drew on
/// (one draw per external message, in delivery order — the only consumer),
/// and every timer's cascade is `(i + 1000) *% 3`. This is the assertion that
/// does not trust the recording run: the replay's downstream stream must be
/// the one the *spec* predicts.
///
/// `with_seq` matches `digestLog`'s replay-vs-replay form. The replayed
/// runtime's sequencer numbers its own deliveries in driver order: iteration
/// `i` delivers `ext_i` (front, seq 4i), cascades `b_i` (back, seq 4i+1),
/// reproduces `t_i` (front, seq 4i+2), cascades `bt_i` (back, seq 4i+3) — so
/// back's entries are exactly the odd seqs.
fn expectedBackStream(allocator: std.mem.Allocator, seed: u64, with_seq: bool) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var tmp: [8]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(seed);
    var rnd = prng.random();
    try buf.appendSlice(allocator, "back");
    try buf.append(allocator, 0);
    std.mem.writeInt(u64, &tmp, @as(u64, ext_count) * 2, .little);
    try buf.appendSlice(allocator, &tmp);
    for (0..ext_count) |i| {
        const v: u32 = @intCast(i);
        const r = rnd.int(u32);
        // The external message's cascade, stamped at its own iteration's clock.
        if (with_seq) {
            std.mem.writeInt(u64, &tmp, @as(u64, i) * 4 + 1, .little);
            try buf.appendSlice(allocator, &tmp);
        }
        std.mem.writeInt(u64, &tmp, @as(u64, i) * 100, .little);
        try buf.appendSlice(allocator, &tmp);
        std.mem.writeInt(u16, tmp[0..2], @backingInt(dlog.Kind.message), .little);
        try buf.appendSlice(allocator, tmp[0..2]);
        std.mem.writeInt(u32, tmp[0..4], v ^ r, .little);
        try buf.appendSlice(allocator, tmp[0..4]);
        // The timer's cascade, delivered when the *next* iteration's tick
        // crosses its deadline — stamped there.
        if (with_seq) {
            std.mem.writeInt(u64, &tmp, @as(u64, i) * 4 + 3, .little);
            try buf.appendSlice(allocator, &tmp);
        }
        std.mem.writeInt(u64, &tmp, @as(u64, i) * 100 + 100, .little);
        try buf.appendSlice(allocator, &tmp);
        std.mem.writeInt(u16, tmp[0..2], @backingInt(dlog.Kind.message), .little);
        try buf.appendSlice(allocator, tmp[0..2]);
        std.mem.writeInt(u32, tmp[0..4], (v + 1000) *% 3, .little);
        try buf.appendSlice(allocator, tmp[0..4]);
    }
    return buf.toOwnedSlice(allocator);
}

/// Spawn the graph onto `rt` (det mode) and return the front handle. Back has
/// no track: the input boundary is `front` alone (see the module doc — the
/// log of an S-level replay is the boundary, cascades are reproduced).
fn spawnGraph(rt: *Runtime, record_back: bool) !*runtime_impl.Handle(Front, 64) {
    const back = if (record_back)
        try rt.spawn(Back, .{}, .{ .capacity = 64, .mode = .pooled, .record = .{ .id = "back", .capacity = 256 } })
    else
        try rt.spawn(Back, .{}, .{ .capacity = 64, .mode = .pooled });
    return rt.spawn(Front, .{ .back = back }, .{ .capacity = 64, .mode = .pooled, .record = .{ .id = "front", .capacity = 256 } });
}

test "replay.Driver: init refuses a non-det runtime and a running ticker" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var manual = Clock.Manual{ .now_ms = 0 };
    var records: [0]dlog.Record = .{};

    // A plain runtime: the mechanics would turn, the guarantee would not.
    var plain = Runtime.init(allocator, io, manual.clock());
    defer plain.deinit();
    var loader1 = try recorder_mod.ReplayFromLog.init(allocator, &manual, &records);
    defer loader1.deinit();
    try std.testing.expectError(error.NotDeterministic, Driver.init(&plain, io, &loader1));

    // Det mode but somebody started the ticker: two drivers of one wheel.
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(allocator, io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 4 },
        .deterministic = .{ .seed = 1 },
    });
    defer rt.deinit();
    var loader2 = try recorder_mod.ReplayFromLog.init(allocator, &clk, &records);
    defer loader2.deinit();
    try rt.start();
    try std.testing.expectError(error.TickerRunning, Driver.init(&rt, io, &loader2));
}

test "replay.Driver (§4.3): the same log replays byte-identically ten times, forks legally on another seed, and timers are reproduced by the wheel" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // ── record (det runtime A, seed 42, only the boundary tracked) ───────
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buf: [192]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/driver", .{dir.sub_path[0..]});
    const config: dlog.Config = .{
        .dir_path = dir_path,
        .max_segment_bytes = 1 << 20,
        .max_record_bytes = 4096,
        .sync_mode = .none,
    };

    var digest_a: []u8 = undefined;
    {
        var clk = Clock.Manual{ .now_ms = 0 };
        var rt_a = try Runtime.initWithOptions(allocator, io, .{
            .clock = .{ .manual = &clk },
            .scheduler = .{ .max_pooled_workers = 4 },
            .deterministic = .{ .seed = 42 },
        });
        defer rt_a.deinit();
        const front = try spawnGraph(&rt_a, false);
        for (0..ext_count) |i| {
            clk.set(@intCast(i * 100));
            _ = rt_a.tick();
            try front.send(@intCast(i));
            try settlePool(&rt_a, io);
        }
        // Fire the last timer (armed at 1100, deadline 1130).
        clk.set(ext_count * 100);
        _ = rt_a.tick();
        try settlePool(&rt_a, io);

        const log_a = rt_a.deliveryLog().?;
        digest_a = try digestLog(allocator, log_a, &.{"front"}, false);

        try log_a.setCodecRef(front.track.?, U32Codec, u32);
        var writer = try dlog.Writer.open(allocator, io, config);
        const report = try log_a.drainTo(&writer);
        writer.deinit();
        try std.testing.expectEqual(@as(usize, ext_count * 2), report.records);
        try std.testing.expectEqual(@as(u64, 0), report.holes);
    }
    defer allocator.free(digest_a);

    var scanned = try dlog.scan(allocator, io, config);
    defer scanned.deinit(allocator);
    try scanned.expectClean();
    try std.testing.expectEqual(@as(usize, ext_count * 2), scanned.records.len);

    // The expected downstream stream, from the spec rather than from A — in
    // the with-seq layout `digest_full` uses, so a plain slice compare works.
    const want_back = try expectedBackStream(allocator, 42, true);
    defer allocator.free(want_back);

    // ── replay ────────────────────────────────────────────────────────────
    const Replay = struct {
        digest_full: []u8,
        delivered: usize,
        timer_steps: u64,
    };

    const replayOnce = struct {
        fn call(alloc: std.mem.Allocator, io2: std.Io, records: []const dlog.Record, seed: u64) !Replay {
            var clk = Clock.Manual{ .now_ms = 0 };
            var rt = try Runtime.initWithOptions(alloc, io2, .{
                .clock = .{ .manual = &clk },
                .scheduler = .{ .max_pooled_workers = 4 },
                .deterministic = .{ .seed = seed },
            });
            defer rt.deinit();
            const front = try spawnGraph(&rt, true);

            var loader = try recorder_mod.ReplayFromLog.init(alloc, &clk, records);
            defer loader.deinit();
            try loader.setCodec("front", U32Codec, u32);
            try loader.bindDecoded("front", front);
            try std.testing.expect(loader.isFullyBound());

            var driver = try Driver.init(&rt, io2, &loader);
            const report = try driver.runToEnd();
            try std.testing.expectEqual(@as(usize, ext_count * 2), report.iterations);
            try std.testing.expectEqual(StoppedOn.end, report.stopped_on);

            const log = rt.deliveryLog().?;
            return .{
                .digest_full = try digestLog(alloc, log, &.{ "front", "back" }, true),
                .delivered = report.delivered,
                .timer_steps = loader.timerRecords(),
            };
        }
    }.call;

    // §4.3-1: ten replays of one recording, byte-identical — including the
    // runtime's own seq assignment, so this pins the whole delivery order.
    var first: ?Replay = null;
    defer if (first) |f| allocator.free(f.digest_full);
    for (0..10) |round| {
        const replay = try replayOnce(allocator, io, scanned.records, 42);
        if (first == null) {
            first = replay;
            continue;
        }
        defer allocator.free(replay.digest_full);
        try std.testing.expectEqualSlices(u8, first.?.digest_full, replay.digest_full);
        _ = round;
    }
    const f = first.?;
    // Twelve external sends delivered from the file; twelve timer steps the
    // wheel reproduced — never re-posted, so `delivered` sees none of them.
    try std.testing.expectEqual(@as(usize, ext_count), f.delivered);
    try std.testing.expectEqual(@as(u64, ext_count), f.timer_steps);

    // The recording and the replay agree on the boundary track, stamp for
    // stamp (seq excluded: each runtime's sequencer counts its own).
    {
        var clk = Clock.Manual{ .now_ms = 0 };
        var rt = try Runtime.initWithOptions(allocator, io, .{
            .clock = .{ .manual = &clk },
            .scheduler = .{ .max_pooled_workers = 4 },
            .deterministic = .{ .seed = 42 },
        });
        defer rt.deinit();
        const front = try spawnGraph(&rt, true);
        var loader = try recorder_mod.ReplayFromLog.init(allocator, &clk, scanned.records);
        defer loader.deinit();
        try loader.setCodec("front", U32Codec, u32);
        try loader.bindDecoded("front", front);
        var driver = try Driver.init(&rt, io, &loader);
        _ = try driver.runToEnd();
        const digest_front = try digestLog(allocator, rt.deliveryLog().?, &.{"front"}, false);
        defer allocator.free(digest_front);
        try std.testing.expectEqualSlices(u8, digest_a, digest_front);
    }

    // The downstream stream is the one the spec predicts — cascades were
    // reproduced, not re-posted (the file holds no `back` record at all).
    // `digest_full` is front-then-back, so the spec's `back` section must
    // appear inside it, byte for byte.
    try std.testing.expect(std.mem.indexOf(u8, f.digest_full, want_back) != null);

    // §4.3-2: another seed forks legally — its two runs agree with each other
    // and disagree with seed 42 (the workload routes `rng()` into payloads).
    const fork1 = try replayOnce(allocator, io, scanned.records, 43);
    defer allocator.free(fork1.digest_full);
    const fork2 = try replayOnce(allocator, io, scanned.records, 43);
    defer allocator.free(fork2.digest_full);
    try std.testing.expectEqualSlices(u8, fork1.digest_full, fork2.digest_full);
    try std.testing.expect(!std.mem.eql(u8, f.digest_full, fork1.digest_full));
}

test "replay.Driver: runUntilSeq and runUntilClock stop where documented, and a run resumes after the bound" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // A smaller recording is enough: four externals, four timers.
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buf: [192]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/driver-bounds", .{dir.sub_path[0..]});
    const config: dlog.Config = .{
        .dir_path = dir_path,
        .max_segment_bytes = 1 << 20,
        .max_record_bytes = 4096,
        .sync_mode = .none,
    };
    {
        var clk = Clock.Manual{ .now_ms = 0 };
        var rt_a = try Runtime.initWithOptions(allocator, io, .{
            .clock = .{ .manual = &clk },
            .scheduler = .{ .max_pooled_workers = 4 },
            .deterministic = .{ .seed = 7 },
        });
        defer rt_a.deinit();
        const front = try spawnGraph(&rt_a, false);
        for (0..4) |i| {
            clk.set(@intCast(i * 100));
            _ = rt_a.tick();
            try front.send(@intCast(i));
            try settlePool(&rt_a, io);
        }
        clk.set(400);
        _ = rt_a.tick();
        try settlePool(&rt_a, io);
        const log_a = rt_a.deliveryLog().?;
        try log_a.setCodecRef(front.track.?, U32Codec, u32);
        var writer = try dlog.Writer.open(allocator, io, config);
        _ = try log_a.drainTo(&writer);
        writer.deinit();
    }
    var scanned = try dlog.scan(allocator, io, config);
    defer scanned.deinit(allocator);
    try scanned.expectClean();
    // front is the only track, so its claims are the log's seqs: dense
    // 0..7, alternating message/timer (ext0, t0, ext1, t1, …).
    try std.testing.expectEqual(@as(usize, 8), scanned.records.len);

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(allocator, io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 4 },
        .deterministic = .{ .seed = 7 },
    });
    defer rt.deinit();
    const front = try spawnGraph(&rt, true);

    var loader = try recorder_mod.ReplayFromLog.init(allocator, &clk, scanned.records);
    defer loader.deinit();
    try loader.setCodec("front", U32Codec, u32);
    try loader.bindDecoded("front", front);
    var driver = try Driver.init(&rt, io, &loader);

    // runUntilSeq(3): stops *after* seq 3 has landed (inclusive). Steps
    // 0..3 = ext0, t0, ext1, t1 — two deliveries, two timer steps.
    const r1 = try driver.runUntilSeq(3);
    try std.testing.expectEqual(StoppedOn.seq, r1.stopped_on);
    try std.testing.expectEqual(@as(usize, 4), r1.iterations);
    try std.testing.expectEqual(@as(usize, 2), r1.delivered);
    try std.testing.expectEqual(@as(u64, 3), r1.last_step.?.seq);
    try std.testing.expectEqual(@as(i64, 200), clk.now_ms);

    // runUntilClock(250): resumes where the bound left off — nothing is
    // re-done. The next steps are ext2@200, t2@300: the first stamp ≥ 250
    // is t2's, so the run stops there with the clock at 300.
    const r2 = try driver.runUntilClock(250);
    try std.testing.expectEqual(StoppedOn.clock, r2.stopped_on);
    try std.testing.expectEqual(@as(usize, 2), r2.iterations);
    try std.testing.expectEqual(@as(usize, 1), r2.delivered);
    try std.testing.expectEqual(@as(u64, 5), r2.last_step.?.seq);
    try std.testing.expectEqual(@as(i64, 300), clk.now_ms);

    // runToEnd: the remaining two steps (ext3@300, t3@400), then done.
    const r3 = try driver.runToEnd();
    try std.testing.expectEqual(StoppedOn.end, r3.stopped_on);
    try std.testing.expectEqual(@as(usize, 2), r3.iterations);
    try std.testing.expectEqual(@as(usize, 1), r3.delivered);
    try std.testing.expectEqual(@as(u64, 7), r3.last_step.?.seq);
    try std.testing.expectEqual(@as(i64, 400), clk.now_ms);
    try std.testing.expectEqual(@as(usize, 0), loader.remaining());
    try std.testing.expectEqual(@as(u64, 4), loader.timerRecords());

    // The whole bounded path produced the full graph anyway: every cascade
    // landed (four external + four timer messages into back).
    const back_track = rt.deliveryLog().?.find("back").?;
    try std.testing.expectEqual(@as(usize, 8), back_track.len(back_track));
}

/// One worker, two timers per message with the *same* deadline: the workload
/// D4's FIFO contract has to survive end to end — arm order at the wheel, fire
/// order at the tick, payload order in the track, byte order in the digest.
const Solo = struct {
    pub const Message = u32;

    pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
        _ = self;
        if (msg >= 100) return; // a timer's own delivery: nothing further
        _ = try ctx.handle.after(20, 100 + msg);
        _ = try ctx.handle.after(20, 200 + msg);
    }
};

test "replay.Driver: same-deadline timers fire in arm order through the whole driver path (D4)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buf: [192]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/driver-d4", .{dir.sub_path[0..]});
    const config: dlog.Config = .{
        .dir_path = dir_path,
        .max_segment_bytes = 1 << 20,
        .max_record_bytes = 4096,
        .sync_mode = .none,
    };
    {
        var clk = Clock.Manual{ .now_ms = 0 };
        var rt_a = try Runtime.initWithOptions(allocator, io, .{
            .clock = .{ .manual = &clk },
            .scheduler = .{ .max_pooled_workers = 4 },
            .deterministic = .{ .seed = 3 },
        });
        defer rt_a.deinit();
        const solo = try rt_a.spawn(Solo, .{}, .{ .capacity = 64, .mode = .pooled, .record = .{ .id = "solo", .capacity = 64 } });
        for (0..3) |i| {
            clk.set(@intCast(i * 100));
            _ = rt_a.tick();
            try solo.send(@intCast(i));
            try settlePool(&rt_a, io);
        }
        clk.set(300);
        _ = rt_a.tick();
        try settlePool(&rt_a, io);
        const log_a = rt_a.deliveryLog().?;
        try log_a.setCodecRef(solo.track.?, U32Codec, u32);
        var writer = try dlog.Writer.open(allocator, io, config);
        _ = try log_a.drainTo(&writer);
        writer.deinit();
    }
    var scanned = try dlog.scan(allocator, io, config);
    defer scanned.deinit(allocator);
    try scanned.expectClean();
    try std.testing.expectEqual(@as(usize, 9), scanned.records.len);

    // Two replays; each must show arm order (100 before 200) at every stamp,
    // and agree with each other byte for byte.
    var first: ?[]u8 = null;
    defer if (first) |f| allocator.free(f);
    for (0..2) |_| {
        var clk = Clock.Manual{ .now_ms = 0 };
        var rt = try Runtime.initWithOptions(allocator, io, .{
            .clock = .{ .manual = &clk },
            .scheduler = .{ .max_pooled_workers = 4 },
            .deterministic = .{ .seed = 3 },
        });
        defer rt.deinit();
        const solo = try rt.spawn(Solo, .{}, .{ .capacity = 64, .mode = .pooled, .record = .{ .id = "solo", .capacity = 64 } });
        var loader = try recorder_mod.ReplayFromLog.init(allocator, &clk, scanned.records);
        defer loader.deinit();
        try loader.setCodec("solo", U32Codec, u32);
        try loader.bindDecoded("solo", solo);
        var driver = try Driver.init(&rt, io, &loader);
        _ = try driver.runToEnd();

        const track = rt.deliveryLog().?.find("solo").?;
        const n = track.len(track);
        try std.testing.expectEqual(@as(usize, 9), n);
        const want_payloads = [_]u32{ 0, 100, 200, 1, 101, 201, 2, 102, 202 };
        const want_clocks = [_]i64{ 0, 100, 100, 100, 200, 200, 200, 300, 300 };
        const want_kinds = [_]dlog.Kind{ .message, .timer, .timer, .message, .timer, .timer, .message, .timer, .timer };
        for (0..n) |i| {
            const e = track.entry(track, i);
            const p: *const u32 = @ptrCast(@alignCast(e.payload));
            try std.testing.expectEqual(want_payloads[i], p.*);
            try std.testing.expectEqual(want_clocks[i], e.clock_ms);
            try std.testing.expectEqual(want_kinds[i], e.kind);
        }
        const digest = try digestLog(allocator, rt.deliveryLog().?, &.{"solo"}, true);
        if (first == null) {
            first = digest;
        } else {
            defer allocator.free(digest);
            try std.testing.expectEqualSlices(u8, first.?, digest);
        }
    }
}
