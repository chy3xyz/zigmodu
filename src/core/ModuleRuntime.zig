//! Per-module runtime resource container.
//! Holds the bulkhead, rate limiter, and circuit breaker for one module.

const std = @import("std");
const api = @import("../api/Module.zig");
const Bulkhead = @import("../resilience/Bulkhead.zig").Bulkhead;
const RateLimiter = @import("../resilience/RateLimiter.zig").RateLimiter;
const CircuitBreaker = @import("../resilience/CircuitBreaker.zig").CircuitBreaker;

pub const ModuleRuntime = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    module_name: []const u8,
    options: api.RuntimeOptions,
    bulkhead: ?Bulkhead,
    rate_limiter: ?RateLimiter,
    circuit_breaker: ?CircuitBreaker,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, options: api.RuntimeOptions) !Self {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        var bulkhead: ?Bulkhead = null;
        if (options.max_concurrent > 0) {
            bulkhead = try Bulkhead.init(allocator, name_copy, options.max_concurrent, 0);
        }
        errdefer if (bulkhead) |*bh| bh.deinit();

        var rate_limiter: ?RateLimiter = null;
        if (options.max_qps > 0) {
            rate_limiter = try RateLimiter.init(allocator, name_copy, options.max_qps, options.max_qps);
        }
        errdefer if (rate_limiter) |*rl| rl.deinit();

        var circuit_breaker: ?CircuitBreaker = null;
        if (options.cb_failure_threshold > 0) {
            circuit_breaker = try CircuitBreaker.init(allocator, name_copy, .{
                .failure_threshold = options.cb_failure_threshold,
                .success_threshold = if (options.cb_success_threshold > 0) options.cb_success_threshold else 1,
                .timeout_seconds = options.cb_timeout_seconds,
                .half_open_max_calls = if (options.cb_half_open_max_calls > 0) options.cb_half_open_max_calls else 1,
            });
        }

        return .{
            .allocator = allocator,
            .module_name = name_copy,
            .options = options,
            .bulkhead = bulkhead,
            .rate_limiter = rate_limiter,
            .circuit_breaker = circuit_breaker,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.bulkhead) |*bh| bh.deinit();
        if (self.rate_limiter) |*rl| rl.deinit();
        if (self.circuit_breaker) |*cb| cb.deinit();
        self.allocator.free(self.module_name);
        self.* = undefined;
    }

    /// Try to acquire permission to execute one request/command.
    /// Returns false if bulkhead, rate limit, or circuit breaker rejects.
    pub fn tryEnter(self: *Self) bool {
        if (self.bulkhead) |*bh| {
            if (!bh.tryAcquire()) return false;
        }

        if (self.rate_limiter) |*rl| {
            if (!rl.tryAcquire()) {
                if (self.bulkhead) |*bh| bh.release();
                return false;
            }
        }

        if (self.circuit_breaker) |*cb| {
            if (cb.getState() == .OPEN) {
                if (self.bulkhead) |*bh| bh.release();
                if (self.rate_limiter) |*rl| rl.reset();
                return false;
            }
        }

        return true;
    }

    /// Release one bulkhead slot after execution.
    pub fn release(self: *Self) void {
        if (self.bulkhead) |*bh| bh.release();
    }

    pub fn recordSuccess(self: *Self) void {
        if (self.circuit_breaker) |*cb| {
            _ = cb.call(struct {
                fn op() !void {}
            }.op);
        }
    }

    pub fn recordFailure(self: *Self) void {
        if (self.circuit_breaker) |*cb| {
            _ = cb.call(struct {
                fn op() !void {
                    return error.ModuleFailure;
                }
            }.op);
        }
    }

    pub const Stats = struct {
        bulkhead_active: u32 = 0,
        bulkhead_rejected: u64 = 0,
        rate_available: u32 = 0,
        cb_state: ?CircuitBreaker.State = null,
    };

    pub fn getStats(self: *Self) Stats {
        var stats: Stats = .{};
        if (self.bulkhead) |*bh| {
            stats.bulkhead_active = bh.getActiveCount();
            stats.bulkhead_rejected = bh.getStats().total_rejected;
        }
        if (self.rate_limiter) |*rl| {
            stats.rate_available = rl.availableTokens();
        }
        if (self.circuit_breaker) |*cb| {
            stats.cb_state = cb.getState();
        }
        return stats;
    }
};

test "ModuleRuntime with all protections" {
    const allocator = std.testing.allocator;
    var rt = try ModuleRuntime.init(allocator, "order", .{
        .max_concurrent = 2,
        .max_qps = 5,
        .cb_failure_threshold = 1,
        .cb_success_threshold = 1,
        .cb_timeout_seconds = 0,
        .cb_half_open_max_calls = 1,
    });
    defer rt.deinit();

    try std.testing.expect(rt.tryEnter());
    try std.testing.expect(rt.tryEnter());
    try std.testing.expect(!rt.tryEnter()); // bulkhead full

    rt.release();
    try std.testing.expect(rt.tryEnter());
}

test "ModuleRuntime disabled when options are zero" {
    const allocator = std.testing.allocator;
    var rt = try ModuleRuntime.init(allocator, "user", .{});
    defer rt.deinit();

    for (0..10) |_| {
        try std.testing.expect(rt.tryEnter());
    }
}
