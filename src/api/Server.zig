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
        const chunk_header = try std.fmt.allocPrint(self.allocator, "{x}\r\n", .{data.len});
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

/// The status a failed parameter parse owes the client.
///
/// `parseQueryInto` and `parseFormBody` fail for two unrelated reasons, and the
/// caller must not flatten them into one: `error.TooManyParams` is the
/// client's fault (it sent more occurrences than `Server.Config.max_params`
/// allows) and is a 400, while everything else these parsers return — the arena
/// under them refusing an allocation — is the server's and is a 500. Answering
/// the second as "the client sent no fields" serves a request whose fields were
/// never read; answering the first as a success leaves the client with an empty
/// form and no way to learn it sent too many fields.
fn paramParseFailureStatus(err: anyerror) u16 {
    return if (err == error.TooManyParams) 400 else 500;
}

/// What the urlencoded-body step found for one request.
const UrlencodedForm = union(enum) {
    /// No urlencoded body on this request.
    absent,
    /// Parsed; the `Params` belongs to the allocator the step was given.
    parsed: Params,
    /// The request cannot be served. `status` says what it owes the client and
    /// `message` is the reason phrase for that status.
    refused: struct { status: u16, message: []const u8 },
};

/// The urlencoded-body step both request paths run between taking the request
/// apart and matching a route.
///
/// It reports the two failures of `parseFormBody` separately instead of
/// collapsing them into "there was no form" (see `paramParseFailureStatus`):
/// only a request that was actually parsed may reach a handler with
/// `ctx.form` set, and a request whose parse failed is answered instead — 400
/// for a field count over `max_params`, 500 for an allocation failure.
fn parseUrlencodedForm(
    allocator: std.mem.Allocator,
    content_type: []const u8,
    body: ?[]const u8,
    max_params: usize,
) UrlencodedForm {
    const raw = body orelse return .absent;
    if (!std.mem.startsWith(u8, content_type, "application/x-www-form-urlencoded")) return .absent;

    const form = parseFormBody(allocator, raw, max_params) catch |err| {
        // `warn`, not `err`: the request *is* answered, and an error-level line
        // fails the whole suite (`scripts/test-runner.zig` counts those).
        std.log.warn("[Server] urlencoded body refused: {s}", .{@errorName(err)});
        const status = paramParseFailureStatus(err);
        return .{ .refused = .{ .status = status, .message = getStatusText(status) } };
    };
    return .{ .parsed = form };
}

