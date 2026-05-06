// ═══════════════════════════════════════════════════════════
// AI Context: upload module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_upload_file — 17 columns
//   zmodu_upload_group — 9 columns
//
// Public API: service.zig
//   listZmoduUploadFiles / getZmoduUploadFile / createZmoduUploadFile / updateZmoduUploadFile / deleteZmoduUploadFile
//   listZmoduUploadGroups / getZmoduUploadGroup / createZmoduUploadGroup / updateZmoduUploadGroup / deleteZmoduUploadGroup
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
