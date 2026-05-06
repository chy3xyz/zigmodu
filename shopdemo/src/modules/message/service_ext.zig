// message service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const message_svc = @import("service.zig");

pub const MessageServiceExt = struct {
    svc: *message_svc.MessageService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *message_svc.MessageService, backend: zigmodu.SqlxBackend) MessageServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
