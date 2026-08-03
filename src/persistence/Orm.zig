//! Unified ORM layer with comptime Backend abstraction
//!
//! This ORM is designed to be backend-agnostic. The default implementation
//! uses sqlx (src/persistence/backends/SqlxBackend.zig), but any type
//! satisfying the Backend trait can be plugged in at compile time.

const std = @import("std");
const sqlx = @import("../sqlx/sqlx.zig");
const bulk = @import("../sqlx/Bulk.zig");

/// Common value representation for ORM parameter binding
pub const OrmValue = union(enum) {
    null,
    int: i64,
    float: f64,
    string: []const u8,
    bool: bool,
};

/// Convert a primitive value to OrmValue
pub fn toOrmValue(v: anytype) OrmValue {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => .{ .int = @intCast(v) },
        .float, .comptime_float => .{ .float = v },
        .bool => .{ .bool = v },
        .optional => {
            if (v) |payload| {
                return toOrmValue(payload);
            }
            return .null;
        },
        else => blk: {
            if (T == []const u8 or T == []u8 or T == [:0]const u8) {
                break :blk .{ .string = v };
            }
            @compileError("Unsupported ORM value type: " ++ @typeName(T));
        },
    };
}

fn assertBackend(comptime B: type) void {
    if (!@hasField(B, "allocator")) @compileError("Backend must have 'allocator' field");
    if (!@hasDecl(B, "Value")) @compileError("Backend must declare Value type");
    if (!@hasDecl(B, "ExecResult")) @compileError("Backend must declare ExecResult type");
    if (!@hasDecl(B, "Tx")) @compileError("Backend must declare Tx type");
    if (!@hasDecl(B, "queryRow")) @compileError("Backend must declare queryRow");
    if (!@hasDecl(B, "queryRows")) @compileError("Backend must declare queryRows");
    if (!@hasDecl(B, "exec")) @compileError("Backend must declare exec");
    if (!@hasDecl(B, "beginTx")) @compileError("Backend must declare beginTx");
    if (!@hasDecl(B, "commitTx")) @compileError("Backend must declare commitTx");
    if (!@hasDecl(B, "rollbackTx")) @compileError("Backend must declare rollbackTx");
    if (!@hasDecl(B, "execTx")) @compileError("Backend must declare execTx");
    if (!@hasDecl(B, "queryRowTx")) @compileError("Backend must declare queryRowTx");
    if (!@hasDecl(B, "queryRowsTx")) @compileError("Backend must declare queryRowsTx");
    if (!@hasDecl(B, "fromOrmValue")) @compileError("Backend must declare fromOrmValue");
}

fn snakeCase(comptime name: []const u8) []const u8 {
    const idx = std.mem.lastIndexOf(u8, name, ".") orelse return name;
    return name[idx + 1 ..];
}

/// Convert camelCase to snake_case at comptime.
/// e.g. "userName" → "user_name", "deptId" → "dept_id", "id" → "id"
pub fn camelToSnake(comptime input: []const u8) []const u8 {
    @setEvalBranchQuota(2000);
    comptime var buf: [256]u8 = @splat(0);
    var idx: usize = 0;
    for (input) |c| {
        if (c >= 'A' and c <= 'Z') {
            buf[idx] = '_';
            idx += 1;
            buf[idx] = c + ('a' - 'A');
        } else {
            buf[idx] = c;
        }
        idx += 1;
    }
    const result = buf[0..idx];
    return result;
}

/// Check if the model type has sql_column_style = .camelCase
fn isCamelCaseModel(comptime T: type) bool {
    return @hasDecl(T, "sql_column_style") and T.sql_column_style == .camelCase;
}

