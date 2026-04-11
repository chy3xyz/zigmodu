const std = @import("std");
const PrometheusMetrics = @import("../metrics/PrometheusMetrics.zig");
const DistributedTracer = @import("../tracing/DistributedTracer.zig");

/// 自动埋点器
/// 自动为模块生命周期、事件处理、API调用等创建指标和链路追踪
/// 这是架构评估中的高优先级改进项
pub const AutoInstrumentation = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    metrics: *PrometheusMetrics,
    tracer: *DistributedTracer,

    // 模块生命周期指标
    module_init_duration: *PrometheusMetrics.Histogram,
    module_init_total: *PrometheusMetrics.Counter,
    module_active_gauge: *PrometheusMetrics.Gauge,

    // 事件处理指标
    event_published_total: *PrometheusMetrics.Counter,
    event_consumed_total: *PrometheusMetrics.Counter,
    event_processing_duration: *PrometheusMetrics.Histogram,

    // API调用指标
    api_request_total: *PrometheusMetrics.Counter,
    api_request_duration: *PrometheusMetrics.Histogram,
    api_error_total: *PrometheusMetrics.Counter,

    pub fn init(allocator: std.mem.Allocator, metrics: *PrometheusMetrics, tracer: *DistributedTracer) !Self {
        // 创建模块生命周期指标
        const module_init_duration = try metrics.createHistogram("zigmodu_module_init_duration_seconds", "模块初始化耗时", &.{ 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 });

        const module_init_total = try metrics.createCounter("zigmodu_module_init_total", "模块初始化次数（包括成功和失败）");

        const module_active_gauge = try metrics.createGauge("zigmodu_module_active", "当前活跃的模块数量");

        // 创建事件处理指标
        const event_published_total = try metrics.createCounter("zigmodu_event_published_total", "发布的事件总数");

        const event_consumed_total = try metrics.createCounter("zigmodu_event_consumed_total", "消费的事件总数");

        const event_processing_duration = try metrics.createHistogram("zigmodu_event_processing_duration_seconds", "事件处理耗时", &.{ 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5 });

        // 创建API调用指标
        const api_request_total = try metrics.createCounter("zigmodu_api_request_total", "API请求总数");

        const api_request_duration = try metrics.createHistogram("zigmodu_api_request_duration_seconds", "API请求耗时", &.{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 });

        const api_error_total = try metrics.createCounter("zigmodu_api_error_total", "API错误总数");

        return .{
            .allocator = allocator,
            .metrics = metrics,
            .tracer = tracer,
            .module_init_duration = module_init_duration,
            .module_init_total = module_init_total,
            .module_active_gauge = module_active_gauge,
            .event_published_total = event_published_total,
            .event_consumed_total = event_consumed_total,
            .event_processing_duration = event_processing_duration,
            .api_request_total = api_request_total,
            .api_request_duration = api_request_duration,
            .api_error_total = api_error_total,
        };
    }

    /// 记录模块初始化
    pub fn recordModuleInit(self: *Self, module_name: []const u8, duration_seconds: f64, success: bool) void {
        self.module_init_duration.observe(duration_seconds);
        self.module_init_total.inc();

        if (success) {
            self.module_active_gauge.inc();
        }

        std.log.info("[AutoInstrumentation] 模块 {s} 初始化完成，耗时: {d:.3}s，状态: {s}", .{
            module_name,
            duration_seconds,
            if (success) "成功" else "失败",
        });
    }

    /// 记录模块关闭
    pub fn recordModuleShutdown(self: *Self, module_name: []const u8) void {
        self.module_active_gauge.dec();

        std.log.info("[AutoInstrumentation] 模块 {s} 已关闭", .{module_name});
    }

    /// 记录事件发布（带链路追踪）
    pub fn recordEventPublished(self: *Self, event_name: []const u8, module_name: []const u8) !?*DistributedTracer.Span {
        self.event_published_total.inc();

        // 创建链路追踪 Span
        const span = try self.tracer.startTrace(try std.fmt.allocPrint(self.allocator, "event_publish:{s}", .{event_name}));
        errdefer {
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }

        try span.setAttribute(self.allocator, "event.name", event_name);
        try span.setAttribute(self.allocator, "module.name", module_name);
        try span.setAttribute(self.allocator, "event.type", "published");

        std.log.info("[AutoInstrumentation] 事件 {s} 从模块 {s} 发布", .{ event_name, module_name });

        return span;
    }

    /// 记录事件消费（带链路追踪）
    pub fn recordEventConsumed(self: *Self, event_name: []const u8, module_name: []const u8, parent_span: ?*DistributedTracer.Span) !?*DistributedTracer.Span {
        self.event_consumed_total.inc();

        // 创建链路追踪 Span
        const span = if (parent_span) |parent|
            try self.tracer.startSpan(parent, try std.fmt.allocPrint(self.allocator, "event_consume:{s}", .{event_name}))
        else
            try self.tracer.startTrace(try std.fmt.allocPrint(self.allocator, "event_consume:{s}", .{event_name}));

        errdefer {
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }

        try span.setAttribute(self.allocator, "event.name", event_name);
        try span.setAttribute(self.allocator, "module.name", module_name);
        try span.setAttribute(self.allocator, "event.type", "consumed");

        std.log.info("[AutoInstrumentation] 事件 {s} 被模块 {s} 消费", .{ event_name, module_name });

        return span;
    }

    /// 记录事件处理完成
    pub fn recordEventProcessed(self: *Self, span: *DistributedTracer.Span, duration_seconds: f64, success: bool) void {
        self.event_processing_duration.observe(duration_seconds);

        if (!success) {
            span.status = .ERROR;
        } else {
            span.status = .OK;
        }

        self.tracer.endSpan(span);

        std.log.info("[AutoInstrumentation] 事件处理完成，耗时: {d:.3}s，状态: {s}", .{
            duration_seconds,
            if (success) "成功" else "失败",
        });
    }

    /// 记录API调用开始（带链路追踪）
    pub fn recordApiRequestStart(self: *Self, api_name: []const u8, module_name: []const u8) !*DistributedTracer.Span {
        self.api_request_total.inc();

        const span = try self.tracer.startTrace(try std.fmt.allocPrint(self.allocator, "api:{s}", .{api_name}));
        errdefer {
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }

        try span.setAttribute(self.allocator, "api.name", api_name);
        try span.setAttribute(self.allocator, "module.name", module_name);

        return span;
    }

    /// 记录API调用完成
    pub fn recordApiRequestEnd(self: *Self, span: *DistributedTracer.Span, duration_seconds: f64, success: bool) void {
        self.api_request_duration.observe(duration_seconds);

        if (!success) {
            self.api_error_total.inc();
            span.status = .ERROR;
        } else {
            span.status = .OK;
        }

        try span.addEvent(self.allocator, "api_request_complete");
        self.tracer.endSpan(span);

        std.log.info("[AutoInstrumentation] API调用完成，耗时: {d:.3}s，状态: {s}", .{
            duration_seconds,
            if (success) "成功" else "失败",
        });
    }

    /// 包装函数执行，自动记录指标和追踪
    pub fn instrumentFunction(
        self: *Self,
        name: []const u8,
        comptime ResultType: type,
        func: fn () anyerror!ResultType,
    ) !ResultType {
        const start_time = std.time.nanoTimestamp();

        // 创建追踪 Span
        const span = try self.tracer.startTrace(name);
        defer {
            self.tracer.endSpan(span);
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }

        // 执行函数
        const result = func() catch |err| {
            const duration = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1e9;

            span.status = .ERROR;
            try span.setAttribute(self.allocator, "error.type", @errorName(err));

            std.log.err("[AutoInstrumentation] 函数 {s} 执行失败: {s}，耗时: {d:.3}s", .{
                name,
                @errorName(err),
                duration,
            });

            return err;
        };

        const duration = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1e9;
        span.status = .OK;

        std.log.info("[AutoInstrumentation] 函数 {s} 执行成功，耗时: {d:.3}s", .{
            name,
            duration,
        });

        return result;
    }

    /// 获取Prometheus格式的指标
    pub fn getMetrics(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        return try self.metrics.toPrometheusFormat(allocator);
    }
};

