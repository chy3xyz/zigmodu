//! Lightweight middleware for ZigModu HTTP server.
//!
//! Recommended production middleware chain (order matters):
//!   recover → requestId → cors → jwtAuth → csrf → rateLimit → handler
//!
//! Example:
//!   server.addMiddleware(zigmodu.http_middleware.recover());
//!   server.addMiddleware(zigmodu.http_middleware.requestId());
//!   server.addMiddleware(zigmodu.http_middleware.cors(.{}));
//!   server.addMiddleware(zigmodu.http_middleware.jwtAuth("my-secret"));
//!   // Production (wall-clock exp): share a SecurityModule initialized with initWithIo
//!   server.addMiddleware(zigmodu.http_middleware.jwtAuthWithSecurity(&sec));
//!   server.addMiddleware(zigmodu.http_middleware.csrf());

const std = @import("std");
const api = @import("Server.zig");
const Time = @import("../core/Time.zig");
const SecurityModule = @import("../security/SecurityModule.zig").SecurityModule;

/// CORS middleware configuration
pub const CorsConfig = struct {
    allow_origins: []const []const u8 = &.{"*"},
    allow_methods: []const u8 = "GET,POST,PUT,DELETE,PATCH,HEAD,OPTIONS",
    allow_headers: []const u8 = "Content-Type,Authorization",
    max_age: u32 = 86400,
};

/// CORS middleware — config stored at module scope to avoid heap allocation.
pub fn cors(config: CorsConfig) api.Middleware {
    // Per-instance configuration on `user_data` (allocated once, process
    // lifetime): multiple Servers / registrations with different configs no
    // longer overwrite each other via module-level statics.
    const cfg = std.heap.page_allocator.create(CorsConfig) catch unreachable;
    cfg.* = config;
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const c: *const CorsConfig = @ptrCast(@alignCast(user_data.?));
                // `header()` is case-insensitive (RFC 9110): request header keys are
                // lowercased at parse time, so `ctx.headers.get("Origin")` would never
                // match a browser's `Origin:` header and every origin would be treated
                // as same-origin. Regression test: "cors matches Origin case-insensitively".
                const origin = ctx.header("Origin") orelse "";

                // Validate origin against whitelist; reject if not allowed
                var origin_allowed = false;
                if (std.mem.eql(u8, origin, "")) {
                    origin_allowed = true; // Same-origin request
                } else {
                    for (c.allow_origins) |allowed| {
                        const matched = if (std.mem.eql(u8, allowed, "*")) true else if (std.mem.startsWith(u8, allowed, "*.")) std.mem.endsWith(u8, origin, allowed[1..]) else std.mem.eql(u8, allowed, origin);
                        if (matched) {
                            origin_allowed = true;
                            break;
                        }
                    }
                }

                if (!origin_allowed) {
                    ctx.status_code = 403;
                    ctx.responded = true;
                    return;
                }

                if (c.allow_origins.len > 0 and !std.mem.eql(u8, c.allow_origins[0], "*")) {
                    try ctx.setHeader("Access-Control-Allow-Origin", origin);
                    try ctx.setHeader("Vary", "Origin");
                } else if (c.allow_origins.len > 0) {
                    try ctx.setHeader("Access-Control-Allow-Origin", c.allow_origins[0]);
                }
                try ctx.setHeader("Access-Control-Allow-Methods", c.allow_methods);
                try ctx.setHeader("Access-Control-Allow-Headers", c.allow_headers);
                const max_age_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{c.max_age});
                defer ctx.allocator.free(max_age_str);
                try ctx.setHeader("Access-Control-Max-Age", max_age_str);
                if (ctx.method == .OPTIONS) {
                    ctx.status_code = 204;
                    ctx.responded = true;
                    return;
                }
                try next(ctx);
            }
        }.mw,
        .user_data = cfg,
    };
}

var request_id_counter = std.atomic.Value(u64).init(0);

/// Request ID middleware - adds X-Request-Id header
pub fn requestId() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const id = try std.fmt.allocPrint(ctx.allocator, "{x:0>16}", .{request_id_counter.fetchAdd(1, .monotonic)});
                defer ctx.allocator.free(id);
                try ctx.setHeader("X-Request-Id", id);
                try next(ctx);
            }
        }.mw,
    };
}

/// Logging middleware - logs request method, path, status and duration
pub fn logging() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const start_ms = Time.monotonicNowMilliseconds();
                try next(ctx);
                const elapsed = Time.monotonicNowMilliseconds() - start_ms;
                std.log.info("{s} {s} {d} {d}ms", .{
                    ctx.method.toString(),
                    ctx.raw_path,
                    ctx.status_code,
                    elapsed,
                });
            }
        }.mw,
    };
}