/// The answer a request-boundary parse failure owes the client.
///
/// Every request-boundary failure is a refusal, never a best-effort reparse:
/// 413/431 for the size guards, 501 for a method token this server does not
/// implement, 400 for everything else (including the CL/TE framing conflicts,
/// and `IncompleteBody` — a `Content-Length` the peer never delivered, which
/// used to be a `return` with nothing written: a closed socket and no status
/// line, which reads as a crash rather than a 400).
///
/// `error.OutOfMemory` is the exception. The parser allocates the request line,
/// the query map, the headers and the body on the request arena, and an arena
/// that refused an allocation is this server's fault, not a malformed request.
/// It used to fall into the catch-all with a 400 — the status a genuinely
/// malformed target gets, so the client could not tell the two apart and the
/// wrong side was blamed.
fn requestParseRefusal(err: anyerror) struct { status: u16, message: []const u8 } {
    if (err == error.BodyTooLarge) return .{ .status = 413, .message = "Payload Too Large" };
    if (err == error.TooManyHeaders) return .{ .status = 431, .message = "Request Header Fields Too Large" };
    if (err == error.InvalidMethod) return .{ .status = 501, .message = "Not Implemented" };
    if (err == error.OutOfMemory) return .{ .status = 500, .message = "Internal Server Error" };
    return .{ .status = 400, .message = "Bad Request" };
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
    /// Absolute deadline (`.awake` clock, ns) for the phase currently being
    /// read — the request line + headers, or the body; null = unbounded.
    /// Enforced inside `readInto`, so every read the delimiter scanner
    /// performs is covered, not just the first.
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

    /// Bound the reads of one phase: a peer that trickles bytes (slowloris) is
    /// cut off after `timeout_ms`. 0 disables the bound.
    ///
    /// `connFiber` arms this for the request line + headers; the parser re-arms
    /// it for the body at the blank line. Two arms, not one, because the header
    /// budget is spent by the time the body is read — with no second bound a
    /// `Content-Length: 8M` + 1 byte/s peer holds the connection for free.
    fn setReadDeadline(self: *StreamReader, timeout_ms: u32) void {
        self.timed_out = false;
        if (timeout_ms == 0) {
            self.deadline_ns = null;
            return;
        }
        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        self.deadline_ns = now + @as(i96, timeout_ms) * std.time.ns_per_ms;
    }

    /// The phase this reader was bounding is over: the H2 preface hands it to
    /// the frame loop, and the next keep-alive request arms its own deadline.
    fn clearReadDeadline(self: *StreamReader) void {
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
    fn readUntilDelimiterOrEof(self: *StreamReader, delimiter: u8) !?[]u8 {
        return self.interface.takeDelimiter(delimiter) catch |err| switch (err) {
            error.ReadFailed => error.ReadFailed,
            error.StreamTooLong => error.InvalidRequest,
        };
    }

    /// Read a `Content-Length`-sized body. Returns 0 when the peer closed
    /// before delivering all of it — that is a client fault the caller answers
    /// — but `error.ReadFailed` stays an error: it is how a spent deadline
    /// (`timed_out`) and a broken transport reach the caller as a 408 instead
    /// of being laundered into "0 bytes read" and answered with a silent close.
    fn readAll(self: *StreamReader, out: []u8) !usize {
        self.interface.readSliceAll(out) catch |err| switch (err) {
            error.EndOfStream => return 0,
            error.ReadFailed => return error.ReadFailed,
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
    ///
    /// `body_timeout_ms` bounds the body phase (0 = unbounded). It is armed
    /// here, at the blank line, because the caller's header deadline is already
    /// satisfied by then: the body needs a budget of its own or a peer that
    /// announces a `Content-Length` and then trickles the body holds the
    /// connection for as long as it likes.
    pub fn parseAfterRequestLine(self: *RequestParser, reader: *StreamReader, request_line_raw_view: []const u8, max_body_size: usize, header_limits: HeaderLimits, max_params: usize, body_timeout_ms: u32) !ParsedRequest {
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
            const line_raw = try reader.readUntilDelimiterOrEof('\n') orelse return error.InvalidRequest;
            const header_line = trimCrlf(line_raw);
            if (header_line.len == 0) {
                // Request line + headers are in. Arm the body budget in place
                // of the spent header deadline: the body is read below, and a
                // stalled body must end in 408 (via `timed_out`), not in a
                // connection parked until the peer feels like finishing.
                reader.setReadDeadline(body_timeout_ms);
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
                // `readAll` can now fail (a spent body deadline), so the buffer
                // needs a release on that path too — the arena callers would
                // not notice, a GPA caller would.
                errdefer self.allocator.free(body_buf);
                const bytes_read = try reader.readAll(body_buf);
                if (bytes_read == content_len) {
                    body = body_buf;
                } else {
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

/// How many `{name}` segments a route path carries — the parameters a match
/// would have to capture, counted the way the trie counts them (`TrieNode.init`
/// treats a segment as a parameter when it starts with `{`).
fn countPathParams(path: []const u8) usize {
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len > 0 and part[0] == '{') count += 1;
    }
    return count;
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

    /// Register a route. A path with more parameters than `RouteParams` can hold
    /// is refused here rather than at match time: it is a property of the route,
    /// known while it is being registered, and the request path has no way to
    /// report it — `match` answers `null`, i.e. a 404 for a route the caller
    /// believes it registered. Registration runs at startup, so the refusal is a
    /// startup error (and `Router.addRoute` already returns an error union).
    pub fn addRoute(self: *Router, route: Route) !void {
        // Wildcard route: catch-all for any path under this method
        if (std.mem.eql(u8, route.path, "*")) {
            const path_copy = try self.allocator.dupe(u8, route.path);
            var r = route;
            r.path = path_copy;
            try self.wildcards.put(route.method, r);
            return;
        }

        // Before the trie is touched: a rejection must not leave the partial
        // node chain of a route that will never be usable.
        if (countPathParams(route.path) > RouteParams.MAX) return error.TooManyRouteParams;

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

    /// Match `method` + `path` against the trie. `null` means exactly one
    /// thing: no route answers this method and path.
    ///
    /// A match copies nothing, so it cannot fail. The parameter keys are the
    /// trie's own node names (`TrieNode.param_name`, owned by the router) and
    /// the values are sub-slices of `path`, both of which outlive any use of
    /// the result — the router lives for the process, the path for the request.
    /// That is the point: the previous version duped every key and value into a
    /// `StringHashMap`, and neither way that could fail had an honest answer to
    /// give. A failed dupe came back as `null`, which is "no route matched" —
    /// a 404 for a route that exists. A failed `put` kept the match while
    /// dropping the parameter it could not copy, so a handler reading a tenant
    /// or user path parameter found it silently absent. Callers that need owned
    /// copies build them and report their own failure (`connFiber` answers 500,
    /// `handleForTest` propagates), which is where an error channel exists.
    ///
    /// `allocator` is unused: it is kept in the signature because the call
    /// sites pass the request arena at it.
    pub fn match(self: *const Router, _: std.mem.Allocator, method: Method, path: []const u8) ?MatchedRoute {
        const root = self.roots.get(method) orelse return null;

        var params: RouteParams = .{};

        var parts = std.mem.splitScalar(u8, path, '/');
        var current = root;

        while (parts.next()) |part| {
            if (part.len == 0) continue;

            if (current.findChild(part)) |child| {
                current = child;
            } else if (current.wildcard_child) |wc| {
                // Consume remaining parts into a single rest parameter
                if (wc.route) |route| {
                    return MatchedRoute{ .route = route, .params = params };
                }
                return null;
            } else if (current.findParamChild()) |param_child| {
                // Unreachable for anything `addRoute` accepted — it refuses a
                // path with more than `RouteParams.MAX` parameters, at
                // registration, where the limit is knowable. Kept as the bound
                // on the arrays below so an insert that skips that check cannot
                // write past them.
                if (params.count >= RouteParams.MAX) return null;
                params.keys[params.count] = param_child.param_name.?;
                params.values[params.count] = part;
                params.count += 1;
                current = param_child;
            } else {
                return null;
            }
        }

        // Exact route takes priority over wildcard child
        if (current.route) |route| {
            return MatchedRoute{ .route = route, .params = params };
        }

        // Check if current node has a wildcard child (for /prefix/* matching /prefix)
        if (current.wildcard_child) |wc| {
            if (wc.route) |route| {
                return MatchedRoute{ .route = route, .params = params };
            }
        }

        if (self.wildcards.get(method)) |wc| {
            // The catch-all does not carry the segments it swallowed.
            return MatchedRoute{ .route = wc, .params = .{} };
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

/// Parameters captured by a match. Borrowed, not owned: the keys are the trie's
/// node names and the values are sub-slices of the path `match` was handed.
/// There is nothing to release and nothing here that can fail — see
/// `Router.match` for why that is the point.
const RouteParams = struct {
    /// The most parameters one route may carry. It bounds the two arrays below
    /// and therefore the size of every `MatchedRoute`, which `match` returns by
    /// value — that is why it is a limit rather than a fallback allocation on a
    /// per-request path. `Router.addRoute` refuses a longer path up front
    /// (`error.TooManyRouteParams`, at startup), and the widest route in this
    /// repo uses two (`/users/{id}/posts/{post}`, this file's `match` test).
    pub const MAX = 8;

    keys: [MAX][]const u8 = undefined,
    values: [MAX][]const u8 = undefined,
    count: usize = 0,

    /// The value of the named parameter, or null if the route has no such
    /// parameter. Names are unique within a route.
    pub fn get(self: *const RouteParams, name: []const u8) ?[]const u8 {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.keys[i], name)) return self.values[i];
        }
        return null;
    }

    pub const Entry = struct { key: []const u8, value: []const u8 };

    pub const Iterator = struct {
        params: *const RouteParams,
        index: usize = 0,

        pub fn next(self: *Iterator) ?Entry {
            if (self.index == self.params.count) return null;
            const i = self.index;
            self.index += 1;
            return .{ .key = self.params.keys[i], .value = self.params.values[i] };
        }
    };

    pub fn iterator(self: *const RouteParams) Iterator {
        return .{ .params = self };
    }
};

const MatchedRoute = struct {
    route: Route,
    params: RouteParams,
};

/// Copy a match's borrowed parameters into a map the caller owns — the step
/// `connFiber` needs before a handler can read them out of `ctx.params`. This
/// is the copy that can run out of memory, kept at the caller on purpose: the
/// caller is where an error channel exists, so an allocation failure becomes a
/// 500 instead of a 404 for a route that exists or a match quietly missing the
/// parameter a handler is about to read.
fn copyParamsOwned(
    allocator: std.mem.Allocator,
    params: *const RouteParams,
    into: *std.StringHashMap([]const u8),
) !void {
    var it = params.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, entry.value);
        errdefer allocator.free(value);
        try into.put(key, value);
    }
}

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

/// Ceiling for one response header value. The writer streams header lines, so
/// nothing truncates them silently anymore — this is the bound that has to be
/// explicit and named instead.
const max_response_header_value_bytes = 8 * 1024;

/// Room for one response field line: the largest field *value* the server accepts
/// (`max_response_header_value_bytes`) plus a field name, its colon, CRLF and
/// slack.
///
/// The writer flushes as it fills, so this bounds a **single line**, not the
/// section — the same shape the `std.Io` writer had (a 4 KiB buffer it flushed
/// through), with one difference worth naming: a line that could not fit was a
/// silent drop there (`error.NoSpaceLeft` on a scratch line, logged and never
/// sent — the client saw an empty socket), and is `error.LineTooLong` here, which
/// the caller answers with a warning and a 500. Streaming responses
/// (`Context.flushHeadersToSocket`, SSE) share this buffer through
/// `sockread.BoundedWriter`, so they get the same ceiling instead of the 256-byte
/// scratch line they used to `bufPrint` into.
const response_head_buffer_bytes = max_response_header_value_bytes + 1024;

/// Write one HTTP/1.1 response. `write_body` is `false` for a `HEAD` request:
/// the field section is the `GET` one — `Content-Length` included — and the
/// octets are not sent (RFC 9110 §9.3.2).
///
/// `write_timeout_ms` bounds how long a single send may stall on a full send
/// buffer (0 = unbounded, i.e. no bound is armed). It is the same policy the
/// request side has always had (`header_timeout_ms`, `body_timeout_ms`) and the
/// WS side has for its frames (`ws_write_timeout_ms`): without it, "the peer
/// stopped reading" is a fiber parked forever, which is a shutdown that never
/// finishes, not a slow client.
fn writeResponse(
    stream: std.Io.net.Stream,
    status: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    write_body: bool,
    write_timeout_ms: u32,
) !void {
    // Refuse first, write afterwards: a header the server will not put on the
    // wire must not leave a half-written response behind (and the caller can
    // still answer 500, because nothing has been sent yet). The map can be
    // filled directly, so this is checked here and not only in
    // `Context.setHeader`.
    var precheck = headers.iterator();
    while (precheck.next()) |entry| {
        try validateResponseField(entry.key_ptr.*, entry.value_ptr.*);
    }

    // The writer arms the send bound around each write it makes
    // (`sockread.writeFullBounded`), so there is no socket state here that has to
    // be held across the function — nothing else writes to this fd during it, and
    // no application callback runs inside it.
    var head_buf: [response_head_buffer_bytes]u8 = undefined;
    var w = sockread.BoundedWriter.init(stream, &head_buf, write_timeout_ms);

    const status_text = getStatusText(status);

    // Status line
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ status, status_text });

    // The framing field, decided before the map is written.
    //
    //  - chunked: none at all, from either side (RFC 9112 §6.1 forbids framing a
    //    message both ways).
    //  - `HEAD`: the handler's declaration, which *is* the entity length — no
    //    octets go out here, so there is nothing to check it against and nothing
    //    else that could report the length (RFC 9110 §9.3.2: a response to
    //    `HEAD` carries the field section the `GET` would have). `StaticFiles`
    //    depends on exactly that.
    //  - otherwise: the handler's own only when it equals the octets this
    //    response carries — the rule the H2 encoder applies too
    //    (`assembleSiteResponseBlock`), so both protocols frame a response the
    //    same way — otherwise the server's own, since it is holding the body.
    //
    // Whatever wins goes out **once**. Appending the server's length next to the
    // handler's put two framing fields on the wire (`StaticFiles` declares the
    // file length: `Content-Length: 5120` then `Content-Length: 0` on
    // `HEAD /static/big.bin`), and a response framed by a number its body does
    // not match is one a recipient may reject or mis-read (RFC 9110 §8.6) —
    // `1*DIGIT` is enforced as well, so `1_7` cannot mean 17.
    const chunked = headerLookup(headers, "Transfer-Encoding") != null;
    const declared_length = declaredContentLength(headers);
    const keep_declared_length = !chunked and (if (write_body)
        (declared_length != null and declared_length.? == body.len)
    else
        declared_length != null);

    // Headers
    var hiter = headers.iterator();
    while (hiter.next()) |entry| {
        if (!keep_declared_length and std.ascii.eqlIgnoreCase(entry.key_ptr.*, "content-length")) continue;
        try w.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    if (!chunked and !keep_declared_length) {
        try w.print("Content-Length: {d}\r\n", .{body.len});
    }
    try w.write("\r\n");

    // Body (already chunk-encoded if Transfer-Encoding: chunked). Under `HEAD`
    // there is none to write: the entity length above is the `GET` answer's.
    if (write_body) try w.write(body);
    try w.flush();
}

/// The handler's `Content-Length`, when the value really is one: `1*DIGIT` per
/// RFC 9110 §8.6. Zig's `parseInt` would take `_` as a digit separator, so
/// `1_7` has to be refused rather than read as 17 — `parseContentLength` is the
/// request side's parser and refuses exactly that.
fn declaredContentLength(headers: std.StringHashMap([]const u8)) ?usize {
    const value = headerLookup(headers, "content-length") orelse return null;
    return parseContentLength(value);
}

/// Reject a response field that would let its value rewrite the message:
/// `field-name` must be `1*tchar` (RFC 9110 §5.6.2) and the value must carry no
/// CR, LF or NUL.
///
/// The request side has refused these from the start (`splitHeaderLine` /
/// `isTchar`), but query and form values arrive *percent-decoded* — `%0d%0a` is
/// a real CRLF by the time a handler reads it — so echoing request data into a
/// header is response splitting unless it is checked on this side too.
fn validateResponseField(name: []const u8, value: []const u8) !void {
    if (name.len == 0) return error.InvalidHeader;
    for (name) |c| {
        if (!isTchar(c)) return error.InvalidHeader;
    }
    if (value.len > max_response_header_value_bytes) return error.HeaderTooLarge;
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return error.InvalidHeader;
    }
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
    /// See `Config.body_timeout_ms`.
    body_timeout_ms: u32 = 30_000,
    /// See `Config.response_write_timeout_ms`.
    response_write_timeout_ms: u32 = 30_000,
    /// See `Config.ws_write_timeout_ms`.
    ws_write_timeout_ms: u32 = 0,
    /// See `Config.max_params`.
    max_params: usize = 1000,
    /// Accepted connections currently being served (reserved before the fiber
    /// starts, released when it returns).
    active_connections: std.atomic.Value(u64) = .init(0),
    in_flight: ?*std.atomic.Value(u64) = null,
    /// Upgraded WebSocket connections a `connFiber` is still serving — the ones
    /// `stop()` shuts down so a silent peer cannot decide how long shutdown
    /// takes (see `wakeWsConnections`). Connections handed to `ws_uring` are
    /// owned by the ring instead and are deliberately not listed: the fiber
    /// returns at `adopt`.
    ///
    /// Registration happens once per upgrade, not per request, so this stays off
    /// the HTTP hot path — and non-WebSocket connections are *absent* on purpose:
    /// the drain awaits in-flight requests rather than cancelling them, so it
    /// must not shut their sockets down.
    ws_conns_mutex: std.Io.Mutex,
    /// Guarded by `ws_conns_mutex`; a list of *borrowed* fds — see
    /// `wakeWsConnections` for why that lock is what makes them safe to shut down.
    ws_conns: std.ArrayList(std.posix.socket_t),
    /// Connections a `stop()` wake pass actually shut down. Structural evidence
    /// that the drain was woken rather than merely asked to stop (read by tests).
    ws_woken_connections: std.atomic.Value(u64) = .init(0),
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
        /// Deadline for receiving the request body, armed at the blank line —
        /// `header_timeout_ms` is already satisfied by then, and the handler
        /// budget starts only after the body is in. Without it a
        /// `Content-Length: 8M` request that sends one byte per second holds a
        /// connection (and its slot) forever. Exceeding it answers 408.
        /// 0 disables the deadline.
        body_timeout_ms: u32 = 30_000,
        /// Bound on blocking **response** writes (`SO_SNDTIMEO`, armed around the
        /// write and cleared again). Without it a peer that stops reading owns
        /// the connection's fiber for as long as it likes — and that fiber is
        /// what `stop()`'s drain waits for, so it owns shutdown too. It is the
        /// write-side counterpart of `body_timeout_ms`: the budget is per
        /// blocking `send`, so a slow-but-live peer (one that keeps draining the
        /// socket) is never cut off, while a peer that has stopped reading gets
        /// `error.WriteTimeout`, a truncated response and a closed connection.
        /// 0 keeps the unbounded behavior.
        response_write_timeout_ms: u32 = 30_000,
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
        /// socket is shut down.
        ///
        /// **0 means inherit `response_write_timeout_ms`** (the default: a WS
        /// frame push and a response write are the same hazard, so they share one
        /// number unless this overrides it). `response_write_timeout_ms = 0` is
        /// how you get the old unbounded behavior on both.
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
            .ws_conns_mutex = std.Io.Mutex.init,
            .ws_conns = std.ArrayList(std.posix.socket_t).empty,
            .connection_stack_size = config.connection_stack_size,
            .over_limit_response = config.over_limit_response,
            .header_timeout_ms = config.header_timeout_ms,
            .body_timeout_ms = config.body_timeout_ms,
            .response_write_timeout_ms = config.response_write_timeout_ms,
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

    /// H2 session options derived from `Config`, so both protocols enforce the
    /// same numbers: `max_body_size`, `header_limits` and `header_timeout_ms`
    /// mean on the H2 path exactly what they mean on the H1 one.
    ///
    /// `deadline` is the connection's `StreamReader` wrapped for the loop; pass
    /// `null` only if the session is not reading through one.
    ///
    /// `request_timeout_ms` is not a session option: it is a *per-request*
    /// budget, and `http2RouterSiteHandler` arms it on the `Context` it builds
    /// (`ctx.setDeadline`) — the same call `connFiber` makes on the H1 path.
    fn http2ServeOptions(self: *Server, deadline: ?Http2Server.ReadDeadline) Http2Server.ServeOptions {
        return .{
            .grpc_registry = self.grpc_registry,
            .site_handler = if (self.http2_site_handler != null)
                self.http2_site_handler
            else if (self.http2_use_router)
                Server.http2RouterSiteHandler
            else
                null,
            .site_user_ctx = self,
            // One inbound frame per stream request is typical; leave headroom for SETTINGS/WINDOW_UPDATE/CONTINUATION.
            .max_frames = @max(self.max_requests_per_conn * 16, 4096),
            .inbound = .{
                .max_body_bytes = self.max_body_size,
                .max_header_list_bytes = self.header_limits.max_total_bytes,
                .max_header_count = self.header_limits.max_count,
            },
            // The H1 header deadline is the H2 idle budget: H1 already closes a
            // keep-alive connection that goes quiet for that long, so one number
            // governs both, and `0` disables both. `read_deadline` is what makes
            // it bite inside a blocking read.
            .read_idle_timeout_ms = self.header_timeout_ms,
            .read_deadline = deadline,
            // H2 responses have no other bound than this one: the H1 response
            // path gets it from `writeResponse`, and `ConnWriter` is the H2
            // equivalent — one request per stream, one write per response.
            .write_timeout_ms = self.response_write_timeout_ms,
        };
    }

    /// Adapter between the H2 loop's idle deadline and this connection's
    /// `StreamReader` (`Http2Server` cannot see the transport, and
    /// `std.Io.Reader` carries no deadline). Reads happen on the connection's
    /// own fiber, so the reader outlives the session.
    const Http2ReadDeadline = struct {
        fn arm(ctx: *anyopaque, ms: u32) void {
            const reader: *StreamReader = @ptrCast(@alignCast(ctx));
            reader.setReadDeadline(ms);
        }

        fn clear(ctx: *anyopaque) void {
            const reader: *StreamReader = @ptrCast(@alignCast(ctx));
            reader.clearReadDeadline();
        }

        fn timedOut(ctx: *anyopaque) bool {
            const reader: *StreamReader = @ptrCast(@alignCast(ctx));
            return reader.timed_out;
        }

        fn handle(reader: *StreamReader) Http2Server.ReadDeadline {
            return .{ .ctx = reader, .arm_ms = arm, .clear = clear, .timed_out = timedOut };
        }
    };

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

        // `:path` is the whole request target, query included (RFC 9113 §8.3.1):
        // the same string `RequestParser.parse` receives and splits. Routing, the
        // path rewriter and `requestParam`'s query fallback all run on the split
        // halves. Passing the target through whole made `/route?a=1` unmatched
        // (404) and every query parameter invisible, for the very route that
        // answers both on H1.
        const query_start = std.mem.indexOfScalar(u8, path, '?');
        const path_only = if (query_start) |q| path[0..q] else path;

        // `ctx.allocator` is per-request on H1: `connFiber` owns an arena and
        // resets it at the top of every request, so what a handler allocates
        // from the Context is reclaimed when the request is done — the pattern
        // `setPathRewriter` documents ("allocate new path in arena"). The H2
        // loop hands this adapter the *connection*-level allocator, so without
        // an arena here those allocations pile up for the life of the session
        // (observed: one leaked rewritten `ctx.path` per rewritten request).
        // Same lifetime, same contract, both protocols.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var ctx = try Context.init(arena_alloc, method, path_only);
        errdefer ctx.deinit();

        if (query_start) |q| {
            parseQueryInto(&ctx.query, path[q + 1 ..], arena_alloc, server.max_params) catch |err| {
                // H1 fails such a request instead of routing it with a
                // half-parsed query. Refuse here too — quietly answering the
                // route with the parameters missing is the divergence class
                // this adapter already refuses to have for streaming (501).
                // The *kind* of failure decides the status, exactly as on H1:
                // an over-limit query string is the client's 400, an arena that
                // refused an allocation is the server's 500.
                const status = paramParseFailureStatus(err);
                std.log.warn("[Server] HTTP/2 query string refused: {s}", .{@errorName(err)});
                const refusal = try allocator.dupe(u8, getStatusText(status));
                ctx.deinit();
                return .{
                    .status = status,
                    .content_type = "text/plain",
                    .body = refusal,
                };
            };
        }

        // The same two arms the H1 dispatch performs before routing (see
        // `connFiber`: "Arm the request budget once, here" / `ctx.io =
        // server.io`). Without them the H2 adapter handed handlers a `null`
        // `ctx.io` and `ctx.sqlContext()` reported `deadline_ms = null`, i.e.
        // an unbounded request with no way for storage to hear about the
        // budget — for the same routes, at the same `Config` numbers.
        ctx.setDeadline(server.request_timeout_ms);
        ctx.io = server.io;
        // `ctx.stream` is deliberately left `null` rather than pointed at the
        // connection socket: writing H1 bytes there produces bytes the peer
        // cannot parse as frames. There is no mid-response channel on this
        // adapter at all (the body is one `SiteResponse` written as DATA frames
        // after the handler returns), so a streaming handler is refused below
        // instead of being handed a stream that would corrupt the response —
        // and nothing on this path may dereference `ctx.stream` (it is `null`
        // here, not on H1).
        ctx.raw_path = path; // the whole target; `ctx.path` above is the split

        if (body.len > 0) {
            ctx.body = try arena_alloc.dupe(u8, body);
        }
        for (headers) |h| {
            if (h.name.len == 0 or h.name[0] == ':') continue;
            const k = try arena_alloc.dupe(u8, h.name);
            const v = try arena_alloc.dupe(u8, h.value);
            try ctx.headers.put(k, v);
        }

        // ── Path rewriter, then the urlencoded form parse ──
        // Both are steps `connFiber` runs between taking the request apart and
        // matching a route, and both write fields the handler reads (`ctx.path`,
        // `ctx.requestParam`). Running them on H1 only makes one route answer
        // differently per protocol — e.g. an app that strips an API-version
        // prefix, or a login form whose fields never arrive.
        if (server.path_rewriter) |rewriter| {
            rewriter(&ctx);
        }
        // Same step, same two answers as H1 (see `parseUrlencodedForm`). A
        // refusal has to be returned *before* the handler runs: this path has
        // no `connFiber` around it to turn an exception into a status, and
        // `ctx.deinit()` is what the other early returns here do.
        switch (parseUrlencodedForm(arena_alloc, ctx.headers.get("content-type") orelse "", ctx.body, server.max_params)) {
            .absent => {},
            .parsed => |form| ctx.form = form,
            .refused => |refusal| {
                const body_text = try allocator.dupe(u8, refusal.message);
                ctx.deinit();
                return .{
                    .status = refusal.status,
                    .content_type = "text/plain",
                    .body = body_text,
                };
            },
        }

        try server.handleForTest(&ctx);

        if (ctx.streaming) {
            // `startChunked` / `writeChunk` is the H1 chunked API and has no H2
            // equivalent on this adapter: with `ctx.stream` null the chunks
            // land in `response_body` *with their H1 framing*, and the code
            // below would serve that as an ordinary 200 body (observed:
            // `7\r\n{"a":1}\r\n0\r\n\r\n`). A silent 200 carrying framing bytes
            // is worse than a refusal, so refuse — and say why.
            // `warn`, not `err`, for the same reason as the refused-response
            // header at the end of `connFiber`: the request is answered, and an
            // error-level line makes `scripts/test-runner.zig` fail the suite.
            std.log.warn(
                "[Server] HTTP/2 has no response stream: {s} {s} used the chunked streaming path; answering 501",
                .{ method_str, path },
            );
            const refusal = try allocator.dupe(u8, "streaming is not supported over HTTP/2");
            ctx.deinit();
            return .{
                .status = 501,
                .content_type = "text/plain",
                .body = refusal,
            };
        }

        const status = ctx.status_code;
        // The *response* map, not `ctx.header` (which reads request headers):
        // handlers write `Content-Type` with that spelling, so the lookup has
        // to be case-insensitive or every h2 response falls back to
        // `application/octet-stream`.
        const ctype_src = headerLookup(ctx.response_headers, "content-type") orelse "application/octet-stream";
        const ctype = try allocator.dupe(u8, ctype_src);
        errdefer allocator.free(ctype);
        const resp_body = try allocator.dupe(u8, ctx.response_body.items);
        errdefer allocator.free(resp_body);
        // Everything else the handler put in the map travels too. On H1
        // `writeResponse` writes the whole map, so dropping these on H2 is a
        // per-protocol divergence an app can see: a login's `Set-Cookie`, a
        // redirect's `Location`, a 429's `Retry-After`. H2's rules about what
        // may go in a block (lowercase names, no connection-specific fields,
        // the size budget) are enforced in the encoder, which is the one place
        // every `SiteHandler` passes through.
        const extra = try copyResponseHeaders(allocator, ctx.response_headers);
        errdefer {
            for (extra) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(extra);
        }
        ctx.deinit();
        return .{
            .status = status,
            .content_type = ctype,
            .body = resp_body,
            .content_type_owned = true,
            .headers = extra,
            .headers_owned = true,
        };
    }

    /// Duplicate a response-header map into an owned `Hpack.Header` list.
    ///
    /// `content-type` is left out: `SiteResponse.content_type` owns that field
    /// and two of them in one response is a protocol error. Names keep the
    /// spelling the handler used — lowercasing is the encoder's job, so those
    /// bytes stay valid for anything else that reads this list.
    fn copyResponseHeaders(
        allocator: std.mem.Allocator,
        headers: std.StringHashMap([]const u8),
    ) ![]Hpack.Header {
        var out = std.ArrayList(Hpack.Header).empty;
        errdefer {
            for (out.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            out.deinit(allocator);
        }
        var it = headers.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "content-type")) continue;
            const name = try allocator.dupe(u8, entry.key_ptr.*);
            const value = allocator.dupe(u8, entry.value_ptr.*) catch |err| {
                allocator.free(name);
                return err;
            };
            out.append(allocator, .{ .name = name, .value = value }) catch |err| {
                allocator.free(name);
                allocator.free(value);
                return err;
            };
        }
        return out.toOwnedSlice(allocator);
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
        self.ws_conns.deinit(self.allocator);
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
            // The match borrowed the parameters from the trie and the path; the
            // map handlers read owns its own copies, so this is where an
            // allocation failure can still show up — and this entry point has
            // an error channel for it.
            try copyParamsOwned(ctx.allocator, &m.params, &ctx.params);

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
        // The listener fd is closed only here, on the accept loop's own
        // thread, after the loop has exited. stop() deliberately never
        // closes it: a cross-thread close races the blocked `accept`, and
        // per platform either does not wake it at all (Linux) or lets a
        // fresh accept4 start on the torn-down fd and return EBADF, which
        // std.Io.Threaded classifies as errnoBug and panics on — from
        // inside std, where it cannot be caught. stop() only clears
        // `running` and wakes the syscall; the woken loop unwinds there and
        // runs this defer. `listener_closing` is reset so start() can be
        // called again (restart).
        defer {
            self.closeListener();
            self.listener_closing.store(false, .monotonic); // allow restart
        }
        // Reap any still-running connection fibers on exit so their futures
        // are released. Await (not cancel) so in-flight requests complete.
        //
        // The waits behind this drain and what ends them: header/body deadlines
        // bound the read phases, the HTTP/2 session's idle read uses the same
        // header deadline, and an upgraded WebSocket fiber parked in its read is
        // woken by `stop()` (`wakeWsConnections`) — a peer that goes silent after
        // the handshake cannot hold this. What no wake reaches is user code
        // (`on_connect` / `on_message` / `on_close`, handlers): see `stop()`.
        defer self.conn_group.await(self.io) catch |err| std.log.warn("[Server] conn_group await: {}", .{err});

        self.running.store(true, .monotonic);
        std.log.info("Server listening on port {d}", .{self.port});

        while (self.running.load(.monotonic)) {
            const stream = (self.listener orelse break).accept(self.io) catch |err| {
                if (!self.running.load(.monotonic)) break;
                std.log.err("Accept error: {any}", .{err});
                continue;
            };

            // stop() may have landed between the loop condition and a
            // completed accept (its loopback wake, or a real client racing
            // shutdown): don't dispatch new work while stopping — close the
            // connection and unwind. The loopback wake connection ends here.
            if (!self.running.load(.monotonic)) {
                stream.close(self.io);
                break;
            }

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
                    writeOverLimit503(stream, self.response_write_timeout_ms);
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

    /// Stop the server. Safe to call from any thread, including while
    /// `start()` is blocked in `accept()` on another thread; typically
    /// followed by `join()` on the `runInBackground` thread.
    ///
    /// This never closes the listener fd. A cross-thread close races the
    /// accept loop, and per platform either does not wake a parked
    /// `accept` at all (Linux — the hang the shutdown dance in
    /// `sockread.closeListener` was written for) or lets a fresh accept4
    /// start on the torn-down fd and return EBADF, which std.Io.Threaded
    /// reports as `errnoBug` and panics on, from inside std where it cannot
    /// be caught. Instead: clear `running`, wake the parked syscall with a
    /// real loopback connection (plus the Linux-side shutdown), and let the
    /// accept loop exit on its own thread — `start()`'s defer then closes
    /// the listener there and the port is released. Even without a join the
    /// loop unwinds itself promptly.
    ///
    /// **Bounded against peers, not against your code.** Every wait the accept
    /// loop's drain can sit in is ended by a `shutdown` on a socket, not by the
    /// remote end: `accept` (above), the header/body deadlines
    /// (`header_timeout_ms` / `body_timeout_ms`), HTTP/2 sessions (the same
    /// header deadline as an idle read timeout), and — the one that used to have
    /// no bound at all — the WebSocket read loop, woken by `wakeWsConnections`
    /// (see there for the fd-safety argument). What is left is *your code*:
    /// a handler or `on_connect` / `on_message` / `on_close` that does not return
    /// holds the drain for as long as it blocks, and no budget cuts it short on
    /// purpose — returning with a fiber alive would hand it a server its caller is
    /// about to `deinit`, which is memory unsafety rather than a fast shutdown.
    ///
    /// Idempotent: a second call finds no listener, an empty wake set, and (if
    /// `start()` has unwound) a drained group.
    pub fn stop(self: *Server) void {
        self.running.store(false, .monotonic);
        self.wakeAccept();
        // ... and the same maneuver for the upgraded WebSocket connections that
        // accept loop produced. Ordered after the listener wake so the accept
        // loop is already on its way out; it cannot miss a connection either way,
        // because `running` is already false and a fiber records itself under the
        // same lock this pass takes, checking that flag there — so a fiber that
        // arrives after the pass refuses the connection instead of parking in a
        // read nobody will wake.
        self.wakeWsConnections();
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
            .body_timeout_ms = envInt(u32, env, "HTTP_BODY_TIMEOUT_MS", 30_000),
            .response_write_timeout_ms = envInt(u32, env, "HTTP_RESPONSE_WRITE_TIMEOUT_MS", 30_000),
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

    /// Wake an accept loop blocked in `accept()` so `start()` can unwind on
    /// its own thread and run its closeListener defer there. Two
    /// mechanisms, because the platforms disagree about what wakes a
    /// blocked accept and this must work on all of them without ever
    /// closing the fd from the stopping thread:
    ///
    /// - `shutdown(SHUT.RDWR)` fails a *Linux* `accept` immediately (EINVAL
    ///   → `error.SocketNotListening`, which the loop treats as a normal
    ///   exit once `running` is false). macOS answers ENOTCONN for a
    ///   listener — ignored.
    /// - A real connection to our own port wakes a macOS/BSD `accept` with
    ///   a *valid* fd (Darwin wakes a parked accept on close with
    ///   ECONNABORTED, but that is a close — exactly what must not happen
    ///   from this thread). The loop accepts the loopback connection and
    ///   discards it: `running` is already false.
    fn wakeAccept(self: *Server) void {
        const l = self.listener orelse return;
        _ = std.c.shutdown(l.socket.handle, std.c.SHUT.RDWR);
        const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        var sa: std.posix.sockaddr.in = .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, l.socket.address.getPort()),
            .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
            .zero = std.mem.zeroes([8]u8),
        };
        _ = std.c.connect(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in));
    }

    /// Reserve `fd` for the WebSocket read loop. `false` (no error) once the
    /// server is stopping, and then the caller drops the connection instead of
    /// reading from it.
    ///
    /// The `running` check lives *inside* the critical section on purpose.
    /// `stop()` clears the flag before its wake pass, and the pass takes this
    /// same lock, so a fiber that arrives late either (a) recorded itself before
    /// the pass and gets woken, or (b) finds `running == false` through the mutex
    /// and never parks. A check outside the lock would leave a third
    /// interleaving — "read true, be recorded after the pass" — in which the
    /// fiber parks in a read that nothing will ever wake, which is the hang this
    /// all exists to remove.
    ///
    /// Uncancelable: this runs on a fiber that returns `void`, so a `Canceled`
    /// has no channel to be reported through, and the critical section is one
    /// `append`.
    fn registerWsConnection(self: *Server, fd: std.posix.socket_t) !bool {
        self.ws_conns_mutex.lockUncancelable(self.io);
        defer self.ws_conns_mutex.unlock(self.io);
        if (!self.running.load(.monotonic)) return false;
        try self.ws_conns.append(self.allocator, fd);
        return true;
    }

    /// Drop `fd`'s reservation. Called by the fiber that made it, under this same
    /// lock and *before* the socket is closed — the invariant `wakeWsConnections`
    /// depends on. A no-op when the entry is already gone.
    fn unregisterWsConnection(self: *Server, fd: std.posix.socket_t) void {
        self.ws_conns_mutex.lockUncancelable(self.io);
        defer self.ws_conns_mutex.unlock(self.io);
        for (self.ws_conns.items, 0..) |p, i| {
            if (p == fd) {
                _ = self.ws_conns.swapRemove(i);
                return;
            }
        }
    }

    /// Make every WebSocket connection fiber parked in a read return, so the
    /// drain (`conn_group.await` in `start()`'s defer) has an upper bound.
    ///
    /// The fiber path reads WebSocket frames with a bare `read`
    /// (`im/WsFramer.zig` `readFull` → `core/sockread.zig` `readSome`), which a
    /// peer that goes silent after the handshake never disturbs — no frame, no
    /// close, no FIN — so the fiber waits for as long as the peer wants and the
    /// length of `stop()` becomes the *remote* end's decision.
    /// `shutdown(SHUT_RDWR)` is the wake — the same helper `sockread.closeListener`
    /// applies to `accept` — and the parked read returns 0, which the WS read
    /// loop below already treats as "the peer went away".
    ///
    /// Deliberately not a socket timeout: a long quiet period is a WebSocket's
    /// normal state, so an idle bound would cut healthy connections, whereas this
    /// fires only because the server is being torn down.
    ///
    /// **Taken under `ws_conns_mutex`, and that is what makes the fds safe to
    /// touch**: the owner removes its entry under this same lock before the fd can
    /// be closed, so a recorded fd cannot have been closed and recycled under a
    /// fresh connection by the time the pass sees it. Holding the lock across the
    /// pass adds no wait to anyone — `shutdown` never blocks — and it is taken
    /// uncancelably because `stop()` returns `void` and has to complete.
    fn wakeWsConnections(self: *Server) void {
        self.ws_conns_mutex.lockUncancelable(self.io);
        defer self.ws_conns_mutex.unlock(self.io);

        var woken: u64 = 0;
        for (self.ws_conns.items) |fd| {
            sockread.wakeBlockedSyscall(fd);
            woken += 1;
        }
        if (woken != 0) _ = self.ws_woken_connections.fetchAdd(woken, .monotonic);
    }

    /// Registered WebSocket connections. Test-facing: it lets a shutdown test
    /// wait for the *parked* state instead of guessing at it with a sleep.
    fn registeredWsCount(self: *Server) usize {
        self.ws_conns_mutex.lockUncancelable(self.io);
        defer self.ws_conns_mutex.unlock(self.io);
        return self.ws_conns.items.len;
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
    // The fd is closed here *unless* it was handed to `ws_uring`, which owns it
    // from that point (see `WsUring.adopt`). Closing it here as well would close
    // a descriptor the ring has a read in flight on: the read comes back EBADF,
    // the ring tears the connection down, and it closes that same number a
    // second time — by then the kernel may have reissued it to another
    // connection, which is the descriptor this fiber would be closing.
    var fd_owned_by_fiber = true;
    defer if (fd_owned_by_fiber) stream.close(server.io);
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

        // Bound the request line + header phase (slowloris guard). The parser
        // re-arms it for the body at the blank line; re-armed per request here.
        reader.setReadDeadline(server.header_timeout_ms);

        // Prefetch first line — HTTP/2 prior-knowledge preface starts with PRI.
        const first_line_raw = reader.readUntilDelimiterOrEof('\n') catch |err| {
            // No complete request line: there is nothing to read a method out of,
            // so these two answers are the `GET` shape (see `writeErrorResponse`).
            switch (err) {
                error.ReadFailed => {
                    if (reader.timed_out) writeErrorResponse(stream, arena_alloc, 408, "Request Timeout", false, server.response_write_timeout_ms);
                    return;
                },
                else => {
                    writeErrorResponse(stream, arena_alloc, 400, "Bad Request", false, server.response_write_timeout_ms);
                    return;
                },
            }
        } orelse return;
        const first_line = RequestParser.trimCrlf(first_line_raw);

        if (server.enable_http2 and std.mem.eql(u8, first_line, "PRI * HTTP/2.0")) {
            // Consume remaining preface: empty line, "SM", empty line
            const l2 = (reader.readUntilDelimiterOrEof('\n') catch return) orelse return;
            const l3 = (reader.readUntilDelimiterOrEof('\n') catch return) orelse return;
            const l4 = (reader.readUntilDelimiterOrEof('\n') catch return) orelse return;
            if (RequestParser.trimCrlf(l2).len != 0) return;
            if (!std.mem.eql(u8, RequestParser.trimCrlf(l3), "SM")) return;
            if (RequestParser.trimCrlf(l4).len != 0) return;
            // The preface is consumed; H2 frames are not header-phase reads.
            reader.clearReadDeadline();

            // Reuse the same StreamReader for the H2 session (do not create a second
            // reader on this stream). Any bytes already buffered after the preface
            // stay in the reader and are consumed as frames.
            Http2Server.serveAfterPrefacePrefetchReader(
                server.io,
                stream,
                allocator,
                server.http2ServeOptions(Server.Http2ReadDeadline.handle(&reader)),
                &.{},
                &reader.interface,
            ) catch |err| {
                std.log.warn("[Server] HTTP/2 session ended: {s}", .{@errorName(err)});
            };
            return;
        }

        var request = parser.parseAfterRequestLine(&reader, first_line_raw, server.max_body_size, server.header_limits, server.max_params, server.body_timeout_ms) catch |err| {
            switch (err) {
                error.ReadFailed => {
                    // A spent read deadline is the client that stalled (headers
                    // or body): 408, observable, instead of a vanished socket.
                    if (reader.timed_out) writeErrorResponse(stream, arena_alloc, 408, "Request Timeout", requestLineIsHead(first_line_raw), server.response_write_timeout_ms);
                    return;
                },
                else => {},
            }
            // A malformed request is a client fault, not a server error: warn,
            // so scanners/probes cannot inflate the error signal.
            std.log.warn("Parse error: {any}", .{err});
            const refusal = requestParseRefusal(err);
            writeErrorResponse(stream, arena_alloc, refusal.status, refusal.message, requestLineIsHead(first_line_raw), server.response_write_timeout_ms);
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
        // The streaming/SSE writes below happen *inside* the handler, long after
        // `writeResponse` could apply a bound — this is where they get one.
        ctx.write_timeout_ms = server.response_write_timeout_ms;

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

        // Parse form body — a failure here is answered, never folded into "the
        // request carried no fields" (see `parseUrlencodedForm`). `catch null`
        // here served a request whose form was never read as a 200 with an
        // empty `ctx.form`, and a client over `max_params` was never told.
        switch (parseUrlencodedForm(arena_alloc, ctx.headers.get("content-type") orelse "", request.body, server.max_params)) {
            .absent => {},
            .parsed => |form| ctx.form = form,
            .refused => |refusal| {
                writeErrorResponse(stream, arena_alloc, refusal.status, refusal.message, request.method == .HEAD, server.response_write_timeout_ms);
                return;
            },
        }

        // ── HTTP/2 cleartext upgrade (h2c, RFC 7540 §3.2) ──
        // No method restriction: the upgrade is a property of the connection,
        // not of the request (RFC 7540 §3.2 / RFC 9113 §3.2 name no method), so
        // every method the HTTP/1.1 parser above accepted can carry it — a
        // `POST` upgrade is how a body rides onto the upgraded connection, and
        // `HEAD`/`OPTIONS` upgrade like anything else. A method this server does
        // not implement never reaches this point: the request-line parse above
        // refused an unknown token with 501 (`error.InvalidMethod`).
        if (server.enable_http2) {
            const upgrade_hdr = ctx.headers.get("upgrade") orelse "";
            const conn_hdr = ctx.headers.get("connection") orelse "";
            const h2_settings = ctx.headers.get("http2-settings");
            if (Http2.isH2cUpgrade(upgrade_hdr, conn_hdr, h2_settings)) {
                // RFC 7540 §3.2: this request *is* stream 1 of the session that
                // follows, and the client sends no HEADERS frame for it — so it
                // is handed to the session rather than forgotten here. Built
                // before the 101, so a failure is still answerable: every slice
                // is copied by the session before it returns.
                var upgrade_headers = std.ArrayList(Hpack.Header).empty;
                defer upgrade_headers.deinit(arena_alloc);
                var hdr_it = ctx.headers.iterator();
                while (hdr_it.next()) |e| {
                    upgrade_headers.append(arena_alloc, .{ .name = e.key_ptr.*, .value = e.value_ptr.* }) catch {
                        writeErrorResponse(stream, arena_alloc, 500, "Internal Server Error", request.method == .HEAD, server.response_write_timeout_ms);
                        return;
                    };
                }

                var wbuf: [256]u8 = undefined;
                var w = stream.writer(server.io, &wbuf);
                w.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n") catch return;
                w.interface.flush() catch return;

                Http2Server.serveAfterUpgrade(
                    server.io,
                    stream,
                    allocator,
                    server.http2ServeOptions(Server.Http2ReadDeadline.handle(&reader)),
                    &reader.interface,
                    .{
                        .method = request.method.toString(),
                        // The whole request target, query included: this is what
                        // `:path` means (RFC 9113 §8.3.1) and what the H2 site
                        // adapter splits. `request.path` is the split half.
                        .target = if (request.raw_path.len > 0) request.raw_path else request.path,
                        .authority = ctx.headers.get("host") orelse "",
                        .headers = upgrade_headers.items,
                        // Already read in full by the parser above; stream 1 is
                        // half-closed (remote) from the start.
                        .body = request.body orelse "",
                        .http2_settings = h2_settings,
                    },
                ) catch |err| {
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
                        // would never reach the socket. The method is the real
                        // one — `GET` is the only method that gets this far, and
                        // passing it keeps the answer honest if that ever widens.
                        writeErrorResponse(stream, allocator, 400, "WebSocket handshake failed", request.method == .HEAD, server.response_write_timeout_ms);
                        return;
                    }

                    // Non-empty: `wsHandshakeValid` above returned true.
                    const ws_key = ctx.headers.get("sec-websocket-key") orelse "";
                    ctx.user_data = ws_route.user_data;
                    // Perform handshake
                    var framer = WsFramer.init(stream, server.io);
                    framer.handshake(ws_key) catch {
                        writeErrorResponse(stream, allocator, 400, "WebSocket handshake failed", request.method == .HEAD, server.response_write_timeout_ms);
                        return;
                    };
                    ctx.upgraded = true;
                    // `ws_write_timeout_ms` overrides; `0` means **inherit** the
                    // connection's response budget rather than "unbounded". A
                    // frame push to a peer that stopped reading parks the pushing
                    // thread exactly like a response write parks its fiber, and
                    // "unbounded by default" is what the HTTP side stopped doing
                    // (`Config.response_write_timeout_ms`). Set
                    // `response_write_timeout_ms = 0` to disable both.
                    framer.setSendTimeout(if (server.ws_write_timeout_ms != 0) server.ws_write_timeout_ms else server.response_write_timeout_ms);

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
                        uring.adopt(sock_fd, session.?, ws_route.on_message, ws_route.on_close) catch |err| {
                            // Nothing was taken: the fd is still ours, so it is
                            // closed by the `defer` above as soon as this returns.
                            std.log.warn("[Server] WS handoff to io_uring refused: {}", .{err});
                            framer.writeClose() catch |err2| std.log.err("[Server] WS writeClose on reject: {}", .{err2});
                            if (@intFromPtr(ws_route.on_close) != 0) ws_route.on_close(session.?);
                            return;
                        };
                        // The ring owns the fd now and closes it in its own
                        // teardown — this is the "on success" half of `adopt`'s
                        // contract, and it has to be set before the `return`.
                        fd_owned_by_fiber = false;
                        return; // Fiber exits — io_uring takes over
                    }

                    // WebSocket read loop (fiber path)
                    //
                    // This connection is now the one shape where the *peer* could
                    // otherwise choose how long `stop()` takes: the loop below
                    // reads with a bare `read` and the loop condition alone never
                    // ends it. So it is registered for the shutdown wake pass
                    // first — `stop()` shuts registered sockets down, which makes
                    // the parked read return 0.
                    //
                    // The `defer` runs *before* `connFiber`'s `defer stream.close`
                    // (LIFO), which is the invariant `wakeWsConnections` depends
                    // on: an entry never outlives the fd it names.
                    const ws_fd = stream.socket.handle;
                    const reserved = server.registerWsConnection(ws_fd) catch |err| blk: {
                        // An unreservable connection must not be served half-tracked:
                        // it is refused exactly like the stopping case, and named so
                        // an allocation failure is not read as a shutdown.
                        std.log.warn("[Server] WS connection refused, cannot reserve it for shutdown: {}", .{err});
                        break :blk false;
                    };
                    if (!reserved) {
                        // `stop()` is under way: don't park in a read nobody will
                        // wake. The client gets a close frame, the application its
                        // `on_close`.
                        framer.writeClose() catch |err| std.log.debug("[Server] WS writeClose on stopping: {}", .{err});
                        if (@intFromPtr(ws_route.on_close) != 0) ws_route.on_close(session);
                        return;
                    }
                    defer server.unregisterWsConnection(ws_fd);

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
            // The match borrows its parameters from the trie and the request
            // line, so they are copied into the map handlers read. That copy is
            // the allocation that can fail, and this is the level that can
            // answer for it: a 500 for this request — not a match with a
            // parameter missing from it.
            if (copyParamsOwned(arena_alloc, &m.params, &ctx.params)) |_| {
                ctx.user_data = m.route.user_data;
                ctx.route_template = m.route.path;

                server.executeWithMiddleware(&ctx, m.route.handler, m.route.combined_middleware) catch |err| {
                    std.log.err("[HC] Handler error: {any}", .{err});
                    if (!ctx.responded) {
                        ctx.sendError(500, @errorName(err)) catch |e| std.log.err("[Server] Failed to send 500: {}", .{e});
                    }
                };
            } else |err| {
                std.log.err("[HC] route params could not be copied into the request: {any}", .{err});
                if (!ctx.responded) {
                    ctx.sendError(500, "Internal Server Error") catch |e| std.log.err("[Server] Failed to send 500: {}", .{e});
                }
            }
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
            writeResponse(
                stream,
                ctx.status_code,
                ctx.response_headers,
                ctx.response_body.items,
                // `HEAD`: the response ends at the field section. Every route
                // reached through here — a handler's 200, `sendError`'s 404/408
                // — gets the same treatment, and the declared `Content-Length`
                // still describes the entity the `GET` would have sent.
                ctx.method != .HEAD,
                server.response_write_timeout_ms,
            ) catch |err| {
                switch (err) {
                    // A header the server refuses (non-token name, CR/LF value,
                    // past the value ceiling) is a server-side bug — a handler
                    // built it from input it should have validated.
                    // `writeResponse` rejects before writing a byte, so the
                    // connection is still clean and the client gets a status
                    // instead of nothing. `warn`, not `err`: the request is
                    // answered, and an error-level line makes
                    // `scripts/test-runner.zig` fail the whole suite (it counts
                    // err-level logs as failures).
                    error.InvalidHeader, error.HeaderTooLarge, error.LineTooLong => {
                        std.log.warn("[HC] response header refused: {any}", .{err});
                        writeErrorResponse(stream, arena_alloc, 500, "Internal Server Error", ctx.method == .HEAD, server.response_write_timeout_ms);
                    },
                    // The peer stopped reading and the response is truncated:
                    // the connection ends here. That is the bound doing its job
                    // (`response_write_timeout_ms`), not a server fault — and a
                    // `debug` line, because an err-level one fails the suite.
                    error.WriteTimeout => std.log.debug("[HC] response abandoned: peer stopped reading", .{}),
                    error.ConnectionError, error.ConnectionClosed => std.log.debug("[HC] client went away mid-response", .{}),
                    // Exhaustive on purpose: `writeResponse`'s error set is
                    // inferred from its body, so a new one is a compile error
                    // here rather than an error nobody logs.
                }
                // Whatever went wrong, this connection is not a clean one to
                // keep serving: the response is either refused before its first
                // byte, truncated, or the peer is gone. (A write timeout used to
                // mean a parked fiber; now it means the connection ends.)
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
///
/// Bounded like every other response write (`write_timeout_ms`, 0 = unbounded):
/// a peer that stops reading must not own the **accept loop**, which is worse
/// than owning one connection's fiber — no new connection can be taken while it
/// is parked here. The over-limit socket may never speak HTTP at all, so this is
/// the answer it is least likely to read.
fn writeOverLimit503(stream: std.Io.net.Stream, write_timeout_ms: u32) void {
    var body_buf: [1024]u8 = undefined;
    const rendered = renderTransportError(503, "Service Unavailable", &body_buf);
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ rendered.content_type, rendered.body.len }) catch return;
    sockread.setSendTimeout(stream, write_timeout_ms);
    defer if (write_timeout_ms != 0) sockread.clearSendTimeout(stream);
    writeRaw(stream, head);
    writeRaw(stream, rendered.body);
}

/// Best-effort write that gives up on its own errors (`WriteTimeout` included —
/// the caller has nothing to say to a peer that is not reading).
fn writeRaw(stream: std.Io.net.Stream, bytes: []const u8) void {
    sockread.writeFull(stream, bytes) catch |err| {
        std.log.debug("[Server] raw write gave up: {s}", .{@errorName(err)});
    };
}

/// Error response for requests that failed *before* routing (bad request line,
/// oversized body, header flood). This runs outside the middleware chain, so a
/// middleware cannot restyle it — `transport_error_renderer` is the hook.
///
/// `head_request`: a response to `HEAD` is its field section — `Content-Length`
/// for the entity the answer would have carried, included — and no octets
/// (RFC 9110 §9.3.2). These failures are answered before there is a `Context`,
/// so the caller decides: a request line in hand says `HEAD` (`requestLineIsHead`),
/// and a caller with no request line at all passes `false` — the method is
/// genuinely unknown there, and the body is the only answer that is right for
/// every request that is not `HEAD`.
fn writeErrorResponse(
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    status: u16,
    message: []const u8,
    head_request: bool,
    write_timeout_ms: u32,
) void {
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

    writeResponse(stream, status, headers, rendered.body, !head_request, write_timeout_ms) catch |err| switch (err) {
        // The framework's own field section was refused — a bug here, not in a
        // handler: the 500 it was going to answer with is not on the wire.
        error.InvalidHeader, error.HeaderTooLarge, error.LineTooLong => std.log.err("[Server] writeErrorResponse's own header refused: {}", .{err}),
        // The peer stopped reading: the answer is truncated and the connection
        // ends with it. That is the bound doing its job, not a server fault, so
        // it is not an error-level line (which `scripts/test-runner.zig` counts
        // as a test failure).
        error.WriteTimeout => std.log.debug("[Server] writeErrorResponse abandoned: peer stopped reading", .{}),
        error.ConnectionError, error.ConnectionClosed => std.log.debug("[Server] writeErrorResponse: peer gone", .{}),
        // Exhaustive for the same reason the caller's switch is: a new error out
        // of `writeResponse` must be looked at, not swallowed.
    };
}

/// Whether a request line read from the wire begins with the `HEAD` method
/// token. The pre-routing failures `writeErrorResponse` answers have no parsed
/// request, and this is the only thing their answer needs from one: a method
/// token is case-sensitive (RFC 9110 §9.1) and is separated from the target by
/// one space, so a leading `HEAD ` is the method while `HEADER` and `head` are
/// not.
fn requestLineIsHead(raw: []const u8) bool {
    const line = RequestParser.trimCrlf(raw);
    if (!std.mem.startsWith(u8, line, "HEAD")) return false;
    return line.len == 4 or line[4] == ' ';
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
        // Nothing to release: the match borrows the trie's parameter name and
        // a slice of the path it was given.
        try std.testing.expectEqualStrings("123", m.params.get("id").?);
    } else {
        try std.testing.expect(false);
    }

    const no_match = router.match(std.testing.allocator, .GET, "/posts/123");
    try std.testing.expect(no_match == null);
}

// `Router.match` used to copy every parameter name and value into a
// `StringHashMap`, and both ways that could fail were lies about the request:
// the traversal's `catch return null` came back as "no route matched" — a 404
// for a route that exists — and the map-filling `catch` in the exact-route
// branch kept the match with the parameters it managed to copy, so a handler
// reading a tenant or user path parameter found it silently absent. Neither
// needs the heap: the keys are the tree's own node names and the values are
// slices of the path handed in. An allocator that refuses everything must
// therefore not change the answer.
test "Router match answers from the tree and the path, not the heap" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const route = Route{
        .method = .GET,
        .path = "/users/{id}/posts/{post}",
        .handler = struct {
            fn handle(_: *Context) anyerror!void {}
        }.handle,
    };
    try router.addRoute(route);

    // 4 = let both keys and both values through and refuse the map's own bucket
    // array (the case that used to yield a match missing a parameter), 0 =
    // refuse the first allocation (the case that used to yield a 404 for a
    // route that exists), maxInt = refuse nothing. Ordered so the partly
    // copied match is the first thing this test reports.
    for ([_]usize{ 4, 0, std.math.maxInt(usize) }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const matched = router.match(failing.allocator(), .GET, "/users/123/posts/456");

        // `null` here is the first defect: an allocation failure wearing the
        // answer "no such route".
        try std.testing.expect(matched != null);
        // `null` from `.get("id")` is the second: a match that is missing a
        // parameter the path carried.
        try std.testing.expectEqualStrings("123", matched.?.params.get("id").?);
        try std.testing.expectEqualStrings("456", matched.?.params.get("post").?);
        // And matching must not have needed the heap at all: an allocation
        // failure cannot be answered honestly by a function with no error
        // channel, so the fix is to make none of them happen.
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }
}

