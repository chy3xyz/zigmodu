//! Comptime / generic HTTP routing (Zig-native).
//!
//! See `docs/ROUTE_TABLE.md`. Modules declare `routes` + `module_name` + `nest`;
//! `Router(AppState).scope(prefix).mount(Mod, state)` expands them with `inline for`.
//!
//! Does NOT scan the filesystem. Registration is an explicit comptime module tuple.

const std = @import("std");
const server_mod = @import("Server.zig");
const OpenApi = @import("../http/OpenApi.zig");

pub const Method = server_mod.Method;
pub const HandlerFn = server_mod.HandlerFn;
pub const Context = server_mod.Context;
pub const Server = server_mod.Server;
pub const RouteGroup = server_mod.RouteGroup;
pub const Middleware = server_mod.Middleware;
pub const WsConnectFn = server_mod.WsConnectFn;
pub const WsMessageFn = server_mod.WsMessageFn;
pub const WsCloseFn = server_mod.WsCloseFn;
pub const WsFrameKind = server_mod.WsFrameKind;

/// Auth for a single route. `.inherit` resolves to nest/scoped default (`.jwt`).
pub const Auth = enum {
    inherit,
    /// No authentication. Identity is **not** attached: `ctx.userId()` stays
    /// null. Use `.optional` when a public handler may still want to know who
    /// is calling.
    public,
    /// Optional authentication: verify a presented token and attach the
    /// identity when it is valid; a missing/invalid/expired token changes
    /// nothing and the request still succeeds. Never 401 — the route is public,
    /// it just gets personalization for free. This is the explicit form of the
    /// "public but personalized" endpoint (C-end user center, feature flags per
    /// user, …) that otherwise needs a hand-rolled token check in the handler.
    optional,
    jwt,
};

pub const RouteMeta = struct {
    auth: Auth = .inherit,
    /// Required permission code(s). Prefer fine-grained codes (`tenant:suspend`);
    /// `|` = OR. With `permissionGate` default mode, matched against JWT **roles**;
    /// with `.mode = .rbac`, matched against loaded permission codes.
    permission: ?[]const u8 = null,
    /// Portal / coarse role gate (`|` = OR, e.g. `"admin|ops"`), enforced by
    /// `permissionGateWith` against the identity `roles` attr before the
    /// fine-grained `permission` check. Replaces hardcoded path-prefix → role
    /// maps in consumers.
    roles: ?[]const u8 = null,
    /// ModuleGate name; null → module's `module_name`.
    module: ?[]const u8 = null,
    /// Human-readable one-liner for the generated OpenAPI `summary`. Falls back to
    /// `permission`, then `module`, so an un-annotated route keeps today's output.
    summary: ?[]const u8 = null,
    /// Longer prose for OpenAPI `description`. Falls back to today's per-auth-kind
    /// string (`jwt` / `public` / `websocket` / `text/event-stream (SSE)`), which is
    /// not prose at all — set this when the document is for a consumer.
    description: ?[]const u8 = null,
    /// Request body as a JSON-schema **string** (no new types: `?[]const u8`).
    /// Emitted as the operation's request-body schema when present; absent →
    /// no `requestBody` at all, so un-annotated output is unchanged.
    request_body: ?[]const u8 = null,
    /// When true, route is Server-Sent Events (`Accept: text/event-stream`). Handler should call `http.sse(ctx)`.
    sse: bool = false,
    /// Extra OpenAPI params (typically from `http.openApiParamsFromStruct(QueryDto, .query)`).
    /// Merged with path `{name}` segments in `RouteCatalog.exportOpenApi`.
    openapi_params: []const OpenApi.ApiParam = &.{},
};

pub fn TypedHandler(comptime State: type) type {
    return *const fn (*Context, *State) anyerror!void;
}

/// Compile-time route row for a module state type.
pub fn RouteSpec(comptime State: type) type {
    return struct {
        method: Method,
        path: []const u8,
        handler: TypedHandler(State),
        meta: RouteMeta = .{},
    };
}

/// WebSocket route row; shares RouteMeta (at least `module`).
/// `State` is phantom — keeps WsSpec parallel to RouteSpec(State) for module tables.
pub fn WsSpec(comptime State: type) type {
    return struct {
        path: []const u8,
        on_connect: WsConnectFn,
        on_message: WsMessageFn,
        on_close: WsCloseFn,
        meta: RouteMeta = .{},
        /// When set, passed as ws user_data; otherwise mount()'s state pointer is used.
        user_data: ?*anyopaque = null,
        pub const state_type = State;
    };
}

/// SSE route row; handler calls `http.sse(ctx)` then streams events.
pub fn SseSpec(comptime State: type) type {
    return struct {
        path: []const u8,
        handler: TypedHandler(State),
        meta: RouteMeta = .{},
        pub const state_type = State;
    };
}

/// Bridge `fn(*Context,*State)` → existing `HandlerFn` (state via `ctx.user_data`).
pub fn wrap(comptime State: type, comptime handler: TypedHandler(State)) HandlerFn {
    return struct {
        fn bridged(ctx: *Context) anyerror!void {
            const state = ctx.userData(State) orelse return error.MissingRouteState;
            try handler(ctx, state);
        }
    }.bridged;
}

pub const CatalogEntry = struct {
    method: Method,
    /// Absolute path as registered on the server (no leading slash normalization here).
    path: []const u8,
    auth: Auth,
    module: []const u8,
    permission: ?[]const u8 = null,
    /// Portal / coarse role gate from `RouteMeta.roles` (`|` = OR).
    roles: ?[]const u8 = null,
    /// Borrowed OpenAPI annotations from RouteMeta (static / comptime strings).
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    request_body: ?[]const u8 = null,
    is_ws: bool = false,
    is_sse: bool = false,
    /// Borrowed comptime/static OpenAPI params from RouteMeta.
    openapi_params: []const OpenApi.ApiParam = &.{},
};

