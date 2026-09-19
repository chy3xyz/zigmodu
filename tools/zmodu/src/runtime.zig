//! `zmodu runtime` — the runtime wiring a project *declares*, read out of source.
//!
//! `docs/RUNTIME.md` makes the runtime opt-in: nothing runs until a module asks
//! `ctx.runtime()` for the app's runtime. What follows — which workers exist
//! (and in which execution mode), how big their mailboxes are, whether a pool
//! was declared for the `.pooled` ones, who fans out on a `HotBus`, where timers
//! get armed, whether a recorder is attached — is spread over whichever files own
//! those modules, so a reviewer has to reassemble it by hand. This command reads
//! it back out and reports it as a list of facts, each with a `file:line`.
//!
//! **What it does not do**: read a *live* process. Queue depth, `dropped_full`,
//! `timer_lag_ms` and the pool's own counters are properties of a running
//! runtime, not of source — the runtime exports them as Prometheus metrics
//! (`Runtime.MetricsBridge`, scrape recipe in `docs/RUNTIME.md` §8) and this
//! command neither reads them nor guesses at them.
//!
//! It also **makes no judgement**. Every line is something the text says — a
//! `spawn` call site, the capacity argument as written, a `Recorder(` reference.
//! Ordering questions ("was `attachRecorder` called before `freeze`?") and
//! reachability ("is this module actually in the build?") are what a text scan
//! cannot decide, so they are not asked, let alone answered.
//!
//! ```bash
//! zmodu runtime                     # human report for the current project
//! zmodu runtime examples/alpha-engine
//! zmodu runtime --json              # machine-readable (CI, dashboards)
//! ```

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;

const usage =
    \\Usage: zmodu runtime [dir] [--json]
    \\
    \\Read the runtime wiring a project declares, statically: worker spawns and
    \\their mailbox capacities and modes, pool declarations (max_pooled_workers),
    \\mailbox/queue primitives, timer call sites, recorder/trace references, and
    \\clock selection. Every line carries a file:line; anything the text does not
    \\say is reported as `?`.
    \\
    \\Options:
    \\  --json      machine-readable JSON on stdout
    \\  -h, --help  show this help
    \\
    \\Exit codes: 0 report produced (also when the project uses no runtime),
    \\            1 target directory could not be read,
    \\            2 usage error.
    \\
    \\This command reads source only. It cannot see a live process: queue depth,
    \\dropped_full, timer_lag_ms and the pool's own counters are runtime
    \\(properties — scrape /metrics (docs/RUNTIME.md §8) for those.
    \\
;

/// Flags parsed out of `argv`. Pure data: no I/O, no logging.
const Options = struct {
    dir: []const u8 = ".",
    json: bool = false,
    help: bool = false,
};

const ArgResult = struct {
    opts: Options = .{},
    /// One-line description of the first problem found, or null when the args
    /// are usable. Kept separate from logging so the parser stays testable.
    err: ?[]const u8 = null,
};

fn parseArgs(args: []const []const u8, buf: []u8) ArgResult {
    var result = ArgResult{};
    var seen_dir = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            result.opts.json = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            result.opts.help = true;
        } else if (a.len > 0 and a[0] == '-') {
            result.err = std.fmt.bufPrint(buf, "Unknown option for `zmodu runtime`: {s}", .{a}) catch "Unknown option";
            return result;
        } else if (seen_dir) {
            result.err = std.fmt.bufPrint(buf, "Too many directories: {s} (expected at most one)", .{a}) catch "Too many directories";
            return result;
        } else {
            result.opts.dir = a;
            seen_dir = true;
        }
    }
    return result;
}

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var arg_buf: [256]u8 = undefined;
    const parsed = parseArgs(args, &arg_buf);
    if (parsed.err) |msg| {
        std.debug.print("zmodu runtime: {s}\n\n{s}", .{ msg, usage });
        return 2;
    }
    const opts = parsed.opts;
    if (opts.help) {
        var help_buf: [4096]u8 = undefined;
        var help_file = std.Io.File.stdout();
        var help_writer = help_file.writer(io, &help_buf);
        const hw = &help_writer.interface;
        hw.writeAll(usage) catch return 1;
        hw.flush() catch return 1;
        return 0;
    }

    var sources = std.ArrayList(Source).empty;
    defer {
        for (sources.items) |s| {
            allocator.free(s.path);
            allocator.free(s.content);
        }
        sources.deinit(allocator);
    }
    collectSources(io, allocator, opts.dir, &sources) catch |err| {
        std.debug.print("zmodu runtime: cannot read '{s}': {s}\n", .{ opts.dir, @errorName(err) });
        return 1;
    };

    var report = Report{};
    defer report.deinit(allocator);
    for (sources.items, 0..) |_, i| {
        analyzeSource(allocator, sources.items, i, &report) catch |err| {
            std.debug.print("zmodu runtime: scan failed in '{s}': {s}\n", .{ sources.items[i].path, @errorName(err) });
            return 1;
        };
    }
    report.sortBySite();

    var out_buf: [8192]u8 = undefined;
    var out_file = std.Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    const w = &out_writer.interface;
    if (opts.json) {
        renderJson(opts.dir, report, w) catch return 1;
    } else {
        renderText(opts.dir, report, w) catch return 1;
    }
    w.flush() catch return 1;
    // A project that never touches the runtime is not an error — it is the
    // default, and the report says so.
    return 0;
}

// ─────────────────────────────────────────────────
// Report shape
//
// Every record owns its strings; `Report.deinit` releases them. Slices are
// `file:line` facts, never derived conclusions.
// ─────────────────────────────────────────────────

const WorkerKind = enum {
    spawn,
    spawn_actor,
    spawn_supervised,

    fn label(self: WorkerKind) []const u8 {
        return switch (self) {
            .spawn => "spawn",
            .spawn_actor => "spawnActor",
            .spawn_supervised => "spawnSupervised",
        };
    }
};

const PrimitiveKind = enum {
    mailbox,
    ring_buffer,
    mpsc_ring,
    object_pool,
    hot_bus,

    fn label(self: PrimitiveKind) []const u8 {
        return switch (self) {
            .mailbox => "Mailbox",
            .ring_buffer => "RingBuffer",
            .mpsc_ring => "MpscRing",
            .object_pool => "ObjectPool",
            .hot_bus => "HotBus",
        };
    }

    /// `HotBus(E, max_subscribers)` counts subscribers, not slots.
    fn capacityNoun(self: PrimitiveKind) []const u8 {
        return if (self == .hot_bus) "subscribers" else "capacity";
    }

    fn isBus(self: PrimitiveKind) bool {
        return self == .hot_bus;
    }
};

const TimerKind = enum {
    after,
    schedule_action,
    request_cancel,
    cancel_sync,

    fn label(self: TimerKind) []const u8 {
        return switch (self) {
            .after => "after(",
            .schedule_action => "scheduleAction(",
            .request_cancel => "requestCancelTimer(",
            .cancel_sync => "cancelTimerSync(",
        };
    }
};

const RecordKind = enum {
    attach_recorder,
    recorder,

    fn label(self: RecordKind) []const u8 {
        return switch (self) {
            .attach_recorder => "attachRecorder(",
            .recorder => "Recorder(",
        };
    }
};

const TraceKind = enum {
    send_traced,
    send_blocking_traced,
    trace_id,

    fn label(self: TraceKind) []const u8 {
        return switch (self) {
            .send_traced => "sendTraced(",
            .send_blocking_traced => "sendBlockingTraced(",
            .trace_id => "ctx.traceId(",
        };
    }
};

const ClockKind = enum {
    manual,
    monotonic,

    fn label(self: ClockKind) []const u8 {
        return switch (self) {
            .manual => "manual",
            .monotonic => "monotonic",
        };
    }
};

const Worker = struct {
    kind: WorkerKind,
    /// The worker type as written (`Worker`, `ai.AgentWorker`).
    type_name: []const u8,
    /// The capacity argument as written, or null when the call did not carry one.
    /// For the config form (`{ .capacity = 64, .mode = .pooled }`) this is the
    /// `.capacity` value inside the struct — the argument that *is* the mailbox
    /// size.
    capacity_expr: ?[]const u8,
    /// The capacity, when the text resolves it to a number.
    capacity: ?usize,
    /// The `.mode` the call writes — `"pooled"` or `"dedicated"` — or null when
    /// it does not write one: a positional capacity (`rt.spawn(W, .{}, 256)`), a
    /// config struct without `.mode`, or a mode this scan does not follow.
    ///
    /// The API default is `.dedicated` (docs/RUNTIME.md §12.8 D1: the mode is
    /// additive). That default is *not* reported here, because a default is not
    /// something the text says.
    mode: ?[]const u8,
    file: []const u8,
    line: usize,
};

