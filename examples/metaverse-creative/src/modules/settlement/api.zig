const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const service = @import("service.zig");

pub fn SettlementApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        svc: *Service,

        pub fn init(svc: *Service) Self {
            return .{ .svc = svc };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            try group.post("/purchase", purchase, @ptrCast(@alignCast(self)));
            try group.get("/reconcile", reconcile, @ptrCast(@alignCast(self)));
            try group.post("/outbox/drain", drain, @ptrCast(@alignCast(self)));
        }

        fn purchase(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const key = ctx.queryParam("idempotency_key") orelse {
                try ctx.json(400, "{\"error\":\"missing idempotency_key\"}");
                return;
            };
            const cid = try std.fmt.parseInt(i64, ctx.queryParam("creative_id") orelse "0", 10);
            const buyer = ctx.queryParam("buyer_did") orelse {
                try ctx.json(400, "{\"error\":\"missing buyer_did\"}");
                return;
            };
            const license = ctx.queryParam("license") orelse "personal";
            const r = self.svc.purchase(.{
                .idempotency_key = key,
                .creative_id = cid,
                .buyer_did = buyer,
                .license = license,
            }) catch |err| {
                try ctx.json(400, try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}));
                return;
            };
            const body = try std.fmt.allocPrint(ctx.allocator,
                \\{{"payment_id":{d},"transfer_id":{d},"sale_id":{d},"amount_cents":{d},"platform_fee_cents":{d},"seller_net_cents":{d},"replay":{s}}}
            , .{ r.payment_id, r.transfer_id, r.sale_id, r.amount_cents, r.platform_fee_cents, r.seller_net_cents, if (r.idempotent_replay) "true" else "false" });
            defer ctx.allocator.free(body);
            try ctx.json(201, body);
        }

        fn reconcile(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const r = try self.svc.reconcile();
            const body = try std.fmt.allocPrint(ctx.allocator,
                \\{{"ledger_sum_cents":{d},"succeeded_payments":{d},"transfers":{d},"pending_outbox":{d},"balanced":{s}}}
            , .{ r.ledger_sum_cents, r.succeeded_payments, r.transfers, r.pending_outbox, if (r.balanced) "true" else "false" });
            defer ctx.allocator.free(body);
            try ctx.json(200, body);
        }

        fn drain(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const n = try self.svc.drainOutbox();
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"published\":{d}}}", .{n});
            defer ctx.allocator.free(body);
            try ctx.json(200, body);
        }
    };
}
