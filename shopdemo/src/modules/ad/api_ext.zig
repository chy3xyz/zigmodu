// ad custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const ad_ext = @import("service_ext.zig");

pub const AdApiExt = struct {
    ext: *ad_ext.AdServiceExt,

    pub fn init(ext: *ad_ext.AdServiceExt) AdApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *AdApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/ad/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
