// point service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const point_svc = @import("service.zig");

pub const PointServiceExt = struct {
    svc: *point_svc.PointService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *point_svc.PointService, backend: zigmodu.SqlxBackend) PointServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
