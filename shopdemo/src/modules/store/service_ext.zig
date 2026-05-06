// store service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const store_svc = @import("service.zig");

pub const StoreServiceExt = struct {
    svc: *store_svc.StoreService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *store_svc.StoreService, backend: zigmodu.SqlxBackend) StoreServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
