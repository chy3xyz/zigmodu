const std = @import("std");
const zigmodu = @import("zigmodu");

fn now() i128 {
    return zigmodu.time.monotonicNow();
}

fn elapsedMs(t0: i128) f64 {
    const dt = now() - t0;
    return @as(f64, @floatFromInt(dt)) / 1_000_000.0;
}

/// Median of three samples: run harness `f` three times with `args` and keep the
/// middle value (after sorting, index 1 — for three values that is the median).
///
/// A single sample does not survive a machine that runs anything else. Measured
/// under load: `validateModules x100K` at 446 ms, then 292/295 ms on the two runs
/// right after it. That 1.5x spread is inside the 2.0x gate window, so a single
/// sample turns a scheduling stall into a reported regression larger than the
/// thing the gate exists to catch (an order-of-magnitude slip). The median drops
/// the spike; three samples that are *all* slow — a real regression, or a machine
/// loaded for the whole run — still leave the median slow, so the gate keeps its
/// teeth. What the spread looks like is not hidden either: every call prints the
/// sorted triple, so `scripts/check-bench.sh` shows whether a breach was one
/// stall or three slowdowns.
///
/// Every harness in this file rebuilds its fixture per call, which is what makes
/// repeating one side-effect free. The repeat costs 3x the suite's wall time;
/// the suite runs in CI on push to main/master only, and it is cheaper than a
/// gate that fires on machine noise.
fn median3(comptime name: []const u8, comptime f: anytype, args: anytype) !f64 {
    var samples: [3]f64 = undefined;
    for (&samples) |*sample| sample.* = try @call(.auto, f, args);
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    std.debug.print("  [med3] {s}: {d:.2} / {d:.2} / {d:.2} ms (median {d:.2})\n", .{ name, samples[0], samples[1], samples[2], samples[1] });
    return samples[1];
}

/// Allocator for the harnesses whose timed loop allocates on every turn.
///
/// The suite's own allocator is `a`, a page-allocator arena that never frees:
/// fine at the old scales, where a harness allocated a few thousand times, but
/// these metrics now run tens of thousands of turns, so every `free` in the loop
/// being a no-op means everything the run ever allocated stays live — at these
/// scales the suite's peak RSS went 82 MB -> 213 MB, `findById x20K` alone
/// holding ~100 MB of it, and the clock covered the host's page-fault path as
/// much as the code under test. A reclaiming allocator is also the honest
/// choice: production does not run `checkHealth` or a query loop on an arena, so
/// the harness should not either. Freed blocks come back off the allocator's
/// freelists, which keeps the pages warm and the measurement repeatable — peak
/// RSS 40 MB and `findById x20K` at 1.04x min-to-max across its three samples,
/// against 1.10-1.37x before it.
const harness_allocator = std.heap.smp_allocator;

fn benchModuleScan(count: usize) !f64 {
    const MockModule = struct {
        pub const info = zigmodu.api.Module{ .name = "bench", .description = "Benchmark module", .dependencies = &.{} };
        pub fn init() !void {}
        pub fn deinit() void {}
    };
    const t0 = now();
    for (0..count) |_| {
        var modules = try zigmodu.scanModules(harness_allocator, .{MockModule});
        modules.deinit();
    }
    return elapsedMs(t0);
}

fn benchModuleValidation(allocator: std.mem.Allocator, count: usize) !f64 {
    const A = struct {
        pub const info = zigmodu.api.Module{ .name = "a", .description = "A", .dependencies = &.{} };
        pub fn init() !void {}
        pub fn deinit() void {}
    };
    const B = struct {
        pub const info = zigmodu.api.Module{ .name = "b", .description = "B", .dependencies = &.{"a"} };
        pub fn init() !void {}
        pub fn deinit() void {}
    };
    var modules = try zigmodu.scanModules(allocator, .{ A, B });
    defer modules.deinit();
    const t0 = now();
    for (0..count) |_| {
        try zigmodu.validateModules(&modules);
    }
    return elapsedMs(t0);
}

