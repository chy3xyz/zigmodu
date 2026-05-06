// buy service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const buy_svc = @import("service.zig");

pub const BuyServiceExt = struct {
    svc: *buy_svc.BuyService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *buy_svc.BuyService, backend: zigmodu.SqlxBackend) BuyServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
