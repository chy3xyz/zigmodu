// live custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const live_ext = @import("service_ext.zig");

pub const LiveApiExt = struct {
    ext: *live_ext.LiveServiceExt,

    pub fn init(ext: *live_ext.LiveServiceExt) LiveApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *LiveApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/live/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