pub const RouteCatalog = struct {
    allocator: std.mem.Allocator,
    entries: []CatalogEntry,

    pub fn deinit(self: *RouteCatalog) void {
        for (self.entries) |e| {
            self.allocator.free(e.path);
            // module strings are usually comptime literals — only free if we duped.
            // Mount always dupes path; module is borrowed from module_name / meta (static).
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Exact or `{param}` segment match; prefers exact over param when both would match.
    pub fn findEntry(self: *const RouteCatalog, method: Method, path: []const u8) ?CatalogEntry {
        const norm = normalizePath(path);
        var param_hit: ?CatalogEntry = null;
        for (self.entries) |e| {
            if (e.is_ws) continue;
            if (e.method != method) continue;
            const pat = normalizePath(e.path);
            if (std.mem.eql(u8, pat, norm)) return e;
            if (param_hit == null and pathMatches(pat, norm)) param_hit = e;
        }
        return param_hit;
    }

    pub fn isPublic(self: *const RouteCatalog, method: Method, path: []const u8) bool {
        const e = self.findEntry(method, path) orelse return false;
        return e.auth == .public;
    }

    /// Route wants best-effort identity (`.optional`): verify if a token is
    /// presented, never reject.
    pub fn isOptionalAuth(self: *const RouteCatalog, method: Method, path: []const u8) bool {
        const e = self.findEntry(method, path) orelse return false;
        return e.auth == .optional;
    }

    pub fn authFor(self: *const RouteCatalog, method: Method, path: []const u8) ?Auth {
        const e = self.findEntry(method, path) orelse return null;
        return e.auth;
    }

    pub fn moduleFor(self: *const RouteCatalog, path: []const u8) ?[]const u8 {
        const norm = normalizePath(path);
        var param_hit: ?[]const u8 = null;
        for (self.entries) |e| {
            const pat = normalizePath(e.path);
            if (std.mem.eql(u8, pat, norm)) return e.module;
            if (param_hit == null and pathMatches(pat, norm)) param_hit = e.module;
        }
        return param_hit;
    }

    pub fn permissionFor(self: *const RouteCatalog, method: Method, path: []const u8) ?[]const u8 {
        const e = self.findEntry(method, path) orelse return null;
        return e.permission;
    }

    /// Portal / coarse role expression from `RouteMeta.roles` (`|` = OR).
    pub fn rolesFor(self: *const RouteCatalog, method: Method, path: []const u8) ?[]const u8 {
        const e = self.findEntry(method, path) orelse return null;
        return e.roles;
    }

    /// All distinct permission expressions across the catalog (borrowed from
    /// the entries; valid while the catalog lives). For menu↔route permission
    /// audits / validation scripts. Caller frees the returned slice only.
    pub fn allPermissions(self: *const RouteCatalog, allocator: std.mem.Allocator) ![]const []const u8 {
        var out = std.ArrayList([]const u8).empty;
        errdefer out.deinit(allocator);
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (self.entries) |e| {
            const p = e.permission orelse continue;
            if (seen.contains(p)) continue;
            try seen.put(p, {});
            try out.append(allocator, p);
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Feed catalog rows into OpenApiGenerator (tags = module; `{name}` → path params).
    /// WebSocket upgrades are exported as GET with description `websocket`.
    pub fn exportOpenApi(self: *const RouteCatalog, gen: *OpenApi.OpenApiGenerator) !void {
        for (self.entries) |e| {
            const method: OpenApi.HttpMethod = if (e.is_ws) .GET else switch (e.method) {
                .GET => .GET,
                .POST => .POST,
                .PUT => .PUT,
                .DELETE => .DELETE,
                .PATCH => .PATCH,
                .HEAD => .HEAD,
                .OPTIONS => .OPTIONS,
            };

            var params_buf: [16]OpenApi.ApiParam = undefined;
            var param_count: usize = 0;
            var it = std.mem.splitScalar(u8, e.path, '/');
            while (it.next()) |seg| {
                if (seg.len >= 2 and seg[0] == '{' and seg[seg.len - 1] == '}' and param_count < params_buf.len) {
                    params_buf[param_count] = .{
                        .name = seg[1 .. seg.len - 1],
                        .location = .path,
                        .required = true,
                    };
                    param_count += 1;
                }
            }
            for (e.openapi_params) |extra| {
                if (param_count >= params_buf.len) break;
                var dup = false;
                for (params_buf[0..param_count]) |existing| {
                    if (std.mem.eql(u8, existing.name, extra.name) and existing.location == extra.location) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    params_buf[param_count] = extra;
                    param_count += 1;
                }
            }

            var path_storage: [512]u8 = undefined;
            const oapi_path = if (e.path.len > 0 and e.path[0] == '/') e.path else blk: {
                if (e.path.len + 1 > path_storage.len) return error.PathTooLong;
                path_storage[0] = '/';
                @memcpy(path_storage[1..][0..e.path.len], e.path);
                break :blk path_storage[0 .. e.path.len + 1];
            };

            const summary = e.summary orelse e.permission orelse e.module;
            const desc: []const u8 = if (e.description) |d|
                d
            else if (e.is_ws)
                "websocket"
            else if (e.is_sse)
                "text/event-stream (SSE)"
            else if (e.auth == .public)
                "public"
            else
                "jwt";
            // 401 is only meaningful for authenticated routes (M14).
            var resp_buf: [2]OpenApi.ApiResponse = undefined;
            resp_buf[0] = .{ .status_code = 200, .description = if (e.is_ws) "Switching Protocols" else if (e.is_sse) "text/event-stream" else "OK" };
            var resp_count: usize = 1;
            if (e.auth != .public) {
                resp_buf[1] = .{ .status_code = 401, .description = "Unauthorized" };
                resp_count = 2;
            }
            // `RouteMeta.request_body` is the schema itself; `RequestBody.schema_ref`
            // emits a value starting with `{` verbatim (see OpenApi.RequestBody).
            const req_body: ?OpenApi.RequestBody = if (e.request_body) |schema| .{
                .schema_ref = schema,
            } else null;
            try gen.addEndpoint(.{
                .method = method,
                .path = oapi_path,
                .summary = summary,
                .description = desc,
                .tags = &.{e.module},
                .params = params_buf[0..param_count],
                .request_body = req_body,
                .requires_auth = e.auth != .public,
                .responses = resp_buf[0..resp_count],
            });
        }
    }
};

pub const OpenApiFromCatalogConfig = struct {
    title: []const u8,
    version: []const u8 = "1.0.0",
    description: []const u8 = "",
    /// Emit `components.securitySchemes.bearerAuth` + per-operation `security`
    /// for non-public routes (default on; public routes carry no requirement).
    bearer_auth: bool = true,
};

/// Runtime binding of one OpenAPI endpoint: the slot it documents plus the
/// document header. Regenerated from `CatalogSlot` on each request, so the slot
/// may be filled after registration — only the first request needs it set.
const OpenApiBinding = struct {
    catalog_slot: *CatalogSlot,
    title: []const u8,
    version: []const u8,
    description: []const u8,
    bearer_auth: bool,
};

/// Number of independently-bound OpenAPI endpoints one process may build.
///
/// A `HandlerFn` is a bare function pointer and carries no context, so the
/// binding has to be reached through *the function itself*: every registration
/// claims one slot and returns that slot's own trampoline, which reads its own
/// slot + config and nothing else. Hoisting the state to one module-level store
/// (the shape this replaced) makes it process-wide instead — the second
/// `openApiFromCatalog` overwrote the first, so with two apps in one binary
/// app A's `/openapi.json` served app B's catalog. Both documents are valid
/// JSON, so nothing downstream noticed.
///
/// Slots are claimed at wiring time and never released, so this bounds how many
/// OpenAPI endpoints an application *builds*, not how many requests it serves.
pub const max_openapi_bindings = 16;

const OpenApiBindings = struct {
    /// One binding per claimed slot; unclaimed slots stay `null` and are not
    /// reachable — their trampolines are never handed out.
    var bindings: [max_openapi_bindings]?OpenApiBinding = @splat(null);
    /// Atomic so two threads wiring apps concurrently cannot claim one slot
    /// (which would put two apps on one binding again).
    var claimed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
};

/// Claim the binding for `slot`, reusing the existing slot when the same
/// `CatalogSlot` registers twice: a re-registration updates that app's config,
/// as it always did, and leaves every other app alone.
fn claimOpenApiBinding(slot: *CatalogSlot, config: OpenApiFromCatalogConfig) usize {
    const binding: OpenApiBinding = .{
        .catalog_slot = slot,
        .title = config.title,
        .version = config.version,
        .description = config.description,
        .bearer_auth = config.bearer_auth,
    };
    const claimed = OpenApiBindings.claimed.load(.seq_cst);
    for (0..claimed) |i| {
        if (OpenApiBindings.bindings[i]) |existing| {
            if (existing.catalog_slot == slot) {
                OpenApiBindings.bindings[i] = binding;
                return i;
            }
        }
    }
    const index = OpenApiBindings.claimed.fetchAdd(1, .seq_cst);
    if (index >= max_openapi_bindings) {
        @panic("openApiFromCatalog: OpenAPI binding pool exhausted — raise max_openapi_bindings");
    }
    OpenApiBindings.bindings[index] = binding;
    return index;
}

fn OpenApiHandler(comptime index: usize) type {
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            // Fail closed rather than guess: `null` or an unready slot is not a
            // document we know anything about.
            const binding = OpenApiBindings.bindings[index] orelse {
                try ctx.sendError(503, "Route catalog not ready");
                return;
            };
            const cat = binding.catalog_slot.get() orelse {
                try ctx.sendError(503, "Route catalog not ready");
                return;
            };
            var gen = OpenApi.OpenApiGenerator.init(ctx.allocator, binding.title, binding.version, binding.description);
            defer gen.deinit();
            gen.bearer_auth = binding.bearer_auth;
            try cat.exportOpenApi(&gen);
            const json = try gen.generate();
            defer ctx.allocator.free(json);
            try ctx.setHeader("Content-Type", "application/json");
            try ctx.json(200, json);
        }
    };
}

/// One distinct function pointer per binding — the identity a bare fn pointer
/// cannot otherwise carry. Every entry reads a different binding, so they are
/// not interchangeable and no optimizer may fold them into one.
const openapi_handlers: [max_openapi_bindings]HandlerFn = blk: {
    var table: [max_openapi_bindings]HandlerFn = undefined;
    for (0..max_openapi_bindings) |i| table[i] = OpenApiHandler(i).handle;
    break :blk table;
};

/// Live OpenAPI JSON handler served from this app's `CatalogSlot`, with this
/// app's title/version/description. Register after
/// `catalog_slot.set(try router.finish())` (the handler reads the slot per
/// request, so only requests before `set` see 503).
pub fn openApiFromCatalog(slot: *CatalogSlot, config: OpenApiFromCatalogConfig) HandlerFn {
    return openapi_handlers[claimOpenApiBinding(slot, config)];
}

/// Standalone handler serving an interactive Swagger UI HTML page pointing to `spec_url`.
pub fn swaggerUiHandler(comptime spec_url: []const u8) HandlerFn {
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            const html =
                \\<!DOCTYPE html>
                \\<html lang="en">
                \\<head>
                \\  <meta charset="utf-8" />
                \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
                \\  <title>API Documentation</title>
                \\  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css" />
                \\</head>
                \\<body>
                \\  <div id="swagger-ui"></div>
                \\  <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js" charset="UTF-8"></script>
                \\  <script>
                \\    window.onload = () => {
                \\      window.ui = SwaggerUIBundle({
                \\        url: "
            ++ spec_url ++
                \\",
                \\        dom_id: '#swagger-ui',
                \\      });
                \\    };
                \\  </script>
                \\</body>
                \\</html>
            ;
            try ctx.html(200, html);
        }
    }.handle;
}

