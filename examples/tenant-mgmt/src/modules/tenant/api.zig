const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

/// 本模块的日志作用域。handler 用 `TenantLog.withField("trace_id", …)` 把请求的
/// trace id 绑到每一行上 —— 于是"慢 span → 日志"和"错误日志 → trace"都只需一个
/// 字符串。写法就是 `docs/` 里的配方，没有隐式全局态。
const TenantLog = zigmodu.observability.LogScope.scope("tenant");

/// `TenantLog` 绑定 trace_id 后的类型（`LogScope.withField` 返回的是值）。
pub const TracedTenantLog = @TypeOf(TenantLog.withField("trace_id", ""));

/// handler 的日志作用域：每一行都带上请求的 trace id。
///
/// 抽成一个函数（而不是在每个 handler 里重写那行配方）是为了让示例测试能驱动
/// handler 用的同一段代码：`tracedLog` 一旦不再绑 trace_id，测试就会红。
pub fn tracedLog(ctx: *http.Context) TracedTenantLog {
    return TenantLog.withField("trace_id", ctx.traceId() orelse "");
}

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

            // 可观测性示范：把中间件挂在 ctx 上的 trace id 绑进本 handler 的日志
            // 作用域 —— 这一行的 trace_id 与 tracing/OTLP 里那个 span 的 trace_id
            // 是同一个值。`ctx.traceId()` 为 null（没挂 trace 中间件）时绑空串，
            // 行照常打，只是没有可跳转的 id。
            const log = tracedLog(ctx);

            self.service.suspendTenant(id) catch |err| {
                log.err("suspend tenant {d} failed: {s}", .{ id, @errorName(err) });
                try ctx.sendErrorResponse(404, 0, @errorName(err));
                return;
            };

            log.info("tenant {d} suspended", .{id});
            try ctx.json(200, "{\"status\":\"suspended\"}");
        }
    };
}
