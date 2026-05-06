// ═══════════════════════════════════════════════════════════
// AI Context: delivery module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_delivery — 8 columns
//   zmodu_delivery_rule — 9 columns
//   zmodu_delivery_setting — 16 columns
//   zmodu_delivery_template — 9 columns
//
// Public API: service.zig
//   listZmoduDeliverys / getZmoduDelivery / createZmoduDelivery / updateZmoduDelivery / deleteZmoduDelivery
//   listZmoduDeliveryRules / getZmoduDeliveryRule / createZmoduDeliveryRule / updateZmoduDeliveryRule / deleteZmoduDeliveryRule
//   listZmoduDeliverySettings / getZmoduDeliverySetting / createZmoduDeliverySetting / updateZmoduDeliverySetting / deleteZmoduDeliverySetting
//   listZmoduDeliveryTemplates / getZmoduDeliveryTemplate / createZmoduDeliveryTemplate / updateZmoduDeliveryTemplate / deleteZmoduDeliveryTemplate
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
