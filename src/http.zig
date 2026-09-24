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
/// The HTTP server: routing, middleware chain, listener, graceful shutdown.
pub const Server = server_mod.Server;
/// Per-request handle: params, headers, body, response writers, attrs.
pub const Context = server_mod.Context;
/// Legacy route registration with per-group middleware (prefer ComptimeRouter).
pub const RouteGroup = server_mod.RouteGroup;
/// One registered route (method, path, handler, middleware).
pub const Route = server_mod.Route;
/// Middleware entry: a function plus optional `user_data` passed to it.
pub const Middleware = server_mod.Middleware;
/// Handler signature: `fn (*Context) anyerror!void`.
pub const HandlerFn = server_mod.HandlerFn;
/// HTTP method enum (GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS).
pub const Method = server_mod.Method;
/// Read-only description of a registered route (for dashboards, OpenAPI).
pub const RouteInfo = server_mod.RouteInfo;
/// Typed request identity + typed Context getters (M5/M11).
pub const Identity = server_mod.Identity;
/// Response envelope dialect for `ctx.ok/fail/unauth/paginated` (M6).
pub const EnvelopeDialect = server_mod.EnvelopeDialect;

/// Comptime / generic route table (see `docs/ROUTE_TABLE.md`).
pub const comptime_router = @import("api/ComptimeRouter.zig");
/// Route auth requirement: inherit / public / optional / jwt.
pub const Auth = comptime_router.Auth;
/// Per-route metadata: auth, permission, roles, OpenAPI params.
pub const RouteMeta = comptime_router.RouteMeta;
/// One route in a `routes` table: method, path, handler, meta.
pub const RouteSpec = comptime_router.RouteSpec;
/// One WebSocket route: path plus connect/message/close callbacks.
pub const WsSpec = comptime_router.WsSpec;
/// One SSE route: path plus a handler that streams via `http.sse`.
pub const SseSpec = comptime_router.SseSpec;
/// WebSocket connect callback — returns the per-session state pointer.
pub const WsConnectFn = server_mod.WsConnectFn;
/// WebSocket message callback; receives text and binary frames alike.
pub const WsMessageFn = server_mod.WsMessageFn;
/// WebSocket close callback (per-session cleanup).
pub const WsCloseFn = server_mod.WsCloseFn;
/// Frame kind handed to `on_message`: text (0x1) or binary (0x2).
pub const WsFrameKind = server_mod.WsFrameKind;
/// Frame writer: `writeText`/`writeBinary`, plus `isWritable()` for slow peers.
pub const WsFramer = @import("im/WsFramer.zig").WsFramer;
/// Comptime-typed handler: `fn (ctx, *State)` with a known state type.
pub const TypedHandler = comptime_router.TypedHandler;
/// Adapts a typed handler into a plain `HandlerFn` bound to `State`.
pub const wrap = comptime_router.wrap;
/// Compile-time check that no two routes share a method + path.
pub const assertNoDupes = comptime_router.assertNoDupes;
/// The comptime router: `Router(State)` with `.scope.mountAll(...)`.
pub const Router = comptime_router.Router;
/// A router scope: shared prefix, middleware stack, mounted modules.
pub const Scoped = comptime_router.Scoped;
/// Resolved route table produced by `router.finish()`.
pub const RouteCatalog = comptime_router.RouteCatalog;
/// One catalog entry: method, path template, meta.
pub const CatalogEntry = comptime_router.CatalogEntry;
/// Shared slot holding the finished catalog for auth middleware and audits.
pub const CatalogSlot = comptime_router.CatalogSlot;
/// True when `path` starts with one of the skip prefixes.
pub const pathHasSkipPrefix = comptime_router.pathHasSkipPrefix;
/// Generates an OpenAPI document from the route catalog.
pub const openApiFromCatalog = comptime_router.openApiFromCatalog;
/// OpenAPI generation options (title, version, servers).
pub const OpenApiFromCatalogConfig = comptime_router.OpenApiFromCatalogConfig;
/// Serves the bundled Swagger UI for a spec URL.
pub const swaggerUiHandler = comptime_router.swaggerUiHandler;
/// Serves the bundled Scalar UI for a spec URL.
pub const scalarUiHandler = comptime_router.scalarUiHandler;
/// Ready-made routes for the spec document plus a UI handler.
pub const openApiRoutes = comptime_router.openApiRoutes;
/// Binds a plain `HandlerFn` to `State` as a `TypedHandler` (inverse of `wrap`).
pub const wrapHandler = comptime_router.wrapHandler;

