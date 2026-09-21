//! HTTP API server for ZigModu
//!
//! Provides HTTP server with routing, middleware, and handlers.
//! Aligned with go-zero's rest package.
//!
//! STRUCTURE (monolith — intentionally NOT split; see docs/PRODUCTION_ROADMAP.md):
//!   §1  Method / Route / RouteGroup / WS callbacks —— routing declarations, middleware and listener types
//!   §2  Process-wide error renderers —— setErrorRenderer / setTransportErrorRenderer and the transport body
//!   §3  Context —— request/response, arena, bindJson, streaming and parameter helpers
//!   §4  HTTP/1.1 parsing —— StreamReader, RequestParser, ParsedRequest and header deadlines
//!   §5  TrieNode / Router / RouteInfo —— route matching, wildcards, params, listRoutes
//!   §6  Server & response writers —— status text, raw writes, listen, graceful drain
//!   §7  connFiber —— per-connection lifecycle, WS upgrade, backpressure, write timeout
//!   §8  Middleware runner & struct binding —— runMiddlewareChain, Request/Response/Json, deepCopy
//!   §9  Tests —— routing / middleware / WS / binding / backpressure unit and integration tests
//!
//! Every section carries a matching `// ==== §N ... ====` anchor — `grep "§5"` jumps there.
//!
//! MAINTENANCE:
//!   - New middleware kinds → src/api/Middleware.zig (not here).
//!   - No SQL, tenant, or JWT logic in this file.
//!   - PathRewriter: path rewrite only, no business routes.
//!   - One PR per § block when possible; Context/connFiber changes need Middleware tests too.

const std = @import("std");
const PanicHook = @import("PanicHook.zig");
const WsFramer = @import("../im/WsFramer.zig").WsFramer;
const BufferPool = @import("../im/BufferPool.zig").BufferPool;
const WsUring = @import("../im/ws_uring.zig").WsUring;
const Http2Server = @import("../http/Http2Server.zig");
const Http2 = @import("../http/Http2.zig");
const Http2Tls = @import("../http/Http2Tls.zig");
const Hpack = @import("../http/Hpack.zig");
const GrpcServiceRegistry = @import("../extensions/GrpcTransport.zig").GrpcServiceRegistry;
const Rbac = @import("../security/Rbac.zig");
const Time = @import("../core/Time.zig");
const sockread = @import("../core/sockread.zig");
const sqlx = @import("../sqlx/sqlx.zig");
const ModuleLogger = @import("../log/ModuleLogger.zig").ModuleLogger;

// ==== §1  Method / Route / RouteGroup / WS callbacks ====

/// HTTP method
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

/// Route group helper to prefix paths.
pub const RouteGroup = struct {
    server: *Server,
    prefix: []const u8,
    /// Scope-local middleware applied to routes registered through this group.
    middleware: []const Middleware = &.{},

    pub fn init(server: *Server, prefix: []const u8) RouteGroup {
        return .{ .server = server, .prefix = prefix };
    }

    /// Append scope-local middleware (allocates on server; freed in Server.deinit).
    pub fn use(self: RouteGroup, mw: Middleware) !RouteGroup {
        const extended = try self.server.allocator.alloc(Middleware, self.middleware.len + 1);
        @memcpy(extended[0..self.middleware.len], self.middleware);
        extended[self.middleware.len] = mw;
        try self.server.owned_route_mw.append(self.server.allocator, extended);
        return .{
            .server = self.server,
            .prefix = self.prefix,
            .middleware = extended,
        };
    }

    fn joinPath(self: *const RouteGroup, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const pfx = std.mem.trim(u8, self.prefix, "/");
        const rel = std.mem.trim(u8, path, "/");
        if (pfx.len == 0) return allocator.dupe(u8, rel);
        if (rel.len == 0) return allocator.dupe(u8, pfx);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ pfx, rel });
    }

    fn add(self: *RouteGroup, method: Method, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        const full_path = try self.joinPath(self.server.allocator, path);
        defer self.server.allocator.free(full_path);

        try self.server.addRoute(.{
            .method = method,
            .path = full_path,
            .handler = handler,
            .middleware = self.middleware,
            .user_data = user_data,
        });
    }

    pub fn get(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.GET, path, handler, user_data);
    }
    pub fn post(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.POST, path, handler, user_data);
    }
    pub fn put(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.PUT, path, handler, user_data);
    }
    pub fn delete(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.DELETE, path, handler, user_data);
    }
    pub fn patch(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.PATCH, path, handler, user_data);
    }
    pub fn head(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.HEAD, path, handler, user_data);
    }
    pub fn options(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.OPTIONS, path, handler, user_data);
    }

    /// Register a WebSocket upgrade endpoint.
    /// on_connect is called after successful handshake (user_data = route user_data).
    /// on_message is called for each **text (0x1) or binary (0x2)** data frame.
    /// on_close is called when the connection closes.
    pub fn ws(self: *RouteGroup, path: []const u8, on_connect: WsConnectFn, on_message: WsMessageFn, on_close: WsCloseFn, user_data: ?*anyopaque) !void {
        const full_path = try self.joinPath(self.server.allocator, path);
        defer self.server.allocator.free(full_path);

        const norm_path = if (full_path.len > 0 and full_path[0] == '/') full_path[1..] else full_path;
        const dup_path = try self.server.allocator.dupe(u8, norm_path);
        try self.server.ws_handlers.put(dup_path, .{
            .on_connect = on_connect,
            .on_message = on_message,
            .on_close = on_close,
            .user_data = user_data,
        });
    }
};

/// WebSocket connect callback: called after successful handshake.
/// Return session pointer (non-null accepts, null rejects).
/// The session is opaque to the server; the gateway owns its lifetime.
pub const WsConnectFn = *const fn (ctx: *Context, framer: *anyopaque) ?*anyopaque;

pub const WsFrameKind = @import("../im/WsFramer.zig").WsFrameKind;

/// WebSocket message callback: text (0x1) and binary (0x2) data frames.
/// `msg` is raw payload bytes (UTF-8 for text; opaque for binary, e.g. protobuf).
pub const WsMessageFn = *const fn (session: ?*anyopaque, msg: []const u8, kind: WsFrameKind) void;
/// WebSocket close callback: called when the connection closes.
pub const WsCloseFn = *const fn (session: ?*anyopaque) void;

pub const WsRoute = struct {
    on_connect: WsConnectFn,
    on_message: WsMessageFn,
    on_close: WsCloseFn,
    user_data: ?*anyopaque,
};

/// Field source for auto parameter binding
/// Canonical request identity, written by auth middleware
/// (`jwtAuthFromCatalog*`, `authFromCatalog`) as context attrs.
/// Handlers read it via the typed getters (`userId`, `requireUserId`, …)
/// instead of raw `getAttr("user_id")` strings.
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

// ==== §3  Context ====

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
    upgraded: bool = false,
    /// Envelope dialect used by `ok` / `fail` / `unauth` / `paginated`.
    envelope: EnvelopeDialect = .default,
    /// Absolute deadline (monotonic ms) for this request, from
    /// `Server.Config.request_timeout_ms`. `null` = unbounded.
    ///
    /// This is a **budget**, not a kill switch: wiring it into storage is what
    /// stops a slow request from holding a pool connection after the client has
    /// already given up. `ctx.sqlContext()` is the one-line bridge.
    deadline_ms: ?i64 = null,

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
    pub fn setHeader(self: *Context, key: []const u8, value: []const u8) !void {
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
        const body = try std.fmt.allocPrint(self.allocator, "{{\"code\":{d},\"msg\":{s},\"data\":{s}}}", .{ code, msg_json, data_json });
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
                const data = try std.fmt.allocPrint(self.allocator, "{{\"list\":{s},\"total\":{d}}}", .{ items_json, total });
                defer self.allocator.free(data);
                try self.respondEnvelope(200, code, msg, data);
            },
            .ruoyi => {
                const body = try std.fmt.allocPrint(self.allocator, "{{\"code\":0,\"msg\":\"success\",\"rows\":{s},\"total\":{d}}}", .{ items_json, total });
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
    pub fn startChunked(self: *Context, status: u16, content_type: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Transfer-Encoding", "chunked");
        try self.setHeader("Content-Type", content_type);
        self.responded = true;
        self.streaming = true;
        // Flush status line + headers to socket immediately
        if (self.stream != null and self.io != null) {
            try self.flushHeadersToSocket();
        }
    }

    /// Write status line + headers directly to socket (for streamed responses).
    fn flushHeadersToSocket(self: *Context) !void {
        var write_buf: [4096]u8 = undefined;
        var w = self.stream.?.writer(self.io.?, &write_buf);
        var line_buf: [256]u8 = undefined;
        const status_text = getStatusText(self.status_code);
        const status_line = try std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} {s}\r\n", .{ self.status_code, status_text });
        try w.interface.writeAll(status_line);
        var hiter = self.response_headers.iterator();
        while (hiter.next()) |entry| {
            const header_line = try std.fmt.bufPrint(&line_buf, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            try w.interface.writeAll(header_line);
        }
        try w.interface.writeAll("\r\n");
        try w.interface.flush();
    }

    /// Write a chunk in chunked transfer encoding.
    /// Writes directly to socket when streaming, falls back to response_body buffer.
    pub fn writeChunk(self: *Context, data: []const u8) !void {
        if (self.stream != null and self.io != null) {
            var write_buf: [4096]u8 = undefined;
            var w = self.stream.?.writer(self.io.?, &write_buf);
            var size_buf: [32]u8 = undefined;
            const size_hex = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len});
            try w.interface.writeAll(size_hex);
            try w.interface.writeAll(data);
            try w.interface.writeAll("\r\n");
            try w.interface.flush();
            return;
        }
        const chunk_header = try std.fmt.allocPrint(self.allocator, "{x}\r\n", .{data.len});
        defer self.allocator.free(chunk_header);
        try self.response_body.appendSlice(self.allocator, chunk_header);
        try self.response_body.appendSlice(self.allocator, data);
        try self.response_body.appendSlice(self.allocator, "\r\n");
    }

    /// End chunked transfer encoding.
    /// Writes directly to socket when streaming, falls back to response_body buffer.
    pub fn endStream(self: *Context) !void {
        if (self.stream != null and self.io != null) {
            var write_buf: [4096]u8 = undefined;
            var w = self.stream.?.writer(self.io.?, &write_buf);
            try w.interface.writeAll("0\r\n\r\n");
            try w.interface.flush();
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

    /// Send a structured error response. Under a custom `error_renderer` the
    /// `code` argument is not representable (RFC 7807 has no business code) and
    /// is dropped; the HTTP `status` is always preserved.
    pub fn sendErrorResponse(self: *Context, status: u16, code: i32, message: []const u8) !void {
        if (error_renderer) |render| return render(self, status, message);
        return self.sendErrorEnvelope(status, code, message);
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
        const err_json = try std.fmt.allocPrint(self.allocator, "{{\"code\":{d},\"msg\":{s},\"data\":null}}", .{ code, msg_json });
        defer self.allocator.free(err_json);
        try self.response_body.appendSlice(self.allocator, err_json);
        self.responded = true;
    }

    /// Send success response with CommonResult wrapper: {"code":0,"msg":"","data":<data>}
    /// DEPRECATED: use ctx.json(200, data) instead.
    pub fn sendSuccess(self: *Context, data_json: []const u8) !void {
        self.status_code = 200;
        try self.setHeader("Content-Type", "application/json");
        const wrapped = try std.fmt.allocPrint(self.allocator, "{{\"code\":0,\"msg\":\"\",\"data\":{s}}}", .{data_json});
        defer self.allocator.free(wrapped);
        try self.response_body.appendSlice(self.allocator, wrapped);
        self.responded = true;
    }

    /// Send fail response with CommonResult wrapper: {"code":<code>,"msg":"<msg>","data":null}
    /// DEPRECATED: use ctx.json(status, body) instead.
    pub fn sendFail(self: *Context, code: u16, msg: []const u8) !void {
        self.status_code = 200;
        try self.setHeader("Content-Type", "application/json");
        const wrapped = try std.fmt.allocPrint(self.allocator, "{{\"code\":{d},\"msg\":\"{s}\",\"data\":null}}", .{ code, msg });
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
        const wrapped = try std.fmt.allocPrint(self.allocator, "{{\"code\":0,\"msg\":\"\",\"data\":{{\"list\":{s},\"total\":{d}}}}}", .{ items_json, total });
        defer self.allocator.free(wrapped);
        try self.response_body.appendSlice(self.allocator, wrapped);
        self.responded = true;
    }

    /// Convenience: serialize any Zig value as JSON array and wrap in page result.
    /// Usage: try ctx.sendPageItems(vo_slice.items, total);
    pub fn sendPageItems(self: *Context, items: anytype, total: usize) !void {
        const json_str = try std.fmt.allocPrint(self.allocator, "{any}", .{std.json.fmt(items, .{})});
        defer self.allocator.free(json_str);
        try self.sendPageResult(json_str, total);
    }

    /// Convenience: serialize any Zig value as JSON and wrap in success response.
    /// Usage: try ctx.sendJsonItems(vo_slice.items);
    /// DEPRECATED: use ctx.json(200, ...) instead.
    pub fn sendJsonItems(self: *Context, items: anytype) !void {
        const json_str = try std.fmt.allocPrint(self.allocator, "{any}", .{std.json.fmt(items, .{})});
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
    pub fn jsonStruct(self: *Context, status: u16, value: anytype) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(json_str);
        try self.response_body.appendSlice(self.allocator, json_str);
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

/// Parse `a=1&b=%20&role_id%5B0%5D=7` into `params`: keys and values are
/// percent-decoded, repeated names accumulate, bracket keys are kept verbatim
/// so `getArray`/`getPath` can interpret them. Enforces `max_params`
/// occurrences.
///
/// Public so `http.Testkit` drives the *same* parser instead of keeping a twin
/// copy in sync by hand.
pub fn parseQueryInto(params: *Params, raw_query: []const u8, allocator: std.mem.Allocator, max_params: usize) !void {
    var it = std.mem.splitScalar(u8, raw_query, '&');
    while (it.next()) |param| {
        if (param.len == 0) continue;
        const eq_pos = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        if (params.totalValues() >= max_params) return error.TooManyParams;
        const key = try percentDecode(allocator, param[0..eq_pos]);
        const value = try percentDecode(allocator, param[eq_pos + 1 ..]);
        params.putOwned(key, value) catch |err| {
            allocator.free(key);
            allocator.free(value);
            return err;
        };
    }
}

fn parseFormBody(allocator: std.mem.Allocator, body: []const u8, max_params: usize) !Params {
    var form = Params.init(allocator);
    errdefer form.deinit();

    var iter = std.mem.splitScalar(u8, body, '&');
    while (iter.next()) |param| {
        if (param.len == 0) continue;
        if (std.mem.indexOf(u8, param, "=")) |eq_pos| {
            // Same decoding contract as the query string: keys AND values are
            // percent-decoded (with `+` → space) at parse time. Browsers/`qs`
            // encode nested keys (`role_id[0]` → `role_id%5B0%5D`), so a raw key
            // could never be found via `formValue("role_id[0]")`, and a raw
            // value meant `formValue("name")` returned `%E5%BC%A0%E4%B8%89`
            // instead of `张三`.
            if (form.totalValues() >= max_params) return error.TooManyParams;
            const key = try percentDecode(allocator, param[0..eq_pos]);
            const value = try percentDecode(allocator, param[eq_pos + 1 ..]);
            form.putOwned(key, value) catch |err| {
                allocator.free(key);
                allocator.free(value);
                return err;
            };
        }
    }

    return form;
}

// ==== §4  HTTP/1.1 parsing ====

/// Simple stream reader wrapper for HTTP parsing
/// Persistent buffered reader over a `std.Io.net.Stream`.
///
/// CRITICAL: the underlying `std.Io.net.Stream.Reader` owns an internal buffer.
/// We must keep a single instance across reads — otherwise its buffer state is
/// repeatedly reset and data from previous reads gets clobbered. The buffer is
/// owned by this struct and must be referenced *after* the struct has reached
/// its final memory location, which is why construction is a two-step process:
/// allocate uninitialized storage, then call `setup`.
const StreamReader = struct {
    interface: std.Io.Reader = undefined,
    buffer: [8192]u8 = undefined,
    stream: std.Io.net.Stream = undefined,
    io: std.Io = undefined,
    /// Absolute deadline (`.awake` clock, ns) for the request line + header
    /// phase; null = unbounded. Enforced inside `streamImpl`, so every read
    /// the delimiter scanner performs is covered, not just the first.
    deadline_ns: ?i96 = null,
    /// Set when `deadline_ns` fired, so callers can answer 408 instead of
    /// silently closing.
    timed_out: bool = false,

    fn setup(self: *StreamReader, stream: std.Io.net.Stream, io: std.Io) void {
        self.buffer = undefined;
        self.stream = stream;
        self.io = io;
        self.deadline_ns = null;
        self.timed_out = false;
        // Only `.stream` is implemented; the default `readVec` keeps the
        // buffer bookkeeping (seek/end) in sync.
        self.interface = .{
            .vtable = &.{ .stream = streamImpl },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    /// Bound the header phase: a peer that trickles bytes (slowloris) is cut
    /// off after `timeout_ms`. 0 disables the bound.
    fn setHeaderDeadline(self: *StreamReader, timeout_ms: u32) void {
        self.timed_out = false;
        if (timeout_ms == 0) {
            self.deadline_ns = null;
            return;
        }
        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        self.deadline_ns = now + @as(i96, timeout_ms) * std.time.ns_per_ms;
    }

    /// Headers are in — stop bounding. Bodies/uploads get the looser
    /// `request_timeout_ms` (handler stage) instead.
    fn clearHeaderDeadline(self: *StreamReader) void {
        self.deadline_ns = null;
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *StreamReader = @alignCast(@fieldParentPtr("interface", io_r));
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        const n = try self.readInto(dest);
        io_w.advance(n);
        return n;
    }

    fn readInto(self: *StreamReader, out: []u8) std.Io.Reader.Error!usize {
        if (self.deadline_ns) |deadline| {
            const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
            const remaining_ns = deadline - now;
            if (remaining_ns <= 0) {
                self.timed_out = true;
                return error.ReadFailed;
            }
            const remaining_ms = @divTrunc(remaining_ns, std.time.ns_per_ms) + 1;
            var pfds = [1]std.posix.pollfd{.{
                .fd = self.stream.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&pfds, @intCast(@min(remaining_ms, @as(i96, std.math.maxInt(i32))))) catch return error.ReadFailed;
            if (ready == 0) {
                self.timed_out = true;
                return error.ReadFailed;
            }
            // Raw read: the io `net_read` path can hang on macOS (see
            // core/sockread.zig) and would defeat the deadline.
            const n = std.posix.read(self.stream.socket.handle, out) catch return error.ReadFailed;
            if (n == 0) return error.EndOfStream;
            return n;
        }
        var iovecs = [1][]u8{out};
        const n = self.stream.read(self.io, &iovecs) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        return n;
    }

    /// Reads a single line terminated by `delimiter`. Returns a slice into the
    /// reader's internal buffer, valid only until the next read operation. The
    /// caller must copy any data that needs to outlive subsequent reads.
    ///
    /// Returns `null` if the peer closed cleanly with no bytes available
    /// (EOF on a fresh read), and propagates `error.ReadFailed` for actual
    /// I/O errors so the caller can distinguish benign close from failure.
    fn readUntilDelimiterOrEof(self: *StreamReader, _: []u8, delimiter: u8) !?[]u8 {
        return self.interface.takeDelimiter(delimiter) catch |err| switch (err) {
            error.ReadFailed => error.ReadFailed,
            error.StreamTooLong => error.InvalidRequest,
        };
    }

    fn readAll(self: *StreamReader, out: []u8) !usize {
        self.interface.readSliceAll(out) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => return 0,
        };
        return out.len;
    }
};

/// HTTP request header limits (header-bomb DoS guard).
pub const HeaderLimits = struct {
    /// Maximum number of header lines accepted per request.
    max_count: usize = 100,
    /// Maximum combined byte size of all header lines.
    max_total_bytes: usize = 16 * 1024,
};

/// A header line split into `field-name` / `field-value` (RFC 9110 §5.1).
const HeaderField = struct {
    name: []const u8,
    value: []const u8,
};

/// `tchar` (RFC 9110 §5.6.2) — the only bytes a `field-name` may contain.
fn isTchar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// Split `field-name ":" OWS field-value OWS`. RFC 9110 §5.6.3 defines OWS as
/// *optional* whitespace, so `Host:x` is a valid header line and must be read,
/// not dropped.
///
/// Returns `null` when the line is not a header field at all (no colon, empty
/// or non-token name, obs-fold continuation line). The caller turns that into a
/// 400: a line one parser drops while the next one honours it is exactly what
/// request smuggling is built from.
fn splitHeaderLine(line: []const u8) ?HeaderField {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const name = line[0..colon];
    if (name.len == 0) return null;
    for (name) |c| {
        if (!isTchar(c)) return null;
    }
    return .{ .name = name, .value = std.mem.trim(u8, line[colon + 1 ..], " \t") };
}

/// `Content-Length = 1*DIGIT` (RFC 9110 §8.6). Rejects the empty value, a
/// sign, a list, and `_` (which Zig's `parseInt` would take as a digit
/// separator, so `1_0` would silently mean 10).
fn parseContentLength(value: []const u8) ?usize {
    if (value.len == 0 or value.len > 20) return null;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(usize, value, 10) catch null;
}

/// Only `HTTP/1.x` reaches this parser: HTTP/2 arrives through the
/// prior-knowledge preface probe in `connFiber`, and a request line that names
/// any other version was written for a different parser.
fn isHttp1Version(version: []const u8) bool {
    return version.len == 8 and std.mem.startsWith(u8, version, "HTTP/1.") and std.ascii.isDigit(version[7]);
}

/// HTTP request parser
const RequestParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RequestParser {
        return .{ .allocator = allocator };
    }

    pub fn trimCrlf(line: []const u8) []const u8 {
        var out = line;
        while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) {
            out = out[0 .. out.len - 1];
        }
        return out;
    }

    /// Continue HTTP/1.1 parse after the request line was already read (H2 preface probe).
    pub fn parseAfterRequestLine(self: *RequestParser, reader: *StreamReader, request_line_raw_view: []const u8, max_body_size: usize, header_limits: HeaderLimits, max_params: usize) !ParsedRequest {
        var buffer: [8192]u8 = undefined;

        const request_line_owned = try self.allocator.dupe(u8, trimCrlf(request_line_raw_view));
        const request_line = request_line_owned;
        if (request_line.len < 14) return error.InvalidRequest; // Minimum: "GET / HTTP/1.1"
        if (request_line[0] == ' ' or request_line[0] == '\t') return error.InvalidRequest;

        // `method SP request-target SP HTTP-version` and nothing else. An extra
        // field means this parser and the next one disagree about where the
        // request line ends — which invents a request nobody sent.
        var fields = std.mem.tokenizeScalar(u8, request_line, ' ');
        const method_str = fields.next() orelse return error.InvalidRequest;
        const raw_path = fields.next() orelse return error.InvalidRequest;
        const version = fields.next() orelse return error.InvalidRequest;
        if (fields.next() != null) return error.InvalidRequest;
        if (!isHttp1Version(version)) return error.InvalidRequest;

        // An unknown method token is refused (501), never folded into GET.
        const method = Method.fromString(method_str) orelse return error.InvalidMethod;

        // Parse query string
        var path = raw_path;
        var query_map = Params.init(self.allocator);
        errdefer query_map.deinit();

        if (std.mem.indexOf(u8, raw_path, "?")) |query_start| {
            path = raw_path[0..query_start];
            const query_str = raw_path[query_start + 1 ..];

            try parseQueryInto(&query_map, query_str, self.allocator, max_params);
        }

        // Parse headers
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        var header_count: usize = 0;
        var header_bytes: usize = 0;
        var content_length: ?usize = null;
        var saw_transfer_encoding = false;
        while (true) {
            const line_raw = try reader.readUntilDelimiterOrEof(&buffer, '\n') orelse return error.InvalidRequest;
            const header_line = trimCrlf(line_raw);
            if (header_line.len == 0) {
                // Request line + headers are in; the body is not bounded by
                // the header deadline.
                reader.clearHeaderDeadline();
                break;
            }

            header_count += 1;
            header_bytes += header_line.len;
            if (header_count > header_limits.max_count) return error.TooManyHeaders;
            if (header_bytes > header_limits.max_total_bytes) return error.TooManyHeaders;

            // Unparsable lines are refused, not skipped: a header this server
            // drops is a header a front-end proxy may still act on.
            const field = splitHeaderLine(header_line) orelse return error.InvalidHeader;
            const key_raw = try self.allocator.dupe(u8, field.name);
            for (key_raw) |*c| c.* = std.ascii.toLower(c.*);
            const value = try self.allocator.dupe(u8, field.value);

            // The body is framed by exactly one header, and this server only
            // implements `Content-Length`. A repeated/unparsable
            // `Content-Length`, or any `Transfer-Encoding`, is refused — the
            // CL/TE smuggling shape is precisely "we ignored one of them".
            if (std.mem.eql(u8, key_raw, "content-length")) {
                if (content_length != null) return error.DuplicateContentLength;
                content_length = parseContentLength(field.value) orelse return error.InvalidContentLength;
            } else if (std.mem.eql(u8, key_raw, "transfer-encoding")) {
                saw_transfer_encoding = true;
            }

            try headers.put(key_raw, value);
        }

        if (saw_transfer_encoding) {
            // No chunked request decoder exists here, so accepting such a
            // request would leave the chunked body in the reader to be served
            // as the next request line. Refuse the message instead.
            if (content_length != null) return error.ConflictingBodyFraming;
            return error.TransferEncodingNotSupported;
        }

        // Read body if Content-Length present
        var body: ?[]const u8 = null;
        if (content_length) |content_len| {
            if (content_len > max_body_size) return error.BodyTooLarge;
            if (content_len > 0) {
                const body_buf = try self.allocator.alloc(u8, content_len);
                const bytes_read = try reader.readAll(body_buf);
                if (bytes_read == content_len) {
                    body = body_buf;
                } else {
                    self.allocator.free(body_buf);
                    return error.IncompleteBody;
                }
            }
        }

        return ParsedRequest{
            .method = method,
            .path = path,
            .raw_path = raw_path,
            .query = query_map,
            .headers = headers,
            .body = body,
            ._request_line_buf = request_line_owned,
        };
    }
};

fn hexVal(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// RFC 3986 percent-decode (query form): `%XX` → byte, `+` → space.
pub fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len and std.ascii.isHex(input[i + 1]) and std.ascii.isHex(input[i + 2])) {
            i += 2;
        }
        out_len += 1;
    }
    const out = try allocator.alloc(u8, out_len);
    i = 0;
    var o: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '%' and i + 2 < input.len and std.ascii.isHex(input[i + 1]) and std.ascii.isHex(input[i + 2])) {
            out[o] = (hexVal(input[i + 1]) << 4) | hexVal(input[i + 2]);
            i += 2;
        } else if (c == '+') {
            out[o] = ' ';
        } else {
            out[o] = c;
        }
        o += 1;
    }
    return out;
}

