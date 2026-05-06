// balance service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const balance_svc = @import("service.zig");

pub const BalanceServiceExt = struct {
    svc: *balance_svc.BalanceService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *balance_svc.BalanceService, backend: zigmodu.SqlxBackend) BalanceServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
