// supplier service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const supplier_svc = @import("service.zig");

pub const SupplierServiceExt = struct {
    svc: *supplier_svc.SupplierService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *supplier_svc.SupplierService, backend: zigmodu.SqlxBackend) SupplierServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
