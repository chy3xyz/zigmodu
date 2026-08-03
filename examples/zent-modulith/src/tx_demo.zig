//! Transaction-orchestration + distributed-id demos for zent v0.24:
//!   - OrderApi: outer transaction -> nested savepoint (re-entrant beginTx)
//!     for the stock decrement -> transaction-scoped events delivered once
//!     after commit (afterCommit + enqueueEvent + takePendingEvents).
//!   - AccountApi: uuidv7 primary keys generated server-side and a
//!     `Sensitive` api_key that is only serialized masked (toMaskedJson).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const zent = @import("zent");
const persist = @import("modules/catalog/persistence.zig");

/// OrderApi: POST /api/v1/orders?product_id=&qty= places an order inside an
/// outer transaction; the stock decrement runs in a nested savepoint, and
/// order/stock events are collected on the TxClient and delivered exactly
/// once after a successful commit.
pub fn OrderApi(comptime Client: type) type {
    return struct {
        const Self = @This();

        client: *Client,

        pub const module_name = "catalog";
        pub const nest = .{"orders"};
        pub const State = Self;

        pub fn init(client: *Client) Self {
            return .{ .client = client };
        }

        const CreateOrderQ = struct {
            product_id: i64,
            qty: i64 = 1,
        };

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .POST, .path = "", .handler = create, .meta = .{ .auth = .public } },
            .{ .method = .GET, .path = "{id}", .handler = get, .meta = .{ .auth = .public } },
        };

        const TxT = zent.codegen.client.TxClient(persist.infos);

        /// afterCommit context: drains the transaction-scoped events after a
        /// successful commit (production would publish them to an outbox or
        /// notification queue instead of logging).
        const EvCtx = struct {
            allocator: std.mem.Allocator,
            tx: *TxT,
            delivered: usize = 0,

            fn onCommit(raw: ?*anyopaque) void {
                const self: *EvCtx = @ptrCast(@alignCast(raw.?));
                const events = self.tx.takePendingEvents();
                for (events) |p| {
                    std.log.info("[order] tx event after commit: {s}", .{p});
                    self.allocator.free(p);
                }
                self.delivered = events.len;
                self.allocator.free(events);
            }
        };

        fn create(ctx: *http.Context, self: *State) !void {
            const q = http.extractQuery(ctx, CreateOrderQ) catch |err| return http.respondErr(ctx, err);
            if (q.qty <= 0) return http.respondErr(ctx, error.InvalidQuantity);

            // Outer transaction: the order row, the stock decrement and the
            // events are atomic — nothing is visible before commit.
            var tx = zent.codegen.client.beginTx(persist.infos, self.client.*) catch |err| return http.respondErr(ctx, err);
            defer tx.deinit();

            // Read the product price inside the tx for the order total.
            const price_cents = blk: {
                var qp = tx.client.product.Query();
                defer qp.deinit();
                _ = try qp.Where(.{tx.client.product.predicates.idEQ(.{ .int = q.product_id })});
                var p = (try qp.First()) orelse return http.respondErr(ctx, error.NotFound);
                defer zent.codegen.deinitEntity(persist.infos, persist.ProductInfo, &p, self.client.allocator);
                break :blk p.price_cents;
            };
            const total_cents = price_cents * q.qty;

            const order_id = blk: {
                var b = try tx.client.order.Create();
                defer b.deinit();
                _ = try b.setFieldValue("tenant_id", @as(i64, 1));
                _ = try b.setFieldValue("product_id", q.product_id);
                _ = try b.setFieldValue("qty", q.qty);
                _ = try b.setFieldValue("total_cents", total_cents);
                _ = try b.setFieldValue("status", "pending");
                var row = try b.Save();
                defer zent.codegen.deinitEntity(persist.infos, persist.OrderInfo, &row, self.client.allocator);
                break :blk row.id;
            };

            // Nested beginTx on the same connection degrades to a SAVEPOINT:
            // the stock decrement is its own unit that can be rolled back
            // without aborting the outer work.
            var inner = zent.codegen.client.beginTx(persist.infos, self.client.*) catch |err| return http.respondErr(ctx, err);
            defer inner.deinit();
            {
                var u = inner.client.inventory.Update();
                defer u.deinit();
                _ = try u.setExprArgs("stock", "stock - ?", &.{.{ .int = q.qty }});
                _ = try u.Where(.{
                    inner.client.inventory.predicates.product_idEQ(.{ .int = q.product_id }),
                    inner.client.inventory.predicates.stockGTE(.{ .int = q.qty }),
                });
                const affected = try u.Save();
                if (affected == 0) {
                    // Insufficient stock: roll back the savepoint (only the
                    // decrement), then abort the whole order transaction.
                    inner.rollback() catch {};
                    tx.rollback() catch {};
                    try ctx.jsonStruct(409, .{ .ok = false, .reason = "insufficient_stock" });
                    return;
                }
            }
            try inner.commit(); // release savepoint -> decrement joins the order tx

            // Transaction-scoped events: enqueue inside the tx, deliver once
            // after commit via the after-commit hook.
            const ev_order = try std.fmt.allocPrint(ctx.allocator, "{{\"type\":\"order.created\",\"order_id\":{d},\"product_id\":{d},\"qty\":{d},\"total_cents\":{d}}}", .{ order_id, q.product_id, q.qty, total_cents });
            defer ctx.allocator.free(ev_order);
            try tx.enqueueEvent(ev_order);
            const ev_stock = try std.fmt.allocPrint(ctx.allocator, "{{\"type\":\"stock.decremented\",\"product_id\":{d},\"qty\":{d}}}", .{ q.product_id, q.qty });
            defer ctx.allocator.free(ev_stock);
            try tx.enqueueEvent(ev_stock);

            var ev_ctx = EvCtx{ .allocator = ctx.allocator, .tx = &tx };
            tx.afterCommit(&ev_ctx, EvCtx.onCommit);
            tx.commit() catch |err| return http.respondErr(ctx, err);

            try ctx.jsonStruct(201, .{ .id = order_id, .events_delivered = ev_ctx.delivered });
        }

        fn get(ctx: *http.Context, self: *State) !void {
            const id = try ctx.paramInt(i64, "id");
            var q = self.client.order.Query();
            defer q.deinit();
            _ = try q.Where(.{self.client.order.predicates.idEQ(.{ .int = id })});
            var row = (try q.First()) orelse return http.respondErr(ctx, error.NotFound);
            defer zent.codegen.deinitEntity(persist.infos, persist.OrderInfo, &row, self.client.allocator);
            try ctx.jsonStruct(200, row);
        }
    };
}

