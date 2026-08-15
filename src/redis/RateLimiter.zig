//! Distributed fixed-window rate limiter backed by Redis.
//!
//! `allow(key, max, window_seconds)` does an atomic INCR and sets the key
//! expiry on the first increment within the window. Because Redis is shared
//! across instances, the window is enforced globally — unlike an in-process
//! counter.
//!
//! Fail-closed: when Redis is unreachable the INCR/EXPIRE returns
//! `error.RedisError` and this propagates to the caller. Never treat the
//! error as "allowed" — a rate limit must not silently open when its
//! backend is down.

const std = @import("std");
const Redis = @import("redis.zig").Redis;

pub const RateLimiter = struct {
    const Self = @This();

    redis: *Redis,

    pub fn init(redis: *Redis) Self {
        return .{ .redis = redis };
    }

    /// Check and consume one unit of the limit. Returns `true` when the key
    /// is within `max` increments in the last `window_seconds`, `false` when
    /// over the limit. Returns an error (fail-closed) when Redis is down.
    pub fn allow(self: *Self, key: []const u8, max: u64, window_seconds: u32) !bool {
        if (max == 0) return false;
        const count = try self.redis.incr(key);
        if (count == 1) {
            // First increment in this window — arm the expiry so a stale key
            // can't pin a full bucket forever.
            try self.redis.expire(key, window_seconds);
        }
        return @as(u64, @intCast(count)) <= max;
    }
};

test "RateLimiter denies when max is zero" {
    var redis = Redis.init(std.testing.allocator);
    defer redis.deinit();
    var rl = RateLimiter.init(&redis);
    try std.testing.expect(!(try rl.allow("k", 0, 60)));
}

test "RateLimiter fail-closed when Redis is not connected" {
    var redis = Redis.init(std.testing.allocator);
    defer redis.deinit();
    var rl = RateLimiter.init(&redis);
    // No connection → incr returns error.RedisError (fail-closed).
    try std.testing.expectError(error.RedisError, rl.allow("k", 10, 60));
}
