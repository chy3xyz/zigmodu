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

    pub fn createProduct(self: *CatalogService, tenant_id: i64, name: []const u8, price_cents: i64) !i64 {
        if (tenant_id <= 0 or name.len == 0 or price_cents < 0) return error.InvalidInput;
        return try self.store.createProduct(tenant_id, name, price_cents);
    }

    pub fn listProducts(self: *CatalogService, tenant_id: i64) ![]persist.CatalogStore.ProductRow {
        if (tenant_id <= 0) return error.InvalidInput;
        return try self.store.listProducts(tenant_id);
    }

    pub fn freeProducts(self: *CatalogService, rows: []persist.CatalogStore.ProductRow) void {
        self.store.freeProducts(rows);
    }
};
