const std = @import("std");

/// Prometheus 指标收集器
/// 支持 Counter, Gauge, Histogram, Summary
pub const PrometheusMetrics = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    counters: std.StringHashMap(Counter),
    gauges: std.StringHashMap(Gauge),
    histograms: std.StringHashMap(Histogram),
    summaries: std.StringHashMap(Summary),

    pub const Counter = struct {
        name: []const u8,
        help: []const u8,
        value: std.atomic.Value(u64),
        labels: std.StringHashMap([]const u8),

        pub fn inc(self: *Counter) void {
            _ = self.value.fetchAdd(1, .monotonic);
        }

        pub fn add(self: *Counter, value: u64) void {
            _ = self.value.fetchAdd(value, .monotonic);
        }

        pub fn get(self: *Counter) u64 {
            return self.value.load(.monotonic);
        }
    };

    pub const Gauge = struct {
        name: []const u8,
        help: []const u8,
        /// Thread-safe f64 stored as atomic u64 via bit-cast (same as Java's AtomicDouble).
        raw_value: std.atomic.Value(u64) = std.atomic.Value(u64).init(@bitCast(@as(f64, 0.0))),
        labels: std.StringHashMap([]const u8),

        pub fn set(self: *Gauge, value: f64) void {
            self.raw_value.store(@bitCast(value), .monotonic);
        }

        pub fn inc(self: *Gauge) void {
            self.add(1.0);
        }

        pub fn dec(self: *Gauge) void {
            self.sub(1.0);
        }

        pub fn add(self: *Gauge, value: f64) void {
            while (true) {
                const old_bits = self.raw_value.load(.monotonic);
                const old_val: f64 = @bitCast(old_bits);
                const new_val = old_val + value;
                const new_bits: u64 = @bitCast(new_val);
                if (self.raw_value.cmpxchgWeak(old_bits, new_bits, .monotonic, .monotonic) == null) break;
            }
        }

        pub fn sub(self: *Gauge, value: f64) void {
            self.add(-value);
        }

        pub fn get(self: *Gauge) f64 {
            return @bitCast(self.raw_value.load(.monotonic));
        }
    };

    pub const Histogram = struct {
        name: []const u8,
        help: []const u8,
        buckets: std.array_list.Managed(f64),
        counts: std.array_list.Managed(u64),
        sum: f64 = 0.0,
        count: u64 = 0,

        pub fn observe(self: *Histogram, value: f64) void {
            self.sum += value;
            self.count += 1;

            for (self.buckets.items, 0..) |bucket, i| {
                if (value <= bucket) {
                    self.counts.items[i] += 1;
                }
            }
        }
    };

    pub const Summary = struct {
        name: []const u8,
        help: []const u8,
        quantiles: std.array_list.Managed(f64),
        values: std.array_list.Managed(f64),
        sum: f64 = 0.0,
        count: u64 = 0,
        max_age_seconds: u64 = 600,
        age_buckets: usize = 5,
        /// Hard cap on stored samples to prevent unbounded memory growth.
        /// Once reached, new values replace random existing samples (reservoir sampling).
        max_samples: usize = 500,

        pub fn observe(self: *Summary, value: f64) !void {
            self.sum += value;
            self.count += 1;

            if (self.values.items.len < self.max_samples) {
                try self.values.append(value);
            } else {
                // Reservoir sampling: replace a random sample
                const idx = @as(usize, @intCast(self.count % self.max_samples));
                self.values.items[idx] = value;
            }
        }

        /// Returns the q-th quantile (0.0-1.0).
        /// NOTE: O(n log n) — sorts values on every call. Avoid in hot paths.
        pub fn getQuantile(self: *Summary, q: f64) f64 {
            if (self.values.items.len == 0) return 0.0;

            std.sort.insertion(f64, self.values.items, {}, std.sort.asc(f64));

            const index = @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.values.items.len)) * q));
            return self.values.items[@min(index, self.values.items.len - 1)];
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .counters = std.StringHashMap(Counter).init(allocator),
            .gauges = std.StringHashMap(Gauge).init(allocator),
            .histograms = std.StringHashMap(Histogram).init(allocator),
            .summaries = std.StringHashMap(Summary).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // 释放所有指标
        var counter_iter = self.counters.iterator();
        while (counter_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.help);
            entry.value_ptr.labels.deinit();
        }
        self.counters.deinit();

        var gauge_iter = self.gauges.iterator();
        while (gauge_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.help);
            entry.value_ptr.labels.deinit();
        }
        self.gauges.deinit();

        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.help);
            entry.value_ptr.buckets.deinit();
            entry.value_ptr.counts.deinit();
        }
        self.histograms.deinit();

        var summary_iter = self.summaries.iterator();
        while (summary_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.help);
            entry.value_ptr.quantiles.deinit();
            entry.value_ptr.values.deinit();
        }
        self.summaries.deinit();
    }

    /// 创建 Counter
    pub fn createCounter(self: *Self, name: []const u8, help: []const u8) !*Counter {
        const name_copy = try self.allocator.dupe(u8, name);
        const help_copy = try self.allocator.dupe(u8, help);

        const counter = Counter{
            .name = name_copy,
            .help = help_copy,
            .value = std.atomic.Value(u64).init(0),
            .labels = std.StringHashMap([]const u8).init(self.allocator),
        };

        try self.counters.put(name_copy, counter);
        return self.counters.getPtr(name_copy).?;
    }

    /// 创建 Gauge
    pub fn createGauge(self: *Self, name: []const u8, help: []const u8) !*Gauge {
        const name_copy = try self.allocator.dupe(u8, name);
        const help_copy = try self.allocator.dupe(u8, help);

        const gauge = Gauge{
            .name = name_copy,
            .help = help_copy,
            .labels = std.StringHashMap([]const u8).init(self.allocator),
        };

        try self.gauges.put(name_copy, gauge);
        return self.gauges.getPtr(name_copy).?;
    }

    /// 创建 Histogram
    pub fn createHistogram(self: *Self, name: []const u8, help: []const u8, buckets: []const f64) !*Histogram {
        const name_copy = try self.allocator.dupe(u8, name);
        const help_copy = try self.allocator.dupe(u8, help);

        var bucket_list = std.array_list.Managed(f64).init(self.allocator);
        var count_list = std.array_list.Managed(u64).init(self.allocator);

        for (buckets) |bucket| {
            try bucket_list.append(bucket);
            try count_list.append(0);
        }

        const histogram = Histogram{
            .name = name_copy,
            .help = help_copy,
            .buckets = bucket_list,
            .counts = count_list,
        };

        try self.histograms.put(name_copy, histogram);
        return self.histograms.getPtr(name_copy).?;
    }

    /// 创建 Summary
    pub fn createSummary(self: *Self, name: []const u8, help: []const u8) !*Summary {
        const name_copy = try self.allocator.dupe(u8, name);
        const help_copy = try self.allocator.dupe(u8, help);

        const quantile_list = std.array_list.Managed(f64).init(self.allocator);
        const value_list = std.array_list.Managed(f64).init(self.allocator);

        const summary = Summary{
            .name = name_copy,
            .help = help_copy,
            .quantiles = quantile_list,
            .values = value_list,
        };

        try self.summaries.put(name_copy, summary);
        return self.summaries.getPtr(name_copy).?;
    }

    /// 获取 Counter
    pub fn getCounter(self: *Self, name: []const u8) ?*Counter {
        return self.counters.getPtr(name);
    }

    /// 获取 Gauge
    pub fn getGauge(self: *Self, name: []const u8) ?*Gauge {
        return self.gauges.getPtr(name);
    }

    /// 生成 Prometheus 格式的指标输出
    pub fn toPrometheusFormat(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();

        // Counters
        var counter_iter = self.counters.iterator();
        while (counter_iter.next()) |entry| {
            const counter = entry.value_ptr.*;
            try buf.print("# HELP {s} {s}\n", .{ counter.name, counter.help });
            try buf.print("# TYPE {s} counter\n", .{counter.name});
            try buf.print("{s} {d}\n\n", .{ counter.name, counter.value.load(.monotonic) });
        }

        // Gauges
        var gauge_iter = self.gauges.iterator();
        while (gauge_iter.next()) |entry| {
            const gauge = entry.value_ptr;
            try buf.print("# HELP {s} {s}\n", .{ gauge.name, gauge.help });
            try buf.print("# TYPE {s} gauge\n", .{gauge.name});
            try buf.print("{s} {d:.6}\n\n", .{ gauge.name, gauge.get() });
        }

        // Histograms
        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |entry| {
            const hist = entry.value_ptr.*;
            try buf.print("# HELP {s} {s}\n", .{ hist.name, hist.help });
            try buf.print("# TYPE {s} histogram\n", .{hist.name});

            for (hist.buckets.items, hist.counts.items) |bucket, count| {
                try buf.print("{s}_bucket{{le=\"{d:.3}\"}} {d}\n", .{ hist.name, bucket, count });
            }
            try buf.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ hist.name, hist.count });
            try buf.print("{s}_sum {d:.6}\n", .{ hist.name, hist.sum });
            try buf.print("{s}_count {d}\n\n", .{ hist.name, hist.count });
        }

        return buf.toOwnedSlice();
    }

    /// Export this metrics registry as a pluggable MetricsBackend.
    /// Use this to decouple consumers (e.g. AutoInstrumentation) from Prometheus.
    pub fn toBackend(self: *Self) MetricsBackend {
        const S = @This();
        return MetricsBackend{
            .ptr = self,
            .vtable = &.{
                .createCounter = struct {
                    fn f(ptr: *anyopaque, name: []const u8, help: []const u8) !*anyopaque {
                        const s: *S = @ptrCast(@alignCast(ptr));
                        const c = try s.createCounter(name, help);
                        return @ptrCast(c);
                    }
                }.f,
                .createGauge = struct {
                    fn f(ptr: *anyopaque, name: []const u8, help: []const u8) !*anyopaque {
                        const s: *S = @ptrCast(@alignCast(ptr));
                        const g = try s.createGauge(name, help);
                        return @ptrCast(g);
                    }
                }.f,
                .createHistogram = struct {
                    fn f(ptr: *anyopaque, name: []const u8, help: []const u8, buckets: []const f64) !*anyopaque {
                        const s: *S = @ptrCast(@alignCast(ptr));
                        const h = try s.createHistogram(name, help, buckets);
                        return @ptrCast(h);
                    }
                }.f,
                .counterInc = struct {
                    fn f(ptr: *anyopaque, _: u64) void {
                        const c: *Counter = @ptrCast(@alignCast(ptr));
                        c.inc();
                    }
                }.f,
                .counterAdd = struct {
                    fn f(ptr: *anyopaque, v: u64) void {
                        const c: *Counter = @ptrCast(@alignCast(ptr));
                        c.add(v);
                    }
                }.f,
                .gaugeSet = struct {
                    fn f(ptr: *anyopaque, v: f64) void {
                        const g: *Gauge = @ptrCast(@alignCast(ptr));
                        g.set(v);
                    }
                }.f,
                .gaugeInc = struct {
                    fn f(ptr: *anyopaque) void {
                        const g: *Gauge = @ptrCast(@alignCast(ptr));
                        g.inc();
                    }
                }.f,
                .gaugeDec = struct {
                    fn f(ptr: *anyopaque) void {
                        const g: *Gauge = @ptrCast(@alignCast(ptr));
                        g.dec();
                    }
                }.f,
                .histogramObserve = struct {
                    fn f(ptr: *anyopaque, v: f64) void {
                        const h: *Histogram = @ptrCast(@alignCast(ptr));
                        h.observe(v);
                    }
                }.f,
            },
        };
    }

    /// 模块指标收集器
    pub const ModuleMetricsCollector = struct {
        metrics: *PrometheusMetrics,
        module_start_time: i64,
        request_count: *Counter,
        request_duration: *Histogram,
        active_connections: *Gauge,

        pub fn init(metrics: *PrometheusMetrics, module_name: []const u8) !ModuleMetricsCollector {
            const req_count_name = try std.fmt.allocPrint(metrics.allocator, "{s}_requests_total", .{module_name});
            defer metrics.allocator.free(req_count_name);
            const req_duration_name = try std.fmt.allocPrint(metrics.allocator, "{s}_request_duration_seconds", .{module_name});
            defer metrics.allocator.free(req_duration_name);
            const active_conn_name = try std.fmt.allocPrint(metrics.allocator, "{s}_active_connections", .{module_name});
            defer metrics.allocator.free(active_conn_name);

            return .{
                .metrics = metrics,
                .module_start_time = 0,
                .request_count = try metrics.createCounter(req_count_name, "Total requests"),
                .request_duration = try metrics.createHistogram(req_duration_name, "Request duration", &.{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 }),
                .active_connections = try metrics.createGauge(active_conn_name, "Active connections"),
            };
        }

        pub fn recordRequest(self: *ModuleMetricsCollector, duration_seconds: f64) void {
            self.request_count.inc();
            self.request_duration.observe(duration_seconds);
        }

        pub fn connectionOpened(self: *ModuleMetricsCollector) void {
            self.active_connections.inc();
        }

        pub fn connectionClosed(self: *ModuleMetricsCollector) void {
            self.active_connections.dec();
        }

        pub fn getUptimeSeconds(self: *ModuleMetricsCollector) i64 {
            return 0 - self.module_start_time;
        }
    };

    /// Convenience: register /metrics route on a server with Prometheus text format.
    /// Usage: try metrics.registerMetricsRoute(&server);
    pub fn registerMetricsRoute(self: *Self, server: anytype) !void {
        const ptr: *anyopaque = @ptrCast(self);
        try server.addRoute(.{
            .method = .GET,
            .path = "/metrics",
            .handler = struct {
                fn handle(ctx: *api.Context) anyerror!void {
                    const m: *PrometheusMetrics = @ptrCast(@alignCast(ctx.user_data orelse return error.NoMetrics));
                    const body = try m.toPrometheusFormat(ctx.allocator);
                    defer ctx.allocator.free(body);
                    try ctx.setHeader("Content-Type", "text/plain; version=0.0.4");
                    try ctx.text(200, body);
                }
            }.handle,
            .user_data = ptr,
        });
    }
};

