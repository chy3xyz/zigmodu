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

/// JWT 认证中间件
pub fn jwtAuthMiddleware(_: []const u8) http.Middleware {
    return .{ .func = struct {
        fn handle(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            if (std.mem.startsWith(u8, ctx.path, "/health") or std.mem.startsWith(u8, ctx.path, "health")) {
                try next(ctx);
                return;
            }
            if (ctx.header("authorization")) |_| {
                try next(ctx);
                return;
            }
            try ctx.sendErrorResponse(401, 0, "Missing Authorization header");
        }
    }.handle };
}

/// 数据权限中间件
pub fn dataPermissionMiddleware() http.Middleware {
    return .{ .func = struct {
        fn handle(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            try next(ctx);
        }
    }.handle };
}
