const std = @import("std");
const api = @import("../api/Server.zig");
const SecurityModule = @import("SecurityModule.zig").SecurityModule;
const Rbac = @import("Rbac.zig");

/// Loads permissions for the authenticated user into `auth.permissions`.
/// Called after JWT verification with `auth.role_ids` already populated.
/// Keys inserted into the map MUST be allocated with `allocator` — they are
/// freed by `AuthInfo.deinit`. Typically backed by a role→permission DB query:
///
///   fn loadPerms(allocator: std.mem.Allocator, auth: *Rbac.AuthInfo) !void {
///       for (auth.role_ids) |rid| {
///           const perms = try db.queryPermissions(rid);
///           for (perms) |p| try auth.permissions.put(try allocator.dupe(u8, p), true);
///       }
///   }
pub const PermissionLoader = *const fn (allocator: std.mem.Allocator, auth: *Rbac.AuthInfo) anyerror!void;

/// JWT authentication middleware — verifies token, builds AuthInfo, stores it in
/// `ctx.auth_info` and `ctx.user_data`.
///
/// **Legacy path** for apps that do not use ComptimeRouter. Prefer
/// `http.jwtAuthFromCatalogWithPermissions` when handlers take state via `user_data`
/// (see `docs/ROUTE_TABLE.md`).
///
/// NOTE: `AuthInfo.permissions` stays empty with this variant, so requirePermission()
/// will always deny. Use `jwtAuthWithPermissions` when permission checks are needed.
pub fn jwtAuth(security: *SecurityModule, allocator: std.mem.Allocator) !api.Middleware {
    const S = struct {
        var stored_security: *SecurityModule = undefined;
        var stored_allocator: std.mem.Allocator = undefined;
    };
    S.stored_security = security;
    S.stored_allocator = allocator;

    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                try runJwtAuth(ctx, next, S.stored_security, S.stored_allocator, null);
            }
        }.mw,
    };
}

/// JWT authentication + RBAC permission loading. Same as `jwtAuth`, but invokes
/// `loader` after token verification to populate `AuthInfo.permissions`, making
/// requirePermission/requireAnyPermission/requireAllPermissions functional.
pub fn jwtAuthWithPermissions(security: *SecurityModule, allocator: std.mem.Allocator, loader: PermissionLoader) !api.Middleware {
    const S = struct {
        var stored_security: *SecurityModule = undefined;
        var stored_allocator: std.mem.Allocator = undefined;
        var stored_loader: PermissionLoader = undefined;
    };
    S.stored_security = security;
    S.stored_allocator = allocator;
    S.stored_loader = loader;

    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                try runJwtAuth(ctx, next, S.stored_security, S.stored_allocator, S.stored_loader);
            }
        }.mw,
    };
}

fn runJwtAuth(
    ctx: *api.Context,
    next: api.HandlerFn,
    security: *SecurityModule,
    allocator: std.mem.Allocator,
    loader: ?PermissionLoader,
) anyerror!void {
    const auth_header = ctx.headers.get("authorization") orelse {
        try ctx.sendErrorResponse(401, 401, "Missing Authorization header");
        return;
    };

    const token = SecurityModule.extractBearerToken(auth_header) orelse {
        try ctx.sendErrorResponse(401, 401, "Invalid Authorization header format");
        return;
    };

    // verifyToken returns JwtPayload directly
    const payload = security.verifyToken(token) catch {
        try ctx.sendErrorResponse(401, 401, "Invalid or expired token");
        return;
    };
    defer security.freePayload(payload);

    // Build AuthInfo from JWT payload. Reject malformed numeric fields.
    const user_id = std.fmt.parseInt(i64, payload.sub, 10) catch {
        try ctx.sendErrorResponse(401, 401, "Invalid token: sub claim is not a valid user ID");
        return;
    };
    const tenant_id = std.fmt.parseInt(i64, payload.aud, 10) catch {
        try ctx.sendErrorResponse(401, 401, "Invalid token: aud claim is not a valid tenant ID");
        return;
    };
    var auth = Rbac.AuthInfo{
        .user_id = user_id,
        .tenant_id = tenant_id,
        .username = allocator.dupe(u8, payload.sub) catch return error.OutOfMemory,
        .role_ids = &.{},
        .permissions = std.StringHashMap(bool).init(allocator),
    };

    // Copy role strings. Reject malformed role IDs.
    if (payload.roles.len > 0) {
        const role_ids = allocator.alloc(i64, payload.roles.len) catch return error.OutOfMemory;
        for (payload.roles, 0..) |role_str, i| {
            role_ids[i] = std.fmt.parseInt(i64, role_str, 10) catch {
                allocator.free(role_ids);
                var partial = auth;
                partial.role_ids = &.{};
                partial.deinit(allocator);
                try ctx.sendErrorResponse(401, 401, "Invalid token: role claim contains non-numeric value");
                return;
            };
        }
        auth.role_ids = role_ids;
    }

    // Store auth for downstream middleware (auth_info) and legacy handlers (user_data).
    const auth_ptr = allocator.create(Rbac.AuthInfo) catch return error.OutOfMemory;
    auth_ptr.* = auth;
    ctx.auth_info = @ptrCast(auth_ptr);
    ctx.user_data = @ptrCast(auth_ptr);
    defer {
        auth_ptr.deinit(allocator);
        allocator.destroy(auth_ptr);
        ctx.auth_info = null;
    }

    // Populate permissions from roles (RBAC) before the handler chain runs.
    if (loader) |load| {
        load(allocator, auth_ptr) catch |err| {
            std.log.err("permission loader failed for user {d}: {s}", .{ user_id, @errorName(err) });
            try ctx.sendErrorResponse(500, 500, "Failed to load permissions");
            return;
        };
    }

    try next(ctx);
}

