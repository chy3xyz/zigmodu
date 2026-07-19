const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub fn CartApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service,

        pub fn init(svc: *Service) Self {
            return .{ .service = svc };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            try group.get("/cart", listCart, @ptrCast(@alignCast(self)));
            try group.post("/cart/items", addItem, @ptrCast(@alignCast(self)));
            try group.delete("/cart", clearCart, @ptrCast(@alignCast(self)));
            try group.get("/cart/status", status, null);
        }

        fn requireIds(ctx: *http.Context) !struct { tenant_id: i64, user_id: i64 } {
            const tid_s = ctx.queryParam("tenant_id") orelse ctx.getAttr("tenant_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant_id");
                return error.InvalidInput;
            };
            const uid_s = ctx.queryParam("user_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing user_id");
                return error.InvalidInput;
            };
            return .{
                .tenant_id = try std.fmt.parseInt(i64, tid_s, 10),
                .user_id = try std.fmt.parseInt(i64, uid_s, 10),
            };
        }

        fn listCart(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const ids = try requireIds(ctx);
            const items = self.service.listItems(ids.tenant_id, ids.user_id) catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list cart");
                return;
            };
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"items\":[");
            for (items, 0..) |it, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"product_id":{d},"qty":{d}}}
                , .{ it.product_id, it.qty });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn addItem(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const ids = try requireIds(ctx);
            const pid_s = ctx.queryParam("product_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing product_id");
                return;
            };
            const qty_s = ctx.queryParam("qty") orelse "1";
            const pid = try std.fmt.parseInt(i64, pid_s, 10);
            const qty = try std.fmt.parseInt(i64, qty_s, 10);
            self.service.addItem(ids.tenant_id, ids.user_id, pid, qty) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            try ctx.json(200, "{\"status\":\"ok\"}");
        }

        fn clearCart(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const ids = try requireIds(ctx);
            self.service.clear(ids.tenant_id, ids.user_id) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            try ctx.json(200, "{\"status\":\"ok\"}");
        }

        fn status(ctx: *http.Context) !void {
            try ctx.json(200, "{\"module\":\"cart\",\"status\":\"ok\"}");
        }
    };
}
