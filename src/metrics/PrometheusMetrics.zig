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
        value: u64 = 0,
        labels: std.StringHashMap([]const u8),

        pub fn inc(self: *Counter) void {
            self.value += 1;
        }

        pub fn add(self: *Counter, value: u64) void {
            self.value += value;
        }

        pub fn get(self: *Counter) u64 {
            return self.value;
        }
    };

    pub const Gauge = struct {
        name: []const u8,
        help: []const u8,
        value: f64 = 0.0,
        labels: std.StringHashMap([]const u8),

        pub fn set(self: *Gauge, value: f64) void {
            self.value = value;
        }

        pub fn inc(self: *Gauge) void {
            self.value += 1.0;
        }

        pub fn dec(self: *Gauge) void {
            self.value -= 1.0;
        }

        pub fn add(self: *Gauge, value: f64) void {
            self.value += value;
        }

        pub fn sub(self: *Gauge, value: f64) void {
            self.value -= value;
        }

        pub fn get(self: *Gauge) f64 {
            return self.value;
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

        pub fn observe(self: *Summary, value: f64) !void {
            self.sum += value;
            self.count += 1;
            try self.values.append(value);
        }

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
        const writer = buf.writer();

        // Counters
        var counter_iter = self.counters.iterator();
        while (counter_iter.next()) |entry| {
            const counter = entry.value_ptr.*;
            try writer.print("# HELP {s} {s}\n", .{ counter.name, counter.help });
            try writer.print("# TYPE {s} counter\n", .{counter.name});
            try writer.print("{s} {d}\n\n", .{ counter.name, counter.value });
        }

        // Gauges
        var gauge_iter = self.gauges.iterator();
        while (gauge_iter.next()) |entry| {
            const gauge = entry.value_ptr.*;
            try writer.print("# HELP {s} {s}\n", .{ gauge.name, gauge.help });
            try writer.print("# TYPE {s} gauge\n", .{gauge.name});
            try writer.print("{s} {d:.6}\n\n", .{ gauge.name, gauge.value });
        }

        // Histograms
        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |entry| {
            const hist = entry.value_ptr.*;
            try writer.print("# HELP {s} {s}\n", .{ hist.name, hist.help });
            try writer.print("# TYPE {s} histogram\n", .{hist.name});

            for (hist.buckets.items, hist.counts.items) |bucket, count| {
                try writer.print("{s}_bucket{{le=\"{d:.3}\"}} {d}\n", .{ hist.name, bucket, count });
            }
            try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ hist.name, hist.count });
            try writer.print("{s}_sum {d:.6}\n", .{ hist.name, hist.sum });
            try writer.print("{s}_count {d}\n\n", .{ hist.name, hist.count });
        }

        return buf.toOwnedSlice();
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
            const req_duration_name = try std.fmt.allocPrint(metrics.allocator, "{s}_request_duration_seconds", .{module_name});
            const active_conn_name = try std.fmt.allocPrint(metrics.allocator, "{s}_active_connections", .{module_name});

            return .{
                .metrics = metrics,
                .module_start_time = std.time.timestamp(),
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
            return std.time.timestamp() - self.module_start_time;
        }
    };
};
