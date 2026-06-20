const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub fn UserApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service,

        pub fn init(svc: *Service) Self { return .{ .service = svc }; }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            try group.get("/users", listUsers, @ptrCast(@alignCast(self)));
            try group.post("/users", createUser, @ptrCast(@alignCast(self)));
            try group.get("/users/{id}", getUser, @ptrCast(@alignCast(self)));
        }

        fn listUsers(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));
            const tenant_str = ctx.queryParam("tenant_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing 'tenant_id' query parameter");
                return;
            };
            const tenant_id = std.fmt.parseInt(i64, tenant_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid tenant_id");
                return;
            };

            const users = self.service.listByTenant(tenant_id) catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list users");
                return;
            };

            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"users\":[");
            for (users, 0..) |u, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"tenant_id":{d},"username":"{s}","email":"{s}","role":"{s}"}}
                , .{ u.id, u.tenant_id, u.username, u.email, u.role });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn createUser(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));
            const tenant_id_str = ctx.queryParam("tenant_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant_id"); return;
            };
            const tenant_id = std.fmt.parseInt(i64, tenant_id_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid tenant_id"); return;
            };
            const username = ctx.queryParam("username") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing username"); return;
            };
            const email = ctx.queryParam("email") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing email"); return;
            };
            const role = ctx.queryParam("role") orelse "member";

            const user = self.service.create(tenant_id, username, email, role) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err)); return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"tenant_id":{d},"username":"{s}","role":"{s}"}}
            , .{ user.id, user.tenant_id, user.username, user.role });
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }

        fn getUser(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));
            const tenant_str = ctx.queryParam("tenant_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant_id"); return;
            };
            const tenant_id = std.fmt.parseInt(i64, tenant_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid tenant_id"); return;
            };
            const id_str = ctx.param("id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing user ID"); return;
            };
            const user_id = std.fmt.parseInt(i64, id_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid user ID"); return;
            };
            const user = self.service.getById(tenant_id, user_id) catch |err| {
                try ctx.sendErrorResponse(404, 0, @errorName(err)); return;
            } orelse {
                try ctx.sendErrorResponse(404, 0, "User not found"); return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"tenant_id":{d},"username":"{s}","email":"{s}","role":"{s}","status":{d}}}
            , .{ user.id, user.tenant_id, user.username, user.email, user.role, user.status });
            defer ctx.allocator.free(resp);
            try ctx.json(200, resp);
        }
    };
}
