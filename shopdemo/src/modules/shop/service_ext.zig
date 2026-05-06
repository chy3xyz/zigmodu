// shop service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const shop_svc = @import("service.zig");

pub const ShopServiceExt = struct {
    svc: *shop_svc.ShopService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *shop_svc.ShopService, backend: zigmodu.SqlxBackend) ShopServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
