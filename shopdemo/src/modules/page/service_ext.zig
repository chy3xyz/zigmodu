// page service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const page_svc = @import("service.zig");

pub const PageServiceExt = struct {
    svc: *page_svc.PageService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *page_svc.PageService, backend: zigmodu.SqlxBackend) PageServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
