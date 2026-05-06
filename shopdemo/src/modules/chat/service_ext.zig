// chat service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const chat_svc = @import("service.zig");

pub const ChatServiceExt = struct {
    svc: *chat_svc.ChatService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *chat_svc.ChatService, backend: zigmodu.SqlxBackend) ChatServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
