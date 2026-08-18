//! SQL client abstraction — aligned with go-zero's core/stores/sqlx.
//! Supports SQLite, PostgreSQL, and MySQL via C bindings.
//!
//! SECURITY: Always use parameterized queries with `?` placeholders.
//! Never concatenate user input directly into SQL strings.
//!
//!   // SAFE — parameterized:
//!   client.query("SELECT * FROM users WHERE name = ?", &.{Value.string(name)});
//!
//!   // UNSAFE — SQL injection risk:
//!   const sql = try std.fmt.allocPrint(alloc, "SELECT * FROM users WHERE name = '{s}'", .{name});
//!   client.query(sql, &.{}); // ← name may contain '; DROP TABLE users; --
//!
//! STRUCTURE (monolith — intentionally NOT split; see docs/PRODUCTION_ROADMAP.md):
//!   §1  Types        — Value, Row, Rows, ExecResult, Driver, Conn, Stmt
//!   §2  SQLiteConn   — SQLite connection + VTable
//!   §3  PostgresConn — PostgreSQL connection + VTable
//!   §4  MySqlConn    — MySQL connection + VTable
//!   §5  PreparedStmt — SQLiteStmt, PostgresStmt, MySqlStmt
//!   §6  ConnPool     — Connection pool with circuit breaker
//!   §7  Client       — Main client (init, query, exec, tx)
//!   §8  Transaction  — Transaction with rollback/savepoint
//!   §9  ORM Helpers  — Row scanning utilities
//!   §10 Tests
//!
//! MAINTENANCE (do NOT grow this file without reading the roadmap):
//!   - One PR should touch at most ONE § section.
//!   - New DB driver → new file under sqlx/ (e.g. sqlx/foo_conn.zig), register here only.
//!   - New ORM features → sqlx/orm.zig (or data layer), not ad-hoc helpers in §7.
//!   - ConnPool / Row arena / stmt cache changes → full `zig build test` required.

const std = @import("std");
const builtin = @import("builtin");
const Time = @import("../core/Time.zig");
const errors = @import("errors.zig");
const breaker = @import("breaker.zig");

const enable_sqlite = blk: {
    const bo = @import("build_options");
    break :blk if (@hasDecl(bo, "enable_sqlite")) bo.enable_sqlite else true;
};
const enable_postgres = blk: {
    const bo = @import("build_options");
    break :blk if (@hasDecl(bo, "enable_postgres")) bo.enable_postgres else true;
};
const enable_mysql = blk: {
    const bo = @import("build_options");
    break :blk if (@hasDecl(bo, "enable_mysql")) bo.enable_mysql else true;
};

const sqlite3_c = if (enable_sqlite) @import("sqlite3_c.zig") else @import("sqlite3_c_stub.zig");
const libpq_c = if (enable_postgres) @import("libpq_c.zig") else @import("libpq_c_stub.zig");
const libmysql_c = if (enable_mysql) @import("libmysql_c.zig") else @import("libmysql_c_stub.zig");

/// Compile-time driver feature flags (from `-Ddb=` / `build_options`).
pub const DriverFeatures = struct {
    pub const sqlite = enable_sqlite;
    pub const postgres = enable_postgres;
    pub const mysql = enable_mysql;

    pub fn isEnabled(d: Driver) bool {
        return switch (d) {
            .sqlite => sqlite,
            .postgres => postgres,
            .mysql => mysql,
        };
    }
};
/// Allocate null-terminated copy (replaces removed allocator.dupeZ in Zig 0.17).
fn allocZ(allocator: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, s.len, 0);
    @memcpy(result, s);
    return result;
}

/// Format into buffer with null terminator (replaces removed bufPrintZ in Zig 0.17).
/// Reserves the last byte for `\0` so a full format never writes past `buf.len`.
fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    if (buf.len == 0) return error.NoSpaceLeft;
    const written = try std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args);
    buf[written.len] = 0;
    return buf[0..written.len :0];
}

/// Allocate a formatted null-terminated string.
fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    return try allocZ(allocator, s);
}

/// Validates a SQL identifier (table/column name): `[A-Za-z_][A-Za-z0-9_.]*`.
/// The dot allows schema-qualified names (`public.users`).
pub fn validateIdentifier(name: []const u8) error{InvalidSqlIdentifier}!void {
    if (name.len == 0 or name.len > 128) return error.InvalidSqlIdentifier;
    for (name, 0..) |c, i| {
        const ok = switch (c) {
            'a'...'z', 'A'...'Z', '_' => true,
            '0'...'9', '.' => i > 0,
            else => false,
        };
        if (!ok) return error.InvalidSqlIdentifier;
    }
}

/// Defense-in-depth check for SQL fragments interpolated into query strings
/// (e.g. `where_clause` in findOne/findAll). Values MUST be passed via `?`
/// placeholders + args — string literals, statement separators and comments
/// are rejected to block injection through the fragment itself.
pub fn validateSqlFragment(fragment: []const u8) error{UnsafeSqlFragment}!void {
    if (fragment.len > 4096) return error.UnsafeSqlFragment;
    var i: usize = 0;
    while (i < fragment.len) : (i += 1) {
        switch (fragment[i]) {
            '\'', '"', ';', 0 => return error.UnsafeSqlFragment,
            '-' => if (i + 1 < fragment.len and fragment[i + 1] == '-') return error.UnsafeSqlFragment,
            '/' => if (i + 1 < fragment.len and fragment[i + 1] == '*') return error.UnsafeSqlFragment,
            else => {},
        }
    }
}

/// SQL value types for parameterized queries
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    string: []const u8,
    bool: bool,
};

/// Row of query results
pub const Row = struct {
    /// Pointer to the Rows arena. Stable across arena relocation (move from
    /// stack to Rows struct). Use .allocator() to get a working Allocator.
    arena: *std.heap.ArenaAllocator,
    columns: []const []const u8,
    values: []const ?Value,
    /// Single-entry lazy column-name → index cache for hot repeated lookups.
    cached_col: ?[]const u8 = null,
    cached_idx: usize = 0,

    pub fn rowAllocator(self: Row) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn get(self: *Row, column: []const u8) ?Value {
        if (self.cached_col) |c| {
            if (std.mem.eql(u8, c, column)) return self.values[self.cached_idx];
        }
        for (self.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col, column)) {
                self.cached_col = column;
                self.cached_idx = i;
                return self.values[i];
            }
        }
        return null;
    }

    pub fn scan(self: Row, allocator: std.mem.Allocator, comptime T: type) !T {
        return scanStruct(allocator, T, self, false, null, false);
    }

    pub fn scanPartial(self: Row, allocator: std.mem.Allocator, comptime T: type) !T {
        return scanStruct(allocator, T, self, true, null, false);
    }
};

/// Query results
pub const Rows = struct {
    arena: std.heap.ArenaAllocator,
    /// Mutable — queryRows/queryRow update row.arena to point to this Rows.arena.
    /// Using `[]Row` (not `[]const Row`) avoids @constCast which Zig 0.17-dev
    /// may optimize away in certain monomorphized instances.
    rows: []Row,

    pub fn deinit(self: *Rows) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// RAII managed wrapper for query results to guarantee memory release in current scope.
pub const ManagedRows = struct {
    rows: Rows,

    pub fn init(rows: Rows) ManagedRows {
        return .{ .rows = rows };
    }

    pub fn deinit(self: *ManagedRows) void {
        self.rows.deinit();
    }

    pub fn get(self: *const ManagedRows) []const Row {
        return self.rows.rows;
    }

    pub fn first(self: *const ManagedRows) ?*Row {
        if (self.rows.rows.len == 0) return null;
        return &self.rows.rows[0];
    }
};

/// RAII wrapper for a single scanned row whose `[]const u8` fields borrow an
/// arena owned by this wrapper (no per-field dupe, no `freeScanned` needed).
/// The value is valid until `deinit()`; `get()` returns a shallow copy (string
/// pointers still point into the arena). Prefer `queryRowBorrowed` /
/// `queryRowPartialBorrowed` when the row is consumed within a scope.
///
/// **Lifetime contract: a `BorrowedRow` must not escape its function scope**
/// — strings point into the wrapper-owned arena, so returning it (or storing
/// it beyond `deinit()`) leaves the caller with dangling pointers. For
/// cross-scope returns use the owned `queryRow`/`queryRowOwned` + `freeScanned`.
pub fn BorrowedRow(comptime T: type) type {
    return struct {
        value: T,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }

        /// Shallow copy of the scanned row. String fields remain valid until
        /// `deinit()`.
        pub fn get(self: *const @This()) T {
            return self.value;
        }
    };
}

/// Cursor fetch mode.
pub const CursorMode = enum {
    /// Materialize all rows upfront. Rows remain valid until `cursor.deinit()`.
    buffered,
    /// Fetch rows lazily from the driver. The row returned by `next()` is only
    /// valid until the next call to `next()` or `deinit()`.
    streaming,
};

/// Options for `Client.queryCursorEx`.
pub const CursorOptions = struct {
    mode: CursorMode = .buffered,
};

/// Batch insert strategy.
pub const BatchMode = enum {
    /// Build a single multi-row `INSERT ... VALUES (...), (...)` statement.
    sql,
    /// Use driver-native batch protocols (MySQL prepared-statement multi-execute
    /// or PostgreSQL `COPY FROM STDIN`).
    protocol,
};

/// Options for `Client.batchInsertEx`.
pub const BatchInsertOptions = struct {
    mode: BatchMode = .sql,
};

/// Streaming cursor over a query result set.
pub const Cursor = struct {
    state: State,
    pos: usize = 0,

    const State = union(enum) {
        buffered: Rows,
        streaming_mysql: MySqlCursor,
        streaming_pg: PgCursor,
    };

    pub fn init(rows: Rows) Cursor {
        return .{ .state = .{ .buffered = rows } };
    }

    pub fn deinit(self: *Cursor) void {
        switch (self.state) {
            .buffered => |*rows| rows.deinit(),
            .streaming_mysql => |*c| c.deinit(),
            .streaming_pg => |*c| c.deinit(),
        }
        self.* = undefined;
    }

    pub fn next(self: *Cursor) ?*Row {
        switch (self.state) {
            .buffered => |*rows| {
                if (self.pos >= rows.rows.len) return null;
                const row = &rows.rows[self.pos];
                self.pos += 1;
                return row;
            },
            .streaming_mysql => |*c| return c.next(),
            .streaming_pg => |*c| return c.next(),
        }
    }

    pub fn reset(self: *Cursor) void {
        switch (self.state) {
            .buffered => self.pos = 0,
            .streaming_mysql, .streaming_pg => {}, // forward-only
        }
    }
};

/// Driver-native streaming cursor for MySQL/MariaDB. Uses `mysql_use_result` so
/// rows are pulled over the wire on demand. The active `Row` is invalidated by
/// the next `next()` call.
const MySqlCursor = struct {
    mysql: ?*libmysql_c.MYSQL,
    res: ?*libmysql_c.MYSQL_RES,
    arena: std.heap.ArenaAllocator,
    columns: []const []const u8,
    row: Row,
    eof: bool,

    fn deinit(self: *MySqlCursor) void {
        if (self.res) |r| libmysql_c.mysql_free_result(r);
        self.arena.deinit();
        self.* = undefined;
    }

    fn next(self: *MySqlCursor) ?*Row {
        if (self.eof or self.res == null) return null;
        _ = self.arena.reset(.free_all);
        const row_data = libmysql_c.mysql_fetch_row(self.res);
        if (row_data == null) {
            self.eof = true;
            return null;
        }
        const row_ptr = row_data.?;
        const lengths = libmysql_c.mysql_fetch_lengths(self.res);
        const n_cols = self.columns.len;
        const values = self.arena.allocator().alloc(?Value, n_cols) catch return null;
        for (0..n_cols) |c| {
            if (row_ptr[c] == null) {
                values[c] = null;
            } else {
                const len = lengths[c];
                const val = row_ptr[c].?[0..len];
                values[c] = .{ .string = self.arena.allocator().dupe(u8, val) catch return null };
            }
        }
        self.row = .{
            .arena = &self.arena,
            .columns = self.columns,
            .values = values,
        };
        return &self.row;
    }
};

/// Driver-native streaming cursor for PostgreSQL. Uses `PQsendQueryParams` +
/// `PQsetSingleRowMode` so the server emits one row per result. The active `Row`
/// is invalidated by the next `next()` call.
const PgCursor = struct {
    conn: ?*libpq_c.PGconn,
    arena: std.heap.ArenaAllocator,
    columns: []const []const u8,
    row: Row,
    current: ?*libpq_c.PGresult,
    eof: bool,

    fn deinit(self: *PgCursor) void {
        if (self.current) |r| libpq_c.PQclear(r);
        self.arena.deinit();
        self.* = undefined;
    }

    fn next(self: *PgCursor) ?*Row {
        if (self.eof) return null;
        _ = self.arena.reset(.free_all);
        const res = self.current orelse {
            self.eof = true;
            return null;
        };
        const status = libpq_c.PQresultStatus(res);
        if (status == libpq_c.ExecStatusType.PGRES_COMMAND_OK) {
            libpq_c.PQclear(res);
            self.current = null;
            self.eof = true;
            return null;
        }
        if (status != libpq_c.ExecStatusType.PGRES_TUPLES_OK and status != libpq_c.ExecStatusType.PGRES_SINGLE_TUPLE) {
            libpq_c.PQclear(res);
            self.current = null;
            self.eof = true;
            return null;
        }
        const n_cols = libpq_c.PQnfields(res);
        const values = self.arena.allocator().alloc(?Value, @intCast(n_cols)) catch return null;
        for (0..@intCast(n_cols)) |c| {
            values[c] = pgReadCell(self.arena.allocator(), res, 0, @intCast(c)) catch return null;
        }
        self.row = .{
            .arena = &self.arena,
            .columns = self.columns,
            .values = values,
        };
        libpq_c.PQclear(res);
        self.current = libpq_c.PQgetResult(self.conn);
        return &self.row;
    }
};

/// Execution result
pub const ExecResult = struct {
    last_insert_id: ?i64 = null,
    rows_affected: u64 = 0,
};

/// Database driver type
pub const Driver = enum {
    sqlite,
    postgres,
    mysql,
};

/// Structured diagnostic for SQL errors — table and column are extracted from
/// driver error messages when available (e.g. "UNIQUE constraint failed: users.email").
pub const SqlDiagnostic = struct {
    code: i32,
    message: []const u8, // driver error message (borrowed, not owned)
    constraint: ?[]const u8 = null, // e.g. "users.email" (SQLite), "users_email_key" (PG)
    table: ?[]const u8 = null,
    column: ?[]const u8 = null,
};

/// Parse SQLite error message to extract table/column from constraint failures.
pub fn diagnoseSqlite(err_code: i32, err_msg: []const u8) SqlDiagnostic {
    var diag = SqlDiagnostic{ .code = err_code, .message = err_msg };

    if (err_code == 19) { // SQLITE_CONSTRAINT
        // "UNIQUE constraint failed: table.column"
        if (std.mem.indexOf(u8, err_msg, "UNIQUE constraint failed:")) |pos| {
            const rest = std.mem.trim(u8, err_msg[pos + 24 ..], " \t\r\n");
            if (rest.len > 0) {
                diag.constraint = rest;
                if (std.mem.indexOf(u8, rest, ".")) |dot| {
                    diag.table = rest[0..dot];
                    diag.column = rest[dot + 1 ..];
                } else {
                    diag.table = rest;
                }
            }
        }
        // "NOT NULL constraint failed: table.column"
        if (std.mem.indexOf(u8, err_msg, "NOT NULL constraint failed:")) |pos| {
            const rest = std.mem.trim(u8, err_msg[pos + 26 ..], " \t\r\n");
            if (rest.len > 0) {
                diag.constraint = rest;
                if (std.mem.indexOf(u8, rest, ".")) |dot| {
                    diag.table = rest[0..dot];
                    diag.column = rest[dot + 1 ..];
                } else {
                    diag.table = rest;
                }
            }
        }
    } else if (err_code == 1) { // SQLITE_ERROR
        // "no such table: xxx"
        if (std.mem.indexOf(u8, err_msg, "no such table:")) |pos| {
            const rest = std.mem.trim(u8, err_msg[pos + 14 ..], " \t\r\n");
            if (rest.len > 0) {
                diag.table = rest;
            }
        }
    }
    return diag;
}

/// PG_DIAG_* field codes (from postgres_ext.h)
const PG_DIAG_SQLSTATE: c_int = 'C';
const PG_DIAG_CONSTRAINT_NAME: c_int = 'n';
const PG_DIAG_TABLE_NAME: c_int = 't';
const PG_DIAG_COLUMN_NAME: c_int = 'c';

/// Safely convert a C string pointer to a Zig slice without triggering std.mem.span(null) debug panic.
pub inline fn cStrSpan(c_ptr: [*c]const u8) []const u8 {
    if (c_ptr == null) return "";
    return std.mem.span(c_ptr);
}

/// Extract diagnostic info from a PostgreSQL PGresult after a failure.
pub fn diagnosePostgres(result: ?*const libpq_c.PGresult) SqlDiagnostic {
    var diag = SqlDiagnostic{ .code = 0, .message = "" };

    const sqlstate = if (result) |r| cStrSpan(libpq_c.PQresultErrorField(r, PG_DIAG_SQLSTATE)) else "";
    if (sqlstate.len > 0) {
        diag.code = std.fmt.parseInt(i32, sqlstate, 10) catch 0;
    }

    diag.message = if (result) |r| cStrSpan(libpq_c.PQresultErrorMessage(r)) else "";

    if (result) |r| {
        const constraint = cStrSpan(libpq_c.PQresultErrorField(r, PG_DIAG_CONSTRAINT_NAME));
        if (constraint.len > 0) diag.constraint = constraint;

        const table = cStrSpan(libpq_c.PQresultErrorField(r, PG_DIAG_TABLE_NAME));
        if (table.len > 0) diag.table = table;

        const column = cStrSpan(libpq_c.PQresultErrorField(r, PG_DIAG_COLUMN_NAME));
        if (column.len > 0) diag.column = column;
    }

    return diag;
}

/// Parse MySQL error message to extract table/column from constraint failures.
pub fn diagnoseMysql(err_no: c_uint, err_msg: []const u8) SqlDiagnostic {
    var diag = SqlDiagnostic{ .code = @intCast(err_no), .message = err_msg };

    // "Duplicate entry 'value' for key 'table.column'"
    if (std.mem.indexOf(u8, err_msg, "Duplicate entry")) |pos| {
        const rest = err_msg[pos..];
        if (std.mem.indexOf(u8, rest, "for key '")) |key_pos| {
            const key = rest[key_pos + 9 ..];
            if (std.mem.indexOf(u8, key, "'")) |end_pos| {
                const key_name = key[0..end_pos];
                diag.constraint = key_name;
                if (std.mem.indexOf(u8, key_name, ".")) |dot| {
                    diag.table = key_name[0..dot];
                    diag.column = key_name[dot + 1 ..];
                } else {
                    diag.table = key_name;
                }
            }
        }
    }
    // "Column 'col' cannot be null"
    if (std.mem.indexOf(u8, err_msg, "Column '")) |pos| {
        const rest = err_msg[pos + 8 ..];
        if (std.mem.indexOf(u8, rest, "'")) |end_pos| {
            diag.column = rest[0..end_pos];
        }
    }
    // "Table 'db.table' doesn't exist"
    if (std.mem.indexOf(u8, err_msg, "Table '")) |pos| {
        const rest = err_msg[pos + 7 ..];
        if (std.mem.indexOf(u8, rest, "'")) |end_pos| {
            const table_name = rest[0..end_pos];
            if (std.mem.indexOf(u8, table_name, ".")) |dot| {
                diag.table = table_name[dot + 1 ..];
            } else {
                diag.table = table_name;
            }
        }
    }

    // Log diagnostic details in error paths
    if (diag.table != null or diag.column != null or diag.constraint != null) {
        std.log.err("MySQL diagnostic: errno={d} table={?s} column={?s} constraint={?s}", .{ err_no, diag.table, diag.column, diag.constraint });
    }

    return diag;
}

/// SQL connection interface
pub const Conn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Monotonic creation time, tracked by the connection pool for lifetime eviction.
    created_at_ms: ?i64 = null,

    pub const VTable = struct {
        query: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows),
        exec: *const fn (ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult),
        close: *const fn (ptr: *anyopaque) void,
        ping: *const fn (ptr: *anyopaque) errors.Result,
        begin: *const fn (ptr: *anyopaque) errors.Result,
        commit: *const fn (ptr: *anyopaque) errors.Result,
        rollback: *const fn (ptr: *anyopaque) errors.Result,
        prepare: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt),
        /// Optional driver-native streaming cursor. Null drivers fall back to
        /// buffering all rows in `queryCursor`.
        queryCursor: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value, opts: CursorOptions) errors.ResultT(Cursor) = null,
        /// Optional driver-native batch insert. SQLite returns null to fall back
        /// to the SQL mode; MySQL and PostgreSQL implement protocol-level batching.
        batchInsert: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) = null,
    };

    pub fn query(self: Conn, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        var rows = try self.vtable.query(self.ptr, allocator, sql_str, args);
        for (rows.rows) |*row| row.arena = &rows.arena;
        return rows;
    }

    pub fn exec(self: Conn, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        return self.vtable.exec(self.ptr, sql_str, args);
    }

    pub fn close(self: Conn) void {
        self.vtable.close(self.ptr);
    }

    pub fn ping(self: Conn) errors.Result {
        return self.vtable.ping(self.ptr);
    }

    pub fn begin(self: Conn) errors.Result {
        return self.vtable.begin(self.ptr);
    }

    pub fn commit(self: Conn) errors.Result {
        return self.vtable.commit(self.ptr);
    }

    pub fn rollback(self: Conn) errors.Result {
        return self.vtable.rollback(self.ptr);
    }

    pub fn prepare(self: Conn, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt) {
        return self.vtable.prepare(self.ptr, allocator, sql_str);
    }

    pub fn queryCursor(self: Conn, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value, opts: CursorOptions) errors.ResultT(Cursor) {
        if (self.vtable.queryCursor) |qf| {
            return qf(self.ptr, allocator, sql_str, args, opts);
        }
        const rows = try self.query(allocator, sql_str, args);
        return Cursor.init(rows);
    }

    pub fn batchInsert(self: Conn, allocator: std.mem.Allocator, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        if (self.vtable.batchInsert) |bi| {
            return bi(self.ptr, allocator, table, columns, rows);
        }
        return error.DatabaseError;
    }
};

// ==================== Struct Scanning ====================

/// Precompute struct-field → column-index mapping once per query.
/// Eliminates O(F*C) string comparisons per row — each row scan
/// becomes O(F) direct array indexing instead of O(F*C) linear probes.
fn buildColumnIndices(allocator: std.mem.Allocator, comptime T: type, columns: []const []const u8) ![]?usize {
    const names = std.meta.fieldNames(T);
    const indices = try allocator.alloc(?usize, names.len);
    for (indices) |*idx| idx.* = null;
    for (names, 0..) |name, fi| {
        for (columns, 0..) |col, ci| {
            if (std.mem.eql(u8, col, name)) {
                indices[fi] = ci;
                break;
            }
        }
    }
    return indices;
}

/// Scan all rows into []T using a one-shot column→field index map (O(F+C) setup, O(F) per row).
/// String fields are duplicated into `allocator` (caller owns them via freeScanned).
fn scanRowsToSlice(allocator: std.mem.Allocator, comptime T: type, rows: *Rows, partial: bool) ![]T {
    for (rows.rows) |*row| row.arena = &rows.arena;

    const indices: ?[]?usize = if (rows.rows.len > 0)
        try buildColumnIndices(allocator, T, rows.rows[0].columns)
    else
        null;
    defer if (indices) |idx| allocator.free(idx);

    const result = try allocator.alloc(T, rows.rows.len);
    var scanned_count: usize = 0;
    errdefer {
        for (result[0..scanned_count]) |item| freeScanned(allocator, T, item);
        allocator.free(result);
    }
    for (rows.rows, 0..) |row, i| {
        result[i] = try scanStruct(allocator, T, row, partial, indices, false);
        scanned_count += 1;
    }
    return result;
}

/// Scan into QueryResult owning the Rows arena — string fields borrow arena memory (no second dupe).
/// On success, steals `rows.arena`; caller must NOT call `rows.deinit()`.
pub fn scanRowsToOwned(comptime T: type, rows: *Rows, partial: bool) !QueryResult(T) {
    for (rows.rows) |*row| row.arena = &rows.arena;
    const arena_alloc = rows.arena.allocator();

    const indices: ?[]?usize = if (rows.rows.len > 0)
        try buildColumnIndices(arena_alloc, T, rows.rows[0].columns)
    else
        null;

    const result = try arena_alloc.alloc(T, rows.rows.len);
    for (rows.rows, 0..) |row, i| {
        result[i] = try scanStruct(arena_alloc, T, row, partial, indices, true);
    }

    const stolen = rows.arena;
    rows.* = undefined;
    return .{ .items = result, .arena = stolen };
}

/// Scan a struct Row, optionally using precomputed column indices for O(1) field lookup.
/// When `borrow_strings` is true, []const u8 fields point into the row arena (no dupe).
fn scanStruct(allocator: std.mem.Allocator, comptime T: type, row: Row, partial: bool, indices: ?[]?usize, borrow_strings: bool) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("scanStruct only supports structs, got " ++ @typeName(T));

    var result: T = undefined;
    const fn_names = info.@"struct".field_names;
    const fn_types = info.@"struct".field_types;
    const fn_attrs = info.@"struct".field_attrs;
    inline for (fn_names, fn_types, fn_attrs, 0..) |fname, ft, _, fi| {
        const FieldType = ft;
        const is_optional = @typeInfo(FieldType) == .optional;
        const BaseType = if (is_optional) @typeInfo(FieldType).optional.child else FieldType;
        const is_string = BaseType == []const u8;
        const ci: ?usize = if (indices) |idx| idx[fi] else null;

        if (is_string) {
            // String fields: use index if available, otherwise linear scan.
            if (ci) |c| {
                const raw_val = row.values[c];
                if (raw_val == null or raw_val.? == .null) {
                    if (is_optional) {
                        @field(result, fname) = null;
                    } else if (partial) {
                        @field(result, fname) = &[_]u8{};
                    } else {
                        return error.NotFound;
                    }
                } else {
                    const str = raw_val.?.string;
                    @field(result, fname) = if (borrow_strings)
                        str
                    else
                        allocator.dupe(u8, str) catch return error.DatabaseError;
                }
            } else {
                // Fallback: linear scan (no column index provided)
                found: {
                    for (row.columns, 0..) |col, ci2| {
                        if (std.mem.eql(u8, col, fname)) {
                            const raw_val = row.values[ci2];
                            if (raw_val == null or raw_val.? == .null) {
                                if (is_optional) {
                                    @field(result, fname) = null;
                                } else if (partial) {
                                    @field(result, fname) = &[_]u8{};
                                } else {
                                    return error.NotFound;
                                }
                            } else {
                                const str = raw_val.?.string;
                                @field(result, fname) = if (borrow_strings)
                                    str
                                else
                                    allocator.dupe(u8, str) catch return error.DatabaseError;
                            }
                            break :found;
                        }
                    }
                    if (is_optional) {
                        @field(result, fname) = null;
                    } else if (partial) {
                        @field(result, fname) = &[_]u8{};
                    } else {
                        return error.NotFound;
                    }
                }
            }
            continue;
        }

        // Non-string fields: borrow Value as-is (parseInt uses the arena string transiently).
        const val: ?Value = if (ci) |c| blk: {
            if (row.values[c]) |v| break :blk v;
            break :blk null;
        } else val: {
            var row_mut = row;
            break :val row_mut.get(fname);
        };

        if (is_optional) {
            const ChildType = BaseType;
            if (val == null or val.? == .null) {
                @field(result, fname) = null;
            } else {
                @field(result, fname) = try valueToType(allocator, ChildType, val.?);
            }
        } else {
            if (val == null or val.? == .null) {
                if (partial) {
                    @field(result, fname) = std.mem.zeroes(FieldType);
                } else {
                    return error.NotFound;
                }
            } else {
                @field(result, fname) = try valueToType(allocator, FieldType, val.?);
            }
        }
    }
    return result;
}

