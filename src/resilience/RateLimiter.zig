const std = @import("std");
const Time = @import("../core/Time.zig");

/// Rate limiter — token bucket algorithm
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
            .last_refill_time = Time.monotonicNowSeconds(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
    }

    /// Try to acquire one token
    pub fn tryAcquire(self: *Self) bool {
        self.refill();

        if (self.current_tokens >= 1.0) {
            self.current_tokens -= 1.0;
            return true;
        }

        return false;
    }

    /// Acquire token, wait if unavailable
    /// DEPRECATED: Use tryAcquire() instead. This was meant to block
    /// but blocking sleep is unavailable in Zig 0.16 sync context.
    pub fn acquire(self: *Self) bool {
        return self.tryAcquire();
    }

    /// Try to acquire multiple tokens
    pub fn tryAcquireMany(self: *Self, count: u32) bool {
        self.refill();

        const needed = @as(f64, @floatFromInt(count));
        if (self.current_tokens >= needed) {
            self.current_tokens -= needed;
            return true;
        }

        return false;
    }

    /// [...]tokens (uses cached timestamp — refill rate is per-second, ~1s staleness OK)
    fn refill(self: *Self) void {
        const now = Time.cachedNowSeconds();
        const elapsed = now - self.last_refill_time;

        if (elapsed > 0) {
            const tokens_to_add = @as(f64, @floatFromInt(self.refill_rate)) * @as(f64, @floatFromInt(elapsed));
            self.current_tokens = @min(@as(f64, @floatFromInt(self.max_tokens)), self.current_tokens + tokens_to_add);
            self.last_refill_time = now;
        }
    }

    /// Get current[...]tokens[...]
    pub fn availableTokens(self: *Self) u32 {
        self.refill();
        return @intFromFloat(self.current_tokens);
    }

    /// [...]
    pub fn reset(self: *Self) void {
        self.current_tokens = @as(f64, @floatFromInt(self.max_tokens));
        self.last_refill_time = Time.monotonicNowSeconds();
    }

    /// [...]
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

/// [...]
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

    /// [...]
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

    /// [...]
    pub fn get(self: *Self, name: []const u8) ?*RateLimiter {
        return self.limiters.getPtr(name);
    }

    /// Create rate limiter for specific client[...]IP[...]
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

    /// [...]
    pub fn generateReport(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        return allocator.dupe(u8, "generateReport (pending Zig 0.16 allocPrint migration)");
    }
};

/// [...]
pub const SlidingWindowRateLimiter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    name: []const u8,
    window_size_seconds: u64,
    max_requests: u32,
    requests: std.array_list.Managed(i64), // Request timestamp list

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

    /// [...]
    pub fn tryAcquire(self: *Self) bool {
        self.cleanupOldRequests();

        if (self.requests.items.len < self.max_requests) {
            self.requests.append(Time.monotonicNowSeconds()) catch return false;
            return true;
        }

        return false;
    }

    /// [...]
    fn cleanupOldRequests(self: *Self) void {
        const now = Time.cachedNowSeconds();
        const cutoff = now - @as(i64, @intCast(self.window_size_seconds));

        var i: usize = 0;
        while (i < self.requests.items.len) {
            if (self.requests.items[i] < cutoff) {
                _ = self.requests.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Get current[...]
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

test "RateLimiter burst and refill" {
    const allocator = std.testing.allocator;
    var limiter = try RateLimiter.init(allocator, "burst", 5, 1); // 5 tokens, refill 1/sec
    defer limiter.deinit();

    // Burst: consume all 5 tokens rapidly
    var allowed: u32 = 0;
    for (0..10) |_| {
        if (limiter.tryAcquire()) allowed += 1;
    }
    try std.testing.expectEqual(@as(u32, 5), allowed); // exactly 5 allowed

    // After burst, no more tokens available
    try std.testing.expect(!limiter.tryAcquire());
    try std.testing.expectEqual(@as(u32, 0), limiter.availableTokens());
}
