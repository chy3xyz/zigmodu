pub const Product = struct {
    id: i64,
    tenant_id: i64,
    name: []const u8,
    price_cents: i64,
    status: i32,
    created_at: i64,
    updated_at: i64,

    pub const sql_table_name = "products";
};
