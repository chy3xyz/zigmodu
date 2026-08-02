//! zmsaas auth — public login route issuing a tenant JWT.
const http = @import("zigmodu").http;
const zigmodu = @import("zigmodu");

pub var g_sec: ?*zigmodu.security.AppSecurity = null;

pub const AuthApi = struct {
    pub const module_name = "auth";
    pub const nest = .{"auth"};
    pub const State = @This();

    pub const routes = [_]http.RouteSpec(State){
        .{ .method = .POST, .path = "login", .handler = login, .meta = .{ .auth = .public } },
    };

    fn login(ctx: *http.Context, _: *State) !void {
        const sec = g_sec orelse return error.NotConfigured;
        const token = try sec.module.generateTokenWithTenant("1", &.{"admin"}, "1");
        defer ctx.allocator.free(token);
        try ctx.jsonStruct(200, .{ .token = token });
    }
};