fn valueToType(allocator: std.mem.Allocator, comptime T: type, val: Value) !T {
    return switch (T) {
        i64 => switch (val) {
            .int => |v| v,
            .string => |s| std.fmt.parseInt(i64, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        i32 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(i32, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        i16 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(i16, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        i8 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(i8, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        u64 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(u64, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        u32 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(u32, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        u16 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(u16, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        u8 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(u8, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        f64 => switch (val) {
            .float => |v| v,
            .int => |v| @floatFromInt(v),
            .string => |s| std.fmt.parseFloat(f64, s) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        f32 => switch (val) {
            .float => |v| @floatCast(v),
            .int => |v| @floatFromInt(v),
            .string => |s| std.fmt.parseFloat(f32, s) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        bool => switch (val) {
            .bool => |v| v,
            .int => |v| v != 0,
            .string => |s| std.mem.eql(u8, s, "t") or std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1"),
            else => error.DatabaseError,
        },
        []const u8 => if (val == .string) (allocator.dupe(u8, val.string) catch return error.DatabaseError) else error.DatabaseError,
        else => @compileError("Unsupported scan type: " ++ @typeName(T)),
    };
}

/// Compile-time: does `T` have any `[]const u8` / `?[]const u8` field?
/// Used by `queryScalar` (string-free requirement) and exposed as
/// `QueryResult(T).has_strings` for callers that want to branch on whether a
/// row owns string data.
pub fn typeHasStrings(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    inline for (info.@"struct".field_types) |ft| {
        if (ft == []const u8) return true;
        if (@typeInfo(ft) == .optional and @typeInfo(ft).optional.child == []const u8) return true;
    }
    return false;
}

pub fn freeScanned(allocator: std.mem.Allocator, comptime T: type, val: T) void {
    const info = @typeInfo(T);
    if (info != .@"struct") return;
    inline for (info.@"struct".field_names, info.@"struct".field_types) |fn2, fft2| {
        const FieldType = fft2;
        if (FieldType == []const u8) {
            allocator.free(@field(val, fn2));
        } else if (@typeInfo(FieldType) == .optional and @typeInfo(FieldType).optional.child == []const u8) {
            if (@field(val, fn2)) |s| allocator.free(s);
        }
    }
}

/// Owned query result — prefers arena ownership (strings borrowed, single free on deinit).
/// Legacy path (arena=null) frees per-string via freeScanned.
///
/// ```zig
/// var result = try client.queryRowsOwned(User, "SELECT * FROM users", &.{});
/// defer result.deinit(allocator);
/// for (result.items) |user| { ... }
/// ```
pub fn QueryResult(comptime T: type) type {
    return struct {
        items: []T,
        /// When set, owns all string data (and the items slice). deinit frees the arena only.
        arena: ?std.heap.ArenaAllocator = null,
        /// Whether `T` contains `[]const u8` fields (compile-time; callers can
        /// skip per-row freeing when false).
        pub const has_strings = typeHasStrings(T);

        pub const TakeResult = struct { items: []T, arena: ?std.heap.ArenaAllocator };

        /// Free owned memory. Accepts `*const @This()` so callers can keep the
        /// idiomatic `const rows = try ...; defer rows.deinit(...);` pattern
        /// under Zig 0.17's stricter const checking. The cast is safe because
        /// QueryResult always owns its backing memory on the heap/stack and
        /// the caller holds the only reference at this point.
        ///
        /// Contract: call **either** `deinit` **or** per-row `freeScanned` +
        /// `allocator.free(items)` — never both. When `arena != null`, `deinit`
        /// frees the arena once; when `arena == null`, it `freeScanned`s every
        /// row then frees the items slice. Doing `freeScanned` then `deinit`
        /// is a double-free (heysen SIGABRT / SafeAllocator `len: 7` pattern).
        ///
        /// On the arena path the `allocator` argument is **ignored** — the arena
        /// was created with its own backing allocator (the connection / client's
        /// allocator) and `ArenaAllocator.deinit` uses that one internally.
        /// Passing a different allocator here is a misuse: the caller has mixed
        /// allocator identities and the SafeAllocator-backed backing allocator
        /// will reject memory freed through the wrong path. For arena-backed
        /// results prefer `deinitArena()`, which makes the intent explicit.
        pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
            const self_mut: *@This() = @constCast(self);
            if (self_mut.arena) |*a| {
                a.deinit();
                self_mut.arena = null;
                self_mut.items = &.{};
                return;
            }
            for (self.items) |item| freeScanned(allocator, T, item);
            allocator.free(self.items);
            self_mut.items = &.{};
        }

        /// Free an arena-backed QueryResult without taking an allocator.
        /// Preferred over `deinit(any_allocator)` when the result owns an arena
        /// (the common path returned by `queryRowsOwned` / `scanRowsToOwned`).
        /// The arena's backing allocator — captured at scan time — releases the
        /// arena's internal buffer, so the caller cannot influence or confuse
        /// the free path by passing a different allocator.
        ///
        /// Calling this on a slice-backed result (arena == null) is a bug:
        /// per-row strings would leak. We debug-panic to surface it loudly
        /// rather than silently leak.
        pub fn deinitArena(self: *const @This()) void {
            const self_mut: *@This() = @constCast(self);
            if (self_mut.arena) |*a| {
                a.deinit();
                self_mut.arena = null;
                self_mut.items = &.{};
                return;
            }
            @panic("deinitArena called on a slice-backed QueryResult (arena == null); "
                ++ "use deinit(allocator) for the slice path");
        }

        /// Transfer items + arena ownership out (e.g. into PageResult). Leaves self empty.
        pub fn take(self: *const @This()) TakeResult {
            const self_mut: *@This() = @constCast(self);
            const out: TakeResult = .{ .items = self.items, .arena = self.arena };
            self_mut.items = &.{};
            self_mut.arena = null;
            return out;
        }
    };
}

// ==================== SQLite Implementation ====================

/// Bounded prepared-statement cache (per connection, LRU eviction).
const MAX_CACHED_STMTS = 64;

fn CachedStmt(comptime V: type) type {
    return struct {
        value: V,
        last_used: u64,
    };
}

fn findLruStmtKey(comptime V: type, cache: std.StringHashMap(CachedStmt(V))) ?[]const u8 {
    var it = cache.iterator();
    var lru_key: ?[]const u8 = null;
    var lru_used: u64 = std.math.maxInt(u64);
    while (it.next()) |entry| {
        if (entry.value_ptr.last_used < lru_used) {
            lru_used = entry.value_ptr.last_used;
            lru_key = entry.key_ptr.*;
        }
    }
    return lru_key;
}

pub const SQLiteConn = struct {
    db: ?*sqlite3_c.sqlite3,
    allocator: std.mem.Allocator,
    /// LRU cache of prepared statements keyed by SQL string.
    stmt_cache: std.StringHashMap(CachedStmt(*sqlite3_c.sqlite3_stmt)),
    stmt_counter: u64 = 0,
    magic: u32 = 0xDBDBDBDB,

    fn guard(self: *const @This()) void {
        if (self.magic != 0xDBDBDBDB) @panic("DB heap corruption detected (SQLite magic mismatch)");
    }

    fn poison(self: *@This()) void {
        self.magic = 0xDEADDEAD;
    }

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !SQLiteConn {
        var db: ?*sqlite3_c.sqlite3 = null;
        const c_path = try allocZ(allocator, path);
        defer allocator.free(c_path);
        const rc = sqlite3_c.sqlite3_open(c_path.ptr, &db);
        if (rc != sqlite3_c.SQLITE_OK or db == null) {
            if (db) |d| {
                _ = sqlite3_c.sqlite3_errmsg(d);
                _ = sqlite3_c.sqlite3_close(d);
                return error.DatabaseError;
            }
            return error.DatabaseError;
        }
        errdefer _ = sqlite3_c.sqlite3_close(db.?);
        try applySqlitePragmas(db.?);
        return .{ .db = db, .allocator = allocator, .stmt_cache = std.StringHashMap(CachedStmt(*sqlite3_c.sqlite3_stmt)).init(allocator) };
    }

    fn applySqlitePragmas(db: *sqlite3_c.sqlite3) !void {
        const pragmas = [_][:0]const u8{
            "PRAGMA journal_mode=WAL",
            "PRAGMA busy_timeout=5000",
            "PRAGMA foreign_keys=ON",
            "PRAGMA synchronous=NORMAL",
            "PRAGMA cache_size=-8000",
        };
        for (pragmas) |sql| {
            const rc = sqlite3_c.sqlite3_exec(db, sql.ptr, null, null, null);
            if (rc != sqlite3_c.SQLITE_OK) {
                const msg = cStrSpan(sqlite3_c.sqlite3_errmsg(db));
                std.log.warn("SQLite PRAGMA failed: sql={s} msg={s}", .{ sql, msg });
                return error.DatabaseError;
            }
        }
    }

    /// Get or prepare a cached statement. Returns reset + clear_bindings stmt ready for binding.
    fn getCachedStmt(self: *SQLiteConn, sql_str: []const u8) !*sqlite3_c.sqlite3_stmt {
        self.guard();
        if (self.stmt_cache.getPtr(sql_str)) |entry| {
            self.stmt_counter += 1;
            entry.last_used = self.stmt_counter;
            _ = sqlite3_c.sqlite3_reset(entry.value);
            _ = sqlite3_c.sqlite3_clear_bindings(entry.value);
            return entry.value;
        }
        // Evict LRU entry when at capacity.
        if (self.stmt_cache.count() >= MAX_CACHED_STMTS) {
            if (findLruStmtKey(*sqlite3_c.sqlite3_stmt, self.stmt_cache)) |lru_key| {
                if (self.stmt_cache.fetchRemove(lru_key)) |kv| {
                    _ = sqlite3_c.sqlite3_finalize(kv.value.value);
                    self.allocator.free(kv.key);
                }
            }
        }
        var stmt: ?*sqlite3_c.sqlite3_stmt = null;
        const rc = sqlite3_c.sqlite3_prepare_v2(self.db, @ptrCast(sql_str.ptr), @intCast(sql_str.len), &stmt, null);
        if (rc != sqlite3_c.SQLITE_OK or stmt == null) {
            const err_msg = std.mem.span(sqlite3_c.sqlite3_errmsg(self.db));
            const ext_code = sqlite3_c.sqlite3_extended_errcode(self.db);
            const diag = diagnoseSqlite(ext_code, err_msg);
            if (ext_code == 1 and std.mem.indexOf(u8, err_msg, "no such table") != null) { // SQLITE_ERROR + no such table
                std.log.err("SQLite not found: table={s}", .{diag.table orelse "?"});
                return error.NotFound;
            }
            std.log.err("SQLite prepare error: code={d} msg={s}", .{ ext_code, err_msg });
            return error.DatabaseError;
        }
        const key = self.allocator.dupe(u8, sql_str) catch {
            _ = sqlite3_c.sqlite3_finalize(stmt);
            return error.DatabaseError;
        };
        self.stmt_counter += 1;
        try self.stmt_cache.put(key, .{ .value = stmt.?, .last_used = self.stmt_counter });
        return stmt.?;
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        _ = allocator;
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const stmt = try self.getCachedStmt(sql_str);

        try bindSQLite(stmt, args);

        const col_count = sqlite3_c.sqlite3_column_count(stmt);
        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        // Column names are identical for every row — allocate once and share.
        const shared_columns = arena_alloc.alloc([]const u8, @intCast(col_count)) catch return error.DatabaseError;
        var names_ready = false;

        var step_rc = sqlite3_c.sqlite3_step(stmt);
        while (step_rc == sqlite3_c.SQLITE_ROW) {
            if (!names_ready) {
                for (0..@intCast(col_count)) |i| {
                    const raw_name = sqlite3_c.sqlite3_column_name(stmt, @intCast(i));
                    const name_len = std.mem.len(raw_name);
                    shared_columns[i] = arena_alloc.dupe(u8, raw_name[0..name_len]) catch return error.DatabaseError;
                }
                names_ready = true;
            }
            const values = arena_alloc.alloc(?Value, @intCast(col_count)) catch return error.DatabaseError;
            for (0..@intCast(col_count)) |i| {
                values[i] = readSQLiteValue(arena_alloc, stmt, @intCast(i));
            }
            rows_list.append(arena_alloc, .{ .arena = undefined, .columns = shared_columns, .values = values }) catch return error.DatabaseError;
            step_rc = sqlite3_c.sqlite3_step(stmt);
        }
        // Check if step ended with an error (not DONE)
        if (step_rc != sqlite3_c.SQLITE_DONE) {
            const err_msg = cStrSpan(sqlite3_c.sqlite3_errmsg(self.db));
            const ext_code = sqlite3_c.sqlite3_extended_errcode(self.db);
            std.log.err("SQLite query error: code={d} msg={s}", .{ ext_code, err_msg });
            return error.DatabaseError;
        }

        const rows_slice = arena_alloc.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const stmt = try self.getCachedStmt(sql_str);

        try bindSQLite(stmt, args);

        const step_rc = sqlite3_c.sqlite3_step(stmt);
        if (step_rc != sqlite3_c.SQLITE_DONE and step_rc != sqlite3_c.SQLITE_ROW) {
            const err_msg = std.mem.span(sqlite3_c.sqlite3_errmsg(self.db));
            const ext_code = sqlite3_c.sqlite3_extended_errcode(self.db);
            const diag = diagnoseSqlite(ext_code, err_msg);
            if (ext_code == 19) { // SQLITE_CONSTRAINT
                std.log.err("SQLite constraint violation: table={s} column={s} msg={s}", .{ diag.table orelse "?", diag.column orelse "?", err_msg });
                return error.ConstraintViolation;
            }
            std.log.err("SQLite exec error: code={d} msg={s}", .{ ext_code, err_msg });
            return error.DatabaseError;
        }

        return ExecResult{
            .last_insert_id = sqlite3_c.sqlite3_last_insert_rowid(self.db),
            .rows_affected = @intCast(sqlite3_c.sqlite3_changes(self.db)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        // Finalize all cached statements
        var it = self.stmt_cache.iterator();
        while (it.next()) |entry| {
            _ = sqlite3_c.sqlite3_finalize(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.stmt_cache.deinit();
        if (self.db) |db| {
            _ = sqlite3_c.sqlite3_close(db);
            self.db = null;
        }
        self.poison();
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (self.db == null) return error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const rc = sqlite3_c.sqlite3_exec(self.db, "BEGIN", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const rc = sqlite3_c.sqlite3_exec(self.db, "COMMIT", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const rc = sqlite3_c.sqlite3_exec(self.db, "ROLLBACK", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    fn prepareFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt) {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const stmt = allocator.create(SQLiteStmt) catch return error.DatabaseError;
        errdefer allocator.destroy(stmt);
        stmt.* = SQLiteStmt.prepare(self.db, allocator, sql_str) catch return error.DatabaseError;
        return stmt.toStmt();
    }

    fn queryCursorFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value, opts: CursorOptions) errors.ResultT(Cursor) {
        _ = opts;
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const rows = try queryFn(ptr, allocator, sql_str, args);
        return Cursor.init(rows);
    }

    fn batchInsertFn(ptr: *anyopaque, allocator: std.mem.Allocator, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        _ = ptr;
        _ = allocator;
        _ = table;
        _ = columns;
        _ = rows;
        return error.DatabaseError; // Caller falls back to SQL mode.
    }

    pub fn toConn(self: *SQLiteConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
                .begin = beginFn,
                .commit = commitFn,
                .rollback = rollbackFn,
                .prepare = prepareFn,
                .queryCursor = queryCursorFn,
                .batchInsert = batchInsertFn,
            },
        };
    }
};

const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

fn bindSQLite(stmt: ?*sqlite3_c.sqlite3_stmt, args: []const Value) !void {
    for (args, 0..) |arg, i| {
        const idx: c_int = @intCast(i + 1);
        const rc = switch (arg) {
            .null => sqlite3_c.sqlite3_bind_null(stmt, idx),
            .int => |v| sqlite3_c.sqlite3_bind_int64(stmt, idx, v),
            .float => |v| sqlite3_c.sqlite3_bind_double(stmt, idx, v),
            .string => |v| sqlite3_c.sqlite3_bind_text(stmt, idx, @ptrCast(v.ptr), @intCast(v.len), @ptrCast(SQLITE_TRANSIENT)),
            .bool => |v| sqlite3_c.sqlite3_bind_int64(stmt, idx, if (v) 1 else 0),
        };
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }
}

fn readSQLiteValue(allocator: std.mem.Allocator, stmt: ?*sqlite3_c.sqlite3_stmt, col: c_int) ?Value {
    const t = sqlite3_c.sqlite3_column_type(stmt, col);
    return switch (t) {
        sqlite3_c.SQLITE_INTEGER => Value{ .int = sqlite3_c.sqlite3_column_int64(stmt, col) },
        sqlite3_c.SQLITE_FLOAT => Value{ .float = sqlite3_c.sqlite3_column_double(stmt, col) },
        sqlite3_c.SQLITE_TEXT => blk: {
            const raw_text = sqlite3_c.sqlite3_column_text(stmt, col);
            const text_len = std.mem.len(raw_text);
            const text = raw_text[0..text_len];
            break :blk Value{ .string = allocator.dupe(u8, text) catch return null };
        },
        sqlite3_c.SQLITE_NULL => null,
        else => null,
    };
}

// ==================== PostgreSQL Implementation ====================

/// Maximum cached prepared statements per PG connection.
const PG_MAX_CACHED_STMTS = 64;

/// `resultFormat` for PQexecParams / PQexecPrepared — binary wire format.
const PG_RESULT_BINARY: c_int = 1;

/// Common PostgreSQL type OIDs (pg_type).
const PgOid = struct {
    const bool_t: libpq_c.Oid = 16;
    const bytea: libpq_c.Oid = 17;
    const char_t: libpq_c.Oid = 18;
    const name: libpq_c.Oid = 19;
    const int8: libpq_c.Oid = 20;
    const int2: libpq_c.Oid = 21;
    const int4: libpq_c.Oid = 23;
    const text: libpq_c.Oid = 25;
    const json: libpq_c.Oid = 114;
    const xml: libpq_c.Oid = 142;
    const float4: libpq_c.Oid = 700;
    const float8: libpq_c.Oid = 701;
    const bpchar: libpq_c.Oid = 1042;
    const varchar: libpq_c.Oid = 1043;
    const date: libpq_c.Oid = 1082;
    const time: libpq_c.Oid = 1083;
    const timestamp: libpq_c.Oid = 1114;
    const timestamptz: libpq_c.Oid = 1184;
    const interval: libpq_c.Oid = 1186;
    const timetz: libpq_c.Oid = 1266;
    const numeric: libpq_c.Oid = 1700;
    const uuid: libpq_c.Oid = 2950;
    const jsonb: libpq_c.Oid = 3802;
    const inet: libpq_c.Oid = 869;
    const cidr: libpq_c.Oid = 650;
};

/// Decode one PG cell. Handles text (`PQexec`) and binary (`resultFormat=1`) results.
fn pgReadCell(allocator: std.mem.Allocator, res: *libpq_c.PGresult, row: c_int, col: c_int) !?Value {
    if (libpq_c.PQgetisnull(res, row, col) == 1) return null;

    const raw = libpq_c.PQgetvalue(res, row, col);
    const len: usize = @intCast(libpq_c.PQgetlength(res, row, col));
    const bytes = raw[0..len];

    // Text format (simple query / resultFormat=0): keep as string for scanStruct parsing.
    if (libpq_c.PQfformat(res, col) == 0) {
        return .{ .string = try allocator.dupe(u8, bytes) };
    }

    return @as(?Value, try pgDecodeBinary(allocator, libpq_c.PQftype(res, col), bytes));
}

/// Decode PostgreSQL binary column bytes into a Value.
fn pgDecodeBinary(allocator: std.mem.Allocator, oid: libpq_c.Oid, bytes: []const u8) !Value {
    switch (oid) {
        PgOid.bool_t => {
            if (bytes.len < 1) return error.DatabaseError;
            return .{ .bool = bytes[0] != 0 };
        },
        PgOid.int2 => {
            if (bytes.len < 2) return error.DatabaseError;
            return .{ .int = std.mem.readInt(i16, bytes[0..2], .big) };
        },
        PgOid.int4 => {
            if (bytes.len < 4) return error.DatabaseError;
            return .{ .int = std.mem.readInt(i32, bytes[0..4], .big) };
        },
        PgOid.int8 => {
            if (bytes.len < 8) return error.DatabaseError;
            return .{ .int = std.mem.readInt(i64, bytes[0..8], .big) };
        },
        PgOid.float4 => {
            if (bytes.len < 4) return error.DatabaseError;
            const bits = std.mem.readInt(u32, bytes[0..4], .big);
            return .{ .float = @as(f32, @bitCast(bits)) };
        },
        PgOid.float8 => {
            if (bytes.len < 8) return error.DatabaseError;
            const bits = std.mem.readInt(u64, bytes[0..8], .big);
            return .{ .float = @as(f64, @bitCast(bits)) };
        },
        PgOid.numeric => {
            return pgDecodeNumeric(allocator, bytes);
        },
        PgOid.text, PgOid.varchar, PgOid.bpchar, PgOid.name, PgOid.xml, PgOid.json, PgOid.char_t, PgOid.bytea => {
            return .{ .string = try allocator.dupe(u8, bytes) };
        },
        PgOid.jsonb => {
            // jsonb binary: 1-byte version (1) + utf8 json
            if (bytes.len >= 1 and bytes[0] == 1) {
                return .{ .string = try allocator.dupe(u8, bytes[1..]) };
            }
            return .{ .string = try allocator.dupe(u8, bytes) };
        },
        PgOid.uuid => {
            if (bytes.len != 16) return error.DatabaseError;
            const s = try std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
                bytes[0],  bytes[1],  bytes[2],  bytes[3],
                bytes[4],  bytes[5],  bytes[6],  bytes[7],
                bytes[8],  bytes[9],  bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15],
            });
            return .{ .string = s };
        },
        PgOid.date => {
            // days since 2000-01-01
            if (bytes.len < 4) return error.DatabaseError;
            const days = std.mem.readInt(i32, bytes[0..4], .big);
            const s = try pgFormatDate(allocator, days);
            return .{ .string = s };
        },
        PgOid.timestamp, PgOid.timestamptz => {
            // microseconds since 2000-01-01 00:00:00
            if (bytes.len < 8) return error.DatabaseError;
            const us = std.mem.readInt(i64, bytes[0..8], .big);
            const is_tz = oid == PgOid.timestamptz;
            const s = try pgFormatTimestamp(allocator, us, is_tz);
            return .{ .string = s };
        },
        PgOid.interval => {
            // Binary: int64 us (microseconds), int32 days, int32 months
            if (bytes.len < 16) return error.DatabaseError;
            const us = std.mem.readInt(i64, bytes[0..8], .big);
            const days = std.mem.readInt(i32, bytes[8..12], .big);
            const months = std.mem.readInt(i32, bytes[12..16], .big);
            const s = try pgFormatInterval(allocator, months, days, us);
            return .{ .string = s };
        },
        PgOid.time => {
            // int64 microseconds since midnight
            if (bytes.len < 8) return error.DatabaseError;
            const us = std.mem.readInt(i64, bytes[0..8], .big);
            const s = try pgFormatTime(allocator, us, 0);
            return .{ .string = s };
        },
        PgOid.timetz => {
            // int64 us + int32 tz_offset_seconds
            if (bytes.len < 12) return error.DatabaseError;
            const us = std.mem.readInt(i64, bytes[0..8], .big);
            const tz_offset = std.mem.readInt(i32, bytes[8..12], .big);
            const s = try pgFormatTime(allocator, us, tz_offset);
            return .{ .string = s };
        },
        PgOid.inet, PgOid.cidr => {
            // Binary: u8 family, u8 prefix_len, u8 is_cidr, u8 nbytes, u8 addr[nbytes]
            if (bytes.len < 4) return error.DatabaseError;
            const family = bytes[0];
            const prefix_len = bytes[1];
            const is_cidr = bytes[2] == 1;
            const nbytes = bytes[3];
            if (bytes.len < 4 + nbytes) return error.DatabaseError;
            const addr = bytes[4 .. 4 + nbytes];
            const s = try pgFormatInet(allocator, family, prefix_len, is_cidr, addr);
            return .{ .string = s };
        },
        else => {
            // Unknown binary OID: keep raw bytes as string when UTF-8, else hex.
            if (std.unicode.utf8ValidateSlice(bytes)) {
                return .{ .string = try allocator.dupe(u8, bytes) };
            }
            const hex = try allocator.alloc(u8, 2 + bytes.len * 2);
            hex[0] = '\\';
            hex[1] = 'x';
            const digits = "0123456789abcdef";
            for (bytes, 0..) |b, i| {
                hex[2 + i * 2] = digits[b >> 4];
                hex[2 + i * 2 + 1] = digits[b & 0xf];
            }
            return .{ .string = hex };
        },
    }
}

/// Decode PostgreSQL numeric binary format (OID 1700).
///
/// Binary layout: int16 ndigits, int16 weight, uint16 sign, uint16 dscale, uint16 digits[ndigits].
/// Each digit is base-10000. sign: 0x0000=positive, 0x4000=negative, 0xC000=NaN.
fn pgDecodeNumeric(allocator: std.mem.Allocator, bytes: []const u8) !Value {
    if (bytes.len < 8) return error.DatabaseError;
    const ndigits = std.mem.readInt(i16, bytes[0..2], .big);
    const weight = std.mem.readInt(i16, bytes[2..4], .big);
    const sign = std.mem.readInt(u16, bytes[4..6], .big);
    const dscale = std.mem.readInt(u16, bytes[6..8], .big);

    if (sign == 0xC000) return .{ .string = try allocator.dupe(u8, "NaN") };
    if (ndigits <= 0) return .{ .string = try allocator.dupe(u8, "0") };

    const n: usize = @intCast(ndigits);
    if (bytes.len < 8 + n * 2) return error.DatabaseError;

    const digits_before_dot: usize = if (weight >= 0) @intCast((@as(isize, @intCast(weight)) + 1) * 4) else 0;
    const is_neg = sign == 0x4000;

    // Phase 1: expand digits to flat decimal array.
    // Track first_decimal_pos: the decimal position of dec[0] (0 = 10^0, 1 = 10^-1, etc).
    var dec = std.ArrayList(u8).empty;
    try dec.ensureTotalCapacity(allocator, n * 4);
    errdefer dec.deinit(allocator);

    var first_decimal_pos: usize = 0;
    var first_group: ?usize = null;
    for (0..n) |di| {
        var d = std.mem.readInt(u16, bytes[8 + di * 2 ..][0..2], .big);
        if (d == 0 and first_group == null) {
            first_decimal_pos += 4;
            continue;
        }
        if (first_group == null) {
            first_group = di;
            if (d >= 1000) {} // 4 chars, no leading zeros
            else if (d >= 100) {
                first_decimal_pos += 1;
            } else if (d >= 10) {
                first_decimal_pos += 2;
            } else {
                first_decimal_pos += 3;
            }
        }
        if (di == first_group.?) {
            if (d >= 1000) {
                dec.appendAssumeCapacity(@intCast(d / 1000 + '0'));
                d %= 1000;
            }
            if (d >= 100 or dec.items.len > 0) {
                dec.appendAssumeCapacity(@intCast(d / 100 + '0'));
                d %= 100;
            }
            if (d >= 10 or dec.items.len > 0) {
                dec.appendAssumeCapacity(@intCast(d / 10 + '0'));
                d %= 10;
            }
            dec.appendAssumeCapacity(@intCast(d + '0'));
        } else {
            dec.appendAssumeCapacity(@intCast(d / 1000 + '0'));
            d %= 1000;
            dec.appendAssumeCapacity(@intCast(d / 100 + '0'));
            d %= 100;
            dec.appendAssumeCapacity(@intCast(d / 10 + '0'));
            d %= 10;
            dec.appendAssumeCapacity(@intCast(d + '0'));
        }
    }

    const total = dec.items.len;
    if (total == 0) {
        dec.deinit(allocator);
        return .{ .string = try allocator.dupe(u8, "0") };
    }

    // Find first non-zero within raw digits
    var fnz: usize = 0;
    while (fnz < total and dec.items[fnz] == '0') : (fnz += 1) {}
    if (fnz >= total) {
        dec.deinit(allocator);
        return .{ .string = try allocator.dupe(u8, "0") };
    }
    // Adjust: raw fnz is within dec; actual decimal position is first_decimal_pos + fnz
    const true_fnz = first_decimal_pos + fnz;
    const dscale_usz: usize = @intCast(dscale);

    // Phase 2: heap buffer (was fixed [256]u8 — overflowed on large numeric / high dscale).
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // Upper bound: sign + int digits + '.' + dscale padding.
    const cap_hint = 1 + total + dscale_usz + 2;
    try out.ensureTotalCapacity(allocator, cap_hint);

    if (is_neg) try out.append(allocator, '-');

    if (true_fnz >= digits_before_dot) {
        // Pure fraction: "0.00...xxx"
        try out.append(allocator, '0');
        try out.append(allocator, '.');
        const lead_zeros = true_fnz - digits_before_dot;
        try out.appendNTimes(allocator, '0', lead_zeros);
        const frac_room = if (lead_zeros < dscale_usz) dscale_usz - lead_zeros else 0;
        const frac_chars = @min(total - fnz, frac_room);
        try out.appendSlice(allocator, dec.items[fnz .. fnz + frac_chars]);
        const padded = lead_zeros + frac_chars;
        if (dscale_usz > padded) try out.appendNTimes(allocator, '0', dscale_usz - padded);
    } else {
        // Integer + optional fraction
        const int_chars = digits_before_dot - true_fnz;
        const int_out = @min(int_chars, total - fnz);
        try out.appendSlice(allocator, dec.items[fnz .. fnz + int_out]);
        // PG may strip trailing zero base-10000 groups from numeric values, so
        // `ndigits` can be less than `weight + 1`. When that happens, the integer
        // part needs left-padding zeros to fill the higher base-10000 groups.
        // Example: digits=[10], weight=1 → 10 * 10000^1 = 100000 needs 4 zeros
        // padded after the "10" to produce "100000". Without this, 100000 → "10".
        if (int_out < int_chars) {
            try out.appendNTimes(allocator, '0', int_chars - int_out);
        }
        if (dscale_usz > 0) {
            try out.append(allocator, '.');
            const frac_avail = if (total > fnz + int_out) total - fnz - int_out else 0;
            const frac_out = @min(frac_avail, dscale_usz);
            try out.appendSlice(allocator, dec.items[fnz + int_out .. fnz + int_out + frac_out]);
            if (frac_out < dscale_usz) try out.appendNTimes(allocator, '0', dscale_usz - frac_out);
        }
    }

    dec.deinit(allocator);
    const owned = try out.toOwnedSlice(allocator);
    return .{ .string = owned };
}

/// Format PG date (days since 2000-01-01) as `YYYY-MM-DD`.
fn pgFormatDate(allocator: std.mem.Allocator, days_since_2000: i32) ![]u8 {
    // 2000-01-01 = Unix epoch day 10957 (days since 1970-01-01).
    const unix_days: i64 = @as(i64, days_since_2000) + 10957;
    // Civil from days (Howard Hinnant algorithm).
    const z = unix_days + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    var y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    y += if (m <= 2) @as(i64, 1) else 0;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(y)),
        @as(u32, @intCast(m)),
        @as(u32, @intCast(d)),
    });
}

/// Format PG timestamp (µs since 2000-01-01) as ISO-8601 UTC `YYYY-MM-DDTHH:MM:SS.ffffff`.
/// When `is_tz` is true (timestamptz, OID 1184), appends `+00` suffix (PG stores timestamptz in UTC).
fn pgFormatTimestamp(allocator: std.mem.Allocator, us_since_2000: i64, is_tz: bool) ![]u8 {
    const us_per_day: i64 = 86_400_000_000;
    const days: i32 = @intCast(@divFloor(us_since_2000, us_per_day));
    var us_rem = @mod(us_since_2000, us_per_day);
    if (us_rem < 0) us_rem += us_per_day;
    const date = try pgFormatDate(allocator, days);
    defer allocator.free(date);
    const secs = @divFloor(us_rem, 1_000_000);
    const frac = @mod(us_rem, 1_000_000);
    const h = @divFloor(secs, 3600);
    const mi = @divFloor(@mod(secs, 3600), 60);
    const s = @mod(secs, 60);
    if (is_tz) {
        return std.fmt.allocPrint(allocator, "{s}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}+00", .{
            date,
            @as(u32, @intCast(h)),
            @as(u32, @intCast(mi)),
            @as(u32, @intCast(s)),
            @as(u32, @intCast(frac)),
        });
    }
    return std.fmt.allocPrint(allocator, "{s}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
        date,
        @as(u32, @intCast(h)),
        @as(u32, @intCast(mi)),
        @as(u32, @intCast(s)),
        @as(u32, @intCast(frac)),
    });
}

/// Format PG interval (int32 months, int32 days, int64 microseconds) as ISO-8601 duration.
/// When months/days > 0: `P[nY][nM][nD]T[nH][nM][nS]`; else: `HH:MM:SS.ffffff`.
fn pgFormatInterval(allocator: std.mem.Allocator, months: i32, days: i32, us_total: i64) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.ensureTotalCapacity(allocator, 256);
    errdefer buf.deinit(allocator);

    if (months != 0 or days != 0) {
        try buf.append(allocator, 'P');
        if (months != 0) {
            const s = try std.fmt.allocPrint(allocator, "{d}M", .{@abs(months)});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        }
        if (days != 0) {
            const s = try std.fmt.allocPrint(allocator, "{d}D", .{@abs(days)});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        }
        if (us_total != 0) {
            try buf.append(allocator, 'T');
            try pgAppendTimePart(allocator, &buf, us_total);
        }
    } else {
        try pgAppendTimePart(allocator, &buf, us_total);
    }
    return buf.toOwnedSlice(allocator);
}

/// Append time part (HH:MM:SS.ffffff or -HH:MM:SS.ffffff) to an ArrayList.
fn pgAppendTimePart(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), us_total: i64) !void {
    var us = @abs(us_total);
    if (us_total < 0) try buf.append(allocator, '-');

    const h = @divFloor(@as(i64, @intCast(us)), 3_600_000_000);
    us -= @as(u64, @intCast(h)) * 3_600_000_000;
    const mi = @divFloor(@as(i64, @intCast(us)), 60_000_000);
    us -= @as(u64, @intCast(mi)) * 60_000_000;
    const s = @divFloor(@as(i64, @intCast(us)), 1_000_000);
    const frac = us - @as(u64, @intCast(s)) * 1_000_000;
    const time_str = try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
        @as(u32, @intCast(@abs(h))),
        @as(u32, @intCast(@abs(mi))),
        @as(u32, @intCast(@abs(s))),
        @as(u32, @intCast(frac)),
    });
    defer allocator.free(time_str);
    try buf.appendSlice(allocator, time_str);
}

/// Format PG time (µs since midnight) as `HH:MM:SS.ffffff` or `HH:MM:SS.ffffff±HH:MM`.
fn pgFormatTime(allocator: std.mem.Allocator, us_since_midnight: i64, tz_offset_secs: i32) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.ensureTotalCapacity(allocator, 64);
    errdefer buf.deinit(allocator);
    try pgAppendTimePart(allocator, &buf, us_since_midnight);
    if (tz_offset_secs != 0) {
        const abs_offset = @abs(tz_offset_secs);
        const tz_h = @divFloor(abs_offset, 3600);
        const tz_m = @divFloor(@mod(abs_offset, 3600), 60);
        const sign: u8 = if (tz_offset_secs >= 0) '+' else '-';
        const tz_str = try std.fmt.allocPrint(allocator, "{c}{d:0>2}:{d:0>2}", .{ sign, tz_h, tz_m });
        defer allocator.free(tz_str);
        try buf.appendSlice(allocator, tz_str);
    }
    return buf.toOwnedSlice(allocator);
}

/// Format PG inet/cidr binary as text representation.
fn pgFormatInet(allocator: std.mem.Allocator, family: u8, prefix_len: u8, is_cidr: bool, addr: []const u8) ![]u8 {
    if (family == 2) {
        // AF_INET: 4 bytes
        if (addr.len != 4) return error.DatabaseError;
        // Mask network bits for CIDR
        var masked = [_]u8{ 0, 0, 0, 0 };
        @memcpy(&masked, addr);
        if (is_cidr and prefix_len < 32) {
            if (prefix_len == 0) {
                @memset(&masked, 0);
            } else {
                const mask: u32 = @truncate(@as(u64, 0xFFFFFFFF) << @intCast(32 - prefix_len));
                const host_bits = std.mem.readInt(u32, &masked, .big);
                std.mem.writeInt(u32, &masked, host_bits & mask, .big);
            }
        }
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}/{d}", .{
            masked[0], masked[1], masked[2], masked[3], prefix_len,
        });
    } else if (family == 3) {
        // AF_INET6: 16 bytes
        if (addr.len != 16) return error.DatabaseError;
        var masked: [16]u8 = undefined;
        @memcpy(&masked, addr);
        if (is_cidr and prefix_len < 128) {
            const byte_idx: usize = @intCast(prefix_len / 8);
            const bit_in_byte: u8 = prefix_len % 8;
            // Zero bytes at and after byte_idx, then restore partial byte prefix
            for (byte_idx..16) |i| masked[i] = 0;
            if (bit_in_byte > 0 and byte_idx < 16) {
                // mask: keep top bit_in_byte bits, zero lower (8 - bit_in_byte) bits
                const shift = @as(u3, @intCast(8 - bit_in_byte));
                const m: u8 = @truncate(@as(u16, 0xFF) << shift);
                masked[byte_idx] &= m;
            }
        }
        return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}/{d}", .{
            masked[0],  masked[1],  masked[2],  masked[3],
            masked[4],  masked[5],  masked[6],  masked[7],
            masked[8],  masked[9],  masked[10], masked[11],
            masked[12], masked[13], masked[14], masked[15],
            prefix_len,
        });
    }
    return error.DatabaseError;
}

