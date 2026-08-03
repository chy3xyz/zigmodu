//! Commerce + social demos for the two zent capabilities added in v0.21:
//! atomic expression updates (`setExprArgs`, oversell-safe stock decrement)
//! and two-level nested eager loading (`WithEdge("posts.comments")`).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const zent = @import("zent");
const persist = @import("modules/catalog/persistence.zig");

/// InventoryApi: GET /api/v1/inventory/{product_id} and
/// POST /api/v1/inventory/decrement?product_id=&qty= — the decrement runs
/// `SET stock = stock - ? WHERE id = ? AND stock >= ?` in one statement;
/// 0 affected rows means insufficient stock (no oversell).
pub fn InventoryApi(comptime Client: type) type {
    return struct {
        const Self = @This();

        client: *Client,

        pub const module_name = "catalog";
        pub const nest = .{"inventory"};
        pub const State = Self;

        pub fn init(client: *Client) Self {
            return .{ .client = client };
        }

        const DecrementQ = struct { product_id: i64, qty: i64 };

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "{product_id}", .handler = get, .meta = .{ .auth = .public } },
            .{ .method = .POST, .path = "decrement", .handler = decrement, .meta = .{ .auth = .public } },
        };

        fn findByProduct(client: *Client, product_id: i64) !?zent.codegen.entity(persist.infos, persist.InventoryInfo) {
            const inv = client.inventory;
            var q = inv.Query();
            defer q.deinit();
            _ = try q.Where(.{inv.predicates.product_idEQ(.{ .int = product_id })});
            return q.First();
        }

        fn get(ctx: *http.Context, self: *State) !void {
            const product_id = try ctx.paramInt(i64, "product_id");
            var inv = (try findByProduct(self.client, product_id)) orelse return http.respondErr(ctx, error.NotFound);
            defer zent.codegen.deinitEntity(persist.infos, persist.InventoryInfo, &inv, self.client.allocator);
            try ctx.jsonStruct(200, .{ .product_id = product_id, .stock = inv.stock, .version = inv.version });
        }

        fn decrement(ctx: *http.Context, self: *State) !void {
            const q = http.extractQuery(ctx, DecrementQ) catch |err| return http.respondErr(ctx, err);
            if (q.qty <= 0) return http.respondErr(ctx, error.InvalidQuantity);
            var inv = (try findByProduct(self.client, q.product_id)) orelse return http.respondErr(ctx, error.NotFound);
            defer zent.codegen.deinitEntity(persist.infos, persist.InventoryInfo, &inv, self.client.allocator);

            const ec = self.client.inventory;
            var u = ec.Update();
            defer u.deinit();
            _ = try u.setExprArgs("stock", "stock - ?", &.{.{ .int = q.qty }});
            _ = try u.Where(.{ ec.predicates.idEQ(.{ .int = inv.id }), ec.predicates.stockGTE(.{ .int = q.qty }) });
            const affected = try u.Save();
            if (affected == 0) {
                try ctx.jsonStruct(409, .{ .ok = false, .reason = "insufficient_stock", .stock = inv.stock });
                return;
            }
            try ctx.jsonStruct(200, .{ .ok = true, .decremented = q.qty, .remaining = inv.stock - q.qty });
        }
    };
}

/// FeedApi: GET /api/v1/feed/authors — one query + one IN query per level
/// (`WithEdge("posts.comments")`), serialized as nested JSON.
pub fn FeedApi(comptime Client: type) type {
    return struct {
        const Self = @This();

        client: *Client,

        pub const module_name = "catalog";
        pub const nest = .{"feed"};
        pub const State = Self;

        pub fn init(client: *Client) Self {
            return .{ .client = client };
        }

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "authors", .handler = authors, .meta = .{ .auth = .public } },
        };

        fn authors(ctx: *http.Context, self: *State) !void {
            var q = self.client.author.Query();
            defer q.deinit();
            _ = try q.WithEdge("posts.comments");
            const rows = try q.All();
            defer {
                for (rows.items) |*a| zent.codegen.deinitEntity(persist.infos, persist.AuthorInfo, a, self.client.allocator);
                rows.deinit();
            }
            try ctx.jsonStruct(200, .{ .authors = rows.items });
        }
    };
}
