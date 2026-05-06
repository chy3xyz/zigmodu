// upload custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const upload_ext = @import("service_ext.zig");

pub const UploadApiExt = struct {
    ext: *upload_ext.UploadServiceExt,

    pub fn init(ext: *upload_ext.UploadServiceExt) UploadApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *UploadApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/upload/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
