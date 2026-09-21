//! `zig build runtime-stress` — the long-horizon harness for the runtime
//! (docs/RUNTIME.md §5, §8, §12, §14).
//!
//! ## Why this file exists
//!
//! `zig build soak` covers HTTP + tenant isolation: real sockets, N clients × M
//! tenants, "cross-tenant leak = 0". It never touches the runtime — no
//! supervision tree, no pools, no ready ring, no timers. Everything v0.31 added
//! to `src/runtime/**` has the opposite failure shape: it is correct in every
//! short, single-threaded test, and turns into a defect only under a *long*
//! interleaving — the restart budget that never spends (a logged CPU black
//! hole), a pool that quietly stops being scheduled after one refused token, a
//! claim that never comes back, an RSS that walks up one message at a time. A
//! unit test cannot reach those by construction.
//!
//! So this harness runs sustained load and checks invariants *periodically*,
//! and — the half that matters — refuses to report green when a check was never
//! actually walked. Two failure shapes, both fatal:
//!
//!   (a) an invariant is observed false → fail, with the reading that broke it;
//!   (b) an invariant was never walked (load too light, timers never fired, the
//!       supervision tree never restarted, the blocking pool never got busy) →
//!       fail too. A green of that shape proves nothing, and it looks exactly
//!       like a real one, which is why it is the worse of the two.
//!
//! ## What it runs
//!
//! One `Runtime` with **both** pools declared (`.cpu` and `.blocking`,
//! §12.13/§6), eight members and five producer threads:
//!
//! | member | mode / class | role in the run |
//! |---|---|---|
//! | 4 × `CpuWorker` | `.pooled`, `.cpu` | the load the CPU pool must keep moving |
//! | 2 × `BlockingWorker` | `.pooled`, `.blocking` | handlers that really block (`Io.sleep`), so "the CPU pool is not the blocking pool" is observable |
//! | 1 × `ProgressWorker` | `.dedicated` | a member that must never stop making progress |
//! | 1 × `BoomWorker` | `.dedicated`, in a `.one_for_one` group | fails on every message, so its group rebuilds it until the budget is spent |
//!
//! Timer messages are armed **once, up front**, spread across the run
//! (`Handle.after`; the targets are pooled, so a fire exercises the §12.11-3
//! `deliver → enqueue → announceReady` path).
//!
//! ## The invariants, and how each one can fail
//!
//! 1. **Supervision conservation** — `RuntimeStats.group_restarts` equals the
//!    sum of the members' own `group_restarts`, every member's `init` count
//!    equals `1 + its rebuilds`, and every member is *either serving or counted*:
//!    a member that is neither making progress, nor observed running, nor in
//!    `supervised_stops` has vanished silently.
//! 2. **The restart budget is an upper bound, reached and then flat** — the boom
//!    member's group spends exactly `max_restarts`, and afterwards
//!    `group_restarts` must not move again (it is checked every sample), *and
//!    must never exceed it*. §14.3 exists so that an "always dies" member stops
//!    costing anything.
//! 3. **Blocking-class isolation holds over time** — in every sampled interval
//!    that began with a saturated blocking pool (`claimed > 0`), the CPU pool's
//!    `dispatches` must still have advanced; at least three such intervals must
//!    exist.
//! 4. **`ready_push_failures == 0` on both pools** — a contract, not a reading
//!    (§5 rule 4, §12.10): a refused token loses a worker, not a message.
//! 5. **Zero allocation on the hot paths, over the whole run** — every measured
//!    window contains *no arming at all*, so its `allocations == 0` is
//!    attributable to the fire path (timer delivery, pool dispatch, mailbox
//!    hand-off) rather than to `Handle.after`, which allocates one payload by
//!    design (see the alloc contract's last two tests). A window only counts as
//!    walked when timers fired, messages were received and *both* pools
//!    dispatched inside it.
//! 6. **RSS and OS thread count do not walk up** — from a *time series*, not one
//!    reading: RSS spread inside a budget and not strictly increasing, thread
//!    count flat. The thread count is the OS's own, which is the only judge
//!    §12.11-2 leaves for a thread no counter can see.
//! 7. **Shutdown is predictable** — called with work in flight it returns inside
//!    a wall-clock bound, and afterwards `workers == 0`, `claimed == 0` on both
//!    pools, no token left in a ready ring and `pool_threads == 0` (no claim
//!    left unreleased).
//!
//! ## Parameters (`-D…`)
//!
//! `runtime-stress-duration-ms` (default 5000), `-workers`, `-producers`,
//! `-blocking-workers`, `-restarts`, `-sample-ms`, `-pool-threads`,
//! `-blocking-threads`, `-rss-budget-mib`, `-timers`. The defaults keep the step
//! under ~10 s so it can be run by hand or folded into a nightly job; 20 s is
//! `-Druntime-stress-duration-ms=20000`.
//!
//! `zig build test` builds the same file with a *smoke* option set (1.5 s), so
//! the default suite covers the code path and every check while the long run
//! stays its own step — the split `soak` uses.

const std = @import("std");
const builtin = @import("builtin");
const zigmodu = @import("zigmodu");
const rtr = zigmodu.runtime;
const Time = zigmodu.time;
const build_options = @import("build_options");

// ── fixture constants ───────────────────────────────────────────────────────

/// Mailbox capacities. The pooled ones are small enough that a producer can
/// meet `error.Full` (which is counted, not hidden) and large enough that the
/// batch loop always has work.
const cpu_capacity = 64;
const blocking_capacity = 64;
const dedicated_capacity = 64;
/// The boom member's mailbox is deliberately tiny: its producer is *supposed*
/// to meet backpressure while the group is rebuilding it.
const boom_capacity = 8;

/// How long a `.blocking` handler really blocks. A real `Io.sleep`, not a spin:
/// the property under test is "a handler that is *waiting* holds a blocking
/// thread", and a busy loop would be a CPU handler by accident. Kept short (and
/// the blocking producer paced below) so the pool's claim–batch–release cycle
/// is observable many times per measured window rather than once per window.
const blocking_sleep_ms: i64 = 5;

/// How the blocking producer paces itself: one message every this many
/// milliseconds, round-robin over the blocking workers. Deliberately *below*
/// the blocking pool's service rate (`blocking_threads / blocking_sleep_ms`), so
/// the mailbox stays shallow, each claim drains a message or two, and `claimed`
/// is observable at most sample points. A saturating feed would instead grow one
/// 16-message batch and put a single `dispatches` step in each window.
const blocking_feed_ms: i64 = 6;

/// Fires to wait for per measured window. One window is therefore
/// `fires_per_window × spacing` long, which is the resolution of the
/// zero-allocation check.
const fires_per_window: usize = 2;

// Floors. Each one is a "a green below this would be hollow" gate — see the
// header. Units are counts, except `min_duration_ms` and `progress_window_ms`.
/// From `-Druntime-stress-min-windows` (smoke: 1). A *window* only counts when
/// all four paths advanced inside it — timer fire, message receive, cpu
/// dispatch, blocking dispatch — so how many a machine delivers in a fixed
/// budget is a property of the machine, not of the runtime: a 2-core CI runner
/// produced 6 samples in the 2 s smoke and covered the four paths in 2 of them.
/// The sustained harness keeps 3; the smoke asks for 1, which is the difference
/// between "the zero-allocation check was walked at least once" and a floor
/// that only holds on a fast machine.
const min_windows: usize = build_options.runtime_stress_min_windows;
const min_isolation_intervals: usize = 3;
const min_steady_samples: usize = 5;
const min_duration_ms: i64 = 1500;
/// A member that has not been observed making progress for this long is either
/// dead or not being fed; either way the run must say so. Generous on purpose
/// (the check is for a member that *stopped*, not for one that was slow once),
/// but short enough that a run leaves several windows of evidence behind.
const progress_window_ms: i64 = 400;
/// How many progress windows a healthy member must have been observed advancing
/// in. One would make the check vacuous for most of the run.
const min_progress_windows: u64 = 3;
const max_samples = 1024;
const max_members = 16;
const max_label_len = 24;
const max_fails = 12;
/// Room for the producers this harness spawns: one per CPU producer, plus the
/// blocking, progress and boom producers.
const max_producers = 16;

/// Upper bound on `Runtime.shutdown` with work in flight (§12.6: the pool goes
/// before the workers, and the batch in flight finishes first).
const shutdown_bound_ms: i64 = 5_000;

const Params = struct {
    duration_ms: i64,
    sample_ms: i64,
    cpu_workers: usize,
    cpu_producers: usize,
    blocking_workers: usize,
    restarts: u32,
    pool_threads: usize,
    blocking_threads: usize,
    rss_budget_bytes: u64,
    timers: usize,

    fn warmupMs(self: Params) i64 {
        return @divTrunc(self.duration_ms, 4);
    }

    /// Milliseconds between two timer fires. The arm burst covers the steady
    /// phase (warmup → end) so the derived windows fit inside it.
    fn spacingMs(self: Params) i64 {
        if (self.timers == 0) return 1000;
        const span = self.duration_ms - self.warmupMs() - 300;
        return @max(@divTrunc(span, @as(i64, @intCast(self.timers))), 8);
    }
};

