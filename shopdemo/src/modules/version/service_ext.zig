// version service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const version_svc = @import("service.zig");

pub const VersionServiceExt = struct {
    svc: *version_svc.VersionService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *version_svc.VersionService, backend: zigmodu.SqlxBackend) VersionServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
