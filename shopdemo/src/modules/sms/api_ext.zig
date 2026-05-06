// sms custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const sms_ext = @import("service_ext.zig");

pub const SmsApiExt = struct {
    ext: *sms_ext.SmsServiceExt,

    pub fn init(ext: *sms_ext.SmsServiceExt) SmsApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *SmsApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/sms/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