// A route with more parameters than `RouteParams.MAX` cannot ever match: the
// trie accepted the path, registration reported nothing, and `match` answered
// `null` for every request — a 404 for a route the application believes it
// registered. The limit is a property of the route and registration is where it
// is knowable, so it is refused there, before the trie is touched.
//
// Red evidence: with the `addRoute` check removed, the `expectError` below reads
// `expected error.TooManyRouteParams, found void` — the route registers — and the
// nine-segment request that follows matches nothing.
test "registering a route with more parameters than RouteParams.MAX is refused" {
    const allocator = std.testing.allocator;
    const Handle = struct {
        fn handle(_: *Context) anyerror!void {}
    };

    var router = Router.init(allocator);
    defer router.deinit();

    // `MAX` itself still registers and matches: the limit is exclusive.
    try router.addRoute(.{
        .method = .GET,
        .path = "/a/{p1}/b/{p2}/c/{p3}/d/{p4}/e/{p5}/f/{p6}/g/{p7}/h/{p8}",
        .handler = Handle.handle,
    });
    const matched = router.match(allocator, .GET, "/a/v1/b/v2/c/v3/d/v4/e/v5/f/v6/g/v7/h/v8");
    try std.testing.expectEqual(@as(usize, 8), matched.?.params.count);
    try std.testing.expectEqualStrings("v8", matched.?.params.get("p8").?);

    // One past it is a startup error, not a per-request 404.
    try std.testing.expectError(error.TooManyRouteParams, router.addRoute(.{
        .method = .GET,
        .path = "/a/{p1}/b/{p2}/c/{p3}/d/{p4}/e/{p5}/f/{p6}/g/{p7}/h/{p8}/i/{p9}",
        .handler = Handle.handle,
    }));
    // Refused before the trie was touched, so the rejection leaves no half-built
    // route behind.
    try std.testing.expect(router.match(allocator, .GET, "/a/v1/b/v2/c/v3/d/v4/e/v5/f/v6/g/v7/h/v8/i/v9") == null);
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
    const matched_opt = server.router.match(allocator, .GET, "/api/v1/users");
    // A match owns nothing to release: its parameters borrow from the trie and
    // the path.
    try std.testing.expect(matched_opt != null);
}

