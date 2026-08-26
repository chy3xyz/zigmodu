//! Unified ORM layer with comptime Backend abstraction
//!
//! This ORM is designed to be backend-agnostic. The default implementation
//! uses sqlx (src/persistence/backends/SqlxBackend.zig), but any type
//! satisfying the Backend trait can be plugged in at compile time.

const std = @import("std");
const sqlx = @import("../sqlx/sqlx.zig");
const bulk = @import("../sqlx/Bulk.zig");
const Time = @import("../core/Time.zig");

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
    var buf: [256]u8 = @splat(0);
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
    const out: [idx]u8 = buf[0..idx].*;
    return out[0..];
}

/// Convert snake_case to camelCase at comptime.
/// e.g. "tenant_id" → "tenantId", "app_id" → "appId", "id" → "id"
pub fn snakeToCamel(comptime input: []const u8) []const u8 {
    @setEvalBranchQuota(2000);
    var buf: [256]u8 = @splat(0);
    var idx: usize = 0;
    var upper_next = false;
    for (input) |c| {
        if (c == '_') {
            upper_next = true;
        } else if (upper_next) {
            buf[idx] = if (c >= 'a' and c <= 'z') c - ('a' - 'A') else c;
            idx += 1;
            upper_next = false;
        } else {
            buf[idx] = c;
            idx += 1;
        }
    }
    const out: [idx]u8 = buf[0..idx].*;
    return out[0..];
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
    comptime soft_delete: bool,
) []const u8 {
    return "SELECT " ++ comptimeColumnList(sql_cols, fields, camel) ++ " FROM " ++ table ++ " WHERE " ++ pk ++ " = ?" ++ (if (soft_delete) " AND deleted = 0" else "");
}

fn comptimeSelectAll(
    comptime table: []const u8,
    comptime sql_cols: []const []const u8,
    comptime fields: []const []const u8,
    comptime camel: bool,
    comptime soft_delete: bool,
) []const u8 {
    return "SELECT " ++ comptimeColumnList(sql_cols, fields, camel) ++ " FROM " ++ table ++ (if (soft_delete) " WHERE deleted = 0" else "");
}

fn comptimeCount(comptime table: []const u8, comptime soft_delete: bool) []const u8 {
    return "SELECT COUNT(*) AS count FROM " ++ table ++ (if (soft_delete) " WHERE deleted = 0" else "");
}

fn comptimeSelectPage(
    comptime table: []const u8,
    comptime sql_cols: []const []const u8,
    comptime fields: []const []const u8,
    comptime camel: bool,
    comptime soft_delete: bool,
) []const u8 {
    return "SELECT " ++ comptimeColumnList(sql_cols, fields, camel) ++ " FROM " ++ table ++ (if (soft_delete) " WHERE deleted = 0" else "") ++ " LIMIT ? OFFSET ?";
}

fn comptimeSelectPageForTenant(
    comptime table: []const u8,
    comptime sql_cols: []const []const u8,
    comptime fields: []const []const u8,
    comptime camel: bool,
    comptime col: []const u8,
    comptime soft_delete: bool,
) []const u8 {
    return "SELECT " ++ comptimeColumnList(sql_cols, fields, camel) ++ " FROM " ++ table ++ " WHERE " ++ col ++ " = ?" ++ (if (soft_delete) " AND deleted = 0" else "") ++ " LIMIT ? OFFSET ?";
}

fn comptimeCountForTenant(comptime table: []const u8, comptime col: []const u8, comptime soft_delete: bool) []const u8 {
    return "SELECT COUNT(*) AS count FROM " ++ table ++ " WHERE " ++ col ++ " = ?" ++ (if (soft_delete) " AND deleted = 0" else "");
}

/// Tenant-scoped repository methods filter by `col` (a SQL column name, e.g.
/// `"tenant_id"` / `"app_id"`); fail at compile time when the model lacks the
/// tenant field instead of silently skipping the filter. `camel` models map
/// camelCase fields to snake_case columns, so the field name is derived.
fn comptimeRequireTenantField(comptime T: type, comptime col: []const u8, comptime camel: bool) void {
    const field = if (camel) snakeToCamel(col) else col;
    if (!@hasField(T, field)) {
        @compileError("tenant-scoped repository method called for model without field '" ++ field ++ "' (column '" ++ col ++ "') — add the tenant column to the model or use the non-tenant variant");
    }
}

/// Build `WHERE {col} = ?` (empty `where_sql`) or `{where_sql} AND {col} = ?`.
/// Caller owns the returned slice.
fn tenantClause(allocator: std.mem.Allocator, comptime col: []const u8, where_sql: []const u8) ![]const u8 {
    if (where_sql.len == 0) {
        return std.fmt.allocPrint(allocator, "WHERE {s} = ?", .{col});
    }
    return std.fmt.allocPrint(allocator, "{s} AND {s} = ?", .{ where_sql, col });
}

/// Runtime WHERE fragment for filtered reads: caller's `where_sql` plus
/// soft-delete. Returns an owned slice when the model has a `deleted` field
/// (caller frees); otherwise returns `where_sql` borrowed (no free).
fn effectiveWhere(allocator: std.mem.Allocator, comptime T: type, where_sql: []const u8) ![]const u8 {
    if (!@hasField(T, "deleted")) return where_sql;
    if (where_sql.len == 0) return try allocator.dupe(u8, "WHERE deleted = 0");
    return try std.fmt.allocPrint(allocator, "{s} AND deleted = 0", .{where_sql});
}

fn comptimeSkipInsertField(comptime fname: []const u8, comptime auto_ts: bool) bool {
    return std.mem.eql(u8, fname, "id") or
        std.mem.eql(u8, fname, "creator") or
        std.mem.eql(u8, fname, "updater") or
        std.mem.eql(u8, fname, "deleted") or
        ((std.mem.eql(u8, fname, "create_time") or std.mem.eql(u8, fname, "update_time")) and !auto_ts);
}

/// Whether a struct field's type is optional (`?T`). Compile-time only — the
/// undefined operand is never evaluated.
fn isNullableField(comptime T: type, comptime fname: []const u8) bool {
    const F = @TypeOf(@field(@as(T, undefined), fname));
    return @typeInfo(F) == .optional;
}

