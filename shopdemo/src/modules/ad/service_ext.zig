// ad service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const ad_svc = @import("service.zig");

pub const AdServiceExt = struct {
    svc: *ad_svc.AdService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *ad_svc.AdService, backend: zigmodu.SqlxBackend) AdServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
