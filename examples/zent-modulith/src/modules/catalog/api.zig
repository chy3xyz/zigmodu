const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const service = @import("service.zig");

/// Catalog HTTP API — ComptimeRouter (`docs/ROUTE_TABLE.md`).
pub fn CatalogApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        svc: *Service,

        pub const module_name = "catalog";
        pub const nest = .{};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .POST, .path = "tenants", .handler = createTenant, .meta = .{ .auth = .public } },
            .{ .method = .POST, .path = "products", .handler = createProduct, .meta = .{ .auth = .public } },
            .{ .method = .GET, .path = "products", .handler = listProducts, .meta = .{ .auth = .public } },
        };

        pub fn init(svc: *Service) Self {
            return .{ .svc = svc };
        }

        fn createTenant(ctx: *http.Context, self: *State) !void {
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

        fn createProduct(ctx: *http.Context, self: *State) !void {
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

        fn listProducts(ctx: *http.Context, self: *State) !void {
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
