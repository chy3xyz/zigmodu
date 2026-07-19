pub const Order = struct {
    id: i64,
    tenant_id: i64,
    user_id: i64,
    status: []const u8,
    total_cents: i64,
    created_at: i64,
    updated_at: i64,

    pub const sql_table_name = "orders";
};

pub const OrderItem = struct {
    id: i64,
    tenant_id: i64,
    order_id: i64,
    product_id: i64,
    qty: i64,
    price_cents: i64,

    pub const sql_table_name = "order_items";
};
