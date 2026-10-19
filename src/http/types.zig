//! HTTP request/response types shared by the server and its helpers.
//!
//! These lived in `api/Server.zig` until the orthogonal pass: every middleware
//! helper under `http/` and the whole `security/` layer had to import the
//! *server implementation* to name `Context`/`Middleware`, while the server
//! imported the helpers — a directory-level cycle between one layer split in
//! two. The types now live here; `api/Server.zig` re-exports them, so
//! `zigmodu.http.Context` and `zigmodu.api.Server.Context` are the same type.
//!
//! `Context.permissionMatches` evaluates RBAC *expressions* with the pure
//! evaluator in `security/Rbac.zig` (that file imports only `std`, so this is a
//! file-level DAG: types -> Rbac, security -> types).

const std = @import("std");
const Params = @import("Params.zig").Params;
const Multipart = @import("Multipart.zig");
const Time = @import("../core/Time.zig");
const sockread = @import("../core/sockread.zig");
const sqlx = @import("../sqlx/sqlx.zig");
const Rbac = @import("../security/Rbac.zig");
const ModuleLogger = @import("../log/ModuleLogger.zig").ModuleLogger;

// ==== §2  Process-wide error renderers ====

// ── Process-wide error renderers ────────────────────────────────────────
//
// Errors reach the client through three paths, and before these hooks only one
// of them was styleable by an application:
//
//   1. in-chain rejections — `ctx.sendError` / `ctx.sendErrorResponse` from
//      moduleGate, CSRF, auth, the uncaught-handler 500 … (`error_renderer`)
//   2. response bodies written *before* routing — malformed request line,
//      oversized body, header flood, over-limit connections
//      (`transport_error_renderer`)
//   3. handler-owned bodies — `ctx.json` / `http.respondErr`
//
// Set both hooks once at startup (`http.useRfc7807Errors()`) to make every
// framework-generated error body one shape. They are process-wide on purpose:
// the uncaught-handler 500 is raised outside the middleware chain, so no
// per-request or per-route config can reach it.

/// Renders an in-chain error response. Install with `setErrorRenderer`.
pub const ErrorRendererFn = *const fn (ctx: *Context, status: u16, message: []const u8) anyerror!void;

/// Renders a pre-routing error body. `buf` is caller-owned scratch; return a
/// slice of it (or a static string). Called on the accept thread and possibly
/// concurrently, so the returned slice must never alias shared mutable state.
pub const TransportErrorFn = *const fn (status: u16, message: []const u8, buf: []u8) TransportErrorBody;

pub const TransportErrorBody = struct {
    content_type: []const u8 = "application/json",
    body: []const u8,
};

/// See `ErrorRendererFn`. `null` (default) = the legacy
/// `{"code":status,"msg":…,"data":null}` envelope.
pub var error_renderer: ?ErrorRendererFn = null;

/// See `TransportErrorFn`. `null` (default) = the legacy `{"error":"…"}` body.
pub var transport_error_renderer: ?TransportErrorFn = null;

/// Install the renderer for in-chain errors (`sendError` / `sendErrorResponse`,
/// and therefore every gate that defaults to `http.defaultReject`).
/// Call once at startup; `null` restores the legacy envelope.
pub fn setErrorRenderer(renderer: ?ErrorRendererFn) void {
    error_renderer = renderer;
}

/// Install the renderer for errors written before routing (408/413/431/503).
/// Call once at startup; `null` restores the legacy body.
pub fn setTransportErrorRenderer(renderer: ?TransportErrorFn) void {
    transport_error_renderer = renderer;
}

/// Body for a pre-routing error. Falls back to the legacy `{"error":"…"}` when
/// no renderer is installed.
pub fn renderTransportError(status: u16, message: []const u8, buf: []u8) TransportErrorBody {
    if (transport_error_renderer) |f| return f(status, message, buf);
    const body = std.fmt.bufPrint(buf, "{{\"error\":\"{s}\"}}", .{message}) catch return .{ .body = "{\"error\":\"Request Failed\"}" };
    return .{ .body = body };
}

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    /// Parse an HTTP method token. Uses first-char dispatch for O(1) fast path.
    ///
    /// Returns `null` for any other token — including well-formed extension
    /// methods such as `PROPFIND`. It must not fall back to `.GET`: the method
    /// token is attacker-controlled, and "token this parser does not know =
    /// GET" is a request-smuggling primitive whenever a front-end proxy splits
    /// the same bytes differently (the request line it serves is not the one
    /// this server routed). Callers reject with 501 instead.
    pub fn fromString(s: []const u8) ?Method {
        if (s.len == 0) return null;
        return switch (s[0]) {
            'G' => if (std.mem.eql(u8, s, "GET")) .GET else null,
            'P' => if (std.mem.eql(u8, s, "POST"))
                .POST
            else if (std.mem.eql(u8, s, "PUT"))
                .PUT
            else if (std.mem.eql(u8, s, "PATCH"))
                .PATCH
            else
                null,
            'D' => if (std.mem.eql(u8, s, "DELETE")) .DELETE else null,
            'H' => if (std.mem.eql(u8, s, "HEAD")) .HEAD else null,
            'O' => if (std.mem.eql(u8, s, "OPTIONS")) .OPTIONS else null,
            else => null,
        };
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
        };
    }
};

/// HTTP handler function type
pub const HandlerFn = *const fn (*Context) anyerror!void;

/// Path rewriter: runs after Context init, before route matching.
/// Can modify ctx.path to redirect route selection without client redirects.
pub const PathRewriterFn = *const fn (*Context) void;

/// Middleware function type with optional user data
pub const MiddlewareFn = *const fn (*Context, HandlerFn, ?*anyopaque) anyerror!void;

/// Middleware wrapper with optional state
pub const Middleware = struct {
    func: MiddlewareFn,
    user_data: ?*anyopaque = null,
};

/// Route definition
pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: HandlerFn,
    middleware: []const Middleware = &.{},
    user_data: ?*anyopaque = null,
    /// Pre-computed global + route-specific middleware chain.
    /// Set by addRoute() — do not set manually.
    combined_middleware: []const Middleware = &.{},
};

pub const Identity = struct {
    user_id: ?[]const u8 = null,
    tenant_id: ?[]const u8 = null,
    /// Comma-separated portal / coarse roles (JWT `roles`).
    roles: ?[]const u8 = null,
};

/// Response envelope dialect for the `ok` / `fail` / `unauth` / `paginated`
/// Context helpers and auth-rejection rendering (see `http.envelopeReject`).
pub const EnvelopeDialect = enum {
    /// ZigModu CommonResult: ok `{code:0,msg:"ok",data}`; fail `{code:1,…}`;
    /// unauth HTTP 401 `{code:401,…}`; paged `{code:0,…,data:{list,total}}`.
    default,
    /// ThinkPHP: ok `{code:1,msg:"success",data}`; fail `{code:0,…}`;
    /// unauth HTTP 401 `{code:-1,…}`; paged `{code:1,…,data:{list,total}}`.
    thinkphp,
    /// RuoYi: ok `{code:0,msg:"success",data}`; fail `{code:500,…}`;
    /// unauth HTTP 401 `{code:401,…}`; paged `{code:0,msg,rows,total}`.
    ruoyi,
};

