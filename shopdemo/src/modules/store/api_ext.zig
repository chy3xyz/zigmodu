// store custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const store_ext = @import("service_ext.zig");

pub const StoreApiExt = struct {
    ext: *store_ext.StoreServiceExt,

    pub fn init(ext: *store_ext.StoreServiceExt) StoreApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *StoreApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/store/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