/// Middleware barrel: auth, gates, extractors, error renderers.
pub const http_middleware = @import("api/Middleware.zig");
/// JWT auth driven by the route catalog (needs a permission loader).
pub const jwtAuthFromCatalog = http_middleware.jwtAuthFromCatalog;
/// Path A auth: verifies the JWT via the catalog and loads RBAC permissions.
pub const jwtAuthFromCatalogWithPermissions = http_middleware.jwtAuthFromCatalogWithPermissions;
/// Builds a loader that reads role → permission rows from a SQL table.
pub const catalogLoaderFromTable = http_middleware.catalogLoaderFromTable;
/// Loader interface the catalog middleware calls to resolve permissions.
pub const CatalogPermissionLoader = http_middleware.CatalogPermissionLoader;
/// Input to a loader: `sub`, `aud` (tenant) and the caller's roles.
pub const CatalogPermLoadInput = http_middleware.CatalogPermLoadInput;
// Pluggable catalog auth (M1/M3): any AuthBackend + catalog-sole bypass truth.
/// Pluggable token verification behind catalog auth (JWT is built in).
pub const AuthBackend = http_middleware.AuthBackend;
/// Catalog auth with any `AuthBackend`; the catalog is the sole bypass truth.
pub const authFromCatalog = http_middleware.authFromCatalog;
/// Options for `authFromCatalog`: skip prefixes + rejection renderer.
pub const AuthFromCatalogConfig = http_middleware.AuthFromCatalogConfig;
/// Built-in `AuthBackend` that verifies JWTs.
pub const jwtBackend = http_middleware.jwtBackend;
/// JWT backend that also loads the caller's RBAC permissions.
pub const jwtBackendWithPermissions = http_middleware.jwtBackendWithPermissions;
// Auth rejection envelope hook (M4).
/// Hook that renders the 401/403 response (swap the envelope shape).
pub const AuthRejectFn = http_middleware.AuthRejectFn;
/// Default rejection renderer (framework JSON body).
pub const defaultReject = http_middleware.defaultReject;
/// Rejection renderer speaking a chosen envelope dialect (e.g. ThinkPHP).
pub const envelopeReject = http_middleware.envelopeReject;
// Process-wide error renderers: in-chain (sendError) + pre-routing transport.
/// Rejection renderer emitting RFC 7807 `application/problem+json`.
pub const problemReject = http_middleware.problemReject;
/// Pre-routing transport error body in RFC 7807 shape.
pub const problemTransportBody = http_middleware.problemTransportBody;
/// Installs the process-wide rejection renderer.
pub const setDefaultReject = http_middleware.setDefaultReject;
/// Restores the built-in rejection renderer.
pub const clearDefaultReject = http_middleware.clearDefaultReject;
/// One call: render every error (routing included) as RFC 7807.
pub const useRfc7807Errors = http_middleware.useRfc7807Errors;
/// In-chain error renderer signature: `fn (ctx, status, message)`.
pub const ErrorRendererFn = server_mod.ErrorRendererFn;
/// Renderer signature for transport errors raised before routing.
pub const TransportErrorFn = server_mod.TransportErrorFn;
/// Body + content type returned by a transport error renderer.
pub const TransportErrorBody = server_mod.TransportErrorBody;
/// Installs the in-chain error renderer.
pub const setErrorRenderer = server_mod.setErrorRenderer;
/// Installs the pre-routing transport error renderer.
pub const setTransportErrorRenderer = server_mod.setTransportErrorRenderer;
/// Renders a transport-level error via the installed renderer.
pub const renderTransportError = server_mod.renderTransportError;
// Token extractors (M12) + tenant resolver (M7).
/// Where a token may come from: header, query, form, or any of them.
pub const TokenSource = http_middleware.TokenSource;
/// Extracts a `Bearer` token from the `Authorization` header.
pub const extractBearer = http_middleware.extractBearer;
/// Extracts a token from a named header.
pub const extractHeaderToken = http_middleware.extractHeaderToken;
/// Extracts a token from a query parameter.
pub const extractQueryToken = http_middleware.extractQueryToken;
/// Extracts a token from form data.
pub const extractFormToken = http_middleware.extractFormToken;
/// Tries the configured sources in order (header, query, form).
pub const extractTokenAny = http_middleware.extractTokenAny;
/// Derives the request's tenant from headers/query for the tenant attr.
pub const tenantResolver = http_middleware.tenantResolver;
/// Tenant resolver options; `.query` is client-controlled — prefer JWT `aud`.
pub const TenantResolverConfig = http_middleware.TenantResolverConfig;
/// Rejects requests whose module is not allowed; unknown modules configurable.
pub const moduleGate = http_middleware.moduleGate;
/// Checks route permissions against the caller's permission set.
pub const permissionGate = http_middleware.permissionGate;
/// Permission gate with config: match mode and rejection renderer.
pub const permissionGateWith = http_middleware.permissionGateWith;
/// Permission gate settings (mode, attribute names, reject policy).
pub const PermissionGateConfig = http_middleware.PermissionGateConfig;
/// How permissions are matched: RBAC codes or plain role names.
pub const PermissionMode = http_middleware.PermissionMode;
/// True when a roles CSV matches a portal expression (e.g. `portal:user`).
pub const permissionMatchesRoles = http_middleware.permissionMatchesRoles;
/// Same check against a legacy `auth_info` value.
pub const permissionMatchesAuthInfo = http_middleware.permissionMatchesAuthInfo;
/// Same check against the current request context's attrs.
pub const permissionMatchesContext = http_middleware.permissionMatchesContext;
/// Portal-aware match with an explicit mode — what handlers should call.
pub const permissionMatchesWith = http_middleware.permissionMatchesWith;
/// Options for the catalog JWT middleware (slot, loader, skip list).
pub const JwtFromCatalogConfig = http_middleware.JwtFromCatalogConfig;
/// Module gate options: unknown → allow/deny, plus the reject renderer.
pub const ModuleGateConfig = http_middleware.ModuleGateConfig;
/// Tracing middleware module (it also hosts the rate-limit middleware).
pub const tracing_middleware = @import("api/middleware/Tracing.zig");
/// Adds trace ids and span timing to each request.
pub const tracingMiddleware = @import("api/middleware/Tracing.zig").tracing;
/// Per-key rate limiting middleware for a route or group.
pub const rateLimitMiddleware = @import("api/middleware/Tracing.zig").rateLimit;
/// Validates a request body against rules; renders 400 on failure.
pub const validateRequest = @import("api/middleware/Validation.zig").validateRequest;
/// Middleware form of `validateRequest` for a route group.
pub const validationMiddleware = @import("api/middleware/Validation.zig").validationMiddleware;
/// Opt-in response compression (`Accept-Encoding: gzip` / `deflate`).
pub const compressionMiddleware = @import("api/Compression.zig").compressionMiddleware;
/// Response-compression settings (threshold, compressible types, level).
pub const CompressionConfig = @import("api/Compression.zig").CompressionConfig;

