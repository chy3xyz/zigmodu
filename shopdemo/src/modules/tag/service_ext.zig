// tag service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const tag_svc = @import("service.zig");

pub const TagServiceExt = struct {
    svc: *tag_svc.TagService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *tag_svc.TagService, backend: zigmodu.SqlxBackend) TagServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
