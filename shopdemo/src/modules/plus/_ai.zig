// ═══════════════════════════════════════════════════════════
// AI Context: plus module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_plus_category — 7 columns
//   zmodu_plus_wx_collection — 4 columns
//
// Public API: service.zig
//   listZmoduPlusCategorys / getZmoduPlusCategory / createZmoduPlusCategory / updateZmoduPlusCategory / deleteZmoduPlusCategory
//   listZmoduPlusWxCollections / getZmoduPlusWxCollection / createZmoduPlusWxCollection / updateZmoduPlusWxCollection / deleteZmoduPlusWxCollection
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
