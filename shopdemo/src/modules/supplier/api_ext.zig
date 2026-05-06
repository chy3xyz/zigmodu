// supplier custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const supplier_ext = @import("service_ext.zig");

pub const SupplierApiExt = struct {
    ext: *supplier_ext.SupplierServiceExt,

    pub fn init(ext: *supplier_ext.SupplierServiceExt) SupplierApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *SupplierApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/supplier/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
