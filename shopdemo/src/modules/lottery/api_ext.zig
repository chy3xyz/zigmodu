// lottery custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const lottery_ext = @import("service_ext.zig");

pub const LotteryApiExt = struct {
    ext: *lottery_ext.LotteryServiceExt,

    pub fn init(ext: *lottery_ext.LotteryServiceExt) LotteryApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *LotteryApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/lottery/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
