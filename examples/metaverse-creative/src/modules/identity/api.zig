const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const service = @import("service.zig");

pub fn IdentityApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        svc: *Service,

        pub fn init(svc: *Service) Self {
            return .{ .svc = svc };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            try group.post("/creators", createCreator, @ptrCast(@alignCast(self)));
            try group.get("/creators", getCreator, @ptrCast(@alignCast(self)));
        }

        fn createCreator(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const did = ctx.queryParam("did") orelse {
                try ctx.json(400, "{\"error\":\"missing did\"}");
                return;
            };
            const name = ctx.queryParam("name") orelse {
                try ctx.json(400, "{\"error\":\"missing name\"}");
                return;
            };
            const wallet = ctx.queryParam("wallet") orelse {
                try ctx.json(400, "{\"error\":\"missing wallet\"}");
                return;
            };
            self.svc.registerCreator(did, name, wallet) catch |err| {
                try ctx.json(400, try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}));
                return;
            };
            try ctx.json(201, "{\"ok\":true}");
        }

        fn getCreator(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const did = ctx.queryParam("did") orelse {
                try ctx.json(400, "{\"error\":\"missing did\"}");
                return;
            };
            const c = (try self.svc.getCreator(did)) orelse {
                try ctx.json(404, "{\"error\":\"not found\"}");
                return;
            };
            defer self.svc.freeCreator(c);
            const body = try std.fmt.allocPrint(ctx.allocator,
                \\{{"did":"{s}","display_name":"{s}","reputation":{d},"verified":{s}}}
            , .{ c.did, c.display_name, c.reputation, if (c.verified) "true" else "false" });
            defer ctx.allocator.free(body);
            try ctx.json(200, body);
        }
    };
}
