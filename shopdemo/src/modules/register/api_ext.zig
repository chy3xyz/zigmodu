// register custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const register_ext = @import("service_ext.zig");

pub const RegisterApiExt = struct {
    ext: *register_ext.RegisterServiceExt,

    pub fn init(ext: *register_ext.RegisterServiceExt) RegisterApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *RegisterApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/register/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
