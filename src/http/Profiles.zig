//! One-click HTTP + resilience profiles.
//!
//! HTTP:
//!   var state = http.HttpProfileState.init(allocator);
//!   defer state.deinit(allocator);
//!   try http.applyHttpDefaults(&server, .{}, &state);
//!
//! Resilience (per-dependency holders — wire into ModuleRuntime / handlers):
//!   var res = try http.ResilienceProfileState.init(allocator, &.{
//!       .{ .name = "db", .max_qps = 200 },
//!       .{ .name = "payment", .max_qps = 50, .failure_threshold = 3 },
//!   });
//!   defer res.deinit();
//!   const cb = res.breaker("payment").?;

const std = @import("std");
const server_mod = @import("../api/Server.zig");
const mw = @import("../api/Middleware.zig");
const AccessLog = @import("AccessLog.zig");
const HttpMetrics = @import("HttpMetrics.zig");
const CircuitBreaker = @import("../resilience/CircuitBreaker.zig").CircuitBreaker;
const RateLimiter = @import("../resilience/RateLimiter.zig").RateLimiter;

pub const Server = server_mod.Server;

pub const ProfileConfig = struct {
    /// CORS + request-id + recover (panic → 500).
    security_basics: bool = true,
    access_log: bool = true,
    metrics: bool = true,
    /// Idempotency requires an IdempotencyStore — log reminder when true.
    idempotency: bool = false,
    /// Optional CORS allow_origin (default `*`). Kept alive via `HttpProfileState`.
    cors_origin: []const u8 = "*",
};

/// Holds middleware state allocated by `applyHttpDefaults`.
pub const HttpProfileState = struct {
    access_logger: ?AccessLog.AccessLogger = null,
    metrics_collector: ?HttpMetrics.HttpMetricsCollector = null,
    /// Backing storage for CORS `allow_origins` (must outlive Server).
    cors_origins: [1][]const u8 = .{""},

    pub fn init(allocator: std.mem.Allocator) HttpProfileState {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *HttpProfileState, allocator: std.mem.Allocator) void {
        if (self.access_logger) |*l| l.deinit();
        _ = allocator;
        self.* = undefined;
    }
};

/// Attach default security + observability middleware. Requires caller-owned `state`.
pub fn applyHttpDefaults(server: *Server, cfg: ProfileConfig, state: *HttpProfileState) !void {
    if (cfg.security_basics) {
        state.cors_origins[0] = cfg.cors_origin;
        try server.addMiddleware(mw.cors(.{ .allow_origins = &state.cors_origins }));
        try server.addMiddleware(mw.requestId());
        try server.addMiddleware(mw.recover());
    }

    if (cfg.access_log) {
        state.access_logger = AccessLog.AccessLogger.init(server.allocator, 1024);
        const logger = &state.access_logger.?;
        try server.addMiddleware(.{ .func = AccessLog.accessLogMiddleware(logger), .user_data = logger });
    }

    if (cfg.metrics) {
        state.metrics_collector = HttpMetrics.HttpMetricsCollector.init();
        const collector = &state.metrics_collector.?;
        try server.addMiddleware(metricsMiddleware(collector));
    }

    if (cfg.idempotency) {
        std.log.info("ProfileConfig.idempotency=true: attach http.idempotencyMiddleware(store) manually", .{});
    }
}

fn metricsMiddleware(collector: *HttpMetrics.HttpMetricsCollector) server_mod.Middleware {
    const S = struct {
        fn handler(ctx: *server_mod.Context, next: server_mod.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            const c: *HttpMetrics.HttpMetricsCollector = @ptrCast(@alignCast(user_data orelse return error.InternalError));
            const Time = @import("../core/Time.zig");
            const start = Time.monotonicNowSeconds();
            c.in_flight += 1;
            next(ctx) catch |err| {
                c.in_flight -= 1;
                const elapsed = Time.monotonicNowSeconds() - start;
                c.recordRequest(ctx.status_code, @floatFromInt(elapsed));
                return err;
            };
            c.in_flight -= 1;
            const elapsed = Time.monotonicNowSeconds() - start;
            c.recordRequest(if (ctx.responded) ctx.status_code else 200, @floatFromInt(elapsed));
        }
    };
    return .{ .func = S.handler, .user_data = @ptrCast(collector) };
}

// ── Resilience profile (per-dependency) ──

pub const ResilienceDep = struct {
    name: []const u8,
    max_qps: u32 = 100,
    failure_threshold: u32 = 5,
    success_threshold: u32 = 2,
    timeout_seconds: u64 = 30,
    half_open_max_calls: u32 = 3,
};

pub const ResilienceProfileState = struct {
    allocator: std.mem.Allocator,
    breakers: std.ArrayList(CircuitBreaker) = .empty,
    limiters: std.ArrayList(RateLimiter) = .empty,

    pub fn init(allocator: std.mem.Allocator, deps: []const ResilienceDep) !ResilienceProfileState {
        var self: ResilienceProfileState = .{ .allocator = allocator };
        errdefer self.deinit();
        for (deps) |d| {
            try self.breakers.append(allocator, try CircuitBreaker.init(allocator, d.name, .{
                .failure_threshold = d.failure_threshold,
                .success_threshold = d.success_threshold,
                .timeout_seconds = d.timeout_seconds,
                .half_open_max_calls = d.half_open_max_calls,
            }));
            try self.limiters.append(allocator, try RateLimiter.init(allocator, d.name, d.max_qps, d.max_qps));
        }
        return self;
    }

    pub fn deinit(self: *ResilienceProfileState) void {
        for (self.breakers.items) |*b| b.deinit();
        self.breakers.deinit(self.allocator);
        for (self.limiters.items) |*l| l.deinit();
        self.limiters.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn breaker(self: *ResilienceProfileState, name: []const u8) ?*CircuitBreaker {
        for (self.breakers.items) |*b| {
            if (std.mem.eql(u8, b.name, name)) return b;
        }
        return null;
    }

    pub fn limiter(self: *ResilienceProfileState, name: []const u8) ?*RateLimiter {
        for (self.limiters.items) |*l| {
            if (std.mem.eql(u8, l.name, name)) return l;
        }
        return null;
    }
};

/// Alias: create named CB + RL holders for Application bootstrap.
pub const applyResilienceDefaults = ResilienceProfileState.init;

test "applyHttpDefaults wires security + obs middleware" {
    const allocator = std.testing.allocator;
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    var state = HttpProfileState.init(allocator);
    defer state.deinit(allocator);

    try applyHttpDefaults(&server, .{ .security_basics = true, .access_log = true, .metrics = true }, &state);
    try std.testing.expect(server.global_middleware.items.len >= 5);
}

test "ResilienceProfileState creates named breakers" {
    const allocator = std.testing.allocator;
    var res = try ResilienceProfileState.init(allocator, &.{
        .{ .name = "db", .max_qps = 10 },
        .{ .name = "payment", .max_qps = 5, .failure_threshold = 2 },
    });
    defer res.deinit();

    try std.testing.expect(res.breaker("db") != null);
    try std.testing.expect(res.breaker("payment") != null);
    try std.testing.expect(res.limiter("db") != null);
    try std.testing.expect(res.breaker("missing") == null);
}