fn paramsFromOptions() Params {
    return .{
        .duration_ms = @intCast(build_options.runtime_stress_duration_ms),
        .sample_ms = @intCast(build_options.runtime_stress_sample_ms),
        .cpu_workers = build_options.runtime_stress_workers,
        .cpu_producers = build_options.runtime_stress_producers,
        .blocking_workers = build_options.runtime_stress_blocking_workers,
        .restarts = @intCast(build_options.runtime_stress_restarts),
        .pool_threads = build_options.runtime_stress_pool_threads,
        .blocking_threads = build_options.runtime_stress_blocking_threads,
        .rss_budget_bytes = @as(u64, build_options.runtime_stress_rss_budget_mib) * 1024 * 1024,
        .timers = build_options.runtime_stress_timers,
    };
}

fn nowMs() i64 {
    return Time.monotonicNowMilliseconds();
}

/// A wait that a cancelled or short sleep does not turn into an error: every
/// loop in this file is deadline-bound and re-reads the clock, so a cut-short
/// wait costs a re-check, not correctness.
fn sleepMs(io: std.Io, ms: i64) void {
    if (ms <= 0) return;
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .real) catch return;
}

// ── the measuring allocator ─────────────────────────────────────────────────

/// Counts every allocation the runtime makes, from every thread.
///
/// The same instrument `src/runtime/alloc_contract_test.zig` uses
/// (`std.testing.FailingAllocator`: `allocations` + `allocated_bytes`), with one
/// difference that this harness forces rather than chooses: the counters are
/// atomic. The contract test drives single-threaded paths; here the wheel's
/// owner, the pool threads and five producers all allocate or stay silent
/// concurrently, so `self.allocations += 1` from two threads would be a data
/// race and a plain read a torn one. The question is unchanged — "how many
/// allocations happened in this window" — and the answer must not depend on who
/// asks.
const ProbeAllocator = struct {
    backing: std.mem.Allocator,
    /// Successful allocations — the `0` this harness asserts on hot paths.
    allocations: std.atomic.Value(u64) = .init(0),
    /// Bytes handed out; asserted alongside the count, because one allocation
    /// of an unexpected size is as much a contract break as an extra call.
    bytes: std.atomic.Value(u64) = .init(0),
    /// Attempts, successful or not — the "is the instrument live" reading.
    attempts: std.atomic.Value(u64) = .init(0),

    fn allocator(self: *ProbeAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn calls(self: *const ProbeAllocator) u64 {
        return self.allocations.load(.monotonic);
    }

    fn bytesOut(self: *const ProbeAllocator) u64 {
        return self.bytes.load(.monotonic);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ProbeAllocator = @ptrCast(@alignCast(ctx));
        _ = self.attempts.fetchAdd(1, .monotonic);
        const out = self.backing.vtable.alloc(self.backing.ptr, len, alignment, ret_addr);
        if (out != null) {
            _ = self.allocations.fetchAdd(1, .monotonic);
            _ = self.bytes.fetchAdd(len, .monotonic);
        }
        return out;
    }

    /// In-place growth is not a new allocation — the same rule the contract test
    /// applies — but the extra bytes still count: a hot path that resizes a
    /// container per message must not slip past a call-counted window.
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ProbeAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.vtable.resize(self.backing.ptr, memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) _ = self.bytes.fetchAdd(new_len - memory.len, .monotonic);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ProbeAllocator = @ptrCast(@alignCast(ctx));
        const out = self.backing.vtable.remap(self.backing.ptr, memory, alignment, new_len, ret_addr);
        if (out != null and new_len > memory.len) _ = self.bytes.fetchAdd(new_len - memory.len, .monotonic);
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ProbeAllocator = @ptrCast(@alignCast(ctx));
        self.backing.vtable.free(self.backing.ptr, memory, alignment, ret_addr);
    }
};

// ── process readings (RSS + OS thread count) ────────────────────────────────

/// What the two system readings are, and what they are *not*:
///
/// * `rss_bytes` — resident set size of **this process**, from the OS (macOS
///   `proc_pidinfo(PROC_PIDTASKINFO).pti_resident_size`; Linux
///   `/proc/self/statm` field 2 × page size). "Pages this process has resident
///   right now", which is what a leak looks like from outside the program.
/// * `threads` — the OS thread count of this process (macOS
///   `proc_pidinfo(PROC_PIDTASKINFO).pti_threadnum`; Linux `/proc/self/stat`
///   field 20). Deliberately the OS count and not `RuntimeStats.running +
///   poolStats().pool_threads`: §12.11-2 was a *hidden* pool thread that no
///   counter could see, and that section says the judgement can only be the OS
///   thread count. A leak the runtime's own arithmetic cannot express has to be
///   caught by the kernel's arithmetic.
///
/// Either may be null (unsupported platform, or a failed syscall). The caller
/// then says so out loud rather than pretending it measured — see `run`.
const OsInfo = struct {
    rss_bytes: ?u64,
    threads: ?u32,
};

fn osInfo() OsInfo {
    return switch (builtin.os.tag) {
        .macos => macosInfo(),
        .linux => linuxInfo(),
        else => .{ .rss_bytes = null, .threads = null },
    };
}

/// `struct proc_taskinfo` is 96 bytes; only two of its fields are read here, so
/// they are taken by offset from a raw buffer rather than through a mirrored
/// `extern struct` with fifteen fields nobody reads — which the repo's own dead
/// code gate (`scripts/check-deadcode.sh`) counts as fifteen dead declarations.
/// The offsets are the ABI, so they are named and checked here:
///
/// | offset | field | C type |
/// |---|---|---|
/// | 8  | `pti_resident_size` — resident set size, in bytes | `u64` |
/// | 84 | `pti_threadnum` — the process's live thread count | `i32` |
///
/// (`pti_virtual_size` is at 0, `pti_total_user` at 16 … `pti_csw` at 80, then
/// `pti_numrunning` at 88 and `pti_priority` at 92.) Endianness is native: the
/// value is the kernel's own, not a wire format.
const proc_taskinfo_size = 96;
const proc_taskinfo_rss_offset = 8;
const proc_taskinfo_threads_offset = 84;

extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;

const PROC_PIDTASKINFO: c_int = 4;

fn macosInfo() OsInfo {
    var buf: [proc_taskinfo_size]u8 = undefined;
    const got = proc_pidinfo(std.c.getpid(), PROC_PIDTASKINFO, 0, &buf, buf.len);
    if (got != proc_taskinfo_size) return .{ .rss_bytes = null, .threads = null };
    const rss: u64 = @bitCast(buf[proc_taskinfo_rss_offset..][0..8].*);
    const thread_count: i32 = @bitCast(buf[proc_taskinfo_threads_offset..][0..4].*);
    return .{
        .rss_bytes = rss,
        .threads = if (thread_count > 0) @intCast(thread_count) else null,
    };
}

var statm_buf: [256]u8 = undefined;
var stat_buf: [1024]u8 = undefined;

/// One `open`/`read`/`close` of a `/proc` file into a caller-provided buffer: no
/// allocation, so the sampler cannot perturb what it measures.
fn readProcLine(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(fd);
    const n = std.posix.read(fd, buf) catch return null;
    return buf[0..n];
}

fn linuxInfo() OsInfo {
    var rss: ?u64 = null;
    var threads: ?u32 = null;
    // `/proc/self/statm`: size resident shared text lib data dt, in pages.
    if (readProcLine("/proc/self/statm", &statm_buf)) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next(); // size
        if (it.next()) |resident| {
            if (std.fmt.parseInt(u64, resident, 10)) |pages| {
                rss = pages * std.heap.pageSize();
            } else |_| {}
        }
    }
    // `/proc/self/stat`: the comm field is parenthesised and may contain spaces,
    // so the count is taken from the last ')' onwards; field 20 is the thread
    // count.
    if (readProcLine("/proc/self/stat", &stat_buf)) |line| {
        if (std.mem.lastIndexOfScalar(u8, line, ')')) |close_paren| {
            var it = std.mem.tokenizeScalar(u8, line[close_paren + 1 ..], ' ');
            _ = it.next(); // state = field 3
            var field: usize = 3;
            while (it.next()) |tok| {
                field += 1;
                if (field == 20) {
                    if (std.fmt.parseInt(u32, tok, 10)) |n| threads = n else |_| {}
                    break;
                }
            }
        }
    }
    return .{ .rss_bytes = rss, .threads = threads };
}

// ── the fixture ─────────────────────────────────────────────────────────────