/// How a project sized its pool (docs/RUNTIME.md §12.8 D2 — both spellings end
/// up as `SchedulerConfig.max_pooled_workers`).
const PoolForm = enum {
    /// `builder.withMaxPooledWorkers(2)` — the application-side spelling.
    builder,
    /// `.max_pooled_workers = 2` — `Runtime.InitOptions.scheduler` or
    /// `Application.Config`, written out.
    config,

    fn label(self: PoolForm) []const u8 {
        return switch (self) {
            .builder => "withMaxPooledWorkers(",
            .config => ".max_pooled_workers =",
        };
    }
};

/// One `max_pooled_workers` declaration, as written. A declaration is a fact
/// about *configuration*: whether the spawn sites that want a pool are in the
/// same build, let alone reachable, is not something a text scan decides — so
/// the two halves are reported side by side and not compared.
const PoolDecl = struct {
    form: PoolForm,
    /// The value expression as written (`2`, `api.pool_size`).
    expr: []const u8,
    /// The declared bound, when the text resolves it to a number.
    count: ?usize,
    file: []const u8,
    line: usize,
};

const Primitive = struct {
    kind: PrimitiveKind,
    type_name: []const u8,
    capacity_expr: ?[]const u8,
    capacity: ?usize,
    file: []const u8,
    line: usize,
};

const Timer = struct {
    kind: TimerKind,
    file: []const u8,
    line: usize,
};

const Recording = struct {
    kind: RecordKind,
    file: []const u8,
    line: usize,
};

const Tracing = struct {
    kind: TraceKind,
    file: []const u8,
    line: usize,
};

const Clock = struct {
    kind: ClockKind,
    file: []const u8,
    line: usize,
};

/// Site order: by file, then by line.
fn siteLess(a_file: []const u8, a_line: usize, b_file: []const u8, b_line: usize) bool {
    const order = std.mem.order(u8, a_file, b_file);
    if (order != .eq) return order == .lt;
    return a_line < b_line;
}

fn workerLess(_: void, a: Worker, b: Worker) bool {
    return siteLess(a.file, a.line, b.file, b.line);
}

fn poolLess(_: void, a: PoolDecl, b: PoolDecl) bool {
    return siteLess(a.file, a.line, b.file, b.line);
}

fn primitiveLess(_: void, a: Primitive, b: Primitive) bool {
    return siteLess(a.file, a.line, b.file, b.line);
}

fn timerLess(_: void, a: Timer, b: Timer) bool {
    return siteLess(a.file, a.line, b.file, b.line);
}

fn recordingLess(_: void, a: Recording, b: Recording) bool {
    return siteLess(a.file, a.line, b.file, b.line);
}

fn tracingLess(_: void, a: Tracing, b: Tracing) bool {
    return siteLess(a.file, a.line, b.file, b.line);
}

fn clockLess(_: void, a: Clock, b: Clock) bool {
    return siteLess(a.file, a.line, b.file, b.line);
}

const Report = struct {
    /// Any `app.runtime()` / `ctx.runtime()` / `zigmodu.runtime` reference.
    uses_runtime: bool = false,
    files_scanned: usize = 0,
    workers: std.ArrayList(Worker) = .empty,
    /// `max_pooled_workers` declarations (§12.8 D2): "a pool was sized here".
    pools: std.ArrayList(PoolDecl) = .empty,
    primitives: std.ArrayList(Primitive) = .empty,
    timers: std.ArrayList(Timer) = .empty,
    recording: std.ArrayList(Recording) = .empty,
    tracing: std.ArrayList(Tracing) = .empty,
    clocks: std.ArrayList(Clock) = .empty,

    fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.workers.items) |x| {
            allocator.free(x.type_name);
            if (x.capacity_expr) |e| allocator.free(e);
            allocator.free(x.file);
        }
        self.workers.deinit(allocator);
        for (self.pools.items) |x| {
            allocator.free(x.expr);
            allocator.free(x.file);
        }
        self.pools.deinit(allocator);
        for (self.primitives.items) |x| {
            allocator.free(x.type_name);
            if (x.capacity_expr) |e| allocator.free(e);
            allocator.free(x.file);
        }
        self.primitives.deinit(allocator);
        for (self.timers.items) |x| allocator.free(x.file);
        self.timers.deinit(allocator);
        for (self.recording.items) |x| allocator.free(x.file);
        self.recording.deinit(allocator);
        for (self.tracing.items) |x| allocator.free(x.file);
        self.tracing.deinit(allocator);
        for (self.clocks.items) |x| allocator.free(x.file);
        self.clocks.deinit(allocator);
        self.* = undefined;
    }

    fn busCount(self: Report) usize {
        var n: usize = 0;
        for (self.primitives.items) |p| {
            if (p.kind.isBus()) n += 1;
        }
        return n;
    }

    /// Spawn sites that *write* `.mode = .pooled`. A site that stays silent is
    /// not counted: the report lists what the text says, and the API default is
    /// not something it says.
    fn pooledSpawnCount(self: Report) usize {
        var n: usize = 0;
        for (self.workers.items) |x| {
            if (x.mode) |m| {
                if (std.mem.eql(u8, m, "pooled")) n += 1;
            }
        }
        return n;
    }

    /// Order every list by `file:line` so the report (and `--json`) reads the
    /// way the project does — scan order is an implementation detail.
    fn sortBySite(self: *Report) void {
        std.mem.sort(Worker, self.workers.items, {}, workerLess);
        std.mem.sort(PoolDecl, self.pools.items, {}, poolLess);
        std.mem.sort(Primitive, self.primitives.items, {}, primitiveLess);
        std.mem.sort(Timer, self.timers.items, {}, timerLess);
        std.mem.sort(Recording, self.recording.items, {}, recordingLess);
        std.mem.sort(Tracing, self.tracing.items, {}, tracingLess);
        std.mem.sort(Clock, self.clocks.items, {}, clockLess);
    }

    /// The one-line summary the report ends on. Kept a method so the human and
    /// JSON renderings cannot disagree about what the numbers are.
    fn summary(self: Report) struct { workers: usize, pooled: usize, pool_decls: usize, buses: usize, timers: usize, recording: bool, tracing: bool } {
        return .{
            .workers = self.workers.items.len,
            .pooled = self.pooledSpawnCount(),
            .pool_decls = self.pools.items.len,
            .buses = self.busCount(),
            .timers = self.timers.items.len,
            .recording = self.recording.items.len > 0,
            .tracing = self.tracing.items.len > 0,
        };
    }
};

// ─────────────────────────────────────────────────
// Scanning
// ─────────────────────────────────────────────────

const Source = struct {
    /// Project-relative path (`src/modules/order/module.zig`).
    path: []const u8,
    content: []const u8,
};

/// Read every `src/**/*.zig` of the project, plus root-level `*.zig` (where
/// `main.zig` sometimes lives). Recursion is unbounded on purpose: runtime
/// wiring sits wherever the module that owns it sits, at any depth.
fn collectSources(io: Io, allocator: std.mem.Allocator, project_dir: []const u8, out: *std.ArrayList(Source)) !void {
    // Opening the target proves it is readable; a missing path is the caller's
    // exit-1 case, not an empty report.
    var root = try Dir.cwd().openDir(io, project_dir, .{ .iterate = true });
    defer root.close(io);

    if (root.openDir(io, "src", .{ .iterate = true })) |src| {
        defer src.close(io);
        var walker = try Dir.walkSelectively(src, allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (!isSkippedDir(entry.basename)) try walker.enter(io, entry);
                },
                .file => {
                    if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                    const content = entry.dir.readFileAlloc(io, entry.basename, allocator, Io.Limit.limited(max_file_bytes)) catch continue;
                    errdefer allocator.free(content);
                    try out.append(allocator, .{
                        .path = try std.fs.path.join(allocator, &.{ "src", entry.path }),
                        .content = content,
                    });
                },
                else => {},
            }
        }
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.startsWith(u8, entry.name, "build")) continue;
        const content = root.readFileAlloc(io, entry.name, allocator, Io.Limit.limited(max_file_bytes)) catch continue;
        errdefer allocator.free(content);
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, entry.name),
            .content = content,
        });
    }
}