/// Model metadata extracted at compile time from a struct
pub fn Model(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("Model only supports structs");
    const camel = comptime isCamelCaseModel(T);

    return struct {
        /// Explicit SQL table name (snake_case). When present on `T`, used instead of the type name.
        /// zmodu-generated models set this to match `CREATE TABLE` names.
        pub const table_name = if (@hasDecl(T, "sql_table_name"))
            T.sql_table_name
        else blk: {
            const raw = snakeCase(@typeName(T));
            break :blk raw;
        };

        /// Whether this model uses camelCase fields (mapped to snake_case columns)
        pub const camel_case = camel;

        pub const primary_key = blk: {
            if (@hasDecl(T, "sql_primary_key")) break :blk T.sql_primary_key;
            for (info.@"struct".field_names) |fname| {
                if (std.mem.eql(u8, fname, "id")) break :blk "id";
            }
            for (info.@"struct".field_names) |fname| {
                if (fname.len > 3 and std.mem.endsWith(u8, fname, "_id")) break :blk fname;
            }
            break :blk info.@"struct".field_names[0];
        };

        /// Struct field names (camelCase if model uses camelCase, otherwise snake_case)
        pub const fields = blk: {
            var names: []const []const u8 = &[_][]const u8{};
            for (info.@"struct".field_names) |fname| {
                names = names ++ .{fname};
            }
            break :blk names;
        };

        /// SQL column names (always snake_case for camelCase models, otherwise same as fields)
        pub const sql_columns = if (camel) blk: {
            var names: []const []const u8 = &[_][]const u8{};
            for (info.@"struct".field_names) |fname| {
                names = names ++ .{camelToSnake(fname)};
            }
            break :blk names;
        } else fields;
    };
}

fn fieldToBackendValue(comptime B: type, value: anytype) B.Value {
    return B.fromOrmValue(toOrmValue(value));
}

fn structToBackendArgs(comptime B: type, comptime T: type, allocator: std.mem.Allocator, entity: T) ![]B.Value {
    const info = @typeInfo(T).@"struct";
    const args = try allocator.alloc(B.Value, info.field_names.len);
    errdefer allocator.free(args);
    inline for (info.field_names, 0..) |fname, i| {
        args[i] = fieldToBackendValue(B, @field(entity, fname));
    }
    return args;
}

fn structToBackendArgsWithId(comptime B: type, comptime T: type, allocator: std.mem.Allocator, entity: T, comptime pk: []const u8) ![]B.Value {
    const info = @typeInfo(T).@"struct";
    const args = try allocator.alloc(B.Value, info.field_names.len);
    errdefer allocator.free(args);
    var idx: usize = 0;
    inline for (info.field_names) |fname| {
        const is_pk = comptime std.mem.eql(u8, fname, pk);
        if (!is_pk) {
            args[idx] = fieldToBackendValue(B, @field(entity, fname));
            idx += 1;
        }
    }
    args[idx] = fieldToBackendValue(B, @field(entity, pk));
    idx += 1;
    return args;
}

// ==================== SQL Builders ====================
// For camelCase models, sql_cols are snake_case (actual DB columns), fields are camelCase.
// SELECT uses "sql_col AS field" so Row.scan matches struct field names.

fn comptimeColumnList(comptime sql_cols: []const []const u8, comptime fields: []const []const u8, comptime camel: bool) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (sql_cols, 0..) |col, i| {
            if (i > 0) result = result ++ ", ";
            result = result ++ col;
            if (camel and !std.mem.eql(u8, col, fields[i])) {
                result = result ++ " AS \"" ++ fields[i] ++ "\"";
            }
        }
        return result;
    }
}

fn comptimeSelectById(
    comptime table: []const u8,
    comptime sql_cols: []const []const u8,
    comptime fields: []const []const u8,
    comptime pk: []const u8,
    comptime camel: bool,
) []const u8 {
    return "SELECT " ++ comptimeColumnList(sql_cols, fields, camel) ++ " FROM " ++ table ++ " WHERE " ++ pk ++ " = ?";
}

fn comptimeSelectAll(
    comptime table: []const u8,
    comptime sql_cols: []const []const u8,
    comptime fields: []const []const u8,
    comptime camel: bool,
) []const u8 {
    return "SELECT " ++ comptimeColumnList(sql_cols, fields, camel) ++ " FROM " ++ table;
}

fn comptimeCount(comptime table: []const u8) []const u8 {
    return "SELECT COUNT(*) AS count FROM " ++ table;
}

fn comptimeSelectPage(
    comptime table: []const u8,
    comptime sql_cols: []const []const u8,
    comptime fields: []const []const u8,
    comptime camel: bool,
) []const u8 {
    return "SELECT " ++ comptimeColumnList(sql_cols, fields, camel) ++ " FROM " ++ table ++ " LIMIT ? OFFSET ?";
}

