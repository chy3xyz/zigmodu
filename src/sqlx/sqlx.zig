//! SQL client abstraction for zigzero
//!
//! Aligned with go-zero's core/stores/sqlx package.
//! Supports SQLite, PostgreSQL, and MySQL via C bindings.

const std = @import("std");
const builtin = @import("builtin");
const errors = @import("errors.zig");
const sqlite3_c = @import("sqlite3_c.zig");
const libpq_c = @import("libpq_c.zig");
const libmysql_c = @import("libmysql_c.zig");
const breaker = @import("breaker.zig");

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
    allocator: std.mem.Allocator,
    columns: []const []const u8,
    values: []const ?Value,

    pub fn get(self: Row, column: []const u8) ?Value {
        for (self.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col, column)) {
                const v = self.values[i] orelse return null;
                switch (v) {
                    .string => |s| return .{ .string = self.allocator.dupe(u8, s) catch return null },
                    else => return v,
                }
            }
        }
        return null;
    }

    pub fn scan(self: Row, allocator: std.mem.Allocator, comptime T: type) !T {
        return scanStruct(allocator, T, self, false);
    }

    pub fn scanPartial(self: Row, allocator: std.mem.Allocator, comptime T: type) !T {
        return scanStruct(allocator, T, self, true);
    }
};

/// Query results
pub const Rows = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Row,

    pub fn deinit(self: *Rows) void {
        self.arena.deinit();
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

/// SQL connection interface
pub const Conn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        query: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows),
        exec: *const fn (ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult),
        close: *const fn (ptr: *anyopaque) void,
        ping: *const fn (ptr: *anyopaque) errors.Result,
        begin: *const fn (ptr: *anyopaque) errors.Result,
        commit: *const fn (ptr: *anyopaque) errors.Result,
        rollback: *const fn (ptr: *anyopaque) errors.Result,
        prepare: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt),
    };

    pub fn query(self: Conn, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        return self.vtable.query(self.ptr, allocator, sql_str, args);
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
};

// ==================== Struct Scanning ====================

fn scanStruct(allocator: std.mem.Allocator, comptime T: type, row: Row, partial: bool) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("scanStruct only supports structs, got " ++ @typeName(T));

    var result: T = undefined;
    inline for (info.@"struct".fields) |field| {
        const FieldType = field.type;
        const is_optional = @typeInfo(FieldType) == .optional;
        const BaseType = if (is_optional) @typeInfo(FieldType).optional.child else FieldType;
        const is_string = BaseType == []const u8;

        if (is_string) {
            // String fields: bypass row.get() to avoid double-duplication.
            // row.get() duplicates the string; valueToType would duplicate again.
            found: {
                for (row.columns, 0..) |col, ci| {
                    if (std.mem.eql(u8, col, field.name)) {
                        const raw_val = row.values[ci];
                        if (raw_val == null or raw_val.? == .null) {
                            if (is_optional) {
                                @field(result, field.name) = null;
                            } else if (partial) {
                                @field(result, field.name) = &[_]u8{};
                            } else {
                                return error.NotFound;
                            }
                        } else {
                            // raw_val.? is .string. Dupe it once (owned); freeScanned frees it.
                            const str = raw_val.?.string;
                            @field(result, field.name) = allocator.dupe(u8, str) catch return error.DatabaseError;
                        }
                        break :found;
                    }
                }
                // Column not found
                if (is_optional) {
                    @field(result, field.name) = null;
                } else if (partial) {
                    @field(result, field.name) = &[_]u8{};
                } else {
                    return error.NotFound;
                }
            }
            continue;
        }

        // Non-string fields: use row.get() as before (no duplication concern)
        const val = row.get(field.name);
        if (is_optional) {
            const ChildType = BaseType;
            if (val == null or val.? == .null) {
                @field(result, field.name) = null;
            } else {
                @field(result, field.name) = try valueToType(allocator, ChildType, val.?);
            }
        } else {
            if (val == null or val.? == .null) {
                if (partial) {
                    @field(result, field.name) = std.mem.zeroes(FieldType);
                } else {
                    return error.NotFound;
                }
            } else {
                @field(result, field.name) = try valueToType(allocator, FieldType, val.?);
            }
        }
    }
    return result;
}

fn valueToType(allocator: std.mem.Allocator, comptime T: type, val: Value) !T {
    return switch (T) {
        i64 => if (val == .int) val.int else error.DatabaseError,
        i32 => if (val == .int) @intCast(val.int) else error.DatabaseError,
        u64 => if (val == .int) @intCast(val.int) else error.DatabaseError,
        u32 => if (val == .int) @intCast(val.int) else error.DatabaseError,
        f64 => if (val == .float) val.float else if (val == .int) @floatFromInt(val.int) else error.DatabaseError,
        f32 => if (val == .float) @floatCast(val.float) else if (val == .int) @floatFromInt(val.int) else error.DatabaseError,
        bool => if (val == .bool) val.bool else if (val == .int) val.int != 0 else error.DatabaseError,
        []const u8 => if (val == .string) (allocator.dupe(u8, val.string) catch return error.DatabaseError) else error.DatabaseError,
        else => @compileError("Unsupported scan type: " ++ @typeName(T)),
    };
}