const max_file_bytes = 1 << 20;

fn isSkippedDir(name: []const u8) bool {
    const skipped = [_][]const u8{ ".git", ".zig-cache", "zig-cache", "zig-out", ".zig-global-cache", "node_modules" };
    for (skipped) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// Read one file's runtime wiring into `out`. `sources` is the whole scanned
/// tree, so a capacity written as `api.mailbox_capacity` can be followed to the
/// `api.zig` the file imports instead of being reported as unknown.
fn analyzeSource(
    allocator: std.mem.Allocator,
    sources: []const Source,
    index: usize,
    out: *Report,
) !void {
    const content = sources[index].content;
    const rel = sources[index].path;
    out.files_scanned += 1;
    if (usesRuntime(content)) out.uses_runtime = true;

    const worker_needles = [_]struct { needle: []const u8, kind: WorkerKind }{
        .{ .needle = "spawnSupervised(", .kind = .spawn_supervised },
        .{ .needle = "spawnActor(", .kind = .spawn_actor },
        .{ .needle = "spawn(", .kind = .spawn },
    };
    for (worker_needles) |n| {
        var i: usize = 0;
        while (indexOfCode(content, n.needle, i)) |at| {
            i = at + n.needle.len;
            // `spawn` is a method on a runtime/handle here; a bare call is some
            // other function, and `std.Thread.spawn` is a plain thread.
            const recv = receiverSegment(content, at) orelse continue;
            if (std.mem.eql(u8, recv, "Thread")) continue;
            const raw = matchingArgs(content, at + n.needle.len - 1) orelse continue;
            var args: [8][]const u8 = undefined;
            const argc = splitArgs(raw, &args);
            // The runtime signature is (W, initial_state, capacity[, supervision]).
            if (argc < 3) continue;
            const type_name = std.mem.trim(u8, args[0], " \t\r\n");
            if (!isTypePath(type_name)) continue; // `.{}` = Thread.spawn, expressions = not a type
            const arg2 = std.mem.trim(u8, args[2], " \t\r\n");
            // The config form carries both facts this report knows how to read:
            // the capacity and the mode. A positional capacity says nothing about
            // the mode, and this scan does not fill that in.
            const config = parseSpawnConfig(arg2);
            const cap_expr: ?[]const u8 = if (config) |c| c.capacity_expr else arg2;
            try out.workers.append(allocator, .{
                .kind = n.kind,
                .type_name = try allocator.dupe(u8, type_name),
                .capacity_expr = if (cap_expr) |e| try allocator.dupe(u8, e) else null,
                .capacity = if (cap_expr) |e| resolveCapacity(allocator, sources, index, e) else null,
                .mode = if (config) |c| c.mode else null,
                .file = try allocator.dupe(u8, rel),
                .line = lineOf(content, at),
            });
        }
    }

    // Pool declarations (docs/RUNTIME.md §12.8 D2). Reported as their own facts,
    // not as "this project has a working pool": whether the `.pooled` spawn sites
    // are in the same build as the declaration is a question about reachability,
    // and this command only reads text.
    const pool_needles = [_]struct { needle: []const u8, form: PoolForm }{
        .{ .needle = "withMaxPooledWorkers(", .form = .builder },
        .{ .needle = ".max_pooled_workers", .form = .config },
    };
    for (pool_needles) |n| {
        var i: usize = 0;
        while (indexOfCode(content, n.needle, i)) |at| {
            i = at + n.needle.len;
            // Both spellings end in the declaration's *value*: the builder takes
            // it as an argument, the config assigns it. Reading it the same way
            // keeps one "what does the text say the bound is" rule.
            const value_at = switch (n.form) {
                .builder => at + n.needle.len,
                .config => blk: {
                    var j = at + n.needle.len;
                    while (j < content.len and (content[j] == ' ' or content[j] == '\t')) j += 1;
                    if (j >= content.len or content[j] != '=') continue; // `if (x.max_pooled_workers)` reads it
                    break :blk j + 1;
                },
            };
            const value = codeToken(content, value_at) orelse continue;
            try out.pools.append(allocator, .{
                .form = n.form,
                .expr = try allocator.dupe(u8, value),
                .count = resolveCapacity(allocator, sources, index, value),
                .file = try allocator.dupe(u8, rel),
                .line = lineOf(content, at),
            });
        }
    }

    const primitive_needles = [_]struct { needle: []const u8, kind: PrimitiveKind }{
        .{ .needle = "Mailbox(", .kind = .mailbox },
        .{ .needle = "RingBuffer(", .kind = .ring_buffer },
        .{ .needle = "MpscRing(", .kind = .mpsc_ring },
        .{ .needle = "ObjectPool(", .kind = .object_pool },
        .{ .needle = "HotBus(", .kind = .hot_bus },
    };
    for (primitive_needles) |n| {
        var i: usize = 0;
        while (indexOfCode(content, n.needle, i)) |at| {
            i = at + n.needle.len;
            const raw = matchingArgs(content, at + n.needle.len - 1) orelse continue;
            var args: [8][]const u8 = undefined;
            const argc = splitArgs(raw, &args);
            if (argc < 1) continue;
            const type_name = std.mem.trim(u8, args[0], " \t\r\n");
            if (!isTypePath(type_name)) continue; // the declaration `pub fn Mailbox(comptime T: type, …)`
            const cap_expr: ?[]const u8 = if (argc >= 2) std.mem.trim(u8, args[1], " \t\r\n") else null;
            try out.primitives.append(allocator, .{
                .kind = n.kind,
                .type_name = try allocator.dupe(u8, type_name),
                .capacity_expr = if (cap_expr) |e| try allocator.dupe(u8, e) else null,
                .capacity = if (cap_expr) |e| resolveCapacity(allocator, sources, index, e) else null,
                .file = try allocator.dupe(u8, rel),
                .line = lineOf(content, at),
            });
        }
    }

    const timer_needles = [_]struct { needle: []const u8, kind: TimerKind }{
        .{ .needle = "after(", .kind = .after },
        .{ .needle = "scheduleAction(", .kind = .schedule_action },
        .{ .needle = "requestCancelTimer(", .kind = .request_cancel },
        .{ .needle = "cancelTimerSync(", .kind = .cancel_sync },
    };
    for (timer_needles) |n| {
        var i: usize = 0;
        while (indexOfCode(content, n.needle, i)) |at| {
            i = at + n.needle.len;
            try out.timers.append(allocator, .{
                .kind = n.kind,
                .file = try allocator.dupe(u8, rel),
                .line = lineOf(content, at),
            });
        }
    }

    const record_needles = [_]struct { needle: []const u8, kind: RecordKind }{
        .{ .needle = "attachRecorder(", .kind = .attach_recorder },
        .{ .needle = "Recorder(", .kind = .recorder },
    };
    for (record_needles) |n| {
        var i: usize = 0;
        while (indexOfCode(content, n.needle, i)) |at| {
            i = at + n.needle.len;
            // `attachRecorder(` contains `Recorder(`; only a `Recorder(` that
            // starts a word is the primitive reference we report.
            if (!startsWord(content, at)) continue;
            try out.recording.append(allocator, .{
                .kind = n.kind,
                .file = try allocator.dupe(u8, rel),
                .line = lineOf(content, at),
            });
        }
    }

    const trace_needles = [_]struct { needle: []const u8, kind: TraceKind }{
        .{ .needle = "sendBlockingTraced(", .kind = .send_blocking_traced },
        .{ .needle = "sendTraced(", .kind = .send_traced },
        .{ .needle = "ctx.traceId(", .kind = .trace_id },
    };
    for (trace_needles) |n| {
        var i: usize = 0;
        while (indexOfCode(content, n.needle, i)) |at| {
            i = at + n.needle.len;
            try out.tracing.append(allocator, .{
                .kind = n.kind,
                .file = try allocator.dupe(u8, rel),
                .line = lineOf(content, at),
            });
        }
    }

    const clock_needles = [_]struct { needle: []const u8, kind: ClockKind }{
        .{ .needle = "Clock.manual", .kind = .manual },
        .{ .needle = "Clock.Manual", .kind = .manual },
        .{ .needle = ".manual =", .kind = .manual },
        .{ .needle = ".monotonic", .kind = .monotonic },
    };
    for (clock_needles) |n| {
        var i: usize = 0;
        while (indexOfCode(content, n.needle, i)) |at| {
            i = at + n.needle.len;
            try out.clocks.append(allocator, .{
                .kind = n.kind,
                .file = try allocator.dupe(u8, rel),
                .line = lineOf(content, at),
            });
        }
    }
}

/// A project "uses the runtime" when it reaches for the app's runtime or
/// imports the namespace: `app.runtime()`, `ctx.runtime()`, `zmodu.runtime`,
/// `@import("zigmodu").runtime`.
fn usesRuntime(content: []const u8) bool {
    if (indexOfCode(content, ".runtime()", 0) != null) return true;
    if (indexOfCode(content, "zmodu.runtime", 0) != null) return true;
    if (indexOfCode(content, "\"zigmodu\").runtime", 0) != null) return true;
    return false;
}

// ─────────────────────────────────────────────────
// Reading expressions
// ─────────────────────────────────────────────────

/// What a `spawn` config argument (`{ .capacity = 64, .mode = .pooled }`) says,
/// as far as the text goes. Null-able fields mean "the struct does not write
/// this" — never "the default applies", which is an inference this command
/// does not make.
const SpawnFacts = struct {
    capacity_expr: ?[]const u8 = null,
    /// `"pooled"` / `"dedicated"`: the tag `.mode = …` writes, with the leading
    /// dot stripped. Null when `.mode` is absent, or when it is written as
    /// something this scan does not follow (`api.mode`). Points at a literal
    /// (nothing to free).
    mode: ?[]const u8 = null,
};

/// Read the config form of `spawn`'s third argument. Returns null when the
/// argument is not a struct literal at all — a positional capacity
/// (`rt.spawn(W, .{}, 256)`) or an expression, both of which the caller reports
/// as written without inventing fields.
///
/// Field values are split on the top-level commas of the literal; a value that
/// itself contains a comma (a function call, a nested tuple) is not something
/// these call sites write, and a mis-split would show up as an unresolved `?`
/// rather than as a wrong number.
fn parseSpawnConfig(arg: []const u8) ?SpawnFacts {
    if (!std.mem.startsWith(u8, arg, ".{")) return null;
    const close = std.mem.lastIndexOfScalar(u8, arg, '}') orelse return null;
    if (close < 2) return null;
    const inner = arg[2..close];

    var facts = SpawnFacts{};
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw_field| {
        const field = std.mem.trim(u8, raw_field, " \t\r\n");
        if (field.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = std.mem.trim(u8, field[0..eq], " \t\r\n");
        const value = std.mem.trim(u8, field[eq + 1 ..], " \t\r\n");
        if (value.len == 0) continue;
        if (std.mem.eql(u8, key, ".capacity")) {
            facts.capacity_expr = value;
        } else if (std.mem.eql(u8, key, ".mode")) {
            if (std.mem.eql(u8, value, ".pooled")) {
                facts.mode = "pooled";
            } else if (std.mem.eql(u8, value, ".dedicated")) {
                facts.mode = "dedicated";
            }
        }
    }
    return facts;
}

/// The identifier-ish token starting at `index`, skipping leading whitespace:
/// `2`, `1_024`, `api.pool_size`. Stops at the first character that cannot be
/// part of one (`)`, `,`, `}`, newline). Null when there is nothing to read,
/// which is what a declaration with no value looks like.
fn codeToken(content: []const u8, index: usize) ?[]const u8 {
    var i = index;
    while (i < content.len and (content[i] == ' ' or content[i] == '\t')) i += 1;
    const start = i;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') continue;
        break;
    }
    if (i == start) return null;
    return content[start..i];
}

/// Resolve a comptime capacity expression to a number — and only to a number.
/// A literal (`256`, `1_000`) is returned directly; `api.order_capacity` is
/// followed through the file's own `@import` to the `const` that defines it.
/// Anything else (a parameter, a computed expression, a name the scan cannot
/// find) is `null`, which the report prints as `?` rather than inventing a
/// value.
fn resolveCapacity(
    allocator: std.mem.Allocator,
    sources: []const Source,
    self_index: usize,
    expr_raw: []const u8,
) ?usize {
    const expr = std.mem.trim(u8, expr_raw, " \t\r\n");
    if (parseCountLiteral(expr)) |n| return n;
    if (!isTypePath(expr)) return null;

    const content = sources[self_index].content;
    if (std.mem.lastIndexOfScalar(u8, expr, '.')) |dot| {
        const alias = expr[0..dot];
        const name = expr[dot + 1 ..];
        if (std.mem.indexOfScalar(u8, alias, '.') != null) return null; // too deep to follow
        const imported = importedPathForAlias(content, alias) orelse return null;
        const target = resolveImportPath(allocator, sources[self_index].path, imported) orelse return null;
        defer allocator.free(target);
        for (sources) |s| {
            if (!std.mem.eql(u8, s.path, target)) continue;
            return findConstLiteral(s.content, name);
        }
        return null;
    }
    return findConstLiteral(content, expr);
}

/// `256` / `1_000` → 256 / 1000. Null for anything that is not all digits.
fn parseCountLiteral(text: []const u8) ?usize {
    var digits: [24]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == '_') continue;
        if (!std.ascii.isDigit(c)) return null;
        if (n == digits.len) return null;
        digits[n] = c;
        n += 1;
    }
    if (n == 0) return null;
    return std.fmt.parseInt(usize, digits[0..n], 10) catch null;
}

