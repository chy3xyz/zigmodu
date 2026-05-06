// upload service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const upload_svc = @import("service.zig");

pub const UploadServiceExt = struct {
    svc: *upload_svc.UploadService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *upload_svc.UploadService, backend: zigmodu.SqlxBackend) UploadServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