pub fn freeScanned(allocator: std.mem.Allocator, comptime T: type, val: T) void {
    const info = @typeInfo(T);
    if (info != .@"struct") return;
    inline for (info.@"struct".fields) |field| {
        const FieldType = field.type;
        if (FieldType == []const u8) {
            allocator.free(@field(val, field.name));
        } else if (@typeInfo(FieldType) == .optional and @typeInfo(FieldType).optional.child == []const u8) {
            if (@field(val, field.name)) |s| allocator.free(s);
        }
    }
}

// ==================== SQLite Implementation ====================

pub const SQLiteConn = struct {
    db: ?*sqlite3_c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !SQLiteConn {
        var db: ?*sqlite3_c.sqlite3 = null;
        const c_path = allocator.dupeZ(u8, path) catch return error.DatabaseError;
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
        return .{ .db = db, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        _ = allocator;
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        var stmt: ?*sqlite3_c.sqlite3_stmt = null;
        const rc = sqlite3_c.sqlite3_prepare_v2(self.db, @ptrCast(sql_str.ptr), @intCast(sql_str.len), &stmt, null);
        if (rc != sqlite3_c.SQLITE_OK or stmt == null) return error.DatabaseError;
        defer _ = sqlite3_c.sqlite3_finalize(stmt);

        try bindSQLite(stmt.?, args);

        const col_count = sqlite3_c.sqlite3_column_count(stmt);
        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        while (sqlite3_c.sqlite3_step(stmt) == sqlite3_c.SQLITE_ROW) {
            const columns = arena_alloc.alloc([]const u8, @intCast(col_count)) catch return error.DatabaseError;
            const values = arena_alloc.alloc(?Value, @intCast(col_count)) catch return error.DatabaseError;
            for (0..@intCast(col_count)) |i| {
                const raw_name = sqlite3_c.sqlite3_column_name(stmt, @intCast(i));
                const name_len = std.mem.len(raw_name);
                const name = raw_name[0..name_len];
                columns[i] = arena_alloc.dupe(u8, name) catch return error.DatabaseError;
                values[i] = readSQLiteValue(arena_alloc, stmt, @intCast(i));
            }
            rows_list.append(arena_alloc, .{ .allocator = arena_alloc, .columns = columns, .values = values }) catch return error.DatabaseError;
        }

        const rows_slice = arena_alloc.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        var stmt: ?*sqlite3_c.sqlite3_stmt = null;
        const rc = sqlite3_c.sqlite3_prepare_v2(self.db, @ptrCast(sql_str.ptr), @intCast(sql_str.len), &stmt, null);
        if (rc != sqlite3_c.SQLITE_OK or stmt == null) return error.DatabaseError;
        defer _ = sqlite3_c.sqlite3_finalize(stmt);

        try bindSQLite(stmt.?, args);

        const step_rc = sqlite3_c.sqlite3_step(stmt);
        if (step_rc != sqlite3_c.SQLITE_DONE and step_rc != sqlite3_c.SQLITE_ROW) return error.DatabaseError;

        return ExecResult{
            .last_insert_id = sqlite3_c.sqlite3_last_insert_rowid(self.db),
            .rows_affected = @intCast(sqlite3_c.sqlite3_changes(self.db)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        if (self.db) |db| {
            _ = sqlite3_c.sqlite3_close(db);
            self.db = null;
        }
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        if (self.db == null) return error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        const rc = sqlite3_c.sqlite3_exec(self.db, "BEGIN", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        const rc = sqlite3_c.sqlite3_exec(self.db, "COMMIT", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        const rc = sqlite3_c.sqlite3_exec(self.db, "ROLLBACK", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    fn prepareFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt) {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        const stmt = allocator.create(SQLiteStmt) catch return error.DatabaseError;
        errdefer allocator.destroy(stmt);
        stmt.* = SQLiteStmt.prepare(self.db, allocator, sql_str) catch return error.DatabaseError;
        return stmt.toStmt();
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

pub const PostgresConn = struct {
    conn: ?*libpq_c.PGconn,
    allocator: std.mem.Allocator,

    /// Connect using explicit parameters via dlsym (bypasses Zig C ABI issues)
    pub fn connectParams(allocator: std.mem.Allocator, host: []const u8, port: u16, user: []const u8, pass: []const u8, db: []const u8) !PostgresConn {
        const host_c = try allocator.dupeZ(u8, host);
        defer allocator.free(host_c);
        const port_str_buf = try allocator.alloc(u8, 8);
        const port_str = try std.fmt.bufPrintZ(port_str_buf, "{d}", .{port});
        defer allocator.free(port_str_buf);
        const user_c = try allocator.dupeZ(u8, user);
        defer allocator.free(user_c);
        const pass_c = try allocator.dupeZ(u8, pass);
        defer allocator.free(pass_c);
        const db_c = try allocator.dupeZ(u8, db);
        defer allocator.free(db_c);

        const empty_opt = "\x00";
        const conn = libpq_c.PQsetdbLogin(
            host_c,
            port_str,
            empty_opt,
            empty_opt,
            db_c,
            user_c,
            pass_c,
        );
        if (conn == null) return error.DatabaseError;
        if (libpq_c.PQstatus(conn) != libpq_c.ConnStatusType.CONNECTION_OK) {
            libpq_c.PQfinish(conn);
            return error.DatabaseError;
        }
        return .{ .conn = conn, .allocator = allocator };
    }

    /// Null-terminated string connect
    pub fn connect(allocator: std.mem.Allocator, conninfo: []const u8) !PostgresConn {
        const null_terminated = try allocator.dupeZ(u8, conninfo);
        defer allocator.free(null_terminated);
        const conn = libpq_c.PQconnectdb(null_terminated);
        if (conn == null) return error.DatabaseError;
        const status = libpq_c.PQstatus(conn);
        if (status != .CONNECTION_OK) {
            libpq_c.PQfinish(conn);
            return error.DatabaseError;
        }
        return .{ .conn = conn, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const res = execParams(self, sql_str, args) orelse return error.DatabaseError;
        defer libpq_c.PQclear(res);

        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_TUPLES_OK) return error.DatabaseError;

        const n_rows = libpq_c.PQntuples(res);
        const n_cols = libpq_c.PQnfields(res);

        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        for (0..@intCast(n_rows)) |r| {
            const columns = arena_alloc.alloc([]const u8, @intCast(n_cols)) catch return error.DatabaseError;
            const values = arena_alloc.alloc(?Value, @intCast(n_cols)) catch return error.DatabaseError;
            for (0..@intCast(n_cols)) |c| {
                const name = std.mem.span(libpq_c.PQfname(res, @intCast(c)));
                columns[c] = arena_alloc.dupe(u8, name) catch return error.DatabaseError;
                if (libpq_c.PQgetisnull(res, @intCast(r), @intCast(c)) == 1) {
                    values[c] = null;
                } else {
                    const val = std.mem.span(libpq_c.PQgetvalue(res, @intCast(r), @intCast(c)));
                    values[c] = .{ .string = arena_alloc.dupe(u8, val) catch return error.DatabaseError };
                }
            }
            rows_list.append(arena_alloc, .{ .allocator = arena_alloc, .columns = columns, .values = values }) catch return error.DatabaseError;
        }

        const rows_slice = arena_alloc.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        const res = execParams(self, sql_str, args) orelse return error.DatabaseError;
        defer libpq_c.PQclear(res);

        const status = libpq_c.PQresultStatus(res);
        if (status != libpq_c.ExecStatusType.PGRES_COMMAND_OK and status != libpq_c.ExecStatusType.PGRES_TUPLES_OK) return error.DatabaseError;

        const cmd = std.mem.span(libpq_c.PQcmdTuples(res));
        const affected = std.fmt.parseInt(u64, cmd, 10) catch 0;
        return ExecResult{ .rows_affected = affected };
    }

    fn execParams(self: *PostgresConn, sql_str: []const u8, args: []const Value) ?*libpq_c.PGresult {
        if (self.conn == null) return null;
        const paramValues = self.allocator.alloc(?[*]const u8, args.len) catch return null;
        const paramLengths = self.allocator.alloc(c_int, args.len) catch {
            self.allocator.free(paramValues);
            return null;
        };
        // Note: allocated strings (int/float) may leak in this simplified implementation.
        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => null,
                .int => |v| blk: {
                    const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch {
                        self.allocator.free(paramValues);
                        self.allocator.free(paramLengths);
                        return null;
                    };
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .float => |v| blk: {
                    const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch {
                        self.allocator.free(paramValues);
                        self.allocator.free(paramLengths);
                        return null;
                    };
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .string => |v| blk: {
                    // Strings may not be null-terminated, so we provide paramLengths.
                    paramLengths[i] = @intCast(v.len);
                    break :blk @ptrCast(v.ptr);
                },
                .bool => |v| blk: {
                    paramLengths[i] = 1;
                    break :blk if (v) @ptrCast("t") else @ptrCast("f");
                },
            };
        }
        const res = libpq_c.PQexecParams(self.conn, @ptrCast(sql_str.ptr), @intCast(args.len), null, @ptrCast(paramValues.ptr), @ptrCast(paramLengths.ptr), null, 0);
        self.allocator.free(paramValues);
        self.allocator.free(paramLengths);
        return res;
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        if (self.conn) |conn| {
            libpq_c.PQfinish(conn);
            self.conn = null;
        }
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        if (self.conn == null or libpq_c.PQstatus(self.conn) != libpq_c.ConnStatusType.CONNECTION_OK) return error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        const res = libpq_c.PQexec(self.conn, "BEGIN");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        const res = libpq_c.PQexec(self.conn, "COMMIT");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        const res = libpq_c.PQexec(self.conn, "ROLLBACK");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    fn prepareFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        const stmt = allocator.create(PostgresStmt) catch return error.DatabaseError;
        errdefer allocator.destroy(stmt);
        stmt.* = PostgresStmt.prepare(self.conn, allocator, sql_str) catch return error.DatabaseError;
        return stmt.toStmt();
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
                    // Escape single quotes to prevent SQL injection
                    for (v) |char| {
                        if (char == '\'') {
                            try buf.appendSlice(allocator, "''");
                        } else {
                            try buf.append(allocator, char);
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
            const columns = arena_alloc.alloc([]const u8, n_cols) catch return error.DatabaseError;
            const values = arena_alloc.alloc(?Value, n_cols) catch return error.DatabaseError;
            for (0..n_cols) |c| {
                columns[c] = arena_alloc.dupe(u8, field_names[c]) catch return error.DatabaseError;
                if (row_data == null or row_data.?[c] == null) {
                    values[c] = null;
                } else {
                    const len = lengths[c];
                    const val = row_data.?[c].?[0..len];
                    values[c] = .{ .string = arena_alloc.dupe(u8, val) catch return error.DatabaseError };
                }
            }
            rows_list.append(arena_alloc, .{ .allocator = arena_alloc, .columns = columns, .values = values }) catch return error.DatabaseError;
        }

        const rows_slice = arena_alloc.alloc(Row, rows_list.items.len) catch return error.DatabaseError;
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena_mut, .rows = rows_slice };
    }

    if (libmysql_c.mysql_errno(mysql) != 0) return error.DatabaseError;
    if (libmysql_c.mysql_field_count(mysql) == 0) return error.DatabaseError;
    const rows_slice = arena_alloc.alloc(Row, 0) catch return error.DatabaseError;
    return Rows{ .arena = arena_mut, .rows = rows_slice };
}

pub const MySqlConn = struct {
    mysql: ?*libmysql_c.MYSQL,
    allocator: std.mem.Allocator,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, user: []const u8, password: []const u8, db: []const u8, port: u32) !MySqlConn {
        const mysql = libmysql_c.mysql_init(null);
        if (mysql == null) return error.DatabaseError;
        // "" has ptr=null; mysql_real_connect interprets null as "no password".
        // Use "\x00" (null terminator only) as a null-terminated empty string instead.
        const password_cstr: [*c]const u8 = if (password.len > 0) @ptrCast(password.ptr) else @ptrCast("\x00");
        // Use Unix socket for localhost connections (avoids TCP auth issues with
        // caching_sha2_password which MariaDB Connector/C doesn't support with MySQL 8).
        const use_socket = std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1");
        const socket_path: [*c]const u8 = if (use_socket) @ptrCast("/tmp/mysql.sock") else @ptrCast("\x00");
        const conn = libmysql_c.mysql_real_connect(mysql, @ptrCast(host.ptr), @ptrCast(user.ptr), password_cstr, @ptrCast(db.ptr), @intCast(port), socket_path, 0);
        if (conn == null) {
            libmysql_c.mysql_close(mysql);
            return error.DatabaseError;
        }
        return .{ .mysql = mysql, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const query = formatQuery(self.allocator, sql_str, args) catch return error.DatabaseError;
        defer self.allocator.free(query);

        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) return error.DatabaseError;

        return mysqlReadRowsAfterQuery(self.mysql, arena);
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        const query = formatQuery(self.allocator, sql_str, args) catch return error.DatabaseError;
        defer self.allocator.free(query);

        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) return error.DatabaseError;
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
        if (self.mysql) |mysql| {
            libmysql_c.mysql_close(mysql);
            self.mysql = null;
        }
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        if (self.mysql == null) return error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        if (libmysql_c.mysql_real_query(self.mysql, "START TRANSACTION", 17) != 0) return error.DatabaseError;
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        if (libmysql_c.mysql_real_query(self.mysql, "COMMIT", 6) != 0) return error.DatabaseError;
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        if (libmysql_c.mysql_real_query(self.mysql, "ROLLBACK", 8) != 0) return error.DatabaseError;
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);
    }

    fn prepareFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        const stmt = allocator.create(MySqlStmt) catch return error.DatabaseError;
        errdefer allocator.destroy(stmt);
        stmt.* = MySqlStmt.prepare(self.mysql, allocator, sql_str) catch return error.DatabaseError;
        return stmt.toStmt();
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
        return self.vtable.query(self.ptr, allocator, args);
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
            rows_list.append(arena_alloc, .{ .allocator = arena_alloc, .columns = columns, .values = values }) catch return error.DatabaseError;
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
        const stmt_name = try std.fmt.bufPrint(&name_buf, "stmt_{x}", .{@intFromPtr(sql.ptr)});
        const name_copy = try allocator.dupe(u8, stmt_name);
        const res = libpq_c.PQprepare(conn, @ptrCast(name_copy.ptr), @ptrCast(sql.ptr), 0, null);
        if (res == null) return error.DatabaseError;
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
        return .{ .conn = conn, .name = name_copy, .allocator = allocator };
    }

    fn execParamsPrepared(self: *PostgresStmt, args: []const Value) ?*libpq_c.PGresult {
        if (self.conn == null) return null;
        const paramValues = self.allocator.alloc(?[*]const u8, args.len) catch return null;
        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => null,
                .int => |v| blk: {
                    const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch {
                        self.allocator.free(paramValues);
                        return null;
                    };
                    break :blk @ptrCast(s.ptr);
                },
                .float => |v| blk: {
                    const s = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch {
                        self.allocator.free(paramValues);
                        return null;
                    };
                    break :blk @ptrCast(s.ptr);
                },
                .string => |v| @ptrCast(v.ptr),
                .bool => |v| if (v) @ptrCast("t") else @ptrCast("f"),
            };
        }
        const res = libpq_c.PQexecPrepared(self.conn, @ptrCast(self.name.ptr), @intCast(args.len), @ptrCast(paramValues.ptr), null, null, 0);
        self.allocator.free(paramValues);
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

        for (0..@intCast(n_rows)) |r| {
            const columns = arena_alloc.alloc([]const u8, @intCast(n_cols)) catch return error.DatabaseError;
            const values = arena_alloc.alloc(?Value, @intCast(n_cols)) catch return error.DatabaseError;
            for (0..@intCast(n_cols)) |c| {
                const name = std.mem.span(libpq_c.PQfname(res, @intCast(c)));
                columns[c] = arena_alloc.dupe(u8, name) catch return error.DatabaseError;
                if (libpq_c.PQgetisnull(res, @intCast(r), @intCast(c)) == 1) {
                    values[c] = null;
                } else {
                    const val = std.mem.span(libpq_c.PQgetvalue(res, @intCast(r), @intCast(c)));
                    values[c] = .{ .string = arena_alloc.dupe(u8, val) catch return error.DatabaseError };
                }
            }
            rows_list.append(arena_alloc, .{ .allocator = arena_alloc, .columns = columns, .values = values }) catch return error.DatabaseError;
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
        const dealloc_sql = std.fmt.allocPrint(self.allocator, "DEALLOCATE {s}", .{self.name}) catch {
            self.allocator.free(self.name);
            self.allocator.destroy(self);
            return;
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
    mysql: ?*libmysql_c.MYSQL,
    sql: []const u8,
    allocator: std.mem.Allocator,

    pub fn prepare(mysql: ?*libmysql_c.MYSQL, allocator: std.mem.Allocator, sql: []const u8) !MySqlStmt {
        const sql_copy = try allocator.dupe(u8, sql);
        return .{ .mysql = mysql, .sql = sql_copy, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const query = formatQuery(self.allocator, self.sql, args) catch return error.DatabaseError;
        defer self.allocator.free(query);
        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) return error.DatabaseError;
        return mysqlReadRowsAfterQuery(self.mysql, arena);
    }

    fn execFn(ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        const query = formatQuery(self.allocator, self.sql, args) catch return error.DatabaseError;
        defer self.allocator.free(query);
        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) return error.DatabaseError;
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);
        return ExecResult{
            .rows_affected = libmysql_c.mysql_affected_rows(self.mysql),
            .last_insert_id = @intCast(libmysql_c.mysql_insert_id(self.mysql)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        self.allocator.free(self.sql);
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
    allocator: std.mem.Allocator,
    client: *Client,
    max_open: u32,
    max_idle: u32,
    max_wait_ms: u32,
    max_reconnect_attempts: u32 = 3,
    reconnect_delay_ms: u32 = 100,
    active: std.atomic.Value(u32),
    idle: std.ArrayList(Conn),
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    closed: std.atomic.Value(bool),
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, client: *Client, max_open: u32, max_idle: u32, io: std.Io) ConnPool {
        return .{
            .allocator = allocator,
            .client = client,
            .max_open = max_open,
            .max_idle = max_idle,
            .max_wait_ms = client.config.max_wait_ms,
            .active = std.atomic.Value(u32).init(0),
            .idle = std.ArrayList(Conn).empty,
            .mutex = std.Io.Mutex.init,
            .cond = .init,
            .closed = std.atomic.Value(bool).init(false),
            .io = io,
        };
    }

    pub fn deinit(self: *ConnPool) void {
        self.closed.store(true, .monotonic);
        self.cond.broadcast(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.idle.items) |*conn| {
            conn.close();
        }
        self.idle.deinit(self.allocator);
    }

    /// Reconnect and add a new idle connection to the pool
    fn reconnect(self: *ConnPool) !void {
        const conn = self.client.newConn() catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.idle.append(self.allocator, conn) catch {
            conn.close();
        };
    }

    /// Attempt to get a healthy connection with reconnect logic
    fn getHealthyConn(self: *ConnPool) !Conn {
        var attempts: u32 = 0;
        while (attempts < self.max_reconnect_attempts) : (attempts += 1) {
            const conn = self.client.newConn() catch {
                if (attempts < self.max_reconnect_attempts - 1) {
                    self.reconnect() catch {};
                }
                continue;
            };
            // health check: ping before returning
            conn.ping() catch {
                conn.close();
                if (attempts < self.max_reconnect_attempts - 1) {
                    self.reconnect() catch {};
                }
                continue;
            };
            return conn;
        }
        return error.ConnectionFailed;
    }

    pub fn acquire(self: *ConnPool) !Conn {
        if (self.closed.load(.monotonic)) return error.ConnectionFailed;

        self.mutex.lockUncancelable(self.io);

        // Try to get from idle pool
        if (self.idle.items.len > 0) {
            const conn = self.idle.pop().?;
            self.mutex.unlock(self.io);
            return conn;
        }

        // Create new connection if under limit
        const current_active = self.active.load(.monotonic);
        if (current_active < self.max_open) {
            self.mutex.unlock(self.io);
            const conn = self.client.newConn() catch return error.ConnectionFailed;
            _ = self.active.fetchAdd(1, .monotonic);
            return conn;
        }

        // Wait for a connection to become available
        while (self.idle.items.len == 0 and !self.closed.load(.monotonic)) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }

        if (self.idle.items.len > 0) {
            const conn = self.idle.pop().?;
            self.mutex.unlock(self.io);
            // final health check before returning
            conn.ping() catch {
                conn.close();
                _ = self.active.fetchSub(1, .monotonic);
                return error.PoolUnhealthy;
            };
            return conn;
        }

        self.mutex.unlock(self.io);
        return error.Timeout;
    }

    pub fn release(self: *ConnPool, conn: Conn) void {
        if (self.closed.load(.monotonic)) {
            conn.close();
            _ = self.active.fetchSub(1, .monotonic);
            return;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Return to idle pool if not full, otherwise close
        if (self.idle.items.len < self.max_idle) {
            self.idle.append(self.allocator, conn) catch {
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
    max_open_conns: u32 = 1,
    max_idle_conns: u32 = 1,
    max_wait_ms: u32 = 5000,
};

/// SQL option function type aligned with go-zero's SqlOption
pub const SqlOption = *const fn (*Client) void;

/// Default acceptable error filter: NotFound is acceptable
pub fn defaultAcceptable(err: anyerror) bool {
    return err == error.NotFound;
}

/// SQL context aligned with go-zero's context.Context usage for sqlx
pub const SqlContext = struct {
    deadline_ms: ?i64 = null,

    pub fn isDone(self: SqlContext) bool {
        if (self.deadline_ms) |d| {
            return 0 > d;
        }
        return false;
    }

    pub fn withDeadline(deadline_ms: i64) SqlContext {
        return .{ .deadline_ms = deadline_ms };
    }

    pub fn withTimeout(timeout_ms: i64) SqlContext {
        return .{ .deadline_ms = 0 + timeout_ms };
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
            .start_ns = 0,
            .end_ns = null,
            .attributes = std.StringHashMap([]const u8).init(std.heap.page_allocator),
        };
    }

    pub fn setAttribute(self: *Span, key: []const u8, value: []const u8) void {
        self.attributes.put(key, value) catch {};
    }

    pub fn end(self: *Span) void {
        if (self.end_ns == null) {
            self.end_ns = 0;
        }
    }
};

/// SQLx client - unified SQL client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    conn: ?Conn = null,
    pool: ?ConnPool = null,
    cb: ?breaker.CircuitBreaker = null,
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
            .cb = null,
            .acceptable = null,
            .metrics_callback = null,
            .tracer = null,
            .io = io,
        };
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
    }

    fn ensurePool(self: *Client) void {
        if (self.config.max_open_conns > 1 and self.pool == null) {
            self.pool = ConnPool.init(self.allocator, self, self.config.max_open_conns, self.config.max_idle_conns, self.io);
        }
    }

    fn newConn(self: *Client) !Conn {
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
                    pg.* = try PostgresConn.connect(self.allocator, self.config.postgres_conninfo);
                } else {
                    pg.* = try PostgresConn.connectParams(
                        self.allocator,
                        self.config.host,
                        self.config.port,
                        self.config.username,
                        self.config.password,
                        self.config.database,
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
        self.ensureBreaker();
        if (!self.cb.?.allow()) return error.CircuitBreakerOpen;
        const conn = try self.newConn();
        errdefer conn.close();
        var stmt = self.newStmt(conn, sql_str) catch |err| {
            if (!self.isAcceptable(err)) self.cb.?.recordFailure();
            return err;
        };
        stmt.conn = conn;
        self.cb.?.recordSuccess();
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

    fn ensureBreaker(self: *Client) void {
        if (self.cb == null) {
            self.cb = breaker.CircuitBreaker.new(self.io);
        }
    }

    fn doQuery(self: *Client, sql_str: []const u8, args: []const Value) !Rows {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.query(self.allocator, sql_str, args);
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.query(self.allocator, sql_str, args);
    }

    pub fn query(self: *Client, sql_str: []const u8, args: []const Value) !Rows {
        self.ensureBreaker();
        if (!self.cb.?.allow()) return error.CircuitBreakerOpen;

        const t0 = 0;
        const result = self.doQuery(sql_str, args) catch |err| {
            const elapsed: u64 = @intCast(0 - t0);
            if (self.metrics_callback) |cb| cb(elapsed, sql_str, false, @errorName(err));
            if (!self.isAcceptable(err)) self.cb.?.recordFailure();
            return err;
        };
        const elapsed: u64 = @intCast(0 - t0);
        if (self.metrics_callback) |cb| cb(elapsed, sql_str, true, null);
        self.cb.?.recordSuccess();
        return result;
    }

    pub fn queryCtx(self: *Client, ctx: SqlContext, sql_str: []const u8, args: []const Value) !Rows {
        if (ctx.isDone()) return error.Timeout;
        return self.query(sql_str, args);
    }

    fn doExec(self: *Client, sql_str: []const u8, args: []const Value) !ExecResult {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.exec(sql_str, args);
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.exec(sql_str, args);
    }

    pub fn exec(self: *Client, sql_str: []const u8, args: []const Value) !ExecResult {
        self.ensureBreaker();
        if (!self.cb.?.allow()) return error.CircuitBreakerOpen;

        const t0 = 0;
        const result = self.doExec(sql_str, args) catch |err| {
            const elapsed: u64 = @intCast(0 - t0);
            if (self.metrics_callback) |cb| cb(elapsed, sql_str, false, @errorName(err));
            if (!self.isAcceptable(err)) self.cb.?.recordFailure();
            return err;
        };
        const elapsed: u64 = @intCast(0 - t0);
        if (self.metrics_callback) |cb| cb(elapsed, sql_str, true, null);
        self.cb.?.recordSuccess();
        return result;
    }

    pub fn execCtx(self: *Client, ctx: SqlContext, sql_str: []const u8, args: []const Value) !ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.exec(sql_str, args);
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
        self.ensureBreaker();
        if (!self.cb.?.allow()) return error.CircuitBreakerOpen;
        self.doPing() catch |err| {
            if (!self.isAcceptable(err)) self.cb.?.recordFailure();
            return err;
        };
        self.cb.?.recordSuccess();
    }

    pub fn pingCtx(self: *Client, ctx: SqlContext) !void {
        if (ctx.isDone()) return error.Timeout;
        return self.ping();
    }

    pub fn beginTx(self: *Client) errors.Error!Transaction {
        self.ensureBreaker();
        if (!self.cb.?.allow()) return errors.Error.CircuitBreakerOpen;
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = p.acquire() catch |err| {
                if (err == error.ConnectionFailed) return errors.Error.DatabaseError;
                if (err == error.Timeout) return errors.Error.Timeout;
                if (err == error.PoolUnhealthy) return errors.Error.PoolUnhealthy;
                return errors.Error.DatabaseError;
            };
            errdefer p.release(conn);
            conn.begin() catch |err| {
                if (!self.isAcceptable(err)) self.cb.?.recordFailure();
                return errors.Error.DatabaseError;
            };
            return Transaction{ .conn = conn, .pool = p };
        }
        if (self.conn == null) {
            self.connect() catch |err| {
                if (err == error.OutOfMemory) return errors.Error.OutOfMemory;
                return errors.Error.DatabaseError;
            };
        }
        self.conn.?.begin() catch {
            if (!self.isAcceptable(errors.DatabaseError.ConnectionFailed)) self.cb.?.recordFailure();
            return errors.Error.DatabaseError;
        };
        return Transaction{ .conn = self.conn.? };
    }

    pub fn transact(self: *Client, comptime T: type, fn_tx: *const fn (*Transaction) errors.ResultT(T)) errors.ResultT(T) {
        var tx = try self.beginTx();
        errdefer {
            tx.rollback() catch {};
            if (tx.pool) |p| p.release(tx.conn);
        }
        const result = try fn_tx(&tx);
        try tx.commit();
        return result;
    }

    pub fn transactCtx(self: *Client, ctx: SqlContext, comptime T: type, fn_tx: *const fn (*Transaction) errors.ResultT(T)) errors.ResultT(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.transact(T, fn_tx);
    }

    pub fn queryRow(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        if (rows.rows.len == 0) return error.NotFound;
        return try rows.rows[0].scan(self.allocator, T);
    }

    pub fn queryRowCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRow(T, sql_str, args);
    }

    pub fn queryRowPartial(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        if (rows.rows.len == 0) return error.NotFound;
        return try rows.rows[0].scanPartial(self.allocator, T);
    }

    pub fn queryRowPartialCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowPartial(T, sql_str, args);
    }

    pub fn queryRows(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        const result = try self.allocator.alloc(T, rows.rows.len);
        errdefer {
            for (result) |item| freeScanned(self.allocator, T, item);
            self.allocator.free(result);
        }
        for (rows.rows, 0..) |row, i| {
            result[i] = try row.scan(self.allocator, T);
        }
        return result;
    }

    pub fn queryRowsCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRows(T, sql_str, args);
    }

    pub fn queryRowsPartial(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        const result = try self.allocator.alloc(T, rows.rows.len);
        errdefer {
            for (result) |item| freeScanned(self.allocator, T, item);
            self.allocator.free(result);
        }
        for (rows.rows, 0..) |row, i| {
            result[i] = try row.scanPartial(self.allocator, T);
        }
        return result;
    }

    pub fn queryRowsPartialCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowsPartial(T, sql_str, args);
    }

    pub fn deinitQueryRows(self: *Client, comptime T: type, items: []T) void {
        for (items) |item| freeScanned(self.allocator, T, item);
        self.allocator.free(items);
    }

    pub fn findOne(self: *Client, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRow(T, sql, args);
    }

    pub fn findOneCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOne(T, table, where_clause, args);
    }

    pub fn findOnePartial(self: *Client, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRowPartial(T, sql, args);
    }

    pub fn findOnePartialCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOnePartial(T, table, where_clause, args);
    }

    pub fn findAll(self: *Client, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRows(T, sql, args);
    }

    pub fn findAllCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
        if (ctx.isDone()) return error.Timeout;
        return self.findAll(T, table, where_clause, args);
    }

    pub fn findAllPartial(self: *Client, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRowsPartial(T, sql, args);
    }

    pub fn findAllPartialCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
        if (ctx.isDone()) return error.Timeout;
        return self.findAllPartial(T, table, where_clause, args);
    }
};