/// A dotted identifier path and nothing else (`Worker`, `ai.AgentWorker`).
/// This is what keeps `.{}` (`std.Thread.spawn`) and `comptime T: type` (the
/// framework's own `pub fn Mailbox(…)` declaration) out of the report.
fn isTypePath(text: []const u8) bool {
    if (text.len == 0) return false;
    var it = std.mem.splitScalar(u8, text, '.');
    var segments: usize = 0;
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        if (!std.ascii.isAlphabetic(seg[0]) and seg[0] != '_') return false;
        for (seg[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
        segments += 1;
    }
    return segments >= 1;
}

/// `const api = @import("api.zig");` → `api.zig` for the alias `api`.
fn importedPathForAlias(content: []const u8, alias: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (indexOfCode(content, "const ", i)) |at| {
        i = at + "const ".len;
        const rest = content[at + "const ".len ..];
        if (!std.mem.startsWith(u8, rest, alias)) continue;
        const after = rest[alias.len..];
        if (after.len == 0 or (std.ascii.isAlphanumeric(after[0]) or after[0] == '_')) continue;
        const semi = std.mem.indexOfScalar(u8, after, ';') orelse continue;
        const decl = after[0..semi];
        const imp = std.mem.indexOf(u8, decl, "@import(\"") orelse continue;
        const quoted = decl[imp + "@import(\"".len ..];
        const end = std.mem.indexOfScalar(u8, quoted, '"') orelse continue;
        return quoted[0..end];
    }
    return null;
}

/// Project-relative path of an import target: `src/modules/audit/module.zig` +
/// `api.zig` → `src/modules/audit/api.zig`, `..` popping as it goes.
fn resolveImportPath(allocator: std.mem.Allocator, self_path: []const u8, import_path: []const u8) ?[]const u8 {
    if (import_path.len == 0 or import_path[0] == '/') return null;
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    if (std.fs.path.dirname(self_path)) |d| {
        var it = std.mem.splitScalar(u8, d, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            parts.append(allocator, seg) catch return null;
        }
    }
    var it = std.mem.splitScalar(u8, import_path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.pop() == null) return null;
            continue;
        }
        parts.append(allocator, seg) catch return null;
    }
    if (parts.items.len == 0) return null;
    return std.mem.join(allocator, "/", parts.items) catch null;
}

/// The literal behind `const <name>: T = <literal>;` / `pub const <name> = …`.
fn findConstLiteral(content: []const u8, name: []const u8) ?usize {
    if (name.len == 0) return null;
    var i: usize = 0;
    while (indexOfCode(content, "const ", i)) |at| {
        i = at + "const ".len;
        const rest = content[at + "const ".len ..];
        if (!std.mem.startsWith(u8, rest, name)) continue;
        const after = rest[name.len..];
        if (after.len == 0) continue;
        if (std.ascii.isAlphanumeric(after[0]) or after[0] == '_') continue; // a longer name
        if (after[0] != ':' and after[0] != '=' and !std.ascii.isWhitespace(after[0])) continue;
        const semi = std.mem.indexOfScalar(u8, after, ';') orelse continue;
        const eq = std.mem.indexOfScalar(u8, after[0..semi], '=') orelse continue;
        const value = std.mem.trim(u8, after[eq + 1 .. semi], " \t\r\n");
        if (parseCountLiteral(value)) |n| return n;
    }
    return null;
}

