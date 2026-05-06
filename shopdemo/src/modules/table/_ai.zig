// ═══════════════════════════════════════════════════════════
// AI Context: table module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_table — 9 columns
//   zmodu_table_record — 8 columns
//
// Public API: service.zig
//   listZmoduTables / getZmoduTable / createZmoduTable / updateZmoduTable / deleteZmoduTable
//   listZmoduTableRecords / getZmoduTableRecord / createZmoduTableRecord / updateZmoduTableRecord / deleteZmoduTableRecord
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
