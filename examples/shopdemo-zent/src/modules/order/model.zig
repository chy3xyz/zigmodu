//! zent Schema-as-code — order domain for the ZigModu + zent shopdemo-zent parallel.
//!
//! Mirrors `examples/shopdemo/src/modules/order/` but uses zent as the
//! data layer. Order and OrderItem are linked via `order_no` (no edges —
//! zent's String FK is sufficient for this single-module example).
const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const Order = Schema("Order", .{
    .fields = &.{
        field.String("order_no"),
        field.String("status"),
        field.Int("amount_cents"),
        field.Int("user_id"),
    },
});

pub const OrderItem = Schema("OrderItem", .{
    .fields = &.{
        field.String("order_no"),
        field.String("sku"),
        field.Int("qty"),
        field.Int("unit_price_cents"),
    },
});