pub const FieldSource = enum {
    path,
    query,
    form,
    header,
};

/// HTTP context - holds request/response data
pub const Context = struct {
    allocator: std.mem.Allocator,
    method: Method,
    path: []const u8,
    /// Matched route pattern (e.g. `/api/v1/orders/{id}`), set at dispatch.
    /// Use this — not `path` — as a metrics label: paths carry ids and would
    /// blow up cardinality.
    route_template: ?[]const u8 = null,
    raw_path: []const u8,
    /// Query string / form body: multi-value (repeated keys + `a[b]` brackets).
    query: Params,
    params: std.StringHashMap([]const u8),
    headers: std.StringHashMap([]const u8),
    form: ?Params = null,
    body: ?[]const u8 = null,
    response_body: std.ArrayList(u8),
    status_code: u16 = 200,
    response_headers: std.StringHashMap([]const u8),
    responded: bool = false,
    user_data: ?*anyopaque = null,
    /// AuthInfo / opaque auth object for middleware. Separate from `user_data` so
    /// ComptimeRouter route state and RBAC can coexist on one request.
    auth_info: ?*anyopaque = null,
    attributes: std.StringHashMap([]const u8),
    validation_error_message: ?[]const u8 = null,
    stream: ?std.Io.net.Stream = null,
    io: ?std.Io = null,
    streaming: bool = false,
    /// Set by `endStream` — i.e. "this streaming response is complete". It exists
    /// because `streaming` alone cannot tell the two cases apart after a handler
    /// returns: a chunked response that ended is a finished message on a reusable
    /// connection, while one that never ended has left the message open (and an SSE
    /// stream — raw event bytes, no transfer coding — only ever ends at EOF).
    /// Without the distinction the connection was reused either way, so the next
    /// response (or the keep-alive timeout's 408) was written into the previous,
    /// unterminated body.
    /// Set by `startChunked` — i.e. "this stream carries `Transfer-Encoding:
    /// chunked`". An SSE stream does not: `http.sse` writes raw event bytes with no
    /// transfer coding, so its message ends at EOF and writing a chunk terminator
    /// into it would be body corruption.
    chunked_framing: bool = false,
    stream_ended: bool = false,
    upgraded: bool = false,
    /// Send bound for the writes this context makes *itself* — the streaming
    /// ones (`flushHeadersToSocket`, `writeChunk`, `endStream`) and, through
    /// `http.sse`, the `SseWriter`'s events. `Server` fills it from
    /// `Config.response_write_timeout_ms`; `0` = unbounded.
    ///
    /// It is on the context because these paths write *during* the handler (an
    /// SSE loop can run for hours), where `writeResponse` never gets a chance to
    /// apply its bound — and a peer that stops reading is exactly as able to park
    /// that fiber as it is to park a buffered response's.
    write_timeout_ms: u32 = 0,
    /// Envelope dialect used by `ok` / `fail` / `unauth` / `paginated`.
    envelope: EnvelopeDialect = .default,
    /// Absolute deadline (monotonic ms) for this request, from
    /// `Server.Config.request_timeout_ms`. `null` = unbounded.
    ///
    /// This is a **budget**, not a kill switch: wiring it into storage is what
    /// stops a slow request from holding a pool connection after the client has
    /// already given up. `ctx.sqlContext()` is the one-line bridge.
    deadline_ms: ?i64 = null,

    /// Did-you-mean suggestion computed for a 404 (e.g.
    /// "Not Found; did you mean /v1/merchant/orders/submit"), or null when no
    /// registered route was one case-flip away. The built-in 404 body embeds
    /// the same string; a custom `default_404` renderer reads it through
    /// `notFoundHint()` so installing one no longer discards the hint.
    /// Allocated in the request arena — valid for this request only.
    not_found_hint: ?[]const u8 = null,

    /// Per-request arena — eliminates ~20 heap allocs per request.
    /// Removed nested arena in Zig 0.17: ArenaAllocator.free() is no-op,
    /// so inner arena deinit never returned memory to outer arena, causing OOM.
    /// Now uses connFiber's arena allocator directly — arena.reset() between
    /// requests handles all cleanup.
    request_arena: ?std.heap.ArenaAllocator = null,

    // Middleware chain fields
    chain_middlewares: []const Middleware = &.{},
    chain_handler: *const fn (*Context) anyerror!void = undefined,
    chain_index: usize = 0,

    /// Get allocator for request-scoped allocations (headers, params, body).
    pub fn arenaAlloc(self: *Context) std.mem.Allocator {
        return self.allocator;
    }

    /// Reset per-request state between keep-alive requests.
    pub fn resetArena(self: *Context) void {
        self.query.deinit();
        self.freeStringMap(&self.params);
        self.freeStringMap(&self.headers);
        self.freeStringMap(&self.attributes);
        self.freeStringMap(&self.response_headers);
        if (self.form) |*f| f.deinit();
        self.not_found_hint = null;
    }

    /// The did-you-mean suggestion for a 404, or null when none was found.
    /// A custom `default_404` renderer calls this to keep the hint inside its
    /// own envelope; the built-in 404 body already carries the same text.
    pub fn notFoundHint(self: *const Context) ?[]const u8 {
        return self.not_found_hint;
    }

    fn freeStringMap(self: *Context, map: *std.StringHashMap([]const u8)) void {
        // Safe for both GPA (tests) and ArenaAllocator (connFiber): Zig 0.17
        // arena free is a no-op; GPA reclaims each key/value for leak-free tests.
        var iter = map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        map.clearRetainingCapacity();
    }

    pub fn init(allocator: std.mem.Allocator, method: Method, path: []const u8) !Context {
        return Context{
            .allocator = allocator,
            .method = method,
            .path = path,
            .raw_path = path,
            .query = Params.init(allocator),
            .params = std.StringHashMap([]const u8).init(allocator),
            .headers = std.StringHashMap([]const u8).init(allocator),
            .response_body = std.ArrayList(u8).empty,
            .response_headers = std.StringHashMap([]const u8).init(allocator),
            .attributes = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        self.query.deinit();
        self.freeStringMap(&self.params);
        self.params.deinit();
        self.freeStringMap(&self.headers);
        self.headers.deinit();
        if (self.form) |*f| f.deinit();
        self.response_body.deinit(self.allocator);
        self.freeStringMap(&self.response_headers);
        self.response_headers.deinit();
        self.freeStringMap(&self.attributes);
        self.attributes.deinit();
        self.* = undefined;
    }

    /// Arms the request budget. `timeout_ms == 0` disables it (`.null`).
    pub fn setDeadline(self: *Context, timeout_ms: u32) void {
        self.deadline_ms = if (timeout_ms == 0)
            null
        else
            Time.monotonicNowMilliseconds() + @as(i64, @intCast(timeout_ms));
    }

    /// Milliseconds left in the budget, `null` when unbounded. Negative once
    /// the budget is spent.
    pub fn remainingMs(self: *const Context) ?i64 {
        const d = self.deadline_ms orelse return null;
        return d - Time.monotonicNowMilliseconds();
    }

    /// The request budget in the shape storage understands. Hand it to
    /// `Orm.withContext` (or any `sqlx` `*Ctx` call) and every query on that
    /// path refuses to *start* once the budget is spent:
    ///
    /// ```zig
    /// var scoped = self.persistence.orm.withContext(ctx.sqlContext());
    /// const repo = data.Repository(Row){ .orm = &scoped };
    /// ```
    ///
    /// Without this call the request runs unbounded — which is the pre-existing
    /// behaviour, so wiring it is opt-in per handler.
    pub fn sqlContext(self: *const Context) sqlx.SqlContext {
        return .{ .deadline_ms = self.deadline_ms };
    }

    /// Store an attribute on the context (for middleware data passing).
    pub fn setAttr(self: *Context, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(v);
        if (self.attributes.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        try self.attributes.put(k, v);
    }

    /// Retrieve an attribute from the context.
    pub fn getAttr(self: *const Context, key: []const u8) ?[]const u8 {
        return self.attributes.get(key);
    }

    /// Typed route state: `user_data` carries the `*State` the route was
    /// registered with (ComptimeRouter mounts, `RouteGroup` handlers, and the
    /// WebSocket `on_connect` / `on_close` callbacks all reach it this way).
    ///
    /// Prefer this over spelling `@ptrCast(@alignCast(ctx.user_data orelse …))`
    /// at each call site: the reinterpret happens once here, and the
    /// "no state on this route" case is the named `error.NoRouteState` instead
    /// of an inline `orelse unreachable`.
    ///
    /// `T` must be the state type the route was registered with. This is a
    /// reinterpreting cast, not a runtime type check. Reading identity is a
    /// different concern — use `userId()` / `tenantId()` / `rolesCsv()`, which
    /// read middleware attributes.
    pub fn state(self: *const Context, comptime T: type) error{NoRouteState}!*T {
        const raw = self.user_data orelse return error.NoRouteState;
        return @ptrCast(@alignCast(raw));
    }

    /// Get query parameter
    /// Path parameter (route placeholder, e.g. `{id}` in `/orders/{id}`).
    /// `param` is the historical name for exactly this — prefer `pathParam`
    /// when the distinction matters: nothing here reads query or form input.
    /// See the table below.
    pub fn pathParam(self: *const Context, key: []const u8) ?[]const u8 {
        return self.param(key);
    }

    pub fn queryParam(self: *const Context, key: []const u8) ?[]const u8 {
        return self.query.get(key);
    }

    /// Get path parameter.
    ///
    /// The four accessors, so no reader has to guess:
    ///
    /// | call | reads |
    /// |------|-------|
    /// | `param` / `pathParam` | **route placeholder only** (`/orders/{id}`) |
    /// | `queryParam` / `queryStr` / `queryInt` | query string only |
    /// | `formValue` | form body only |
    /// | `requestParam` | **form first, then query** — "wherever the client put it" |
    /// | `nestedParam` | dotted path into form/query (`filter.tags`) |
    pub fn param(self: *const Context, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    /// Form value, else query value (form wins). The "give me this parameter
    /// wherever the client sent it" accessor — `param` is *not* that, despite
    /// the name: it is the route placeholder.
    ///
    /// Form-first matches Rails / Laravel / ThinkPHP `input()` semantics, so a
    /// POST body overrides a stray query parameter of the same name.
    pub fn requestParam(self: *const Context, key: []const u8) ?[]const u8 {
        if (self.form) |f| {
            if (f.get(key)) |v| return v;
        }
        return self.query.get(key);
    }

    /// Path parameter as integer (generic). Returns error.BadRequest if missing/invalid.
    pub fn paramInt(self: *const Context, comptime T: type, key: []const u8) !T {
        const v = self.params.get(key) orelse return error.BadRequest;
        return std.fmt.parseInt(T, v, 10) catch error.BadRequest;
    }

    /// Path parameter as string (required).
    pub fn paramStr(self: *const Context, key: []const u8) ![]const u8 {
        return self.params.get(key) orelse error.BadRequest;
    }

    /// Query parameter as integer with default.
    pub fn queryInt(self: *const Context, comptime T: type, key: []const u8, default: T) T {
        const val = self.query.get(key) orelse return default;
        return std.fmt.parseInt(T, val, 10) catch default;
    }

    /// Query parameter as string with default.
    pub fn queryStr(self: *const Context, key: []const u8, default: []const u8) []const u8 {
        return self.query.get(key) orelse default;
    }

    /// Get request header. Header names are case-insensitive (RFC 9110), so
    /// `"User-Agent"` and `"user-agent"` resolve to the same value. Request
    /// headers are normalized to lowercase at parse time; the exact-match fast
    /// path covers lowercase keys, and a case-insensitive scan handles the rest.
    pub fn header(self: *const Context, key: []const u8) ?[]const u8 {
        return headerLookup(self.headers, key);
    }

    /// Get form value
    pub fn formValue(self: *const Context, key: []const u8) ?[]const u8 {
        return if (self.form) |f| f.get(key) else null;
    }

    /// Set response header. Keys/values are owned by the context allocator and
    /// freed in `deinit` / `resetArena`. Replacing an existing header frees the
    /// previous entry (GPA) or no-ops (arena).
    ///
    /// The field is validated first (`validateResponseField`): a non-token name
    /// or a value carrying CR/LF/NUL is `error.InvalidHeader`, and a value past
    /// `max_response_header_value_bytes` is `error.HeaderTooLarge`. Both are
    /// refused *here* rather than at write time, so the handler that echoed
    /// request data into a header is told which line it is.
    pub fn setHeader(self: *Context, key: []const u8, value: []const u8) !void {
        try validateResponseField(key, value);
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        if (self.response_headers.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        try self.response_headers.put(key_copy, value_copy);
    }

    /// Type-safe accessor for user_data. Replaces @ptrCast(@alignCast(...)).
    pub fn userData(self: *Context, comptime T: type) ?*T {
        return @ptrCast(@alignCast(self.user_data));
    }

    /// Type-safe accessor for auth_info (RBAC AuthInfo, etc.).
    pub fn authInfo(self: *const Context, comptime T: type) ?*T {
        return @ptrCast(@alignCast(self.auth_info));
    }

    pub fn setAuthInfo(self: *Context, ptr: ?*anyopaque) void {
        self.auth_info = ptr;
    }

    // ── Typed identity (canonical attrs) ────────────────────────────────

    /// Write identity attrs (`user_id` / `tenant_id` / `roles`). Auth
    /// middleware calls this after verification; `null` fields are skipped.
    pub fn setIdentity(self: *Context, id: Identity) !void {
        if (id.user_id) |v| try self.setAttr("user_id", v);
        if (id.tenant_id) |v| try self.setAttr("tenant_id", v);
        if (id.roles) |v| try self.setAttr("roles", v);
    }

    /// Snapshot of the identity attrs (any field may be absent).
    pub fn identity(self: *const Context) Identity {
        return .{
            .user_id = self.getAttr("user_id"),
            .tenant_id = self.getAttr("tenant_id"),
            .roles = self.getAttr("roles"),
        };
    }

    /// Authenticated user id (string), or null when unauthenticated.
    pub fn userId(self: *const Context) ?[]const u8 {
        return self.getAttr("user_id");
    }

    /// Authenticated user id parsed as integer, or null when absent/invalid.
    pub fn userIdInt(self: *const Context, comptime T: type) ?T {
        const v = self.userId() orelse return null;
        return std.fmt.parseInt(T, v, 10) catch null;
    }

    /// Authenticated user id or `error.Unauthorized` — replaces the
    /// `requireLogin` / `currentUid` helper copies in consumers.
    pub fn requireUserId(self: *const Context) ![]const u8 {
        return self.userId() orelse error.Unauthorized;
    }

    /// Authenticated user id as integer or `error.Unauthorized`.
    pub fn requireUserIdInt(self: *const Context, comptime T: type) !T {
        return self.userIdInt(T) orelse error.Unauthorized;
    }

    /// Tenant / app id (JWT `aud` or tenant middleware), or null.
    pub fn tenantId(self: *const Context) ?[]const u8 {
        return self.getAttr("tenant_id");
    }

    /// Comma-separated portal roles, or null.
    pub fn rolesCsv(self: *const Context) ?[]const u8 {
        return self.getAttr("roles");
    }

    /// Comma-separated permission codes (JWT/catalog loader), or null.
    ///
    /// Mirror of `rolesCsv()`, reading the same attr `permissionGateWith` writes
    /// (`PermissionGateConfig.permission_attr`, default `"permissions"`). The
    /// kind of check a route's `permission` performs, use `permissionMatches`.
    pub fn permissionsCsv(self: *const Context) ?[]const u8 {
        return self.getAttr("permissions");
    }

    /// Trace id for this request, or null when nothing bound one.
    ///
    /// Nothing here generates or propagates a trace id: the framework has no
    /// ambient "current span", so the producer is whoever knows the id — a
    /// middleware that minted or forwarded one (`tracingMiddleware`,
    /// `tracingWithTrace`), or a handler holding a `DistributedTracer` span.
    /// It calls `setTraceId`; the handler reads the attr back and hands it to
    /// the log scope, which is the whole correlation recipe:
    ///
    /// ```zig
    /// const log = LogScope.scope("payments")
    ///     .withField("trace_id", ctx.traceId() orelse "");
    /// log.info("charged {d}", .{amount});
    /// ```
    pub fn traceId(self: *const Context) ?[]const u8 {
        return self.getAttr("trace_id");
    }

    /// Bind the trace id for this request (attr `trace_id`, owned by the
    /// context). Middleware calls this after minting or parsing an id; the
    /// handler then reads it with `traceId()` — see that doc for the recipe.
    pub fn setTraceId(self: *Context, id: []const u8) !void {
        try self.setAttr("trace_id", id);
    }

    /// A log scope already carrying this request's trace id — the one-liner that
    /// keeps the trace/log loop closed:
    ///
    /// ```zig
    /// const log = ctx.logScope("orders");
    /// log.info("order {d} placed", .{id});   // …→ [orders] order 7 placed trace_id=…
    /// ```
    ///
    /// Built this way on purpose: `LogScope.scope("orders")` alone still works
    /// and emits an untagged line, so a handler that forgets the trace id
    /// *silently* loses correlation. Going through `ctx` removes that failure
    /// mode — either the request has an id and every line carries it, or the
    /// request has none and neither does the line (which is honest).
    pub fn logScope(self: *const Context, comptime module: []const u8) ModuleLogger.LogScope.scope(module).Bound {
        const Scope = ModuleLogger.LogScope.scope(module);
        if (self.traceId()) |id| return Scope.withField("trace_id", id);
        return .{};
    }

    /// Does this identity satisfy a route's `permission` / `roles` expression?
    ///
    /// `expr` is a single code or `|`-separated alternatives — the same syntax
    /// `RouteMeta` declares — so a handler can ask "which side of
    /// `portal:user|portal:shop` is this request on?" instead of re-deriving the
    /// match (and drifting from the gate it sits behind).
    ///
    /// Checked in order: the RBAC `AuthInfo` when one is attached, the
    /// `permissions` attr, then the `roles` attr. Any match counts.
    ///
    /// This is the *handler's* view, not an authorization gate: the gate already
    /// ran. To reproduce one gate's exact semantics (`.roles` vs `.rbac`, custom
    /// attr names) use `http.permissionMatchesWith(ctx, expr, config)`.
    pub fn permissionMatches(self: *const Context, expr: []const u8) bool {
        if (self.authInfo(Rbac.AuthInfo)) |ai| {
            if (Rbac.exprMatchesAuthInfo(ai, expr)) return true;
        }
        if (self.permissionsCsv()) |perms| {
            if (Rbac.exprMatchesCsv(perms, expr)) return true;
        }
        if (self.rolesCsv()) |roles| {
            if (Rbac.exprMatchesCsv(roles, expr)) return true;
        }
        return false;
    }

    // ── Typed attr getters ──────────────────────────────────────────────

    /// Attribute parsed as integer, or null when absent/invalid.
    pub fn getAttrInt(self: *const Context, comptime T: type, key: []const u8) ?T {
        const v = self.getAttr(key) orelse return null;
        return std.fmt.parseInt(T, v, 10) catch null;
    }

    /// Attribute mapped to an enum by name, or null when absent/unknown.
    pub fn getAttrEnum(self: *const Context, comptime E: type, key: []const u8) ?E {
        const v = self.getAttr(key) orelse return null;
        return std.meta.stringToEnum(E, v);
    }

    // ── Envelope dialect helpers ────────────────────────────────────────

    /// Select the envelope dialect for `ok` / `fail` / `unauth` / `paginated`.
    pub fn setEnvelope(self: *Context, dialect: EnvelopeDialect) void {
        self.envelope = dialect;
    }

    /// Low-level envelope writer: `{"code":code,"msg":msg,"data":data_json}`
    /// with `msg` JSON-escaped and `data_json` embedded raw (pass `"null"`).
    pub fn respondEnvelope(self: *Context, http_status: u16, code: i32, msg: []const u8, data_json: []const u8) !void {
        const msg_json = try std.json.Stringify.valueAlloc(self.allocator, msg, .{});
        defer self.allocator.free(msg_json);
        const body = try self.allocator.print("{{\"code\":{d},\"msg\":{s},\"data\":{s}}}", .{ code, msg_json, data_json });
        defer self.allocator.free(body);
        try self.json(http_status, body);
    }

    /// Success envelope per `ctx.envelope`. `data_json` is raw JSON.
    pub fn ok(self: *Context, data_json: []const u8) !void {
        switch (self.envelope) {
            .default => try self.respondEnvelope(200, 0, "ok", data_json),
            .thinkphp => try self.respondEnvelope(200, 1, "success", data_json),
            .ruoyi => try self.respondEnvelope(200, 0, "success", data_json),
        }
    }

    /// Success envelope serializing any Zig value as `data`.
    pub fn okValue(self: *Context, value: anytype) !void {
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(json_str);
        try self.ok(json_str);
    }

    /// Business failure per dialect (HTTP 200; code 1 / 0 / 500).
    pub fn fail(self: *Context, msg: []const u8) !void {
        switch (self.envelope) {
            .default => try self.respondEnvelope(200, 1, msg, "null"),
            .thinkphp => try self.respondEnvelope(200, 0, msg, "null"),
            .ruoyi => try self.respondEnvelope(200, 500, msg, "null"),
        }
    }

    /// Failure with an explicit business code (HTTP 200).
    pub fn failCode(self: *Context, code: i32, msg: []const u8) !void {
        try self.respondEnvelope(200, code, msg, "null");
    }

    /// Unauthenticated per dialect: HTTP 401 with code 401 / -1 / 401.
    pub fn unauth(self: *Context, msg: []const u8) !void {
        switch (self.envelope) {
            .default, .ruoyi => try self.respondEnvelope(401, 401, msg, "null"),
            .thinkphp => try self.respondEnvelope(401, -1, msg, "null"),
        }
    }

    /// Paged envelope: default/thinkphp `{…,data:{list,total}}`;
    /// ruoyi `{code:0,msg,rows,total}` (RuoYi TableDataInfo shape).
    pub fn paginated(self: *Context, items: anytype, total: usize) !void {
        const items_json = try std.json.Stringify.valueAlloc(self.allocator, items, .{});
        defer self.allocator.free(items_json);
        switch (self.envelope) {
            .default, .thinkphp => {
                const code: i32 = if (self.envelope == .thinkphp) 1 else 0;
                const msg: []const u8 = if (self.envelope == .thinkphp) "success" else "ok";
                const data = try self.allocator.print("{{\"list\":{s},\"total\":{d}}}", .{ items_json, total });
                defer self.allocator.free(data);
                try self.respondEnvelope(200, code, msg, data);
            },
            .ruoyi => {
                const body = try self.allocator.print("{{\"code\":0,\"msg\":\"success\",\"rows\":{s},\"total\":{d}}}", .{ items_json, total });
                defer self.allocator.free(body);
                try self.json(200, body);
            },
        }
    }

    /// Stream a chunk of the response body. Call flushHeaders() first to send
    /// status line + headers, then call writeBody() for each chunk. This avoids
    /// buffering the entire response in memory for large payloads.
    pub fn writeBody(self: *Context, data: []const u8) !void {
        try self.response_body.appendSlice(self.allocator, data);
    }

    /// Mark headers as flushed. After this, writeBody() appends data for
    /// chunked transfer (avoids buffering entire response in memory).
    pub fn flushHeaders(self: *Context) void {
        self.responded = true;
    }

    /// Start chunked transfer encoding for streaming large responses.
    /// Call writeChunk() for each chunk, then endStream() when done.
    /// If a direct stream is available, data goes straight to the socket
    /// without buffering in response_body.
    ///
    /// Under `HEAD` the field section still goes out — those are the `GET`
    /// response's own headers — while `writeChunk` / `endStream` put nothing
    /// after it, so the message ends where a response to `HEAD` ends.
    pub fn startChunked(self: *Context, status: u16, content_type: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Transfer-Encoding", "chunked");
        try self.setHeader("Content-Type", content_type);
        self.responded = true;
        self.streaming = true;
        self.chunked_framing = true;
        // Flush status line + headers to socket immediately
        if (self.stream != null and self.io != null) {
            try self.flushHeadersToSocket();
        }
    }

    /// Write status line + headers directly to socket (for streamed responses).
    fn flushHeadersToSocket(self: *Context) !void {
        var head_buf: [response_head_buffer_bytes]u8 = undefined;
        var w = sockread.BoundedWriter.init(self.stream.?, &head_buf, self.write_timeout_ms);
        const status_text = getStatusText(self.status_code);
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status_code, status_text });
        var hiter = self.response_headers.iterator();
        while (hiter.next()) |entry| {
            try w.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try w.write("\r\n");
        try w.flush();
    }

    /// Write a chunk in chunked transfer encoding.
    /// Writes directly to socket when streaming, falls back to response_body buffer.
    ///
    /// Nothing at all under `HEAD`: the response is its field section and no
    /// more (RFC 9110 §9.3.2), and a chunk header is body framing. The length of
    /// a stream is not known before the last chunk, so the field section cannot
    /// carry a `Content-Length` — it carries the `Transfer-Encoding: chunked`
    /// that `startChunked` set, which is the framing a `GET` would have used.
    pub fn writeChunk(self: *Context, data: []const u8) !void {
        if (self.method == .HEAD) return;
        if (self.stream != null and self.io != null) {
            var write_buf: [4096]u8 = undefined;
            var w = sockread.BoundedWriter.init(self.stream.?, &write_buf, self.write_timeout_ms);
            var size_buf: [32]u8 = undefined;
            const size_hex = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len});
            try w.write(size_hex);
            try w.write(data);
            try w.write("\r\n");
            try w.flush();
            return;
        }
        const chunk_header = try self.allocator.print("{x}\r\n", .{data.len});
        defer self.allocator.free(chunk_header);
        try self.response_body.appendSlice(self.allocator, chunk_header);
        try self.response_body.appendSlice(self.allocator, data);
        try self.response_body.appendSlice(self.allocator, "\r\n");
    }

    /// End chunked transfer encoding.
    /// Writes directly to socket when streaming, falls back to response_body buffer.
    ///
    /// Under `HEAD` there is no transfer coding to end: the zero-length chunk is
    /// part of the body a `GET` would have sent, so it stays off the wire with the
    /// rest of it (RFC 9112 §6.3: a response to `HEAD` ends at the first empty
    /// line after the field section, whatever the framing fields say).
    pub fn endStream(self: *Context) !void {
        // Recorded before the `HEAD` early-return on purpose: a response to `HEAD`
        // is complete at its field section (RFC 9112 §6.3), so the connection is
        // reusable in both cases.
        self.stream_ended = true;
        if (self.method == .HEAD) return;
        if (self.stream != null and self.io != null) {
            var write_buf: [16]u8 = undefined;
            var w = sockread.BoundedWriter.init(self.stream.?, &write_buf, self.write_timeout_ms);
            try w.write("0\r\n\r\n");
            try w.flush();
            return;
        }
        try self.response_body.appendSlice(self.allocator, "0\r\n\r\n");
    }

    /// Set JSON response
    pub fn json(self: *Context, status: u16, data: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        try self.response_body.appendSlice(self.allocator, data);
        self.responded = true;
    }

    /// Set plain text response
    pub fn text(self: *Context, status: u16, data: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "text/plain");
        try self.response_body.appendSlice(self.allocator, data);
        self.responded = true;
    }

    /// Set HTML response
    pub fn html(self: *Context, status: u16, data: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "text/html; charset=utf-8");
        try self.response_body.appendSlice(self.allocator, data);
        self.responded = true;
    }

    /// Send an error response.
    ///
    /// Honours the process-wide `error_renderer` when one is installed
    /// (`setErrorRenderer` / `http.useRfc7807Errors`), so framework-internal
    /// rejections — moduleGate, CSRF, the uncaught-handler 500, static-file
    /// errors — take the application's error shape. With no renderer the legacy
    /// `{"code":status,"msg":…,"data":null}` envelope is emitted.
    pub fn sendError(self: *Context, status: u16, message: []const u8) !void {
        if (error_renderer) |render| return render(self, status, message);
        return self.sendErrorEnvelope(status, status, message);
    }

    /// Send a structured error response. Passing `null` for `code` is
    /// equivalent to `sendError`: with no renderer the envelope code falls
    /// back to the HTTP `status`. An independent business `code` is only
    /// visible in the legacy `{code,msg,data}` envelope (under a custom
    /// `error_renderer` it is not representable — RFC 7807 has no business
    /// code — and is dropped, while the HTTP `status` is always preserved),
    /// so prefer `null` or `sendError` in new code.
    pub fn sendErrorResponse(self: *Context, status: u16, code: ?i32, message: []const u8) !void {
        if (error_renderer) |render| return render(self, status, message);
        return self.sendErrorEnvelope(status, code orelse status, message);
    }

    /// Write the legacy envelope directly, bypassing any installed renderer.
    /// This is the fallback body and the escape hatch for a caller that wants
    /// the envelope on one response while the process default is ProblemDetails.
    /// It never consults `error_renderer`, so a renderer may delegate here
    /// without recursing.
    pub fn sendErrorEnvelope(self: *Context, status: u16, code: i32, message: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        const msg_json = try std.json.Stringify.valueAlloc(self.allocator, message, .{});
        defer self.allocator.free(msg_json);
        const err_json = try self.allocator.print("{{\"code\":{d},\"msg\":{s},\"data\":null}}", .{ code, msg_json });
        defer self.allocator.free(err_json);
        try self.response_body.appendSlice(self.allocator, err_json);
        self.responded = true;
    }

    /// Send success response with CommonResult wrapper: {"code":0,"msg":"","data":<data>}
    /// DEPRECATED: use ctx.json(200, data) instead.
    pub fn sendSuccess(self: *Context, data_json: []const u8) !void {
        self.status_code = 200;
        try self.setHeader("Content-Type", "application/json");
        const wrapped = try self.allocator.print("{{\"code\":0,\"msg\":\"\",\"data\":{s}}}", .{data_json});
        defer self.allocator.free(wrapped);
        try self.response_body.appendSlice(self.allocator, wrapped);
        self.responded = true;
    }

    /// Send fail response with CommonResult wrapper: {"code":<code>,"msg":"<msg>","data":null}
    /// DEPRECATED: use ctx.json(status, body) instead.
    pub fn sendFail(self: *Context, code: u16, msg: []const u8) !void {
        self.status_code = 200;
        try self.setHeader("Content-Type", "application/json");
        const wrapped = try self.allocator.print("{{\"code\":{d},\"msg\":\"{s}\",\"data\":null}}", .{ code, msg });
        defer self.allocator.free(wrapped);
        try self.response_body.appendSlice(self.allocator, wrapped);
        self.responded = true;
    }

    /// Send paginated response with CommonResult wrapper:
    /// {"code":0,"msg":"","data":{"list":<items>,"total":<total>}}
    /// DEPRECATED: use ctx.json(200, body) with pagination struct instead.
    pub fn sendPageResult(self: *Context, items_json: []const u8, total: usize) !void {
        self.status_code = 200;
        try self.setHeader("Content-Type", "application/json");
        const wrapped = try self.allocator.print("{{\"code\":0,\"msg\":\"\",\"data\":{{\"list\":{s},\"total\":{d}}}}}", .{ items_json, total });
        defer self.allocator.free(wrapped);
        try self.response_body.appendSlice(self.allocator, wrapped);
        self.responded = true;
    }

    /// Convenience: serialize any Zig value as JSON array and wrap in page result.
    /// Usage: try ctx.sendPageItems(vo_slice.items, total);
    pub fn sendPageItems(self: *Context, items: anytype, total: usize) !void {
        const json_str = try self.allocator.print("{any}", .{std.json.fmt(items, .{})});
        defer self.allocator.free(json_str);
        try self.sendPageResult(json_str, total);
    }

    /// Convenience: serialize any Zig value as JSON and wrap in success response.
    /// Usage: try ctx.sendJsonItems(vo_slice.items);
    /// DEPRECATED: use ctx.json(200, ...) instead.
    pub fn sendJsonItems(self: *Context, items: anytype) !void {
        const json_str = try self.allocator.print("{any}", .{std.json.fmt(items, .{})});
        defer self.allocator.free(json_str);
        try self.sendSuccess(json_str);
    }

    /// Parse JSON body into type T. Deep-copies string fields so the
    /// returned value owns its memory (avoids use-after-free from arena).
    pub fn bindJson(self: *const Context, comptime T: type) !T {
        if (self.body == null) return error.NoBody;
        var parsed = std.json.parseFromSlice(T, self.allocator, self.body.?, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.err("bindJson({s}) failed: {s} body_len={d}", .{ @typeName(T), @errorName(err), self.body.?.len });
            return error.InvalidJson;
        };
        defer parsed.deinit();
        return try deepCopy(parsed.value, self.allocator);
    }

    /// Loose JSON binding: field names match either snake_case or camelCase
    /// (`user_name` ↔ `userName`), `null` values are treated as absent
    /// (field keeps its declared default), and missing fields keep their
    /// declared defaults (only fields without defaults are zeroed).
    /// This is the escape hatch for clients that send camelCase JSON or
    /// `"id": null` for create requests — std.json's strict binding would
    /// reject both (MissingField / type error).
    ///
    /// Ownership: every slice field in the returned value is owned by the
    /// context allocator — declared defaults are deep-copied too, so callers
    /// can free uniformly.
    pub fn bindJsonLoose(self: *const Context, comptime T: type) !T {
        if (self.body == null) return error.NoBody;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, self.body.?, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.err("bindJsonLoose({s}) failed: {s}", .{ @typeName(T), @errorName(err) });
            return error.InvalidJson;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJson;

        // Pass 1: zero-init + fill matched fields (deep-copied, owned).
        // Pass 2: unmatched fields with declared defaults get the default
        // (deep-copied too, so every slice field is uniformly owned).
        const s = @typeInfo(T).@"struct";
        var result: T = undefined;
        var filled: [s.field_names.len]bool = undefined;
        inline for (s.field_names, s.field_types, 0..) |fname, F, i| {
            filled[i] = false;
            @field(result, fname) = std.mem.zeroes(F);
            if (findLooseField(parsed.value.object, fname)) |matched| {
                if (matched != .null) { // null → keep declared default
                    var field_parsed = std.json.parseFromValue(F, self.allocator, matched, .{}) catch |err| {
                        std.log.err("bindJsonLoose({s}) field '{s}': {s}", .{ @typeName(T), fname, @errorName(err) });
                        return error.InvalidJson;
                    };
                    defer field_parsed.deinit();
                    @field(result, fname) = try deepCopy(field_parsed.value, self.allocator);
                    filled[i] = true;
                }
            }
        }
        inline for (s.field_names, s.field_types, s.field_attrs, 0..) |fname, F, attrs, i| {
            if (!filled[i]) {
                if (attrs.defaultValue(F)) |d| {
                    @field(result, fname) = try deepCopy(d, self.allocator);
                }
            }
        }
        return result;
    }

    /// Parse a `multipart/form-data` body (file uploads + mixed forms).
    /// The returned `Form` owns its parts — `defer form.deinit()`.
    /// Parse a `multipart/form-data` body. Size limits live in
    /// `Multipart.Config`, but the **first** gate is the server's body limit:
    /// `Server.Config.max_body_size` (default 8 MB) already rejected the request
    /// while reading it, so a `Config` larger than that can never fire. Keep the
    /// pair consistent with `Multipart.Config.forBodyLimit`.
    pub fn multipart(self: *const Context, config: Multipart.Config) Multipart.Error!Multipart.Form {
        const body = self.body orelse return Multipart.Error.NotMultipart;
        const ctype = self.headers.get("content-type") orelse return Multipart.Error.NotMultipart;
        return Multipart.parse(self.allocator, body, ctype, config);
    }

    /// Bind the **text** parts of a multipart form into a struct, with the same
    /// contract as `bindForm` (loose field names, defaults preserved, owned
    /// strings). File parts are reached via `Form.file(name)`.
    pub fn bindMultipart(self: *const Context, comptime T: type, config: Multipart.Config) !T {
        var form = try self.multipart(config);
        defer form.deinit();
        var params = Params.init(self.allocator);
        defer params.deinit();
        for (form.parts.items) |part| {
            if (part.filename != null) continue; // files are reached via Form.file
            try params.put(part.name, part.data);
        }
        return bindStringMap(T, params, self.allocator);
    }

    /// Every value for `name` in the query string (repeated keys), arrival order.
    pub fn queryValues(self: *const Context, name: []const u8) []const []const u8 {
        return self.query.getAll(name);
    }

    /// Every value for `name` in the form body.
    pub fn formValues(self: *const Context, name: []const u8) []const []const u8 {
        const f = self.form orelse return &.{};
        return f.getAll(name);
    }

    /// Bracket/repeated-key array read (`role_id[0]`, `role_id[]`, `a=1&a=2`).
    /// Caller frees the returned slice.
    pub fn formArray(self: *const Context, allocator: std.mem.Allocator, name: []const u8) ![][]const u8 {
        const f = self.form orelse return allocator.alloc([]const u8, 0);
        return f.getArray(allocator, name);
    }

    pub fn queryArray(self: *const Context, allocator: std.mem.Allocator, name: []const u8) ![][]const u8 {
        return self.query.getArray(allocator, name);
    }

    /// Nested/dotted lookup into form then query (`filter.tags` →
    /// `filter[tags]`, literal key tried first).
    ///
    /// Renamed from `paramPath`, which read like a *path parameter* but has
    /// nothing to do with route placeholders — that confusion is the reason
    /// `paramPath` is now a deprecated alias.
    pub fn nestedParam(self: *const Context, path: []const u8) ?[]const u8 {
        if (self.form) |f| {
            if (f.getPath(path)) |v| return v;
        }
        return self.query.getPath(path);
    }

    /// DEPRECATED: use `nestedParam`. Same behaviour; the name suggested a route
    /// path parameter, which it is not.
    pub fn paramPath(self: *const Context, path: []const u8) ?[]const u8 {
        return self.nestedParam(path);
    }

    /// Bind `application/x-www-form-urlencoded` into a struct. Field lookup is
    /// loose like `bindJsonLoose` (exact name, or camelCase/snake_case
    /// equivalent), absent optionals stay null, and a field with a declared
    /// default keeps it — so a form handler stops hand-rolling `getPara`.
    ///
    /// Supported field types: `[]const u8`/`[]u8`, integers, floats, `bool`
    /// (`1/0/true/false/on/off`), and their `?T` forms. Anything else is a
    /// compile error — add the type deliberately rather than silently ignoring
    /// the field.
    pub fn bindForm(self: *const Context, comptime T: type) !T {
        const form = self.form orelse return error.NoFormBody;
        return bindStringMap(T, form, self.allocator);
    }

    /// Bind the query string into a struct. Same contract as `bindForm`.
    pub fn bindQuery(self: *const Context, comptime T: type) !T {
        return bindStringMap(T, self.query, self.allocator);
    }

    /// Alias of `jsonStruct` for discoverability: any Zig value
    /// (struct / optional / slice / array / int / float / bool / json.Value)
    /// → JSON response. Prefer this name when asking "how do I send a value?"
    pub fn jsonValue(self: *Context, status: u16, value: anytype) !void {
        return self.jsonStruct(status, value);
    }

    /// Send JSON from struct.
    ///
    /// The value is serialized straight into `response_body` through an
    /// allocating writer (`Allocating.fromArrayList`), so the body is built
    /// once. Serializing into a temporary slice and appending it copied every
    /// byte of every JSON response twice.
    pub fn jsonStruct(self: *Context, status: u16, value: anytype) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.response_body);
        // Hand the list back on failure too: `aw` owns it while it is alive.
        errdefer self.response_body = aw.toArrayList();
        try std.json.Stringify.value(value, .{}, &aw.writer);
        self.response_body = aw.toArrayList();
        self.responded = true;
    }

    /// Auto-bind request parameters into a struct.
    /// `sources` maps struct field names to their HTTP source locations.
    /// Example: `const req = try ctx.parseReq(MyReq, .{ .id = .path, .page = .query });`
    pub fn parseReq(self: *Context, comptime T: type, sources: anytype) !T {
        const SourcesType = @TypeOf(sources);
        const sources_info = @typeInfo(SourcesType);
        if (sources_info != .@"struct") @compileError("sources must be a struct literal");

        var req: T = undefined;
        const t_info = @typeInfo(T);
        if (t_info != .@"struct") @compileError("T must be a struct");

        inline for (t_info.@"struct".field_names, t_info.@"struct".field_types) |field_name, field_typ| {
            const has_source = @hasField(SourcesType, field_name);
            if (!has_source) continue;

            const source: FieldSource = @field(sources, field_name);
            const value_str: ?[]const u8 = switch (source) {
                .path => self.params.get(field_name),
                .query => self.query.get(field_name),
                .form => if (self.form) |f| f.get(field_name) else null,
                .header => self.headers.get(field_name),
            };

            if (value_str) |v| {
                @field(req, field_name) = try parseValue(field_typ, v);
            } else {
                // If field is optional, leave as null
                if (@typeInfo(field_typ) == .optional) {
                    @field(req, field_name) = null;
                } else {
                    return error.MissingParameter;
                }
            }
        }

        return req;
    }
};

