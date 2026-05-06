// live service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const live_svc = @import("service.zig");

pub const LiveServiceExt = struct {
    svc: *live_svc.LiveService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *live_svc.LiveService, backend: zigmodu.SqlxBackend) LiveServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
