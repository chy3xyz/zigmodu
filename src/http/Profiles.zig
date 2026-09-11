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
const PrometheusMetrics = @import("../metrics/PrometheusMetrics.zig").PrometheusMetrics;
const HealthEndpointMod = @import("../core/HealthEndpoint.zig");
const HealthEndpoint = HealthEndpointMod.HealthEndpoint;
const tracingMiddleware = @import("../api/middleware/Tracing.zig").tracing;
const dashboardRoutes = @import("Dashboard.zig").registerRoutes;

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
            c.beginRequest();
            next(ctx) catch |err| {
                c.endRequest(500, @floatFromInt(Time.monotonicNowSeconds() - start));
                return err;
            };
            c.endRequest(if (ctx.responded) ctx.status_code else 200, @floatFromInt(Time.monotonicNowSeconds() - start));
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

// ── Production profile (one-call hardening) ──

/// Golden-signal families shared by the production-profile request middleware,
/// keyed by route template. Owned by `ProductionProfileState`.
pub const HttpSignals = struct {
    total: *PrometheusMetrics.CounterFamily,
    c2xx: *PrometheusMetrics.CounterFamily,
    c3xx: *PrometheusMetrics.CounterFamily,
    c4xx: *PrometheusMetrics.CounterFamily,
    c5xx: *PrometheusMetrics.CounterFamily,
    latency: *PrometheusMetrics.HistogramFamily,
};

/// Latency buckets for `http_request_duration_milliseconds` (ms): p50-ish
/// through "this request is broken". Cardinality stays fixed so the series is
/// cheap to scrape.
pub const default_latency_buckets = [_]f64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 };

/// Everything a production server should have, in one call: connection
/// backpressure, request deadlines, security middleware, access log, tracing,
/// Prometheus `/metrics`, and liveness/readiness probes.
///
/// Must be called **before** any `server.addRoute` / `router.mount*`:
/// `Server.addRoute` snapshots the global middleware chain at registration
/// time, so middleware attached afterwards does not apply to those routes.
pub const ProductionConfig = struct {
    // Connection backpressure (see `Server.Config`).
    /// 0 = unlimited.
    max_connections: usize = 0,
    over_limit_response: Server.OverLimitResponse = .close,
    /// Request-line + header deadline (slowloris). 0 disables.
    header_timeout_ms: u32 = 10_000,
    /// Overrides `Server.request_timeout_ms` when set (handler-stage budget).
    request_timeout_ms: ?u32 = null,

    /// Base middleware switches (CORS / request-id / recover / access log / metrics-in-memory).
    http: ProfileConfig = .{},

    /// `GET /metrics` in Prometheus text format, plus golden-signal counters.
    prometheus: bool = true,
    metrics_path: []const u8 = "/metrics",
    /// Label used for the per-route split of the golden signals.
    route_label: []const u8 = "route",
    /// Hard cap on distinct label values; the rest collapse into `__other__`.
    max_route_series: usize = 64,

    /// Liveness + readiness probes (JSON).
    health: bool = true,
    liveness_path: []const u8 = "health/live",
    readiness_path: []const u8 = "health/ready",

    /// Human dashboard routes (`/`, `/dashboard`, `/api/dashboard/*`).
    dashboard: bool = false,

    /// `x-trace-id` injection + latency logging.
    tracing: bool = true,
};

/// Owns everything `productionProfile` allocates. The caller keeps it on the
/// stack; it must outlive the Server (CORS backing storage, probe handlers).
pub const ProductionProfileState = struct {
    http_state: HttpProfileState = .{},
    prometheus: ?PrometheusMetrics = null,
    signals: ?*HttpSignals = null,
    health: ?HealthEndpoint = null,
    /// Backing storage for the readiness handler's endpoint pointer.
    health_ptr: ?*HealthEndpoint = null,

    pub fn init(allocator: std.mem.Allocator) ProductionProfileState {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *ProductionProfileState, allocator: std.mem.Allocator) void {
        if (self.signals) |sg| allocator.destroy(sg);
        if (self.prometheus) |*p| p.deinit();
        if (self.health) |*h| h.deinit();
        self.http_state.deinit(allocator);
        self.* = undefined;
    }
};

