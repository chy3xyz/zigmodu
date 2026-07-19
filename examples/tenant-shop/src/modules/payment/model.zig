pub const Payment = struct {
    id: i64,
    tenant_id: i64,
    order_id: i64,
    idempotency_key: []const u8,
    status: []const u8,
    amount_cents: i64,
    created_at: i64,

    pub const sql_table_name = "payments";
};