test "wildcard route matching" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const expectMatch = struct {
        fn call(r: *Router, method: Method, path: []const u8) !void {
            try std.testing.expect(r.match(allocator, method, path) != null);
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
        var ctx = try Context.init(allocator, .GET, "/users/99");
        defer ctx.deinit();

        // Copy params from matched route — the match borrowed them, the map owns them.
        try copyParamsOwned(allocator, &m.params, &ctx.params);

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
    const m1 = server.router.match(allocator, .GET, "/test/overview/home/dashboard");
    if (m1 == null) @panic("route match failed: expected GET /test/overview/home/dashboard to resolve " ++
        "(registered as group(\"/test/overview/home\").get(\"/dashboard\")). Fix the prefix join in " ++
        "RouteGroup.get / normalizeRoutePath, or correct the path asserted here.");

    // Test: 2-segment path should match
    const m2 = server.router.match(allocator, .GET, "/customer/summary");
    if (m2 == null) @panic("route match failed: expected GET /customer/summary to resolve " ++
        "(registered as group(\"/customer\").get(\"/summary\")). Fix RouteGroup prefix joining, " ++
        "or correct the path asserted here.");

    // Test: 3-segment paths should match
    const m3 = server.router.match(allocator, .GET, "/crm/statistics");
    if (m3 == null) @panic("route match failed: expected GET /crm/statistics to resolve " ++
        "(registered as group(\"/crm\").get(\"/statistics\")). Fix RouteGroup prefix joining, " ++
        "or correct the path asserted here.");

    const m4 = server.router.match(allocator, .GET, "/insurance/compensation-plan");
    if (m4 == null) @panic("route match failed: expected GET /insurance/compensation-plan to resolve " ++
        "(registered as group(\"/insurance\").get(\"/compensation-plan\")). Fix RouteGroup prefix " ++
        "joining, or correct the path asserted here.");

    // Params need no cleanup: a match borrows them.
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
    const matched = server.router.match(allocator, .GET, ctx.path);
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

/// A body no combination of kernel send/receive buffers can absorb, so a client
/// that stops reading forces the server's write to block (measured on macOS
/// loopback: ~1.6 MiB gets buffered before `send` blocks).
const stalled_response_bytes = 16 * 1024 * 1024;

/// The body the `/big` route serves. A global because a `HandlerFn` carries no
/// context of its own.
var stalled_body: []u8 = &.{};

fn bigResponse(ctx: *Context) anyerror!void {
    try ctx.text(200, stalled_body);
}

// The write-side twin of the WS shutdown tests below, and the same shape of
// finding: the *peer* decides how long a connection fiber lives. A client that
// asks for a large response and then never reads parks the fiber inside
// `writeResponse`'s blocking send, and `start()`'s `conn_group.await` waits for
// that fiber — so `stop()` would be unbounded too.
//
// `response_write_timeout_ms` is what ends it. The wait below is a hang budget
// (3 s), not a latency claim: the budget under test is 200 ms.
test "a response write is bounded: a non-reading peer cannot hold the connection fiber" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    stalled_body = try allocator.alloc(u8, stalled_response_bytes);
    defer {
        allocator.free(stalled_body);
        stalled_body = &.{};
    }
    @memset(stalled_body, 'x');

    // `header_timeout_ms` is small too, so the *keep-alive* read a finished
    // response returns to cannot outlive the test either.
    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .response_write_timeout_ms = 200,
        .header_timeout_ms = 200,
    });
    defer server.deinit();
    var group = server.group("");
    try group.get("big", bigResponse, null);

    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    var joined = false;
    defer if (!joined) {
        server.stop();
        th.join();
    };

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
    var closed_client = false;
    defer if (!closed_client) stream.close(std.testing.io);

    var wbuf: [256]u8 = undefined;
    var w = stream.writer(std.testing.io, &wbuf);
    // Ask for the big body and then *never read*: no more client work happens
    // until the assertions below are done.
    try w.interface.writeAll("GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.interface.flush();

    // The fiber took the connection...
    var waited_ms: usize = 0;
    while (server.active_connections.load(.monotonic) == 0 and waited_ms < 3000) : (waited_ms += 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expectEqual(@as(u64, 1), server.active_connections.load(.monotonic));

    // ...and the write budget ended it, with nobody reading the socket.
    waited_ms = 0;
    while (server.active_connections.load(.monotonic) != 0 and waited_ms < 3000) : (waited_ms += 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    const still_running = server.active_connections.load(.monotonic);
    if (still_running != 0) {
        // Report before the cleanup unblocks it: a read here would let the write
        // finish and hide exactly what is being asserted.
        std.log.err("[test] a non-reading peer held the connection fiber {d}ms past the 200ms write budget", .{waited_ms});
        var drain: [64 * 1024]u8 = undefined;
        _ = std.posix.read(stream.socket.handle, &drain) catch {};
    }
    try std.testing.expectEqual(@as(u64, 0), still_running);

    // And the client's answer is a *truncated* response, not a delivered one:
    // the field section names the whole body, the octets stop early, and the
    // connection ends there.
    var saw_declared_length = false;
    var total: usize = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (total < stalled_response_bytes) {
        const n = std.posix.read(stream.socket.handle, &buf) catch break;
        if (n == 0) break;
        if (!saw_declared_length and std.mem.indexOf(u8, buf[0..n], "Content-Length: 16777216\r\n") != null) saw_declared_length = true;
        total += n;
    }
    try std.testing.expect(saw_declared_length);
    try std.testing.expect(total > 0);
    try std.testing.expect(total < stalled_response_bytes);

    stream.close(std.testing.io);
    closed_client = true;
    // `stop()` first: `start()`'s thread only returns once the server is told
    // to stop, so joining before that is a hang, not a shutdown.
    server.stop();
    th.join();
    joined = true;
}

// The other half of that contract: `response_write_timeout_ms = 0` is the
// behavior the default replaces — no budget, so the peer owns the fiber. This is
// the red shape the bound above is measured against, and it is a test rather
// than a note because "0 means unbounded" is a documented promise.
test "response_write_timeout_ms = 0 keeps the unbounded write: only the client can end it" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    stalled_body = try allocator.alloc(u8, stalled_response_bytes);
    defer {
        allocator.free(stalled_body);
        stalled_body = &.{};
    }
    @memset(stalled_body, 'x');

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .response_write_timeout_ms = 0,
        .header_timeout_ms = 200,
    });
    defer server.deinit();
    var group = server.group("");
    try group.get("big", bigResponse, null);

    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    var joined = false;
    defer if (!joined) {
        server.stop();
        th.join();
    };

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
    var closed_client = false;
    defer if (!closed_client) stream.close(std.testing.io);

    var wbuf: [256]u8 = undefined;
    var w = stream.writer(std.testing.io, &wbuf);
    try w.interface.writeAll("GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.interface.flush();

    // A second of silence with the client not reading: the fiber cannot have
    // finished, because finishing needs the whole body to be accepted.
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1000), .real) catch {};
    try std.testing.expectEqual(@as(u64, 1), server.active_connections.load(.monotonic));

    // Reading is what ends it, and the whole body arrives (nothing was cut):
    // `total` counts the field section too, so the body is what follows the
    // blank line the response starts with.
    var total: usize = 0;
    var head_bytes: usize = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (total < stalled_response_bytes) {
        const n = std.posix.read(stream.socket.handle, &buf) catch break;
        if (n == 0) break;
        if (head_bytes == 0) {
            if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n")) |i| head_bytes = i + 4;
        }
        total += n;
    }
    try std.testing.expect(head_bytes > 0);
    try std.testing.expectEqual(@as(usize, stalled_response_bytes), total - head_bytes);

    stream.close(std.testing.io);
    closed_client = true;
    var waited_ms: usize = 0;
    while (server.active_connections.load(.monotonic) != 0 and waited_ms < 3000) : (waited_ms += 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    server.stop();
    th.join();
    joined = true;
}

/// Why the streaming handler below left its loop. Written on the connection
/// fiber and read by the test after that fiber is gone (the only writer), so the
/// assertion is "the write failed, and with this error" rather than an inference
/// from byte counts.
var stream_failure: ?anyerror = null;

/// An SSE handler that only stops when a write fails. With a subscriber that
/// stops reading, the only thing that can fail a write is
/// `response_write_timeout_ms` — which is what makes this a test of the bound
/// rather than of the peer.
fn sseFlood(ctx: *Context) anyerror!void {
    var sse = try @import("../http/Sse.zig").SseWriter.init(ctx);
    var line: [8 * 1024]u8 = @splat('s');
    while (true) {
        sse.sendData(&line) catch |err| {
            stream_failure = err;
            break;
        };
    }
}

/// The chunked-transfer twin of `sseFlood`: `Context.writeChunk` is the other
/// writer that used to go through `std.Io`'s writer.
fn chunkedFlood(ctx: *Context) anyerror!void {
    try ctx.startChunked(200, "application/octet-stream");
    var chunk: [16 * 1024]u8 = @splat('c');
    while (true) {
        ctx.writeChunk(&chunk) catch |err| {
            stream_failure = err;
            break;
        };
    }
    ctx.endStream() catch |err| std.log.debug("[test] flooding handler's endStream failed: {s}", .{@errorName(err)});
}

/// The shared body of the streaming tests: a server whose write budget is
/// 200 ms, a handler that floods, and a client that asks and then never reads.
///
/// `stream_marker` is a byte string the first response bytes must contain, so a
/// passing test also shows the stream really started (the head went out before
/// the budget ran out).
fn runFloodTest(handler: HandlerFn, request_path: []const u8, stream_marker: []const u8) !void {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    stream_failure = null;

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .response_write_timeout_ms = 200,
        .header_timeout_ms = 200,
    });
    defer server.deinit();
    var group = server.group("");
    try group.get(request_path, handler, null);

    var running = try TestServer.start(&server);
    var joined = false;
    defer if (!joined) {
        server.stop();
        running.thread.join();
    };

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", running.port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    var closed_client = false;
    defer if (!closed_client) stream.close(std.testing.io);

    var wbuf: [256]u8 = undefined;
    var w = stream.writer(std.testing.io, &wbuf);
    try w.interface.print("GET /{s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{request_path});
    try w.interface.flush();

    // The handler took the connection and is flooding it; this client reads
    // nothing, so a write can only fail by timing out.
    var waited_ms: usize = 0;
    while (server.active_connections.load(.monotonic) == 0 and waited_ms < 3000) : (waited_ms += 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch |err|
            std.log.debug("[test] flood poll sleep failed: {s}", .{@errorName(err)});
    }
    try std.testing.expectEqual(@as(u64, 1), server.active_connections.load(.monotonic));

    must_finish: {
        waited_ms = 0;
        while (server.active_connections.load(.monotonic) != 0 and waited_ms < 3000) : (waited_ms += 10) {
            std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch |err|
                std.log.debug("[test] flood poll sleep failed: {s}", .{@errorName(err)});
        }
        const still_running = server.active_connections.load(.monotonic);
        if (still_running != 0) {
            // Report before reading anything: reading is what would unblock the
            // write and hide exactly what is being asserted.
            std.log.err("[test] a non-reading subscriber held a streaming fiber {d}ms past the 200ms write budget", .{waited_ms});
            var drain: [64 * 1024]u8 = undefined;
            _ = std.posix.read(stream.socket.handle, &drain) catch |err|
                std.log.debug("[test] unblocking read after the report failed: {s}", .{@errorName(err)});
            break :must_finish;
        }
    }

    // What did arrive is the *head* of a stream that never finished: fewer body
    // bytes than the handler attempted, and the head is there to prove the
    // stream really started before the budget ran out. The field section is not
    // part of what the handler attempted, so it is measured and subtracted.
    var first: [8 * 1024]u8 = undefined;
    var first_len: usize = 0;
    var total: usize = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (total < 64 * 1024 * 1024) {
        const n = std.posix.read(stream.socket.handle, &buf) catch break;
        if (n == 0) break;
        if (first_len == 0) {
            first_len = @min(n, first.len);
            @memcpy(first[0..first_len], buf[0..first_len]);
        }
        total += n;
    }
    try std.testing.expect(total > 0);
    try std.testing.expect(std.mem.indexOf(u8, first[0..first_len], stream_marker) != null);
    const head_bytes = @min((std.mem.indexOf(u8, first[0..first_len], "\r\n\r\n") orelse first_len) + 4, total);
    // The head went out, so what follows it is the start of a body: the stream
    // was live, and it is the *write* that ended — with the budget's error.
    try std.testing.expect(total > head_bytes);
    try std.testing.expectEqual(@as(?anyerror, error.WriteTimeout), stream_failure);

    stream.close(std.testing.io);
    closed_client = true;
    server.stop();
    running.thread.join();
    joined = true;
}

test "a stalled SSE subscriber cannot hold the fiber: the write budget ends the stream" {
    try runFloodTest(sseFlood, "events", "text/event-stream");
}

test "a stalled chunked client cannot hold the fiber: the write budget ends the stream" {
    try runFloodTest(chunkedFlood, "chunks", "Transfer-Encoding: chunked");
}

test "an HTTP/2 client that stops reading cannot hold the session: the write budget ends it" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // Just over any plausible socket-buffer pair, and *under* the session's own
    // outbound-pending cap (`max_pending_bytes` = 4 MiB): a body past that cap
    // is refused with RST_STREAM(INTERNAL_ERROR) before any of it is written,
    // which is a different behavior (and a separate finding) from a blocked
    // write.
    const body_bytes = 3 * 1024 * 1024;
    stalled_body = try allocator.alloc(u8, body_bytes);
    defer {
        allocator.free(stalled_body);
        stalled_body = &.{};
    }
    @memset(stalled_body, 'x');

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .name = "h2-stalled",
        .response_write_timeout_ms = 200,
        // Deliberately *larger* than this test's 3 s budget: the H2 read-idle
        // budget is also a way for a quiet session to end (`header_timeout_ms`),
        // and this test must show the write bound ended it. With 10 s on the read
        // side, only the write budget can end the session inside 3 s.
        .header_timeout_ms = 10_000,
    });
    defer server.deinit();
    server.setHttp2Enabled(true);
    var group = server.group("");
    try group.get("big", bigResponse, null);

    var running = try TestServer.start(&server);
    var joined = false;
    defer if (!joined) {
        server.stop();
        running.thread.join();
    };

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", running.port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    var closed_client = false;
    defer if (!closed_client) stream.close(std.testing.io);

    // The advertised window is what makes this test possible at all: H2's own
    // flow control would otherwise cap the response at the initial 64 KiB —
    // comfortably inside any kernel send buffer — and the session would wait for
    // a WINDOW_UPDATE (bounded by `read_idle_timeout_ms`) instead of ever
    // reaching a blocked `send`. A 16 MiB window puts the whole body on the wire,
    // which no combination of buffers absorbs.
    const window: u32 = 16 * 1024 * 1024;
    const settings = try Http2.encodeSettings(allocator, false, &.{.{ Http2.SettingsId.initial_window_size, window }});
    defer allocator.free(settings);
    const conn_window = try Http2.encodeWindowUpdate(allocator, 0, window);
    defer allocator.free(conn_window);
    const block = try h2RequestBlock(allocator, "GET", "/big", &.{});
    defer allocator.free(block);
    const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(head);
    // **No per-stream `WINDOW_UPDATE`**: the stream's send window has to come
    // from the SETTINGS above (`INITIAL_WINDOW_SIZE` applies to streams opened
    // after it — RFC 9113 §6.5.2). That is deliberate, and it is what makes this
    // test the regression test for `Http2.FlowControlState.initStream`: while new
    // streams started at the protocol default instead, the response stopped at
    // 64 KiB (measured: 65636 bytes on the wire, then a stall) and this test's
    // 3 s budget could never be met — the session was waiting for a per-stream
    // window nobody was going to send, so no `send` ever blocked and no write
    // budget could fire.
    try sockread.writeFull(stream, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    try sockread.writeFull(stream, settings);
    try sockread.writeFull(stream, conn_window);
    try sockread.writeFull(stream, head);
    // And then nothing: no read, no further WINDOW_UPDATE, no GOAWAY.

    var waited_ms: usize = 0;
    while (server.active_connections.load(.monotonic) == 0 and waited_ms < 3000) : (waited_ms += 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expectEqual(@as(u64, 1), server.active_connections.load(.monotonic));

    waited_ms = 0;
    while (server.active_connections.load(.monotonic) != 0 and waited_ms < 3000) : (waited_ms += 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    const still_running = server.active_connections.load(.monotonic);
    if (still_running != 0) {
        var drain: [64 * 1024]u8 = undefined;
        var drained: usize = 0;
        var polls = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        while (std.posix.poll(&polls, 200) catch 0 > 0) {
            const n = std.posix.read(stream.socket.handle, &drain) catch break;
            if (n == 0) break;
            drained += n;
        }
        std.log.err("[test] a non-reading HTTP/2 client held the session fiber {d}ms past the 200ms write budget ({d} bytes on the wire)", .{ waited_ms, drained });
        var off: usize = 0;
        while (off + 9 <= drained) {
            const f = Http2.decodeFrame(drain[off..drained]) catch break;
            std.log.err("[test]   frame {s} len={d} flags=0x{x} stream={d} payload={any}", .{ @tagName(f.header.typ), f.header.length, f.header.flags, f.header.stream_id, f.payload[0..@min(f.payload.len, 4)] });
            off += 9 + @as(usize, f.header.length);
        }
    }
    try std.testing.expectEqual(@as(u64, 0), still_running);

    // The session wrote the head of a response and then stopped: some frame bytes
    // arrived, and the DATA frames stop well short of the 16 MiB body.
    var total: usize = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (total < body_bytes) {
        const n = std.posix.read(stream.socket.handle, &buf) catch break;
        if (n == 0) break;
        total += n;
    }
    try std.testing.expect(total > 0);
    try std.testing.expect(total < body_bytes);

    stream.close(std.testing.io);
    closed_client = true;
    server.stop();
    running.thread.join();
    joined = true;
}

/// The framer of the WebSocket route below, so the pusher thread can write to it
/// — an application pushes to its own sessions, and *that* write is what a peer
/// which stopped reading parks.
var ws_push_framer: ?*WsFramer = null;
var ws_push_failure: ?anyerror = null;

/// Push binary frames until a write fails. Nothing else can stop it: a peer that
/// is reading never makes a write fail.
fn wsPusher() void {
    const framer = ws_push_framer orelse return;
    var frame: [8 * 1024]u8 = @splat('w');
    while (true) {
        framer.writeFrame(0x2, &frame) catch |err| {
            ws_push_failure = err;
            return;
        };
    }
}

test "a WebSocket push to a peer that stopped reading gets the write budget (ws 0 = inherit)" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    ws_push_framer = null;
    ws_push_failure = null;
    ws_silent_state = .{};

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        // `ws_write_timeout_ms` is deliberately left at its default 0: this is
        // the *inheritance* test — one number for response writes and frame
        // pushes, which is what `0` means since 第 58 批.
        .response_write_timeout_ms = 200,
    });
    defer server.deinit();
    var group = server.group("");
    try group.ws("ws", (struct {
        fn connect(_: *Context, framer: ?*anyopaque) ?*anyopaque {
            ws_push_framer = @ptrCast(@alignCast(framer.?));
            const th = std.Thread.spawn(.{}, wsPusher, .{}) catch return null;
            th.detach();
            return @ptrCast(&ws_silent_state);
        }
    }).connect, (struct {
        fn message(_: ?*anyopaque, _: []const u8, _: WsFrameKind) void {}
    }).message, (struct {
        fn close(session: ?*anyopaque) void {
            _ = session;
            ws_silent_state.closed.store(true, .monotonic);
        }
    }).close, null);

    var running = try TestServer.start(&server);
    var joined = false;
    defer if (!joined) {
        server.stop();
        running.thread.join();
    };

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", running.port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    var closed_client = false;
    defer if (!closed_client) stream.close(std.testing.io);

    var wbuf: [512]u8 = undefined;
    var w = stream.writer(std.testing.io, &wbuf);
    try w.interface.writeAll("GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");
    try w.interface.flush();

    // Read the 101 and then never read again: from here the pusher is talking to
    // a full socket buffer.
    var pfds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expect((try std.posix.poll(&pfds, 3000)) > 0);
    var resp: [512]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, resp[0..try std.posix.read(stream.socket.handle, &resp)], "101") != null);

    // The pusher returns as soon as one write fails, and with nobody reading the
    // only thing that can fail one is the budget. 3 s is a hang budget: the bound
    // under test is 200 ms.
    var waited_ms: usize = 0;
    while (ws_push_failure == null and waited_ms < 3000) : (waited_ms += 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch |err|
            std.log.debug("[test] push poll sleep failed: {s}", .{@errorName(err)});
    }
    const failure = ws_push_failure;
    if (failure == null) {
        std.log.err("[test] a WebSocket push to a non-reading peer parked {d}ms past the 200ms write budget", .{waited_ms});
        // Nothing shut the socket down, so unblock the pusher for the teardown.
        stream.close(std.testing.io);
        closed_client = true;
    }
    try std.testing.expectEqual(@as(?anyerror, error.WriteTimeout), failure);

    // And the server side ends with it: `WsFramer.writeFrame` shuts the socket
    // down on a send timeout, so the connection fiber's read returns and the fiber
    // leaves — the connection is not left half-open.
    waited_ms = 0;
    while (server.active_connections.load(.monotonic) != 0 and waited_ms < 3000) : (waited_ms += 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch |err|
            std.log.debug("[test] fiber poll sleep failed: {s}", .{@errorName(err)});
    }
    try std.testing.expectEqual(@as(u64, 0), server.active_connections.load(.monotonic));

    stream.close(std.testing.io);
    closed_client = true;
    server.stop();
    running.thread.join();
    joined = true;
}

/// Server-side state for the silent-peer shutdown test. Atomics because the
/// callbacks run on the connection fiber and the assertions on the test thread.
const WsSilentState = struct {
    closed: std.atomic.Value(bool) = .init(false),
};
var ws_silent_state = WsSilentState{};

