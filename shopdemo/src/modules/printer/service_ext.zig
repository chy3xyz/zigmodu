// printer service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const printer_svc = @import("service.zig");

pub const PrinterServiceExt = struct {
    svc: *printer_svc.PrinterService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *printer_svc.PrinterService, backend: zigmodu.SqlxBackend) PrinterServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
