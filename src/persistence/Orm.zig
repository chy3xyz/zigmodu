//! Unified ORM layer with comptime Backend abstraction
//!
//! This ORM is designed to be backend-agnostic. The default implementation
//! uses sqlx (src/persistence/backends/SqlxBackend.zig), but any type
//! satisfying the Backend trait can be plugged in at compile time.

const std = @import("std");

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
    comptime var buf: [256]u8 = [_]u8{0} ** 256;
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
            for (info.@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, "id")) break :blk "id";
            }
            for (info.@"struct".fields) |field| {
                if (field.name.len > 3 and std.mem.endsWith(u8, field.name, "_id")) break :blk field.name;
            }
            break :blk info.@"struct".fields[0].name;
        };

        /// Struct field names (camelCase if model uses camelCase, otherwise snake_case)
        pub const fields = blk: {
            var names: []const []const u8 = &[_][]const u8{};
            for (info.@"struct".fields) |field| {
                names = names ++ .{field.name};
            }
            break :blk names;
        };

        /// SQL column names (always snake_case for camelCase models, otherwise same as fields)
        pub const sql_columns = if (camel) blk: {
            var names: []const []const u8 = &[_][]const u8{};
            for (info.@"struct".fields) |field| {
                names = names ++ .{camelToSnake(field.name)};
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
    const args = try allocator.alloc(B.Value, info.fields.len);
    errdefer allocator.free(args);
    inline for (info.fields, 0..) |field, i| {
        args[i] = fieldToBackendValue(B, @field(entity, field.name));
    }
    return args;
}

fn structToBackendArgsWithId(comptime B: type, comptime T: type, allocator: std.mem.Allocator, entity: T, comptime pk: []const u8) ![]B.Value {
    const info = @typeInfo(T).@"struct";
    const args = try allocator.alloc(B.Value, info.fields.len);
    errdefer allocator.free(args);
    var idx: usize = 0;
    inline for (info.fields) |field| {
        const is_pk = comptime std.mem.eql(u8, field.name, pk);
        if (!is_pk) {
            args[idx] = fieldToBackendValue(B, @field(entity, field.name));
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
    const offset = page * size;
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

        pub fn queryRows(self: @This(), comptime T: type, sql: []const u8, args: []const B.Value) ![]T {
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
                    const sql = try buildSelectById(self.orm.backend.allocator, meta.table_name, meta.sql_columns, meta.fields, meta.primary_key, meta.camel_case);
                    defer self.orm.backend.allocator.free(sql);
                    const args = try self.orm.backend.allocator.alloc(B.Value, 1);
                    defer self.orm.backend.allocator.free(args);
                    args[0] = B.fromOrmValue(toOrmValue(id));
                    return self.orm.backend.queryRow(T, sql, args);
                }

                pub fn findAll(self: @This()) ![]T {
                    const sql = try buildSelectAll(self.orm.backend.allocator, meta.table_name, meta.sql_columns, meta.fields, meta.camel_case);
                    defer self.orm.backend.allocator.free(sql);
                    return self.orm.backend.queryRows(T, sql, &.{});
                }

                pub fn count(self: @This()) !usize {
                    const sql = try buildCount(self.orm.backend.allocator, meta.table_name);
                    defer self.orm.backend.allocator.free(sql);
                    const result = try self.orm.backend.queryRow(struct { count: i64 }, sql, &.{});
                    return @intCast(result.?.count);
                }

                pub fn findPage(self: @This(), page: usize, size: usize) !PageResult(T) {
                    const sql = try buildSelectPage(self.orm.backend.allocator, meta.table_name, meta.sql_columns, meta.fields, page, size, meta.camel_case);
                    defer self.orm.backend.allocator.free(sql);
                    const items = try self.orm.backend.queryRows(T, sql, &.{});
                    const total = try self.count();
                    return .{ .items = items, .page = page, .size = size, .total = total };
                }

                /// Filtered pagination with custom WHERE clause and args.
                pub fn findPageFiltered(self: @This(), alloc: std.mem.Allocator, where_sql: []const u8, args: []const B.Value, page: usize, size: usize) !PageResult(T) {
                    const count_sql = try std.fmt.allocPrint(alloc, "SELECT COUNT(*) as count FROM {s} {s}", .{ meta.table_name, where_sql });
                    defer alloc.free(count_sql);
                    const count_row = try self.orm.backend.queryRow(struct { count: i64 }, count_sql, args);
                    const total: usize = if (count_row) |c| @intCast(c.count) else 0;

                    const offset = page * size;
                    const data_sql = try std.fmt.allocPrint(alloc, "SELECT * FROM {s} {s} ORDER BY {s} DESC LIMIT {d},{d}", .{ meta.table_name, where_sql, meta.primary_key, offset, size });
                    defer alloc.free(data_sql);
                    const items = try self.orm.backend.queryRows(T, data_sql, args);
                    return .{ .items = items, .page = page, .size = size, .total = total };
                }

                pub fn insert(self: @This(), entity: T) !T {
                    const sql = try buildInsert(self.orm.backend.allocator, meta.table_name, meta.sql_columns);
                    defer self.orm.backend.allocator.free(sql);
                    const args = try structToBackendArgs(B, T, self.orm.backend.allocator, entity);
                    defer self.orm.backend.allocator.free(args);
                    _ = try self.orm.backend.exec(sql, args);
                    return entity;
                }

                pub fn update(self: @This(), entity: T) !void {
                    const sql = try buildUpdate(self.orm.backend.allocator, meta.table_name, meta.sql_columns, meta.primary_key);
                    defer self.orm.backend.allocator.free(sql);
                    const args = try structToBackendArgsWithId(B, T, self.orm.backend.allocator, entity, meta.primary_key);
                    defer self.orm.backend.allocator.free(args);
                    _ = try self.orm.backend.exec(sql, args);
                }

                pub fn delete(self: @This(), id: anytype) !void {
                    const sql = try buildDelete(self.orm.backend.allocator, meta.table_name, meta.primary_key);
                    defer self.orm.backend.allocator.free(sql);
                    const args = try self.orm.backend.allocator.alloc(B.Value, 1);
                    defer self.orm.backend.allocator.free(args);
                    args[0] = B.fromOrmValue(toOrmValue(id));
                    _ = try self.orm.backend.exec(sql, args);
                }

                pub fn transact(self: @This(), comptime R: type, fn_tx: *const fn (*Tx(B)) anyerror!R) !R {
                    var tx = try self.orm.backend.beginTx();
                    errdefer self.orm.backend.rollbackTx(&tx) catch {};
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
