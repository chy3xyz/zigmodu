// ═══════════════════════════════════════════════════════════
// AI Context: coupon module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_coupon — 26 columns
//
// Public API: service.zig
//   listZmoduCoupons / getZmoduCoupon / createZmoduCoupon / updateZmoduCoupon / deleteZmoduCoupon
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
