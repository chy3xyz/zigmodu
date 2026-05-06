// ═══════════════════════════════════════════════════════════
// AI Context: page module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_page — 9 columns
//   zmodu_page_category — 6 columns
//
// Public API: service.zig
//   listZmoduPages / getZmoduPage / createZmoduPage / updateZmoduPage / deleteZmoduPage
//   listZmoduPageCategorys / getZmoduPageCategory / createZmoduPageCategory / updateZmoduPageCategory / deleteZmoduPageCategory
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
