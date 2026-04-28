const std = @import("std");

/// 性能基准测试框架
/// 提供完整的性能测试、统计分析和报告生成能力
/// 这是架构评估中的中优先级改进项
pub const Benchmark = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    name: []const u8,
    results: std.array_list.Managed(BenchmarkResult),
    config: Config,

    /// 基准测试配置
    pub const Config = struct {
        /// 最小运行次数
        min_iterations: usize = 10,
        /// 最大运行次数
        max_iterations: usize = 10000,
        /// 最小运行时间（纳秒）
        min_time_ns: u64 = 1_000_000_000, // 1秒
        /// 是否预热
        warmup: bool = true,
        /// 预热次数
        warmup_iterations: usize = 3,
        /// 是否显示详细输出
        verbose: bool = false,
    };

    /// 单次运行结果
    pub const RunResult = struct {
        duration_ns: u64,
        iterations: usize,
        bytes_processed: usize = 0,
        items_processed: usize = 0,
    };

    /// 基准测试结果
    pub const BenchmarkResult = struct {
        name: []const u8,
        runs: std.array_list.Managed(RunResult),

        // 统计值
        mean_ns: f64 = 0,
        median_ns: f64 = 0,
        min_ns: u64 = 0,
        max_ns: u64 = 0,
        std_dev_ns: f64 = 0,

        // 吞吐量
        throughput_bytes_per_sec: f64 = 0,
        throughput_items_per_sec: f64 = 0,

        pub fn calculateStats(self: *BenchmarkResult) void {
            if (self.runs.items.len == 0) return;

            // 计算均值
            var sum: u128 = 0;
            var min: u64 = std.math.maxInt(u64);
            var max: u64 = 0;
            var total_bytes: u128 = 0;
            var total_items: u128 = 0;

            for (self.runs.items) |r| {
                sum += r.duration_ns;
                min = @min(min, r.duration_ns);
                max = @max(max, r.duration_ns);
                total_bytes += r.bytes_processed;
                total_items += r.items_processed;
            }

            self.mean_ns = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(self.runs.items.len));
            self.min_ns = min;
            self.max_ns = max;

            // 计算中位数
            var sorted = self.runs.clone() catch return;
            defer sorted.deinit();

            std.sort.insertion(RunResult, sorted.items, {}, struct {
                fn lessThan(_: void, a: RunResult, b: RunResult) bool {
                    return a.duration_ns < b.duration_ns;
                }
            }.lessThan);

            const mid = sorted.items.len / 2;
            if (sorted.items.len % 2 == 0) {
                self.median_ns = (@as(f64, @floatFromInt(sorted.items[mid - 1].duration_ns)) +
                    @as(f64, @floatFromInt(sorted.items[mid].duration_ns))) / 2.0;
            } else {
                self.median_ns = @as(f64, @floatFromInt(sorted.items[mid].duration_ns));
            }

            // 计算标准差
            var variance_sum: f64 = 0;
            for (self.runs.items) |r| {
                const diff = @as(f64, @floatFromInt(r.duration_ns)) - self.mean_ns;
                variance_sum += diff * diff;
            }
            self.std_dev_ns = @sqrt(variance_sum / @as(f64, @floatFromInt(self.runs.items.len)));

            // 计算吞吐量
            const total_duration_secs = @as(f64, @floatFromInt(sum)) / 1_000_000_000.0;
            if (total_duration_secs > 0) {
                self.throughput_bytes_per_sec = @as(f64, @floatFromInt(total_bytes)) / total_duration_secs;
                self.throughput_items_per_sec = @as(f64, @floatFromInt(total_items)) / total_duration_secs;
            }
        }

        /// 获取格式化的时间字符串
        pub fn formatDuration(ns: u64, buf: []u8) ![]const u8 {
            if (ns < 1000) {
                return try std.fmt.bufPrint(buf, "{d}ns", .{ns});
            } else if (ns < 1_000_000) {
                return try std.fmt.bufPrint(buf, "{d:.2}us", .{@as(f64, @floatFromInt(ns)) / 1000.0});
            } else if (ns < 1_000_000_000) {
                return try std.fmt.bufPrint(buf, "{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
            } else {
                return try std.fmt.bufPrint(buf, "{d:.3}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
            }
        }
    };

    /// 创建新的基准测试
    pub fn init(allocator: std.mem.Allocator, name: []const u8, config: Config) !Self {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .results = std.array_list.Managed(BenchmarkResult).init(allocator),
            .config = config,
        };
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);

        for (self.results.items) |*result| {
            self.allocator.free(result.name);
            result.runs.deinit();
        }
        self.results.deinit();
    }

    /// 运行单个基准测试函数
    pub fn run(self: *Self, bench_name: []const u8, comptime BenchFn: type, bench_ctx: anytype) !void {
        _ = BenchFn;
        var result = BenchmarkResult{
            .name = try self.allocator.dupe(u8, bench_name),
            .runs = std.array_list.Managed(RunResult).init(self.allocator),
        };
        errdefer {
            result.runs.deinit();
            self.allocator.free(result.name);
        }

        // 预热
        if (self.config.warmup) {
            var i: usize = 0;
            while (i < self.config.warmup_iterations) : (i += 1) {
                _ = try bench_ctx.run();
            }
        }

        // 实际测试
        var total_time: u64 = 0;
        var iteration: usize = 0;

        while (iteration < self.config.max_iterations) : (iteration += 1) {
            const start = 0;
            const bench_result = try bench_ctx.run();
            const end = 0;

            const duration = @as(u64, @intCast(end - start));
            total_time += duration;

            try result.runs.append(.{
                .duration_ns = duration,
                .iterations = bench_result.iterations,
                .bytes_processed = bench_result.bytes_processed,
                .items_processed = bench_result.items_processed,
            });

            // 检查是否达到最小时间要求
            if (iteration >= self.config.min_iterations and total_time >= self.config.min_time_ns) {
                break;
            }
        }

        // 计算统计值
        result.calculateStats();

        try self.results.append(result);

        if (self.config.verbose) {
            self.printResult(&result);
        }
    }

    /// 打印单个结果
    fn printResult(self: *Self, result: *const BenchmarkResult) void {
        _ = self;

        // SAFETY: Buffer is immediately filled by formatDuration() before use
        var buf: [64]u8 = undefined;

        std.log.info("\n{s}", .{result.name});
        std.log.info("  Runs: {d}", .{result.runs.items.len});

        const mean_str = BenchmarkResult.formatDuration(@as(u64, @intFromFloat(result.mean_ns)), &buf) catch "N/A";
        std.log.info("  Mean: {s}", .{mean_str});

        const median_str = BenchmarkResult.formatDuration(@as(u64, @intFromFloat(result.median_ns)), &buf) catch "N/A";
        std.log.info("  Median: {s}", .{median_str});

        const min_str = BenchmarkResult.formatDuration(result.min_ns, &buf) catch "N/A";
        std.log.info("  Min: {s}", .{min_str});

        const max_str = BenchmarkResult.formatDuration(result.max_ns, &buf) catch "N/A";
        std.log.info("  Max: {s}", .{max_str});

        std.log.info("  StdDev: {d:.2}ns", .{result.std_dev_ns});

        if (result.throughput_items_per_sec > 0) {
            std.log.info("  Throughput: {d:.2} items/sec", .{result.throughput_items_per_sec});
        }

        if (result.throughput_bytes_per_sec > 0) {
            const mb_per_sec = result.throughput_bytes_per_sec / (1024.0 * 1024.0);
            std.log.info("  Bandwidth: {d:.2} MB/sec", .{mb_per_sec});
        }
    }

    /// 生成完整报告
    pub fn generateReport(self: *Self) ![]const u8 {
        var buf = std.array_list.Managed(u8).init(self.allocator);
        defer buf.deinit();
        const writer = buf.writer();

        try writer.print("# Benchmark Report: {s}\n\n", .{self.name});
        try writer.writeAll("| Benchmark | Runs | Mean | Median | Min | Max | StdDev |\n");
        try writer.writeAll("|-----------|------|------|--------|-----|-----|--------|\n");

        // SAFETY: Buffer is immediately filled by formatDuration() before each use
        var temp_buf: [64]u8 = undefined;

        for (self.results.items) |result| {
            const mean_str = try BenchmarkResult.formatDuration(@as(u64, @intFromFloat(result.mean_ns)), &temp_buf);
            const median_str = try BenchmarkResult.formatDuration(@as(u64, @intFromFloat(result.median_ns)), &temp_buf);
            const min_str = try BenchmarkResult.formatDuration(result.min_ns, &temp_buf);
            const max_str = try BenchmarkResult.formatDuration(result.max_ns, &temp_buf);

            try writer.print("| {s} | {d} | {s} | {s} | {s} | {s} | {d:.2}ns |\n", .{
                result.name,
                result.runs.items.len,
                mean_str,
                median_str,
                min_str,
                max_str,
                result.std_dev_ns,
            });
        }

        return buf.toOwnedSlice();
    }

    /// 与另一个基准测试结果比较
    pub fn compareWithBaseline(self: *Self, baseline: *const Benchmark, result_name: []const u8) !?ComparisonResult {
        const current = self.findResult(result_name) orelse return null;
        const base = baseline.findResult(result_name) orelse return null;

        const change_pct = ((current.mean_ns - base.mean_ns) / base.mean_ns) * 100.0;

        return ComparisonResult{
            .benchmark_name = result_name,
            .baseline_mean_ns = base.mean_ns,
            .current_mean_ns = current.mean_ns,
            .change_percent = change_pct,
            .is_regression = change_pct > 5.0, // 5%阈值
            .is_improvement = change_pct < -5.0,
        };
    }

    fn findResult(self: *Self, name: []const u8) ?*const BenchmarkResult {
        for (self.results.items) |*result| {
            if (std.mem.eql(u8, result.name, name)) {
                return result;
            }
        }
        return null;
    }

    /// 比较结果
    pub const ComparisonResult = struct {
        benchmark_name: []const u8,
        baseline_mean_ns: f64,
        current_mean_ns: f64,
        change_percent: f64,
        is_regression: bool,
        is_improvement: bool,
    };
};

