// page custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const page_ext = @import("service_ext.zig");

pub const PageApiExt = struct {
    ext: *page_ext.PageServiceExt,

    pub fn init(ext: *page_ext.PageServiceExt) PageApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *PageApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/page/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
