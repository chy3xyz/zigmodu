const std = @import("std");
const api = @import("../api/Server.zig");
const SecurityModule = @import("SecurityModule.zig").SecurityModule;
const Rbac = @import("Rbac.zig");

/// JWT authenticationMiddleware — Validation Token [...] AuthInfo [...] ctx.user_data
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
                const auth_header = ctx.headers.get("authorization") orelse {
                    try ctx.sendErrorResponse(401, 401, "Missing Authorization header");
                    return;
                };

                const token = if (std.mem.startsWith(u8, auth_header, "Bearer "))
                    auth_header[7..]
                else
                    auth_header;

                // verifyToken returns JwtPayload directly
                const payload = S.stored_security.verifyToken(token) catch {
                    try ctx.sendErrorResponse(401, 401, "Invalid or expired token");
                    return;
                };

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
                    .username = S.stored_allocator.dupe(u8, payload.sub) catch return error.OutOfMemory,
                    .role_ids = &.{},
                    .permissions = std.StringHashMap(bool).init(S.stored_allocator),
                };

                // Copy role strings. Reject malformed role IDs.
                if (payload.roles.len > 0) {
                    const role_ids = S.stored_allocator.alloc(i64, payload.roles.len) catch return error.OutOfMemory;
                    for (payload.roles, 0..) |role_str, i| {
                        role_ids[i] = std.fmt.parseInt(i64, role_str, 10) catch {
                            try ctx.sendErrorResponse(401, 401, "Invalid token: role claim contains non-numeric value");
                            return;
                        };
                    }
                    auth.role_ids = role_ids;
                }

                // Store auth in context for downstream handlers
                const auth_ptr = S.stored_allocator.create(Rbac.AuthInfo) catch return error.OutOfMemory;
                auth_ptr.* = auth;
                ctx.user_data = @ptrCast(auth_ptr);

                try next(ctx);

                // Cleanup
                auth_ptr.deinit(S.stored_allocator);
                S.stored_allocator.destroy(auth_ptr);
                S.stored_security.freePayload(payload);
            }
        }.mw,
    };
}

/// Permission middleware — must run after jwtAuth.
/// `perm` is captured at comptime (use a string literal).
pub fn requirePermission(comptime perm: []const u8) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const auth = ctx.userData(Rbac.AuthInfo) orelse {
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
                const auth = ctx.userData(Rbac.AuthInfo) orelse {
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
                const auth = ctx.userData(Rbac.AuthInfo) orelse {
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

/// [...] ctx.user_data Get current AuthInfo[...] jwtAuth [...]
pub fn getAuth(ctx: *api.Context) ?*Rbac.AuthInfo {
    if (ctx.user_data) |data| {
        return @ptrCast(@alignCast(data));
    }
    return null;
}