/// Outbound HTTP(S) client; HTTPS streams through `std.http.Client` trust store.
pub const HttpClient = @import("http/HttpClient.zig").HttpClient;
/// Builds OpenAPI documents from declared endpoints.
pub const OpenApiGenerator = @import("http/OpenApi.zig").OpenApiGenerator;
/// One documented endpoint: method, path, params, responses.
pub const ApiEndpoint = @import("http/OpenApi.zig").ApiEndpoint;
/// A JSON-schema node for a documented model.
pub const ApiSchema = @import("http/OpenApi.zig").ApiSchema;
/// Method enum used by the OpenAPI model.
pub const HttpMethod = @import("http/OpenApi.zig").HttpMethod;
/// RFC 7807 problem document (type, title, status, detail).
pub const ProblemDetails = @import("http/ProblemDetails.zig").ProblemDetails;
/// Problem document carrying per-field validation errors.
pub const ValidationProblem = @import("http/ProblemDetails.zig").ValidationProblem;
/// Stores `idempotency-key` → response so a retry replays instead of re-running.
pub const IdempotencyStore = @import("http/Idempotency.zig").IdempotencyStore;
/// Replays/records responses by `idempotency-key` header.
pub const idempotencyMiddleware = @import("http/Idempotency.zig").idempotencyMiddleware;
/// HTTP/2 frame codec (RFC 7540) plus HPACK.
pub const Http2 = @import("http/Http2.zig");
/// HTTP/2 prior-knowledge (h2c) connection loop.
pub const Http2Server = @import("http/Http2Server.zig");
/// HTTP/2 over TLS: ALPN negotiation helpers.
pub const Http2Tls = @import("http/Http2Tls.zig");
/// HPACK header compression (encode/decode, Huffman strings).
pub const Hpack = @import("http/Hpack.zig");
/// A parsed API version (major/minor).
pub const ApiVersion = @import("http/ApiVersioning.zig").ApiVersion;
/// Pulls the requested API version from path, header or query.
pub const ApiVersionExtractor = @import("http/ApiVersioning.zig").ApiVersionExtractor;
/// Routes the same resource by API version.
pub const ApiVersionRouter = @import("http/ApiVersioning.zig").ApiVersionRouter;
/// Records the request's API version on the context for handlers.
pub const apiVersionMiddleware = @import("http/ApiVersioning.zig").apiVersionMiddleware;
/// Server-Sent Events writer (heartbeats, `retry`, `last-event-id`).
pub const SseWriter = @import("http/Sse.zig").SseWriter;
/// Alias for SSE streaming handlers.
pub const Sse = SseWriter;
/// Test double that records SSE events instead of sending them.
pub const SseRecorder = @import("http/Sse.zig").SseRecorder;
/// Reads the client's `Last-Event-ID` so a stream can resume where it stopped.
pub const lastEventId = @import("http/Sse.zig").lastEventId;