fn comptimeSkipInsertField(comptime fname: []const u8) bool {
    return std.mem.eql(u8, fname, "id") or
        std.mem.eql(u8, fname, "create_time") or
        std.mem.eql(u8, fname, "update_time") or
        std.mem.eql(u8, fname, "creator") or
        std.mem.eql(u8, fname, "updater") or
        std.mem.eql(u8, fname, "deleted");
}

fn comptimeInsertArgCount(comptime fields: []const []const u8) usize {
    @setEvalBranchQuota(100_000);
    comptime {
        var n: usize = 0;
        for (fields) |fname| {
            if (!comptimeSkipInsertField(fname)) n += 1;
        }
        return n;
    }
}

fn comptimeInsertArgCountUpsert(comptime fields: []const []const u8) usize {
    @setEvalBranchQuota(100_000);
    comptime {
        var n: usize = 0;
        for (fields) |fname| {
            if (!comptimeSkipUpsertField(fname)) n += 1;
        }
        return n;
    }
}

/// SQL columns actually written by INSERT (field order preserved, skipping
/// generated/audit fields like id/create_time).
fn comptimeInsertColumns(
    comptime sql_cols: []const []const u8,
    comptime fields: []const []const u8,
) []const []const u8 {
    comptime {
        var result: []const []const u8 = &.{};
        for (fields, 0..) |fname, i| {
            if (comptimeSkipInsertField(fname)) continue;
            result = result ++ &[_][]const u8{sql_cols[i]};
        }
        return result;
    }
}

/// Upsert writes the conflict key too (id), so ON CONFLICT can match; only
/// audit columns (create_time/update_time/creator/updater/deleted) are
/// skipped.
fn comptimeSkipUpsertField(comptime fname: []const u8) bool {
    return std.mem.eql(u8, fname, "create_time") or
        std.mem.eql(u8, fname, "update_time") or
        std.mem.eql(u8, fname, "creator") or
        std.mem.eql(u8, fname, "updater") or
        std.mem.eql(u8, fname, "deleted");
}

fn comptimeUpsertColumns(
    comptime sql_cols: []const []const u8,
    comptime fields: []const []const u8,
) []const []const u8 {
    comptime {
        var result: []const []const u8 = &.{};
        for (fields, 0..) |fname, i| {
            if (comptimeSkipUpsertField(fname)) continue;
            result = result ++ &[_][]const u8{sql_cols[i]};
        }
        return result;
    }
}

fn comptimeInsert(
    comptime table: []const u8,
    comptime sql_cols: []const []const u8,
    comptime fields: []const []const u8,
) []const u8 {
    comptime {
        var cols: []const u8 = "";
        var placeholders: []const u8 = "";
        var first = true;
        for (fields, 0..) |fname, i| {
            if (comptimeSkipInsertField(fname)) continue;
            if (!first) {
                cols = cols ++ ", ";
                placeholders = placeholders ++ ", ";
            }
            first = false;
            cols = cols ++ sql_cols[i];
            placeholders = placeholders ++ "?";
        }
        return "INSERT INTO " ++ table ++ " (" ++ cols ++ ") VALUES (" ++ placeholders ++ ")";
    }
}

fn comptimeUpdate(
    comptime table: []const u8,
    comptime sql_cols: []const []const u8,
    comptime pk: []const u8,
) []const u8 {
    comptime {
        var set_clause: []const u8 = "";
        var first = true;
        for (sql_cols) |col| {
            if (std.mem.eql(u8, col, pk)) continue;
            if (!first) set_clause = set_clause ++ ", ";
            first = false;
            set_clause = set_clause ++ col ++ " = ?";
        }
        return "UPDATE " ++ table ++ " SET " ++ set_clause ++ " WHERE " ++ pk ++ " = ?";
    }
}

fn comptimeDelete(comptime table: []const u8, comptime pk: []const u8) []const u8 {
    return "DELETE FROM " ++ table ++ " WHERE " ++ pk ++ " = ?";
}

