const std = @import("std");
const zigmodu = @import("zigmodu");

fn now() i128 {
    return zigmodu.time.monotonicNow();
}

fn elapsedMs(t0: i128) f64 {
    const dt = now() - t0;
    return @as(f64, @floatFromInt(dt)) / 1_000_000.0;
}

fn benchModuleScan(allocator: std.mem.Allocator, count: usize) !f64 {
    const MockModule = struct {
        pub const info = zigmodu.api.Module{ .name = "bench", .description = "Benchmark module", .dependencies = &.{} };
        pub fn init() !void {}
        pub fn deinit() void {}
    };
    const t0 = now();
    for (0..count) |_| {
        var modules = try zigmodu.scanModules(allocator, .{MockModule});
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

fn benchCircuitBreaker(allocator: std.mem.Allocator, calls: usize) !f64 {
    var cb = try zigmodu.CircuitBreaker.init(allocator, "bench", .{ .failure_threshold = 100, .success_threshold = 2, .timeout_seconds = 30, .half_open_max_calls = 10 });
    defer cb.deinit();
    const t0 = now();
    for (0..calls) |_| {
        _ = cb.call(struct {
            fn op() anyerror!void {}
        }.op);
    }
    return elapsedMs(t0);
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

fn benchHealthEndpoint(allocator: std.mem.Allocator, checks: usize, iterations: usize) !f64 {
    var ep = zigmodu.HealthEndpoint.init(allocator);
    defer ep.deinit();
    for (0..checks) |i| {
        const name = try std.fmt.allocPrint(allocator, "check-{}", .{i});
        defer allocator.free(name);
        try ep.registerCheck(name, "bench", zigmodu.HealthEndpoint.alwaysUp);
    }
    const t0 = now();
    for (0..iterations) |_| {
        var d = ep.checkHealth();
        d.components.deinit();
    }
    return elapsedMs(t0);
}

fn benchApplicationLifecycle(io: std.Io, allocator: std.mem.Allocator, count: usize) !f64 {
    const M = struct {
        pub const info = zigmodu.api.Module{ .name = "m", .description = "M", .dependencies = &.{} };
        pub fn init() !void {}
        pub fn deinit() void {}
    };
    const t0 = now();
    for (0..count) |_| {
        var app = try zigmodu.Application.init(io, allocator, "bench", .{M}, .{});
        try app.start();
        app.stop();
        app.deinit();
    }
    return elapsedMs(t0);
}

fn benchDbQuery(io: std.Io, allocator: std.mem.Allocator, queries: usize) !f64 {
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
    _ = try repo.findById(@as(i64, 50));
    const t0 = now();
    for (0..queries) |_| {
        if (try repo.findById(@as(i64, 50))) |r| allocator.free(r.name);
    }
    return elapsedMs(t0);
}

const BenchResult = struct {
    name: []const u8,
    unit: []const u8 = "ms",
    value: f64,
};

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
    var ctx = zigmodu.ai.SkillContext{ .allocator = allocator };
    const t0 = now();
    for (0..iterations) |_| {
        var r = try wf.run(allocator, &ctx);
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

    std.debug.print("=== ZigModu Framework Benchmarks ===\n\n", .{});

    std.debug.print("-- Module System --\n", .{});
    inline for (.{ .{ "scanModules x1K", 1000 }, .{ "scanModules x10K", 10000 } }) |tc| {
        const ms = try benchModuleScan(a, tc[1]);
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} ops/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(tc[1])) / ms * 1000.0 });
    }
    inline for (.{ .{ "validateModules x10K", 10000 }, .{ "validateModules x100K", 100000 } }) |tc| {
        const ms = try benchModuleValidation(a, tc[1]);
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} ops/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(tc[1])) / ms * 1000.0 });
    }
    {
        const ms = try benchApplicationLifecycle(io, a, 1000);
        try results.append(a, .{ .name = "App lifecycle x1K", .value = ms });
        std.debug.print("  App lifecycle x1K  {d:.2} ms  ({d:.0} ops/s)\n", .{ ms, 1000.0 / ms * 1000.0 });
    }

    std.debug.print("\n-- AI Workflow --\n", .{});
    {
        const ms = try benchWorkflow(a, io, 20, 100);
        try results.append(a, .{ .name = "workflow 20-step x100", .value = ms });
        std.debug.print("  workflow 20-step x100  {d:.2} ms\n", .{ms});
    }

    std.debug.print("\n-- Event System --\n", .{});
    inline for (.{ .{ "1L x10K events", 1, 10000 }, .{ "10L x1K events", 10, 1000 }, .{ "100L x100 events", 100, 100 } }) |tc| {
        const ms = try benchEventBus(a, tc[1], tc[2]);
        const d = tc[1] * tc[2];
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} deliveries/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(d)) / ms * 1000.0 });
    }

    std.debug.print("\n-- Resilience --\n", .{});
    inline for (.{ .{ "CircuitBreaker x100K", 100_000 }, .{ "CircuitBreaker x1M", 1_000_000 } }) |tc| {
        const ms = try benchCircuitBreaker(a, tc[1]);
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} calls/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(tc[1])) / ms * 1000.0 });
    }
    inline for (.{ .{ "RateLimiter x1M", 1_000_000 }, .{ "RateLimiter x10M", 10_000_000 } }) |tc| {
        const ms = try benchRateLimiter(a, tc[1]);
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} tries/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(tc[1])) / ms * 1000.0 });
    }

    std.debug.print("\n-- Health Checks --\n", .{});
    inline for (.{ .{ "10 checks x1K", 10, 1000 }, .{ "100 checks x1K", 100, 1000 } }) |tc| {
        const ms = try benchHealthEndpoint(a, tc[1], tc[2]);
        const t = tc[1] * tc[2];
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} checks/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(t)) / ms * 1000.0 });
    }

    std.debug.print("\n-- Database (SQLite :memory:) --\n", .{});
    inline for (.{ .{ "findById x1K", 1000 }, .{ "findById x10K", 10000 } }) |tc| {
        const ms = try benchDbQuery(io, a, tc[1]);
        try results.append(a, .{ .name = tc[0], .value = ms });
        std.debug.print("  {s}  {d:.2} ms  ({d:.0} queries/s)\n", .{ tc[0], ms, @as(f64, @floatFromInt(tc[1])) / ms * 1000.0 });
    }

    // Emit bench-results.json for CI baseline tracking
    // (github-action-benchmark `customSmallerIsBetter` format).
    const json = try std.json.Stringify.valueAlloc(a, results.items, .{});
    const file = try std.Io.Dir.cwd().createFile(io, "bench-results.json", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, json);

    std.debug.print("\nDone. Results written to bench-results.json\n", .{});
}
