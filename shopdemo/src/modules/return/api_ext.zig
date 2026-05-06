// return custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const return_ext = @import("service_ext.zig");

pub const ReturnApiExt = struct {
    ext: *return_ext.ReturnServiceExt,

    pub fn init(ext: *return_ext.ReturnServiceExt) ReturnApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *ReturnApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/return/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
