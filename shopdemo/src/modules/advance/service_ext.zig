// advance service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const advance_svc = @import("service.zig");

pub const AdvanceServiceExt = struct {
    svc: *advance_svc.AdvanceService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *advance_svc.AdvanceService, backend: zigmodu.SqlxBackend) AdvanceServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
