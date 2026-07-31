//! Stub MySQL bindings when mysql driver is disabled (no libmysqlclient link).

pub const MYSQL = opaque {};
pub const MYSQL_RES = opaque {};
pub const MYSQL_STMT = opaque {};
pub const MYSQL_ROW = ?[*]?[*]u8;
pub const MYSQL_FIELD = extern struct {
    name: [*c]u8,
    org_name: [*c]u8,
    table: [*c]u8,
    org_table: [*c]u8,
    db: [*c]u8,
    catalog: [*c]u8,
    def: [*c]u8,
    length: c_ulong,
    max_length: c_ulong,
    name_length: c_uint,
    org_name_length: c_uint,
    table_length: c_uint,
    org_table_length: c_uint,
    db_length: c_uint,
    catalog_length: c_uint,
    def_length: c_uint,
    flags: c_uint,
    decimals: c_uint,
    charsetnr: c_uint,
    type: c_int,
};

pub const enum_field_types = c_int;
pub const MYSQL_TYPE_NULL = 6;
pub const MYSQL_TYPE_LONG = 3;
pub const MYSQL_TYPE_LONGLONG = 8;
pub const MYSQL_TYPE_DOUBLE = 5;
pub const MYSQL_TYPE_VAR_STRING = 253;
pub const MYSQL_TYPE_STRING = 254;
pub const MYSQL_TYPE_VARCHAR = 15;
pub const MYSQL_TYPE_TINY = 1;
pub const MYSQL_TYPE_SHORT = 2;
pub const MYSQL_TYPE_FLOAT = 4;
pub const MYSQL_TYPE_DECIMAL = 0;
pub const MYSQL_TYPE_TIMESTAMP = 7;
pub const MYSQL_TYPE_DATE = 10;
pub const MYSQL_TYPE_TIME = 11;
pub const MYSQL_TYPE_DATETIME = 12;
pub const MYSQL_TYPE_BIT = 16;
pub const MYSQL_TYPE_JSON = 245;
pub const MYSQL_TYPE_NEWDECIMAL = 246;
pub const MYSQL_TYPE_ENUM = 247;
pub const MYSQL_TYPE_SET = 248;
pub const MYSQL_TYPE_TINY_BLOB = 249;
pub const MYSQL_TYPE_MEDIUM_BLOB = 250;
pub const MYSQL_TYPE_LONG_BLOB = 251;
pub const MYSQL_TYPE_BLOB = 252;

pub const UNSIGNED_FLAG: c_uint = 32;
pub const NOT_NULL_FLAG: c_uint = 1;
pub const my_bool = u8;
pub const MYSQL_NO_DATA: c_int = 100;
pub const MYSQL_DATA_TRUNCATED: c_int = 101;
pub const MYSQL_OPT_CONNECT_TIMEOUT: c_int = 0;
pub const MYSQL_OPT_READ_TIMEOUT: c_int = 11;
pub const MYSQL_OPT_SSL_MODE: c_int = 1053;
pub const SSL_MODE_DISABLED: c_int = 1;
pub const SSL_MODE_PREFERRED: c_int = 2;
pub const SSL_MODE_REQUIRED: c_int = 3;

pub const MYSQL_BIND = extern struct {
    length: ?*c_ulong = null,
    is_null: ?*my_bool = null,
    buffer: ?*anyopaque = null,
    @"error": ?*my_bool = null,
    u: extern union {
        row_ptr: ?[*]u8,
        indicator: ?[*]u8,
    } = .{ .row_ptr = null },
    store_param_func: ?*anyopaque = null,
    fetch_result: ?*anyopaque = null,
    skip_result: ?*anyopaque = null,
    buffer_length: c_ulong = 0,
    offset: c_ulong = 0,
    length_value: c_ulong = 0,
    flags: c_uint = 0,
    pack_length: c_uint = 0,
    buffer_type: c_int = 0,
    error_value: my_bool = 0,
    is_unsigned: my_bool = 0,
    long_data_used: my_bool = 0,
    is_null_value: my_bool = 0,
    extension: ?*anyopaque = null,
};