/// Escape a single value for PostgreSQL `COPY ... FROM STDIN WITH (FORMAT csv)`.
fn appendCsvCell(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len == 0) {
        return try buf.appendSlice(allocator, "\"\"");
    }
    var needs_quote = false;
    for (value) |ch| {
        if (ch == ',' or ch == '"' or ch == '\n' or ch == '\r') {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote) {
        return try buf.appendSlice(allocator, value);
    }
    try buf.append(allocator, '"');
    for (value) |ch| {
        if (ch == '"') try buf.append(allocator, '"');
        try buf.append(allocator, ch);
    }
    try buf.append(allocator, '"');
}

pub const PostgresConn = struct {
    conn: ?*libpq_c.PGconn,
    allocator: std.mem.Allocator,
    /// Socket read timeout (ms); 0 = disabled. Applied via SO_RCVTIMEO so
    /// synchronous PQexec*/PQgetResult reads cannot hang forever. NOTE: this
    /// is a per-read idle timeout (kernel), not a whole-query deadline — a
    /// slow-but-progressing query is not cut off.
    query_timeout_ms: u32 = 0,
    /// LRU-style prepared statement cache: SQL text → null-terminated statement name.
    /// Values MUST stay `[:0]u8` (from `allocZ`): coercing to `[]const u8` then `free`
    /// drops the sentinel and panics SafeAllocator with alloc=N+1 / free=N.
    stmt_cache: std.StringHashMap(CachedStmt([:0]u8)),
    stmt_counter: u64 = 0,
    magic: u32 = 0xDBDBDBDB,

    fn guard(self: *const @This()) void {
        if (self.magic != 0xDBDBDBDB) @panic("DB heap corruption detected (PG magic mismatch)");
    }

    fn poison(self: *@This()) void {
        self.magic = 0xDEADDEAD;
    }

    /// Connect using explicit parameters via dlsym (bypasses Zig C ABI issues)
    pub fn connectParams(allocator: std.mem.Allocator, host: []const u8, port: u16, user: []const u8, pass: []const u8, db: []const u8, query_timeout_ms: u32) !PostgresConn {
        // Use PQconnectdb with conninfo string so we can set sslmode
        const sslmode = if (std.c.getenv("PGSSLMODE")) |v| std.mem.span(v) else "require";
        const conninfo = try std.fmt.allocPrint(allocator, "host={s} port={d} dbname={s} user={s} password={s} sslmode={s} connect_timeout=10", .{ host, port, db, user, pass, sslmode });
        defer allocator.free(conninfo);
        return connect(allocator, conninfo, query_timeout_ms);
    }

    /// Null-terminated string connect
    pub fn connect(allocator: std.mem.Allocator, conninfo: []const u8, query_timeout_ms: u32) !PostgresConn {
        const null_terminated = try allocZ(allocator, conninfo);
        defer allocator.free(null_terminated);
        const conn = libpq_c.PQconnectdb(null_terminated);
        if (conn == null) return error.DatabaseError;
        const status = libpq_c.PQstatus(conn);
        if (status != .CONNECTION_OK) {
            const err_msg = libpq_c.PQerrorMessage(conn);
            std.log.err("PG connect failed (status={s}): {s}", .{ @tagName(status), std.mem.span(err_msg) });
            libpq_c.PQfinish(conn);
            return error.DatabaseError;
        }
        applySocketTimeout(conn.?, query_timeout_ms);
        return .{ .conn = conn, .allocator = allocator, .query_timeout_ms = query_timeout_ms, .stmt_cache = std.StringHashMap(CachedStmt([:0]u8)).init(allocator) };
    }

    /// Apply SO_RCVTIMEO to the libpq socket so synchronous PQexec* reads
    /// cannot block a worker thread forever (Threaded Io M:N fibers). A
    /// timed-out read leaves the connection in an indeterminate state — the
    /// pool's ping / single-conn reconnect paths recover it on next use.
    fn applySocketTimeout(conn: *libpq_c.PGconn, timeout_ms: u32) void {
        if (timeout_ms == 0) return;
        const fd = libpq_c.PQsocket(conn);
        if (fd < 0) return;
        var tv = std.posix.timeval{
            .sec = @intCast(@divTrunc(@as(i64, @intCast(timeout_ms)), 1000)),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(@intCast(fd), std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch |err| {
            std.log.warn("[sqlx] PG SO_RCVTIMEO apply failed: {s}", .{@errorName(err)});
        };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const res = execPrepared(self, sql_str, args);
        if (res == null) {
            std.log.err("PG queryFn: execPrepared returned null sql={s}", .{sql_str});
            return error.DatabaseError;
        }
        defer libpq_c.PQclear(res.?);

        const status = libpq_c.PQresultStatus(res.?);
        if (status != libpq_c.ExecStatusType.PGRES_TUPLES_OK) {
            const err_msg = std.mem.span(libpq_c.PQerrorMessage(self.conn));
            std.log.err("PG queryFn: status={d} sql={s} err={s}", .{ @backingInt(status), sql_str, err_msg });
            if (status == libpq_c.ExecStatusType.PGRES_FATAL_ERROR) {
                const diag = diagnosePostgres(res);
                const sqlstate = cStrSpan(libpq_c.PQresultErrorField(res.?, PG_DIAG_SQLSTATE));
                const db_err = errors.sqlStateToError(sqlstate);

                switch (db_err) {
                    error.ConstraintViolation => {
                        std.log.err("PG constraint violation: table={s} column={s}", .{ diag.table orelse "?", diag.column orelse "?" });
                        return error.ConstraintViolation;
                    },
                    error.NotFound => return error.NotFound,
                    error.ConnectionFailed => return error.DatabaseConnectionFailed,
                    error.SerializationFailure => return error.SerializationFailure,
                    error.ReadOnlyViolation => return error.ReadOnlyViolation,
                    else => return error.DatabaseError,
                }
            }
            return error.DatabaseError;
        }

        const n_rows = libpq_c.PQntuples(res.?);
        const n_cols = libpq_c.PQnfields(res.?);

        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        const shared_columns = arena_alloc.alloc([]const u8, @intCast(n_cols)) catch return error.DatabaseError;
        for (0..@intCast(n_cols)) |c| {
            const name = cStrSpan(libpq_c.PQfname(res.?, @intCast(c)));
            shared_columns[c] = arena_alloc.dupe(u8, name) catch return error.DatabaseError;
        }

        for (0..@intCast(n_rows)) |r| {
            const values = arena_alloc.alloc(?Value, @intCast(n_cols)) catch return error.DatabaseError;
            for (0..@intCast(n_cols)) |c| {
                values[c] = pgReadCell(arena_alloc, res.?, @intCast(r), @intCast(c)) catch return error.DatabaseError;
            }
            rows_list.append(arena_alloc, .{ .arena = undefined, .columns = shared_columns, .values = values }) catch return error.DatabaseError;
        }

        const rows_slice = arena_alloc.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const res = execPrepared(self, sql_str, args);
        if (res == null) {
            std.log.err("PG execFn: execPrepared returned null sql={s}", .{sql_str});
            return error.DatabaseError;
        }
        defer libpq_c.PQclear(res.?);

        const status = libpq_c.PQresultStatus(res.?);
        if (status != libpq_c.ExecStatusType.PGRES_COMMAND_OK and status != libpq_c.ExecStatusType.PGRES_TUPLES_OK) {
            const err_msg = std.mem.span(libpq_c.PQerrorMessage(self.conn));
            std.log.err("PG execFn: status={d} sql={s} err={s}", .{ @backingInt(status), sql_str, err_msg });
            if (status == libpq_c.ExecStatusType.PGRES_FATAL_ERROR) {
                const diag = diagnosePostgres(res.?);
                const sqlstate = cStrSpan(libpq_c.PQresultErrorField(res.?, PG_DIAG_SQLSTATE));
                const db_err = errors.sqlStateToError(sqlstate);

                switch (db_err) {
                    error.ConstraintViolation => {
                        std.log.err("PG constraint violation: table={s} column={s}", .{ diag.table orelse "?", diag.column orelse "?" });
                        return error.ConstraintViolation;
                    },
                    error.NotFound => return error.NotFound,
                    error.ConnectionFailed => return error.DatabaseConnectionFailed,
                    error.SerializationFailure => return error.SerializationFailure,
                    error.ReadOnlyViolation => return error.ReadOnlyViolation,
                    else => return error.DatabaseError,
                }
            }
            return error.DatabaseError;
        }

        const cmd = std.mem.span(libpq_c.PQcmdTuples(res));
        const affected = std.fmt.parseInt(u64, cmd, 10) catch 0;
        return ExecResult{ .rows_affected = affected };
    }

    /// Execute with prepared statement caching. First call prepares and caches;
    /// subsequent calls reuse via PQexecPrepared (server-side).
    /// Falls back to `execParamsDirect` on prepare failure or zero-arg queries.
    fn execPrepared(self: *PostgresConn, sql_str: []const u8, args: []const Value) ?*libpq_c.PGresult {
        // No bind params → PQexec is enough (and avoids polluting the stmt cache).
        if (args.len == 0) {
            return execParamsDirect(self, sql_str, args);
        }

        // Cache key = original Zig SQL (`?` placeholders). Hit → PQexecPrepared.
        if (self.stmt_cache.getPtr(sql_str)) |entry| {
            self.stmt_counter += 1;
            entry.last_used = self.stmt_counter;
            if (self.execPreparedStmt(entry.value, args)) |res| return res;
            // Cached name may be stale after reconnect; drop and re-prepare below.
            if (self.stmt_cache.fetchRemove(sql_str)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.value);
            }
        }

        const pg_sql = convertPlaceholders(self.allocator, sql_str) orelse return execParamsDirect(self, sql_str, args);
        defer self.allocator.free(pg_sql);

        // Evict LRU entry when at capacity.
        if (self.stmt_cache.count() >= PG_MAX_CACHED_STMTS) {
            if (findLruStmtKey([:0]u8, self.stmt_cache)) |lru_key| {
                if (self.stmt_cache.fetchRemove(lru_key)) |kv| {
                    var dealloc_buf: [80]u8 = undefined;
                    if (bufPrintZ(&dealloc_buf, "DEALLOCATE {s}", .{kv.value.value})) |dealloc_sql| {
                        if (self.conn) |c| {
                            if (libpq_c.PQexec(c, @ptrCast(dealloc_sql.ptr))) |dr| libpq_c.PQclear(dr);
                        }
                    } else |_| {}
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value.value);
                }
            }
        }

        self.stmt_counter += 1;
        var stmt_buf: [32]u8 = undefined;
        const stmt_name_z = bufPrintZ(&stmt_buf, "zs_{d}", .{self.stmt_counter}) catch {
            return execParamsDirect(self, sql_str, args);
        };

        const prep_res = libpq_c.PQprepare(self.conn, @ptrCast(stmt_name_z.ptr), @ptrCast(pg_sql.ptr), @intCast(args.len), null);
        if (prep_res == null) return execParamsDirect(self, sql_str, args);
        defer libpq_c.PQclear(prep_res.?);
        if (libpq_c.PQresultStatus(prep_res.?) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) {
            const err = std.mem.span(libpq_c.PQerrorMessage(self.conn));
            std.log.warn("PG PQprepare failed, falling back to PQexecParams: {s}", .{err});
            return execParamsDirect(self, sql_str, args);
        }

        const sql_dup = self.allocator.dupe(u8, sql_str) catch {
            return self.execPreparedStmt(stmt_name_z, args) orelse execParamsDirect(self, sql_str, args);
        };
        const stmt_name_dup = allocZ(self.allocator, stmt_name_z) catch {
            self.allocator.free(sql_dup);
            return self.execPreparedStmt(stmt_name_z, args) orelse execParamsDirect(self, sql_str, args);
        };
        self.stmt_counter += 1;
        self.stmt_cache.put(sql_dup, .{ .value = stmt_name_dup, .last_used = self.stmt_counter }) catch {
            self.allocator.free(sql_dup);
            self.allocator.free(stmt_name_dup);
            return self.execPreparedStmt(stmt_name_z, args) orelse execParamsDirect(self, sql_str, args);
        };

        return self.execPreparedStmt(stmt_name_dup, args);
    }

    /// Direct PQexecParams (no prepared statement cache).
    fn execParamsDirect(self: *PostgresConn, sql_str: []const u8, args: []const Value) ?*libpq_c.PGresult {
        // Use PQexec (simple query, no params) for queries without args
        // Must null-terminate the SQL string for libpq
        if (args.len == 0) {
            const pg_sql_simple = allocZ(self.allocator, sql_str) catch return null;
            defer self.allocator.free(pg_sql_simple);
            const res = libpq_c.PQexec(self.conn, @ptrCast(pg_sql_simple.ptr));
            if (res == null) {
                std.log.err("PG PQexec returned null", .{});
                return null;
            }
            const status = libpq_c.PQresultStatus(res.?);
            if (status != libpq_c.ExecStatusType.PGRES_TUPLES_OK and status != libpq_c.ExecStatusType.PGRES_COMMAND_OK) {
                const err = std.mem.span(libpq_c.PQerrorMessage(self.conn));
                std.log.err("PG PQexec failed: sql={s} err={s}", .{ sql_str, err });
                libpq_c.PQclear(res.?);
                return null;
            }
            return res.?;
        }

        // Convert ? → $1,$2,...
        const pg_sql = convertPlaceholders(self.allocator, sql_str) orelse return null;
        defer self.allocator.free(pg_sql);

        const param_count = args.len;
        const paramValues = self.allocator.alloc(?[*]const u8, param_count) catch return null;
        errdefer self.allocator.free(paramValues);
        const paramLengths = self.allocator.alloc(c_int, param_count) catch {
            self.allocator.free(paramValues);
            return null;
        };
        errdefer self.allocator.free(paramLengths);
        const paramAllocs = self.allocator.alloc(?[:0]const u8, param_count) catch {
            self.allocator.free(paramValues);
            self.allocator.free(paramLengths);
            return null;
        };
        defer {
            for (paramAllocs) |maybe_alloc| {
                if (maybe_alloc) |a| self.allocator.free(a);
            }
            self.allocator.free(paramAllocs);
            self.allocator.free(paramLengths);
            self.allocator.free(paramValues);
        }
        @memset(paramAllocs, null);

        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => blk: {
                    paramLengths[i] = 0;
                    break :blk null;
                },
                .int => |v| blk: {
                    const s = allocPrintZ(self.allocator, "{d}", .{v}) catch return null;
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .float => |v| blk: {
                    const s = allocPrintZ(self.allocator, "{d}", .{v}) catch return null;
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .string => |v| blk: {
                    const s = allocZ(self.allocator, v) catch return null;
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .bool => |v| blk: {
                    paramLengths[i] = 1;
                    break :blk if (v) @ptrCast("t") else @ptrCast("f");
                },
            };
        }

        const res = libpq_c.PQexecParams(self.conn, @ptrCast(pg_sql.ptr), @intCast(param_count), null, @ptrCast(paramValues.ptr), @ptrCast(paramLengths.ptr), null, PG_RESULT_BINARY);
        if (res == null) {
            const err = std.mem.span(libpq_c.PQerrorMessage(self.conn));
            std.log.err("PG PQexecParams returned null: err={s}", .{err});
        }
        return res;
    }

    /// Execute already-prepared statement.
    /// Param strings live in a local arena until `PQexecPrepared` returns (heysen §1.1/§1.2).
    /// `stmt_name` must be null-terminated (`[:0]const u8` or a `bufPrintZ` stack name).
    fn execPreparedStmt(self: *PostgresConn, stmt_name: [:0]const u8, args: []const Value) ?*libpq_c.PGresult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const paramValues = aa.alloc(?[*:0]const u8, args.len) catch return null;
        const paramLengths = aa.alloc(c_int, args.len) catch return null;

        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => blk: {
                    paramLengths[i] = 0;
                    break :blk null;
                },
                .int => |v| blk: {
                    const s = allocPrintZ(aa, "{d}", .{v}) catch return null;
                    paramLengths[i] = @intCast(s.len);
                    break :blk s.ptr;
                },
                .float => |v| blk: {
                    const s = allocPrintZ(aa, "{d}", .{v}) catch return null;
                    paramLengths[i] = @intCast(s.len);
                    break :blk s.ptr;
                },
                .string => |v| blk: {
                    const s = allocZ(aa, v) catch return null;
                    paramLengths[i] = @intCast(s.len);
                    break :blk s.ptr;
                },
                .bool => |v| blk: {
                    paramLengths[i] = 1;
                    break :blk if (v) @as(?[*:0]const u8, @ptrCast("t")) else @ptrCast("f");
                },
            };
        }

        // Cached names are allocZ'd; stack names from bufPrintZ are also sentinel-terminated.
        return libpq_c.PQexecPrepared(
            self.conn,
            @ptrCast(stmt_name.ptr),
            @intCast(args.len),
            @ptrCast(paramValues.ptr),
            @ptrCast(paramLengths.ptr),
            null,
            PG_RESULT_BINARY,
        );
    }

    /// Bytes consumed when `sql[i]` opens a string literal (`'...'` with `''`
    /// escapes), quoted identifier (`"..."`), `--` line comment, or `/* ... */`
    /// block comment; 0 when `sql[i]` is plain SQL text.
    fn skipQuotedOrComment(sql: []const u8, i: usize) usize {
        const c = sql[i];
        if (c == '\'') {
            var j = i + 1;
            while (j < sql.len) {
                if (sql[j] == '\'') {
                    j += 1;
                    if (j < sql.len and sql[j] == '\'') {
                        j += 1; // escaped ''
                        continue;
                    }
                    return j - i;
                }
                j += 1;
            }
            return sql.len - i; // unterminated — consume the rest
        }
        if (c == '"') {
            var j = i + 1;
            while (j < sql.len and sql[j] != '"') : (j += 1) {}
            return if (j < sql.len) j + 1 - i else sql.len - i;
        }
        if (c == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
            var j = i;
            while (j < sql.len and sql[j] != '\n') : (j += 1) {}
            return j - i;
        }
        if (c == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
            var j = i + 2;
            while (j + 1 < sql.len and !(sql[j] == '*' and sql[j + 1] == '/')) : (j += 1) {}
            return if (j + 1 < sql.len) j + 2 - i else sql.len - i;
        }
        return 0;
    }

    /// Number of digits following a `?` placeholder at `sql[i]` (sqlite-style
    /// `?N` numbering). The digits must be consumed so `?1` becomes `$1`, not
    /// `$11`.
    fn placeholderDigits(sql: []const u8, i: usize) usize {
        var j = i + 1;
        while (j < sql.len and std.ascii.isDigit(sql[j])) : (j += 1) {}
        return j - i - 1;
    }

    /// Converts sqlite-style `?` / `?N` placeholders to PostgreSQL `$N`.
    ///
    /// Every placeholder is numbered sequentially in order of appearance and
    /// trailing digits are consumed, so `?`, `?2`, `?` become `$1`, `$2`, `$3`.
    /// Quoted strings, quoted identifiers, `--` comments and `/* */` comments
    /// are skipped so `?` inside literals is never rewritten.
    fn convertPlaceholders(allocator: std.mem.Allocator, sql: []const u8) ?[:0]u8 {
        // Pass 1: count placeholders and compute the exact output size.
        var count: usize = 0;
        var removed: usize = 0;
        var added: usize = 0;
        var i: usize = 0;
        while (i < sql.len) {
            const skipped = skipQuotedOrComment(sql, i);
            if (skipped > 0) {
                i += skipped;
                continue;
            }
            if (sql[i] == '?') {
                count += 1;
                const digits = placeholderDigits(sql, i);
                removed += 1 + digits;
                var tmp: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "${d}", .{count}) catch return null;
                added += s.len;
                i += 1 + digits;
            } else {
                i += 1;
            }
        }
        if (count == 0) return allocZ(allocator, sql) catch null;

        // Pass 2: emit `$N`, consuming `?N` digits verbatim-skipped elsewhere.
        const buf = allocator.allocSentinel(u8, sql.len - removed + added, 0) catch return null;
        var pos: usize = 0;
        var n: usize = 0;
        i = 0;
        while (i < sql.len) {
            const skipped = skipQuotedOrComment(sql, i);
            if (skipped > 0) {
                @memcpy(buf[pos .. pos + skipped], sql[i .. i + skipped]);
                pos += skipped;
                i += skipped;
                continue;
            }
            if (sql[i] == '?') {
                n += 1;
                var tmp: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "${d}", .{n}) catch {
                    allocator.free(buf);
                    return null;
                };
                @memcpy(buf[pos .. pos + s.len], s);
                pos += s.len;
                i += 1 + placeholderDigits(sql, i);
            } else {
                buf[pos] = sql[i];
                pos += 1;
                i += 1;
            }
        }
        return buf[0..pos :0];
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        // Deallocate all cached prepared statements
        var it = self.stmt_cache.iterator();
        while (it.next()) |entry| {
            var dealloc_buf: [64]u8 = undefined;
            const sql = bufPrintZ(&dealloc_buf, "DEALLOCATE {s}", .{entry.value_ptr.value}) catch "";
            if (self.conn != null) _ = libpq_c.PQexec(self.conn, @ptrCast(sql.ptr));
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.stmt_cache.deinit();
        if (self.conn) |conn| {
            libpq_c.PQfinish(conn);
            self.conn = null;
        }
        self.poison();
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (self.conn == null or libpq_c.PQstatus(self.conn) != libpq_c.ConnStatusType.CONNECTION_OK) return error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const res = libpq_c.PQexec(self.conn, "BEGIN");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const res = libpq_c.PQexec(self.conn, "COMMIT");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const res = libpq_c.PQexec(self.conn, "ROLLBACK");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    fn prepareFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const stmt = allocator.create(PostgresStmt) catch return error.DatabaseError;
        errdefer allocator.destroy(stmt);
        stmt.* = PostgresStmt.prepare(self.conn, allocator, sql_str) catch return error.DatabaseError;
        return stmt.toStmt();
    }

    fn queryCursorFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value, opts: CursorOptions) errors.ResultT(Cursor) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (opts.mode == .buffered) {
            const rows = try queryFn(ptr, allocator, sql_str, args);
            return Cursor.init(rows);
        }

        // Convert ? → $1,$2,... then null-terminate for libpq.
        // Keep branches separate: `if (a) []u8 else [:0]u8` coerces to []u8 and
        // `free` then drops the sentinel (alloc=N+1 / free=N SafeAllocator panic).
        const sql_z: [:0]u8 = blk: {
            if (args.len == 0) {
                break :blk allocZ(allocator, sql_str) catch return error.DatabaseError;
            }
            const pg_sql = convertPlaceholders(self.allocator, sql_str) orelse return error.DatabaseError;
            defer self.allocator.free(pg_sql);
            break :blk allocZ(allocator, pg_sql) catch return error.DatabaseError;
        };
        defer allocator.free(sql_z);

        // Build text parameter arrays. Owned by `allocator` and freed before return.
        const paramValues = allocator.alloc(?[*]const u8, args.len) catch return error.DatabaseError;
        defer allocator.free(paramValues);
        const paramLengths = allocator.alloc(c_int, args.len) catch return error.DatabaseError;
        defer allocator.free(paramLengths);
        const paramAllocs = allocator.alloc(?[]u8, args.len) catch return error.DatabaseError;
        defer {
            for (paramAllocs) |maybe| {
                if (maybe) |a| allocator.free(a);
            }
            allocator.free(paramAllocs);
        }
        @memset(paramAllocs, null);

        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => blk: {
                    paramLengths[i] = 0;
                    break :blk null;
                },
                .int => |v| blk: {
                    const s = std.fmt.allocPrint(allocator, "{d}", .{v}) catch return error.DatabaseError;
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .float => |v| blk: {
                    const s = std.fmt.allocPrint(allocator, "{d}", .{v}) catch return error.DatabaseError;
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .string => |v| blk: {
                    const s = allocator.dupe(u8, v) catch return error.DatabaseError;
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .bool => |v| blk: {
                    paramLengths[i] = 1;
                    break :blk if (v) @ptrCast("t") else @ptrCast("f");
                },
            };
        }

        if (libpq_c.PQsendQueryParams(self.conn, @ptrCast(sql_z.ptr), @intCast(args.len), null, @ptrCast(paramValues.ptr), @ptrCast(paramLengths.ptr), null, 0) == 0) {
            return error.DatabaseError;
        }
        _ = libpq_c.PQsetSingleRowMode(self.conn);
        _ = libpq_c.PQconsumeInput(self.conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var first = libpq_c.PQgetResult(self.conn);
        var columns: [][]u8 = &[_][]u8{};
        var eof = false;
        if (first) |r| {
            const status = libpq_c.PQresultStatus(r);
            if (status == libpq_c.ExecStatusType.PGRES_COMMAND_OK) {
                libpq_c.PQclear(r);
                first = null;
                eof = true;
            } else if (status == libpq_c.ExecStatusType.PGRES_TUPLES_OK or status == libpq_c.ExecStatusType.PGRES_SINGLE_TUPLE) {
                const n_cols = libpq_c.PQnfields(r);
                if (n_cols > 0) {
                    columns = arena.allocator().alloc([]u8, @intCast(n_cols)) catch return error.DatabaseError;
                    for (0..@intCast(n_cols)) |c| {
                        const name = std.mem.span(libpq_c.PQfname(r, @intCast(c)));
                        columns[c] = arena.allocator().dupe(u8, name) catch return error.DatabaseError;
                    }
                }
            } else {
                libpq_c.PQclear(r);
                return error.DatabaseError;
            }
        } else {
            eof = true;
        }

        return Cursor{ .state = .{ .streaming_pg = .{
            .conn = self.conn,
            .arena = arena,
            .columns = columns,
            .row = undefined,
            .current = first,
            .eof = eof,
        } } };
    }

    /// Batch insert using PostgreSQL `COPY ... FROM STDIN WITH (FORMAT csv)`.
    fn copyFrom(self: *PostgresConn, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        validateIdentifier(table) catch return error.DatabaseError;
        if (rows.len == 0) return ExecResult{};
        if (columns.len == 0) return error.DatabaseError;
        for (columns) |c| validateIdentifier(c) catch return error.DatabaseError;

        var sql = std.ArrayList(u8).empty;
        defer sql.deinit(self.allocator);
        try sql.appendSlice(self.allocator, "COPY ");
        try sql.appendSlice(self.allocator, table);
        try sql.appendSlice(self.allocator, " (");
        for (columns, 0..) |col, i| {
            if (i > 0) try sql.appendSlice(self.allocator, ",");
            try sql.appendSlice(self.allocator, col);
        }
        try sql.appendSlice(self.allocator, ") FROM STDIN WITH (FORMAT csv)");

        const sql_z = allocZ(self.allocator, sql.items) catch return error.DatabaseError;
        defer self.allocator.free(sql_z);

        const begin = libpq_c.PQexec(self.conn, "BEGIN");
        defer if (begin) |b| libpq_c.PQclear(b);
        if (begin == null or libpq_c.PQresultStatus(begin.?) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;

        const res = libpq_c.PQexec(self.conn, @ptrCast(sql_z.ptr));
        defer if (res) |r| libpq_c.PQclear(r);
        if (res == null or libpq_c.PQresultStatus(res.?) != libpq_c.ExecStatusType.PGRES_COPY_IN) return error.DatabaseError;

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        for (rows) |row| {
            if (row.len != columns.len) return error.DatabaseError;
            buf.items.len = 0;
            for (row, 0..) |val, c| {
                if (c > 0) try buf.append(self.allocator, ',');
                switch (val) {
                    .null => try buf.appendSlice(self.allocator, "\\N"),
                    .int => |v| try buf.appendSlice(self.allocator, try std.fmt.allocPrint(scratch.allocator(), "{d}", .{v})),
                    .float => |v| try buf.appendSlice(self.allocator, try std.fmt.allocPrint(scratch.allocator(), "{d}", .{v})),
                    .string => |v| try appendCsvCell(self.allocator, &buf, v),
                    .bool => |v| try buf.appendSlice(self.allocator, if (v) "t" else "f"),
                }
            }
            try buf.appendSlice(self.allocator, "\n");
            if (libpq_c.PQputCopyData(self.conn, @ptrCast(buf.items.ptr), @intCast(buf.items.len)) != 1) {
                _ = libpq_c.PQputCopyEnd(self.conn, "copy data failed");
                return error.DatabaseError;
            }
        }

        if (libpq_c.PQputCopyEnd(self.conn, null) != 1) return error.DatabaseError;
        const final = libpq_c.PQgetResult(self.conn);
        defer if (final) |f| libpq_c.PQclear(f);
        if (final == null or libpq_c.PQresultStatus(final.?) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;

        const commit = libpq_c.PQexec(self.conn, "COMMIT");
        defer if (commit) |c| libpq_c.PQclear(c);
        if (commit == null or libpq_c.PQresultStatus(commit.?) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;

        const cmd = std.mem.span(libpq_c.PQcmdTuples(final.?));
        const affected = std.fmt.parseInt(u64, cmd, 10) catch 0;
        return ExecResult{ .rows_affected = affected };
    }

    fn batchInsertFn(ptr: *anyopaque, allocator: std.mem.Allocator, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        _ = allocator;
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        return self.copyFrom(table, columns, rows);
    }

    pub fn toConn(self: *PostgresConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
                .begin = beginFn,
                .commit = commitFn,
                .rollback = rollbackFn,
                .prepare = prepareFn,
                .queryCursor = queryCursorFn,
                .batchInsert = batchInsertFn,
            },
        };
    }
};

// ==================== MySQL Implementation ====================

fn formatQuery(allocator: std.mem.Allocator, sql: []const u8, args: []const Value) ![]u8 {
    var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var arg_idx: usize = 0;
    for (sql) |c| {
        if (c == '?') {
            if (arg_idx >= args.len) return error.DatabaseError;
            const arg = args[arg_idx];
            arg_idx += 1;
            switch (arg) {
                .null => try buf.appendSlice(allocator, "NULL"),
                .int => |v| try buf.print(allocator, "{d}", .{v}),
                .float => |v| try buf.print(allocator, "{d}", .{v}),
                .string => |v| {
                    try buf.append(allocator, '\'');
                    // Escape backslash and single quotes for MySQL sql_mode (NO_BACKSLASH_ESCAPES off by default)
                    for (v) |char| {
                        switch (char) {
                            '\\' => try buf.appendSlice(allocator, "\\\\"),
                            '\'' => try buf.appendSlice(allocator, "''"),
                            0x00 => try buf.appendSlice(allocator, "\\0"),
                            '\n' => try buf.appendSlice(allocator, "\\n"),
                            '\r' => try buf.appendSlice(allocator, "\\r"),
                            0x1a => try buf.appendSlice(allocator, "\\Z"),
                            else => try buf.append(allocator, char),
                        }
                    }
                    try buf.append(allocator, '\'');
                },
                .bool => |v| try buf.appendSlice(allocator, if (v) "1" else "0"),
            }
        } else {
            try buf.append(allocator, c);
        }
    }
    return allocator.dupe(u8, buf.items);
}

/// After a successful `mysql_real_query` for a statement that may return rows, build `Rows`.
/// `mysql_store_result` returns NULL in three cases: read failure (errno != 0), statements
/// with no result set (field_count == 0, e.g. INSERT), or an **empty SELECT** (errno == 0,
/// field_count > 0). The last case must yield zero rows, not `DatabaseError`.
/// Caller owns `arena` and should `errdefer arena.deinit()` until `Rows` is returned.
fn mysqlReadRowsAfterQuery(mysql: ?*libmysql_c.MYSQL, arena: std.heap.ArenaAllocator) errors.ResultT(Rows) {
    var arena_mut = arena;
    const arena_alloc = arena_mut.allocator();
    const res = libmysql_c.mysql_store_result(mysql);
    if (res) |r| {
        defer libmysql_c.mysql_free_result(r);

        const n_cols = libmysql_c.mysql_num_fields(r);
        const n_rows = libmysql_c.mysql_num_rows(r);

        const field_names = arena_alloc.alloc([]const u8, n_cols) catch return error.DatabaseError;
        for (0..n_cols) |c| {
            const field = libmysql_c.mysql_fetch_field(r) orelse return error.DatabaseError;
            const name = std.mem.span(field.name);
            field_names[c] = arena_alloc.dupe(u8, name) catch return error.DatabaseError;
        }

        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        for (0..n_rows) |_| {
            const row_data = libmysql_c.mysql_fetch_row(r);
            const lengths = libmysql_c.mysql_fetch_lengths(r);
            const values = arena_alloc.alloc(?Value, n_cols) catch return error.DatabaseError;
            for (0..n_cols) |c| {
                if (row_data == null or row_data.?[c] == null) {
                    values[c] = null;
                } else {
                    const len = lengths[c];
                    const val = row_data.?[c].?[0..len];
                    values[c] = .{ .string = arena_alloc.dupe(u8, val) catch return error.DatabaseError };
                }
            }
            // Share field_names across rows (same arena lifetime).
            rows_list.append(arena_alloc, .{ .arena = undefined, .columns = field_names, .values = values }) catch return error.DatabaseError;
        }

        const rows_slice = arena_alloc.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena_mut, .rows = rows_slice };
    }

    if (libmysql_c.mysql_errno(mysql) != 0) return error.DatabaseError;
    if (libmysql_c.mysql_field_count(mysql) == 0) return error.DatabaseError;
    const rows_slice = arena_alloc.alloc(Row, 0) catch return error.DatabaseError;
    const rows = Rows{ .arena = arena_mut, .rows = rows_slice };
    return rows;
}