test "percentDecode decodes query values" {
    const allocator = std.testing.allocator;
    const decoded = try percentDecode(allocator, "100%25off");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("100%off", decoded);

    const spaced = try percentDecode(allocator, "widget+pro");
    defer allocator.free(spaced);
    try std.testing.expectEqualStrings("widget pro", spaced);

    const plain = try percentDecode(allocator, "hello");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("hello", plain);
}

const Multipart = @import("../http/Multipart.zig");
const Params = @import("../http/Params.zig").Params;

const ParsedRequest = struct {
    method: Method,
    path: []const u8,
    raw_path: []const u8,
    query: Params,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,
    /// Owned buffer that path and raw_path slice into.
    /// Freed by deinit() — do not free path/raw_path separately.
    _request_line_buf: []const u8,

    pub fn deinit(self: *ParsedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self._request_line_buf);

        self.query.deinit();

        var headers_iter = self.headers.iterator();
        while (headers_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        if (self.body) |b| allocator.free(b);
        self.* = undefined;
    }
};

// ==== §5  Router ====

/// Trie node for the router
const TrieNode = struct {
    segment: []const u8,
    is_param: bool,
    is_wildcard: bool,
    param_name: ?[]const u8,
    route: ?Route,
    children: std.ArrayList(*TrieNode),
    /// O(1) child lookup map, lazily built when children exceed MAP_THRESHOLD.
    child_map: ?std.StringHashMap(*TrieNode) = null,
    /// Cached pointer to the first param child (at most one per node).
    param_child: ?*TrieNode = null,
    /// Cached pointer to the wildcard child (at most one `*` per node).
    wildcard_child: ?*TrieNode = null,

    const MAP_THRESHOLD: usize = 8;

    pub fn init(allocator: std.mem.Allocator, segment: []const u8) !*TrieNode {
        const node = try allocator.create(TrieNode);
        node.* = .{
            .segment = try allocator.dupe(u8, segment),
            .is_param = std.mem.startsWith(u8, segment, "{"),
            .is_wildcard = std.mem.eql(u8, segment, "*"),
            .param_name = null,
            .route = null,
            .children = std.ArrayList(*TrieNode).empty,
        };
        if (node.is_param) {
            const name = if (std.mem.endsWith(u8, segment, "}"))
                segment[1 .. segment.len - 1]
            else
                segment[1..];
            node.param_name = try allocator.dupe(u8, name);
        }
        return node;
    }

    pub fn deinit(self: *TrieNode, allocator: std.mem.Allocator) void {
        allocator.free(self.segment);
        if (self.param_name) |name| allocator.free(name);
        if (self.route) |route| {
            allocator.free(route.path);
            if (route.combined_middleware.len > 0) allocator.free(route.combined_middleware);
        }
        for (self.children.items) |child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
        if (self.child_map) |*map| {
            map.deinit();
        }
        allocator.destroy(self);
    }

    /// Insert a child and conditionally upgrade to HashMap lookup.
    pub fn addChild(self: *TrieNode, allocator: std.mem.Allocator, child: *TrieNode) !void {
        try self.children.append(allocator, child);

        // Track param child for O(1) access
        if (child.is_param and self.param_child == null) {
            self.param_child = child;
        }
        // Track wildcard child for O(1) access
        if (child.is_wildcard and self.wildcard_child == null) {
            self.wildcard_child = child;
        }

        // Lazy upgrade to HashMap when children cross threshold
        if (self.children.items.len == MAP_THRESHOLD) {
            self.child_map = std.StringHashMap(*TrieNode).init(allocator);
            for (self.children.items) |c| {
                try self.child_map.?.put(c.segment, c);
            }
        } else if (self.child_map) |*map| {
            try map.put(child.segment, child);
        }
    }

    pub fn findChild(self: *const TrieNode, segment: []const u8) ?*TrieNode {
        if (self.child_map) |map| {
            return map.get(segment);
        }
        // Linear scan for small child counts (fast due to cache locality)
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.segment, segment)) return child;
        }
        return null;
    }

    pub fn findParamChild(self: *const TrieNode) ?*TrieNode {
        if (self.param_child) |pc| return pc;
        // Fallback: linear scan (should rarely be reached with addChild tracking)
        for (self.children.items) |child| {
            if (child.is_param) return child;
        }
        return null;
    }
};

/// Canonical form of a stored route path: exactly one leading `/`.
///
/// Callers are inconsistent — `group.get("/health")` carries the slash,
/// `group.get("health")` and every ComptimeRouter mount (`nest` + `spec.path`)
/// do not — but the stored path is what `ctx.route_template` reports and what
/// metrics label on. Two spellings of one route (`health` vs `/health`, and
/// `orders/{id}` vs `/metrics`) mean a dashboard query silently misses half the
/// traffic. Normalise at registration, where the path is already being duped.
///
/// Matching is unaffected: the trie splits on `/` and skips empty segments, so
/// only the node structure routes requests, never this string.
fn normalizeRoutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const trimmed = std.mem.trimStart(u8, path, "/");
    if (trimmed.len == 0) return allocator.dupe(u8, "/");
    return std.fmt.allocPrint(allocator, "/{s}", .{trimmed});
}

/// Router for matching routes using a trie
const Router = struct {
    allocator: std.mem.Allocator,
    roots: std.AutoHashMap(Method, *TrieNode),
    wildcards: std.AutoHashMap(Method, Route),

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .allocator = allocator,
            .roots = std.AutoHashMap(Method, *TrieNode).init(allocator),
            .wildcards = std.AutoHashMap(Method, Route).init(allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        var wc_iter = self.wildcards.iterator();
        while (wc_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.path);
            if (entry.value_ptr.combined_middleware.len > 0) {
                self.allocator.free(entry.value_ptr.combined_middleware);
            }
        }
        self.wildcards.deinit();
        var iter = self.roots.valueIterator();
        while (iter.next()) |root| {
            root.*.deinit(self.allocator);
        }
        self.roots.deinit();
        self.* = undefined;
    }

    pub fn addRoute(self: *Router, route: Route) !void {
        // Wildcard route: catch-all for any path under this method
        if (std.mem.eql(u8, route.path, "*")) {
            const path_copy = try self.allocator.dupe(u8, route.path);
            var r = route;
            r.path = path_copy;
            try self.wildcards.put(route.method, r);
            return;
        }

        const root = try self.getOrCreateRoot(route.method);

        var parts = std.mem.splitScalar(u8, route.path, '/');
        var current = root;

        while (parts.next()) |part| {
            if (part.len == 0) continue;

            if (current.findChild(part)) |child| {
                current = child;
            } else {
                const child = try TrieNode.init(self.allocator, part);
                try current.addChild(self.allocator, child);
                current = child;
            }
        }

        // Store route at the endpoint node
        const path_copy = try normalizeRoutePath(self.allocator, route.path);
        var r = route;
        r.path = path_copy;
        current.route = r;
    }

    fn getOrCreateRoot(self: *Router, method: Method) !*TrieNode {
        if (self.roots.get(method)) |root| return root;
        const root = try TrieNode.init(self.allocator, "");
        try self.roots.put(method, root);
        return root;
    }

    /// Walk the route trie and collect all registered routes as RouteInfo entries (method, path).
    pub fn listRoutes(self: *const Router, alloc: std.mem.Allocator) ![]const RouteInfo {
        var result = std.ArrayList(RouteInfo).empty;

        var method_iter = self.roots.iterator();
        while (method_iter.next()) |entry| {
            const method = entry.key_ptr.*;
            const root = entry.value_ptr.*;
            try collectRoutes(root, method, "", alloc, &result);
        }

        return result.toOwnedSlice(alloc);
    }

    /// PERF: `allocator` should be the per-request arena (connFiber passes
    /// `arena_alloc`) — params map + dupes are bump-allocated and bulk-freed
    /// with the request, so no per-match heap traffic on the hot path.
    pub fn match(self: *const Router, allocator: std.mem.Allocator, method: Method, path: []const u8) ?MatchedRoute {
        const root = self.roots.get(method) orelse return null;

        const MAX_PARAMS = 8;
        var param_keys: [MAX_PARAMS][]const u8 = undefined;
        var param_vals: [MAX_PARAMS][]const u8 = undefined;
        var param_count: usize = 0;

        var parts = std.mem.splitScalar(u8, path, '/');
        var current = root;

        while (parts.next()) |part| {
            if (part.len == 0) continue;

            if (current.findChild(part)) |child| {
                current = child;
            } else if (current.wildcard_child) |wc| {
                // Consume remaining parts into a single rest parameter
                if (wc.route) |route| {
                    var params = std.StringHashMap([]const u8).init(allocator);
                    for (0..param_count) |i| {
                        params.put(param_keys[i], param_vals[i]) catch |err| {
                            std.log.err("[Router] wildcard param put failed: {}", .{err});
                            for (0..param_count) |k| {
                                allocator.free(param_keys[k]);
                                allocator.free(param_vals[k]);
                            }
                            params.deinit();
                            return null;
                        };
                    }
                    return MatchedRoute{ .route = route, .params = params };
                }
                return null;
            } else if (current.findParamChild()) |param_child| {
                if (param_count >= MAX_PARAMS) return null;
                param_keys[param_count] = allocator.dupe(u8, param_child.param_name.?) catch return null;
                errdefer allocator.free(param_keys[param_count]);
                param_vals[param_count] = allocator.dupe(u8, part) catch {
                    allocator.free(param_keys[param_count]);
                    return null;
                };
                param_count += 1;
                current = param_child;
            } else {
                for (0..param_count) |i| {
                    allocator.free(param_keys[i]);
                    allocator.free(param_vals[i]);
                }
                return null;
            }
        }

        // Exact route takes priority over wildcard child
        if (current.route) |route| {
            var params = std.StringHashMap([]const u8).init(allocator);
            for (0..param_count) |i| {
                params.put(param_keys[i], param_vals[i]) catch |err| {
                    std.log.err("[Router] param put failed: {}", .{err});
                    allocator.free(param_keys[i]);
                    allocator.free(param_vals[i]);
                };
            }
            return MatchedRoute{
                .route = route,
                .params = params,
            };
        }

        // Check if current node has a wildcard child (for /prefix/* matching /prefix)
        if (current.wildcard_child) |wc| {
            if (wc.route) |route| {
                var params = std.StringHashMap([]const u8).init(allocator);
                for (0..param_count) |i| {
                    params.put(param_keys[i], param_vals[i]) catch |err| {
                        std.log.err("[Router] wildcard param put failed: {}", .{err});
                        for (0..param_count) |k| {
                            allocator.free(param_keys[k]);
                            allocator.free(param_vals[k]);
                        }
                        params.deinit();
                        return null;
                    };
                }
                return MatchedRoute{ .route = route, .params = params };
            }
        }

        for (0..param_count) |i| {
            allocator.free(param_keys[i]);
            allocator.free(param_vals[i]);
        }
        if (self.wildcards.get(method)) |wc| {
            return MatchedRoute{ .route = wc, .params = std.StringHashMap([]const u8).init(allocator) };
        }
        std.log.debug("[Router] no match: {s} {s}", .{ method.toString(), path });
        return null;
    }
};

/// Lightweight route metadata for listing (no handler pointer)
pub const RouteInfo = struct {
    method: []const u8,
    path: []const u8,
};

/// Recursively traverse trie nodes to collect all route paths
fn collectRoutes(
    node: *const TrieNode,
    method: Method,
    prefix: []const u8,
    alloc: std.mem.Allocator,
    result: *std.ArrayList(RouteInfo),
) !void {
    if (node.route) |_| {
        const path = try std.fmt.allocPrint(alloc, "/{s}", .{prefix});
        defer alloc.free(path);
        try result.append(alloc, .{
            .method = try alloc.dupe(u8, method.toString()),
            .path = try alloc.dupe(u8, path),
        });
    }
    for (node.children.items) |child| {
        const sep = if (prefix.len > 0 and prefix[prefix.len - 1] != '/') "/" else "";
        const full = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ prefix, sep, child.segment });
        defer alloc.free(full);
        try collectRoutes(child, method, full, alloc, result);
    }
}

