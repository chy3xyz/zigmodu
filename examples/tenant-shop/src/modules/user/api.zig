const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub fn UserApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service,

        pub const module_name = "user";
        pub const nest = .{"users"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "", .handler = listUsers },
            .{ .method = .POST, .path = "", .handler = createUser },
        };

        pub fn init(svc: *Service) Self {
            return .{ .service = svc };
        }

        fn requireTenantId(ctx: *http.Context) !i64 {
            const tenant_str = ctx.queryParam("tenant_id") orelse ctx.getAttr("tenant_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant_id");
                return error.InvalidInput;
            };
            return std.fmt.parseInt(i64, tenant_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid tenant_id");
                return error.InvalidInput;
            };
        }

        fn listUsers(ctx: *http.Context, self: *State) !void {
            const tenant_id = try requireTenantId(ctx);
            var users_qr = self.service.listByTenant(tenant_id) catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list users");
                return;
            };
            defer users_qr.deinit(ctx.allocator);
            const users = users_qr.items;
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"users\":[");
            for (users, 0..) |u, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"tenant_id":{d},"username":"{s}","role":"{s}"}}
                , .{ u.id, u.tenant_id, u.username, u.role });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn createUser(ctx: *http.Context, self: *State) !void {
            const tenant_id = try requireTenantId(ctx);
            const username = ctx.queryParam("username") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing username");
                return;
            };
            const email = ctx.queryParam("email") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing email");
                return;
            };
            const role = ctx.queryParam("role") orelse "customer";
            const user = self.service.create(tenant_id, username, email, role) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"tenant_id":{d},"username":"{s}","role":"{s}"}}
            , .{ user.id, user.tenant_id, user.username, user.role });
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }
    };
}
