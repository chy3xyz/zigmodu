// chat custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const chat_ext = @import("service_ext.zig");

pub const ChatApiExt = struct {
    ext: *chat_ext.ChatServiceExt,

    pub fn init(ext: *chat_ext.ChatServiceExt) ChatApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *ChatApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/chat/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
