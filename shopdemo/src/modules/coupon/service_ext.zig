// coupon service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const coupon_svc = @import("service.zig");

pub const CouponServiceExt = struct {
    svc: *coupon_svc.CouponService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *coupon_svc.CouponService, backend: zigmodu.SqlxBackend) CouponServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
