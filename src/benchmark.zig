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
/// Both observation-only sections in this suite cost real CI time — the `[pct]`
/// section is one extra pass over the metrics it covers, and the `[alloc]`
/// section is another — so the budget each one claims in its banner is printed
/// next to what it actually spent. Without this the cost of the next metric added
/// to either list would show up only as a slower CI job, which is exactly the kind
/// of drift a comment cannot catch.
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
// Allocation counts per op — `[alloc]` (instrumented, separate pass, report only)
//
// A latency table says how long a turn takes; it cannot say whether the turn
// *allocated*, and for the runtime group that is the number the framework actually
// makes a promise about: `send` copies into a fixed-capacity slot, `publish` fans
// out over frozen sinks, arming a timer pushes a command onto a fixed-capacity
// ring. This section prints that number — allocations per op — for the same nine
// runtime metrics whose `[med3]` values the gate thresholds, in the same run and at
// the same scale.
//
// It is a **separate instrumented pass**, and none of it is comparable with the
// other two sections:
//
//   * **A counting allocator is a change to the thing being measured**, which is
//     why this section exists at all instead of being folded into `[pct]` (that
//     was the deliberate omission until now). Every allocation in a counted path
//     goes through a second vtable with a counter write behind it, so a *duration*
//     measured here would be measuring the instrument. These runs therefore print
//     no duration: a count, and the op count it is divided by. Nothing from this
//     pass is mixed into the latency samples, and the timed harnesses above are
//     untouched — each metric below has its own copy of that harness's op loop,
//     call for call and assertion for assertion, and the counts come from the copy.
//   * **The counting allocator goes where the code under test holds one.** The
//     wheel (`schedule` allocates the node), the object pool and the worker
//     runtime (`spawn` allocates the heap handle, one per worker; the mailbox
//     storage is inline, sized at comptime) hold an allocator, so their counts are
//     what the timed region really allocates through it. For `RingBuffer`,
//     `Mailbox`, `HotBus.publish`, `Sequencer` and the atomic reference the
//     operation takes no allocator at all: there is no path to allocate from, and
//     the zero is structural rather than measured. Both readings — a `1.00` and a
//     structural `0.00` — are the same numbers `src/runtime/alloc_contract_test.zig`
//     asserts *exactly*, with the same instrument, on the same operations; that
//     test is where the enforcement lives (it arms the allocator so an added
//     allocation is an error, not a number), and this section is where the numbers
//     are visible next to the timings they belong to. `Handle.send*` and `MpscRing`
//     are covered by that test but have no metric of their own in this suite, so
//     they have no row here.
//   * **Fixture is built before the snapshot**, never counted: the mailbox is
//     filled, the worker runtime is started, the wheel's map is left to grow as it
//     grows in the timed harness. Only the timed region's allocations are reported.
//   * **Reported, never gated.** No `[alloc]` number reaches `bench-results.json`,
//     no baseline holds an `alloc/op`, and `scripts/check-bench.sh` neither knows
//     these names nor thresholds them — the same rule the `[pct]` rows follow, and
//     for the same reason: there is no cross-host spread for them yet.
//
// Cost: one extra pass over the runtime group's op loops, measured and printed by
// `reportSectionCost` at the end of the section (~0.16 s at today's scales). What
// dominates it is the op counts the `[med3]` metrics use — the three 10M-op loops,
// `Worker spawn+join`'s 1000 thread lifecycles — not the counting itself. Two of
// the nine metrics pay a counted allocation per op, `TimerWheel` (one node per
// scheduled timer) and `Worker spawn+join` (a handle per spawn); that is the fact
// their rows report, not a cost the other seven avoid.
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
        const name = "Mailbox full-path x10M";
        const ms = try median3(name, benchMailboxFull, .{ io, 10_000_000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} rejects/s)\n", .{ name, ms, 10_000_000.0 / ms * 1000.0 });
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
    {
        const name = "Worker spawn+join x1K";
        const ms = try median3(name, benchWorkerSpawnJoin, .{ io, 1000 });
        try results.append(a, .{ .name = name, .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} cycles/s)\n", .{ name, ms, 1000.0 / ms * 1000.0 });
    }

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
    // latency table and outside it: its runs are counted, never timed, and nothing
    // it produces is comparable with `[med3]` or `[pct]`. Same nine runtime
    // metrics, same scales, same op loops. A row that reads other than 0.00 is a
    // finding rather than a bug in the harness — the two that do (`TimerWheel`,
    // `Worker spawn+join`) are both deliberate, both documented in
    // `src/runtime/alloc_contract_test.zig`, and both named in the lines below.
    std.debug.print("\n-- Allocation counts per op (instrumented pass: counts only, no timing) --\n", .{});
    std.debug.print("  A counting allocator sits in the path, so these runs are *not* timed and nothing here is\n  comparable with the `[med3]` or `[pct]` numbers above. Fixture is built before the\n  snapshot; the op loops are copies of the timed ones. Observation only, never gated.\n", .{});
    const alloc_section_t0 = now();
    allocLine("atomic RMW x10M", try allocAtomicRmw(10_000_000), "");
    allocLine("RingBuffer SPSC x1M", try allocRingBuffer(1_000_000), "");
    allocLine("Mailbox post+drain x1M", try allocMailbox(io, 1_000_000), "");
    allocLine("Mailbox full-path x10M", try allocMailboxFull(io, 10_000_000), "");
    allocLine("TimerWheel x100K", try allocTimerWheel(100_000), "one node per scheduled timer: `Wheel.schedule` allocates the node by contract, `cancel`/`advance` do not");
    allocLine("HotBus 8sub x1M", try allocHotBus(1_000_000), "");
    allocLine("ObjectPool x1M", try allocObjectPool(1_000_000), "");
    allocLine("Sequencer x10M", try allocSequencer(10_000_000), "");
    allocLine("Worker spawn+join x1K", try allocWorkerSpawnJoin(io, 1_000), "one heap handle per worker (`spawn`), plus the worker list's amortized growth; `stop`/`join` allocate nothing");
    reportSectionCost("alloc", alloc_section_t0, 9);

    // Emit bench-results.json for CI baseline tracking
    // (github-action-benchmark `customSmallerIsBetter` format); `value` is the
    // median of the three samples each metric was measured with (`median3`).
    // The percentile section above deliberately writes nothing here: a metric the
    // baselines do not know is a WARN in `check-bench.sh`, and adding 40 such
    // entries per run (10 metrics x 4 quantiles) would train its reader to skip
    // warnings. `check-bench.sh` sees the `[pct]` lines in its own log instead,
    // and the `[alloc]` rows never reach a file at all.
    const json = try std.json.Stringify.valueAlloc(a, results.items, .{});
    const file = try std.Io.Dir.cwd().createFile(io, "bench-results.json", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, json);

    std.debug.print("\nDone. Results written to bench-results.json\n", .{});
}
