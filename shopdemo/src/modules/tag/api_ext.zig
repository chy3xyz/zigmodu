// tag custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const tag_ext = @import("service_ext.zig");

pub const TagApiExt = struct {
    ext: *tag_ext.TagServiceExt,

    pub fn init(ext: *tag_ext.TagServiceExt) TagApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *TagApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/tag/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