/// Standalone handler serving an interactive Scalar API Reference HTML page pointing to `spec_url`.
pub fn scalarUiHandler(comptime spec_url: []const u8) HandlerFn {
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            const html =
                \\<!doctype html>
                \\<html>
                \\  <head>
                \\    <title>API Reference</title>
                \\    <meta charset="utf-8" />
                \\    <meta name="viewport" content="width=device-width, initial-scale=1" />
                \\  </head>
                \\  <body>
                \\    <script id="api-reference" data-url="
            ++ spec_url ++
                \\"></script>
                \\    <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
                \\  </body>
                \\</html>
            ;
            try ctx.html(200, html);
        }
    }.handle;
}

/// Adapter to turn a 1-arg `HandlerFn` (`fn(*Context)`) into a 2-arg `TypedHandler(State)` (`fn(*Context, *State)`).
/// `handler` must be comptime: a runtime `var` store would be shared by every
/// wrapper of the same `State` (last write wins) and cannot be evaluated when
/// the route table is built at comptime.
pub fn wrapHandler(comptime State: type, comptime handler: HandlerFn) TypedHandler(State) {
    return struct {
        fn adapter(ctx: *Context, _: *State) anyerror!void {
            return handler(ctx);
        }
    }.adapter;
}

/// Zero-boilerplate RouteSpec tuple for mounting OpenAPI JSON + Swagger UI + Scalar UI.
/// Returns 3 routes (`openapi.json`, `docs`, `scalar`) preconfigured for public access.
pub fn openApiRoutes(
    comptime State: type,
    slot: *CatalogSlot,
    config: OpenApiFromCatalogConfig,
) [3]RouteSpec(State) {
    const index = claimOpenApiBinding(slot, config);
    // `RouteSpec(State).handler` is a `TypedHandler(State)`, and the binding
    // index is a runtime value, so the adapter that bridges to the slot's
    // `HandlerFn` has to exist per (State, slot) — one distinct fn per binding,
    // same reason as `openapi_handlers`.
    const Adapter = struct {
        fn forSlot(comptime i: usize) TypedHandler(State) {
            return struct {
                fn adapter(ctx: *Context, _: *State) anyerror!void {
                    return openapi_handlers[i](ctx);
                }
            }.adapter;
        }
        const table: [max_openapi_bindings]TypedHandler(State) = blk: {
            var t: [max_openapi_bindings]TypedHandler(State) = undefined;
            for (0..max_openapi_bindings) |i| t[i] = forSlot(i);
            break :blk t;
        };
    };
    return [_]RouteSpec(State){
        .{ .method = .GET, .path = "openapi.json", .handler = Adapter.table[index], .meta = .{ .auth = .public } },
        .{ .method = .GET, .path = "docs", .handler = wrapHandler(State, swaggerUiHandler("openapi.json")), .meta = .{ .auth = .public } },
        .{ .method = .GET, .path = "scalar", .handler = wrapHandler(State, scalarUiHandler("openapi.json")), .meta = .{ .auth = .public } },
    };
}

/// Filled after `router.finish()`; middleware holds a pointer and reads once set.
pub const CatalogSlot = struct {
    catalog: ?RouteCatalog = null,

    pub fn set(self: *CatalogSlot, catalog: RouteCatalog) void {
        if (self.catalog) |*old| old.deinit();
        self.catalog = catalog;
    }

    pub fn get(self: *const CatalogSlot) ?*const RouteCatalog {
        if (self.catalog) |*c| return c;
        return null;
    }

    pub fn deinit(self: *CatalogSlot) void {
        if (self.catalog) |*c| c.deinit();
        self.catalog = null;
    }
};

fn normalizePath(path: []const u8) []const u8 {
    if (path.len > 0 and path[0] == '/') return path[1..];
    return path;
}

fn pathEqual(registered: []const u8, incoming_norm: []const u8) bool {
    const a = normalizePath(registered);
    return std.mem.eql(u8, a, incoming_norm);
}

/// Pattern may contain `{name}` segments matching any non-empty path segment.
fn pathMatches(pattern: []const u8, incoming: []const u8) bool {
    var pat_it = std.mem.splitScalar(u8, pattern, '/');
    var in_it = std.mem.splitScalar(u8, incoming, '/');
    while (true) {
        const p = while (pat_it.next()) |seg| {
            if (seg.len > 0) break seg;
        } else null;
        const i = while (in_it.next()) |seg| {
            if (seg.len > 0) break seg;
        } else null;
        if (p == null and i == null) return true;
        if (p == null or i == null) return false;
        const ps = p.?;
        const is = i.?;
        if (ps.len >= 2 and ps[0] == '{' and ps[ps.len - 1] == '}') continue;
        if (!std.mem.eql(u8, ps, is)) return false;
    }
}

fn resolveAuth(meta: RouteMeta, default_auth: Auth) Auth {
    return if (meta.auth == .inherit) default_auth else meta.auth;
}

fn resolveModule(meta: RouteMeta, module_name: []const u8) []const u8 {
    return meta.module orelse module_name;
}

