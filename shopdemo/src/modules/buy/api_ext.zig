// buy custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const buy_ext = @import("service_ext.zig");

pub const BuyApiExt = struct {
    ext: *buy_ext.BuyServiceExt,

    pub fn init(ext: *buy_ext.BuyServiceExt) BuyApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *BuyApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/buy/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
