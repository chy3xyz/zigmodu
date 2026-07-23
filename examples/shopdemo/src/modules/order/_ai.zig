// ═══════════════════════════════════════════════════════════
// AI Context: order module
// ═══════════════════════════════════════════════════════════
// Dependencies: &.{}
// Tables:
//   zmodu_order — 71 columns
//   zmodu_order_address — 11 columns
//   zmodu_order_advance — 27 columns
//   zmodu_order_delivery — 18 columns
//   zmodu_order_extract — 7 columns
//   zmodu_order_product — 59 columns
//   zmodu_order_refund — 26 columns
//   zmodu_order_refund_address — 7 columns
//   zmodu_order_refund_image — 5 columns
//   zmodu_order_settled — 17 columns
//   zmodu_order_trade — 10 columns
//
// Public API: service.zig
//   listZmoduOrders / getZmoduOrder / createZmoduOrder / updateZmoduOrder / deleteZmoduOrder
//   listZmoduOrderAddresss / getZmoduOrderAddress / createZmoduOrderAddress / updateZmoduOrderAddress / deleteZmoduOrderAddress
//   listZmoduOrderAdvances / getZmoduOrderAdvance / createZmoduOrderAdvance / updateZmoduOrderAdvance / deleteZmoduOrderAdvance
//   listZmoduOrderDeliverys / getZmoduOrderDelivery / createZmoduOrderDelivery / updateZmoduOrderDelivery / deleteZmoduOrderDelivery
//   listZmoduOrderExtracts / getZmoduOrderExtract / createZmoduOrderExtract / updateZmoduOrderExtract / deleteZmoduOrderExtract
//   listZmoduOrderProducts / getZmoduOrderProduct / createZmoduOrderProduct / updateZmoduOrderProduct / deleteZmoduOrderProduct
//   listZmoduOrderRefunds / getZmoduOrderRefund / createZmoduOrderRefund / updateZmoduOrderRefund / deleteZmoduOrderRefund
//   listZmoduOrderRefundAddresss / getZmoduOrderRefundAddress / createZmoduOrderRefundAddress / updateZmoduOrderRefundAddress / deleteZmoduOrderRefundAddress
//   listZmoduOrderRefundImages / getZmoduOrderRefundImage / createZmoduOrderRefundImage / updateZmoduOrderRefundImage / deleteZmoduOrderRefundImage
//   listZmoduOrderSettleds / getZmoduOrderSettled / createZmoduOrderSettled / updateZmoduOrderSettled / deleteZmoduOrderSettled
//   listZmoduOrderTrades / getZmoduOrderTrade / createZmoduOrderTrade / updateZmoduOrderTrade / deleteZmoduOrderTrade
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
