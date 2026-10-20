// order service extension — add custom business logic here.
// Survives zmodu regeneration.
const zmodu = @import("zmodu");
const order_svc = @import("service.zig");

pub const OrderServiceExt = struct {
    svc: *order_svc.OrderService,
    backend: zmodu.data.SqlxBackend,

    pub fn init(svc: *order_svc.OrderService, backend: zmodu.data.SqlxBackend) OrderServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
