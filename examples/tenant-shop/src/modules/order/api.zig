const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const service = @import("service.zig");

pub fn OrderApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service,

        pub const module_name = "order";
        pub const nest = .{"orders"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "", .handler = listOrders },
            .{ .method = .POST, .path = "checkout", .handler = checkout },
            .{ .method = .GET, .path = "status", .handler = status },
        };

        pub fn init(svc: *Service) Self {
            return .{ .service = svc };
        }

        fn tenantId(ctx: *http.Context) !i64 {
            const s = ctx.queryParam("tenant_id") orelse ctx.getAttr("tenant_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant_id");
                return error.InvalidInput;
            };
            return std.fmt.parseInt(i64, s, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid tenant_id");
                return error.InvalidInput;
            };
        }

        fn listOrders(ctx: *http.Context, self: *State) !void {
            const tid = try tenantId(ctx);
            var orders_qr = self.service.listByTenant(tid) catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list orders");
                return;
            };
            defer orders_qr.deinit(ctx.allocator);
            const orders = orders_qr.items;
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"orders\":[");
            for (orders, 0..) |o, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"user_id":{d},"status":"{s}","total_cents":{d}}}
                , .{ o.id, o.user_id, o.status, o.total_cents });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn checkout(ctx: *http.Context, self: *State) !void {
            const tid = try tenantId(ctx);
            const uid_s = ctx.queryParam("user_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing user_id");
                return;
            };
            const uid = try std.fmt.parseInt(i64, uid_s, 10);
            const result = self.service.checkout(.{ .tenant_id = tid, .user_id = uid }) catch |err| {
                const msg = switch (err) {
                    error.NotFound => "Cart or product not found",
                    error.ConstraintViolation => "Insufficient stock",
                    error.InvalidInput => "Cart empty or invalid",
                    else => @errorName(err),
                };
                try ctx.sendErrorResponse(400, 0, msg);
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"order_id":{d},"status":"pending"}}
            , .{result.order_id});
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }

        fn status(ctx: *http.Context, _: *State) !void {
            try ctx.json(200, "{\"module\":\"order\",\"status\":\"ok\"}");
        }
    };
}

pub const DefaultOrderApi = OrderApi(service.OrderService);
