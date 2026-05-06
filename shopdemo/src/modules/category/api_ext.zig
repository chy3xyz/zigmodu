// category custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const category_ext = @import("service_ext.zig");

pub const CategoryApiExt = struct {
    ext: *category_ext.CategoryServiceExt,

    pub fn init(ext: *category_ext.CategoryServiceExt) CategoryApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *CategoryApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/category/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