pub fn productionProfile(server: *Server, cfg: ProductionConfig, state: *ProductionProfileState) !void {
    // 1. Connection-level backpressure + deadlines.
    server.max_connections = cfg.max_connections;
    server.over_limit_response = cfg.over_limit_response;
    server.header_timeout_ms = cfg.header_timeout_ms;
    if (cfg.request_timeout_ms) |t| server.request_timeout_ms = t;
    if (cfg.max_connections == 0) {
        std.log.warn("[profile] productionProfile: max_connections=0 (unlimited) — set it to cap accept floods", .{});
    }

    // Wildcard CORS is the default of the low-level middleware; in a
    // production profile it is almost always a mistake (any origin may read
    // authenticated responses), so say so loudly instead of silently shipping it.
    if (cfg.http.security_basics and std.mem.eql(u8, cfg.http.cors_origin, "*")) {
        std.log.warn("[profile] CORS allow_origins=\"*\": set ProductionConfig.http.cors_origin to your real origin", .{});
    }

    // 2. Security + observability middleware (CORS, request-id, recover, access log, counters).
    try applyHttpDefaults(server, cfg.http, &state.http_state);
    try server.addMiddleware(mw.securityHeaders(null));
    if (cfg.tracing) try server.addMiddleware(tracingMiddleware());

    // 3. Prometheus exposition — golden signals, labeled by route template.
    //
    // The label is the *matched pattern* (`/orders/{id}`), never the raw path:
    // ids in labels would blow the series budget up. Cardinality is capped and
    // spills into `route="__other__"` — see CounterFamily.
    if (cfg.prometheus) {
        state.prometheus = PrometheusMetrics.init(server.allocator);
        const m = &state.prometheus.?;
        const route_label = cfg.route_label;
        const total = try m.createCounterFamily("http_requests_total", "Total HTTP requests", route_label, cfg.max_route_series, server.io);
        const c2xx = try m.createCounterFamily("http_responses_2xx_total", "HTTP responses with a 2xx status", route_label, cfg.max_route_series, server.io);
        const c3xx = try m.createCounterFamily("http_responses_3xx_total", "HTTP responses with a 3xx status", route_label, cfg.max_route_series, server.io);
        const c4xx = try m.createCounterFamily("http_responses_4xx_total", "HTTP responses with a 4xx status", route_label, cfg.max_route_series, server.io);
        const c5xx = try m.createCounterFamily("http_responses_5xx_total", "HTTP responses with a 5xx status (5xx rate = error budget burn)", route_label, cfg.max_route_series, server.io);
        const latency = try m.createHistogramFamily(
            "http_request_duration_milliseconds",
            "HTTP request duration in milliseconds",
            route_label,
            cfg.max_route_series,
            &default_latency_buckets,
            server.io,
        );
        const signals = try server.allocator.create(HttpSignals);
        signals.* = .{
            .total = total,
            .c2xx = c2xx,
            .c3xx = c3xx,
            .c4xx = c4xx,
            .c5xx = c5xx,
            .latency = latency,
        };
        state.signals = signals;
        try server.addMiddleware(.{
            .func = struct {
                fn handler(ctx: *server_mod.Context, next: server_mod.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                    const s: *HttpSignals = @ptrCast(@alignCast(user_data orelse return error.NoMetrics));
                    const Time = @import("../core/Time.zig");
                    // Unmatched route (`404`) and skipped dispatch collapse into
                    // one series. ComptimeRouter stores patterns without a
                    // leading slash (`api/v1/tenants`) while server routes keep
                    // it (`/metrics`) — normalize, or the same endpoint shows up
                    // as two series.
                    var route_buf: [192]u8 = undefined;
                    const raw_route = ctx.route_template orelse "__unmatched__";
                    const route: []const u8 = if (raw_route.len > 0 and raw_route[0] != '/' and !std.mem.startsWith(u8, raw_route, "__"))
                        std.fmt.bufPrint(&route_buf, "/{s}", .{raw_route}) catch raw_route
                    else
                        raw_route;
                    const start = Time.monotonicNowMilliseconds();
                    s.total.get(route).inc();
                    next(ctx) catch |err| {
                        const elapsed: f64 = @floatFromInt(Time.monotonicNowMilliseconds() - start);
                        s.latency.get(route).observe(elapsed);
                        s.c5xx.get(route).inc();
                        return err;
                    };
                    const status = if (ctx.responded) ctx.status_code else 200;
                    const elapsed: f64 = @floatFromInt(Time.monotonicNowMilliseconds() - start);
                    s.latency.get(route).observe(elapsed);
                    switch (status / 100) {
                        2 => s.c2xx.get(route).inc(),
                        3 => s.c3xx.get(route).inc(),
                        4 => s.c4xx.get(route).inc(),
                        5 => s.c5xx.get(route).inc(),
                        else => {},
                    }
                }
            }.handler,
            .user_data = @ptrCast(signals),
        });
        try m.registerMetricsRoutePath(server, cfg.metrics_path);
    }

    // 4. K8s-style probes.
    if (cfg.health) {
        state.health = HealthEndpoint.init(server.allocator);
        state.health_ptr = &state.health.?;
        try state.health.?.registerCheck("process", "process liveness", HealthEndpointMod.LivenessProbe.check);
        try server.addRoute(.{
            .method = .GET,
            .path = cfg.liveness_path,
            .handler = HealthEndpointMod.handleLiveness,
        });
        try server.addRoute(.{
            .method = .GET,
            .path = cfg.readiness_path,
            .handler = HealthEndpointMod.handleReadiness(state.health_ptr.?),
        });
    }

    // 5. Optional dashboard.
    if (cfg.dashboard) {
        var dash_group = server.group("");
        try dashboardRoutes(&dash_group);
    }
}

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

