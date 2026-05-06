// seckill service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const seckill_svc = @import("service.zig");

pub const SeckillServiceExt = struct {
    svc: *seckill_svc.SeckillService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *seckill_svc.SeckillService, backend: zigmodu.SqlxBackend) SeckillServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
