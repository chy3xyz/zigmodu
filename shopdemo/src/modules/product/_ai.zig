// ═══════════════════════════════════════════════════════════
// AI Context: product module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_product — 66 columns
//   zmodu_product_image — 6 columns
//   zmodu_product_reduce — 4 columns
//   zmodu_product_sku — 17 columns
//   zmodu_product_spec_rel — 6 columns
//   zmodu_product_virtual — 13 columns
//
// Public API: service.zig
//   listZmoduProducts / getZmoduProduct / createZmoduProduct / updateZmoduProduct / deleteZmoduProduct
//   listZmoduProductImages / getZmoduProductImage / createZmoduProductImage / updateZmoduProductImage / deleteZmoduProductImage
//   listZmoduProductReduces / getZmoduProductReduce / createZmoduProductReduce / updateZmoduProductReduce / deleteZmoduProductReduce
//   listZmoduProductSkus / getZmoduProductSku / createZmoduProductSku / updateZmoduProductSku / deleteZmoduProductSku
//   listZmoduProductSpecRels / getZmoduProductSpecRel / createZmoduProductSpecRel / updateZmoduProductSpecRel / deleteZmoduProductSpecRel
//   listZmoduProductVirtuals / getZmoduProductVirtual / createZmoduProductVirtual / updateZmoduProductVirtual / deleteZmoduProductVirtual
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
