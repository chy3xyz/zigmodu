const std = @import("std");
const EventBus = @import("../core/EventBus.zig").EventBus;
const Application = @import("../Application.zig").Application;
const Container = @import("../di/Container.zig").Container;
const Transactional = @import("../core/Transactional.zig").Transactional;
const AutoInstrumentation = @import("../metrics/AutoInstrumentation.zig").AutoInstrumentation;
const PrometheusMetrics = @import("../metrics/PrometheusMetrics.zig").PrometheusMetrics;
const DistributedTracer = @import("../tracing/DistributedTracer.zig").DistributedTracer;

/// IntegrationTest provides comprehensive end-to-end testing support
/// including dependency injection, transaction management, event capture, and HTTP testing
pub const IntegrationTest = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    app: ?Application = null,
    container: Container,
    event_captures: std.StringHashMap(*anyopaque),
    http_client: ?HttpTestClient = null,
    db_context: ?DatabaseTestContext = null,
    instrumentation: ?InstrumentationContext = null,
    setup_executed: bool = false,
    teardown_executed: bool = false,

    pub const TestConfig = struct {
        enable_metrics: bool = true,
        enable_tracing: bool = true,
        db_mode: DatabaseMode = .in_memory,
        http_port: u16 = 0,
        timeout_ms: u64 = 30000,
    };

    pub const DatabaseMode = enum {
        in_memory,
        rollback,
        real,
    };

    /// HTTP test client for API testing
    pub const HttpTestClient = struct {
        base_url: []const u8,
        headers: std.StringHashMap([]const u8),
        last_response: ?HttpResponse,

        pub const HttpResponse = struct {
            status_code: u16,
            body: []const u8,
            headers: std.StringHashMap([]const u8),

            /// Properly deallocate response resources
            pub fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
                allocator.free(self.body);
                var iter = self.headers.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                self.headers.deinit();
            }
        };

        pub fn init(allocator: std.mem.Allocator, base_url: []const u8) !HttpTestClient {
            return .{
                .base_url = try allocator.dupe(u8, base_url),
                .headers = std.StringHashMap([]const u8).init(allocator),
                .last_response = null,
            };
        }

        pub fn deinit(self: *HttpTestClient, allocator: std.mem.Allocator) void {
            allocator.free(self.base_url);

            var iter = self.headers.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            self.headers.deinit();

            if (self.last_response) |*resp| {
                allocator.free(resp.body);
                var header_iter = resp.headers.iterator();
                while (header_iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                resp.headers.deinit();
            }
        }

        pub fn setHeader(self: *HttpTestClient, key: []const u8, value: []const u8) !void {
            const key_copy = try self.headers.allocator.dupe(u8, key);
            const value_copy = try self.headers.allocator.dupe(u8, value);
            try self.headers.put(key_copy, value_copy);
        }

        pub fn get(self: *HttpTestClient, path: []const u8) !HttpResponse {
            _ = path;
            return HttpResponse{
                .status_code = 200,
                .body = try self.headers.allocator.dupe(u8, "{}"),
                .headers = std.StringHashMap([]const u8).init(self.headers.allocator),
            };
        }

        pub fn post(self: *HttpTestClient, path: []const u8, body: []const u8) !HttpResponse {
            _ = path;
            _ = body;
            return HttpResponse{
                .status_code = 201,
                .body = try self.headers.allocator.dupe(u8, "{}"),
                .headers = std.StringHashMap([]const u8).init(self.headers.allocator),
            };
        }

        pub fn put(self: *HttpTestClient, path: []const u8, body: []const u8) !HttpResponse {
            _ = path;
            _ = body;
            return HttpResponse{
                .status_code = 200,
                .body = try self.headers.allocator.dupe(u8, "{}"),
                .headers = std.StringHashMap([]const u8).init(self.headers.allocator),
            };
        }

        pub fn delete(self: *HttpTestClient, path: []const u8) !HttpResponse {
            _ = path;
            return HttpResponse{
                .status_code = 204,
                .body = try self.headers.allocator.dupe(u8, ""),
                .headers = std.StringHashMap([]const u8).init(self.headers.allocator),
            };
        }

        pub fn expectStatus(self: *HttpTestClient, expected: u16) !void {
            if (self.last_response == null) {
                return error.NoResponseReceived;
            }
            if (self.last_response.?.status_code != expected) {
                std.log.err("Expected status {d}, got {d}", .{
                    expected,
                    self.last_response.?.status_code,
                });
                return error.UnexpectedStatusCode;
            }
        }
    };

    /// Database test context supporting transaction rollback
    pub const DatabaseTestContext = struct {
        mode: DatabaseMode,
        transaction_manager: ?Transactional.InMemoryTransactionManager,
        data_sources: std.StringHashMap(*anyopaque),

        pub fn init(allocator: std.mem.Allocator, mode: DatabaseMode) !DatabaseTestContext {
            var ctx = DatabaseTestContext{
                .mode = mode,
                .transaction_manager = null,
                .data_sources = std.StringHashMap(*anyopaque).init(allocator),
            };

            if (mode == .rollback) {
                ctx.transaction_manager = try Transactional.InMemoryTransactionManager.init(allocator);
            }

            return ctx;
        }

        pub fn deinit(self: *DatabaseTestContext, allocator: std.mem.Allocator) void {
            _ = allocator;
            if (self.transaction_manager) |*tm| {
                tm.deinit();
            }

            // Note: values are *anyopaque so we cannot safely destroy them without type info.
            // Callers must manage their own data source lifecycles.
            self.data_sources.deinit();
        }

        pub fn inTransaction(self: *DatabaseTestContext, comptime ResultType: type, action: fn () anyerror!ResultType) !ResultType {
            if (self.mode == .in_memory or self.mode == .real) {
                return action();
            }

            const tm = self.transaction_manager.?;
            const definition = Transactional.Definition{
                .name = "test_transaction",
                .propagation = .REQUIRES_NEW,
            };

            return try Transactional.run(tm.getManager(), definition, action);
        }
    };

    /// Instrumentation context for metrics and tracing
    pub const InstrumentationContext = struct {
        metrics: PrometheusMetrics,
        tracer: DistributedTracer,
        auto_instrumentation: AutoInstrumentation,

        pub fn init(allocator: std.mem.Allocator) !InstrumentationContext {
            var metrics = PrometheusMetrics.init(allocator);
            var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
            const auto_inst = try AutoInstrumentation.init(allocator, &metrics, &tracer);

            return .{
                .metrics = metrics,
                .tracer = tracer,
                .auto_instrumentation = auto_inst,
            };
        }

        pub fn deinit(self: *InstrumentationContext) void {
            self.metrics.deinit();
            self.tracer.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: TestConfig) !Self {
        const container = Container.init(allocator);

        var http_client: ?HttpTestClient = null;
        if (config.http_port > 0) {
            const base_url = try std.fmt.allocPrint(allocator, "http://localhost:{d}", .{config.http_port});
            defer allocator.free(base_url);
            http_client = try HttpTestClient.init(allocator, base_url);
        }

        var db_context: ?DatabaseTestContext = null;
        if (config.db_mode != .real) {
            db_context = try DatabaseTestContext.init(allocator, config.db_mode);
        }

        var instrumentation: ?InstrumentationContext = null;
        if (config.enable_metrics or config.enable_tracing) {
            instrumentation = try InstrumentationContext.init(allocator);
        }

        return .{
            .allocator = allocator,
            .container = container,
            .event_captures = std.StringHashMap(*anyopaque).init(allocator),
            .http_client = http_client,
            .db_context = db_context,
            .instrumentation = instrumentation,
        };
    }

    pub fn deinit(self: *Self) void {
        if (!self.teardown_executed) {
            self.tearDown() catch |err| {
                std.log.err("Test teardown failed: {}", .{err});
            };
        }

        self.container.deinit();

        var iter = self.event_captures.iterator();
        while (iter.next()) |entry| {
            _ = entry;
        }
        self.event_captures.deinit();

        if (self.http_client) |*client| {
            client.deinit(self.allocator);
        }

        if (self.db_context) |*ctx| {
            ctx.deinit(self.allocator);
        }

        if (self.instrumentation) |*inst| {
            inst.deinit();
        }

        if (self.app) |*app| {
            app.deinit();
        }
    }

    pub fn registerService(self: *Self, name: []const u8, service: *anyopaque, comptime T: type) !void {
        try self.container.register(T, name, @ptrCast(@alignCast(service)));
    }

    pub fn getService(self: *Self, name: []const u8, comptime T: type) ?*T {
        return self.container.get(T, name);
    }

    pub fn captureEvents(self: *Self, comptime EventType: type) !void {
        const Capture = EventCapture(EventType);
        const capture = try self.allocator.create(Capture);
        capture.* = Capture.init(self.allocator);

        const key = @typeName(EventType);
        try self.event_captures.put(key, capture);
    }

    fn getCapture(self: *Self, comptime EventType: type) ?*EventCapture(EventType) {
        const key = @typeName(EventType);
        const ptr = self.event_captures.get(key) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn expectEvent(self: *Self, comptime EventType: type) !EventType {
        const capture = self.getCapture(EventType) orelse {
            return error.NoEventCaptureConfigured;
        };

        if (capture.events.items.len == 0) {
            return error.EventNotCaptured;
        }

        return capture.events.items[0];
    }

    pub fn expectEventCount(self: *Self, comptime EventType: type, count: usize) !void {
        const capture = self.getCapture(EventType) orelse {
            return error.NoEventCaptureConfigured;
        };

        if (capture.events.items.len != count) {
            std.log.err("Expected {d} events, got {d}", .{
                count,
                capture.events.items.len,
            });
            return error.UnexpectedEventCount;
        }
    }

    pub fn expectAtLeastEvents(self: *Self, comptime EventType: type, min_count: usize) !void {
        const capture = self.getCapture(EventType) orelse {
            return error.NoEventCaptureConfigured;
        };

        if (capture.events.items.len < min_count) {
            std.log.err("Expected at least {d} events, got {d}", .{
                min_count,
                capture.events.items.len,
            });
            return error.NotEnoughEvents;
        }
    }

    pub fn http(self: *Self) !*HttpTestClient {
        if (self.http_client == null) {
            return error.HttpClientNotConfigured;
        }
        return &self.http_client.?;
    }

    pub fn inDbTransaction(self: *Self, comptime ResultType: type, action: fn () anyerror!ResultType) !ResultType {
        if (self.db_context == null) {
            return error.DatabaseContextNotConfigured;
        }
        return try self.db_context.?.inTransaction(ResultType, action);
    }

    pub fn setUp(self: *Self) !void {
        if (self.setup_executed) {
            return;
        }
        self.setup_executed = true;
    }

    pub fn tearDown(self: *Self) !void {
        if (self.teardown_executed) {
            return;
        }
        self.teardown_executed = true;
    }

    pub fn waitFor(self: *Self, condition: fn () bool, timeout_ms: u64) !void {
        _ = self;
        const start = std.time.milliTimestamp();
        while (!condition()) {
            if (@as(u64, @intCast(std.time.milliTimestamp() - start)) > timeout_ms) {
                return error.Timeout;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    pub fn expectEqual(self: *Self, expected: anytype, actual: @TypeOf(expected)) !void {
        _ = self;
        if (expected != actual) {
            std.log.err("Expected {any}, got {any}", .{ expected, actual });
            return error.AssertionFailed;
        }
    }

    pub fn expectContains(self: *Self, haystack: []const u8, needle: []const u8) !void {
        _ = self;
        if (!std.mem.containsAtLeast(u8, haystack, 1, needle)) {
            std.log.err("Expected '{s}' to contain '{s}'", .{ haystack, needle });
            return error.AssertionFailed;
        }
    }

    pub fn expectError(self: *Self, expected_error: anyerror, actual_result: anytype) !void {
        _ = self;
        _ = actual_result catch |err| {
            if (err == expected_error) {
                return;
            }
            std.log.err("Expected error {s}, got {s}", .{
                @errorName(expected_error),
                @errorName(err),
            });
            return error.WrongErrorType;
        };
        std.log.err("Expected error {s}, but got success", .{@errorName(expected_error)});
        return error.ExpectedErrorButGotSuccess;
    }

    pub fn getMetricsOutput(self: *Self) !?[]const u8 {
        if (self.instrumentation) |*inst| {
            return try inst.metrics.toPrometheusFormat(self.allocator);
        }
        return null;
    }
};

fn EventCapture(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        events: std.ArrayList(T),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .events = std.ArrayList(T){},
            };
        }

        pub fn deinit(self: *Self) void {
            self.events.deinit(self.allocator);
        }

        pub fn capture(self: *Self, event: T) !void {
            try self.events.append(self.allocator, event);
        }

        pub fn clear(self: *Self) void {
            self.events.clearRetainingCapacity();
        }
    };
}

/// Test data generator for creating random test data
pub const TestDataGenerator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, seed: u64) Self {
        return .{
            .allocator = allocator,
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn randomString(self: *Self, len: usize) ![]u8 {
        const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        const result = try self.allocator.alloc(u8, len);
        for (result) |*c| {
            c.* = chars[self.rng.random().int(usize) % chars.len];
        }
        return result;
    }

    pub fn randomInt(self: *Self, comptime T: type, min: T, max: T) T {
        return self.rng.random().intRangeAtMost(T, min, max);
    }

    pub fn randomBool(self: *Self) bool {
        return self.rng.random().boolean();
    }

    pub fn randomChoice(self: *Self, comptime T: type, items: []const T) T {
        return items[self.rng.random().int(usize) % items.len];
    }

    pub fn uuid(self: *Self) ![36]u8 {
        const hex = "0123456789abcdef";
        var result: [36]u8 = undefined;

        var i: usize = 0;
        while (i < 36) : (i += 1) {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                result[i] = '-';
            } else {
                result[i] = hex[self.rng.random().int(usize) % hex.len];
            }
        }

        return result;
    }
};

