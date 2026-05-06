// balance custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const balance_ext = @import("service_ext.zig");

pub const BalanceApiExt = struct {
    ext: *balance_ext.BalanceServiceExt,

    pub fn init(ext: *balance_ext.BalanceServiceExt) BalanceApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *BalanceApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/balance/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
