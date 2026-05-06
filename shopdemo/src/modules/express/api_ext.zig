// express custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const express_ext = @import("service_ext.zig");

pub const ExpressApiExt = struct {
    ext: *express_ext.ExpressServiceExt,

    pub fn init(ext: *express_ext.ExpressServiceExt) ExpressApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *ExpressApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/express/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
