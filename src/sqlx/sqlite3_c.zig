//! SQLite3 C bindings (minimal)

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

pub extern "c" fn sqlite3_open(filename: [*c]const u8, db: ?*?*sqlite3) c_int;
pub extern "c" fn sqlite3_close(db: ?*sqlite3) c_int;
pub extern "c" fn sqlite3_exec(db: ?*sqlite3, sql: [*c]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*[*c]u8) c_int;
pub extern "c" fn sqlite3_prepare_v2(db: ?*sqlite3, sql: [*]const u8, nByte: c_int, stmt: ?*?*sqlite3_stmt, tail: ?*?*[*]const u8) c_int;
pub extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_column_count(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_column_name(stmt: ?*sqlite3_stmt, iCol: c_int) [*c]const u8;
pub extern "c" fn sqlite3_column_type(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
pub extern "c" fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) i64;
pub extern "c" fn sqlite3_column_double(stmt: ?*sqlite3_stmt, iCol: c_int) f64;
pub extern "c" fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) [*c]const u8;
pub extern "c" fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, val: i64) c_int;
pub extern "c" fn sqlite3_bind_double(stmt: ?*sqlite3_stmt, idx: c_int, val: f64) c_int;
pub extern "c" fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, val: [*]const u8, n: c_int, dtor: ?*const anyopaque) c_int;
pub extern "c" fn sqlite3_bind_null(stmt: ?*sqlite3_stmt, idx: c_int) c_int;
pub extern "c" fn sqlite3_changes(db: ?*sqlite3) c_int;
pub extern "c" fn sqlite3_last_insert_rowid(db: ?*sqlite3) i64;
pub extern "c" fn sqlite3_errmsg(db: ?*sqlite3) [*c]const u8;
pub extern "c" fn sqlite3_free(ptr: ?*anyopaque) void;
