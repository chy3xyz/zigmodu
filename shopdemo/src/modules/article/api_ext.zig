// article custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const article_ext = @import("service_ext.zig");

pub const ArticleApiExt = struct {
    ext: *article_ext.ArticleServiceExt,

    pub fn init(ext: *article_ext.ArticleServiceExt) ArticleApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *ArticleApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/article/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