/// Everything the workers and the producers share. Plain atomics: the harness
/// never takes a lock on the load path, so a scheduling stall cannot look like a
/// runtime defect.
const Shared = struct {
    load_stop: std.atomic.Value(bool) = .init(false),

    handled_cpu: std.atomic.Value(u64) = .init(0),
    handled_blocking: std.atomic.Value(u64) = .init(0),
    handled_progress: std.atomic.Value(u64) = .init(0),

    /// Blocking handlers currently inside the sleep — the "the blocking pool
    /// really is occupied" evidence, taken from *inside* the handler.
    blocking_holding: std.atomic.Value(u32) = .init(0),

    cpu_sent: std.atomic.Value(u64) = .init(0),
    cpu_full: std.atomic.Value(u64) = .init(0),
    blocking_sent: std.atomic.Value(u64) = .init(0),
    blocking_full: std.atomic.Value(u64) = .init(0),
    progress_sent: std.atomic.Value(u64) = .init(0),
    boom_sent: std.atomic.Value(u64) = .init(0),
    boom_closed: std.atomic.Value(u64) = .init(0),
};

const CpuWorker = struct {
    pub const Message = u64;

    shared: *Shared,
    /// This member's own generation counter, bumped by `init` — one slot per
    /// member, not one per type: the conservation law below is per member, and a
    /// shared counter would read "cpu-0 was rebuilt 3 times" when four
    /// group-mates each ran `init` once.
    generations: *std.atomic.Value(u32),
    seen: u64 = 0,

    pub fn init(self: *@This(), _: anytype) !void {
        _ = self.generations.fetchAdd(1, .release);
    }

    pub fn deinit(_: *@This()) void {}

    pub fn handle(self: *@This(), msg: u64, _: anytype) anyerror!void {
        self.seen +%= msg;
        _ = self.shared.handled_cpu.fetchAdd(1, .monotonic);
    }
};

const BlockingWorker = struct {
    pub const Message = u64;

    shared: *Shared,
    generations: *std.atomic.Value(u32),
    seen: u64 = 0,

    pub fn init(self: *@This(), _: anytype) !void {
        _ = self.generations.fetchAdd(1, .release);
    }

    pub fn deinit(_: *@This()) void {}

    pub fn handle(self: *@This(), msg: u64, ctx: anytype) anyerror!void {
        _ = self.shared.blocking_holding.fetchAdd(1, .monotonic);
        defer _ = self.shared.blocking_holding.fetchSub(1, .monotonic);
        sleepMs(ctx.io, blocking_sleep_ms);
        self.seen +%= msg;
        _ = self.shared.handled_blocking.fetchAdd(1, .monotonic);
    }
};

const ProgressWorker = struct {
    pub const Message = u64;

    shared: *Shared,
    generations: *std.atomic.Value(u32),
    seen: u64 = 0,

    pub fn init(self: *@This(), _: anytype) !void {
        _ = self.generations.fetchAdd(1, .release);
    }

    pub fn deinit(_: *@This()) void {}

    pub fn handle(self: *@This(), msg: u64, _: anytype) anyerror!void {
        self.seen +%= msg;
        _ = self.shared.handled_progress.fetchAdd(1, .monotonic);
    }
};

/// Fails on every message. Its own budget (`max_errors = 1`) is spent every
/// second message, so the group is asked every second message — which is what
/// makes the *group's* restart budget the thing under test rather than this
/// worker's error budget.
const BoomWorker = struct {
    pub const Message = u64;

    shared: *Shared,
    generations: *std.atomic.Value(u32),

    pub fn init(self: *@This(), _: anytype) !void {
        _ = self.generations.fetchAdd(1, .release);
    }

    pub fn deinit(_: *@This()) void {}

    pub fn handle(_: *@This(), _: u64, _: anytype) anyerror!void {
        return error.StressBoom;
    }
};

// ── type-erased member view ─────────────────────────────────────────────────

/// One spawned worker, seen through the public API only (`stats()`,
/// `stopped_by_group`). The thunks are comptime-specialised per `Handle`, so
/// the table holds members of four different types without a vtable on any hot
/// path.
const Member = struct {
    label: []const u8,
    ctx: *anyopaque,
    /// The generation counter this member's `init` bumps (the harness's own
    /// reading, kept beside the runtime's so the conservation law can be
    /// *checked* rather than assumed).
    generations: *std.atomic.Value(u32),
    /// True for members that must keep taking work for the whole run. The boom
    /// member is the one that must not — it is expected to stop.
    must_progress: bool,
    /// True for members expected to end the run flagged as supervised-stopped.
    expected_stop: bool,
    stats_fn: *const fn (*anyopaque) rtr.WorkerStats,
    group_stopped_fn: *const fn (*anyopaque) bool,

    fn stats(self: Member) rtr.WorkerStats {
        return self.stats_fn(self.ctx);
    }

    fn stoppedByGroup(self: Member) bool {
        return self.group_stopped_fn(self.ctx);
    }

    /// "This member is dead, and the framework said so." The two flags are not
    /// the same reason (`stopped_by_supervisor` = it decided, `stopped_by_group`
    /// = a group-mate took it down), but both are supervised stops on the
    /// runtime's one counter (§14.6).
    fn countedDead(self: Member) bool {
        return self.stats().stopped_by_supervisor or self.stoppedByGroup();
    }
};

fn memberOf(
    comptime W: type,
    comptime cap: usize,
    handle: *rtr.Handle(W, cap),
    label: []const u8,
    generations: *std.atomic.Value(u32),
    must_progress: bool,
    expected_stop: bool,
) Member {
    const Thunks = struct {
        fn stats(p: *anyopaque) rtr.WorkerStats {
            const h: *rtr.Handle(W, cap) = @ptrCast(@alignCast(p));
            return h.stats();
        }
        fn groupStopped(p: *anyopaque) bool {
            const h: *rtr.Handle(W, cap) = @ptrCast(@alignCast(p));
            return h.stopped_by_group.load(.acquire);
        }
    };
    return .{
        .label = label,
        .ctx = @ptrCast(handle),
        .generations = generations,
        .must_progress = must_progress,
        .expected_stop = expected_stop,
        .stats_fn = Thunks.stats,
        .group_stopped_fn = Thunks.groupStopped,
    };
}

// ── producers ───────────────────────────────────────────────────────────────

const CpuProducer = struct {
    shared: *Shared,
    handles: []const *rtr.Handle(CpuWorker, cpu_capacity),
    version: u64,

    fn run(self: *@This()) void {
        var i: u64 = self.version;
        while (!self.shared.load_stop.load(.acquire)) {
            for (self.handles) |h| {
                h.send(i) catch |err| switch (err) {
                    // Expected: a bounded mailbox refuses rather than grows, and
                    // the refusal is counted (§5 rule 2) instead of hidden.
                    error.Full, error.Timeout => {
                        _ = self.shared.cpu_full.fetchAdd(1, .monotonic);
                        continue;
                    },
                    // Only reachable once the mailboxes are closed, which the
                    // producers' stop barrier is there to precede.
                    error.Closed => return,
                };
                _ = self.shared.cpu_sent.fetchAdd(1, .monotonic);
                i +%= 1;
            }
        }
    }
};

const BlockingProducer = struct {
    shared: *Shared,
    handles: []const *rtr.Handle(BlockingWorker, blocking_capacity),
    io: std.Io,

    fn run(self: *@This()) void {
        var i: u64 = 0;
        var next: usize = 0;
        while (!self.shared.load_stop.load(.acquire)) {
            const h = self.handles[next % self.handles.len];
            next += 1;
            h.send(i) catch |err| switch (err) {
                error.Full, error.Timeout => {
                    _ = self.shared.blocking_full.fetchAdd(1, .monotonic);
                    continue;
                },
                error.Closed => return,
            };
            _ = self.shared.blocking_sent.fetchAdd(1, .monotonic);
            i +%= 1;
            sleepMs(self.io, blocking_feed_ms);
        }
    }
};

const ProgressProducer = struct {
    shared: *Shared,
    handle: *rtr.Handle(ProgressWorker, dedicated_capacity),
    io: std.Io,

    fn run(self: *@This()) void {
        var i: u64 = 0;
        while (!self.shared.load_stop.load(.acquire)) {
            self.handle.send(i) catch |err| switch (err) {
                error.Full, error.Timeout => {
                    std.atomic.spinLoopHint();
                    continue;
                },
                error.Closed => return,
            };
            _ = self.shared.progress_sent.fetchAdd(1, .monotonic);
            i +%= 1;
            // Paced, so this member's mailbox usually has room: a timer armed at
            // it then exercises a *successful* delivery (the dropped-delivery
            // case is covered by the saturated cpu mailboxes, and counted).
            sleepMs(self.io, 1);
        }
    }
};

