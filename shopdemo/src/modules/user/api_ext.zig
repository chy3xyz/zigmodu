// user custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const user_ext = @import("service_ext.zig");

pub const UserApiExt = struct {
    ext: *user_ext.UserServiceExt,

    pub fn init(ext: *user_ext.UserServiceExt) UserApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *UserApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/user/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