/// Map MySQL/MariaDB errno to ZigModu errors.
fn mysqlErrnoToError(err_no: c_uint) errors.Error {
    return switch (err_no) {
        // Constraint violations
        1062, 1586 => error.ConstraintViolation, // ER_DUP_ENTRY, ER_DUP_ENTRY_WITH_KEY_NAME
        1451, 1452, 1216, 1217 => error.ConstraintViolation, // FK violations
        1048 => error.ConstraintViolation, // ER_BAD_NULL_ERROR
        // Not found
        1146 => error.NotFound, // ER_NO_SUCH_TABLE
        1054 => error.NotFound, // ER_BAD_FIELD_ERROR
        // Connection failures
        2006, 2013, 2003 => error.DatabaseConnectionFailed, // ER_SERVER_GONE, ER_QUERY_INTERRUPTED, ER_CONN_HOST_ERROR
        // Query failures
        1064 => error.QueryFailed, // ER_PARSE_ERROR
        // Default
        else => error.DatabaseError,
    };
}

/// Per-column bind buffer for binary result-set reading.
const MysqlBindBuffer = union(enum) {
    tiny: u8,
    short: i16,
    long: i32,
    longlong: i64,
    float: f32,
    double: f64,
    string: struct { buf: [4096]u8, len: usize = 0 },
};

/// Bind `args` onto a prepared statement. Scratch storage lives in `arena`.
fn mysqlBindParams(stmt: *libmysql_c.MYSQL_STMT, arena: std.mem.Allocator, args: []const Value) !void {
    if (args.len == 0) return;
    const binds = try arena.alloc(libmysql_c.MYSQL_BIND, args.len);
    @memset(binds, .{});
    const null_flags = try arena.alloc(libmysql_c.my_bool, args.len);
    const lengths = try arena.alloc(c_ulong, args.len);
    const int_bufs = try arena.alloc(i64, args.len);
    const float_bufs = try arena.alloc(f64, args.len);
    const bool_bufs = try arena.alloc(u8, args.len);

    for (args, 0..) |arg, i| {
        switch (arg) {
            .null => {
                null_flags[i] = 1;
                binds[i].buffer_type = libmysql_c.MYSQL_TYPE_NULL;
                binds[i].is_null = &null_flags[i];
            },
            .int => |v| {
                null_flags[i] = 0;
                int_bufs[i] = v;
                binds[i].buffer_type = libmysql_c.MYSQL_TYPE_LONGLONG;
                binds[i].buffer = @ptrCast(&int_bufs[i]);
                binds[i].is_null = &null_flags[i];
                binds[i].is_unsigned = 0;
            },
            .float => |v| {
                null_flags[i] = 0;
                float_bufs[i] = v;
                binds[i].buffer_type = libmysql_c.MYSQL_TYPE_DOUBLE;
                binds[i].buffer = @ptrCast(&float_bufs[i]);
                binds[i].is_null = &null_flags[i];
            },
            .string => |s| {
                null_flags[i] = 0;
                lengths[i] = @intCast(s.len);
                binds[i].buffer_type = libmysql_c.MYSQL_TYPE_STRING;
                binds[i].buffer = @ptrCast(@constCast(s.ptr));
                binds[i].buffer_length = @intCast(s.len);
                binds[i].length = &lengths[i];
                binds[i].is_null = &null_flags[i];
            },
            .bool => |v| {
                null_flags[i] = 0;
                bool_bufs[i] = if (v) 1 else 0;
                binds[i].buffer_type = libmysql_c.MYSQL_TYPE_TINY;
                binds[i].buffer = @ptrCast(&bool_bufs[i]);
                binds[i].is_null = &null_flags[i];
                binds[i].is_unsigned = 1;
            },
        }
    }
    if (libmysql_c.mysql_stmt_bind_param(stmt, binds.ptr) != 0) {
        const err_no = libmysql_c.mysql_stmt_errno(stmt);
        const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
        std.log.err("MySQL stmt_bind_param error: errno={d} msg={s}", .{ err_no, err_msg });
        return mysqlErrnoToError(err_no);
    }
}

/// Fetch a single oversized/binary column after `mysql_stmt_fetch` returned
/// `MYSQL_DATA_TRUNCATED`. `field_type` is the original bound type (or field type)
/// so binary BLOB columns are refetched without string coercion.
/// The returned slice is allocated in `arena_alloc`.
fn mysqlFetchStringColumn(arena_alloc: std.mem.Allocator, stmt: *libmysql_c.MYSQL_STMT, col: usize, actual_len: usize, field_type: c_int) errors.ResultT([]u8) {
    const temp = arena_alloc.alloc(u8, actual_len) catch return error.DatabaseError;
    var fetch_len: c_ulong = 0;
    const buffer_type: c_int = if (field_type == 0) libmysql_c.MYSQL_TYPE_STRING else field_type;
    var fetch_bind: libmysql_c.MYSQL_BIND = .{
        .buffer_type = buffer_type,
        .buffer = @ptrCast(temp.ptr),
        .buffer_length = @intCast(actual_len),
        .length = &fetch_len,
    };
    if (libmysql_c.mysql_stmt_fetch_column(stmt, &fetch_bind, @intCast(col), 0) != 0) {
        return error.DatabaseError;
    }
    const returned_len: usize = @intCast(fetch_len);
    if (returned_len > actual_len) return error.DatabaseError;
    return temp[0..returned_len];
}

/// Return a `Value.string` for a column, refetching oversized values on truncation.
fn mysqlFetchStringValue(arena_alloc: std.mem.Allocator, stmt: *libmysql_c.MYSQL_STMT, col: usize, len: usize, rc: c_int, buf: []const u8, field_type: c_int) errors.ResultT(Value) {
    if (len > buf.len) {
        if (rc == libmysql_c.MYSQL_DATA_TRUNCATED) {
            const full = try mysqlFetchStringColumn(arena_alloc, stmt, col, len, field_type);
            return Value{ .string = full };
        }
        return error.DatabaseError;
    }
    return Value{ .string = arena_alloc.dupe(u8, buf[0..len]) catch return error.DatabaseError };
}

/// Validate a MySQL DECIMAL/NEWDECIMAL string. Returns the input unchanged on success.
fn mysqlParseDecimal(s: []const u8) errors.Error![]const u8 {
    if (s.len == 0) return error.InvalidFormat;
    var i: usize = 0;
    if (s[0] == '-' or s[0] == '+') i += 1;
    if (i >= s.len) return error.InvalidFormat;
    var has_digit = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) has_digit = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) has_digit = true;
    }
    if (!has_digit or i != s.len) return error.InvalidFormat;
    return s;
}

fn isValidFractionalSeconds(s: []const u8, prefix_len: usize) bool {
    if (s.len == prefix_len) return true;
    if (s.len < prefix_len + 2) return false;
    if (s[prefix_len] != '.') return false;
    const frac = s[prefix_len + 1 ..];
    if (frac.len == 0 or frac.len > 6) return false;
    for (frac) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

/// Validate a MySQL DATETIME/TIMESTAMP/DATE/TIME string. Returns the input unchanged on success.
fn mysqlParseDateTime(s: []const u8) errors.Error![]const u8 {
    if (s.len < 8) return error.InvalidFormat;

    // DATETIME / TIMESTAMP
    if (std.mem.indexOfScalar(u8, s, ' ') != null) {
        if (s.len < 19) return error.InvalidFormat;
        if (s[4] != '-' or s[7] != '-' or s[10] != ' ' or s[13] != ':' or s[16] != ':') return error.InvalidFormat;
        if (!isValidFractionalSeconds(s, 19)) return error.InvalidFormat;
        return s;
    }

    // DATE
    if (s.len >= 10 and s[4] == '-' and s[7] == '-') {
        if (!isValidFractionalSeconds(s, 10)) return error.InvalidFormat;
        return s;
    }

    // TIME (optional leading '-')
    const time_start: usize = if (s[0] == '-') 1 else 0;
    const prefix_len = time_start + 8;
    if (s.len < prefix_len) return error.InvalidFormat;
    if (s[time_start + 2] != ':' or s[time_start + 5] != ':') return error.InvalidFormat;
    if (!isValidFractionalSeconds(s, prefix_len)) return error.InvalidFormat;
    return s;
}

/// Validate a MySQL JSON string. Returns the input unchanged on success.
fn mysqlParseJson(s: []const u8) errors.Error![]const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidFormat;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), trimmed, .{}) catch return error.InvalidFormat;
    parsed.deinit();
    return s;
}

/// After successful `mysql_stmt_execute` for a result-producing statement, fetch rows with binary decoding.
fn mysqlStmtReadRows(stmt: *libmysql_c.MYSQL_STMT, arena: std.heap.ArenaAllocator) errors.ResultT(Rows) {
    var arena_mut = arena;
    const arena_alloc = arena_mut.allocator();

    if (libmysql_c.mysql_stmt_store_result(stmt) != 0) {
        const err_no = libmysql_c.mysql_stmt_errno(stmt);
        const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
        std.log.err("MySQL stmt_store_result error: errno={d} msg={s}", .{ err_no, err_msg });
        return mysqlErrnoToError(err_no);
    }

    const meta = libmysql_c.mysql_stmt_result_metadata(stmt) orelse {
        // No metadata → treat as empty result set (should be rare after field_count > 0).
        const empty = arena_alloc.alloc(Row, 0) catch return error.DatabaseError;
        return Rows{ .arena = arena_mut, .rows = empty };
    };
    defer libmysql_c.mysql_free_result(meta);

    const n_cols = libmysql_c.mysql_num_fields(meta);
    const fields = libmysql_c.mysql_fetch_fields(meta) orelse return error.DatabaseError;

    const shared_columns = arena_alloc.alloc([]const u8, n_cols) catch return error.DatabaseError;
    const binds = arena_alloc.alloc(libmysql_c.MYSQL_BIND, n_cols) catch return error.DatabaseError;
    @memset(binds, .{});
    const null_flags = arena_alloc.alloc(libmysql_c.my_bool, n_cols) catch return error.DatabaseError;
    const lengths = arena_alloc.alloc(c_ulong, n_cols) catch return error.DatabaseError;
    const err_flags = arena_alloc.alloc(libmysql_c.my_bool, n_cols) catch return error.DatabaseError;
    const bind_bufs = arena_alloc.alloc(MysqlBindBuffer, n_cols) catch return error.DatabaseError;
    const is_unsigned_flags = arena_alloc.alloc(libmysql_c.my_bool, n_cols) catch return error.DatabaseError;

    for (0..n_cols) |c| {
        const field = fields[c];
        const name = field.name[0..field.name_length];
        shared_columns[c] = arena_alloc.dupe(u8, name) catch return error.DatabaseError;

        const unsigned = (field.flags & libmysql_c.UNSIGNED_FLAG) != 0;
        is_unsigned_flags[c] = if (unsigned) 1 else 0;

        // Initialize bind buffer based on column type
        bind_bufs[c] = switch (field.type) {
            libmysql_c.MYSQL_TYPE_TINY => .{ .tiny = 0 },
            libmysql_c.MYSQL_TYPE_SHORT => .{ .short = 0 },
            libmysql_c.MYSQL_TYPE_LONG => .{ .long = 0 },
            libmysql_c.MYSQL_TYPE_LONGLONG => .{ .longlong = 0 },
            libmysql_c.MYSQL_TYPE_FLOAT => .{ .float = 0 },
            libmysql_c.MYSQL_TYPE_DOUBLE => .{ .double = 0 },
            else => blk: {
                var buf: [4096]u8 = undefined;
                @memset(&buf, 0);
                break :blk .{ .string = .{ .buf = buf } };
            },
        };

        // Set up bind descriptors per column type
        switch (field.type) {
            libmysql_c.MYSQL_TYPE_TINY => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_TINY;
                binds[c].buffer = @ptrCast(&bind_bufs[c].tiny);
                binds[c].buffer_length = @sizeOf(u8);
                binds[c].is_unsigned = is_unsigned_flags[c];
            },
            libmysql_c.MYSQL_TYPE_SHORT => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_SHORT;
                binds[c].buffer = @ptrCast(&bind_bufs[c].short);
                binds[c].buffer_length = @sizeOf(i16);
                binds[c].is_unsigned = is_unsigned_flags[c];
            },
            libmysql_c.MYSQL_TYPE_LONG => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_LONG;
                binds[c].buffer = @ptrCast(&bind_bufs[c].long);
                binds[c].buffer_length = @sizeOf(i32);
                binds[c].is_unsigned = is_unsigned_flags[c];
            },
            libmysql_c.MYSQL_TYPE_LONGLONG => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_LONGLONG;
                binds[c].buffer = @ptrCast(&bind_bufs[c].longlong);
                binds[c].buffer_length = @sizeOf(i64);
                binds[c].is_unsigned = is_unsigned_flags[c];
            },
            libmysql_c.MYSQL_TYPE_FLOAT => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_FLOAT;
                binds[c].buffer = @ptrCast(&bind_bufs[c].float);
                binds[c].buffer_length = @sizeOf(f32);
                binds[c].is_unsigned = 0;
            },
            libmysql_c.MYSQL_TYPE_DOUBLE => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_DOUBLE;
                binds[c].buffer = @ptrCast(&bind_bufs[c].double);
                binds[c].buffer_length = @sizeOf(f64);
                binds[c].is_unsigned = 0;
            },
            // BLOB types (249-252) and VARCHAR/VAR_STRING: bind as BLOB with length+ptr
            libmysql_c.MYSQL_TYPE_BLOB,
            libmysql_c.MYSQL_TYPE_TINY_BLOB,
            libmysql_c.MYSQL_TYPE_MEDIUM_BLOB,
            libmysql_c.MYSQL_TYPE_LONG_BLOB,
            libmysql_c.MYSQL_TYPE_VAR_STRING,
            libmysql_c.MYSQL_TYPE_VARCHAR,
            => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_BLOB;
                binds[c].buffer = @ptrCast(&bind_bufs[c].string.buf);
                binds[c].buffer_length = bind_bufs[c].string.buf.len;
                binds[c].length = &lengths[c];
                binds[c].is_unsigned = 0;
            },
            // DECIMAL, NEWDECIMAL, DATE, TIME, DATETIME, TIMESTAMP, and default: keep as STRING
            else => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_STRING;
                binds[c].buffer = @ptrCast(&bind_bufs[c].string.buf);
                binds[c].buffer_length = bind_bufs[c].string.buf.len;
                binds[c].length = &lengths[c];
                binds[c].is_unsigned = 0;
            },
        }
        binds[c].is_null = &null_flags[c];
        binds[c].@"error" = &err_flags[c];
    }

    if (libmysql_c.mysql_stmt_bind_result(stmt, binds.ptr) != 0) {
        const err_no = libmysql_c.mysql_stmt_errno(stmt);
        const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
        std.log.err("MySQL stmt_bind_result error: errno={d} msg={s}", .{ err_no, err_msg });
        return mysqlErrnoToError(err_no);
    }

    var rows_list: std.ArrayList(Row) = .empty;
    while (true) {
        const rc = libmysql_c.mysql_stmt_fetch(stmt);
        if (rc == 1) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt_fetch error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }
        if (rc == libmysql_c.MYSQL_NO_DATA) break;
        // 0 = OK, MYSQL_DATA_TRUNCATED = truncated but still usable
        if (rc != 0 and rc != libmysql_c.MYSQL_DATA_TRUNCATED) {
            return error.DatabaseError;
        }

        const values = arena_alloc.alloc(?Value, n_cols) catch return error.DatabaseError;
        for (0..n_cols) |c| {
            if (null_flags[c] != 0) {
                values[c] = null;
            } else {
                values[c] = switch (fields[c].type) {
                    libmysql_c.MYSQL_TYPE_TINY => blk: {
                        if (is_unsigned_flags[c] != 0) {
                            break :blk Value{ .int = @as(i64, bind_bufs[c].tiny) };
                        } else {
                            break :blk Value{ .int = @as(i64, @as(i8, @bitCast(bind_bufs[c].tiny))) };
                        }
                    },
                    libmysql_c.MYSQL_TYPE_SHORT => blk: {
                        if (is_unsigned_flags[c] != 0) {
                            break :blk Value{ .int = @as(i64, @as(u16, @bitCast(bind_bufs[c].short))) };
                        } else {
                            break :blk Value{ .int = @as(i64, bind_bufs[c].short) };
                        }
                    },
                    libmysql_c.MYSQL_TYPE_LONG => blk: {
                        if (is_unsigned_flags[c] != 0) {
                            break :blk Value{ .int = @as(i64, @as(u32, @bitCast(bind_bufs[c].long))) };
                        } else {
                            break :blk Value{ .int = @as(i64, bind_bufs[c].long) };
                        }
                    },
                    libmysql_c.MYSQL_TYPE_LONGLONG => blk: {
                        break :blk Value{ .int = bind_bufs[c].longlong };
                    },
                    libmysql_c.MYSQL_TYPE_FLOAT => Value{ .float = @as(f64, bind_bufs[c].float) },
                    libmysql_c.MYSQL_TYPE_DOUBLE => Value{ .float = bind_bufs[c].double },
                    // BLOB types: store as string (like bytea)
                    libmysql_c.MYSQL_TYPE_BLOB,
                    libmysql_c.MYSQL_TYPE_TINY_BLOB,
                    libmysql_c.MYSQL_TYPE_MEDIUM_BLOB,
                    libmysql_c.MYSQL_TYPE_LONG_BLOB,
                    => try mysqlFetchStringValue(arena_alloc, stmt, c, @intCast(lengths[c]), rc, bind_bufs[c].string.buf[0..], binds[c].buffer_type),
                    // DECIMAL, JSON, temporal, ENUM/SET, and explicit STRING fallback
                    libmysql_c.MYSQL_TYPE_NEWDECIMAL,
                    libmysql_c.MYSQL_TYPE_DECIMAL,
                    libmysql_c.MYSQL_TYPE_JSON,
                    libmysql_c.MYSQL_TYPE_DATETIME,
                    libmysql_c.MYSQL_TYPE_TIMESTAMP,
                    libmysql_c.MYSQL_TYPE_DATE,
                    libmysql_c.MYSQL_TYPE_TIME,
                    libmysql_c.MYSQL_TYPE_ENUM,
                    libmysql_c.MYSQL_TYPE_SET,
                    libmysql_c.MYSQL_TYPE_STRING,
                    => try mysqlFetchStringValue(arena_alloc, stmt, c, @intCast(lengths[c]), rc, bind_bufs[c].string.buf[0..], binds[c].buffer_type),
                    // Remaining string-like fallback
                    else => try mysqlFetchStringValue(arena_alloc, stmt, c, @intCast(lengths[c]), rc, bind_bufs[c].string.buf[0..], binds[c].buffer_type),
                };
            }
        }
        rows_list.append(arena_alloc, .{ .arena = undefined, .columns = shared_columns, .values = values }) catch return error.DatabaseError;
    }

    const rows_slice = arena_alloc.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
    @memcpy(rows_slice, rows_list.items);
    _ = libmysql_c.mysql_stmt_free_result(stmt);
    return Rows{ .arena = arena_mut, .rows = rows_slice };
}

pub const MySqlConn = struct {
    mysql: ?*libmysql_c.MYSQL,
    allocator: std.mem.Allocator,
    /// LRU-ish prepared-statement cache keyed by original SQL (`?` placeholders).
    stmt_cache: std.StringHashMap(CachedStmt(*libmysql_c.MYSQL_STMT)),
    stmt_counter: u64 = 0,
    magic: u32 = 0xDBDBDBDB,

    fn guard(self: *const @This()) void {
        if (self.magic != 0xDBDBDBDB) @panic("DB heap corruption detected (MySQL magic mismatch)");
    }

    fn poison(self: *@This()) void {
        self.magic = 0xDEADDEAD;
    }

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, user: []const u8, password: []const u8, db: []const u8, port: u32) !MySqlConn {
        const mysql = libmysql_c.mysql_init(null);
        if (mysql == null) return error.DatabaseError;

        // Connection timeouts (P1-5)
        _ = libmysql_c.mysql_options(mysql, libmysql_c.MYSQL_OPT_CONNECT_TIMEOUT, @ptrCast(@constCast(&@as(c_uint, 10))));
        _ = libmysql_c.mysql_options(mysql, libmysql_c.MYSQL_OPT_READ_TIMEOUT, @ptrCast(@constCast(&@as(c_uint, 30))));

        // SSL/TLS support (P0-3)
        const ssl_mode = if (std.c.getenv("MYSQL_SSL_MODE")) |v| std.mem.span(v) else "preferred";
        if (std.mem.eql(u8, ssl_mode, "disabled")) {
            // Don't set SSL
        } else if (std.mem.eql(u8, ssl_mode, "required")) {
            _ = libmysql_c.mysql_options(mysql, libmysql_c.MYSQL_OPT_SSL_MODE, @ptrCast(@constCast(&libmysql_c.SSL_MODE_REQUIRED)));
        } else {
            _ = libmysql_c.mysql_options(mysql, libmysql_c.MYSQL_OPT_SSL_MODE, @ptrCast(@constCast(&libmysql_c.SSL_MODE_PREFERRED)));
        }

        // "" has ptr=null; mysql_real_connect interprets null as "no password".
        // Use "\x00" (null terminator only) as a null-terminated empty string instead.
        const password_cstr: [*c]const u8 = if (password.len > 0) @ptrCast(password.ptr) else @ptrCast("\x00");
        // Use Unix socket for localhost connections (avoids TCP auth issues with
        // caching_sha2_password which MariaDB Connector/C doesn't support with MySQL 8).
        const use_socket = std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1");
        // Socket path from MYSQL_UNIX_PORT env var, or default (P2-9)
        const socket_path: [*c]const u8 = if (use_socket)
            if (std.c.getenv("MYSQL_UNIX_PORT")) |sp| @ptrCast(sp) else @ptrCast("/tmp/mysql.sock")
        else
            @ptrCast("\x00");
        const conn = libmysql_c.mysql_real_connect(mysql, @ptrCast(host.ptr), @ptrCast(user.ptr), password_cstr, @ptrCast(db.ptr), @intCast(port), socket_path, 0);
        if (conn == null) {
            const err_no = libmysql_c.mysql_errno(mysql);
            const err_msg = cStrSpan(libmysql_c.mysql_error(mysql));
            std.log.err("MySQL connect error: errno={d} msg={s}", .{ err_no, err_msg });
            libmysql_c.mysql_close(mysql);
            return error.DatabaseError;
        }

        // Set charset to utf8mb4 (P1-6)
        _ = libmysql_c.mysql_set_character_set(mysql, "utf8mb4");

        return .{
            .mysql = mysql,
            .allocator = allocator,
            .stmt_cache = std.StringHashMap(CachedStmt(*libmysql_c.MYSQL_STMT)).init(allocator),
        };
    }

    /// Get or prepare a cached statement. Returns reset stmt ready for binding.
    fn getCachedStmt(self: *MySqlConn, sql_str: []const u8) !*libmysql_c.MYSQL_STMT {
        self.guard();
        if (self.stmt_cache.getPtr(sql_str)) |entry| {
            self.stmt_counter += 1;
            entry.last_used = self.stmt_counter;
            _ = libmysql_c.mysql_stmt_reset(entry.value);
            _ = libmysql_c.mysql_stmt_free_result(entry.value);
            return entry.value;
        }
        // Evict LRU entry when at capacity.
        if (self.stmt_cache.count() >= MAX_CACHED_STMTS) {
            if (findLruStmtKey(*libmysql_c.MYSQL_STMT, self.stmt_cache)) |lru_key| {
                if (self.stmt_cache.fetchRemove(lru_key)) |kv| {
                    _ = libmysql_c.mysql_stmt_close(kv.value.value);
                    self.allocator.free(kv.key);
                }
            }
        }
        const stmt = libmysql_c.mysql_stmt_init(self.mysql) orelse return error.DatabaseError;
        if (libmysql_c.mysql_stmt_prepare(stmt, @ptrCast(sql_str.ptr), @intCast(sql_str.len)) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt_prepare error: errno={d} msg={s}", .{ err_no, err_msg });
            _ = libmysql_c.mysql_stmt_close(stmt);
            return mysqlErrnoToError(err_no);
        }
        const key = self.allocator.dupe(u8, sql_str) catch {
            _ = libmysql_c.mysql_stmt_close(stmt);
            return error.DatabaseError;
        };
        self.stmt_counter += 1;
        self.stmt_cache.put(key, .{ .value = stmt, .last_used = self.stmt_counter }) catch {
            self.allocator.free(key);
            _ = libmysql_c.mysql_stmt_close(stmt);
            return error.DatabaseError;
        };
        return stmt;
    }

    /// Execute via binary prepared statement. Returns `null` to signal formatQuery fallback.
    fn execViaStmt(self: *MySqlConn, sql_str: []const u8, args: []const Value) !?ExecResult {
        const stmt = self.getCachedStmt(sql_str) catch return null;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        mysqlBindParams(stmt, scratch.allocator(), args) catch return null;
        if (libmysql_c.mysql_stmt_execute(stmt) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt_execute error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }
        if (libmysql_c.mysql_stmt_field_count(stmt) > 0) {
            _ = libmysql_c.mysql_stmt_store_result(stmt);
            _ = libmysql_c.mysql_stmt_free_result(stmt);
        }
        return ExecResult{
            .rows_affected = libmysql_c.mysql_stmt_affected_rows(stmt),
            .last_insert_id = @intCast(libmysql_c.mysql_stmt_insert_id(stmt)),
        };
    }

    /// Query via binary prepared statement. Returns `null` to signal formatQuery fallback.
    fn queryViaStmt(self: *MySqlConn, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) !?Rows {
        const stmt = self.getCachedStmt(sql_str) catch return null;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        mysqlBindParams(stmt, scratch.allocator(), args) catch return null;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        if (libmysql_c.mysql_stmt_execute(stmt) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt_execute error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }
        if (libmysql_c.mysql_stmt_field_count(stmt) == 0) {
            const empty = try arena.allocator().alloc(Row, 0);
            return Rows{ .arena = arena, .rows = empty };
        }
        return try mysqlStmtReadRows(stmt, arena);
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        // Zero-arg: skip prepare overhead.
        if (args.len == 0) {
            if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(sql_str.ptr), @intCast(sql_str.len)) != 0) {
                const err_no = libmysql_c.mysql_errno(self.mysql);
                const err_msg = std.mem.span(libmysql_c.mysql_error(self.mysql));
                std.log.err("MySQL query error: errno={d} msg={s}", .{ err_no, err_msg });
                return mysqlErrnoToError(err_no);
            }
            return mysqlReadRowsAfterQuery(self.mysql, arena);
        }

        if (self.queryViaStmt(allocator, sql_str, args)) |maybe_rows| {
            if (maybe_rows) |rows| return rows;
        } else |err| return err;

        const query = formatQuery(self.allocator, sql_str, args) catch return error.DatabaseError;
        defer self.allocator.free(query);

        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) {
            const err_no = libmysql_c.mysql_errno(self.mysql);
            const err_msg = std.mem.span(libmysql_c.mysql_error(self.mysql));
            std.log.err("MySQL query error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }

        return mysqlReadRowsAfterQuery(self.mysql, arena);
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();

        if (args.len == 0) {
            if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(sql_str.ptr), @intCast(sql_str.len)) != 0) {
                const err_no = libmysql_c.mysql_errno(self.mysql);
                const err_msg = std.mem.span(libmysql_c.mysql_error(self.mysql));
                std.log.err("MySQL exec error: errno={d} msg={s}", .{ err_no, err_msg });
                return mysqlErrnoToError(err_no);
            }
        } else {
            if (self.execViaStmt(sql_str, args)) |maybe_res| {
                if (maybe_res) |res| return res;
            } else |err| return err;

            const query = formatQuery(self.allocator, sql_str, args) catch return error.DatabaseError;
            defer self.allocator.free(query);

            if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) {
                const err_no = libmysql_c.mysql_errno(self.mysql);
                const err_msg = std.mem.span(libmysql_c.mysql_error(self.mysql));
                std.log.err("MySQL exec error: errno={d} msg={s}", .{ err_no, err_msg });
                return mysqlErrnoToError(err_no);
            }
        }
        // mysql_store_result returns NULL for DDL/DML (no result set). Only free if non-null.
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);

        return ExecResult{
            .rows_affected = libmysql_c.mysql_affected_rows(self.mysql),
            .last_insert_id = @intCast(libmysql_c.mysql_insert_id(self.mysql)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        var it = self.stmt_cache.iterator();
        while (it.next()) |entry| {
            _ = libmysql_c.mysql_stmt_close(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.stmt_cache.deinit();
        if (self.mysql) |mysql| {
            libmysql_c.mysql_close(mysql);
            self.mysql = null;
        }
        self.poison();
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (self.mysql == null) return error.DatabaseError;
        return if (libmysql_c.mysql_ping(self.mysql) == 0) {} else error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (libmysql_c.mysql_real_query(self.mysql, "START TRANSACTION", 17) != 0) return error.DatabaseError;
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (libmysql_c.mysql_real_query(self.mysql, "COMMIT", 6) != 0) return error.DatabaseError;
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (libmysql_c.mysql_real_query(self.mysql, "ROLLBACK", 8) != 0) return error.DatabaseError;
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);
    }

    fn prepareFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const stmt = allocator.create(MySqlStmt) catch return error.DatabaseError;
        errdefer allocator.destroy(stmt);
        stmt.* = MySqlStmt.prepare(self.mysql, allocator, sql_str) catch return error.DatabaseError;
        return stmt.toStmt();
    }

    fn queryCursorFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value, opts: CursorOptions) errors.ResultT(Cursor) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (opts.mode == .buffered) {
            const rows = try queryFn(ptr, allocator, sql_str, args);
            return Cursor.init(rows);
        }

        const query = if (args.len == 0) sql_str else formatQuery(self.allocator, sql_str, args) catch return error.DatabaseError;
        defer if (args.len != 0) self.allocator.free(query);
        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) {
            const err_no = libmysql_c.mysql_errno(self.mysql);
            const err_msg = std.mem.span(libmysql_c.mysql_error(self.mysql));
            std.log.err("MySQL streaming query error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const res = libmysql_c.mysql_use_result(self.mysql);
        var columns: [][]u8 = &[_][]u8{};
        var eof = false;
        if (res) |r| {
            const n_cols = libmysql_c.mysql_num_fields(r);
            if (n_cols > 0) {
                columns = arena.allocator().alloc([]u8, n_cols) catch return error.DatabaseError;
                for (0..n_cols) |c| {
                    const field = libmysql_c.mysql_fetch_field(r) orelse return error.DatabaseError;
                    columns[c] = arena.allocator().dupe(u8, std.mem.span(field.name)) catch return error.DatabaseError;
                }
            }
        } else {
            if (libmysql_c.mysql_errno(self.mysql) != 0) return error.DatabaseError;
            eof = true; // DML or empty result set
        }

        return Cursor{ .state = .{ .streaming_mysql = .{
            .mysql = self.mysql,
            .res = res,
            .arena = arena,
            .columns = columns,
            .row = undefined,
            .eof = eof,
        } } };
    }

    /// Batch insert using a prepared statement executed once per row. This avoids
    /// sending the SQL text repeatedly and keeps the binary wire format.
    fn batchInsertPrepared(self: *MySqlConn, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        validateIdentifier(table) catch return error.DatabaseError;
        if (rows.len == 0) return ExecResult{};
        if (columns.len == 0) return error.DatabaseError;
        for (columns) |c| validateIdentifier(c) catch return error.DatabaseError;

        var sql = std.ArrayList(u8).empty;
        defer sql.deinit(self.allocator);
        try sql.appendSlice(self.allocator, "INSERT INTO ");
        try sql.appendSlice(self.allocator, table);
        try sql.appendSlice(self.allocator, " (");
        for (columns, 0..) |col, i| {
            if (i > 0) try sql.appendSlice(self.allocator, ",");
            try sql.appendSlice(self.allocator, col);
        }
        try sql.appendSlice(self.allocator, ") VALUES (");
        for (0..columns.len) |c| {
            if (c > 0) try sql.appendSlice(self.allocator, ",");
            try sql.appendSlice(self.allocator, "?");
        }
        try sql.appendSlice(self.allocator, ")");

        const stmt = libmysql_c.mysql_stmt_init(self.mysql) orelse return error.DatabaseError;
        errdefer _ = libmysql_c.mysql_stmt_close(stmt);
        if (libmysql_c.mysql_stmt_prepare(stmt, @ptrCast(sql.items.ptr), @intCast(sql.items.len)) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL batch prepare error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }
        defer _ = libmysql_c.mysql_stmt_close(stmt);

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var total_affected: u64 = 0;
        var last_insert_id: i64 = 0;
        for (rows) |row| {
            if (row.len != columns.len) return error.DatabaseError;
            mysqlBindParams(stmt, scratch.allocator(), row) catch return error.DatabaseError;
            if (libmysql_c.mysql_stmt_execute(stmt) != 0) {
                const err_no = libmysql_c.mysql_stmt_errno(stmt);
                const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
                std.log.err("MySQL batch execute error: errno={d} msg={s}", .{ err_no, err_msg });
                return mysqlErrnoToError(err_no);
            }
            total_affected += libmysql_c.mysql_stmt_affected_rows(stmt);
            if (last_insert_id == 0) last_insert_id = @intCast(libmysql_c.mysql_stmt_insert_id(stmt));
            _ = libmysql_c.mysql_stmt_free_result(stmt);
            _ = scratch.reset(.free_all);
        }
        return ExecResult{ .rows_affected = total_affected, .last_insert_id = if (last_insert_id == 0) null else last_insert_id };
    }

    fn batchInsertFn(ptr: *anyopaque, allocator: std.mem.Allocator, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        _ = allocator;
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        return self.batchInsertPrepared(table, columns, rows);
    }

    pub fn toConn(self: *MySqlConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
                .begin = beginFn,
                .commit = commitFn,
                .rollback = rollbackFn,
                .prepare = prepareFn,
                .queryCursor = queryCursorFn,
                .batchInsert = batchInsertFn,
            },
        };
    }
};

