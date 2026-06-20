//! HTTP domain: server, middleware, client, OpenAPI, utilities.
//! Import directly: `const http = @import("zigmodu").http;`
//!
//! Canonical types (use these):
//!   http.Server, http.Context, http.RouteGroup, http.Middleware, http.Route
//!
//! Deprecated: `http.http_server` — same module as above; removed from root in v0.14.0.
//!   Prefer `http.Server` over `http.http_server.Server` or `zigmodu.http_server.Server`.

const std = @import("std");

const server_mod = @import("api/Server.zig");
/// DEPRECATED v0.14.0: use `Server`, `Context`, etc. exported below.
pub const http_server = server_mod;
pub const Server = server_mod.Server;
pub const Context = server_mod.Context;
pub const RouteGroup = server_mod.RouteGroup;
pub const Route = server_mod.Route;
pub const Middleware = server_mod.Middleware;
pub const HandlerFn = server_mod.HandlerFn;
pub const Method = server_mod.Method;
pub const RouteInfo = server_mod.RouteInfo;
pub const http_middleware = @import("api/Middleware.zig");
pub const tracing_middleware = @import("api/middleware/Tracing.zig");
pub const validateRequest = @import("api/middleware/Validation.zig").validateRequest;
pub const validationMiddleware = @import("api/middleware/Validation.zig").validationMiddleware;

pub const HttpClient = @import("http/HttpClient.zig").HttpClient;
pub const OpenApiGenerator = @import("http/OpenApi.zig").OpenApiGenerator;
pub const ApiEndpoint = @import("http/OpenApi.zig").ApiEndpoint;
pub const ApiSchema = @import("http/OpenApi.zig").ApiSchema;
pub const HttpMethod = @import("http/OpenApi.zig").HttpMethod;
pub const ProblemDetails = @import("http/ProblemDetails.zig").ProblemDetails;
pub const ValidationProblem = @import("http/ProblemDetails.zig").ValidationProblem;
pub const IdempotencyStore = @import("http/Idempotency.zig").IdempotencyStore;
pub const idempotencyMiddleware = @import("http/Idempotency.zig").idempotencyMiddleware;
pub const ApiVersion = @import("http/ApiVersioning.zig").ApiVersion;
pub const ApiVersionExtractor = @import("http/ApiVersioning.zig").ApiVersionExtractor;
pub const ApiVersionRouter = @import("http/ApiVersioning.zig").ApiVersionRouter;
pub const apiVersionMiddleware = @import("http/ApiVersioning.zig").apiVersionMiddleware;
pub const SseWriter = @import("http/Sse.zig").SseWriter;
pub const Dashboard = @import("http/Dashboard.zig");
pub const AccessLogger = @import("http/AccessLog.zig").AccessLogger;
pub const accessLogMiddleware = @import("http/AccessLog.zig").accessLogMiddleware;
pub const HttpMetricsCollector = @import("http/HttpMetrics.zig").HttpMetricsCollector;
pub const httpMetricsMiddleware = @import("http/HttpMetrics.zig").httpMetricsMiddleware;
pub const OpenApiVersion = @import("http/OpenApi.zig").OpenApiVersion;
pub const ParamLocation = @import("http/OpenApi.zig").ParamLocation;
pub const ApiParam = @import("http/OpenApi.zig").ApiParam;
pub const RequestBody = @import("http/OpenApi.zig").RequestBody;
pub const ApiResponse = @import("http/OpenApi.zig").ApiResponse;
pub const SchemaProperty = @import("http/OpenApi.zig").SchemaProperty;
pub const IdempotencyEntry = @import("http/Idempotency.zig").IdempotencyEntry;
pub const IdempotencyConfig = @import("http/Idempotency.zig").IdempotencyConfig;
pub const SystemInfo = @import("http/Dashboard.zig").SystemInfo;
pub const dashboardRoutes = @import("http/Dashboard.zig").registerRoutes;
pub const sendProblem = @import("http/ProblemDetails.zig").sendProblem;
pub const sendProblemWithType = @import("http/ProblemDetails.zig").sendProblemWithType;
pub const sendValidationProblem = @import("http/ProblemDetails.zig").sendValidationProblem;
pub const wrapContextWithIdempotency = @import("http/Idempotency.zig").wrapContextWithIdempotency;
pub const recordIdempotencyResponse = @import("http/Idempotency.zig").recordIdempotencyResponse;

/// Request utility helpers.
pub const RequestUtil = struct {
    /// Get client real IP (X-Real-IP > X-Forwarded-For > remote).
    pub fn getRealIp(ctx: *Context) []const u8 {
        if (ctx.getAttr("X-Real-IP")) |ip| return ip;
        if (ctx.getAttr("X-Forwarded-For")) |fwd| {
            if (std.mem.indexOf(u8, fwd, ",")) |pos| return std.mem.trim(u8, fwd[0..pos], &std.ascii.whitespace);
            return fwd;
        }
        return "unknown";
    }
    /// Check if AJAX/XMLHttpRequest.
    pub fn isAjax(ctx: *Context) bool {
        if (ctx.getAttr("X-Requested-With")) |v| return std.mem.eql(u8, v, "XMLHttpRequest");
        return false;
    }
};

/// Unified response renderer (zfinal-style).
pub const RenderExt = struct {
    /// {"success":true,"data":<value>}
    pub fn success(ctx: *Context, data: anytype) !void {
        try ctx.jsonStruct(200, .{ .success = true, .data = data });
    }
    /// {"success":false,"err":"<message>"}
    pub fn err(ctx: *Context, message: []const u8) !void {
        try ctx.jsonStruct(200, .{ .success = false, .err = message });
    }
    /// {"success":true,"data":{"list":<list>,"total":N,"page":P,"pageSize":S,"totalPages":T}}
    pub fn page(ctx: *Context, list: anytype, total: usize, page_num: usize, page_size: usize) !void {
        try ctx.jsonStruct(200, .{ .success = true, .data = .{
            .list = list, .total = total, .page = page_num, .pageSize = page_size,
            .totalPages = (total + page_size - 1) / page_size,
        } });
    }
};
