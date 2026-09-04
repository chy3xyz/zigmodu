const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

/// Tenant HTTP API — ComptimeRouter (`docs/ROUTE_TABLE.md`).
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
            .{ .method = .PUT, .path = "{id}/tier", .handler = updateTier },
            .{ .method = .DELETE, .path = "{id}", .handler = suspendTenant, .meta = .{ .permission = "tenant:suspend" } },
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
                    \\{{"id":{d},"name":"{s}","domain":"{s}","tier":"{s}","status":{d}}}
                , .{ t.id, t.name, t.domain, t.tier, t.status });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }

            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn createTenant(ctx: *http.Context, self: *State) !void {
            const name = ctx.queryParam("name") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing 'name' parameter");
                return;
            };
            const domain = ctx.queryParam("domain") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing 'domain' parameter");
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
            const id_str = ctx.param("id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant ID");
                return;
            };
            const id = std.fmt.parseInt(i64, id_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid tenant ID");
                return;
            };

            const tenant = self.service.getById(id) catch |err| {
                try ctx.sendErrorResponse(404, 0, @errorName(err));
                return;
            } orelse {
                try ctx.sendErrorResponse(404, 0, "Tenant not found");
                return;
            };
            defer self.service.freeTenant(tenant);

            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"name":"{s}","domain":"{s}","tier":"{s}","status":{d}}}
            , .{ tenant.id, tenant.name, tenant.domain, tenant.tier, tenant.status });
            defer ctx.allocator.free(resp);
            try ctx.json(200, resp);
        }

        fn updateTier(ctx: *http.Context, self: *State) !void {
            const id_str = ctx.param("id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant ID");
                return;
            };
            const id = std.fmt.parseInt(i64, id_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid tenant ID");
                return;
            };
            const tier = ctx.queryParam("tier") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing 'tier' parameter");
                return;
            };

            self.service.updateTier(id, tier) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };

            try ctx.json(200, "{\"status\":\"ok\"}");
        }

        fn suspendTenant(ctx: *http.Context, self: *State) !void {
            const id_str = ctx.param("id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant ID");
                return;
            };
            const id = std.fmt.parseInt(i64, id_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid tenant ID");
                return;
            };

            self.service.suspendTenant(id) catch |err| {
                try ctx.sendErrorResponse(404, 0, @errorName(err));
                return;
            };

            try ctx.json(200, "{\"status\":\"suspended\"}");
        }
    };
}