/// SQL transaction
pub const Transaction = struct {
    conn: Conn,
    pool: ?*ConnPool = null,

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

    /// queryRow scans a single row into struct T (like Client.queryRow but on tx)
    pub fn queryRow(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(allocator, sql_str, args);
        defer rows.deinit();
        if (rows.rows.len == 0) return error.NotFound;
        return try rows.rows[0].scan(allocator, T);
    }

    /// queryRows scans all rows into []T (like Client.queryRows but on tx)
    pub fn queryRows(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        var rows = try self.query(allocator, sql_str, args);
        defer rows.deinit();
        const result = try allocator.alloc(T, rows.rows.len);
        errdefer {
            for (result) |item| freeScanned(allocator, T, item);
            allocator.free(result);
        }
        for (rows.rows, 0..) |row, i| {
            result[i] = try row.scan(allocator, T);
        }
        return result;
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
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const FieldType = field.type;
        if (FieldType == []const u8) {
            @field(dst, field.name) = try allocator.dupe(u8, @field(src, field.name));
        } else if (@typeInfo(FieldType) == .optional and @typeInfo(FieldType).optional.child == []const u8) {
            if (@field(src, field.name)) |s| {
                @field(dst, field.name) = try allocator.dupe(u8, s);
            }
        }
    }
    return dst;
}

