const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

/// 租户拦截中间件 — 从请求中提取 X-Tenant-ID 并设置 TenantContext
pub fn tenantMiddleware() http.Middleware {
    return .{
        .func = struct {
            fn handle(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
                if (ctx.header("X-Tenant-ID")) |_| {
                    // 生产环境: 解析并设置 TenantContext
                }
                try next(ctx);
            }
        }.handle,
    };
}

/// JWT + SQLite role→permission (`CatalogPermDb`) into `permissions` attr.
pub fn jwtAuthMiddleware(
    sec: *zigmodu.security.SecurityModule,
    slot: *http.CatalogSlot,
    db: *zigmodu.data.Client,
) http.Middleware {
    return http.jwtAuthFromCatalogWithPermissions(
        sec,
        slot,
        zigmodu.security.CatalogPermDb.loaderFromClient(db),
        .{},
    );
}

/// ModuleGate: injects `module` attr from catalog; unknown paths allowed (API may 404 later).
pub fn moduleGateMiddleware(slot: *http.CatalogSlot) http.Middleware {
    return http.moduleGate(slot, .{ .unknown = .allow });
}

/// PermissionGate (RBAC): `RouteMeta.permission` must appear in loaded permission codes.
pub fn permissionGateMiddleware(slot: *http.CatalogSlot) http.Middleware {
    return http.permissionGateWith(slot, .{ .mode = .rbac });
}

/// 数据权限中间件（统一下沉）：从 JWT attrs（roles/user_id）解析数据作用域，
/// 写入 `data_scope` attr（"all" | "self"）。所有 handler 统一消费该 attr，
/// 不再各自从 roles 推导——角色→作用域的决策只在这里做一次。
pub fn dataPermissionMiddleware() http.Middleware {
    return .{ .func = struct {
        fn handle(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            const roles_csv = ctx.getAttr("roles") orelse "";
            const scope: []const u8 = if (std.mem.indexOf(u8, roles_csv, "admin") != null) "all" else "self";
            try ctx.setAttr("data_scope", scope);
            try next(ctx);
        }
    }.handle };
}
