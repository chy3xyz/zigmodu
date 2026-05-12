const std = @import("std");
const Time = @import("../core/Time.zig");

/// 断路器模式 - 实现容错机制
pub const CircuitBreaker = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    name: []const u8,
    state: State,
    failure_count: u32,
    success_count: u32,
    last_failure_time: i64,
    config: Config,

    pub const State = enum {
        CLOSED, // 正常状态，允许请求通过
        OPEN, // 断路状态，拒绝请求
        HALF_OPEN, // 半开状态，允许有限请求测试
    };

    pub const Config = struct {
        failure_threshold: u32, // 触发断路的失败次数阈值
        success_threshold: u32, // 半开状态下恢复成功的阈值
        timeout_seconds: u64, // 断路器打开后的超时时间
        half_open_max_calls: u32, // 半开状态下允许的最大调用数
    };

    pub const Result = union(enum) {
        success: void,
        failure: anyerror,
        circuit_open: void,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, config: Config) !Self {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .state = .CLOSED,
            .failure_count = 0,
            .success_count = 0,
            .last_failure_time = 0,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
    }

    /// Execute a protected call through the circuit breaker.
    ///
    /// Thread safety: this method is NOT thread-safe. For concurrent access,
    /// wrap the CircuitBreaker in a Mutex or use one instance per fiber.
    pub fn call(self: *Self, operation: *const fn () anyerror!void) Result {
        // Hot path: CLOSED state (~99.9% of calls) skips the updateState syscall.
        if (self.state != .CLOSED) {
            self.updateState();
        }

        switch (self.state) {
            .OPEN => {
                std.log.warn("Circuit breaker '{s}' is OPEN, rejecting call", .{self.name});
                return .circuit_open;
            },
            .HALF_OPEN => {
                if (self.success_count >= self.config.half_open_max_calls) {
                    std.log.warn("Circuit breaker '{s}' HALF_OPEN limit reached", .{self.name});
                    return .circuit_open;
                }
            },
            .CLOSED => {},
        }

        // 执行操作
        operation() catch |err| {
            self.onFailure();
            return .{ .failure = err };
        };

        self.onSuccess();
        return .success;
    }

    /// 记录成功
    fn onSuccess(self: *Self) void {
        switch (self.state) {
            .CLOSED => {
                // 重置失败计数
                self.failure_count = 0;
            },
            .HALF_OPEN => {
                self.success_count += 1;
                if (self.success_count >= self.config.success_threshold) {
                    // 恢复关闭状态
                    std.log.info("Circuit breaker '{s}' closing after {d} successes", .{ self.name, self.success_count });
                    self.state = .CLOSED;
                    self.failure_count = 0;
                    self.success_count = 0;
                }
            },
            .OPEN => {},
        }
    }

    /// 记录失败
    fn onFailure(self: *Self) void {
        self.failure_count += 1;
        self.last_failure_time = Time.monotonicNowSeconds();

        switch (self.state) {
            .CLOSED => {
                if (self.failure_count >= self.config.failure_threshold) {
                    // 触发断路
                    std.log.warn("Circuit breaker '{s}' opening after {d} failures", .{ self.name, self.failure_count });
                    self.state = .OPEN;
                }
            },
            .HALF_OPEN => {
                // 半开状态下失败，重新打开
                std.log.warn("Circuit breaker '{s}' re-opening after failure in HALF_OPEN", .{self.name});
                self.state = .OPEN;
                self.success_count = 0;
            },
            .OPEN => {},
        }
    }

    /// 更新断路器状态（检查超时）
    fn updateState(self: *Self) void {
        if (self.state == .OPEN) {
            const now = Time.monotonicNowSeconds();
            const elapsed = @as(u64, @intCast(now - self.last_failure_time));

            if (elapsed >= self.config.timeout_seconds) {
                // 超时，进入半开状态
                std.log.info("Circuit breaker '{s}' entering HALF_OPEN after timeout", .{self.name});
                self.state = .HALF_OPEN;
                self.success_count = 0;
            }
        }
    }

    /// 手动重置断路器
    pub fn reset(self: *Self) void {
        std.log.info("Circuit breaker '{s}' manually reset", .{self.name});
        self.state = .CLOSED;
        self.failure_count = 0;
        self.success_count = 0;
        self.last_failure_time = 0;
    }

    /// 强制打开断路器
    pub fn forceOpen(self: *Self) void {
        std.log.warn("Circuit breaker '{s}' manually forced OPEN", .{self.name});
        self.state = .OPEN;
        self.last_failure_time = 0;
    }

    /// 获取当前状态
    pub fn getState(self: *Self) State {
        self.updateState();
        return self.state;
    }

    /// 获取统计信息
    pub fn getStats(self: *Self) Stats {
        return .{
            .state = self.state,
            .failure_count = self.failure_count,
            .success_count = self.success_count,
            .last_failure_time = self.last_failure_time,
        };
    }

    pub const Stats = struct {
        state: State,
        failure_count: u32,
        success_count: u32,
        last_failure_time: i64,
    };
};