const MatchedRoute = struct {
    route: Route,
    params: std.StringHashMap([]const u8),

    pub fn deinit(self: *MatchedRoute, allocator: std.mem.Allocator) void {
        var it = self.params.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();
    }
};

// ==== §6  Server & response writers ====

fn getStatusText(status: u16) []const u8 {
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

/// Write HTTP response directly to a `std.Io.net.Stream`.
/// Avoids intermediate ArrayList allocation — formats status line and headers
/// into small stack buffers and writes body directly from caller's buffer.
fn writeResponse(io: std.Io, stream: std.Io.net.Stream, status: u16, headers: std.StringHashMap([]const u8), body: []const u8) !void {
    var write_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &write_buf);

    var line_buf: [256]u8 = undefined;
    const status_text = getStatusText(status);

    // Status line
    const status_line = try std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} {s}\r\n", .{ status, status_text });
    try w.interface.writeAll(status_line);

    // Headers
    var hiter = headers.iterator();
    while (hiter.next()) |entry| {
        const header_line = try std.fmt.bufPrint(&line_buf, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        try w.interface.writeAll(header_line);
    }

    // Content-Length (skip for chunked transfer to avoid HTTP spec violation)
    if (headers.get("Transfer-Encoding") == null) {
        const cl_line = try std.fmt.bufPrint(&line_buf, "Content-Length: {d}\r\n", .{body.len});
        try w.interface.writeAll(cl_line);
    }
    try w.interface.writeAll("\r\n");

    // Body (already chunk-encoded if Transfer-Encoding: chunked)
    try w.interface.writeAll(body);
    try w.interface.flush();
}

/// Case-insensitive header lookup. Keys stored in the map (request headers are
/// lowercased at parse time) are matched exactly first, then by
/// `std.ascii.eqlIgnoreCase` so `ctx.header("X-Agent-Token")` works.
fn headerLookup(headers: std.StringHashMap([]const u8), key: []const u8) ?[]const u8 {
    if (headers.get(key)) |value| return value;
    var it = headers.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, key)) return entry.value_ptr.*;
    }
    return null;
}

/// HTTP server — async fiber-based
pub const Server = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    port: u16,
    router: Router,
    global_middleware: std.ArrayList(Middleware),
    default_404: ?HandlerFn = null,
    ws_handlers: std.StringHashMap(WsRoute),
    /// Path rewriter callback (optional) — runs before router.match().
    /// Use for ThinkPHP /api/* compat, legacy URL mapping, prefix stripping.
    path_rewriter: ?PathRewriterFn = null,
    ws_buffer_pool: ?*BufferPool = null,
    ws_uring: ?*WsUring = null,
    name: []const u8,
    running: std.atomic.Value(bool),
    listener: ?std.Io.net.Server,
    listener_closing: std.atomic.Value(bool),
    conn_group: std.Io.Group,
    max_body_size: usize,
    request_timeout_ms: u32,
    max_requests_per_conn: usize,
    header_limits: HeaderLimits,
    /// 0 = unlimited. See `Config.max_connections`.
    max_connections: usize = 0,
    /// See `Config.connection_stack_size` (used by `runInBackground`, raised to
    /// `min_thread_stack_size` there).
    connection_stack_size: usize = 128 * 1024,
    /// See `Config.over_limit_response`.
    over_limit_response: OverLimitResponse = .close,
    /// See `Config.header_timeout_ms`.
    header_timeout_ms: u32 = 10_000,
    /// See `Config.ws_write_timeout_ms`.
    ws_write_timeout_ms: u32 = 0,
    /// See `Config.max_params`.
    max_params: usize = 1000,
    /// Accepted connections currently being served (reserved before the fiber
    /// starts, released when it returns).
    active_connections: std.atomic.Value(u64) = .init(0),
    in_flight: ?*std.atomic.Value(u64) = null,
    /// Allocated route-group / scoped middleware slices (RouteGroup.use, ComptimeRouter Scoped.use).
    owned_route_mw: std.ArrayList([]const Middleware),
    /// Prior-knowledge HTTP/2 (h2c). When true, connFiber detects `PRI * HTTP/2.0` preface.
    enable_http2: bool = false,
    /// Optional gRPC registry for HTTP/2 gRPC dispatch.
    grpc_registry: ?*GrpcServiceRegistry = null,
    /// Optional non-gRPC HTTP/2 site handler (multiplexed streams).
    http2_site_handler: ?Http2Server.SiteHandler = null,
    /// When true, non-gRPC H2 requests use `handleForTest` / Router (same routes as HTTP/1.1).
    http2_use_router: bool = true,
    /// TLS front / ALPN intent (stdlib has no TLS server; use sidecar — see `http.Http2Tls`).
    tls_front: Http2Tls.TlsFrontConfig = .{},

    pub const Config = struct {
        port: u16 = 8080,
        name: []const u8 = "zigmodu-api",
        max_body_size: usize = 8 * 1024 * 1024,
        request_timeout_ms: u32 = 30000,
        max_requests_per_conn: usize = 100,
        header_limits: HeaderLimits = .{},
        /// Thread stack size for the accept-loop thread `runInBackground`
        /// spawns. Connection fibers do **not** run on it (they execute on the
        /// io executor's own worker threads), so this sizes one thread, not
        /// one-per-connection. Values below `min_thread_stack_size` are raised
        /// to that floor at spawn time — raising it is the useful direction
        /// (deep recursion inside the loop); lowering it is not.
        connection_stack_size: usize = 128 * 1024,
        /// Max accepted connections served concurrently. 0 = unlimited.
        /// Over the limit the connection is closed immediately (or answered
        /// with 503 when `over_limit_response == .unavailable`), which keeps
        /// an accept flood from exhausting file descriptors and memory.
        max_connections: usize = 0,
        /// What an over-limit connection gets: `.close` (cheapest) or
        /// `.unavailable` (write 503 first).
        over_limit_response: OverLimitResponse = .close,
        /// Deadline for receiving the request line + headers, independent of
        /// `request_timeout_ms` (which only covers handler execution). Bounds
        /// slowloris-style trickle. 0 disables the deadline.
        header_timeout_ms: u32 = 10_000,
        /// Upper bound on parameters parsed from one request's query string or
        /// form body (occurrences, not distinct names). Mirrors PHP's
        /// `max_input_vars`: a parser that accepts unbounded input is a DoS
        /// surface. Exceeding it fails the request (`error.TooManyParams`)
        /// instead of silently truncating it.
        max_params: usize = 1000,
        /// Bound on blocking WebSocket writes (`SO_SNDTIMEO`). A peer that
        /// stops reading would otherwise stall the writing thread forever
        /// (and, for `im.ConnectionRegistry`, while holding a shard lock).
        /// On timeout the frame write fails with `error.WriteTimeout` and the
        /// socket is shut down. 0 keeps the unbounded behavior.
        ws_write_timeout_ms: u32 = 0,
    };

    pub const OverLimitResponse = enum { close, unavailable };

    /// Smallest `stack_size` `pthread_create` accepts here: on aarch64 glibc
    /// (ubuntu 22.04) 128 KiB *is* `PTHREAD_STACK_MIN` and the guard page eats
    /// into it, so smaller requests come back as EINVAL (measured). The tests
    /// below spawn their accept loops with this size for the same reason.
    pub const min_thread_stack_size: usize = 2 * 1024 * 1024;

    /// What `runInBackground` hands to `std.Thread.spawn`: the configured size,
    /// never below the platform floor.
    pub fn effectiveStackSize(configured: usize) usize {
        return @max(configured, min_thread_stack_size);
    }

    pub fn init(io: std.Io, allocator: std.mem.Allocator, port: u16) Server {
        return Server.initWithConfig(io, allocator, .{ .port = port });
    }

    pub fn initWithConfig(io: std.Io, allocator: std.mem.Allocator, config: Config) Server {
        return .{
            .io = io,
            .allocator = allocator,
            .port = config.port,
            .router = Router.init(allocator),
            .global_middleware = std.ArrayList(Middleware).empty,
            .ws_handlers = std.StringHashMap(WsRoute).init(allocator),
            .name = config.name,
            .running = std.atomic.Value(bool).init(false),
            .listener = null,
            .listener_closing = std.atomic.Value(bool).init(false),
            .conn_group = .init,
            .max_body_size = config.max_body_size,
            .request_timeout_ms = config.request_timeout_ms,
            .max_requests_per_conn = config.max_requests_per_conn,
            .header_limits = config.header_limits,
            .max_connections = config.max_connections,
            .connection_stack_size = config.connection_stack_size,
            .over_limit_response = config.over_limit_response,
            .header_timeout_ms = config.header_timeout_ms,
            .ws_write_timeout_ms = config.ws_write_timeout_ms,
            .max_params = config.max_params,
            .owned_route_mw = std.ArrayList([]const Middleware).empty,
        };
    }

    /// Enable prior-knowledge HTTP/2 cleartext (h2c). Pair with `setGrpcRegistry` for gRPC-over-H2.
    pub fn setHttp2Enabled(self: *Server, enabled: bool) void {
        self.enable_http2 = enabled;
    }

    pub fn setGrpcRegistry(self: *Server, registry: ?*GrpcServiceRegistry) void {
        self.grpc_registry = registry;
    }

    pub fn setHttp2SiteHandler(self: *Server, handler: ?Http2Server.SiteHandler) void {
        self.http2_site_handler = handler;
    }

    /// When enabled (default), H2 non-gRPC requests dispatch through the same Router as HTTP/1.1.
    pub fn setHttp2UseRouter(self: *Server, enabled: bool) void {
        self.http2_use_router = enabled;
    }

    /// Declare TLS terminator / ALPN intent (no in-process TLS server in Zig 0.17 stdlib).
    pub fn setTlsFront(self: *Server, cfg: Http2Tls.TlsFrontConfig) void {
        self.tls_front = cfg;
    }

    /// H2 site adapter: run `handleForTest` and map Context → SiteResponse.
    fn http2RouterSiteHandler(
        user_ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        method_str: []const u8,
        path: []const u8,
        headers: []const Hpack.Header,
        body: []const u8,
    ) anyerror!Http2Server.SiteResponse {
        const server: *Server = @ptrCast(@alignCast(user_ctx.?));
        // Same rule as HTTP/1.1: an unknown `:method` is reported, not coerced
        // into GET and routed as if the client had asked for it.
        const method = Method.fromString(method_str) orelse return .{
            .status = 501,
            .content_type = "text/plain",
            .body = try allocator.dupe(u8, "Not Implemented"),
        };
        var ctx = try Context.init(allocator, method, path);
        errdefer ctx.deinit();

        var body_owned: ?[]u8 = null;
        defer if (body_owned) |b| allocator.free(b);
        if (body.len > 0) {
            body_owned = try allocator.dupe(u8, body);
            ctx.body = body_owned;
        }
        for (headers) |h| {
            if (h.name.len == 0 or h.name[0] == ':') continue;
            const k = try allocator.dupe(u8, h.name);
            errdefer allocator.free(k);
            const v = try allocator.dupe(u8, h.value);
            errdefer allocator.free(v);
            try ctx.headers.put(k, v);
        }

        try server.handleForTest(&ctx);

        const status = ctx.status_code;
        const ctype_src = ctx.response_headers.get("content-type") orelse "application/octet-stream";
        const ctype = try allocator.dupe(u8, ctype_src);
        errdefer allocator.free(ctype);
        const resp_body = try allocator.dupe(u8, ctx.response_body.items);
        ctx.deinit();
        return .{
            .status = status,
            .content_type = ctype,
            .body = resp_body,
            .content_type_owned = true,
        };
    }

    /// Attach a shared buffer pool for WebSocket frame I/O.
    /// Without this, each WS connection stack-allocates 4KB read + write buffers.
    pub fn setWsBufferPool(self: *Server, pool: *BufferPool) void {
        self.ws_buffer_pool = pool;
    }

    /// Use io_uring for WebSocket I/O instead of fibers.
    /// Eliminates per-connection fiber stack (6KB → 0). Linux 5.1+ only.
    pub fn setWsUring(self: *Server, uring: *WsUring) void {
        self.ws_uring = uring;
    }

    pub fn deinit(self: *Server) void {
        for (self.owned_route_mw.items) |slice| {
            self.allocator.free(slice);
        }
        self.owned_route_mw.deinit(self.allocator);
        self.router.deinit();
        self.global_middleware.deinit(self.allocator);
        {
            var it = self.ws_handlers.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
        }
        self.ws_handlers.deinit();
        self.* = undefined;
    }

    pub fn addRoute(self: *Server, route: Route) !void {
        var r = route;
        // Pre-compose global + route middleware so executeWithMiddleware
        // avoids alloc+memcpy+free per request.
        if (self.global_middleware.items.len > 0 or route.middleware.len > 0) {
            const total = self.global_middleware.items.len + route.middleware.len;
            const combined = try self.allocator.alloc(Middleware, total);
            @memcpy(combined[0..self.global_middleware.items.len], self.global_middleware.items);
            @memcpy(combined[self.global_middleware.items.len..], route.middleware);
            r.combined_middleware = combined;
        }
        try self.router.addRoute(r);
        std.log.info("ROUTE: {s} {s}", .{ @tagName(r.method), r.path });
    }

    pub fn group(self: *Server, prefix: []const u8) RouteGroup {
        return RouteGroup.init(self, prefix);
    }

    /// List all registered routes (method + path pairs)
    pub fn listRoutes(self: *const Server, alloc: std.mem.Allocator) ![]const RouteInfo {
        return self.router.listRoutes(alloc);
    }

    pub fn addMiddleware(self: *Server, mw: Middleware) !void {
        try self.global_middleware.append(self.allocator, mw);
    }

    /// Set a path rewriter callback. Runs after Context init, before router.match().
    /// Use for legacy URL mapping, prefix stripping, ThinkPHP compat.
    /// Must be called before server.start().
    pub fn setPathRewriter(self: *Server, rewriter: PathRewriterFn) void {
        self.path_rewriter = rewriter;
    }

    /// Wire the server into the Application's graceful-shutdown drain counter.
    /// When set, every request increments the counter on entry and decrements
    /// on completion so Application.run() can drain before stopping.
    pub fn withGracefulDrain(self: *Server, counter: *std.atomic.Value(u64)) void {
        self.in_flight = counter;
    }

    fn executeWithMiddleware(self: *Server, ctx: *Context, final_handler: HandlerFn, combined_middleware: []const Middleware) !void {
        _ = self;
        PanicHook.setRequestContext(ctx.method.toString(), ctx.path);
        defer PanicHook.clearRequestContext();
        ctx.chain_middlewares = combined_middleware;
        ctx.chain_handler = final_handler;
        ctx.chain_index = 0;

        try runMiddlewareChain(ctx);
    }

    /// Test-only dispatch: match route, copy params, run middleware + handler (no listen).
    pub fn handleForTest(self: *Server, ctx: *Context) !void {
        var matched = self.router.match(ctx.allocator, ctx.method, ctx.path);
        if (matched) |*m| {
            defer m.deinit(ctx.allocator);

            var pit = m.params.iterator();
            while (pit.next()) |entry| {
                const key = try ctx.allocator.dupe(u8, entry.key_ptr.*);
                const val = try ctx.allocator.dupe(u8, entry.value_ptr.*);
                try ctx.params.put(key, val);
            }

            ctx.user_data = m.route.user_data;
            ctx.route_template = m.route.path;

            self.executeWithMiddleware(ctx, m.route.handler, m.route.combined_middleware) catch |err| {
                if (!ctx.responded) {
                    try ctx.sendError(500, @errorName(err));
                }
            };
            return;
        }

        if (self.global_middleware.items.len > 0) {
            self.executeWithMiddleware(ctx, struct {
                fn h(_: *Context) anyerror!void {}
            }.h, self.global_middleware.items) catch |err| std.log.err("[Server] global middleware on unmatched route failed: {}", .{err});
        }
        if (!ctx.responded) {
            try ctx.sendError(404, "Not Found");
        }
    }

    /// Start the async HTTP server.
    /// Blocks until stop() is called (runs within self.io scheduler).
    pub fn start(self: *Server) !void {
        const addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", self.port);
        self.listener = try addr.listen(self.io, .{
            .reuse_address = true,
        });
        // Only the path that first flips `listener_closing` to true is allowed
        // to call `deinit`. This prevents a double-close race between `stop()`
        // (called by user code) and this defer (triggered when the accept loop
        // exits because the fd was closed underneath it).
        defer self.closeListener();
        // Reap any still-running connection fibers on exit so their futures
        // are released. Await (not cancel) so in-flight requests complete.
        defer self.conn_group.await(self.io) catch |err| std.log.warn("[Server] conn_group await: {}", .{err});

        self.running.store(true, .monotonic);
        std.log.info("Server listening on port {d}", .{self.port});

        while (self.running.load(.monotonic)) {
            const stream = (self.listener orelse break).accept(self.io) catch |err| {
                if (!self.running.load(.monotonic)) break;
                std.log.err("Accept error: {any}", .{err});
                continue;
            };

            // Connection-level backpressure: reserve a slot before dispatching
            // and release it when the fiber returns. Without this an accept
            // flood (or thousands of slow connections) exhausts fds/memory.
            const active = self.active_connections.fetchAdd(1, .monotonic) + 1;
            if (self.max_connections != 0 and active > self.max_connections) {
                _ = self.active_connections.fetchSub(1, .monotonic);
                if (self.over_limit_response == .unavailable) {
                    // Raw socket write, deliberately: this runs on the accept
                    // thread, and the io write path can block it (which would
                    // stop all accepts — worse than the flood we're shedding).
                    writeOverLimit503(stream);
                }
                stream.close(self.io);
                continue;
            }

            // Use `concurrent`, NOT `async`, to dispatch the connection fiber.
            //
            // `Group.async` has backpressure semantics: when `busy_count`
            // reaches `async_limit` (default cpu_count-1) it falls back to
            // `groupAsyncEager` — running connFiber synchronously on *this*
            // (accept-loop) thread. connFiber is a keep-alive read loop that
            // blocks on `readv` until the peer sends the next request, so a
            // single idle keep-alive client could then occupy the accept
            // thread forever and freeze the whole server (accept stops, every
            // new connection times out). `concurrent` has a `concurrent_limit`
            // (default `.unlimited`) and never falls back to eager execution:
            // at the limit it returns an error we can reject the connection
            // with, instead of hijacking the accept loop.
            self.conn_group.concurrent(self.io, connFiber, .{ self, stream, self.allocator }) catch |err| {
                std.log.warn("[Server] connection rejected (concurrent limit): {}", .{err});
                _ = self.active_connections.fetchSub(1, .monotonic);
                stream.close(self.io);
                continue;
            };
        }
    }

    /// Reduce kernel TCP buffer sizes for high-connection WebSocket workloads.
    /// Default: ~16KB recv + ~16KB send = 32KB/conn kernel memory.
    /// After: 2KB recv + 2KB send = 4KB/conn. Saves 28KB per connection.
    /// For 1M connections: 32GB → 4GB kernel memory.
    pub fn tuneSocket(stream: std.Io.net.Stream) void {
        const fd = stream.socket.handle;
        const rcvbuf: i32 = 2048;
        const sndbuf: i32 = 2048;
        const one: i32 = 1;
        std.posix.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVBUF, std.mem.asBytes(&rcvbuf)) catch |err| std.log.debug("[Server] setsockopt RCVBUF: {}", .{err});
        std.posix.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDBUF, std.mem.asBytes(&sndbuf)) catch |err| std.log.debug("[Server] setsockopt SNDBUF: {}", .{err});
        std.posix.setsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, std.mem.asBytes(&one)) catch |err| std.log.debug("[Server] setsockopt TCP_NODELAY: {}", .{err});
        // SO_KEEPALIVE only: idle/probe timings are the OS defaults (Linux and
        // macOS both idle 7200 s, probe every 75 s) — TCP_KEEPIDLE/TCP_KEEPINTVL
        // are not set, and the per-platform constant names differ.
        std.posix.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.KEEPALIVE, std.mem.asBytes(&one)) catch |err| std.log.debug("[Server] setsockopt KEEPALIVE: {}", .{err});
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .monotonic);
        self.closeListener();
        self.listener_closing.store(false, .monotonic); // allow restart
    }

    /// Start the server in a background thread. Returns immediately.
    /// Call stop() to shut down. Use this when you need to start multiple
    /// services (HTTP + gRPC + cluster) in the same process.
    pub fn runInBackground(self: *Server) !std.Thread {
        self.running.store(true, .monotonic);
        // NB: on aarch64 glibc (ubuntu 22.04 arm64) `pthread_create` rejects a
        // custom `stack_size` ≤ 256 KiB with EINVAL (PTHREAD_STACK_MIN is 128 KiB
        // there, and the guard page eats into it). 2 MiB is the smallest size we
        // measured to succeed, which is why `effectiveStackSize` raises anything
        // smaller — including the 128 KiB default — to `min_thread_stack_size`.
        const handle = try std.Thread.spawn(
            .{ .stack_size = effectiveStackSize(self.connection_stack_size) },
            runLoop,
            .{self},
        );
        return handle;
    }

    /// Enable SO_REUSEPORT for multi-process deployment.
    /// Must be called before start(). On POSIX, reuse_address already sets
    /// SO_REUSEPORT; this is a no-op. Call this to document intent.
    pub fn enableReusePort(self: *Server) void {
        _ = self;
    }

    fn runLoop(self: *Server) void {
        self.start() catch |err| {
            std.log.err("[Server] Background accept loop failed: {}", .{err});
        };
    }

    /// Read an integer environment variable, falling back to `default` when the
    /// variable is unset or malformed (a typo must not take the server down).
    fn envInt(comptime T: type, env: *const std.process.Environ.Map, key: []const u8, default: T) T {
        const raw = env.get(key) orelse return default;
        return std.fmt.parseInt(T, raw, 10) catch default;
    }

    /// Factory: create a Server from environment variables.
    /// Pass main's environment map: `Server.fromEnv(io, alloc, init.environ_map)`.
    pub fn fromEnv(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !Server {
        return initWithConfig(io, allocator, .{
            .port = envInt(u16, env, "HTTP_PORT", 8080),
            .max_body_size = envInt(usize, env, "HTTP_MAX_BODY", 8 * 1024 * 1024),
            .max_connections = envInt(usize, env, "HTTP_MAX_CONNECTIONS", 0),
            .header_timeout_ms = envInt(u32, env, "HTTP_HEADER_TIMEOUT_MS", 10_000),
            .ws_write_timeout_ms = envInt(u32, env, "WS_WRITE_TIMEOUT_MS", 0),
        });
    }

    /// Close the listener exactly once, whichever caller wins the race.
    fn closeListener(self: *Server) void {
        if (self.listener_closing.swap(true, .acq_rel)) return;
        if (self.listener) |*l| {
            // `sockread.closeListener` is the shared version of this dance: the
            // `shutdown` before the `close` is what wakes a thread blocked in
            // `accept` on Linux, where `close` alone leaves it blocked forever.
            sockread.closeListener(self.io, l);
            self.listener = null;
        }
    }
};

