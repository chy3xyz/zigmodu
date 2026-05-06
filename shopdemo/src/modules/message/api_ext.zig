// message custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const message_ext = @import("service_ext.zig");

pub const MessageApiExt = struct {
    ext: *message_ext.MessageServiceExt,

    pub fn init(ext: *message_ext.MessageServiceExt) MessageApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *MessageApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/message/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
