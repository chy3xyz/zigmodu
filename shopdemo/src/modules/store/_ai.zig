// ═══════════════════════════════════════════════════════════
// AI Context: store module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_store — 22 columns
//   zmodu_store_clerk — 11 columns
//   zmodu_store_order — 11 columns
//
// Public API: service.zig
//   listZmoduStores / getZmoduStore / createZmoduStore / updateZmoduStore / deleteZmoduStore
//   listZmoduStoreClerks / getZmoduStoreClerk / createZmoduStoreClerk / updateZmoduStoreClerk / deleteZmoduStoreClerk
//   listZmoduStoreOrders / getZmoduStoreOrder / createZmoduStoreOrder / updateZmoduStoreOrder / deleteZmoduStoreOrder
//
// Extension points:
//   service_ext.zig — custom business logic (survives regeneration)
//   api_ext.zig — custom HTTP endpoints (survives regeneration)
//
// File map:
//   module.zig — declaration layer (module contract)
//   model.zig — data structures + jsonStringify
//   persistence.zig — ORM repositories
//   service.zig — CRUD delegation + event hooks
//   api.zig — HTTP routes + JSON handlers
//   root.zig — barrel exports
//   test.zig — smoke tests
// ═══════════════════════════════════════════════════════════
