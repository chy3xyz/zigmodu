// ═══════════════════════════════════════════════════════════
// AI Context: buy module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_buy_activity — 15 columns
//   zmodu_buy_activity_product — 9 columns
//
// Public API: service.zig
//   listZmoduBuyActivitys / getZmoduBuyActivity / createZmoduBuyActivity / updateZmoduBuyActivity / deleteZmoduBuyActivity
//   listZmoduBuyActivityProducts / getZmoduBuyActivityProduct / createZmoduBuyActivityProduct / updateZmoduBuyActivityProduct / deleteZmoduBuyActivityProduct
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