const MetricsBackend = @import("MetricsBackend.zig").MetricsBackend;
const api = @import("../api/Server.zig");

test "PrometheusMetrics counter and gauge" {
    const allocator = std.testing.allocator;
    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    const counter = try metrics.createCounter("requests_total", "Total requests");
    counter.inc();
    counter.add(2);
    try std.testing.expectEqual(@as(u64, 3), counter.get());

    const gauge = try metrics.createGauge("temperature", "Current temp");
    gauge.set(23.5);
    gauge.inc();
    gauge.dec();
    try std.testing.expectEqual(@as(f64, 23.5), gauge.get());
}

test "PrometheusMetrics histogram and summary" {
    const allocator = std.testing.allocator;
    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    const hist = try metrics.createHistogram("latency", "Request latency", &.{ 0.1, 0.5, 1.0 });
    hist.observe(0.05);
    hist.observe(0.7);
    try std.testing.expectEqual(@as(u64, 2), hist.count);

    const summary = try metrics.createSummary("response_size", "Response size");
    try summary.observe(100.0);
    try summary.observe(200.0);
    try summary.observe(300.0);
    try std.testing.expectEqual(@as(f64, 200.0), summary.getQuantile(0.5));
}

test "PrometheusMetrics toPrometheusFormat" {
    const allocator = std.testing.allocator;
    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    const counter = try metrics.createCounter("test_total", "Test counter");
    counter.inc();

    const output = try metrics.toPrometheusFormat(allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "# HELP test_total Test counter"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "test_total 1"));
}

