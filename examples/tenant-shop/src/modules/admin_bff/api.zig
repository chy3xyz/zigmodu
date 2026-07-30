const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

/// Merchant admin BFF — product / inventory / orders (+ optional outbox ops).
pub fn AdminBffApi(
    comptime ProductService: type,
    comptime InventoryService: type,
    comptime OrderService: type,
    comptime Poller: type,
) type {
    return struct {
        const Self = @This();
        product_svc: *ProductService,
        inventory_svc: *InventoryService,
        order_svc: *OrderService,
        poller: *Poller,

        pub const module_name = "admin_bff";
        pub const nest = .{"admin"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "products", .handler = listProducts },
            .{ .method = .POST, .path = "products", .handler = createProduct },
            .{ .method = .GET, .path = "inventory", .handler = listInventory },
            .{ .method = .POST, .path = "inventory", .handler = setInventory },
            .{ .method = .GET, .path = "orders", .handler = listOrders },
            .{ .method = .GET, .path = "outbox", .handler = listOutbox },
            .{ .method = .GET, .path = "outbox/dlq", .handler = listDlq },
            .{ .method = .POST, .path = "outbox/drain", .handler = drainOutbox },
            .{ .method = .POST, .path = "outbox/requeue", .handler = requeueOutbox },
            .{ .method = .GET, .path = "status", .handler = status },
        };

        pub fn init(
            product_svc: *ProductService,
            inventory_svc: *InventoryService,
            order_svc: *OrderService,
            poller: *Poller,
        ) Self {
            return .{
                .product_svc = product_svc,
                .inventory_svc = inventory_svc,
                .order_svc = order_svc,
                .poller = poller,
            };
        }

        fn tenantId(ctx: *http.Context) !i64 {
            const s = ctx.queryParam("tenant_id") orelse ctx.getAttr("tenant_id") orelse {
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
            var products_qr = self.product_svc.listByTenant(tid) catch {
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
                    \\{{"id":{d},"name":"{s}","price_cents":{d}}}
                , .{ p.id, p.name, p.price_cents });
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
            const p = self.product_svc.create(tid, name, price) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"tenant_id":{d},"name":"{s}","price_cents":{d}}}
            , .{ p.id, p.tenant_id, p.name, p.price_cents });
            defer ctx.allocator.free(resp);
            try ctx.json(201, resp);
        }

        fn listInventory(ctx: *http.Context, self: *State) !void {
            const tid = try tenantId(ctx);
            var rows_qr = self.inventory_svc.listByTenant(tid) catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list inventory");
                return;
            };
            defer rows_qr.deinit(ctx.allocator);
            const rows = rows_qr.items;
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"inventory\":[");
            for (rows, 0..) |r, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"product_id":{d},"qty":{d},"reserved":{d}}}
                , .{ r.product_id, r.qty, r.reserved });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn setInventory(ctx: *http.Context, self: *State) !void {
            const tid = try tenantId(ctx);
            const pid_s = ctx.queryParam("product_id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing product_id");
                return;
            };
            const qty_s = ctx.queryParam("qty") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing qty");
                return;
            };
            const pid = try std.fmt.parseInt(i64, pid_s, 10);
            const qty = try std.fmt.parseInt(i64, qty_s, 10);
            self.inventory_svc.setQty(tid, pid, qty) catch |err| {
                try ctx.sendErrorResponse(400, 0, @errorName(err));
                return;
            };
            try ctx.json(200, "{\"status\":\"ok\"}");
        }

        fn listOrders(ctx: *http.Context, self: *State) !void {
            const tid = try tenantId(ctx);
            var orders_qr = self.order_svc.listByTenant(tid) catch {
                try ctx.sendErrorResponse(500, 0, "Failed to list orders");
                return;
            };
            defer orders_qr.deinit(ctx.allocator);
            const orders = orders_qr.items;
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"orders\":[");
            for (orders, 0..) |o, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"user_id":{d},"status":"{s}","total_cents":{d}}}
                , .{ o.id, o.user_id, o.status, o.total_cents });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn listOutbox(ctx: *http.Context, self: *State) !void {
            var rows_qr = self.poller.listRecent(50) catch {
                try ctx.sendErrorResponse(500, 0, "outbox list failed");
                return;
            };
            defer rows_qr.deinit(ctx.allocator);
            try writeOutbox(ctx, rows_qr.items);
        }

        fn listDlq(ctx: *http.Context, self: *State) !void {
            var rows_qr = self.poller.listByStatus("dlq", 50) catch {
                try ctx.sendErrorResponse(500, 0, "dlq list failed");
                return;
            };
            defer rows_qr.deinit(ctx.allocator);
            try writeOutbox(ctx, rows_qr.items);
        }

        fn drainOutbox(ctx: *http.Context, self: *State) !void {
            const sim = ctx.queryParam("simulate_fail");
            const want_fail = if (sim) |s| std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true") else false;
            self.poller.setSimulateFail(want_fail);
            defer self.poller.setSimulateFail(false);
            const res = self.poller.pollOnce() catch {
                try ctx.sendErrorResponse(500, 0, "drain failed");
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"published":{d},"retried":{d},"dlq":{d}}}
            , .{ res.published, res.retried, res.dlq });
            defer ctx.allocator.free(resp);
            try ctx.json(200, resp);
        }

        fn requeueOutbox(ctx: *http.Context, self: *State) !void {
            const id_s = ctx.queryParam("id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing id");
                return;
            };
            const id = try std.fmt.parseInt(i64, id_s, 10);
            const ok = self.poller.requeue(id) catch {
                try ctx.sendErrorResponse(500, 0, "requeue failed");
                return;
            };
            if (!ok) {
                try ctx.sendErrorResponse(404, 0, "DLQ entry not found");
                return;
            }
            try ctx.json(200, "{\"status\":\"requeued\"}");
        }

        fn writeOutbox(ctx: *http.Context, rows: anytype) !void {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"outbox\":[");
            for (rows, 0..) |r, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const err_s = r.last_error orelse "";
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"topic":"{s}","status":"{s}","retry_count":{d},"max_retries":{d},"last_error":"{s}"}}
                , .{ r.id, r.topic, r.status, r.retry_count, r.max_retries, err_s });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn status(ctx: *http.Context, _: *State) !void {
            try ctx.json(200, "{\"bff\":\"admin\",\"status\":\"ok\"}");
        }
    };
}