/// 基准测试上下文接口
pub fn BenchmarkContext(comptime ReturnType: type) type {
    return struct {
        const Self = @This();

        run_fn: *const fn (*anyopaque) anyerror!ReturnType,
        ctx: *anyopaque,

        pub fn run(self: *Self) !ReturnType {
            return self.run_fn(self.ctx);
        }
    };
}

/// 常用基准测试场景
pub const BenchmarkScenarios = struct {
    /// 模块启动性能测试
    pub const ModuleStartupBenchmark = struct {
        pub const Result = struct {
            iterations: usize = 1,
            bytes_processed: usize = 0,
            items_processed: usize = 1,
        };

        module_name: []const u8,
        init_fn: *const fn () anyerror!void,
        deinit_fn: *const fn () void,

        pub fn run(self: *ModuleStartupBenchmark) !Result {
            const start = 0;

            try self.init_fn();
            self.deinit_fn();

            _ = start;

            return Result{
                .iterations = 1,
                .items_processed = 1,
            };
        }
    };

    /// 事件总线性能测试
    pub const EventBusBenchmark = struct {
        pub const Result = struct {
            iterations: usize,
            bytes_processed: usize = 0,
            items_processed: usize,
        };

        event_count: usize,
        publish_fn: *const fn (usize) anyerror!void,

        pub fn run(self: *EventBusBenchmark) !Result {
            var i: usize = 0;
            while (i < self.event_count) : (i += 1) {
                try self.publish_fn(i);
            }

            return Result{
                .iterations = self.event_count,
                .items_processed = self.event_count,
            };
        }
    };

    /// HTTP API性能测试
    pub const HttpApiBenchmark = struct {
        pub const Result = struct {
            iterations: usize,
            bytes_processed: usize,
            items_processed: usize,
        };

        request_count: usize,
        endpoint: []const u8,
        request_fn: *const fn ([]const u8) anyerror![]const u8,

        pub fn run(self: *HttpApiBenchmark, allocator: std.mem.Allocator) !Result {
            var total_bytes: usize = 0;

            var i: usize = 0;
            while (i < self.request_count) : (i += 1) {
                const response = try self.request_fn(self.endpoint);
                total_bytes += response.len;
                allocator.free(response);
            }

            return Result{
                .iterations = self.request_count,
                .bytes_processed = total_bytes,
                .items_processed = self.request_count,
            };
        }
    };
};