// ==================== Prepared Statements ====================

pub const Stmt = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    conn: ?Conn = null,

    pub const VTable = struct {
        query: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows),
        exec: *const fn (ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult),
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn query(self: Stmt, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        var rows = try self.vtable.query(self.ptr, allocator, args);
        for (rows.rows) |*row| row.arena = &rows.arena;
        return rows;
    }

    pub fn exec(self: Stmt, args: []const Value) errors.ResultT(ExecResult) {
        return self.vtable.exec(self.ptr, args);
    }

    pub fn close(self: Stmt) void {
        self.vtable.close(self.ptr);
        if (self.conn) |c| c.close();
    }
};

pub const SQLiteStmt = struct {
    db: ?*sqlite3_c.sqlite3,
    stmt: ?*sqlite3_c.sqlite3_stmt,
    allocator: std.mem.Allocator,

    pub fn prepare(db: ?*sqlite3_c.sqlite3, allocator: std.mem.Allocator, sql: []const u8) !SQLiteStmt {
        var stmt: ?*sqlite3_c.sqlite3_stmt = null;
        const rc = sqlite3_c.sqlite3_prepare_v2(db, @ptrCast(sql.ptr), @intCast(sql.len), &stmt, null);
        if (rc != sqlite3_c.SQLITE_OK or stmt == null) return error.DatabaseError;
        return .{ .db = db, .stmt = stmt, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*SQLiteStmt, @ptrCast(@alignCast(ptr)));
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        _ = sqlite3_c.sqlite3_reset(self.stmt);
        try bindSQLite(self.stmt.?, args);

        const col_count = sqlite3_c.sqlite3_column_count(self.stmt);
        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        while (sqlite3_c.sqlite3_step(self.stmt) == sqlite3_c.SQLITE_ROW) {
            const columns = arena_alloc.alloc([]const u8, @intCast(col_count)) catch return error.DatabaseError;
            const values = arena_alloc.alloc(?Value, @intCast(col_count)) catch return error.DatabaseError;
            for (0..@intCast(col_count)) |i| {
                const raw_name = sqlite3_c.sqlite3_column_name(self.stmt, @intCast(i));
                const name_len = std.mem.len(raw_name);
                const name = raw_name[0..name_len];
                columns[i] = arena_alloc.dupe(u8, name) catch return error.DatabaseError;
                values[i] = readSQLiteValue(arena_alloc, self.stmt, @intCast(i));
            }
            rows_list.append(arena_alloc, .{ .arena = undefined, .columns = columns, .values = values }) catch return error.DatabaseError;
        }

        const rows_slice = arena_alloc.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*SQLiteStmt, @ptrCast(@alignCast(ptr)));
        _ = sqlite3_c.sqlite3_reset(self.stmt);
        try bindSQLite(self.stmt.?, args);
        const step_rc = sqlite3_c.sqlite3_step(self.stmt);
        if (step_rc != sqlite3_c.SQLITE_DONE and step_rc != sqlite3_c.SQLITE_ROW) return error.DatabaseError;
        return ExecResult{
            .last_insert_id = sqlite3_c.sqlite3_last_insert_rowid(self.db),
            .rows_affected = @intCast(sqlite3_c.sqlite3_changes(self.db)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*SQLiteStmt, @ptrCast(@alignCast(ptr)));
        if (self.stmt) |s| {
            _ = sqlite3_c.sqlite3_finalize(s);
            self.stmt = null;
        }
        self.allocator.destroy(self);
    }

    pub fn toStmt(self: *SQLiteStmt) Stmt {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
            },
        };
    }
};

pub const PostgresStmt = struct {
    conn: ?*libpq_c.PGconn,
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn prepare(conn: ?*libpq_c.PGconn, allocator: std.mem.Allocator, sql: []const u8) !PostgresStmt {
        var name_buf: [32]u8 = undefined;
        const stmt_name = try bufPrintZ(&name_buf, "stmt_{x}", .{@intFromPtr(sql.ptr)});
        const name_copy = try allocZ(allocator, stmt_name);
        const sql_z = try allocZ(allocator, sql);
        defer allocator.free(sql_z);
        const res = libpq_c.PQprepare(conn, @ptrCast(name_copy.ptr), @ptrCast(sql_z.ptr), 0, null);
        if (res == null) return error.DatabaseError;
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
        return .{ .conn = conn, .name = name_copy, .allocator = allocator };
    }

    fn execParamsPrepared(self: *PostgresStmt, args: []const Value) ?*libpq_c.PGresult {
        if (self.conn == null) return null;

        // Arena holds all null-terminated string copies alive until PQexecPrepared completes
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const paramValues = aa.alloc(?[*:0]const u8, args.len) catch return null;
        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => null,
                .int => |v| allocPrintZ(aa, "{d}", .{v}) catch {
                    return null;
                },
                .float => |v| allocPrintZ(aa, "{d}", .{v}) catch {
                    return null;
                },
                .string => |v| allocZ(aa, v) catch {
                    return null;
                },
                .bool => |v| if (v) @as(?[*:0]const u8, @ptrCast("t")) else @ptrCast("f"),
            };
        }
        const res = libpq_c.PQexecPrepared(self.conn, @ptrCast(self.name.ptr), @intCast(args.len), @ptrCast(paramValues.ptr), null, null, PG_RESULT_BINARY);
        return res;
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*PostgresStmt, @ptrCast(@alignCast(ptr)));
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const res = execParamsPrepared(self, args) orelse return error.DatabaseError;
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_TUPLES_OK) return error.DatabaseError;

        const n_rows = libpq_c.PQntuples(res);
        const n_cols = libpq_c.PQnfields(res);
        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        const shared_columns = arena_alloc.alloc([]const u8, @intCast(n_cols)) catch return error.DatabaseError;
        for (0..@intCast(n_cols)) |c| {
            const name = std.mem.span(libpq_c.PQfname(res, @intCast(c)));
            shared_columns[c] = arena_alloc.dupe(u8, name) catch return error.DatabaseError;
        }

        for (0..@intCast(n_rows)) |r| {
            const values = arena_alloc.alloc(?Value, @intCast(n_cols)) catch return error.DatabaseError;
            for (0..@intCast(n_cols)) |c| {
                values[c] = pgReadCell(arena_alloc, res, @intCast(r), @intCast(c)) catch return error.DatabaseError;
            }
            rows_list.append(arena_alloc, .{ .arena = undefined, .columns = shared_columns, .values = values }) catch return error.DatabaseError;
        }
        const rows_slice = arena_alloc.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*PostgresStmt, @ptrCast(@alignCast(ptr)));
        const res = execParamsPrepared(self, args) orelse return error.DatabaseError;
        defer libpq_c.PQclear(res);
        const status = libpq_c.PQresultStatus(res);
        if (status != libpq_c.ExecStatusType.PGRES_COMMAND_OK and status != libpq_c.ExecStatusType.PGRES_TUPLES_OK) return error.DatabaseError;
        const cmd = std.mem.span(libpq_c.PQcmdTuples(res));
        const affected = std.fmt.parseInt(u64, cmd, 10) catch 0;
        return ExecResult{ .rows_affected = affected };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*PostgresStmt, @ptrCast(@alignCast(ptr)));
        const dealloc_sql = blk: {
            var buf: [128]u8 = undefined;
            const s = bufPrintZ(&buf, "DEALLOCATE {s}", .{self.name}) catch {
                self.allocator.free(self.name);
                self.allocator.destroy(self);
                return;
            };
            break :blk allocZ(self.allocator, s) catch {
                self.allocator.free(self.name);
                self.allocator.destroy(self);
                return;
            };
        };
        const res = libpq_c.PQexec(self.conn, @ptrCast(dealloc_sql.ptr));
        if (res) |r| libpq_c.PQclear(r);
        self.allocator.free(dealloc_sql);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn toStmt(self: *PostgresStmt) Stmt {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
            },
        };
    }
};

pub const MySqlStmt = struct {
    stmt: ?*libmysql_c.MYSQL_STMT,
    allocator: std.mem.Allocator,

    pub fn prepare(mysql: ?*libmysql_c.MYSQL, allocator: std.mem.Allocator, sql: []const u8) !MySqlStmt {
        const stmt = libmysql_c.mysql_stmt_init(mysql) orelse return error.DatabaseError;
        if (libmysql_c.mysql_stmt_prepare(stmt, @ptrCast(sql.ptr), @intCast(sql.len)) != 0) {
            _ = libmysql_c.mysql_stmt_close(stmt);
            return error.DatabaseError;
        }
        return .{ .stmt = stmt, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        const stmt = self.stmt orelse return error.DatabaseError;
        _ = libmysql_c.mysql_stmt_reset(stmt);
        _ = libmysql_c.mysql_stmt_free_result(stmt);

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        try mysqlBindParams(stmt, scratch.allocator(), args);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        if (libmysql_c.mysql_stmt_execute(stmt) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt query error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }
        if (libmysql_c.mysql_stmt_field_count(stmt) == 0) {
            const empty = try arena.allocator().alloc(Row, 0);
            return Rows{ .arena = arena, .rows = empty };
        }
        return mysqlStmtReadRows(stmt, arena);
    }

    fn execFn(ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        const stmt = self.stmt orelse return error.DatabaseError;
        _ = libmysql_c.mysql_stmt_reset(stmt);
        _ = libmysql_c.mysql_stmt_free_result(stmt);

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        try mysqlBindParams(stmt, scratch.allocator(), args);

        if (libmysql_c.mysql_stmt_execute(stmt) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt exec error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }
        if (libmysql_c.mysql_stmt_field_count(stmt) > 0) {
            _ = libmysql_c.mysql_stmt_store_result(stmt);
            _ = libmysql_c.mysql_stmt_free_result(stmt);
        }
        return ExecResult{
            .rows_affected = libmysql_c.mysql_stmt_affected_rows(stmt),
            .last_insert_id = @intCast(libmysql_c.mysql_stmt_insert_id(stmt)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        if (self.stmt) |s| {
            _ = libmysql_c.mysql_stmt_close(s);
            self.stmt = null;
        }
        self.allocator.destroy(self);
    }

    pub fn toStmt(self: *MySqlStmt) Stmt {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
            },
        };
    }
};

// ==================== Connection Pool ====================

const ConnPool = struct {
    pub const PooledEntry = struct {
        conn: Conn,
        created_at_ms: i64,
        idle_since_ms: ?i64 = null,
    };

    pub const Waiter = struct {
        cond: std.Io.Condition,
        ready: bool,
        conn: Conn,
    };

    pub const PoolMetrics = struct {
        total_acquired: u64,
        total_released: u64,
        total_evicted_lifetime: u64,
        total_evicted_idle: u64,
        current_active: u32,
        current_idle: u32,
        current_waiters: u32,
    };

    allocator: std.mem.Allocator,
    client: *Client,
    max_open: u32,
    max_idle: u32,
    max_wait_ms: u32,
    max_lifetime_ms: u64,
    max_idle_time_ms: u64,
    max_reconnect_attempts: u32 = 3,
    reconnect_delay_ms: u32 = 100,
    active: std.atomic.Value(u32),
    idle: std.ArrayList(PooledEntry),
    waiters: std.ArrayList(*Waiter),
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    closed: std.atomic.Value(bool),
    io: std.Io,
    acquire_count: std.atomic.Value(u64),
    release_count: std.atomic.Value(u64),
    evict_lifetime_count: std.atomic.Value(u64),
    evict_idle_count: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, client: *Client, max_open: u32, max_idle: u32, io: std.Io) ConnPool {
        return .{
            .allocator = allocator,
            .client = client,
            .max_open = max_open,
            .max_idle = max_idle,
            .max_wait_ms = client.config.max_wait_ms,
            .max_lifetime_ms = @as(u64, client.config.max_lifetime_secs) * 1000,
            .max_idle_time_ms = @as(u64, client.config.max_idle_time_secs) * 1000,
            .active = std.atomic.Value(u32).init(0),
            .idle = std.ArrayList(PooledEntry).empty,
            .waiters = std.ArrayList(*Waiter).empty,
            .mutex = std.Io.Mutex.init,
            .cond = .init,
            .closed = std.atomic.Value(bool).init(false),
            .io = io,
            .acquire_count = std.atomic.Value(u64).init(0),
            .release_count = std.atomic.Value(u64).init(0),
            .evict_lifetime_count = std.atomic.Value(u64).init(0),
            .evict_idle_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *ConnPool) void {
        self.closed.store(true, .monotonic);
        // Wake any waiters waiting on a per-waiter condition.
        self.mutex.lockUncancelable(self.io);
        for (self.waiters.items) |waiter| {
            waiter.ready = false;
            waiter.cond.signal(self.io);
        }
        self.mutex.unlock(self.io);
        self.cond.broadcast(self.io);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.idle.items) |*entry| {
            entry.conn.close();
        }
        self.idle.deinit(self.allocator);
        self.waiters.deinit(self.allocator);
    }

    /// Reconnect and add a new idle connection to the pool
    fn reconnect(self: *ConnPool) !void {
        var conn = self.client.newConn() catch return;
        const now = Time.monotonicNowMilliseconds();
        conn.created_at_ms = now;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.idle.append(self.allocator, .{
            .conn = conn,
            .created_at_ms = now,
            .idle_since_ms = now,
        }) catch {
            conn.close();
        };
    }

    pub fn acquire(self: *ConnPool) !Conn {
        if (self.closed.load(.monotonic)) return error.ConnectionFailed;

        self.mutex.lockUncancelable(self.io);
        while (true) {
            if (self.closed.load(.monotonic)) {
                self.mutex.unlock(self.io);
                return error.ConnectionFailed;
            }

            // Prefer idle connections — always ping before checkout.
            while (self.idle.items.len > 0) {
                const entry = self.idle.pop().?;
                const conn = entry.conn;
                const created_at = entry.created_at_ms;
                self.mutex.unlock(self.io);
                conn.ping() catch {
                    conn.close();
                    _ = self.active.fetchSub(1, .monotonic);
                    self.mutex.lockUncancelable(self.io);
                    continue;
                };
                const now = Time.monotonicNowMilliseconds();
                if (self.max_lifetime_ms > 0 and now - created_at >= self.max_lifetime_ms) {
                    conn.close();
                    _ = self.active.fetchSub(1, .monotonic);
                    _ = self.evict_lifetime_count.fetchAdd(1, .monotonic);
                    self.mutex.lockUncancelable(self.io);
                    continue;
                }
                _ = self.acquire_count.fetchAdd(1, .monotonic);
                return conn;
            }

            // Create new connection if under limit.
            const current_active = self.active.load(.monotonic);
            if (current_active < self.max_open) {
                _ = self.active.fetchAdd(1, .monotonic);
                self.mutex.unlock(self.io);
                var conn = self.client.newConn() catch {
                    _ = self.active.fetchSub(1, .monotonic);
                    return error.ConnectionFailed;
                };
                conn.created_at_ms = Time.monotonicNowMilliseconds();
                _ = self.acquire_count.fetchAdd(1, .monotonic);
                return conn;
            }

            // Wait until a connection is released (honour max_wait_ms).
            // Waits are sliced (50ms) so the fiber responds to cancellation
            // (io.checkCancel) and pool close between slices — a single long
            // futex wait on Threaded Io would be uninterruptible. The FIFO
            // waiter handoff in `release` still wakes the waiter immediately
            // via its condition variable.
            if (self.max_wait_ms == 0) {
                self.mutex.unlock(self.io);
                return error.Timeout;
            }
            const slice_ns: i96 = 50_000_000; // 50ms per futex slice

            var waiter: Waiter = .{
                .cond = .init,
                .ready = false,
                .conn = undefined,
            };
            self.waiters.append(self.allocator, &waiter) catch {
                self.mutex.unlock(self.io);
                return error.ConnectionFailed;
            };
            var waited_ms: u64 = 0;
            while (waited_ms < self.max_wait_ms) {
                const slice_woken = waiter.cond.waitTimeout(self.io, &self.mutex, .{
                    .duration = .{ .raw = .{ .nanoseconds = slice_ns }, .clock = .awake },
                });
                if (slice_woken) |_| {} else |err| switch (err) {
                    // A slice timeout is NOT an overall failure — keep
                    // waiting until max_wait_ms. Cancellation aborts now
                    // (waitTimeout re-acquires the mutex before returning).
                    error.Timeout => {},
                    error.Canceled => {
                        self.removeWaiter(&waiter);
                        self.mutex.unlock(self.io);
                        return error.Timeout;
                    },
                }
                // Woken with mutex held: released conn handoff, slice timeout,
                // or spurious wakeup.
                if (waiter.ready) {
                    self.removeWaiter(&waiter);
                    _ = self.acquire_count.fetchAdd(1, .monotonic);
                    return waiter.conn;
                }
                if (self.closed.load(.monotonic)) {
                    self.removeWaiter(&waiter);
                    self.mutex.unlock(self.io);
                    return error.ConnectionFailed;
                }
                waited_ms += 50;
            }
            self.removeWaiter(&waiter);
            self.mutex.unlock(self.io);
            return error.Timeout;
        }
    }

    fn removeWaiter(self: *ConnPool, waiter: *Waiter) void {
        for (self.waiters.items, 0..) |w, i| {
            if (w == waiter) {
                _ = self.waiters.orderedRemove(i);
                return;
            }
        }
    }

    pub fn release(self: *ConnPool, conn: Conn) void {
        _ = self.release_count.fetchAdd(1, .monotonic);
        if (self.closed.load(.monotonic)) {
            conn.close();
            _ = self.active.fetchSub(1, .monotonic);
            return;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // FIFO handoff to the oldest waiting acquire().
        if (self.waiters.items.len > 0) {
            const waiter = self.waiters.orderedRemove(0);
            waiter.ready = true;
            waiter.conn = conn;
            waiter.cond.signal(self.io);
            return;
        }

        // No waiters: evict if the connection exceeded its lifetime.
        const now = Time.monotonicNowMilliseconds();
        const created_at = conn.created_at_ms orelse now;
        if (self.max_lifetime_ms > 0 and now - created_at >= self.max_lifetime_ms) {
            conn.close();
            _ = self.active.fetchSub(1, .monotonic);
            _ = self.evict_lifetime_count.fetchAdd(1, .monotonic);
            return;
        }

        // Return to idle pool if not full, otherwise close.
        if (self.idle.items.len < self.max_idle) {
            self.idle.append(self.allocator, .{
                .conn = conn,
                .created_at_ms = created_at,
                .idle_since_ms = now,
            }) catch {
                conn.close();
                _ = self.active.fetchSub(1, .monotonic);
                return;
            };
            self.cond.signal(self.io);
        } else {
            conn.close();
            _ = self.active.fetchSub(1, .monotonic);
        }
    }

    /// Pre-create `count` idle connections (capped at `max_idle`).
    pub fn warmup(self: *ConnPool, count: u32) !void {
        if (self.closed.load(.monotonic)) return error.ConnectionFailed;
        const target = @min(count, self.max_idle);
        if (target == 0) return;
        var conns = std.ArrayList(Conn).empty;
        defer {
            for (conns.items) |*c| c.close();
            conns.deinit(self.allocator);
        }
        const now = Time.monotonicNowMilliseconds();
        for (0..target) |_| {
            var conn = self.client.newConn() catch return error.ConnectionFailed;
            conn.created_at_ms = now;
            conns.append(self.allocator, conn) catch {
                conn.close();
                return error.ConnectionFailed;
            };
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (conns.items) |conn| {
            self.idle.append(self.allocator, .{
                .conn = conn,
                .created_at_ms = conn.created_at_ms orelse now,
                .idle_since_ms = now,
            }) catch {
                conn.close();
                continue;
            };
            _ = self.active.fetchAdd(1, .monotonic);
        }
        conns.items.len = 0;
    }

    /// Ping all idle connections — returns false if any are dead.
    pub fn ping(self: *ConnPool) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var all_healthy = true;
        var i: usize = 0;
        while (i < self.idle.items.len) {
            self.idle.items[i].conn.ping() catch {
                // Connection is dead — close it and remove from idle pool.
                self.idle.items[i].conn.close();
                _ = self.active.fetchSub(1, .monotonic);
                _ = self.idle.swapRemove(i);
                all_healthy = false;
                continue;
            };
            i += 1;
        }
        return all_healthy;
    }

    /// Run keepAlive — ping all idle connections, then evict any that have been idle too long.
    pub fn keepAlive(self: *ConnPool) void {
        if (!self.ping()) {
            std.log.warn("[ConnPool] keepAlive: some idle connections were dead and removed", .{});
        }
        self.evictIdle();
    }

    fn evictIdle(self: *ConnPool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = Time.monotonicNowMilliseconds();
        var i: usize = 0;
        while (i < self.idle.items.len) {
            const idle_since = self.idle.items[i].idle_since_ms orelse continue;
            if (self.max_idle_time_ms > 0 and now - idle_since >= self.max_idle_time_ms) {
                self.idle.items[i].conn.close();
                _ = self.active.fetchSub(1, .monotonic);
                _ = self.idle.swapRemove(i);
                _ = self.evict_idle_count.fetchAdd(1, .monotonic);
                continue;
            }
            i += 1;
        }
    }

    /// Current metrics snapshot (values are consistent with respect to the pool mutex).
    pub fn metrics(self: *ConnPool) PoolMetrics {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .total_acquired = self.acquire_count.load(.monotonic),
            .total_released = self.release_count.load(.monotonic),
            .total_evicted_lifetime = self.evict_lifetime_count.load(.monotonic),
            .total_evicted_idle = self.evict_idle_count.load(.monotonic),
            .current_active = self.active.load(.monotonic),
            .current_idle = @intCast(self.idle.items.len),
            .current_waiters = @intCast(self.waiters.items.len),
        };
    }

    /// Execute a function within a transaction, acquiring a connection from the pool.
    /// The connection is automatically released after commit or rollback.
    pub fn transaction(self: *ConnPool, comptime func: anytype, args: anytype) !@typeInfo(@TypeOf(func)).@"fn".return_type {
        const conn = try self.acquire();
        defer self.release(conn);
        try conn.begin();
        errdefer conn.rollback() catch |e| std.log.err("[ConnPool] tx rollback failed: {}", .{e});
        const result = try @call(.auto, func, .{conn} ++ args);
        try conn.commit();
        return result;
    }
};

// ==================== Unified Client ====================

/// SQL configuration
pub const Config = struct {
    driver: Driver,
    host: []const u8 = "localhost",
    port: u16 = 3306,
    database: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    sqlite_path: []const u8 = ":memory:",
    postgres_conninfo: []const u8 = "",
    max_open_conns: u32 = 8,
    max_idle_conns: u32 = 4,
    max_wait_ms: u32 = 5000,
    max_lifetime_secs: u32 = 3600,
    max_idle_time_secs: u32 = 300,
    /// libpq socket read timeout (ms). 0 = disabled. Guards against a hung
    /// synchronous PQexec* permanently wedging a fiber/worker thread — the
    /// query fails with error.Timeout and the connection is re-established.
    query_timeout_ms: u32 = 30000,
};

/// Transaction options aligned with Go's sql.TxOptions.
pub const TxOptions = struct {
    read_only: bool = false,
    deferred: bool = false,
};

fn beginSql(driver: Driver, opts: TxOptions) []const u8 {
    if (driver == .mysql) {
        if (opts.read_only) return "START TRANSACTION READ ONLY";
        return "START TRANSACTION";
    }
    if (opts.deferred and opts.read_only) return "BEGIN DEFERRED READ ONLY";
    if (opts.deferred) return "BEGIN DEFERRED";
    if (opts.read_only) return "BEGIN READ ONLY";
    return "BEGIN";
}

/// SQL option function type aligned with go-zero's SqlOption
pub const SqlOption = *const fn (*Client) void;

/// Default acceptable error filter: NotFound is acceptable
pub fn defaultAcceptable(err: anyerror) bool {
    return err == error.NotFound;
}

/// SQL context aligned with go-zero's context.Context usage for sqlx
pub const SqlContext = struct {
    /// Absolute deadline in monotonic milliseconds (see Time.monotonicNowMilliseconds).
    deadline_ms: ?i64 = null,

    pub fn isDone(self: SqlContext) bool {
        if (self.deadline_ms) |d| {
            return Time.monotonicNowMilliseconds() > d;
        }
        return false;
    }

    pub fn withDeadline(deadline_ms: i64) SqlContext {
        return .{ .deadline_ms = deadline_ms };
    }

    pub fn withTimeout(timeout_ms: i64) SqlContext {
        return .{ .deadline_ms = Time.monotonicNowMilliseconds() + timeout_ms };
    }
};

/// Metrics callback type: called after each query/exec with timing info
pub const MetricsCallback = *const fn (duration_ns: u64, query: []const u8, ok: bool, err_msg: ?[]const u8) void;

/// Tracer interface: minimal OpenTelemetry-compatible span
pub const Tracer = struct {
    start_span: *const fn (name: []const u8) Span,
    end_span: *const fn (span: *Span) void,
};

