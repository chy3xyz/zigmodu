// delivery custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const delivery_ext = @import("service_ext.zig");

pub const DeliveryApiExt = struct {
    ext: *delivery_ext.DeliveryServiceExt,

    pub fn init(ext: *delivery_ext.DeliveryServiceExt) DeliveryApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *DeliveryApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/delivery/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
