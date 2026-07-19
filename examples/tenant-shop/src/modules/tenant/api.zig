const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

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
        }

        fn listTenants(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const tenants = self.service.listActive() catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list tenants");
                return;
            };
            defer self.service.freeTenantList(tenants);

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
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
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
