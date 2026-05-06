// lottery service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const lottery_svc = @import("service.zig");

pub const LotteryServiceExt = struct {
    svc: *lottery_svc.LotteryService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *lottery_svc.LotteryService, backend: zigmodu.SqlxBackend) LotteryServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
