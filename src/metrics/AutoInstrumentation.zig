const std = @import("std");
const PrometheusMetrics = @import("PrometheusMetrics.zig").PrometheusMetrics;
const DistributedTracer = @import("../tracing/DistributedTracer.zig").DistributedTracer;

/// Auto-instrumentation collector
/// Auto-create metrics and traces for module lifecycle, events, API calls
/// High-priority architecture improvement item
pub const AutoInstrumentation = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    metrics: *PrometheusMetrics,
    tracer: *DistributedTracer,

    // Module lifecycle metrics
    module_init_duration: *PrometheusMetrics.Histogram,
    module_init_total: *PrometheusMetrics.Counter,
    module_active_gauge: *PrometheusMetrics.Gauge,

    // Event processing metrics
    event_published_total: *PrometheusMetrics.Counter,
    event_consumed_total: *PrometheusMetrics.Counter,
    event_processing_duration: *PrometheusMetrics.Histogram,

    // API call metrics
    api_request_total: *PrometheusMetrics.Counter,
    api_request_duration: *PrometheusMetrics.Histogram,
    api_error_total: *PrometheusMetrics.Counter,

    pub fn init(allocator: std.mem.Allocator, metrics: *PrometheusMetrics, tracer: *DistributedTracer) !Self {
        // Create module lifecycle metrics
        const module_init_duration = try metrics.createHistogram("zigmodu_module_init_duration_seconds", "Module initialization duration", &.{ 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 });

        const module_init_total = try metrics.createCounter("zigmodu_module_init_total", "Module initialization count (success + failure)");

        const module_active_gauge = try metrics.createGauge("zigmodu_module_active", "Current active module count");

        // Create event processing metrics
        const event_published_total = try metrics.createCounter("zigmodu_event_published_total", "Total published events");

        const event_consumed_total = try metrics.createCounter("zigmodu_event_consumed_total", "Total consumed events");

        const event_processing_duration = try metrics.createHistogram("zigmodu_event_processing_duration_seconds", "Event processing duration", &.{ 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5 });

        // Create API call metrics
        const api_request_total = try metrics.createCounter("zigmodu_api_request_total", "Total API requests");

        const api_request_duration = try metrics.createHistogram("zigmodu_api_request_duration_seconds", "API request duration", &.{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 });

        const api_error_total = try metrics.createCounter("zigmodu_api_error_total", "Total API errors");

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

    /// Record module initialization
    pub fn recordModuleInit(self: *Self, module_name: []const u8, duration_seconds: f64, success: bool) void {
        self.module_init_duration.observe(duration_seconds);
        self.module_init_total.inc();

        if (success) {
            self.module_active_gauge.inc();
        }

        std.log.info("[AutoInstrumentation] Module {s} init done, duration: {d:.3}s, status: {s}", .{
            module_name,
            duration_seconds,
            if (success) "success" else "failure",
        });
    }

    /// Record module shutdown
    pub fn recordModuleShutdown(self: *Self, module_name: []const u8) void {
        self.module_active_gauge.dec();

        std.log.info("[AutoInstrumentation] Module {s} shutdown", .{module_name});
    }

    /// Record event published (with trace)
    pub fn recordEventPublished(self: *Self, event_name: []const u8, module_name: []const u8) !?*DistributedTracer.Span {
        self.event_published_total.inc();

        // Create trace span
        const span = try self.tracer.startTrace(try std.fmt.allocPrint(self.allocator, "event_publish:{s}", .{event_name}));
        errdefer {
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }

        try span.setAttribute(self.allocator, "event.name", event_name);
        try span.setAttribute(self.allocator, "module.name", module_name);
        try span.setAttribute(self.allocator, "event.type", "published");

        std.log.info("[AutoInstrumentation] Event {s} published from module {s}", .{ event_name, module_name });

        return span;
    }

    /// Record event consumed (with trace)
    pub fn recordEventConsumed(self: *Self, event_name: []const u8, module_name: []const u8, parent_span: ?*DistributedTracer.Span) !?*DistributedTracer.Span {
        self.event_consumed_total.inc();

        // Create trace span
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

        std.log.info("[AutoInstrumentation] Event {s} consumed by module {s}", .{ event_name, module_name });

        return span;
    }

    /// Record event processing complete
    pub fn recordEventProcessed(self: *Self, span: *DistributedTracer.Span, duration_seconds: f64, success: bool) void {
        self.event_processing_duration.observe(duration_seconds);

        if (!success) {
            span.status = .ERROR;
        } else {
            span.status = .OK;
        }

        self.tracer.endSpan(span);

        std.log.info("[AutoInstrumentation] Event processing done, duration: {d:.3}s, status: {s}", .{
            duration_seconds,
            if (success) "success" else "failure",
        });
    }

    /// Record API call start (with trace)
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

    /// Record API call complete
    pub fn recordApiRequestEnd(self: *Self, span: *DistributedTracer.Span, duration_seconds: f64, success: bool) void {
        self.api_request_duration.observe(duration_seconds);

        if (!success) {
            self.api_error_total.inc();
            span.status = .ERROR;
        } else {
            span.status = .OK;
        }

        span.addEvent(self.allocator, "api_request_complete") catch {};
        self.tracer.endSpan(span);

        std.log.info("[AutoInstrumentation] API call done, duration: {d:.3}s, status: {s}", .{
            duration_seconds,
            if (success) "success" else "failure",
        });
    }

    /// Wrap function execution, auto-record metrics and traces
    pub fn instrumentFunction(
        self: *Self,
        name: []const u8,
        comptime ResultType: type,
        func: fn () anyerror!ResultType,
    ) !ResultType {
        const start_time = 0;

        // Create trace span
        const span = try self.tracer.startTrace(name);
        defer {
            self.tracer.endSpan(span);
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }

        // Execute function
        const result = func() catch |err| {
            const duration = @as(f64, @floatFromInt(0 - start_time)) / 1e9;

            span.status = .ERROR;
            try span.setAttribute(self.allocator, "error.type", @errorName(err));

            std.log.err("[AutoInstrumentation] Function {s} failed: {s}, duration: {d:.3}s", .{
                name,
                @errorName(err),
                duration,
            });

            return err;
        };

        const duration = @as(f64, @floatFromInt(0 - start_time)) / 1e9;
        span.status = .OK;

        std.log.info("[AutoInstrumentation] Function {s} succeeded, duration: {d:.3}s", .{
            name,
            duration,
        });

        return result;
    }

    /// Get Prometheus-format metrics
    pub fn getMetrics(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        return try self.metrics.toPrometheusFormat(allocator);
    }
};

