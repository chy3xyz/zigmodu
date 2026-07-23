// order service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const order_svc = @import("service.zig");

pub const OrderServiceExt = struct {
    svc: *order_svc.OrderService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *order_svc.OrderService, backend: zigmodu.SqlxBackend) OrderServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