fn parseValue(comptime T: type, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, value, 10),
        .float => std.fmt.parseFloat(T, value),
        .bool => std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"),
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) value else @compileError("Unsupported slice type in parseValue"),
            else => @compileError("Unsupported pointer type in parseValue"),
        },
        .optional => |opt| if (value.len == 0) null else try parseValue(opt.child, value),
        else => @compileError("Unsupported field type in parseValue"),
    };
}

pub fn isTchar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub const max_response_header_value_bytes = 8 * 1024;

pub const response_head_buffer_bytes = max_response_header_value_bytes + 1024;

pub fn validateResponseField(name: []const u8, value: []const u8) !void {
    if (name.len == 0) return error.InvalidHeader;
    for (name) |c| {
        if (!isTchar(c)) return error.InvalidHeader;
    }
    if (value.len > max_response_header_value_bytes) return error.HeaderTooLarge;
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return error.InvalidHeader;
    }
}

pub fn headerLookup(headers: std.StringHashMap([]const u8), key: []const u8) ?[]const u8 {
    if (headers.get(key)) |value| return value;
    var it = headers.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, key)) return entry.value_ptr.*;
    }
    return null;
}

pub fn getStatusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

fn namesEquivalent(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] == '_') {
            i += 1;
            continue;
        }
        if (b[j] == '_') {
            j += 1;
            continue;
        }
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
    while (i < a.len and a[i] == '_') i += 1;
    while (j < b.len and b[j] == '_') j += 1;
    return i == a.len and j == b.len;
}

