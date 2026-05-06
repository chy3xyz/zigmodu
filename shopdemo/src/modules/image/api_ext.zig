// image custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const image_ext = @import("service_ext.zig");

pub const ImageApiExt = struct {
    ext: *image_ext.ImageServiceExt,

    pub fn init(ext: *image_ext.ImageServiceExt) ImageApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *ImageApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/image/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
