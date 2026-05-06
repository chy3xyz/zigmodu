// center service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const center_svc = @import("service.zig");

pub const CenterServiceExt = struct {
    svc: *center_svc.CenterService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *center_svc.CenterService, backend: zigmodu.SqlxBackend) CenterServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
