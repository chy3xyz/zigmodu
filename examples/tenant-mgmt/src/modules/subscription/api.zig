const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

/// Subscription + plans HTTP API — ComptimeRouter (`docs/ROUTE_TABLE.md`).
/// Two resources under one module (`plans` + `subscriptions`); nest is empty so
/// route paths carry the resource segment (preserves existing URLs).
pub fn SubscriptionApi(comptime Sv: type) type {
    return struct {
        const Self = @This();
        svc: *Sv,

        pub const module_name = "subscription";
        pub const nest = .{};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "plans", .handler = listPlans },
            .{ .method = .POST, .path = "subscriptions", .handler = subscribe },
            .{ .method = .GET, .path = "subscriptions/{tenant_id}", .handler = getSubscription },
            .{ .method = .DELETE, .path = "subscriptions/{id}", .handler = cancelSubscription },
        };

        pub fn init(s: *Sv) Self {
            return .{ .svc = s };
        }

        fn listPlans(ctx: *http.Context, self: *State) !void {
            var plans_qr = self.svc.listPlans() catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list plans");
                return;
            };
            defer plans_qr.deinit(ctx.allocator);
            const plans = plans_qr.items;
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"plans\":[");
            for (plans, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"name":"{s}","max_users":{d},"price":{d:.2}}}
                , .{ p.id, p.name, p.max_users, p.price });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn subscribe(ctx: *http.Context, self: *State) !void {
            const tenant_str = ctx.queryParam("tenant_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant_id");
                return;
            };
            const tenant_id = std.fmt.parseInt(i64, tenant_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid tenant_id");
                return;
            };
            const plan_str = ctx.queryParam("plan_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing plan_id");
                return;
            };
            const plan_id = std.fmt.parseInt(i64, plan_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid plan_id");
                return;
            };
            const sub = self.svc.subscribe(tenant_id, plan_id) catch |err| {
                try ctx.sendErrorResponse(500, 0, @errorName(err));
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"tenant_id":{d},"plan_id":{d},"status":"{s}"}}
            , .{ sub.id, sub.tenant_id, sub.plan_id, sub.status });
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }

        fn getSubscription(ctx: *http.Context, self: *State) !void {
            const tenant_str = ctx.param("tenant_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing tenant_id");
                return;
            };
            const tenant_id = std.fmt.parseInt(i64, tenant_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid tenant_id");
                return;
            };
            const sub = self.svc.getByTenant(tenant_id) catch |err| {
                try ctx.sendErrorResponse(500, 0, @errorName(err));
                return;
            } orelse {
                try ctx.sendErrorResponse(404, 0, "No subscription found");
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"tenant_id":{d},"plan_id":{d},"status":"{s}","expires_at":{d}}}
            , .{ sub.id, sub.tenant_id, sub.plan_id, sub.status, sub.expires_at });
            defer ctx.allocator.free(resp);
            try ctx.json(200, resp);
        }

        fn cancelSubscription(ctx: *http.Context, self: *State) !void {
            const id_str = ctx.param("id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing subscription ID");
                return;
            };
            const id = std.fmt.parseInt(i64, id_str, 10) catch {
                try ctx.sendErrorResponse(400, 0, "Invalid subscription ID");
                return;
            };
            self.svc.cancel(id) catch |err| {
                try ctx.sendErrorResponse(500, 0, @errorName(err));
                return;
            };
            try ctx.json(200, "{\"status\":\"cancelled\"}");
        }
    };
}