/// Max body size middleware
pub fn maxBodySize(max_size: usize) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const limit = @as(usize, @intFromPtr(user_data));
                if (ctx.body) |body| {
                    if (body.len > limit) {
                        try ctx.sendError(413, "Payload Too Large");
                        return;
                    }
                }
                try next(ctx);
            }
        }.mw,
        .user_data = @ptrFromInt(max_size),
    };
}

/// Request timeout middleware — marks the response 504 when the handler
/// exceeded the budget (post-hoc: fiber-based handlers cannot be preempted).
pub fn requestTimeout(timeout_ms: u64) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const budget_ms: i64 = @intCast(@intFromPtr(user_data));
                const start_ms = Time.monotonicNowMilliseconds();
                try next(ctx);
                if (Time.monotonicNowMilliseconds() - start_ms > budget_ms and !ctx.responded) {
                    ctx.status_code = 504;
                }
            }
        }.mw,
        .user_data = @ptrFromInt(timeout_ms),
    };
}

/// Recovery middleware - catches panics and returns 500
pub fn recover() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                next(ctx) catch |err| {
                    std.log.warn("Handler panic: {any}", .{err});
                    if (!ctx.responded) {
                        try ctx.sendError(500, "Internal Server Error");
                    }
                };
            }
        }.mw,
    };
}

/// JWT auth middleware — validates Bearer token via `SecurityModule.verifyToken`.
/// Uses `ctx.io` for wall-clock expiry when set; falls back to monotonic in unit tests.
///
/// The ephemeral `SecurityModule` here is a zero-allocation struct, so per-request
/// construction is free. The expiry argument is irrelevant for verification (the
/// token's own `exp` claim is checked) — it only matters for token GENERATION,
/// so use `jwtAuthWithSecurity` / `AppSecurity` when you also issue tokens.
pub fn jwtAuth(secret: []const u8) api.Middleware {
    const secret_copy = std.heap.page_allocator.create([]const u8) catch unreachable;
    secret_copy.* = secret;
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const stored: []const u8 = @as(*const []const u8, @ptrCast(@alignCast(user_data.?))).*;
                // Expiry 0: verification-only module, never generates tokens.
                var sec = if (ctx.io) |io|
                    SecurityModule.initWithIo(ctx.allocator, stored, 0, io)
                else
                    SecurityModule.init(ctx.allocator, stored, 0);
                try verifyJwtAndNext(&sec, ctx, next);
            }
        }.mw,
        .user_data = @ptrCast(secret_copy),
    };
}

/// JWT auth using a long-lived `SecurityModule` (prefer `initWithIo` in production).
pub fn jwtAuthWithSecurity(security: *SecurityModule) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                try verifyJwtAndNext(@ptrCast(@alignCast(user_data.?)), ctx, next);
            }
        }.mw,
        .user_data = security,
    };
}

fn verifyJwtAndNext(sec: *SecurityModule, ctx: *api.Context, next: api.HandlerFn) !void {
    try verifyJwtLoadPermsAndNext(sec, ctx, next, null);
}

fn joinCsv(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");
    var total: usize = 0;
    for (parts, 0..) |p, i| {
        total += p.len;
        if (i > 0) total += 1;
    }
    const buf = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0) {
            buf[off] = ',';
            off += 1;
        }
        @memcpy(buf[off..][0..p.len], p);
        off += p.len;
    }
    return buf;
}

/// Input for `CatalogPermissionLoader` — identity + portal roles after JWT verify.
/// Simple loaders (static table / CatalogPermDb) may ignore `sub`/`aud`.
/// Multi-realm apps (e.g. shop/supplier/admin RBAC tables) use them to query per-user grants.
pub const CatalogPermLoadInput = struct {
    /// JWT `sub` (user id string).
    sub: []const u8,
    /// JWT `aud` (tenant / app id string).
    aud: []const u8,
    /// JWT `roles` slice (portal / coarse roles).
    roles: []const []const u8,
};

/// Optional: map identity + JWT roles → fine-grained permission codes (CSV on `permissions` attr).
pub const CatalogPermissionLoader = *const fn (
    allocator: std.mem.Allocator,
    input: CatalogPermLoadInput,
) anyerror![]u8;

