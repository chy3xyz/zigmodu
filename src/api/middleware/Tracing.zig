//! Production-grade HTTP middlewares — tracing, rate limiting.
//! Plugs into `zigmodu.http.Server.addMiddleware(...)`.
//!
//! Usage:
//!   server.addMiddleware(zigmodu.http.tracingMiddleware());
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
                // Propagate an inbound id when the caller supplied one (an
                // upstream service, or a client correlating its own traces),
                // otherwise mint one. Bounded on purpose: the value ends up in
                // an attribute, so an unbounded header is a memory lever.
                const inbound: ?[]const u8 = blk: {
                    const raw = ctx.header("x-trace-id") orelse break :blk null;
                    if (raw.len == 0 or raw.len > 128) break :blk null;
                    for (raw) |ch| {
                        if (ch < 0x21 or ch > 0x7e) break :blk null;
                    }
                    break :blk raw;
                };

                const trace_id = if (inbound) |id|
                    try ctx.allocator.dupe(u8, id)
                else blk: {
                    const now_ns: u64 = @intCast(Time.monotonicNow());
                    const counter = trace_id_counter.fetchAdd(1, .monotonic);
                    break :blk try std.fmt.allocPrint(ctx.allocator, "{x:016}-{x:016}", .{ now_ns, counter });
                };
                defer ctx.allocator.free(trace_id);

                // Hand it to the request, not just to the response header: this
                // is what lets a handler do `ctx.logScope("m")` and get every
                // line tagged, and what makes the timing line below correlate
                // with the handler's own lines.
                try ctx.setTraceId(trace_id);
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
                // Propagate incoming trace-id if present. `header()` is
                // case-insensitive: request header keys are lowercased at
                // parse time, so `get("X-Trace-Id")` would never match.
                if (ctx.header(hdr)) |incoming_trace| {
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
        .user_data = @ptrCast(@constCast(header_name.ptr)),
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
    const S = struct {
        stored_registry: *RateLimiterRegistry,
        stored_extractor: *const fn (*api.Context) []const u8,
    };
    const stored = std.heap.page_allocator.create(S) catch @panic("tracing middleware setup: out of memory");
    stored.* = .{ .stored_registry = registry, .stored_extractor = key_extractor };

    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const s: *const S = @ptrCast(@alignCast(user_data.?));
                const client_key = s.stored_extractor(ctx);
                const lim = try s.stored_registry.getOrCreateForClient(client_key, 100, 10);
                if (!lim.tryAcquire()) {
                    try ctx.sendErrorResponse(429, 429, "Too Many Requests");
                    return;
                }
                try next(ctx);
            }
        }.mw,
        .user_data = stored,
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
                        fn fail() anyerror!void {
                            return error.BreakerFail;
                        }
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

test "tracing() hands the trace id to the request and reuses a sane inbound one" {
    const allocator = std.testing.allocator;

    const Next = struct {
        var seen: ?[]const u8 = null;
        fn n(c: *api.Context) anyerror!void {
            seen = c.traceId();
        }
    };
    const next = Next.n;

    // No inbound id: one is minted, the handler can read it, and the response
    // echoes it.
    {
        Next.seen = null;
        var ctx = try api.Context.init(allocator, .GET, "/orders");
        defer ctx.deinit();
        const mw = tracing();
        try mw.func(&ctx, next, mw.user_data);
        try std.testing.expect(ctx.traceId() != null);
        try std.testing.expectEqualStrings(ctx.traceId().?, Next.seen.?);
        try std.testing.expectEqualStrings(ctx.traceId().?, ctx.response_headers.get("x-trace-id").?);
    }

    // A sane inbound id is propagated instead of replaced — that is what makes
    // the id useful across two services.
    {
        Next.seen = null;
        var ctx = try api.Context.init(allocator, .GET, "/orders");
        defer ctx.deinit();
        try ctx.headers.put(try allocator.dupe(u8, "x-trace-id"), try allocator.dupe(u8, "abc-123"));
        const mw = tracing();
        try mw.func(&ctx, next, mw.user_data);
        try std.testing.expectEqualStrings("abc-123", ctx.traceId().?);
    }

    // An oversized id is ignored rather than copied into an attribute — the
    // header is attacker-controlled.
    {
        Next.seen = null;
        var ctx = try api.Context.init(allocator, .GET, "/orders");
        defer ctx.deinit();
        var junk_buf: [200]u8 = undefined;
        @memset(&junk_buf, 'x');
        const junk: []const u8 = &junk_buf;
        try ctx.headers.put(try allocator.dupe(u8, "x-trace-id"), try allocator.dupe(u8, junk));
        const mw = tracing();
        try mw.func(&ctx, next, mw.user_data);
        try std.testing.expect(ctx.traceId() != null);
        try std.testing.expect(!std.mem.eql(u8, junk, ctx.traceId().?));
    }
}
