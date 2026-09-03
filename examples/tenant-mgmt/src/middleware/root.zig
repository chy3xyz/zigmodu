const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

/// 租户解析中间件 — 建立请求级租户上下文（attr `tenant_id`）。
///
/// 信任优先级：
///  1. JWT `aud`（由 jwtAuthFromCatalog* 写入 attr）——已验证身份，权威来源；
///  2. `X-Tenant-ID` 头 —— dev / 内部服务回退路径（无 JWT 时）；
///  3. 两者都存在但不一致 → 403（防止携带他租户头越权）。
///
/// 注意：租户 ID 绝不取自 URL query —— 客户端可任意篡改 `?tenant_id=`。
/// 本中间件只建立上下文；需要租户的 handler 用 `requireTenantId(ctx)` 读取。
pub fn tenantMiddleware() http.Middleware {
    return .{
        .func = struct {
            fn handle(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
                const jwt_tenant = ctx.tenantId();
                if (ctx.header("X-Tenant-ID")) |raw| {
                    const header_id = std.fmt.parseInt(i64, raw, 10) catch {
                        try ctx.sendErrorResponse(400, 0, "Invalid X-Tenant-ID");
                        return;
                    };
                    if (header_id <= 0) {
                        try ctx.sendErrorResponse(400, 0, "Invalid X-Tenant-ID");
                        return;
                    }
                    if (jwt_tenant) |jt| {
                        const jwt_id = std.fmt.parseInt(i64, jt, 10) catch {
                            // JWT aud 非数值（门户名等）：不接受 header 覆盖
                            try ctx.sendErrorResponse(403, 0, "X-Tenant-ID not allowed with this token");
                            return;
                        };
                        if (jwt_id != header_id) {
                            try ctx.sendErrorResponse(403, 0, "X-Tenant-ID conflicts with JWT tenant");
                            return;
                        }
                    } else {
                        try ctx.setAttr("tenant_id", raw);
                    }
                }
                try next(ctx);
            }
        }.handle,
    };
}

/// 读取请求租户上下文。缺失/非法时直接写错误响应并返回 error ——
/// handler 用法：`const tenant_id = requireTenantId(ctx) catch return;`
pub fn requireTenantId(ctx: *http.Context) !i64 {
    const raw = ctx.tenantId() orelse {
        try ctx.sendErrorResponse(401, 0, "Missing tenant context (JWT aud or X-Tenant-ID)");
        return error.MissingTenantContext;
    };
    const id = std.fmt.parseInt(i64, raw, 10) catch {
        try ctx.sendErrorResponse(400, 0, "Invalid tenant_id");
        return error.InvalidTenantContext;
    };
    if (id <= 0) {
        try ctx.sendErrorResponse(400, 0, "Invalid tenant_id");
        return error.InvalidTenantContext;
    }
    return id;
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