test "productionProfile applies backpressure, metrics and probes" {
    const allocator = std.testing.allocator;
    const Testkit = @import("Testkit.zig");

    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    var state = ProductionProfileState.init(allocator);
    defer state.deinit(allocator);

    try productionProfile(&server, .{
        .max_connections = 512,
        .over_limit_response = .unavailable,
        .header_timeout_ms = 4000,
        .request_timeout_ms = 15_000,
        .dashboard = true,
    }, &state);

    // Connection backpressure lands on the live Server fields (read by the
    // accept loop), not just on a Config that was already consumed.
    try std.testing.expectEqual(@as(usize, 512), server.max_connections);
    try std.testing.expectEqual(Server.OverLimitResponse.unavailable, server.over_limit_response);
    try std.testing.expectEqual(@as(u32, 4000), server.header_timeout_ms);
    try std.testing.expectEqual(@as(u32, 15_000), server.request_timeout_ms);

    // Middleware: security basics + security headers + tracing + request counter.
    try std.testing.expect(server.global_middleware.items.len >= 7);

    // Exercise a route so the families have a series to render (status and
    // latency are recorded after the handler returns).
    {
        var hit = try Testkit.dispatch(&server, .GET, "/health/live", null);
        defer hit.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), hit.status_code);
    }

    // Prometheus exposition is live, and the golden signals are split by the
    // matched route *template* — not the raw path.
    {
        var resp = try Testkit.dispatch(&server, .GET, "/metrics", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        inline for (.{
            "http_requests_total",
            "http_responses_2xx_total",
            "http_responses_4xx_total",
            "http_responses_5xx_total",
            "http_request_duration_milliseconds_bucket",
        }) |metric| {
            try std.testing.expect(std.mem.indexOf(u8, resp.body, metric) != null);
        }
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "http_requests_total{route=\"/health/live\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "http_request_duration_milliseconds_count{route=\"/health/live\"}") != null);
    }

    {
        var resp = try Testkit.dispatch(&server, .GET, "/health/live", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "UP") != null);
    }

    {
        var resp = try Testkit.dispatch(&server, .GET, "/health/ready", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "UP") != null);
    }

    {
        var resp = try Testkit.dispatch(&server, .GET, "/api/dashboard/stats", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    }
}

test "productionProfile honours custom endpoint paths" {
    const allocator = std.testing.allocator;
    const Testkit = @import("Testkit.zig");

    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    var state = ProductionProfileState.init(allocator);
    defer state.deinit(allocator);

    try productionProfile(&server, .{
        .metrics_path = "internal/metrics",
        .liveness_path = "livez",
        .readiness_path = "readyz",
        .dashboard = false,
    }, &state);

    inline for (.{ "/internal/metrics", "/livez", "/readyz" }) |p| {
        var resp = try Testkit.dispatch(&server, .GET, p, null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    }
}