/// Raw text between the parens opening at `open`, skipping nested parens,
/// brackets, braces, string literals and char literals. Null if unbalanced.
fn matchingArgs(content: []const u8, open: usize) ?[]const u8 {
    var depth: usize = 0;
    var i = open;
    while (i < content.len) : (i += 1) {
        switch (content[i]) {
            '"', '\'' => {
                const quote = content[i];
                i += 1;
                while (i < content.len and content[i] != quote) : (i += 1) {
                    if (content[i] == '\\') i += 1;
                }
                if (i >= content.len) return null;
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return content[open + 1 .. i];
            },
            else => {},
        }
    }
    return null;
}

/// Split a raw argument list on its top-level commas. Returns the number of
/// arguments found (capped at `out.len`; only index 0 and 2 are ever read, so
/// the cap cannot hide anything the report claims).
fn splitArgs(raw: []const u8, out: [][]const u8) usize {
    var depth: usize = 0;
    var start: usize = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            '"', '\'' => {
                const quote = raw[i];
                i += 1;
                while (i < raw.len and raw[i] != quote) : (i += 1) {
                    if (raw[i] == '\\') i += 1;
                }
            },
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            ',' => {
                if (depth != 0) continue;
                if (n == out.len) return n;
                out[n] = raw[start..i];
                n += 1;
                start = i + 1;
            },
            else => {},
        }
    }
    if (n < out.len) {
        const tail = std.mem.trim(u8, raw[start..], " \t\r\n");
        if (tail.len > 0) {
            out[n] = tail;
            n += 1;
        }
    }
    return n;
}

/// The last segment of the receiver before the `.` at `call_index - 1`
/// (`try rt.spawn(` → `rt`, `std.Thread.spawn(` → `Thread`). Null when the call
/// is not a method call.
fn receiverSegment(content: []const u8, call_index: usize) ?[]const u8 {
    if (call_index == 0 or content[call_index - 1] != '.') return null;
    const dot = call_index - 1;
    var start = dot;
    while (start > 0) {
        const c = content[start - 1];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') {
            start -= 1;
        } else break;
    }
    if (start == dot) return null;
    const recv = content[start..dot];
    const last = if (std.mem.lastIndexOfScalar(u8, recv, '.')) |d| recv[d + 1 ..] else recv;
    return last;
}

fn startsWord(content: []const u8, index: usize) bool {
    if (index == 0) return true;
    const c = content[index - 1];
    return !std.ascii.isAlphanumeric(c) and c != '_';
}

/// First *code* occurrence of `needle` at or after `from` — the scan's one
/// precision rule. Three things disqualify a match, and each of them was a real false positive
/// before it was added: the site is inert (a `//` comment, a string literal, a
/// `\\` line of a multiline string — fix hints and test fixtures say `spawn(`
/// without spawning anything); the needle is glued to a longer name
/// (`Time.monotonicNowSeconds(` is not a clock choice, `snapshot_after(` is not
/// a timer); or a word-initial needle sits at the tail of another identifier
/// (`respawn(`).
fn indexOfCode(content: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0) return null;
    // A leading `.` or `"` is already a boundary; a leading letter is not.
    const need_start = std.ascii.isAlphanumeric(needle[0]) or needle[0] == '_';
    const last = needle[needle.len - 1];
    const need_end = std.ascii.isAlphanumeric(last) or last == '_';

    var i = from;
    while (std.mem.indexOfPos(u8, content, i, needle)) |at| {
        i = at + needle.len;
        if (need_start and !startsWord(content, at)) continue;
        if (need_end and at + needle.len < content.len) {
            const after = content[at + needle.len];
            if (std.ascii.isAlphanumeric(after) or after == '_') continue;
        }
        if (isInertPlace(content, at)) continue;
        return at;
    }
    return null;
}

/// True when the position holds no code: a `//` comment line, a `\\` line of a
/// multiline string literal, or the inside of a `"…"` literal opened earlier on
/// the same line (Zig string literals do not span lines, so the line is enough
/// of a window).
fn isInertPlace(content: []const u8, index: usize) bool {
    var start = index;
    while (start > 0 and content[start - 1] != '\n') start -= 1;
    const before = content[start..index];
    const trimmed = std.mem.trim(u8, before, " \t");
    if (std.mem.startsWith(u8, trimmed, "//")) return true;
    if (std.mem.startsWith(u8, trimmed, "\\\\")) return true;

    var in_string = false;
    var i: usize = 0;
    while (i < before.len) : (i += 1) {
        if (before[i] == '\\') {
            i += 1; // the escaped byte cannot close a literal
            continue;
        }
        if (before[i] == '"') in_string = !in_string;
    }
    return in_string;
}