// ==== §7  connFiber ====

/// Does `Connection`'s value contain the `upgrade` token?
///
/// `Connection` is a comma-separated token list (RFC 7230 §6.1), and browsers
/// send `Connection: keep-alive, Upgrade` — an equality test against
/// `"Upgrade"` rejects the normal client. Tokens are case-insensitive.
fn connectionHasUpgrade(value: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "upgrade")) return true;
    }
    return false;
}

/// The RFC 6455 §4.2.1 conditions a client handshake request must satisfy
/// before the server may answer 101: an `Upgrade: websocket` header, `upgrade`
/// in the `Connection` token list, `Sec-WebSocket-Version: 13`, and a non-empty
/// `Sec-WebSocket-Key`.
///
/// The upgrade is answered *before* `router.match` and before every middleware
/// (docs/RUNTIME.md §12.14), so this is the pre-auth surface: checking only
/// `Upgrade` + a non-empty key used to be enough to get a 101 for a request that
/// is not a WebSocket handshake at all.
fn wsHandshakeValid(ctx: *const Context) bool {
    const ws_key = ctx.headers.get("sec-websocket-key") orelse "";
    if (ws_key.len == 0) return false;

    // §4.4: no version other than 13 has ever existed, so anything else (or a
    // missing header) is not a handshake we can complete.
    const version = ctx.headers.get("sec-websocket-version") orelse "";
    if (!std.mem.eql(u8, version, "13")) return false;

    return connectionHasUpgrade(ctx.headers.get("connection") orelse "");
}

/// Connection fiber — handles one HTTP connection
fn connFiber(server: *Server, stream: std.Io.net.Stream, allocator: std.mem.Allocator) void {
    defer _ = server.active_connections.fetchSub(1, .monotonic);
    defer stream.close(server.io);
    Server.tuneSocket(stream);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var reader: StreamReader = undefined;
    reader.setup(stream, server.io);
    var parser = RequestParser.init(arena_alloc);

    var req_count: usize = 0;
    while (req_count < server.max_requests_per_conn and server.running.load(.monotonic)) : (req_count += 1) {
        _ = arena.reset(.retain_capacity);

        const start_time = std.Io.Timestamp.now(server.io, .real);

        // Bound the request line + header phase (slowloris guard). Cleared by
        // the parser once the blank line is seen; re-armed per request here.
        reader.setHeaderDeadline(server.header_timeout_ms);

        // Prefetch first line — HTTP/2 prior-knowledge preface starts with PRI.
        const first_line_raw = reader.readUntilDelimiterOrEof(&.{}, '\n') catch |err| {
            switch (err) {
                error.ReadFailed => {
                    if (reader.timed_out) writeErrorResponse(server.io, stream, arena_alloc, 408, "Request Timeout");
                    return;
                },
                else => {
                    writeErrorResponse(server.io, stream, arena_alloc, 400, "Bad Request");
                    return;
                },
            }
        } orelse return;
        const first_line = RequestParser.trimCrlf(first_line_raw);

        if (server.enable_http2 and std.mem.eql(u8, first_line, "PRI * HTTP/2.0")) {
            // Consume remaining preface: empty line, "SM", empty line
            const l2 = (reader.readUntilDelimiterOrEof(&.{}, '\n') catch return) orelse return;
            const l3 = (reader.readUntilDelimiterOrEof(&.{}, '\n') catch return) orelse return;
            const l4 = (reader.readUntilDelimiterOrEof(&.{}, '\n') catch return) orelse return;
            if (RequestParser.trimCrlf(l2).len != 0) return;
            if (!std.mem.eql(u8, RequestParser.trimCrlf(l3), "SM")) return;
            if (RequestParser.trimCrlf(l4).len != 0) return;
            // The preface is consumed; H2 frames are not header-phase reads.
            reader.clearHeaderDeadline();

            // Reuse the same StreamReader for the H2 session (do not create a second
            // reader on this stream). Any bytes already buffered after the preface
            // stay in the reader and are consumed as frames.
            Http2Server.serveAfterPrefacePrefetchReader(server.io, stream, allocator, .{
                .grpc_registry = server.grpc_registry,
                .site_handler = if (server.http2_site_handler != null)
                    server.http2_site_handler
                else if (server.http2_use_router)
                    Server.http2RouterSiteHandler
                else
                    null,
                .site_user_ctx = server,
                // One inbound frame per stream request is typical; leave headroom for SETTINGS/WINDOW_UPDATE/CONTINUATION.
                .max_frames = @max(server.max_requests_per_conn * 16, 4096),
            }, &.{}, &reader.interface) catch |err| {
                std.log.warn("[Server] HTTP/2 session ended: {s}", .{@errorName(err)});
            };
            return;
        }

        var request = parser.parseAfterRequestLine(&reader, first_line_raw, server.max_body_size, server.header_limits, server.max_params) catch |err| {
            switch (err) {
                error.ReadFailed => {
                    if (reader.timed_out) writeErrorResponse(server.io, stream, arena_alloc, 408, "Request Timeout");
                    return;
                },
                error.IncompleteBody => return,
                else => {},
            }
            // A malformed request is a client fault, not a server error: warn,
            // so scanners/probes cannot inflate the error signal.
            std.log.warn("Parse error: {any}", .{err});
            // Every request-boundary failure is a refusal, never a best-effort
            // reparse: 413/431 for the size guards, 501 for a method token this
            // server does not implement, 400 for everything else (including
            // the CL/TE framing conflicts).
            const msg = if (err == error.BodyTooLarge)
                "Payload Too Large"
            else if (err == error.TooManyHeaders)
                "Request Header Fields Too Large"
            else if (err == error.InvalidMethod)
                "Not Implemented"
            else
                "Bad Request";
            const status: u16 = if (err == error.BodyTooLarge)
                413
            else if (err == error.TooManyHeaders)
                431
            else if (err == error.InvalidMethod)
                501
            else
                400;
            writeErrorResponse(server.io, stream, arena_alloc, status, msg);
            return;
        };
        defer request.deinit(arena_alloc);

        // Track in-flight requests for graceful shutdown drain
        if (server.in_flight) |counter| {
            _ = counter.fetchAdd(1, .monotonic);
            defer _ = counter.fetchSub(1, .monotonic);
        }

        std.log.debug("[HC] {s} {s}", .{ request.method.toString(), request.path });

        var ctx = Context.init(arena_alloc, request.method, request.path) catch |err| {
            std.log.err("Context init error: {any}", .{err});
            return;
        };
        defer ctx.deinit();

        // Arm the request budget once, here: `request_timeout_ms` used to be a
        // post-hoc check (compare elapsed, send 408 if the handler overshot)
        // with no way for storage to hear about it. Context now carries the
        // deadline, and `ctx.sqlContext()` hands it to the query layer — so a
        // handler that wires it stops piling queries behind a spent budget.
        ctx.setDeadline(server.request_timeout_ms);

        ctx.io = server.io;
        ctx.stream = stream;

        // Transfer ownership: steal the query/headers containers from request
        // to avoid re-duplicating every key-value pair (saves ~10 allocs/req).
        // Both use arena_alloc so lifetimes are consistent.
        ctx.query.deinit();
        ctx.query = request.query;
        request.query = Params.init(arena_alloc);

        ctx.headers.deinit();
        ctx.headers = request.headers;
        request.headers = std.StringHashMap([]const u8).init(arena_alloc);

        ctx.body = request.body;
        ctx.raw_path = request.raw_path;

        // ── Path rewriter (runs before route matching) ──
        if (server.path_rewriter) |rewriter| {
            rewriter(&ctx);
            request.path = ctx.path; // sync — router.match uses request.path
        }

        // Parse form body
        if (request.body) |body| {
            const ctype = ctx.headers.get("content-type") orelse "";
            if (std.mem.startsWith(u8, ctype, "application/x-www-form-urlencoded")) {
                ctx.form = parseFormBody(arena_alloc, body, server.max_params) catch null;
            }
        }

        // ── HTTP/2 cleartext upgrade (h2c, RFC 7540 §3.2) ──
        if (server.enable_http2 and std.mem.eql(u8, request.method.toString(), "GET")) {
            const upgrade_hdr = ctx.headers.get("upgrade") orelse "";
            const conn_hdr = ctx.headers.get("connection") orelse "";
            const h2_settings = ctx.headers.get("http2-settings");
            if (Http2.isH2cUpgrade(upgrade_hdr, conn_hdr, h2_settings)) {
                var wbuf: [256]u8 = undefined;
                var w = stream.writer(server.io, &wbuf);
                w.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n") catch return;
                w.interface.flush() catch return;
                Http2Server.serve(server.io, stream, allocator, .{
                    .grpc_registry = server.grpc_registry,
                    .site_handler = if (server.http2_site_handler != null)
                        server.http2_site_handler
                    else if (server.http2_use_router)
                        Server.http2RouterSiteHandler
                    else
                        null,
                    .site_user_ctx = server,
                    .max_frames = @max(server.max_requests_per_conn * 16, 4096),
                }) catch |err| {
                    std.log.warn("[Server] HTTP/2 h2c upgrade session ended: {s}", .{@errorName(err)});
                };
                return;
            }
        }

        // ── WebSocket upgrade check ──
        const ws_lookup_path = if (request.path.len > 0 and request.path[0] == '/') request.path[1..] else request.path;
        if (server.ws_handlers.get(ws_lookup_path)) |ws_route| {
            if (std.mem.eql(u8, request.method.toString(), "GET")) {
                const upgrade_hdr = ctx.headers.get("upgrade") orelse "";
                if (std.ascii.eqlIgnoreCase(upgrade_hdr, "websocket")) {
                    // RFC 6455 §4.2.1: the request also needs `upgrade` in the
                    // `Connection` token list, `Sec-WebSocket-Version: 13` and a
                    // non-empty key. A request that fails these is refused here
                    // with a 400 and **no** 101 — the accept key must not be
                    // computed for a request that is not a handshake.
                    if (!wsHandshakeValid(&ctx)) {
                        // `writeErrorResponse`, not `ctx.sendError`: this block
                        // returns out of `connFiber` rather than falling through
                        // to the normal response write, so a queued response
                        // would never reach the socket.
                        writeErrorResponse(server.io, stream, allocator, 400, "WebSocket handshake failed");
                        return;
                    }

                    // Non-empty: `wsHandshakeValid` above returned true.
                    const ws_key = ctx.headers.get("sec-websocket-key") orelse "";
                    ctx.user_data = ws_route.user_data;
                    // Perform handshake
                    var framer = WsFramer.init(stream, server.io);
                    framer.handshake(ws_key) catch {
                        writeErrorResponse(server.io, stream, allocator, 400, "WebSocket handshake failed");
                        return;
                    };
                    ctx.upgraded = true;
                    framer.setSendTimeout(server.ws_write_timeout_ms);

                    // Call on_connect — gateway returns session pointer (null = reject)
                    const session = ws_route.on_connect(&ctx, @ptrCast(&framer));
                    if (session == null) {
                        framer.writeClose() catch |err| std.log.err("[Server] WS writeClose on reject: {}", .{err});
                        if (@intFromPtr(ws_route.on_close) != 0) ws_route.on_close(null);
                        return;
                    }

                    // If io_uring is available, transfer fd ownership (fiber stack released here)
                    if (server.ws_uring) |uring| {
                        const sock_fd = stream.socket.handle;
                        uring.adopt(sock_fd, session.?, ws_route.on_message, ws_route.on_close) catch {
                            framer.writeClose() catch |err| std.log.err("[Server] WS writeClose on reject: {}", .{err});
                            if (@intFromPtr(ws_route.on_close) != 0) ws_route.on_close(session.?);
                            return;
                        };
                        return; // Fiber exits — io_uring takes over
                    }

                    // WebSocket read loop (fiber path)
                    var messages = WsFramer.MessageReader.init(&framer, server.allocator);
                    defer messages.deinit();
                    while (server.running.load(.monotonic)) {
                        const read_buf = if (server.ws_buffer_pool) |pool|
                            pool.acquire() catch break
                        else
                            server.allocator.alloc(u8, 4096) catch break;
                        defer {
                            if (server.ws_buffer_pool) |pool| pool.release(read_buf) else server.allocator.free(read_buf);
                        }
                        const event = messages.read(read_buf) catch break;
                        switch (event) {
                            .message => |m| {
                                if (@intFromPtr(ws_route.on_message) != 0) ws_route.on_message(session, m.payload, m.kind);
                            },
                            .close => break,
                        }
                    }

                    if (@intFromPtr(ws_route.on_close) != 0) ws_route.on_close(session);
                    return; // Connection done — don't continue HTTP loop
                }
            }
        }

        const matched_orig = server.router.match(arena_alloc, request.method, request.path);
        var matched = matched_orig;
        if (matched) |*m| {
            defer {
                var it = m.params.iterator();
                while (it.next()) |entry| {
                    arena_alloc.free(entry.key_ptr.*);
                    arena_alloc.free(entry.value_ptr.*);
                }
                m.params.deinit();
            }

            // Transfer params ownership (same pattern as query/headers above).
            // Avoids duping every param key/value — saves 2 allocs per param.
            ctx.params.deinit();
            ctx.params = m.params;
            m.params = std.StringHashMap([]const u8).init(arena_alloc);

            ctx.user_data = m.route.user_data;
            ctx.route_template = m.route.path;

            server.executeWithMiddleware(&ctx, m.route.handler, m.route.combined_middleware) catch |err| {
                std.log.err("[HC] Handler error: {any}", .{err});
                if (!ctx.responded) {
                    ctx.sendError(500, @errorName(err)) catch |e| std.log.err("[Server] Failed to send 500: {}", .{e});
                }
            };
        } else {
            // Run global middleware before 404
            if (server.global_middleware.items.len > 0) {
                server.executeWithMiddleware(&ctx, struct {
                    fn h(_: *Context) anyerror!void {}
                }.h, server.global_middleware.items) catch |err| std.log.err("[Server] global middleware before 404: {}", .{err});
            }
            if (!ctx.responded) {
                if (server.default_404) |nf| {
                    nf(&ctx) catch |err| std.log.err("[Server] default_404 handler failed: {}", .{err});
                } else {
                    ctx.sendError(404, "Not Found") catch |err| std.log.err("[Server] failed to send 404: {}", .{err});
                }
            }
        }

        const current_time = std.Io.Timestamp.now(server.io, .real);
        const elapsed_ms = @divTrunc(current_time.nanoseconds - start_time.nanoseconds, std.time.ns_per_ms);
        if (elapsed_ms > server.request_timeout_ms and !ctx.responded) {
            ctx.sendError(408, "Request Timeout") catch |err| std.log.err("[Server] failed to send 408: {}", .{err});
        }

        if (ctx.responded and !ctx.streaming) {
            writeResponse(server.io, stream, ctx.status_code, ctx.response_headers, ctx.response_body.items) catch |err| {
                std.log.err("[HC] write error: {any}", .{err});
                return;
            };
        }

        // Keep-alive decision: default keep-alive unless Connection: close
        if (ctx.headers.get("connection")) |conn_val| {
            if (std.ascii.eqlIgnoreCase(conn_val, "close")) return;
        }
    }
}

/// Write an error response directly to the connection stream
/// Minimal 503 for over-limit connections. Raw `write` syscalls only — it runs
/// on the accept thread, where an io-path write could stall the accept loop.
/// The body follows `transport_error_renderer` when one is installed.
fn writeOverLimit503(stream: std.Io.net.Stream) void {
    var body_buf: [1024]u8 = undefined;
    const rendered = renderTransportError(503, "Service Unavailable", &body_buf);
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ rendered.content_type, rendered.body.len }) catch return;
    writeRaw(stream, head);
    writeRaw(stream, rendered.body);
}

