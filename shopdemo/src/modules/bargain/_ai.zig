// ═══════════════════════════════════════════════════════════
// AI Context: bargain module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_bargain_product — 32 columns
//   zmodu_bargain_product_sku — 13 columns
//   zmodu_bargain_setting — 5 columns
//   zmodu_bargain_task — 24 columns
//   zmodu_bargain_task_help — 9 columns
//
// Public API: service.zig
//   listZmoduBargainProducts / getZmoduBargainProduct / createZmoduBargainProduct / updateZmoduBargainProduct / deleteZmoduBargainProduct
//   listZmoduBargainProductSkus / getZmoduBargainProductSku / createZmoduBargainProductSku / updateZmoduBargainProductSku / deleteZmoduBargainProductSku
//   listZmoduBargainSettings / getZmoduBargainSetting / createZmoduBargainSetting / updateZmoduBargainSetting / deleteZmoduBargainSetting
//   listZmoduBargainTasks / getZmoduBargainTask / createZmoduBargainTask / updateZmoduBargainTask / deleteZmoduBargainTask
//   listZmoduBargainTaskHelps / getZmoduBargainTaskHelp / createZmoduBargainTaskHelp / updateZmoduBargainTaskHelp / deleteZmoduBargainTaskHelp
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