fn joinNestComptime(comptime nest: anytype) []const u8 {
    if (nest.len == 0) return "";
    var out: []const u8 = nest[0];
    comptime var i: usize = 1;
    inline while (i < nest.len) : (i += 1) {
        out = out ++ "/" ++ nest[i];
    }
    return out;
}

fn joinPaths(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    var nonempty: usize = 0;
    for (parts) |p| {
        const t = std.mem.trim(u8, p, "/");
        if (t.len == 0) continue;
        if (nonempty > 0) total += 1;
        total += t.len;
        nonempty += 1;
    }
    const buf = try allocator.alloc(u8, total);
    var off: usize = 0;
    var first = true;
    for (parts) |p| {
        const t = std.mem.trim(u8, p, "/");
        if (t.len == 0) continue;
        if (!first) {
            buf[off] = '/';
            off += 1;
        }
        @memcpy(buf[off..][0..t.len], t);
        off += t.len;
        first = false;
    }
    return buf;
}

/// Compile-time duplicate detection across modules (nest + method + path).
/// Does not include runtime scope prefixes (`/admin-api`); call once per scope group.
pub fn assertNoDupes(comptime modules: anytype) void {
    comptime {
        @setEvalBranchQuota(5_000_000);
        var seen: []const []const u8 = &.{};
        for (modules) |Mod| {
            if (!@hasDecl(Mod, "routes")) @compileError(@typeName(Mod) ++ " missing pub const routes");
            if (!@hasDecl(Mod, "module_name")) @compileError(@typeName(Mod) ++ " missing pub const module_name");
            if (!@hasDecl(Mod, "nest")) @compileError(@typeName(Mod) ++ " missing pub const nest");
            const base = joinNestComptime(Mod.nest);
            for (Mod.routes) |spec| {
                const key = @tagName(spec.method) ++ "|" ++ base ++ "/" ++ spec.path;
                for (seen) |s| {
                    if (std.mem.eql(u8, s, key)) {
                        @compileError("duplicate route: " ++ key);
                    }
                }
                seen = seen ++ .{key};
            }
            if (@hasDecl(Mod, "ws_routes")) {
                for (Mod.ws_routes) |spec| {
                    const key = "WS|" ++ base ++ "/" ++ spec.path;
                    for (seen) |s| {
                        if (std.mem.eql(u8, s, key)) {
                            @compileError("duplicate ws route: " ++ key);
                        }
                    }
                    seen = seen ++ .{key};
                }
            }
            if (@hasDecl(Mod, "sse_routes")) {
                for (Mod.sse_routes) |spec| {
                    const key = "SSE|GET|" ++ base ++ "/" ++ spec.path;
                    for (seen) |s| {
                        if (std.mem.eql(u8, s, key)) {
                            @compileError("duplicate sse route: " ++ key);
                        }
                    }
                    seen = seen ++ .{key};
                }
            }
        }
    }
}

fn validateModule(comptime Mod: type) void {
    comptime {
        if (!@hasDecl(Mod, "routes")) @compileError(@typeName(Mod) ++ " missing pub const routes");
        if (!@hasDecl(Mod, "module_name")) @compileError(@typeName(Mod) ++ " missing pub const module_name");
        if (!@hasDecl(Mod, "nest")) @compileError(@typeName(Mod) ++ " missing pub const nest");
        if (!@hasDecl(Mod, "State")) @compileError(@typeName(Mod) ++ " missing pub const State");
    }
}

/// Generic app router: holds `std.Io`, server, and builds a RouteCatalog while mounting.
pub fn Router(comptime AppState: type) type {
    return struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        server: *Server,
        app_state: *AppState,
        default_auth: Auth = .jwt,
        catalog_buf: std.ArrayList(CatalogEntry) = .empty,

        const Self = @This();

        pub fn init(io: std.Io, allocator: std.mem.Allocator, server: *Server, app_state: *AppState) Self {
            return .{
                .io = io,
                .allocator = allocator,
                .server = server,
                .app_state = app_state,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.catalog_buf.items) |e| {
                self.allocator.free(e.path);
            }
            self.catalog_buf.deinit(self.allocator);
            self.* = undefined;
        }

        /// Scope prefix group, e.g. `/admin-api`.
        pub fn scope(self: *Self, prefix: []const u8) Scoped(AppState) {
            return .{
                .router = self,
                .prefix = prefix,
            };
        }

        /// Transfer catalog ownership to caller. Call after all mounts.
        pub fn finish(self: *Self) !RouteCatalog {
            const items = try self.catalog_buf.toOwnedSlice(self.allocator);
            self.catalog_buf = .empty;
            // Runtime duplicate check (includes scope prefix)
            var i: usize = 0;
            while (i < items.len) : (i += 1) {
                var j: usize = i + 1;
                while (j < items.len) : (j += 1) {
                    if (items[i].is_ws != items[j].is_ws) continue;
                    if (items[i].method != items[j].method and !items[i].is_ws) continue;
                    if (pathEqual(items[i].path, normalizePath(items[j].path))) {
                        std.log.err("duplicate route at finish: {s} {s}", .{
                            if (items[i].is_ws) "WS" else @tagName(items[i].method),
                            items[i].path,
                        });
                        // Free and error
                        for (items) |e| self.allocator.free(e.path);
                        self.allocator.free(items);
                        return error.DuplicateRoute;
                    }
                }
            }
            return .{
                .allocator = self.allocator,
                .entries = items,
            };
        }
    };
}

