// setting custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const setting_ext = @import("service_ext.zig");

pub const SettingApiExt = struct {
    ext: *setting_ext.SettingServiceExt,

    pub fn init(ext: *setting_ext.SettingServiceExt) SettingApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *SettingApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/setting/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
