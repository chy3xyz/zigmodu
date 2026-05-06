// shop custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const shop_ext = @import("service_ext.zig");

pub const ShopApiExt = struct {
    ext: *shop_ext.ShopServiceExt,

    pub fn init(ext: *shop_ext.ShopServiceExt) ShopApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *ShopApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/shop/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
