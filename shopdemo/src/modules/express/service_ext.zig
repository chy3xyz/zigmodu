// express service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const express_svc = @import("service.zig");

pub const ExpressServiceExt = struct {
    svc: *express_svc.ExpressService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *express_svc.ExpressService, backend: zigmodu.SqlxBackend) ExpressServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