// A client that completes the handshake and then says nothing — no frame, no
// close frame, no FIN.
//
// The connection fiber parks in a bare `read` (`im/WsFramer.zig` `readFull` →
// `core/sockread.zig` `readSome`), which nothing on the shutdown path disturbs,
// while `start()`'s `conn_group.await` waits for that fiber — so the length of
// `stop()` is decided by the *peer*. `stop()` must shut those sockets down.
//
// The wait below is a **hang budget, not a latency bound**: the wake pass is
// immediate, so a green run finishes in microseconds and only a drain that
// never ends reaches the 3 s ceiling. It therefore cannot prove *how fast*
// shutdown is — only that it does not depend on the peer.
test "stop() ends a silent WebSocket client's fiber instead of waiting for the peer" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    ws_silent_state = .{};

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0 });
    defer server.deinit();
    var group = server.group("");
    try group.ws("ws", (struct {
        fn connect(_: *Context, _: ?*anyopaque) ?*anyopaque {
            return @ptrCast(&ws_silent_state);
        }
    }).connect, (struct {
        fn message(_: ?*anyopaque, _: []const u8, _: WsFrameKind) void {}
    }).message, (struct {
        fn close(session: ?*anyopaque) void {
            _ = session;
            ws_silent_state.closed.store(true, .monotonic);
        }
    }).close, null);

    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    var joined = false;
    // LIFO note: the client socket below is closed *before* this runs, so the
    // failure path can never leave the accept thread parked in a drain.
    defer if (!joined) {
        server.stop();
        th.join();
    };

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

    // Read the 101, then go silent for the rest of the test.
    var pfds = [_]std.posix.pollfd{.{
        .fd = stream.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expect((try std.posix.poll(&pfds, 3000)) > 0);
    var resp: [512]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, resp[0..try std.posix.read(stream.socket.handle, &resp)], "101") != null);

    // The upgrade answer is written before `on_connect` runs, so the counter can
    // be observed a moment before the fiber reaches its read loop. Wait for the
    // connection to be *registered* (the step immediately before that read)
    // rather than guessing with a sleep, so the assertions below are about the
    // parked state, not about a race.
    tries = 0;
    while (server.registeredWsCount() != 1 and tries < 200) : (tries += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), server.registeredWsCount());

    server.stop();

    // **Either** the wake pass shut this connection's socket down, **or** the
    // fiber saw `running == false` on its way into the read and left before
    // parking. Both end it without any cooperation from the peer — which is the
    // claim this test exists for — but only the first exercises the wake pass,
    // and the wake pass has its own deterministic test
    // (`stop() shuts down every registered WebSocket connection`: socketpair, no
    // fiber, no timing).
    //
    // This used to assert `ws_woken_connections == 1` outright, and that is a
    // race: between `registerWsConnection` returning and the fiber's first
    // `running` check there is a window, and a stop() landing inside it leaves the
    // fiber to leave on its own (observed as one red CI job, green on rerun and in
    // 40 idle local runs). Asserting the disjunction keeps the teeth that matter:
    // a *parked* fiber that the wake pass fails to wake is still registered here
    // and still fails the budget check below.
    const registered_after_stop = server.registeredWsCount();
    const woken = server.ws_woken_connections.load(.monotonic);
    if (woken == 0) {
        std.log.warn("[test] the silent connection was not woken (registered after stop: {d}): it saw `running == false` and left before parking, so this run does not exercise the wake pass", .{registered_after_stop});
    }
    try std.testing.expect(woken == 1 or registered_after_stop == 0);

    // Bounded wait for the connection fiber to be gone. 3 s is a hang budget:
    // the wake pass runs inside `stop()`, so nothing here is a latency bound.
    var waited_ms: usize = 0;
    while (server.active_connections.load(.monotonic) != 0 and waited_ms < 3000) : (waited_ms += 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    const still_running = server.active_connections.load(.monotonic);
    if (still_running != 0) {
        // The peer's silence is exactly what holds it: end the silence, let the
        // threads unwind, then report the observation made *before* the cleanup.
        std.log.err("[test] stop() left the WebSocket fiber parked {d}ms after it returned: the silent peer decides the shutdown length", .{waited_ms});
        stream.close(std.testing.io);
        closed_early = true;
        th.join();
        joined = true;
    }
    try std.testing.expectEqual(@as(u64, 0), still_running);

    th.join();
    joined = true;
    // `on_close` runs before the fiber returns, so a drained connection count
    // means the application was told, not just abandoned.
    try std.testing.expect(ws_silent_state.closed.load(.monotonic));
    try std.testing.expect(server.listener == null);
    // The reservation is gone too — made before the fiber could close the fd, so
    // no later wake pass can land on a recycled descriptor.
    try std.testing.expectEqual(@as(usize, 0), server.registeredWsCount());

    stream.close(std.testing.io);
    closed_early = true;
}

// The registry half of the shutdown fix, without a server or a network: a
// socketpair stands in for an upgraded connection, and the assertion is the
// syscall-level consequence the fiber read depends on (`shutdown` → the read
// returns EOF). Deterministic — no timing, no peer.
test "stop() shuts down every registered WebSocket connection" {
    const allocator = std.testing.allocator;
    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0 });
    defer server.deinit();

    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    var peer_fds: [2]std.posix.socket_t = undefined;
    const rc2 = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &peer_fds);
    switch (std.posix.errno(rc2)) {
        .SUCCESS => {},
        else => {
            _ = std.posix.system.close(fds[0]);
            _ = std.posix.system.close(fds[1]);
            return error.SkipZigTest;
        },
    }
    defer {
        for (fds) |fd| _ = std.posix.system.close(fd);
        for (peer_fds) |fd| _ = std.posix.system.close(fd);
    }

    // The registry only accepts a connection while the server is up: `start()`
    // sets this flag, `stop()` is what clears it. Set it here the way a running
    // accept loop would.
    server.running.store(true, .monotonic);
    try std.testing.expect(try server.registerWsConnection(fds[0]));
    try std.testing.expect(try server.registerWsConnection(peer_fds[0]));
    try std.testing.expectEqual(@as(usize, 2), server.registeredWsCount());
    try std.testing.expectEqual(@as(u64, 0), server.ws_woken_connections.load(.monotonic));

    server.stop();

    try std.testing.expectEqual(@as(u64, 2), server.ws_woken_connections.load(.monotonic));
    // The registered end of each pair is now at EOF — exactly what the fiber's
    // bare read gets, which is what makes it leave.
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try std.posix.read(fds[0], &buf));
    try std.testing.expectEqual(@as(usize, 0), try std.posix.read(peer_fds[0], &buf));
    // The pass shuts sockets down; it never drops entries. Removal is the owning
    // fiber's job (under the same lock, before it closes the fd), which is what
    // keeps a recorded fd from being recycled while the pass is using it.
    try std.testing.expectEqual(@as(usize, 2), server.registeredWsCount());

    // Deregistration is therefore what shrinks the set: the next pass wakes only
    // what is still registered.
    server.unregisterWsConnection(fds[0]);
    try std.testing.expectEqual(@as(usize, 1), server.registeredWsCount());
    server.stop();
    try std.testing.expectEqual(@as(u64, 3), server.ws_woken_connections.load(.monotonic));
}

// The interleaving the `running` check inside the lock exists for: a connection
// that upgrades *after* the wake pass has already run must not be served, or it
// would park in a read that nothing will ever wake.
test "a WebSocket registration after stop() is refused instead of parking" {
    const allocator = std.testing.allocator;
    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0 });
    defer server.deinit();

    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer for (fds) |fd| {
        _ = std.posix.system.close(fd);
    };

    // Up, then stopping: this is the interleaving a late upgrade can land in.
    server.running.store(true, .monotonic);
    server.stop();
    try std.testing.expect(!try server.registerWsConnection(fds[0]));
    // Refused means refused: nothing was recorded, so the caller's teardown is
    // the only place that fd is closed (the invariant that keeps the wake pass
    // off recycled descriptors).
    try std.testing.expectEqual(@as(usize, 0), server.registeredWsCount());
    // Nothing to wake, so the counter stays put — the `false` above is really the
    // stopping flag, not an empty list happening to answer the same way.
    try std.testing.expectEqual(@as(u64, 0), server.ws_woken_connections.load(.monotonic));
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
    /// Body budget handed to the parser (ms); 0 = unbounded. The old parser
    /// cleared the deadline at the blank line, which is the defect the body
    /// budget test pins.
    body_timeout_ms: u32 = 2000,

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
        probe.reader.setReadDeadline(2000);
        _ = std.posix.system.write(fds[1], payload.ptr, payload.len);
        return probe;
    }

    fn destroy(self: *ParserProbe) void {
        self.stream.close(std.testing.io);
        _ = std.posix.system.close(self.peer);
    }

    fn parse(self: *ParserProbe) !ParsedRequest {
        const first = try self.reader.readUntilDelimiterOrEof('\n') orelse return error.ClientClosed;
        return self.parser.parseAfterRequestLine(&self.reader, first, 1 * 1024 * 1024, .{}, 100, self.body_timeout_ms);
    }
};

// ── Fuzz: request line + header parser ──────────────────────────────────────
//
// `parseAfterRequestLine` is the parse surface every unauthenticated peer
// reaches, so it has to survive arbitrary bytes: any outcome — a
// `ParsedRequest` or a refusal error — is a pass, a crash or an out-of-bounds
// read is not. Driven over a socketpair because the parser reads
// incrementally from a `StreamReader`; the model is "peer sent its whole
// request, then half-closed", so a declared body longer than the bytes sent
// hits EOF (a refusal) instead of blocking the read.

fn fuzzParseRequest(_: void, smith: *std.testing.Smith) !void {
    var raw: [4096]u8 = undefined;
    smith.bytes(&raw);

    const fds = testSocketPair() orelse return error.SkipZigTest;
    const stream: std.Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
    // One write, then close the write end: 4 KiB always fits the socket buffer,
    // and the close is what turns "body shorter than Content-Length" from a
    // hang into a clean `IncompleteBody`.
    _ = std.posix.system.write(fds[1], &raw, raw.len);
    _ = std.posix.system.close(fds[1]);
    defer stream.close(std.testing.io);

    var reader: StreamReader = undefined;
    reader.setup(stream, std.testing.io);
    // Backstop for a parser path that waits on more bytes despite the half-close.
    reader.setReadDeadline(2000);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parser = RequestParser.init(a);
    const first_maybe = reader.readUntilDelimiterOrEof('\n') catch return;
    const first = first_maybe orelse return;
    var request = parser.parseAfterRequestLine(&reader, first, 16 * 1024, .{}, 100, 2000) catch return;
    request.deinit(a);
}

test "fuzz: request-line + header parser only errors or succeeds on arbitrary bytes" {
    // Valid requests on the success path, then the refusal shapes the audit
    // added (chunked TE, duplicate/garbage Content-Length, folded headers),
    // then bytes that aren't text at all.
    const corpus = [_][]const u8{
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
        "POST /a?x=1&y=%20 HTTP/1.1\r\nHost: y\r\nContent-Length: 3\r\n\r\nabc",
        "OPTIONS * HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello",
        "POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 1_0\r\n\r\nhello",
        "GET / HTTP/1.1\r\nHost: x\r\n folded: value\r\n\r\n",
        "GET / HTTP/1.1\r\nBrokenHeaderLine\r\n\r\n",
        "GET /",
        "\r\n\r\n",
        "\x00\x01\x02\xff\xfe\xfd",
    };
    try std.testing.fuzz({}, fuzzParseRequest, .{ .corpus = &corpus });
}

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
    reader.setReadDeadline(80);

    // Peer sends nothing: the deadline must cut the read instead of blocking.
    try std.testing.expectError(error.ReadFailed, reader.readUntilDelimiterOrEof('\n'));
    try std.testing.expect(reader.timed_out);
}

test "StreamReader header deadline leaves a prompt peer alone" {
    const fds = testSocketPair() orelse return error.SkipZigTest;
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    var reader: StreamReader = undefined;
    reader.setup(stream, std.testing.io);
    reader.setReadDeadline(2000);
    _ = std.posix.system.write(fds[1], "GET / HTTP/1.1\r\n", 16);

    const line = try reader.readUntilDelimiterOrEof('\n');
    try std.testing.expect(line != null);
    try std.testing.expect(std.mem.startsWith(u8, line.?, "GET / HTTP/1.1"));
    try std.testing.expect(!reader.timed_out);

    // The body phase gets its own budget (armed by the parser at the blank
    // line, which is where `setReadDeadline` is called again in connFiber);
    // `0` is what "unbounded upload" looks like, and the read still works.
    reader.setReadDeadline(0);
    _ = std.posix.system.write(fds[1], "BODY", 4);
    var body: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try reader.readAll(&body));
    try std.testing.expectEqualStrings("BODY", &body);
    try std.testing.expect(!reader.timed_out);
    try std.testing.expect(reader.deadline_ns == null);
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

test "stop() wakes a blocked accept without EBADF panic and unwinds cleanly" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0 });
    defer server.deinit();

    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    var joined = false;
    defer {
        // Failure path: never leave the accept thread blocked in `accept` —
        // a hung join would turn a red test into a timeout.
        if (!joined) {
            server.stop();
            th.join();
        }
    }

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

    // Let the accept loop actually park inside accept4(). (On this Darwin a
    // *blocked* accept wakes with ECONNABORTED — clean; the EBADF hazard is
    // the loop *starting* a fresh accept4 on a closed fd, which the churn
    // test below hammers.)
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(100), .real) catch {};

    server.stop();
    th.join();
    joined = true;

    // The woken loop must have unwound start() — including its
    // closeListener defer — by the time join returns.
    try std.testing.expect(server.listener == null);

    // And the port must be free again: a fresh listener binds the address.
    const addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
    var probe = try addr.listen(std.testing.io, .{ .reuse_address = true });
    probe.deinit(std.testing.io);

    // A second stop() must be harmless.
    server.stop();
}

/// Connect flood: keeps the accept backlog non-empty so the accept loop
/// keeps *returning from* accept4 and re-entering it (never parked in the
/// syscall) while stop() lands. Raw syscalls on purpose: a std.Io connect
/// surfaces teardown races (EINVAL on a closing listener) through
/// unexpectedErrno stack dumps, and here those races are the *expected*
/// background noise of a stopping server.
fn stopChurnLoop(port: u16, stop: *std.atomic.Value(bool)) void {
    var sa: std.posix.sockaddr.in = .{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
        .zero = std.mem.zeroes([8]u8),
    };
    while (!stop.load(.monotonic)) {
        const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (fd < 0) continue;
        _ = std.c.connect(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in));
        _ = std.c.close(fd);
    }
}

test "stop() during accept churn never hits the closed-fd EBADF race" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // Regression: pre-fix stop() closed the listener fd from the stopping
    // thread. When the accept loop is spinning (backlog non-empty, accept4
    // returning and re-entering), a fresh accept4 can start on the
    // just-closed fd → EBADF → std.Io.Threaded errnoBug → Debug panic the
    // Server layer cannot catch. macOS only wakes a *parked* accept cleanly
    // (ECONNABORTED), so the churn window needs load to surface — hammer it.
    var cycle: usize = 0;
    while (cycle < 15) : (cycle += 1) {
        var server = Server.initWithConfig(std.testing.io, allocator, .{
            .port = 0,
            .header_timeout_ms = 200,
        });
        defer server.deinit();

        const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
            fn run(s: *Server) void {
                s.start() catch {};
            }
        }.run, .{&server});
        var joined = false;
        defer if (!joined) {
            server.stop();
            th.join();
        };

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

        var stop_churn = std.atomic.Value(bool).init(false);
        var churns: [8]?std.Thread = undefined;
        for (&churns) |*c| {
            c.* = try std.Thread.spawn(.{}, stopChurnLoop, .{ port, &stop_churn });
        }
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(50), .real) catch {};
        server.stop();
        stop_churn.store(true, .monotonic);
        for (churns) |c| {
            if (c) |t| t.join();
        }
        th.join();
        joined = true;

        try std.testing.expect(server.listener == null);
    }
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
    try env.put("HTTP_RESPONSE_WRITE_TIMEOUT_MS", "1500");

    var server = try Server.fromEnv(std.testing.io, allocator, &env);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 18080), server.port);
    try std.testing.expectEqual(@as(usize, 4096), server.max_connections);
    try std.testing.expectEqual(@as(u32, 2500), server.header_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1024), server.max_body_size);
    try std.testing.expectEqual(@as(u32, 1500), server.response_write_timeout_ms);
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

// ── response framing + body budget ─────────────────────────────────────────
//
// Response-path shapes that used to fail *silently*: a response dropped when a
// header value outgrew a fixed 256-byte scratch line, a header value that could
// rewrite the response, a body read that reported a transport failure as "0
// bytes", and a body phase with no deadline at all. Asserted on the wire (or on
// the state the wire is built from), because "the client sees it" is the
// property that matters.

/// Read what the peer has sent, stopping at a short idle gap. Every writer
/// here is done before the read starts, so "nothing more arrived" means "that
/// was all". `first_timeout_ms` bounds the wait for the first byte.
fn readPeer(fd: std.posix.socket_t, buf: []u8, first_timeout_ms: i32) ![]const u8 {
    var got: usize = 0;
    while (got < buf.len) {
        var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = try std.posix.poll(&pfds, if (got == 0) first_timeout_ms else 50);
        if (ready <= 0) break;
        const n = try std.posix.read(fd, buf[got..]);
        if (n == 0) break;
        got += n;
    }
    return buf[0..got];
}

test "long response header values are written, not dropped" {
    const allocator = std.testing.allocator;
    const fds = testSocketPair() orelse return error.SkipZigTest;
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    // The CORS middleware echoes the request `Origin` back (Middleware.zig), and
    // a `*.example.com` allow-list entry matches any prefix length — so a peer
    // picks the length of this value. 300 bytes is past the old `[256]u8`
    // scratch line, whose `error.NoSpaceLeft` connFiber logged and dropped:
    // the client got an empty socket instead of a response.
    const origin = try allocator.alloc(u8, 300);
    defer allocator.free(origin);
    @memset(origin, 'a');

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("Access-Control-Allow-Origin", origin);

    try writeResponse(stream, 200, headers, "{}", true, 0);

    var buf: [1024]u8 = undefined;
    const response = try readPeer(fds[1], &buf, 2000);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, response, origin) != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Content-Length: 2\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, response, "\r\n\r\n{}"));
}

test "response header values have an explicit ceiling, reported as an error" {
    const allocator = std.testing.allocator;
    const fds = testSocketPair() orelse return error.SkipZigTest;
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    const big = try allocator.alloc(u8, max_response_header_value_bytes + 1);
    defer allocator.free(big);
    @memset(big, 'a');

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("X-Big", big);

    // No fixed write buffer exists anymore, so the ceiling has to be explicit
    // and named — not "NoSpaceLeft from a scratch buffer nobody can see".
    try std.testing.expectError(error.HeaderTooLarge, writeResponse(stream, 200, headers, "{}", true, 0));
}

test "setHeader refuses a CR/LF/NUL value and a non-token name" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/x");
    defer ctx.deinit();

    // Query and form values arrive *percent-decoded*, so `%0d%0a` is a real
    // CRLF by the time a handler sees it: echoing one into a header is response
    // splitting. The request side has refused these from the start
    // (`splitHeaderLine`), the response side has to as well.
    try std.testing.expectError(error.InvalidHeader, ctx.setHeader("X-Echo", "a\r\nX-Evil: 1"));
    try std.testing.expectError(error.InvalidHeader, ctx.setHeader("X-Echo", "a\nb"));
    try std.testing.expectError(error.InvalidHeader, ctx.setHeader("X-Echo", "a\x00b"));
    try std.testing.expectError(error.InvalidHeader, ctx.setHeader("X Echo", "v"));
    try std.testing.expectError(error.InvalidHeader, ctx.setHeader("", "v"));

    const big = try allocator.alloc(u8, max_response_header_value_bytes + 1);
    defer allocator.free(big);
    @memset(big, 'a');
    try std.testing.expectError(error.HeaderTooLarge, ctx.setHeader("X-Big", big));

    // A legal field still goes through and is stored.
    try ctx.setHeader("X-Ok", "fine");
    try std.testing.expectEqualStrings("fine", ctx.response_headers.get("X-Ok") orelse "<missing>");
}

test "readAll reports a read failure instead of zero bytes" {
    const fds = testSocketPair() orelse return error.SkipZigTest;
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    var reader: StreamReader = undefined;
    reader.setup(stream, std.testing.io);
    reader.setReadDeadline(80);

    // The peer says nothing and the deadline fires. Returning 0 here made the
    // caller answer `IncompleteBody`, which `connFiber` treats as "close and
    // say nothing" — a transport failure the client cannot tell from a crash.
    var body: [8]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, reader.readAll(&body));
    try std.testing.expect(reader.timed_out);
}

