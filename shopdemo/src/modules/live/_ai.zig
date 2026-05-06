// ═══════════════════════════════════════════════════════════
// AI Context: live module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_live_gift — 10 columns
//   zmodu_live_plan — 10 columns
//   zmodu_live_plan_order — 19 columns
//   zmodu_live_product — 6 columns
//   zmodu_live_room — 32 columns
//   zmodu_live_room_gift — 8 columns
//   zmodu_live_user_gift — 7 columns
//
// Public API: service.zig
//   listZmoduLiveGifts / getZmoduLiveGift / createZmoduLiveGift / updateZmoduLiveGift / deleteZmoduLiveGift
//   listZmoduLivePlans / getZmoduLivePlan / createZmoduLivePlan / updateZmoduLivePlan / deleteZmoduLivePlan
//   listZmoduLivePlanOrders / getZmoduLivePlanOrder / createZmoduLivePlanOrder / updateZmoduLivePlanOrder / deleteZmoduLivePlanOrder
//   listZmoduLiveProducts / getZmoduLiveProduct / createZmoduLiveProduct / updateZmoduLiveProduct / deleteZmoduLiveProduct
//   listZmoduLiveRooms / getZmoduLiveRoom / createZmoduLiveRoom / updateZmoduLiveRoom / deleteZmoduLiveRoom
//   listZmoduLiveRoomGifts / getZmoduLiveRoomGift / createZmoduLiveRoomGift / updateZmoduLiveRoomGift / deleteZmoduLiveRoomGift
//   listZmoduLiveUserGifts / getZmoduLiveUserGift / createZmoduLiveUserGift / updateZmoduLiveUserGift / deleteZmoduLiveUserGift
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
