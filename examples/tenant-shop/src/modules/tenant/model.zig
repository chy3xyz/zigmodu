pub const Tenant = struct {
    id: i64,
    name: []const u8,
    domain: []const u8,
    status: i32,
    tier: []const u8,
    created_at: i64,
    updated_at: i64,

    pub const sql_table_name = "tenants";
};
