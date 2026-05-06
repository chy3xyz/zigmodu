// ═══════════════════════════════════════════════════════════
// AI Context: article module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_article — 15 columns
//   zmodu_article_category — 6 columns
//
// Public API: service.zig
//   listZmoduArticles / getZmoduArticle / createZmoduArticle / updateZmoduArticle / deleteZmoduArticle
//   listZmoduArticleCategorys / getZmoduArticleCategory / createZmoduArticleCategory / updateZmoduArticleCategory / deleteZmoduArticleCategory
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