/// Simple string cache for testing CachedConn
pub const StringCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) StringCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *StringCache) void {
        var iter = self.map.valueIterator();
        while (iter.next()) |v| self.allocator.free(v.*);
        var key_iter = self.map.keyIterator();
        while (key_iter.next()) |k| self.allocator.free(k.*);
        self.map.deinit();
    }

    pub fn get(self: *StringCache, key: []const u8) ?[]const u8 {
        const val = self.map.get(key) orelse return null;
        return self.allocator.dupe(u8, val) catch null;
    }

    pub fn set(self: *StringCache, key: []const u8, value: []const u8, ttl_sec: u32) !void {
        _ = ttl_sec;
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        const entry = self.map.getEntry(k);
        if (entry) |e| {
            self.allocator.free(e.value_ptr.*);
            e.value_ptr.* = v;
            self.allocator.free(k);
        } else {
            try self.map.put(k, v);
        }
    }

    pub fn del(self: *StringCache, key: []const u8) void {
        if (self.map.fetchRemove(key)) |entry| {
            self.allocator.free(entry.value);
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
        self.setCache(cache_key, json, self.ttl_sec) catch {};
        return result;
    }

    pub fn queryRowNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        return self.client.queryRow(T, sql_str, args);
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
        self.setCache(cache_key, json, self.ttl_sec) catch {};
        return result;
    }

    pub fn queryRowPartialNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        return self.client.queryRowPartial(T, sql_str, args);
    }

    pub fn queryRowPartialCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowPartial(T, cache_key, sql_str, args);
    }

    pub fn queryRows(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) ![]T {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            var parsed = std.json.parseFromSlice([]T, self.allocator, cached, .{}) catch return error.DatabaseError;
            defer parsed.deinit();
            const result = try self.allocator.alloc(T, parsed.value.len);
            errdefer {
                for (result) |item| freeScanned(self.allocator, T, item);
                self.allocator.free(result);
            }
            for (parsed.value, 0..) |item, i| {
                result[i] = try deepCopyStruct(self.allocator, T, item);
            }
            return result;
        }
        const result = try self.client.queryRows(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch {};
        return result;
    }

    pub fn queryRowsNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        return self.client.queryRows(T, sql_str, args);
    }

    pub fn queryRowsCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) ![]T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRows(T, cache_key, sql_str, args);
    }

    pub fn queryRowsPartial(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) ![]T {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            var parsed = std.json.parseFromSlice([]T, self.allocator, cached, .{}) catch return error.DatabaseError;
            defer parsed.deinit();
            const result = try self.allocator.alloc(T, parsed.value.len);
            errdefer {
                for (result) |item| freeScanned(self.allocator, T, item);
                self.allocator.free(result);
            }
            for (parsed.value, 0..) |item, i| {
                result[i] = try deepCopyStruct(self.allocator, T, item);
            }
            return result;
        }
        const result = try self.client.queryRowsPartial(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch {};
        return result;
    }

    pub fn queryRowsPartialNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        return self.client.queryRowsPartial(T, sql_str, args);
    }

    pub fn queryRowsPartialCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) ![]T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowsPartial(T, cache_key, sql_str, args);
    }

    pub fn exec(self: *CachedConn, cache_keys: []const []const u8, sql_str: []const u8, args: []const Value) !ExecResult {
        const result = try self.client.exec(sql_str, args);
        for (cache_keys) |key| {
            self.delCache(key) catch {};
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
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRow(T, cache_key, sql, args);
    }

    pub fn findOneNoCache(self: *CachedConn, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
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

    pub fn findAll(self: *CachedConn, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRows(T, cache_key, sql, args);
    }

    pub fn findAllNoCache(self: *CachedConn, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRowsNoCache(T, sql, args);
    }

    pub fn findAllCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
        if (ctx.isDone()) return error.Timeout;
        return self.findAll(T, cache_key, table, where_clause, args);
    }

    pub fn findAllNoCacheCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) ![]T {
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
    const db_env = if (builtin.os.tag == .windows) "" else if (std.c.getenv("DB")) |ptr| std.mem.span(ptr) else return error.SkipZigTest;
    if (db_env.len == 0 or !std.mem.eql(u8, db_env, db)) {
        return error.SkipZigTest;
    }
}