fn lineOf(content: []const u8, index: usize) usize {
    var line: usize = 1;
    for (content[0..@min(index, content.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

// ─────────────────────────────────────────────────
// Rendering
// ─────────────────────────────────────────────────

fn renderText(project_dir: []const u8, report: Report, w: anytype) !void {
    try w.print("runtime wiring: {s}  ({d} .zig file(s) scanned)\n", .{ project_dir, report.files_scanned });

    // Every section is always printed: a project that never touches the runtime
    // is the default (0 / no), and one that touches it without a visible
    // `runtime()` reference still gets its call sites listed rather than hidden
    // behind this line.
    if (report.uses_runtime) {
        try w.writeAll("uses runtime: yes  (app.runtime()/ctx.runtime() or zigmodu.runtime)\n");
    } else {
        try w.writeAll("uses runtime: no  (no app.runtime()/ctx.runtime(), no zigmodu.runtime reference)\n");
    }

    try w.print("\nworkers ({d} spawn site(s)):\n", .{report.workers.items.len});
    if (report.workers.items.len == 0) try w.writeAll("  (none)\n");
    for (report.workers.items) |x| {
        try w.print("  {s} {s} mailbox ", .{ x.kind.label(), x.type_name });
        try writeCapacity(x.capacity, x.capacity_expr, w);
        // Printed only when the call writes it: `rt.spawn(W, .{}, 256)` says
        // nothing about the mode, and filling in the API default here would be
        // the report guessing.
        if (x.mode) |m| try w.print(" mode={s}", .{m});
        try w.print("  ({s}:{d})\n", .{ x.file, x.line });
    }

    // The pool (§12): one half is "who asked to be pooled", the other is "what
    // was the pool sized to". Both are facts; that they match is not asserted,
    // because reachability is not something a text scan sees.
    try w.writeAll("\npool (.mode = .pooled; docs/RUNTIME.md §12):\n");
    const s0 = report.summary();
    try w.print("  spawn site(s) writing .mode = .pooled: {d} of {d}\n", .{ s0.pooled, s0.workers });
    if (report.pools.items.len == 0) {
        try w.writeAll("  declared max_pooled_workers: none  (without a declaration `.pooled` is refused at `spawn`)\n");
    } else {
        for (report.pools.items) |p| {
            try w.writeAll("  declared max_pooled_workers=");
            try writeCapacity(p.count, p.expr, w);
            try w.print("  [{s}]  ({s}:{d})\n", .{ p.form.label(), p.file, p.line });
        }
    }

    try w.print("\nmailbox / queue primitives ({d} site(s); `bus(es)` in the summary counts HotBus):\n", .{report.primitives.items.len});
    if (report.primitives.items.len == 0) try w.writeAll("  (none)\n");
    for (report.primitives.items) |x| {
        try w.print("  {s} {s} {s} ", .{ x.kind.label(), x.type_name, x.kind.capacityNoun() });
        try writeCapacity(x.capacity, x.capacity_expr, w);
        try w.print("  ({s}:{d})\n", .{ x.file, x.line });
    }

    try w.print("\ntimer call sites ({d}):\n", .{report.timers.items.len});
    if (report.timers.items.len == 0) try w.writeAll("  (none)\n");
    for (report.timers.items) |x| {
        try w.print("  {s}  ({s}:{d})\n", .{ x.kind.label(), x.file, x.line });
    }

    const s = report.summary();
    try w.print("\nrecording: {s}  ({d} site(s): attachRecorder( / Recorder( )\n", .{
        if (s.recording) "yes" else "no",
        report.recording.items.len,
    });
    for (report.recording.items) |x| {
        try w.print("  {s}  ({s}:{d})\n", .{ x.kind.label(), x.file, x.line });
    }
    try w.print("tracing: {s}  ({d} site(s): sendTraced( / sendBlockingTraced( / ctx.traceId( )\n", .{
        if (s.tracing) "yes" else "no",
        report.tracing.items.len,
    });
    for (report.tracing.items) |x| {
        try w.print("  {s}  ({s}:{d})\n", .{ x.kind.label(), x.file, x.line });
    }

    try w.print("\nclock selection ({d}):\n", .{report.clocks.items.len});
    if (report.clocks.items.len == 0) try w.writeAll("  (none — the runtime default is .monotonic)\n");
    var saw_manual = false;
    for (report.clocks.items) |x| {
        try w.print("  {s}  ({s}:{d})\n", .{ x.kind.label(), x.file, x.line });
        if (x.kind == .manual) saw_manual = true;
    }
    if (saw_manual) try w.writeAll("  (a manual clock only moves when a driver advances it — tests.)\n");

    try w.print("\nsummary: {d} worker(s) ({d} .pooled), {d} bus(es), {d} timer call site(s), pool: {s}, recording: {s}, tracing: {s}\n", .{
        s.workers,
        s.pooled,
        s.buses,
        s.timers,
        if (s.pool_decls > 0) "declared" else "none declared",
        if (s.recording) "yes" else "no",
        if (s.tracing) "yes" else "no",
    });
    try renderFootnote(w);
}

fn renderFootnote(w: anytype) !void {
    try w.writeAll(
        \\note: static wiring only — this reads source, not a live process. Queue depth /
        \\      dropped_full / timer_lag_ms and the pool's own counters (claims, ready
        \\      depth, refused pushes) are properties of a running runtime: scrape
        \\      /metrics (docs/RUNTIME.md §8) for those.
        \\
    );
}

/// `256 (api.order_capacity)` / `? (api.order_capacity)` / `256`.
fn writeCapacity(capacity: ?usize, expr: ?[]const u8, w: anytype) !void {
    if (capacity) |n| {
        try w.print("{d}", .{n});
    } else {
        try w.writeAll("?");
    }
    if (expr) |e| {
        if (capacity == null or parseCountLiteral(e) == null) {
            try w.print(" ({s})", .{e});
        }
    }
}

fn renderJson(project_dir: []const u8, report: Report, w: anytype) !void {
    const s = report.summary();
    try w.writeAll("{\"dir\":");
    try writeJsonString(project_dir, w);
    try w.print(",\"files_scanned\":{d},\"uses_runtime\":{},", .{ report.files_scanned, report.uses_runtime });

    try w.writeAll("\"workers\":[");
    for (report.workers.items, 0..) |x, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"kind\":\"{s}\",\"type\":", .{x.kind.label()});
        try writeJsonString(x.type_name, w);
        try w.writeAll(",\"capacity\":");
        try writeJsonCapacity(x.capacity, w);
        try w.writeAll(",\"capacity_expr\":");
        try writeJsonOptionalString(x.capacity_expr, w);
        // `null` = the call does not write a `.mode` (the API default is
        // `.dedicated`, but a default is not something the text says).
        try w.writeAll(",\"mode\":");
        try writeJsonOptionalString(x.mode, w);
        try w.writeAll(",\"file\":");
        try writeJsonString(x.file, w);
        try w.print(",\"line\":{d}}}", .{x.line});
    }

    try w.writeAll("],\"pool\":{\"declared\":[");
    for (report.pools.items, 0..) |x, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"form\":\"{s}\",\"max_pooled_workers\":", .{@tagName(x.form)});
        try writeJsonCapacity(x.count, w);
        try w.writeAll(",\"expr\":");
        try writeJsonString(x.expr, w);
        try w.writeAll(",\"file\":");
        try writeJsonString(x.file, w);
        try w.print(",\"line\":{d}}}", .{x.line});
    }
    try w.print("],\"pooled_spawns\":{d}}}", .{s.pooled});

    try w.writeAll(",\"primitives\":[");
    for (report.primitives.items, 0..) |x, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"kind\":\"{s}\",\"type\":", .{@tagName(x.kind)});
        try writeJsonString(x.type_name, w);
        try w.writeAll(",\"capacity\":");
        try writeJsonCapacity(x.capacity, w);
        try w.writeAll(",\"capacity_expr\":");
        try writeJsonOptionalString(x.capacity_expr, w);
        try w.writeAll(",\"file\":");
        try writeJsonString(x.file, w);
        try w.print(",\"line\":{d}}}", .{x.line});
    }

    try w.writeAll("],\"timers\":[");
    for (report.timers.items, 0..) |x, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"kind\":\"{s}\",\"file\":", .{@tagName(x.kind)});
        try writeJsonString(x.file, w);
        try w.print(",\"line\":{d}}}", .{x.line});
    }

    try w.writeAll("],\"recording\":[");
    for (report.recording.items, 0..) |x, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"kind\":\"{s}\",\"file\":", .{@tagName(x.kind)});
        try writeJsonString(x.file, w);
        try w.print(",\"line\":{d}}}", .{x.line});
    }

    try w.writeAll("],\"tracing\":[");
    for (report.tracing.items, 0..) |x, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"kind\":\"{s}\",\"file\":", .{@tagName(x.kind)});
        try writeJsonString(x.file, w);
        try w.print(",\"line\":{d}}}", .{x.line});
    }

    try w.writeAll("],\"clocks\":[");
    for (report.clocks.items, 0..) |x, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"kind\":\"{s}\",\"file\":", .{@tagName(x.kind)});
        try writeJsonString(x.file, w);
        try w.print(",\"line\":{d}}}", .{x.line});
    }

    try w.print("],\"summary\":{{\"workers\":{d},\"pooled_spawns\":{d},\"pool_declarations\":{d},\"buses\":{d},\"timer_sites\":{d},\"recording\":{},\"tracing\":{}}}}}\n", .{
        s.workers, s.pooled, s.pool_decls, s.buses, s.timers, s.recording, s.tracing,
    });
}

fn writeJsonCapacity(capacity: ?usize, w: anytype) !void {
    if (capacity) |n| {
        try w.print("{d}", .{n});
    } else {
        try w.writeAll("null");
    }
}

fn writeJsonOptionalString(value: ?[]const u8, w: anytype) !void {
    if (value) |v| {
        try writeJsonString(v, w);
    } else {
        try w.writeAll("null");
    }
}

fn writeJsonString(value: []const u8, w: anytype) !void {
    try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "runtime reads worker type names and mailbox capacities out of source" {
    const allocator = std.testing.allocator;
    const src =
        \\const runtime = zmodu.runtime;
        \\
        \\pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        \\    const rt = try ctx.runtime();
        \\    risk = try rt.spawn(Risk, .{}, 256);
        \\    audit = try rt.spawn(Audit, .{ .risk = risk.? }, 64);
        \\    faulty = try rt.spawnActor(FaultyReporter, .{}, 32, .{ .max_errors = 3 });
        \\    gate = try rt.spawnSupervised(Gate, .{}, 8, .{});
        \\    bus = runtime.HotBus(Delta, 4).init();
        \\    inbox = runtime.Mailbox(Delta, 128).init(io);
        \\    q = runtime.MpscRing(Tick, 512).init();
        \\    ring = runtime.RingBuffer(u8, 1_024).init();
        \\    // a comment mentioning spawn(NotAWorker, .{}, 1) is not wiring
        \\    const feed = try std.Thread.spawn(.{}, Feed.run, .{book});
        \\}
        \\
    ;
    const sources = [_]Source{.{ .path = "src/main.zig", .content = src }};
    var report = Report{};
    defer report.deinit(allocator);
    try analyzeSource(allocator, &sources, 0, &report);
    report.sortBySite();

    try std.testing.expect(report.uses_runtime);
    try std.testing.expectEqual(@as(usize, 4), report.workers.items.len);

    try std.testing.expectEqualStrings("Risk", report.workers.items[0].type_name);
    try std.testing.expectEqual(WorkerKind.spawn, report.workers.items[0].kind);
    try std.testing.expectEqual(@as(?usize, 256), report.workers.items[0].capacity);
    try std.testing.expectEqualStrings("256", report.workers.items[0].capacity_expr.?);

    // A multi-line call carries its arguments just the same.
    try std.testing.expectEqualStrings("Audit", report.workers.items[1].type_name);
    try std.testing.expectEqual(@as(?usize, 64), report.workers.items[1].capacity);
    try std.testing.expectEqual(@as(usize, 6), report.workers.items[1].line);

    try std.testing.expectEqualStrings("FaultyReporter", report.workers.items[2].type_name);
    try std.testing.expectEqual(WorkerKind.spawn_actor, report.workers.items[2].kind);
    try std.testing.expectEqual(@as(?usize, 32), report.workers.items[2].capacity);

    try std.testing.expectEqualStrings("Gate", report.workers.items[3].type_name);
    try std.testing.expectEqual(WorkerKind.spawn_supervised, report.workers.items[3].kind);
    try std.testing.expectEqual(@as(?usize, 8), report.workers.items[3].capacity);

    // Primitives, with the HotBus subscriber count read as such.
    try std.testing.expectEqual(@as(usize, 4), report.primitives.items.len);
    try std.testing.expectEqual(PrimitiveKind.hot_bus, report.primitives.items[0].kind);
    try std.testing.expectEqualStrings("Delta", report.primitives.items[0].type_name);
    try std.testing.expectEqual(@as(?usize, 4), report.primitives.items[0].capacity);
    try std.testing.expectEqual(@as(?usize, 128), report.primitives.items[1].capacity);
    try std.testing.expectEqual(@as(?usize, 512), report.primitives.items[2].capacity);
    try std.testing.expectEqual(@as(?usize, 1024), report.primitives.items[3].capacity);
    try std.testing.expectEqual(@as(usize, 1), report.busCount());
}

