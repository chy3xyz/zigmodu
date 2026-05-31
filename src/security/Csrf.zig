//! CSRF protection — double-submit cookie pattern for stateless APIs.
//!
//! Usage:
//!   var csrf = CsrfProtection.init(csprng);
//!   server.addMiddleware(csrf.middleware());

const std = @import("std");
const api = @import("../api/Server.zig");

pub const CsrfProtection = struct {
    const TOKEN_LEN = 32;

    /// CSRF token as hex string (64 chars).
    token: [TOKEN_LEN * 2]u8,

    pub fn init(io: std.Io) CsrfProtection {
        var token_bytes: [TOKEN_LEN]u8 = undefined;
        std.Random.DefaultCsprng.init(io).fill(&token_bytes);
        var token: [TOKEN_LEN * 2]u8 = undefined;
        _ = std.fmt.bufPrint(&token, "{s}", .{std.fmt.fmtSliceHexLower(&token_bytes)}) catch unreachable;
        return .{ .token = token };
    }

    /// Returns middleware that enforces CSRF on state-changing methods.
    pub fn middleware(self: *CsrfProtection) api.MiddlewareFn {
        const S = struct {
            fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const csrf: *CsrfProtection = @ptrCast(@alignCast(user_data orelse return error.InternalError));

                // Only validate state-changing methods
                switch (ctx.method) {
                    .POST, .PUT, .DELETE, .PATCH => {
                        const header_token = ctx.getHeader("X-CSRF-Token") orelse "";
                        const cookie_token = ctx.getHeader("X-CSRF-Cookie") orelse header_token;

                        if (!std.mem.eql(u8, csrf.token[0..], header_token) and
                            !std.mem.eql(u8, csrf.token[0..], cookie_token))
                        {
                            ctx.status_code = 403;
                            ctx.setHeader("Content-Type", "application/json") catch {};
                            _ = ctx.stream.?.writer(ctx.io.?, &.{}{}).interface.writeAll(
                                "{\"code\":403,\"msg\":\"CSRF validation failed\"}",
                            ) catch {};
                            ctx.responded = true;
                            return;
                        }
                    },
                    else => {},
                }

                // Set CSRF cookie on every response
                ctx.setHeader("X-CSRF-Token", csrf.token[0..]) catch {};
                try next(ctx, next, user_data);
            }
        };
        return .{ .func = S.handler, .user_data = @ptrCast(@constCast(self)) };
    }
};
