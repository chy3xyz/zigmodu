// admin service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const admin_svc = @import("service.zig");

pub const AdminServiceExt = struct {
    svc: *admin_svc.AdminService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *admin_svc.AdminService, backend: zigmodu.SqlxBackend) AdminServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
