//! Commerce + social demos for zent v0.21-v0.26:
//!   - atomic expression updates (`setExprArgs`, oversell-safe stock
//!     decrement) and two-level nested eager loading (`WithEdge`);
//!   - edge filtering (`WhereRaw`) + per-parent order/limit;
//!   - composite keyset pagination (`CursorKeyset`) that survives ties;
//!   - bulk soft delete (`BulkDelete` + chunk-safe `IN`);
//!   - column projection (`Select`) and batch insert (`insertMany`).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const zent = @import("zent");

/// Serialize a zent entity array as a JSON array via zent's toMaskedJson —
/// raw entities cannot go through ctx.jsonStruct: the injected json_arena /
/// Allocator field makes std.json walk comptime-only fn pointers under
/// zig 0.17-dev.1422.
fn maskedArrayJson(
    allocator: std.mem.Allocator,
    comptime infos: []const zent.codegen.graph.TypeInfo,
    comptime info: zent.codegen.graph.TypeInfo,
    items: []const zent.codegen.entity(infos, info),
) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        const piece = try zent.codegen.toMaskedJson(allocator, infos, info, item);
        defer allocator.free(piece);
        try buf.appendSlice(allocator, piece);
    }
    try buf.append(allocator, ']');
    return try buf.toOwnedSlice(allocator);
}
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
            .{ .method = .GET, .path = "comments", .handler = comments, .meta = .{ .auth = .public } },
            .{ .method = .GET, .path = "trashed", .handler = trashed, .meta = .{ .auth = .public } },
            .{ .method = .POST, .path = "bulk-delete", .handler = bulkDelete, .meta = .{ .auth = .public } },
            .{ .method = .DELETE, .path = "{post_id}", .handler = softDeletePost, .meta = .{ .auth = .public } },
            .{ .method = .POST, .path = "{post_id}/restore", .handler = restorePost, .meta = .{ .auth = .public } },
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
            const arr = try maskedArrayJson(self.client.allocator, persist.infos, persist.AuthorInfo, rows.items);
            defer self.client.allocator.free(arr);
            const body = try std.fmt.allocPrint(self.client.allocator, "{{\"authors\":{s}}}", .{arr});
            defer self.client.allocator.free(body);
            try ctx.json(200, body);
        }

        const CommentsCursorQ = struct {
            cursor_ts: i64 = 0,
            cursor_id: i64 = 0,
            page_size: i64 = 2,
            desc: []const u8 = "",
        };

        /// Composite keyset pagination (v0.23): `WHERE (created_at > ?) OR
        /// (created_at = ? AND id > ?) ORDER BY created_at, id` — ties on the
        /// cursor column (same-second comments) are never dropped between
        /// pages. The response carries the next cursor to continue.
        fn comments(ctx: *http.Context, self: *State) !void {
            const q = http.extractQuery(ctx, CommentsCursorQ) catch |err| return http.respondErr(ctx, err);
            const desc = std.mem.eql(u8, q.desc, "1") or std.mem.eql(u8, q.desc, "true") or std.mem.eql(u8, q.desc, "desc");
            const page_size: usize = @intCast(@max(1, @min(50, q.page_size)));

            var qb = self.client.comment.Query();
            defer qb.deinit();
            // Only visible comments (mirrors the eager edge filter).
            _ = try qb.Where(.{self.client.comment.predicates.hiddenEQ(.{ .bool = false })});
            if (q.cursor_ts != 0 or q.cursor_id != 0) {
                _ = qb.CursorKeyset("created_at", .{ .int = q.cursor_ts }, q.cursor_id, desc);
            } else {
                _ = try qb.OrderBy(&.{ .{ .column = .{ .name = "created_at", .desc = desc } }, .{ .column = .{ .name = "id", .desc = desc } } });
            }
            _ = qb.Limit(page_size);

            const rows = try qb.All();
            defer {
                for (rows.items) |*c| zent.codegen.deinitEntity(persist.infos, persist.CommentInfo, c, self.client.allocator);
                rows.deinit();
            }
            const CommentEntity = zent.codegen.entity(persist.infos, persist.CommentInfo);
            const last: ?CommentEntity = if (rows.items.len > 0) rows.items[rows.items.len - 1] else null;
            const arr = try maskedArrayJson(self.client.allocator, persist.infos, persist.CommentInfo, rows.items);
            defer self.client.allocator.free(arr);
            const body = try std.fmt.allocPrint(self.client.allocator, "{{\"items\":{s},\"next_cursor_ts\":{d},\"next_cursor_id\":{d}}}", .{
                arr,
                if (last) |l| l.created_at else q.cursor_ts,
                if (last) |l| l.id else q.cursor_id,
            });
            defer self.client.allocator.free(body);
            try ctx.json(200, body);
        }

        const BulkDeleteBody = struct { ids: []i64 };

        /// Bulk soft delete (v0.26): one UPDATE sets deleted_at for every id
        /// in the IN list (chunk-safe; Post is a soft_delete entity).
        fn bulkDelete(ctx: *http.Context, self: *State) !void {
            const body = ctx.bindJson(BulkDeleteBody) catch return ctx.json(400, "{\"error\":\"invalid body\"}");
            if (body.ids.len == 0) return ctx.json(400, "{\"error\":\"ids required\"}");
            const values = try ctx.allocator.alloc(zent.sql.Value, body.ids.len);
            defer ctx.allocator.free(values);
            for (body.ids, 0..) |id, i| values[i] = .{ .int = id };
            var d = try self.client.post.BulkDelete();
            defer d.deinit();
            _ = try d.Where(.{zent.sql.In("id", values)});
            const affected = try d.Exec();
            try ctx.jsonStruct(200, .{ .soft_deleted = affected });
        }

        fn softDeletePost(ctx: *http.Context, self: *State) !void {
            const post_id = try ctx.paramInt(i64, "post_id");
            var d = self.client.post.Delete();
            defer d.deinit();
            _ = try d.Where(.{self.client.post.predicates.idEQ(.{ .int = post_id })});
            const affected = try d.Exec(); // soft delete (deleted_at = now)
            if (affected == 0) return http.respondErr(ctx, error.NotFound);
            try ctx.jsonStruct(200, .{ .deleted = post_id });
        }

        fn restorePost(ctx: *http.Context, self: *State) !void {
            const post_id = try ctx.paramInt(i64, "post_id");
            var d = self.client.post.Delete();
            defer d.deinit();
            if (!try d.Restore(post_id)) return http.respondErr(ctx, error.NotFound);
            try ctx.jsonStruct(200, .{ .restored = post_id });
        }

        fn trashed(ctx: *http.Context, self: *State) !void {
            var q = self.client.post.Query();
            defer q.deinit();
            _ = q.WithTrashed();
            const rows = try q.All();
            defer {
                for (rows.items) |*p| zent.codegen.deinitEntity(persist.infos, persist.PostInfo, p, self.client.allocator);
                rows.deinit();
            }
            const arr = try maskedArrayJson(self.client.allocator, persist.infos, persist.PostInfo, rows.items);
            defer self.client.allocator.free(arr);
            const body = try std.fmt.allocPrint(self.client.allocator, "{{\"trashed\":{s}}}", .{arr});
            defer self.client.allocator.free(body);
            try ctx.json(200, body);
        }
    };
}