pub fn mysql_init(_: ?*MYSQL) ?*MYSQL {
    return null;
}
pub fn mysql_real_connect(_: ?*MYSQL, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: c_uint, _: [*c]const u8, _: c_ulong) ?*MYSQL {
    return null;
}
pub fn mysql_close(_: ?*MYSQL) void {}
pub fn mysql_query(_: ?*MYSQL, _: [*c]const u8) c_int {
    return 1;
}
pub fn mysql_real_query(_: ?*MYSQL, _: [*c]const u8, _: c_ulong) c_int {
    return 1;
}
pub fn mysql_store_result(_: ?*MYSQL) ?*MYSQL_RES {
    return null;
}
pub fn mysql_use_result(_: ?*MYSQL) ?*MYSQL_RES {
    return null;
}
pub fn mysql_free_result(_: ?*MYSQL_RES) void {}
pub fn mysql_fetch_row(_: ?*MYSQL_RES) MYSQL_ROW {
    return null;
}
pub fn mysql_fetch_lengths(_: ?*MYSQL_RES) [*c]c_ulong {
    const s = struct {
        var z: c_ulong = 0;
    };
    return &s.z;
}
pub fn mysql_num_fields(_: ?*MYSQL_RES) c_uint {
    return 0;
}
pub fn mysql_num_rows(_: ?*MYSQL_RES) c_ulonglong {
    return 0;
}
pub fn mysql_fetch_field(_: ?*MYSQL_RES) ?*MYSQL_FIELD {
    return null;
}
pub fn mysql_fetch_fields(_: ?*MYSQL_RES) ?[*]MYSQL_FIELD {
    return null;
}
pub fn mysql_affected_rows(_: ?*MYSQL) c_ulonglong {
    return 0;
}
pub fn mysql_insert_id(_: ?*MYSQL) c_ulonglong {
    return 0;
}
pub fn mysql_error(_: ?*MYSQL) [*c]const u8 {
    return "mysql driver disabled";
}
pub fn mysql_errno(_: ?*MYSQL) c_uint {
    return 1;
}
pub fn mysql_field_count(_: ?*MYSQL) c_uint {
    return 0;
}
pub fn mysql_autocommit(_: ?*MYSQL, _: bool) c_int {
    return 1;
}
pub fn mysql_commit(_: ?*MYSQL) c_int {
    return 1;
}
pub fn mysql_rollback(_: ?*MYSQL) c_int {
    return 1;
}
pub fn mysql_stmt_init(_: ?*MYSQL) ?*MYSQL_STMT {
    return null;
}
pub fn mysql_stmt_prepare(_: ?*MYSQL_STMT, _: [*c]const u8, _: c_ulong) c_int {
    return 1;
}
pub fn mysql_stmt_bind_param(_: ?*MYSQL_STMT, _: [*]MYSQL_BIND) my_bool {
    return 1;
}
pub fn mysql_stmt_bind_result(_: ?*MYSQL_STMT, _: [*]MYSQL_BIND) my_bool {
    return 1;
}
pub fn mysql_stmt_execute(_: ?*MYSQL_STMT) c_int {
    return 1;
}
pub fn mysql_stmt_store_result(_: ?*MYSQL_STMT) c_int {
    return 1;
}
pub fn mysql_stmt_fetch(_: ?*MYSQL_STMT) c_int {
    return 1;
}
pub fn mysql_stmt_fetch_column(_: ?*MYSQL_STMT, _: [*c]MYSQL_BIND, _: c_uint, _: c_ulong) c_int {
    return 1;
}
pub fn mysql_stmt_free_result(_: ?*MYSQL_STMT) my_bool {
    return 0;
}
pub fn mysql_stmt_close(_: ?*MYSQL_STMT) my_bool {
    return 0;
}
pub fn mysql_stmt_reset(_: ?*MYSQL_STMT) my_bool {
    return 0;
}
pub fn mysql_stmt_param_count(_: ?*MYSQL_STMT) c_ulong {
    return 0;
}
pub fn mysql_stmt_field_count(_: ?*MYSQL_STMT) c_uint {
    return 0;
}
pub fn mysql_stmt_affected_rows(_: ?*MYSQL_STMT) c_ulonglong {
    return 0;
}
pub fn mysql_stmt_insert_id(_: ?*MYSQL_STMT) c_ulonglong {
    return 0;
}
pub fn mysql_stmt_errno(_: ?*MYSQL_STMT) c_uint {
    return 1;
}
pub fn mysql_stmt_error(_: ?*MYSQL_STMT) [*c]const u8 {
    return "mysql driver disabled";
}
pub fn mysql_stmt_result_metadata(_: ?*MYSQL_STMT) ?*MYSQL_RES {
    return null;
}
pub fn mysql_stmt_num_rows(_: ?*MYSQL_STMT) c_ulonglong {
    return 0;
}
pub fn mysql_options(_: ?*MYSQL, _: c_int, _: ?*const anyopaque) c_int {
    return 1;
}
pub fn mysql_set_character_set(_: ?*MYSQL, _: [*c]const u8) c_int {
    return 1;
}
pub fn mysql_ping(_: ?*MYSQL) c_int {
    return 1;
}