fn writeRaw(stream: std.Io.net.Stream, bytes: []const u8) void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.posix.system.write(stream.socket.handle, bytes[sent..].ptr, bytes[sent..].len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            else => return,
        }
        const n: usize = @intCast(rc);
        if (n == 0) return;
        sent += n;
    }
}

/// Error response for requests that failed *before* routing (bad request line,
/// oversized body, header flood). This runs outside the middleware chain, so a
/// middleware cannot restyle it — `transport_error_renderer` is the hook.
fn writeErrorResponse(io: std.Io, stream: std.Io.net.Stream, allocator: std.mem.Allocator, status: u16, message: []const u8) void {
    var body_buf: [1024]u8 = undefined;
    const rendered = renderTransportError(status, message, &body_buf);

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = headers.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        headers.deinit();
    }

    const key = allocator.dupe(u8, "Content-Type") catch return;
    const val = allocator.dupe(u8, rendered.content_type) catch {
        allocator.free(key);
        return;
    };
    headers.put(key, val) catch {
        allocator.free(key);
        allocator.free(val);
        return;
    };

    writeResponse(io, stream, status, headers, rendered.body) catch |err| std.log.err("[Server] writeErrorResponse failed: {}", .{err});
}

// ==== §8  Middleware runner & struct binding ====

fn runMiddlewareChain(ctx: *Context) anyerror!void {
    if (ctx.chain_index < ctx.chain_middlewares.len) {
        const mw = ctx.chain_middlewares[ctx.chain_index];
        ctx.chain_index += 1;
        try mw.func(ctx, runMiddlewareChain, mw.user_data);
    } else {
        try ctx.chain_handler(ctx);
    }
}

// Request/Response type wrapper
pub fn Request(comptime T: type) type {
    return struct {
        body: T,
    };
}

pub fn Response(comptime T: type) type {
    return struct {
        status: u16 = 200,
        body: T,
    };
}

/// JSON request/response wrapper
pub fn Json(comptime T: type) type {
    return struct {
        json: T,
    };
}

/// Deep-copy a parsed JSON value, duping all []const u8 fields
/// to escape the parse arena lifetime. Supports nested structs.
/// Whether two field names are equivalent ignoring underscores and case:
/// `user_name` == `userName` == `USERNAME`. Used by bindJsonLoose so clients
/// can send snake_case or camelCase JSON regardless of the struct spelling.
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

/// Find a JSON object entry whose key is name-equivalent to `fname`.
/// Shared loose binder for string→value sources (form body, query string).
/// Values are owned by the caller exactly like `bindJsonLoose` (deep-copied
/// strings), so the same free/ownership discipline applies.
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

/// Parse one textual parameter value into a field type. Unsupported types are a
/// compile error on purpose: a field the binder cannot fill must not silently
/// stay zero.
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

fn deepCopy(value: anytype, allocator: std.mem.Allocator) !@TypeOf(value) {
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

// ==== §9  Tests ====

test "api server" {
    const allocator = std.testing.allocator;
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    const route = Route{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                try ctx.json(200, "{\"status\":\"ok\"}");
            }
        }.handle,
    };

    try server.addRoute(route);
    try std.testing.expect(server.port == 0);
}

test "path matching" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    const route = Route{
        .method = .GET,
        .path = "/users/{id}",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                _ = ctx;
            }
        }.handle,
    };

    try router.addRoute(route);

    var matched = router.match(std.testing.allocator, .GET, "/users/123");
    if (matched) |*m| {
        defer {
            var iter = m.params.iterator();
            while (iter.next()) |entry| {
                std.testing.allocator.free(entry.key_ptr.*);
                std.testing.allocator.free(entry.value_ptr.*);
            }
            m.params.deinit();
        }
        try std.testing.expectEqualStrings("123", m.params.get("id").?);
    } else {
        try std.testing.expect(false);
    }

    const no_match = router.match(std.testing.allocator, .GET, "/posts/123");
    try std.testing.expect(no_match == null);
}

test "http methods" {
    try std.testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try std.testing.expectEqualStrings("POST", Method.POST.toString());
}

test "parse req binding" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/users/42");
    defer ctx.deinit();

    try ctx.params.put(try allocator.dupe(u8, "id"), try allocator.dupe(u8, "42"));
    try ctx.query.put("page", "3");

    const Req = struct {
        id: u32,
        page: u32,
    };

    const req = try ctx.parseReq(Req, .{ .id = .path, .page = .query });
    try std.testing.expectEqual(@as(u32, 42), req.id);
    try std.testing.expectEqual(@as(u32, 3), req.page);
}

test "route group" {
    const allocator = std.testing.allocator;
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    var api_group = server.group("/api/v1");
    try api_group.get("/users", struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.json(200, "{\"users\":[]}");
        }
    }.handle, null);

    // Route should exist at /api/v1/users
    var matched_opt = server.router.match(allocator, .GET, "/api/v1/users");
    if (matched_opt) |*matched| {
        defer matched.deinit(allocator);
    } else {
        try std.testing.expect(false);
    }
}

test "wildcard route matching" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const expectMatch = struct {
        fn call(r: *Router, method: Method, path: []const u8) !void {
            var matched = r.match(allocator, method, path) orelse return error.TestExpectedEqual;
            defer matched.deinit(allocator);
        }
    }.call;

    // Register wildcard routes
    try router.addRoute(.{
        .method = .GET,
        .path = "/crm/statistics/*",
        .handler = struct {
            fn h(_: *Context) anyerror!void {}
        }.h,
    });
    try router.addRoute(.{
        .method = .GET,
        .path = "/insurance/compensation-plan/*",
        .handler = struct {
            fn h(_: *Context) anyerror!void {}
        }.h,
    });
    try router.addRoute(.{
        .method = .GET,
        .path = "/users/{id}",
        .handler = struct {
            fn h(_: *Context) anyerror!void {}
        }.h,
    });
    try router.addRoute(.{
        .method = .POST,
        .path = "/api/data/*",
        .handler = struct {
            fn h(_: *Context) anyerror!void {}
        }.h,
    });

    // Test: wildcard path matches sub-paths
    try expectMatch(&router, .GET, "/crm/statistics/overview");
    try expectMatch(&router, .GET, "/crm/statistics/daily/report");
    try expectMatch(&router, .GET, "/insurance/compensation-plan/2024");
    try expectMatch(&router, .GET, "/insurance/compensation-plan/list/all");

    // Test: param route still works alongside wildcards
    try expectMatch(&router, .GET, "/users/42");

    // Test: POST wildcard works
    try expectMatch(&router, .POST, "/api/data/metrics");

    // Test: non-existent paths return null
    try std.testing.expect(router.match(allocator, .GET, "/crm/unknown") == null);
    try std.testing.expect(router.match(allocator, .GET, "/other/path") == null);
}

test "context carries the request budget into storage" {
    const allocator = std.testing.allocator;

    // Unarmed by default: an unconfigured Context must not impose a deadline.
    {
        var ctx = try Context.init(allocator, .GET, "/test");
        defer ctx.deinit();
        try std.testing.expect(ctx.deadline_ms == null);
        try std.testing.expect(ctx.remainingMs() == null);
        try std.testing.expect(ctx.sqlContext().deadline_ms == null);
    }

    // `request_timeout_ms` (30s default) arms it.
    {
        var ctx = try Context.init(allocator, .GET, "/test");
        defer ctx.deinit();
        ctx.setDeadline(30_000);
        const remaining = ctx.remainingMs().?;
        try std.testing.expect(remaining > 29_000 and remaining <= 30_000);
        // The same budget reaches storage, which is the whole point.
        try std.testing.expect(ctx.sqlContext().deadline_ms == ctx.deadline_ms);
        try std.testing.expect(!ctx.sqlContext().isDone());
    }

    // 0 disables the budget rather than arming an already-expired one.
    {
        var ctx = try Context.init(allocator, .GET, "/test");
        defer ctx.deinit();
        ctx.setDeadline(0);
        try std.testing.expect(ctx.deadline_ms == null);
    }

    // A spent budget is visible to storage and refuses queries.
    {
        var ctx = try Context.init(allocator, .GET, "/test");
        defer ctx.deinit();
        ctx.deadline_ms = Time.monotonicNowMilliseconds() - 1;
        try std.testing.expect(ctx.sqlContext().isDone());
        try std.testing.expect(ctx.remainingMs().? <= 0);
    }
}

test "context logScope carries the request's trace id, and nothing when absent" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;

    var ctx = try Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    // No id yet: the scope must be empty, not a phantom `trace_id=`.
    try std.testing.expectEqualStrings("", ctx.logScope("orders").fieldSuffix(&buf));

    try ctx.setTraceId("abc-123");
    try std.testing.expectEqualStrings(" trace_id=abc-123", ctx.logScope("orders").fieldSuffix(&buf));
}

test "context response helpers" {
    const allocator = std.testing.allocator;
    // JSON response
    {
        var ctx = try Context.init(allocator, .GET, "/test");
        defer ctx.deinit();
        try ctx.json(200, "{\"ok\":true}");
        try std.testing.expectEqual(@as(u16, 200), ctx.status_code);
        try std.testing.expect(ctx.responded);
        try std.testing.expectEqualStrings("application/json", ctx.response_headers.get("Content-Type").?);
        try std.testing.expectEqualStrings("{\"ok\":true}", ctx.response_body.items);
    }

    // Text response
    {
        var ctx = try Context.init(allocator, .GET, "/test");
        defer ctx.deinit();
        try ctx.text(201, "created");
        try std.testing.expectEqual(@as(u16, 201), ctx.status_code);
        try std.testing.expectEqualStrings("text/plain", ctx.response_headers.get("Content-Type").?);
        try std.testing.expectEqualStrings("created", ctx.response_body.items);
    }

    // Error response
    {
        var ctx = try Context.init(allocator, .GET, "/test");
        defer ctx.deinit();
        try ctx.sendError(400, "bad request");
        try std.testing.expectEqual(@as(u16, 400), ctx.status_code);
        try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "bad request") != null);
    }
}
test "middleware chain execution" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const TestState = struct {
        call_order: [5]u8 = undefined,
        idx: usize = 0,
    };
    var state = TestState{};

    const S = struct {
        fn mw1(c: *Context, next: HandlerFn, user_data: ?*anyopaque) anyerror!void {
            const st: *TestState = @ptrCast(@alignCast(user_data.?));
            st.call_order[st.idx] = 1;
            st.idx += 1;
            try next(c);
            st.call_order[st.idx] = 5;
            st.idx += 1;
        }
        fn mw2(c: *Context, next: HandlerFn, user_data: ?*anyopaque) anyerror!void {
            const st: *TestState = @ptrCast(@alignCast(user_data.?));
            st.call_order[st.idx] = 2;
            st.idx += 1;
            try next(c);
            st.call_order[st.idx] = 4;
            st.idx += 1;
        }
        fn handler(c: *Context) anyerror!void {
            const st: *TestState = @ptrCast(@alignCast(c.user_data.?));
            st.call_order[st.idx] = 3;
            st.idx += 1;
        }
    };

    const mws = try allocator.alloc(Middleware, 2);
    defer allocator.free(mws);
    mws[0] = Middleware{ .func = S.mw1, .user_data = &state };
    mws[1] = Middleware{ .func = S.mw2, .user_data = &state };

    ctx.chain_middlewares = mws;
    ctx.chain_handler = S.handler;
    ctx.chain_index = 0;
    ctx.user_data = &state;

    try runMiddlewareChain(&ctx);

    try std.testing.expectEqual(@as(u8, 1), state.call_order[0]);
    try std.testing.expectEqual(@as(u8, 2), state.call_order[1]);
    try std.testing.expectEqual(@as(u8, 3), state.call_order[2]);
    try std.testing.expectEqual(@as(u8, 4), state.call_order[3]);
    try std.testing.expectEqual(@as(u8, 5), state.call_order[4]);
}

test "integration: router + handler + response" {
    const allocator = std.testing.allocator;

    // 1. Set up server with a route
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    const HandlerCtx = struct {
        var last_id: u32 = 0;
        var last_page: u32 = 0;
    };

    try server.addRoute(.{
        .method = .GET,
        .path = "/users/{id}",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                const id_str = ctx.param("id") orelse "0";
                const id = try std.fmt.parseInt(u32, id_str, 10);
                HandlerCtx.last_id = id;

                const page_str = ctx.queryParam("page") orelse "1";
                HandlerCtx.last_page = try std.fmt.parseInt(u32, page_str, 10);

                try ctx.json(200, "{\"found\":true}");
            }
        }.handle,
    });

    // 2. Simulate a matched request
    var matched = server.router.match(allocator, .GET, "/users/99");
    try std.testing.expect(matched != null);

    if (matched) |*m| {
        defer {
            var it = m.params.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            m.params.deinit();
        }

        var ctx = try Context.init(allocator, .GET, "/users/99");
        defer ctx.deinit();

        // Copy params from matched route
        var piter = m.params.iterator();
        while (piter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const val = try allocator.dupe(u8, entry.value_ptr.*);
            try ctx.params.put(key, val);
        }

        // Set a query param
        try ctx.query.put("page", "5");

        // Execute handler
        try m.route.handler(&ctx);

        // Verify response
        try std.testing.expectEqual(@as(u32, 99), HandlerCtx.last_id);
        try std.testing.expectEqual(@as(u32, 5), HandlerCtx.last_page);
        try std.testing.expectEqual(@as(u16, 200), ctx.status_code);
        try std.testing.expect(ctx.responded);
        try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "found") != null);
    }
}

test "router listRoutes" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    try router.addRoute(.{ .method = .GET, .path = "/health", .handler = struct {
        fn handle(_: *Context) !void {}
    }.handle });
    try router.addRoute(.{ .method = .POST, .path = "/users", .handler = struct {
        fn handle(_: *Context) !void {}
    }.handle });
    try router.addRoute(.{ .method = .GET, .path = "/users/{id}", .handler = struct {
        fn handle(_: *Context) !void {}
    }.handle });
    try router.addRoute(.{ .method = .DELETE, .path = "/api/v1/admin/settings", .handler = struct {
        fn handle(_: *Context) !void {}
    }.handle });

    const routes = try router.listRoutes(allocator);
    defer {
        for (routes) |r| {
            allocator.free(r.method);
            allocator.free(r.path);
        }
        allocator.free(routes);
    }

    try std.testing.expectEqual(@as(usize, 4), routes.len);

    // Verify method/path pairs exist (order not guaranteed)
    var found_health = false;
    var found_post_users = false;
    var found_get_users_id = false;
    var found_admin = false;
    for (routes) |r| {
        if (std.mem.eql(u8, r.method, "GET") and std.mem.eql(u8, r.path, "/health")) found_health = true;
        if (std.mem.eql(u8, r.method, "POST") and std.mem.eql(u8, r.path, "/users")) found_post_users = true;
        if (std.mem.eql(u8, r.method, "GET") and std.mem.eql(u8, r.path, "/users/{id}")) found_get_users_id = true;
        if (std.mem.eql(u8, r.method, "DELETE") and std.mem.eql(u8, r.path, "/api/v1/admin/settings")) found_admin = true;
    }
    try std.testing.expect(found_health);
    try std.testing.expect(found_post_users);
    try std.testing.expect(found_get_users_id);
    try std.testing.expect(found_admin);
}

test "integration: router + global middleware + handler" {
    const allocator = std.testing.allocator;

    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    const MwCtx = struct {
        var called: bool = false;
        var handled: bool = false;
    };

    // Add global middleware
    try server.addMiddleware(.{
        .func = struct {
            fn mw(ctx: *Context, next: HandlerFn, _: ?*anyopaque) anyerror!void {
                MwCtx.called = true;
                try next(ctx);
            }
        }.mw,
    });

    // Add route
    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                MwCtx.handled = true;
                try ctx.json(200, "{\"status\":\"ok\"}");
            }
        }.handle,
    });

    // Simulate match
    var matched = server.router.match(allocator, .GET, "/health");
    try std.testing.expect(matched != null);

    if (matched) |*m| {
        defer {
            var it = m.params.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            m.params.deinit();
        }

        var ctx = try Context.init(allocator, .GET, "/health");
        defer ctx.deinit();

        // Execute with middleware chain
        try server.executeWithMiddleware(&ctx, m.route.handler, m.route.combined_middleware);

        try std.testing.expect(MwCtx.called);
        try std.testing.expect(MwCtx.handled);
        try std.testing.expectEqual(@as(u16, 200), ctx.status_code);
        try std.testing.expect(ctx.responded);
    }
}

test "e2e: full middleware chain with error path" {
    const allocator = std.testing.allocator;

    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    const Ctx = struct {
        var hit_count: u32 = 0;
        var last_status: u16 = 0;
    };

    // Global logging middleware
    try server.addMiddleware(.{
        .func = struct {
            fn h(ctx: *Context, next: HandlerFn, _: ?*anyopaque) anyerror!void {
                Ctx.hit_count += 1;
                try next(ctx);
            }
        }.h,
    });

    // Register a route that returns 201
    try server.addRoute(.{
        .method = .POST,
        .path = "/items",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                Ctx.last_status = 201;
                try ctx.json(201, "{\"created\":true}");
            }
        }.handle,
    });

    // Register a route that triggers an error
    try server.addRoute(.{
        .method = .GET,
        .path = "/boom",
        .handler = struct {
            fn handle(_: *Context) anyerror!void {
                return error.SomePanic;
            }
        }.handle,
    });

    // Test 1: happy path
    {
        Ctx.hit_count = 0;
        var matched = server.router.match(allocator, .POST, "/items");
        try std.testing.expect(matched != null);
        if (matched) |*m| {
            defer {
                var it = m.params.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                m.params.deinit();
            }
            var ctx = try Context.init(allocator, .POST, "/items");
            defer ctx.deinit();
            try server.executeWithMiddleware(&ctx, m.route.handler, m.route.combined_middleware);
            try std.testing.expectEqual(@as(u32, 1), Ctx.hit_count);
            try std.testing.expectEqual(@as(u16, 201), ctx.status_code);
            try std.testing.expect(ctx.responded);
        }
    }

    // Test 2: route not found (404)
    {
        const matched = server.router.match(allocator, .GET, "/nonexistent");
        try std.testing.expect(matched == null);
    }

    // Test 3: panic handler returns 500
    {
        Ctx.hit_count = 0;
        var matched = server.router.match(allocator, .GET, "/boom");
        try std.testing.expect(matched != null);
        if (matched) |*m| {
            defer {
                var it = m.params.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                m.params.deinit();
            }
            var ctx = try Context.init(allocator, .GET, "/boom");
            defer ctx.deinit();
            server.executeWithMiddleware(&ctx, m.route.handler, m.route.combined_middleware) catch {
                _ = ctx.sendError(500, "Internal Server Error") catch {};
            };
            try std.testing.expectEqual(@as(u32, 1), Ctx.hit_count);
        }
    }
}