fn appendColumnList(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, sql_cols: []const []const u8, fields: []const []const u8, camel: bool) !void {
    for (sql_cols, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, col);
        if (camel and !std.mem.eql(u8, col, fields[i])) {
            try buf.appendSlice(allocator, " AS \"");
            try buf.appendSlice(allocator, fields[i]);
            try buf.appendSlice(allocator, "\"");
        }
    }
}

fn buildSelectById(allocator: std.mem.Allocator, table: []const u8, sql_cols: []const []const u8, fields: []const []const u8, pk: []const u8, camel: bool) ![]u8 {
    var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "SELECT ");
    try appendColumnList(&buf, allocator, sql_cols, fields, camel);
    try buf.print(allocator, " FROM {s} WHERE {s} = ?", .{ table, pk });
    return allocator.dupe(u8, buf.items);
}

fn buildSelectAll(allocator: std.mem.Allocator, table: []const u8, sql_cols: []const []const u8, fields: []const []const u8, camel: bool) ![]u8 {
    var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "SELECT ");
    try appendColumnList(&buf, allocator, sql_cols, fields, camel);
    try buf.print(allocator, " FROM {s}", .{table});
    return allocator.dupe(u8, buf.items);
}

fn buildInsert(allocator: std.mem.Allocator, table: []const u8, sql_cols: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "INSERT INTO {s} (", .{table});
    for (sql_cols, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, col);
    }
    try buf.appendSlice(allocator, ") VALUES (");
    for (0..sql_cols.len) |i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, "?");
    }
    try buf.appendSlice(allocator, ")");
    return allocator.dupe(u8, buf.items);
}

fn buildUpdate(allocator: std.mem.Allocator, table: []const u8, sql_cols: []const []const u8, pk: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "UPDATE {s} SET ", .{table});
    var first = true;
    for (sql_cols) |col| {
        if (std.mem.eql(u8, col, pk)) continue;
        if (!first) try buf.appendSlice(allocator, ", ");
        first = false;
        try buf.print(allocator, "{s} = ?", .{col});
    }
    try buf.print(allocator, " WHERE {s} = ?", .{pk});
    return allocator.dupe(u8, buf.items);
}

fn buildSelectPage(allocator: std.mem.Allocator, table: []const u8, sql_cols: []const []const u8, fields: []const []const u8, page: usize, size: usize, camel: bool) ![]u8 {
    var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "SELECT ");
    try appendColumnList(&buf, allocator, sql_cols, fields, camel);
    const offset = if (page > 0) (page - 1) * size else 0;
    try buf.print(allocator, " FROM {s} LIMIT {d} OFFSET {d}", .{ table, size, offset });
    return allocator.dupe(u8, buf.items);
}

fn buildCount(allocator: std.mem.Allocator, table: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "SELECT COUNT(*) as count FROM {s}", .{table});
}

fn buildDelete(allocator: std.mem.Allocator, table: []const u8, pk: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "DELETE FROM {s} WHERE {s} = ?", .{ table, pk });
}

// ==================== Pagination ====================

pub fn PageResult(comptime T: type) type {
    return struct {
        items: []T,
        page: usize,
        size: usize,
        total: usize,
        total_page: usize,
        /// When set, owns string data (and items slice) via QueryResult arena transfer.
        /// Skips JSON serialization (contains comptime-only Allocator).
        arena: ?std.heap.ArenaAllocator = null,

        /// Returns true if there is a previous page.
        pub fn hasPrevious(self: *const @This()) bool {
            return self.page > 1;
        }

        /// Returns true if there is a next page.
        pub fn hasNext(self: *const @This()) bool {
            return self.page < self.total_page;
        }

        /// Custom JSON serialization: skips the internal `arena` field
        /// (which holds a comptime-only std.mem.Allocator) so `jsonStruct`
        /// works under Zig 0.17's stricter comptime checks.
        pub fn jsonStringify(self: *const @This(), jws: anytype) !void {
            try jws.beginObject();
            try jws.objectField("items");
            try jws.write(self.items);
            try jws.objectField("page");
            try jws.write(self.page);
            try jws.objectField("size");
            try jws.write(self.size);
            try jws.objectField("total");
            try jws.write(self.total);
            try jws.objectField("total_page");
            try jws.write(self.total_page);
            try jws.endObject();
        }

        /// Free owned memory (arena preferred; else per-string freeScanned).
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.arena) |*a| {
                a.deinit();
                self.arena = null;
                self.items = &.{};
                return;
            }
            for (self.items) |item| sqlx.freeScanned(allocator, T, item);
            allocator.free(self.items);
            self.items = &.{};
        }
    };
}

