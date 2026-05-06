// category service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const category_svc = @import("service.zig");

pub const CategoryServiceExt = struct {
    svc: *category_svc.CategoryService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *category_svc.CategoryService, backend: zigmodu.SqlxBackend) CategoryServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
