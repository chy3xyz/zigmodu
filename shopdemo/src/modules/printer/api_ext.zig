// printer custom API endpoints — add business routes here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const printer_ext = @import("service_ext.zig");

pub const PrinterApiExt = struct {
    ext: *printer_ext.PrinterServiceExt,

    pub fn init(ext: *printer_ext.PrinterServiceExt) PrinterApiExt {
        return .{ .ext = ext };
    }

    pub fn registerRoutes(self: *PrinterApiExt, group: *zigmodu.http_server.RouteGroup) !void {
        _ = self;
        // Add custom routes:
        // try group.get("/printer/custom", myHandler, @ptrCast(@alignCast(self)));
    }
};