test "incomplete body is answered, not closed silently" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .header_timeout_ms = 2000,
    });
    defer server.deinit();
    var group = server.group("");
    try group.post("ping", struct {
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

    var client = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer client.close(std.testing.io);

    // `Content-Length: 10` and 3 bytes, then half-close: the body can never
    // arrive. Half-closing keeps this deterministic (no waiting on a timeout).
    const head = "POST /ping HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc";
    _ = std.posix.system.write(client.socket.handle, head.ptr, head.len);
    _ = std.c.shutdown(client.socket.handle, std.c.SHUT.WR);

    var buf: [512]u8 = undefined;
    const response = try readPeer(client.socket.handle, &buf, 3000);
    try std.testing.expect(response.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400"));
}

test "a stalled body is cut by its own budget, not parked forever" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The slow-POST shape: the peer announces 10 bytes, sends one, then goes
    // quiet while its connection keeps the slot. The header deadline is long
    // satisfied by then, so without a body budget the read parks forever.
    var probe = try ParserProbe.create(a, "POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nA") orelse return error.SkipZigTest;
    defer probe.destroy();
    probe.body_timeout_ms = 200;

    const Outcome = struct {
        done: std.atomic.Value(bool) = .init(false),
        err: ?anyerror = null,
        timed_out: bool = false,
    };
    var outcome = Outcome{};
    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(p: *ParserProbe, alloc: std.mem.Allocator, o: *Outcome) void {
            if (p.parse()) |request| {
                var r = request;
                r.deinit(alloc);
            } else |err| {
                o.err = err;
            }
            o.timed_out = p.reader.timed_out;
            o.done.store(true, .release);
        }
    }.run, .{ probe, a, &outcome });
    defer {
        // Release a parser that is still parked: shutting the peer's write end
        // turns the blocking read into EOF, so the join below cannot hang
        // whether the assertion passes or fails.
        _ = std.c.shutdown(probe.peer, std.c.SHUT.WR);
        th.join();
    }

    var waited_ms: u32 = 0;
    while (waited_ms < 2000 and !outcome.done.load(.acquire)) : (waited_ms += 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(outcome.done.load(.acquire));
    try std.testing.expectEqual(error.ReadFailed, outcome.err.?);
    try std.testing.expect(outcome.timed_out);
}

test "jsonStruct serializes straight into response_body" {
    const allocator = std.testing.allocator;
    var fa = std.testing.FailingAllocator.init(allocator, .{});
    var ctx = try Context.init(fa.allocator(), .GET, "/x");
    defer ctx.deinit();

    const blob = try allocator.alloc(u8, 4000);
    defer allocator.free(blob);
    @memset(blob, 'x');

    // Reserve the capacity the body needs first: with a single-copy path
    // serialization itself then allocates *nothing* — what is left is the
    // `Content-Type` dupes and the header map's first insertion, ~300 bytes
    // for a 4 KB response. The old `valueAlloc` + `appendSlice` round trip
    // allocated the body a second time on top of that.
    try ctx.response_body.ensureTotalCapacity(fa.allocator(), 8192);
    const before = fa.allocated_bytes;
    try ctx.jsonStruct(200, .{ .blob = blob });
    const grown = fa.allocated_bytes - before;
    try std.testing.expect(grown < blob.len);
    try std.testing.expect(ctx.response_body.items.len > 4000);
    try std.testing.expect(std.mem.startsWith(u8, ctx.response_body.items, "{\"blob\":\""));
}

test "a stalled body is answered with 408 once its budget is spent" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .header_timeout_ms = 2000,
        .body_timeout_ms = 200,
    });
    defer server.deinit();
    var group = server.group("");
    try group.post("ping", struct {
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

    var client = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer client.close(std.testing.io);

    // `Content-Length: 10`, one byte delivered, then silence: the slow-POST
    // shape that used to hold the connection (and its slot) for as long as the
    // peer liked, because the header deadline was already satisfied.
    const head = "POST /ping HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nA";
    _ = std.posix.system.write(client.socket.handle, head.ptr, head.len);

    var buf: [512]u8 = undefined;
    const response = try readPeer(client.socket.handle, &buf, 3000);
    try std.testing.expect(response.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 408"));
}

test "a 300-byte Origin is echoed in a response that reaches the client" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .header_timeout_ms = 2000,
    });
    defer server.deinit();
    // A `*.example.com` suffix entry matches any prefix length, so the *client*
    // picks how long the echoed `Access-Control-Allow-Origin` becomes.
    try server.addMiddleware(@import("Middleware.zig").cors(.{ .allow_origins = &.{"*.example.com"} }));
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

    var client = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer client.close(std.testing.io);

    const origin = try allocator.alloc(u8, 320);
    defer allocator.free(origin);
    @memset(origin, 'a');
    const request = try std.fmt.allocPrint(allocator, "GET /ping HTTP/1.1\r\nHost: x\r\nOrigin: https://{s}.example.com\r\nConnection: close\r\n\r\n", .{origin});
    defer allocator.free(request);
    _ = std.posix.system.write(client.socket.handle, request.ptr, request.len);

    var buf: [2048]u8 = undefined;
    const response = try readPeer(client.socket.handle, &buf, 3000);
    // Same bytes as the `writeResponse` unit test above, but through the chain
    // the finding described: middleware echo → response header → wire.
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, response, origin) != null);
}

test "a response header the server refuses is answered with 500, not dropped" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .header_timeout_ms = 2000,
    });
    defer server.deinit();
    var group = server.group("");
    try group.get("bad-header", struct {
        fn h(ctx: *Context) anyerror!void {
            // Written straight into the map: `setHeader` refuses this (and a
            // handler should use it), so this test reaches the wire-level
            // guard — and is the shape a middleware writing the map itself has.
            const big = try ctx.allocator.alloc(u8, max_response_header_value_bytes + 1);
            @memset(big, 'x');
            try ctx.response_headers.put(try ctx.allocator.dupe(u8, "X-Big"), big);
            try ctx.jsonStruct(200, .{ .ok = true });
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

    var client = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer client.close(std.testing.io);

    const request = "GET /bad-header HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    _ = std.posix.system.write(client.socket.handle, request.ptr, request.len);

    var buf: [512]u8 = undefined;
    const response = try readPeer(client.socket.handle, &buf, 3000);
    // Nothing partial: the refusal happens before the status line is written,
    // so the 500 is a complete response rather than a truncated 200.
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 500"));
}

// --- H2 adapter parity (h2c over loopback) ---
//
// `connFiber` performs a fixed sequence between receiving a request and routing
// it: split the query off the request target, arm the budget and `io`, take
// `.body`, copy headers, run `path_rewriter`, parse a urlencoded form body,
// match. `http2RouterSiteHandler` is the H2 twin of that sequence, and every
// step it skips is a difference the application can see — handler code reads
// `ctx.path` / `ctx.requestParam` the same way on both protocols. These tests
// drive a real h2c exchange, so what is asserted is the bytes the client gets,
// not the adapter's internals.

/// Client side of one prior-knowledge h2c exchange with a running `Server`:
/// connection preface, then `frames`, then a half-close so the connection
/// fiber's frame loop sees EOF instead of parking in a read.
fn h2SendToServer(port: u16, frames: []const u8, out: []u8) !usize {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer stream.close(std.testing.io);

    try @import("../core/sockread.zig").writeFull(stream, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    try @import("../core/sockread.zig").writeFull(stream, frames);
    _ = std.c.shutdown(stream.socket.handle, std.c.SHUT.WR);

    var total: usize = 0;
    while (total < out.len) {
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 3000) catch break;
        if (ready == 0) break;
        const n = std.posix.read(stream.socket.handle, out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// One HPACK request block: the four pseudo-headers plus `extra`.
fn h2RequestBlock(
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    extra: []const Hpack.Header,
) ![]u8 {
    var headers = std.ArrayList(Hpack.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = ":method", .value = method });
    try headers.append(allocator, .{ .name = ":path", .value = path });
    try headers.append(allocator, .{ .name = ":scheme", .value = "http" });
    try headers.append(allocator, .{ .name = ":authority", .value = "localhost" });
    try headers.appendSlice(allocator, extra);
    const enc = Hpack.Encoder.init(allocator);
    return enc.encodeSmart(headers.items);
}

fn h2FindFrame(wire: []const u8, typ: Http2.FrameType, stream_id: u31) ?Http2.Frame {
    var off: usize = 0;
    while (off + 9 <= wire.len) {
        const frame = Http2.decodeFrame(wire[off..]) catch return null;
        if (frame.header.typ == typ and (stream_id == 0 or frame.header.stream_id == stream_id)) return frame;
        off += 9 + @as(usize, frame.header.length);
    }
    return null;
}

fn h2FirstHeaderValue(headers: []const Hpack.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, name)) return h.value;
    }
    return null;
}

/// POST one urlencoded body over h2c and return the reply's DATA payload (a
/// subslice of `out`, which the caller owns).
fn h2PostForm(
    allocator: std.mem.Allocator,
    port: u16,
    route: []const u8,
    body: []const u8,
    out: []u8,
) ![]const u8 {
    const reply = try h2PostFormReply(allocator, port, route, body, out);
    const frame = h2FindFrame(reply, .data, 1) orelse return error.NoDataFrameInReply;
    return frame.payload;
}

/// The same exchange, but the whole reply: a refusal carries its answer in the
/// HEADERS frame (`:status`) and may carry a body the body-only helper above
/// cannot tell apart from a success's.
fn h2PostFormReply(
    allocator: std.mem.Allocator,
    port: u16,
    route: []const u8,
    body: []const u8,
    out: []u8,
) ![]const u8 {
    const ctype = [_]Hpack.Header{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};
    const block = try h2RequestBlock(allocator, "POST", route, &ctype);
    defer allocator.free(block);

    var script = std.ArrayList(u8).empty;
    defer script.deinit(allocator);
    const head = try Http2.encodeHeaders(allocator, 1, block, false, true);
    defer allocator.free(head);
    try script.appendSlice(allocator, head);
    const data = try Http2.encodeData(allocator, 1, body, true);
    defer allocator.free(data);
    try script.appendSlice(allocator, data);

    const n = try h2SendToServer(port, script.items, out);
    return out[0..n];
}

/// The `:status` of a reply's stream-1 HEADERS frame, as a number.
fn h2ReplyStatus(allocator: std.mem.Allocator, reply: []const u8) !u16 {
    const hframe = h2FindFrame(reply, .headers, 1) orelse return error.NoHeadersFrameInReply;
    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    const hdrs = try dec.decode(hframe.payload);
    defer Hpack.freeHeaders(allocator, hdrs);
    const raw = h2FirstHeaderValue(hdrs, ":status") orelse return error.NoStatusHeaderInReply;
    return std.fmt.parseInt(u16, raw, 10);
}

/// A real `Server` listening on a loopback port on its own thread.
///
/// `stop()` **before** `join()`: the accept loop only unwinds once `running` is
/// cleared, and `start()`'s `conn_group.await` then waits for its fibers.
const TestServer = struct {
    thread: std.Thread,
    port: u16,

    /// Returns once the accept loop has published the port it bound.
    fn start(server: *Server) !TestServer {
        const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
            fn run(s: *Server) void {
                s.start() catch |err| std.log.warn("[h2 parity] test accept loop ended: {s}", .{@errorName(err)});
            }
        }.run, .{server});

        var port: u16 = 0;
        var tries: usize = 0;
        while (tries < 200) : (tries += 1) {
            if (server.listener) |*l| {
                port = l.socket.address.getPort();
                break;
            }
            std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch |err|
                std.log.debug("[h2 parity] poll sleep failed: {s}", .{@errorName(err)});
        }
        if (port == 0) {
            server.stop();
            th.join();
            return error.ServerNeverListened;
        }
        return .{ .thread = th, .port = port };
    }

    /// `stop()` before `join()`: the accept loop only unwinds once `running` is
    /// cleared, and `start()`'s `conn_group.await` then waits for the fibers.
    fn stop(self: *TestServer, server: *Server) void {
        server.stop();
        self.thread.join();
    }
};

/// The name the h2 parity tests were written against.
const H2TestServer = TestServer;

test "h2 adapter parity: a urlencoded form body is parsed like H1" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2-form" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.post("h2form", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, ctx.requestParam("name") orelse "MISSING");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    // Percent-encoded value: the point is that the *same* parser ran
    // (`parseFormBody` decodes `+` and `%XX`), not just that some bytes were
    // buffered.
    var out: [8192]u8 = undefined;
    const payload = try h2PostForm(allocator, running.port, "/h2form", "name=%E5%BC%A0%E4%B8%89&role=admin", &out);
    try std.testing.expectEqualStrings("张三", payload);
}

test "h2 adapter parity: the form parser takes Server.Config.max_params too" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // The limit is the field the H1 parser is handed; a body over it must be
    // refused on H2 as well, or the H2 path is the cheap way past the DoS bound.
    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .max_params = 2, .name = "h2-form-limit" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.post("h2formlimit", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, ctx.requestParam("a") orelse "MISSING");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    // Two bodies through the same route: one within the limit is parsed, the
    // one over it is refused with the same 400 the query string's limit
    // produces — so "the limit is applied" is distinguishable from "no body is
    // ever parsed", and a client that sent too many fields is told so instead
    // of being handed a handler that sees no fields at all.
    var out_a: [8192]u8 = undefined;
    const within_limit = try h2PostFormReply(allocator, running.port, "/h2formlimit", "a=1&b=2", &out_a);
    try std.testing.expectEqual(@as(u16, 200), try h2ReplyStatus(allocator, within_limit));
    const data_a = h2FindFrame(within_limit, .data, 1) orelse return error.NoDataFrameInReply;
    try std.testing.expectEqualStrings("1", data_a.payload);

    var out_b: [8192]u8 = undefined;
    const over_limit = try h2PostFormReply(allocator, running.port, "/h2formlimit", "a=1&b=2&c=3", &out_b);
    try std.testing.expectEqual(@as(u16, 400), try h2ReplyStatus(allocator, over_limit));
    const data_b = h2FindFrame(over_limit, .data, 1) orelse return error.NoDataFrameInReply;
    try std.testing.expectEqualStrings("Bad Request", data_b.payload);
}

// ── A urlencoded body that fails to parse: two causes, two answers ───────
//
// `parseFormBody` fails for two unrelated reasons, and both request paths used
// to flatten them into one with `catch null` — "there was no form" — and then
// answer 200. A handler reading `ctx.formValue` could not tell "the client sent
// no fields" from "the server could not parse the ones it sent", and a body
// over `Config.max_params` was never reported to the client at all.
//
// The two halves are covered where each one is reachable. The field flood goes
// through real sockets (below and in the H2 parity test above): a body over
// `max_params` needs nothing but a small limit. The allocation half cannot be
// driven that way — the parse allocates on the *request arena*, which is carved
// out of the server's allocator in whole chunks, so a size-trapping server
// allocator never sees one of the parse's own requests (measured: it fires zero
// times for a request whose form parse definitely allocated). The seam that
// does reach them is the parser itself, and the step's classification is what
// turns its two errors into the two statuses.

test "the urlencoded-body step answers an allocation failure with 500, and never with a form" {
    const allocator = std.testing.allocator;
    const ctype = "application/x-www-form-urlencoded";
    const body = "a=1&roles%5B1%5D=8&note=a+b";

    // Baseline: with memory to spare the body parses, so the assertions below
    // are about failures and not about a step that never parsed anything.
    switch (parseUrlencodedForm(allocator, ctype, body, 1000)) {
        .parsed => |form| {
            var parsed = form;
            defer parsed.deinit();
            try std.testing.expectEqualStrings("1", parsed.get("a").?);
            try std.testing.expectEqualStrings("a b", parsed.get("note").?);
            try std.testing.expectEqualStrings("8", parsed.getPath("roles.1").?);
        },
        .absent, .refused => return error.TestUnexpectedResult,
    }

    // Refusing the *first* allocation the parse makes (the first key's decode)
    // is the injection that leaves nothing half-built behind, so what comes
    // back is the step's refusal and nothing else.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parseFormBody(failing.allocator(), body, 1000));
    try std.testing.expect(failing.has_induced_failure);
    var failing_query = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var query_params = Params.init(failing_query.allocator());
    defer query_params.deinit();
    try std.testing.expectError(error.OutOfMemory, parseQueryInto(&query_params, "a=1&b=2", failing_query.allocator(), 1000));
    try std.testing.expect(failing_query.has_induced_failure);

    // The other failure of the same parse is the client's field count, and it
    // is a different error: the two callers classify on exactly that.
    try std.testing.expectError(error.TooManyParams, parseFormBody(allocator, body, 1));
}

test "a parse failure is answered by its kind: 400 for the field flood, 500 for the server's own" {
    // The H1 request boundary classifies with `requestParseRefusal`, the H2
    // adapter and both urlencoded-body call sites with `paramParseFailureStatus`
    // — and the two have to agree, or the same request gets one answer on each
    // protocol.
    try std.testing.expectEqual(@as(u16, 400), paramParseFailureStatus(error.TooManyParams));
    try std.testing.expectEqual(@as(u16, 500), paramParseFailureStatus(error.OutOfMemory));
    try std.testing.expectEqual(@as(u16, 400), requestParseRefusal(error.TooManyParams).status);
    try std.testing.expectEqual(@as(u16, 500), requestParseRefusal(error.OutOfMemory).status);
    try std.testing.expectEqualStrings("Internal Server Error", requestParseRefusal(error.OutOfMemory).message);

    // The rest of the request boundary keeps the statuses it had.
    try std.testing.expectEqual(@as(u16, 413), requestParseRefusal(error.BodyTooLarge).status);
    try std.testing.expectEqual(@as(u16, 431), requestParseRefusal(error.TooManyHeaders).status);
    try std.testing.expectEqual(@as(u16, 501), requestParseRefusal(error.InvalidMethod).status);
    try std.testing.expectEqual(@as(u16, 400), requestParseRefusal(error.InvalidRequest).status);
    try std.testing.expectEqual(@as(u16, 400), requestParseRefusal(error.IncompleteBody).status);
}

test "a request the server could not allocate room for is answered 500, not 400" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // The parser allocates the request line on the request arena, and the arena
    // asks for it in one chunk-sized request. Refusing chunk-sized requests
    // therefore fails the *request-line* allocation — an allocation failure
    // inside the parse, which is this server's fault — while the small
    // allocations the refusal itself needs (`writeErrorResponse`'s
    // `Content-Type`) still go through, so the client gets an answer and not a
    // vanished socket. The same failure used to fall into the parse boundary's
    // catch-all and come back as 400, a status that blames the client for a
    // request it sent correctly.
    var trap = LargeAllocTrap{ .child = allocator, .min_size = 4096 };

    var server = Server.initWithConfig(std.testing.io, trap.allocator(), .{ .port = 0, .name = "h1-parse-oom" });
    defer server.deinit();

    var group = server.group("");
    try group.get("h1parseoom", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, "MISSING");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    // A target long enough that the request line is a chunk-sized allocation.
    const filler: [5000]u8 = @splat('a');
    const request = "GET /h1parseoom?q=" ++ filler ++ " HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";

    var out: [4096]u8 = undefined;
    const response = try h1RawExchange(running.port, request, &out);

    try std.testing.expect(trap.trapped.load(.monotonic) >= 1);
    try std.testing.expectEqualStrings("HTTP/1.1 500 Internal Server Error", h1StatusLine(response));
}

test "a urlencoded body over max_params is refused with 400, not served as an empty form" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .max_params = 2, .name = "h1-form-limit" });
    defer server.deinit();

    var group = server.group("");
    try group.post("h1formlimit", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, ctx.requestParam("a") orelse "MISSING");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const ctype = "Content-Type: application/x-www-form-urlencoded\r\n";
    var out: [4096]u8 = undefined;

    // Within the limit: parsed, so "refused" is distinguishable from "no form
    // is ever parsed on this route".
    const ok = try h1RawExchange(running.port, "POST /h1formlimit HTTP/1.1\r\nHost: x\r\n" ++ ctype ++ "Content-Length: 7\r\nConnection: close\r\n\r\na=1&b=2", &out);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", h1StatusLine(ok));
    try std.testing.expectEqualStrings("1", h1Body(ok));

    // Over it: three occurrences against a limit of two is the client's fault,
    // and the answer is the 400 the query string's own limit already produces.
    const over = try h1RawExchange(running.port, "POST /h1formlimit HTTP/1.1\r\nHost: x\r\n" ++ ctype ++ "Content-Length: 11\r\nConnection: close\r\n\r\na=1&b=2&c=3", &out);
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request", h1StatusLine(over));
    try std.testing.expect(std.mem.indexOf(u8, over, "MISSING") == null);
}

