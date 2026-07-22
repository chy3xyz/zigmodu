//! Per-module runtime resource container.
//! Holds the bulkhead, rate limiter, circuit breaker, and optional worker pool for one module.

const std = @import("std");
const api = @import("../api/Module.zig");
const Bulkhead = @import("../resilience/Bulkhead.zig").Bulkhead;
const RateLimiter = @import("../resilience/RateLimiter.zig").RateLimiter;
const CircuitBreaker = @import("../resilience/CircuitBreaker.zig").CircuitBreaker;
const WorkerPool = @import("WorkerPool.zig").WorkerPool;
const Task = @import("WorkerPool.zig").Task;

pub const ModuleRuntime = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    module_name: []const u8,
    options: api.RuntimeOptions,
    bulkhead: ?Bulkhead,
    rate_limiter: ?RateLimiter,
    circuit_breaker: ?CircuitBreaker,
    worker_pool: ?WorkerPool,
    mu: std.Io.Mutex,

    /// Thread-safety contract: all state-changing operations (`tryEnter`,
    /// `release`, `recordSuccess`, `recordFailure`) are protected by an internal
    /// `std.Io.Mutex`. It is therefore safe to call them concurrently from
    /// multiple fibers/threads that share the same `std.Io` instance.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, name: []const u8, options: api.RuntimeOptions) !Self {
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

        var worker_pool: ?WorkerPool = null;
        if (options.worker_count > 0) {
            worker_pool = try WorkerPool.init(allocator, io, name, options.worker_count, options.worker_count * 8);
        }

        return .{
            .allocator = allocator,
            .io = io,
            .module_name = name_copy,
            .options = options,
            .bulkhead = bulkhead,
            .rate_limiter = rate_limiter,
            .circuit_breaker = circuit_breaker,
            .worker_pool = worker_pool,
            .mu = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.bulkhead) |*bh| bh.deinit();
        if (self.rate_limiter) |*rl| rl.deinit();
        if (self.circuit_breaker) |*cb| cb.deinit();
        if (self.worker_pool) |*wp| wp.deinit();
        self.allocator.free(self.module_name);
        self.* = undefined;
    }

    /// Try to acquire permission to execute one request/command.
    /// Returns false if bulkhead, rate limit, or circuit breaker rejects.
    pub fn tryEnter(self: *Self) bool {
        self.mu.lock(self.io) catch return false;
        defer self.mu.unlock(self.io);

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
            if (!cb.canAccept()) {
                if (self.bulkhead) |*bh| bh.release();
                if (self.rate_limiter) |*rl| rl.release();
                return false;
            }
        }

        return true;
    }

    /// Release one bulkhead slot after execution.
    pub fn release(self: *Self) void {
        self.mu.lock(self.io) catch return;
        defer self.mu.unlock(self.io);

        if (self.bulkhead) |*bh| bh.release();
    }

    pub fn recordSuccess(self: *Self) void {
        self.mu.lock(self.io) catch return;
        defer self.mu.unlock(self.io);

        if (self.circuit_breaker) |*cb| {
            cb.onSuccess();
        }
    }

    pub fn recordFailure(self: *Self) void {
        self.mu.lock(self.io) catch return;
        defer self.mu.unlock(self.io);

        if (self.circuit_breaker) |*cb| {
            cb.onFailure();
        }
    }

    /// Dispatch a task on this module's worker pool. Returns false if no pool or queue full.
    pub fn dispatchAsync(self: *Self, task: Task) bool {
        if (self.worker_pool) |*wp| {
            return wp.dispatch(task);
        }
        return false;
    }

    pub const Stats = struct {
        bulkhead_active: u32 = 0,
        bulkhead_rejected: u64 = 0,
        rate_available: u32 = 0,
        cb_state: ?CircuitBreaker.State = null,
    };

    pub fn getStats(self: *Self) Stats {
        self.mu.lock(self.io) catch return .{};
        defer self.mu.unlock(self.io);

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
    var rt = try ModuleRuntime.init(allocator, std.testing.io, "order", .{
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
    var rt = try ModuleRuntime.init(allocator, std.testing.io, "user", .{});
    defer rt.deinit();

    for (0..10) |_| {
        try std.testing.expect(rt.tryEnter());
    }
}

test "ModuleRuntime rejects HALF_OPEN circuit breaker over limit" {
    const allocator = std.testing.allocator;
    var rt = try ModuleRuntime.init(allocator, std.testing.io, "payment", .{
        .max_concurrent = 1,
        .max_qps = 0,
        .cb_failure_threshold = 1,
        .cb_success_threshold = 3,
        .cb_timeout_seconds = 0,
        .cb_half_open_max_calls = 2,
    });
    defer rt.deinit();

    // One failure opens the circuit; with timeout=0 the next state check moves it to HALF_OPEN.
    rt.recordFailure();
    try std.testing.expectEqual(CircuitBreaker.State.HALF_OPEN, rt.circuit_breaker.?.getState());

    // Exhaust the two half-open test calls without reaching success_threshold.
    rt.recordSuccess();
    rt.recordSuccess();
    try std.testing.expectEqual(CircuitBreaker.State.HALF_OPEN, rt.circuit_breaker.?.getState());

    // A new request must be rejected because the half-open budget is exhausted.
    try std.testing.expect(!rt.tryEnter());
}

test "ModuleRuntime refunds rate limiter token when circuit breaker rejects" {
    const allocator = std.testing.allocator;
    var rt = try ModuleRuntime.init(allocator, std.testing.io, "refund-test", .{
        .max_concurrent = 1,
        .max_qps = 2,
        .cb_failure_threshold = 1,
        .cb_success_threshold = 3,
        .cb_timeout_seconds = 0,
        .cb_half_open_max_calls = 1,
    });
    defer rt.deinit();

    // Consume one rate-limit token while the circuit is still CLOSED.
    try std.testing.expect(rt.tryEnter());
    rt.release();
    try std.testing.expectEqual(@as(u32, 1), rt.rate_limiter.?.availableTokens());

    // Open the circuit and exhaust the single HALF_OPEN test call.
    rt.recordFailure();
    try std.testing.expectEqual(CircuitBreaker.State.HALF_OPEN, rt.circuit_breaker.?.getState());
    rt.recordSuccess();
    try std.testing.expect(!rt.circuit_breaker.?.canAccept());

    // tryEnter acquires a rate token, the breaker rejects, and the token is refunded.
    try std.testing.expect(!rt.tryEnter());
    try std.testing.expectEqual(@as(u32, 1), rt.rate_limiter.?.availableTokens());
}

test "ModuleRuntime recordSuccess and recordFailure drive breaker state" {
    const allocator = std.testing.allocator;
    var rt = try ModuleRuntime.init(allocator, std.testing.io, "state-test", .{
        .max_concurrent = 1,
        .max_qps = 0,
        .cb_failure_threshold = 2,
        .cb_success_threshold = 2,
        .cb_timeout_seconds = 10,
        .cb_half_open_max_calls = 3,
    });
    defer rt.deinit();

    try std.testing.expectEqual(CircuitBreaker.State.CLOSED, rt.circuit_breaker.?.getState());

    rt.recordFailure();
    try std.testing.expectEqual(CircuitBreaker.State.CLOSED, rt.circuit_breaker.?.getState());

    rt.recordFailure();
    try std.testing.expectEqual(CircuitBreaker.State.OPEN, rt.circuit_breaker.?.state);

    // Simulate the timeout expiring so the next state check moves to HALF_OPEN.
    rt.circuit_breaker.?.last_failure_time = 0;
    try std.testing.expectEqual(CircuitBreaker.State.HALF_OPEN, rt.circuit_breaker.?.getState());

    // Two consecutive successes close it again.
    rt.recordSuccess();
    rt.recordSuccess();
    try std.testing.expectEqual(CircuitBreaker.State.CLOSED, rt.circuit_breaker.?.getState());
}

test "ModuleRuntime concurrent tryEnter and release do not corrupt state" {
    const allocator = std.testing.allocator;
    var rt = try ModuleRuntime.init(allocator, std.testing.io, "concurrent-test", .{
        .max_concurrent = 2,
        .max_qps = 100,
        .cb_failure_threshold = 0,
    });
    defer rt.deinit();

    const Context = struct {
        rt: *ModuleRuntime,
        local_successes: usize,

        fn run(ctx: *@This()) void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                if (ctx.rt.tryEnter()) {
                    ctx.local_successes += 1;
                    ctx.rt.release();
                }
            }
        }
    };

    var contexts: [10]Context = undefined;
    var threads: [10]std.Thread = undefined;

    for (&contexts, &threads) |*ctx, *t| {
        ctx.* = .{ .rt = &rt, .local_successes = 0 };
        t.* = try std.Thread.spawn(.{}, Context.run, .{ctx});
    }

    for (&threads) |*t| t.join();

    var total_successes: usize = 0;
    for (&contexts) |*ctx| total_successes += ctx.local_successes;

    // No slot should be leaked, and the total accepted calls must not exceed
    // the per-thread budget because each successful enter is paired with a release.
    const stats = rt.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.bulkhead_active);
    try std.testing.expect(total_successes > 0);
}

test "ModuleRuntime creates worker pool from worker_count" {
    const allocator = std.testing.allocator;
    var rt = try ModuleRuntime.init(allocator, std.testing.io, "worker", .{
        .worker_count = 2,
    });
    defer rt.deinit();

    const Ctx = struct {
        var counter: std.atomic.Value(u32) = .init(0);
        fn run(ctx: ?*anyopaque, io: std.Io) void {
            _ = ctx;
            _ = io;
            _ = @This().counter.fetchAdd(1, .monotonic);
        }
    };

    try std.testing.expect(rt.dispatchAsync(.{ .run = Ctx.run, .ctx = null }));
    while (Ctx.counter.load(.monotonic) < 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
}