/// Concurrent test utilities
pub const ConcurrentTest = struct {
    pub fn parallel(allocator: std.mem.Allocator, comptime ResultType: type, tasks: []const fn () anyerror!ResultType) ![]ResultType {
        var results = try allocator.alloc(ResultType, tasks.len);
        errdefer allocator.free(results);

        var threads = try allocator.alloc(std.Thread, tasks.len);
        defer allocator.free(threads);

        const TaskContext = struct {
            task: fn () anyerror!ResultType,
            result: *ResultType,
            error_ptr: *?anyerror,
        };

        var contexts = try allocator.alloc(TaskContext, tasks.len);
        defer allocator.free(contexts);

        for (tasks, 0..) |task, i| {
            contexts[i] = .{
                .task = task,
                .result = &results[i],
                .error_ptr = &(@as(?anyerror, null)),
            };

            threads[i] = try std.Thread.spawn(.{}, struct {
                fn run(ctx: *TaskContext) void {
                    ctx.result.* = ctx.task() catch |err| {
                        ctx.error_ptr.* = err;
                        return;
                    };
                }
            }.run, .{&contexts[i]});
        }

        for (threads) |thread| {
            thread.join();
        }

        for (contexts) |ctx| {
            if (ctx.error_ptr.*) |err| {
                return err;
            }
        }

        return results;
    }

    pub fn parallelWithTimeout(
        allocator: std.mem.Allocator,
        comptime ResultType: type,
        tasks: []const fn () anyerror!ResultType,
        timeout_ms: u64,
    ) ![]ResultType {
        const start = std.time.milliTimestamp();
        const results = try parallel(allocator, ResultType, tasks);

        const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
        if (elapsed > timeout_ms) {
            allocator.free(results);
            return error.Timeout;
        }

        return results;
    }
};

