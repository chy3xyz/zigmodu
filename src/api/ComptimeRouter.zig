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
pub const WsConnectFn = server_mod.WsConnectFn;
pub const WsMessageFn = server_mod.WsMessageFn;
pub const WsCloseFn = server_mod.WsCloseFn;

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
    /// ModuleGate name; null → module's `module_name`.
    module: ?[]const u8 = null,
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
    is_ws: bool = false,
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

            var params_buf: [8]OpenApi.ApiParam = undefined;
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
            else if (e.auth == .public)
                "public"
            else
                "jwt";
            try gen.addEndpoint(.{
                .method = method,
                .path = oapi_path,
                .summary = summary,
                .description = desc,
                .tags = &.{e.module},
                .params = params_buf[0..param_count],
                .responses = &.{
                    .{ .status_code = 200, .description = if (e.is_ws) "Switching Protocols" else "OK" },
                    .{ .status_code = 401, .description = "Unauthorized" },
                },
            });
        }
    }
};

pub const OpenApiFromCatalogConfig = struct {
    title: []const u8,
    version: []const u8 = "1.0.0",
    description: []const u8 = "",
};

/// Live OpenAPI JSON handler: regenerates from `CatalogSlot` on each request.
/// Register after `catalog_slot.set(try router.finish())`.
pub fn openApiFromCatalog(slot: *CatalogSlot, config: OpenApiFromCatalogConfig) HandlerFn {
    const Store = struct {
        var catalog_slot: *CatalogSlot = undefined;
        var title: []const u8 = "";
        var version: []const u8 = "";
        var description: []const u8 = "";
    };
    Store.catalog_slot = slot;
    Store.title = config.title;
    Store.version = config.version;
    Store.description = config.description;
    return struct {
        fn handle(ctx: *Context) anyerror!void {
            const cat = Store.catalog_slot.get() orelse {
                try ctx.sendError(503, "Route catalog not ready");
                return;
            };
            var gen = OpenApi.OpenApiGenerator.init(ctx.allocator, Store.title, Store.version, Store.description);
            defer gen.deinit();
            try cat.exportOpenApi(&gen);
            const json = try gen.generate();
            defer ctx.allocator.free(json);
            try ctx.setHeader("Content-Type", "application/json");
            try ctx.json(200, json);
        }
    }.handle;
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
        @setEvalBranchQuota(100_000);
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

        const Self = @This();

        /// Mount one modulith HTTP module: expands `Mod.routes` / optional `ws_routes`.
        pub fn mount(self: *Self, comptime Mod: type, state: *Mod.State) !void {
            validateModule(Mod);
            const nest_path = comptime joinNestComptime(Mod.nest);
            const base = try joinPaths(self.router.allocator, &.{ self.prefix, nest_path });
            defer self.router.allocator.free(base);

            var group = self.router.server.group(base);
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
                    .is_ws = false,
                });
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
        fn onMessage(_: ?*anyopaque, _: []const u8) void {}
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
