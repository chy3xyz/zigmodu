const std = @import("std");

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

    /// 执行受保护的调用
    pub fn call(self: *Self, operation: *const fn () anyerror!void) Result {
        // 检查当前状态
        self.updateState();

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
        self.last_failure_time = std.time.timestamp();

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
            const now = std.time.timestamp();
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
        self.last_failure_time = std.time.timestamp();
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
        while (iter.next()) |entry| {
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
        const entry = self.breakers.fetchRemove(name) orelse return false;
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
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll("=== Circuit Breaker Report ===\n\n");

        var iter = self.breakers.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const breaker = entry.value_ptr.*;
            const stats = breaker.getStats();

            try writer.print("{s}:\n", .{name});
            try writer.print("  State: {s}\n", .{@tagName(stats.state)});
            try writer.print("  Failures: {d}\n", .{stats.failure_count});
            try writer.print("  Successes: {d}\n", .{stats.success_count});
            try writer.writeAll("\n");
        }

        return buf.toOwnedSlice(allocator);
    }
};
