pub const Inventory = struct {
    id: i64,
    tenant_id: i64,
    product_id: i64,
    qty: i64,
    reserved: i64,
    updated_at: i64,

    pub const sql_table_name = "inventory";
};
