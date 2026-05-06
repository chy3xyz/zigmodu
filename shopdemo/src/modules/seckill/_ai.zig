// ═══════════════════════════════════════════════════════════
// AI Context: seckill module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_seckill_activity — 14 columns
//   zmodu_seckill_product — 17 columns
//   zmodu_seckill_product_sku — 13 columns
//   zmodu_seckill_time — 8 columns
//
// Public API: service.zig
//   listZmoduSeckillActivitys / getZmoduSeckillActivity / createZmoduSeckillActivity / updateZmoduSeckillActivity / deleteZmoduSeckillActivity
//   listZmoduSeckillProducts / getZmoduSeckillProduct / createZmoduSeckillProduct / updateZmoduSeckillProduct / deleteZmoduSeckillProduct
//   listZmoduSeckillProductSkus / getZmoduSeckillProductSku / createZmoduSeckillProductSku / updateZmoduSeckillProductSku / deleteZmoduSeckillProductSku
//   listZmoduSeckillTimes / getZmoduSeckillTime / createZmoduSeckillTime / updateZmoduSeckillTime / deleteZmoduSeckillTime
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
