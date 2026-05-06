// agent custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const agent_ext = @import("service_ext.zig");

pub const AgentApiExt = struct {
    ext: *agent_ext.AgentServiceExt,

    pub fn init(ext: *agent_ext.AgentServiceExt) AgentApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *AgentApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/agent/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