/// 断路器注册表 - 管理多个断路器
pub const CircuitBreakerRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    breakers: std.StringHashMap(CircuitBreaker),
    default_config: CircuitBreaker.Config,

    pub fn init(allocator: std.mem.Allocator, default_config: CircuitBreaker.Config) Self {
        return .{
            .allocator = allocator,
            .breakers = std.StringHashMap(CircuitBreaker).init(allocator),
            .default_config = default_config,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.breakers.iterator();
        while (iter.next()) |*entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.breakers.deinit();
    }

    /// 获取或创建断路器
    pub fn getOrCreate(self: *Self, name: []const u8) !*CircuitBreaker {
        if (self.breakers.getPtr(name)) |breaker| {
            return breaker;
        }

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const breaker = try CircuitBreaker.init(self.allocator, name_copy, self.default_config);
        try self.breakers.put(name_copy, breaker);

        return self.breakers.getPtr(name).?;
    }

    /// 获取断路器
    pub fn get(self: *Self, name: []const u8) ?*CircuitBreaker {
        return self.breakers.getPtr(name);
    }

    /// 移除断路器
    pub fn remove(self: *Self, name: []const u8) bool {
        var entry = self.breakers.fetchRemove(name) orelse return false;
        self.allocator.free(entry.key);
        entry.value.deinit();
        return true;
    }

    /// 重置所有断路器
    pub fn resetAll(self: *Self) void {
        var iter = self.breakers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.reset();
        }
    }

    /// 获取所有断路器状态报告
    pub fn generateReport(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        return allocator.dupe(u8, "generateReport (pending Zig 0.16 allocPrint migration)");
    }
};

test "CircuitBreaker state transitions" {
    const allocator = std.testing.allocator;
    var cb = try CircuitBreaker.init(allocator, "test", .{
        .failure_threshold = 3,
        .success_threshold = 2,
        .timeout_seconds = 1,
        .half_open_max_calls = 5,
    });
    defer cb.deinit();

    const fail_op = struct {
        fn op() !void {
            return error.TestFail;
        }
    }.op;

    const ok_op = struct {
        fn op() !void {}
    }.op;

    // Initially CLOSED
    try std.testing.expectEqual(CircuitBreaker.State.CLOSED, cb.getState());

    // 3 failures -> OPEN
    _ = cb.call(fail_op);
    _ = cb.call(fail_op);
    _ = cb.call(fail_op);
    try std.testing.expectEqual(CircuitBreaker.State.OPEN, cb.getState());

    // Wait for timeout -> HALF_OPEN (simulate time passing)
    cb.last_failure_time = -10;
    try std.testing.expectEqual(CircuitBreaker.State.HALF_OPEN, cb.getState());
    try std.testing.expectEqual(CircuitBreaker.State.HALF_OPEN, cb.getState());

    // 2 successes -> CLOSED
    _ = cb.call(ok_op);
    _ = cb.call(ok_op);
    try std.testing.expectEqual(CircuitBreaker.State.CLOSED, cb.getState());
}

test "CircuitBreakerRegistry" {
    const allocator = std.testing.allocator;
    var registry = CircuitBreakerRegistry.init(allocator, .{
        .failure_threshold = 2,
        .success_threshold = 1,
        .timeout_seconds = 1,
        .half_open_max_calls = 3,
    });
    defer registry.deinit();

    const cb = try registry.getOrCreate("api");
    try std.testing.expectEqualStrings("api", cb.name);
    try std.testing.expect(registry.get("api") != null);

    try std.testing.expect(registry.remove("api"));
    try std.testing.expect(registry.get("api") == null);
}

test "CircuitBreaker OPEN to HALF_OPEN via timeout" {
    const allocator = std.testing.allocator;

    var cb = try CircuitBreaker.init(allocator, "test-hc", .{
        .failure_threshold = 1,
        .success_threshold = 2,
        .timeout_seconds = 0,
        .half_open_max_calls = 10,
    });
    defer cb.deinit();

    // Force OPEN with 0 timestamp
    cb.forceOpen();
    try std.testing.expectEqual(CircuitBreaker.State.OPEN, cb.state);

    // getState() calls updateState(), which triggers OPEN->HALF_OPEN with timeout=0
    const state = cb.getState();
    try std.testing.expectEqual(CircuitBreaker.State.HALF_OPEN, state);

    // Reset to CLOSED
    cb.reset();
    try std.testing.expectEqual(CircuitBreaker.State.CLOSED, cb.state);
}
