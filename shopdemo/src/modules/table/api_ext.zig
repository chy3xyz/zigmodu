// table custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const table_ext = @import("service_ext.zig");

pub const TableApiExt = struct {
    ext: *table_ext.TableServiceExt,

    pub fn init(ext: *table_ext.TableServiceExt) TableApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *TableApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/table/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
