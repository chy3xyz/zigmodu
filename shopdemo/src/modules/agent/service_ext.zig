// agent service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const agent_svc = @import("service.zig");

pub const AgentServiceExt = struct {
    svc: *agent_svc.AgentService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *agent_svc.AgentService, backend: zigmodu.SqlxBackend) AgentServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
