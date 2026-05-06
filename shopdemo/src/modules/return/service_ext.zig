// return service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const return_svc = @import("service.zig");

pub const ReturnServiceExt = struct {
    svc: *return_svc.ReturnService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *return_svc.ReturnService, backend: zigmodu.SqlxBackend) ReturnServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
