//! Persistence over zent Client — SQL stays inside zent builders.
const std = @import("std");
const zent = @import("zent");
const model = @import("model.zig");

const graph = zent.codegen.graph.buildGraph(&.{
    model.Tenant,
    model.Product,
    model.Doc,
    zent.outbox.OutboxMessage,
    model.Author,
    model.Post,
    model.Comment,
    model.Inventory,
});
pub const infos = graph.types;
pub const Client = zent.codegen.client.Client(infos);
pub const ProductInfo = infos[1];
pub const DocInfo = infos[2];
pub const OutboxInfo = infos[3];
pub const AuthorInfo = infos[4];
pub const PostInfo = infos[5];
pub const CommentInfo = infos[6];
pub const InventoryInfo = infos[7];

pub const CatalogStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) CatalogStore {
        return .{
            .allocator = allocator,
            .client = client,
        };
    }

    pub fn createTenant(self: *CatalogStore, name: []const u8, domain: []const u8) !i64 {
        var b = try self.client.tenant.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("domain", domain);
        const row = try b.Save();
        return row.id;
    }

    pub const ProductRow = struct {
        id: i64,
        tenant_id: i64,
        name: []const u8,
        price_cents: i64,
    };

    pub fn freeProducts(self: *CatalogStore, rows: []ProductRow) void {
        for (rows) |r| self.allocator.free(r.name);
        self.allocator.free(rows);
    }

    pub const CountRow = struct { tenant_id: i64, count: i64 };

    /// zent CountBy(): 单条 GROUP BY 替代 N 次 Count。
    pub fn countProductsByTenant(self: *CatalogStore) ![]CountRow {
        var q = self.client.product.Query();
        defer q.deinit();
        var counts = try q.CountBy("tenant_id");
        defer counts.deinit();
        const out = try self.allocator.alloc(CountRow, counts.items.len);
        for (counts.items, 0..) |g, i| out[i] = .{ .tenant_id = g.key, .count = g.count };
        return out;
    }

    /// zent ContainsEscaped：LIKE 通配符在渲染期转义，用户输入 % _ 按字面匹配。
    pub fn searchProducts(self: *CatalogStore, tenant_id: i64, needle: []const u8) ![]ProductRow {
        var q = self.client.product.Query();
        defer q.deinit();
        const preds = self.client.product.predicates;
        _ = try q.Where(.{ preds.tenant_idEQ(.{ .int = tenant_id }), preds.nameContainsEscaped(needle) });
        var found = try q.All();
        defer {
            for (found.items) |*p| {
                zent.codegen.deinitEntity(infos, ProductInfo, p, self.allocator);
            }
            found.deinit();
        }
        var out = try self.allocator.alloc(ProductRow, found.items.len);
        errdefer self.allocator.free(out);
        for (found.items, 0..) |*p, i| {
            out[i] = .{
                .id = p.id,
                .tenant_id = p.tenant_id,
                .name = try self.allocator.dupe(u8, p.name),
                .price_cents = p.price_cents,
            };
        }
        return out;
    }

    /// zent BulkInsert.SaveOrUpdate：批量 upsert，一次多行 SQL。
    pub fn upsertProducts(self: *CatalogStore, rows: []const ProductRow) !void {
        var b = try self.client.product.BulkInsert();
        defer b.deinit();
        for (rows) |r| {
            _ = try b.setFieldValue("id", r.id);
            _ = try b.setFieldValue("tenant_id", r.tenant_id);
            _ = try b.setFieldValue("name", r.name);
            _ = try b.setFieldValue("price_cents", r.price_cents);
            _ = try b.Next();
        }
        var ids = try b.SaveOrUpdate();
        defer ids.deinit();
    }
};