/// Transaction wrapper exposed to user callbacks
pub fn Tx(comptime B: type) type {
    return struct {
        backend: *B,
        tx: *B.Tx,

        pub fn exec(self: @This(), sql: []const u8, args: []const B.Value) !B.ExecResult {
            return self.backend.execTx(self.tx, sql, args);
        }

        pub fn queryRow(self: @This(), comptime T: type, sql: []const u8, args: []const B.Value) !?T {
            return self.backend.queryRowTx(self.tx, T, sql, args);
        }

        pub fn queryRows(self: @This(), comptime T: type, sql: []const u8, args: []const B.Value) !sqlx.QueryResult(T) {
            return self.backend.queryRowsTx(self.tx, T, sql, args);
        }
    };
}

/// Main ORM container parameterized by Backend type
pub fn Orm(comptime B: type) type {
    assertBackend(B);

    return struct {
        const Self = @This();
        backend: B,

        pub fn Repository(comptime T: type) type {
            const meta = Model(T);

            return struct {
                orm: *Self,

                pub fn findById(self: @This(), id: anytype) !?T {
                    const sql = comptime comptimeSelectById(meta.table_name, meta.sql_columns, meta.fields, meta.primary_key, meta.camel_case);
                    var args = [_]B.Value{B.fromOrmValue(toOrmValue(id))};
                    return self.orm.backend.queryRow(T, sql, &args);
                }

                /// Batch lookup: `WHERE pk IN (?,?,…)` in one round-trip.
                /// Result order follows the DB, not the input order.
                pub fn findByIds(self: @This(), allocator: std.mem.Allocator, ids: []const i64) !sqlx.QueryResult(T) {
                    if (ids.len == 0) return error.EmptyIds;
                    const cols = comptime comptimeColumnList(meta.sql_columns, meta.fields, meta.camel_case);
                    var buf = std.ArrayList(u8).empty;
                    defer buf.deinit(allocator);
                    try buf.appendSlice(allocator, "SELECT ");
                    try buf.appendSlice(allocator, cols);
                    try buf.appendSlice(allocator, " FROM ");
                    try buf.appendSlice(allocator, meta.table_name);
                    try buf.appendSlice(allocator, " WHERE ");
                    try buf.appendSlice(allocator, meta.primary_key);
                    try buf.appendSlice(allocator, " IN (");
                    for (0..ids.len) |i| {
                        if (i > 0) try buf.appendSlice(allocator, ",");
                        try buf.appendSlice(allocator, "?");
                    }
                    try buf.appendSlice(allocator, ")");
                    const args = try allocator.alloc(B.Value, ids.len);
                    defer allocator.free(args);
                    for (0..ids.len) |i| args[i] = B.fromOrmValue(toOrmValue(ids[i]));
                    return self.orm.backend.queryRows(T, buf.items, args);
                }

                pub fn findAll(self: @This()) !sqlx.QueryResult(T) {
                    const sql = comptime comptimeSelectAll(meta.table_name, meta.sql_columns, meta.fields, meta.camel_case);
                    return self.orm.backend.queryRows(T, sql, &.{});
                }

                pub fn count(self: @This()) !usize {
                    const sql = comptime comptimeCount(meta.table_name);
                    const result = try self.orm.backend.queryRow(struct { count: i64 }, sql, &.{});
                    return @intCast(result.?.count);
                }

                pub fn findPage(self: @This(), page: usize, size: usize) !PageResult(T) {
                    const sql = comptime comptimeSelectPage(meta.table_name, meta.sql_columns, meta.fields, meta.camel_case);
                    const offset: i64 = if (page > 0) @intCast((page - 1) * size) else 0;
                    var args = [_]B.Value{
                        B.fromOrmValue(.{ .int = @intCast(size) }),
                        B.fromOrmValue(.{ .int = offset }),
                    };
                    var result = try self.orm.backend.queryRows(T, sql, &args);
                    const owned = result.take();
                    const total = try self.count();
                    const total_page = if (size > 0) (total + size - 1) / size else 0;
                    return .{
                        .items = owned.items,
                        .arena = owned.arena,
                        .page = page,
                        .size = size,
                        .total = total,
                        .total_page = total_page,
                    };
                }

                /// Filtered pagination with custom WHERE clause and args.
                /// `where_sql` must not contain string literals/comments/`;` —
                /// pass values via `?` placeholders + `args` (see sqlx.validateSqlFragment).
                /// LIMIT/OFFSET are appended as bound parameters (portable across SQLite/PG/MySQL).
                pub fn findPageFiltered(self: @This(), alloc: std.mem.Allocator, where_sql: []const u8, args: []const B.Value, page: usize, size: usize) !PageResult(T) {
                    try sqlx.validateSqlFragment(where_sql);
                    const col_list = comptime comptimeColumnList(meta.sql_columns, meta.fields, meta.camel_case);

                    const count_sql = try std.fmt.allocPrint(alloc, "SELECT COUNT(*) AS count FROM {s} {s}", .{ meta.table_name, where_sql });
                    defer alloc.free(count_sql);
                    const count_row = try self.orm.backend.queryRow(struct { count: i64 }, count_sql, args);
                    const total: usize = if (count_row) |c| @intCast(c.count) else 0;

                    const offset: i64 = if (page > 0) @intCast((page - 1) * size) else 0;
                    const data_sql = try std.fmt.allocPrint(
                        alloc,
                        "SELECT {s} FROM {s} {s} ORDER BY {s} DESC LIMIT ? OFFSET ?",
                        .{ col_list, meta.table_name, where_sql, meta.primary_key },
                    );
                    defer alloc.free(data_sql);

                    const all_args = try alloc.alloc(B.Value, args.len + 2);
                    defer alloc.free(all_args);
                    if (args.len > 0) @memcpy(all_args[0..args.len], args);
                    all_args[args.len] = B.fromOrmValue(.{ .int = @intCast(size) });
                    all_args[args.len + 1] = B.fromOrmValue(.{ .int = offset });

                    var result = try self.orm.backend.queryRows(T, data_sql, all_args);
                    const owned = result.take();
                    const total_page = if (size > 0) (total + size - 1) / size else 0;
                    return .{
                        .items = owned.items,
                        .arena = owned.arena,
                        .page = page,
                        .size = size,
                        .total = total,
                        .total_page = total_page,
                    };
                }

                pub fn insert(self: @This(), entity: T) !T {
                    const sql = comptime comptimeInsert(meta.table_name, meta.sql_columns, meta.fields);
                    const n = comptime comptimeInsertArgCount(meta.fields);
                    var args: [n]B.Value = undefined;
                    var idx: usize = 0;
                    inline for (@typeInfo(T).@"struct".field_names) |fname| {
                        if (comptime comptimeSkipInsertField(fname)) continue;
                        args[idx] = fieldToBackendValue(B, @field(entity, fname));
                        idx += 1;
                    }
                    _ = try self.orm.backend.exec(sql, args[0..idx]);
                    return entity;
                }

                /// Multi-row INSERT in one round-trip (VALUES (?,?),(?,?)…).
                pub fn insertMany(self: @This(), allocator: std.mem.Allocator, entities: []const T) !void {
                    if (entities.len == 0) return;
                    const columns = comptime comptimeInsertColumns(meta.sql_columns, meta.fields);
                    const rows = try self.rowsFromEntities(allocator, entities);
                    defer {
                        for (rows) |r| allocator.free(r);
                        allocator.free(rows);
                    }
                    _ = try bulk.insertMany(allocator, self.orm.backend, meta.table_name, columns, rows, .sqlite, null);
                }

                /// Multi-row upsert (INSERT … ON CONFLICT DO UPDATE /
                /// ON DUPLICATE KEY UPDATE) in one round-trip. Requires a
                /// backend exposing `dialect()` (e.g. data.SqlxBackend).
                pub fn upsertMany(
                    self: @This(),
                    allocator: std.mem.Allocator,
                    entities: []const T,
                    conflict_columns: []const []const u8,
                ) !void {
                    if (entities.len == 0) return;
                    if (!@hasDecl(@TypeOf(self.orm.backend), "dialect")) {
                        @compileError("upsertMany requires a backend exposing dialect() (e.g. data.SqlxBackend)");
                    }
                    const columns = comptime comptimeUpsertColumns(meta.sql_columns, meta.fields);
                    const rows = try self.rowsFromEntitiesUpsert(allocator, entities);
                    defer {
                        for (rows) |r| allocator.free(r);
                        allocator.free(rows);
                    }
                    _ = try bulk.insertMany(
                        allocator,
                        self.orm.backend,
                        meta.table_name,
                        columns,
                        rows,
                        self.orm.backend.dialect(),
                        .{ .conflict_columns = conflict_columns },
                    );
                }

                /// Build one Value slice per entity (insert-column order).
                fn rowsFromEntities(self: @This(), allocator: std.mem.Allocator, entities: []const T) ![]const []const B.Value {
                    _ = self;
                    const n_cols = comptime comptimeInsertArgCount(meta.fields);
                    const rows = try allocator.alloc([]const B.Value, entities.len);
                    var filled: usize = 0;
                    errdefer {
                        for (rows[0..filled]) |r| allocator.free(r);
                        allocator.free(rows);
                    }
                    for (entities, 0..) |e, i| {
                        const row = try allocator.alloc(B.Value, n_cols);
                        var idx: usize = 0;
                        inline for (@typeInfo(T).@"struct".field_names) |fname| {
                            if (comptime comptimeSkipInsertField(fname)) continue;
                            row[idx] = fieldToBackendValue(B, @field(e, fname));
                            idx += 1;
                        }
                        rows[i] = row;
                        filled += 1;
                    }
                    return rows;
                }

                /// Like rowsFromEntities but keeps the conflict key (id) and
                /// only skips audit columns — order matches
                /// comptimeUpsertColumns.
                fn rowsFromEntitiesUpsert(self: @This(), allocator: std.mem.Allocator, entities: []const T) ![]const []const B.Value {
                    _ = self;
                    const n_cols = comptime comptimeInsertArgCountUpsert(meta.fields);
                    const rows = try allocator.alloc([]const B.Value, entities.len);
                    var filled: usize = 0;
                    errdefer {
                        for (rows[0..filled]) |r| allocator.free(r);
                        allocator.free(rows);
                    }
                    for (entities, 0..) |e, i| {
                        const row = try allocator.alloc(B.Value, n_cols);
                        var idx: usize = 0;
                        inline for (@typeInfo(T).@"struct".field_names) |fname| {
                            if (comptime comptimeSkipUpsertField(fname)) continue;
                            row[idx] = fieldToBackendValue(B, @field(e, fname));
                            idx += 1;
                        }
                        rows[i] = row;
                        filled += 1;
                    }
                    return rows;
                }

                pub fn update(self: @This(), entity: T) !void {
                    const sql = comptime comptimeUpdate(meta.table_name, meta.sql_columns, meta.primary_key);
                    const n = @typeInfo(T).@"struct".field_names.len;
                    var args: [n]B.Value = undefined;
                    var idx: usize = 0;
                    inline for (@typeInfo(T).@"struct".field_names) |fname| {
                        const is_pk = comptime std.mem.eql(u8, fname, meta.primary_key);
                        if (!is_pk) {
                            args[idx] = fieldToBackendValue(B, @field(entity, fname));
                            idx += 1;
                        }
                    }
                    args[idx] = fieldToBackendValue(B, @field(entity, meta.primary_key));
                    idx += 1;
                    _ = try self.orm.backend.exec(sql, args[0..idx]);
                }

                pub fn delete(self: @This(), id: anytype) !void {
                    const sql = comptime comptimeDelete(meta.table_name, meta.primary_key);
                    var args = [_]B.Value{B.fromOrmValue(toOrmValue(id))};
                    _ = try self.orm.backend.exec(sql, &args);
                }

                pub fn transact(self: @This(), comptime R: type, fn_tx: *const fn (*Tx(B)) anyerror!R) !R {
                    var tx = try self.orm.backend.beginTx();
                    errdefer self.orm.backend.rollbackTx(&tx) catch |err| std.log.warn("[Orm] tx rollback failed: {}", .{err});
                    var wrapper = Tx(B){ .backend = &self.orm.backend, .tx = &tx };
                    const result = try fn_tx(&wrapper);
                    try self.orm.backend.commitTx(&tx);
                    return result;
                }
            };
        }
    };
}

