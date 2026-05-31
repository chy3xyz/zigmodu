//! Security response headers — HSTS, X-Frame-Options, X-Content-Type-Options, CSP, Referrer-Policy.

const std = @import("std");
const api = @import("../api/Server.zig");

/// Pre-configured security headers for production deployment.
pub const defaultHeaders = [_]Header{
    .{ .name = "Strict-Transport-Security", .value = "max-age=31536000; includeSubDomains" },
    .{ .name = "X-Frame-Options", .value = "DENY" },
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    .{ .name = "Referrer-Policy", .value = "strict-origin-when-cross-origin" },
    .{ .name = "X-Permitted-Cross-Domain-Policies", .value = "none" },
    .{ .name = "X-Download-Options", .value = "noopen" },
    .{ .name = "X-DNS-Prefetch-Control", .value = "off" },
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Middleware that injects security response headers on every response.
pub fn securityHeadersMiddleware(headers: []const Header) api.MiddlewareFn {
    const S = struct {
        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            const hdrs: []const Header = @ptrCast(@alignCast(user_data orelse return error.InternalError));
            for (hdrs) |h| {
                ctx.setHeader(h.name, h.value) catch {};
            }
            try next(ctx, next, user_data);
        }
    };
    return .{ .func = S.handler, .user_data = @constCast(@ptrCast(headers.ptr)) };
}
