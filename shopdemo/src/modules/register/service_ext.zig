// register service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const register_svc = @import("service.zig");

pub const RegisterServiceExt = struct {
    svc: *register_svc.RegisterService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *register_svc.RegisterService, backend: zigmodu.SqlxBackend) RegisterServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
