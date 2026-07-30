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

/// Optional JWT: skip when Authorization absent (smoke / local).
/// When present, verify via catalog-safe path (attrs only; no `user_data` overwrite).
pub fn jwtAuthMiddleware(sec: *zigmodu.security.SecurityModule, _: *http.CatalogSlot) http.Middleware {
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
                if (std.mem.eql(u8, ctx.path, "/openapi.json") or std.mem.eql(u8, ctx.path, "openapi.json")) {
                    try next(ctx);
                    return;
                }
                // Dev convenience: skip auth when Authorization absent.
                if (ctx.header("authorization") == null) {
                    try next(ctx);
                    return;
                }
                // Token present: require valid JWT (even if route is .public via default_auth).
                const inner = http.http_middleware.jwtAuthWithSecurity(Store.stored);
                try inner.func(ctx, next, inner.user_data);
            }
        }.handle,
    };
}

/// ModuleGate: injects `module` attr from catalog.
pub fn moduleGateMiddleware(slot: *http.CatalogSlot) http.Middleware {
    return http.moduleGate(slot, .{ .unknown = .allow });
}

pub fn dataPermissionMiddleware() http.Middleware {
    return .{ .func = struct {
        fn handle(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            try next(ctx);
        }
    }.handle };
}