pub fn Scoped(comptime AppState: type) type {
    return struct {
        router: *Router(AppState),
        prefix: []const u8,
        middleware: []const Middleware = &.{},

        const Self = @This();

        /// Append scope-local middleware (stored on server; freed in Server.deinit).
        pub fn use(self: Self, mw: Middleware) !Self {
            const extended = try self.router.server.allocator.alloc(Middleware, self.middleware.len + 1);
            @memcpy(extended[0..self.middleware.len], self.middleware);
            extended[self.middleware.len] = mw;
            try self.router.server.owned_route_mw.append(self.router.server.allocator, extended);
            return .{
                .router = self.router,
                .prefix = self.prefix,
                .middleware = extended,
            };
        }

        /// Mount one modulith HTTP module: expands `Mod.routes` / optional `ws_routes` / `sse_routes`.
        pub fn mount(self: *Self, comptime Mod: type, state: *Mod.State) !void {
            validateModule(Mod);
            const nest_path = comptime joinNestComptime(Mod.nest);
            const base = try joinPaths(self.router.allocator, &.{ self.prefix, nest_path });
            defer self.router.allocator.free(base);

            var group = self.router.server.group(base);
            group.middleware = self.middleware;
            const state_ptr: ?*anyopaque = state;

            inline for (Mod.routes) |spec| {
                const auth = resolveAuth(spec.meta, self.router.default_auth);
                const module = resolveModule(spec.meta, Mod.module_name);
                const bridged = wrap(Mod.State, spec.handler);
                try routeMethod(&group, spec.method, spec.path, bridged, state_ptr);

                const full = try joinPaths(self.router.allocator, &.{ base, spec.path });
                try self.router.catalog_buf.append(self.router.allocator, .{
                    .method = spec.method,
                    .path = full,
                    .auth = auth,
                    .module = module,
                    .permission = spec.meta.permission,
                    .roles = spec.meta.roles,
                    .summary = spec.meta.summary,
                    .description = spec.meta.description,
                    .request_body = spec.meta.request_body,
                    .is_ws = false,
                    .is_sse = spec.meta.sse,
                    .openapi_params = spec.meta.openapi_params,
                });
            }

            if (@hasDecl(Mod, "sse_routes")) {
                inline for (Mod.sse_routes) |spec| {
                    const auth = resolveAuth(spec.meta, self.router.default_auth);
                    const module = resolveModule(spec.meta, Mod.module_name);
                    const bridged = wrap(Mod.State, spec.handler);
                    try group.get(spec.path, bridged, state_ptr);

                    const full = try joinPaths(self.router.allocator, &.{ base, spec.path });
                    try self.router.catalog_buf.append(self.router.allocator, .{
                        .method = .GET,
                        .path = full,
                        .auth = auth,
                        .module = module,
                        .permission = spec.meta.permission,
                        .roles = spec.meta.roles,
                        .summary = spec.meta.summary,
                        .description = spec.meta.description,
                        .request_body = spec.meta.request_body,
                        .is_ws = false,
                        .is_sse = true,
                        .openapi_params = spec.meta.openapi_params,
                    });
                }
            }

            if (@hasDecl(Mod, "ws_routes")) {
                inline for (Mod.ws_routes) |spec| {
                    // ── A WebSocket route has no enforcement point. ─────────────
                    //
                    // The upgrade is answered in `Server` *before* `router.match`
                    // and before any global middleware runs, so nothing here reads
                    // `auth` / `permission` / `roles`: they would be catalog
                    // metadata that reads as a guarantee and is not one. The
                    // framework used to record them anyway, which is how the
                    // scaffolded IM module ended up taking its identity from
                    // `?userId=` — the declaration said `.auth = .jwt` and nothing
                    // checked anything.
                    //
                    // So the declaration is **enforced by being refused**: state
                    // your posture explicitly, and it may only be `.public`.
                    //
                    // Refused at compile time on purpose. A runtime refusal would
                    // leave the misleading declaration in the source for the next
                    // reader to copy.
                    if (comptime spec.meta.auth == .inherit) @compileError(
                        "WebSocket route '" ++ spec.path ++ "' in " ++ @typeName(Mod) ++ " does not declare " ++
                            "`.meta.auth`.\n" ++
                            "A WS route has no enforcement point — the upgrade is answered before " ++
                            "`router.match` and before any middleware runs, so an inherited `auth` would be " ++
                            "recorded and never checked (docs/RUNTIME.md §12.14).\n" ++
                            "Say who owns the identity, explicitly:\n" ++
                            "  .meta = .{ .auth = .public }                       // you authenticate inside on_connect\n" ++
                            "and if that is what you mean, do it there — the `ctx` is the upgrade request.",
                    );
                    if (comptime spec.meta.auth != .public) @compileError(
                        "WebSocket route '" ++ spec.path ++ "' in " ++ @typeName(Mod) ++ " declares `.meta.auth = ." ++
                            @tagName(spec.meta.auth) ++ "`, which cannot be enforced.\n" ++
                            "The upgrade is handled before `router.match` and before any global middleware, so " ++
                            "nothing would check it — the route would be open while reading as protected " ++
                            "(docs/RUNTIME.md §12.14).\n" ++
                            "Declare `.auth = .public` and authenticate inside `on_connect`, where `ctx` is the " ++
                            "upgrade request.",
                    );
                    if (comptime (spec.meta.permission != null or spec.meta.roles != null)) @compileError(
                        "WebSocket route '" ++ spec.path ++ "' in " ++ @typeName(Mod) ++ " declares " ++
                            "`permission` / `roles`, which cannot be enforced on a WS route (nothing runs before " ++
                            "the upgrade is answered).\n" ++
                            "Check them inside `on_connect` instead, or drop them (docs/RUNTIME.md §12.14).",
                    );

                    const auth = resolveAuth(spec.meta, self.router.default_auth);
                    const module = resolveModule(spec.meta, Mod.module_name);
                    const ud = spec.user_data orelse state_ptr;
                    try group.ws(spec.path, spec.on_connect, spec.on_message, spec.on_close, ud);

                    const full = try joinPaths(self.router.allocator, &.{ base, spec.path });
                    try self.router.catalog_buf.append(self.router.allocator, .{
                        .method = .GET, // upgrade
                        .path = full,
                        .auth = auth,
                        .module = module,
                        .summary = spec.meta.summary,
                        .description = spec.meta.description,
                        .permission = spec.meta.permission,
                        .roles = spec.meta.roles,
                        .is_ws = true,
                    });
                }
            }
        }

        /// `mounts` = `.{ .{ .Mod = M1, .state = &s1 }, .{ .Mod = M2, .state = &s2 } }`
        /// Tuple shape is comptime; state pointers may be runtime.
        pub fn mountAll(self: *Self, mounts: anytype) !void {
            inline for (mounts) |m| {
                try self.mount(m.Mod, m.state);
            }
        }
    };
}

/// Extension: RouteGroup method dispatch used by Scoped.mount (keeps Server.zig slim).
fn routeMethod(self: *RouteGroup, method: Method, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
    switch (method) {
        .GET => try self.get(path, handler, user_data),
        .POST => try self.post(path, handler, user_data),
        .PUT => try self.put(path, handler, user_data),
        .DELETE => try self.delete(path, handler, user_data),
        .PATCH => try self.patch(path, handler, user_data),
        .HEAD => try self.head(path, handler, user_data),
        .OPTIONS => try self.options(path, handler, user_data),
    }
}

/// Shared by catalog middleware (http_middleware) for health/dashboard skips.
pub fn pathHasSkipPrefix(path: []const u8, prefixes: []const []const u8) bool {
    const norm = normalizePath(path);
    for (prefixes) |pfx| {
        const np = normalizePath(pfx);
        if (np.len == 0) continue;
        if (std.mem.eql(u8, norm, np)) return true;
        if (norm.len > np.len and std.mem.startsWith(u8, norm, np) and norm[np.len] == '/') return true;
    }
    return false;
}

// --- tests ---

const TestMod = struct {
    pub const module_name = "crm";
    pub const nest = .{ "crm", "customer" };
    pub const State = struct { hits: *u32 };

    fn page(ctx: *Context, state: *State) !void {
        _ = ctx;
        state.hits.* += 1;
    }
    fn assign(ctx: *Context, state: *State) !void {
        _ = ctx;
        state.hits.* += 10;
    }

    pub const routes = [_]RouteSpec(State){
        .{ .method = .GET, .path = "page", .handler = page },
        .{ .method = .POST, .path = "assign", .handler = assign, .meta = .{ .auth = .jwt } },
        .{ .method = .GET, .path = "health", .handler = page, .meta = .{ .auth = .public } },
    };
};

const TestModB = struct {
    pub const module_name = "crm";
    pub const nest = .{ "crm", "contact" };
    pub const State = struct {};
    fn page(ctx: *Context, state: *State) !void {
        _ = ctx;
        _ = state;
    }
    pub const routes = [_]RouteSpec(State){
        .{ .method = .GET, .path = "page", .handler = page },
    };
};

test "wrap typed handler uses Context.user_data" {
    var hits: u32 = 0;
    var state = TestMod.State{ .hits = &hits };
    const bridged = wrap(TestMod.State, TestMod.page);
    var ctx = try Context.init(std.testing.allocator, .GET, "/x");
    defer ctx.deinit();
    ctx.user_data = &state;
    try bridged(&ctx);
    try std.testing.expectEqual(@as(u32, 1), hits);
}

