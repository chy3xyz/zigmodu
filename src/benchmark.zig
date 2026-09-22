const std = @import("std");
const zigmodu = @import("zigmodu");

fn now() i128 {
    return zigmodu.time.monotonicNow();
}

fn elapsedMs(t0: i128) f64 {
    const dt = now() - t0;
    return @as(f64, @floatFromInt(dt)) / 1_000_000.0;
}

/// A reporting section's own wall time, measured around it.
///
/// Both extra-pass sections in this suite cost real CI time — the `[pct]`
/// section is one extra pass over the metrics it covers, and the `[alloc]`
/// section another over every gated metric — so the budget each one claims in
/// its banner is printed next to what it actually spent. Without this the cost
/// of the next metric added to either list would show up only as a slower CI
/// job, which is exactly the kind of drift a comment cannot catch.
fn reportSectionCost(comptime label: []const u8, t0: i128, metrics: usize) void {
    std.debug.print("  [{s}] section cost: {d:.2} s for {d} metric(s), measured around it\n", .{ label, elapsedMs(t0) / 1000.0, metrics });
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
fn benchCircuitBreaker(allocator: std.mem.Allocator, calls: usize, counted: ?*usize) !f64 {
    const cb = try allocator.create(zigmodu.CircuitBreaker);
    defer allocator.destroy(cb);
    cb.* = try zigmodu.CircuitBreaker.init(allocator, "bench", .{ .failure_threshold = 100, .success_threshold = 2, .timeout_seconds = 30, .half_open_max_calls = 10 });
    defer cb.deinit();

    const op = struct {
        fn op() anyerror!void {}
    }.op;

    var accepted: usize = 0;
    // `counted` is the [alloc] pass's counter slot: when non-null, `c.*` holds
    // the probe's running total after fixture on entry and is replaced with the
    // timed loop's allocation delta on return (`allocCircuitBreaker`). Timed
    // callers pass null. The branch is outside the loop, and there is exactly
    // one textual copy of this loop in the binary on purpose: a second copy —
    // even of a noinline-wrapped call, measured 2026-09-22 — costs the judged
    // loop ~4x by changing how LLVM specializes `CircuitBreaker.call`.
    const counted_before: usize = if (counted) |c| c.* else 0;
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
    if (counted) |c| c.* = c.* - counted_before;

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
// Latency distribution — p50 / p95 / p99 / p99.9 (ns per operation)
//
// `median3` answers "what does a normal turn cost", which is the right input for
// a regression gate and the wrong shape for a claim about a *high-performance
// runtime*: a tail is where a runtime's latency stories actually live (a
// scheduler wake-up, a cold mailbox slot, a thread creation that reaches the
// allocator), and a median cannot see one at all. This section measures the
// distribution on the same harnesses, in the same run, and prints it next to the
// median. Three rules define it:
//
//   * **Many batches, not three runs.** Each metric is measured as
//     `pct_batches` consecutive batches of `total_ops / pct_batches` operations
//     — the same harness function `median3` calls three times, called once per
//     batch instead. Every harness starts its own clock *after* building its
//     fixture, so each sample is that harness's own measurement of one batch and
//     per-call fixture stays out of it. Timing individual operations is not an
//     option at this resolution: a `Sequencer` turn is ~2 ns and one clock read
//     is ~25 ns, so per-operation timing would measure the clock. A batch is
//     therefore the sampling unit, which makes the reported tail the tail of
//     *batch* latency — a stall shorter than one batch is invisible, and the
//     printed `ops` per batch is the resolution that says how fine one is.
//   * **The collection allocates nothing.** The sample buffer is one preallocated
//     slice, and the allocator behind it is armed to refuse every request for the
//     rest of the section. The loop body reads the clock and writes one `f64` into
//     that slice and nothing else, so a sampler that grew an allocation (a growing
//     list of samples, a formatted log line) fails the run instead of quietly
//     timing its own bookkeeping. Requirements of the measured path itself are
//     each harness's business and are asserted there: `harness_allocator` is the
//     same reclaiming allocator the median runs use, and the two harnesses whose
//     stop path must not allocate already carry their own `WorkerAllocProbe`.
//   * **Reported, never gated.** The percentiles are printed; nothing else reads
//     them. `scripts/check-bench.sh` judges `bench-results.json`, which this
//     section does not write to, and no baseline file holds a percentile. The
//     cross-host spread of a tail is not known yet, and this repo has already
//     paid three times for gating a fresh number against one host's recording
//     (`RingBuffer SPSC x1M` alone moves 2.15x on the host's memory-ordering
//     implementation — see `scripts/check-bench.sh`). Collect a few rounds of
//     observations first; promote one to a criterion only with the spread in hand.
//
// Cost: every metric here is measured with the same total work as one `median3`
// sample of it, so the section adds one extra pass over the metrics it covers —
// measured and printed by `reportSectionCost` at the end of it (~0.2 s at today's
// scales) — while the gate's other 16 metrics are not touched at all. `TimerWheel
// x100K` is the one metric of the runtime group deliberately not covered, and for
// a measured reason rather than a cost one; see the section's call site.
//
// `LatencyInjector` exists so that "the samples are real" is demonstrable rather
// than asserted; it is off unless the environment asks for it.
// ─────────────────────────────────────────────────

/// Batches per metric. 1000 samples is what makes p99.9 an order statistic
/// rather than the maximum of a handful — nearest-rank p99.9 over 1000 samples is
/// the 999th — and it is also the knob that bounds the section's cost (see the
/// banner): the total op count per metric is fixed, so more batches means shorter
/// batches, not more work.
const pct_batches: usize = 1000;

/// The query points, nearest-rank: sample `ceil(p * n)`, 1-based, clamped. For
/// `n = 1000` that is the 500th, 950th, 990th and 999th of the sorted samples.
const pct_points = [_]struct { label: []const u8, p: f64 }{
    .{ .label = "p50", .p = 0.50 },
    .{ .label = "p95", .p = 0.95 },
    .{ .label = "p99", .p = 0.99 },
    .{ .label = "p99.9", .p = 0.999 },
};

/// Nearest-rank quantile of an ascending slice: `ceil(p * n)`, 1-based, clamped
/// into `[1, n]`. The convention is stated here rather than left to the reader
/// because the upper quantiles are the point of this section, and "p99.9 of 1000
/// samples" is only meaningful next to the rule that produced it.
fn nearestRank(sorted: []const f64, p: f64) f64 {
    const n: f64 = @floatFromInt(sorted.len);
    const rank = std.math.clamp(@ceil(p * n), 1, n);
    return sorted[@as(usize, @intFromFloat(rank)) - 1];
}

/// Stall injection: the counter-proof that this section samples real per-batch
/// times instead of deriving a distribution from the median.
///
/// With `ZIGMODU_BENCH_INJECT_NS` set, every `ZIGMODU_BENCH_INJECT_EVERY`-th
/// batch (40th by default — 25 of the 1000 samples) pays an extra busy-spin of
/// that many nanoseconds, timed with the same clock and added to that batch's
/// sample. The cadence is the point: 25 stalled samples are 2.5% of the
/// distribution and they are its slowest members, so they occupy the top of the
/// sorted array — above p95 (the 5% boundary) and past p99 (the 1% boundary).
/// p50 must therefore not move at all, and p99/p99.9 must move by roughly the
/// injected width (exactly that width plus the stalled batch's own cost, which is
/// why the moved value lands at a predictable place and not merely "higher"). A
/// sampler that reprinted the median three times, or whose quantiles came from
/// anywhere but its own 1000 samples, cannot produce that shape. p95 is the one
/// boundary that can shift a notch: it sits 2.5 points — 25 samples — away from
/// the stalled mass, so its rank moves with it, visibly so on a heavy tail like
/// `App lifecycle`. `every` between 21 and 99 keeps the property (1-5% stalled).
///
/// A spin rather than a sleep: a sleep's overshoot is the host's scheduler, so the
/// injected width would not be reproducible, and the thing being modelled is
/// elapsed time inside the measured loop. The spin is measured, not assumed — the
/// value added to the sample is the width the clock actually observed.
///
/// Injection is off unless the variable is set, and the section prints the fact
/// when it is on: a percentile table produced with injection running is
/// counter-proof output, not a measurement of the framework.
const LatencyInjector = struct {
    stall_ns: i128 = 0,
    every: usize = 40,

    /// Reads the knobs from main's environment map. A value that does not parse is
    /// an error rather than a silent fallback to "off": a typo in the variable
    /// would otherwise look exactly like a sampler that cannot see a stall.
    fn fromEnv(environ: anytype) !LatencyInjector {
        var injector = LatencyInjector{};
        if (environ.get("ZIGMODU_BENCH_INJECT_NS")) |raw| {
            injector.stall_ns = std.fmt.parseInt(i128, raw, 10) catch return error.BenchInvalidInjectNs;
            if (injector.stall_ns < 0) return error.BenchInvalidInjectNs;
        }
        if (environ.get("ZIGMODU_BENCH_INJECT_EVERY")) |raw| {
            injector.every = std.fmt.parseInt(usize, raw, 10) catch return error.BenchInvalidInjectEvery;
        }
        return injector;
    }

    fn active(self: LatencyInjector) bool {
        return self.stall_ns > 0 and self.every > 0;
    }

    /// Elapsed nanoseconds this batch paid for its stall, 0 for an unstalled one.
    fn paid(self: LatencyInjector, index: usize) i128 {
        if (!self.active()) return 0;
        if (index % self.every != self.every - 1) return 0;
        const t0 = now();
        while (now() - t0 < self.stall_ns) {}
        return now() - t0;
    }
};

/// Runs one metric in `pct_batches` batches and prints its percentile line: the
/// four quantiles in ns per operation, the batch shape they came from, and the
/// cross-check that batching did not move the metric — the metric's own sum over
/// its batches against the `[med3]` value the gate judges it by, for the same
/// total work, in the same run.
const LatencyRun = struct {
    allocator: std.mem.Allocator,
    injector: LatencyInjector,
    medians: *const std.ArrayList(BenchResult),

    fn medianMs(self: LatencyRun, name: []const u8) ?f64 {
        for (self.medians.items) |result| {
            if (std.mem.eql(u8, result.name, name)) return result.value;
        }
        return null;
    }

    fn run(self: LatencyRun, comptime name: []const u8, comptime f: anytype, args: anytype, total_ops: usize) !void {
        if (total_ops < pct_batches) return error.BenchPercentileTooFewOps;
        const ops = total_ops / pct_batches;

        var probe = WorkerAllocProbe.init(self.allocator, .{});
        const samples = try probe.allocator().alloc(f64, pct_batches);
        defer probe.allocator().free(samples);
        // Armed from here on: nothing in the sampling loop may allocate.
        probe.fail_index = probe.alloc_index;

        var sum_ms: f64 = 0;
        var stalled: usize = 0;
        for (samples, 0..) |*sample, index| {
            const stall_ns = self.injector.paid(index);
            if (stall_ns > 0) stalled += 1;
            const ms = try @call(.auto, f, args ++ .{ops});
            sum_ms += ms;
            sample.* = (ms * 1_000_000.0 + @as(f64, @floatFromInt(stall_ns))) / @as(f64, @floatFromInt(ops));
        }
        std.mem.sort(f64, samples, {}, std.sort.asc(f64));

        // A percentile line without a median to sit next to would be a number
        // nobody can place; the names come from the same table, so a missing one
        // means the two views of the suite have drifted apart.
        const med3_ms = self.medianMs(name) orelse return error.BenchPercentileUnpaired;

        std.debug.print("  [pct] {s}:", .{name});
        inline for (pct_points) |point| {
            std.debug.print(" {s} {d:.2}", .{ point.label, nearestRank(samples, point.p) });
        }
        const drift = sum_ms / med3_ms;
        std.debug.print(" ns/op  [{d} batches x {d} ops; sum {d:.2} ms = {d:.2}x med3 {d:.2} ms", .{ pct_batches, ops, sum_ms, drift, med3_ms });
        if (stalled > 0) std.debug.print("; stalled {d}", .{stalled});
        std.debug.print("]", .{});
        // Outside this band the two numbers are not the same measurement of the
        // same thing, and the line says so instead of letting a reader compare
        // them as if they were. The known cause is the host: load can move between
        // the `[med3]` phase of the run and this one at the end of it (measured at
        // 1.37-1.57x on `HotBus 8sub x1M` and `Mailbox full-path x10M` while a
        // compile ran on this machine). A *measured* second cause — a batch whose
        // shape differs from the judged sample's by construction — is why
        // `TimerWheel x100K` is not in this list at all (see the section banner),
        // so with the two views of the suite in their current state a breach here
        // is host load or a harness that grew a per-call fixture; either way the
        // quantiles describe what the sampler saw, and what is in question is only
        // whether that is the workload `check-bench.sh` thresholds.
        if (drift < 0.8 or drift > 1.25) {
            std.debug.print("\n        ^ its batches summed to {d:.2}x the `[med3]` sample it is compared against — the two are\n          not the same measurement (host load that moved between the `[med3]` phase and this one, or\n          a batch shape that is not the judged one). Read ns/op as the sampled shape's own.", .{drift});
        }
        std.debug.print("\n", .{});
    }
};

// ─────────────────────────────────────────────────
// Runtime primitives (`src/runtime/**`) — the framework's worker plumbing
//
// Deliberately deterministic: no sockets, no wall-clock deadlines, and a
// `Manual` clock wherever anything schedules. Every harness heap-allocates the
// structure it drives and feeds each result through `std.mem.doNotOptimizeAway`,
// so LLVM cannot conclude the address never escapes and delete the loop it is
// supposed to be timing. The `CircuitBreaker x*` metrics above used to be the
// counter-example — no heap, no barrier, and a printed 0.00 ms that was a
// folded-away loop rather than a fast one; see `benchCircuitBreaker` for what
// changed.
//
// The one exception to "no threads" is `Worker spawn+join`, and it is the point
// of that metric: a worker's lifecycle *is* thread creation, so that harness
// creates real threads on a real started runtime and is orders of magnitude
// slower than the lock-free primitives around it. Everything else in this group
// runs on the calling thread only, which is what keeps it in the
// nanoseconds-per-operation band and repeatable on a loaded host.
// ─────────────────────────────────────────────────

const rt = zigmodu.runtime;

/// The host's atomic-path speed, measured on the same run as everything else —
/// the reference `scripts/check-bench.sh` divides the atomic-path metrics by.
///
/// Why a reference metric at all: the gate used to hold every metric to an
/// absolute millisecond value, so it also held the *host* still. CI runners are
/// provisioned per Azure region from a rolling hardware generation, and a
/// generation that makes a single-core atomic read-modify-write 2.6-4.6x more
/// expensive turns `Sequencer x10M`, the two `Mailbox` metrics, `HotBus 8sub`
/// and `1L x10M events` red on code whose instructions are byte-identical to the
/// commit that recorded the baseline (verified at the machine-code level: the
/// timed loop of `benchEventBus` is 2683 instructions, all identical between the
/// two binaries). What moved is the host, not the framework, and no recorded
/// millisecond value can tell those apart. A ratio against a metric that runs on
/// the same host at the same moment can.
///
/// The loop is deliberately nothing but the atomic: a monotonic `fetchAdd` on
/// one counter held on the heap, with each old value fed to
/// `doNotOptimizeAway`. No branch that could be predicted differently on another
/// microarchitecture, no memory beyond the one cache line, no second counter —
/// what this measures is the machine's baseline cost of the operation the
/// normalized metrics are made of, and nothing else. Counters in the suite
/// usually sit next to more work; this one is the control.
///
/// It is a metric because it has to be measured (and so recorded, printed and
/// gated like the rest), but it is not a framework metric: a regression in
/// `src/runtime/**` cannot move it, only the host can. `check-bench.sh` prints it
/// separately for that reason.
fn benchAtomicRmw(allocator: std.mem.Allocator, count: usize) !f64 {
    const counter = try allocator.create(std.atomic.Value(u64));
    defer allocator.destroy(counter);
    counter.* = std.atomic.Value(u64).init(0);

    const t0 = now();
    for (0..count) |_| {
        std.mem.doNotOptimizeAway(counter.fetchAdd(1, .monotonic));
    }
    return elapsedMs(t0);
}

/// The host's store→load forwarding cost, measured on the same run as everything
/// else — the *candidate* denominator for `RingBuffer SPSC x1M`, recorded and
/// printed like the reference above but not wired to anything yet.
///
/// `atomic RMW x10M` is the right denominator for the five metrics whose turn is
/// a read-modify-write, and the ring is not one of them: `tryPush` stores `tail`
/// and `tryPop` loads that index straight back, and the same for `head`, so its
/// turn is a store-to-load forwarding chain plus the host's lowering of the
/// release/acquire pair (plain `mov`s on x86_64, `stlr`/`ldar` on aarch64). The
/// two host properties correlate, but they are not the same quantity, and the
/// residual shows up across generations: the Xeon 8370C run that reddened
/// `624b423` put the ring's ratio at 0.0386 against 0.0523-0.0527 on the EPYC
/// runners (26% apart) while the same run's `atomic RMW` was 2.6-2.9x its EPYC
/// value. `scripts/check-bench.sh` records that imperfection next to the metric.
///
/// So this harness is the ring's turn with the ring taken out: two release stores
/// and two acquire loads per round, both counters in the same cache line, each
/// load reading what the store in front of it just wrote. No index arithmetic, no
/// mask, no fullness branch, no slot array, no second thread. What is left is the
/// forwarding chain and the orderings — which is most of what the ring's number is
/// on a host where the ring's own code is not the cost: the identical loop is
/// 10.7 ms per 1M round trips on an aarch64 laptop against 1.24 ms on an EPYC
/// runner, an 8.6x gap in code that did not change (see the header of
/// `scripts/check-bench.sh`).
///
/// A machine reference like `benchAtomicRmw`, not a framework metric: a
/// regression in `src/runtime/**` cannot move it, only the host can — which is
/// also why `check-bench.sh` reports it instead of gating it on an absolute
/// value, exactly as it treats the reference the atomic-path metrics divide by.
/// It is deliberately **not** in that script's normalized list: whether the ring
/// should be gated against this instead of against the atomic is a question about
/// how the two candidates behave across host generations, and one host cannot
/// answer it. The local run-to-run spreads of both ratios, and what is still
/// missing to decide, are recorded in that script's header next to the list.
fn benchStoreForward(allocator: std.mem.Allocator, count: usize) !f64 {
    // `a` is cache-line aligned and `b` sits 8 bytes behind it, so both counters
    // share one line. The ring's own two indices are separated on purpose (one
    // core writing each); this harness measures a single core's chain, where a
    // second line would add a miss the ring does not pay.
    const Cells = struct {
        a: std.atomic.Value(u64) align(std.atomic.cache_line),
        b: std.atomic.Value(u64),
    };
    const cells = try allocator.create(Cells);
    defer allocator.destroy(cells);
    cells.* = .{
        .a = std.atomic.Value(u64).init(0),
        .b = std.atomic.Value(u64).init(0),
    };

    var x: u64 = 0;
    const t0 = now();
    for (0..count) |_| {
        cells.a.store(x +% 1, .release); // producer writes `tail`
        x = cells.a.load(.acquire); // consumer reads it back: the forward
        cells.b.store(x +% 1, .release); // consumer writes `head`
        x = cells.b.load(.acquire); // producer reads it back: the forward
        std.mem.doNotOptimizeAway(x);
    }
    const ms = elapsedMs(t0);

    // Two increments per round, so a loop the optimizer folded away fails here
    // instead of recording a fast number (`benchMailboxFull` makes the same point).
    if (x != 2 *% @as(u64, @intCast(count))) return error.BenchStoreForwardFolded;
    return ms;
}

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

/// Producer count for the multi-producer push metric: enough cursors to be
/// "many" (the scheduler's ready ring and the timer command queue are both
/// many-producer structures), small enough that the round-robin bookkeeping
/// stays below the noise floor.
const bench_mpsc_producers = 4;

/// MPSC push on the raw Vyukov ring: `count` pushes from
/// `bench_mpsc_producers` interleaved producer cursors into one shared
/// `MpscRing`, drained inline as it fills — the same post+drain shape as
/// `benchMailbox`, one structural level down.
///
/// Why not real producer threads: this suite's position on thread-parallel
/// numbers is measured, not stylistic — the hand-off pair below swings
/// 1.84x/3.09x run-to-run within one machine, and the pool sweep is
/// observation-only for exactly that reason (see `scripts/check-bench.sh`'s
/// header: a 2.0x window on a number that swings 3x within one machine is a
/// false-red machine). The gated shape is the contention-free one: same ring
/// code, same slot-sequence protocol, four producer cursors taking turns.
/// What it gives up — cross-core CAS retries — is the part a 2.0x window
/// cannot hold anyway; the pool sweep is where the contended shape is read.
///
/// What it covers that `Mailbox post+drain x1M` does not: the raw ring path
/// the scheduler's ready ring and the runtime's timer command queue actually
/// run — no close-flag check, no sent/received stats, no error mapping. The
/// per-producer order assertion is the MPSC contract from `ring.zig`'s own
/// multi-producer test: each cursor's messages must come out in the order
/// that cursor pushed them.
fn benchMpscRingPush(count: usize) !f64 {
    const R = rt.MpscRing(u64, 1024);
    const ring = try harness_allocator.create(R);
    defer harness_allocator.destroy(ring);
    ring.* = R.init();

    // The pushed value is the global sequence number; producer and per-producer
    // sequence are its residue and quotient mod `bench_mpsc_producers`.
    var expected: [bench_mpsc_producers]u64 = @splat(0);
    var pushed: usize = 0;
    const t0 = now();
    while (pushed < count) {
        while (pushed < count) {
            if (!ring.tryPush(@intCast(pushed))) break; // full: drain below, then resume
            pushed += 1;
        }
        while (ring.tryPop()) |v| {
            if (expected[v % bench_mpsc_producers] != v / bench_mpsc_producers) return error.BenchMpscReordered;
            expected[v % bench_mpsc_producers] = v / bench_mpsc_producers + 1;
            std.mem.doNotOptimizeAway(v);
        }
    }
    const ms = elapsedMs(t0);

    if (pushed != count) return error.BenchMpscLostPushes;
    if (!ring.isEmpty()) return error.BenchMpscLeftovers;
    return ms;
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

/// Backpressure reject path: `count` posts into a mailbox that is already full,
/// every one of which must come back `error.Full`.
///
/// Filling the mailbox is fixture, not measurement. The timed loop takes the
/// branch a production producer takes once its consumer stops keeping up:
/// `tryPush` fails, the ring's and the mailbox's drop counters bump, the error
/// returns. Nothing on that path can allocate — `send` does not even take an
/// allocator, the queue storage is inside the mailbox — and nothing blocks, so
/// this is the per-message price of refusing work. It is measured at 10x the
/// scale of the accepted path above for that reason: a reject is an order of
/// magnitude cheaper than a hand-off, so 1M of them is a 2 ms sample — above the
/// 2 ms floor but under the 5 ms this suite sizes a new metric at (see
/// `scripts/check-bench.sh`), where the 2.0x window is narrower than the wobble
/// it is meant to see past. 10M puts it at ~21 ms.
///
/// The mailbox is the only thing here that needs memory, and it is built through
/// a `FailingAllocator` that is armed to refuse the next request before the timed
/// loop starts: the "no allocation on the reject path" guarantee is structural
/// (`send` has no allocator to allocate with), and this is what makes it an
/// executed tripwire too — a reject path that grew a retry queue, a heap-backed
/// error log or a metrics buffer would fail this harness rather than merely
/// measure slower. The counter delta is checked afterwards for the same reason,
/// so a loop the optimizer folded away fails the run instead of recording a fast
/// number.
fn benchMailboxFull(io: std.Io, count: usize) !f64 {
    const M = rt.Mailbox(u64, 256);
    var probe = WorkerAllocProbe.init(harness_allocator, .{});
    const mailbox = try probe.allocator().create(M);
    defer probe.allocator().destroy(mailbox);
    mailbox.* = M.init(io);

    var posted: usize = 0;
    while (mailbox.send(posted)) |_| {
        posted += 1;
    } else |err| switch (err) {
        error.Full => {}, // the queue is full: the loop below measures this path
        else => return err,
    }
    if (posted != mailbox.maxMessages()) return error.BenchMailboxNotFull;
    const dropped_before = mailbox.stats().dropped_full;

    // Armed from here on: the next allocation through this allocator fails.
    probe.fail_index = probe.alloc_index;
    const t0 = now();
    for (0..count) |_| {
        mailbox.send(0) catch |err| switch (err) {
            error.Full => continue,
            else => return err, // Closed/Timeout is a different path, not this metric
        };
        return error.BenchMailboxAcceptedWhenFull;
    }
    const ms = elapsedMs(t0);
    probe.fail_index = std.math.maxInt(usize);

    if (mailbox.stats().dropped_full - dropped_before != count) return error.BenchMailboxRejectsNotCounted;
    return ms;
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

/// How many timers the churn metric keeps live, and how many times it arms and
/// fires them. 100x10000 = 1M schedule+fire cycles, which is what puts it above
/// the ~5 ms floor at both the fixed and the unfixed cost (measured: ~28 ms fixed,
/// ~265 ms before the fix — see `benchTimerWheelChurn`).
const timer_churn_live = 100;
const timer_churn_rounds = 10_000;

/// The **production shape**: *one* wheel, alive for the whole run, taking the
/// traffic a long-lived ticker actually sees — a modest live set, fresh ids every
/// time, fire and re-arm forever.
///
/// This is a different question from `benchTimerWheel` above, and the difference
/// is not academic. That harness builds a wheel, arms it and drops it: every
/// insert goes into a map that has never held anything, so it measures the
/// *cheapest* state a `Wheel` is ever in. The runtime's wheel is the other shape
/// — `src/runtime/runtime.zig` holds one for the process's lifetime and the
/// ticker drives it forever — and a wheel that has been churning for a while is
/// in a state a fresh wheel never reaches. Measured on this host, same loop, same
/// op count: **a wheel reused for the run cost 234-245 ns per `schedule` against
/// 28.3 ns for one rebuilt every round** (8.3x), a number no other metric in this
/// suite could have shown. The cause was the `nodes` map's tombstone probe
/// behaviour, not the wheel's own code; `timer_wheel.zig`'s `nodes` field and the
/// `a long-lived wheel's lookups do not get slower as it ages` test in that file
/// carry the mechanism.
///
/// So this row is the one that fails if the wheel ever goes back to a structure
/// whose per-op cost depends on how long it has been alive. It is deliberately
/// shaped like the runtime's use and not like a worst case: 100 timers live, one
/// `advance` per round that takes them all out, ids from a counter that never
/// repeats, deadlined over half a level-0 rotation so `advance` walks slots one
/// by one (`timer_span_ms`) instead of taking the long-stall rescan. Cost is
/// ~28 ms per sample after the fix, 3 samples per run.
fn benchTimerWheelChurn(allocator: std.mem.Allocator, rounds: usize) !f64 {
    var wheel = rt.Wheel(u64).init(allocator, 0);
    defer wheel.deinit();
    var fired = TimerFireCounter{};
    const slots_used = timer_span_ms / rt.timer_wheel.slot_ms;

    var now_ms: i64 = 0;
    var id: u64 = 1;
    const t0 = now();
    for (0..rounds) |_| {
        for (0..timer_churn_live) |k| {
            const tick: i64 = @intCast(k % @as(usize, @intCast(slots_used)));
            try wheel.scheduleWithId(id, now_ms + (tick + 1) * rt.timer_wheel.slot_ms, @intCast(k));
            id += 1;
        }
        _ = wheel.advance(now_ms + timer_span_ms, &fired, TimerFireCounter.onFire);
        now_ms += timer_span_ms;
    }
    const ms = elapsedMs(t0);

    // Armed and fired as well as timed: every id is distinct and every round's
    // `advance` has to take its 100 back out, so a harness that stopped inserting
    // (or one whose ids collided) fails here instead of recording a fast number.
    if (wheel.pendingCount() != 0) return error.BenchTimerWheelLeaked;
    if (fired.fired != @as(u64, rounds) * timer_churn_live) return error.BenchTimerWheelLostTimers;
    return ms;
}

/// The `after()` scheduling path end to end: `count` `Handle.after` calls on a
/// worker whose runtime is driven by hand. Every arm allocates its `Delivery`
/// payload and pushes a command onto the runtime's bounded timer-command ring
/// on the caller's thread; the periodic `tick()` is the owner half of the same
/// path — it drains that ring and inserts each command into the wheel. Both
/// halves are the metric: `TimerWheel x100K` above measures the wheel insert
/// alone, and gating only the caller half would leave the rest of the path
/// unjudged.
///
/// The runtime is deliberately *not* started: on a `Manual` clock the harness
/// thread is the wheel's owner (`tick()` claims ownership, and a running
/// ticker has already claimed it — mixing the two is a bug the wheel reports,
/// see `Runtime.tick`), which keeps the run deterministic and off the wall
/// clock. The command ring is `timer_command_capacity` deep and is drained
/// whenever the arm loop fills it, so `error.Full` is the backpressure answer,
/// never an overflow.
///
/// Assertions: the clock is parked below every deadline, so nothing may fire
/// during the run. After a final drain outside the timed region,
/// `wheel.pendingCount()` must equal `count` — every arm reached the wheel —
/// and `Runtime.shutdown()` must then discard exactly `count` timers with zero
/// deliveries dropped (the payload-release path; nothing fired, so nothing was
/// delivered). The mailbox overflow question never arises because nothing is
/// ever delivered into it.
fn benchTimerAfter(io: std.Io, count: usize) !f64 {
    var clk = rt.Clock.Manual{ .now_ms = 0 };
    var rtx = rt.Runtime.init(harness_allocator, io, .{ .manual = &clk });
    defer rtx.deinit();
    const handle = try rtx.spawn(BenchNoopWorker, .{}, bench_worker_mailbox_capacity);

    const tick_count = timer_span_ms / rt.timer_wheel.slot_ms;
    var armed: usize = 0;
    const t0 = now();
    while (armed < count) {
        while (armed < count) {
            const tick: i64 = @intCast(armed % @as(usize, @intCast(tick_count)));
            _ = handle.after((tick + 1) * rt.timer_wheel.slot_ms, @intCast(armed)) catch |err| switch (err) {
                error.Full => break, // command ring full: drain below, then resume
                else => return err,
            };
            armed += 1;
        }
        _ = rtx.tick(); // the owner half: command ring -> wheel
    }
    const ms = elapsedMs(t0);

    // Flush whatever the arm loop left in the command ring — fixture for the
    // assertion, not part of the timed region.
    _ = rtx.tick();
    if (rtx.wheel.pendingCount() != count) return error.BenchTimerAfterLostTimers;

    rtx.shutdown();
    const s = rtx.stats();
    if (s.timers_discarded != count) return error.BenchTimerAfterLeakedTimers;
    if (s.timer_deliveries_dropped != 0) return error.BenchTimerAfterDroppedDelivery;
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

/// Mailbox capacity for the lifecycle harness. Small on purpose: `MpscRing.init`
/// seeds every slot at comptime and this harness pays for one mailbox per turn.
const bench_worker_mailbox_capacity = 8;

/// The allocator both allocation-sensitive runtime harnesses run through, with a
/// tripwire on it: every allocation and resize routed through it is counted, and
/// `fail_index` can be moved to the current count so the next allocation fails
/// outright.
///
/// `spawn` is the one timed loop in this file that *must* allocate — a heap
/// handle, an entry in the runtime's worker list, a thread — so "no allocation
/// on the hot path" cannot mean "no allocation in the loop" here. What it does
/// mean is that the *graceful stop* half allocates nothing, and this probe is how
/// that is asserted instead of assumed: a `stop`/`join` that allocated anything
/// (a fresh handle, a re-registration, a logged error built on the heap) fails the
/// run rather than quietly inflating the number. `std.testing.FailingAllocator`
/// rather than a local vtable — it already counts allocations, exposes the
/// counters, and can be armed mid-run; the framework uses it the same way
/// elsewhere (`src/core/ModuleRegistry.zig`).
const WorkerAllocProbe = std.testing.FailingAllocator;

/// A worker with nothing to do: it declares a message type and an `init` hook so
/// a lifecycle turn covers the whole contract (thread, mailbox, hook, receive
/// loop), and so the cost it reports is the plumbing rather than a handler.
const BenchNoopWorker = struct {
    pub const Message = u64;
    seen: u64 = 0,

    pub fn init(self: *@This(), ctx: anytype) anyerror!void {
        _ = ctx;
        self.seen = 0;
    }

    pub fn handle(self: *@This(), msg: u64, ctx: anytype) anyerror!void {
        _ = ctx;
        self.seen +%= msg;
    }
};

/// Worker lifecycle: `count` spawn → `stop` → `join` turns on one started
/// runtime, then a runtime shutdown that must report nothing left alive.
///
/// A turn is the whole graceful cycle, not just the start: the thread is created,
/// the handle and its mailbox come off the heap, the optional `init` hook runs,
/// `stop()` closes the mailbox and sets the stop flag, the worker leaves its
/// receive loop and runs its optional `deinit`, and `join()` reaps the thread.
/// The probe is armed across the stop half (see `WorkerAllocProbe`); the start
/// half is expected to allocate and does.
///
/// The runtime is started on a `Manual` clock, so the ticker thread runs as it
/// would in production without anything actually reading the wall clock, and the
/// handles are deliberately left registered as the loop goes: by the end the
/// worker list holds all `count` of them, which is what makes the closing
/// `shutdown()` a real check that the runtime reclaims every one of them
/// (`workers` and `running` back to 0, the acceptance line this metric exists
/// for) rather than a formality over an empty list.
fn benchWorkerSpawnJoin(io: std.Io, count: usize) !f64 {
    var clk = rt.Clock.Manual{ .now_ms = 0 };
    var probe = WorkerAllocProbe.init(harness_allocator, .{});
    var rtx = rt.Runtime.init(probe.allocator(), io, .{ .manual = &clk });
    defer rtx.deinit();
    try rtx.start();

    const t0 = now();
    for (0..count) |_| {
        const handle = try rtx.spawn(BenchNoopWorker, .{}, bench_worker_mailbox_capacity);
        // The start half just allocated, as it must. From here to the end of the
        // turn: any allocation through the runtime's allocator fails, and the
        // counters are compared as well, so an allocation added to the stop path
        // — including a `resize`/`remap` growth that `fail_index` does not cover —
        // fails the run instead of hiding as a slightly slower sample.
        probe.fail_index = probe.alloc_index;
        const allocations_before = probe.alloc_index + probe.resize_index;
        handle.stop();
        handle.join();
        probe.fail_index = std.math.maxInt(usize);
        if (probe.alloc_index + probe.resize_index != allocations_before) return error.BenchStopPathAllocated;
        std.mem.doNotOptimizeAway(handle.state.seen);
    }
    const ms = elapsedMs(t0);

    rtx.shutdown();
    const s = rtx.stats();
    if (s.workers != 0 or s.running != 0) return error.BenchRuntimeLeakedWorkers;
    return ms;
}

/// The worker the two hand-off metrics below drive: it counts what it received
/// and does nothing else, so the producer's loop and the hand-off are the whole
/// cost. `acc` is touched only by the worker's own thread (the `[med3]` driver
/// reads it after `join`), and `seen` is the atomic the producer waits on.
const BenchDrainWorker = struct {
    pub const Message = u64;
    seen: *std.atomic.Value(u64),
    acc: u64 = 0,

    pub fn handle(self: *@This(), msg: u64, _: anytype) !void {
        self.acc +%= msg;
        std.mem.doNotOptimizeAway(self.acc);
        _ = self.seen.fetchAdd(1, .monotonic);
    }
};

/// Mailbox capacity for the hand-off metrics: the same 256 the mailbox group
/// uses, so `Mailbox post+drain x1M` (no thread), `Worker drain dedicated x1M`
/// and `Pooled dispatch x1M` sit on one axis and differ only in who drains.
const bench_drain_capacity = 256;

/// Bound on the wait for the tail, in spin rounds. A lost message must *fail*
/// the metric, not hang the suite.
const bench_drain_timeout_spins = 4_000_000_000;

/// `count` messages handed to a worker and drained by it, on whichever execution
/// resource `mode` names.
///
/// This is the pair the scheduler needed and never had. The runtime's execution
/// modes were documented as a trade — "a dedicated worker costs a thread, a
/// pooled one costs a ready-ring round trip, so keep the critical path
/// dedicated" (`docs/RUNTIME.md` §12.5) — with nothing measuring either side.
/// Same producer loop, same worker, same mailbox capacity; the only difference is
/// whether the drain happens on the worker's own parked thread or on a pool
/// thread that had to claim it first.
fn benchWorkerDrain(comptime mode: rt.SpawnMode, io: std.Io, count: usize) !f64 {
    var seen = std.atomic.Value(u64).init(0);
    // The pool is declared either way: it materialises no thread until the first
    // `.pooled` spawn, so the dedicated run pays nothing for it and the two runs
    // differ in exactly one thing.
    var rtx = try rt.Runtime.initWithOptions(harness_allocator, io, .{
        .scheduler = .{ .max_pooled_workers = 1, .pool_threads = 1 },
    });
    defer rtx.deinit();
    try rtx.start();

    const handle = if (comptime mode == .pooled)
        try rtx.spawn(BenchDrainWorker, .{ .seen = &seen }, .{ .capacity = bench_drain_capacity, .mode = .pooled })
    else
        try rtx.spawn(BenchDrainWorker, .{ .seen = &seen }, bench_drain_capacity);

    const t0 = now();
    var sent: usize = 0;
    while (sent < count) {
        handle.send(sent) catch |err| switch (err) {
            // The consumer is behind: this is the backpressure path the mailbox
            // group measures on its own, and here it is just how a producer waits.
            error.Full => {
                std.atomic.spinLoopHint();
                continue;
            },
            error.Closed => return error.BenchDrainWorkerClosed,
            // `send` does not wait, so this cannot come from it; the error set is
            // the shared `SendError`, so it is named rather than papered over.
            error.Timeout => return error.BenchDrainUnexpectedTimeout,
        };
        sent += 1;
    }
    // Everything was accepted, so the wait for the tail is part of the hand-off.
    var spins: usize = 0;
    while (seen.load(.acquire) < count and spins < bench_drain_timeout_spins) : (spins += 1) std.atomic.spinLoopHint();
    const ms = elapsedMs(t0);
    if (seen.load(.acquire) != count) return error.BenchDrainLostMessages;

    // `stop()` before `join()`, and the first version of this harness hung here
    // without it: a dedicated worker's loop parks in `recv` until its mailbox is
    // closed, so `join` waits for a stop nobody asked for. (The pooled side is
    // released by the empty mailbox alone, which is exactly why the omission only
    // shows up on the dedicated metric — the first one, so the run produced no
    // output at all rather than a wrong number.)
    handle.stop();
    handle.join();
    // After `join` the worker's thread is done, so its `acc` is the whole picture:
    // a handler that saw every message exactly once. Counting receipts alone
    // would pass on a mailbox that duplicated a message and dropped another.
    if (handle.state.acc != count * (count - 1) / 2) return error.BenchDrainWrongSum;
    return ms;
}

fn benchWorkerDrainDedicated(io: std.Io, count: usize) !f64 {
    return benchWorkerDrain(.dedicated, io, count);
}

fn benchWorkerDrainPooled(io: std.Io, count: usize) !f64 {
    return benchWorkerDrain(.pooled, io, count);
}

/// Mailbox capacity for the sweep. Smaller than the hand-off pair's 256 on
/// purpose: with 100 workers a wide mailbox holds the whole working set and the
/// producer never sees backpressure, which is the state this is about.
const bench_sweep_capacity = 64;

/// Messages per point for the payload family. Fewer than the no-payload family
/// because each message costs ~400 ns of work: the same 500k would be 0.2 s of
/// CPU per sample, times four thread counts times three samples.
const bench_sweep_worked_messages = 200_000;

/// Dependent multiply steps per message in the payload family. Sized so one
/// message is a few hundred ns — far above mailbox and dispatch costs, which is
/// what makes the pool rather than the producer the limiter, and small enough
/// that 200k messages stay a fraction of a second per sample.
const sweep_work_iters: u32 = 256;

/// One family of the pool sweep, printed as a block. `work_iters` is comptime so
/// the two families are different worker types rather than a branch in the
/// handler — an `if (work == 0)` in the hot loop would measure the branch.
fn sweepFamily(
    comptime label: []const u8,
    comptime work_iters: u32,
    io: std.Io,
    grid: []const [2]usize,
    total: usize,
) void {
    std.debug.print("  -- {s} --\n", .{label});
    for (grid) |point| {
        const workers = point[0];
        const threads = point[1];
        var samples: [3]f64 = undefined;
        for (&samples) |*sample| {
            sample.* = benchPoolSweep(work_iters, io, workers, threads, total) catch |err| {
                std.debug.print("  workers={d:<4} pool_threads={d:<2} ERROR {s}\n", .{ workers, threads, @errorName(err) });
                return;
            };
        }
        std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
        const ms = samples[1];
        std.debug.print("  workers={d:<4} pool_threads={d:<2} {d:>7.1} ms  {d:>6.1} ns/msg  {d:>10.0} msg/s  [{d:.1} / {d:.1} / {d:.1}]\n", .{
            workers,
            threads,
            ms,
            ms * 1e6 / @as(f64, @floatFromInt(total)),
            @as(f64, @floatFromInt(total)) / ms * 1000.0,
            samples[0],
            samples[1],
            samples[2],
        });
    }
}

/// Messages per sweep point. 500k over 100 workers is 5k each — far above the
/// ~5 ms floor this suite judges at, and small enough that the whole grid of
/// medians-of-3 stays a few seconds on every push to main.
const bench_sweep_messages = 500_000;

/// A dependent multiply chain — the shape of "real work" in this suite. Each
/// step feeds the next, so it cannot be vectorized or pipelined and the loop's
/// cost is its own latency times `iters`. Nothing here is a framework cost; it is
/// the *payload* the two sweep families differ by.
fn workChain(comptime iters: u32, seed: u64) u64 {
    var x = seed;
    var i: u32 = 0;
    while (i < iters) : (i += 1) x = x *% 6364136223846793005 +% 1442695040888963407;
    return x;
}

/// The sweep's worker: like `BenchDrainWorker`, plus a **shared** total so the
/// producer can wait on one load instead of summing 100 counters per spin, and a
/// comptime `work_iters` so one harness covers both questions below.
fn SweepWorker(comptime work_iters: u32) type {
    return struct {
        pub const Message = u64;
        seen: *std.atomic.Value(u64),
        total: *std.atomic.Value(u64),
        acc: u64 = 0,

        pub fn handle(self: *@This(), msg: u64, _: anytype) !void {
            self.acc +%= msg +% workChain(work_iters, msg);
            std.mem.doNotOptimizeAway(self.acc);
            _ = self.seen.fetchAdd(1, .monotonic);
            _ = self.total.fetchAdd(1, .release);
        }
    };
}

/// `total` messages round-robined over `workers` pooled workers, drained by
/// `pool_threads` pool threads.
///
/// **The `pool_threads` dimension is the point of this harness.** With one
/// producer and N workers, more pool threads can only help if the *dispatch*
/// path is the bottleneck rather than the work — and because a batch is bounded,
/// one pool thread already holds several workers ready without draining any of
/// them. Whether a second thread buys anything is a question about this
/// scheduler, and it is not answerable by reading it.
///
/// The producer **skips a full mailbox instead of waiting on it**: a cursor
/// walks the workers and retries whichever refused. Waiting would serialize the
/// run on the slowest worker and measure backpressure instead of dispatch — the
/// `Mailbox full-path x10M` metric already answers that question.
fn benchPoolSweep(comptime work_iters: u32, io: std.Io, workers: usize, pool_threads: usize, total: usize) !f64 {
    const W = SweepWorker(work_iters);
    const H = rt.Handle(W, bench_sweep_capacity);
    const allocator = harness_allocator;

    const counters = try allocator.alloc(std.atomic.Value(u64), workers);
    defer allocator.free(counters);
    for (counters) |*c| c.* = std.atomic.Value(u64).init(0);
    var done = std.atomic.Value(u64).init(0);

    var rtx = try rt.Runtime.initWithOptions(allocator, io, .{
        .scheduler = .{ .max_pooled_workers = workers, .pool_threads = pool_threads },
    });
    defer rtx.deinit();
    try rtx.start();

    const handles = try allocator.alloc(*H, workers);
    defer allocator.free(handles);
    for (handles, 0..) |*h, i| {
        h.* = try rtx.spawn(W, .{ .seen = &counters[i], .total = &done }, .{
            .capacity = bench_sweep_capacity,
            .mode = .pooled,
        });
    }

    const t0 = now();
    var sent: usize = 0;
    var cursor: usize = 0;
    while (sent < total) {
        const h = handles[cursor % workers];
        cursor +%= 1;
        h.send(sent) catch |err| switch (err) {
            // Move on to the next worker rather than waiting on this one.
            error.Full => continue,
            error.Closed => return error.BenchSweepWorkerClosed,
            error.Timeout => return error.BenchSweepUnexpectedTimeout,
        };
        sent += 1;
    }

    // Every message was accepted; wait for the last one to be handled.
    var spins: usize = 0;
    while (done.load(.acquire) < total and spins < bench_drain_timeout_spins) : (spins += 1) std.atomic.spinLoopHint();
    const ms = elapsedMs(t0);
    if (done.load(.acquire) != total) return error.BenchSweepLostMessages;

    for (handles) |h| h.stop();
    for (handles) |h| h.join();
    return ms;
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

// ─────────────────────────────────────────────────
// Allocation counts per op — `[alloc]` (instrumented, separate pass, the second
// criterion)
//
// A latency table says how long a turn takes; it cannot say whether the turn
// *allocated*, and for the runtime group that is the number the framework actually
// makes a promise about: `send` copies into a fixed-capacity slot, `publish` fans
// out over frozen sinks, arming a timer pushes a command onto a fixed-capacity
// ring. This section prints that number — allocations per op — for **every gated
// metric**, in the same run and at the same scale as its `[med3]` line.
//
// The rows are a criterion, not just a readout. Since 2026-09-22 a baseline entry
// may declare `"max_alloc_per_op": <f>`, and `scripts/check-bench.sh` parses these
// lines from the measured run's own log and fails any budgeted metric that reads
// above its budget. A counted allocation is exact — no median, no host wobble —
// so an alloc breach is a regression the first time it fires, and the host-check
// narrative that applies to a millisecond breach does not apply to it. Budgets
// are recorded from a measured run plus headroom for fixed overheads (hash-map
// growth, one-time setup), are preserved verbatim by `--update`, and are optional:
// the CI baseline predates the field and simply carries no alloc criterion until
// it is re-recorded on a runner.
//
// It is a **separate instrumented pass**, and none of it is comparable with the
// other two sections:
//
//   * **A counting allocator is a change to the thing being measured**, which is
//     why this section exists at all instead of being folded into `[pct]`. Every
//     allocation in a counted path goes through a second vtable with a counter
//     write behind it, so a *duration* measured here would be measuring the
//     instrument. These runs therefore print no duration: a count, and the op
//     count it is divided by. Nothing from this pass is mixed into the latency
//     samples, and the timed harnesses above are untouched — each metric below
//     has its own copy of that harness's op loop, call for call and assertion
//     for assertion, and the counts come from the copy.
//   * **The counting allocator goes where the code under test holds one.** The
//     wheel (`schedule` allocates the node), the object pool, the SQLx client and
//     the worker runtime (`spawn` allocates the heap handle; the mailbox storage
//     is inline, sized at comptime) hold an allocator, so their counts are what
//     the timed region really allocates through it. For `RingBuffer`, `MpscRing`,
//     `Mailbox`, `HotBus.publish`, `Sequencer`, the two breakers, the rate
//     limiter and the atomic reference the operation takes no allocator at all:
//     there is no path to allocate from, and the zero is structural rather than
//     measured. Both readings — a counted `N.NN` and a structural `0.00` — are
//     the same numbers `src/runtime/alloc_contract_test.zig` asserts *exactly*,
//     with the same instrument, on the same operations; that test is where the
//     per-path enforcement lives (it arms the allocator so an added allocation
//     is an error, not a number), and this section is where every gated metric's
//     number sits next to the timing it belongs to.
//   * **Fixture is built before the snapshot**, never counted: the mailbox is
//     filled, the worker runtime is started, the wheel's map is left to grow as it
//     grows in the timed harness. Only the timed region's allocations are reported.
//   * **Printed in a fixed format on purpose.** Each row is
//     `  [alloc] <name>: <alloc/op> alloc/op  (<count> allocation(s) / <ops> ops)`,
//     and `check-bench.sh` matches it with a regex — metric names contain no
//     colon, so the first colon separates name from value. `bench-results.json`
//     stays duration-only (the CI history format); these rows reach the gate
//     through the log, not the file.
//
// Cost: one extra pass over every gated metric's op loop, measured and printed by
// `reportSectionCost` at the end of the section. What dominates it is the op
// counts the `[med3]` metrics use — the three 10M-op loops, the 100M-call breaker,
// `Worker spawn+join`'s 1000 thread lifecycles — not the counting itself. The rows
// that pay a counted allocation per op say so in their note; that is the fact they
// report, not a cost the zero rows avoid.
// ─────────────────────────────────────────────────

/// Counting allocator for this section: every allocation served through it is
/// counted, nothing is ever refused (`fail_index` is left at its default). It is
/// the same instrument as `WorkerAllocProbe`, named for its second job; the
/// difference is that the worker harness arms it to *fail*, and this one only
/// reads the counter.
const AllocCounter = std.testing.FailingAllocator;

/// One instrumented reading: what a metric's timed region allocated, over the op
/// count its `[med3]` entry runs.
const AllocReading = struct {
    allocations: usize,
    ops: usize,
    /// Set only by a harness with a half the allocation contract marks "must not
    /// allocate" (the worker's `stop`/`join`), so the line can show that half's own
    /// count instead of asking the reader to trust the total.
    none_alloc_half: ?usize = null,
};

fn allocLine(name: []const u8, reading: AllocReading, note: []const u8) void {
    const per_op = @as(f64, @floatFromInt(reading.allocations)) / @as(f64, @floatFromInt(reading.ops));
    std.debug.print("  [alloc] {s}: {d:.2} alloc/op  ({d} allocation(s) / {d} ops)", .{ name, per_op, reading.allocations, reading.ops });
    if (reading.none_alloc_half) |half| std.debug.print("; {d} through the stop/join half", .{half});
    if (note.len > 0) std.debug.print(" — {s}", .{note});
    std.debug.print("\n", .{});
}

/// Mirrors of the nine runtime harnesses above, op loop for op loop, counted.
///
/// Each one builds its fixture through the counting allocator's allocator (so a
/// path that allocates has the counter in it), snapshots the count, runs the same
/// timed region, and returns the delta. The assertions the timed harnesses carry
/// are kept: a count reported for a loop that did not actually run would be worse
/// than no count at all.
fn allocAtomicRmw(count: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    const counter = try probe.allocator().create(std.atomic.Value(u64));
    defer probe.allocator().destroy(counter);
    counter.* = std.atomic.Value(u64).init(0);

    const before = probe.allocations;
    for (0..count) |_| std.mem.doNotOptimizeAway(counter.fetchAdd(1, .monotonic));
    return .{ .allocations = probe.allocations - before, .ops = count };
}

fn allocRingBuffer(count: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    const ring = try probe.allocator().create(rt.RingBuffer(u64, 1024));
    defer probe.allocator().destroy(ring);
    ring.* = .{};

    const before = probe.allocations;
    for (0..count) |i| {
        if (!ring.tryPush(i)) return error.BenchRingFull;
        std.mem.doNotOptimizeAway(ring.tryPop() orelse return error.BenchRingEmpty);
    }
    return .{ .allocations = probe.allocations - before, .ops = count };
}

fn allocMailbox(io: std.Io, count: usize) !AllocReading {
    const M = rt.Mailbox(u64, 256);
    var probe = AllocCounter.init(harness_allocator, .{});
    const mailbox = try probe.allocator().create(M);
    defer probe.allocator().destroy(mailbox);
    mailbox.* = M.init(io);

    var posted: usize = 0;
    const before = probe.allocations;
    while (posted < count) {
        while (posted < count) {
            mailbox.send(posted) catch break; // queue full: drain, then resume
            posted += 1;
        }
        while (mailbox.tryRecv() != null) {}
    }
    return .{ .allocations = probe.allocations - before, .ops = count };
}

fn allocMailboxFull(io: std.Io, count: usize) !AllocReading {
    const M = rt.Mailbox(u64, 256);
    var probe = AllocCounter.init(harness_allocator, .{});
    const mailbox = try probe.allocator().create(M);
    defer probe.allocator().destroy(mailbox);
    mailbox.* = M.init(io);

    var posted: usize = 0;
    while (mailbox.send(posted)) |_| {
        posted += 1;
    } else |err| switch (err) {
        error.Full => {},
        else => return err,
    }
    if (posted != mailbox.maxMessages()) return error.BenchMailboxNotFull;

    const before = probe.allocations;
    for (0..count) |_| {
        mailbox.send(0) catch |err| switch (err) {
            error.Full => continue,
            else => return err,
        };
        return error.BenchMailboxAcceptedWhenFull;
    }
    return .{ .allocations = probe.allocations - before, .ops = count };
}

fn allocTimerWheel(count: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    var wheel = rt.Wheel(u64).init(probe.allocator(), 0);
    defer wheel.deinit();
    var fired = TimerFireCounter{};
    const tick_count = timer_span_ms / rt.timer_wheel.slot_ms;

    const before = probe.allocations;
    for (0..count) |i| {
        const tick: i64 = @intCast(i % @as(usize, @intCast(tick_count)));
        _ = try wheel.schedule((tick + 1) * rt.timer_wheel.slot_ms, @intCast(i));
    }
    _ = wheel.advance(timer_span_ms, &fired, TimerFireCounter.onFire);
    const allocations = probe.allocations - before;

    if (fired.fired != count) return error.BenchTimerWheelLostTimers;
    return .{ .allocations = allocations, .ops = count };
}

fn allocHotBus(count: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    const bus = try probe.allocator().create(rt.HotBus(u64, bench_bus_subscribers));
    defer probe.allocator().destroy(bus);
    bus.* = rt.HotBus(u64, bench_bus_subscribers).init();

    const counters = try probe.allocator().alloc(BusCounter, bench_bus_subscribers);
    defer probe.allocator().free(counters);
    @memset(counters, BusCounter{});
    for (counters) |*counter| try bus.subscribeSink(counter.sink());
    bus.freeze();

    const before = probe.allocations;
    for (0..count) |i| _ = try bus.publish(i);
    const allocations = probe.allocations - before;

    for (counters) |counter| {
        if (counter.events != count) return error.BenchHotBusLostEvents;
    }
    return .{ .allocations = allocations, .ops = count };
}

fn allocObjectPool(count: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    const pool = try probe.allocator().create(rt.ObjectPool(PoolSlot));
    defer probe.allocator().destroy(pool);
    pool.* = try rt.ObjectPool(PoolSlot).init(probe.allocator(), 64, null);
    defer pool.deinit();

    const before = probe.allocations;
    for (0..count) |i| {
        const slot = pool.acquire() orelse return error.BenchPoolExhausted;
        slot.value = i;
        std.mem.doNotOptimizeAway(slot.value);
        if (!pool.release(slot)) return error.BenchPoolRejectedRelease;
    }
    return .{ .allocations = probe.allocations - before, .ops = count };
}

fn allocSequencer(count: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    const seq = try probe.allocator().create(rt.Sequencer);
    defer probe.allocator().destroy(seq);
    seq.* = rt.Sequencer.init(0);

    const before = probe.allocations;
    for (0..count) |_| std.mem.doNotOptimizeAway(seq.next());
    return .{ .allocations = probe.allocations - before, .ops = count };
}

fn allocWorkerSpawnJoin(io: std.Io, turns: usize) !AllocReading {
    var clk = rt.Clock.Manual{ .now_ms = 0 };
    var probe = AllocCounter.init(harness_allocator, .{});
    var rtx = rt.Runtime.init(probe.allocator(), io, .{ .manual = &clk });
    defer rtx.deinit();
    try rtx.start();

    var stop_half: usize = 0;
    const before = probe.allocations;
    for (0..turns) |_| {
        const handle = try rtx.spawn(BenchNoopWorker, .{}, bench_worker_mailbox_capacity);
        const after_spawn = probe.allocations;
        handle.stop();
        handle.join();
        stop_half += probe.allocations - after_spawn;
        std.mem.doNotOptimizeAway(handle.state.seen);
    }
    const allocations = probe.allocations - before;

    rtx.shutdown();
    const s = rtx.stats();
    if (s.workers != 0 or s.running != 0) return error.BenchRuntimeLeakedWorkers;
    return .{ .allocations = allocations, .ops = turns, .none_alloc_half = stop_half };
}

// ── Mirrors for the rest of the gated metrics ─────────────────────────
//
// Same contract as the nine above: fixture through the counter, snapshot, the
// timed harness's op loop call for call with its assertions kept, report the
// delta. Everything here is one of the two readings the banner describes —
// a counted `N.NN` where the path allocates by design, or a structural `0.00`
// where it holds no allocator at all.

fn allocModuleScan(count: usize) !AllocReading {
    const MockModule = struct {
        pub const info = zigmodu.api.Module{ .name = "bench", .description = "Benchmark module", .dependencies = &.{} };
        pub fn init() !void {}
        pub fn deinit() void {}
    };
    var probe = AllocCounter.init(harness_allocator, .{});
    // No fixture: the harness's whole loop is the timed region, so the mirror
    // counts all of it, scan and deinit alike.
    const before = probe.allocations;
    for (0..count) |_| {
        var modules = try zigmodu.scanModules(probe.allocator(), .{MockModule});
        modules.deinit();
    }
    return .{ .allocations = probe.allocations - before, .ops = count };
}

fn allocModuleValidation(count: usize) !AllocReading {
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
    var probe = AllocCounter.init(harness_allocator, .{});
    var modules = try zigmodu.scanModules(probe.allocator(), .{ A, B });
    defer modules.deinit();
    const before = probe.allocations;
    for (0..count) |_| {
        try zigmodu.validateModules(&modules);
    }
    return .{ .allocations = probe.allocations - before, .ops = count };
}

fn allocApplicationLifecycle(io: std.Io, count: usize) !AllocReading {
    const M = struct {
        pub const info = zigmodu.api.Module{ .name = "m", .description = "M", .dependencies = &.{} };
        pub fn init() !void {}
        pub fn deinit() void {}
    };
    var probe = AllocCounter.init(harness_allocator, .{});
    const before = probe.allocations;
    for (0..count) |_| {
        var app = try zigmodu.Application.init(io, probe.allocator(), "bench", .{M}, .{});
        try app.start();
        app.stop();
        app.deinit();
    }
    return .{ .allocations = probe.allocations - before, .ops = count };
}

fn allocWorkflow(io: std.Io, steps_count: usize, iterations: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    const allocator = probe.allocator();
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
    // Unlike `benchWorkflow` (fixture on the caller's arena, per-run records on
    // `harness_allocator`), the mirror runs everything through the counter: the
    // fixture is built before the snapshot, and the per-run records — step
    // records plus the skill's result value — are exactly what the snapshot
    // region must catch.
    var ctx = zigmodu.ai.SkillContext{ .allocator = allocator };
    const before = probe.allocations;
    for (0..iterations) |_| {
        var r = try wf.run(allocator, &ctx);
        r.deinit();
    }
    return .{ .allocations = probe.allocations - before, .ops = iterations };
}

fn allocEventBus(listeners: usize, events: usize) !AllocReading {
    const E = struct { id: u64 };
    var probe = AllocCounter.init(harness_allocator, .{});
    var bus = zigmodu.TypedEventBus(E).init(probe.allocator());
    defer bus.deinit();
    for (0..listeners) |_| {
        try bus.subscribe(struct {
            fn cb(_: E) void {}
        }.cb);
    }
    const before = probe.allocations;
    for (0..events) |i| {
        bus.publish(.{ .id = @intCast(i) });
    }
    return .{ .allocations = probe.allocations - before, .ops = events };
}

fn allocCircuitBreaker(calls: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    // One loop for both passes: the harness is the timed one, and the mirror
    // routes through it with the probe as its allocator (see the `counted`
    // parameter there — and why this binary must not hold two copies of that
    // loop). On return `probe.allocations` holds the loop's delta.
    _ = try benchCircuitBreaker(probe.allocator(), calls, &probe.allocations);
    return .{ .allocations = probe.allocations, .ops = calls };
}

fn allocRateLimiter(calls: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    var rl = try zigmodu.RateLimiter.init(probe.allocator(), "bench", 1_000_000, 1_000_000);
    defer rl.deinit();
    const before = probe.allocations;
    for (0..calls) |_| {
        _ = rl.tryAcquire();
    }
    return .{ .allocations = probe.allocations - before, .ops = calls };
}

fn allocHealthEndpoint(checks: usize, iterations: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    const allocator = probe.allocator();
    var ep = zigmodu.HealthEndpoint.init(allocator);
    defer ep.deinit();
    for (0..checks) |i| {
        const name = try std.fmt.allocPrint(allocator, "check-{}", .{i});
        defer allocator.free(name);
        try ep.registerCheck(name, "bench", zigmodu.HealthEndpoint.alwaysUp);
    }
    const before = probe.allocations;
    for (0..iterations) |_| {
        var d = ep.checkHealth();
        d.components.deinit();
    }
    return .{ .allocations = probe.allocations - before, .ops = iterations };
}

fn allocDbQuery(io: std.Io, queries: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    const allocator = probe.allocator();
    var client = zigmodu.data.sqlx.Client.init(allocator, io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, value REAL)", &.{});
    for (0..100) |i| {
        const s = try std.fmt.allocPrint(allocator, "INSERT INTO t VALUES ({}, 'item{}', {}.0)", .{ i, i, i });
        defer allocator.free(s);
        _ = try client.exec(s, &.{});
    }
    const backend = zigmodu.data.SqlxBackend{ .allocator = allocator, .client = &client };
    var orm = zigmodu.data.orm.Orm(zigmodu.data.SqlxBackend){ .backend = backend };
    const Row = struct {
        pub const sql_table_name: []const u8 = "t";
        id: i64,
        name: []const u8,
        value: f64,
    };
    var repo = zigmodu.data.Repository(Row){ .orm = &orm };
    if (try repo.findById(@as(i64, 50))) |r| allocator.free(r.name);
    const before = probe.allocations;
    for (0..queries) |_| {
        if (try repo.findById(@as(i64, 50))) |r| allocator.free(r.name);
    }
    return .{ .allocations = probe.allocations - before, .ops = queries };
}

fn allocStoreForward(count: usize) !AllocReading {
    const Cells = struct {
        a: std.atomic.Value(u64) align(std.atomic.cache_line),
        b: std.atomic.Value(u64),
    };
    var probe = AllocCounter.init(harness_allocator, .{});
    const cells = try probe.allocator().create(Cells);
    defer probe.allocator().destroy(cells);
    cells.* = .{
        .a = std.atomic.Value(u64).init(0),
        .b = std.atomic.Value(u64).init(0),
    };
    var x: u64 = 0;
    const before = probe.allocations;
    for (0..count) |_| {
        cells.a.store(x +% 1, .release);
        x = cells.a.load(.acquire);
        cells.b.store(x +% 1, .release);
        x = cells.b.load(.acquire);
        std.mem.doNotOptimizeAway(x);
    }
    const allocations = probe.allocations - before;
    if (x != 2 *% @as(u64, @intCast(count))) return error.BenchStoreForwardFolded;
    return .{ .allocations = allocations, .ops = count };
}

fn allocMpscRingPush(count: usize) !AllocReading {
    // The ring holds no allocator, so this reading is the structural zero —
    // the same zero `alloc_contract_test.zig` asserts for `MpscRing` push+pop.
    var probe = AllocCounter.init(harness_allocator, .{});
    const R = rt.MpscRing(u64, 1024);
    const ring = try probe.allocator().create(R);
    defer probe.allocator().destroy(ring);
    ring.* = R.init();
    var expected: [bench_mpsc_producers]u64 = @splat(0);
    var pushed: usize = 0;
    const before = probe.allocations;
    while (pushed < count) {
        while (pushed < count) {
            if (!ring.tryPush(@intCast(pushed))) break;
            pushed += 1;
        }
        while (ring.tryPop()) |v| {
            if (expected[v % bench_mpsc_producers] != v / bench_mpsc_producers) return error.BenchMpscReordered;
            expected[v % bench_mpsc_producers] = v / bench_mpsc_producers + 1;
        }
    }
    const allocations = probe.allocations - before;
    if (pushed != count) return error.BenchMpscLostPushes;
    if (!ring.isEmpty()) return error.BenchMpscLeftovers;
    return .{ .allocations = allocations, .ops = count };
}

fn allocTimerWheelChurn(rounds: usize) !AllocReading {
    var probe = AllocCounter.init(harness_allocator, .{});
    var wheel = rt.Wheel(u64).init(probe.allocator(), 0);
    defer wheel.deinit();
    var fired = TimerFireCounter{};
    const slots_used = timer_span_ms / rt.timer_wheel.slot_ms;
    var now_ms: i64 = 0;
    var id: u64 = 1;
    const before = probe.allocations;
    for (0..rounds) |_| {
        for (0..timer_churn_live) |k| {
            const tick: i64 = @intCast(k % @as(usize, @intCast(slots_used)));
            try wheel.scheduleWithId(id, now_ms + (tick + 1) * rt.timer_wheel.slot_ms, @intCast(k));
            id += 1;
        }
        _ = wheel.advance(now_ms + timer_span_ms, &fired, TimerFireCounter.onFire);
        now_ms += timer_span_ms;
    }
    const allocations = probe.allocations - before;
    if (wheel.pendingCount() != 0) return error.BenchTimerWheelLeaked;
    if (fired.fired != @as(u64, rounds) * timer_churn_live) return error.BenchTimerWheelLostTimers;
    return .{ .allocations = allocations, .ops = @as(usize, rounds) * timer_churn_live };
}

fn allocWorkerDrain(comptime mode: rt.SpawnMode, io: std.Io, count: usize) !AllocReading {
    var seen = std.atomic.Value(u64).init(0);
    var probe = AllocCounter.init(harness_allocator, .{});
    // The runtime — and its ticker — run for real on the probe allocator. The
    // ticker's steady state drains an empty command ring and advances an empty
    // wheel, which allocates nothing, so the snapshot region is producer-side
    // only; a ticker that grew a per-tick allocation would show up here.
    var rtx = try rt.Runtime.initWithOptions(probe.allocator(), io, .{
        .scheduler = .{ .max_pooled_workers = 1, .pool_threads = 1 },
    });
    defer rtx.deinit();
    try rtx.start();

    const handle = if (comptime mode == .pooled)
        try rtx.spawn(BenchDrainWorker, .{ .seen = &seen }, .{ .capacity = bench_drain_capacity, .mode = .pooled })
    else
        try rtx.spawn(BenchDrainWorker, .{ .seen = &seen }, bench_drain_capacity);

    const before = probe.allocations;
    var sent: usize = 0;
    while (sent < count) {
        handle.send(sent) catch |err| switch (err) {
            error.Full => {
                std.atomic.spinLoopHint();
                continue;
            },
            error.Closed => return error.BenchDrainWorkerClosed,
            error.Timeout => return error.BenchDrainUnexpectedTimeout,
        };
        sent += 1;
    }
    var spins: usize = 0;
    while (seen.load(.acquire) < count and spins < bench_drain_timeout_spins) : (spins += 1) std.atomic.spinLoopHint();
    const allocations = probe.allocations - before;
    if (seen.load(.acquire) != count) return error.BenchDrainLostMessages;

    handle.stop();
    handle.join();
    if (handle.state.acc != count * (count - 1) / 2) return error.BenchDrainWrongSum;
    return .{ .allocations = allocations, .ops = count };
}

fn allocWorkerDrainDedicated(io: std.Io, count: usize) !AllocReading {
    return allocWorkerDrain(.dedicated, io, count);
}

fn allocWorkerDrainPooled(io: std.Io, count: usize) !AllocReading {
    return allocWorkerDrain(.pooled, io, count);
}

fn allocTimerAfter(io: std.Io, count: usize) !AllocReading {
    var clk = rt.Clock.Manual{ .now_ms = 0 };
    var probe = AllocCounter.init(harness_allocator, .{});
    var rtx = rt.Runtime.init(probe.allocator(), io, .{ .manual = &clk });
    defer rtx.deinit();
    const handle = try rtx.spawn(BenchNoopWorker, .{}, bench_worker_mailbox_capacity);

    const tick_count = timer_span_ms / rt.timer_wheel.slot_ms;
    var armed: usize = 0;
    const before = probe.allocations;
    while (armed < count) {
        while (armed < count) {
            const tick: i64 = @intCast(armed % @as(usize, @intCast(tick_count)));
            _ = handle.after((tick + 1) * rt.timer_wheel.slot_ms, @intCast(armed)) catch |err| switch (err) {
                error.Full => break,
                else => return err,
            };
            armed += 1;
        }
        _ = rtx.tick();
    }
    _ = rtx.tick();
    const allocations = probe.allocations - before;

    if (rtx.wheel.pendingCount() != count) return error.BenchTimerAfterLostTimers;
    rtx.shutdown();
    const s = rtx.stats();
    if (s.timers_discarded != count) return error.BenchTimerAfterLeakedTimers;
    if (s.timer_deliveries_dropped != 0) return error.BenchTimerAfterDroppedDelivery;
    return .{ .allocations = allocations, .ops = count };
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
        const ms = try median3(tc[0], benchCircuitBreaker, .{ a, tc[1], null });
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
    // One scale per primitive: in a ReleaseFast build these land at 6-29 ms, which
    // is stable enough to threshold, and a second scale would double both CI time
    // and the number of thresholds the gate has to hold. The two metrics that are
    // not a lock-free primitive — `Worker spawn+join` (thread creation) and
    // `Mailbox full-path` (a refusal, an order of magnitude cheaper per turn than
    // the hand-off above and so given 10x the turns) — are each still one
    // primitive, not a second scale of something already in the group.
    //
    // `atomic RMW x10M` leads the group because it is the group's (and the
    // suite's) machine reference: the host's bare atomic RMW cost, which
    // `check-bench.sh` divides the atomic-path metrics by. First, so the
    // reference and the metrics normalized against it are never far apart in
    // time; see `benchAtomicRmw`.
    {
        const name = "atomic RMW x10M";
        const ms = try median3(name, benchAtomicRmw, .{ a, 10_000_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} RMW/s)\n", .{ name, ms, 10_000_000.0 / ms * 1000.0 });
        std.debug.print("    ^ machine reference, not a framework metric: check-bench.sh gates the\n      atomic-path metrics (Mailbox post+drain, Mailbox full-path, HotBus 8sub,\n      Sequencer x10M, 1L x10M events) as a ratio against this run's value.\n", .{});
    }
    {
        // The ring's candidate denominator, measured next to the metric it may one
        // day divide. Ten million rounds because that is ~1M ring round trips'
        // worth of this loop's work on a host where the orderings are cheap and
        // ~5x that where they are not — either way comfortably above the ~5 ms
        // this suite sizes a new metric at. See `benchStoreForward`.
        const name = "StoreForward x10M";
        const ms = try median3(name, benchStoreForward, .{ a, 10_000_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} chains/s)\n", .{ name, ms, 10_000_000.0 / ms * 1000.0 });
        std.debug.print("    ^ candidate reference for `RingBuffer SPSC x1M`, not a divisor yet and\n      not gated on an absolute value: check-bench.sh reports it, see its header.\n", .{});
    }
    {
        const name = "RingBuffer SPSC x1M";
        const ms = try median3(name, benchRingBuffer, .{ a, 1_000_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} round trips/s)\n", .{ name, ms, 1_000_000.0 / ms * 1000.0 });
    }
    {
        // The raw Vyukov ring's multi-producer push, next to its SPSC sibling
        // above: `MpscRing` is what the scheduler's ready ring and the timer
        // command queue run, and `Mailbox post+drain` only covers it through
        // the mailbox wrapper. Four producer cursors, one thread — the gated
        // shape is contention-free on purpose, see `benchMpscRingPush`. 2M
        // (not 1M): the raw push is ~3.7x cheaper than the mailbox wrapper
        // above, and 1M landed at 4.7 ms — under the ~5 ms this suite sizes a
        // new metric at.
        const name = "MpscRing 4P x2M";
        const ms = try median3(name, benchMpscRingPush, .{2_000_000});
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} pushes/s)\n", .{ name, ms, 2_000_000.0 / ms * 1000.0 });
    }
    {
        const name = "Mailbox post+drain x1M";
        const ms = try median3(name, benchMailbox, .{ io, a, 1_000_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} messages/s)\n", .{ name, ms, 1_000_000.0 / ms * 1000.0 });
    }
    {
        const name = "Mailbox full-path x10M";
        const ms = try median3(name, benchMailboxFull, .{ io, 10_000_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} rejects/s)\n", .{ name, ms, 10_000_000.0 / ms * 1000.0 });
    }
    {
        const name = "TimerWheel x100K";
        // `a` (the suite's arena), and it is *not* the reclaiming
        // `harness_allocator` the rest of the harnesses use — that was measured
        // and it is worse here. The argument for `harness_allocator` elsewhere is
        // that freed blocks come back off the freelist and keep the pages warm,
        // but this harness **never frees**: it arms `count` never-reused ids into
        // a fresh wheel and drops it, so nothing is returned to any freelist and
        // the swap only adds `smp_allocator`'s own slab metadata to the tail.
        // Eight runs each way, same machine, medians of `[med3]`:
        //
        //   arena         6.94 - 8.79 ms   run-to-run 1.27x, worst in-run 1.55x
        //   harness_all.  7.95 - 12.17 ms  run-to-run 1.53x, worst in-run 1.86x
        //
        // Either way this one is far noisier than its neighbours in the same runs
        // (`TimerWheel churn x1M` 1.05x, `atomic RMW x10M` 1.04x), and the reason
        // is structural rather than fixable by the allocator: a fresh wheel plus
        // `count` fresh ids means the timed loop grows `nodes` (34 growth
        // allocations / 14.75 MB at 100k) and first-touches every page it lands
        // on — the host's page path, in the numerator, on purpose. That is what
        // this metric is for (the steady state is `TimerWheel churn x1M`), so it
        // is left alone and `check-bench.sh`'s header says what a breach here
        // means: re-run before believing it.
        const ms = try median3(name, benchTimerWheel, .{ a, 100_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} timers/s)\n", .{ name, ms, 100_000.0 / ms * 1000.0 });
    }
    {
        // The other half of the same question: not "what does arming cost" but
        // "what does arming cost on a wheel that has been arming for a while".
        // See `benchTimerWheelChurn` — this is the row that catches a regression
        // no fresh-wheel harness can see.
        const name = "TimerWheel churn x1M";
        const ms = try median3(name, benchTimerWheelChurn, .{ harness_allocator, timer_churn_rounds });
        try results.append(a, .{ .name = name, .value = ms });
        const ops = @as(f64, timer_churn_rounds) * timer_churn_live;
        std.debug.print("  {s}  {d:.2} ms  ({d:.1} ns per schedule+fire, {d} live)\n", .{ name, ms, ms * 1e6 / ops, @as(u32, timer_churn_live) });
    }
    {
        // The `after()` path end to end — caller-side payload + command ring,
        // owner-side drain + wheel insert — on a hand-driven runtime, see
        // `benchTimerAfter`. 100K arms lands in the same scale family as the
        // two wheel metrics above it (~10-15 ms against today's build).
        const name = "Timer after x100K";
        const ms = try median3(name, benchTimerAfter, .{ io, 100_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} arms/s)\n", .{ name, ms, 100_000.0 / ms * 1000.0 });
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
    {
        const name = "Worker spawn+join x1K";
        const ms = try median3(name, benchWorkerSpawnJoin, .{ io, 1000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} cycles/s)\n", .{ name, ms, 1000.0 / ms * 1000.0 });
    }
    // The hand-off pair, and the axis they sit on with `Mailbox post+drain x1M`
    // above: no thread / a dedicated thread / a pool thread, same producer loop,
    // same worker, same mailbox capacity. Read as a boundary rather than two
    // metrics — see the printed line, which states the ratio because the ratio is
    // the whole point: that is the price of the execution mode, and it is what
    // decides whether a worker belongs on the critical path or in the long tail.
    var drain_ms: [2]f64 = undefined;
    {
        const name = "Worker drain dedicated x1M";
        const ms = try median3(name, benchWorkerDrainDedicated, .{ io, 1_000_000 });
        drain_ms[0] = ms;
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.1} ns per hand-off)\n", .{ name, ms, ms * 1e6 / 1_000_000.0 });
    }
    {
        const name = "Pooled dispatch x1M";
        const ms = try median3(name, benchWorkerDrainPooled, .{ io, 1_000_000 });
        drain_ms[1] = ms;
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.1} ns per hand-off)\n", .{ name, ms, ms * 1e6 / 1_000_000.0 });
    }
    std.debug.print("    ^ pooled / dedicated = {d:.2}x. Both are gated on their own absolute value; this\n      ratio is printed, not thresholded, because it is near 1 and a 2.0x window on a\n      ratio of two similar numbers is noise. A >1.3x move here is the boundary\n      shifting and worth a look.\n", .{drain_ms[1] / drain_ms[0]});

    // ── Pool sweep ────────────────────────────────────────────────────────
    //
    // Five scales, not a grid: what a reader needs is (a) whether a second pool
    // thread buys anything at a fixed worker count, and (b) how the cost per
    // message moves as workers multiply. Sweeping both axes fully would be 25
    // points for a shape five of them already show, in a suite that runs on
    // every push.
    //
    // **Observation only, never gated, and nothing here enters
    // `bench-results.json`.** The hand-off pair above measures 1.84x and 3.09x
    // run-to-run spread on this machine at a single grid point; a dozen more such
    // numbers in front of a 2.0x window would be a false-red machine. The gate
    // judges the two hand-off rows (absolute, declared in `REF_METRICS`), and
    // these lines are for reading.
    std.debug.print("\n-- Pool sweep (observation only, never gated) --\n", .{});
    std.debug.print("  {d} messages per point, {d}-slot mailboxes, one producer that skips a full worker\n  instead of waiting on it. Median of 3 per point.\n", .{ bench_sweep_messages, bench_sweep_capacity });
    std.debug.print("  Two families, and they answer opposite halves of one question. **Read the\n  pool_threads column together with the family label**: with no payload {d} workers x\n  {d} slots is {d} messages of slack, so the *producer* is the limiter and extra pool\n  threads only add ring-CAS and cache-line contention — the 1-thread row is the\n  fastest there, and that is not a defect. With a payload the pool is the limiter\n  and the rows climb with threads until the machine runs out of cores. Neither\n  family is the answer on its own.\n", .{ 100, bench_sweep_capacity, 100 * bench_sweep_capacity });
    const sweep = [_][2]usize{
        .{ 1, 1 },
        .{ 10, 4 },
        .{ 100, 1 },
        .{ 100, 2 },
        .{ 100, 4 },
    };
    sweepFamily("payload=none  (the producer is the limiter)", 0, io, &sweep, bench_sweep_messages);
    // The same axis with **real work per message**, which is the only way to ask
    // the other half of the question: a pool exists to run work, so "does a
    // second thread help" is really "can the pool use one". With no payload the
    // producer is the limiter and extra threads are pure contention (above); here
    // the work is, and the rows should climb with `pool_threads` until the
    // machine's cores run out.
    //
    // 8 workers, not 100, and that is deliberate: the question is per-thread
    // scaling, so the worker count should be at or below the core count of a
    // typical CI box rather than 10x over it.
    const worked = [_][2]usize{
        .{ 8, 1 },
        .{ 8, 2 },
        .{ 8, 4 },
        .{ 8, 8 },
    };
    sweepFamily("payload=256 (the pool is the limiter)", sweep_work_iters, io, &worked, bench_sweep_worked_messages);

    // ── Latency distribution ──────────────────────────────────────────────
    //
    // The latency-sensitive half of the runtime group plus the two chains this
    // suite has: `App lifecycle` (scan → validate → init → start → stop, the
    // whole application lifecycle in one turn) and `1L x10M events` (publish →
    // dispatch → deliver). One metric per primitive, not a second scale of one
    // already here, and each measured with the same total work as its `[med3]`
    // line above — see the banner at `pct_batches` for what a sample is, why the
    // collection cannot allocate, and why none of this is gated.
    //
    // `atomic RMW x10M` leads the list as it does above: it is the machine
    // reference, so its own spread is the context for the ones below it. The
    // harnesses with a per-call fixture comparable to their timed region are
    // deliberately absent — `findById x20K` rebuilds a table and inserts 100 rows
    // per call, which is fixture the sampler would be timing alongside the query
    // it is not (see `LatencyRun.run`).
    //
    // `TimerWheel x100K` is the other absence, and it is the one that used to be a
    // caveat instead: it was sampled like the rest and reported 0.34-0.51x of its
    // own `[med3]` value, with a printed note per run. The cause is not the
    // sampler but the metric: **its per-turn cost is a function of the live
    // wheel's size**, because a turn's work is walking the structure the 100k
    // scheduled timers form. A 100-op batch holds 100 nodes — a ~5.6 KB live
    // structure it walks straight out of L1 — where the judged sample walks the
    // same 100k nodes spread over ~5.6 MB, and the difference is not in the
    // per-turn code but in the memory system underneath it. Measured on this
    // machine with the same loop (one wheel, one clock pair per half, no per-op
    // clock — a per-op clock read is ~25 ns against a ~70 ns turn): a 100k-node
    // wheel costs 49.8 ns in the schedule half and 20.8 ns in the advance walk per
    // timer; 100-op batches cost 23.5 and 4.9. The schedule half's gap is the
    // `nodes` map (100k entries, ~3.5 MB of buckets, a cache miss per put/remove)
    // and first-touching the node memory; the advance half's is the 5.6 MB of
    // nodes it has to walk.
    //
    // Growing the batch does not close it — the quantity that matters is how much
    // *live* structure a sample walks, not how many ops it runs. Same 100k timers
    // split five ways, sum over the batches against `[med3]`:
    //
    //     ops/batch    100    250    500   1000   2000
    //     sum/med3    0.42   0.47   0.45   0.47   0.64
    //
    // So making the batches comparable means making each one a judged-scale run,
    // and that is where this stops: one judged sample is ~6.7 ms, so 1000 of them
    // are ~6.8 s — 30x the entire section's cost for one row, in a suite that runs
    // on every push to main. The cheaper shapes are not honest: 100 judged-scale
    // batches (measured 677 ms, sum/med3 1.007) do put the sum back at 1.0x, but
    // p99.9 over 100 samples is the maximum of 100 — a different statistic from the
    // one the other rows print — and 20 of them (134 ms) are worse still. This is a
    // harness whose cost lives in the size of its state, and batching it changes
    // what is measured, so the row is dropped rather than sampled at a shape nobody
    // can compare (the metric itself stays: `[med3] TimerWheel x100K` is still
    // measured and still gated, see `benchTimerWheel`). The section prints the
    // omission.
    std.debug.print("\n-- Latency distribution (p50 / p95 / p99 / p99.9, ns per op) --\n", .{});
    std.debug.print("  {d} batches per metric, one clock pair per batch, nearest-rank quantiles over the\n  batch samples. Observation only: the gate judges the `[med3]` values above, not these.\n", .{pct_batches});
    std.debug.print("  Not sampled here: `TimerWheel x100K` — its per-turn cost is the size of the live wheel\n  (100k nodes), which no 100-op batch holds; its `[med3]` number above is unaffected.\n", .{});
    std.debug.print("  Not sampled here either: `TimerWheel churn x1M` — what it measures is what a wheel costs\n  *after* churning, and a batch that rebuilds the fixture is only a few rounds old (the same\n  fixture-dominates-the-sample rule that keeps `findById x20K` out).\n", .{});
    std.debug.print("  And the hand-off pair: `Worker drain dedicated x1M` / `Pooled dispatch x1M` — each call\n  builds a Runtime, a worker and (for the pooled one) a pool thread, which for a 1000-op batch\n  is fixture the size of the measurement. Their `[med3]` values above are the numbers; the tail\n  of a hand-off is left to a harness that can build its fixture once.\n", .{});

    const latency_section_t0 = now();
    var latency = LatencyRun{ .allocator = a, .injector = try LatencyInjector.fromEnv(init.environ_map), .medians = &results };
    if (latency.injector.active()) {
        std.debug.print("  !! latency injection ON (ZIGMODU_BENCH_INJECT_NS={d}, every {d}th batch): counter-proof\n     run, not a measurement of the framework — p50/p95 must stay put and p99 must move.\n", .{ latency.injector.stall_ns, latency.injector.every });
    }
    std.debug.print("\n", .{});
    try latency.run("atomic RMW x10M", benchAtomicRmw, .{a}, 10_000_000);
    try latency.run("RingBuffer SPSC x1M", benchRingBuffer, .{a}, 1_000_000);
    try latency.run("Mailbox post+drain x1M", benchMailbox, .{ io, a }, 1_000_000);
    try latency.run("Mailbox full-path x10M", benchMailboxFull, .{io}, 10_000_000);
    try latency.run("HotBus 8sub x1M", benchHotBus, .{a}, 1_000_000);
    try latency.run("ObjectPool x1M", benchObjectPool, .{a}, 1_000_000);
    try latency.run("Sequencer x10M", benchSequencer, .{a}, 10_000_000);
    try latency.run("Worker spawn+join x1K", benchWorkerSpawnJoin, .{io}, 1_000);
    try latency.run("App lifecycle x3K", benchApplicationLifecycle, .{io}, 3_000);
    try latency.run("1L x10M events", benchEventBus, .{ a, 1 }, 10_000_000);
    reportSectionCost("pct", latency_section_t0, 10);

    // ── Allocation counts per op ──────────────────────────────────────────
    //
    // The instrumented pass described in the banner at `AllocCounter`, after the
    // latency table and outside it: its runs are counted, never timed, and a
    // duration measured here would measure the instrument. One row per gated
    // metric, same scales and op loops as the `[med3]` section — and since
    // 2026-09-22 a criterion, not just a readout: `scripts/check-bench.sh`
    // parses these rows and fails any metric whose baseline declares
    // `max_alloc_per_op` and reads above it. A row that reads other than 0.00
    // names why in its note — the paths that allocate by contract do so
    // deliberately, and are asserted exactly in
    // `src/runtime/alloc_contract_test.zig`.
    std.debug.print("\n-- Allocation counts per op (instrumented pass: counts only, no timing) --\n", .{});
    std.debug.print("  A counting allocator sits in the path, so these runs are *not* timed and nothing here is\n  comparable with the `[med3]` or `[pct]` numbers above. Fixture is built before the\n  snapshot; the op loops are copies of the timed ones. Second criterion: `check-bench.sh`\n  fails any metric whose baseline declares `max_alloc_per_op` and reads above it — a count\n  is exact, so an alloc breach is a regression, not noise.\n", .{});
    const alloc_section_t0 = now();
    allocLine("scanModules x100K", try allocModuleScan(100000), "");
    allocLine("scanModules x1M", try allocModuleScan(1_000_000), "");
    allocLine("validateModules x10K", try allocModuleValidation(10000), "");
    allocLine("validateModules x100K", try allocModuleValidation(100000), "");
    allocLine("App lifecycle x3K", try allocApplicationLifecycle(io, 3000), "");
    allocLine("workflow 20-step x5K", try allocWorkflow(io, 20, 5000), "");
    allocLine("1L x10M events", try allocEventBus(1, 10_000_000), "");
    allocLine("10L x1M events", try allocEventBus(10, 1_000_000), "");
    allocLine("100L x100K events", try allocEventBus(100, 100_000), "");
    allocLine("CircuitBreaker x10M", try allocCircuitBreaker(10_000_000), "");
    allocLine("CircuitBreaker x100M", try allocCircuitBreaker(100_000_000), "");
    allocLine("RateLimiter x1M", try allocRateLimiter(1_000_000), "");
    allocLine("RateLimiter x10M", try allocRateLimiter(10_000_000), "");
    allocLine("10 checks x100K", try allocHealthEndpoint(10, 100000), "");
    allocLine("100 checks x10K", try allocHealthEndpoint(100, 10000), "");
    allocLine("findById x20K", try allocDbQuery(io, 20000), "");
    allocLine("findById x10K", try allocDbQuery(io, 10000), "");
    allocLine("atomic RMW x10M", try allocAtomicRmw(10_000_000), "host reference: no allocator on the path, the zero is structural");
    allocLine("StoreForward x10M", try allocStoreForward(10_000_000), "host reference: same structural zero");
    allocLine("RingBuffer SPSC x1M", try allocRingBuffer(1_000_000), "");
    allocLine("MpscRing 4P x2M", try allocMpscRingPush(2_000_000), "");
    allocLine("Mailbox post+drain x1M", try allocMailbox(io, 1_000_000), "");
    allocLine("Mailbox full-path x10M", try allocMailboxFull(io, 10_000_000), "");
    allocLine("TimerWheel x100K", try allocTimerWheel(100_000), "one node per scheduled timer: `Wheel.schedule` allocates the node by contract, `cancel`/`advance` do not");
    allocLine("TimerWheel churn x1M", try allocTimerWheelChurn(timer_churn_rounds), "one node per schedule, freed on fire: the churn shape's count is the same 1/op with reuse, so what it buys over `TimerWheel x100K`'s row is the *steady-state* map-growth number");
    allocLine("HotBus 8sub x1M", try allocHotBus(1_000_000), "");
    allocLine("ObjectPool x1M", try allocObjectPool(1_000_000), "");
    allocLine("Sequencer x10M", try allocSequencer(10_000_000), "");
    allocLine("Worker spawn+join x1K", try allocWorkerSpawnJoin(io, 1_000), "one heap handle per worker (`spawn`), plus the worker list's amortized growth; `stop`/`join` allocate nothing");
    allocLine("Worker drain dedicated x1M", try allocWorkerDrainDedicated(io, 1_000_000), "");
    allocLine("Pooled dispatch x1M", try allocWorkerDrainPooled(io, 1_000_000), "");
    allocLine("Timer after x100K", try allocTimerAfter(io, 100_000), "one `Delivery` payload per arm on the caller thread, plus one wheel node per insert on the owner half — the two allocations the path makes by contract");
    reportSectionCost("alloc", alloc_section_t0, 32);

    // Emit bench-results.json for CI baseline tracking
    // (github-action-benchmark `customSmallerIsBetter` format); `value` is the
    // median of the three samples each metric was measured with (`median3`).
    // The percentile section above deliberately writes nothing here: a metric the
    // baselines do not know is a WARN in `check-bench.sh`, and adding 40 such
    // entries per run (10 metrics x 4 quantiles) would train its reader to skip
    // warnings. The `[alloc]` rows stay out of this file too — the CI history
    // format has no place for them — but they are a criterion now, read from the
    // run's log by `check-bench.sh`, not lost: see the section above.
    const json = try std.json.Stringify.valueAlloc(a, results.items, .{});
    const file = try std.Io.Dir.cwd().createFile(io, "bench-results.json", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, json);

    std.debug.print("\nDone. Results written to bench-results.json\n", .{});
}
