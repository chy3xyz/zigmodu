const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub fn ProductApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service,

        pub const module_name = "product";
        pub const nest = .{"products"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "", .handler = listProducts },
            .{ .method = .POST, .path = "", .handler = createProduct },
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

        fn listProducts(ctx: *http.Context, self: *State) !void {
            const tid = try tenantId(ctx);
            var products_qr = self.service.listByTenant(tid) catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list products");
                return;
            };
            defer products_qr.deinit(ctx.allocator);
            const products = products_qr.items;
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"products\":[");
            for (products, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"tenant_id":{d},"name":"{s}","price_cents":{d}}}
                , .{ p.id, p.tenant_id, p.name, p.price_cents });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn createProduct(ctx: *http.Context, self: *State) !void {
            const tid = try tenantId(ctx);
            const name = ctx.queryParam("name") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing name");
                return;
            };
            const price_str = ctx.queryParam("price_cents") orelse "0";
            const price = std.fmt.parseInt(i64, price_str, 10) catch 0;
            const p = self.service.create(tid, name, price) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"tenant_id":{d},"name":"{s}","price_cents":{d}}}
            , .{ p.id, p.tenant_id, p.name, p.price_cents });
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }
    };
}
