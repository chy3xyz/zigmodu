// version custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const version_ext = @import("service_ext.zig");

pub const VersionApiExt = struct {
    ext: *version_ext.VersionServiceExt,

    pub fn init(ext: *version_ext.VersionServiceExt) VersionApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *VersionApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/version/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
