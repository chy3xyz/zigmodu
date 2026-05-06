// ═══════════════════════════════════════════════════════════
// AI Context: chat module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_chat — 11 columns
//   zmodu_chat_relation — 7 columns
//   zmodu_chat_user — 14 columns
//
// Public API: service.zig
//   listZmoduChats / getZmoduChat / createZmoduChat / updateZmoduChat / deleteZmoduChat
//   listZmoduChatRelations / getZmoduChatRelation / createZmoduChatRelation / updateZmoduChatRelation / deleteZmoduChatRelation
//   listZmoduChatUsers / getZmoduChatUser / createZmoduChatUser / updateZmoduChatUser / deleteZmoduChatUser
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
