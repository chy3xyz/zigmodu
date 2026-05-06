// assemble custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const assemble_ext = @import("service_ext.zig");

pub const AssembleApiExt = struct {
    ext: *assemble_ext.AssembleServiceExt,

    pub fn init(ext: *assemble_ext.AssembleServiceExt) AssembleApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *AssembleApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/assemble/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