test "Router mount expands routes into catalog" {
    const AppState = struct {};
    var app: AppState = .{};
    var hits: u32 = 0;
    var mod_state = TestMod.State{ .hits = &hits };

    var server = Server.initWithConfig(std.testing.io, std.testing.allocator, .{ .port = 18099 });
    defer server.deinit();

    var router = Router(AppState).init(std.testing.io, std.testing.allocator, &server, &app);
    defer router.deinit();

    var admin = router.scope("/admin-api");
    try admin.mount(TestMod, &mod_state);

    var catalog = try router.finish();
    defer catalog.deinit();

    try std.testing.expect(catalog.entries.len == 3);
    try std.testing.expect(catalog.isPublic(.GET, "/admin-api/crm/customer/health"));
    try std.testing.expect(!catalog.isPublic(.GET, "/admin-api/crm/customer/page"));
    try std.testing.expectEqualStrings("crm", catalog.moduleFor("/admin-api/crm/customer/page").?);

    // Handler wired: match + invoke. Nothing is released — the match borrows the
    // trie's parameter names and slices of the path it was given.
    var matched = server.router.match(std.testing.allocator, .GET, "/admin-api/crm/customer/page");
    try std.testing.expect(matched != null);
    var ctx = try Context.init(std.testing.allocator, .GET, "/admin-api/crm/customer/page");
    defer ctx.deinit();
    ctx.user_data = matched.?.route.user_data;
    try matched.?.route.handler(&ctx);
    try std.testing.expectEqual(@as(u32, 1), hits);
}

test "assertNoDupes accepts distinct nests" {
    assertNoDupes(.{ TestMod, TestModB });
}

test "mountAll tuple" {
    const AppState = struct {};
    var app: AppState = .{};
    var hits: u32 = 0;
    var st_a = TestMod.State{ .hits = &hits };
    var st_b: TestModB.State = .{};

    var server = Server.initWithConfig(std.testing.io, std.testing.allocator, .{ .port = 18100 });
    defer server.deinit();

    var router = Router(AppState).init(std.testing.io, std.testing.allocator, &server, &app);
    defer router.deinit();

    var admin = router.scope("/admin-api");
    try admin.mountAll(.{
        .{ .Mod = TestMod, .state = &st_a },
        .{ .Mod = TestModB, .state = &st_b },
    });

    var catalog = try router.finish();
    defer catalog.deinit();
    try std.testing.expect(catalog.entries.len == 4);
}

test "catalog matches path params and prefers exact" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(CatalogEntry, 2);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/users/{id}"),
        .auth = .jwt,
        .module = "user",
    };
    entries[1] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/users/me"),
        .auth = .public,
        .module = "user",
    };
    var catalog = RouteCatalog{ .allocator = alloc, .entries = entries };
    defer catalog.deinit();

    try std.testing.expectEqualStrings("user", catalog.moduleFor("/api/v1/users/42").?);
    try std.testing.expect(catalog.findEntry(.GET, "/api/v1/users/42") != null);
    try std.testing.expect(catalog.isPublic(.GET, "/api/v1/users/me"));
    try std.testing.expect(!catalog.isPublic(.GET, "/api/v1/users/42"));
}

test "pathHasSkipPrefix health boundary" {
    try std.testing.expect(pathHasSkipPrefix("/health/live", &.{ "health", "dashboard" }));
    try std.testing.expect(pathHasSkipPrefix("dashboard", &.{ "health", "dashboard" }));
    try std.testing.expect(!pathHasSkipPrefix("/api/v1/users", &.{ "health", "dashboard" }));
}

test "catalog exportOpenApi adds endpoints" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(CatalogEntry, 2);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/users/{id}"),
        .auth = .jwt,
        .module = "user",
        .permission = "admin",
    };
    entries[1] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "admin-api/im/ws"),
        .auth = .jwt,
        .module = "im",
        .is_ws = true,
    };
    var catalog = RouteCatalog{ .allocator = alloc, .entries = entries };
    defer catalog.deinit();

    var gen = OpenApi.OpenApiGenerator.init(alloc, "t", "1", "d");
    defer gen.deinit();
    try catalog.exportOpenApi(&gen);
    try std.testing.expectEqual(@as(usize, 2), gen.endpoints.items.len);
    try std.testing.expectEqualStrings("/api/v1/users/{id}", gen.endpoints.items[0].path);
    try std.testing.expectEqual(@as(usize, 1), gen.endpoints.items[0].params.len);
    try std.testing.expectEqualStrings("websocket", gen.endpoints.items[1].description);
}

test "mount records ws_routes in catalog" {
    const AppState = struct {};
    var app: AppState = .{};
    var hits: u32 = 0;
    const WsMod = struct {
        pub const module_name = "im";
        pub const nest = .{"im"};
        pub const State = struct { hits: *u32 };
        fn noopHttp(ctx: *Context, state: *State) !void {
            _ = ctx;
            state.hits.* += 1;
        }
        fn onConnect(_: *Context, _: *anyopaque) ?*anyopaque {
            return null;
        }
        fn onMessage(_: ?*anyopaque, _: []const u8, _: WsFrameKind) void {}
        fn onClose(_: ?*anyopaque) void {}
        pub const routes = [_]RouteSpec(State){
            .{ .method = .GET, .path = "ping", .handler = noopHttp, .meta = .{ .auth = .public } },
        };
        pub const ws_routes = [_]WsSpec(State){
            // `.auth` is mandatory on a WS route and may only be `.public`: there is
            // no enforcement point before the upgrade is answered (§12.14).
            .{ .path = "ws", .on_connect = onConnect, .on_message = onMessage, .on_close = onClose, .meta = .{ .auth = .public } },
        };
    };
    var st = WsMod.State{ .hits = &hits };

    var server = Server.initWithConfig(std.testing.io, std.testing.allocator, .{ .port = 18101 });
    defer server.deinit();
    var router = Router(AppState).init(std.testing.io, std.testing.allocator, &server, &app);
    defer router.deinit();
    var scope = router.scope("/admin-api");
    try scope.mount(WsMod, &st);
    var catalog = try router.finish();
    defer catalog.deinit();

    try std.testing.expectEqual(@as(usize, 2), catalog.entries.len);
    var saw_ws = false;
    for (catalog.entries) |e| {
        if (e.is_ws) {
            saw_ws = true;
            try std.testing.expect(std.mem.endsWith(u8, e.path, "im/ws") or std.mem.eql(u8, e.path, "admin-api/im/ws"));
        }
    }
    try std.testing.expect(saw_ws);
    try std.testing.expect(server.ws_handlers.contains("admin-api/im/ws") or server.ws_handlers.count() == 1);
}

test "catalog allPermissions returns distinct permission expressions" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(CatalogEntry, 3);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/policies"),
        .auth = .jwt,
        .module = "policy",
        .permission = try alloc.dupe(u8, "policy:view"),
    };
    entries[1] = .{
        .method = .POST,
        .path = try alloc.dupe(u8, "api/v1/policies"),
        .auth = .jwt,
        .module = "policy",
        .permission = try alloc.dupe(u8, "policy:write"),
    };
    entries[2] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/policies/{id}"),
        .auth = .jwt,
        .module = "policy",
        .permission = try alloc.dupe(u8, "policy:view"), // duplicate
    };
    var catalog = RouteCatalog{ .allocator = alloc, .entries = entries };
    defer {
        // deinit frees paths only; the permission dupes are test-owned.
        for (entries) |e| alloc.free(e.permission.?);
        catalog.deinit();
    }

    const perms = try catalog.allPermissions(alloc);
    defer alloc.free(perms);
    try std.testing.expectEqual(@as(usize, 2), perms.len);
    try std.testing.expectEqualStrings("policy:view", perms[0]);
    try std.testing.expectEqualStrings("policy:write", perms[1]);
}

