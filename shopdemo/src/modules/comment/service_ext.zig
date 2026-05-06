// comment service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const comment_svc = @import("service.zig");

pub const CommentServiceExt = struct {
    svc: *comment_svc.CommentService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *comment_svc.CommentService, backend: zigmodu.SqlxBackend) CommentServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
