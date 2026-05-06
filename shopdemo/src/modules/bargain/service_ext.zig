// bargain service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const bargain_svc = @import("service.zig");

pub const BargainServiceExt = struct {
    svc: *bargain_svc.BargainService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *bargain_svc.BargainService, backend: zigmodu.SqlxBackend) BargainServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