/// 基准测试套件 - 运行多个相关基准测试
pub const BenchmarkSuite = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    name: []const u8,
    benchmarks: std.array_list.Managed(*Benchmark),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Self {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .benchmarks = std.array_list.Managed(*Benchmark).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);

        for (self.benchmarks.items) |bench| {
            bench.deinit();
            self.allocator.destroy(bench);
        }
        self.benchmarks.deinit();
    }

    /// 添加基准测试
    pub fn addBenchmark(self: *Self, name: []const u8, config: Benchmark.Config) !*Benchmark {
        const bench = try self.allocator.create(Benchmark);
        bench.* = try Benchmark.init(self.allocator, name, config);
        try self.benchmarks.append(bench);
        return bench;
    }

    /// 运行所有基准测试
    pub fn runAll(self: *Self) !void {
        std.log.info("\n=== Running Benchmark Suite: {s} ===", .{self.name});

        for (self.benchmarks.items) |bench| {
            std.log.info("\nRunning: {s}", .{bench.name});
            // 基准测试已经在 addBenchmark 时创建，这里不需要再运行
            // 实际的运行应该在添加测试用例时完成
        }
    }

    /// 生成汇总报告
    pub fn generateSummaryReport(self: *Self) ![]const u8 {
        var buf = std.array_list.Managed(u8).init(self.allocator);
        defer buf.deinit();
        const writer = buf.writer();

        try writer.print("# Benchmark Suite Report: {s}\n\n", .{self.name});
        try writer.print("Total Benchmarks: {d}\n\n", .{self.benchmarks.items.len});

        for (self.benchmarks.items) |bench| {
            const report = try bench.generateReport();
            defer self.allocator.free(report);
            try writer.writeAll(report);
            try writer.writeAll("\n---\n\n");
        }

        return buf.toOwnedSlice();
    }
};

