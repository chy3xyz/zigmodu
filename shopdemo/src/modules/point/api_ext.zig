// point custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const point_ext = @import("service_ext.zig");

pub const PointApiExt = struct {
    ext: *point_ext.PointServiceExt,

    pub fn init(ext: *point_ext.PointServiceExt) PointApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *PointApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/point/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