/// Begin an SSE response (`Content-Type: text/event-stream`).
/// Sets `ctx.responded` and `ctx.streaming` so Server skips buffered `writeResponse`.
/// Requires live `ctx.stream` + `ctx.io`.
pub fn sse(ctx: *Context) !SseWriter {
    return SseWriter.init(ctx);
}

/// Typed extractors plus the unified error-response helpers (module barrel).
pub const Extract = @import("api/Extract.zig");
/// Paged-response helpers: clamped params plus the paged envelope.
pub const page = @import("http/Page.zig");
/// Parsed `page` / `page_size` (clamped so `0` cannot select every row).
pub const PageParams = page.PageParams;
/// Options for a paged response (defaults, maximum page size).
pub const PageOpts = page.PageOpts;
/// Paged-response dialect: plain / ruoyi / items.
pub const PageEnvelope = page.Envelope;
/// Sends the paged envelope for a list plus its total.
pub const sendPaged = page.sendPaged;
/// One declaration generates the entity's whole CRUD surface.
pub const CrudApi = @import("api/Crud.zig").CrudApi;
/// CRUD API options: scoping, auth, hooks, pagination defaults.
pub const CrudOpts = @import("api/Crud.zig").CrudOpts;
/// Parses the query string into a struct (defaults applied).
pub const extractQuery = Extract.extractQuery;
/// Reads route placeholders into a struct.
pub const extractPath = Extract.extractPath;
/// Parses a JSON body into a struct (400 on malformed input).
pub const extractJson = Extract.extractJson;
/// Parses and validates a JSON body against field rules.
pub const extractJsonValidated = Extract.extractJsonValidated;
/// Parses JSON while ignoring unknown fields.
pub const extractJsonLoose = Extract.extractJsonLoose;
/// Parses `multipart/form-data` into fields and uploaded files.
pub const extractMultipart = Extract.extractMultipart;
/// Derives OpenAPI parameters from a struct's fields.
pub const openApiParamsFromStruct = Extract.openApiParamsFromStruct;
/// Sends an RFC 7807 problem response.
pub const respondProblem = Extract.respondProblem;
/// Maps an error to the configured response shape and sends it.
pub const respondErr = Extract.respondErr;
/// Registers error → status/body overrides.
pub const setErrorMap = Extract.setErrorMap;
/// Clears the error-map overrides.
pub const clearErrorMap = Extract.clearErrorMap;
/// Registers localized messages per error and locale.
pub const setErrorLocalizations = Extract.setErrorLocalizations;
/// One error's mapping (status, code, message).
pub const ErrorMapping = Extract.ErrorMapping;
/// A localized message for an error key and locale.
pub const ErrorLocalization = Extract.ErrorLocalization;
/// Field validation rules used by `extractJsonValidated`.
pub const FieldRules = Extract.FieldRules;
/// Converts a model into a DTO struct.
pub const toDto = Extract.toDto;
/// Converts a slice of models into DTOs.
pub const toDtoList = Extract.toDtoList;
/// Converts and sends a DTO response.
pub const respondDto = Extract.respondDto;