test "router scalability: 200 routes with O(1) child lookup" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    // Register 200 routes across different methods and path depths
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const path = try std.fmt.allocPrint(allocator, "/api/v1/users/{d}", .{i});
        defer allocator.free(path);
        try router.addRoute(.{
            .method = .GET,
            .path = path,
            .handler = struct {
                fn handle(_: *Context) !void {}
            }.handle,
        });
    }
    // Add 50 more with different prefixes
    var j: usize = 0;
    while (j < 50) : (j += 1) {
        const path = try std.fmt.allocPrint(allocator, "/api/v2/items/{d}/details", .{j});
        defer allocator.free(path);
        try router.addRoute(.{
            .method = .GET,
            .path = path,
            .handler = struct {
                fn handle(_: *Context) !void {}
            }.handle,
        });
    }
    // 50 POST routes sharing prefixes
    var k: usize = 0;
    while (k < 50) : (k += 1) {
        const path = try std.fmt.allocPrint(allocator, "/api/v1/users/{d}/posts", .{k});
        defer allocator.free(path);
        try router.addRoute(.{
            .method = .POST,
            .path = path,
            .handler = struct {
                fn handle(_: *Context) !void {}
            }.handle,
        });
    }

    // Verify all 200 routes match correctly
    try std.testing.expect(router.match(allocator, .GET, "/api/v1/users/42") != null);
    try std.testing.expect(router.match(allocator, .POST, "/api/v1/users/7/posts") != null);
    try std.testing.expect(router.match(allocator, .GET, "/api/v2/items/3/details") != null);
    try std.testing.expect(router.match(allocator, .GET, "/nonexistent") == null);

    // Verify listRoutes returns all 200
    const routes = try router.listRoutes(allocator);
    defer {
        for (routes) |r| {
            allocator.free(r.method);
            allocator.free(r.path);
        }
        allocator.free(routes);
    }
    try std.testing.expectEqual(@as(usize, 200), routes.len);
}

test "deepCopy strings escape arena lifetime" {
    const allocator = std.testing.allocator;

    const S = struct { name: []const u8, age: i32 };
    const original = S{ .name = "alice", .age = 30 };
    const copy = try deepCopy(original, allocator);
    defer allocator.free(copy.name);

    // Verify deep copy produced independent memory
    try std.testing.expectEqualStrings("alice", copy.name);
    try std.testing.expectEqual(@as(i32, 30), copy.age);
    try std.testing.expect(copy.name.ptr != original.name.ptr); // different pointers

    // Verify nested struct copy
    const Outer = struct { inner: S, label: []const u8 };
    const outer = Outer{ .inner = S{ .name = "bob", .age = 25 }, .label = "test" };
    const outer_copy = try deepCopy(outer, allocator);
    defer allocator.free(outer_copy.inner.name);
    defer allocator.free(outer_copy.label);

    try std.testing.expectEqualStrings("bob", outer_copy.inner.name);
    try std.testing.expectEqual(@as(i32, 25), outer_copy.inner.age);
    try std.testing.expectEqualStrings("test", outer_copy.label);
}

test "deepCopy non-u8 slices escape arena lifetime" {
    const allocator = std.testing.allocator;

    // Slice of structs: inner string pointers must be deep-copied.
    const Row = struct { name: []const u8, id: i32 };
    const rows = [_]Row{ .{ .name = "a", .id = 1 }, .{ .name = "bb", .id = 2 } };
    const rows_slice: []const Row = &rows;
    const rows_copy = try deepCopy(rows_slice, allocator);
    defer allocator.free(rows_copy);
    defer {
        for (rows_copy) |r| allocator.free(r.name);
    }
    try std.testing.expectEqual(@as(usize, 2), rows_copy.len);
    try std.testing.expectEqualStrings("a", rows_copy[0].name);
    try std.testing.expect(rows_copy[0].name.ptr != rows[0].name.ptr);

    // Slice of slices: inner buffers must be independent.
    const tags = [_][]const u8{ "x", "yy" };
    const tags_slice: []const []const u8 = &tags;
    const tags_copy = try deepCopy(tags_slice, allocator);
    defer allocator.free(tags_copy);
    defer {
        for (tags_copy) |t| allocator.free(t);
    }
    try std.testing.expectEqualStrings("yy", tags_copy[1]);
    try std.testing.expect(tags_copy[1].ptr != tags[1].ptr);
}

test "queryInt returns default on missing param" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    try std.testing.expectEqual(@as(i64, 0), ctx.queryInt(i64, "page", 0));
    try std.testing.expectEqual(@as(i64, 10), ctx.queryInt(i64, "size", 10));
}

test "queryInt parses valid integer" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/test?page=5&size=20");
    defer ctx.deinit();

    try ctx.query.put("page", "5");
    try ctx.query.put("size", "20");

    try std.testing.expectEqual(@as(i64, 5), ctx.queryInt(i64, "page", 0));
    try std.testing.expectEqual(@as(i64, 20), ctx.queryInt(i64, "size", 10));
    try std.testing.expectEqual(@as(i64, 42), ctx.queryInt(i64, "missing", 42));
}

test "deep path matching with RouteGroup" {
    const allocator = std.testing.allocator;
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    // Simulate RouteGroup with deep prefix (exactly as user reports)
    var dashboard_group = server.group("/test/overview/home");
    try dashboard_group.get("/dashboard", struct {
        fn handle(_: *Context) anyerror!void {}
    }.handle, null);

    var crm_group = server.group("/crm");
    try crm_group.get("/statistics", struct {
        fn handle(_: *Context) anyerror!void {}
    }.handle, null);

    var insurance_group = server.group("/insurance");
    try insurance_group.get("/compensation-plan", struct {
        fn handle(_: *Context) anyerror!void {}
    }.handle, null);

    // Existing 2-segment path (control)
    var customer_group = server.group("/customer");
    try customer_group.get("/summary", struct {
        fn handle(_: *Context) anyerror!void {}
    }.handle, null);

    // Test: deep path (4 segments) should match
    var m1 = server.router.match(allocator, .GET, "/test/overview/home/dashboard");
    if (m1 == null) @panic("route match failed: expected GET /test/overview/home/dashboard to resolve " ++
        "(registered as group(\"/test/overview/home\").get(\"/dashboard\")). Fix the prefix join in " ++
        "RouteGroup.get / normalizeRoutePath, or correct the path asserted here.");

    // Test: 2-segment path should match
    var m2 = server.router.match(allocator, .GET, "/customer/summary");
    if (m2 == null) @panic("route match failed: expected GET /customer/summary to resolve " ++
        "(registered as group(\"/customer\").get(\"/summary\")). Fix RouteGroup prefix joining, " ++
        "or correct the path asserted here.");

    // Test: 3-segment paths should match
    var m3 = server.router.match(allocator, .GET, "/crm/statistics");
    if (m3 == null) @panic("route match failed: expected GET /crm/statistics to resolve " ++
        "(registered as group(\"/crm\").get(\"/statistics\")). Fix RouteGroup prefix joining, " ++
        "or correct the path asserted here.");

    var m4 = server.router.match(allocator, .GET, "/insurance/compensation-plan");
    if (m4 == null) @panic("route match failed: expected GET /insurance/compensation-plan to resolve " ++
        "(registered as group(\"/insurance\").get(\"/compensation-plan\")). Fix RouteGroup prefix " ++
        "joining, or correct the path asserted here.");

    // Clean up params
    if (m1) |*m| m.params.deinit();
    if (m2) |*m| m.params.deinit();
    if (m3) |*m| m.params.deinit();
    if (m4) |*m| m.params.deinit();
}

test "bindJsonLoose matches camelCase, skips null, defaults missing" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .POST, "/");
    defer ctx.deinit();
    ctx.body = "{\"userName\":\"alice\",\"id\":null,\"age\":30}";

    const Req = struct {
        user_name: []const u8 = "anon", // snake struct field
        id: ?i64 = 7,
        age: i64 = 0,
    };
    const req = try ctx.bindJsonLoose(Req);
    defer allocator.free(req.user_name); // all slice fields are owned (defaults duped too)
    try std.testing.expectEqualStrings("alice", req.user_name); // camelCase matched
    try std.testing.expectEqual(@as(?i64, 7), req.id); // null → default kept
    try std.testing.expectEqual(@as(i64, 30), req.age); // exact match
}

test "wildcard + exact route coexistence" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    // Register exact route AND wildcard sibling (user's scenario)
    try router.addRoute(.{
        .method = .GET,
        .path = "/crm/statistics",
        .handler = struct {
            fn h(_: *Context) anyerror!void {}
        }.h,
    });
    try router.addRoute(.{
        .method = .GET,
        .path = "/crm/statistics/*",
        .handler = struct {
            fn h(_: *Context) anyerror!void {}
        }.h,
    });
    try router.addRoute(.{
        .method = .GET,
        .path = "/insurance/compensation-plan",
        .handler = struct {
            fn h(_: *Context) anyerror!void {}
        }.h,
    });
    try router.addRoute(.{
        .method = .GET,
        .path = "/insurance/compensation-plan/*",
        .handler = struct {
            fn h(_: *Context) anyerror!void {}
        }.h,
    });

    // Exact paths must match
    try std.testing.expect(router.match(allocator, .GET, "/crm/statistics") != null);
    try std.testing.expect(router.match(allocator, .GET, "/insurance/compensation-plan") != null);

    // Wildcard sub-paths must match
    try std.testing.expect(router.match(allocator, .GET, "/crm/statistics/overview") != null);
    try std.testing.expect(router.match(allocator, .GET, "/insurance/compensation-plan/list") != null);

    // Wrong method must NOT match
    try std.testing.expect(router.match(allocator, .POST, "/crm/statistics") == null);
}

test "path rewriter changes route selection" {
    const allocator = std.testing.allocator;
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    // Register route at rewritten path
    _ = try server.addRoute(.{
        .method = .GET,
        .path = "/rewritten/path",
        .handler = struct {
            fn h(_: *Context) anyerror!void {}
        }.h,
    });

    // Set rewriter: map /old/* → /rewritten/*
    server.setPathRewriter(struct {
        fn rewrite(ctx: *Context) void {
            if (std.mem.startsWith(u8, ctx.path, "/old/")) {
                // Allocate new path in arena — freed on request end
                const suffix = ctx.path["/old/".len..];
                ctx.path = std.fmt.allocPrint(ctx.allocator, "/rewritten/{s}", .{suffix}) catch return;
            }
        }
    }.rewrite);

    // Without rewriter, /old/path would 404. With rewriter, it matches /rewritten/path.
    // Test only the router (connFiber not exercised in unit test)
    var ctx = try Context.init(allocator, .GET, "/old/path");
    defer ctx.deinit();
    const rw = server.path_rewriter.?;
    rw(&ctx);
    defer if (!std.mem.eql(u8, ctx.path, "/old/path")) allocator.free(ctx.path);
    var matched = server.router.match(allocator, .GET, ctx.path);
    defer if (matched) |*m| m.deinit(allocator);
    try std.testing.expect(matched != null);
}

test "WebSocket route path normalization handles leading slash variations" {
    const allocator = std.testing.allocator;
    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 8080 });
    defer server.deinit();

    var group = server.group("/app-api");
    try group.ws("/ws/im", (struct {
        fn connect(_: *Context, _: ?*anyopaque) ?*anyopaque {
            return null;
        }
    }).connect, (struct {
        fn message(_: ?*anyopaque, _: []const u8, _: WsFrameKind) void {}
    }).message, (struct {
        fn close(_: ?*anyopaque) void {}
    }).close, null);

    // Both "/app-api/ws/im" and "app-api/ws/im" should hit the normalized ws_handlers lookup key ("app-api/ws/im")
    try std.testing.expect(server.ws_handlers.contains("app-api/ws/im"));

    const path1 = "/app-api/ws/im";
    const norm1 = if (path1.len > 0 and path1[0] == '/') path1[1..] else path1;
    try std.testing.expect(server.ws_handlers.get(norm1) != null);

    const path2 = "app-api/ws/im";
    const norm2 = if (path2.len > 0 and path2[0] == '/') path2[1..] else path2;
    try std.testing.expect(server.ws_handlers.get(norm2) != null);
}

test "header lookup is case-insensitive" {
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();
    try headers.put("user-agent", "zigmodu-test");
    try headers.put("x-tenant-id", "42");

    try std.testing.expectEqualStrings("zigmodu-test", headerLookup(headers, "User-Agent").?);
    try std.testing.expectEqualStrings("42", headerLookup(headers, "X-Tenant-ID").?);
    try std.testing.expectEqualStrings("zigmodu-test", headerLookup(headers, "user-agent").?);
    try std.testing.expect(headerLookup(headers, "content-type") == null);
}

test "HeaderLimits defaults are sane" {
    const h = HeaderLimits{};
    try std.testing.expect(h.max_count > 0 and h.max_count <= 1024);
    try std.testing.expect(h.max_total_bytes > 0 and h.max_total_bytes <= 1024 * 1024);
}

test "connection_stack_size flows from Config to the accept-loop spawn" {
    const allocator = std.testing.allocator;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .connection_stack_size = 4 * 1024 * 1024 });
    defer server.deinit();
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), server.connection_stack_size);
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), Server.effectiveStackSize(server.connection_stack_size));

    // Below the platform floor the request is raised, not honoured: smaller
    // sizes fail `pthread_create` with EINVAL (see `min_thread_stack_size`).
    try std.testing.expectEqual(Server.min_thread_stack_size, Server.effectiveStackSize(128 * 1024));
    try std.testing.expectEqual(Server.min_thread_stack_size, Server.effectiveStackSize(0));

    var defaults = Server.init(std.testing.io, allocator, 8080);
    defer defaults.deinit();
    try std.testing.expectEqual(@as(usize, 128 * 1024), defaults.connection_stack_size);
    try std.testing.expectEqual(Server.min_thread_stack_size, Server.effectiveStackSize(defaults.connection_stack_size));
}

const WsE2eState = struct {
    messages: usize = 0,
    pings: usize = 0,
    closed: bool = false,
};
var ws_e2e_state = WsE2eState{};

test "WebSocket fiber path receives client frames and fires on_close" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    ws_e2e_state = .{};

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0 });
    defer server.deinit();
    var group = server.group("");
    try group.ws("ws", (struct {
        fn connect(_: *Context, _: ?*anyopaque) ?*anyopaque {
            return @ptrCast(&ws_e2e_state);
        }
    }).connect, (struct {
        fn message(session: ?*anyopaque, _: []const u8, _: WsFrameKind) void {
            const st: *WsE2eState = @ptrCast(@alignCast(session.?));
            st.messages += 1;
        }
    }).message, (struct {
        fn close(session: ?*anyopaque) void {
            const st: *WsE2eState = @ptrCast(@alignCast(session.?));
            st.closed = true;
        }
    }).close, null);

    // Fiber path: connFiber runs on an io worker thread while the accept loop
    // runs on this spawned thread. NOTE: glibc aarch64 PTHREAD_STACK_MIN is
    // 128 KiB and pthread_create needs TLS headroom beyond that — a custom
    // stack_size near the minimum returns EINVAL (panic in std). Use 2 MiB.
    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    defer th.join();
    // Before the join (defer is LIFO): a failing assertion must not leave
    // `start()` blocked in `accept`, because then the join waits forever and the
    // failure reads as a hang. Same trap as the handshake test below.
    defer server.stop();

    var port: u16 = 0;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (server.listener) |*l| {
            port = l.socket.address.getPort();
            break;
        }
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(port != 0);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    var closed_early = false;
    defer if (!closed_early) stream.close(std.testing.io);

    // Handshake.
    var wbuf: [512]u8 = undefined;
    var w = stream.writer(std.testing.io, &wbuf);
    const handshake = "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    try w.interface.writeAll(handshake);
    try w.interface.flush();

    // Read the 101 with raw poll+read (io-based reads can hang when the io is
    // shared across threads — see im/WsFramer.zig readFull).
    var fds = [_]std.posix.pollfd{.{
        .fd = stream.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, 3000);
    try std.testing.expect(ready > 0);
    var resp: [512]u8 = undefined;
    const n = try std.posix.read(stream.socket.handle, &resp);
    try std.testing.expect(std.mem.indexOf(u8, resp[0..n], "101") != null);

    // Send a masked text frame "hi".
    var frame_buf: [64]u8 = undefined;
    const payload = "hi";
    const mask: [4]u8 = .{ 1, 2, 3, 4 };
    frame_buf[0] = 0x81;
    frame_buf[1] = 0x80 | @as(u8, @intCast(payload.len));
    frame_buf[2..6].* = mask;
    for (payload, 0..) |c, i| frame_buf[6 + i] = c ^ mask[i % 4];
    try w.interface.writeAll(frame_buf[0 .. 6 + payload.len]);
    try w.interface.flush();

    // Wait (bounded) for on_message.
    tries = 0;
    while (ws_e2e_state.messages == 0 and tries < 300) : (tries += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), ws_e2e_state.messages);

    // Closing the client must trigger on_close on the server fiber.
    stream.close(std.testing.io);
    closed_early = true;
    tries = 0;
    while (!ws_e2e_state.closed and tries < 300) : (tries += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(ws_e2e_state.closed);

    server.stop();
}

/// A masked client frame (RFC 6455 §5.1 — a server MUST reject unmasked ones).
fn buildClientFrame(out: []u8, opcode: u8, payload: []const u8) []u8 {
    const mask = [4]u8{ 1, 2, 3, 4 };
    var n: usize = 0;
    out[0] = 0x80 | opcode;
    if (payload.len < 126) {
        out[1] = 0x80 | @as(u8, @intCast(payload.len));
        n = 2;
    } else if (payload.len < 65536) {
        out[1] = 0x80 | 126;
        std.mem.writeInt(u16, out[2..4], @intCast(payload.len), .big);
        n = 4;
    } else {
        out[1] = 0x80 | 127;
        std.mem.writeInt(u64, out[2..10], @intCast(payload.len), .big);
        n = 10;
    }
    @memcpy(out[n..][0..4], &mask);
    n += 4;
    for (payload, 0..) |b, i| out[n + i] = b ^ mask[i % 4];
    return out[0 .. n + payload.len];
}

/// Send `req` on a fresh connection to `port` and return however many bytes of
/// the response arrive first. The WS handshake tests need to see the status line
/// the server actually wrote, which the normal `Context` response path is not
/// involved in.
fn wsProbe(port: u16, req: []const u8, out: []u8) usize {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return 0;
    var stream = addr.connect(std.testing.io, .{ .mode = .stream }) catch return 0;
    defer stream.close(std.testing.io);

    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(std.testing.io, &wbuf);
    w.interface.writeAll(req) catch return 0;
    w.interface.flush() catch return 0;

    var pfds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    if ((std.posix.poll(&pfds, 3000) catch 0) == 0) return 0;
    return std.posix.read(stream.socket.handle, out) catch 0;
}

/// Counts `on_connect` calls. Atomic because the server runs on its own thread
/// and the assertions below read it from the test thread.
/// Wait (bounded) for `on_connect` to have run `want` times, then assert.
///
/// The upgrade path writes `101` before it calls the application's `on_connect`,
/// so a client that has just read the status line can legitimately arrive before
/// the server thread has incremented the counter. The wait is 2s — far more than
/// the handshake needs, and short enough that a genuine regression still fails
/// the test rather than the job.
fn expectConnects(want: usize) !void {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (ws_upgrade_state.connects.load(.monotonic) == want) return;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch |err| {
            // A failed sleep only makes the wait shorter than intended; the
            // assertion below still reports the state that was actually
            // observed, which is what this test is about.
            std.log.debug("[test] expectConnects sleep: {s}", .{@errorName(err)});
        };
    }
    try std.testing.expectEqual(want, ws_upgrade_state.connects.load(.monotonic));
}

const WsUpgradeState = struct { connects: std.atomic.Value(usize) = .init(0) };
var ws_upgrade_state = WsUpgradeState{};

