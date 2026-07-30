const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub fn InventoryApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service,

        pub const module_name = "inventory";
        pub const nest = .{"inventory"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "", .handler = listInventory },
            .{ .method = .POST, .path = "", .handler = setInventory },
        };

        pub fn init(svc: *Service) Self {
            return .{ .service = svc };
        }

        fn tenantId(ctx: *http.Context) !i64 {
            const s = ctx.queryParam("tenant_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant_id");
                return error.InvalidInput;
            };
            return std.fmt.parseInt(i64, s, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid tenant_id");
                return error.InvalidInput;
            };
        }

        fn listInventory(ctx: *http.Context, self: *State) !void {
            const tid = try tenantId(ctx);
            var rows_qr = self.service.listByTenant(tid) catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list inventory");
                return;
            };
            defer rows_qr.deinit(ctx.allocator);
            const rows = rows_qr.items;
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"inventory\":[");
            for (rows, 0..) |r, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"product_id":{d},"qty":{d},"reserved":{d}}}
                , .{ r.product_id, r.qty, r.reserved });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn setInventory(ctx: *http.Context, self: *State) !void {
            const tid = try tenantId(ctx);
            const pid_s = ctx.queryParam("product_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing product_id");
                return;
            };
            const qty_s = ctx.queryParam("qty") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing qty");
                return;
            };
            const pid = try std.fmt.parseInt(i64, pid_s, 10);
            const qty = try std.fmt.parseInt(i64, qty_s, 10);
            self.service.setQty(tid, pid, qty) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            try ctx.json(200, "{\"status\":\"ok\"}");
        }
    };
}
