const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub fn TenantApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service,

        pub const module_name = "tenant";
        pub const nest = .{"tenants"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "", .handler = listTenants },
            .{ .method = .POST, .path = "", .handler = createTenant },
            .{ .method = .GET, .path = "{id}", .handler = getTenant },
        };

        pub fn init(svc: *Service) Self {
            return .{ .service = svc };
        }

        fn listTenants(ctx: *http.Context, self: *State) !void {
            var tenants_qr = self.service.listActive() catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list tenants");
                return;
            };
            defer tenants_qr.deinit(ctx.allocator);
            const tenants = tenants_qr.items;

            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"tenants\":[");
            for (tenants, 0..) |t, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"name":"{s}","domain":"{s}","tier":"{s}"}}
                , .{ t.id, t.name, t.domain, t.tier });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
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
            const tier = ctx.queryParam("tier") orelse "free";
            const tenant = self.service.create(name, domain, tier) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"name":"{s}","domain":"{s}","tier":"{s}"}}
            , .{ tenant.id, tenant.name, tenant.domain, tenant.tier });
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }

        fn getTenant(ctx: *http.Context, self: *State) !void {
            const id = try ctx.paramInt(i64, "id");
            const tenant = (try self.service.getById(id)) orelse {
                try ctx.sendErrorResponse(404, 0, "Tenant not found");
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"name":"{s}","domain":"{s}","tier":"{s}","status":{d}}}
            , .{ tenant.id, tenant.name, tenant.domain, tenant.tier, tenant.status });
            defer ctx.allocator.free(resp);
            try ctx.json(200, resp);
        }
    };
}
