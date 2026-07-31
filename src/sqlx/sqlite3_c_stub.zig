//! Stub SQLite3 bindings when `-Ddb=` disables sqlite (no libsqlite3 link).

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const SQLITE_OK = 0;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;
pub const SQLITE_INTEGER = 1;
pub const SQLITE_FLOAT = 2;
pub const SQLITE_TEXT = 3;
pub const SQLITE_BLOB = 4;
pub const SQLITE_NULL = 5;

pub fn sqlite3_open(_: [*c]const u8, _: ?*?*sqlite3) c_int {
    return 1;
}
pub fn sqlite3_close(_: ?*sqlite3) c_int {
    return 0;
}
pub fn sqlite3_exec(_: ?*sqlite3, _: [*c]const u8, _: ?*const anyopaque, _: ?*anyopaque, _: ?*[*c]u8) c_int {
    return 1;
}
pub fn sqlite3_prepare_v2(_: ?*sqlite3, _: [*]const u8, _: c_int, _: ?*?*sqlite3_stmt, _: ?*?*[*]const u8) c_int {
    return 1;
}
pub fn sqlite3_step(_: ?*sqlite3_stmt) c_int {
    return 1;
}
pub fn sqlite3_finalize(_: ?*sqlite3_stmt) c_int {
    return 0;
}
pub fn sqlite3_reset(_: ?*sqlite3_stmt) c_int {
    return 0;
}
pub fn sqlite3_clear_bindings(_: ?*sqlite3_stmt) c_int {
    return 0;
}
pub fn sqlite3_column_count(_: ?*sqlite3_stmt) c_int {
    return 0;
}
pub fn sqlite3_column_name(_: ?*sqlite3_stmt, _: c_int) [*c]const u8 {
    return "";
}
pub fn sqlite3_column_type(_: ?*sqlite3_stmt, _: c_int) c_int {
    return SQLITE_NULL;
}
pub fn sqlite3_column_int64(_: ?*sqlite3_stmt, _: c_int) i64 {
    return 0;
}
pub fn sqlite3_column_double(_: ?*sqlite3_stmt, _: c_int) f64 {
    return 0;
}
pub fn sqlite3_column_text(_: ?*sqlite3_stmt, _: c_int) [*c]const u8 {
    return "";
}
pub fn sqlite3_bind_int64(_: ?*sqlite3_stmt, _: c_int, _: i64) c_int {
    return 1;
}
pub fn sqlite3_bind_double(_: ?*sqlite3_stmt, _: c_int, _: f64) c_int {
    return 1;
}
pub fn sqlite3_bind_text(_: ?*sqlite3_stmt, _: c_int, _: [*]const u8, _: c_int, _: ?*const anyopaque) c_int {
    return 1;
}
pub fn sqlite3_bind_null(_: ?*sqlite3_stmt, _: c_int) c_int {
    return 1;
}
pub fn sqlite3_changes(_: ?*sqlite3) c_int {
    return 0;
}
pub fn sqlite3_last_insert_rowid(_: ?*sqlite3) i64 {
    return 0;
}
pub fn sqlite3_errmsg(_: ?*sqlite3) [*c]const u8 {
    return "sqlite driver disabled";
}
pub fn sqlite3_extended_errcode(_: ?*sqlite3) c_int {
    return 1;
}
pub fn sqlite3_free(_: ?*anyopaque) void {}
