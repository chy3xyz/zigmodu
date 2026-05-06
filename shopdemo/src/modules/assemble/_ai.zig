// ═══════════════════════════════════════════════════════════
// AI Context: assemble module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_assemble_bill — 10 columns
//   zmodu_assemble_bill_user — 11 columns
//   zmodu_assemble_product — 34 columns
//   zmodu_assemble_product_sku — 13 columns
//
// Public API: service.zig
//   listZmoduAssembleBills / getZmoduAssembleBill / createZmoduAssembleBill / updateZmoduAssembleBill / deleteZmoduAssembleBill
//   listZmoduAssembleBillUsers / getZmoduAssembleBillUser / createZmoduAssembleBillUser / updateZmoduAssembleBillUser / deleteZmoduAssembleBillUser
//   listZmoduAssembleProducts / getZmoduAssembleProduct / createZmoduAssembleProduct / updateZmoduAssembleProduct / deleteZmoduAssembleProduct
//   listZmoduAssembleProductSkus / getZmoduAssembleProductSku / createZmoduAssembleProductSku / updateZmoduAssembleProductSku / deleteZmoduAssembleProductSku
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
