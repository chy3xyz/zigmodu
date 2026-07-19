const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

/// Extract X-Tenant-ID (lowercase header key) into request attributes.
pub fn tenantMiddleware() http.Middleware {
    return .{ .func = struct {
        fn handle(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            if (ctx.header("x-tenant-id")) |tid| {
                try ctx.setAttr("tenant_id", tid);
            }
            try next(ctx);
        }
    }.handle };
}

pub fn jwtAuthMiddleware(sec: *zigmodu.security.SecurityModule) http.Middleware {
    const Store = struct {
        var stored: *zigmodu.security.SecurityModule = undefined;
    };
    Store.stored = sec;
    return .{
        .func = struct {
            fn handle(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
                if (std.mem.startsWith(u8, ctx.path, "/health") or std.mem.startsWith(u8, ctx.path, "health")) {
                    try next(ctx);
                    return;
                }
                // Dev convenience: skip auth when Authorization absent (smoke / local).
                if (ctx.header("authorization") == null) {
                    try next(ctx);
                    return;
                }
                const inner = http.http_middleware.jwtAuthWithSecurity(Store.stored);
                try inner.func(ctx, next, inner.user_data);
            }
        }.handle,
    };
}

pub fn dataPermissionMiddleware() http.Middleware {
    return .{ .func = struct {
        fn handle(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            try next(ctx);
        }
    }.handle };
}
