// product service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const product_svc = @import("service.zig");

pub const ProductServiceExt = struct {
    svc: *product_svc.ProductService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *product_svc.ProductService, backend: zigmodu.SqlxBackend) ProductServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
