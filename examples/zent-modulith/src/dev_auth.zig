//! Dev-only tenant token endpoint for the zent-modulith demo.
//!
//! The products CRUD resolves the tenant from the JWT-derived `tenant_id`
//! attr, so the demo needs a way to obtain a token. This route mints one for
//! whatever `tenant_id` is asked for — i.e. it is a backdoor — so `main.zig`
//! only mounts it when `ZENT_DEV_TOKEN=1` is set. Real deployments must not
//! enable it; issue tokens from a real login flow instead.

const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub fn DevAuthApi(comptime Security: type) type {
    return struct {
        const Self = @This();

        sec: *Security,

        pub const module_name = "devauth";
        pub const nest = .{"dev"};
        pub const State = Self;

        pub fn init(sec: *Security) Self {
            return .{ .sec = sec };
        }

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .POST, .path = "token", .handler = issue, .meta = .{ .auth = .public } },
        };

        fn issue(ctx: *http.Context, self: *State) !void {
            const sub = ctx.queryStr("sub", "1");
            const tenant = ctx.queryStr("tenant_id", "1");
            // Token is allocated by the security module's allocator. It must
            // be freed with that same allocator: ctx.allocator is the
            // per-request arena, whose free() is a no-op — freeing across
            // allocators leaks the token once per mint.
            const token = self.sec.generateTokenWithTenant(sub, &.{"user"}, tenant) catch |err| return http.respondErr(ctx, err);
            defer self.sec.allocator.free(token);
            try ctx.jsonStruct(200, .{ .token = token, .tenant_id = tenant });
        }
    };
}
