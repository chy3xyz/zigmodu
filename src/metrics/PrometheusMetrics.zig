const std = @import("std");

/// Prometheus metrics collector
/// Supports Counter, Gauge, Histogram, Summary
pub const PrometheusMetrics = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    scrape_hook: ?ScrapeHook,
    scrape_userdata: ?*anyopaque,
    /// Bounded-cardinality labeled series (see `createCounterFamily`).
    counter_families: std.ArrayList(*CounterFamily),
    histogram_families: std.ArrayList(*HistogramFamily),
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
        /// Thread-safe f64 sum via bitcast u64 + CAS (same pattern as Gauge).
        sum_bits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Thread-safe observation count.
        count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        pub fn observe(self: *Histogram, value: f64) void {
            // CAS loop for f64 sum
            while (true) {
                const old_bits = self.sum_bits.load(.monotonic);
                const old_val: f64 = @bitCast(old_bits);
                const new_val = old_val + value;
                const new_bits: u64 = @bitCast(new_val);
                if (self.sum_bits.cmpxchgWeak(old_bits, new_bits, .monotonic, .monotonic) == null) break;
            }
            _ = self.count.fetchAdd(1, .monotonic);
            for (self.buckets.items, 0..) |bucket, i| {
                if (value <= bucket) {
                    _ = @atomicRmw(u64, &self.counts.items[i], .Add, 1, .monotonic);
                }
            }
        }

        pub fn sum(self: *const Histogram) f64 {
            return @bitCast(self.sum_bits.load(.monotonic));
        }

        pub fn totalCount(self: *const Histogram) u64 {
            return self.count.load(.monotonic);
        }
    };

    pub const Summary = struct {
        name: []const u8,
        help: []const u8,
        quantiles: std.array_list.Managed(f64),
        values: std.array_list.Managed(f64),
        /// Thread-safe f64 sum via bitcast u64 + CAS (same pattern as Gauge).
        sum_bits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Thread-safe observation count (used for reservoir sampling index).
        count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        max_age_seconds: u64 = 600,
        age_buckets: usize = 5,
        /// Hard cap on stored samples to prevent unbounded memory growth.
        /// Once reached, new values replace random existing samples (reservoir sampling).
        max_samples: usize = 500,

        pub fn observe(self: *Summary, value: f64) !void {
            // CAS loop for f64 sum
            while (true) {
                const old_bits = self.sum_bits.load(.monotonic);
                const old_val: f64 = @bitCast(old_bits);
                const new_val = old_val + value;
                const new_bits: u64 = @bitCast(new_val);
                if (self.sum_bits.cmpxchgWeak(old_bits, new_bits, .monotonic, .monotonic) == null) break;
            }
            const n = self.count.fetchAdd(1, .monotonic);

            if (self.values.items.len < self.max_samples) {
                try self.values.append(value);
            } else {
                const idx = @as(usize, @intCast(n % self.max_samples));
                self.values.items[idx] = value;
            }
        }

        pub fn totalSum(self: *Summary) f64 {
            return @bitCast(self.sum_bits.load(.monotonic));
        }

        pub fn totalCount(self: *Summary) u64 {
            return self.count.load(.monotonic);
        }

        /// Returns the q-th quantile (0.0-1.0) using QuickSelect O(n).
        /// Avoids the full sort that was used in v0.9.4 (O(n log n)).
        pub fn getQuantile(self: *Summary, q: f64) f64 {
            const n = self.values.items.len;
            if (n == 0) return 0.0;
            if (n == 1) return self.values.items[0];

            const target = @min(@as(usize, @intFromFloat(@as(f64, @floatFromInt(n)) * q)), n - 1);
            const items = self.values.items;

            // QuickSelect: O(n) expected time, in-place
            var lo: usize = 0;
            var hi: usize = n - 1;
            while (lo < hi) {
                const pivot = items[lo + (hi - lo) / 2];
                var i: usize = lo;
                var j: usize = hi;
                while (i <= j) {
                    while (items[i] < pivot) : (i += 1) {}
                    while (items[j] > pivot) : (j -= 1) {}
                    if (i <= j) {
                        std.mem.swap(f64, &items[i], &items[j]);
                        i += 1;
                        j -= 1;
                    }
                }
                if (target <= j) {
                    hi = j;
                } else if (target >= i) {
                    lo = i;
                } else {
                    break;
                }
            }
            return items[target];
        }
    };

    /// A counter split by one label, with a hard series cap. Values beyond the
    /// cap collapse into a single `__other__` series, so a dynamic label value
    /// can never make a scrape (or memory) unbounded.
    pub const CounterFamily = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        name: []const u8,
        help: []const u8,
        label: []const u8,
        max_series: usize,
        series: std.StringHashMap(*Counter),
        overflow: Counter,
        overflow_used: bool = false,

        /// Series handle for `label_value` (creates it on first use, up to
        /// `max_series`). Never fails: on allocation pressure it degrades to
        /// the shared overflow counter.
        pub fn get(self: *CounterFamily, label_value: []const u8) *Counter {
            self.mutex.lock(self.io) catch return &self.overflow;
            defer self.mutex.unlock(self.io);
            if (self.series.get(label_value)) |c| return c;
            if (self.series.count() >= self.max_series) {
                self.overflow_used = true;
                return &self.overflow;
            }
            const key = self.allocator.dupe(u8, label_value) catch {
                self.overflow_used = true;
                return &self.overflow;
            };
            const counter = self.allocator.create(Counter) catch {
                self.allocator.free(key);
                self.overflow_used = true;
                return &self.overflow;
            };
            counter.* = .{
                .name = self.name,
                .help = self.help,
                .value = std.atomic.Value(u64).init(0),
                .labels = std.StringHashMap([]const u8).init(self.allocator),
            };
            self.series.put(key, counter) catch {
                self.allocator.free(key);
                self.allocator.destroy(counter);
                self.overflow_used = true;
                return &self.overflow;
            };
            return counter;
        }

        fn render(self: *CounterFamily, buf: *std.array_list.Managed(u8)) !void {
            try buf.print("# HELP {s} {s}\n", .{ self.name, self.help });
            try buf.print("# TYPE {s} counter\n", .{self.name});
            var it = self.series.iterator();
            while (it.next()) |entry| {
                try buf.print("{s}{{{s}=\"{s}\"}} {d}\n", .{
                    self.name, self.label, entry.key_ptr.*, entry.value_ptr.*.value.load(.monotonic),
                });
            }
            if (self.overflow_used) {
                try buf.print("{s}{{{s}=\"__other__\"}} {d}\n", .{
                    self.name, self.label, self.overflow.value.load(.monotonic),
                });
            }
            try buf.print("\n", .{});
        }

        fn deinit(self: *CounterFamily) void {
            self.overflow.labels.deinit();
            var it = self.series.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.labels.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.series.deinit();
            self.allocator.free(self.name);
            self.allocator.free(self.help);
            self.allocator.free(self.label);
            self.allocator.destroy(self);
        }
    };

    /// Histogram split by one label, with the same bounded-series rule as
    /// `CounterFamily`.
    pub const HistogramFamily = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        name: []const u8,
        help: []const u8,
        label: []const u8,
        max_series: usize,
        buckets: []f64,
        series: std.StringHashMap(*Histogram),
        overflow: Histogram,
        overflow_used: bool = false,

        pub fn get(self: *HistogramFamily, label_value: []const u8) *Histogram {
            self.mutex.lock(self.io) catch return &self.overflow;
            defer self.mutex.unlock(self.io);
            if (self.series.get(label_value)) |h| return h;
            if (self.series.count() >= self.max_series) {
                self.overflow_used = true;
                return &self.overflow;
            }
            const key = self.allocator.dupe(u8, label_value) catch {
                self.overflow_used = true;
                return &self.overflow;
            };
            const hist = self.allocator.create(Histogram) catch {
                self.allocator.free(key);
                self.overflow_used = true;
                return &self.overflow;
            };
            hist.* = .{
                .name = self.name,
                .help = self.help,
                .buckets = std.array_list.Managed(f64).init(self.allocator),
                .counts = std.array_list.Managed(u64).init(self.allocator),
            };
            for (self.buckets) |b| {
                hist.buckets.append(b) catch {
                    hist.buckets.deinit();
                    hist.counts.deinit();
                    self.allocator.free(key);
                    self.allocator.destroy(hist);
                    self.overflow_used = true;
                    return &self.overflow;
                };
                hist.counts.append(0) catch {};
            }
            self.series.put(key, hist) catch {
                hist.buckets.deinit();
                hist.counts.deinit();
                self.allocator.free(key);
                self.allocator.destroy(hist);
                self.overflow_used = true;
                return &self.overflow;
            };
            return hist;
        }

        fn render(self: *HistogramFamily, buf: *std.array_list.Managed(u8)) !void {
            try buf.print("# HELP {s} {s}\n", .{ self.name, self.help });
            try buf.print("# TYPE {s} histogram\n", .{self.name});
            var it = self.series.iterator();
            while (it.next()) |entry| {
                try renderHistogram(buf, entry.value_ptr.*, self.label, entry.key_ptr.*);
            }
            if (self.overflow_used) {
                try renderHistogram(buf, &self.overflow, self.label, "__other__");
            }
            try buf.print("\n", .{});
        }

        fn deinit(self: *HistogramFamily) void {
            self.overflow.buckets.deinit();
            self.overflow.counts.deinit();
            var it = self.series.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.buckets.deinit();
                entry.value_ptr.*.counts.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.series.deinit();
            self.allocator.free(self.name);
            self.allocator.free(self.help);
            self.allocator.free(self.label);
            self.allocator.free(self.buckets);
            self.allocator.destroy(self);
        }
    };

    fn renderHistogram(buf: *std.array_list.Managed(u8), hist: *const Histogram, label: []const u8, label_value: []const u8) !void {
        for (hist.buckets.items, hist.counts.items) |bucket, count| {
            try buf.print("{s}_bucket{{{s}=\"{s}\",le=\"{d:.3}\"}} {d}\n", .{ hist.name, label, label_value, bucket, count });
        }
        try buf.print("{s}_bucket{{{s}=\"{s}\",le=\"+Inf\"}} {d}\n", .{ hist.name, label, label_value, hist.totalCount() });
        try buf.print("{s}_sum{{{s}=\"{s}\"}} {d:.6}\n", .{ hist.name, label, label_value, hist.sum() });
        try buf.print("{s}_count{{{s}=\"{s}\"}} {d}\n", .{ hist.name, label, label_value, hist.totalCount() });
    }

    /// Called at the start of every scrape, before rendering. Use it to
    /// refresh gauges that are cheap to sample but expensive to keep fresh
    /// (DB pool saturation, outbox backlog) — no background thread needed.
    pub const ScrapeHook = *const fn (userdata: ?*anyopaque) void;

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .scrape_hook = null,
            .scrape_userdata = null,
            .counter_families = std.ArrayList(*CounterFamily).empty,
            .histogram_families = std.ArrayList(*HistogramFamily).empty,
            .counters = std.StringHashMap(Counter).init(allocator),
            .gauges = std.StringHashMap(Gauge).init(allocator),
            .histograms = std.StringHashMap(Histogram).init(allocator),
            .summaries = std.StringHashMap(Summary).init(allocator),
        };
    }

    pub fn setScrapeHook(self: *Self, hook: ?ScrapeHook, userdata: ?*anyopaque) void {
        self.scrape_hook = hook;
        self.scrape_userdata = userdata;
    }

    pub fn deinit(self: *Self) void {
        for (self.counter_families.items) |f| f.deinit();
        self.counter_families.deinit(self.allocator);
        for (self.histogram_families.items) |f| f.deinit();
        self.histogram_families.deinit(self.allocator);

        // Free all metrics
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
        self.* = undefined;
    }

    /// Create Counter
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

    /// Create Gauge
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

    /// Create Histogram
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

    /// Create Summary
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

    /// Get Counter
    pub fn getCounter(self: *Self, name: []const u8) ?*Counter {
        return self.counters.getPtr(name);
    }

    /// Get Gauge
    pub fn getGauge(self: *Self, name: []const u8) ?*Gauge {
        return self.gauges.getPtr(name);
    }

    /// Generate Prometheus-format metrics output
    pub fn toPrometheusFormat(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        if (self.scrape_hook) |hook| hook(self.scrape_userdata);
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();

        // Labeled families (bounded cardinality; overflow collapses into
        // a single `__other__` series so a hostile/dynamic label value can
        // never blow up the scrape).
        for (self.counter_families.items) |f| try f.render(&buf);
        for (self.histogram_families.items) |f| try f.render(&buf);

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
            try buf.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ hist.name, hist.totalCount() });
            try buf.print("{s}_sum {d:.6}\n", .{ hist.name, hist.sum() });
            try buf.print("{s}_count {d}\n\n", .{ hist.name, hist.totalCount() });
        }

        return try buf.toOwnedSlice();
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

    /// Module metrics collector
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

    /// Bounded-cardinality counter split by a single label.
    /// `max_series` caps distinct label values; extra ones share `__other__`.
    pub fn createCounterFamily(self: *Self, name: []const u8, help: []const u8, label: []const u8, max_series: usize, io: std.Io) !*CounterFamily {
        const f = try self.allocator.create(CounterFamily);
        errdefer self.allocator.destroy(f);
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const help_copy = try self.allocator.dupe(u8, help);
        errdefer self.allocator.free(help_copy);
        const label_copy = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_copy);
        f.* = .{
            .allocator = self.allocator,
            .io = io,
            .name = name_copy,
            .help = help_copy,
            .label = label_copy,
            .max_series = @max(1, max_series),
            .series = std.StringHashMap(*Counter).init(self.allocator),
            .overflow = .{
                .name = name_copy,
                .help = help_copy,
                .value = std.atomic.Value(u64).init(0),
                .labels = std.StringHashMap([]const u8).init(self.allocator),
            },
        };
        try self.counter_families.append(self.allocator, f);
        return f;
    }

    /// Bounded-cardinality histogram split by a single label.
    pub fn createHistogramFamily(self: *Self, name: []const u8, help: []const u8, label: []const u8, max_series: usize, buckets: []const f64, io: std.Io) !*HistogramFamily {
        const f = try self.allocator.create(HistogramFamily);
        errdefer self.allocator.destroy(f);
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const help_copy = try self.allocator.dupe(u8, help);
        errdefer self.allocator.free(help_copy);
        const label_copy = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_copy);
        const buckets_copy = try self.allocator.dupe(f64, buckets);
        errdefer self.allocator.free(buckets_copy);
        f.* = .{
            .allocator = self.allocator,
            .io = io,
            .name = name_copy,
            .help = help_copy,
            .label = label_copy,
            .max_series = @max(1, max_series),
            .buckets = buckets_copy,
            .series = std.StringHashMap(*Histogram).init(self.allocator),
            .overflow = .{
                .name = name_copy,
                .help = help_copy,
                .buckets = std.array_list.Managed(f64).init(self.allocator),
                .counts = std.array_list.Managed(u64).init(self.allocator),
            },
        };
        for (buckets) |b| {
            try f.overflow.buckets.append(b);
            try f.overflow.counts.append(0);
        }
        try self.histogram_families.append(self.allocator, f);
        return f;
    }

    /// Convenience: register /metrics route on a server with Prometheus text format.
    /// Usage: try metrics.registerMetricsRoute(&server);
    pub fn registerMetricsRoute(self: *Self, server: anytype) !void {
        try self.registerMetricsRoutePath(server, "/metrics");
    }

    /// Same as `registerMetricsRoute` with a caller-chosen path.
    pub fn registerMetricsRoutePath(self: *Self, server: anytype, path: []const u8) !void {
        const ptr: *anyopaque = @ptrCast(self);
        try server.addRoute(.{
            .method = .GET,
            .path = path,
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
    try std.testing.expectEqual(@as(u64, 2), hist.totalCount());

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

test "counter family caps cardinality and collapses the overflow" {
    const allocator = std.testing.allocator;
    var m = PrometheusMetrics.init(allocator);
    defer m.deinit();

    const family = try m.createCounterFamily("http_requests_total", "Total requests", "route", 2, std.testing.io);
    family.get("/a").inc();
    family.get("/b").inc();
    family.get("/b").inc();
    family.get("/c").inc();
    family.get("/d").inc();
    family.get("/d").inc();

    const text = try m.toPrometheusFormat(allocator);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "http_requests_total{route=\"/a\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "http_requests_total{route=\"/b\"} 2") != null);
    // Everything past the cap shares one series — a dynamic label value can
    // never grow the scrape or the memory without bound.
    try std.testing.expect(std.mem.indexOf(u8, text, "http_requests_total{route=\"__other__\"} 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "route=\"/c\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "route=\"/d\"") == null);
}

test "histogram family renders per-label buckets" {
    const allocator = std.testing.allocator;
    var m = PrometheusMetrics.init(allocator);
    defer m.deinit();

    const buckets = [_]f64{ 10, 100 };
    const family = try m.createHistogramFamily("http_request_duration_milliseconds", "latency", "route", 8, &buckets, std.testing.io);
    family.get("/orders/{id}").observe(5);
    family.get("/orders/{id}").observe(50);
    family.get("/orders/{id}").observe(500);

    const text = try m.toPrometheusFormat(allocator);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "http_request_duration_milliseconds_bucket{route=\"/orders/{id}\",le=\"10.000\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "http_request_duration_milliseconds_bucket{route=\"/orders/{id}\",le=\"100.000\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "http_request_duration_milliseconds_bucket{route=\"/orders/{id}\",le=\"+Inf\"} 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "http_request_duration_milliseconds_count{route=\"/orders/{id}\"} 3") != null);
}

test "scrape hook refreshes gauges before rendering" {
    const allocator = std.testing.allocator;
    var m = PrometheusMetrics.init(allocator);
    defer m.deinit();

    const gauge = try m.createGauge("db_pool_active", "Active pooled connections");
    const Hook = struct {
        fn run(ud: ?*anyopaque) void {
            const g: *PrometheusMetrics.Gauge = @ptrCast(@alignCast(ud.?));
            g.set(7);
        }
    };
    m.setScrapeHook(Hook.run, gauge);

    const text = try m.toPrometheusFormat(allocator);
    defer allocator.free(text);
    // The value was sampled at scrape time, not registered up front.
    try std.testing.expect(std.mem.indexOf(u8, text, "db_pool_active 7.000000") != null);
}
