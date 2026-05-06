// admin custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const admin_ext = @import("service_ext.zig");

pub const AdminApiExt = struct {
    ext: *admin_ext.AdminServiceExt,

    pub fn init(ext: *admin_ext.AdminServiceExt) AdminApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *AdminApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/admin/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
