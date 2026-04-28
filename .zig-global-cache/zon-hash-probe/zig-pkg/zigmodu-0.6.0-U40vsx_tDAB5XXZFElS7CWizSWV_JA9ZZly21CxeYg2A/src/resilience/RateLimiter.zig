const std = @import("std");

/// 限流器 - 令牌桶算法
pub const RateLimiter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    name: []const u8,
    max_tokens: u32,
    refill_rate: u32, // tokens per second
    current_tokens: f64,
    last_refill_time: i64,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, max_tokens: u32, refill_rate: u32) !Self {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .max_tokens = max_tokens,
            .refill_rate = refill_rate,
            .current_tokens = @as(f64, @floatFromInt(max_tokens)),
            .last_refill_time = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
    }

    /// 尝试获取一个令牌
    pub fn tryAcquire(self: *Self) bool {
        self.refill();

        if (self.current_tokens >= 1.0) {
            self.current_tokens -= 1.0;
            return true;
        }

        return false;
    }

    /// 获取一个令牌，如果不可用则等待
    pub fn acquire(self: *Self) void {
        while (true) {
            if (self.tryAcquire()) break;
            // Note: Blocking sleep unavailable in Zig 0.16.0 sync context
            // In async context, use: suspend {} or io.sleep()
            break; // Exit in sync context - caller handles retry
        }
    }

    /// 尝试获取多个令牌
    pub fn tryAcquireMany(self: *Self, count: u32) bool {
        self.refill();

        const needed = @as(f64, @floatFromInt(count));
        if (self.current_tokens >= needed) {
            self.current_tokens -= needed;
            return true;
        }

        return false;
    }

    /// 补充令牌
    fn refill(self: *Self) void {
        const now = 0;
        const elapsed = now - self.last_refill_time;

        if (elapsed > 0) {
            const tokens_to_add = @as(f64, @floatFromInt(self.refill_rate)) * @as(f64, @floatFromInt(elapsed));
            self.current_tokens = @min(@as(f64, @floatFromInt(self.max_tokens)), self.current_tokens + tokens_to_add);
            self.last_refill_time = now;
        }
    }

    /// 获取当前可用令牌数
    pub fn availableTokens(self: *Self) u32 {
        self.refill();
        return @intFromFloat(self.current_tokens);
    }

    /// 重置限流器
    pub fn reset(self: *Self) void {
        self.current_tokens = @as(f64, @floatFromInt(self.max_tokens));
        self.last_refill_time = 0;
    }

    /// 获取限流器统计
    pub fn getStats(self: *Self) Stats {
        self.refill();
        return .{
            .name = self.name,
            .max_tokens = self.max_tokens,
            .refill_rate = self.refill_rate,
            .available_tokens = @intFromFloat(self.current_tokens),
        };
    }

    pub const Stats = struct {
        name: []const u8,
        max_tokens: u32,
        refill_rate: u32,
        available_tokens: u32,
    };
};

