// ═══════════════════════════════════════════════════════════
// AI Context: app module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_app — 23 columns
//   zmodu_app_mp — 11 columns
//   zmodu_app_open — 16 columns
//   zmodu_app_update — 10 columns
//   zmodu_app_wx — 11 columns
//   zmodu_app_wx_live — 14 columns
//
// Public API: service.zig
//   listZmoduApps / getZmoduApp / createZmoduApp / updateZmoduApp / deleteZmoduApp
//   listZmoduAppMps / getZmoduAppMp / createZmoduAppMp / updateZmoduAppMp / deleteZmoduAppMp
//   listZmoduAppOpens / getZmoduAppOpen / createZmoduAppOpen / updateZmoduAppOpen / deleteZmoduAppOpen
//   listZmoduAppUpdates / getZmoduAppUpdate / createZmoduAppUpdate / updateZmoduAppUpdate / deleteZmoduAppUpdate
//   listZmoduAppWxs / getZmoduAppWx / createZmoduAppWx / updateZmoduAppWx / deleteZmoduAppWx
//   listZmoduAppWxLives / getZmoduAppWxLive / createZmoduAppWxLive / updateZmoduAppWxLive / deleteZmoduAppWxLive
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
