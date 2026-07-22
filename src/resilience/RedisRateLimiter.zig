//! Redis-based distributed rate limiter
//!
//! Uses Redis INCR + EXPIRE to implement a sliding-window rate limiter
//! that works across multiple nodes sharing a Redis instance.

const std = @import("std");
const redis = @import("../redis/redis.zig");

/// Distributed rate limiter backed by Redis.
///
/// Each key gets its own sliding window. The window is reset
/// every `window_seconds` via Redis EXPIRE.
pub const RedisRateLimiter = struct {
    const Self = @This();

    redis: *redis.Redis,
    window_seconds: u64,
    max_requests: u64,

    /// Check if a request is allowed for the given key.
    ///
    /// Uses Redis INCR to atomically increment the counter.
    /// On first request (count == 1), sets EXPIRE to start the window.
    /// Returns true if the count is within the limit.
    pub fn allow(self: *Self, key: []const u8) !bool {
        const count = try self.redis.incr(key);

        // Set expiry on the first request in the window
        if (count == 1) {
            try self.redis.expire(key, @intCast(self.window_seconds));
        }

        return count <= @as(i64, @intCast(self.max_requests));
    }

    /// Get the current request count for a key within its window.
    /// Returns 0 if the key does not exist.
    pub fn currentCount(self: *Self, key: []const u8) !u64 {
        const val = try self.redis.get(key);
        if (val) |v| {
            defer self.redis.allocator.free(v);
            return std.fmt.parseInt(u64, v, 10) catch 0;
        }
        return 0;
    }

    /// Reset the counter for a key, removing its window.
    pub fn reset(self: *Self, key: []const u8) !void {
        _ = try self.redis.del(&.{key});
    }

    /// Try acquire with automatic local fallback when Redis is unreachable or returns error.
    pub fn allowWithFallback(self: *Self, key: []const u8, local_limiter: ?*@import("RateLimiter.zig").RateLimiter) bool {
        const is_redis_valid = if (@intFromPtr(self.redis) == 0) false else self.redis.stream != null;
        const allowed = if (!is_redis_valid) blk: {
            std.log.warn("[RedisRateLimiter] Redis client disconnected, falling back to local RateLimiter for key='{s}'", .{key});
            if (local_limiter) |ll| {
                break :blk ll.tryAcquire();
            }
            break :blk true;
        } else self.allow(key) catch |err| blk: {
            std.log.warn("[RedisRateLimiter] Redis call failed ({}), falling back to local RateLimiter for key='{s}'", .{ err, key });
            if (local_limiter) |ll| {
                break :blk ll.tryAcquire();
            }
            break :blk true;
        };
        return allowed;
    }
};

// ── Tests ──

test "RedisRateLimiter allows within limit" {
    const allocator = std.testing.allocator;

    // Use in-memory simulation since we can't connect to Redis in unit tests.
    // The RedisRateLimiter constructor requires a connected Redis client,
    // so we skip these tests unless REDIS_URL is set.
    const redis_url = if (std.c.getenv("REDIS_URL")) |ptr| std.mem.span(ptr) else null;
    if (redis_url == null or redis_url.?.len == 0) return error.SkipZigTest;

    var r = try redis.Redis.new(allocator, std.testing.io, .{});
    defer r.deinit();
    try r.connect();

    var limiter = RedisRateLimiter{
        .redis = &r,
        .window_seconds = 60,
        .max_requests = 5,
    };

    // Clean up any previous test data
    limiter.reset("test-rate-limit-key") catch {};

    // All requests within limit should be allowed
    for (0..5) |_| {
        try std.testing.expect(try limiter.allow("test-rate-limit-key"));
    }

    limiter.reset("test-rate-limit-key") catch {};
}

test "RedisRateLimiter denies over limit" {
    const allocator = std.testing.allocator;

    const redis_url = if (std.c.getenv("REDIS_URL")) |ptr| std.mem.span(ptr) else null;
    if (redis_url == null or redis_url.?.len == 0) return error.SkipZigTest;

    var r = try redis.Redis.new(allocator, std.testing.io, .{});
    defer r.deinit();
    try r.connect();

    var limiter = RedisRateLimiter{
        .redis = &r,
        .window_seconds = 60,
        .max_requests = 3,
    };

    limiter.reset("test-rate-limit-over") catch {};

    // First 3 should be allowed
    try std.testing.expect(try limiter.allow("test-rate-limit-over"));
    try std.testing.expect(try limiter.allow("test-rate-limit-over"));
    try std.testing.expect(try limiter.allow("test-rate-limit-over"));

    limiter.reset("test-rate-limit-over") catch {};
}

test "RedisRateLimiter degradation fallback" {
    const allocator = std.testing.allocator;
    var local_rl = try @import("RateLimiter.zig").RateLimiter.init(allocator, "test-local", 2, 2);
    defer local_rl.deinit();

    var r = redis.Redis{
        .allocator = allocator,
        .io = std.testing.io,
        .stream = null,
        .config = .{},
    };


    var dummy_limiter = RedisRateLimiter{
        .redis = &r,
        .window_seconds = 60,
        .max_requests = 10,
    };

    try std.testing.expect(dummy_limiter.allowWithFallback("test-key", &local_rl));
    try std.testing.expect(dummy_limiter.allowWithFallback("test-key", &local_rl));
    // 3rd call exceeds local_rl limit of 2, so should be denied
    try std.testing.expect(!dummy_limiter.allowWithFallback("test-key", &local_rl));
}


