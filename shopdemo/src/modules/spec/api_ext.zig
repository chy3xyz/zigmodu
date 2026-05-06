// spec custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const spec_ext = @import("service_ext.zig");

pub const SpecApiExt = struct {
    ext: *spec_ext.SpecServiceExt,

    pub fn init(ext: *spec_ext.SpecServiceExt) SpecApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *SpecApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/spec/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
