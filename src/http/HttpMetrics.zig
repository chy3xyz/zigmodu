const std = @import("std");

/// HTTP Metrics 中间件 — 使用内置收集器自动收集请求计数和延迟
///
/// 用法:
///   var collector = HttpMetricsCollector.init();
///   server.addMiddleware(.{ .func = httpMetricsMiddleware(&collector) });
pub fn httpMetricsMiddleware(collector: *HttpMetricsCollector) api.MiddlewareFn {
    const S = struct {
        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            const c: *HttpMetricsCollector = @ptrCast(@alignCast(user_data orelse return error.InternalError));
            const start = @import("../core/Time.zig").monotonicNowSeconds();

            c.in_flight += 1;

            next(ctx, next, null) catch |err| {
                c.in_flight -= 1;
                const elapsed = @import("../core/Time.zig").monotonicNowSeconds() - start;
                c.recordRequest(500, @floatFromInt(elapsed));
                return err;
            };

            c.in_flight -= 1;
            const elapsed = @import("../core/Time.zig").monotonicNowSeconds() - start;
            c.recordRequest(200, @floatFromInt(elapsed));
        }
    };

    return .{ .func = S.handler, .user_data = @ptrCast(@constCast(collector)) };
}

/// HTTP Metrics 收集器 (简化版 — 不依赖 PrometheusMetrics)
/// 适用于需要轻量级指标但不引入 Prometheus 的场景
pub const HttpMetricsCollector = struct {
    const Self = @This();

    /// 请求计数器
    request_count: u64 = 0,
    /// 按状态码分类的计数
    status_counts: [6]u64 = @splat(0),
    /// 总延迟 (秒)
    total_duration_seconds: f64 = 0,
    /// 最小延迟 (秒)
    min_duration_seconds: f64 = std.math.floatMax(f64),
    /// 最大延迟 (秒)
    max_duration_seconds: f64 = 0,
    /// 活跃请求数
    in_flight: u64 = 0,

    const StatusBucket = enum(usize) {
        info = 0, // 1xx
        success = 1, // 2xx
        redirect = 2, // 3xx
        client_error = 3, // 4xx
        server_error = 4, // 5xx
        unknown = 5,
    };

    pub fn init() Self {
        return .{};
    }

    /// 记录一次请求
    pub fn recordRequest(self: *Self, status: u16, duration_seconds: f64) void {
        self.request_count += 1;
        self.total_duration_seconds += duration_seconds;
        self.min_duration_seconds = @min(self.min_duration_seconds, duration_seconds);
        self.max_duration_seconds = @max(self.max_duration_seconds, duration_seconds);

        const bucket: usize = switch (status) {
            100...199 => @intFromEnum(StatusBucket.info),
            200...299 => @intFromEnum(StatusBucket.success),
            300...399 => @intFromEnum(StatusBucket.redirect),
            400...499 => @intFromEnum(StatusBucket.client_error),
            500...599 => @intFromEnum(StatusBucket.server_error),
            else => @intFromEnum(StatusBucket.unknown),
        };
        self.status_counts[bucket] += 1;
    }

    /// 平均延迟
    pub fn avgDuration(self: *Self) f64 {
        if (self.request_count == 0) return 0;
        return self.total_duration_seconds / @as(f64, @floatFromInt(self.request_count));
    }

    /// 请求速率 (req/s — 调用方提供 elapsed_seconds)
    pub fn requestRate(self: *Self, elapsed_seconds: f64) f64 {
        if (elapsed_seconds == 0) return 0;
        return @as(f64, @floatFromInt(self.request_count)) / elapsed_seconds;
    }

    /// 生成可读报告
    pub fn generateReport(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);

        const Emit = struct {
            fn f(target: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
                const s = try std.fmt.allocPrint(alloc, fmt, args);
                defer alloc.free(s);
                try target.appendSlice(alloc, s);
            }
        };

        try buf.appendSlice(allocator, "═══════════════════════════════════\n");
        try buf.appendSlice(allocator, "  HTTP Metrics Report\n");
        try buf.appendSlice(allocator, "═══════════════════════════════════\n\n");

        try Emit.f(&buf, allocator, "  Total Requests:    {d}\n", .{self.request_count});
        try Emit.f(&buf, allocator, "  In Flight:         {d}\n", .{self.in_flight});
        try Emit.f(&buf, allocator, "  2xx Responses:     {d}\n", .{self.status_counts[@intFromEnum(StatusBucket.success)]});
        try Emit.f(&buf, allocator, "  4xx Responses:     {d}\n", .{self.status_counts[@intFromEnum(StatusBucket.client_error)]});
        try Emit.f(&buf, allocator, "  5xx Responses:     {d}\n", .{self.status_counts[@intFromEnum(StatusBucket.server_error)]});
        try Emit.f(&buf, allocator, "  Avg Duration:      {d:.3}ms\n", .{self.avgDuration() * 1000});
        try Emit.f(&buf, allocator, "  Min Duration:      {d:.3}ms\n", .{self.min_duration_seconds * 1000});
        try Emit.f(&buf, allocator, "  Max Duration:      {d:.3}ms\n", .{self.max_duration_seconds * 1000});

        return buf.toOwnedSlice(allocator);
    }
};

const api = @import("../api/Server.zig");

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "HttpMetricsCollector record and stats" {
    var collector = HttpMetricsCollector.init();

    collector.recordRequest(200, 0.010);
    collector.recordRequest(200, 0.020);
    collector.recordRequest(404, 0.005);
    collector.recordRequest(500, 0.100);
    collector.recordRequest(201, 0.015);

    try std.testing.expectEqual(@as(u64, 5), collector.request_count);
    try std.testing.expectEqual(@as(u64, 3), collector.status_counts[@intFromEnum(HttpMetricsCollector.StatusBucket.success)]);
    try std.testing.expectEqual(@as(u64, 1), collector.status_counts[@intFromEnum(HttpMetricsCollector.StatusBucket.client_error)]);
    try std.testing.expectEqual(@as(u64, 1), collector.status_counts[@intFromEnum(HttpMetricsCollector.StatusBucket.server_error)]);
}

test "HttpMetricsCollector avg duration" {
    var collector = HttpMetricsCollector.init();

    collector.recordRequest(200, 0.100);
    collector.recordRequest(200, 0.200);
    collector.recordRequest(200, 0.300);

    const avg = collector.avgDuration();
    try std.testing.expect(avg > 0.19 and avg < 0.21);
}

test "HttpMetricsCollector request rate" {
    var collector = HttpMetricsCollector.init();

    collector.recordRequest(200, 0.001);
    collector.recordRequest(200, 0.001);

    const rate = collector.requestRate(1.0); // 2 requests in 1 second
    try std.testing.expectEqual(@as(f64, 2.0), rate);
}

test "HttpMetricsCollector generate report" {
    const allocator = std.testing.allocator;
    var collector = HttpMetricsCollector.init();

    collector.recordRequest(200, 0.010);
    collector.recordRequest(404, 0.005);

    const report = try collector.generateReport(allocator);
    defer allocator.free(report);

    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "HTTP Metrics Report"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "Total Requests"));
}