test "h2 adapter parity: the path rewriter runs before routing" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2-rewrite" });
    defer server.deinit();
    server.setHttp2Enabled(true);
    // The shape an app uses to strip an API-version prefix.
    server.setPathRewriter(struct {
        fn rewrite(ctx: *Context) void {
            if (std.mem.startsWith(u8, ctx.path, "/v1/")) {
                ctx.path = std.fmt.allocPrint(ctx.allocator, "/{s}", .{ctx.path["/v1/".len..]}) catch return;
            }
        }
    }.rewrite);

    var group = server.group("");
    try group.get("ping", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, "pong");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const block = try h2RequestBlock(allocator, "GET", "/v1/ping", &.{});
    defer allocator.free(block);
    const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(head);

    var out: [8192]u8 = undefined;
    const n = try h2SendToServer(running.port, head, &out);
    const reply = out[0..n];

    const hframe = h2FindFrame(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    const hdrs = try dec.decode(hframe.payload);
    defer Hpack.freeHeaders(allocator, hdrs);
    try std.testing.expectEqualStrings("200", h2FirstHeaderValue(hdrs, ":status") orelse return error.TestUnexpectedResultWithMessage);

    const body = h2FindFrame(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("pong", body.payload);
}

test "h2 adapter parity: the query string is split off the target and parsed" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2-query" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2query", struct {
        fn h(ctx: *Context) anyerror!void {
            // `ctx.param` is the route placeholder; the query is the fallback
            // `requestParam` reaches for, and it has to be parsed to be there.
            try ctx.text(200, ctx.requestParam("b") orelse "MISSING");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const block = try h2RequestBlock(allocator, "GET", "/h2query?a=1&b=%E5%BC%A0%E4%B8%89", &.{});
    defer allocator.free(block);
    const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(head);

    var out: [8192]u8 = undefined;
    const n = try h2SendToServer(running.port, head, &out);
    const reply = out[0..n];

    // A 200 also proves the target was matched as `/h2query`: the router sees
    // `ctx.path`, not the whole `:path` with the query still attached.
    const hframe = h2FindFrame(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    const hdrs = try dec.decode(hframe.payload);
    defer Hpack.freeHeaders(allocator, hdrs);
    try std.testing.expectEqualStrings("200", h2FirstHeaderValue(hdrs, ":status") orelse return error.TestUnexpectedResultWithMessage);

    const body = h2FindFrame(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("张三", body.payload);
}

test "h2 adapter parity: the auth rate limiter answers 429 through the response channel" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2-ratelimit" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    // max_attempts 1 per 60s: the second request is refused, which is the path
    // that used to write to `ctx.stream` — null on this adapter, so it took the
    // process down instead of answering. The limiter lives as long as the
    // middleware does (it rides along as `user_data`; nothing frees it), so it
    // gets an arena the test tears down wholesale rather than the leak-checking
    // `std.testing.allocator`.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const mw = try @import("../security/SecurityModule.zig").authRateLimitMiddleware(arena.allocator(), 1, 60);
    try server.addMiddleware(mw);

    var group = server.group("");
    try group.post("h2login", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, "ok");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const block = try h2RequestBlock(allocator, "POST", "/h2login", &.{});
    defer allocator.free(block);
    const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(head);

    {
        var out: [8192]u8 = undefined;
        const n = try h2SendToServer(running.port, head, &out);
        const reply = out[0..n];
        const hframe = h2FindFrame(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
        var dec = Hpack.Decoder.init(allocator);
        defer dec.deinit();
        const hdrs = try dec.decode(hframe.payload);
        defer Hpack.freeHeaders(allocator, hdrs);
        try std.testing.expectEqualStrings("200", h2FirstHeaderValue(hdrs, ":status") orelse return error.TestUnexpectedResultWithMessage);
    }

    {
        // A fresh connection, so the 429 is the limiter's answer and not
        // stream state from the request above.
        var out: [8192]u8 = undefined;
        const n = try h2SendToServer(running.port, head, &out);
        const reply = out[0..n];

        const hframe = h2FindFrame(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
        var dec = Hpack.Decoder.init(allocator);
        defer dec.deinit();
        const hdrs = try dec.decode(hframe.payload);
        defer Hpack.freeHeaders(allocator, hdrs);
        try std.testing.expectEqualStrings("429", h2FirstHeaderValue(hdrs, ":status") orelse return error.TestUnexpectedResultWithMessage);

        // The limiter's `Retry-After` is the header a client backs off on, and
        // it is written into `ctx.response_headers` exactly like `content-type`
        // — the one response field this adapter used to carry.
        try std.testing.expectEqualStrings("60", h2FirstHeaderValue(hdrs, "retry-after") orelse return error.RetryAfterMissingFromH2Response);

        // ...and a body, delivered as an ordinary DATA frame: the refusal is a
        // response, not a dropped connection or a process abort.
        const body = h2FindFrame(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
        try std.testing.expect(std.mem.indexOf(u8, body.payload, "Too many requests") != null);
    }
}

/// Comma-joined response field names, sorted, so comparing the *set* of fields
/// a reply carried does not depend on hash-map iteration order.
fn h2FieldNamesSorted(allocator: std.mem.Allocator, headers: []const Hpack.Header) ![]u8 {
    const names = try allocator.alloc([]const u8, headers.len);
    defer allocator.free(names);
    for (headers, 0..) |h, i| names[i] = h.name;
    std.mem.sort([]const u8, names, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return std.mem.join(allocator, ",", names);
}

test "h2 adapter parity: every response header the handler set reaches the wire" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2-resp-headers" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.post("h2headers", struct {
        fn h(ctx: *Context) anyerror!void {
            // The shapes an app loses when only `content-type` travels: a
            // session cookie, a back-off hint, a redirect target, an app
            // header. `writeResponse` writes the whole map on H1, so the same
            // handler gets all four onto an H1 wire.
            try ctx.setHeader("Set-Cookie", "sid=abc123; Path=/; HttpOnly");
            try ctx.setHeader("Retry-After", "60");
            try ctx.setHeader("Location", "/next");
            try ctx.setHeader("X-App", "v1");
            // Connection-specific. H2 forbids these in a response (RFC 9113
            // §8.2.2) — the requirement is to filter it, not to forward it,
            // and not to lose the rest of the response over it either.
            try ctx.setHeader("Connection", "keep-alive");
            try ctx.text(429, "slow down");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const block = try h2RequestBlock(allocator, "POST", "/h2headers", &.{});
    defer allocator.free(block);
    const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(head);

    var out: [8192]u8 = undefined;
    const n = try h2SendToServer(running.port, head, &out);
    const reply = out[0..n];

    const hframe = h2FindFrame(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    const hdrs = try dec.decode(hframe.payload);
    defer Hpack.freeHeaders(allocator, hdrs);

    // One assertion carries the whole field-name set, so a miss names the
    // fields that did arrive instead of "expected true, found false". No
    // `connection` here: it is the field h2 forbids.
    const names = try h2FieldNamesSorted(allocator, hdrs);
    defer allocator.free(names);
    try std.testing.expectEqualStrings(
        ":status,content-type,location,retry-after,set-cookie,x-app",
        names,
    );

    // …and the values, so this is not just "some field with that name".
    try std.testing.expectEqualStrings("429", h2FirstHeaderValue(hdrs, ":status") orelse return error.NoStatusField);
    try std.testing.expectEqualStrings("text/plain", h2FirstHeaderValue(hdrs, "content-type") orelse return error.NoContentTypeField);
    try std.testing.expectEqualStrings("sid=abc123; Path=/; HttpOnly", h2FirstHeaderValue(hdrs, "set-cookie") orelse return error.NoSetCookieField);
    try std.testing.expectEqualStrings("60", h2FirstHeaderValue(hdrs, "retry-after") orelse return error.NoRetryAfterField);
    try std.testing.expectEqualStrings("/next", h2FirstHeaderValue(hdrs, "location") orelse return error.NoLocationField);
    try std.testing.expectEqualStrings("v1", h2FirstHeaderValue(hdrs, "x-app") orelse return error.NoXAppField);
    try std.testing.expect(h2FirstHeaderValue(hdrs, "connection") == null);

    // H2 field names are lowercase on the wire (RFC 9113 §8.2.1) and a peer
    // must treat `Set-Cookie` as malformed — the handler's spelling may not
    // reach the encoder.
    for (hdrs) |h| {
        for (h.name) |c| try std.testing.expectEqual(std.ascii.toLower(c), c);
    }

    const body = h2FindFrame(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("slow down", body.payload);
}

test "h2 adapter parity: a response field past Config.header_limits is dropped, not framed unsendably" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // RFC 9113 §6.5.2 accounting (name + value + 32 per field): the request's
    // four pseudo-headers cost 185, the response's `:status` + `content-type`
    // 96, so the 400-byte extra below cannot fit in what the peer advertised.
    var server = Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .name = "h2-resp-budget",
        .header_limits = .{ .max_total_bytes = 250 },
    });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.post("h2budget", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.setHeader("X-Small", "1");
            const big = try ctx.allocator.alloc(u8, 400);
            @memset(big, 'x');
            try ctx.response_headers.put(try ctx.allocator.dupe(u8, "X-Big"), big);
            try ctx.text(200, "ok");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const block = try h2RequestBlock(allocator, "POST", "/h2budget", &.{});
    defer allocator.free(block);
    const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(head);

    var out: [8192]u8 = undefined;
    const n = try h2SendToServer(running.port, head, &out);
    const reply = out[0..n];

    // A field that does not fit costs that field, not the response: the status,
    // the content-type and the body are all still there, and the stream was not
    // reset.
    const hframe = h2FindFrame(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    const hdrs = try dec.decode(hframe.payload);
    defer Hpack.freeHeaders(allocator, hdrs);
    try std.testing.expectEqualStrings("200", h2FirstHeaderValue(hdrs, ":status") orelse return error.NoStatusField);
    try std.testing.expectEqualStrings("text/plain", h2FirstHeaderValue(hdrs, "content-type") orelse return error.NoContentTypeField);
    try std.testing.expect(h2FirstHeaderValue(hdrs, "x-big") == null);
    try std.testing.expect(h2FindFrame(reply, .rst_stream, 1) == null);
    try std.testing.expect(h2FindFrame(reply, .goaway, 0) == null);

    const body = h2FindFrame(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("ok", body.payload);
}

// --- h2c upgrade (RFC 7540 §3.2 / RFC 9113 §3.2) over loopback ---
//
// `connFiber` answers `Connection: Upgrade, HTTP2-Settings` + `Upgrade: h2c`
// with a 101 and hands the socket to the H2 session. RFC 7540 §3.2: the request
// that carried the upgrade **is** stream 1, and it is implicitly half-closed
// from the client toward the server — the client sends no HEADERS frame for it.
// These tests drive that handshake on a real socket, so what is asserted is
// what a client gets after the 101. Without the seeding of stream 1 the client
// sees the protocol switch and then nothing at all: `curl --http2` hangs.

/// `HTTP2-Settings` value (RFC 7540 §3.2.1): the payload of a SETTINGS frame,
/// base64url, no padding. Encoded through the shared frame codec and then cut
/// back to the payload, so the header cannot drift from the wire format.
fn h2cSettingsValue(allocator: std.mem.Allocator, params: []const struct { u16, u32 }) ![]u8 {
    const frame = try Http2.encodeSettings(allocator, false, params);
    defer allocator.free(frame);
    const payload = frame[9..];
    const buf = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
    errdefer allocator.free(buf);
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(buf, payload);
    return buf[0..encoded.len];
}

/// Client side of one h2c upgrade against a running `Server`: the HTTP/1.1
/// request carrying the upgrade fields, then the client connection preface and
/// `frames`. Returns the whole reply — the 101 status line included — so a test
/// can assert both halves (`h2cWireAfter101` splits them).
///
/// Everything goes out in one segment: the server reads the preface only after
/// it has written the 101, and the bytes that arrived earlier sit in the
/// connection's own reader buffer — the case `serveAfterUpgrade` exists for.
/// The half-close lets the session's frame loop see EOF instead of parking.
fn h2cUpgradeToServer(
    port: u16,
    request_headers: []const u8,
    frames: []const u8,
    out: []u8,
) !usize {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer stream.close(std.testing.io);

    try sockread.writeFull(stream, request_headers);
    try sockread.writeFull(stream, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    try sockread.writeFull(stream, frames);
    _ = std.c.shutdown(stream.socket.handle, std.c.SHUT.WR);

    var total: usize = 0;
    while (total < out.len) {
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 3000) catch break;
        if (ready == 0) break;
        const n = std.posix.read(stream.socket.handle, out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// One h2c upgrade request block, upgrade fields included. `method` is the
/// request-line method — the upgrade is a connection property, not a `GET` one
/// (RFC 7540 §3.2), so the tests that carry a body or ask about `HEAD` send
/// theirs with the method they mean. `extra_lines` are complete header lines,
/// each terminated with CRLF (empty when there are none); `body` follows the
/// blank line.
fn h2cUpgradeRequest(
    allocator: std.mem.Allocator,
    method: []const u8,
    target: []const u8,
    settings_value: []const u8,
    extra_lines: []const u8,
    body: []const u8,
) ![]u8 {
    std.debug.assert(extra_lines.len == 0 or std.mem.endsWith(u8, extra_lines, "\r\n"));
    return std.fmt.allocPrint(
        allocator,
        "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade, HTTP2-Settings\r\n" ++
            "Upgrade: h2c\r\nHTTP2-Settings: {s}\r\n{s}\r\n{s}",
        .{ method, target, settings_value, extra_lines, body },
    );
}

/// The H2 half of an upgrade reply: everything after the 101's header block.
fn h2cWireAfter101(reply: []const u8) ![]const u8 {
    const end = std.mem.indexOf(u8, reply, "\r\n\r\n") orelse return error.NoUpgradeResponseHeaders;
    return reply[end + 4 ..];
}

/// Frames of `typ` on `stream_id` (any stream when 0) in a server reply.
fn h2CountFrames(wire: []const u8, typ: Http2.FrameType, stream_id: u31) usize {
    var count: usize = 0;
    var off: usize = 0;
    while (off + 9 <= wire.len) {
        const frame = Http2.decodeFrame(wire[off..]) catch return count;
        off += 9 + @as(usize, frame.header.length);
        if (frame.header.typ == typ and (stream_id == 0 or frame.header.stream_id == stream_id)) count += 1;
    }
    return count;
}

/// Concatenated DATA payloads for one stream, in wire order: the body a client
/// reassembles, however many frames the server split it into.
fn h2CollectData(allocator: std.mem.Allocator, wire: []const u8, stream_id: u31) ![]u8 {
    var body = std.ArrayList(u8).empty;
    errdefer body.deinit(allocator);
    var off: usize = 0;
    while (off + 9 <= wire.len) {
        const frame = Http2.decodeFrame(wire[off..]) catch break;
        off += 9 + @as(usize, frame.header.length);
        if (frame.header.typ != .data or frame.header.stream_id != stream_id) continue;
        try body.appendSlice(allocator, frame.payload);
    }
    return body.toOwnedSlice(allocator);
}

test "h2c upgrade: the request that carried the upgrade is answered as stream 1" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2c-upgrade" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2cup", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.jsonStruct(200, .{ .ok = true, .proto = "h2c" });
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const settings_value = try h2cSettingsValue(allocator, &.{.{ Http2.SettingsId.initial_window_size, 131072 }});
    defer allocator.free(settings_value);
    const request = try h2cUpgradeRequest(allocator, "GET", "/h2cup", settings_value, "", "");
    defer allocator.free(request);

    var out: [8192]u8 = undefined;
    // No HEADERS frame anywhere on this connection: the only request is the one
    // that carried the upgrade, so a stream-1 answer can come from nothing else.
    const n = try h2cUpgradeToServer(running.port, request, &.{}, &out);
    const reply = out[0..n];
    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 101"));

    const wire = try h2cWireAfter101(reply);
    const hframe = h2FindFrame(wire, .headers, 1) orelse return error.NoStream1ResponseAfterUpgrade;
    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    const hdrs = try dec.decode(hframe.payload);
    defer Hpack.freeHeaders(allocator, hdrs);
    try std.testing.expectEqualStrings("200", h2FirstHeaderValue(hdrs, ":status") orelse return error.NoStatusField);
    // The route's own content-type, not the loop's built-in 404 fallback: the
    // path in the HTTP/1.1 request line reached the router.
    try std.testing.expectEqualStrings("application/json", h2FirstHeaderValue(hdrs, "content-type") orelse return error.NoContentTypeField);

    const data = h2FindFrame(wire, .data, 1) orelse return error.NoStream1BodyAfterUpgrade;
    try std.testing.expectEqualStrings("{\"ok\":true,\"proto\":\"h2c\"}", data.payload);
    // The upgrade request was complete before the session started, so stream 1
    // is answered exactly once and closed (END_STREAM on the response's body).
    try std.testing.expect((data.header.flags & Http2.FrameFlags.end_stream) != 0);
    try std.testing.expect(h2FindFrame(wire, .goaway, 0) == null);
}

test "h2c upgrade: the request's query string and fields reach the handler" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2c-upgrade-query" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2cupq", struct {
        fn h(ctx: *Context) anyerror!void {
            const q = ctx.requestParam("b") orelse "MISSING";
            const f = ctx.header("x-tenant") orelse "NOFIELD";
            const out = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ q, f });
            try ctx.text(200, out);
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const settings_value = try h2cSettingsValue(allocator, &.{.{ Http2.SettingsId.initial_window_size, 131072 }});
    defer allocator.free(settings_value);
    // The whole request target goes in the request line, so the query reaches
    // `:path` intact (RFC 9113 §8.3.1) and the adapter splits it off; the
    // `x-tenant` field is the ordinary-field half of the same path.
    const request = try h2cUpgradeRequest(
        allocator,
        "GET",
        "/h2cupq?a=1&b=%E5%BC%A0%E4%B8%89",
        settings_value,
        "X-Tenant: acme\r\n",
        "",
    );
    defer allocator.free(request);

    var out: [8192]u8 = undefined;
    const n = try h2cUpgradeToServer(running.port, request, &.{}, &out);
    try std.testing.expect(std.mem.startsWith(u8, out[0..n], "HTTP/1.1 101"));
    const wire = try h2cWireAfter101(out[0..n]);

    const body = try h2CollectData(allocator, wire, 1);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("张三/acme", body);
}

test "h2c upgrade: the HTTP2-Settings payload is applied before the first response" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // 70000 bytes is past the 65535 a stream may send before the peer's
    // INITIAL_WINDOW_SIZE is known. The upgrade request advertises 131072 in
    // `HTTP2-Settings`, and this connection sends no SETTINGS frame of its own
    // — so the whole body can only arrive if that field was applied as the
    // peer's SETTINGS before stream 1 was answered (RFC 7540 §3.2.1). A session
    // that waits for a SETTINGS frame truncates the body to 65535 and stalls.
    const big_len: usize = 70000;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2c-upgrade-settings" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2cbig", struct {
        fn h(ctx: *Context) anyerror!void {
            const big = try ctx.allocator.alloc(u8, big_len);
            @memset(big, 'x');
            try ctx.text(200, big);
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const settings_value = try h2cSettingsValue(allocator, &.{.{ Http2.SettingsId.initial_window_size, 131072 }});
    defer allocator.free(settings_value);
    const request = try h2cUpgradeRequest(allocator, "GET", "/h2cbig", settings_value, "", "");
    defer allocator.free(request);

    // A reply larger than the default peer window, so it needs its own buffer.
    const out = try allocator.alloc(u8, big_len + 1024);
    defer allocator.free(out);
    const n = try h2cUpgradeToServer(running.port, request, &.{}, out);
    const wire = try h2cWireAfter101(out[0..n]);

    const body = try h2CollectData(allocator, wire, 1);
    defer allocator.free(body);
    try std.testing.expectEqual(big_len, body.len);
    for (body) |c| try std.testing.expectEqual(@as(u8, 'x'), c);
}

test "h2c upgrade: a HEADERS frame for stream 1 is refused, not dispatched twice" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2c-upgrade-dup" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2cupdup", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, "served once");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const settings_value = try h2cSettingsValue(allocator, &.{.{ Http2.SettingsId.initial_window_size, 131072 }});
    defer allocator.free(settings_value);
    const request = try h2cUpgradeRequest(allocator, "GET", "/h2cupdup", settings_value, "", "");
    defer allocator.free(request);

    // The client preface, the SETTINGS frame the RFC requires next (§3.2.2: the
    // same values as `HTTP2-Settings`), and then the mistake §3.2 makes
    // impossible for a correct client — the upgrade request again as HEADERS(1).
    // Stream 1 is half-closed (remote) from the start, so this must not be
    // served a second time.
    var script = std.ArrayList(u8).empty;
    defer script.deinit(allocator);
    const client_settings = try Http2.encodeSettings(allocator, false, &.{.{ Http2.SettingsId.initial_window_size, 131072 }});
    defer allocator.free(client_settings);
    try script.appendSlice(allocator, client_settings);
    const block = try h2RequestBlock(allocator, "GET", "/h2cupdup", &.{});
    defer allocator.free(block);
    const dup = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(dup);
    try script.appendSlice(allocator, dup);

    var out: [8192]u8 = undefined;
    const n = try h2cUpgradeToServer(running.port, request, script.items, &out);
    const wire = try h2cWireAfter101(out[0..n]);

    // Exactly one response HEADERS frame on stream 1: the answer seeded from the
    // upgrade. A second one is the double dispatch.
    try std.testing.expectEqual(@as(usize, 1), h2CountFrames(wire, .headers, 1));
    try std.testing.expectEqual(@as(usize, 1), h2CountFrames(wire, .data, 1));
    const rst = h2FindFrame(wire, .rst_stream, 1) orelse return error.NoStreamClosedForRepeatedHeaders;
    try std.testing.expectEqual(Http2.ErrorCode.STREAM_CLOSED, try Http2.decodeRstStream(rst.payload));
    // A stream error, not the connection: the session keeps running.
    try std.testing.expect(h2FindFrame(wire, .goaway, 0) == null);

    const body = try h2CollectData(allocator, wire, 1);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("served once", body);
}

test "h2c upgrade: an upgrade request body becomes stream 1's body" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2c-upgrade-body" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2cbody", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, ctx.body orelse "NOBODY");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const settings_value = try h2cSettingsValue(allocator, &.{.{ Http2.SettingsId.initial_window_size, 131072 }});
    defer allocator.free(settings_value);
    // RFC 7540 §3.2: a request with a body sends it *in full* as part of the
    // HTTP/1.1 request, before any HTTP/2 frame. The session therefore receives
    // the whole body with the request and must not wait for DATA frames that
    // will never come — stream 1 is half-closed (remote) from the first frame.
    const request = try h2cUpgradeRequest(
        allocator,
        "GET",
        "/h2cbody",
        settings_value,
        "Content-Length: 11\r\n",
        "hello world",
    );
    defer allocator.free(request);

    var out: [8192]u8 = undefined;
    const n = try h2cUpgradeToServer(running.port, request, &.{}, &out);
    try std.testing.expect(std.mem.startsWith(u8, out[0..n], "HTTP/1.1 101"));
    const wire = try h2cWireAfter101(out[0..n]);

    const body = try h2CollectData(allocator, wire, 1);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("hello world", body);
    const data = h2FindFrame(wire, .data, 1) orelse return error.NoStream1BodyAfterUpgrade;
    try std.testing.expect((data.header.flags & Http2.FrameFlags.end_stream) != 0);
}

test "h2c upgrade: a POST carrying a body is stream 1, and OPTIONS upgrades too" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2c-upgrade-post" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    // Neither RFC 7540 §3.2 nor RFC 9113 §3.2 names a method: the upgrade is a
    // connection property, and the request that carried it becomes stream 1
    // whatever it is. `POST` is the interesting one — the HTTP/1.1 request is
    // how a body rides onto the upgraded connection.
    try group.post("h2cpost", struct {
        fn h(ctx: *Context) anyerror!void {
            const body = ctx.body orelse "NOBODY";
            const out = try std.fmt.allocPrint(ctx.allocator, "{s}:{s}", .{ ctx.method.toString(), body });
            try ctx.text(200, out);
        }
    }.h, null);
    try group.options("h2copt", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, ctx.method.toString());
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const settings_value = try h2cSettingsValue(allocator, &.{.{ Http2.SettingsId.initial_window_size, 131072 }});
    defer allocator.free(settings_value);

    var out: [8192]u8 = undefined;
    {
        const request = try h2cUpgradeRequest(
            allocator,
            "POST",
            "/h2cpost",
            settings_value,
            "Content-Length: 11\r\n",
            "hello world",
        );
        defer allocator.free(request);

        const n = try h2cUpgradeToServer(running.port, request, &.{}, &out);
        try std.testing.expect(std.mem.startsWith(u8, out[0..n], "HTTP/1.1 101"));
        const wire = try h2cWireAfter101(out[0..n]);

        // The method reached the handler as `POST` and the body arrived whole:
        // the seeded stream carries both, since no DATA frame will ever come for
        // a stream that is half-closed (remote) from the start.
        const body = try h2CollectData(allocator, wire, 1);
        defer allocator.free(body);
        try std.testing.expectEqualStrings("POST:hello world", body);

        const hframe = h2FindFrame(wire, .headers, 1) orelse return error.NoStream1ResponseAfterUpgrade;
        var dec = Hpack.Decoder.init(allocator);
        defer dec.deinit();
        const hdrs = try dec.decode(hframe.payload);
        defer Hpack.freeHeaders(allocator, hdrs);
        try std.testing.expectEqualStrings("200", h2FirstHeaderValue(hdrs, ":status") orelse return error.NoStatusField);
    }
    {
        // A second connection, no body: the method gate is gone, not widened to
        // one extra verb.
        const request = try h2cUpgradeRequest(allocator, "OPTIONS", "/h2copt", settings_value, "", "");
        defer allocator.free(request);

        const n = try h2cUpgradeToServer(running.port, request, &.{}, &out);
        try std.testing.expect(std.mem.startsWith(u8, out[0..n], "HTTP/1.1 101"));
        const wire = try h2cWireAfter101(out[0..n]);

        const body = try h2CollectData(allocator, wire, 1);
        defer allocator.free(body);
        try std.testing.expectEqualStrings("OPTIONS", body);
    }
}

test "h2c upgrade: a HEAD request is answered with no body at all" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2c-upgrade-head" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.head("h2chead", struct {
        fn h(ctx: *Context) anyerror!void {
            // The method the session seeded into `:method`/`st.method`, echoed
            // back — a `GET` would take this route and send its body.
            try ctx.setHeader("X-Seen-Method", ctx.method.toString());
            // The entity a `GET` would have produced, and its length: a response
            // to `HEAD` carries the field section and no body (RFC 9110 §9.3.2,
            // RFC 9113 §8.2), so the declared length has to survive while the
            // octets do not.
            try ctx.setHeader("Content-Length", "11");
            try ctx.text(200, "eleven byte");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    const settings_value = try h2cSettingsValue(allocator, &.{.{ Http2.SettingsId.initial_window_size, 131072 }});
    defer allocator.free(settings_value);
    const request = try h2cUpgradeRequest(allocator, "HEAD", "/h2chead", settings_value, "", "");
    defer allocator.free(request);

    var out: [8192]u8 = undefined;
    const n = try h2cUpgradeToServer(running.port, request, &.{}, &out);
    try std.testing.expect(std.mem.startsWith(u8, out[0..n], "HTTP/1.1 101"));
    const wire = try h2cWireAfter101(out[0..n]);

    // No DATA frame for stream 1: HEADERS carries END_STREAM instead.
    try std.testing.expectEqual(@as(usize, 0), h2CountFrames(wire, .data, 1));
    const hframe = h2FindFrame(wire, .headers, 1) orelse return error.NoStream1ResponseAfterUpgrade;
    try std.testing.expect((hframe.header.flags & Http2.FrameFlags.end_stream) != 0);

    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    const hdrs = try dec.decode(hframe.payload);
    defer Hpack.freeHeaders(allocator, hdrs);
    try std.testing.expectEqualStrings("200", h2FirstHeaderValue(hdrs, ":status") orelse return error.NoStatusField);
    // The seeded `:method` is the request line's, not the `GET` the upgrade path
    // used to be limited to.
    try std.testing.expectEqualStrings("HEAD", h2FirstHeaderValue(hdrs, "x-seen-method") orelse return error.NoSeenMethodField);
    try std.testing.expectEqualStrings("11", h2FirstHeaderValue(hdrs, "content-length") orelse return error.NoContentLengthField);
}

test "h2c upgrade: an HTTP2-Settings value that is not base64url is refused with GOAWAY" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2c-upgrade-badsettings" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2cbad", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, "must not be reached");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    // RFC 7540 §3.2.1: the `HTTP2-Settings` field *is* the peer's SETTINGS, so a
    // value that is not the base64url payload of a SETTINGS frame is a
    // connection error. The 101 is already out by the time the field is read, so
    // GOAWAY is the only answer left — and stream 1 must not be dispatched: the
    // request was never understood far enough to serve it. A `POST` with a body,
    // i.e. the upgrade a client uses to send one, refuses the same way.
    const request = try h2cUpgradeRequest(
        allocator,
        "POST",
        "/h2cbad",
        "!!!not-base64url!!!",
        "Content-Length: 11\r\n",
        "hello world",
    );
    defer allocator.free(request);

    var out: [8192]u8 = undefined;
    const n = try h2cUpgradeToServer(running.port, request, &.{}, &out);
    try std.testing.expect(std.mem.startsWith(u8, out[0..n], "HTTP/1.1 101"));
    const wire = try h2cWireAfter101(out[0..n]);

    const goaway = h2FindFrame(wire, .goaway, 0) orelse return error.NoGoAwayForUndecodableSettings;
    const info = try Http2.decodeGoAway(goaway.payload);
    try std.testing.expectEqual(Http2.ErrorCode.PROTOCOL_ERROR, info.error_code);
    try std.testing.expectEqual(@as(u31, 1), info.last_stream_id);
    try std.testing.expectEqual(@as(usize, 0), h2CountFrames(wire, .headers, 1));
    try std.testing.expectEqual(@as(usize, 0), h2CountFrames(wire, .data, 1));
}

test "h2c upgrade: base64url that is not a SETTINGS payload is refused with the mapped code" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2c-upgrade-shortsets" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2cshort", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, "must not be reached");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    // Five bytes of well-formed base64url: it survives the decode and is refused
    // by `SettingsIterator.init` instead — a SETTINGS payload is a whole number
    // of 6-byte entries (RFC 7540 §6.5). The second arm of the same guard, and
    // the one that has to map the error rather than assume PROTOCOL_ERROR.
    var five = [_]u8{ 0, 0, 0, 0, 1 };
    var encoded_buf: [16]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buf, &five);
    const request = try h2cUpgradeRequest(allocator, "GET", "/h2cshort", encoded, "", "");
    defer allocator.free(request);

    var out: [8192]u8 = undefined;
    const n = try h2cUpgradeToServer(running.port, request, &.{}, &out);
    try std.testing.expect(std.mem.startsWith(u8, out[0..n], "HTTP/1.1 101"));
    const wire = try h2cWireAfter101(out[0..n]);

    const goaway = h2FindFrame(wire, .goaway, 0) orelse return error.NoGoAwayForShortSettingsPayload;
    const info = try Http2.decodeGoAway(goaway.payload);
    try std.testing.expectEqual(Http2.ErrorCode.FRAME_SIZE_ERROR, info.error_code);
    try std.testing.expectEqual(@as(usize, 0), h2CountFrames(wire, .headers, 1));
    try std.testing.expectEqual(@as(usize, 0), h2CountFrames(wire, .data, 1));
}

// --- H1 response framing over loopback ---
//
// The field section `writeResponse` builds is the one thing H1 and H2 do not
// share, so these drive it through a socket rather than calling it: the shapes
// that matter (`Content-Length` twice, a body under `HEAD`) only exist on the
// wire.

/// One HTTP/1.1 exchange against a running `Server`: send `request`, then read
/// until EOF (the caller's `Connection: close` is what ends it). The reply is a
/// subslice of `out`.
fn h1RawExchange(port: u16, request: []const u8, out: []u8) ![]const u8 {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer stream.close(std.testing.io);

    try sockread.writeFull(stream, request);

    var total: usize = 0;
    while (total < out.len) {
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 3000) catch break;
        if (ready == 0) break;
        const n = std.posix.read(stream.socket.handle, out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return out[0..total];
}

/// Values of every `name` field line in `response`'s field section, in wire
/// order. A count is what a duplicate-framing assertion needs: `indexOf != null`
/// cannot tell one `Content-Length` from two.
fn h1HeaderValues(allocator: std.mem.Allocator, response: []const u8, name: []const u8) ![][]const u8 {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse response.len;
    var values = std.ArrayList([]const u8).empty;
    errdefer values.deinit(allocator);
    var lines = std.mem.splitSequence(u8, response[0..head_end], "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            try values.append(allocator, std.mem.trim(u8, line[colon + 1 ..], " \t"));
        }
    }
    return values.toOwnedSlice(allocator);
}

/// The bytes after the field section of an H1 response.
fn h1Body(response: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[end + 4 ..];
}

/// The status line of an H1 response — status *and* reason phrase, so a test
/// can compare the whole thing it saw instead of a prefix of it.
fn h1StatusLine(response: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n") orelse response.len;
    return response[0..end];
}

/// An allocator that refuses every request of `min_size` bytes or more, and
/// passes everything smaller to `child`, counting the refusals.
///
/// `connFiber` builds the per-request arena on `Server.allocator`, and the
/// arena asks its child for memory in whole chunks — one chunk-sized request
/// per node, never one per parse allocation. Refusing chunk-sized requests is
/// therefore how a *server-side* allocation failure is injected into a real
/// request without also failing the listener, the fiber or the response writer
/// (those ask for less). See the tests that use it for what each size reaches.
const LargeAllocTrap = struct {
    child: std.mem.Allocator,
    min_size: usize,
    trapped: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LargeAllocTrap = @ptrCast(@alignCast(ctx));
        if (len >= self.min_size) {
            _ = self.trapped.fetchAdd(1, .monotonic);
            return null;
        }
        return self.child.rawAlloc(len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LargeAllocTrap = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LargeAllocTrap = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LargeAllocTrap = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *LargeAllocTrap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "a handler's Content-Length is written once, not twice" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h1-content-length" });
    defer server.deinit();

    var group = server.group("");
    // `StaticFiles` sets the field itself on the non-streamed path (the file
    // length), and that is the length the client has to see. `writeResponse`
    // used to append the server's own next to it, so the wire carried two
    // framing fields — `Content-Length: 17` and `Content-Length: 17` here, and
    // `17` next to `0` on the `HEAD` shape below.
    try group.get("cl", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.setHeader("Content-Length", "17");
            try ctx.text(200, "small static body");
        }
    }.h, null);
    try group.head("clh", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.setHeader("Content-Length", "17");
            ctx.responded = true;
        }
    }.h, null);
    // The same field with a value that does not describe the body: it is the
    // handler's bug, and sending it next to the server's own would put two
    // disagreeing framing fields on the wire.
    try group.get("cllie", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.setHeader("Content-Length", "999");
            try ctx.text(200, "small static body");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    var out: [4096]u8 = undefined;
    {
        const response = try h1RawExchange(running.port, "GET /cl HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
        const values = try h1HeaderValues(allocator, response, "content-length");
        defer allocator.free(values);
        try std.testing.expectEqual(@as(usize, 1), values.len);
        try std.testing.expectEqualStrings("17", values[0]);
        try std.testing.expectEqualStrings("small static body", h1Body(response));
    }
    {
        // The static-files `HEAD`: the entity length is declared, no body is
        // written. One field, and it is the entity's.
        const response = try h1RawExchange(running.port, "HEAD /clh HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
        const values = try h1HeaderValues(allocator, response, "content-length");
        defer allocator.free(values);
        try std.testing.expectEqual(@as(usize, 1), values.len);
        try std.testing.expectEqualStrings("17", values[0]);
        try std.testing.expectEqualStrings("", h1Body(response));
    }
    {
        // A declaration that disagrees with the octets is dropped, not written:
        // the remaining field is the one that frames this body.
        const response = try h1RawExchange(running.port, "GET /cllie HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
        const values = try h1HeaderValues(allocator, response, "content-length");
        defer allocator.free(values);
        try std.testing.expectEqual(@as(usize, 1), values.len);
        try std.testing.expectEqualStrings("17", values[0]);
        try std.testing.expectEqualStrings("small static body", h1Body(response));
    }
}

test "declaredContentLength reads only a real 1*DIGIT length" {
    const allocator = std.testing.allocator;
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    // Absent: the server frames the body itself.
    try std.testing.expectEqual(@as(?usize, null), declaredContentLength(headers));
    // A handler's value, under the spelling a handler actually uses.
    try headers.put("Content-Length", "17");
    try std.testing.expectEqual(@as(?usize, 17), declaredContentLength(headers));
    _ = headers.remove("Content-Length");
    // `1_7` is not a length: Zig's `parseInt` takes `_` as a digit separator
    // and would read it as 17, which is not what goes on the wire.
    try headers.put("content-length", "1_7");
    try std.testing.expectEqual(@as(?usize, null), declaredContentLength(headers));
    _ = headers.remove("content-length");
    // Nor is a padded or signed value; the lookup itself is case-insensitive.
    try headers.put("content-length", " 17");
    try std.testing.expectEqual(@as(?usize, null), declaredContentLength(headers));
    _ = headers.remove("content-length");
    try headers.put("Content-Length", "+17");
    try std.testing.expectEqual(@as(?usize, null), declaredContentLength(headers));
}

test "a response to HEAD carries the entity length and no body bytes" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h1-head-body" });
    defer server.deinit();

    var group = server.group("");
    try group.head("headbody", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, "eleven byte");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    var out: [4096]u8 = undefined;
    const response = try h1RawExchange(running.port, "HEAD /headbody HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));

    // The field section of the `GET` response, and nothing after it: RFC 9110
    // §9.3.2 forbids a body under `HEAD`, and the 11 octets a client would have
    // to skip are exactly what desynchronises a keep-alive connection.
    const values = try h1HeaderValues(allocator, response, "content-length");
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 1), values.len);
    try std.testing.expectEqualStrings("11", values[0]);
    try std.testing.expectEqualStrings("", h1Body(response));
}

/// Two chunks and the terminator, through the streaming API — the one response
/// shape whose bytes are not assembled by `writeResponse`.
fn streamAlphaBeta(ctx: *Context) anyerror!void {
    try ctx.startChunked(200, "text/plain");
    try ctx.writeChunk("alpha");
    try ctx.writeChunk("beta");
    try ctx.endStream();
}

test "a HEAD request to a streaming route puts no chunk bytes on the wire" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h1-head-stream" });
    defer server.deinit();

    var group = server.group("");
    // Both methods take the same handler, so the method is the only variable
    // between the two exchanges below.
    try group.get("s", streamAlphaBeta, null);
    try group.head("s", streamAlphaBeta, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    var out: [4096]u8 = undefined;
    {
        // The `GET` first: it proves the route really streams (`Transfer-Encoding:
        // chunked` and the chunk framing on the wire), so the `HEAD` assertion
        // below is about the method and not about a route that never streamed.
        const response = try h1RawExchange(running.port, "GET /s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
        const te = try h1HeaderValues(allocator, response, "transfer-encoding");
        defer allocator.free(te);
        try std.testing.expectEqual(@as(usize, 1), te.len);
        try std.testing.expectEqualStrings("chunked", te[0]);
        try std.testing.expectEqualStrings("5\r\nalpha\r\n4\r\nbeta\r\n0\r\n\r\n", h1Body(response));
    }
    {
        // RFC 9110 §9.3.2: a response to `HEAD` ends at the field section. The
        // field section is the `GET` one — `Transfer-Encoding: chunked`, which is
        // the only framing field a stream of unknown length can carry — and not
        // one octet follows it, not even the zero-length chunk that would end
        // the body a `GET` sends.
        const response = try h1RawExchange(running.port, "HEAD /s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
        const te = try h1HeaderValues(allocator, response, "transfer-encoding");
        defer allocator.free(te);
        try std.testing.expectEqual(@as(usize, 1), te.len);
        try std.testing.expectEqualStrings("chunked", te[0]);
        try std.testing.expectEqualStrings("", h1Body(response));
    }
}

test "a HEAD request refused before routing carries no error body" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h1-head-preflight" });
    defer server.deinit();

    var group = server.group("");
    try group.get("never", struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.text(200, "must not be reached");
        }
    }.h, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    // A `Transfer-Encoding` request is refused by the parser with 400 before any
    // route is matched, so the answer comes from `writeErrorResponse` — the
    // factory for every request that never reached the success path.
    const bad = "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n";

    var get_out: [4096]u8 = undefined;
    const get_bad = try std.fmt.allocPrint(allocator, "GET /never HTTP/1.1\r\nHost: x\r\n{s}", .{bad});
    defer allocator.free(get_bad);
    const get_response = try h1RawExchange(running.port, get_bad, &get_out);
    try std.testing.expect(std.mem.startsWith(u8, get_response, "HTTP/1.1 400"));
    const entity = h1Body(get_response);
    try std.testing.expect(entity.len > 0);
    // The entity length a `HEAD` response has to describe, without being told
    // which number it is here: whatever the `GET` answer carried.
    const expected_length = try std.fmt.allocPrint(allocator, "{d}", .{entity.len});
    defer allocator.free(expected_length);

    var out: [4096]u8 = undefined;
    const head_bad = try std.fmt.allocPrint(allocator, "HEAD /never HTTP/1.1\r\nHost: x\r\n{s}", .{bad});
    defer allocator.free(head_bad);
    const response = try h1RawExchange(running.port, head_bad, &out);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400"));

    // RFC 9110 §9.3.2 again, on the error factory: the field section, the length
    // the body *would* have had, and no octets.
    const values = try h1HeaderValues(allocator, response, "content-length");
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 1), values.len);
    try std.testing.expectEqualStrings(expected_length, values[0]);
    try std.testing.expectEqualStrings("", h1Body(response));
}

