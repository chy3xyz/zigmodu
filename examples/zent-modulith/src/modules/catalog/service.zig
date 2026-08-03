const std = @import("std");
const persist = @import("persistence.zig");

pub const CatalogService = struct {
    store: *persist.CatalogStore,

    pub fn init(store: *persist.CatalogStore) CatalogService {
        return .{ .store = store };
    }

    pub fn createTenant(self: *CatalogService, name: []const u8, domain: []const u8) !i64 {
        if (name.len == 0 or domain.len == 0) return error.InvalidInput;
        return try self.store.createTenant(name, domain);
    }

    pub fn freeProducts(self: *CatalogService, rows: []persist.CatalogStore.ProductRow) void {
        self.store.freeProducts(rows);
    }

    pub fn countProductsByTenant(self: *CatalogService) ![]persist.CatalogStore.CountRow {
        return try self.store.countProductsByTenant();
    }

    pub fn searchProducts(self: *CatalogService, tenant_id: i64, needle: []const u8) ![]persist.CatalogStore.ProductRow {
        if (tenant_id <= 0 or needle.len == 0) return error.InvalidInput;
        return try self.store.searchProducts(tenant_id, needle);
    }

    pub fn upsertProducts(self: *CatalogService, rows: []const persist.CatalogStore.ProductRow) !void {
        return try self.store.upsertProducts(rows);
    }
};