pub const Span = struct {
    name: []const u8,
    start_ns: i128,
    end_ns: ?i128 = null,
    attributes: std.StringHashMap([]const u8),

    pub fn init(name: []const u8) Span {
        return .{
            .name = name,
            .start_ns = Time.monotonicNow(),
            .end_ns = null,
            .attributes = std.StringHashMap([]const u8).init(std.heap.page_allocator),
        };
    }

    /// Span duration in nanoseconds; null until `end()` is called.
    pub fn durationNs(self: *const Span) ?i128 {
        const e = self.end_ns orelse return null;
        return e - self.start_ns;
    }

    pub fn setAttribute(self: *Span, key: []const u8, value: []const u8) void {
        const alloc = std.heap.page_allocator;
        const k = alloc.dupe(u8, key) catch return;
        errdefer alloc.free(k);
        const v = alloc.dupe(u8, value) catch {
            alloc.free(k);
            return;
        };
        self.attributes.put(k, v) catch {
            alloc.free(k);
            alloc.free(v);
        };
    }

    pub fn deinit(self: *Span) void {
        const alloc = std.heap.page_allocator;
        var it = self.attributes.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.attributes.deinit();
    }

    pub fn end(self: *Span) void {
        if (self.end_ns == null) {
            self.end_ns = Time.monotonicNow();
        }
        self.deinit();
    }
};

/// SQLx client - unified SQL client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    conn: ?Conn = null,
    pool: ?ConnPool = null,
    /// Eagerly initialized in `init` — never lazy. Does not store `Io`; call sites
    /// pass `self.io` into allow/record* so futex waits use the live handle.
    cb: breaker.CircuitBreaker,
    acceptable: ?*const fn (anyerror) bool = null,
    /// Optional metrics callback (zero-cost when null)
    metrics_callback: ?MetricsCallback = null,
    /// Optional tracer for OpenTelemetry-compatible spans (zero-cost when null)
    tracer: ?*const Tracer = null,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: Config) Client {
        return .{
            .allocator = allocator,
            .config = cfg,
            .conn = null,
            .pool = null,
            .cb = breaker.CircuitBreaker.new(),
            .acceptable = null,
            .metrics_callback = null,
            .tracer = null,
            .io = io,
        };
    }

    /// One-step init + connect. Use instead of init() + connect().
    ///
    /// Pool creation is deferred to the first query via `ensurePool` so
    /// `ConnPool.client` is bound to the caller's stable `*Client` address.
    /// Creating the pool here then `return client` by value would leave
    /// `pool.client` dangling at the temporary's old address (SIGSEGV in
    /// `ensurePool` / `acquire` under `max_open_conns > 1`).
    /// Call `warmPool()` on the assigned client if idle warmup is needed.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, cfg: Config) !Client {
        var client = Client.init(allocator, io, cfg);
        try client.connect();
        return client;
    }

    /// Create the connection pool (if configured) and optionally warm idle
    /// connections. Must be called on the final `*Client` location (after
    /// `open`/`init` has been stored into its long-lived variable).
    pub fn warmPool(self: *Client) void {
        self.ensurePool();
        if (self.pool) |*p| {
            p.warmup(self.config.max_idle_conns) catch |err| {
                std.log.warn("[sqlx] connection warmup failed: {}", .{err});
            };
        }
    }

    pub fn withOptions(self: *Client, opts: []const SqlOption) void {
        for (opts) |opt| {
            opt(self);
        }
    }

    pub fn withMetrics(self: *Client, cb: MetricsCallback) void {
        self.metrics_callback = cb;
    }

    pub fn withTracer(self: *Client, t: *const Tracer) void {
        self.tracer = t;
    }

    fn isAcceptable(self: *Client, err: anyerror) bool {
        if (self.acceptable) |f| {
            return f(err);
        }
        return defaultAcceptable(err);
    }

    pub fn deinit(self: *Client) void {
        if (self.pool) |*p| {
            p.deinit();
            self.pool = null;
        }
        if (self.conn) |*c| c.close();
        self.* = undefined;
    }

    fn ensurePool(self: *Client) void {
        if (self.pool) |*p| {
            // Client may have been moved by value after the pool was created
            // (e.g. historical open() path). Always rebind the back-pointer.
            p.client = self;
            return;
        }
        if (self.config.max_open_conns > 1) {
            self.pool = ConnPool.init(self.allocator, self, self.config.max_open_conns, self.config.max_idle_conns, self.io);
        }
    }

    fn newConn(self: *Client) !Conn {
        if (!DriverFeatures.isEnabled(self.config.driver)) return error.DriverNotEnabled;
        switch (self.config.driver) {
            .sqlite => {
                const sqlite = try self.allocator.create(SQLiteConn);
                errdefer self.allocator.destroy(sqlite);
                sqlite.* = try SQLiteConn.open(self.allocator, self.config.sqlite_path);
                return sqlite.toConn();
            },
            .postgres => {
                const pg: *PostgresConn = try self.allocator.create(PostgresConn);
                errdefer self.allocator.destroy(pg);
                if (self.config.postgres_conninfo.len > 0) {
                    pg.* = try PostgresConn.connect(self.allocator, self.config.postgres_conninfo, self.config.query_timeout_ms);
                } else {
                    pg.* = try PostgresConn.connectParams(
                        self.allocator,
                        self.config.host,
                        self.config.port,
                        self.config.username,
                        self.config.password,
                        self.config.database,
                        self.config.query_timeout_ms,
                    );
                }
                return pg.toConn();
            },
            .mysql => {
                const mysql = try self.allocator.create(MySqlConn);
                errdefer self.allocator.destroy(mysql);
                mysql.* = try MySqlConn.connect(self.allocator, self.config.host, self.config.username, self.config.password, self.config.database, self.config.port);
                return mysql.toConn();
            },
        }
    }

    pub fn connect(self: *Client) !void {
        if (self.conn != null) return;
        self.conn = try self.newConn();
    }

    pub fn prepare(self: *Client, sql_str: []const u8) !Stmt {
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;
        const conn = try self.newConn();
        errdefer conn.close();
        var stmt = self.newStmt(conn, sql_str) catch |err| {
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return err;
        };
        stmt.conn = conn;
        self.cb.recordSuccess(self.io);
        return stmt;
    }

    pub fn prepareCtx(self: *Client, ctx: SqlContext, sql_str: []const u8) !Stmt {
        if (ctx.isDone()) return error.Timeout;
        return self.prepare(sql_str);
    }

    pub fn withAcceptable(f: *const fn (anyerror) bool) SqlOption {
        return struct {
            fn apply(client: *Client) void {
                client.acceptable = f;
            }
        }.apply;
    }

    fn newStmt(self: *Client, conn: Conn, sql_str: []const u8) !Stmt {
        return conn.prepare(self.allocator, sql_str);
    }

    fn doQuery(self: *Client, sql_str: []const u8, args: []const Value) !Rows {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.query(self.allocator, sql_str, args);
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.query(self.allocator, sql_str, args) catch {
            // Single-connection reconnect on failure
            self.conn.?.close();
            self.conn = null;
            try self.connect();
            return self.conn.?.query(self.allocator, sql_str, args);
        };
    }

    pub fn query(self: *Client, sql_str: []const u8, args: []const Value) !Rows {
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;

        const t0 = Time.monotonicNow();
        var rows = self.doQuery(sql_str, args) catch |err| {
            const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
            if (self.metrics_callback) |cb| cb(elapsed, sql_str, false, @errorName(err));
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return err;
        };
        for (rows.rows) |*row| row.arena = &rows.arena;
        const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
        if (self.metrics_callback) |cb| cb(elapsed, sql_str, true, null);
        self.cb.recordSuccess(self.io);
        return rows;
    }

    pub fn queryCtx(self: *Client, ctx: SqlContext, sql_str: []const u8, args: []const Value) !Rows {
        if (ctx.isDone()) return error.Timeout;
        return self.query(sql_str, args);
    }

    /// Query and return a buffered Cursor for row-by-row iteration. Caller must `defer cursor.deinit()`.
    pub fn queryCursor(self: *Client, sql_str: []const u8, args: []const Value) !Cursor {
        return self.queryCursorEx(sql_str, args, .{});
    }

    pub fn queryCursorCtx(self: *Client, ctx: SqlContext, sql_str: []const u8, args: []const Value) !Cursor {
        if (ctx.isDone()) return error.Timeout;
        return self.queryCursor(sql_str, args);
    }

    /// Query and return a Cursor with explicit fetch mode. `.buffered` (default)
    /// materializes all rows; `.streaming` fetches rows lazily and the row returned
    /// by `next()` is only valid until the next `next()`/`deinit()`.
    pub fn queryCursorEx(self: *Client, sql_str: []const u8, args: []const Value, opts: CursorOptions) !Cursor {
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;

        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return try conn.queryCursor(self.allocator, sql_str, args, opts);
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.queryCursor(self.allocator, sql_str, args, opts) catch |err| {
            std.log.err("queryCursorEx failed, reconnecting: {s}", .{@errorName(err)});
            self.conn.?.close();
            self.conn = null;
            try self.connect();
            return self.conn.?.queryCursor(self.allocator, sql_str, args, opts);
        };
    }

    fn doExec(self: *Client, sql_str: []const u8, args: []const Value) !ExecResult {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.exec(sql_str, args);
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.exec(sql_str, args) catch {
            // Single-connection reconnect on failure
            self.conn.?.close();
            self.conn = null;
            try self.connect();
            return self.conn.?.exec(sql_str, args);
        };
    }

    pub fn exec(self: *Client, sql_str: []const u8, args: []const Value) !ExecResult {
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;

        const t0 = Time.monotonicNow();
        const result = self.doExec(sql_str, args) catch |err| {
            const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
            if (self.metrics_callback) |cb| cb(elapsed, sql_str, false, @errorName(err));
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return err;
        };
        const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
        if (self.metrics_callback) |cb| cb(elapsed, sql_str, true, null);
        self.cb.recordSuccess(self.io);
        return result;
    }

    pub fn execCtx(self: *Client, ctx: SqlContext, sql_str: []const u8, args: []const Value) !ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.exec(sql_str, args);
    }

    /// Execute the same statement multiple times with different argument sets.
    /// Caller owns the returned slice and must free it with `allocator.free(results)`.
    pub fn batchExec(self: *Client, sql_str: []const u8, rows: []const []const Value) ![]ExecResult {
        const results = try self.allocator.alloc(ExecResult, rows.len);
        errdefer self.allocator.free(results);
        for (rows, 0..) |args, i| {
            results[i] = try self.exec(sql_str, args);
        }
        return results;
    }

    pub fn batchExecCtx(self: *Client, ctx: SqlContext, sql_str: []const u8, rows: []const []const Value) ![]ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.batchExec(sql_str, rows);
    }

    /// Build and execute a single multi-row INSERT for the given table/columns.
    /// All drivers share the `?` placeholder; the caller must ensure `rows[i].len == columns.len`.
    pub fn batchInsert(self: *Client, table: []const u8, columns: []const []const u8, rows: []const []const Value) !ExecResult {
        try validateIdentifier(table);
        if (rows.len == 0) return ExecResult{};
        if (columns.len == 0) return error.DatabaseError;
        for (columns) |c| try validateIdentifier(c);

        // Flatten parameters: [row0col0, row0col1, ..., rowNcolM].
        const total_args = rows.len * columns.len;
        const flat_args = try self.allocator.alloc(Value, total_args);
        defer self.allocator.free(flat_args);
        var pos: usize = 0;
        for (rows) |row| {
            if (row.len != columns.len) return error.DatabaseError;
            @memcpy(flat_args[pos .. pos + row.len], row);
            pos += row.len;
        }

        // Build "INSERT INTO t (c1,c2) VALUES (?,?),(?,?),...".
        var sql = std.ArrayList(u8).empty;
        defer sql.deinit(self.allocator);
        try sql.appendSlice(self.allocator, "INSERT INTO ");
        try sql.appendSlice(self.allocator, table);
        try sql.appendSlice(self.allocator, " (");
        for (columns, 0..) |col, i| {
            if (i > 0) try sql.appendSlice(self.allocator, ",");
            try sql.appendSlice(self.allocator, col);
        }
        try sql.appendSlice(self.allocator, ") VALUES ");
        for (0..rows.len) |r| {
            if (r > 0) try sql.appendSlice(self.allocator, ",");
            try sql.append(self.allocator, '(');
            for (0..columns.len) |c| {
                if (c > 0) try sql.appendSlice(self.allocator, ",");
                try sql.appendSlice(self.allocator, "?");
            }
            try sql.append(self.allocator, ')');
        }
        return self.exec(sql.items, flat_args);
    }

    pub fn batchInsertCtx(self: *Client, ctx: SqlContext, table: []const u8, columns: []const []const u8, rows: []const []const Value) !ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.batchInsert(table, columns, rows);
    }

    /// Batch insert with explicit strategy. `.sql` (default) builds a single
    /// multi-row INSERT; `.protocol` uses MySQL prepared-statement multi-execute
    /// or PostgreSQL `COPY FROM STDIN`. SQLite always falls back to SQL mode.
    pub fn batchInsertEx(self: *Client, table: []const u8, columns: []const []const u8, rows: []const []const Value, opts: BatchInsertOptions) !ExecResult {
        // SQLite has no protocol-level batch insert; use the optimized SQL path.
        // MySQL/PostgreSQL will attempt native batching and fall back on failure.
        if (opts.mode == .sql or rows.len == 0 or self.config.driver == .sqlite) return self.batchInsert(table, columns, rows);
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;
        self.ensurePool();

        const t0 = Time.monotonicNow();
        const result = self.doBatchInsert(table, columns, rows) catch |err| {
            const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
            if (self.metrics_callback) |cb| cb(elapsed, table, false, @errorName(err));
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return err;
        };
        const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
        if (self.metrics_callback) |cb| cb(elapsed, table, true, null);
        self.cb.recordSuccess(self.io);
        return result;
    }

    fn doBatchInsert(self: *Client, table: []const u8, columns: []const []const u8, rows: []const []const Value) !ExecResult {
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.batchInsert(self.allocator, table, columns, rows) catch |err| {
                std.log.warn("[sqlx] protocol batch insert failed, falling back to SQL mode: {s}", .{@errorName(err)});
                return self.batchInsert(table, columns, rows);
            };
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.batchInsert(self.allocator, table, columns, rows) catch |err| {
            std.log.warn("[sqlx] protocol batch insert failed, falling back to SQL mode: {s}", .{@errorName(err)});
            return self.batchInsert(table, columns, rows);
        };
    }

    fn doPing(self: *Client) !void {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.ping();
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.ping();
    }

    pub fn ping(self: *Client) !void {
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;
        self.doPing() catch |err| {
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return err;
        };
        self.cb.recordSuccess(self.io);
    }

    pub fn pingCtx(self: *Client, ctx: SqlContext) !void {
        if (ctx.isDone()) return error.Timeout;
        return self.ping();
    }

    pub fn beginTx(self: *Client) errors.Error!Transaction {
        return self.beginTxOpts(.{});
    }

    pub fn beginTxOpts(self: *Client, opts: TxOptions) errors.Error!Transaction {
        if (!self.cb.allow(self.io)) return errors.Error.CircuitBreakerOpen;
        self.ensurePool();
        const sql = beginSql(self.config.driver, opts);
        if (self.pool) |*p| {
            const conn = p.acquire() catch |err| {
                if (err == error.ConnectionFailed) return errors.Error.DatabaseError;
                if (err == error.Timeout) return errors.Error.Timeout;
                if (err == error.PoolUnhealthy) return errors.Error.PoolUnhealthy;
                return errors.Error.DatabaseError;
            };
            errdefer p.release(conn);
            _ = conn.exec(sql, &.{}) catch |err| {
                if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
                return errors.Error.DatabaseError;
            };
            return Transaction{ .conn = conn, .pool = p, .allocator = self.allocator };
        }
        if (self.conn == null) {
            self.connect() catch |err| {
                if (err == error.OutOfMemory) return errors.Error.OutOfMemory;
                return errors.Error.DatabaseError;
            };
        }
        _ = self.conn.?.exec(sql, &.{}) catch |err| {
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return errors.Error.DatabaseError;
        };
        return Transaction{ .conn = self.conn.?, .allocator = self.allocator };
    }

    pub fn transact(self: *Client, comptime T: type, fn_tx: *const fn (*Transaction) errors.ResultT(T)) errors.ResultT(T) {
        var tx = try self.beginTx();
        errdefer {
            tx.rollback() catch |err| std.log.err("[sqlx] Transaction rollback failed: {}", .{err});
            if (tx.pool) |p| p.release(tx.conn);
        }
        const result = try fn_tx(&tx);
        try tx.commit();
        return result;
    }

    /// transact with a runtime context passed to the callback — the
    /// single-parameter form can't capture business values (order id,
    /// tenant, timestamps), so multi-write business methods use this.
    pub fn transactWith(self: *Client, comptime T: type, comptime Ctx: type, ctx: Ctx, fn_tx: *const fn (*Transaction, Ctx) errors.ResultT(T)) errors.ResultT(T) {
        var tx = try self.beginTx();
        errdefer {
            tx.rollback() catch |err| std.log.err("[sqlx] Transaction rollback failed: {}", .{err});
            if (tx.pool) |p| p.release(tx.conn);
        }
        const result = try fn_tx(&tx, ctx);
        try tx.commit();
        return result;
    }

    pub fn transactCtx(self: *Client, ctx: SqlContext, comptime T: type, fn_tx: *const fn (*Transaction) errors.ResultT(T)) errors.ResultT(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.transact(T, fn_tx);
    }

    /// Scan the first row into `T`. `[]const u8` / `?[]const u8` fields are
    /// **owned copies** allocated from the client's allocator — the row arena
    /// is released before returning, so strings are never borrowed from it.
    /// The caller owns the returned string fields and must free them once done
    /// (e.g. `defer freeScanned(allocator, T, row)`), otherwise they leak.
    /// Scalar fields are copied by value and need no freeing.
    pub fn queryRow(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        for (rows.rows) |*row| row.arena = &rows.arena;
        if (rows.rows.len == 0) return error.NotFound;
        const indices = try buildColumnIndices(self.allocator, T, rows.rows[0].columns);
        defer self.allocator.free(indices);
        return try scanStruct(self.allocator, T, rows.rows[0], false, indices, false);
    }

    /// Same implementation as `queryRow` — the explicit name makes the
    /// ownership contract self-evident: string fields are owned copies from
    /// the client's allocator and must be freed by the caller
    /// (`freeScanned`). For scope-local use prefer `queryRowBorrowed`, which
    /// returns an arena-backed RAII row with nothing to free.
    pub const queryRowOwned = queryRow;

    /// Arena-borrowed RAII variant of `queryRow`: returns a `BorrowedRow(T)`
    /// that owns the scan arena; `[]const u8` fields point **into** that arena
    /// (no dupe). Strings stay valid until `BorrowedRow.deinit()`, which
    /// releases everything — no `freeScanned` needed. Use when the row is
    /// consumed within a scope.
    pub fn queryRowBorrowed(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        var rows = try self.query(sql_str, args);
        errdefer rows.deinit();
        for (rows.rows) |*row| row.arena = &rows.arena;
        if (rows.rows.len == 0) return error.NotFound;
        const indices = try buildColumnIndices(self.allocator, T, rows.rows[0].columns);
        defer self.allocator.free(indices);
        const arena_alloc = rows.arena.allocator();
        const value = try scanStruct(arena_alloc, T, rows.rows[0], false, indices, true);
        const stolen = rows.arena;
        return .{ .value = value, .arena = stolen };
    }

    pub fn queryRowCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRow(T, sql_str, args);
    }

    /// Partial-scan variant of `queryRow`: columns missing from the result set
    /// are zeroed (non-optional string fields become `""`, optionals `null`)
    /// instead of failing. Same ownership contract as `queryRow` — string
    /// fields are owned copies from the client's allocator; the caller must
    /// free them (e.g. `defer freeScanned(allocator, T, row)`).
    pub fn queryRowPartial(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        for (rows.rows) |*row| row.arena = &rows.arena;
        if (rows.rows.len == 0) return error.NotFound;
        const indices = try buildColumnIndices(self.allocator, T, rows.rows[0].columns);
        defer self.allocator.free(indices);
        return try scanStruct(self.allocator, T, rows.rows[0], true, indices, false);
    }

    /// Same implementation as `queryRowPartial` — the explicit name makes the
    /// ownership contract self-evident: string fields are owned copies from
    /// the client's allocator and must be freed by the caller
    /// (`freeScanned`). For scope-local use prefer `queryRowPartialBorrowed`.
    pub const queryRowPartialOwned = queryRowPartial;

    /// Arena-borrowed RAII variant of `queryRowPartial`: returns a
    /// `BorrowedRow(T)` that owns the scan arena; `[]const u8` fields point
    /// **into** that arena (no dupe). Missing columns are zeroed as in
    /// `queryRowPartial`. Strings stay valid until `BorrowedRow.deinit()`.
    pub fn queryRowPartialBorrowed(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        var rows = try self.query(sql_str, args);
        errdefer rows.deinit();
        for (rows.rows) |*row| row.arena = &rows.arena;
        if (rows.rows.len == 0) return error.NotFound;
        const indices = try buildColumnIndices(self.allocator, T, rows.rows[0].columns);
        defer self.allocator.free(indices);
        const arena_alloc = rows.arena.allocator();
        const value = try scanStruct(arena_alloc, T, rows.rows[0], true, indices, true);
        const stolen = rows.arena;
        return .{ .value = value, .arena = stolen };
    }

    /// One-shot scalar query: scans the first row and frees the owned strings
    /// internally, returning a plain value copy — no `freeScanned` needed by
    /// the caller. Requires a **string-free** `T` (scalars / numeric structs);
    /// models with `[]const u8` fields hit a compile error (use `queryRow` /
    /// `queryRowOwned` / `queryRowBorrowed` instead). `NotFound` → `null`.
    pub fn queryScalar(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !?T {
        comptime if (typeHasStrings(T)) {
            @compileError("queryScalar requires a string-free type — use queryRow / queryRowOwned / queryRowBorrowed for models with []const u8 fields");
        };
        const row = self.queryRow(T, sql_str, args) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        return row; // freeScanned is a no-op for string-free T
    }

    pub fn queryRowPartialCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowPartial(T, sql_str, args);
    }

    pub fn queryRows(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        var rows = try self.query(sql_str, args);
        return scanRowsToOwned(T, &rows, false) catch |err| {
            rows.deinit();
            return err;
        };
    }

    pub fn queryRowsCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRows(T, sql_str, args);
    }

    pub fn queryRowsPartial(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        var rows = try self.query(sql_str, args);
        return scanRowsToOwned(T, &rows, true) catch |err| {
            rows.deinit();
            return err;
        };
    }

    pub fn queryRowsPartialCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowsPartial(T, sql_str, args);
    }

    /// Like queryRows but returns an owned QueryResult(T). Caller MUST `defer result.deinit(allocator)`.
    /// Strings borrow the result arena (no per-field second copy).
    pub fn queryRowsOwned(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        return self.queryRows(T, sql_str, args);
    }

    /// Scan all rows into an owned slice using `allocator`: strings are
    /// duplicated and the column→field index is built **once** per query
    /// (O(F+C) setup, O(F) per row) — faster than per-row `Row.scan` for
    /// large result sets while keeping column-name mapping safety.
    ///
    /// Ownership: the returned slice and each item's string fields live in
    /// `allocator`. Caller frees with `freeScanned` per item plus
    /// `allocator.free(slice)` — or transfer items into a collection and free
    /// only the slice buffer (strings then belong to the collection).
    pub fn queryRowsSlice(self: *Client, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        return scanRowsToSlice(allocator, T, &rows, false);
    }

    /// Like queryRowsPartial but returns an owned QueryResult(T). Caller MUST `defer result.deinit(allocator)`.
    pub fn queryRowsPartialOwned(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        return self.queryRowsPartial(T, sql_str, args);
    }

    pub fn findOne(self: *Client, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        try validateIdentifier(table);
        try validateSqlFragment(where_clause);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRow(T, sql, args);
    }

    pub fn findOneCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOne(T, table, where_clause, args);
    }

    pub fn findOnePartial(self: *Client, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        try validateIdentifier(table);
        try validateSqlFragment(where_clause);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRowPartial(T, sql, args);
    }

    pub fn findOnePartialCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOnePartial(T, table, where_clause, args);
    }

    pub fn findAll(self: *Client, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        try validateIdentifier(table);
        if (where_clause) |w| try validateSqlFragment(w);
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRows(T, sql, args);
    }

    /// Like findAll but returns an owned QueryResult(T). Caller MUST `defer result.deinit(allocator)`.
    pub fn findAllOwned(self: *Client, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        return self.findAll(T, table, where_clause, args);
    }

    pub fn findAllCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.findAll(T, table, where_clause, args);
    }

    pub fn findAllPartial(self: *Client, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        try validateIdentifier(table);
        if (where_clause) |w| try validateSqlFragment(w);
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRowsPartial(T, sql, args);
    }

    pub fn findAllPartialCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.findAllPartial(T, table, where_clause, args);
    }
};

/// SQL transaction
pub const Transaction = struct {
    conn: Conn,
    pool: ?*ConnPool = null,
    allocator: std.mem.Allocator,

    pub fn query(self: *Transaction, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) !Rows {
        return self.conn.query(allocator, sql_str, args);
    }

    pub fn queryCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) !Rows {
        if (ctx.isDone()) return error.Timeout;
        return self.conn.query(allocator, sql_str, args);
    }

    pub fn exec(self: *Transaction, sql_str: []const u8, args: []const Value) !ExecResult {
        return self.conn.exec(sql_str, args);
    }

    pub fn execCtx(self: *Transaction, ctx: SqlContext, sql_str: []const u8, args: []const Value) !ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.conn.exec(sql_str, args);
    }

    pub fn commit(self: *Transaction) !void {
        try self.conn.commit();
        if (self.pool) |p| {
            p.release(self.conn);
            self.pool = null;
        }
    }

    pub fn commitCtx(self: *Transaction, ctx: SqlContext) !void {
        if (ctx.isDone()) return error.Timeout;
        return self.commit();
    }

    pub fn rollback(self: *Transaction) !void {
        try self.conn.rollback();
        if (self.pool) |p| {
            p.release(self.conn);
            self.pool = null;
        }
    }

    pub fn rollbackCtx(self: *Transaction, ctx: SqlContext) !void {
        if (ctx.isDone()) return error.Timeout;
        return self.rollback();
    }

    /// Create a savepoint with the given name.
    pub fn savepoint(self: *Transaction, name: []const u8) !void {
        validateIdentifier(name) catch return error.DatabaseError;
        const sql = try std.fmt.allocPrint(self.allocator, "SAVEPOINT {s}", .{name});
        defer self.allocator.free(sql);
        _ = try self.exec(sql, &.{});
    }

    /// Rollback to a previously created savepoint.
    pub fn rollbackTo(self: *Transaction, name: []const u8) !void {
        validateIdentifier(name) catch return error.DatabaseError;
        const sql = try std.fmt.allocPrint(self.allocator, "ROLLBACK TO {s}", .{name});
        defer self.allocator.free(sql);
        _ = try self.exec(sql, &.{});
    }

    /// Release a savepoint.
    pub fn releaseSavepoint(self: *Transaction, name: []const u8) !void {
        validateIdentifier(name) catch return error.DatabaseError;
        const sql = try std.fmt.allocPrint(self.allocator, "RELEASE SAVEPOINT {s}", .{name});
        defer self.allocator.free(sql);
        _ = try self.exec(sql, &.{});
    }

    /// queryRow scans a single row into struct T (like Client.queryRow but on tx)
    pub fn queryRow(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(allocator, sql_str, args);
        defer rows.deinit();
        if (rows.rows.len == 0) return error.NotFound;
        return try rows.rows[0].scan(allocator, T);
    }

    /// Partial-scan variant of `queryRow` on a transaction: missing columns
    /// are zeroed instead of failing (like `Client.queryRowPartial`).
    pub fn queryRowPartial(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(allocator, sql_str, args);
        defer rows.deinit();
        if (rows.rows.len == 0) return error.NotFound;
        return try rows.rows[0].scanPartial(allocator, T);
    }

    /// queryRows scans all rows into an owned QueryResult(T) (like Client.queryRows but on tx).
    /// Caller MUST `defer result.deinit(allocator)`.
    pub fn queryRows(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        var rows = try self.query(allocator, sql_str, args);
        return scanRowsToOwned(T, &rows, false) catch |err| {
            rows.deinit();
            return err;
        };
    }

    pub fn prepare(self: *Transaction, allocator: std.mem.Allocator, sql_str: []const u8) !Stmt {
        return self.conn.prepare(allocator, sql_str);
    }

    pub fn prepareCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, sql_str: []const u8) !Stmt {
        if (ctx.isDone()) return error.Timeout;
        return self.prepare(allocator, sql_str);
    }
};

fn deepCopyStruct(allocator: std.mem.Allocator, comptime T: type, src: T) !T {
    var dst = src;
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |dcn2, dct2| {
        const FieldType = dct2;
        if (FieldType == []const u8) {
            @field(dst, dcn2) = try allocator.dupe(u8, @field(src, dcn2));
        } else if (@typeInfo(FieldType) == .optional and @typeInfo(FieldType).optional.child == []const u8) {
            if (@field(src, dcn2)) |s| {
                @field(dst, dcn2) = try allocator.dupe(u8, s);
            }
        }
    }
    return dst;
}

/// Simple string cache for testing CachedConn
pub const StringCache = struct {
    const Entry = struct {
        value: []const u8,
        expires_at_ms: i64,
    };

    allocator: std.mem.Allocator,
    map: std.StringHashMap(Entry),

    pub fn init(allocator: std.mem.Allocator) StringCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *StringCache) void {
        var iter = self.map.valueIterator();
        while (iter.next()) |v| self.allocator.free(v.value);
        var key_iter = self.map.keyIterator();
        while (key_iter.next()) |k| self.allocator.free(k.*);
        self.map.deinit();
        self.* = undefined;
    }

    pub fn get(self: *StringCache, key: []const u8) ?[]const u8 {
        const entry = self.map.getEntry(key) orelse return null;
        if (Time.monotonicNowMilliseconds() > entry.value_ptr.expires_at_ms) {
            self.allocator.free(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
            _ = self.map.removeByPtr(entry.key_ptr);
            return null;
        }
        return self.allocator.dupe(u8, entry.value_ptr.value) catch null;
    }

    pub fn set(self: *StringCache, key: []const u8, value: []const u8, ttl_sec: u32) !void {
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        const entry = self.map.getEntry(k);
        const expires_at_ms = if (ttl_sec == 0)
            std.math.maxInt(i64)
        else
            Time.monotonicNowMilliseconds() + @as(i64, ttl_sec) * 1000;
        if (entry) |e| {
            self.allocator.free(e.value_ptr.value);
            e.value_ptr.* = .{ .value = v, .expires_at_ms = expires_at_ms };
            self.allocator.free(k);
        } else {
            try self.map.put(k, .{ .value = v, .expires_at_ms = expires_at_ms });
        }
    }

    pub fn del(self: *StringCache, key: []const u8) void {
        if (self.map.fetchRemove(key)) |entry| {
            self.allocator.free(entry.value.value);
            self.allocator.free(entry.key);
        }
    }
};

