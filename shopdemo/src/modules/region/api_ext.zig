// region custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const region_ext = @import("service_ext.zig");

pub const RegionApiExt = struct {
    ext: *region_ext.RegionServiceExt,

    pub fn init(ext: *region_ext.RegionServiceExt) RegionApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *RegionApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/region/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
