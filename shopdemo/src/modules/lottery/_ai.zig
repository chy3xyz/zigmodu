// ═══════════════════════════════════════════════════════════
// AI Context: lottery module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_lottery — 16 columns
//   zmodu_lottery_prize — 21 columns
//   zmodu_lottery_record — 25 columns
//
// Public API: service.zig
//   listZmoduLotterys / getZmoduLottery / createZmoduLottery / updateZmoduLottery / deleteZmoduLottery
//   listZmoduLotteryPrizes / getZmoduLotteryPrize / createZmoduLotteryPrize / updateZmoduLotteryPrize / deleteZmoduLotteryPrize
//   listZmoduLotteryRecords / getZmoduLotteryRecord / createZmoduLotteryRecord / updateZmoduLotteryRecord / deleteZmoduLotteryRecord
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
