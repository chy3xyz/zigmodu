// advance custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const advance_ext = @import("service_ext.zig");

pub const AdvanceApiExt = struct {
    ext: *advance_ext.AdvanceServiceExt,

    pub fn init(ext: *advance_ext.AdvanceServiceExt) AdvanceApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *AdvanceApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/advance/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
