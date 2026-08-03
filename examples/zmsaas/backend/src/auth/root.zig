//! zmsaas auth — public login route issuing a tenant JWT.
const std = @import("std");
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
        // demo 多角色：login?role=user&uid=42 签发 user 角色（数据权限演示用）。
        const role = ctx.queryStr("role", "admin");
        const uid = ctx.queryInt(i64, "uid", 1);
        const sub_buf = try std.fmt.allocPrint(ctx.allocator, "{d}", .{uid});
        defer ctx.allocator.free(sub_buf);
        const is_admin = std.mem.eql(u8, role, "admin");
        const roles: []const []const u8 = if (is_admin) &.{"admin"} else &.{"user"};
        const token = try sec.module.generateTokenWithTenant(sub_buf, roles, "1");
        defer ctx.allocator.free(token);
        try ctx.jsonStruct(200, .{ .token = token });
    }
};