test "openApiRoutes generates 3 public UI and spec routes" {
    const State = struct {};
    var slot = CatalogSlot{};
    defer slot.deinit();
    const routes = openApiRoutes(State, &slot, .{ .title = "Test App" });
    try std.testing.expectEqual(@as(usize, 3), routes.len);
    try std.testing.expectEqualStrings("openapi.json", routes[0].path);
    try std.testing.expectEqualStrings("docs", routes[1].path);
    try std.testing.expectEqualStrings("scalar", routes[2].path);
    try std.testing.expect(routes[0].meta.auth == .public);
    try std.testing.expect(routes[1].meta.auth == .public);
    try std.testing.expect(routes[2].meta.auth == .public);
}

test "one process, two servers: each /openapi.json serves its own catalog" {
    const allocator = std.testing.allocator;
    const Testkit = @import("../http/Testkit.zig");

    // Two apps in one binary, each with its own `Router`, `CatalogSlot` and
    // OpenAPI title, registered in production order (`openApiFromCatalog`
    // before the slot is filled). A single process-wide store would make the
    // second registration overwrite the first, so app A's documentation
    // endpoint would answer with app B's catalog — a valid document describing
    // the wrong service, which is why nothing downstream would complain.
    const AppState = struct {};
    const CartApi = struct {
        pub const module_name = "cart";
        pub const nest = .{};
        pub const State = @This();
        pub const routes = [_]RouteSpec(State){
            .{ .method = .GET, .path = "carts", .handler = noop, .meta = .{ .auth = .public } },
        };
        fn noop(ctx: *Context, _: *State) !void {
            try ctx.jsonStruct(200, .{});
        }
    };
    const UserApi = struct {
        pub const module_name = "user";
        pub const nest = .{};
        pub const State = @This();
        pub const routes = [_]RouteSpec(State){
            .{ .method = .GET, .path = "users", .handler = noop, .meta = .{ .auth = .public } },
        };
        fn noop(ctx: *Context, _: *State) !void {
            try ctx.jsonStruct(200, .{});
        }
    };

    var shop_srv = Server.init(std.testing.io, allocator, 0);
    defer shop_srv.deinit();
    var shop_slot: CatalogSlot = .{};
    defer shop_slot.deinit();
    var admin_srv = Server.init(std.testing.io, allocator, 0);
    defer admin_srv.deinit();
    var admin_slot: CatalogSlot = .{};
    defer admin_slot.deinit();

    var shop_state: AppState = .{};
    var shop_mod: CartApi = .{};
    var shop_router = Router(AppState).init(std.testing.io, allocator, &shop_srv, &shop_state);
    defer shop_router.deinit();
    var admin_state: AppState = .{};
    var admin_mod: UserApi = .{};
    var admin_router = Router(AppState).init(std.testing.io, allocator, &admin_srv, &admin_state);
    defer admin_router.deinit();

    // Handlers first (the app registers its docs route while wiring), then the
    // routes, then the catalog slot — same order as the examples.
    try shop_srv.addRoute(.{
        .method = .GET,
        .path = "openapi.json",
        .handler = openApiFromCatalog(&shop_slot, .{ .title = "Shop App" }),
    });
    try admin_srv.addRoute(.{
        .method = .GET,
        .path = "openapi.json",
        .handler = openApiFromCatalog(&admin_slot, .{ .title = "Admin App" }),
    });
    {
        var shop_root = shop_router.scope("");
        try shop_root.mount(CartApi, &shop_mod);
    }
    {
        var admin_root = admin_router.scope("");
        try admin_root.mount(UserApi, &admin_mod);
    }
    shop_slot.set(try shop_router.finish());
    admin_slot.set(try admin_router.finish());

    {
        var resp = try Testkit.dispatch(&shop_srv, .GET, "/openapi.json", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        // The leak, asserted first: this document must not describe the other
        // app. (With a process-wide store it does, and every later assertion
        // would be checking the wrong app's document.)
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "Admin App") == null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "/users") == null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "Shop App") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "/carts") != null);
    }
    {
        var resp = try Testkit.dispatch(&admin_srv, .GET, "/openapi.json", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "Admin App") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "/users") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "Shop App") == null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "/carts") == null);
    }
    // …and back to the first app: a binding overwritten while answering admin
    // shows up right here.
    {
        var resp = try Testkit.dispatch(&shop_srv, .GET, "/openapi.json", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "Shop App") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "/carts") != null);
    }
}

test "wrapHandler captures each handler independently (no shared store)" {
    const State = struct {};
    const S = struct {
        var called: u8 = 0;
        fn h1(_: *Context) anyerror!void {
            called = 1;
        }
        fn h2(_: *Context) anyerror!void {
            called = 2;
        }
    };
    const a1 = wrapHandler(State, S.h1);
    const a2 = wrapHandler(State, S.h2);
    var state = State{};
    // Regression: a runtime `var Store.fn_ptr` was shared by every wrapper of
    // the same State, so all adapters dispatched to the last-stored handler.
    try a1(undefined, &state);
    try std.testing.expectEqual(@as(u8, 1), S.called);
    try a2(undefined, &state);
    try std.testing.expectEqual(@as(u8, 2), S.called);
    try a1(undefined, &state);
    try std.testing.expectEqual(@as(u8, 1), S.called);
}

test "catalog exportOpenApi: RouteMeta annotations replace the permission/auth fallbacks" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(CatalogEntry, 1);
    entries[0] = .{
        .method = .POST,
        .path = try alloc.dupe(u8, "api/v1/users"),
        .auth = .jwt,
        .module = "user",
        .permission = "user:create",
        .summary = "Create a user",
        .description = "Creates a user in the caller's tenant.",
        .request_body = "{\"type\":\"object\",\"required\":[\"email\"]}",
    };
    var catalog = RouteCatalog{ .allocator = alloc, .entries = entries };
    defer catalog.deinit();

    var gen = OpenApi.OpenApiGenerator.init(alloc, "t", "1", "d");
    defer gen.deinit();
    try catalog.exportOpenApi(&gen);
    const json = try gen.generate();
    defer alloc.free(json);

    // summary: the annotation wins over the permission code, which used to be
    // the summary for every gated route.
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"summary\": \"Create a user\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"summary\": \"user:create\"") == null);
    // description: the prose wins over the auth-kind word.
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"description\": \"Creates a user in the caller's tenant.\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\": \"jwt\"") == null);
    // request body: the schema string is emitted verbatim.
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"requestBody\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"content\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"schema\": {\"type\":\"object\",\"required\":[\"email\"]}"));
}

test "catalog exportOpenApi: a public route's description is no longer the auth word when set" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(CatalogEntry, 1);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "health"),
        .auth = .public,
        .module = "system",
        .description = "Liveness probe.",
    };
    var catalog = RouteCatalog{ .allocator = alloc, .entries = entries };
    defer catalog.deinit();

    var gen = OpenApi.OpenApiGenerator.init(alloc, "t", "1", "d");
    defer gen.deinit();
    try catalog.exportOpenApi(&gen);
    const json = try gen.generate();
    defer alloc.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"description\": \"Liveness probe.\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\": \"public\"") == null);
    // The un-annotated public route still says "public".
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"summary\": \"system\""));
}

