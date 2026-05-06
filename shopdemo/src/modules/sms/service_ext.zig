// sms service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const sms_svc = @import("service.zig");

pub const SmsServiceExt = struct {
    svc: *sms_svc.SmsService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *sms_svc.SmsService, backend: zigmodu.SqlxBackend) SmsServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
