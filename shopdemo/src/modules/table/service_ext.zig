// table service extension — add custom business logic here.
// Survives zmodu regeneration.
const std = @import("std");
const zigmodu = @import("zigmodu");
const table_svc = @import("service.zig");

pub const TableServiceExt = struct {
    svc: *table_svc.TableService,
    backend: zigmodu.SqlxBackend,

    pub fn init(svc: *table_svc.TableService, backend: zigmodu.SqlxBackend) TableServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    // Add your custom business methods here
};