fn verifyJwtLoadPermsAndNext(
    sec: *SecurityModule,
    ctx: *api.Context,
    next: api.HandlerFn,
    loader: ?CatalogPermissionLoader,
) !void {
    const auth = ctx.headers.get("authorization") orelse {
        try ctx.sendError(401, "Unauthorized");
        return;
    };
    const token = SecurityModule.extractBearerToken(auth) orelse {
        try ctx.sendError(401, "Unauthorized");
        return;
    };

    const payload = sec.verifyToken(token) catch {
        try ctx.sendError(401, "Unauthorized");
        return;
    };
    defer sec.freePayload(payload);

    try ctx.setAttr("user_id", payload.sub);
    try ctx.setAttr("tenant_id", payload.aud);
    // Comma-separated roles for permissionGate(.roles) and CatalogPermissionLoader.
    if (payload.roles.len > 0) {
        const roles_csv = try joinCsv(ctx.allocator, payload.roles);
        defer ctx.allocator.free(roles_csv);
        try ctx.setAttr("roles", roles_csv);
    } else {
        try ctx.setAttr("roles", "");
    }

    if (loader) |load| {
        const perms_csv = load(ctx.allocator, .{
            .sub = payload.sub,
            .aud = payload.aud,
            .roles = payload.roles,
        }) catch |err| {
            std.log.err("jwt perm loader failed: {s}", .{@errorName(err)});
            try ctx.sendError(500, "Failed to load permissions");
            return;
        };
        defer ctx.allocator.free(perms_csv);
        try ctx.setAttr("permissions", perms_csv);
    }

    try next(ctx);
}

const comptime_router = @import("ComptimeRouter.zig");
const Rbac = @import("../security/Rbac.zig");

pub const JwtFromCatalogConfig = struct {
    skip_prefixes: []const []const u8 = &.{ "health", "dashboard", "openapi.json" },
};

/// JWT that skips when catalog marks the route `.public`, or path matches skip_prefixes.
/// Fill `slot` with `slot.set(try router.finish())` after mounts.
pub fn jwtAuthFromCatalog(security: *SecurityModule, slot: *comptime_router.CatalogSlot, config: JwtFromCatalogConfig) api.Middleware {
    const Store = struct {
        sec: *SecurityModule,
        catalog_slot: *comptime_router.CatalogSlot,
        cfg: JwtFromCatalogConfig,
    };
    const stored = std.heap.page_allocator.create(Store) catch unreachable;
    stored.* = .{ .sec = security, .catalog_slot = slot, .cfg = config };
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const st: *const Store = @ptrCast(@alignCast(user_data.?));
                if (comptime_router.pathHasSkipPrefix(ctx.path, st.cfg.skip_prefixes)) {
                    try next(ctx);
                    return;
                }
                if (st.catalog_slot.get()) |cat| {
                    if (cat.isPublic(ctx.method, ctx.path)) {
                        try next(ctx);
                        return;
                    }
                }
                try verifyJwtLoadPermsAndNext(st.sec, ctx, next, null);
            }
        }.mw,
        .user_data = stored,
    };
}

/// Like `jwtAuthFromCatalog`, but loads fine-grained permissions via `loader`
/// into ctx attr `permissions` (CSV). Does **not** overwrite `ctx.user_data`
/// (safe with ComptimeRouter). Pair with `permissionGateWith(..., .{ .mode = .rbac })`.
pub fn jwtAuthFromCatalogWithPermissions(
    security: *SecurityModule,
    slot: *comptime_router.CatalogSlot,
    loader: CatalogPermissionLoader,
    config: JwtFromCatalogConfig,
) api.Middleware {
    const Store = struct {
        sec: *SecurityModule,
        catalog_slot: *comptime_router.CatalogSlot,
        cfg: JwtFromCatalogConfig,
        load: CatalogPermissionLoader,
    };
    const stored = std.heap.page_allocator.create(Store) catch unreachable;
    stored.* = .{ .sec = security, .catalog_slot = slot, .cfg = config, .load = loader };
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const st: *const Store = @ptrCast(@alignCast(user_data.?));
                if (comptime_router.pathHasSkipPrefix(ctx.path, st.cfg.skip_prefixes)) {
                    try next(ctx);
                    return;
                }
                if (st.catalog_slot.get()) |cat| {
                    if (cat.isPublic(ctx.method, ctx.path)) {
                        try next(ctx);
                        return;
                    }
                }
                try verifyJwtLoadPermsAndNext(st.sec, ctx, next, st.load);
            }
        }.mw,
        .user_data = stored,
    };
}

/// Build a `CatalogPermissionLoader` from a static `RolePermissionTable`.
/// Ignores `sub`/`aud` (role→permission map only).
/// Note: a `CatalogPermissionLoader` is a plain fn (no user_data context), so
/// this keeps a module-level table reference — safe in practice because the
/// table is a process-wide singleton. For multi-instance isolation pass a
/// custom loader closure instead.
pub fn catalogLoaderFromTable(table: *const Rbac.RolePermissionTable) CatalogPermissionLoader {
    const Holder = struct {
        var tbl: *const Rbac.RolePermissionTable = undefined;
        fn load(allocator: std.mem.Allocator, input: CatalogPermLoadInput) anyerror![]u8 {
            return @This().tbl.permissionsCsv(allocator, input.roles);
        }
    };
    Holder.tbl = table;
    return Holder.load;
}

pub const ModuleGateConfig = struct {
    allowed: ?[]const []const u8 = null,
    unknown: enum { allow, deny } = .allow,
    attr_key: []const u8 = "module",
};

