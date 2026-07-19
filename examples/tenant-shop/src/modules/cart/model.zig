pub const Cart = struct {
    id: i64,
    tenant_id: i64,
    user_id: i64,
    updated_at: i64,

    pub const sql_table_name = "carts";
};

pub const CartItem = struct {
    id: i64,
    tenant_id: i64,
    cart_id: i64,
    product_id: i64,
    qty: i64,

    pub const sql_table_name = "cart_items";
};