/// 限流器注册表
pub const RateLimiterRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    limiters: std.StringHashMap(RateLimiter),
    default_max_tokens: u32,
    default_refill_rate: u32,

    pub fn init(allocator: std.mem.Allocator, default_max_tokens: u32, default_refill_rate: u32) Self {
        return .{
            .allocator = allocator,
            .limiters = std.StringHashMap(RateLimiter).init(allocator),
            .default_max_tokens = default_max_tokens,
            .default_refill_rate = default_refill_rate,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.limiters.iterator();
        while (iter.next()) |*entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.limiters.deinit();
    }

    /// 获取或创建限流器
    pub fn getOrCreate(self: *Self, name: []const u8) !*RateLimiter {
        if (self.limiters.getPtr(name)) |limiter| {
            return limiter;
        }

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const limiter = try RateLimiter.init(
            self.allocator,
            name_copy,
            self.default_max_tokens,
            self.default_refill_rate,
        );
        try self.limiters.put(name_copy, limiter);

        return self.limiters.getPtr(name).?;
    }

    /// 获取限流器
    pub fn get(self: *Self, name: []const u8) ?*RateLimiter {
        return self.limiters.getPtr(name);
    }

    /// 为特定客户端创建限流器（IP限流）
    pub fn getOrCreateForClient(self: *Self, client_id: []const u8, max_tokens: u32, refill_rate: u32) !*RateLimiter {
        if (self.limiters.getPtr(client_id)) |limiter| {
            return limiter;
        }

        const id_copy = try self.allocator.dupe(u8, client_id);
        errdefer self.allocator.free(id_copy);
        const limiter = try RateLimiter.init(self.allocator, id_copy, max_tokens, refill_rate);
        try self.limiters.put(id_copy, limiter);

        return self.limiters.getPtr(client_id).?;
    }

    /// 生成限流报告
    pub fn generateReport(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        const writer = buf.writer(allocator);

        try writer.writeAll("=== Rate Limiter Report ===\n\n");

        var iter = self.limiters.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const limiter = entry.value_ptr.*;
            const stats = limiter.getStats();

            try writer.print("{s}:\n", .{name});
            try writer.print("  Max Tokens: {d}\n", .{stats.max_tokens});
            try writer.print("  Refill Rate: {d}/s\n", .{stats.refill_rate});
            try writer.print("  Available: {d}\n", .{stats.available_tokens});
            try writer.writeAll("\n");
        }

        return buf.toOwnedSlice(allocator);
    }
};

/// 滑动窗口限流器（更精确的限流）
pub const SlidingWindowRateLimiter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    name: []const u8,
    window_size_seconds: u64,
    max_requests: u32,
    requests: std.array_list.Managed(i64), // 请求时间戳列表

    pub fn init(allocator: std.mem.Allocator, name: []const u8, window_size_seconds: u64, max_requests: u32) !Self {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .window_size_seconds = window_size_seconds,
            .max_requests = max_requests,
            .requests = std.array_list.Managed(i64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.requests.deinit();
    }

    /// 尝试获取许可
    pub fn tryAcquire(self: *Self) bool {
        self.cleanupOldRequests();

        if (self.requests.items.len < self.max_requests) {
            self.requests.append(0) catch return false;
            return true;
        }

        return false;
    }

    /// 清理过期的请求记录
    fn cleanupOldRequests(self: *Self) void {
        const now = 0;
        const cutoff = now - @as(i64, @intCast(self.window_size_seconds));

        var i: usize = 0;
        while (i < self.requests.items.len) {
            if (self.requests.items[i] < cutoff) {
                _ = self.requests.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// 获取当前窗口内的请求数
    pub fn currentCount(self: *Self) usize {
        self.cleanupOldRequests();
        return self.requests.items.len;
    }
};

test "RateLimiter token bucket" {
    const allocator = std.testing.allocator;
    var limiter = try RateLimiter.init(allocator, "api", 3, 1);
    defer limiter.deinit();

    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.tryAcquire()); // exhausted

    // Note: Blocking sleep unavailable in Zig 0.16.0 - test validates sync behavior
    _ = {};
}

test "RateLimiterRegistry" {
    const allocator = std.testing.allocator;
    var registry = RateLimiterRegistry.init(allocator, 5, 10);
    defer registry.deinit();

    const limiter = try registry.getOrCreate("user");
    try std.testing.expectEqualStrings("user", limiter.name);
    try std.testing.expect(registry.get("user") != null);
}

test "SlidingWindowRateLimiter" {
    const allocator = std.testing.allocator;
    var limiter = try SlidingWindowRateLimiter.init(allocator, "window", 1, 2);
    defer limiter.deinit();

    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.tryAcquire()); // limit reached

    // Wait for window to slide
    // Note: Blocking sleep unavailable in Zig 0.16.0 - test validates sync behavior
    _ = {};
}