/// Resolves catalog module → ctx attr; optional allow-list / deny-unknown.
pub fn moduleGate(slot: *comptime_router.CatalogSlot, config: ModuleGateConfig) api.Middleware {
    const Store = struct {
        catalog_slot: *comptime_router.CatalogSlot,
        cfg: ModuleGateConfig,
    };
    const stored = std.heap.page_allocator.create(Store) catch unreachable;
    stored.* = .{ .catalog_slot = slot, .cfg = config };
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const st: *const Store = @ptrCast(@alignCast(user_data.?));
                const cat = st.catalog_slot.get() orelse {
                    try next(ctx);
                    return;
                };
                if (cat.moduleFor(ctx.path)) |mod| {
                    try ctx.setAttr(st.cfg.attr_key, mod);
                    if (st.cfg.allowed) |allow| {
                        var ok = false;
                        for (allow) |a| {
                            if (std.mem.eql(u8, a, mod)) {
                                ok = true;
                                break;
                            }
                        }
                        if (!ok) {
                            try ctx.sendError(403, "Module not allowed");
                            return;
                        }
                    }
                } else if (st.cfg.unknown == .deny) {
                    if (!comptime_router.pathHasSkipPrefix(ctx.path, &.{ "health", "dashboard", "openapi.json" })) {
                        try ctx.sendError(404, "Unknown route module");
                        return;
                    }
                }
                try next(ctx);
            }
        }.mw,
        .user_data = stored,
    };
}

fn rolesCsvHas(roles_csv: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, roles_csv, ',');
    while (it.next()) |r| {
        const trimmed = std.mem.trim(u8, r, " \t");
        if (trimmed.len > 0 and std.mem.eql(u8, trimmed, want)) return true;
    }
    return false;
}

/// `permission` may be a single code or OR-alternatives separated by `|`.
pub fn permissionMatchesRoles(roles_csv: []const u8, permission: []const u8) bool {
    var alts = std.mem.splitScalar(u8, permission, '|');
    while (alts.next()) |alt| {
        const want = std.mem.trim(u8, alt, " \t");
        if (want.len > 0 and rolesCsvHas(roles_csv, want)) return true;
    }
    return false;
}

pub fn permissionMatchesAuthInfo(auth: *const Rbac.AuthInfo, permission: []const u8) bool {
    var alts = std.mem.splitScalar(u8, permission, '|');
    while (alts.next()) |alt| {
        const want = std.mem.trim(u8, alt, " \t");
        if (want.len > 0 and auth.hasPermission(want)) return true;
    }
    return false;
}

pub const PermissionMode = enum {
    /// Match `RouteMeta.permission` against JWT role names (legacy v1.1).
    roles,
    /// Match against fine-grained permission codes (`permissions` attr and/or AuthInfo).
    rbac,
};

pub const PermissionGateConfig = struct {
    mode: PermissionMode = .roles,
    /// Context attr holding comma-separated JWT roles (set by jwtAuth*).
    role_attr: []const u8 = "roles",
    /// Context attr holding comma-separated permission codes (set by jwtAuthFromCatalogWithPermissions).
    permission_attr: []const u8 = "permissions",
    /// When true, writes matched permission expression to ctx attr `permission`.
    set_permission_attr: bool = true,
    /// When true, routes without a `RouteMeta.permission` are DENIED (403)
    /// instead of passing through. Public routes always pass. Default
    /// `false` = allow-unannotated (current behavior).
    deny_by_default: bool = false,
};

/// Enforces `RouteMeta.permission` (default mode = JWT roles, `|` = OR).
/// Skips public routes and paths without a permission.
pub fn permissionGate(slot: *comptime_router.CatalogSlot) api.Middleware {
    return permissionGateWith(slot, .{});
}

pub fn permissionGateWith(slot: *comptime_router.CatalogSlot, config: PermissionGateConfig) api.Middleware {
    const Store = struct {
        var catalog_slot: *comptime_router.CatalogSlot = undefined;
        var cfg: PermissionGateConfig = .{};
    };
    Store.catalog_slot = slot;
    Store.cfg = config;
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const cat = Store.catalog_slot.get() orelse {
                    try next(ctx);
                    return;
                };
                if (cat.isPublic(ctx.method, ctx.path)) {
                    try next(ctx);
                    return;
                }
                const perm = cat.permissionFor(ctx.method, ctx.path) orelse {
                    if (Store.cfg.deny_by_default) {
                        try ctx.sendError(403, "Forbidden");
                        return;
                    }
                    try next(ctx);
                    return;
                };

                const allowed = switch (Store.cfg.mode) {
                    .roles => blk: {
                        const roles = ctx.getAttr(Store.cfg.role_attr) orelse break :blk false;
                        break :blk permissionMatchesRoles(roles, perm);
                    },
                    .rbac => blk: {
                        if (ctx.authInfo(Rbac.AuthInfo)) |ai| {
                            break :blk permissionMatchesAuthInfo(ai, perm);
                        }
                        const perms = ctx.getAttr(Store.cfg.permission_attr) orelse break :blk false;
                        break :blk permissionMatchesRoles(perms, perm);
                    },
                };
                if (!allowed) {
                    try ctx.sendError(403, "Forbidden");
                    return;
                }
                if (Store.cfg.set_permission_attr) {
                    try ctx.setAttr("permission", perm);
                }
                try next(ctx);
            }
        }.mw,
    };
}