fn comptimeInsertArgCount(comptime fields: []const []const u8, comptime auto_ts: bool) usize {
    @setEvalBranchQuota(100_000);
    comptime {
        var n: usize = 0;
        for (fields) |fname| {
            if (!comptimeSkipInsertField(fname, auto_ts)) n += 1;
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
    comptime auto_ts: bool,
) []const []const u8 {
    comptime {
        var result: []const []const u8 = &.{};
        for (fields, 0..) |fname, i| {
            if (comptimeSkipInsertField(fname, auto_ts)) continue;
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
    comptime auto_ts: bool,
) []const u8 {
    comptime {
        var cols: []const u8 = "";
        var placeholders: []const u8 = "";
        var first = true;
        for (fields, 0..) |fname, i| {
            if (comptimeSkipInsertField(fname, auto_ts)) continue;
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

        /// Transactional tenant-scoped delete: `DELETE FROM {t} WHERE pk = ?
        /// AND {col} = ?`. Returns rows affected — 0 when the row belongs to
        /// another tenant (guarded no-op). `col` is the SQL tenant column
        /// name; compile-time error when the model lacks that field.
        pub fn deleteForTenant(self: @This(), comptime T: type, comptime col: []const u8, tenant_id: i64, id: anytype) !u64 {
            const meta = Model(T);
            comptime comptimeRequireTenantField(T, col, meta.camel_case);
            const sql = comptime comptimeDelete(meta.table_name, meta.primary_key) ++ " AND " ++ col ++ " = ?";
            var args = [_]B.Value{ B.fromOrmValue(toOrmValue(id)), B.fromOrmValue(.{ .int = tenant_id }) };
            const res = try self.exec(sql, &args);
            return res.rows_affected;
        }

        /// Transactional tenant-scoped update: `UPDATE {t} SET … WHERE pk = ?
        /// AND {col} = ?`. Returns rows affected — 0 when the row belongs to
        /// another tenant (guarded no-op).
        pub fn updateForTenant(self: @This(), comptime T: type, comptime col: []const u8, tenant_id: i64, entity: T) !u64 {
            const meta = Model(T);
            comptime comptimeRequireTenantField(T, col, meta.camel_case);
            const auto_ts = comptime @hasDecl(T, "sql_auto_timestamps") and T.sql_auto_timestamps;
            const sql = comptime comptimeUpdate(meta.table_name, meta.sql_columns, meta.primary_key) ++ " AND " ++ col ++ " = ?";
            const n = @typeInfo(T).@"struct".field_names.len;
            var args: [n + 1]B.Value = undefined;
            var idx: usize = 0;
            const now = Time.monotonicNowSeconds();
            inline for (@typeInfo(T).@"struct".field_names) |fname| {
                const is_pk = comptime std.mem.eql(u8, fname, meta.primary_key);
                if (!is_pk) {
                    if (auto_ts and std.mem.eql(u8, fname, "update_time")) {
                        args[idx] = B.fromOrmValue(.{ .int = now });
                    } else {
                        args[idx] = fieldToBackendValue(B, @field(entity, fname));
                    }
                    idx += 1;
                }
            }
            args[idx] = fieldToBackendValue(B, @field(entity, meta.primary_key));
            idx += 1;
            args[idx] = B.fromOrmValue(.{ .int = tenant_id });
            idx += 1;
            const res = try self.exec(sql, args[0..idx]);
            return res.rows_affected;
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
                    const sql = comptime comptimeSelectById(meta.table_name, meta.sql_columns, meta.fields, meta.primary_key, meta.camel_case, @hasField(T, "deleted"));
                    var args = [_]B.Value{B.fromOrmValue(toOrmValue(id))};
                    return self.orm.backend.queryRow(T, sql, &args);
                }

                /// Soft-delete escape hatch: like `findById` but WITHOUT the
                /// `AND deleted = 0` filter — returns soft-deleted rows too.
                /// Use for restore / audit queries; the normal read paths keep
                /// filtering automatically.
                pub fn findByIdIgnoringSoftDelete(self: @This(), id: anytype) !?T {
                    const sql = comptime comptimeSelectById(meta.table_name, meta.sql_columns, meta.fields, meta.primary_key, meta.camel_case, false);
                    var args = [_]B.Value{B.fromOrmValue(toOrmValue(id))};
                    return self.orm.backend.queryRow(T, sql, &args);
                }

                /// Tenant-scoped single lookup: `WHERE pk = ? AND {col} = ?`.
                /// `col` is the tenant column name; compile-time error when the
                /// model lacks that field.
                pub fn findByIdForTenant(self: @This(), comptime col: []const u8, tenant_id: i64, id: anytype) !?T {
                    comptime comptimeRequireTenantField(T, col, meta.camel_case);
                    const sql = comptime comptimeSelectById(meta.table_name, meta.sql_columns, meta.fields, meta.primary_key, meta.camel_case, @hasField(T, "deleted")) ++ " AND " ++ col ++ " = ?";
                    var args = [_]B.Value{ B.fromOrmValue(toOrmValue(id)), B.fromOrmValue(.{ .int = tenant_id }) };
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
                    if (@hasField(T, "deleted")) try buf.appendSlice(allocator, " AND deleted = 0");
                    const args = try allocator.alloc(B.Value, ids.len);
                    defer allocator.free(args);
                    for (0..ids.len) |i| args[i] = B.fromOrmValue(toOrmValue(ids[i]));
                    return self.orm.backend.queryRows(T, buf.items, args);
                }

                /// Tenant-scoped batch lookup: `WHERE pk IN (?,…) AND {col} = ?`.
                /// `col` is the tenant column name (`"tenant_id"` or `"app_id"`);
                /// compile-time error when the model lacks that field.
                pub fn findByIdsForTenant(self: @This(), comptime col: []const u8, allocator: std.mem.Allocator, tenant_id: i64, ids: []const i64) !sqlx.QueryResult(T) {
                    comptime comptimeRequireTenantField(T, col, meta.camel_case);
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
                    try buf.appendSlice(allocator, ") AND ");
                    try buf.appendSlice(allocator, col);
                    try buf.appendSlice(allocator, " = ?");
                    if (@hasField(T, "deleted")) try buf.appendSlice(allocator, " AND deleted = 0");
                    const args = try allocator.alloc(B.Value, ids.len + 1);
                    defer allocator.free(args);
                    for (0..ids.len) |i| args[i] = B.fromOrmValue(toOrmValue(ids[i]));
                    args[ids.len] = B.fromOrmValue(.{ .int = tenant_id });
                    return self.orm.backend.queryRows(T, buf.items, args);
                }

                pub fn findAll(self: @This()) !sqlx.QueryResult(T) {
                    const sql = comptime comptimeSelectAll(meta.table_name, meta.sql_columns, meta.fields, meta.camel_case, @hasField(T, "deleted"));
                    return self.orm.backend.queryRows(T, sql, &.{});
                }

                /// Soft-delete escape hatch: like `findAll` but WITHOUT the
                /// `WHERE deleted = 0` filter — includes soft-deleted rows.
                /// Use for restore / audit queries.
                pub fn findAllIncludingSoftDelete(self: @This()) !sqlx.QueryResult(T) {
                    const sql = comptime comptimeSelectAll(meta.table_name, meta.sql_columns, meta.fields, meta.camel_case, false);
                    return self.orm.backend.queryRows(T, sql, &.{});
                }

                /// Tenant-scoped full scan: `SELECT … FROM {t} WHERE {col} = ?`.
                pub fn findAllForTenant(self: @This(), comptime col: []const u8, tenant_id: i64) !sqlx.QueryResult(T) {
                    comptime comptimeRequireTenantField(T, col, meta.camel_case);
                    const sql = comptime comptimeSelectAll(meta.table_name, meta.sql_columns, meta.fields, meta.camel_case, @hasField(T, "deleted")) ++ " WHERE " ++ col ++ " = ?";
                    return self.orm.backend.queryRows(T, sql, &.{.{ .int = tenant_id }});
                }

                pub fn count(self: @This()) !usize {
                    const sql = comptime comptimeCount(meta.table_name, @hasField(T, "deleted"));
                    const result = try self.orm.backend.queryRow(struct { count: i64 }, sql, &.{});
                    return @intCast(result.?.count);
                }

                pub fn findPage(self: @This(), page: usize, size: usize) !PageResult(T) {
                    const sql = comptime comptimeSelectPage(meta.table_name, meta.sql_columns, meta.fields, meta.camel_case, @hasField(T, "deleted"));
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

                /// Tenant-scoped pagination: `SELECT … WHERE {col} = ? LIMIT ?
                /// OFFSET ?` plus a tenant-scoped COUNT for `total`. `col` is
                /// the tenant column name (`"tenant_id"` or `"app_id"`);
                /// compile-time error when the model lacks that field.
                pub fn findPageForTenant(self: @This(), comptime col: []const u8, tenant_id: i64, page: usize, size: usize) !PageResult(T) {
                    comptime comptimeRequireTenantField(T, col, meta.camel_case);
                    const sql = comptime comptimeSelectPageForTenant(meta.table_name, meta.sql_columns, meta.fields, meta.camel_case, col, @hasField(T, "deleted"));
                    const offset: i64 = if (page > 0) @intCast((page - 1) * size) else 0;
                    var args = [_]B.Value{
                        B.fromOrmValue(.{ .int = tenant_id }),
                        B.fromOrmValue(.{ .int = @intCast(size) }),
                        B.fromOrmValue(.{ .int = offset }),
                    };
                    var result = try self.orm.backend.queryRows(T, sql, &args);
                    const owned = result.take();
                    const total = try self.countForTenant(col, tenant_id);
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

                /// Tenant-scoped row count: `SELECT COUNT(*) FROM {t} WHERE {col} = ?`.
                pub fn countForTenant(self: @This(), comptime col: []const u8, tenant_id: i64) !usize {
                    comptime comptimeRequireTenantField(T, col, meta.camel_case);
                    const sql = comptime comptimeCountForTenant(meta.table_name, col, @hasField(T, "deleted"));
                    const result = try self.orm.backend.queryRow(struct { count: i64 }, sql, &.{.{ .int = tenant_id }});
                    return @intCast(result.?.count);
                }

                /// Filtered pagination with custom WHERE clause and args.
                /// `where_sql` must not contain string literals/comments/`;` —
                /// pass values via `?` placeholders + `args` (see sqlx.validateSqlFragment).
                /// LIMIT/OFFSET are appended as bound parameters (portable across SQLite/PG/MySQL).
                pub fn findPageFiltered(self: @This(), alloc: std.mem.Allocator, where_sql: []const u8, args: []const B.Value, page: usize, size: usize) !PageResult(T) {
                    try sqlx.validateSqlFragment(where_sql);
                    const col_list = comptime comptimeColumnList(meta.sql_columns, meta.fields, meta.camel_case);

                    const eff_where = try effectiveWhere(alloc, T, where_sql);
                    defer if (@hasField(T, "deleted")) alloc.free(eff_where);
                    const count_sql = try std.fmt.allocPrint(alloc, "SELECT COUNT(*) AS count FROM {s} {s}", .{ meta.table_name, eff_where });
                    defer alloc.free(count_sql);
                    const count_row = try self.orm.backend.queryRow(struct { count: i64 }, count_sql, args);
                    const total: usize = if (count_row) |c| @intCast(c.count) else 0;

                    const offset: i64 = if (page > 0) @intCast((page - 1) * size) else 0;
                    const data_sql = try std.fmt.allocPrint(
                        alloc,
                        "SELECT {s} FROM {s} {s} ORDER BY {s} DESC LIMIT ? OFFSET ?",
                        .{ col_list, meta.table_name, eff_where, meta.primary_key },
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

                /// Tenant-scoped filtered pagination: prepends `{col} = ?` to
                /// the WHERE clause (when `where_sql` is empty, filters only by
                /// tenant). Same `where_sql` contract as `findPageFiltered`
                /// (full `WHERE …` clause, may be empty; values via `?`
                /// placeholders + args). `col` is the tenant column name;
                /// compile-time error when the model lacks that field.
                pub fn findPageFilteredForTenant(self: @This(), comptime col: []const u8, alloc: std.mem.Allocator, tenant_id: i64, where_sql: []const u8, args: []const B.Value, page: usize, size: usize) !PageResult(T) {
                    comptime comptimeRequireTenantField(T, col, meta.camel_case);
                    try sqlx.validateSqlFragment(where_sql);
                    const col_list = comptime comptimeColumnList(meta.sql_columns, meta.fields, meta.camel_case);

                    const count_clause = try tenantClause(alloc, col, where_sql);
                    defer alloc.free(count_clause);
                    const eff_where = try effectiveWhere(alloc, T, count_clause);
                    defer if (@hasField(T, "deleted")) alloc.free(eff_where);
                    const count_sql = try std.fmt.allocPrint(alloc, "SELECT COUNT(*) AS count FROM {s} {s}", .{ meta.table_name, eff_where });
                    defer alloc.free(count_sql);
                    const count_args = try alloc.alloc(B.Value, args.len + 1);
                    defer alloc.free(count_args);
                    if (args.len > 0) @memcpy(count_args[0..args.len], args);
                    count_args[args.len] = B.fromOrmValue(.{ .int = tenant_id });
                    const count_row = try self.orm.backend.queryRow(struct { count: i64 }, count_sql, count_args);
                    const total: usize = if (count_row) |c| @intCast(c.count) else 0;

                    const offset: i64 = if (page > 0) @intCast((page - 1) * size) else 0;
                    const data_sql = try std.fmt.allocPrint(
                        alloc,
                        "SELECT {s} FROM {s} {s} ORDER BY {s} DESC LIMIT ? OFFSET ?",
                        .{ col_list, meta.table_name, eff_where, meta.primary_key },
                    );
                    defer alloc.free(data_sql);

                    const all_args = try alloc.alloc(B.Value, args.len + 3);
                    defer alloc.free(all_args);
                    if (args.len > 0) @memcpy(all_args[0..args.len], args);
                    all_args[args.len] = B.fromOrmValue(.{ .int = tenant_id });
                    all_args[args.len + 1] = B.fromOrmValue(.{ .int = @intCast(size) });
                    all_args[args.len + 2] = B.fromOrmValue(.{ .int = offset });

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

                /// Write the DB-generated primary key back into `e.id` after an
                /// INSERT. SQLite/MySQL populate `ExecResult.last_insert_id`;
                /// the Postgres driver leaves it null, so follow up with
                /// `SELECT lastval()` (safe: per-request session, this INSERT is
                /// the most recent sequence advance).
                fn writeBackInsertedId(self: @This(), e: *T, exec_result: anytype) !void {
                    if (exec_result.last_insert_id) |id| {
                        if (@hasField(T, "id")) e.id = id;
                        return;
                    }
                    if (!@hasField(T, "id")) return;
                    if (comptime @hasDecl(B, "dialect")) {
                        if (self.orm.backend.dialect() == .postgres) {
                            const Wrapper = struct { id: i64 };
                            const row = (try self.orm.backend.queryRow(Wrapper, "SELECT lastval() AS id", &.{})) orelse Wrapper{ .id = 0 };
                            if (row.id > 0) e.id = row.id;
                        }
                    }
                }

                pub fn insert(self: @This(), entity: T) !T {
                    const auto_ts = comptime @hasDecl(T, "sql_auto_timestamps") and T.sql_auto_timestamps;
                    var e = entity;
                    const sql = comptime comptimeInsert(meta.table_name, meta.sql_columns, meta.fields, auto_ts);
                    const n = comptime comptimeInsertArgCount(meta.fields, auto_ts);
                    var args: [n]B.Value = undefined;
                    var idx: usize = 0;
                    const now = Time.monotonicNowSeconds();
                    inline for (@typeInfo(T).@"struct".field_names) |fname| {
                        if (comptime comptimeSkipInsertField(fname, auto_ts)) continue;
                        if (auto_ts and (std.mem.eql(u8, fname, "create_time") or std.mem.eql(u8, fname, "update_time"))) {
                            args[idx] = B.fromOrmValue(.{ .int = now });
                        } else {
                            args[idx] = fieldToBackendValue(B, @field(e, fname));
                        }
                        idx += 1;
                    }
                    const exec_result = try self.orm.backend.exec(sql, args[0..idx]);
                    try self.writeBackInsertedId(&e, exec_result);
                    if (auto_ts) {
                        if (@hasField(T, "create_time")) e.create_time = now;
                        if (@hasField(T, "update_time")) e.update_time = now;
                    }
                    return e;
                }

                /// INSERT that omits columns whose value is null — letting the
                /// DB `DEFAULT` (if any) take over. Non-nullable fields are
                /// always written. This is opt-in: the default `insert` keeps
                /// writing explicit NULLs (full-coverage semantics).
                pub fn insertOmitNulls(self: @This(), allocator: std.mem.Allocator, entity: T) !T {
                    const auto_ts = comptime @hasDecl(T, "sql_auto_timestamps") and T.sql_auto_timestamps;
                    var e = entity;
                    var cols = std.ArrayList(u8).empty;
                    defer cols.deinit(allocator);
                    var vals = std.ArrayList(u8).empty;
                    defer vals.deinit(allocator);
                    var args = std.ArrayList(B.Value).empty;
                    defer args.deinit(allocator);
                    const now = Time.monotonicNowSeconds();
                    inline for (@typeInfo(T).@"struct".field_names, 0..) |fname, i| {
                        if (comptime comptimeSkipInsertField(fname, auto_ts)) continue;
                        const val = @field(e, fname);
                        const write_it = if (comptime isNullableField(T, fname)) val != null else true;
                        if (write_it) {
                            if (cols.items.len > 0) {
                                try cols.appendSlice(allocator, ", ");
                                try vals.appendSlice(allocator, ", ");
                            }
                            try cols.appendSlice(allocator, meta.sql_columns[i]);
                            try vals.appendSlice(allocator, "?");
                            if (auto_ts and (std.mem.eql(u8, fname, "create_time") or std.mem.eql(u8, fname, "update_time"))) {
                                try args.append(allocator, B.fromOrmValue(.{ .int = now }));
                            } else {
                                try args.append(allocator, fieldToBackendValue(B, val));
                            }
                        }
                    }
                    const sql = try std.fmt.allocPrint(allocator, "INSERT INTO {s} ({s}) VALUES ({s})", .{ meta.table_name, cols.items, vals.items });
                    defer allocator.free(sql);
                    const exec_result = try self.orm.backend.exec(sql, args.items);
                    try self.writeBackInsertedId(&e, exec_result);
                    if (auto_ts) {
                        if (@hasField(T, "create_time")) e.create_time = now;
                        if (@hasField(T, "update_time")) e.update_time = now;
                    }
                    return e;
                }

                /// Multi-row INSERT in one round-trip (VALUES (?,?),(?,?)…).
                pub fn insertMany(self: @This(), allocator: std.mem.Allocator, entities: []const T) !void {
                    if (entities.len == 0) return;
                    const columns = comptime comptimeInsertColumns(meta.sql_columns, meta.fields, false);
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
                    const n_cols = comptime comptimeInsertArgCount(meta.fields, false);
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
                            if (comptime comptimeSkipInsertField(fname, false)) continue;
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
                    const auto_ts = comptime @hasDecl(T, "sql_auto_timestamps") and T.sql_auto_timestamps;
                    const sql = comptime comptimeUpdate(meta.table_name, meta.sql_columns, meta.primary_key);
                    const n = @typeInfo(T).@"struct".field_names.len;
                    var args: [n]B.Value = undefined;
                    var idx: usize = 0;
                    const now = Time.monotonicNowSeconds();
                    inline for (@typeInfo(T).@"struct".field_names) |fname| {
                        const is_pk = comptime std.mem.eql(u8, fname, meta.primary_key);
                        if (!is_pk) {
                            if (auto_ts and std.mem.eql(u8, fname, "update_time")) {
                                args[idx] = B.fromOrmValue(.{ .int = now });
                            } else {
                                args[idx] = fieldToBackendValue(B, @field(entity, fname));
                            }
                            idx += 1;
                        }
                    }
                    args[idx] = fieldToBackendValue(B, @field(entity, meta.primary_key));
                    idx += 1;
                    _ = try self.orm.backend.exec(sql, args[0..idx]);
                }

                /// UPDATE returning rows affected — 0 means the primary key did
                /// not match any row (enables optimistic-lock / NotFound checks
                /// without a separate read). Mirrors `updateForTenant`.
                pub fn updateReturning(self: @This(), entity: T) !u64 {
                    const auto_ts = comptime @hasDecl(T, "sql_auto_timestamps") and T.sql_auto_timestamps;
                    const sql = comptime comptimeUpdate(meta.table_name, meta.sql_columns, meta.primary_key);
                    const n = @typeInfo(T).@"struct".field_names.len;
                    var args: [n]B.Value = undefined;
                    var idx: usize = 0;
                    const now = Time.monotonicNowSeconds();
                    inline for (@typeInfo(T).@"struct".field_names) |fname| {
                        const is_pk = comptime std.mem.eql(u8, fname, meta.primary_key);
                        if (!is_pk) {
                            if (auto_ts and std.mem.eql(u8, fname, "update_time")) {
                                args[idx] = B.fromOrmValue(.{ .int = now });
                            } else {
                                args[idx] = fieldToBackendValue(B, @field(entity, fname));
                            }
                            idx += 1;
                        }
                    }
                    args[idx] = fieldToBackendValue(B, @field(entity, meta.primary_key));
                    idx += 1;
                    const res = try self.orm.backend.exec(sql, args[0..idx]);
                    return res.rows_affected;
                }

                /// Partial UPDATE: only SET columns whose value is non-null —
                /// nullable fields left null keep their current DB value. The
                /// primary key is always used for the WHERE clause. Opt-in; the
                /// default `update` keeps full-coverage (null clears) semantics.
                pub fn updatePartial(self: @This(), allocator: std.mem.Allocator, entity: T) !void {
                    const auto_ts = comptime @hasDecl(T, "sql_auto_timestamps") and T.sql_auto_timestamps;
                    var set_clause = std.ArrayList(u8).empty;
                    defer set_clause.deinit(allocator);
                    var args = std.ArrayList(B.Value).empty;
                    defer args.deinit(allocator);
                    const now = Time.monotonicNowSeconds();
                    inline for (@typeInfo(T).@"struct".field_names, 0..) |fname, i| {
                        const is_pk = comptime std.mem.eql(u8, fname, meta.primary_key);
                        if (is_pk) continue;
                        const val = @field(entity, fname);
                        const write_it = if (comptime isNullableField(T, fname)) val != null else true;
                        if (write_it) {
                            if (set_clause.items.len > 0) try set_clause.appendSlice(allocator, ", ");
                            try set_clause.appendSlice(allocator, meta.sql_columns[i]);
                            try set_clause.appendSlice(allocator, " = ?");
                            if (auto_ts and std.mem.eql(u8, fname, "update_time")) {
                                try args.append(allocator, B.fromOrmValue(.{ .int = now }));
                            } else {
                                try args.append(allocator, fieldToBackendValue(B, val));
                            }
                        }
                    }
                    if (set_clause.items.len == 0) return; // nothing to update
                    try args.append(allocator, fieldToBackendValue(B, @field(entity, meta.primary_key)));
                    const sql = try std.fmt.allocPrint(allocator, "UPDATE {s} SET {s} WHERE {s} = ?", .{ meta.table_name, set_clause.items, meta.primary_key });
                    defer allocator.free(sql);
                    _ = try self.orm.backend.exec(sql, args.items);
                }

                /// Tenant-scoped update: `UPDATE {t} SET … WHERE pk = ? AND {col} = ?`.
                /// Returns rows affected — 0 when the row belongs to another
                /// tenant (guarded no-op), so callers can `if (== 0) return
                /// error.NotFound;` style-guard their migrations.
                pub fn updateForTenant(self: @This(), comptime col: []const u8, tenant_id: i64, entity: T) !u64 {
                    comptime comptimeRequireTenantField(T, col, meta.camel_case);
                    const auto_ts = comptime @hasDecl(T, "sql_auto_timestamps") and T.sql_auto_timestamps;
                    const sql = comptime comptimeUpdate(meta.table_name, meta.sql_columns, meta.primary_key) ++ " AND " ++ col ++ " = ?";
                    const n = @typeInfo(T).@"struct".field_names.len;
                    var args: [n + 1]B.Value = undefined;
                    var idx: usize = 0;
                    const now = Time.monotonicNowSeconds();
                    inline for (@typeInfo(T).@"struct".field_names) |fname| {
                        const is_pk = comptime std.mem.eql(u8, fname, meta.primary_key);
                        if (!is_pk) {
                            if (auto_ts and std.mem.eql(u8, fname, "update_time")) {
                                args[idx] = B.fromOrmValue(.{ .int = now });
                            } else {
                                args[idx] = fieldToBackendValue(B, @field(entity, fname));
                            }
                            idx += 1;
                        }
                    }
                    args[idx] = fieldToBackendValue(B, @field(entity, meta.primary_key));
                    idx += 1;
                    args[idx] = B.fromOrmValue(.{ .int = tenant_id });
                    idx += 1;
                    const res = try self.orm.backend.exec(sql, args[0..idx]);
                    return res.rows_affected;
                }

                pub fn delete(self: @This(), id: anytype) !void {
                    const sql = comptime comptimeDelete(meta.table_name, meta.primary_key);
                    var args = [_]B.Value{B.fromOrmValue(toOrmValue(id))};
                    _ = try self.orm.backend.exec(sql, &args);
                }

                /// DELETE returning rows affected — 0 means the primary key did
                /// not match any row. Mirrors `deleteForTenant`.
                pub fn deleteByIdReturning(self: @This(), id: anytype) !u64 {
                    const sql = comptime comptimeDelete(meta.table_name, meta.primary_key);
                    var args = [_]B.Value{B.fromOrmValue(toOrmValue(id))};
                    const res = try self.orm.backend.exec(sql, &args);
                    return res.rows_affected;
                }

                /// Tenant-scoped delete: `DELETE FROM {t} WHERE pk = ? AND {col} = ?`.
                /// Returns rows affected — 0 when the row belongs to another
                /// tenant (guarded no-op).
                pub fn deleteForTenant(self: @This(), comptime col: []const u8, tenant_id: i64, id: anytype) !u64 {
                    comptime comptimeRequireTenantField(T, col, meta.camel_case);
                    const sql = comptime comptimeDelete(meta.table_name, meta.primary_key) ++ " AND " ++ col ++ " = ?";
                    var args = [_]B.Value{ B.fromOrmValue(toOrmValue(id)), B.fromOrmValue(.{ .int = tenant_id }) };
                    const res = try self.orm.backend.exec(sql, &args);
                    return res.rows_affected;
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

test "Repository insertOmitNulls lets DB DEFAULT take over (sqlite)" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");

    const NullableRow = struct {
        pub const sql_table_name: []const u8 = "nullable_row";
        id: i64,
        name: ?[]const u8,
        note: ?[]const u8,
    };

    var client = try data.Client.open(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    _ = try client.exec("CREATE TABLE nullable_row (id INTEGER PRIMARY KEY, name TEXT DEFAULT 'anon', note TEXT)", &.{});
    _ = try client.exec("INSERT INTO nullable_row (id, name, note) VALUES (1, 'orig', 'n1')", &.{});

    const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
    var orm: data.orm.Orm(data.SqlxBackend) = undefined;
    orm.backend = backend;
    const Repo = data.Repository(NullableRow);
    const repo = Repo{ .orm = &orm };

    // insertOmitNulls: name=null → column omitted → DB DEFAULT 'anon' applies.
    const e = NullableRow{ .id = 2, .name = null, .note = "n2" };
    _ = try repo.insertOmitNulls(allocator, e);
    const got = (try repo.findById(@as(i64, 2))).?;
    defer {
        if (got.name) |s| allocator.free(s);
        if (got.note) |s| allocator.free(s);
    }
    try std.testing.expectEqualStrings("anon", got.name.?);
    try std.testing.expectEqualStrings("n2", got.note.?);

    // updatePartial: note=null → name kept at current value; note stays.
    const e2 = NullableRow{ .id = 2, .name = null, .note = "updated" };
    try repo.updatePartial(allocator, e2);
    const got2 = (try repo.findById(@as(i64, 2))).?;
    defer {
        if (got2.name) |s| allocator.free(s);
        if (got2.note) |s| allocator.free(s);
    }
    try std.testing.expectEqualStrings("anon", got2.name.?); // untouched
    try std.testing.expectEqualStrings("updated", got2.note.?);
}

test "Repository insert writes back DB-generated id (sqlite)" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");

    const AutoRow = struct {
        pub const sql_table_name: []const u8 = "auto_row";
        id: i64,
        name: []const u8,
    };

    var client = try data.Client.open(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    _ = try client.exec("CREATE TABLE auto_row (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)", &.{});

    const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
    var orm: data.orm.Orm(data.SqlxBackend) = undefined;
    orm.backend = backend;
    const Repo = data.Repository(AutoRow);
    const repo = Repo{ .orm = &orm };

    const inserted = try repo.insert(.{ .id = 0, .name = "a" });
    try std.testing.expect(inserted.id > 0); // last_insert_id written back
    const got = (try repo.findById(inserted.id)).?;
    defer allocator.free(got.name);
    try std.testing.expectEqualStrings("a", got.name);

    const inserted2 = try repo.insertOmitNulls(allocator, .{ .id = 0, .name = "b" });
    try std.testing.expect(inserted2.id > inserted.id);
}

test "Repository tenant-scoped methods filter by tenant column (sqlite)" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");

    const TenantProduct = struct {
        pub const sql_table_name: []const u8 = "tenant_product";
        id: i64,
        sku: []const u8,
        price_cents: i64,
        tenant_id: i64,
    };

    var client = try data.Client.open(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    _ = try client.exec(
        "CREATE TABLE tenant_product (id INTEGER PRIMARY KEY, sku TEXT NOT NULL, price_cents INTEGER NOT NULL, tenant_id INTEGER NOT NULL)",
        &.{},
    );
    const rows = [_]struct { id: i64, sku: []const u8, price: i64, tenant: i64 }{
        .{ .id = 1, .sku = "T1-A", .price = 100, .tenant = 1 },
        .{ .id = 2, .sku = "T1-B", .price = 200, .tenant = 1 },
        .{ .id = 3, .sku = "T2-A", .price = 100, .tenant = 2 },
        .{ .id = 4, .sku = "T2-B", .price = 200, .tenant = 2 },
    };
    for (rows) |r| {
        _ = try client.exec(
            "INSERT INTO tenant_product (id, sku, price_cents, tenant_id) VALUES (?1, ?2, ?3, ?4)",
            &.{ .{ .int = r.id }, .{ .string = r.sku }, .{ .int = r.price }, .{ .int = r.tenant } },
        );
    }

    const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
    var orm: data.orm.Orm(data.SqlxBackend) = undefined;
    orm.backend = backend;
    const Repo = data.Repository(TenantProduct);
    const repo = Repo{ .orm = &orm };

    // findPageForTenant: rows and total are tenant-scoped.
    var page = try repo.findPageForTenant("tenant_id", 1, 1, 10);
    defer if (page.arena) |*a| a.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqual(@as(usize, 2), page.total);

    // countForTenant.
    try std.testing.expectEqual(@as(usize, 2), try repo.countForTenant("tenant_id", 1));
    try std.testing.expectEqual(@as(usize, 2), try repo.countForTenant("tenant_id", 2));

    // findByIdsForTenant: ids from other tenants are not returned.
    var found = try repo.findByIdsForTenant("tenant_id", allocator, 1, &.{ @as(i64, 1), @as(i64, 3) });
    defer found.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(i64, 1), found.items[0].id);

    // findPageFilteredForTenant: WHERE + tenant combine.
    var filtered = try repo.findPageFilteredForTenant("tenant_id", allocator, 1, "WHERE price_cents > ?", &.{.{ .int = 100 }}, 1, 10);
    defer if (filtered.arena) |*a| a.deinit();
    try std.testing.expectEqual(@as(usize, 1), filtered.items.len);
    try std.testing.expectEqualStrings("T1-B", filtered.items[0].sku);
    try std.testing.expectEqual(@as(usize, 1), filtered.total);
}

test "Repository tenant methods work with camelCase models" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");

    // camelCase field `tenantId` maps to snake_case column `tenant_id`.
    const CamelProduct = struct {
        pub const sql_table_name: []const u8 = "camel_product";
        pub const sql_column_style = .camelCase;
        id: i64,
        sku: []const u8,
        tenantId: i64,
    };

    var client = try data.Client.open(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    _ = try client.exec(
        "CREATE TABLE camel_product (id INTEGER PRIMARY KEY, sku TEXT NOT NULL, tenant_id INTEGER NOT NULL)",
        &.{},
    );
    const rows = [_]struct { id: i64, sku: []const u8, tenant: i64 }{
        .{ .id = 1, .sku = "C-T1", .tenant = 1 },
        .{ .id = 2, .sku = "C-T2", .tenant = 2 },
    };
    for (rows) |r| {
        _ = try client.exec(
            "INSERT INTO camel_product (id, sku, tenant_id) VALUES (?1, ?2, ?3)",
            &.{ .{ .int = r.id }, .{ .string = r.sku }, .{ .int = r.tenant } },
        );
    }

    const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
    var orm: data.orm.Orm(data.SqlxBackend) = undefined;
    orm.backend = backend;
    const Repo = data.Repository(CamelProduct);
    const repo = Repo{ .orm = &orm };

    // `col` is the SQL column name; the field check derives `tenantId`.
    var page = try repo.findPageForTenant("tenant_id", 1, 1, 10);
    defer if (page.arena) |*a| a.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("C-T1", page.items[0].sku);
    try std.testing.expectEqual(@as(usize, 1), page.total);

    try std.testing.expectEqual(@as(usize, 1), try repo.countForTenant("tenant_id", 1));

    var found = try repo.findByIdsForTenant("tenant_id", allocator, 1, &.{ @as(i64, 1), @as(i64, 2) });
    defer found.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(i64, 1), found.items[0].id);

    // findByIdForTenant: row belongs to tenant 1; tenant 2 must not see it.
    const by_id = (try repo.findByIdForTenant("tenant_id", 1, @as(i64, 1))).?;
    try std.testing.expectEqualStrings("C-T1", by_id.sku);
    allocator.free(by_id.sku);
    try std.testing.expect((try repo.findByIdForTenant("tenant_id", 2, @as(i64, 1))) == null);

    // findAllForTenant: only that tenant's rows.
    var all = try repo.findAllForTenant("tenant_id", 2);
    defer all.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), all.items.len);
    try std.testing.expectEqualStrings("C-T2", all.items[0].sku);

    // updateForTenant: cross-tenant update must not touch the row (0 rows).
    try std.testing.expectEqual(@as(u64, 0), try repo.updateForTenant("tenant_id", 1, .{ .id = 2, .sku = "HACK", .tenantId = 1 }));
    const row2 = (try repo.findByIdForTenant("tenant_id", 2, @as(i64, 2))).?;
    try std.testing.expectEqualStrings("C-T2", row2.sku);
    allocator.free(row2.sku);
    // In-tenant update applies (1 row).
    try std.testing.expectEqual(@as(u64, 1), try repo.updateForTenant("tenant_id", 2, .{ .id = 2, .sku = "C-T2b", .tenantId = 2 }));
    const row2b = (try repo.findByIdForTenant("tenant_id", 2, @as(i64, 2))).?;
    try std.testing.expectEqualStrings("C-T2b", row2b.sku);
    allocator.free(row2b.sku);

    // deleteForTenant: cross-tenant delete is a guarded no-op (0 rows)…
    try std.testing.expectEqual(@as(u64, 0), try repo.deleteForTenant("tenant_id", 1, @as(i64, 2)));
    const still = try repo.findByIdForTenant("tenant_id", 2, @as(i64, 2));
    try std.testing.expect(still != null);
    if (still) |s| allocator.free(s.sku);
    // …in-tenant delete removes it (1 row).
    try std.testing.expectEqual(@as(u64, 1), try repo.deleteForTenant("tenant_id", 2, @as(i64, 2)));
    try std.testing.expect((try repo.findByIdForTenant("tenant_id", 2, @as(i64, 2))) == null);

    // Transactional variants keep the same guard semantics inside a tx.
    try repo.transact(void, struct {
        fn f(tx: *data.orm.Tx(data.SqlxBackend)) anyerror!void {
            // cross-tenant delete in tx → 0 rows.
            try std.testing.expectEqual(@as(u64, 0), try tx.deleteForTenant(CamelProduct, "tenant_id", 2, @as(i64, 1)));
            // in-tenant update in tx → 1 row.
            try std.testing.expectEqual(@as(u64, 1), try tx.updateForTenant(CamelProduct, "tenant_id", 1, .{ .id = 1, .sku = "C-T1x", .tenantId = 1 }));
        }
    }.f);
    const updated = (try repo.findByIdForTenant("tenant_id", 1, @as(i64, 1))).?;
    try std.testing.expectEqualStrings("C-T1x", updated.sku);
    allocator.free(updated.sku);
}

test "Repository soft-delete filters deleted rows from reads" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");

    // Model with a `deleted` audit column → reads append AND deleted = 0.
    const SoftTask = struct {
        pub const sql_table_name: []const u8 = "soft_task";
        id: i64,
        title: []const u8,
        deleted: i64,
    };

    var client = try data.Client.open(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    _ = try client.exec(
        "CREATE TABLE soft_task (id INTEGER PRIMARY KEY, title TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0)",
        &.{},
    );
    const rows = [_]struct { id: i64, title: []const u8, deleted: i64 }{
        .{ .id = 1, .title = "live-1", .deleted = 0 },
        .{ .id = 2, .title = "gone-2", .deleted = 1 },
        .{ .id = 3, .title = "live-3", .deleted = 0 },
    };
    for (rows) |r| {
        _ = try client.exec(
            "INSERT INTO soft_task (id, title, deleted) VALUES (?1, ?2, ?3)",
            &.{ .{ .int = r.id }, .{ .string = r.title }, .{ .int = r.deleted } },
        );
    }

    const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
    var orm: data.orm.Orm(data.SqlxBackend) = undefined;
    orm.backend = backend;
    const Repo = data.Repository(SoftTask);
    const repo = Repo{ .orm = &orm };

    // findById skips soft-deleted rows.
    try std.testing.expect((try repo.findById(@as(i64, 2))) == null);
    const live = (try repo.findById(@as(i64, 1))).?;
    try std.testing.expectEqualStrings("live-1", live.title);
    allocator.free(live.title);

    // findByIds / findAll / count all exclude deleted.
    var by_ids = try repo.findByIds(allocator, &.{ @as(i64, 1), @as(i64, 2), @as(i64, 3) });
    defer by_ids.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), by_ids.items.len);

    var all = try repo.findAll();
    defer all.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), all.items.len);
    try std.testing.expectEqual(@as(usize, 2), try repo.count());

    // findPage / findPageFiltered exclude deleted.
    var page = try repo.findPage(1, 10);
    defer if (page.arena) |*a| a.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqual(@as(usize, 2), page.total);

    // Soft-delete escape hatches see deleted rows (restore / audit path).
    const gone = (try repo.findByIdIgnoringSoftDelete(@as(i64, 2))).?;
    try std.testing.expectEqualStrings("gone-2", gone.title);
    allocator.free(gone.title);
    var all_incl = try repo.findAllIncludingSoftDelete();
    defer all_incl.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), all_incl.items.len);

    var filtered = try repo.findPageFiltered(allocator, "WHERE id > ?", &.{.{ .int = 0 }}, 1, 10);
    defer if (filtered.arena) |*a| a.deinit();
    try std.testing.expectEqual(@as(usize, 2), filtered.items.len);
    try std.testing.expectEqual(@as(usize, 2), filtered.total);

    // Tenant variant also filters deleted (model has tenant field here).
    const SoftTenant = struct {
        pub const sql_table_name: []const u8 = "soft_tenant";
        id: i64,
        title: []const u8,
        deleted: i64,
        tenant_id: i64,
    };
    _ = try client.exec(
        "CREATE TABLE soft_tenant (id INTEGER PRIMARY KEY, title TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, tenant_id INTEGER NOT NULL)",
        &.{},
    );
    for (rows) |r| {
        _ = try client.exec(
            "INSERT INTO soft_tenant (id, title, deleted, tenant_id) VALUES (?1, ?2, ?3, ?4)",
            &.{ .{ .int = r.id }, .{ .string = r.title }, .{ .int = r.deleted }, .{ .int = 7 } },
        );
    }
    const RepoT = data.Repository(SoftTenant);
    const repoT = RepoT{ .orm = &orm };
    var tpage = try repoT.findPageForTenant("tenant_id", 7, 1, 10);
    defer if (tpage.arena) |*a| a.deinit();
    try std.testing.expectEqual(@as(usize, 2), tpage.items.len);
    try std.testing.expectEqual(@as(usize, 2), tpage.total);
    try std.testing.expectEqual(@as(usize, 2), try repoT.countForTenant("tenant_id", 7));
    try std.testing.expect((try repoT.findByIdForTenant("tenant_id", 7, @as(i64, 2))) == null);
}

test "Repository soft-delete opt-out: models without deleted are unaffected" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");

    const Plain = struct {
        pub const sql_table_name: []const u8 = "plain_row";
        id: i64,
        title: []const u8,
    };

    var client = try data.Client.open(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    _ = try client.exec("CREATE TABLE plain_row (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", &.{});
    _ = try client.exec("INSERT INTO plain_row (id, title) VALUES (?1, ?2)", &.{ .{ .int = 1 }, .{ .string = "x" } });

    const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
    var orm: data.orm.Orm(data.SqlxBackend) = undefined;
    orm.backend = backend;
    const repo = data.Repository(Plain){ .orm = &orm };

    try std.testing.expectEqual(@as(usize, 1), try repo.count());
    const all = try repo.findAll();
    defer all.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), all.items.len);
}

test "Repository auto timestamps fill create_time/update_time (opt-in)" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");

    const Audited = struct {
        pub const sql_table_name: []const u8 = "audited_row";
        pub const sql_auto_timestamps = true;
        id: i64,
        title: []const u8,
        create_time: i64,
        update_time: i64,
    };

    var client = try data.Client.open(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    _ = try client.exec(
        "CREATE TABLE audited_row (id INTEGER PRIMARY KEY, title TEXT NOT NULL, create_time INTEGER NOT NULL DEFAULT 0, update_time INTEGER NOT NULL DEFAULT 0)",
        &.{},
    );

    const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
    var orm: data.orm.Orm(data.SqlxBackend) = undefined;
    orm.backend = backend;
    const Repo = data.Repository(Audited);
    const repo = Repo{ .orm = &orm };

    // insert fills create_time/update_time from the clock.
    const inserted = try repo.insert(.{ .id = 1, .title = "a", .create_time = 0, .update_time = 0 });
    try std.testing.expect(inserted.create_time > 0);
    try std.testing.expect(inserted.update_time > 0);
    try std.testing.expectEqual(inserted.create_time, inserted.update_time);

    const after_insert = (try repo.findById(@as(i64, 1))).?;
    try std.testing.expect(after_insert.create_time > 0);
    try std.testing.expectEqual(after_insert.create_time, after_insert.update_time);
    allocator.free(after_insert.title);

    // update refreshes update_time only; create_time stays.
    const orig_create = inserted.create_time;
    try repo.update(.{ .id = 1, .title = "a2", .create_time = orig_create, .update_time = 0 });
    const after_update = (try repo.findById(@as(i64, 1))).?;
    try std.testing.expect(after_update.update_time >= after_update.create_time);
    try std.testing.expectEqual(orig_create, after_update.create_time);
    allocator.free(after_update.title);
}
