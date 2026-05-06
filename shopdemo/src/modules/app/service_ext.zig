// app service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const app_svc = @import("service.zig");

pub const AppServiceExt = struct {
    svc: *app_svc.AppService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *app_svc.AppService, backend: zigmodu.SqlxBackend) AppServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