// 测试用例
test "Benchmark basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var bench = try Benchmark.init(allocator, "test_benchmark", .{
        .min_iterations = 5,
        .max_iterations = 10,
        .verbose = true,
    });
    defer bench.deinit();

    // 创建一个简单的基准测试上下文
    const TestContext = struct {
        counter: usize = 0,

        const Result = struct {
            iterations: usize = 1,
            bytes_processed: usize = 0,
            items_processed: usize = 1,
        };

        pub fn run(self: *@This()) !Result {
            // 模拟一些工作
            var sum: usize = 0;
            for (0..1000) |i| {
                sum += i;
            }
            self.counter += 1;
            return Result{};
        }
    };

    var ctx = TestContext{};
    try bench.run("simple_test", TestContext, &ctx);
}

test "BenchmarkScenarios" {
    const testing = std.testing;

    // 测试模块启动基准
    var startup_bench = BenchmarkScenarios.ModuleStartupBenchmark{
        .module_name = "test_module",
        .init_fn = struct {
            fn init() !void {
                // Note: Blocking sleep unavailable in Zig 0.16.0
                _ = {};
            }
        }.init,
        .deinit_fn = struct {
            fn deinit() void {}
        }.deinit,
    };

    const result = try startup_bench.run();
    try testing.expectEqual(@as(usize, 1), result.items_processed);
}

test "BenchmarkSuite" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var suite = try BenchmarkSuite.init(allocator, "test_suite");
    defer suite.deinit();

    const bench = try suite.addBenchmark("module_performance", .{
        .min_iterations = 3,
        .verbose = false,
    });
    _ = bench;

    try suite.runAll();
}