/// CSRF protection using double-submit cookie pattern.
/// GET/HEAD/OPTIONS pass through. State-changing methods require
/// X-CSRF-Token header to match the csrf_token cookie value.
pub fn csrf() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                switch (ctx.method) {
                    .GET, .HEAD, .OPTIONS => return next(ctx),
                    else => {
                        const header_token = ctx.header("x-csrf-token") orelse "";
                        const cookie_header = ctx.header("cookie") orelse "";
                        // Extract csrf_token=... from Cookie header
                        var cookie_match = false;
                        var it = std.mem.splitScalar(u8, cookie_header, ';');
                        while (it.next()) |part| {
                            const trimmed = std.mem.trim(u8, part, " ");
                            if (std.mem.startsWith(u8, trimmed, "csrf_token=")) {
                                const token = trimmed["csrf_token=".len..];
                                if (std.mem.eql(u8, token, header_token) and token.len > 0) {
                                    cookie_match = true;
                                }
                                break;
                            }
                        }
                        if (!cookie_match) {
                            try ctx.sendError(403, "CSRF token mismatch");
                            return;
                        }
                        return next(ctx);
                    },
                }
            }
        }.mw,
    };
}

/// Security response header pair.
pub const SecurityHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Production-grade default security headers (HSTS, frame/type protections,
/// CSP, referrer policy).
pub const defaultSecurityHeaders = [_]SecurityHeader{
    .{ .name = "Strict-Transport-Security", .value = "max-age=31536000; includeSubDomains" },
    .{ .name = "X-Frame-Options", .value = "DENY" },
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    .{ .name = "Referrer-Policy", .value = "strict-origin-when-cross-origin" },
    .{ .name = "X-Permitted-Cross-Domain-Policies", .value = "none" },
    .{ .name = "X-Download-Options", .value = "noopen" },
    .{ .name = "X-DNS-Prefetch-Control", .value = "off" },
};

/// Injects security response headers on every response. `null` uses the
/// built-in defaults; pass a custom slice for a tailored policy.
pub fn securityHeaders(headers: ?[]const SecurityHeader) api.Middleware {
    const S = struct {
        var stored: []const SecurityHeader = &.{};
        fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
            const hdrs: []const SecurityHeader = if (stored.len > 0) stored else &defaultSecurityHeaders;
            for (hdrs) |h| {
                try ctx.setHeader(h.name, h.value);
            }
            try next(ctx);
        }
    };
    S.stored = if (headers) |h| h else &.{};
    return .{ .func = S.mw };
}

