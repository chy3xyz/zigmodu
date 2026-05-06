//! Order service extension — custom business logic (survives regeneration).
//! AI Context: module=order | layer=business extension | extends=service.zig

const std = @import("std");
const zigmodu = @import("zigmodu");
const order_svc = @import("service.zig");
const business = @import("../../business/root.zig");

pub const OrderServiceExt = struct {
    svc: *order_svc.OrderService;
    backend: zigmodu.SqlxBackend;

    pub fn init(svc: *order_svc.OrderService, backend: zigmodu.SqlxBackend) OrderServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    pub fn cancelOrder(self: *OrderServiceExt, order_id: i64) !void {
        const order = try self.svc.getZmoduOrder(order_id) orelse return error.NotFound;
        const s: business.enums.OrderStatus = @enumFromInt(order.order_status);
        if (!business.order_flow.isValidTransition(s, .cancelled)) return error.InvalidTransition;
        var u = order; u.order_status = @intFromEnum(business.enums.OrderStatus.cancelled);
        try self.svc.updateZmoduOrder(u);
        std.log.info("[order] {d} cancelled", .{order_id});
    }

    pub fn confirmReceipt(self: *OrderServiceExt, order_id: i64) !void {
        const order = try self.svc.getZmoduOrder(order_id) orelse return error.NotFound;
        const s: business.enums.OrderStatus = @enumFromInt(order.order_status);
        if (!business.order_flow.isValidTransition(s, .received)) return error.InvalidTransition;
        var u = order; u.order_status = @intFromEnum(business.enums.OrderStatus.received);
        u.receipt_time = @intCast(std.time.timestamp());
        try self.svc.updateZmoduOrder(u);
        std.log.info("[order] {d} receipt confirmed", .{order_id});
    }

    pub fn applyCommission(self: *OrderServiceExt, order_id: i64) !business.commission.CommissionResult {
        const order = try self.svc.getZmoduOrder(order_id) orelse return error.NotFound;
        const r = business.commission.calculate(@floatFromInt(order.total_price), 10, 5, 3);
        std.log.info("[order] {d} commission: total={d:.2}", .{ order_id, r.total });
        return r;
    }
};
