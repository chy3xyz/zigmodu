// seckill custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const seckill_ext = @import("service_ext.zig");

pub const SeckillApiExt = struct {
    ext: *seckill_ext.SeckillServiceExt,

    pub fn init(ext: *seckill_ext.SeckillServiceExt) SeckillApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *SeckillApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/seckill/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