test "csrf rejects state-changing requests without a matching token" {
    const allocator = std.testing.allocator;
    const mw = csrf();
    var ctx = try api.Context.init(allocator, .POST, "/api/orders");
    defer ctx.deinit();
    try ctx.headers.put(try allocator.dupe(u8, "cookie"), try allocator.dupe(u8, "csrf_token=abc"));
    try mw.func(&ctx, struct {
        fn h(_: *api.Context) anyerror!void {}
    }.h, null);
    try std.testing.expectEqual(@as(u16, 403), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "csrf allows matching double-submit tokens" {
    const allocator = std.testing.allocator;
    const mw = csrf();
    var ctx = try api.Context.init(allocator, .POST, "/api/orders");
    defer ctx.deinit();
    try ctx.headers.put(try allocator.dupe(u8, "cookie"), try allocator.dupe(u8, "csrf_token=tok123"));
    try ctx.headers.put(try allocator.dupe(u8, "x-csrf-token"), try allocator.dupe(u8, "tok123"));
    const State = struct {
        var reached = false;
    };
    try mw.func(&ctx, struct {
        fn h(_: *api.Context) anyerror!void {
            State.reached = true;
        }
    }.h, null);
    try std.testing.expect(State.reached);
    try std.testing.expectEqual(@as(u16, 200), ctx.status_code);
}

test "securityHeaders injects defaults and calls through" {
    const allocator = std.testing.allocator;
    const mw = securityHeaders(null);
    var ctx = try api.Context.init(allocator, .GET, "/");
    defer ctx.deinit();
    const State = struct {
        var reached = false;
    };
    try mw.func(&ctx, struct {
        fn h(_: *api.Context) anyerror!void {
            State.reached = true;
        }
    }.h, mw.user_data);
    try std.testing.expect(State.reached);
    try std.testing.expect(ctx.response_headers.get("Strict-Transport-Security") != null);
    try std.testing.expect(ctx.response_headers.get("X-Frame-Options") != null);
}

test "cors middleware sets headers" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const cfg = CorsConfig{};
    const mw = cors(cfg);
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqualStrings("*", ctx.response_headers.get("Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("GET,POST,PUT,DELETE,PATCH,HEAD,OPTIONS", ctx.response_headers.get("Access-Control-Allow-Methods").?);
}

test "cors matches Origin case-insensitively (lowercased request headers)" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/api/v1/users");
    defer ctx.deinit();
    // Request header keys are lowercased at parse time; a browser's
    // `Origin:` header arrives with key "origin".
    try ctx.headers.put(try allocator.dupe(u8, "origin"), try allocator.dupe(u8, "https://app.example.com"));

    const mw = cors(.{ .allow_origins = &.{"https://app.example.com"} });
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqualStrings("https://app.example.com", ctx.response_headers.get("Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("Origin", ctx.response_headers.get("Vary").?);
}

test "cors rejects origins outside the allow-list with 403" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/api/v1/users");
    defer ctx.deinit();
    try ctx.headers.put(try allocator.dupe(u8, "origin"), try allocator.dupe(u8, "https://evil.example.com"));

    const mw = cors(.{ .allow_origins = &.{"https://app.example.com"} });
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 403), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "cors instances with different configs stay isolated (no static overwrite)" {
    const allocator = std.testing.allocator;
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    // Register the first instance, then a second with a different whitelist.
    // With the old module-level static storage, mw_b would overwrite mw_a's
    // config and a.example.com would be rejected.
    const mw_a = cors(.{ .allow_origins = &.{"https://a.example.com"} });
    const mw_b = cors(.{ .allow_origins = &.{"https://b.example.com"} });

    var ctx_a = try api.Context.init(allocator, .GET, "/api/v1/users");
    defer ctx_a.deinit();
    try ctx_a.headers.put(try allocator.dupe(u8, "origin"), try allocator.dupe(u8, "https://a.example.com"));
    try mw_a.func(&ctx_a, next, mw_a.user_data);
    try std.testing.expectEqualStrings("https://a.example.com", ctx_a.response_headers.get("Access-Control-Allow-Origin").?);

    var ctx_b = try api.Context.init(allocator, .GET, "/api/v1/users");
    defer ctx_b.deinit();
    try ctx_b.headers.put(try allocator.dupe(u8, "origin"), try allocator.dupe(u8, "https://b.example.com"));
    try mw_b.func(&ctx_b, next, mw_b.user_data);
    try std.testing.expectEqualStrings("https://b.example.com", ctx_b.response_headers.get("Access-Control-Allow-Origin").?);
}

test "maxBodySize middleware rejects large payload" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .POST, "/test");
    defer ctx.deinit();
    ctx.body = "this is a test body that is longer than ten bytes";

    const mw = maxBodySize(10);
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 413), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "recover middleware catches panic" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const mw = recover();
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
            return error.SomePanic;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 500), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "jwtAuth middleware rejects missing authorization" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const mw = jwtAuth("secret");
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

fn putRequestHeader(ctx: *api.Context, key: []const u8, value: []const u8) !void {
    const k = try ctx.allocator.dupe(u8, key);
    errdefer ctx.allocator.free(k);
    const v = try ctx.allocator.dupe(u8, value);
    errdefer ctx.allocator.free(v);
    try ctx.headers.put(k, v);
}

fn putBearerAuth(ctx: *api.Context, token: []const u8) !void {
    const k = try ctx.allocator.dupe(u8, "authorization");
    errdefer ctx.allocator.free(k);
    const v = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{token});
    errdefer ctx.allocator.free(v);
    try ctx.headers.put(k, v);
}

test "jwtAuth middleware accepts valid token" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "secret", 3600);
    const token = try sec.generateToken("user-1", &.{});
    defer allocator.free(token);

    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();
    try putBearerAuth(&ctx, token);

    const S = struct {
        var reached: bool = false;
    };
    S.reached = false;
    const mw = jwtAuth("secret");
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
            S.reached = true;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(S.reached);
    try std.testing.expect(!ctx.responded);
}

