const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const service = @import("service.zig");

/// Tenant API 层 — HTTP 路由处理
pub fn TenantApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service,

        pub fn init(svc: *Service) Self {
            return .{ .service = svc };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            try group.get("/tenants", listTenants, @ptrCast(@alignCast(self)));
            try group.post("/tenants", createTenant, @ptrCast(@alignCast(self)));
            try group.get("/tenants/{id}", getTenant, @ptrCast(@alignCast(self)));
            try group.put("/tenants/{id}/tier", updateTier, @ptrCast(@alignCast(self)));
            try group.delete("/tenants/{id}", suspendTenant, @ptrCast(@alignCast(self)));
        }

        fn listTenants(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));
            const tenants = self.service.listActive() catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list tenants");
                return;
            };

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

        fn createTenant(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));

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

        fn getTenant(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));
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

            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"name":"{s}","domain":"{s}","tier":"{s}","status":{d}}}
            , .{ tenant.id, tenant.name, tenant.domain, tenant.tier, tenant.status });
            defer ctx.allocator.free(resp);
            try ctx.json(200, resp);
        }

        fn updateTier(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));
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

        fn suspendTenant(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));
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