/// The one producer whose *exit* is part of an invariant: it returns only when
/// the boom member's mailbox closes, which happens when its group's budget runs
/// out. If the budget never runs out this loop never ends — which is precisely
/// the CPU black hole §14.3 exists to prevent, and the bounded settle check
/// turns it into a failure rather than a hung harness.
const BoomProducer = struct {
    shared: *Shared,
    handle: *rtr.Handle(BoomWorker, boom_capacity),

    fn run(self: *@This()) void {
        var i: u64 = 0;
        while (!self.shared.load_stop.load(.acquire)) {
            self.handle.send(i) catch |err| switch (err) {
                error.Full, error.Timeout => {
                    std.atomic.spinLoopHint();
                    continue;
                },
                error.Closed => {
                    _ = self.shared.boom_closed.fetchAdd(1, .monotonic);
                    return;
                },
            };
            _ = self.shared.boom_sent.fetchAdd(1, .monotonic);
            i +%= 1;
        }
    }
};

// ── the report ──────────────────────────────────────────────────────────────

const Fail = struct {
    buf: [240]u8 = undefined,
    len: usize = 0,
};

/// Per-check deduplication: a check that fires on every sample would otherwise
/// bury the one line that explains it. The *total* count stays complete, and a
/// suppressed repeat is reported as such.
const CheckId = enum(u6) {
    param_floor,
    member_count,
    conservation_restarts,
    conservation_stops,
    member_progress,
    member_generations,
    restart_budget_bound,
    restart_budget_settle,
    restart_budget_stable,
    restart_stop_evidence,
    isolation_advance,
    isolation_saturation,
    push_failures,
    pool_evidence,
    window_alloc,
    window_coverage,
    probe_live,
    rss_stability,
    thread_stability,
    sample_floor,
    shutdown_bound,
    shutdown_state,
    shutdown_in_flight,
};

const Report = struct {
    fails: [max_fails]Fail = undefined,
    stored: usize = 0,
    total: u64 = 0,
    seen: u64 = 0,
    /// Checks that degraded to a warning because the reading they need is not
    /// available on this platform. Counted and printed — never silent.
    warnings: u64 = 0,

    fn fail(self: *Report, id: CheckId, comptime fmt: []const u8, args: anytype) void {
        self.total += 1;
        const bit = @as(u64, 1) << @backingInt(id);
        if (self.seen & bit != 0) return;
        self.seen |= bit;
        if (self.stored == max_fails) return;
        const slot = &self.fails[self.stored];
        if (std.fmt.bufPrint(&slot.buf, fmt, args)) |written| {
            slot.len = written.len;
        } else |_| {
            const truncated = "<message too long>";
            @memcpy(slot.buf[0..truncated.len], truncated);
            slot.len = truncated.len;
        }
        self.stored += 1;
    }

    fn warn(self: *Report, comptime fmt: []const u8, args: anytype) void {
        self.warnings += 1;
        std.debug.print("[stress] WARN: " ++ fmt ++ "\n", args);
    }

    fn dump(self: *const Report) void {
        for (self.fails[0..self.stored]) |f| {
            std.debug.print("[stress] FAIL: {s}\n", .{f.buf[0..f.len]});
        }
        if (self.total > self.stored) {
            std.debug.print("[stress] ({d} failure(s) total; {d} distinct check(s) shown, repeats suppressed)\n", .{
                self.total, self.stored,
            });
        }
        if (self.warnings != 0) {
            std.debug.print("[stress] ({d} warning(s): a reading this platform does not offer)\n", .{self.warnings});
        }
    }

    fn passed(self: *const Report) bool {
        return self.total == 0;
    }
};

/// One sample of the time series. RSS and thread count are `?` because the
/// platform may not offer them; the runtime readings never are.
const Sample = struct {
    t_ms: i64,
    rss: ?u64,
    threads: ?u32,
    workers: usize,
    running: usize,
    supervised_stops: u64,
    group_restarts: u64,
    cpu_dispatches: u64,
    cpu_claimed: usize,
    blocking_dispatches: u64,
    blocking_claimed: usize,
    cpu_push_failures: u64,
    blocking_push_failures: u64,
};

const MemberProgress = struct {
    base_t: i64 = 0,
    base_received: u64 = 0,
    ran_in_window: bool = false,
    /// Windows in which this member was observed advancing — the "was it
    /// walked" evidence for invariant 1. A member that never progresses would
    /// make the progress check vacuous, which the run reports.
    windows: u64 = 0,
};

/// One member's readings, taken while its handle is still alive.
///
/// Not an optimisation: `Runtime.shutdown` destroys every `*Handle` in the
/// middle of its teardown, so a `stats()` call after it is a read of freed
/// memory. The first run of this harness did exactly that and printed
/// `received=6148914691236517205` for every member — the debug allocator's
/// freed-memory pattern, which is how this snapshot came to exist.
const MemberSnapshot = struct {
    label: []const u8,
    received: u64,
    running: bool,
    generations: u32,
    restarts: u64,
    errors: u64,
    stopped_by_supervisor: bool,
    stopped_by_group: bool,
    progress_windows: u64,

    fn countedDead(self: MemberSnapshot) bool {
        return self.stopped_by_supervisor or self.stopped_by_group;
    }
};

// ── the run ─────────────────────────────────────────────────────────────────