fn bindStringMap(comptime T: type, params: Params, allocator: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("bindForm/bindQuery expect a struct type, got " ++ @typeName(T));

    var result: T = undefined;
    inline for (info.@"struct".field_names, info.@"struct".field_types, info.@"struct".field_attrs) |fname, F, attrs| {
        const raw = lookupLoose(params, fname);
        const finfo = @typeInfo(F);
        const is_opt = finfo == .optional;
        const Base = if (is_opt) finfo.optional.child else F;

        if (raw) |text| {
            @field(result, fname) = try parseFieldString(Base, fname, text, allocator);
        } else if (comptime is_opt) {
            @field(result, fname) = null;
        } else if (attrs.defaultValue(F)) |d| {
            @field(result, fname) = d;
        } else {
            return error.MissingField;
        }
    }
    return result;
}

fn parseFieldString(comptime Base: type, comptime fname: []const u8, text: []const u8, allocator: std.mem.Allocator) !Base {
    return switch (@typeInfo(Base)) {
        .pointer => |ptr| blk: {
            if (ptr.size != .slice or ptr.child != u8) {
                @compileError("bindForm/bindQuery: unsupported field type for '" ++ fname ++ "': " ++ @typeName(Base));
            }
            break :blk try allocator.dupe(u8, text);
        },
        .int => std.fmt.parseInt(Base, text, 10) catch error.InvalidField,
        .float => std.fmt.parseFloat(Base, text) catch error.InvalidField,
        .bool => parseBoolLoose(text) orelse error.InvalidField,
        else => @compileError("bindForm/bindQuery: unsupported field type for '" ++ fname ++ "': " ++ @typeName(Base)),
    };
}

