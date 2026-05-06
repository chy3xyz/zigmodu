// plus custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const plus_ext = @import("service_ext.zig");

pub const PlusApiExt = struct {
    ext: *plus_ext.PlusServiceExt,

    pub fn init(ext: *plus_ext.PlusServiceExt) PlusApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *PlusApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/plus/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
