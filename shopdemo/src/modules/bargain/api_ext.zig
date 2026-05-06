// bargain custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const bargain_ext = @import("service_ext.zig");

pub const BargainApiExt = struct {
    ext: *bargain_ext.BargainServiceExt,

    pub fn init(ext: *bargain_ext.BargainServiceExt) BargainApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *BargainApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/bargain/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
