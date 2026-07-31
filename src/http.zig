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

/// Comptime / generic route table (see `docs/ROUTE_TABLE.md`).
pub const comptime_router = @import("api/ComptimeRouter.zig");
pub const Auth = comptime_router.Auth;
pub const RouteMeta = comptime_router.RouteMeta;
pub const RouteSpec = comptime_router.RouteSpec;
pub const WsSpec = comptime_router.WsSpec;
pub const SseSpec = comptime_router.SseSpec;
pub const WsConnectFn = server_mod.WsConnectFn;
pub const WsMessageFn = server_mod.WsMessageFn;
pub const WsCloseFn = server_mod.WsCloseFn;
pub const WsFrameKind = server_mod.WsFrameKind;
pub const WsFramer = @import("im/WsFramer.zig").WsFramer;
pub const TypedHandler = comptime_router.TypedHandler;
pub const wrap = comptime_router.wrap;
pub const assertNoDupes = comptime_router.assertNoDupes;
pub const Router = comptime_router.Router;
pub const Scoped = comptime_router.Scoped;
pub const RouteCatalog = comptime_router.RouteCatalog;
pub const CatalogEntry = comptime_router.CatalogEntry;
pub const CatalogSlot = comptime_router.CatalogSlot;
pub const pathHasSkipPrefix = comptime_router.pathHasSkipPrefix;
pub const openApiFromCatalog = comptime_router.openApiFromCatalog;
pub const OpenApiFromCatalogConfig = comptime_router.OpenApiFromCatalogConfig;

pub const http_middleware = @import("api/Middleware.zig");
pub const jwtAuthFromCatalog = http_middleware.jwtAuthFromCatalog;
pub const jwtAuthFromCatalogWithPermissions = http_middleware.jwtAuthFromCatalogWithPermissions;
pub const catalogLoaderFromTable = http_middleware.catalogLoaderFromTable;
pub const CatalogPermissionLoader = http_middleware.CatalogPermissionLoader;
pub const CatalogPermLoadInput = http_middleware.CatalogPermLoadInput;
pub const moduleGate = http_middleware.moduleGate;
pub const permissionGate = http_middleware.permissionGate;
pub const permissionGateWith = http_middleware.permissionGateWith;
pub const PermissionGateConfig = http_middleware.PermissionGateConfig;
pub const PermissionMode = http_middleware.PermissionMode;
pub const permissionMatchesRoles = http_middleware.permissionMatchesRoles;
pub const permissionMatchesAuthInfo = http_middleware.permissionMatchesAuthInfo;
pub const JwtFromCatalogConfig = http_middleware.JwtFromCatalogConfig;
pub const ModuleGateConfig = http_middleware.ModuleGateConfig;
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
pub const Http2 = @import("http/Http2.zig");
pub const Http2Server = @import("http/Http2Server.zig");
pub const Http2Tls = @import("http/Http2Tls.zig");
pub const Hpack = @import("http/Hpack.zig");
pub const ApiVersion = @import("http/ApiVersioning.zig").ApiVersion;
pub const ApiVersionExtractor = @import("http/ApiVersioning.zig").ApiVersionExtractor;
pub const ApiVersionRouter = @import("http/ApiVersioning.zig").ApiVersionRouter;
pub const apiVersionMiddleware = @import("http/ApiVersioning.zig").apiVersionMiddleware;
pub const SseWriter = @import("http/Sse.zig").SseWriter;
/// Alias for SSE streaming handlers.
pub const Sse = SseWriter;
pub const SseRecorder = @import("http/Sse.zig").SseRecorder;
pub const lastEventId = @import("http/Sse.zig").lastEventId;

/// Begin an SSE response (`Content-Type: text/event-stream`).
/// Sets `ctx.responded` and `ctx.streaming` so Server skips buffered `writeResponse`.
/// Requires live `ctx.stream` + `ctx.io`.
pub fn sse(ctx: *Context) !SseWriter {
    return SseWriter.init(ctx);
}

pub const Extract = @import("api/Extract.zig");
pub const extractQuery = Extract.extractQuery;
pub const extractPath = Extract.extractPath;
pub const extractJson = Extract.extractJson;
pub const extractJsonValidated = Extract.extractJsonValidated;
pub const openApiParamsFromStruct = Extract.openApiParamsFromStruct;
pub const respondProblem = Extract.respondProblem;
pub const respondErr = Extract.respondErr;
pub const setErrorMap = Extract.setErrorMap;
pub const clearErrorMap = Extract.clearErrorMap;
pub const ErrorMapping = Extract.ErrorMapping;
pub const FieldRules = Extract.FieldRules;

pub const Testkit = @import("http/Testkit.zig");
pub const Profiles = @import("http/Profiles.zig");
pub const ProfileConfig = Profiles.ProfileConfig;
pub const HttpProfileState = Profiles.HttpProfileState;
pub const applyHttpDefaults = Profiles.applyHttpDefaults;
pub const ResilienceDep = Profiles.ResilienceDep;
pub const ResilienceProfileState = Profiles.ResilienceProfileState;
pub const applyResilienceDefaults = Profiles.applyResilienceDefaults;

pub const Lifecycle = @import("http/Lifecycle.zig");
pub const ShutdownChecklist = Lifecycle.ShutdownChecklist;
pub const requireEnv = Lifecycle.requireEnv;

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
            .list = list,
            .total = total,
            .page = page_num,
            .pageSize = page_size,
            .totalPages = (total + page_size - 1) / page_size,
        } });
    }
};