/// Permission middleware — must run after jwtAuth.
/// `perm` is captured at comptime (use a string literal).
pub fn requirePermission(comptime perm: []const u8) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const auth = getAuth(ctx) orelse {
                    try ctx.sendErrorResponse(403, 403, "Authentication required before permission check");
                    return;
                };

                if (!auth.hasPermission(perm)) {
                    try ctx.sendErrorResponse(403, 403, "Permission denied");
                    return;
                }
                try next(ctx);
            }
        }.mw,
    };
}

/// Require any of the given permissions (comptime list of string literals).
pub fn requireAnyPermission(comptime perms: []const []const u8) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const auth = getAuth(ctx) orelse {
                    try ctx.sendErrorResponse(403, 403, "Authentication required before permission check");
                    return;
                };

                if (!auth.hasAnyPermission(perms)) {
                    try ctx.sendErrorResponse(403, 403, "Permission denied");
                    return;
                }
                try next(ctx);
            }
        }.mw,
    };
}

/// Require all of the given permissions (comptime list of string literals).
pub fn requireAllPermissions(comptime perms: []const []const u8) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const auth = getAuth(ctx) orelse {
                    try ctx.sendErrorResponse(403, 403, "Authentication required before permission check");
                    return;
                };

                if (!auth.hasAllPermissions(perms)) {
                    try ctx.sendErrorResponse(403, 403, "Permission denied");
                    return;
                }
                try next(ctx);
            }
        }.mw,
    };
}

/// [...] ctx.user_data / ctx.auth_info Get current AuthInfo[...] jwtAuth [...]
pub fn getAuth(ctx: *api.Context) ?*Rbac.AuthInfo {
    if (ctx.authInfo(Rbac.AuthInfo)) |a| return a;
    if (ctx.user_data) |data| {
        return @ptrCast(@alignCast(data));
    }
    return null;
}

fn testPutBearerAuth(ctx: *api.Context, token: []const u8) !void {
    const k = try ctx.allocator.dupe(u8, "authorization");
    errdefer ctx.allocator.free(k);
    const v = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{token});
    errdefer ctx.allocator.free(v);
    try ctx.headers.put(k, v);
}

test "jwtAuthWithPermissions loads permissions and passes requirePermission" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "test-secret", 3600);
    const token = try sec.generateTokenWithTenant("42", &.{"7"}, "1");
    defer allocator.free(token);

    var ctx = try api.Context.init(allocator, .GET, "/tenants");
    defer ctx.deinit();
    try testPutBearerAuth(&ctx, token);

    const S = struct {
        var loader_called: bool = false;
        var handler_reached: bool = false;
        var seen_role: i64 = 0;

        fn loadPerms(alloc: std.mem.Allocator, auth: *Rbac.AuthInfo) anyerror!void {
            loader_called = true;
            if (auth.role_ids.len > 0) seen_role = auth.role_ids[0];
            try auth.permissions.put(try alloc.dupe(u8, "tenant:read"), true);
        }

        fn handler(c: *api.Context) anyerror!void {
            const auth = getAuth(c) orelse return error.MissingAuth;
            if (!auth.hasPermission("tenant:read")) return error.PermissionDenied;
            handler_reached = true;
        }
    };

    const auth_mw = try jwtAuthWithPermissions(&sec, allocator, S.loadPerms);

    // Chain: jwtAuthWithPermissions → requirePermission → handler
    const Chain = struct {
        fn permThenHandler(c: *api.Context) anyerror!void {
            const perm_mw = requirePermission("tenant:read");
            try perm_mw.func(c, S.handler, perm_mw.user_data);
        }
    };

    try auth_mw.func(&ctx, Chain.permThenHandler, auth_mw.user_data);

    try std.testing.expect(S.loader_called);
    try std.testing.expectEqual(@as(i64, 7), S.seen_role);
    try std.testing.expect(S.handler_reached);
    try std.testing.expect(!ctx.responded);
}

test "jwtAuth without loader leaves permissions empty (requirePermission denies)" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "test-secret", 3600);
    const token = try sec.generateTokenWithTenant("42", &.{}, "1");
    defer allocator.free(token);

    var ctx = try api.Context.init(allocator, .GET, "/tenants");
    defer ctx.deinit();
    try testPutBearerAuth(&ctx, token);

    const S = struct {
        var denied: bool = false;
        fn checkPerms(c: *api.Context) anyerror!void {
            const auth = getAuth(c) orelse return error.MissingAuth;
            denied = !auth.hasPermission("tenant:read");
        }
    };

    const auth_mw = try jwtAuth(&sec, allocator);
    try auth_mw.func(&ctx, S.checkPerms, auth_mw.user_data);
    try std.testing.expect(S.denied);
}