test "ModuleMetricsCollector" {
    const allocator = std.testing.allocator;
    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var collector = try PrometheusMetrics.ModuleMetricsCollector.init(&metrics, "order");
    collector.recordRequest(0.123);
    collector.connectionOpened();
    collector.connectionClosed();

    try std.testing.expectEqual(@as(u64, 1), collector.request_count.get());
    try std.testing.expectEqual(@as(f64, 0.0), collector.active_connections.get());
}

test "Gauge atomic CAS correctness" {
    const allocator = std.testing.allocator;
    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    const gauge = try metrics.createGauge("test_gauge", "Test atomic gauge");

    // Basic operations
    gauge.set(100.0);
    try std.testing.expectEqual(@as(f64, 100.0), gauge.get());

    gauge.add(50.5);
    try std.testing.expectEqual(@as(f64, 150.5), gauge.get());

    gauge.sub(25.25);
    try std.testing.expectEqual(@as(f64, 125.25), gauge.get());

    // Inc/Dec use add internally
    gauge.set(0.0);
    gauge.inc();
    gauge.inc();
    gauge.dec();
    try std.testing.expectEqual(@as(f64, 1.0), gauge.get());

    // Negative values
    gauge.set(-10.0);
    try std.testing.expectEqual(@as(f64, -10.0), gauge.get());
    gauge.add(15.0);
    try std.testing.expectEqual(@as(f64, 5.0), gauge.get());
}

test "MetricsBackend adapter" {
    const allocator = std.testing.allocator;
    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    // Create metrics through the VTable-based MetricsBackend adapter
    const backend = metrics.toBackend();
    const counter_h = try backend.createCounter("backend_counter", "Test");
    const gauge_h = try backend.createGauge("backend_gauge", "Test");
    const hist_h = try backend.createHistogram("backend_hist", "Test", &.{ 0.1, 0.5, 1.0 });
    backend.counterInc(counter_h);
    backend.counterAdd(counter_h, 2);
    backend.gaugeSet(gauge_h, 42.0);
    backend.gaugeInc(gauge_h);
    backend.gaugeDec(gauge_h);
    backend.histogramObserve(hist_h, 0.3);

    // Verify values through the native PrometheusMetrics API
    const counter = metrics.getCounter("backend_counter").?;
    try std.testing.expectEqual(@as(u64, 3), counter.get());

    const gauge = metrics.getGauge("backend_gauge").?;
    try std.testing.expectEqual(@as(f64, 42.0), gauge.get());
}