test "catalog exportOpenApi: ApiParam.description reaches the parameter object" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(CatalogEntry, 1);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/users/{id}"),
        .auth = .jwt,
        .module = "user",
        .openapi_params = &.{
            .{ .name = "fields", .location = .query, .param_type = "string", .description = "Fields to return" },
            .{ .name = "verbose", .location = .query, .param_type = "boolean" },
        },
    };
    var catalog = RouteCatalog{ .allocator = alloc, .entries = entries };
    defer catalog.deinit();

    var gen = OpenApi.OpenApiGenerator.init(alloc, "t", "1", "d");
    defer gen.deinit();
    try catalog.exportOpenApi(&gen);
    const json = try gen.generate();
    defer alloc.free(json);

    // Was dropped on the floor before: the struct carried a description, the
    // emitter never wrote it out.
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        json,
        1,
        "{ \"name\": \"fields\", \"in\": \"query\", \"required\": false, \"schema\": { \"type\": \"string\" }, \"description\": \"Fields to return\" }",
    ));
    // An empty description emits no key at all (that is what keeps un-annotated
    // parameter bytes unchanged).
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        json,
        1,
        "{ \"name\": \"verbose\", \"in\": \"query\", \"required\": false, \"schema\": { \"type\": \"boolean\" } }",
    ));
}

test "mount carries RouteMeta openapi annotations into the catalog" {
    const AppState = struct {};
    const DocMod = struct {
        pub const module_name = "doc";
        pub const nest = .{"doc"};
        pub const State = struct {};
        fn list(_: *Context, _: *State) !void {}
        fn create(_: *Context, _: *State) !void {}
        pub const routes = [_]RouteSpec(State){
            .{ .method = .GET, .path = "items", .handler = list, .meta = .{ .auth = .jwt, .summary = "List items" } },
            .{ .method = .POST, .path = "items", .handler = create, .meta = .{
                .auth = .jwt,
                .description = "Create one item.",
                .request_body = "{\"type\":\"object\"}",
            } },
        };
    };
    var st = DocMod.State{};
    var app: AppState = .{};

    var server = Server.initWithConfig(std.testing.io, std.testing.allocator, .{ .port = 18102 });
    defer server.deinit();
    var router = Router(AppState).init(std.testing.io, std.testing.allocator, &server, &app);
    defer router.deinit();
    var scope = router.scope("/api");
    try scope.mount(DocMod, &st);
    var catalog = try router.finish();
    defer catalog.deinit();

    try std.testing.expectEqual(@as(usize, 2), catalog.entries.len);
    try std.testing.expectEqualStrings("List items", catalog.entries[0].summary.?);
    try std.testing.expect(catalog.entries[0].description == null);
    try std.testing.expectEqualStrings("Create one item.", catalog.entries[1].description.?);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", catalog.entries[1].request_body.?);

    var gen = OpenApi.OpenApiGenerator.init(std.testing.allocator, "t", "1", "d");
    defer gen.deinit();
    try catalog.exportOpenApi(&gen);
    const json = try gen.generate();
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"summary\": \"List items\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"requestBody\""));
}

/// The bytes `exportOpenApi` produced before `RouteMeta.summary` / `.description`
/// / `.request_body` existed, for a catalog where none of them is set. Frozen on
/// purpose: the fallbacks (`permission` → `module`, the per-auth-kind word, no
/// request body at all) must stay output-identical for un-annotated routes.
const unannotated_openapi_golden =
    \\{
    \\  "openapi": "3.0.3",
    \\  "info": {
    \\    "title": "t",
    \\    "version": "1",
    \\    "description": "d"
    \\  },
    \\  "servers": [
    \\    { "url": "/" }
    \\  ],
    \\  "tags": [
    \\    { "name": "user" },
    \\    { "name": "system" },
    \\    { "name": "im" },
    \\    { "name": "order" },
    \\    { "name": "opt" }
    \\  ],
    \\  "paths": {
    \\    "/api/v1/users/{id}": {
    \\      "get": {
    \\        "summary": "user:view",
    \\        "description": "jwt",
    \\        "tags": ["user"],
    \\        "parameters": [
    \\          { "name": "id", "in": "path", "required": true, "schema": { "type": "string" } },
    \\          { "name": "fields", "in": "query", "required": false, "schema": { "type": "string" } },
    \\          { "name": "X-Trace", "in": "header", "required": true, "schema": { "type": "string" } }
    \\        ],
    \\        "security": [ { "bearerAuth": [] } ],
    \\        "responses": {
    \\          "200": { "description": "OK" },
    \\          "401": { "description": "Unauthorized" }
    \\        }
    \\      }
    \\    },
    \\    "/health": {
    \\      "get": {
    \\        "summary": "system",
    \\        "description": "public",
    \\        "tags": ["system"],
    \\        "responses": {
    \\          "200": { "description": "OK" }
    \\        }
    \\      }
    \\    },
    \\    "/im/ws": {
    \\      "get": {
    \\        "summary": "im",
    \\        "description": "websocket",
    \\        "tags": ["im"],
    \\        "responses": {
    \\          "200": { "description": "Switching Protocols" }
    \\        }
    \\      }
    \\    },
    \\    "/optional/ping": {
    \\      "get": {
    \\        "summary": "opt",
    \\        "description": "jwt",
    \\        "tags": ["opt"],
    \\        "security": [ { "bearerAuth": [] } ],
    \\        "responses": {
    \\          "200": { "description": "OK" },
    \\          "401": { "description": "Unauthorized" }
    \\        }
    \\      }
    \\    },
    \\    "/api/v1/users": {
    \\      "post": {
    \\        "summary": "user",
    \\        "description": "jwt",
    \\        "tags": ["user"],
    \\        "security": [ { "bearerAuth": [] } ],
    \\        "responses": {
    \\          "200": { "description": "OK" },
    \\          "401": { "description": "Unauthorized" }
    \\        }
    \\      }
    \\    },
    \\    "/orders/stream": {
    \\      "get": {
    \\        "summary": "order",
    \\        "description": "text/event-stream (SSE)",
    \\        "tags": ["order"],
    \\        "security": [ { "bearerAuth": [] } ],
    \\        "responses": {
    \\          "200": { "description": "text/event-stream" },
    \\          "401": { "description": "Unauthorized" }
    \\        }
    \\      }
    \\    }
    \\  },
    \\  "components": {
    \\    "securitySchemes": {
    \\      "bearerAuth": { "type": "http", "scheme": "bearer", "bearerFormat": "JWT" }
    \\    }
    \\  }
    \\}
++ "\n";

test "catalog exportOpenApi: un-annotated output is byte-identical to the pre-annotation emitter" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(CatalogEntry, 6);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/users/{id}"),
        .auth = .jwt,
        .module = "user",
        .permission = "user:view",
        .openapi_params = &.{
            .{ .name = "fields", .location = .query, .param_type = "string" },
            .{ .name = "X-Trace", .location = .header, .param_type = "string", .required = true },
        },
    };
    entries[1] = .{ .method = .POST, .path = try alloc.dupe(u8, "api/v1/users"), .auth = .jwt, .module = "user" };
    entries[2] = .{ .method = .GET, .path = try alloc.dupe(u8, "health"), .auth = .public, .module = "system" };
    entries[3] = .{ .method = .GET, .path = try alloc.dupe(u8, "im/ws"), .auth = .public, .module = "im", .is_ws = true };
    entries[4] = .{ .method = .GET, .path = try alloc.dupe(u8, "orders/stream"), .auth = .jwt, .module = "order", .is_sse = true, .roles = "admin|ops" };
    entries[5] = .{ .method = .GET, .path = try alloc.dupe(u8, "optional/ping"), .auth = .optional, .module = "opt" };
    var catalog = RouteCatalog{ .allocator = alloc, .entries = entries };
    defer catalog.deinit();

    var gen = OpenApi.OpenApiGenerator.init(alloc, "t", "1", "d");
    defer gen.deinit();
    gen.bearer_auth = true;
    try catalog.exportOpenApi(&gen);
    const json = try gen.generate();
    defer alloc.free(json);

    try std.testing.expectEqualStrings(unannotated_openapi_golden, json);
}
