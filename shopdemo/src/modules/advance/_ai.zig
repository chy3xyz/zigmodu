// ═══════════════════════════════════════════════════════════
// AI Context: advance module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_advance_product — 19 columns
//   zmodu_advance_product_sku — 11 columns
//
// Public API: service.zig
//   listZmoduAdvanceProducts / getZmoduAdvanceProduct / createZmoduAdvanceProduct / updateZmoduAdvanceProduct / deleteZmoduAdvanceProduct
//   listZmoduAdvanceProductSkus / getZmoduAdvanceProductSku / createZmoduAdvanceProductSku / updateZmoduAdvanceProductSku / deleteZmoduAdvanceProductSku
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