// ==================== Tests ====================

test "Model metadata extraction" {
    const User = struct {
        pub const sql_table_name: []const u8 = "users";
        id: i64,
        name: []const u8,
        email: []const u8,
    };

    const meta = Model(User);
    try std.testing.expectEqualStrings("users", meta.table_name);
    try std.testing.expectEqualStrings("id", meta.primary_key);
    try std.testing.expectEqual(@as(usize, 3), meta.fields.len);
}

test "Model table name defaults to type name without sql_table_name" {
    const Account = struct {
        id: i64,
    };
    const meta = Model(Account);
    try std.testing.expectEqualStrings("Account", meta.table_name);
}

test "SQL builders" {
    const allocator = std.testing.allocator;

    const fields = &.{ "id", "name", "email" };

    const select_id = try buildSelectById(allocator, "users", fields, fields, "id", false);
    defer allocator.free(select_id);
    try std.testing.expectEqualStrings("SELECT id, name, email FROM users WHERE id = ?", select_id);

    const select_all = try buildSelectAll(allocator, "users", fields, fields, false);
    defer allocator.free(select_all);
    try std.testing.expectEqualStrings("SELECT id, name, email FROM users", select_all);

    const insert = try buildInsert(allocator, "users", fields);
    defer allocator.free(insert);
    try std.testing.expectEqualStrings("INSERT INTO users (id, name, email) VALUES (?, ?, ?)", insert);

    const update = try buildUpdate(allocator, "users", fields, "id");
    defer allocator.free(update);
    try std.testing.expectEqualStrings("UPDATE users SET name = ?, email = ? WHERE id = ?", update);

    const del = try buildDelete(allocator, "users", "id");
    defer allocator.free(del);
    try std.testing.expectEqualStrings("DELETE FROM users WHERE id = ?", del);
}