/// Module lifecycle listener (for auto-instrumentation)
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
        self.* = undefined;
    }

    /// Called before module init
    pub fn onModuleInitStart(self: *Self, module_name: []const u8) !void {
        const start_time = 0;
        try self.module_init_times.put(module_name, @intCast(start_time));

        std.log.info("[LifecycleListener] Module {s} initializing", .{module_name});
    }

    /// Called after module init
    pub fn onModuleInitEnd(self: *Self, module_name: []const u8, success: bool) void {
        const start_time = self.module_init_times.get(module_name) orelse 0;
        const duration = @as(f64, @floatFromInt(0 - start_time)) / 1e9;

        self.instrumentation.recordModuleInit(module_name, duration, success);
        _ = self.module_init_times.remove(module_name);
    }

    /// Called before module shutdown
    pub fn onModuleShutdown(self: *Self, module_name: []const u8) void {
        self.instrumentation.recordModuleShutdown(module_name);
    }
};

/// Event listener (for auto-instrumentation)
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
        var span_iter = self.event_processing_spans.iterator();
        while (span_iter.next()) |entry| {
            self.event_processing_spans.allocator.free(entry.key_ptr.*);
        }
        self.event_processing_spans.deinit();

        var time_iter = self.event_start_times.iterator();
        while (time_iter.next()) |entry| {
            self.event_start_times.allocator.free(entry.key_ptr.*);
        }
        self.event_start_times.deinit();
        self.* = undefined;
    }

    /// Called on event publish
    pub fn onEventPublished(self: *Self, event_name: []const u8, module_name: []const u8) !void {
        const span = try self.instrumentation.recordEventPublished(event_name, module_name);
        if (span) |s| {
            const key = try std.fmt.allocPrint(self.event_processing_spans.allocator, "{s}:{s}", .{ event_name, module_name });
            try self.event_processing_spans.put(key, s);
        }
    }

    /// Called on event consumption start
    pub fn onEventConsumeStart(self: *Self, event_name: []const u8, module_name: []const u8) !void {
        // Look up publish-time span as parent
        const pub_key = try std.fmt.allocPrint(self.event_processing_spans.allocator, "{s}:{s}", .{ event_name, module_name });
        defer self.event_processing_spans.allocator.free(pub_key);
        const parent_span = self.event_processing_spans.get(pub_key);

        const span = try self.instrumentation.recordEventConsumed(event_name, module_name, parent_span);

        if (span) |s| {
            const key = try std.fmt.allocPrint(self.event_processing_spans.allocator, "consume:{s}:{s}", .{ event_name, module_name });
            try self.event_processing_spans.put(key, s);
            try self.event_start_times.put(key, 0);
        }
    }

    /// Called on event consumption complete
    pub fn onEventConsumeEnd(self: *Self, event_name: []const u8, module_name: []const u8, success: bool) void {
        const key = std.fmt.allocPrint(self.event_start_times.allocator, "consume:{s}:{s}", .{ event_name, module_name }) catch return;
        defer self.event_start_times.allocator.free(key);

        const start_time = self.event_start_times.get(key) orelse 0;
        const duration = @as(f64, @floatFromInt(0 - start_time)) / 1e9;

        if (self.event_processing_spans.get(key)) |span| {
            self.instrumentation.recordEventProcessed(span, duration, success);
            _ = self.event_processing_spans.remove(key);
            _ = self.event_start_times.remove(key);
        }
    }
};

// Tests
test "AutoInstrumentation basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
    defer tracer.deinit();

    var instrumentation = try AutoInstrumentation.init(allocator, &metrics, &tracer);

    // Test module init recording
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