/// AccountApi: uuidv7 primary keys generated server-side (time-ordered,
/// safe across shards) and a `Sensitive` api_key that APIs must serialize
/// through `toMaskedJson` — the raw entity would leak the secret.
pub fn AccountApi(comptime Client: type) type {
    return struct {
        const Self = @This();

        client: *Client,
        io: std.Io,

        pub const module_name = "catalog";
        pub const nest = .{"accounts"};
        pub const State = Self;

        pub fn init(client: *Client, io: std.Io) Self {
            return .{ .client = client, .io = io };
        }

        const CreateAccountQ = struct {
            name: []const u8,
            api_key: []const u8,
        };

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .POST, .path = "", .handler = create, .meta = .{ .auth = .public } },
            .{ .method = .GET, .path = "{id}", .handler = get, .meta = .{ .auth = .public } },
        };

        fn nowMs(self: *const Self) i64 {
            const ts = std.Io.Timestamp.now(self.io, .real);
            return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
        }

        fn create(ctx: *http.Context, self: *State) !void {
            const q = http.extractQuery(ctx, CreateAccountQ) catch |err| return http.respondErr(ctx, err);
            var uuid_buf: [36]u8 = undefined;
            const id_str = zent.core.id.format(zent.core.id.uuidv7(self.nowMs()), &uuid_buf);
            var b = try self.client.account.Create();
            defer b.deinit();
            _ = try b.setFieldValue("id", id_str);
            _ = try b.setFieldValue("name", q.name);
            _ = try b.setFieldValue("api_key", q.api_key);
            var row = try b.Save();
            defer zent.codegen.deinitEntity(persist.infos, persist.AccountInfo, &row, self.client.allocator);
            try ctx.jsonStruct(201, .{ .id = row.id });
        }

        fn get(ctx: *http.Context, self: *State) !void {
            const id = try ctx.paramStr("id");
            var q = self.client.account.Query();
            defer q.deinit();
            _ = try q.Where(.{self.client.account.predicates.idEQ(.{ .string = id })});
            var row = (try q.First()) orelse return http.respondErr(ctx, error.NotFound);
            defer zent.codegen.deinitEntity(persist.infos, persist.AccountInfo, &row, self.client.allocator);
            const masked = try zent.codegen.toMaskedJson(ctx.allocator, persist.infos, persist.AccountInfo, row);
            defer ctx.allocator.free(masked);
            try ctx.json(200, masked);
        }
    };
}