fn lookupLoose(params: Params, fname: []const u8) ?[]const u8 {
    if (params.get(fname)) |v| return v;
    var it = params.map.iterator();
    while (it.next()) |e| {
        if (namesEquivalent(e.key_ptr.*, fname)) return e.value_ptr.items[e.value_ptr.items.len - 1];
    }
    // Nested key (`role_id[0]`, `params[balance][money]`): bind the first
    // element to the scalar field. Browsers/`qs` send exactly this shape, and
    // the parse layer already decoded it (`role_id%5B0%5D` → `role_id[0]`).
    // Other indices / repeated keys are read explicitly from the map.
    var nested: ?[]const u8 = null;
    var it2 = params.map.iterator();
    while (it2.next()) |e| {
        const key = e.key_ptr.*;
        if (key.len > fname.len and key[fname.len] == '[' and
            std.mem.startsWith(u8, key, fname))
        {
            if (nested == null or std.mem.order(u8, key, nested.?) == .lt) nested = key;
        }
    }
    if (nested) |k| return params.get(k);
    return null;
}

fn parseBoolLoose(text: []const u8) ?bool {
    if (text.len == 0) return false;
    if (std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "on") or std.ascii.eqlIgnoreCase(text, "yes")) return true;
    if (std.mem.eql(u8, text, "0") or std.ascii.eqlIgnoreCase(text, "false") or std.ascii.eqlIgnoreCase(text, "off") or std.ascii.eqlIgnoreCase(text, "no")) return false;
    return null;
}

