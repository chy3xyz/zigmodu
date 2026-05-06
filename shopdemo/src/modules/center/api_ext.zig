// center custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const center_ext = @import("service_ext.zig");

pub const CenterApiExt = struct {
    ext: *center_ext.CenterServiceExt,

    pub fn init(ext: *center_ext.CenterServiceExt) CenterApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *CenterApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/center/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
