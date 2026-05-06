// ═══════════════════════════════════════════════════════════
// AI Context: ad module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_ad — 12 columns
//   zmodu_ad_category — 5 columns
//
// Public API: service.zig
//   listZmoduAds / getZmoduAd / createZmoduAd / updateZmoduAd / deleteZmoduAd
//   listZmoduAdCategorys / getZmoduAdCategory / createZmoduAdCategory / updateZmoduAdCategory / deleteZmoduAdCategory
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
