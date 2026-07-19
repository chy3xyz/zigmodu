const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const service = @import("service.zig");

pub fn PaymentApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service,

        pub fn init(svc: *Service) Self {
            return .{ .service = svc };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            try group.get("/payments", listPayments, @ptrCast(@alignCast(self)));
            try group.post("/payments/charge", charge, @ptrCast(@alignCast(self)));
            try group.get("/payments/status", status, null);
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

        fn listPayments(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const tid = try tenantId(ctx);
            const oid_s = ctx.queryParam("order_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing order_id");
                return;
            };
            const oid = try std.fmt.parseInt(i64, oid_s, 10);
            const rows = self.service.listByOrder(tid, oid) catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list payments");
                return;
            };
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"payments\":[");
            for (rows, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"order_id":{d},"status":"{s}","amount_cents":{d},"idempotency_key":"{s}"}}
                , .{ p.id, p.order_id, p.status, p.amount_cents, p.idempotency_key });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn charge(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
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
            const payment = self.service.charge(.{
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
                \\{{"id":{d},"order_id":{d},"status":"{s}","amount_cents":{d}}}
            , .{ payment.id, payment.order_id, payment.status, payment.amount_cents });
            defer ctx.allocator.free(resp);
            try ctx.json(200, resp);
        }

        fn status(ctx: *http.Context) !void {
            try ctx.json(200, "{\"module\":\"payment\",\"status\":\"ok\"}");
        }
    };
}

pub const DefaultPaymentApi = PaymentApi(service.PaymentService);
