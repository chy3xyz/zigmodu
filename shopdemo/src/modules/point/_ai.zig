// ═══════════════════════════════════════════════════════════
// AI Context: point module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_point_product — 15 columns
//   zmodu_point_product_sku — 13 columns
//
// Public API: service.zig
//   listZmoduPointProducts / getZmoduPointProduct / createZmoduPointProduct / updateZmoduPointProduct / deleteZmoduPointProduct
//   listZmoduPointProductSkus / getZmoduPointProductSku / createZmoduPointProductSku / updateZmoduPointProductSku / deleteZmoduPointProductSku
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