/// HTTP test helpers — dispatch requests without binding a port.
pub const Testkit = @import("http/Testkit.zig");
/// Meta ↔ runtime auth audit (M2): `auditAuthCoverage(alloc, &server, &slot)`.
pub const auditAuthCoverage = Testkit.auditAuthCoverage;
/// A route whose declared auth disagrees with its runtime wiring.
pub const AuthAuditMismatch = Testkit.AuthAuditMismatch;
/// `multipart/form-data` parsing with upload limits applied.
pub const Multipart = @import("http/Multipart.zig");
/// Upload content policy: sniffed format vs extension allowlist (see doc header).
pub const UploadGuard = @import("http/UploadGuard.zig");
/// `extractMultipart` + `UploadGuard.checkForm` in one call (rejection → ProblemDetails).
pub const extractMultipartGuarded = Extract.extractMultipartGuarded;
/// Config for `extractMultipartGuarded` (parser limits + content policy).
pub const GuardedUpload = Extract.GuardedUpload;
/// Static file serving module (wraps the `staticFiles` handler).
pub const StaticFiles = @import("http/StaticFiles.zig");
/// Static file serving (traversal guard + ETag/304 + Range).
pub const staticFiles = @import("http/StaticFiles.zig").staticFiles;
/// HTTP + resilience profile bundle (defaults and production wiring).
pub const Profiles = @import("http/Profiles.zig");
/// Inputs for `applyHttpDefaults` (security basics, logs, metrics).
pub const ProfileConfig = Profiles.ProfileConfig;
/// Handles returned by `applyHttpDefaults` (logger, metrics, CORS origins).
pub const HttpProfileState = Profiles.HttpProfileState;
/// Applies sane HTTP defaults: body/connection limits, timeouts, middleware.
pub const applyHttpDefaults = Profiles.applyHttpDefaults;
/// One dependency's resilience settings (QPS, breaker thresholds, timeout).
pub const ResilienceDep = Profiles.ResilienceDep;
/// Handles returned by `applyResilienceDefaults`.
pub const ResilienceProfileState = Profiles.ResilienceProfileState;
/// Wires breaker / rate limiter / bulkhead / load shedding with defaults.
pub const applyResilienceDefaults = Profiles.applyResilienceDefaults;
/// Inputs for `productionProfile` (connections, headers, probes, security).
pub const ProductionConfig = Profiles.ProductionConfig;
/// Handles returned by `productionProfile`.
pub const ProductionProfileState = Profiles.ProductionProfileState;
/// One-call production hardening (backpressure + security + metrics + probes).
pub const productionProfile = Profiles.productionProfile;

/// Config validation and graceful-shutdown checklist helpers.
pub const Lifecycle = @import("http/Lifecycle.zig");
/// Ordered shutdown steps: drain, stop, flush, close.
pub const ShutdownChecklist = Lifecycle.ShutdownChecklist;
/// Reads a required env var, failing fast when it is missing.
pub const requireEnv = Lifecycle.requireEnv;

/// Built-in system dashboard plus its route registration.
pub const Dashboard = @import("http/Dashboard.zig");
/// Access log writer (method, path, status, latency).
pub const AccessLogger = @import("http/AccessLog.zig").AccessLogger;
/// Logs every handled request in the access-log format.
pub const accessLogMiddleware = @import("http/AccessLog.zig").accessLogMiddleware;
/// Collects HTTP golden signals (rate, errors, duration).
pub const HttpMetricsCollector = @import("http/HttpMetrics.zig").HttpMetricsCollector;
/// Feeds per-route request metrics into the collector.
pub const httpMetricsMiddleware = @import("http/HttpMetrics.zig").httpMetricsMiddleware;
/// OpenAPI spec version enum (3.0 / 3.1).
pub const OpenApiVersion = @import("http/OpenApi.zig").OpenApiVersion;
/// Where a documented parameter lives (path / query / header / cookie).
pub const ParamLocation = @import("http/OpenApi.zig").ParamLocation;
/// One documented parameter (name, location, schema).
pub const ApiParam = @import("http/OpenApi.zig").ApiParam;
/// A documented request body (content type plus schema).
pub const RequestBody = @import("http/OpenApi.zig").RequestBody;
/// A documented response (status, schema, description).
pub const ApiResponse = @import("http/OpenApi.zig").ApiResponse;
/// One property of an object schema.
pub const SchemaProperty = @import("http/OpenApi.zig").SchemaProperty;
/// A stored idempotent response plus its expiry.
pub const IdempotencyEntry = @import("http/Idempotency.zig").IdempotencyEntry;
/// Idempotency settings (TTL, key requirement, replay behaviour).
pub const IdempotencyConfig = @import("http/Idempotency.zig").IdempotencyConfig;
/// Snapshot of system info rendered on the dashboard.
pub const SystemInfo = @import("http/Dashboard.zig").SystemInfo;
/// Registers the dashboard routes on a router.
pub const dashboardRoutes = @import("http/Dashboard.zig").registerRoutes;
/// Sends an RFC 7807 problem document.
pub const sendProblem = @import("http/ProblemDetails.zig").sendProblem;
/// Same, with an explicit `type` URI.
pub const sendProblemWithType = @import("http/ProblemDetails.zig").sendProblemWithType;
/// Sends a problem document wrapping field validation errors.
pub const sendValidationProblem = @import("http/ProblemDetails.zig").sendValidationProblem;
/// Wraps a context so its response is recorded for later replay.
pub const wrapContextWithIdempotency = @import("http/Idempotency.zig").wrapContextWithIdempotency;
/// Stores a response under the request's idempotency key.
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
