// coupon custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const coupon_ext = @import("service_ext.zig");

pub const CouponApiExt = struct {
    ext: *coupon_ext.CouponServiceExt,

    pub fn init(ext: *coupon_ext.CouponServiceExt) CouponApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *CouponApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/coupon/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
