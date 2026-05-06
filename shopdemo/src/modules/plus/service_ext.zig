// plus service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const plus_svc = @import("service.zig");

pub const PlusServiceExt = struct {
    svc: *plus_svc.PlusService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *plus_svc.PlusService, backend: zigmodu.SqlxBackend) PlusServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
