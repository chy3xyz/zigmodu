// region service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const region_svc = @import("service.zig");

pub const RegionServiceExt = struct {
    svc: *region_svc.RegionService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *region_svc.RegionService, backend: zigmodu.SqlxBackend) RegionServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