/// Cached SQL connection aligned with go-zero's CachedConn
pub const CachedConn = struct {
    allocator: std.mem.Allocator,
    client: *Client,

    local_cache: ?*StringCache = null,
    ttl_sec: u32 = 60,

    pub fn queryRow(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !T {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            var parsed = std.json.parseFromSlice(T, self.allocator, cached, .{}) catch return error.DatabaseError;
            defer parsed.deinit();
            return try deepCopyStruct(self.allocator, T, parsed.value);
        }
        const result = try self.client.queryRow(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch |err| std.log.warn("[CachedConn] setCache failed: {}", .{err});
        return result;
    }

    pub fn queryRowNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        return self.client.queryRow(T, sql_str, args);
    }

    /// Arena-borrowed variant — deliberately bypasses the JSON cache: the
    /// returned strings point into an arena owned by `BorrowedRow`, which is
    /// incompatible with caching. See `Client.queryRowBorrowed`.
    pub fn queryRowBorrowed(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        return self.client.queryRowBorrowed(T, sql_str, args);
    }

    pub fn queryRowCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRow(T, cache_key, sql_str, args);
    }

    pub fn queryRowPartial(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !T {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            var parsed = std.json.parseFromSlice(T, self.allocator, cached, .{}) catch return error.DatabaseError;
            defer parsed.deinit();
            return try deepCopyStruct(self.allocator, T, parsed.value);
        }
        const result = try self.client.queryRowPartial(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch |err| std.log.warn("[CachedConn] setCache failed: {}", .{err});
        return result;
    }

    pub fn queryRowPartialNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        return self.client.queryRowPartial(T, sql_str, args);
    }

    pub fn queryRowPartialCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowPartial(T, cache_key, sql_str, args);
    }

    pub fn queryRows(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            var parsed = std.json.parseFromSlice([]T, self.allocator, cached, .{}) catch return error.DatabaseError;
            defer parsed.deinit();
            const items = try self.allocator.alloc(T, parsed.value.len);
            errdefer {
                for (items) |item| freeScanned(self.allocator, T, item);
                self.allocator.free(items);
            }
            for (parsed.value, 0..) |item, i| {
                items[i] = try deepCopyStruct(self.allocator, T, item);
            }
            return .{ .items = items, .arena = null };
        }
        const result = try self.client.queryRows(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result.items, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch |err| std.log.warn("[CachedConn] setCache failed: {}", .{err});
        return result;
    }

    pub fn queryRowsNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        return self.client.queryRows(T, sql_str, args);
    }

    pub fn queryRowsCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRows(T, cache_key, sql_str, args);
    }

    pub fn queryRowsPartial(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            var parsed = std.json.parseFromSlice([]T, self.allocator, cached, .{}) catch return error.DatabaseError;
            defer parsed.deinit();
            const items = try self.allocator.alloc(T, parsed.value.len);
            errdefer {
                for (items) |item| freeScanned(self.allocator, T, item);
                self.allocator.free(items);
            }
            for (parsed.value, 0..) |item, i| {
                items[i] = try deepCopyStruct(self.allocator, T, item);
            }
            return .{ .items = items, .arena = null };
        }
        const result = try self.client.queryRowsPartial(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result.items, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch |err| std.log.warn("[CachedConn] setCache failed: {}", .{err});
        return result;
    }

    pub fn queryRowsPartialNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        return self.client.queryRowsPartial(T, sql_str, args);
    }

    pub fn queryRowsPartialCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowsPartial(T, cache_key, sql_str, args);
    }

    pub fn exec(self: *CachedConn, cache_keys: []const []const u8, sql_str: []const u8, args: []const Value) !ExecResult {
        const result = try self.client.exec(sql_str, args);
        for (cache_keys) |key| {
            self.delCache(key) catch |err| std.log.warn("[CachedConn] delCache failed: {}", .{err});
        }
        return result;
    }

    pub fn execNoCache(self: *CachedConn, sql_str: []const u8, args: []const Value) !ExecResult {
        return self.client.exec(sql_str, args);
    }

    pub fn execCtx(self: *CachedConn, ctx: SqlContext, cache_keys: []const []const u8, sql_str: []const u8, args: []const Value) !ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.exec(cache_keys, sql_str, args);
    }

    pub fn execNoCacheCtx(self: *CachedConn, ctx: SqlContext, sql_str: []const u8, args: []const Value) !ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.execNoCache(sql_str, args);
    }

    pub fn findOne(self: *CachedConn, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        try validateIdentifier(table);
        try validateSqlFragment(where_clause);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRow(T, cache_key, sql, args);
    }

    pub fn findOneNoCache(self: *CachedConn, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        try validateIdentifier(table);
        try validateSqlFragment(where_clause);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRowNoCache(T, sql, args);
    }

    pub fn findOneCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOne(T, cache_key, table, where_clause, args);
    }

    pub fn findOneNoCacheCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOneNoCache(T, table, where_clause, args);
    }

    pub fn findAll(self: *CachedConn, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        try validateIdentifier(table);
        if (where_clause) |w| try validateSqlFragment(w);
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRows(T, cache_key, sql, args);
    }

    pub fn findAllNoCache(self: *CachedConn, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        try validateIdentifier(table);
        if (where_clause) |w| try validateSqlFragment(w);
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRowsNoCache(T, sql, args);
    }

    pub fn findAllCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.findAll(T, cache_key, table, where_clause, args);
    }

    pub fn findAllNoCacheCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.findAllNoCache(T, table, where_clause, args);
    }

    fn getCache(self: *CachedConn, key: []const u8) ?[]const u8 {
        if (self.local_cache) |lc| {
            return lc.get(key);
        }
        return null;
    }

    fn setCache(self: *CachedConn, key: []const u8, value: []const u8, ttl: u32) !void {
        if (self.local_cache) |lc| {
            try lc.set(key, value, ttl);
            return;
        }
    }

    fn delCache(self: *CachedConn, key: []const u8) !void {
        if (self.local_cache) |lc| {
            lc.del(key);
            return;
        }
    }
};

/// SQL builder for common operations
pub const Builder = struct {
    allocator: std.mem.Allocator,
    table: []const u8,
    select_columns: ?[][]const u8 = null,
    join_clauses: ?[][]const u8 = null,
    where_clauses: ?[][]const u8 = null,
    group_by_clause: ?[]const u8 = null,
    having_clause: ?[]const u8 = null,
    order_by_clause: ?[]const u8 = null,
    limit_val: ?usize = null,
    offset_val: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, table: []const u8) Builder {
        return .{
            .allocator = allocator,
            .table = table,
        };
    }

    pub fn deinit(self: *Builder) void {
        if (self.select_columns) |cols| self.allocator.free(cols);
        if (self.join_clauses) |joins| {
            for (joins) |clause| self.allocator.free(clause);
            self.allocator.free(joins);
        }
        if (self.where_clauses) |wheres| {
            for (wheres) |clause| self.allocator.free(clause);
            self.allocator.free(wheres);
        }
        if (self.group_by_clause) |g| self.allocator.free(g);
        if (self.having_clause) |h| self.allocator.free(h);
        if (self.order_by_clause) |o| self.allocator.free(o);
        self.* = undefined;
    }

    pub fn selectColumns(self: *Builder, columns: []const []const u8) *Builder {
        if (self.select_columns) |cols| self.allocator.free(cols);
        self.select_columns = self.allocator.dupe([]const u8, columns) catch null;
        return self;
    }

    pub fn join(self: *Builder, clause: []const u8) *Builder {
        const new_clause = self.allocator.dupe(u8, clause) catch return self;
        if (self.join_clauses) |joins| {
            const new_j = self.allocator.realloc(joins, joins.len + 1) catch {
                self.allocator.free(new_clause);
                return self;
            };
            new_j[new_j.len - 1] = new_clause;
            self.join_clauses = new_j;
        } else {
            self.join_clauses = self.allocator.alloc([]const u8, 1) catch {
                self.allocator.free(new_clause);
                return self;
            };
            self.join_clauses.?[0] = new_clause;
        }
        return self;
    }

    pub fn where(self: *Builder, clause: []const u8) *Builder {
        const new_clause = self.allocator.dupe(u8, clause) catch return self;
        if (self.where_clauses) |wheres| {
            const new_w = self.allocator.realloc(wheres, wheres.len + 1) catch {
                self.allocator.free(new_clause);
                return self;
            };
            new_w[new_w.len - 1] = new_clause;
            self.where_clauses = new_w;
        } else {
            self.where_clauses = self.allocator.alloc([]const u8, 1) catch {
                self.allocator.free(new_clause);
                return self;
            };
            self.where_clauses.?[0] = new_clause;
        }
        return self;
    }

    pub fn groupBy(self: *Builder, clause: []const u8) *Builder {
        if (self.group_by_clause) |g| self.allocator.free(g);
        self.group_by_clause = self.allocator.dupe(u8, clause) catch null;
        return self;
    }

    pub fn having(self: *Builder, clause: []const u8) *Builder {
        if (self.having_clause) |h| self.allocator.free(h);
        self.having_clause = self.allocator.dupe(u8, clause) catch null;
        return self;
    }

    pub fn orderBy(self: *Builder, clause: []const u8) *Builder {
        if (self.order_by_clause) |o| self.allocator.free(o);
        self.order_by_clause = self.allocator.dupe(u8, clause) catch null;
        return self;
    }

    pub fn limit(self: *Builder, n: usize) *Builder {
        self.limit_val = n;
        return self;
    }

    pub fn offset(self: *Builder, n: usize) *Builder {
        self.offset_val = n;
        return self;
    }

    pub fn toSql(self: *const Builder) ![]u8 {
        var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        if (self.select_columns) |cols| {
            try buf.appendSlice(self.allocator, "SELECT ");
            for (cols, 0..) |col, i| {
                if (i > 0) try buf.appendSlice(self.allocator, ", ");
                try buf.appendSlice(self.allocator, col);
            }
            try buf.print(self.allocator, " FROM {s}", .{self.table});
        } else {
            try buf.print(self.allocator, "SELECT * FROM {s}", .{self.table});
        }

        if (self.join_clauses) |joins| {
            for (joins) |clause| {
                try buf.print(self.allocator, " {s}", .{clause});
            }
        }

        if (self.where_clauses) |wheres| {
            try buf.appendSlice(self.allocator, " WHERE ");
            for (wheres, 0..) |clause, i| {
                if (i > 0) try buf.appendSlice(self.allocator, " AND ");
                try buf.appendSlice(self.allocator, clause);
            }
        }

        if (self.group_by_clause) |g| {
            try buf.print(self.allocator, " GROUP BY {s}", .{g});
        }

        if (self.having_clause) |h| {
            try buf.print(self.allocator, " HAVING {s}", .{h});
        }

        if (self.order_by_clause) |o| {
            try buf.print(self.allocator, " ORDER BY {s}", .{o});
        }

        if (self.limit_val) |n| {
            try buf.print(self.allocator, " LIMIT {d}", .{n});
        }

        if (self.offset_val) |n| {
            try buf.print(self.allocator, " OFFSET {d}", .{n});
        }

        return self.allocator.dupe(u8, buf.items);
    }

    pub fn select(self: *const Builder, columns: []const []const u8) ![]u8 {
        var b = Builder.init(self.allocator, self.table);
        b.select_columns = self.allocator.dupe([]const u8, columns) catch return error.DatabaseError;
        defer b.deinit();
        return b.toSql();
    }

    pub fn insert(self: *const Builder, columns: []const []const u8) ![]u8 {
        var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try buf.print(self.allocator, "INSERT INTO {s} (", .{self.table});
        for (columns, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.appendSlice(self.allocator, col);
        }
        try buf.appendSlice(self.allocator, ") VALUES (");
        for (0..columns.len) |i| {
            if (i > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.print(self.allocator, "?{d}", .{i + 1});
        }
        try buf.appendSlice(self.allocator, ")");

        return self.allocator.dupe(u8, buf.items);
    }

    pub fn batchInsert(self: *const Builder, columns: []const []const u8, row_count: usize) ![]u8 {
        var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try buf.print(self.allocator, "INSERT INTO {s} (", .{self.table});
        for (columns, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.appendSlice(self.allocator, col);
        }
        try buf.appendSlice(self.allocator, ") VALUES ");
        var param_idx: usize = 1;
        for (0..row_count) |r| {
            if (r > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.appendSlice(self.allocator, "(");
            for (0..columns.len) |c| {
                if (c > 0) try buf.appendSlice(self.allocator, ", ");
                try buf.print(self.allocator, "?{d}", .{param_idx});
                param_idx += 1;
            }
            try buf.appendSlice(self.allocator, ")");
        }

        return self.allocator.dupe(u8, buf.items);
    }

    pub fn update(self: *const Builder, columns: []const []const u8) ![]u8 {
        var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.print(self.allocator, "UPDATE {s} SET ", .{self.table});
        for (columns, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.print(self.allocator, "{s} = ?{d}", .{ col, i + 1 });
        }
        return self.allocator.dupe(u8, buf.items);
    }

    pub fn delete(self: *const Builder) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "DELETE FROM {s}", .{self.table});
    }

    pub fn count(self: *const Builder, where_clause: ?[]const u8) ![]u8 {
        if (where_clause) |w| {
            return std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) FROM {s} WHERE {s}", .{ self.table, w });
        }
        return std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) FROM {s}", .{self.table});
    }
};

// ==================== Tests ====================

/// Skip this test unless the DB env var matches.
/// Postgres tests (named "postgres"): skip if DB=mysql or DB=sqlite
/// MySQL tests (named "mysql"): skip if DB=postgres or DB=sqlite
/// All other tests: always run (DB env doesn't affect them)
/// In CI: postgres job sets DB=postgres, mysql job sets DB=mysql,
/// sqlite job leaves DB unset so all tests run.
fn skipUnlessDb(comptime db: []const u8) !void {
    if (comptime std.mem.eql(u8, db, "postgres")) {
        if (!DriverFeatures.postgres) return error.SkipZigTest;
    } else if (comptime std.mem.eql(u8, db, "mysql")) {
        if (!DriverFeatures.mysql) return error.SkipZigTest;
    } else if (comptime std.mem.eql(u8, db, "sqlite")) {
        if (!DriverFeatures.sqlite) return error.SkipZigTest;
    }
    const db_env = if (builtin.os.tag == .windows) "" else if (std.c.getenv("DB")) |ptr| std.mem.span(ptr) else return error.SkipZigTest;
    if (db_env.len == 0 or !std.mem.eql(u8, db_env, db)) {
        return error.SkipZigTest;
    }
}

test "DriverFeatures and DriverNotEnabled" {
    try std.testing.expect(DriverFeatures.isEnabled(.sqlite) == DriverFeatures.sqlite);
    try std.testing.expect(DriverFeatures.isEnabled(.postgres) == DriverFeatures.postgres);
    try std.testing.expect(DriverFeatures.isEnabled(.mysql) == DriverFeatures.mysql);
    if (DriverFeatures.postgres) return;
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .postgres, .host = "127.0.0.1" });
    defer client.deinit();
    try std.testing.expectError(error.DriverNotEnabled, client.connect());
}

test "cached conn queryRow and exec" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var cache = StringCache.init(allocator);
    defer cache.deinit();

    var cached = CachedConn{
        .allocator = allocator,
        .client = &client,
        .local_cache = &cache,
        .ttl_sec = 60,
    };

    // First query should hit DB and populate cache
    const user1 = try cached.queryRow(User, "user:1", "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
    defer freeScanned(allocator, User, user1);
    try std.testing.expectEqual(@as(i64, 1), user1.id);
    try std.testing.expectEqualStrings("Alice", user1.name);

    // Second query should hit cache
    const user2 = try cached.queryRow(User, "user:1", "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 999 }});
    defer freeScanned(allocator, User, user2);
    try std.testing.expectEqualStrings("Alice", user2.name);

    // Exec with cache invalidation
    _ = try cached.exec(&.{"user:1"}, "UPDATE users SET name = ?1 WHERE id = ?2", &.{ .{ .string = "Bob" }, .{ .int = 1 } });

    // After invalidation, query should hit DB again
    const user3 = try cached.queryRow(User, "user:1", "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
    defer freeScanned(allocator, User, user3);
    try std.testing.expectEqualStrings("Bob", user3.name);
}

test "sqlite context deadline" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    const User = struct { id: i64, name: []const u8 };

    // Normal context should work
    const ctx_ok = SqlContext.withTimeout(5000);
    const user_ok = try client.queryRowCtx(ctx_ok, User, "SELECT 1 AS id, 'Alice' AS name", &.{});
    defer freeScanned(allocator, User, user_ok);
    try std.testing.expectEqual(@as(i64, 1), user_ok.id);

    // Expired context should return Timeout
    const ctx_expired = SqlContext.withDeadline(0 - 1);
    const err = client.queryRowCtx(ctx_expired, User, "SELECT 1 AS id, 'Alice' AS name", &.{}) catch |e| e;
    try std.testing.expectEqual(errors.Error.Timeout, err);
}

test "sqlite acceptable error does not trip breaker" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    // queryRow on empty table should return NotFound
    const User = struct { id: i64, name: []const u8 };
    const err = client.queryRow(User, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 999 }}) catch |e| e;
    try std.testing.expectEqual(errors.Error.NotFound, err);

    // NotFound is acceptable, so breaker should still allow requests
    try client.ping();
}

test "sqlite builder count" {
    const allocator = std.testing.allocator;
    const b = Builder.init(allocator, "users");
    const count_sql = try b.count("id > ?1");
    defer allocator.free(count_sql);
    try std.testing.expectEqualStrings("SELECT COUNT(*) FROM users WHERE id > ?1", count_sql);

    const count_all = try b.count(null);
    defer allocator.free(count_all);
    try std.testing.expectEqualStrings("SELECT COUNT(*) FROM users", count_all);
}

test "client findOne and findAll" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    const user = try client.findOne(User, "users", "name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, User, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);

    const users = try client.findAll(User, "users", null, &.{});
    defer users.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), users.items.len);

    // Injection attempts through table / where_clause are rejected.
    try std.testing.expectError(error.InvalidSqlIdentifier, client.findAll(User, "users; DROP TABLE users", null, &.{}));
    try std.testing.expectError(error.UnsafeSqlFragment, client.findOne(User, "users", "name = 'Alice' OR 1=1 --", &.{}));
    try std.testing.expectError(error.UnsafeSqlFragment, client.findAll(User, "users", "1=1; DELETE FROM users", &.{}));
}

test "validateIdentifier and validateSqlFragment" {
    // Valid identifiers
    try validateIdentifier("users");
    try validateIdentifier("public.users");
    try validateIdentifier("_tmp_table1");

    // Invalid identifiers
    try std.testing.expectError(error.InvalidSqlIdentifier, validateIdentifier(""));
    try std.testing.expectError(error.InvalidSqlIdentifier, validateIdentifier("1users"));
    try std.testing.expectError(error.InvalidSqlIdentifier, validateIdentifier("users; DROP"));
    try std.testing.expectError(error.InvalidSqlIdentifier, validateIdentifier("users--"));

    // Valid fragments (parameterized)
    try validateSqlFragment("name = ?1");
    try validateSqlFragment("age > ? AND status = ?");
    try validateSqlFragment("WHERE tenant_id = ? ORDER BY id");

    // Unsafe fragments
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("name = 'Alice'"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1; DROP TABLE users"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1 -- comment"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1 /* comment */"));
}

test "cached conn findOne" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var cache = StringCache.init(allocator);
    defer cache.deinit();

    var cached = CachedConn{
        .allocator = allocator,
        .client = &client,
        .local_cache = &cache,
        .ttl_sec = 60,
    };

    const user1 = try cached.findOne(User, "user:1", "users", "name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, User, user1);

    const user2 = try cached.findOne(User, "user:1", "users", "name = ?1", &.{.{ .string = "WRONG" }});
    defer freeScanned(allocator, User, user2);
    try std.testing.expectEqualStrings("Alice", user2.name);
}

test "sqlite parameterized query treats injection payload as literal" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    const malicious = "'; DROP TABLE users; --";
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = malicious }});

    var rows = try client.query("SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = malicious }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);

    var count_rows = try client.query("SELECT COUNT(*) AS cnt FROM users", &.{});
    defer count_rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), (&count_rows.rows[0]).get("cnt").?.int);
}

test "sqlite in-memory query and exec" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();

    const create = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    try std.testing.expectEqual(@as(u64, 0), create.rows_affected);

    const insert = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(i64, 1), insert.last_insert_id.?);

    var rows = try client.query("SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqual(@as(i64, 1), (&rows.rows[0]).get("id").?.int);
    if ((&rows.rows[0]).get("name")) |name_val| {
        try std.testing.expectEqualStrings("Alice", name_val.string);
    } else return error.TestUnexpectedResult;
}

test "sqlx builder" {
    const allocator = std.testing.allocator;
    const b = Builder.init(allocator, "users");

    const select_sql = try b.select(&.{ "id", "name", "email" });
    defer allocator.free(select_sql);
    try std.testing.expectEqualStrings("SELECT id, name, email FROM users", select_sql);

    const insert_sql = try b.insert(&.{ "name", "email" });
    defer allocator.free(insert_sql);
    try std.testing.expectEqualStrings("INSERT INTO users (name, email) VALUES (?1, ?2)", insert_sql);
}

test "sqlx builder chainable" {
    const allocator = std.testing.allocator;
    var b = Builder.init(allocator, "users");
    defer b.deinit();

    const sql = try b.selectColumns(&.{ "id", "name" })
        .where("id = ?1")
        .where("name = ?2")
        .orderBy("id DESC")
        .limit(10)
        .offset(20)
        .toSql();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT id, name FROM users WHERE id = ?1 AND name = ?2 ORDER BY id DESC LIMIT 10 OFFSET 20", sql);
}

test "sqlx builder join group by having" {
    const allocator = std.testing.allocator;
    var b = Builder.init(allocator, "users");
    defer b.deinit();

    const sql = try b.selectColumns(&.{ "users.id", "users.name" })
        .join("INNER JOIN orders ON orders.user_id = users.id")
        .where("users.id = ?1")
        .groupBy("users.id")
        .having("COUNT(orders.id) > ?2")
        .orderBy("users.id DESC")
        .limit(10)
        .toSql();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings(
        "SELECT users.id, users.name FROM users INNER JOIN orders ON orders.user_id = users.id WHERE users.id = ?1 GROUP BY users.id HAVING COUNT(orders.id) > ?2 ORDER BY users.id DESC LIMIT 10",
        sql,
    );
}

test "sqlx builder batch insert" {
    const allocator = std.testing.allocator;
    const b = Builder.init(allocator, "users");

    const sql = try b.batchInsert(&.{ "name", "email" }, 3);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings("INSERT INTO users (name, email) VALUES (?1, ?2), (?3, ?4), (?5, ?6)", sql);
}

test "sqlite transaction commit" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    var tx = try client.beginTx();
    const insert = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});
    try std.testing.expectEqual(@as(u64, 1), insert.rows_affected);
    try tx.commit();

    var rows = try client.query("SELECT name FROM users WHERE name = ?1", &.{.{ .string = "Bob" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
}

test "sqlite transaction rollback" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    var tx = try client.beginTx();
    _ = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Charlie" }});
    try tx.rollback();

    var rows = try client.query("SELECT name FROM users WHERE name = ?1", &.{.{ .string = "Charlie" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), rows.rows.len);
}

test "sqlite queryRowPartial struct scan" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name, email) VALUES (?1, ?2)", &.{ .{ .string = "Alice" }, .{ .string = "alice@example.com" } });

    const PartialUser = struct {
        id: i64,
        name: []const u8,
        bio: []const u8, // missing in DB, should be zeroed
    };

    const user = try client.queryRowPartial(PartialUser, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, PartialUser, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
    try std.testing.expectEqual(@as(usize, 0), user.bio.len);
}

test "sqlite queryRowBorrowed RAII arena borrow" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    // Borrowed variant: strings point into the wrapper-owned arena, freed
    // together by deinit — no freeScanned needed.
    var row = try client.queryRowBorrowed(User, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer row.deinit();
    const user = row.get();
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
}

test "sqlite queryRowPartialBorrowed zeroes missing columns" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const PartialUser = struct {
        id: i64,
        name: []const u8,
        bio: []const u8, // missing in DB, should be zeroed
    };

    var row = try client.queryRowPartialBorrowed(PartialUser, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer row.deinit();
    const user = row.get();
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
    try std.testing.expectEqual(@as(usize, 0), user.bio.len);
}

test "sqlite queryRowOwned alias has owned-string contract" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    const user = try client.queryRowOwned(User, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, User, user); // owned → caller frees
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
}

test "typeHasStrings detects []const u8 fields" {
    const S = struct { a: i64, b: []const u8 };
    const N = struct { a: i64, b: i64 };
    const O = struct { a: ?[]const u8 };
    try std.testing.expect(typeHasStrings(S));
    try std.testing.expect(!typeHasStrings(N));
    try std.testing.expect(typeHasStrings(O));
    try std.testing.expect(!typeHasStrings(i64));
}

test "sqlite queryScalar returns value copy for string-free T" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, price INTEGER NOT NULL)", &.{});
    _ = try client.exec("INSERT INTO items (id, price) VALUES (?1, ?2)", &.{ .{ .int = 1 }, .{ .int = 100 } });

    const ItemRow = struct { id: i64, price: i64 };
    const val = try client.queryScalar(ItemRow, "SELECT id, price FROM items WHERE id = ?1", &.{.{ .int = 1 }});
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 100), val.?.price);

    // NotFound → null, no freeing needed.
    try std.testing.expect((try client.queryScalar(ItemRow, "SELECT id, price FROM items WHERE id = ?1", &.{.{ .int = 999 }})) == null);
}

test "sqlite queryRow and queryRows struct scan" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    const user = try client.queryRow(User, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, User, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);

    const users = try client.queryRows(User, "SELECT id, name FROM users ORDER BY id", &.{});
    defer users.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expectEqualStrings("Alice", users.items[0].name);
    try std.testing.expectEqualStrings("Bob", users.items[1].name);
}

test "sqlite transact helper" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    const affected = try client.transact(u64, struct {
        fn doTx(tx: *Transaction) errors.ResultT(u64) {
            const r = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "TxUser" }});
            return r.rows_affected;
        }
    }.doTx);
    try std.testing.expectEqual(@as(u64, 1), affected);

    var rows = try client.query("SELECT name FROM users WHERE name = ?1", &.{.{ .string = "TxUser" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
}

test "sqlite circuit breaker" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = "/nonexistent/path/bad.db" });
    defer client.deinit();

    var failures: u32 = 0;
    for (0..15) |_| {
        _ = client.query("SELECT 1", &.{}) catch {
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(u32, 15), failures);

    // After enough failures, circuit breaker should be open
    const err = client.query("SELECT 1", &.{}) catch |e| e;
    try std.testing.expectEqual(errors.Error.CircuitBreakerOpen, err);
}

test "sqlite connection pool" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:", .max_open_conns = 3, .max_idle_conns = 2 });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    const users = try client.queryRows(User, "SELECT id, name FROM users ORDER BY id", &.{});
    defer users.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), users.items.len);

    // Transaction through pool
    const affected = try client.transact(u64, struct {
        fn doTx(tx: *Transaction) errors.ResultT(u64) {
            const r = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Charlie" }});
            return r.rows_affected;
        }
    }.doTx);
    try std.testing.expectEqual(@as(u64, 1), affected);
}

test "sqlite prepared statement" {
    const allocator = std.testing.allocator;
    const db_path = "/tmp/zigzero_sqlx_stmt_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = db_path });
    defer {
        client.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};
    }

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    var stmt = try client.prepare("INSERT INTO users (name) VALUES (?1)");
    defer stmt.close();

    const r1 = try stmt.exec(&.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(u64, 1), r1.rows_affected);
    try std.testing.expectEqual(@as(i64, 1), r1.last_insert_id.?);

    const r2 = try stmt.exec(&.{.{ .string = "Bob" }});
    try std.testing.expectEqual(@as(u64, 1), r2.rows_affected);
    try std.testing.expectEqual(@as(i64, 2), r2.last_insert_id.?);

    var select_stmt = try client.prepare("SELECT id, name FROM users WHERE name = ?1");
    defer select_stmt.close();

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var rows = try select_stmt.query(allocator, &.{.{ .string = "Alice" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const user = try rows.rows[0].scan(allocator, User);
    defer freeScanned(allocator, User, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
}

test "sqlx value" {
    const v = Value{ .int = 42 };
    try std.testing.expectEqual(@as(i64, 42), v.int);
}

test "pgDecodeBinary scalars and uuid" {
    const allocator = std.testing.allocator;

    const b_true = try pgDecodeBinary(allocator, PgOid.bool_t, &[_]u8{1});
    try std.testing.expect(b_true.bool);

    var i2_buf: [2]u8 = undefined;
    std.mem.writeInt(i16, &i2_buf, -7, .big);
    const v_i2 = try pgDecodeBinary(allocator, PgOid.int2, &i2_buf);
    try std.testing.expectEqual(@as(i64, -7), v_i2.int);

    var i4_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &i4_buf, 123456, .big);
    const v_i4 = try pgDecodeBinary(allocator, PgOid.int4, &i4_buf);
    try std.testing.expectEqual(@as(i64, 123456), v_i4.int);

    var i8_buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &i8_buf, 9_007_199_254_740_991, .big);
    const v_i8 = try pgDecodeBinary(allocator, PgOid.int8, &i8_buf);
    try std.testing.expectEqual(@as(i64, 9_007_199_254_740_991), v_i8.int);

    var f8_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &f8_buf, @as(u64, @bitCast(@as(f64, 3.5))), .big);
    const v_f8 = try pgDecodeBinary(allocator, PgOid.float8, &f8_buf);
    try std.testing.expectEqual(@as(f64, 3.5), v_f8.float);

    const text = try pgDecodeBinary(allocator, PgOid.text, "hello");
    defer allocator.free(text.string);
    try std.testing.expectEqualStrings("hello", text.string);

    const jsonb = try pgDecodeBinary(allocator, PgOid.jsonb, &[_]u8{ 1, '{', '}' });
    defer allocator.free(jsonb.string);
    try std.testing.expectEqualStrings("{}", jsonb.string);

    const uuid_bytes = [_]u8{ 0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00 };
    const uuid = try pgDecodeBinary(allocator, PgOid.uuid, &uuid_bytes);
    defer allocator.free(uuid.string);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", uuid.string);

    // 2000-01-01 → days 0
    var date_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &date_buf, 0, .big);
    const date = try pgDecodeBinary(allocator, PgOid.date, &date_buf);
    defer allocator.free(date.string);
    try std.testing.expectEqualStrings("2000-01-01", date.string);
}

test "pgDecodeNumeric integers" {
    const allocator = std.testing.allocator;

    // 123.45: ndigits=2, weight=0, sign=0, dscale=2
    // digit[0]=123 (10000^0), digit[1]=4500 (10000^-1)
    var buf: [12]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 2, .big); // ndigits
    std.mem.writeInt(i16, buf[2..4], 0, .big); // weight
    std.mem.writeInt(u16, buf[4..6], 0, .big); // sign (positive)
    std.mem.writeInt(u16, buf[6..8], 2, .big); // dscale
    std.mem.writeInt(u16, buf[8..10], 123, .big); // digit 0
    std.mem.writeInt(u16, buf[10..12], 4500, .big); // digit 1
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("123.45", v.string);
}

test "pgDecodeNumeric negative" {
    const allocator = std.testing.allocator;
    // -789: ndigits=1, weight=0, sign=0x4000, dscale=0
    var buf: [10]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 1, .big); // ndigits
    std.mem.writeInt(i16, buf[2..4], 0, .big); // weight
    std.mem.writeInt(u16, buf[4..6], 0x4000, .big); // sign (negative)
    std.mem.writeInt(u16, buf[6..8], 0, .big); // dscale
    std.mem.writeInt(u16, buf[8..10], 789, .big); // digit
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("-789", v.string);
}

test "pgDecodeNumeric large integer" {
    const allocator = std.testing.allocator;
    // 10000: ndigits=2, weight=1, sign=0, dscale=0
    // digits: 1, 0
    var buf: [12]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 2, .big); // ndigits
    std.mem.writeInt(i16, buf[2..4], 1, .big); // weight (=1 means 8 int digits before dot)
    std.mem.writeInt(u16, buf[4..6], 0, .big); // sign
    std.mem.writeInt(u16, buf[6..8], 0, .big); // dscale
    std.mem.writeInt(u16, buf[8..10], 1, .big); // digit 0
    std.mem.writeInt(u16, buf[10..12], 0, .big); // digit 1
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("10000", v.string);
}