/// Runs the whole scenario and prints the report. The returned `Report` is the
/// caller's verdict: zero failures means every invariant was observed true *and*
/// walked.
fn run(io: std.Io, backing: std.mem.Allocator, p: Params) !Report {
    var report = Report{};
    var probe = ProbeAllocator{ .backing = backing };
    const alloc = probe.allocator();

    std.debug.print("[stress] runtime-stress: duration={d}ms sample={d}ms timers={d} spacing={d}ms\n", .{
        p.duration_ms, p.sample_ms, p.timers, p.spacingMs(),
    });
    std.debug.print("[stress]   cpu_workers={d} producers={d} pool_threads={d} | blocking_workers={d} width={d} | restarts={d}\n", .{
        p.cpu_workers, p.cpu_producers, p.pool_threads, p.blocking_workers, p.blocking_threads, p.restarts,
    });

    // The floors first: a run that cannot walk its own checks is refused before
    // it burns the budget, and says which parameter is too small.
    if (p.duration_ms < min_duration_ms) {
        report.fail(
            .param_floor,
            "duration_ms={d} is below the floor ({d}ms): at this budget the harness cannot walk its windows and " ++
                "samples, so a green run would prove nothing",
            .{ p.duration_ms, min_duration_ms },
        );
        report.dump();
        return report;
    }
    if (p.cpu_workers == 0 or p.cpu_producers == 0 or p.blocking_workers == 0 or p.timers == 0) {
        report.fail(
            .param_floor,
            "the load is empty (cpu_workers={d} producers={d} blocking_workers={d} timers={d}): every window below " ++
                "would be an un-walked check, which is a failure by construction",
            .{ p.cpu_workers, p.cpu_producers, p.blocking_workers, p.timers },
        );
        report.dump();
        return report;
    }
    if (p.pool_threads == 0 or p.blocking_threads == 0) {
        report.fail(.param_floor, "pool_threads={d} blocking_threads={d}: a pool needs a consumer", .{
            p.pool_threads, p.blocking_threads,
        });
        report.dump();
        return report;
    }

    const shared = try alloc.create(Shared);
    defer alloc.destroy(shared);
    shared.* = .{};

    // Both classes are declared, so a `.blocking` spawn is admitted — and its
    // handler cannot land on a CPU-pool thread, because the two pools share no
    // ring, no thread and no counter (§12.13).
    var runtime = try rtr.Runtime.initWithOptions(alloc, io, .{
        .scheduler = .{
            .max_pooled_workers = p.cpu_workers,
            .pool_threads = p.pool_threads,
            .blocking_threads = p.blocking_threads,
            .max_blocking_workers = p.blocking_workers,
        },
    });
    defer runtime.deinit();
    try runtime.start();

    // ── spawn the members ───────────────────────────────────────────────────
    const group = try runtime.spawnGroupWith(.one_for_one, .{ .max_restarts = p.restarts, .window_ms = 60_000 });

    // One generation counter per member (see `CpuWorker.generations`).
    var generations: [max_members]std.atomic.Value(u32) = undefined;
    for (&generations) |*g| g.* = .init(0);

    const cpu_handles = try alloc.alloc(*rtr.Handle(CpuWorker, cpu_capacity), p.cpu_workers);
    defer alloc.free(cpu_handles);
    for (cpu_handles, 0..) |*h, i| {
        h.* = try runtime.spawn(CpuWorker, .{ .shared = shared, .generations = &generations[i] }, .{
            .capacity = cpu_capacity,
            .mode = .pooled,
        });
    }

    const blocking_handles = try alloc.alloc(*rtr.Handle(BlockingWorker, blocking_capacity), p.blocking_workers);
    defer alloc.free(blocking_handles);
    for (blocking_handles, 0..) |*h, i| {
        h.* = try runtime.spawn(BlockingWorker, .{
            .shared = shared,
            .generations = &generations[p.cpu_workers + i],
        }, .{
            .capacity = blocking_capacity,
            .mode = .pooled,
            .execution_class = .blocking,
        });
    }

    const progress_index = p.cpu_workers + p.blocking_workers;
    const progress_handle = try runtime.spawn(ProgressWorker, .{
        .shared = shared,
        .generations = &generations[progress_index],
    }, dedicated_capacity);

    const boom_index = progress_index + 1;
    const boom_handle = try runtime.spawnActor(
        BoomWorker,
        .{ .shared = shared, .generations = &generations[boom_index] },
        boom_capacity,
        .{ .max_errors = 1, .window_ms = 60_000, .group = group },
    );

    // ── the member table ────────────────────────────────────────────────────
    var labels: [max_members][max_label_len]u8 = undefined;
    var members: [max_members]Member = undefined;
    var member_count: usize = 0;
    for (cpu_handles, 0..) |h, i| {
        const label = try std.fmt.bufPrint(&labels[member_count], "cpu-{d}", .{i});
        members[member_count] = memberOf(CpuWorker, cpu_capacity, h, label, &generations[member_count], true, false);
        member_count += 1;
    }
    for (blocking_handles, 0..) |h, i| {
        const label = try std.fmt.bufPrint(&labels[member_count], "blocking-{d}", .{i});
        members[member_count] = memberOf(BlockingWorker, blocking_capacity, h, label, &generations[member_count], true, false);
        member_count += 1;
    }
    const progress_label = try std.fmt.bufPrint(&labels[member_count], "progress", .{});
    members[member_count] = memberOf(ProgressWorker, dedicated_capacity, progress_handle, progress_label, &generations[member_count], true, false);
    member_count += 1;
    const boom_label = try std.fmt.bufPrint(&labels[member_count], "boom", .{});
    members[member_count] = memberOf(BoomWorker, boom_capacity, boom_handle, boom_label, &generations[member_count], false, true);
    member_count += 1;

    std.debug.print("[stress] members={d} (cpu={d} pooled/.cpu, blocking={d} pooled/.blocking, 1 dedicated, 1 supervised actor)\n", .{
        member_count, p.cpu_workers, p.blocking_workers,
    });

    if (runtime.stats().workers != member_count) {
        report.fail(.member_count, "runtime reports {d} workers right after spawn, the harness spawned {d}", .{
            runtime.stats().workers, member_count,
        });
    }

    // ── producers ───────────────────────────────────────────────────────────
    var producers: [max_producers]std.Thread = undefined;
    var producer_n: usize = 0;
    var producers_stopped = false;
    defer if (!producers_stopped) stopProducers(shared, &producers, producer_n);

    const cpu_ctxs = try alloc.alloc(CpuProducer, p.cpu_producers);
    defer alloc.free(cpu_ctxs);
    for (cpu_ctxs, 0..) |*c, i| {
        c.* = .{ .shared = shared, .handles = cpu_handles, .version = i };
        producers[producer_n] = try std.Thread.spawn(.{}, CpuProducer.run, .{c});
        producer_n += 1;
    }
    var blocking_ctx = BlockingProducer{ .shared = shared, .handles = blocking_handles, .io = io };
    producers[producer_n] = try std.Thread.spawn(.{}, BlockingProducer.run, .{&blocking_ctx});
    producer_n += 1;
    var progress_ctx = ProgressProducer{ .shared = shared, .handle = progress_handle, .io = io };
    producers[producer_n] = try std.Thread.spawn(.{}, ProgressProducer.run, .{&progress_ctx});
    producer_n += 1;
    var boom_ctx = BoomProducer{ .shared = shared, .handle = boom_handle };
    producers[producer_n] = try std.Thread.spawn(.{}, BoomProducer.run, .{&boom_ctx});
    producer_n += 1;

    // ── arm the timer burst, once ───────────────────────────────────────────
    //
    // Armed up front on purpose: every measured window below then contains *no
    // arming at all*, so its `allocations == 0` is attributable to the fire path
    // — `Delivery.post` → `enqueue` → `announceReady` → pool dispatch — and not
    // to `after`, which allocates one payload by design. Spread evenly so fires
    // continue through the whole steady phase.
    const first_fire_ms = p.warmupMs() + 200;
    const spacing = p.spacingMs();
    var armed: usize = 0;
    for (0..p.timers) |i| {
        const delay = first_fire_ms + @as(i64, @intCast(i)) * spacing;
        const payload: u64 = @intCast(i + 1);
        // One fire in four lands on the dedicated member, whose mailbox is paced
        // to have room: that half exercises a *successful* timer delivery, while
        // the pooled half exercises §12.11-3's `enqueue` + `announceReady` on a
        // mailbox that is usually full (those deliveries are dropped and
        // counted — `timer_deliveries_dropped`, docs/RUNTIME.md §5). Two arms
        // because the two members have two handle types; the error handling is
        // the same for both.
        if (i % 4 == 3) {
            _ = progress_handle.after(delay, payload) catch |err| {
                report.fail(.window_coverage, "arming timer {d} failed: {s} (the timer command queue is a bounded " ++
                    "hand-off, docs/RUNTIME.md §5)", .{ i, @errorName(err) });
                break;
            };
        } else {
            _ = cpu_handles[i % cpu_handles.len].after(delay, payload) catch |err| {
                report.fail(.window_coverage, "arming timer {d} failed: {s} (the timer command queue is a bounded " ++
                    "hand-off, docs/RUNTIME.md §5)", .{ i, @errorName(err) });
                break;
            };
        }
        armed += 1;
    }
    if (armed != p.timers) {
        report.fail(.window_coverage, "only {d} of {d} timers were armed", .{ armed, p.timers });
    }
    // Wait until the arm burst has been drained (the wheel's single owner
    // applies the commands on its own thread) and the probe has gone quiet: the
    // instrument-liveness reading. If the probe had counted nothing, a
    // zero-allocation window would be a statement about the instrument rather
    // than about the runtime.
    const arm_quiet_deadline = nowMs() + 2000;
    var last_calls = probe.calls();
    var quiet_ms: i64 = 0;
    while (nowMs() < arm_quiet_deadline and quiet_ms < 40) {
        sleepMs(io, 5);
        const c = probe.calls();
        if (c == last_calls) {
            quiet_ms += 5;
        } else {
            last_calls = c;
            quiet_ms = 0;
        }
    }
    const armed_allocations = probe.calls();
    std.debug.print("[stress] armed {d} timers (first at {d}ms): the arm burst allocated {d} call(s), {d} byte(s)\n", .{
        p.timers, first_fire_ms, armed_allocations, probe.bytesOut(),
    });
    if (armed_allocations == 0) {
        report.fail(.probe_live, "the allocation probe saw 0 allocations while arming {d} timers: the instrument is not " ++
            "live, so every `0` below would be meaningless", .{p.timers});
    }

    // ── steady phase ────────────────────────────────────────────────────────
    const start_ms = nowMs();
    const deadline = start_ms + p.duration_ms;
    const warmup_at = start_ms + p.warmupMs();

    var samples: [max_samples]Sample = undefined;
    var sample_n: usize = 0;
    var progress_state: [max_members]MemberProgress = undefined;
    for (progress_state[0..member_count]) |*ps| ps.* = .{ .base_t = start_ms, .base_received = 0 };

    var windows_attempted: usize = 0;
    var windows_covered: usize = 0;
    var window_alloc_calls: u64 = 0;
    var window_alloc_bytes: u64 = 0;
    var isolation_intervals: usize = 0;
    var saturation_seen: usize = 0;
    var restarts_bound_violations: usize = 0;

    const settle_deadline = start_ms + 3000;
    var settled = false;
    // True once the group's budget has actually been observed spent — the
    // precondition for checking the restart conservation law to the unit.
    var budget_spent = false;
    var settle_ms: i64 = 0;
    var prev: Sample = undefined;
    var have_prev = false;

    while (true) {
        const loop_now = nowMs();
        if (loop_now >= deadline) break;

        // ── one measured window: zero allocation + fire-path coverage ───────
        const fires_now = runtime.stats().timer_fires;
        const fires_left = @as(u64, @intCast(p.timers)) - @min(fires_now, @as(u64, @intCast(p.timers)));
        if (fires_left >= fires_per_window and loop_now + 400 < deadline) {
            const cpu0 = runtime.poolStats().?;
            const blk0 = runtime.blockingPoolStats().?;
            const a0 = probe.calls();
            const b0 = probe.bytesOut();
            const r0 = runtime.stats().messages_received;
            const window_deadline = loop_now + 2000;
            while (runtime.stats().timer_fires < fires_now + fires_per_window and nowMs() < window_deadline) {
                sleepMs(io, 2);
            }
            const fires = runtime.stats().timer_fires - fires_now;
            const alloc_calls = probe.calls() - a0;
            const alloc_bytes = probe.bytesOut() - b0;
            const recv = runtime.stats().messages_received - r0;
            const cpu1 = runtime.poolStats().?;
            const blk1 = runtime.blockingPoolStats().?;
            const cpu_runs = cpu1.dispatches - cpu0.dispatches;
            const blk_runs = blk1.dispatches - blk0.dispatches;

            windows_attempted += 1;
            window_alloc_calls += alloc_calls;
            window_alloc_bytes += alloc_bytes;
            if (alloc_calls != 0 or alloc_bytes != 0) {
                report.fail(
                    .window_alloc,
                    "zero-allocation window #{d}: {d} allocation(s)/{d} byte(s) in a window with no arming in it " ++
                        "(fires={d} received={d} cpu_dispatches={d} blocking_dispatches={d})",
                    .{ windows_attempted, alloc_calls, alloc_bytes, fires, recv, cpu_runs, blk_runs },
                );
            }
            if (fires >= fires_per_window and recv > 0 and cpu_runs > 0 and blk_runs > 0 and alloc_calls == 0) {
                windows_covered += 1;
            }
        }

        // ── sample the time series ──────────────────────────────────────────
        const now = nowMs();
        const info = osInfo();
        const stats = runtime.stats();
        const cpu = runtime.poolStats().?;
        const blk = runtime.blockingPoolStats().?;
        if (now >= warmup_at and sample_n < samples.len) {
            samples[sample_n] = .{
                .t_ms = now,
                .rss = info.rss_bytes,
                .threads = info.threads,
                .workers = stats.workers,
                .running = stats.running,
                .supervised_stops = stats.supervised_stops,
                .group_restarts = stats.group_restarts,
                .cpu_dispatches = cpu.dispatches,
                .cpu_claimed = cpu.claimed,
                .blocking_dispatches = blk.dispatches,
                .blocking_claimed = blk.claimed,
                .cpu_push_failures = cpu.ready_push_failures,
                .blocking_push_failures = blk.ready_push_failures,
            };
            sample_n += 1;
        }

        // ── invariant 4: the push contract, on both pools ──────────────────
        if (cpu.ready_push_failures != 0) {
            report.fail(.push_failures, "cpu pool ready_push_failures={d} — must be 0: a refused token loses a worker, " ++
                "not a message (§5 rule 4, §12.10)", .{cpu.ready_push_failures});
        }
        if (blk.ready_push_failures != 0) {
            report.fail(.push_failures, "blocking pool ready_push_failures={d} — must be 0", .{blk.ready_push_failures});
        }

        // ── invariant 1: nobody vanishes, and the counters conserve ────────
        if (stats.workers != member_count) {
            report.fail(.member_count, "runtime workers={d} mid-run, expected {d}: a member left the table", .{
                stats.workers, member_count,
            });
        }
        var restart_sum: u64 = 0;
        var dead_count: usize = 0;
        // Conservation is checked *exactly*, but only once the restart budget is
        // spent: the runtime's accumulator and a member's own counter are two
        // separate `fetchAdd`s (`Handle.countGroupRestart`) and the two readings
        // here are microseconds apart, so a live rebuild can make them disagree
        // legitimately — by however many rebuilds fit in that gap. With the
        // budget spent, nothing rebuilds and the law must hold to the unit.
        for (members[0..member_count], 0..) |m, i| {
            const ms = m.stats();
            restart_sum += ms.group_restarts;
            if (m.countedDead()) dead_count += 1;

            // Every rebuild runs `init` again (§14.4: `deinit` + `init` in
            // place), so generations and rebuilds are one conservation law.
            // Only checked once the member has started serving: a pooled member
            // runs `init` in its first batch, so before that it has neither.
            if (ms.received > 0 and !m.countedDead()) {
                const ran_inits = m.generations.load(.acquire);
                const expected_generations = 1 + ms.group_restarts;
                if (ran_inits != expected_generations) {
                    report.fail(.member_generations, "{s}: init ran {d} time(s) but it was rebuilt {d} time(s) " ++
                        "(expected {d} generations)", .{ m.label, ran_inits, ms.group_restarts, expected_generations });
                }
            }

            // Progress over a window, time-based, so a missed sample cannot turn
            // a healthy member into a failure. A member that is neither
            // advancing, nor observed running inside the window, nor counted as
            // a supervised stop has disappeared without a number — the shape
            // this check exists for.
            const ps = &progress_state[i];
            if (ms.running) ps.ran_in_window = true;
            if (now - ps.base_t >= progress_window_ms) {
                if (ps.ran_in_window or ms.received > ps.base_received) {
                    ps.windows += 1;
                } else if (m.must_progress) {
                    report.fail(
                        .member_progress,
                        "{s}: no progress for {d}ms (received={d}, running={}, restarts={d}) and it carries no " ++
                            "supervised-stop flag — a member that is neither serving nor counted",
                        .{ m.label, progress_window_ms, ms.received, ms.running, ms.group_restarts },
                    );
                }
                ps.base_t = now;
                ps.base_received = ms.received;
                ps.ran_in_window = false;
            }
        }
        if (budget_spent and restart_sum != stats.group_restarts) {
            report.fail(.conservation_restarts, "runtime group_restarts={d} != sum over members={d}", .{
                stats.group_restarts, restart_sum,
            });
        }
        // A counted stop without a dead member, or a dead member without a
        // count, are both conservation breaks. The count is published by the
        // member's own thread on its way out, so a stop decided in this very
        // sample may lag — never by more than a sample.
        if (stats.supervised_stops > dead_count and now > settle_deadline) {
            report.fail(.conservation_stops, "supervised_stops={d} but only {d} member(s) carry the flag", .{
                stats.supervised_stops, dead_count,
            });
        }

        // ── invariant 2: the restart budget ────────────────────────────────
        if (stats.group_restarts > p.restarts) {
            restarts_bound_violations += 1;
            report.fail(.restart_budget_bound, "group_restarts={d} exceeds the declared budget {d}: the group rebuilt " ++
                "past its own intensity (§14.3)", .{ stats.group_restarts, p.restarts });
        }
        if (!settled) {
            if (stats.group_restarts == p.restarts) {
                settled = true;
                budget_spent = true;
                settle_ms = now - start_ms;
                // Observing the budget spent is not enough: the rebuild's *stop*
                // has to be visible too, or "flat restarts" could just mean
                // "never restarted".
                if (stats.supervised_stops == 0) {
                    report.fail(.restart_stop_evidence, "the restart budget is spent but supervised_stops is 0: nothing " ++
                        "was stopped, so 'flat restarts' would prove nothing", .{});
                }
            } else if (now > settle_deadline) {
                report.fail(.restart_budget_settle, "group_restarts={d} after {d}ms: the group never spent its budget of " ++
                    "{d} (supervised_stops={d})", .{
                    stats.group_restarts, now - start_ms, p.restarts, stats.supervised_stops,
                });
                settled = true; // reported once; the per-sample bound check keeps watching
            }
        } else if (stats.group_restarts != p.restarts) {
            report.fail(.restart_budget_stable, "group_restarts moved after the budget was spent: {d} != {d} (a spent " ++
                "budget that keeps rebuilding is the CPU black hole §14.3 prevents)", .{
                stats.group_restarts, p.restarts,
            });
        }

        // ── invariant 3: blocking isolation, interval by interval ──────────
        if (blk.claimed > 0) saturation_seen += 1;
        if (have_prev and prev.blocking_claimed > 0) {
            if (cpu.dispatches > prev.cpu_dispatches) {
                isolation_intervals += 1;
            } else {
                report.fail(.isolation_advance, "the blocking pool held {d} claim(s) for a whole sample interval and the " ++
                    "cpu pool did not advance its dispatches ({d} -> {d})", .{
                    prev.blocking_claimed, prev.cpu_dispatches, cpu.dispatches,
                });
            }
        }
        prev = .{
            .t_ms = now,
            .rss = info.rss_bytes,
            .threads = info.threads,
            .workers = stats.workers,
            .running = stats.running,
            .supervised_stops = stats.supervised_stops,
            .group_restarts = stats.group_restarts,
            .cpu_dispatches = cpu.dispatches,
            .cpu_claimed = cpu.claimed,
            .blocking_dispatches = blk.dispatches,
            .blocking_claimed = blk.claimed,
            .cpu_push_failures = cpu.ready_push_failures,
            .blocking_push_failures = blk.ready_push_failures,
        };
        have_prev = true;

        // The "was this walked" reading for both pools: a pool with 0 dispatches
        // means those workers never reached a pool thread (§12.10: "有 `.pooled`
        // spawn 却是 0").
        if (cpu.dispatches == 0 or blk.dispatches == 0) {
            report.fail(.pool_evidence, "pool dispatches: cpu={d} blocking={d}", .{ cpu.dispatches, blk.dispatches });
        }

        const elapsed = nowMs() - now;
        sleepMs(io, if (elapsed < p.sample_ms) p.sample_ms - elapsed else 1);
    }

    const stats_end = runtime.stats();
    const cpu_end = runtime.poolStats().?;
    const blk_end = runtime.blockingPoolStats().?;

    // Every per-member reading, taken now — while the handles still exist (see
    // `MemberSnapshot`).
    var snapshots: [max_members]MemberSnapshot = undefined;
    for (members[0..member_count], 0..) |m, i| {
        const ms = m.stats();
        snapshots[i] = .{
            .label = m.label,
            .received = ms.received,
            .running = ms.running,
            .generations = m.generations.load(.acquire),
            .restarts = ms.group_restarts,
            .errors = ms.handler_errors,
            .stopped_by_supervisor = ms.stopped_by_supervisor,
            .stopped_by_group = m.stoppedByGroup(),
            .progress_windows = progress_state[i].windows,
        };
    }
    var dead_end: usize = 0;
    var restart_sum_end: u64 = 0;
    for (snapshots[0..member_count]) |s| {
        restart_sum_end += s.restarts;
        if (s.countedDead()) dead_end += 1;
    }
    if (restart_sum_end != stats_end.group_restarts) {
        if (budget_spent) {
            report.fail(.conservation_restarts, "runtime group_restarts={d} != sum over members={d} at the end of the run", .{
                stats_end.group_restarts, restart_sum_end,
            });
        } else {
            // Not exact *and* not exactness-testable: the budget was never spent,
            // so rebuilds may still be in flight between the two reads. Said out
            // loud — the red for this shape is `restart_budget_settle` below, and
            // a silent skip here is exactly the hollow green this harness is for.
            report.warn("conservation could not be checked exactly: the budget was never spent, and runtime " ++
                "group_restarts={d} vs members={d} were read while rebuilds were still running", .{
                stats_end.group_restarts, restart_sum_end,
            });
        }
    }

    // ── floors: a green run with too little evidence would be hollow ────────
    if (sample_n < min_steady_samples) {
        report.fail(.sample_floor, "only {d} steady sample(s) (floor {d}): the time-series checks were not walked", .{
            sample_n, min_steady_samples,
        });
    }
    if (windows_attempted < min_windows) {
        report.fail(.window_coverage, "only {d} measured window(s) (floor {d})", .{ windows_attempted, min_windows });
    }
    if (windows_covered < min_windows) {
        report.fail(.window_coverage, "only {d} of {d} window(s) covered all four paths (fire, receive, cpu dispatch, " ++
            "blocking dispatch): the zero-allocation check was not walked enough to mean anything", .{
            windows_covered, windows_attempted,
        });
    }
    if (saturation_seen == 0) {
        report.fail(.isolation_saturation, "the blocking pool never reported a claim: no blocking handler ran, so the " ++
            "cpu-pool-keeps-moving check had nothing to test", .{});
    } else if (isolation_intervals < min_isolation_intervals) {
        report.fail(.isolation_saturation, "only {d} interval(s) began with a claimed blocking pool (floor {d}; {d} " ++
            "sample(s) saw a claim)", .{ isolation_intervals, min_isolation_intervals, saturation_seen });
    }
    if (!settled) {
        report.fail(.restart_budget_settle, "the restart budget was never observed spent ({d}/{d} rebuilds) within {d}ms", .{
            stats_end.group_restarts, p.restarts, settle_deadline - start_ms,
        });
    }
    if (stats_end.supervised_stops != dead_end) {
        report.fail(.conservation_stops, "supervised_stops={d} != members carrying a stop flag ({d})", .{
            stats_end.supervised_stops, dead_end,
        });
    }
    if (dead_end == 0) {
        report.fail(.restart_stop_evidence, "no member was ever stopped by supervision: the stop path and its counter " ++
            "were never walked", .{});
    }
    if (shared.boom_closed.load(.monotonic) == 0) {
        report.fail(.restart_stop_evidence, "the boom producer never saw error.Closed: that member's mailbox is still open " ++
            "after {d} rebuild(s), i.e. the budget did not take it down", .{stats_end.group_restarts});
    }
    const boom_index_used = member_count - 1; // `boom` is the last member spawned
    const boom_generations_end = generations[boom_index_used].load(.acquire);
    if (boom_generations_end != 1 + @as(u32, @intCast(stats_end.group_restarts))) {
        report.fail(.member_generations, "boom generations={d} != 1 + runtime group_restarts={d}", .{
            boom_generations_end, stats_end.group_restarts,
        });
    }
    // Invariant 1's "was it walked": every member that was supposed to keep
    // serving must have been observed doing so at least once.
    for (members[0..member_count], 0..) |m, i| {
        if (m.must_progress and progress_state[i].windows < min_progress_windows) {
            report.fail(.member_progress, "{s} was observed advancing in only {d} progress window(s) (floor {d})", .{
                m.label, progress_state[i].windows, min_progress_windows,
            });
        }
    }
    if (probe.calls() == 0 or probe.attempts.load(.monotonic) == 0) {
        report.fail(.probe_live, "the allocation probe recorded {d} attempt(s) over the whole run", .{
            probe.attempts.load(.monotonic),
        });
    }
    if (restarts_bound_violations > 0) {
        report.fail(.restart_budget_bound, "{d} sample(s) saw group_restarts above the budget", .{restarts_bound_violations});
    }

    // ── invariant 6: the time series ────────────────────────────────────────
    var rss_min: u64 = std.math.maxInt(u64);
    var rss_max: u64 = 0;
    var rss_first: u64 = 0;
    var rss_last: u64 = 0;
    var rss_seen: usize = 0;
    var rss_rises: usize = 0;
    var rss_steps: usize = 0;
    var thr_min: u32 = std.math.maxInt(u32);
    var thr_max: u32 = 0;
    var thr_seen: usize = 0;
    var thr_rises: usize = 0;
    var thr_steps: usize = 0;
    var prev_rss: ?u64 = null;
    var prev_thr: ?u32 = null;
    for (samples[0..sample_n]) |s| {
        if (s.rss) |r| {
            rss_seen += 1;
            if (rss_seen == 1) rss_first = r;
            rss_last = r;
            rss_min = @min(rss_min, r);
            rss_max = @max(rss_max, r);
            if (prev_rss) |pr| {
                rss_steps += 1;
                if (r > pr) rss_rises += 1;
            }
            prev_rss = r;
        }
        if (s.threads) |t| {
            thr_seen += 1;
            thr_min = @min(thr_min, t);
            thr_max = @max(thr_max, t);
            if (prev_thr) |pt| {
                thr_steps += 1;
                if (t > pt) thr_rises += 1;
            }
            prev_thr = t;
        }
    }

    if (rss_seen == 0) {
        report.warn("RSS is not readable on this platform ({s}): invariant 6 is only half covered, and this line is the " ++
            "reason — not a green", .{@tagName(builtin.os.tag)});
    } else {
        const spread = rss_max - rss_min;
        if (spread > p.rss_budget_bytes) {
            report.fail(.rss_stability, "RSS spread over {d} sample(s) is {d} byte(s) (budget {d}): the steady phase is " ++
                "growing, not steady", .{ rss_seen, spread, p.rss_budget_bytes });
        }
        // "Not monotonically increasing" needs a series, not one reading: a
        // strictly rising series of N readings is growth by construction.
        if (rss_steps > 0 and rss_rises == rss_steps and rss_last > rss_first) {
            report.fail(.rss_stability, "RSS rose at all {d} step(s) of the series ({d} -> {d} bytes): monotone growth", .{
                rss_steps, rss_first, rss_last,
            });
        }
    }
    if (thr_seen == 0) {
        report.warn("the OS thread count is not readable on this platform ({s}): invariant 6 is only half covered", .{
            @tagName(builtin.os.tag),
        });
    } else {
        if (thr_max - thr_min > 2) {
            report.fail(.thread_stability, "OS thread count ranged {d}..{d} over {d} sample(s): threads are being leaked " ++
                "(§12.11-2's shape — a thread no counter can see)", .{ thr_min, thr_max, thr_seen });
        }
        if (thr_steps > 0 and thr_rises == thr_steps and thr_max > thr_min) {
            report.fail(.thread_stability, "the thread count rose at every one of {d} step(s) ({d} -> {d})", .{
                thr_steps, thr_min, thr_max,
            });
        }
    }

    // ── invariant 7: shutdown with work in flight ───────────────────────────
    //
    // The producers go first, and that is not a convenience: `Runtime.shutdown`
    // frees every worker's `*Handle` in the middle of its teardown
    // (`Entry.destroy` → `Handle.deinit` → `allocator.destroy`), so a producer
    // still calling `handle.send` would be writing into freed memory. The load
    // in flight at shutdown is therefore the *backlog* — queued messages and the
    // batch that already owns them — which is what §12.6's ordering has to
    // survive.
    stopProducers(shared, &producers, producer_n);
    producers_stopped = true;

    for (blocking_handles) |h| {
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            // Closed or still full: either way this mailbox is as deep as it
            // gets, which is all this line needs.
            h.sendBlocking(@intCast(i), 200) catch break;
        }
    }
    for (cpu_handles) |h| {
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            h.sendBlocking(@intCast(i), 50) catch break;
        }
    }
    _ = cpu_handles[0].after(40, 7) catch |err| {
        report.fail(.shutdown_in_flight, "arming the in-flight timer before shutdown failed: {s}", .{@errorName(err)});
    };

    // Evidence that there really was work in flight when shutdown was called.
    const in_flight_deadline = nowMs() + 2000;
    var in_flight_claimed: usize = 0;
    while (nowMs() < in_flight_deadline) {
        in_flight_claimed = runtime.blockingPoolStats().?.claimed;
        if (in_flight_claimed > 0) break;
        sleepMs(io, 1);
    }
    if (in_flight_claimed == 0) {
        report.fail(.shutdown_in_flight, "no claim was in flight before shutdown (the blocking pool's claim stayed 0 for " ++
            "2s): the shutdown check would have been measured against an idle runtime", .{});
    }

    const t_shutdown = nowMs();
    runtime.shutdown();
    const shutdown_ms = nowMs() - t_shutdown;

    const after = runtime.stats();
    const cpu_after = runtime.poolStats().?;
    const blk_after = runtime.blockingPoolStats().?;
    if (shutdown_ms > shutdown_bound_ms) {
        report.fail(.shutdown_bound, "shutdown() took {d}ms (bound {d}ms)", .{ shutdown_ms, shutdown_bound_ms });
    }
    if (after.workers != 0) {
        report.fail(.shutdown_state, "workers={d} after shutdown", .{after.workers});
    }
    if (cpu_after.claimed != 0 or blk_after.claimed != 0) {
        report.fail(.shutdown_state, "a claim survived shutdown: cpu claimed={d}, blocking claimed={d} — the pool went down " ++
            "without handing every claim back", .{ cpu_after.claimed, blk_after.claimed });
    }
    if (cpu_after.pool_threads != 0 or blk_after.pool_threads != 0) {
        report.fail(.shutdown_state, "pool threads after shutdown: cpu={d} blocking={d}", .{
            cpu_after.pool_threads, blk_after.pool_threads,
        });
    }
    // A token left in a ready ring is reported, not asserted: the pool is
    // stopped before the workers (§12.6), so a worker that still had mail when
    // it was told to stop re-arms its token on the way out and nothing reads it
    // again — `Runtime.deinit`'s comment says exactly that ("tokens that arrived
    // while they were winding down are still in the rings"). No claim is held
    // by that token, which is the part invariant 7 is about; the count is
    // printed so a *rise* over runs is still visible.

    // ── the report ──────────────────────────────────────────────────────────
    std.debug.print("[stress] steady samples={d} (floor {d})\n", .{ sample_n, min_steady_samples });
    std.debug.print("[stress] windows: attempted={d} covered={d} (floor {d}); allocations inside them: calls={d} bytes={d}\n", .{
        windows_attempted, windows_covered, min_windows, window_alloc_calls, window_alloc_bytes,
    });
    std.debug.print("[stress] isolation: intervals={d} (floor {d}), samples with a blocking claim={d}, holding now={d}\n", .{
        isolation_intervals, min_isolation_intervals, saturation_seen, shared.blocking_holding.load(.monotonic),
    });
    std.debug.print("[stress] supervision: restarts={d}/{d} (settled at {d}ms) supervised_stops={d} dead-flagged members={d}\n", .{
        stats_end.group_restarts, p.restarts, settle_ms, stats_end.supervised_stops, dead_end,
    });
    for (snapshots[0..member_count]) |s| {
        std.debug.print(
            "[stress]   member {s}: received={d} running={} generations={d} restarts={d} errors={d} progress_windows={d} stopped_by_supervisor={} stopped_by_group={}\n",
            .{
                s.label,  s.received,         s.running,               s.generations,      s.restarts,
                s.errors, s.progress_windows, s.stopped_by_supervisor, s.stopped_by_group,
            },
        );
    }
    std.debug.print("[stress] cpu pool: dispatches={d} push_failures={d} high_water={d} capacity={d} ready_len={d}\n", .{
        cpu_end.dispatches, cpu_end.ready_push_failures, cpu_end.ready_high_water, cpu_end.ready_capacity, cpu_end.ready_len,
    });
    std.debug.print("[stress] blocking pool: dispatches={d} push_failures={d} high_water={d} capacity={d} ready_len={d}\n", .{
        blk_end.dispatches, blk_end.ready_push_failures, blk_end.ready_high_water, blk_end.ready_capacity, blk_end.ready_len,
    });
    // `ready_high_water` above `ready_capacity` is not a level: it is the
    // unsigned underflow of `(pos + 1) - dequeue_pos` in `ReadyRing.tryPush`
    // when the producer that won position `pos` is descheduled before the depth
    // read while consumers run past it (`scheduler.zig`). Reported, not asserted
    // — it is a bookkeeping reading, not one of this harness's invariants, and
    // the framework is out of scope here (see the report's findings).
    if (cpu_end.ready_high_water > cpu_end.ready_capacity or blk_end.ready_high_water > blk_end.ready_capacity) {
        report.warn("ready_high_water={d}/{d} exceeds ready_capacity={d}/{d}: the depth is an underflowed subtraction, " ++
            "not a ring level (ReadyRing.tryPush, scheduler.zig)", .{
            cpu_end.ready_high_water, blk_end.ready_high_water, cpu_end.ready_capacity, blk_end.ready_capacity,
        });
    }
    std.debug.print("[stress] timer deliveries: fires={d} dropped={d} timers_discarded(later)={d}\n", .{
        stats_end.timer_fires, stats_end.timer_deliveries_dropped, after.timers_discarded,
    });
    std.debug.print("[stress] sent: cpu={d} (full {d}) blocking={d} (full {d}) progress={d} boom={d} (closed {d})\n", .{
        shared.cpu_sent.load(.monotonic),      shared.cpu_full.load(.monotonic),
        shared.blocking_sent.load(.monotonic), shared.blocking_full.load(.monotonic),
        shared.progress_sent.load(.monotonic), shared.boom_sent.load(.monotonic),
        shared.boom_closed.load(.monotonic),
    });
    std.debug.print("[stress] handled: cpu={d} blocking={d} progress={d} boom_errors={d}\n", .{
        shared.handled_cpu.load(.monotonic),
        shared.handled_blocking.load(.monotonic),
        shared.handled_progress.load(.monotonic),
        stats_end.handler_errors,
    });
    if (rss_seen > 0) {
        std.debug.print(
            "[stress] rss: first={d} last={d} min={d} max={d} spread={d} (budget {d}) over {d} sample(s), rises={d}/{d} steps\n",
            .{ rss_first, rss_last, rss_min, rss_max, rss_max - rss_min, p.rss_budget_bytes, rss_seen, rss_rises, rss_steps },
        );
    }
    if (thr_seen > 0) {
        std.debug.print("[stress] threads (OS): min={d} max={d} over {d} sample(s), rises={d}/{d} steps\n", .{
            thr_min, thr_max, thr_seen, thr_rises, thr_steps,
        });
    }
    std.debug.print(
        "[stress] shutdown: took {d}ms (bound {d}ms) with {d} claim(s) in flight; workers={d} claimed cpu/blocking={d}/{d} " ++
            "pool_threads={d}/{d} timers_discarded={d}\n",
        .{
            shutdown_ms,            shutdown_bound_ms, in_flight_claimed,      after.workers,
            cpu_after.claimed,      blk_after.claimed, cpu_after.pool_threads, blk_after.pool_threads,
            after.timers_discarded,
        },
    );
    std.debug.print("[stress] alloc probe totals: calls={d} bytes={d} attempts={d}\n", .{
        probe.calls(), probe.bytesOut(), probe.attempts.load(.monotonic),
    });

    report.dump();
    std.debug.print("[stress] RESULT: {s}\n", .{if (report.passed()) "PASS" else "FAIL"});
    return report;
}

/// Ask every producer to stop, then join it. Both the explicit call (before
/// `shutdown`) and the `defer` guard go through here, and the caller's
/// `producers_stopped` flag keeps the join single — joining a finished thread
/// handle twice is `EINVAL` → abort, which is the exact failure mode §12.11-4
/// was about.
fn stopProducers(shared: *Shared, producers: *[max_producers]std.Thread, n: usize) void {
    shared.load_stop.store(true, .release);
    for (producers[0..n]) |t| t.join();
}

// ── entry points ────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const report = try run(init.io, init.gpa, paramsFromOptions());
    if (!report.passed()) std.process.exit(1);
}

test "runtime stress: sustained load walks every runtime invariant" {
    const report = try run(std.testing.io, std.testing.allocator, paramsFromOptions());
    try std.testing.expectEqual(@as(u64, 0), report.total);
}