test "runtime follows a named capacity to the const in the imported file" {
    const allocator = std.testing.allocator;
    const sources = [_]Source{
        .{
            .path = "src/modules/exec/module.zig",
            .content =
            \\const api = @import("api.zig");
            \\const runtime = @import("zigmodu").runtime;
            \\pub fn initWith(ctx: *zmodu.ModuleContext) !void {
            \\    const rt = try ctx.runtime();
            \\    inbox = try rt.spawn(Worker, .{
            \\        .desk = api.order_capacity,
            \\    }, api.order_capacity);
            \\    other = try rt.spawn(Other, .{}, api.missing);
            \\}
            ,
        },
        .{
            .path = "src/modules/exec/api.zig",
            .content =
            \\pub const order_capacity: usize = 1_024;
            ,
        },
    };
    var report = Report{};
    defer report.deinit(allocator);
    try analyzeSource(allocator, &sources, 0, &report);
    report.sortBySite();

    try std.testing.expectEqual(@as(usize, 2), report.workers.items.len);
    try std.testing.expectEqualStrings("api.order_capacity", report.workers.items[0].capacity_expr.?);
    try std.testing.expectEqual(@as(?usize, 1024), report.workers.items[0].capacity);
    try std.testing.expectEqual(@as(usize, 5), report.workers.items[0].line);
    // A name the scan cannot find is `?`, not a guess.
    try std.testing.expectEqualStrings("api.missing", report.workers.items[1].capacity_expr.?);
    try std.testing.expectEqual(@as(?usize, null), report.workers.items[1].capacity);
}

test "runtime reports timer sites, recorder/trace references and clock choice" {
    const allocator = std.testing.allocator;
    const src =
        \\const runtime = zmodu.runtime;
        \\var rec = runtime.Recorder(Trade, 4096).init(clock);
        \\try bus.attachRecorder(&rec);
        \\try h.after(200, .{});
        \\try h.sendTraced(msg, trace);
        \\try h.sendBlockingTraced(msg, trace, 5);
        \\var manual = runtime.Clock.Manual{ .now_ms = 0 };
        \\const sys: runtime.Clock = .monotonic;
        \\
    ;
    const sources = [_]Source{.{ .path = "src/main.zig", .content = src }};
    var report = Report{};
    defer report.deinit(allocator);
    try analyzeSource(allocator, &sources, 0, &report);
    report.sortBySite();

    // `attachRecorder(` contains `Recorder(` — it must not be counted twice.
    try std.testing.expectEqual(@as(usize, 2), report.recording.items.len);
    try std.testing.expectEqual(RecordKind.recorder, report.recording.items[0].kind);
    try std.testing.expectEqual(RecordKind.attach_recorder, report.recording.items[1].kind);

    // The two trace-send needles are distinct substrings; there is no
    // `ctx.traceId(` in this source, so tracing is the two sends.
    try std.testing.expectEqual(@as(usize, 2), report.tracing.items.len);
    try std.testing.expectEqual(TraceKind.send_traced, report.tracing.items[0].kind);
    try std.testing.expectEqual(TraceKind.send_blocking_traced, report.tracing.items[1].kind);
    try std.testing.expectEqual(@as(usize, 1), report.timers.items.len);
    try std.testing.expectEqual(TimerKind.after, report.timers.items[0].kind);

    try std.testing.expectEqual(@as(usize, 2), report.clocks.items.len);
    try std.testing.expectEqual(ClockKind.manual, report.clocks.items[0].kind);
    try std.testing.expectEqual(ClockKind.monotonic, report.clocks.items[1].kind);
}

test "runtime reports zero for a project that never touches the runtime" {
    const allocator = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\pub fn main() !void {
        \\    const feed = try std.Thread.spawn(.{}, run, .{});
        \\    feed.join();
        \\}
        \\
    ;
    const sources = [_]Source{.{ .path = "src/main.zig", .content = src }};
    var report = Report{};
    defer report.deinit(allocator);
    try analyzeSource(allocator, &sources, 0, &report);
    report.sortBySite();

    try std.testing.expect(!report.uses_runtime);
    try std.testing.expectEqual(@as(usize, 0), report.workers.items.len);

    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try renderText("examples/basic", report, &stream);
    const text = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "uses runtime: no") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "summary: 0 worker(s) (0 .pooled), 0 bus(es), 0 timer call site(s), pool: none declared, recording: no, tracing: no") != null);
}

test "runtime reads no wiring out of comments, string literals or \\\\ lines" {
    const allocator = std.testing.allocator;
    const src =
        \\const hint =
        \\    "  then: const worker = try rt.spawn(W, .{}, capacity);\n";
        \\const inline = "try bus.attachRecorder(&rec);";
        \\const rt_ref = "try app.runtime()";
        \\// prose: spawn(NotWiring, .{}, 4) and after( are only mentioned here
        \\
    ;
    const sources = [_]Source{.{ .path = "src/hints.zig", .content = src }};
    var report = Report{};
    defer report.deinit(allocator);
    try analyzeSource(allocator, &sources, 0, &report);

    try std.testing.expect(!report.uses_runtime);
    try std.testing.expectEqual(@as(usize, 0), report.workers.items.len);
    try std.testing.expectEqual(@as(usize, 0), report.recording.items.len);
    try std.testing.expectEqual(@as(usize, 0), report.timers.items.len);

    // A `\\` line of a multiline string literal is string content as well; a
    // real call site on a code line is not.
    try std.testing.expect(isInertPlace("    \\\\ spawn(Risk, .{}, 256);", 7));
    try std.testing.expect(!isInertPlace("    risk = try rt.spawn(Risk, .{}, 256);", 18));
}

