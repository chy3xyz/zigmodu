// product custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const product_ext = @import("service_ext.zig");

pub const ProductApiExt = struct {
    ext: *product_ext.ProductServiceExt,

    pub fn init(ext: *product_ext.ProductServiceExt) ProductApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *ProductApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/product/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