fn benchEventBus(allocator: std.mem.Allocator, listeners: usize, events: usize) !f64 {
    const E = struct { id: u64 };
    var bus = zigmodu.TypedEventBus(E).init(allocator);
    defer bus.deinit();
    for (0..listeners) |_| {
        try bus.subscribe(struct {
            fn cb(_: E) void {}
        }.cb);
    }
    const t0 = now();
    for (0..events) |_| {
        bus.publish(.{ .id = 1 });
    }
    return elapsedMs(t0);
}

/// Closed-state fast path: a `CircuitBreaker.call` over a no-op operation, which
/// is what production hits for every request while the dependency is healthy.
///
/// This harness measured a hard 0.00 ms in a ReleaseFast build for as long as it
/// existed, and the number was not fast, it was absent: the breaker was a stack
/// local whose only live field was `name`, the operation was a comptime-known
/// no-op, and `onSuccess` in the CLOSED state just writes `failure_count = 0`.
/// Every iteration therefore had an identical, unobservable effect, so LLVM
/// deleted the loop and the timing came back as literal zero — leaving this
/// metric with no gate coverage at all (`check-bench.sh` can only WARN on a
/// baseline of 0.000; there is no ratio to compare). Measured on this machine,
/// the fold is undone by *consuming* each `Result` (barrier: 10M calls time at
/// 4.8 ms instead of 0.0); keeping the breaker on the heap on top of that is what
/// puts its state traffic back in the timed path (6.5 ms — the stack version lets
/// LLVM keep the state in registers and elide the loads). The counts are checked
/// afterwards, so a harness that silently stops driving the breaker fails the run
/// instead of reporting a suspiciously fast number.
fn benchCircuitBreaker(allocator: std.mem.Allocator, calls: usize) !f64 {
    const cb = try allocator.create(zigmodu.CircuitBreaker);
    defer allocator.destroy(cb);
    cb.* = try zigmodu.CircuitBreaker.init(allocator, "bench", .{ .failure_threshold = 100, .success_threshold = 2, .timeout_seconds = 30, .half_open_max_calls = 10 });
    defer cb.deinit();

    const op = struct {
        fn op() anyerror!void {}
    }.op;

    var accepted: usize = 0;
    const t0 = now();
    for (0..calls) |_| {
        const result = cb.call(op);
        switch (result) {
            .success => accepted += 1,
            .failure => return error.BenchCircuitBreakerUnexpectedFailure,
            .circuit_open => return error.BenchCircuitBreakerTrippedOpen,
        }
        std.mem.doNotOptimizeAway(&result);
    }
    const ms = elapsedMs(t0);

    if (accepted != calls) return error.BenchCircuitBreakerLostCalls;
    return ms;
}

fn benchRateLimiter(allocator: std.mem.Allocator, calls: usize) !f64 {
    var rl = try zigmodu.RateLimiter.init(allocator, "bench", 1_000_000, 1_000_000);
    defer rl.deinit();
    const t0 = now();
    for (0..calls) |_| {
        _ = rl.tryAcquire();
    }
    return elapsedMs(t0);
}

fn benchHealthEndpoint(checks: usize, iterations: usize) !f64 {
    var ep = zigmodu.HealthEndpoint.init(harness_allocator);
    defer ep.deinit();
    for (0..checks) |i| {
        const name = try std.fmt.allocPrint(harness_allocator, "check-{}", .{i});
        defer harness_allocator.free(name);
        try ep.registerCheck(name, "bench", zigmodu.HealthEndpoint.alwaysUp);
    }
    const t0 = now();
    for (0..iterations) |_| {
        var d = ep.checkHealth();
        d.components.deinit();
    }
    return elapsedMs(t0);
}

fn benchApplicationLifecycle(io: std.Io, count: usize) !f64 {
    const M = struct {
        pub const info = zigmodu.api.Module{ .name = "m", .description = "M", .dependencies = &.{} };
        pub fn init() !void {}
        pub fn deinit() void {}
    };
    const t0 = now();
    for (0..count) |_| {
        var app = try zigmodu.Application.init(io, harness_allocator, "bench", .{M}, .{});
        try app.start();
        app.stop();
        app.deinit();
    }
    return elapsedMs(t0);
}