/// 模块生命周期监听器（用于自动埋点）
pub const InstrumentedLifecycleListener = struct {
    const Self = @This();

    instrumentation: *AutoInstrumentation,
    module_init_times: std.StringHashMap(i64),

    pub fn init(allocator: std.mem.Allocator, instrumentation: *AutoInstrumentation) Self {
        return .{
            .instrumentation = instrumentation,
            .module_init_times = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.module_init_times.deinit();
    }

    /// 模块初始化前调用
    pub fn onModuleInitStart(self: *Self, module_name: []const u8) !void {
        const start_time = std.time.nanoTimestamp();
        try self.module_init_times.put(module_name, start_time);

        std.log.info("[LifecycleListener] 模块 {s} 开始初始化", .{module_name});
    }

    /// 模块初始化后调用
    pub fn onModuleInitEnd(self: *Self, module_name: []const u8, success: bool) void {
        const start_time = self.module_init_times.get(module_name) orelse std.time.nanoTimestamp();
        const duration = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1e9;

        self.instrumentation.recordModuleInit(module_name, duration, success);
        _ = self.module_init_times.remove(module_name);
    }

    /// 模块关闭前调用
    pub fn onModuleShutdown(self: *Self, module_name: []const u8) void {
        self.instrumentation.recordModuleShutdown(module_name);
    }
};

/// 事件监听器（用于自动埋点）
pub const InstrumentedEventListener = struct {
    const Self = @This();

    instrumentation: *AutoInstrumentation,
    event_processing_spans: std.StringHashMap(*DistributedTracer.Span),
    event_start_times: std.StringHashMap(i64),

    pub fn init(allocator: std.mem.Allocator, instrumentation: *AutoInstrumentation) Self {
        return .{
            .instrumentation = instrumentation,
            .event_processing_spans = std.StringHashMap(*DistributedTracer.Span).init(allocator),
            .event_start_times = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.event_processing_spans.deinit();
        self.event_start_times.deinit();
    }

    /// 事件发布时调用
    pub fn onEventPublished(self: *Self, event_name: []const u8, module_name: []const u8) !void {
        const span = try self.instrumentation.recordEventPublished(event_name, module_name);
        if (span) |s| {
            const key = try std.fmt.allocPrint(self.event_processing_spans.allocator, "{s}:{s}", .{ event_name, module_name });
            try self.event_processing_spans.put(key, s);
        }
    }

    /// 事件消费开始时调用
    pub fn onEventConsumeStart(self: *Self, event_name: []const u8, module_name: []const u8) !void {
        // 查找发布时的 span 作为父 span
        const pub_key = try std.fmt.allocPrint(self.event_processing_spans.allocator, "{s}:{s}", .{ event_name, module_name });
        const parent_span = self.event_processing_spans.get(pub_key);

        const span = try self.instrumentation.recordEventConsumed(event_name, module_name, parent_span);

        if (span) |s| {
            const key = try std.fmt.allocPrint(self.event_processing_spans.allocator, "consume:{s}:{s}", .{ event_name, module_name });
            try self.event_processing_spans.put(key, s);
            try self.event_start_times.put(key, std.time.nanoTimestamp());
        }
    }

    /// 事件消费完成时调用
    pub fn onEventConsumeEnd(self: *Self, event_name: []const u8, module_name: []const u8, success: bool) void {
        const key = std.fmt.allocPrint(self.event_start_times.allocator, "consume:{s}:{s}", .{ event_name, module_name }) catch return;
        defer self.event_start_times.allocator.free(key);

        const start_time = self.event_start_times.get(key) orelse std.time.nanoTimestamp();
        const duration = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1e9;

        if (self.event_processing_spans.get(key)) |span| {
            self.instrumentation.recordEventProcessed(span, duration, success);
            _ = self.event_processing_spans.remove(key);
            _ = self.event_start_times.remove(key);
        }
    }
};

// 测试
test "AutoInstrumentation basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
    defer tracer.deinit();

    var instrumentation = try AutoInstrumentation.init(allocator, &metrics, &tracer);

    // 测试模块初始化记录
    instrumentation.recordModuleInit("test_module", 0.5, true);

    try testing.expectEqual(@as(u64, 1), instrumentation.module_init_total.get());
    try testing.expectEqual(@as(f64, 1.0), instrumentation.module_active_gauge.get());
}

test "InstrumentedLifecycleListener" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
    defer tracer.deinit();

    var instrumentation = try AutoInstrumentation.init(allocator, &metrics, &tracer);

    var listener = InstrumentedLifecycleListener.init(allocator, &instrumentation);
    defer listener.deinit();

    try listener.onModuleInitStart("test_module");
    listener.onModuleInitEnd("test_module", true);

    try testing.expectEqual(@as(u64, 1), instrumentation.module_init_total.get());
}
