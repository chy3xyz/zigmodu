//! Production-grade HTTP middlewares — tracing, rate limiting.
//! Plugs into `zigmodu.http.Server.addMiddleware(...)`.
//!
//! Usage:
//!   server.addMiddleware(zigmodu.http_middleware.tracing(&tracer));
//!   server.addMiddleware(zigmodu.http_middleware.rateLimit(&limiter));

const std = @import("std");
const api = @import("../../api/Server.zig");
const Time = @import("../../core/Time.zig");
const CircutBreaker = @import("../../resilience/CircuitBreaker.zig").CircuitBreaker;
const RateLimiter = @import("../../resilience/RateLimiter.zig").RateLimiter;

// ═══════════════════════════════════════════════════════════════
// Tracing middleware
// ═══════════════════════════════════════════════════════════════

var trace_id_counter = std.atomic.Value(u64).init(0);

/// Tracing middleware — injects `x-trace-id` and logs request timing.
/// Integrates with DistributedTracer when available.
/// Usage: `server.addMiddleware(tracing(&tracer))`
pub fn tracing() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                // Generate unique trace-id for this request
                const now_ns: u64 = @intCast(Time.monotonicNow());
                const counter = trace_id_counter.fetchAdd(1, .monotonic);
                const trace_id = try std.fmt.allocPrint(ctx.allocator, "{x:016}-{x:016}", .{ now_ns, counter });
                defer ctx.allocator.free(trace_id);

                // Inject trace-id into request context for downstream use
                try ctx.setHeader("x-trace-id", trace_id);

                // Record start time
                const start_ns = Time.monotonicNow();

                // Execute downstream
                try next(ctx);

                // Log with trace-id for correlation
                const elapsed_us = @divTrunc(Time.monotonicNow() - start_ns, std.time.ns_per_us);
                std.log.info("[trace={s}] {s} {s} → {d} ({d}μs)", .{
                    trace_id,
                    ctx.method.toString(),
                    ctx.raw_path,
                    ctx.status_code,
                    elapsed_us,
                });
            }
        }.mw,
    };
}

/// Inject a provided trace-id (from incoming request headers).
/// Used when propagating a trace from an upstream service.
pub fn tracingWithTrace(header_name: []const u8) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const hdr: []const u8 = @ptrCast(@alignCast(user_data.?));
                // Propagate incoming trace-id if present
                if (ctx.headers.get(hdr)) |incoming_trace| {
                    try ctx.setHeader("x-trace-id", incoming_trace);
                } else {
                    const now_ns: u64 = @intCast(Time.monotonicNow());
                    const counter = trace_id_counter.fetchAdd(1, .monotonic);
                    const trace_id = try std.fmt.allocPrint(ctx.allocator, "{x:016}-{x:016}", .{ now_ns, counter });
                    defer ctx.allocator.free(trace_id);
                    try ctx.setHeader("x-trace-id", trace_id);
                }
                try next(ctx);
            }
        }.mw,
        .user_data = @constCast(@ptrCast(header_name.ptr)),
    };
}

// ═══════════════════════════════════════════════════════════════
// Rate limiting middleware
// ═══════════════════════════════════════════════════════════════

/// Rate limiting middleware — rejects requests when the limiter is exhausted.
/// Uses the token-bucket RateLimiter from resilience module.
/// Usage: `server.addMiddleware(rateLimit(&limiter))`
pub fn rateLimit(limiter: *RateLimiter) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const lim: *RateLimiter = @ptrCast(@alignCast(user_data.?));
                if (!lim.tryAcquire()) {
                    std.log.warn("[RateLimit] Rejected {s} {s}: limit exceeded", .{
                        ctx.method.toString(), ctx.raw_path,
                    });
                    try ctx.sendErrorResponse(429, 429, "Too Many Requests");
                    return;
                }
                try next(ctx);
            }
        }.mw,
        .user_data = @ptrCast(limiter),
    };
}

/// Per-client rate limiting — uses a specific key from the request (IP, API key, etc).
/// Usage: `server.addMiddleware(rateLimitPerClient(&registry, extractKey))`
pub fn rateLimitPerClient(
    registry: *RateLimiterRegistry,
    key_extractor: *const fn (*api.Context) []const u8,
) api.Middleware {
    const ctx_ptr = std.heap.page_allocator.create(struct {
        registry: *RateLimiterRegistry,
        extractor: *const fn (*api.Context) []const u8,
    }) catch unreachable;
    ctx_ptr.* = .{ .registry = registry, .extractor = key_extractor };

    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const state = @as(*struct {
                    registry: *RateLimiterRegistry,
                    extractor: *const fn (*api.Context) []const u8,
                }, @ptrCast(@alignCast(user_data.?)));
                const client_key = state.extractor(ctx);
                const lim = try state.registry.getOrCreateForClient(client_key, 100, 10);
                if (!lim.tryAcquire()) {
                    try ctx.sendErrorResponse(429, 429, "Too Many Requests");
                    return;
                }
                try next(ctx);
            }
        }.mw,
        .user_data = @ptrCast(ctx_ptr),
    };
}

// ═══════════════════════════════════════════════════════════════
// Circuit breaker middleware
// ═══════════════════════════════════════════════════════════════

/// Circuit breaker middleware — opens the breaker on repeated failures.
/// Usage: `server.addMiddleware(circuitBreak(&breaker))`
pub fn circuitBreak(breaker: *CircutBreaker) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const cb: *CircutBreaker = @ptrCast(@alignCast(user_data.?));
                // Check breaker state before calling downstream
                _ = cb.getStats(); // triggers state update
                if (cb.getState() == .OPEN) {
                    try ctx.sendErrorResponse(503, 503, "Service Unavailable (circuit open)");
                    return;
                }
                // Execute downstream and track result
                next(ctx) catch |err| {
                    _ = cb.call(struct {
                        fn fail() anyerror!void { return error.BreakerFail; }
                    }.fail);
                    return err;
                };
                _ = cb.call(struct {
                    fn ok() anyerror!void {}
                }.ok);
            }
        }.mw,
        .user_data = @ptrCast(breaker),
    };
}

// Re-export RateLimiterRegistry from resilience
const RateLimiterRegistry = @import("../../resilience/RateLimiter.zig").RateLimiterRegistry;

// ═══════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════

test "tracing middleware injects x-trace-id" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const mw = tracing();
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(ctx.response_headers.get("x-trace-id") != null);
}

test "rateLimit middleware allows request" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    var limiter = try RateLimiter.init(allocator, "test", 10, 5);
    defer limiter.deinit();

    const mw = rateLimit(&limiter);
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(!ctx.responded); // Request was allowed through
}

test "rateLimit middleware blocks exhausted requests" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    var limiter = try RateLimiter.init(allocator, "test", 1, 1);
    defer limiter.deinit();

    const mw = rateLimit(&limiter);
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    // First request — allowed
    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(!ctx.responded);

    // Second request — blocked (429)
    var ctx2 = try api.Context.init(allocator, .GET, "/test");
    defer ctx2.deinit();
    try mw.func(&ctx2, next, mw.user_data);
    try std.testing.expect(ctx2.responded);
    try std.testing.expectEqual(@as(u16, 429), ctx2.status_code);
}

test "circuitBreak middleware passes on success" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    var cb = try CircutBreaker.init(allocator, "test", .{
        .failure_threshold = 3,
        .success_threshold = 2,
        .timeout_seconds = 1,
        .half_open_max_calls = 5,
    });
    defer cb.deinit();

    const mw = circuitBreak(&cb);
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(!ctx.responded);
}