fn benchDbQuery(io: std.Io, queries: usize) !f64 {
    var client = zigmodu.data.sqlx.Client.init(harness_allocator, io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, value REAL)", &.{});
    for (0..100) |i| {
        const s = try std.fmt.allocPrint(harness_allocator, "INSERT INTO t VALUES ({}, 'item{}', {}.0)", .{ i, i, i });
        defer harness_allocator.free(s);
        _ = try client.exec(s, &.{});
    }
    const backend = zigmodu.data.SqlxBackend{ .allocator = harness_allocator, .client = &client };
    var orm = zigmodu.data.orm.Orm(zigmodu.data.SqlxBackend){ .backend = backend };
    const Row = struct {
        pub const sql_table_name: []const u8 = "t";
        id: i64,
        name: []const u8,
        value: f64,
    };
    var repo = zigmodu.data.Repository(Row){ .orm = &orm };
    _ = try repo.findById(@as(i64, 50));
    const t0 = now();
    for (0..queries) |_| {
        if (try repo.findById(@as(i64, 50))) |r| harness_allocator.free(r.name);
    }
    return elapsedMs(t0);
}

const BenchResult = struct {
    name: []const u8,
    unit: []const u8 = "ms",
    /// Median of the metric's three samples (`median3`), never one run's duration
    /// — this is the value `scripts/check-bench.sh` thresholds.
    value: f64,
};

// ─────────────────────────────────────────────────
// Runtime primitives (`src/runtime/**`) — the framework's worker plumbing
//
// Deliberately deterministic: no sockets, no threads, no wall-clock deadlines.
// Every harness heap-allocates the structure it drives and feeds each result
// through `std.mem.doNotOptimizeAway`, so LLVM cannot conclude the address never
// escapes and delete the loop it is supposed to be timing. The `CircuitBreaker x*`
// metrics above used to be the counter-example — no heap, no barrier, and a
// printed 0.00 ms that was a folded-away loop rather than a fast one; see
// `benchCircuitBreaker` for what changed.
// ─────────────────────────────────────────────────

const rt = zigmodu.runtime;

/// SPSC hand-off: `count` push/pop round trips through a bounded ring.
fn benchRingBuffer(allocator: std.mem.Allocator, count: usize) !f64 {
    const ring = try allocator.create(rt.RingBuffer(u64, 1024));
    defer allocator.destroy(ring);
    ring.* = .{};

    const t0 = now();
    for (0..count) |i| {
        if (!ring.tryPush(i)) return error.BenchRingFull;
        std.mem.doNotOptimizeAway(ring.tryPop() orelse return error.BenchRingEmpty);
    }
    return elapsedMs(t0);
}

/// Worker hand-off: `count` posts against a bounded mailbox, drained as it fills.
/// Capacity 256 (not 1024): `MpscRing.init` seeds every slot at comptime, and a
/// wider mailbox exceeds the default `@setEvalBranchQuota`.
fn benchMailbox(io: std.Io, allocator: std.mem.Allocator, count: usize) !f64 {
    const M = rt.Mailbox(u64, 256);
    const mailbox = try allocator.create(M);
    defer allocator.destroy(mailbox);
    mailbox.* = M.init(io);

    var posted: usize = 0;
    const t0 = now();
    while (posted < count) {
        while (posted < count) {
            mailbox.send(posted) catch break; // queue full: drain, then resume
            posted += 1;
        }
        while (mailbox.tryRecv() != null) {}
    }
    return elapsedMs(t0);
}

const TimerFireCounter = struct {
    fired: u64 = 0,

    fn onFire(self: *@This(), _: rt.Wheel(u64).Id, _: u64) void {
        self.fired += 1;
    }
};

/// Fine-wheel span: half a level-0 rotation, so `advance` walks slots one by one
/// instead of taking the long-stall rescan path.
const timer_span_ms: i64 = rt.timer_wheel.max_cascade_ms / 2;

/// Scheduler: `count` timers spread over the fine wheel, then a single `advance`
/// that must fire all of them. The wheel's clock is the caller's, so this never
/// sleeps and never reads the wall clock.
fn benchTimerWheel(allocator: std.mem.Allocator, count: usize) !f64 {
    var wheel = rt.Wheel(u64).init(allocator, 0);
    defer wheel.deinit();
    var fired = TimerFireCounter{};
    const tick_count = timer_span_ms / rt.timer_wheel.slot_ms;

    const t0 = now();
    for (0..count) |i| {
        const tick: i64 = @intCast(i % @as(usize, @intCast(tick_count)));
        _ = try wheel.schedule((tick + 1) * rt.timer_wheel.slot_ms, @intCast(i));
    }
    _ = wheel.advance(timer_span_ms, &fired, TimerFireCounter.onFire);
    const ms = elapsedMs(t0);

    if (fired.fired != count) return error.BenchTimerWheelLostTimers;
    return ms;
}

