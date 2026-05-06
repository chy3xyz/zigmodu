// ═══════════════════════════════════════════════════════════
// AI Context: message module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_message — 10 columns
//   zmodu_message_field — 10 columns
//   zmodu_message_settings — 13 columns
//
// Public API: service.zig
//   listZmoduMessages / getZmoduMessage / createZmoduMessage / updateZmoduMessage / deleteZmoduMessage
//   listZmoduMessageFields / getZmoduMessageField / createZmoduMessageField / updateZmoduMessageField / deleteZmoduMessageField
//   listZmoduMessageSettingss / getZmoduMessageSettings / createZmoduMessageSettings / updateZmoduMessageSettings / deleteZmoduMessageSettings
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
