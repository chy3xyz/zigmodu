//! HTTP domain: server, middleware, client, OpenAPI, utilities.
//! Import directly: `const http = @import("zigmodu").http;`
//!
//! Top-level aliases for common types:
//!   http.Server, http.Context, http.RouteGroup, http.Middleware

pub const http_server = @import("api/Server.zig");
pub const Server = @import("api/Server.zig").Server;
pub const Context = @import("api/Server.zig").Context;
pub const RouteGroup = @import("api/Server.zig").RouteGroup;
pub const Route = @import("api/Server.zig").Route;
pub const Middleware = @import("api/Server.zig").Middleware;
pub const HandlerFn = @import("api/Server.zig").HandlerFn;
pub const Method = @import("api/Server.zig").Method;
pub const RouteInfo = @import("api/Server.zig").RouteInfo;
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

/// Unified response renderer (zfinal-style).
pub const RenderExt = struct {
    /// {"success":true,"data":<value>}
    pub fn success(ctx: *http_server.Context, data: anytype) !void {
        try ctx.jsonStruct(200, .{ .success = true, .data = data });
    }
    /// {"success":false,"err":"<message>"}
    pub fn err(ctx: *http_server.Context, message: []const u8) !void {
        try ctx.jsonStruct(200, .{ .success = false, .err = message });
    }
    /// {"success":true,"data":{"list":<list>,"total":N,"page":P,"pageSize":S,"totalPages":T}}
    pub fn page(ctx: *http_server.Context, list: anytype, total: usize, page_num: usize, page_size: usize) !void {
        try ctx.jsonStruct(200, .{ .success = true, .data = .{
            .list = list, .total = total, .page = page_num, .pageSize = page_size,
            .totalPages = (total + page_size - 1) / page_size,
        } });
    }
};
