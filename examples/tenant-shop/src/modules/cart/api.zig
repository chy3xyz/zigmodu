const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub fn CartApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service,

        pub const module_name = "cart";
        pub const nest = .{"cart"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "", .handler = listCart },
            .{ .method = .POST, .path = "items", .handler = addItem },
            .{ .method = .DELETE, .path = "", .handler = clearCart },
            .{ .method = .GET, .path = "status", .handler = status },
        };

        pub fn init(svc: *Service) Self {
            return .{ .service = svc };
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

        fn listCart(ctx: *http.Context, self: *State) !void {
            const ids = try requireIds(ctx);
            var items_qr = self.service.listItems(ids.tenant_id, ids.user_id) catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list cart");
                return;
            };
            defer items_qr.deinit(ctx.allocator);
            const items = items_qr.items;
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

        fn addItem(ctx: *http.Context, self: *State) !void {
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

        fn clearCart(ctx: *http.Context, self: *State) !void {
            const ids = try requireIds(ctx);
            self.service.clear(ids.tenant_id, ids.user_id) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            try ctx.json(200, "{\"status\":\"ok\"}");
        }

        fn status(ctx: *http.Context, _: *State) !void {
            try ctx.json(200, "{\"module\":\"cart\",\"status\":\"ok\"}");
        }
    };
}