const bench_bus_subscribers = 8;

const BusCounter = struct {
    events: u64 = 0,

    fn deliver(ctx: *anyopaque, event: u64) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.events += 1;
        std.mem.doNotOptimizeAway(event);
        return true;
    }

    fn sink(self: *@This()) rt.HotBus(u64, bench_bus_subscribers).Sink {
        return .{ .ctx = @ptrCast(self), .deliver = deliver };
    }
};

/// L0 fan-out: one publisher, `bench_bus_subscribers` sinks, `count` events.
fn benchHotBus(allocator: std.mem.Allocator, count: usize) !f64 {
    const bus = try allocator.create(rt.HotBus(u64, bench_bus_subscribers));
    defer allocator.destroy(bus);
    bus.* = rt.HotBus(u64, bench_bus_subscribers).init();

    const counters = try allocator.alloc(BusCounter, bench_bus_subscribers);
    defer allocator.free(counters);
    @memset(counters, BusCounter{});
    for (counters) |*counter| try bus.subscribeSink(counter.sink());
    bus.freeze();

    const t0 = now();
    for (0..count) |i| _ = try bus.publish(i);
    const ms = elapsedMs(t0);

    for (counters) |counter| {
        if (counter.events != count) return error.BenchHotBusLostEvents;
    }
    return ms;
}

const PoolSlot = struct { value: u64 = 0 };

/// Bounded reuse: `count` acquire/release round trips over a fixed-capacity pool.
fn benchObjectPool(allocator: std.mem.Allocator, count: usize) !f64 {
    const pool = try allocator.create(rt.ObjectPool(PoolSlot));
    defer allocator.destroy(pool);
    pool.* = try rt.ObjectPool(PoolSlot).init(allocator, 64, null);
    defer pool.deinit();

    const t0 = now();
    for (0..count) |i| {
        const slot = pool.acquire() orelse return error.BenchPoolExhausted;
        slot.value = i;
        std.mem.doNotOptimizeAway(slot.value);
        if (!pool.release(slot)) return error.BenchPoolRejectedRelease;
    }
    return elapsedMs(t0);
}

/// Ordering without a clock: `count` sequence stamps.
fn benchSequencer(allocator: std.mem.Allocator, count: usize) !f64 {
    const seq = try allocator.create(rt.Sequencer);
    defer allocator.destroy(seq);
    seq.* = rt.Sequencer.init(0);

    const t0 = now();
    for (0..count) |_| std.mem.doNotOptimizeAway(seq.next());
    return elapsedMs(t0);
}

