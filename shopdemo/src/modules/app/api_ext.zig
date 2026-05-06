// app custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const app_ext = @import("service_ext.zig");

pub const AppApiExt = struct {
    ext: *app_ext.AppServiceExt,

    pub fn init(ext: *app_ext.AppServiceExt) AppApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *AppApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/app/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
