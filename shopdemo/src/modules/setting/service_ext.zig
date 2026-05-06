// setting service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const setting_svc = @import("service.zig");

pub const SettingServiceExt = struct {
    svc: *setting_svc.SettingService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *setting_svc.SettingService, backend: zigmodu.SqlxBackend) SettingServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
