// ═══════════════════════════════════════════════════════════
// AI Context: balance module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_balance_order — 17 columns
//   zmodu_balance_plan — 10 columns
//
// Public API: service.zig
//   listZmoduBalanceOrders / getZmoduBalanceOrder / createZmoduBalanceOrder / updateZmoduBalanceOrder / deleteZmoduBalanceOrder
//   listZmoduBalancePlans / getZmoduBalancePlan / createZmoduBalancePlan / updateZmoduBalancePlan / deleteZmoduBalancePlan
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