test "WebSocket upgrade: bad handshakes get 400 and no 101, a Connection token list gets 101" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    ws_upgrade_state = .{ .connects = .init(0) };

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0 });
    defer server.deinit();
    var group = server.group("");
    try group.ws("ws", (struct {
        fn connect(_: *Context, _: ?*anyopaque) ?*anyopaque {
            _ = ws_upgrade_state.connects.fetchAdd(1, .monotonic);
            return @ptrCast(&ws_upgrade_state);
        }
    }).connect, (struct {
        fn message(_: ?*anyopaque, _: []const u8, _: WsFrameKind) void {}
    }).message, (struct {
        fn close(_: ?*anyopaque) void {}
    }).close, null);

    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    defer th.join();
    // Declared *after* the join, so it runs *before* it (defer is LIFO): every
    // exit from this test — including the `try` assertions below — has to stop
    // the server first. Without it a failed assertion leaves `start()` blocked
    // in `accept`, and the deferred `join()` waits forever: an assertion failure
    // becomes a hang, which is how this test turned a red CI into a 25-minute
    // timeout instead of a one-line failure.
    defer server.stop();

    var port: u16 = 0;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (server.listener) |*l| {
            port = l.socket.address.getPort();
            break;
        }
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(port != 0);

    // The three required headers, minus whichever one a case drops.
    const head = "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";
    var resp: [512]u8 = undefined;

    // `Sec-WebSocket-Version` is mandatory and must be 13 (RFC 6455 §4.2.1/§4.4).
    var n = wsProbe(port, head ++ "Connection: Upgrade\r\n\r\n", &resp);
    try std.testing.expect(std.mem.startsWith(u8, resp[0..n], "HTTP/1.1 400"));
    n = wsProbe(port, head ++ "Connection: Upgrade\r\nSec-WebSocket-Version: 8\r\n\r\n", &resp);
    try std.testing.expect(std.mem.startsWith(u8, resp[0..n], "HTTP/1.1 400"));

    // `Connection` present but without the `upgrade` token.
    n = wsProbe(port, head ++ "Connection: keep-alive\r\nSec-WebSocket-Version: 13\r\n\r\n", &resp);
    try std.testing.expect(std.mem.startsWith(u8, resp[0..n], "HTTP/1.1 400"));

    // No key at all.
    n = wsProbe(port, "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n\r\n", &resp);
    try std.testing.expect(std.mem.startsWith(u8, resp[0..n], "HTTP/1.1 400"));

    // None of those reached the upgrade path: no 101 was written and the
    // application's `on_connect` never ran.
    try std.testing.expectEqual(@as(usize, 0), ws_upgrade_state.connects.load(.monotonic));

    // The shape browsers actually send — `Connection` is a token list, so an
    // equality check against "Upgrade" would have rejected this.
    n = wsProbe(port, "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", &resp);
    try std.testing.expect(std.mem.startsWith(u8, resp[0..n], "HTTP/1.1 101"));
    // The 101 is written *before* `on_connect` runs, so the count is not
    // guaranteed to be visible the moment the client has the status line in
    // hand. Waiting for it turns this into an assertion about the server's
    // behaviour instead of about which thread the scheduler ran first — on
    // Linux the old bare read lost that race and failed here.
    try expectConnects(1);

    server.stop();
}

test "connectionHasUpgrade is a token-list test, not an equality test" {
    try std.testing.expect(connectionHasUpgrade("Upgrade"));
    try std.testing.expect(connectionHasUpgrade("upgrade"));
    // Browsers send exactly this.
    try std.testing.expect(connectionHasUpgrade("keep-alive, Upgrade"));
    try std.testing.expect(connectionHasUpgrade("Upgrade,keep-alive"));
    try std.testing.expect(connectionHasUpgrade("keep-alive , upgrade"));
    try std.testing.expect(!connectionHasUpgrade("keep-alive"));
    // Substring, not token.
    try std.testing.expect(!connectionHasUpgrade("xyzupgrade"));
    try std.testing.expect(!connectionHasUpgrade(""));
}

const WsBigFrameState = struct { bytes: usize = 0, kind: WsFrameKind = .binary };
var ws_big_frame_state = WsBigFrameState{};

test "WebSocket fiber path delivers a frame larger than the 4 KiB read buffer" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    ws_big_frame_state = .{};

    // The pool is what production uses; it hands out 4 KiB slices and only takes
    // back slices of at least that length, so `readFrame` must not resize its
    // caller's buffer even when the frame does not fit in it. Declared before
    // the server so it outlives `server.deinit()`.
    var pool = BufferPool.init(allocator, std.testing.io, 4);
    defer pool.deinit();

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0 });
    defer server.deinit();
    server.setWsBufferPool(&pool);

    var group = server.group("");
    try group.ws("ws", (struct {
        fn connect(_: *Context, _: ?*anyopaque) ?*anyopaque {
            return @ptrCast(&ws_big_frame_state);
        }
    }).connect, (struct {
        fn message(session: ?*anyopaque, msg: []const u8, kind: WsFrameKind) void {
            const st: *WsBigFrameState = @ptrCast(@alignCast(session.?));
            st.bytes = msg.len;
            st.kind = kind;
        }
    }).message, (struct {
        fn close(_: ?*anyopaque) void {}
    }).close, null);

    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    defer th.join();
    // Before the join (defer is LIFO): see the handshake test below — without
    // this, a failed assertion hangs here instead of failing.
    defer server.stop();

    var port: u16 = 0;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (server.listener) |*l| {
            port = l.socket.address.getPort();
            break;
        }
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(port != 0);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    var closed_early = false;
    defer if (!closed_early) stream.close(std.testing.io);

    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(std.testing.io, &wbuf);
    try w.interface.writeAll("GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");
    try w.interface.flush();

    var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expect(try std.posix.poll(&fds, 3000) > 0);
    var resp: [512]u8 = undefined;
    const n = try std.posix.read(stream.socket.handle, &resp);
    try std.testing.expect(std.mem.indexOf(u8, resp[0..n], "101") != null);

    // 10 KiB: above the 4 KiB pooled buffer, so it used to come back as
    // error.PayloadTooLarge and drop the connection silently.
    const payload_len = 10 * 1024;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 17);

    const wire = try allocator.alloc(u8, payload_len + 14);
    defer allocator.free(wire);
    try w.interface.writeAll(buildClientFrame(wire, 0x2, payload));
    try w.interface.flush();

    tries = 0;
    while (ws_big_frame_state.bytes == 0 and tries < 500) : (tries += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expectEqual(payload_len, ws_big_frame_state.bytes);
    try std.testing.expectEqual(WsFrameKind.binary, ws_big_frame_state.kind);

    // The pooled buffer came back whole: `readFrame` never resized it, so
    // `BufferPool.release` accepted it instead of dropping it on the floor.
    stream.close(std.testing.io);
    closed_early = true;
    tries = 0;
    while (pool.stats().free < 1 and tries < 300) : (tries += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), pool.stats().free);

    server.stop();
}

test "typed identity getters read canonical attrs" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    try std.testing.expect(ctx.userId() == null);
    try std.testing.expectError(error.Unauthorized, ctx.requireUserId());

    try ctx.setIdentity(.{ .user_id = "42", .tenant_id = "shop1", .roles = "admin,ops" });
    try std.testing.expectEqualStrings("42", ctx.userId().?);
    try std.testing.expectEqual(@as(?i64, 42), ctx.userIdInt(i64));
    try std.testing.expectEqual(@as(i64, 42), try ctx.requireUserIdInt(i64));
    try std.testing.expectEqualStrings("shop1", ctx.tenantId().?);
    try std.testing.expectEqualStrings("admin,ops", ctx.rolesCsv().?);

    const snap = ctx.identity();
    try std.testing.expectEqualStrings("42", snap.user_id.?);
    try std.testing.expectEqualStrings("shop1", snap.tenant_id.?);
}

test "state(T) returns the route state and names the missing-state case" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    const RouteState = struct { hits: u32 = 0 };
    var st = RouteState{};

    // A route registered without state (legacy RouteGroup default) is an error,
    // not an inline unreachable.
    try std.testing.expectError(error.NoRouteState, ctx.state(RouteState));

    ctx.user_data = &st;
    const got = try ctx.state(RouteState);
    try std.testing.expect(got == &st);
    got.hits += 1;
    try std.testing.expectEqual(@as(u32, 1), st.hits);
}

test "trace id is an attr the log side can read" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    // Nothing binds one unless the app does — no ambient trace state.
    try std.testing.expect(ctx.traceId() == null);

    try ctx.setTraceId("4bf92f3577b34da6a3ce929d0e0e4736");
    try std.testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", ctx.traceId().?);
    // Same attr, so the generic accessor sees it too.
    try std.testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", ctx.getAttr("trace_id").?);

    // Rebinding replaces the value (and the context frees the old copy).
    try ctx.setTraceId("00000000000000000000000000000000");
    try std.testing.expectEqualStrings("00000000000000000000000000000000", ctx.traceId().?);

    // Sanity: it is not the tenant/user attrs.
    try std.testing.expect(ctx.userId() == null);
    try std.testing.expect(ctx.tenantId() == null);
}

test "typed attr getters parse int and enum" {
    const allocator = std.testing.allocator;
    const Portal = enum { admin, shop };
    var ctx = try Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    try ctx.setAttr("level", "7");
    try ctx.setAttr("portal", "shop");
    try ctx.setAttr("bad", "NaN");
    try std.testing.expectEqual(@as(?u32, 7), ctx.getAttrInt(u32, "level"));
    try std.testing.expectEqual(@as(?Portal, .shop), ctx.getAttrEnum(Portal, "portal"));
    try std.testing.expect(ctx.getAttrInt(u32, "bad") == null);
    try std.testing.expect(ctx.getAttrEnum(Portal, "bad") == null);
    try std.testing.expect(ctx.getAttrInt(u32, "missing") == null);
}

test "envelope dialects render expected shapes" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/");
    defer ctx.deinit();

    // default (CommonResult)
    try ctx.ok("{\"a\":1}");
    try std.testing.expectEqualStrings("{\"code\":0,\"msg\":\"ok\",\"data\":{\"a\":1}}", ctx.response_body.items);

    ctx.response_body.clearRetainingCapacity();
    ctx.setEnvelope(.thinkphp);
    try ctx.fail("余额不足");
    try std.testing.expectEqualStrings("{\"code\":0,\"msg\":\"余额不足\",\"data\":null}", ctx.response_body.items);

    ctx.response_body.clearRetainingCapacity();
    try ctx.unauth("请先登录");
    try std.testing.expectEqual(@as(u16, 401), ctx.status_code);
    try std.testing.expectEqualStrings("{\"code\":-1,\"msg\":\"请先登录\",\"data\":null}", ctx.response_body.items);

    ctx.response_body.clearRetainingCapacity();
    ctx.setEnvelope(.ruoyi);
    const Item = struct { id: u32 };
    try ctx.paginated(&[_]Item{.{ .id = 1 }}, 9);
    try std.testing.expectEqualStrings("{\"code\":0,\"msg\":\"success\",\"rows\":[{\"id\":1}],\"total\":9}", ctx.response_body.items);

    // msg with quotes must be JSON-escaped
    ctx.response_body.clearRetainingCapacity();
    ctx.setEnvelope(.default);
    try ctx.failCode(42, "say \"hi\"");
    try std.testing.expectEqualStrings("{\"code\":42,\"msg\":\"say \\\"hi\\\"\",\"data\":null}", ctx.response_body.items);
}

// ── connection backpressure / header deadline ──────────────────────────────

/// socketpair helper shared by the StreamReader deadline tests.
fn testSocketPair() ?[2]std.posix.socket_t {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return fds,
        else => return null,
    }
}

// ── request boundary (header / framing) tests ──────────────────────────────

/// Drive `RequestParser` over a real socketpair, the way `connFiber` does it:
/// one shared `StreamReader`, the request line prefetched with `&.{}`, then
/// `parseAfterRequestLine`. Wire-level, so the tests see the same bytes a peer
/// would send (not a hand-rolled buffer).
const ParserProbe = struct {
    peer: std.posix.socket_t,
    stream: std.Io.net.Stream,
    reader: StreamReader,
    parser: RequestParser,

    /// Heap-allocated on purpose: `StreamReader.setup` stores a pointer to its
    /// own buffer, so the struct must not move after setup. Writes `payload`
    /// into the peer end; `null` when no socketpair is available (the caller
    /// turns that into `SkipZigTest`).
    fn create(allocator: std.mem.Allocator, payload: []const u8) !?*ParserProbe {
        const fds = testSocketPair() orelse return null;
        const probe = try allocator.create(ParserProbe);
        probe.* = .{
            .peer = fds[1],
            .stream = .{ .socket = .{ .handle = fds[0], .address = undefined } },
            .reader = undefined,
            .parser = RequestParser.init(allocator),
        };
        probe.reader.setup(probe.stream, std.testing.io);
        probe.reader.setHeaderDeadline(2000);
        _ = std.posix.system.write(fds[1], payload.ptr, payload.len);
        return probe;
    }

    fn destroy(self: *ParserProbe) void {
        self.stream.close(std.testing.io);
        _ = std.posix.system.close(self.peer);
    }

    fn parse(self: *ParserProbe) !ParsedRequest {
        const first = try self.reader.readUntilDelimiterOrEof(&.{}, '\n') orelse return error.ClientClosed;
        return self.parser.parseAfterRequestLine(&self.reader, first, 1 * 1024 * 1024, .{}, 100);
    }
};

test "request headers: OWS after the colon is optional, an unparsable line is a 400" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `Content-Length:5` — no OWS — is a valid header line (RFC 9110 §5.6.3 OWS
    // may be zero octets). The old parser only matched ": " and dropped the
    // line, leaving this body in the reader to be served as the next request.
    const smuggled = "GET /admin HTTP/1.1\r\nHost: y\r\n\r\n";
    const payload = try std.fmt.allocPrint(a, "POST /upload HTTP/1.1\r\nHost:x\r\nContent-Length:{d}\r\n\r\n{s}", .{ smuggled.len, smuggled });

    var probe = try ParserProbe.create(a, payload) orelse return error.SkipZigTest;
    defer probe.destroy();

    var request = try probe.parse();
    defer request.deinit(a);

    try std.testing.expectEqualStrings("x", request.headers.get("host") orelse "<missing>");
    const expected_len = try std.fmt.allocPrint(a, "{d}", .{smuggled.len});
    try std.testing.expectEqualStrings(expected_len, request.headers.get("content-length") orelse "<missing>");
    try std.testing.expect(request.body != null);
    try std.testing.expectEqualStrings(smuggled, request.body.?);
    try std.testing.expectEqual(Method.POST, request.method);
    try std.testing.expectEqualStrings("/upload", request.path);

    // A line that is not a header field at all must be refused, never skipped.
    const broken = try ParserProbe.create(a, "GET / HTTP/1.1\r\nHost: x\r\nBrokenHeaderLine\r\n\r\n") orelse return error.SkipZigTest;
    defer broken.destroy();
    try std.testing.expectError(error.InvalidHeader, broken.parse());

    // Same for a line that starts with a space (obs-fold continuation).
    const folded = try ParserProbe.create(a, "GET / HTTP/1.1\r\nHost: x\r\n\tfolded: value\r\n\r\n") orelse return error.SkipZigTest;
    defer folded.destroy();
    try std.testing.expectError(error.InvalidHeader, folded.parse());
}

