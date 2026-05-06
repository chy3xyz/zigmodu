// spec service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const spec_svc = @import("service.zig");

pub const SpecServiceExt = struct {
    svc: *spec_svc.SpecService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *spec_svc.SpecService, backend: zigmodu.SqlxBackend) SpecServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