fn benchWorkflow(allocator: std.mem.Allocator, io: std.Io, steps_count: usize, iterations: usize) !f64 {
    var registry = zigmodu.ai.SkillRegistry.init(allocator, io);
    defer registry.deinit();
    try registry.register(.{
        .name = "nop",
        .description = "",
        .parameters = &.{},
        .handler = struct {
            fn h(c: *zigmodu.ai.SkillContext, _: std.json.Value) anyerror!std.json.Value {
                var o = std.json.ObjectMap{};
                try o.put(c.allocator, try c.allocator.dupe(u8, "ok"), .{ .bool = true });
                return .{ .object = o };
            }
        }.h,
    });
    const steps = try allocator.alloc(zigmodu.ai.workflow.Step, steps_count);
    defer allocator.free(steps);
    for (0..steps_count) |i| {
        steps[i] = .{
            .name = try std.fmt.allocPrint(allocator, "step-{d}", .{i}),
            .kind = .{ .skill = .{ .name = "nop", .args = .{ .object = .{} } } },
        };
    }
    defer for (steps) |s| allocator.free(s.name);
    var wf = zigmodu.ai.workflow.Workflow.init(&registry, steps);
    // Steps and registry above are setup state and stay on the caller's arena;
    // what a single `run` allocates — step records, plus the skill's own result
    // value, which the handler builds with `ctx.allocator` — goes through the
    // reclaiming allocator, like the rest of the per-turn loops.
    var ctx = zigmodu.ai.SkillContext{ .allocator = harness_allocator };
    const t0 = now();
    for (0..iterations) |_| {
        var r = try wf.run(harness_allocator, &ctx);
        r.deinit();
    }
    return elapsedMs(t0);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var results = std.ArrayList(BenchResult).empty;

    std.debug.print("=== ZigModu Framework Benchmarks ===\n", .{});
    std.debug.print("Each metric is the median of 3 samples; every `[med3]` line lists all three, sorted.\n\n", .{});

    std.debug.print("-- Module System --\n", .{});
    // `scanModules` used to run 1K/10K turns, i.e. 0.17/1.7 ms per sample — under
    // the ~2 ms noise floor, where the 2.0x window is worth less than the machine's
    // own wobble (the same reasoning as the event and breaker metrics below).
    // It is 78 ns a turn on the reclaiming allocator, so a 10x pair at 100K/1M
    // lands at ~8 / ~78 ms.
    inline for (.{ .{ "scanModules x100K", 100000 }, .{ "scanModules x1M", 1_000_000 } }) |tc| {
        const ms = try median3(tc[0], benchModuleScan, .{tc[1]});
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} ops/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(tc[1])) / ms * 1000.0 });
    }
    inline for (.{ .{ "validateModules x10K", 10000 }, .{ "validateModules x100K", 100000 } }) |tc| {
        const ms = try median3(tc[0], benchModuleValidation, .{ a, tc[1] });
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} ops/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(tc[1])) / ms * 1000.0 });
    }
    // App lifecycle is the last metric under the floor: 4.0 ms recorded, 3.3-3.9 ms
    // measured on this machine, and the one `--update` kept rejecting — a 1000-app
    // sample allocates and frees a whole application per turn, so it moves with
    // whatever else the host is doing (measured at 8.3 and 11.6 ms while a compile
    // was running, both past the 2.0x window). 3K turns put it at ~10 ms and the
    // harness is on the reclaiming allocator, so the per-turn memory comes back.
    {
        const name = "App lifecycle x3K";
        const ms = try median3(name, benchApplicationLifecycle, .{ io, 3000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} ops/s)\n", .{ name, ms, 3000.0 / ms * 1000.0 });
    }

    std.debug.print("\n-- AI Workflow --\n", .{});
    // 100 iterations of a 20-step workflow is 0.4 ms of work; 5K puts it at ~19 ms.
    {
        const name = "workflow 20-step x5K";
        const ms = try median3(name, benchWorkflow, .{ a, io, 20, 5000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms\n", .{ name, ms });
    }

    std.debug.print("\n-- Event System --\n", .{});
    // 10M deliveries per metric, deliberately. At the previous scales these three
    // harnesses finished in 10-22 microseconds, i.e. on the floor of what this
    // machine can time: the gate's window is 2.0x, so 13 us of work with a 26 us
    // ceiling is crossed by ordinary scheduling jitter on a loaded host (measured
    // repeatedly, and reported as a regression in code nobody had touched — the
    // gate cannot tell a 13 us stall from a 13 us slowdown). Ten million inlined
    // dispatches land at 12-21 ms per sample, which is resolution the 2.0x window
    // can act on, and it costs ~0.3 s of the suite's wall time in total.
    inline for (.{ .{ "1L x10M events", 1, 10_000_000 }, .{ "10L x1M events", 10, 1_000_000 }, .{ "100L x100K events", 100, 100_000 } }) |tc| {
        const ms = try median3(tc[0], benchEventBus, .{ a, tc[1], tc[2] });
        const d = tc[1] * tc[2];
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} deliveries/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(d)) / ms * 1000.0 });
    }

    std.debug.print("\n-- Resilience --\n", .{});
    // Same noise floor, same fix: a CLOSED-path `call` is a load, a branch and a
    // store, so the old 100K/1M scales replayed it in 60-70 us and 0.6 ms — the
    // smaller of the two inside the same jitter band as the event metrics above
    // (one of nine samples already came back at 2.1x). Ten times the iterations
    // puts both at 6-7 ms and 60-70 ms, which the 2.0x window can judge.
    inline for (.{ .{ "CircuitBreaker x10M", 10_000_000 }, .{ "CircuitBreaker x100M", 100_000_000 } }) |tc| {
        const ms = try median3(tc[0], benchCircuitBreaker, .{ a, tc[1] });
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} calls/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(tc[1])) / ms * 1000.0 });
    }
    inline for (.{ .{ "RateLimiter x1M", 1_000_000 }, .{ "RateLimiter x10M", 10_000_000 } }) |tc| {
        const ms = try median3(tc[0], benchRateLimiter, .{ a, tc[1] });
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} tries/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(tc[1])) / ms * 1000.0 });
    }

    std.debug.print("\n-- Health Checks --\n", .{});
    // The health section used to run 1K calls of `checkHealth` — 0.16 ms and
    // 1.9 ms per sample, both on the noise floor. A call builds a hash map with
    // one entry per registered check, so the check count is also the map size and
    // the two scales below (1M checks each, 13 ns a check) land at ~13 / ~15 ms.
    inline for (.{ .{ "10 checks x100K", 10, 100000 }, .{ "100 checks x10K", 100, 10000 } }) |tc| {
        const ms = try median3(tc[0], benchHealthEndpoint, .{ tc[1], tc[2] });
        const t = tc[1] * tc[2];
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} checks/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(t)) / ms * 1000.0 });
    }

    std.debug.print("\n-- Database (SQLite :memory:) --\n", .{});
    // `findById x1K` was 0.7 ms per sample. 20K puts it at ~14 ms and stays under
    // the 10K-scale entry, which is already above the floor and untouched.
    inline for (.{ .{ "findById x20K", 20000 }, .{ "findById x10K", 10000 } }) |tc| {
        const ms = try median3(tc[0], benchDbQuery, .{ io, tc[1] });
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} queries/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(tc[1])) / ms * 1000.0 });
    }

    std.debug.print("\n-- Runtime (worker plumbing) --\n", .{});
    // One scale per primitive: in a ReleaseFast build these land at 6-22 ms, which
    // is stable enough to threshold, and a second scale would double both CI time
    // and the number of thresholds the gate has to hold.
    {
        const name = "RingBuffer SPSC x1M";
        const ms = try median3(name, benchRingBuffer, .{ a, 1_000_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} round trips/s)\n", .{ name, ms, 1_000_000.0 / ms * 1000.0 });
    }
    {
        const name = "Mailbox post+drain x1M";
        const ms = try median3(name, benchMailbox, .{ io, a, 1_000_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} messages/s)\n", .{ name, ms, 1_000_000.0 / ms * 1000.0 });
    }
    {
        const name = "TimerWheel x100K";
        const ms = try median3(name, benchTimerWheel, .{ a, 100_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} timers/s)\n", .{ name, ms, 100_000.0 / ms * 1000.0 });
    }
    {
        const name = "HotBus 8sub x1M";
        const ms = try median3(name, benchHotBus, .{ a, 1_000_000 });
        try results.append(a, .{ .name = name, .value = ms });
        const deliveries = 1_000_000.0 * @as(f64, bench_bus_subscribers);
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} deliveries/s)\n", .{ name, ms, deliveries / ms * 1000.0 });
    }
    {
        const name = "ObjectPool x1M";
        const ms = try median3(name, benchObjectPool, .{ a, 1_000_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} cycles/s)\n", .{ name, ms, 1_000_000.0 / ms * 1000.0 });
    }
    {
        const name = "Sequencer x10M";
        const ms = try median3(name, benchSequencer, .{ a, 10_000_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} stamps/s)\n", .{ name, ms, 10_000_000.0 / ms * 1000.0 });
    }

    // Emit bench-results.json for CI baseline tracking
    // (github-action-benchmark `customSmallerIsBetter` format); `value` is the
    // median of the three samples each metric was measured with (`median3`).
    const json = try std.json.Stringify.valueAlloc(a, results.items, .{});
    const file = try std.Io.Dir.cwd().createFile(io, "bench-results.json", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, json);

    std.debug.print("\nDone. Results written to bench-results.json\n", .{});
}