/// GET /api/v1/products/summary — column projection (v0.26) skips the large
/// optional description field; unselected fields serialize as zero values.
pub fn SummaryApi(comptime Client: type) type {
    return struct {
        const Self = @This();

        client: *Client,

        pub const module_name = "catalog";
        pub const nest = .{"products"};
        pub const State = Self;

        pub fn init(client: *Client) Self {
            return .{ .client = client };
        }

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "summary", .handler = summary, .meta = .{ .auth = .public } },
        };

        fn summary(ctx: *http.Context, self: *State) !void {
            var q = self.client.product.Query();
            defer q.deinit();
            _ = q.Select(&.{ "id", "name", "price_cents" });
            const rows = try q.All();
            defer {
                for (rows.items) |*p| zent.codegen.deinitEntity(persist.infos, persist.ProductInfo, p, self.client.allocator);
                rows.deinit();
            }
            const arr = try maskedArrayJson(self.client.allocator, persist.infos, persist.ProductInfo, rows.items);
            defer self.client.allocator.free(arr);
            const body = try std.fmt.allocPrint(self.client.allocator, "{{\"summaries\":{s}}}", .{arr});
            defer self.client.allocator.free(body);
            try ctx.json(200, body);
        }
    };
}

/// POST /api/v1/products/batch — CrudService.insertMany (one INSERT
/// statement for many rows, v0.25).
pub fn BatchApi(comptime Crud: type) type {
    return struct {
        const Self = @This();

        crud: *Crud,

        pub const module_name = "catalog";
        pub const nest = .{"products"};
        pub const State = Self;

        pub fn init(crud: *Crud) Self {
            return .{ .crud = crud };
        }

        const BatchItem = struct {
            tenant_id: i64,
            name: []const u8,
            price_cents: i64,
        };

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .POST, .path = "batch", .handler = batch, .meta = .{ .auth = .public } },
        };

        fn batch(ctx: *http.Context, self: *State) !void {
            const Entity = zent.codegen.entity(persist.infos, persist.ProductInfo);
            const items = ctx.bindJson([]BatchItem) catch return ctx.json(400, "{\"error\":\"invalid body\"}");
            var entities = std.ArrayList(Entity).empty;
            defer entities.deinit(ctx.allocator);
            for (items) |it| {
                try entities.append(ctx.allocator, .{
                    .id = 0,
                    .tenant_id = it.tenant_id,
                    .name = it.name,
                    .price_cents = it.price_cents,
                    .description = null,
                    .created_by = null,
                    .updated_by = null,
                    .edges = .{},
                });
            }
            var ids = self.crud.insertMany(entities.items) catch |err| return http.respondErr(ctx, err);
            defer ids.deinit();
            try ctx.jsonStruct(201, .{ .ids = ids.items });
        }
    };
}
