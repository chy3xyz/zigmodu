//! Fault injection — what actually happens to HTTP traffic while a dependency
//! is down. The resilience components have unit tests; these run the full
//! chain (route → handler → breaker/limiter → flapping downstream) so the
//! *behaviour* is pinned, not just the state machine:
//!
//!   outage → breaker opens → traffic is shed without hammering the dependency
//!   → half-open probe → recovery → normal traffic resumes.
//!
//! Copy the shape into an app test: swap `downstream()` for a real client call.

const std = @import("std");
const http = @import("../http.zig");
const CircuitBreaker = @import("../resilience/CircuitBreaker.zig").CircuitBreaker;
const RateLimiter = @import("../resilience/RateLimiter.zig").RateLimiter;

const Fault = struct {
    var breaker: CircuitBreaker = undefined;
    var limiter: RateLimiter = undefined;
    var downstream_healthy: bool = false;
    var downstream_calls: usize = 0;

    fn downstream() anyerror!void {
        downstream_calls += 1;
        if (!downstream_healthy) return error.DownstreamUnavailable;
    }

    /// A handler that refuses to call a dependency the breaker has opened.
    fn handler(ctx: *http.Context) anyerror!void {
        switch (breaker.call(&downstream)) {
            .success => try ctx.jsonStruct(200, .{ .ok = true }),
            .failure => try ctx.jsonStruct(502, .{ .message = "bad_gateway" }),
            .circuit_open => try ctx.jsonStruct(503, .{ .message = "circuit_open" }),
        }
    }

    fn limited(ctx: *http.Context) anyerror!void {
        if (!limiter.tryAcquire()) {
            try ctx.jsonStruct(429, .{ .message = "too_many_requests" });
            return;
        }
        try ctx.jsonStruct(200, .{ .ok = true });
    }
};

test "fault injection: outage opens the breaker, recovery closes it" {
    const allocator = std.testing.allocator;
    const Testkit = @import("../http/Testkit.zig");

    Fault.downstream_healthy = false;
    Fault.downstream_calls = 0;
    Fault.breaker = try CircuitBreaker.init(allocator, "downstream", .{
        .failure_threshold = 2,
        .success_threshold = 1,
        .timeout_seconds = 60, // stay OPEN: the point of phase 1
        .half_open_max_calls = 1,
    });
    defer Fault.breaker.deinit();

    var server = http.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var group = server.group("");
    try group.get("proxy", Fault.handler, null);

    // ── Phase 1: dependency down ────────────────────────────────────────────
    inline for (0..2) |_| {
        var resp = try Testkit.dispatch(&server, .GET, "/proxy", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 502), resp.status_code);
    }
    try std.testing.expectEqual(CircuitBreaker.State.OPEN, Fault.breaker.getState());

    const calls_when_open = Fault.downstream_calls;
    inline for (0..3) |_| {
        var resp = try Testkit.dispatch(&server, .GET, "/proxy", null);
        defer resp.deinit(allocator);
        // Shed, not forwarded: failing fast is the whole promise.
        try std.testing.expectEqual(@as(u16, 503), resp.status_code);
    }
    try std.testing.expectEqual(calls_when_open, Fault.downstream_calls);

    // ── Phase 2: dependency recovers ────────────────────────────────────────
    Fault.downstream_healthy = true;
    // The rollout window elapses (60s of wall time is not something a test
    // should wait for, so shorten it and let the state machine notice).
    Fault.breaker.config.timeout_seconds = 0;

    {
        var probe = try Testkit.dispatch(&server, .GET, "/proxy", null);
        defer probe.deinit(allocator);
        // Half-open admits one probe; it succeeds and closes the circuit.
        try std.testing.expectEqual(@as(u16, 200), probe.status_code);
    }
    try std.testing.expectEqual(CircuitBreaker.State.CLOSED, Fault.breaker.getState());

    {
        var resp = try Testkit.dispatch(&server, .GET, "/proxy", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    }
    try std.testing.expectEqual(CircuitBreaker.State.CLOSED, Fault.breaker.getState());
}

test "fault injection: rate limiter sheds excess load with 429" {
    const allocator = std.testing.allocator;
    const Testkit = @import("../http/Testkit.zig");

    // Two tokens, no refill inside the test window. The handler reads the
    // file-scope holder, so initialize that one.
    Fault.limiter = try RateLimiter.init(allocator, "api", 2, 0);
    defer Fault.limiter.deinit();

    var server = http.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var group = server.group("");
    try group.get("limited", Fault.limited, null);

    inline for (0..2) |_| {
        var resp = try Testkit.dispatch(&server, .GET, "/limited", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    }
    inline for (0..3) |_| {
        var resp = try Testkit.dispatch(&server, .GET, "/limited", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 429), resp.status_code);
    }

    // Exhausted buckets recover once tokens are refilled (operator action, or
    // the refill rate doing its job over time).
    Fault.limiter.reset();
    var resp = try Testkit.dispatch(&server, .GET, "/limited", null);
    defer resp.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
}