test "cached conn queryRow and exec" {
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
    defer client.deinitQueryRows(User, users);
    try std.testing.expectEqual(@as(usize, 2), users.len);
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
    try std.testing.expectEqual(@as(i64, 1), rows.rows[0].get("id").?.int);
    if (rows.rows[0].get("name")) |name_val| {
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
    defer client.deinitQueryRows(User, users);
    try std.testing.expectEqual(@as(usize, 2), users.len);
    try std.testing.expectEqualStrings("Alice", users[0].name);
    try std.testing.expectEqualStrings("Bob", users[1].name);
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
    defer client.deinitQueryRows(User, users);
    try std.testing.expectEqual(@as(usize, 2), users.len);

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
    if (rows.rows[0].get("name")) |name_val| {
        const name_str = name_val.string;
        try std.testing.expectEqualStrings("Alice", name_str);
    } else return error.TestUnexpectedResult;

    var empty_rows = try client.query("SELECT id, name FROM zigzero_test_users WHERE name = $1", &.{.{ .string = "NobodyHere" }});
    defer empty_rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_rows.rows.len);

    _ = try client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{});
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
    if (rows.rows[0].get("name")) |name_val| {
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
    try std.testing.expectEqual(@as(i64, 1), rows.rows[0].get("id").?.int);

    // Close connection (this frees the heap-allocated SQLiteConn)
    conn.close();
}
