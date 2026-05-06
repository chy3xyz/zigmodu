// delivery service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const delivery_svc = @import("service.zig");

pub const DeliveryServiceExt = struct {
    svc: *delivery_svc.DeliveryService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *delivery_svc.DeliveryService, backend: zigmodu.SqlxBackend) DeliveryServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
