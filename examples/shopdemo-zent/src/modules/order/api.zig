//! HTTP API for the order module. Routes are query-string driven to
//! keep parity with the zent-modulith catalog example; JSON bodies are
//! not used in this minimal smoke test.
const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const service = @import("service.zig");

pub fn OrderApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        svc: *Service,

        pub fn init(svc: *Service) Self {
            return .{ .svc = svc };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            try group.post("/orders", createOrder, @ptrCast(@alignCast(self)));
            try group.get("/orders", listOrders, @ptrCast(@alignCast(self)));
            try group.get("/orders/{order_no}", getOrder, @ptrCast(@alignCast(self)));
            try group.post("/orders/{order_no}/items", addItem, @ptrCast(@alignCast(self)));
        }

        fn createOrder(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const order_no = ctx.queryParam("order_no") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing order_no");
                return;
            };
            const status = ctx.queryParam("status") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing status");
                return;
            };
            const amount_s = ctx.queryParam("amount_cents") orelse "0";
            const user_s = ctx.queryParam("user_id") orelse "0";
            const amount = std.fmt.parseInt(i64, amount_s, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid amount_cents");
                return;
            };
            const user_id = std.fmt.parseInt(i64, user_s, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid user_id");
                return;
            };
            const id = self.svc.createOrder(order_no, status, amount, user_id) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{id});
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }

        fn listOrders(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const rows = self.svc.listOrders() catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            defer self.svc.freeOrders(rows);

            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"orders\":[");
            for (rows, 0..) |r, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"order_no":"{s}","status":"{s}","amount_cents":{d},"user_id":{d}}}
                , .{ r.id, r.order_no, r.status, r.amount_cents, r.user_id });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn getOrder(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const order_no = ctx.param("order_no") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing order_no");
                return;
            };
            const row_opt = self.svc.getOrder(order_no) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(404, 0, "Order not found");
                return;
            };
            defer row.free(ctx.allocator);

            const body = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"order_no":"{s}","status":"{s}","amount_cents":{d},"user_id":{d}}}
            , .{ row.id, row.order_no, row.status, row.amount_cents, row.user_id });
            defer ctx.allocator.free(body);
            try ctx.json(200, body);
        }

        fn addItem(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const order_no = ctx.param("order_no") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing order_no");
                return;
            };
            const sku = ctx.queryParam("sku") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing sku");
                return;
            };
            const qty_s = ctx.queryParam("qty") orelse "0";
            const price_s = ctx.queryParam("unit_price_cents") orelse "0";
            const qty = std.fmt.parseInt(i64, qty_s, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid qty");
                return;
            };
            const unit_price = std.fmt.parseInt(i64, price_s, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid unit_price_cents");
                return;
            };
            const id = self.svc.addItem(order_no, sku, qty, unit_price) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{id});
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }
    };
}

pub const DefaultOrderApi = OrderApi(service.OrderService);