test "a HEAD request whose response field the server refuses carries no error body" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h1-head-refused" });
    defer server.deinit();

    var group = server.group("");
    // A field name that is not `1*tchar` (RFC 9110 §5.6.2) — the bug
    // `writeResponse` refuses the whole response for, before a byte of it is
    // written. `setHeader` validates, so the map is filled the way the comment
    // in `writeResponse` says it can be: directly.
    const bad_field = struct {
        fn h(ctx: *Context) anyerror!void {
            try ctx.response_headers.put(try ctx.allocator.dupe(u8, "X Bad Name"), try ctx.allocator.dupe(u8, "1"));
            ctx.status_code = 200;
            ctx.responded = true;
        }
    }.h;
    try group.get("badfield", bad_field, null);
    try group.head("badfield", bad_field, null);

    var running = try H2TestServer.start(&server);
    defer running.stop(&server);

    var get_out: [4096]u8 = undefined;
    const get_response = try h1RawExchange(running.port, "GET /badfield HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &get_out);
    try std.testing.expect(std.mem.startsWith(u8, get_response, "HTTP/1.1 500"));
    const entity = h1Body(get_response);
    try std.testing.expect(entity.len > 0);
    const expected_length = try std.fmt.allocPrint(allocator, "{d}", .{entity.len});
    defer allocator.free(expected_length);

    var out: [4096]u8 = undefined;
    const response = try h1RawExchange(running.port, "HEAD /badfield HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 500"));

    // The 500 the handler's own response was refused for is still a response to
    // a `HEAD` request: same field section, no octets (RFC 9110 §9.3.2).
    const values = try h1HeaderValues(allocator, response, "content-length");
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 1), values.len);
    try std.testing.expectEqualStrings(expected_length, values[0]);
    try std.testing.expectEqualStrings("", h1Body(response));
}

test "requestLineIsHead reads the method token, not a prefix of it" {
    // The first line of a request, terminator included, as `connFiber` has it.
    try std.testing.expect(requestLineIsHead("HEAD /x HTTP/1.1\r\n"));
    try std.testing.expect(requestLineIsHead("HEAD /x HTTP/1.1\n"));
    try std.testing.expect(requestLineIsHead("HEAD"));

    // `HEADER` is a method token of its own (`M-SEARCH`-style), and a method
    // token is case-sensitive (RFC 9110 §9.1) — neither is a `HEAD` request, so
    // their answer keeps the body the other requests get.
    try std.testing.expect(!requestLineIsHead("HEADER /x HTTP/1.1\r\n"));
    try std.testing.expect(!requestLineIsHead("head /x HTTP/1.1\r\n"));
    try std.testing.expect(!requestLineIsHead("GET /x HTTP/1.1\r\n"));
    try std.testing.expect(!requestLineIsHead(""));
    try std.testing.expect(!requestLineIsHead("HEA"));
}
