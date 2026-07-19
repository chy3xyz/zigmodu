pub const User = struct {
    id: i64,
    tenant_id: i64,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
    role: []const u8,
    status: i32,
    created_at: i64,
    updated_at: i64,

    pub const sql_table_name = "users";
};
