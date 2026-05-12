// order custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const order_ext = @import("service_ext.zig");

pub const OrderApiExt = struct {
    ext: *order_ext.OrderServiceExt,

    pub fn init(ext: *order_ext.OrderServiceExt) OrderApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *OrderApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/order/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
