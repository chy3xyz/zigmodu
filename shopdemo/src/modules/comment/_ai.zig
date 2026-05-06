// ═══════════════════════════════════════════════════════════
// AI Context: comment module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_comment — 18 columns
//   zmodu_comment_image — 5 columns
//
// Public API: service.zig
//   listZmoduComments / getZmoduComment / createZmoduComment / updateZmoduComment / deleteZmoduComment
//   listZmoduCommentImages / getZmoduCommentImage / createZmoduCommentImage / updateZmoduCommentImage / deleteZmoduCommentImage
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
