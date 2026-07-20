const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const service = @import("service.zig");

pub fn CatalogApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        svc: *Service,

        pub fn init(svc: *Service) Self {
            return .{ .svc = svc };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            try group.post("/tenants", createTenant, @ptrCast(@alignCast(self)));
            try group.post("/products", createProduct, @ptrCast(@alignCast(self)));
            try group.get("/products", listProducts, @ptrCast(@alignCast(self)));
        }

        fn createTenant(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const name = ctx.queryParam("name") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing name");
                return;
            };
            const domain = ctx.queryParam("domain") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing domain");
                return;
            };
            const id = self.svc.createTenant(name, domain) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{id});
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }

        fn createProduct(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const tid_s = ctx.queryParam("tenant_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant_id");
                return;
            };
            const name = ctx.queryParam("name") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing name");
                return;
            };
            const price_s = ctx.queryParam("price_cents") orelse "0";
            const tid = try std.fmt.parseInt(i64, tid_s, 10);
            const price = try std.fmt.parseInt(i64, price_s, 10);
            const id = self.svc.createProduct(tid, name, price) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{id});
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }

        fn listProducts(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const tid_s = ctx.queryParam("tenant_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant_id");
                return;
            };
            const tid = try std.fmt.parseInt(i64, tid_s, 10);
            const rows = self.svc.listProducts(tid) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            defer self.svc.freeProducts(rows);

            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"products\":[");
            for (rows, 0..) |r, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"tenant_id":{d},"name":"{s}","price_cents":{d}}}
                , .{ r.id, r.tenant_id, r.name, r.price_cents });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }
    };
}

pub const DefaultCatalogApi = CatalogApi(service.CatalogService);
