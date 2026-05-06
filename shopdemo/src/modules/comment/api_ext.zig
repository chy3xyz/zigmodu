// comment custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const comment_ext = @import("service_ext.zig");

pub const CommentApiExt = struct {
    ext: *comment_ext.CommentServiceExt,

    pub fn init(ext: *comment_ext.CommentServiceExt) CommentApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *CommentApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/comment/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
