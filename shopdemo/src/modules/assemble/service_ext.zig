// assemble service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const assemble_svc = @import("service.zig");

pub const AssembleServiceExt = struct {
    svc: *assemble_svc.AssembleService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *assemble_svc.AssembleService, backend: zigmodu.SqlxBackend) AssembleServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