test "pgDecodeNumeric pure fraction" {
    const allocator = std.testing.allocator;
    // 0.005: 0.005 = 50 * 10000^-1, so ndigits=1, weight=-1, sign=0, dscale=3
    var buf: [10]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 1, .big); // ndigits
    std.mem.writeInt(i16, buf[2..4], -1, .big); // weight
    std.mem.writeInt(u16, buf[4..6], 0, .big); // sign
    std.mem.writeInt(u16, buf[6..8], 3, .big); // dscale
    std.mem.writeInt(u16, buf[8..10], 50, .big); // digit = 50 (= 0.005 * 10000^1)
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("0.005", v.string);
}

test "pgDecodeNumeric NaN" {
    const allocator = std.testing.allocator;
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 0, .big); // ndigits = 0
    std.mem.writeInt(i16, buf[2..4], 0, .big); // weight
    std.mem.writeInt(u16, buf[4..6], 0xC000, .big); // sign = NaN
    std.mem.writeInt(u16, buf[6..8], 0, .big); // dscale
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("NaN", v.string);
}

test "pgDecodeNumeric 100000 base-10000 boundary" {
    const allocator = std.testing.allocator;
    // 100000: ndigits=2, weight=1, sign=0, dscale=0, digits=[10, 0]
    var buf: [12]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 2, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 10, .big);
    std.mem.writeInt(u16, buf[10..12], 0, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("100000", v.string);
}

test "pgDecodeNumeric 800000 base-10000 boundary" {
    const allocator = std.testing.allocator;
    var buf: [12]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 2, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 80, .big);
    std.mem.writeInt(u16, buf[10..12], 0, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("800000", v.string);
}

test "pgDecodeNumeric 1000000 base-10000 boundary" {
    const allocator = std.testing.allocator;
    // 1000000: ndigits=2, weight=1, digits=[100, 0]
    var buf: [12]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 2, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 100, .big);
    std.mem.writeInt(u16, buf[10..12], 0, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("1000000", v.string);
}

test "pgDecodeNumeric 100000 stripped (PG may drop trailing zero groups)" {
    // PG stores numeric in a compressed form that strips trailing zero base-10000
    // groups. 100000 = 10 * 10000^1 can be sent as ndigits=1, weight=1, digits=[10].
    // The decoder must pad "10" with 4 zeros to reach "100000".
    const allocator = std.testing.allocator;
    var buf: [10]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 1, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 10, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("100000", v.string);
}

test "pgDecodeNumeric 800000 stripped" {
    const allocator = std.testing.allocator;
    var buf: [10]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 1, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 80, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("800000", v.string);
}

test "pgDecodeNumeric 10000 stripped single digit" {
    const allocator = std.testing.allocator;
    var buf: [10]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 1, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 1, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("10000", v.string);
}



test "pgDecodeNumeric exceeds former 256-byte stack buffer" {
    const allocator = std.testing.allocator;
    // 80 digit groups × 4 chars + sign + '.' + high dscale padding ≫ 256.
    const ndigits: i16 = 80;
    var buf: [8 + 80 * 2]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], ndigits, .big);
    std.mem.writeInt(i16, buf[2..4], ndigits - 1, .big); // weight → long integer part
    std.mem.writeInt(u16, buf[4..6], 0x4000, .big); // negative
    std.mem.writeInt(u16, buf[6..8], 40, .big); // dscale padding
    for (0..@as(usize, @intCast(ndigits))) |i| {
        std.mem.writeInt(u16, buf[8 + i * 2 ..][0..2], 1234, .big);
    }
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expect(v.string.len > 256);
    try std.testing.expect(v.string[0] == '-');
}

test "bufPrintZ reserves byte for null terminator" {
    var buf: [4]u8 = undefined;
    // Fits in 3 payload bytes + 1 sentinel.
    const ok = try bufPrintZ(&buf, "{s}", .{"ab"});
    try std.testing.expectEqualStrings("ab", ok);
    try std.testing.expectEqual(@as(u8, 0), buf[2]);
    // Would need 4 payload bytes — must fail instead of writing past buf.
    try std.testing.expectError(error.NoSpaceLeft, bufPrintZ(&buf, "{s}", .{"abcd"}));
}

test "QueryResult.deinit frees strings once (arena=null path)" {
    const allocator = std.testing.allocator;
    const Tiny = struct { name: []const u8 };
    const name = try allocator.dupe(u8, "HS8529!"); // len 7 — matches production double-free size
    const items = try allocator.alloc(Tiny, 1);
    items[0] = .{ .name = name };
    var qr = QueryResult(Tiny){ .items = items, .arena = null };
    // Correct: deinit alone. Incorrect would be freeScanned then deinit (SIGABRT).
    qr.deinit(allocator);
}

test "Client circuit breaker is eager (no lazy ensureBreaker)" {
    var client = Client.init(std.testing.allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    // Must allow immediately — cb is fully initialized in init(), not on first query.
    try std.testing.expect(client.cb.allow(client.io));
    client.cb.recordFailure(client.io);
    try std.testing.expectEqual(@as(u32, 1), client.cb.failure_count);
}

test "Client.pool offset is before cb (SqlxBackend ABI claim)" {
    // pool precedes cb in source order; changing cb optionality cannot move pool.
    try std.testing.expect(@offsetOf(Client, "pool") < @offsetOf(Client, "cb"));
    // SqlxBackend is { allocator, *Client } — not an overlay on Client bytes.
    const Backend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
    try std.testing.expect(@sizeOf(Backend) < @sizeOf(Client));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Backend, "allocator"));
    try std.testing.expect(@offsetOf(Backend, "client") > 0);
}

test "pgDecodeInterval basic" {
    const allocator = std.testing.allocator;
    // 1 month, 2 days, 3:04:05.000006
    var buf: [16]u8 = undefined;
    const total_us: i64 = (3 * 3600 + 4 * 60 + 5) * 1_000_000 + 6;
    std.mem.writeInt(i64, buf[0..8], total_us, .big); // microseconds
    std.mem.writeInt(i32, buf[8..12], 2, .big); // days
    std.mem.writeInt(i32, buf[12..16], 1, .big); // months
    const v = try pgDecodeBinary(allocator, PgOid.interval, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("P1M2DT03:04:05.000006", v.string);
}

test "pgDecodeInterval time only" {
    const allocator = std.testing.allocator;
    // 0 months, 0 days, 12:30:45.0
    var buf: [16]u8 = undefined;
    const total_us: i64 = (12 * 3600 + 30 * 60 + 45) * 1_000_000;
    std.mem.writeInt(i64, buf[0..8], total_us, .big);
    std.mem.writeInt(i32, buf[8..12], 0, .big);
    std.mem.writeInt(i32, buf[12..16], 0, .big);
    const v = try pgDecodeBinary(allocator, PgOid.interval, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("12:30:45.000000", v.string);
}

test "pgDecodeTime basic" {
    const allocator = std.testing.allocator;
    // 23:59:59.123456
    var buf: [8]u8 = undefined;
    const us: i64 = (23 * 3600 + 59 * 60 + 59) * 1_000_000 + 123456;
    std.mem.writeInt(i64, buf[0..8], us, .big);
    const v = try pgDecodeBinary(allocator, PgOid.time, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("23:59:59.123456", v.string);
}

test "pgDecodeInet basic" {
    const allocator = std.testing.allocator;
    // 192.168.1.1/24
    var buf: [8]u8 = undefined;
    buf[0] = 2; // AF_INET
    buf[1] = 24; // prefix_len
    buf[2] = 0; // is_cidr = 0
    buf[3] = 4; // nbytes
    buf[4] = 192;
    buf[5] = 168;
    buf[6] = 1;
    buf[7] = 1;
    const v = try pgDecodeBinary(allocator, PgOid.inet, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("192.168.1.1/24", v.string);
}

test "pgDecodeCidr masking" {
    const allocator = std.testing.allocator;
    // 10.0.0.42/8 as CIDR → 10.0.0.0/8
    var buf: [8]u8 = undefined;
    buf[0] = 2; // AF_INET
    buf[1] = 8; // prefix_len
    buf[2] = 1; // is_cidr = 1
    buf[3] = 4; // nbytes
    buf[4] = 10;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 42;
    const v = try pgDecodeBinary(allocator, PgOid.cidr, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("10.0.0.0/8", v.string);
}

test "postgres config init" {
    const cfg = Config{
        .driver = .postgres,
        .host = "localhost",
        .port = 5432,
        .database = "test",
        .username = "user",
        .password = "pass",
    };
    try std.testing.expectEqual(Driver.postgres, cfg.driver);
    try std.testing.expectEqual(@as(u16, 5432), cfg.port);
}

test "mysql config init" {
    const cfg = Config{
        .driver = .mysql,
        .host = "localhost",
        .port = 3306,
        .database = "test",
        .username = "user",
        .password = "pass",
    };
    try std.testing.expectEqual(Driver.mysql, cfg.driver);
    try std.testing.expectEqual(@as(u16, 3306), cfg.port);
}

test "postgres live connection" {
    try skipUnlessDb("postgres");
    const allocator = std.testing.allocator;

    // Support env overrides for CI and local dev
    const conninfo_default = "host=localhost port=5432 dbname=postgres user=cborli";
    const conninfo = if (builtin.os.tag == .windows) conninfo_default else if (std.c.getenv("PGconninfo")) |ptr| std.mem.span(ptr) else conninfo_default;

    var client = Client.init(allocator, std.testing.io, .{
        .driver = .postgres,
        .postgres_conninfo = conninfo,
    });
    defer client.deinit();

    try client.connect();
    try client.ping();

    _ = client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{}) catch {};
    _ = try client.exec("CREATE TABLE zigzero_test_users (id SERIAL PRIMARY KEY, name TEXT)", &.{});

    const insert = try client.exec("INSERT INTO zigzero_test_users (name) VALUES ($1)", &.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(u64, 1), insert.rows_affected);

    var rows = try client.query("SELECT id, name FROM zigzero_test_users WHERE name = $1", &.{.{ .string = "Alice" }});
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    if ((&rows.rows[0]).get("name")) |name_val| {
        const name_str = name_val.string;
        try std.testing.expectEqualStrings("Alice", name_str);
    } else return error.TestUnexpectedResult;

    var empty_rows = try client.query("SELECT id, name FROM zigzero_test_users WHERE name = $1", &.{.{ .string = "NobodyHere" }});
    defer empty_rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_rows.rows.len);

    _ = try client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{});
}

test "mysqlParseDecimal accepts valid MySQL decimal strings" {
    try std.testing.expectEqualStrings("1234567890123.4567", try mysqlParseDecimal("1234567890123.4567"));
    try std.testing.expectEqualStrings("-0.0001", try mysqlParseDecimal("-0.0001"));
    try std.testing.expectEqualStrings("+42.50", try mysqlParseDecimal("+42.50"));
    try std.testing.expectEqualStrings(".75", try mysqlParseDecimal(".75"));
    try std.testing.expectEqualStrings("100.", try mysqlParseDecimal("100."));
}

test "mysqlParseDecimal rejects invalid decimal strings" {
    try std.testing.expectError(error.InvalidFormat, mysqlParseDecimal(""));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDecimal("."));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDecimal("abc"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDecimal("12a.34"));
}

test "mysqlParseDateTime accepts valid MySQL temporal strings" {
    try std.testing.expectEqualStrings("2024-03-15 14:30:00", try mysqlParseDateTime("2024-03-15 14:30:00"));
    try std.testing.expectEqualStrings("2024-03-15 14:30:00.123456", try mysqlParseDateTime("2024-03-15 14:30:00.123456"));
    try std.testing.expectEqualStrings("2024-03-15", try mysqlParseDateTime("2024-03-15"));
    try std.testing.expectEqualStrings("14:30:00", try mysqlParseDateTime("14:30:00"));
    try std.testing.expectEqualStrings("-14:30:00", try mysqlParseDateTime("-14:30:00"));
    try std.testing.expectEqualStrings("14:30:00.123", try mysqlParseDateTime("14:30:00.123"));
    try std.testing.expectEqualStrings("-14:30:00.123456", try mysqlParseDateTime("-14:30:00.123456"));
}

test "mysqlParseDateTime rejects invalid temporal strings" {
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime(""));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("2024/03/15"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("14-30-00"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("-2024-03-15"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("2024-03-15 14:30:00."));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("2024-03-15 14:30:00.1234567"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("2024-03-15 14:30:00x"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("14:30:00."));
}

test "mysqlParseJson accepts valid MySQL JSON strings" {
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", try mysqlParseJson("{\"key\":\"value\"}"));
    try std.testing.expectEqualStrings("[1,2,3]", try mysqlParseJson("[1,2,3]"));
    try std.testing.expectEqualStrings("null", try mysqlParseJson("null"));
    try std.testing.expectEqualStrings("true", try mysqlParseJson("true"));
    try std.testing.expectEqualStrings("42", try mysqlParseJson("42"));
    try std.testing.expectEqualStrings("  {\"a\":1}  ", try mysqlParseJson("  {\"a\":1}  "));
    try std.testing.expectEqualStrings("\"hello\"", try mysqlParseJson("\"hello\""));
    try std.testing.expectEqualStrings("-3.14", try mysqlParseJson("-3.14"));
}

test "mysqlParseJson rejects invalid JSON strings" {
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson(""));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("not json"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("{\"a\":1"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("42e"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("1.2.3"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("++1"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("--1"));
}

test "mysql live connection" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;

    const host_default = "127.0.0.1";
    const host = if (builtin.os.tag == .windows) host_default else if (std.c.getenv("MYSQL_HOST")) |ptr| std.mem.span(ptr) else host_default;
    const user_default = "root";
    const user = if (builtin.os.tag == .windows) user_default else if (std.c.getenv("MYSQL_USER")) |ptr| std.mem.span(ptr) else user_default;
    const pass_default = "";
    const pass = if (builtin.os.tag == .windows) pass_default else if (std.c.getenv("MYSQL_PASSWORD")) |ptr| std.mem.span(ptr) else pass_default;
    const db_default = "zigzero_test";
    const db = if (builtin.os.tag == .windows) db_default else if (std.c.getenv("MYSQL_DATABASE")) |ptr| std.mem.span(ptr) else db_default;

    var client = Client.init(allocator, std.testing.io, .{
        .driver = .mysql,
        .host = host,
        .port = 3306,
        .database = db,
        .username = user,
        .password = pass,
    });
    defer client.deinit();

    try client.connect();
    try client.ping();

    _ = client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{}) catch {};
    _ = try client.exec("CREATE TABLE zigzero_test_users (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))", &.{});

    const insert = try client.exec("INSERT INTO zigzero_test_users (name) VALUES (?)", &.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(u64, 1), insert.rows_affected);

    var rows = try client.query("SELECT id, name FROM zigzero_test_users WHERE name = ?", &.{.{ .string = "Alice" }});
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    if ((&rows.rows[0]).get("name")) |name_val| {
        const name_str = name_val.string;
        try std.testing.expectEqualStrings("Alice", name_str);
        allocator.free(name_str);
    } else return error.TestUnexpectedResult;

    // Empty SELECT: libmysql may return NULL from mysql_store_result with errno==0; must not be DatabaseError.
    var empty_rows = try client.query("SELECT id, name FROM zigzero_test_users WHERE name = ?", &.{.{ .string = "NobodyHere" }});
    defer empty_rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_rows.rows.len);

    var empty_stmt = try client.prepare("SELECT id, name FROM zigzero_test_users WHERE name = ?");
    defer empty_stmt.close();
    var empty_prepared = try empty_stmt.query(allocator, &.{.{ .string = "NobodyHere" }});
    defer empty_prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_prepared.rows.len);

    // DECIMAL / DATETIME / JSON round-trip via prepared statement binary protocol.
    _ = client.exec("DROP TABLE IF EXISTS zigzero_test_types", &.{}) catch {};
    _ = try client.exec("CREATE TABLE zigzero_test_types (id INT AUTO_INCREMENT PRIMARY KEY, amount DECIMAL(19,4), created_at DATETIME, payload JSON)", &.{});

    const insert_types = try client.exec("INSERT INTO zigzero_test_types (amount, created_at, payload) VALUES (?, ?, ?)", &.{
        .{ .string = "1234567890123.4567" },
        .{ .string = "2024-03-15 14:30:00" },
        .{ .string = "{\"key\":\"value\",\"num\":42}" },
    });
    try std.testing.expectEqual(@as(u64, 1), insert_types.rows_affected);

    var type_rows = try client.query("SELECT amount, created_at, payload FROM zigzero_test_types WHERE id = ?", &.{.{ .int = insert_types.last_insert_id.? }});
    defer type_rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), type_rows.rows.len);
    const type_row = &type_rows.rows[0];

    const amount_val = type_row.get("amount") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1234567890123.4567", try mysqlParseDecimal(amount_val.string));

    const created_val = type_row.get("created_at") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2024-03-15 14:30:00", try mysqlParseDateTime(created_val.string));

    const payload_val = type_row.get("payload") orelse return error.TestUnexpectedResult;
    const payload_str = try mysqlParseJson(payload_val.string);
    try std.testing.expect(std.mem.indexOf(u8, payload_str, "\"key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_str, "\"value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_str, "\"num\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_str, "42") != null);

    _ = try client.exec("DROP TABLE IF EXISTS zigzero_test_types", &.{});
    _ = try client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{});
}

test "sqlite conn interface lifecycle" {
    const allocator = std.testing.allocator;

    // Conn.close() expects heap-allocated SQLiteConn, so allocate on heap
    const sqlite = try allocator.create(SQLiteConn);
    sqlite.* = try SQLiteConn.open(allocator, ":memory:");
    var conn = sqlite.toConn();

    // Ping should succeed
    try conn.ping();

    // Create table through Conn interface
    const create = try conn.exec("CREATE TABLE lifecycle_test (id INTEGER PRIMARY KEY)", &.{});
    try std.testing.expectEqual(@as(u64, 0), create.rows_affected);

    // Transaction commit through Conn interface
    try conn.begin();
    const insert = try conn.exec("INSERT INTO lifecycle_test (id) VALUES (1)", &.{});
    try std.testing.expectEqual(@as(i64, 1), insert.last_insert_id.?);
    try conn.commit();

    // Transaction rollback through Conn interface
    try conn.begin();
    _ = try conn.exec("INSERT INTO lifecycle_test (id) VALUES (2)", &.{});
    try conn.rollback();

    // Verify only committed row exists
    var rows = try conn.query(allocator, "SELECT id FROM lifecycle_test", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqual(@as(i64, 1), (&rows.rows[0]).get("id").?.int);

    // Close connection (this frees the heap-allocated SQLiteConn)
    conn.close();
}

test "sqlite batchExec and batchInsert helpers" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    const batch = [_][]const Value{
        &.{ .{ .int = 1 }, .{ .string = "Alice" } },
        &.{ .{ .int = 2 }, .{ .string = "Bob" } },
        &.{ .{ .int = 3 }, .{ .string = "Carol" } },
    };
    const results = try client.batchExec("INSERT INTO users (id, name) VALUES (?1, ?2)", &batch);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 3), results.len);

    const batch2 = [_][]const Value{
        &.{ .{ .int = 4 }, .{ .string = "Dave" } },
        &.{ .{ .int = 5 }, .{ .string = "Eve" } },
    };
    const insert = try client.batchInsert("users", &.{ "id", "name" }, &batch2);
    try std.testing.expectEqual(@as(u64, 2), insert.rows_affected);

    var rows = try client.queryCursor("SELECT id, name FROM users ORDER BY id", &.{});
    defer rows.deinit();
    var count: usize = 0;
    while (rows.next()) |row| {
        _ = (&row.*).get("id").?.int;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
}

test "sqlite Row.get caches repeated lookups" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE t (a INTEGER, b TEXT)", &.{});
    _ = try client.exec("INSERT INTO t (a, b) VALUES (1, 'x')", &.{});

    var rows = try client.query("SELECT a, b FROM t", &.{});
    defer rows.deinit();
    var row = rows.rows[0];
    try std.testing.expectEqual(@as(i64, 1), row.get("a").?.int);
    try std.testing.expectEqual(@as(i64, 1), row.get("a").?.int);
    try std.testing.expectEqualStrings("x", row.get("b").?.string);
}

test "sqlite deferred transaction option" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE t (id INTEGER)", &.{});
    _ = try client.exec("INSERT INTO t (id) VALUES (1)", &.{});

    var tx = try client.beginTxOpts(.{ .deferred = true });
    defer tx.rollback() catch {};
    const n = try tx.queryRow(allocator, struct { id: i64 }, "SELECT id FROM t", &.{});
    try std.testing.expectEqual(@as(i64, 1), n.id);
}

test "sqlite CachedConn respects TTL expiration" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO t (id, name) VALUES (1, 'Alice')", &.{});

    var cache = StringCache.init(allocator);
    defer cache.deinit();

    const User = struct { id: i64, name: []const u8 };
    var cached = CachedConn{ .allocator = allocator, .client = &client, .local_cache = &cache, .ttl_sec = 0 };

    const user1 = try cached.queryRow(User, "u:1", "SELECT id, name FROM t WHERE id = 1", &.{});
    defer freeScanned(allocator, User, user1);
    try std.testing.expectEqualStrings("Alice", user1.name);

    _ = try client.exec("UPDATE t SET name = 'Bob' WHERE id = 1", &.{});
    const user2 = try cached.queryRow(User, "u:1", "SELECT id, name FROM t WHERE id = 1", &.{});
    defer freeScanned(allocator, User, user2);
    try std.testing.expectEqualStrings("Alice", user2.name);
}

test "sqlite connection pool warmup" {
    const allocator = std.testing.allocator;

    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 4,
        .max_idle_conns = 2,
    });
    defer db.deinit();
    db.warmPool();

    // Warmup should have created up to max_idle idle connections.
    try std.testing.expect(db.pool != null);
    try std.testing.expect(db.pool.?.idle.items.len > 0);
    // Back-pointer must address the final Client, not a moved temporary.
    try std.testing.expectEqual(@intFromPtr(&db), @intFromPtr(db.pool.?.client));
}

test "conn pool rebinds client pointer after value move" {
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 3,
        .max_idle_conns = 1,
    });
    defer db.deinit();
    db.warmPool();
    try std.testing.expect(db.pool != null);

    // Simulate open()-by-value leave-behind: pool.client points at a dead address.
    db.pool.?.client = @ptrFromInt(0x70);
    db.ensurePool();
    try std.testing.expectEqual(@intFromPtr(&db), @intFromPtr(db.pool.?.client));
}

test "conn pool evicts idle connection after timeout" {
    const allocator = std.testing.allocator;

    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 2,
    });
    defer db.deinit();
    db.warmPool();

    try std.testing.expect(db.pool != null);
    const before = db.pool.?.metrics();
    try std.testing.expectEqual(@as(u32, 2), before.current_idle);
    try std.testing.expectEqual(@as(u64, 0), before.total_evicted_idle);

    // Use a 1 ms idle threshold and wait long enough for the warmed-up
    // connections to exceed it before invoking keepAlive().
    db.pool.?.max_idle_time_ms = 1;
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(2), .awake) catch {};

    db.pool.?.keepAlive();

    const after = db.pool.?.metrics();
    try std.testing.expectEqual(@as(u32, 0), after.current_idle);
    try std.testing.expectEqual(@as(u64, 2), after.total_evicted_idle);
}

test "conn pool thread smoke" {
    const allocator = std.testing.allocator;

    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 4,
        .max_idle_conns = 0,
        .max_wait_ms = 5000,
    });
    defer db.deinit();
    db.warmPool();

    const pool = &db.pool.?;

    const Worker = struct {
        fn run(p: *ConnPool) void {
            const c = p.acquire() catch return;
            p.release(c);
        }
    };

    var threads: [2]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{pool});
    }
    for (&threads) |*t| {
        t.join();
    }
}

test "conn pool release hands off to waiters in FIFO order" {
    const allocator = std.testing.allocator;

    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 0,
        .max_wait_ms = 5000,
    });
    defer db.deinit();
    db.warmPool();

    const pool = &db.pool.?;
    const conn_a = try pool.acquire();
    const conn_b = try pool.acquire();

    // Simulate a FIFO wait queue directly. Each release() must hand the
    // connection to the oldest waiter and set its ready flag.
    var waiters: [3]ConnPool.Waiter = undefined;
    for (&waiters) |*w| {
        w.* = .{ .cond = .init, .ready = false, .conn = undefined };
        try pool.waiters.append(allocator, w);
    }
    defer {
        // Remove the dummy waiters so pool deinit sees an empty queue.
        pool.waiters.items.len = 0;
    }

    try std.testing.expectEqual(@as(usize, 3), pool.waiters.items.len);

    pool.release(conn_a);
    try std.testing.expect(waiters[0].ready);
    try std.testing.expect(!waiters[1].ready);
    try std.testing.expect(!waiters[2].ready);

    pool.release(conn_b);
    try std.testing.expect(waiters[1].ready);
    try std.testing.expect(!waiters[2].ready);

    // Close the connections that were handed to the dummy waiters so the
    // pool's active count and the test allocator stay consistent.
    waiters[0].conn.close();
    waiters[1].conn.close();
}

test "sqlite buffered cursor iterates rows" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer db.deinit();
    try db.connect();
    _ = try db.exec("CREATE TABLE cur (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try db.exec("INSERT INTO cur (name) VALUES (?), (?), (?)", &.{ Value{ .string = "a" }, Value{ .string = "b" }, Value{ .string = "c" } });

    var cursor = try db.queryCursor("SELECT id, name FROM cur ORDER BY id", &.{});
    defer cursor.deinit();

    var count: usize = 0;
    while (cursor.next()) |row| {
        count += 1;
        const id = row.get("id").?.int;
        const name = row.get("name").?.string;
        try std.testing.expectEqual(@as(i64, @intCast(count)), id);
        try std.testing.expect(name.len == 1);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "sqlite streaming cursor falls back to buffered" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer db.deinit();
    try db.connect();
    _ = try db.exec("CREATE TABLE cur2 (id INTEGER PRIMARY KEY)", &.{});
    _ = try db.exec("INSERT INTO cur2 VALUES (1), (2)", &.{});
    var cursor = try db.queryCursorEx("SELECT id FROM cur2 ORDER BY id", &.{}, .{ .mode = .streaming });
    defer cursor.deinit();
    try std.testing.expect(cursor.next().?.get("id").?.int == 1);
    try std.testing.expect(cursor.next().?.get("id").?.int == 2);
    try std.testing.expect(cursor.next() == null);
}

test "mysql streaming cursor api compiles" {
    // Requires a live MySQL server; kept as a compile-time/API smoke test.
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{ .driver = .mysql, .host = "127.0.0.1", .user = "root", .password = "", .database = "test" });
    defer db.deinit();
    var cursor = try db.queryCursorEx("SELECT 1 AS n", &.{});
    defer cursor.deinit();
    _ = cursor.next();
}

test "postgres streaming cursor api compiles" {
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{ .driver = .postgres, .host = "127.0.0.1", .user = "postgres", .password = "", .database = "test" });
    defer db.deinit();
    var cursor = try db.queryCursorEx("SELECT 1 AS n", &.{}, .{ .mode = .streaming });
    defer cursor.deinit();
    _ = cursor.next();
}

test "sqlite batchInsertEx sql mode matches batchInsert" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer db.deinit();
    try db.connect();
    _ = try db.exec("CREATE TABLE batch (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    const res = try db.batchInsertEx("batch", &.{ "id", "name" }, &.{
        &.{ Value{ .int = 1 }, Value{ .string = "a" } },
        &.{ Value{ .int = 2 }, Value{ .string = "b" } },
    }, .{ .mode = .sql });
    try std.testing.expectEqual(@as(u64, 2), res.rows_affected);
}

test "sqlite batchInsertEx protocol mode routes to sql" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer db.deinit();
    try db.connect();
    _ = try db.exec("CREATE TABLE batch2 (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    const res = try db.batchInsertEx("batch2", &.{ "id", "name" }, &.{
        &.{ Value{ .int = 1 }, Value{ .string = "a" } },
        &.{ Value{ .int = 2 }, Value{ .string = "b" } },
    }, .{ .mode = .protocol });
    try std.testing.expectEqual(@as(u64, 2), res.rows_affected);
}

test "mysql batchInsertEx protocol mode api compiles" {
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{ .driver = .mysql, .host = "127.0.0.1", .user = "root", .password = "", .database = "test" });
    defer db.deinit();
    _ = try db.batchInsertEx("t", &.{"c"}, &.{
        &.{Value{ .int = 1 }},
    }, .{ .mode = .protocol });
}

test "postgres batchInsertEx protocol mode api compiles" {
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{ .driver = .postgres, .host = "127.0.0.1", .user = "postgres", .password = "", .database = "test" });
    defer db.deinit();
    _ = try db.batchInsertEx("t", &.{"c"}, &.{
        &.{Value{ .int = 1 }},
    }, .{ .mode = .protocol });
}

test "diagnosePostgres handles null result and missing error fields safely" {
    const diag_null = diagnosePostgres(null);
    try std.testing.expectEqual(@as(i32, 0), diag_null.code);
    try std.testing.expectEqualStrings("", diag_null.message);
    try std.testing.expect(diag_null.constraint == null);
    try std.testing.expect(diag_null.table == null);
    try std.testing.expect(diag_null.column == null);
}

test "convertPlaceholders maps ? and ?N to sequential $N" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "SELECT * FROM users WHERE username = ?1", .want = "SELECT * FROM users WHERE username = $1" },
        .{ .in = "INSERT INTO t (a, b) VALUES (?1, ?2)", .want = "INSERT INTO t (a, b) VALUES ($1, $2)" },
        .{ .in = "SELECT * FROM t WHERE a = ? AND b = ?2 AND c = ?", .want = "SELECT * FROM t WHERE a = $1 AND b = $2 AND c = $3" },
        .{ .in = "UPDATE t SET a = ?12 WHERE id = ?", .want = "UPDATE t SET a = $1 WHERE id = $2" },
        .{ .in = "SELECT * FROM t WHERE x = ?", .want = "SELECT * FROM t WHERE x = $1" },
        .{ .in = "SELECT * FROM t", .want = "SELECT * FROM t" },
    };
    for (cases) |case| {
        const got = PostgresConn.convertPlaceholders(allocator, case.in) orelse return error.TestUnexpectedResult;
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "convertPlaceholders skips ? inside literals and comments" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "SELECT 'it''s ? fine' AS s, ? AS p", .want = "SELECT 'it''s ? fine' AS s, $1 AS p" },
        .{ .in = "SELECT \"col?\" FROM t WHERE x = ?", .want = "SELECT \"col?\" FROM t WHERE x = $1" },
        .{ .in = "SELECT 1 -- ? comment\nWHERE x = ?", .want = "SELECT 1 -- ? comment\nWHERE x = $1" },
        .{ .in = "SELECT 1 /* ? block */ WHERE x = ?", .want = "SELECT 1 /* ? block */ WHERE x = $1" },
        .{ .in = "SELECT '?', 'a''b?c' WHERE x = ?1", .want = "SELECT '?', 'a''b?c' WHERE x = $1" },
    };
    for (cases) |case| {
        const got = PostgresConn.convertPlaceholders(allocator, case.in) orelse return error.TestUnexpectedResult;
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "sqlite transaction queryRowPartial zeroes missing columns" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const PartialUser = struct {
        id: i64,
        name: []const u8,
        bio: []const u8, // missing in DB, should be zeroed
    };

    var tx = try client.beginTx();
    defer tx.rollback() catch {};
    const user = try tx.queryRowPartial(allocator, PartialUser, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, PartialUser, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
    try std.testing.expectEqual(@as(usize, 0), user.bio.len);
}