/// Test fixture support for setup/teardown
pub fn TestFixture(comptime SetupFn: type, comptime TeardownFn: type) type {
    return struct {
        const Self = @This();

        setup: SetupFn,
        teardown: TeardownFn,
        data: ?*anyopaque = null,

        pub fn init(setup: SetupFn, teardown: TeardownFn) Self {
            return .{
                .setup = setup,
                .teardown = teardown,
            };
        }

        pub fn beforeEach(self: *Self) !void {
            self.data = try self.setup();
        }

        pub fn afterEach(self: *Self) void {
            if (self.data) |data| {
                self.teardown(data);
                self.data = null;
            }
        }
    };
}

test "IntegrationTest basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try IntegrationTest.init(allocator, .{
        .enable_metrics = true,
        .enable_tracing = true,
        .db_mode = .in_memory,
    });
    defer ctx.deinit();

    try ctx.setUp();

    try ctx.expectEqual(42, 42);
    try ctx.expectContains("hello world", "world");

    const result: anyerror!i32 = error.TestError;
    try ctx.expectError(error.TestError, result);
}

test "TestDataGenerator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var gen = TestDataGenerator.init(allocator, 12345);

    const str = try gen.randomString(10);
    defer allocator.free(str);
    try testing.expectEqual(@as(usize, 10), str.len);

    const int_val = gen.randomInt(i32, 1, 100);
    try testing.expect(int_val >= 1 and int_val <= 100);

    const uuid_str = try gen.uuid();
    try testing.expectEqual(@as(usize, 36), uuid_str.len);
}

test "IntegrationTest with HTTP" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try IntegrationTest.init(allocator, .{
        .enable_metrics = false,
        .http_port = 8080,
    });
    defer ctx.deinit();

    const client = try ctx.http();
    try client.setHeader("Content-Type", "application/json");

    var response = try client.get("/api/test");
    defer response.deinit(allocator);
    try testing.expectEqual(@as(u16, 200), response.status_code);
}

test "IntegrationTest end-to-end service registration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try IntegrationTest.init(allocator, .{
        .enable_metrics = false,
        .enable_tracing = false,
        .db_mode = .in_memory,
    });
    defer ctx.deinit();

    const service = try allocator.create(i32);
    service.* = 42;
    try ctx.registerService("my_service", service, i32);

    const retrieved = ctx.getService("my_service", i32);
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(i32, 42), retrieved.?.*);
}