test "runtime --json parses back into the documented shape" {
    const allocator = std.testing.allocator;
    const src =
        \\const runtime = zmodu.runtime;
        \\pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        \\    const rt = try ctx.runtime();
        \\    risk = try rt.spawn(Risk, .{}, 256);
        \\    audit = try rt.spawn(Audit, .{}, .{ .capacity = 64, .mode = .pooled });
        \\    bus = runtime.HotBus(Delta, 4).init();
        \\    _ = try ctx.handle.after(200, .{});
        \\    try bus.attachRecorder(&rec);
        \\    _ = ctx.traceId();
        \\}
        \\pub fn main() !void {
        \\    var app = try b.withMaxPooledWorkers(2).build(.{Pipeline});
        \\    _ = app;
        \\}
        \\
    ;
    const sources = [_]Source{.{ .path = "src/main.zig", .content = src }};
    var report = Report{};
    defer report.deinit(allocator);
    try analyzeSource(allocator, &sources, 0, &report);
    report.sortBySite();

    var buf: [8192]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try renderJson("examples/runtime-workers", report, &stream);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, stream.buffered(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("examples/runtime-workers", root.get("dir").?.string);
    try std.testing.expect(root.get("files_scanned").?.integer == 1);
    try std.testing.expect(root.get("uses_runtime").?.bool);

    const workers = root.get("workers").?.array;
    try std.testing.expectEqual(@as(usize, 2), workers.items.len);
    try std.testing.expectEqualStrings("spawn", workers.items[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("Risk", workers.items[0].object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 256), workers.items[0].object.get("capacity").?.integer);
    // A positional capacity writes no mode: `null`, not the API default.
    switch (workers.items[0].object.get("mode").?) {
        .null => {},
        else => return error.PositionalCapacityShouldNotNameAMode,
    }

    try std.testing.expectEqualStrings("Audit", workers.items[1].object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 64), workers.items[1].object.get("capacity").?.integer);
    try std.testing.expectEqualStrings("pooled", workers.items[1].object.get("mode").?.string);
    try std.testing.expectEqualStrings("64", workers.items[1].object.get("capacity_expr").?.string);

    const pool = root.get("pool").?.object;
    try std.testing.expectEqual(@as(i64, 1), pool.get("pooled_spawns").?.integer);
    const decls = pool.get("declared").?.array;
    try std.testing.expectEqual(@as(usize, 1), decls.items.len);
    try std.testing.expectEqualStrings("builder", decls.items[0].object.get("form").?.string);
    try std.testing.expectEqual(@as(i64, 2), decls.items[0].object.get("max_pooled_workers").?.integer);

    const primitives = root.get("primitives").?.array;
    try std.testing.expectEqual(@as(usize, 1), primitives.items.len);
    try std.testing.expectEqualStrings("hot_bus", primitives.items[0].object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 4), primitives.items[0].object.get("capacity").?.integer);

    try std.testing.expectEqual(@as(usize, 1), root.get("timers").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), root.get("recording").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), root.get("tracing").?.array.items.len);

    const summary = root.get("summary").?.object;
    try std.testing.expectEqual(@as(i64, 2), summary.get("workers").?.integer);
    try std.testing.expectEqual(@as(i64, 1), summary.get("pooled_spawns").?.integer);
    try std.testing.expectEqual(@as(i64, 1), summary.get("pool_declarations").?.integer);
    try std.testing.expectEqual(@as(i64, 1), summary.get("buses").?.integer);
    try std.testing.expectEqual(@as(i64, 1), summary.get("timer_sites").?.integer);
    try std.testing.expect(summary.get("recording").?.bool);
    try std.testing.expect(summary.get("tracing").?.bool);
}

test "runtime reports the pool both ways round: who is pooled, and what was declared" {
    const allocator = std.testing.allocator;
    const src =
        \\const rt = try zigmodu.Runtime.initWithOptions(allocator, io, .{
        \\    .scheduler = .{ .max_pooled_workers = 8 },
        \\});
        \\pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        \\    audit = try rt.spawn(Audit, .{}, .{ .capacity = 64, .mode = .pooled });
        \\    book = try rt.spawn(Book, .{}, 256);
        \\    chatty = try rt.spawn(Chatty, .{}, .{ .capacity = 8, .mode = .dedicated });
        \\}
        \\pub fn main() !void {
        \\    var app = try b.withMaxPooledWorkers(pool_size).build(.{Pipeline});
        \\    if (app.config.max_pooled_workers > 0) {}
        \\}
        \\
    ;
    const sources = [_]Source{.{ .path = "src/main.zig", .content = src }};
    var report = Report{};
    defer report.deinit(allocator);
    try analyzeSource(allocator, &sources, 0, &report);
    report.sortBySite();

    try std.testing.expectEqual(@as(usize, 3), report.workers.items.len);
    try std.testing.expectEqualStrings("pooled", report.workers.items[0].mode.?);
    try std.testing.expectEqual(@as(?usize, 64), report.workers.items[0].capacity);
    try std.testing.expectEqual(@as(?[]const u8, null), report.workers.items[1].mode);
    try std.testing.expectEqual(@as(?usize, 256), report.workers.items[1].capacity);
    try std.testing.expectEqualStrings("dedicated", report.workers.items[2].mode.?);

    // Two declarations, two spellings, each with its value resolved or not:
    // `max_pooled_workers = 8` is a literal, `withMaxPooledWorkers(pool_size)`
    // names a const this fixture does not define (reported `?`, not guessed).
    try std.testing.expectEqual(@as(usize, 2), report.pools.items.len);
    try std.testing.expectEqual(PoolForm.config, report.pools.items[0].form);
    try std.testing.expectEqual(@as(?usize, 8), report.pools.items[0].count);
    try std.testing.expectEqual(PoolForm.builder, report.pools.items[1].form);
    try std.testing.expectEqual(@as(?usize, null), report.pools.items[1].count);
    try std.testing.expectEqualStrings("pool_size", report.pools.items[1].expr);

    // The reading of a member (`if (app.config.max_pooled_workers > 0)`) is not a
    // declaration: there is no `=` after the name, so nothing is reported.
    var buf: [8192]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try renderText("examples/runtime-workers", report, &stream);
    const text = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "spawn Audit mailbox 64 mode=pooled") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "spawn Book mailbox 256") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "spawn Chatty mailbox 8 mode=dedicated") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "spawn site(s) writing .mode = .pooled: 1 of 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declared max_pooled_workers=8  [.max_pooled_workers =]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declared max_pooled_workers=? (pool_size)  [withMaxPooledWorkers(]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pool: declared") != null);
}

test "runtime parseArgs: unknown flag is a usage error, the pure function never logs" {
    var buf: [256]u8 = undefined;

    const ok = parseArgs(&.{ "examples/basic", "--json" }, &buf);
    try std.testing.expect(ok.err == null);
    try std.testing.expect(ok.opts.json);
    try std.testing.expectEqualStrings("examples/basic", ok.opts.dir);

    const defaults = parseArgs(&.{}, &buf);
    try std.testing.expect(defaults.err == null);
    try std.testing.expectEqualStrings(".", defaults.opts.dir);
    try std.testing.expect(!defaults.opts.json);

    const help = parseArgs(&.{"-h"}, &buf);
    try std.testing.expect(help.err == null);
    try std.testing.expect(help.opts.help);

    const bogus = parseArgs(&.{"--bogus"}, &buf);
    try std.testing.expect(bogus.err != null);
    try std.testing.expect(std.mem.indexOf(u8, bogus.err.?, "--bogus") != null);

    const two_dirs = parseArgs(&.{ "a", "b" }, &buf);
    try std.testing.expect(two_dirs.err != null);
}

test "runtime: the two non-zero exit paths are reachable without printing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // `run` maps a parse error to exit 2 and a scan failure to exit 1. Both are
    // asserted at the layer that decides them, because `run` itself narrates the
    // failure on stderr (`std.debug.print`) — which the build runner then echoes
    // as the step's stderr, labelling a *passing* test run "failed command".
    var buf: [256]u8 = undefined;
    try std.testing.expect(parseArgs(&.{"--bogus"}, &buf).err != null);

    var sources = std.ArrayList(Source).empty;
    defer sources.deinit(allocator);
    try std.testing.expectError(
        error.FileNotFound,
        collectSources(io, allocator, "/nonexistent-zmodu-runtime", &sources),
    );
}

test "runtime scans a project tree and reports the wiring with file:line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Wiring two directories deep, which a fixed two-level walk would miss.
    try tmp.dir.createDirPath(io, "src/modules/pipeline/inner");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/modules/pipeline/inner/module.zig",
        .data =
        \\const runtime = @import("zigmodu").runtime;
        \\pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        \\    const rt = try ctx.runtime();
        \\    inbox = try rt.spawn(Worker, .{}, 128);
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data =
        \\const std = @import("std");
        \\pub fn main() void {}
        ,
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..path_len];

    var sources = std.ArrayList(Source).empty;
    defer {
        for (sources.items) |s| {
            allocator.free(s.path);
            allocator.free(s.content);
        }
        sources.deinit(allocator);
    }
    try collectSources(io, allocator, dir, &sources);
    try std.testing.expectEqual(@as(usize, 2), sources.items.len);

    var report = Report{};
    defer report.deinit(allocator);
    for (sources.items, 0..) |_, i| try analyzeSource(allocator, sources.items, i, &report);
    report.sortBySite();

    try std.testing.expect(report.uses_runtime);
    try std.testing.expectEqual(@as(usize, 1), report.workers.items.len);
    try std.testing.expectEqualStrings("Worker", report.workers.items[0].type_name);
    try std.testing.expectEqual(@as(?usize, 128), report.workers.items[0].capacity);
    try std.testing.expectEqualStrings("src/modules/pipeline/inner/module.zig", report.workers.items[0].file);

    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try renderText(dir, report, &stream);
    const text = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "spawn Worker mailbox 128  (src/modules/pipeline/inner/module.zig:4)") != null);
}
