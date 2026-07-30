const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

/// Storefront BFF — thin orchestration over order + payment services.
pub fn ShopBffApi(comptime OrderService: type, comptime PaymentService: type) type {
    return struct {
        const Self = @This();
        order_svc: *OrderService,
        payment_svc: *PaymentService,

        pub const module_name = "shop_bff";
        pub const nest = .{"shop"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .POST, .path = "checkout", .handler = checkout },
            .{ .method = .POST, .path = "pay", .handler = pay },
            .{ .method = .GET, .path = "status", .handler = status },
        };

        pub fn init(order_svc: *OrderService, payment_svc: *PaymentService) Self {
            return .{ .order_svc = order_svc, .payment_svc = payment_svc };
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

        fn checkout(ctx: *http.Context, self: *State) !void {
            const tid = try tenantId(ctx);
            const uid_s = ctx.queryParam("user_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing user_id");
                return;
            };
            const uid = try std.fmt.parseInt(i64, uid_s, 10);
            const result = self.order_svc.checkout(.{ .tenant_id = tid, .user_id = uid }) catch |err| {
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

        fn pay(ctx: *http.Context, self: *State) !void {
            const tid = try tenantId(ctx);
            const oid_s = ctx.queryParam("order_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing order_id");
                return;
            };
            const key = ctx.queryParam("idempotency_key") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing idempotency_key");
                return;
            };
            const outcome = ctx.queryParam("outcome") orelse "success";
            const success = std.mem.eql(u8, outcome, "success");
            if (!success and !std.mem.eql(u8, outcome, "fail")) {
                try ctx.sendErrorResponse(400, 0, "outcome must be success|fail");
                return;
            }
            const oid = try std.fmt.parseInt(i64, oid_s, 10);
            const payment = self.payment_svc.charge(.{
                .tenant_id = tid,
                .order_id = oid,
                .idempotency_key = key,
                .success = success,
            }) catch |err| {
                const msg = switch (err) {
                    error.NotFound => "Order not found",
                    error.ConstraintViolation => "Inventory adjust failed",
                    error.InvalidInput => "Order not pending or bad input",
                    else => @errorName(err),
                };
                try ctx.sendErrorResponse(400, 0, msg);
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"payment_id":{d},"order_id":{d},"status":"{s}","amount_cents":{d}}}
            , .{ payment.id, payment.order_id, payment.status, payment.amount_cents });
            defer ctx.allocator.free(resp);
            try ctx.json(200, resp);
        }

        fn status(ctx: *http.Context, _: *State) !void {
            try ctx.json(200, "{\"bff\":\"shop\",\"status\":\"ok\"}");
        }
    };
}
