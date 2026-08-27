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
    public,
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

            const summary = e.permission orelse e.module;
            const desc: []const u8 = if (e.is_ws)
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
            try gen.addEndpoint(.{
                .method = method,
                .path = oapi_path,
                .summary = summary,
                .description = desc,
                .tags = &.{e.module},
                .params = params_buf[0..param_count],
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

/// Live OpenAPI JSON handler: regenerates from `CatalogSlot` on each request.
/// Register after `catalog_slot.set(try router.finish())`.
/// Runtime backing store for the OpenAPI catalog handler. Hoisted to
/// container level so the handler fn itself stays comptime-known (required by
/// `wrapHandler`); one OpenAPI endpoint per app, so a single store is enough.
/// NOTE: registering `openApiFromCatalog` twice overwrites the first — one
/// catalog slot per application by design (module Gate is app-wide anyway).
const OpenApiRouteStore = struct {
    var catalog_slot: *CatalogSlot = undefined;
    var title: []const u8 = "";
    var version: []const u8 = "";
    var description: []const u8 = "";
    var bearer_auth: bool = true;
};

fn openApiCatalogHandler(ctx: *Context) anyerror!void {
    const cat = OpenApiRouteStore.catalog_slot.get() orelse {
        try ctx.sendError(503, "Route catalog not ready");
        return;
    };
    var gen = OpenApi.OpenApiGenerator.init(ctx.allocator, OpenApiRouteStore.title, OpenApiRouteStore.version, OpenApiRouteStore.description);
    defer gen.deinit();
    gen.bearer_auth = OpenApiRouteStore.bearer_auth;
    try cat.exportOpenApi(&gen);
    const json = try gen.generate();
    defer ctx.allocator.free(json);
    try ctx.setHeader("Content-Type", "application/json");
    try ctx.json(200, json);
}

pub fn openApiFromCatalog(slot: *CatalogSlot, config: OpenApiFromCatalogConfig) HandlerFn {
    OpenApiRouteStore.catalog_slot = slot;
    OpenApiRouteStore.title = config.title;
    OpenApiRouteStore.version = config.version;
    OpenApiRouteStore.description = config.description;
    OpenApiRouteStore.bearer_auth = config.bearer_auth;
    return openApiCatalogHandler;
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
    _ = openApiFromCatalog(slot, config); // fills OpenApiRouteStore at runtime
    return [_]RouteSpec(State){
        .{ .method = .GET, .path = "openapi.json", .handler = wrapHandler(State, openApiCatalogHandler), .meta = .{ .auth = .public } },
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
                        .is_ws = false,
                        .is_sse = true,
                        .openapi_params = spec.meta.openapi_params,
                    });
                }
            }

            if (@hasDecl(Mod, "ws_routes")) {
                inline for (Mod.ws_routes) |spec| {
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

    // Handler wired: match + invoke
    var matched = server.router.match(std.testing.allocator, .GET, "/admin-api/crm/customer/page");
    defer if (matched) |*m| m.deinit(std.testing.allocator);
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
            .{ .path = "ws", .on_connect = onConnect, .on_message = onMessage, .on_close = onClose },
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