test "jwtAuth middleware rejects tampered token" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "secret", 3600);
    const token = try sec.generateToken("user-1", &.{});
    defer allocator.free(token);

    var tampered = try allocator.dupe(u8, token);
    defer allocator.free(tampered);
    if (tampered.len > 10) tampered[tampered.len - 5] +%= 1;

    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();
    try putBearerAuth(&ctx, tampered);

    const mw = jwtAuth("secret");
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "jwtAuth middleware rejects expired token" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "secret", -1);
    const token = try sec.generateToken("user-1", &.{});
    defer allocator.free(token);

    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();
    try putBearerAuth(&ctx, token);

    const mw = jwtAuth("secret");
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "jwtAuthWithSecurity uses wall clock from SecurityModule io" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.initWithIo(allocator, "secret", 3600, std.testing.io);
    const token = try sec.generateToken("user-1", &.{});
    defer allocator.free(token);

    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();
    ctx.io = std.testing.io;
    try putBearerAuth(&ctx, token);

    var reached = false;
    const mw = jwtAuthWithSecurity(&sec);
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    reached = !ctx.responded;
    try std.testing.expect(reached);
}

test "csrf middleware rejects POST without matching token" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .POST, "/test");
    defer ctx.deinit();

    const mw = csrf();
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 403), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "csrf middleware accepts POST with double-submit token" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .POST, "/test");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "x-csrf-token", "abc123");
    try putRequestHeader(&ctx, "cookie", "csrf_token=abc123");

    const S = struct {
        var reached: bool = false;
    };
    S.reached = false;
    const mw = csrf();
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
            S.reached = true;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(S.reached);
    try std.testing.expect(!ctx.responded);
}

test "csrf middleware allows GET without token" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const S = struct {
        var reached: bool = false;
    };
    S.reached = false;
    const mw = csrf();
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
            S.reached = true;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(S.reached);
}

test "jwtAuthFromCatalog skips public and skip_prefixes" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/open"),
        .auth = .public,
        .module = "open",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    var sec = SecurityModule.init(alloc, "test-secret", 3600);
    const mw = jwtAuthFromCatalog(&sec, &slot, .{});
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var pub_ctx = try api.Context.init(alloc, .GET, "/api/v1/open");
    defer pub_ctx.deinit();
    try mw.func(&pub_ctx, next, mw.user_data);
    try std.testing.expect(!pub_ctx.responded);

    var health_ctx = try api.Context.init(alloc, .GET, "/health/live");
    defer health_ctx.deinit();
    try mw.func(&health_ctx, next, mw.user_data);
    try std.testing.expect(!health_ctx.responded);

    var priv_ctx = try api.Context.init(alloc, .GET, "/api/v1/secret");
    defer priv_ctx.deinit();
    try mw.func(&priv_ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), priv_ctx.status_code);
}

test "moduleGate sets attr and can deny unknown" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/users"),
        .auth = .jwt,
        .module = "user",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const mw = moduleGate(&slot, .{ .unknown = .deny });
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var ok_ctx = try api.Context.init(alloc, .GET, "/api/v1/users");
    defer ok_ctx.deinit();
    try mw.func(&ok_ctx, next, mw.user_data);
    try std.testing.expectEqualStrings("user", ok_ctx.getAttr("module").?);

    var bad_ctx = try api.Context.init(alloc, .GET, "/api/v1/nope");
    defer bad_ctx.deinit();
    try mw.func(&bad_ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 404), bad_ctx.status_code);
}

test "permissionGate requires role matching RouteMeta.permission" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .DELETE,
        .path = try alloc.dupe(u8, "api/v1/tenants/{id}"),
        .auth = .jwt,
        .module = "tenant",
        .permission = "admin",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const mw = permissionGate(&slot);
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var deny_ctx = try api.Context.init(alloc, .DELETE, "/api/v1/tenants/1");
    defer deny_ctx.deinit();
    try deny_ctx.setAttr("roles", "user");
    try mw.func(&deny_ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 403), deny_ctx.status_code);

    var allow_ctx = try api.Context.init(alloc, .DELETE, "/api/v1/tenants/1");
    defer allow_ctx.deinit();
    try allow_ctx.setAttr("roles", "user,admin");
    try mw.func(&allow_ctx, next, mw.user_data);
    try std.testing.expect(!allow_ctx.responded);
    try std.testing.expectEqualStrings("admin", allow_ctx.getAttr("permission").?);
}

test "permissionMatchesRoles supports OR alternatives" {
    try std.testing.expect(permissionMatchesRoles("user,owner", "admin|owner"));
    try std.testing.expect(!permissionMatchesRoles("user", "admin|owner"));
    try std.testing.expect(permissionMatchesRoles(" admin ", "admin"));
}

test "permissionGate accepts any OR alternative" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .DELETE,
        .path = try alloc.dupe(u8, "api/v1/tenants/{id}"),
        .auth = .jwt,
        .module = "tenant",
        .permission = "admin|owner",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const mw = permissionGate(&slot);
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var ok_ctx = try api.Context.init(alloc, .DELETE, "/api/v1/tenants/1");
    defer ok_ctx.deinit();
    try ok_ctx.setAttr("roles", "owner");
    try mw.func(&ok_ctx, next, mw.user_data);
    try std.testing.expect(!ok_ctx.responded);
}