test "Repository insertMany / upsertMany / findByIds end-to-end (sqlite)" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");

    const Product = struct {
        pub const sql_table_name: []const u8 = "bulk_product";
        id: i64,
        sku: []const u8,
        price_cents: i64,
    };

    var client = try data.Client.open(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    _ = try client.exec(
        "CREATE TABLE bulk_product (id INTEGER PRIMARY KEY, sku TEXT NOT NULL, price_cents INTEGER NOT NULL)",
        &.{},
    );
    const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
    var orm: data.orm.Orm(data.SqlxBackend) = undefined;
    orm.backend = backend;
    const Repo = data.Repository(Product);
    const repo = Repo{ .orm = &orm };

    // Multi-row insert in one round-trip.
    const products = [_]Product{
        .{ .id = 0, .sku = "SKU-1", .price_cents = 100 },
        .{ .id = 0, .sku = "SKU-2", .price_cents = 200 },
        .{ .id = 0, .sku = "SKU-3", .price_cents = 300 },
    };
    try repo.insertMany(allocator, &products);
    try std.testing.expectEqual(@as(usize, 3), try repo.count());

    // Batch lookup in one round-trip.
    var found = try repo.findByIds(allocator, &.{ @as(i64, 2), @as(i64, 1) });
    defer found.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), found.items.len);

    // Upsert: update SKU-2, insert SKU-4 (single statement).
    const upserts = [_]Product{
        .{ .id = 2, .sku = "SKU-2", .price_cents = 250 },
        .{ .id = 4, .sku = "SKU-4", .price_cents = 400 },
    };
    try repo.upsertMany(allocator, &upserts, &.{"id"});
    try std.testing.expectEqual(@as(usize, 4), try repo.count());

    const by_id = (try repo.findById(@as(i64, 2))).?;
    try std.testing.expectEqual(@as(i64, 250), by_id.price_cents);
    std.testing.allocator.free(by_id.sku);
}
