//! MariaDB/MySQL C bindings (minimal)

pub const MYSQL = opaque {};
pub const MYSQL_RES = opaque {};
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
pub const MYSQL_TYPE_BLOB = 252;

pub extern "c" fn mysql_init(mysql: ?*MYSQL) ?*MYSQL;
pub extern "c" fn mysql_real_connect(mysql: ?*MYSQL, host: [*c]const u8, user: [*c]const u8, passwd: [*c]const u8, db: [*c]const u8, port: c_uint, unix_socket: [*c]const u8, clientflag: c_ulong) ?*MYSQL;
pub extern "c" fn mysql_close(sock: ?*MYSQL) void;
pub extern "c" fn mysql_query(mysql: ?*MYSQL, q: [*c]const u8) c_int;
pub extern "c" fn mysql_real_query(mysql: ?*MYSQL, q: [*c]const u8, length: c_ulong) c_int;
pub extern "c" fn mysql_store_result(mysql: ?*MYSQL) ?*MYSQL_RES;
pub extern "c" fn mysql_free_result(res: ?*MYSQL_RES) void;
pub extern "c" fn mysql_fetch_row(res: ?*MYSQL_RES) MYSQL_ROW;
pub extern "c" fn mysql_fetch_lengths(res: ?*MYSQL_RES) [*c]c_ulong;
pub extern "c" fn mysql_num_fields(res: ?*MYSQL_RES) c_uint;
pub extern "c" fn mysql_num_rows(res: ?*MYSQL_RES) c_ulonglong;
pub extern "c" fn mysql_fetch_field(res: ?*MYSQL_RES) ?*MYSQL_FIELD;
pub extern "c" fn mysql_affected_rows(mysql: ?*MYSQL) c_ulonglong;
pub extern "c" fn mysql_insert_id(mysql: ?*MYSQL) c_ulonglong;
pub extern "c" fn mysql_error(mysql: ?*MYSQL) [*c]const u8;
pub extern "c" fn mysql_errno(mysql: ?*MYSQL) c_uint;
pub extern "c" fn mysql_autocommit(mysql: ?*MYSQL, auto_mode: bool) c_int;
pub extern "c" fn mysql_commit(mysql: ?*MYSQL) c_int;
pub extern "c" fn mysql_rollback(mysql: ?*MYSQL) c_int;