test "permissionGate rbac mode uses permissions attr not roles" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .DELETE,
        .path = try alloc.dupe(u8, "api/v1/tenants/{id}"),
        .auth = .jwt,
        .module = "tenant",
        .permission = "tenant:suspend",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const mw = permissionGateWith(&slot, .{ .mode = .rbac });
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    // Has role admin but no permission code → deny
    var deny_ctx = try api.Context.init(alloc, .DELETE, "/api/v1/tenants/1");
    defer deny_ctx.deinit();
    try deny_ctx.setAttr("roles", "admin");
    try deny_ctx.setAttr("permissions", "tenant:read");
    try mw.func(&deny_ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 403), deny_ctx.status_code);

    var allow_ctx = try api.Context.init(alloc, .DELETE, "/api/v1/tenants/1");
    defer allow_ctx.deinit();
    try allow_ctx.setAttr("roles", "user");
    try allow_ctx.setAttr("permissions", "tenant:read,tenant:suspend");
    try mw.func(&allow_ctx, next, mw.user_data);
    try std.testing.expect(!allow_ctx.responded);
    try std.testing.expectEqualStrings("tenant:suspend", allow_ctx.getAttr("permission").?);
}

test "jwtAuthFromCatalogWithPermissions loads permission CSV" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/tenants"),
        .auth = .jwt,
        .module = "tenant",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const table = Rbac.RolePermissionTable{ .rows = &.{
        .{ .role = "admin", .permissions = &.{ Rbac.Permissions.tenant_suspend, Rbac.Permissions.tenant_read } },
    } };
    var sec = SecurityModule.init(alloc, "test-secret", 3600);
    const token = try sec.generateTokenWithTenant("u1", &.{"admin"}, "42");
    defer alloc.free(token);

    const mw = jwtAuthFromCatalogWithPermissions(&sec, &slot, catalogLoaderFromTable(&table), .{});
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var ctx = try api.Context.init(alloc, .GET, "/api/v1/tenants");
    defer ctx.deinit();
    const auth_hdr = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    defer alloc.free(auth_hdr);
    try ctx.headers.put(try alloc.dupe(u8, "authorization"), try alloc.dupe(u8, auth_hdr));
    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(!ctx.responded);
    try std.testing.expectEqualStrings("u1", ctx.getAttr("user_id").?);
    try std.testing.expectEqualStrings("42", ctx.getAttr("tenant_id").?);
    const perms = ctx.getAttr("permissions").?;
    try std.testing.expect(std.mem.indexOf(u8, perms, "tenant:suspend") != null);
}

test "CatalogPermissionLoader receives sub and aud" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "shop/products"),
        .auth = .jwt,
        .module = "shop",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const S = struct {
        var seen_sub: []u8 = &.{};
        var seen_aud: []u8 = &.{};
        var seen_role: []u8 = &.{};
        fn load(allocator: std.mem.Allocator, input: CatalogPermLoadInput) anyerror![]u8 {
            // Copy: payload slices are freed after verify returns.
            if (seen_sub.len > 0) allocator.free(seen_sub);
            if (seen_aud.len > 0) allocator.free(seen_aud);
            if (seen_role.len > 0) allocator.free(seen_role);
            seen_sub = try allocator.dupe(u8, input.sub);
            seen_aud = try allocator.dupe(u8, input.aud);
            seen_role = if (input.roles.len > 0) try allocator.dupe(u8, input.roles[0]) else &.{};
            return try std.fmt.allocPrint(allocator, "portal:shop,shop.product:write@{s}/{s}", .{ input.aud, input.sub });
        }
    };

    var sec = SecurityModule.init(alloc, "test-secret", 3600);
    const token = try sec.generateTokenWithTenant("99", &.{"shop"}, "1001");
    defer alloc.free(token);

    const mw = jwtAuthFromCatalogWithPermissions(&sec, &slot, S.load, .{});
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var ctx = try api.Context.init(alloc, .GET, "/shop/products");
    defer ctx.deinit();
    const auth_hdr = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    defer alloc.free(auth_hdr);
    try ctx.headers.put(try alloc.dupe(u8, "authorization"), try alloc.dupe(u8, auth_hdr));
    try mw.func(&ctx, next, mw.user_data);
    defer {
        if (S.seen_sub.len > 0) alloc.free(S.seen_sub);
        if (S.seen_aud.len > 0) alloc.free(S.seen_aud);
        if (S.seen_role.len > 0) alloc.free(S.seen_role);
    }
    try std.testing.expectEqualStrings("99", S.seen_sub);
    try std.testing.expectEqualStrings("1001", S.seen_aud);
    try std.testing.expectEqualStrings("shop", S.seen_role);
    const perms = ctx.getAttr("permissions").?;
    try std.testing.expect(std.mem.indexOf(u8, perms, "1001/99") != null);
}