fn findLooseField(obj: std.json.ObjectMap, fname: []const u8) ?std.json.Value {
    var it = obj.iterator();
    while (it.next()) |e| {
        if (namesEquivalent(e.key_ptr.*, fname)) return e.value_ptr.*;
    }
    return null;
}

pub fn deepCopy(value: anytype, allocator: std.mem.Allocator) !@TypeOf(value) {
    const T = @TypeOf(value);
    if (comptime T == []const u8 or T == []u8) {
        return allocator.dupe(u8, value);
    }
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            var copy: T = undefined;
            inline for (s.field_names) |f_name| {
                @field(copy, f_name) = try deepCopy(@field(value, f_name), allocator);
            }
            return copy;
        },
        .optional => {
            if (value) |v| return try deepCopy(v, allocator);
            return null;
        },
        .array => {
            var copy: T = undefined;
            for (value, 0..) |elem, i| {
                copy[i] = try deepCopy(elem, allocator);
            }
            return copy;
        },
        .pointer => |p| {
            if (p.child == u8) {
                return allocator.dupe(u8, value);
            }
            // Slices of non-u8 (e.g. []struct, [][]const u8) must be deep-copied:
            // the source points into the (freed) JSON parse buffer.
            if (p.size == .slice) {
                const Child = p.child;
                var copy = try allocator.alloc(Child, value.len);
                for (value, 0..) |elem, i| {
                    copy[i] = try deepCopy(elem, allocator);
                }
                return copy;
            }
            return value;
        },
        else => return value,
    }
}
