const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

/// 租户拦截中间件 — 从请求中提取 X-Tenant-ID 并设置 TenantContext
pub fn tenantMiddleware() http.Middleware {
    return .{ .func = struct {
        fn handle(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            if (ctx.header("X-Tenant-ID")) |_| {
                // 生产环境: 解析并设置 TenantContext
            }
            try next(ctx);
        }
    }.handle };
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

/// 数据权限中间件（可读 ctx.getAttr("module") / ctx.getAttr("permissions")）
pub fn dataPermissionMiddleware() http.Middleware {
    return .{ .func = struct {
        fn handle(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            try next(ctx);
        }
    }.handle };
}
