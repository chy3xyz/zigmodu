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

        const CreateTenantQ = struct { name: []const u8, domain: []const u8 };
        const CreateProductQ = struct { tenant_id: i64, name: []const u8, price_cents: i64 = 0 };
        const ListProductQ = struct { tenant_id: i64 };

        const create_tenant_params = http.openApiParamsFromStruct(CreateTenantQ, .query);
        const create_product_params = http.openApiParamsFromStruct(CreateProductQ, .query);
        const list_product_params = http.openApiParamsFromStruct(ListProductQ, .query);

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .POST, .path = "tenants", .handler = createTenant, .meta = .{ .auth = .public, .openapi_params = &create_tenant_params } },
            .{ .method = .POST, .path = "products", .handler = createProduct, .meta = .{ .auth = .public, .openapi_params = &create_product_params } },
            .{ .method = .GET, .path = "products", .handler = listProducts, .meta = .{ .auth = .public, .openapi_params = &list_product_params } },
        };

        pub const sse_routes = [_]http.SseSpec(State){
            .{ .path = "events", .handler = streamEvents, .meta = .{ .auth = .public } },
        };

        pub fn init(svc: *Service) Self {
            return .{ .svc = svc };
        }

        fn createTenant(ctx: *http.Context, self: *State) !void {
            const q = http.extractQuery(ctx, CreateTenantQ) catch |err| return http.respondErr(ctx, err);
            const id = self.svc.createTenant(q.name, q.domain) catch |err| return http.respondErr(ctx, err);
            const resp = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{id});
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }

        fn createProduct(ctx: *http.Context, self: *State) !void {
            const q = http.extractQuery(ctx, CreateProductQ) catch |err| return http.respondErr(ctx, err);
            const id = self.svc.createProduct(q.tenant_id, q.name, q.price_cents) catch |err| return http.respondErr(ctx, err);
            const resp = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{id});
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }

        fn listProducts(ctx: *http.Context, self: *State) !void {
            const q = http.extractQuery(ctx, ListProductQ) catch |err| return http.respondErr(ctx, err);
            const rows = self.svc.listProducts(q.tenant_id) catch |err| return http.respondErr(ctx, err);
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

        /// Demo SSE: one tick then done (requires live stream in production).
        fn streamEvents(ctx: *http.Context, _: *State) !void {
            var writer = try http.sse(ctx);
            try writer.sendEvent("hello", "{\"source\":\"catalog\"}");
            try writer.done();
        }
    };
}

pub const DefaultCatalogApi = CatalogApi(service.CatalogService);
