const std = @import("std");
const api = @import("../api/Server.zig");
const SecurityModule = @import("SecurityModule.zig");
const Rbac = @import("Rbac.zig");

/// JWT 认证中间件 — 验证 Token 并将 AuthInfo 挂载到 ctx.user_data
pub fn jwtAuth(security: *SecurityModule, allocator: std.mem.Allocator) !api.Middleware {
    const ctx_ptr = allocator.create(struct {
        security: *SecurityModule,
        allocator: std.mem.Allocator,
    }) catch return error.OutOfMemory;
    ctx_ptr.* = .{ .security = security, .allocator = allocator };

    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const self = @as(*struct { security: *SecurityModule, allocator: std.mem.Allocator }, @ptrCast(@alignCast(user_data.?)));

                const auth_header = ctx.headers.get("Authorization") orelse {
                    try ctx.sendErrorResponse(401, 401, "Missing Authorization header");
                    return;
                };

                const token = if (std.mem.startsWith(u8, auth_header, "Bearer "))
                    auth_header[7..]
                else
                    auth_header;

                // verifyToken returns JwtPayload directly
                const payload = self.security.verifyToken(token) catch {
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
                    .username = self.allocator.dupe(u8, payload.sub) catch return error.OutOfMemory,
                    .role_ids = &.{},
                };

                // Copy role strings. Reject malformed role IDs.
                if (payload.roles.len > 0) {
                    const role_ids = self.allocator.alloc(i64, payload.roles.len) catch return error.OutOfMemory;
                    for (payload.roles, 0..) |role_str, i| {
                        role_ids[i] = std.fmt.parseInt(i64, role_str, 10) catch {
                            try ctx.sendErrorResponse(401, 401, "Invalid token: role claim contains non-numeric value");
                            return;
                        };
                    }
                    auth.role_ids = role_ids;
                }

                // Store auth in context for downstream handlers
                const auth_ptr = self.allocator.create(Rbac.AuthInfo) catch return error.OutOfMemory;
                auth_ptr.* = auth;
                ctx.user_data = @ptrCast(auth_ptr);

                try next(ctx);

                // Cleanup
                auth_ptr.deinit(self.allocator);
                self.allocator.destroy(auth_ptr);
                self.security.freePayload(payload);
            }
        }.mw,
        .user_data = @ptrCast(ctx_ptr),
    };
}

/// 权限校验中间件 — 要求单一权限
/// 需在 jwtAuth 之后使用
pub fn requirePermission(perm: []const u8) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const required = @as([]const u8, @ptrCast(@alignCast(user_data.?)));
                const auth: *Rbac.AuthInfo = @ptrCast(@alignCast(ctx.user_data orelse {
                    try ctx.sendErrorResponse(403, 403, "Authentication required before permission check");
                    return;
                }));

                if (!auth.hasPermission(required)) {
                    try ctx.sendErrorResponse(403, 403, "Permission denied");
                    return;
                }
                try next(ctx);
            }
        }.mw,
        .user_data = @constCast(@ptrCast(perm.ptr)),
    };
}

/// 权限校验 — 满足任一即可
pub fn requireAnyPermission(perms: []const []const u8) !api.Middleware {
    const perms_copy = std.heap.page_allocator.dupe([]const u8, perms) catch return error.OutOfMemory;
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const required = @as([]const []const u8, @ptrCast(@alignCast(user_data.?)));
                const auth: *Rbac.AuthInfo = @ptrCast(@alignCast(ctx.user_data orelse {
                    try ctx.sendErrorResponse(403, 403, "Authentication required before permission check");
                    return;
                }));

                if (!auth.hasAnyPermission(required)) {
                    try ctx.sendErrorResponse(403, 403, "Permission denied");
                    return;
                }
                try next(ctx);
            }
        }.mw,
        .user_data = @constCast(@ptrCast(perms_copy.ptr)),
    };
}

/// 权限校验 — 全部满足
pub fn requireAllPermissions(perms: []const []const u8) !api.Middleware {
    const perms_copy = std.heap.page_allocator.dupe([]const u8, perms) catch return error.OutOfMemory;
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const required = @as([]const []const u8, @ptrCast(@alignCast(user_data.?)));
                const auth: *Rbac.AuthInfo = @ptrCast(@alignCast(ctx.user_data orelse {
                    try ctx.sendErrorResponse(403, 403, "Authentication required before permission check");
                    return;
                }));

                if (!auth.hasAllPermissions(required)) {
                    try ctx.sendErrorResponse(403, 403, "Permission denied");
                    return;
                }
                try next(ctx);
            }
        }.mw,
        .user_data = @constCast(@ptrCast(perms_copy.ptr)),
    };
}

/// 从 ctx.user_data 获取当前 AuthInfo（如果 jwtAuth 已执行）
pub fn getAuth(ctx: *api.Context) ?*Rbac.AuthInfo {
    if (ctx.user_data) |data| {
        return @ptrCast(@alignCast(data));
    }
    return null;
}