test "request body framing: Transfer-Encoding and conflicting Content-Length are refused" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct {
        payload: []const u8,
        expected: anyerror,
    }{
        // Chunked request: no decoder exists here, so the chunked body would be
        // read back as the next request line (the audit's "1;GET /admin" shape).
        .{ .payload = "POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1;GET /admin HTTP/1.1\r\n\r\n", .expected = error.TransferEncodingNotSupported },
        .{ .payload = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello", .expected = error.ConflictingBodyFraming },
        .{ .payload = "POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\nhello", .expected = error.ConflictingBodyFraming },
        // Repeated / unparsable Content-Length: last-wins and "parse what we
        // can" both let two parsers disagree about the body length.
        .{ .payload = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello", .expected = error.DuplicateContentLength },
        .{ .payload = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\nhello", .expected = error.InvalidContentLength },
        .{ .payload = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\nhello", .expected = error.InvalidContentLength },
        .{ .payload = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: +5\r\n\r\nhello", .expected = error.InvalidContentLength },
        .{ .payload = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 1_0\r\n\r\nhello", .expected = error.InvalidContentLength },
        .{ .payload = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length:\r\n\r\n", .expected = error.InvalidContentLength },
        .{ .payload = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5 5\r\n\r\nhello", .expected = error.InvalidContentLength },
    };

    for (cases) |case| {
        const probe = try ParserProbe.create(a, case.payload) orelse return error.SkipZigTest;
        defer probe.destroy();
        try std.testing.expectError(case.expected, probe.parse());
    }

    // Control: the same request with one well-formed Content-Length parses, and
    // the body is consumed (so it can never be read back as a request line).
    const ok = try ParserProbe.create(a, "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello") orelse return error.SkipZigTest;
    defer ok.destroy();
    var request = try ok.parse();
    defer request.deinit(a);
    try std.testing.expect(request.body != null);
    try std.testing.expectEqualStrings("hello", request.body.?);
}

test "request line: unknown methods are refused, not folded into GET" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Method token contract: known methods only. `PROPFIND`/`get`/`GETX` used to
    // become `.GET`.
    try std.testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try std.testing.expectEqual(Method.DELETE, Method.fromString("DELETE").?);
    try std.testing.expect(Method.fromString("GETX") == null);
    try std.testing.expect(Method.fromString("get") == null);
    try std.testing.expect(Method.fromString("PROPFIND") == null);
    try std.testing.expect(Method.fromString("") == null);

    const payloads = [_][]const u8{
        // The audit's chunk-size-as-request-line shape.
        "1;GET /admin HTTP/1.1\r\nHost: x\r\n\r\n",
        "GETX /admin HTTP/1.1\r\nHost: x\r\n\r\n",
        "PROPFIND /admin HTTP/1.1\r\nHost: x\r\n\r\n",
    };
    for (payloads) |payload| {
        const probe = try ParserProbe.create(a, payload) orelse return error.SkipZigTest;
        defer probe.destroy();
        try std.testing.expectError(error.InvalidMethod, probe.parse());
    }
}

test "request line: extra fields and non-HTTP/1.x versions are refused" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const payloads = [_][]const u8{
        "GET / HTTP/1.1 extra\r\nHost: x\r\n\r\n", // trailing field
        "GET /verylongpath\r\n", // request-target without a version field
        "GET /\r\n", // shorter than any legal request line
        "GET / HTTP/2.0\r\nHost: x\r\n\r\n", // version for another parser
        "GET / HTTP/0.9\r\nHost: x\r\n\r\n",
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", // H2 preface with HTTP/2 disabled
    };
    for (payloads) |payload| {
        const probe = try ParserProbe.create(a, payload) orelse return error.SkipZigTest;
        defer probe.destroy();
        try std.testing.expectError(error.InvalidRequest, probe.parse());
    }

    // Control: HTTP/1.0 and extra SP runs still parse (recipients MAY parse on
    // whitespace-delimited word boundaries).
    const ok = try ParserProbe.create(a, "GET  /ping HTTP/1.0\r\nHost: x\r\n\r\n") orelse return error.SkipZigTest;
    defer ok.destroy();
    var request = try ok.parse();
    defer request.deinit(a);
    try std.testing.expectEqualStrings("/ping", request.path);
}

test "StreamReader header deadline fires on a silent peer" {
    const fds = testSocketPair() orelse return error.SkipZigTest;
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    var reader: StreamReader = undefined;
    reader.setup(stream, std.testing.io);
    reader.setHeaderDeadline(80);

    // Peer sends nothing: the deadline must cut the read instead of blocking.
    try std.testing.expectError(error.ReadFailed, reader.readUntilDelimiterOrEof(&.{}, '\n'));
    try std.testing.expect(reader.timed_out);
}

test "StreamReader header deadline leaves a prompt peer alone" {
    const fds = testSocketPair() orelse return error.SkipZigTest;
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    var reader: StreamReader = undefined;
    reader.setup(stream, std.testing.io);
    reader.setHeaderDeadline(2000);
    _ = std.posix.system.write(fds[1], "GET / HTTP/1.1\r\n", 16);

    const line = try reader.readUntilDelimiterOrEof(&.{}, '\n');
    try std.testing.expect(line != null);
    try std.testing.expect(std.mem.startsWith(u8, line.?, "GET / HTTP/1.1"));
    try std.testing.expect(!reader.timed_out);

    // Headers complete → deadline cleared → the body follows the normal read
    // path (unbounded), so a slow upload is not killed by the header deadline.
    reader.clearHeaderDeadline();
    _ = std.posix.system.write(fds[1], "BODY", 4);
    var body: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try reader.readAll(&body));
    try std.testing.expectEqualStrings("BODY", &body);
    try std.testing.expect(!reader.timed_out);
}

test "header deadline answers 408 and max_connections sheds the flood" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .max_connections = 1,
        .over_limit_response = .close,
        .header_timeout_ms = 300,
    });
    defer server.deinit();
    var group = server.group("");
    try group.get("ping", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.jsonStruct(200, .{ .ok = true });
        }
    }.h, null);

    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    defer th.join();

    var port: u16 = 0;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (server.listener) |*l| {
            port = l.socket.address.getPort();
            break;
        }
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(port != 0);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // 1) Occupy the single slot with a silent connection.
    var holder = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer holder.close(std.testing.io);
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
    try std.testing.expectEqual(@as(u64, 1), server.active_connections.load(.monotonic));

    // 2) A second connection is over the limit → closed without a response.
    var rejected = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer rejected.close(std.testing.io);
    var rbuf: [64]u8 = undefined;
    var pfds = [_]std.posix.pollfd{.{ .fd = rejected.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = try std.posix.poll(&pfds, 2000);
    try std.testing.expect(ready > 0);
    const rn = try std.posix.read(rejected.socket.handle, &rbuf);
    try std.testing.expectEqual(@as(usize, 0), rn); // immediate EOF, no 503 body

    // 3) The silent holder trips the header deadline: 408 then close.
    var hbuf: [256]u8 = undefined;
    var hpds = [_]std.posix.pollfd{.{ .fd = holder.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const hready = try std.posix.poll(&hpds, 3000);
    try std.testing.expect(hready > 0);
    const hn = try std.posix.read(holder.socket.handle, &hbuf);
    try std.testing.expect(hn > 0);
    try std.testing.expect(std.mem.indexOf(u8, hbuf[0..hn], "408") != null);

    // 4) Slot released → a normal request is served again.
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
    try std.testing.expectEqual(@as(u64, 0), server.active_connections.load(.monotonic));
    var ok_stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer ok_stream.close(std.testing.io);
    const req = "GET /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    _ = std.posix.system.write(ok_stream.socket.handle, req.ptr, req.len);
    var obuf: [512]u8 = undefined;
    var opds = [_]std.posix.pollfd{.{ .fd = ok_stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const oready = try std.posix.poll(&opds, 3000);
    try std.testing.expect(oready > 0);
    const on = try std.posix.read(ok_stream.socket.handle, &obuf);
    try std.testing.expect(on > 0);
    try std.testing.expect(std.mem.startsWith(u8, obuf[0..on], "HTTP/1.1 200"));

    // Required: the deferred th.join() runs before server.deinit(), so the
    // accept loop must be told to exit or join blocks forever.
    server.stop();
}

test "over-limit connections get 503 when configured" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .max_connections = 1,
        .over_limit_response = .unavailable,
        .header_timeout_ms = 3000,
    });
    defer server.deinit();
    var group = server.group("");
    try group.get("ping", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.jsonStruct(200, .{ .ok = true });
        }
    }.h, null);

    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    defer th.join();

    var port: u16 = 0;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (server.listener) |*l| {
            port = l.socket.address.getPort();
            break;
        }
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(port != 0);
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    var holder = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer holder.close(std.testing.io);
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(100), .real) catch {};

    var rejected = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer rejected.close(std.testing.io);
    var buf: [256]u8 = undefined;
    var pfds = [_]std.posix.pollfd{.{ .fd = rejected.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = try std.posix.poll(&pfds, 2000);
    try std.testing.expect(ready > 0);
    const n = try std.posix.read(rejected.socket.handle, &buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "503") != null);

    server.stop();
}

test "a chunked-bodied request is refused instead of becoming a second request" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .header_timeout_ms = 2000,
    });
    defer server.deinit();

    var group = server.group("");
    const ping = struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.jsonStruct(200, .{ .ok = true });
        }
    }.h;
    try group.get("ping", ping, null);
    try group.post("ping", ping, null);
    try group.get("admin", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.jsonStruct(200, .{ .handler = "admin-was-served" });
        }
    }.h, null);

    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    defer th.join();
    defer server.stop();

    var port: u16 = 0;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (server.listener) |*l| {
            port = l.socket.address.getPort();
            break;
        }
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(port != 0);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // Both smuggling shapes send one request and get one second request served
    // out of it: a front-end that decodes `Transfer-Encoding` passes the
    // chunked body through, while a back-end that ignores the header reads the
    // left-over bytes as its next request line.
    const payloads = [_][]const u8{
        // Audit shape: the chunk-size line is a request line to that parser.
        "POST /ping HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1;GET /admin HTTP/1.1\r\nHost: x\r\n\r\n",
        // The chunked body simply starts with a complete request.
        "POST /ping HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nGET /admin HTTP/1.1\r\nHost: x\r\n\r\n",
    };

    var buf: [1024]u8 = undefined;
    for (payloads) |req| {
        var client = try addr.connect(std.testing.io, .{ .mode = .stream });
        defer client.close(std.testing.io);
        _ = std.posix.system.write(client.socket.handle, req.ptr, req.len);

        var pfds = [_]std.posix.pollfd{.{ .fd = client.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        try std.testing.expect(try std.posix.poll(&pfds, 3000) > 0);
        const n = try std.posix.read(client.socket.handle, &buf);
        try std.testing.expect(n > 0);
        try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 400"));

        // Nothing after the refusal: no served handler and no second response.
        var got_eof = false;
        var rounds: usize = 0;
        while (rounds < 20) : (rounds += 1) {
            var dpfds = [_]std.posix.pollfd{.{ .fd = client.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&dpfds, 500) <= 0) break;
            const dn = try std.posix.read(client.socket.handle, &buf);
            if (dn == 0) {
                got_eof = true;
                break;
            }
            try std.testing.expect(std.mem.indexOf(u8, buf[0..dn], "admin-was-served") == null);
            try std.testing.expect(std.mem.indexOf(u8, buf[0..dn], "HTTP/1.1 200") == null);
        }
        try std.testing.expect(got_eof);
    }
}

const SlowWsState = struct {
    framer: WsFramer = undefined,
    write_error: ?anyerror = null,
    closed: bool = false,
};
var slow_ws_state = SlowWsState{};

test "WS write timeout disconnects a peer that stops reading" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    slow_ws_state = .{};

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .ws_write_timeout_ms = 200,
    });
    defer server.deinit();

    var group = server.group("");
    try group.ws("ws", (struct {
        fn connect(_: *Context, framer: *anyopaque) ?*anyopaque {
            // Copy by value: the pointer targets a connFiber stack local.
            slow_ws_state.framer = @as(*WsFramer, @ptrCast(@alignCast(framer))).*;
            return @ptrCast(&slow_ws_state);
        }
    }).connect, (struct {
        fn message(session: ?*anyopaque, _: []const u8, _: WsFrameKind) void {
            const st: *SlowWsState = @ptrCast(@alignCast(session.?));
            var payload: [64 * 1024]u8 = @splat('x');
            var i: usize = 0;
            while (i < 200) : (i += 1) {
                st.framer.writeBinary(&payload) catch |err| {
                    st.write_error = err;
                    return;
                };
            }
        }
    }).message, (struct {
        fn close(session: ?*anyopaque) void {
            const st: *SlowWsState = @ptrCast(@alignCast(session.?));
            st.closed = true;
        }
    }).close, null);

    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    defer th.join();

    var port: u16 = 0;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (server.listener) |*l| {
            port = l.socket.address.getPort();
            break;
        }
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(port != 0);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    var closed_early = false;
    defer if (!closed_early) stream.close(std.testing.io);

    var wbuf: [512]u8 = undefined;
    var w = stream.writer(std.testing.io, &wbuf);
    const handshake = "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    try w.interface.writeAll(handshake);
    try w.interface.flush();

    // Read the 101, then deliberately stop reading anything.
    var rbuf: [512]u8 = undefined;
    var pfds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&pfds, 3000);
    _ = try std.posix.read(stream.socket.handle, &rbuf);

    // Trigger the server-side push loop with one masked binary frame.
    var frame_buf: [16]u8 = undefined;
    frame_buf[0] = 0x82; // FIN + binary
    frame_buf[1] = 0x80 | 2; // masked, 2-byte payload
    frame_buf[2..6].* = .{ 9, 9, 9, 9 };
    frame_buf[6] = 'g' ^ 9;
    frame_buf[7] = 'o' ^ 9;
    _ = std.posix.system.write(stream.socket.handle, &frame_buf, 8);

    // The send buffer is tiny (SO_SNDBUF=2048 via tuneSocket), so the push
    // loop must hit the 200ms send timeout quickly instead of hanging.
    tries = 0;
    while (slow_ws_state.write_error == null and tries < 500) : (tries += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(slow_ws_state.write_error != null);
    try std.testing.expectEqual(error.WriteTimeout, slow_ws_state.write_error.?);

    // Closing the client lets the read loop end and on_close fire.
    stream.close(std.testing.io);
    closed_early = true;
    tries = 0;
    while (!slow_ws_state.closed and tries < 300) : (tries += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(slow_ws_state.closed);

    server.stop();
}

test "parseFormBody decodes keys and values like the query string" {
    const allocator = std.testing.allocator;
    var form = try parseFormBody(allocator, "name=%E5%BC%A0%E4%B8%89&role_id%5B0%5D=7&note=a+b&plain=v", 1000);
    defer form.deinit(); // Params owns names and values

    // UTF-8 value arrives decoded (`张三`), not as percent escapes.
    try std.testing.expectEqualStrings("张三", form.get("name").?);
    // Nested key is reachable by its decoded form — this is what the browser
    // actually sent as `role_id%5B0%5D`.
    try std.testing.expectEqualStrings("7", form.get("role_id[0]").?);
    // `+` is a space, same as in query strings.
    try std.testing.expectEqualStrings("a b", form.get("note").?);
    try std.testing.expectEqualStrings("v", form.get("plain").?);
    // No raw-key duplicate is left behind.
    try std.testing.expect(form.get("role_id%5B0%5D") == null);
}

test "pathParam and jsonValue aliases keep the documented semantics" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/orders/42");
    defer ctx.deinit();
    try ctx.params.put(try allocator.dupe(u8, "id"), try allocator.dupe(u8, "42"));

    try std.testing.expectEqualStrings("42", ctx.pathParam("id").?);
    try std.testing.expectEqualStrings("42", ctx.param("id").?);

    try ctx.jsonValue(201, .{ .id = 42, .ok = true });
    try std.testing.expectEqual(@as(u16, 201), ctx.status_code);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "\"id\":42") != null);
}

test "bindForm / bindQuery bind a struct without hand-rolled getPara" {
    const allocator = std.testing.allocator;
    const Fields = struct {
        name: []const u8,
        role_id: i64,
        active: bool = false,
        note: ?[]const u8 = null,
        score: f64 = 1.5,
    };

    var ctx = try Context.init(allocator, .POST, "/users");
    defer ctx.deinit();
    ctx.body = "name=%E5%BC%A0%E4%B8%89&role_id%5B0%5D=7&active=1&score=9.25";
    // Ownership stays with `ctx` — `Context.deinit` frees the form map (keys
    // and values included), so the test must not free it a second time.
    ctx.form = try parseFormBody(allocator, ctx.body.?, 1000);
    try ctx.query.put("name", "fallback");

    const p = try ctx.bindForm(Fields);
    defer allocator.free(p.name);
    try std.testing.expectEqualStrings("张三", p.name);
    // Nested key binds its first element to the scalar field: the browser sent
    // `role_id%5B0%5D=7`, which the parse layer decoded to `role_id[0]`.
    try std.testing.expectEqual(@as(i64, 7), p.role_id);
    try std.testing.expect(p.active);
    try std.testing.expectEqual(@as(f64, 9.25), p.score);
    // Declared default preserved for an absent optional.
    try std.testing.expect(p.note == null);

    // bindQuery reads the query map with the same contract (form does not leak in).
    const Q = struct { name: []const u8, page: i64 = 1 };
    const q = try ctx.bindQuery(Q);
    defer allocator.free(q.name);
    try std.testing.expectEqualStrings("fallback", q.name);
    try std.testing.expectEqual(@as(i64, 1), q.page);

    // Missing required field is an error, not a silent empty value.
    const Required = struct { absent_required: i64 };
    try std.testing.expectError(error.MissingField, ctx.bindQuery(Required));
}

test "ctx.multipart and bindMultipart read a real request body" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .POST, "/upload");
    defer ctx.deinit();

    const body =
        "--X\r\nContent-Disposition: form-data; name=\"full_name\"\r\n\r\nZhang San\r\n" ++
        "--X\r\nContent-Disposition: form-data; name=\"age\"\r\n\r\n42\r\n" ++
        "--X\r\nContent-Disposition: form-data; name=\"doc\"; filename=\"r.pdf\"\r\n" ++
        "Content-Type: application/pdf\r\n\r\n%PDF-1.4\r\n" ++
        "--X--\r\n";
    ctx.body = body;
    // NB: `headers` are the *request* headers (setHeader writes responses).
    try ctx.headers.put(try allocator.dupe(u8, "content-type"), try allocator.dupe(u8, "multipart/form-data; boundary=X"));

    // Text fields bind through the same contract as bindForm.
    const Meta = struct { full_name: []const u8, age: i64 };
    const meta = try ctx.bindMultipart(Meta, .{});
    defer allocator.free(meta.full_name);
    try std.testing.expectEqualStrings("Zhang San", meta.full_name);
    try std.testing.expectEqual(@as(i64, 42), meta.age);

    // Files stay reachable, and text lookups never hand back a blob.
    var form = try ctx.multipart(.{});
    defer form.deinit();
    const doc = form.file("doc").?;
    try std.testing.expectEqualStrings("r.pdf", doc.filename.?);
    try std.testing.expectEqualStrings("%PDF-1.4", doc.data);
    try std.testing.expect(form.value("doc") == null);

    // (Non-multipart rejection lives in Multipart.zig's own tests — replacing a
    // request header here would leak the previous value, which `ctx.deinit`
    // cannot know about.)
}

test "query parsing: repeated keys, brackets and the parameter guard" {
    const allocator = std.testing.allocator;
    var q = Params.init(allocator);
    defer q.deinit();

    try parseQueryInto(&q, "ids=1&ids=2&role_id%5B0%5D=7&role_id%5B1%5D=8&tag%5B%5D=a&name=%E5%BC%A0%E4%B8%89&empty=&novalue", allocator, 100);

    // Repeated keys: every value is kept, `get` stays "last wins" for compat.
    try std.testing.expectEqual(@as(usize, 2), q.getAll("ids").len);
    try std.testing.expectEqualStrings("2", q.get("ids").?);

    // Brackets survive parsing (decoded to `role_id[0]`) and read back sorted.
    const roles = try q.getArray(allocator, "role_id");
    defer allocator.free(roles);
    try std.testing.expectEqual(@as(usize, 2), roles.len);
    try std.testing.expectEqualStrings("7", roles[0]);
    try std.testing.expectEqualStrings("8", roles[1]);

    const tags = try q.getArray(allocator, "tag");
    defer allocator.free(tags);
    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("a", tags[0]);

    // Values are decoded; `=`-less params are skipped; empty values are kept.
    try std.testing.expectEqualStrings("张三", q.get("name").?);
    try std.testing.expectEqualStrings("", q.get("empty").?);
    try std.testing.expect(!q.contains("novalue"));

    // The guard counts occurrences and refuses rather than truncating.
    var small = Params.init(allocator);
    defer small.deinit();
    try std.testing.expectError(error.TooManyParams, parseQueryInto(&small, "a=1&b=2&c=3", allocator, 2));
}

test "requestParam prefers the form and falls back to the query string" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .POST, "/orders/7");
    defer ctx.deinit();

    // Route placeholder: only `param`/`pathParam` see it.
    try ctx.params.put(try allocator.dupe(u8, "id"), try allocator.dupe(u8, "7"));
    try std.testing.expectEqualStrings("7", ctx.param("id").?);
    try std.testing.expect(ctx.queryParam("id") == null);
    try std.testing.expect(ctx.formValue("id") == null);
    try std.testing.expect(ctx.requestParam("id") == null);

    // Same name in query and form: the body wins (POST semantics).
    try ctx.query.put("name", "from-query");
    try std.testing.expectEqualStrings("from-query", ctx.requestParam("name").?);
    // Ownership note: `ctx.form` holds the Params **by value** and deinits it,
    // so the local must not be deinit'd too (that frees the map ctx still points
    // at — found the hard way, as a segfault).
    var form = Params.init(allocator);
    try form.put("name", "from-form");
    try form.put("only_form", "x");
    ctx.form = form;
    try std.testing.expectEqualStrings("from-form", ctx.requestParam("name").?);
    try std.testing.expectEqualStrings("from-query", ctx.queryParam("name").?);
    try std.testing.expectEqualStrings("x", ctx.requestParam("only_form").?);
    try std.testing.expect(ctx.requestParam("absent") == null);
}

test "nestedParam is the dotted-path lookup; paramPath stays as its alias" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/x");
    defer ctx.deinit();

    try ctx.query.put("filter[tags]", "a,b");
    try std.testing.expectEqualStrings("a,b", ctx.nestedParam("filter.tags").?);
    // Deprecated alias keeps working (source compatibility).
    try std.testing.expectEqualStrings("a,b", ctx.paramPath("filter.tags").?);
    // …and it is not a route parameter, which is the whole point of the rename.
    try std.testing.expect(ctx.nestedParam("id") == null);
}

test "fromEnv reads the documented variables off init.environ_map" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HTTP_PORT", "18080");
    try env.put("HTTP_MAX_CONNECTIONS", "4096");
    try env.put("HTTP_HEADER_TIMEOUT_MS", "2500");
    try env.put("HTTP_MAX_BODY", "1024");

    var server = try Server.fromEnv(std.testing.io, allocator, &env);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 18080), server.port);
    try std.testing.expectEqual(@as(usize, 4096), server.max_connections);
    try std.testing.expectEqual(@as(u32, 2500), server.header_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1024), server.max_body_size);
    // Unset or malformed variables fall back to the documented defaults.
    try std.testing.expectEqual(@as(u32, 0), server.ws_write_timeout_ms);
}

test "fromEnv falls back to defaults when a variable is malformed" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HTTP_PORT", "not-a-port");

    var server = try Server.fromEnv(std.testing.io, allocator, &env);
    defer server.deinit();
    try std.testing.expectEqual(@as(u16, 8080), server.port);
}
