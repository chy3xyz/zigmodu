//! Bulk write helpers - multi-row INSERT and dialect-aware upsert.
//!
//! Pure SQL builders + argument flatteners; execution is delegated to any
//! object exposing `exec(sql, args)` (`sqlx.Client`, `sqlx.Transaction`,
//! `SqlxBackend`), so both raw-sqlx code (zigshop's N-round-trip order items)
//! and Repository code reuse the same generator.
//!
//! ```zig
//! const bulk = zigmodu.data.bulk;
//! const rows = [_][]const sqlx.Value{
//!     &.{ .{ .int = 1 }, .{ .string = "a" } },
//!     &.{ .{ .int = 2 }, .{ .string = "b" } },
//! };
//! _ = try bulk.insertMany(alloc, &client, "t", &.{ "id", "name" }, &rows, .sqlite, .{
//!     .conflict_columns = &.{"id"},
//! });
//! ```
//!
//! SECURITY: table/column names are trusted schema identifiers (never user
//! input); values always go through `?` placeholders.

const std = @import("std");
const sqlx = @import("sqlx.zig");

/// Dialect used for the upsert suffix. Reuses `sqlx.Driver` values so callers
/// can pass `client.config.driver` directly.
pub const Dialect = sqlx.Driver;

pub const UpsertOpts = struct {
    /// Conflict columns (ON CONFLICT (...) / implicit unique key on MySQL).
    conflict_columns: []const []const u8 = &.{"id"},
    /// Columns updated on conflict; null means every column except the
    /// conflict columns (keeps generated/id columns out of the SET list).
    update_columns: ?[]const []const u8 = null,
};

/// Build `INSERT INTO t (c1,c2) VALUES (?,?),(?,?) [ON CONFLICT ...]`.
/// Caller frees the returned slice.
pub fn buildInsertMany(
    allocator: std.mem.Allocator,
    table: []const u8,
    columns: []const []const u8,
    row_count: usize,
    dialect: Dialect,
    upsert: ?UpsertOpts,
) ![]u8 {
    if (row_count == 0) return error.EmptyRows;
    if (columns.len == 0) return error.EmptyColumns;
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "INSERT INTO ");
    try buf.appendSlice(allocator, table);
    try buf.appendSlice(allocator, " (");
    for (columns, 0..) |c, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, c);
    }
    try buf.appendSlice(allocator, ") VALUES ");
    for (0..row_count) |r| {
        if (r > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "(");
        for (0..columns.len) |i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "?");
        }
        try buf.appendSlice(allocator, ")");
    }

    if (upsert) |u| {
        try appendUpsertSuffix(allocator, &buf, columns, dialect, u);
    }
    return buf.toOwnedSlice(allocator);
}

fn appendUpsertSuffix(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    columns: []const []const u8,
    dialect: Dialect,
    opts: UpsertOpts,
) !void {
    const update_cols = opts.update_columns orelse try nonConflictColumns(allocator, columns, opts.conflict_columns);
    defer if (opts.update_columns == null) allocator.free(update_cols);
    if (update_cols.len == 0) return error.EmptyUpsertColumns;

    switch (dialect) {
        .mysql => {
            try buf.appendSlice(allocator, " ON DUPLICATE KEY UPDATE ");
            for (update_cols, 0..) |c, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, c);
                try buf.appendSlice(allocator, "=VALUES(");
                try buf.appendSlice(allocator, c);
                try buf.appendSlice(allocator, ")");
            }
        },
        else => {
            // SQLite / PostgreSQL: ON CONFLICT ("id") DO UPDATE SET
            // "c"=excluded."c" (double-quoted identifiers are valid in both).
            try buf.appendSlice(allocator, " ON CONFLICT (");
            for (opts.conflict_columns, 0..) |c, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, "\"");
                try buf.appendSlice(allocator, c);
                try buf.appendSlice(allocator, "\"");
            }
            try buf.appendSlice(allocator, ") DO UPDATE SET ");
            for (update_cols, 0..) |c, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, "\"");
                try buf.appendSlice(allocator, c);
                try buf.appendSlice(allocator, "\"=excluded.\"");
                try buf.appendSlice(allocator, c);
                try buf.appendSlice(allocator, "\"");
            }
        },
    }
}

/// columns minus conflict columns (order preserved).
fn nonConflictColumns(
    allocator: std.mem.Allocator,
    columns: []const []const u8,
    conflict: []const []const u8,
) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    for (columns) |c| {
        var is_conflict = false;
        for (conflict) |cc| {
            if (std.mem.eql(u8, c, cc)) {
                is_conflict = true;
                break;
            }
        }
        if (!is_conflict) try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

/// Flatten `rows` (one Value slice per row) into one contiguous arg array.
pub fn flattenArgs(
    allocator: std.mem.Allocator,
    rows: []const []const sqlx.Value,
) ![]sqlx.Value {
    var total: usize = 0;
    for (rows) |r| total += r.len;
    const out = try allocator.alloc(sqlx.Value, total);
    var idx: usize = 0;
    for (rows) |r| {
        for (r) |v| {
            out[idx] = v;
            idx += 1;
        }
    }
    return out;
}

/// One-shot helper: build the SQL, flatten the args, run `exec`.
/// `exec` must expose `exec(sql: []const u8, args: []const Value) !ExecResult`
/// (Client, Transaction, SqlxBackend all qualify).
pub fn insertMany(
    allocator: std.mem.Allocator,
    exec: anytype,
    table: []const u8,
    columns: []const []const u8,
    rows: []const []const sqlx.Value,
    dialect: Dialect,
    upsert: ?UpsertOpts,
) !sqlx.ExecResult {
    for (rows) |r| {
        if (r.len != columns.len) return error.ColumnCountMismatch;
    }
    const sql = try buildInsertMany(allocator, table, columns, rows.len, dialect, upsert);
    defer allocator.free(sql);
    const args = try flattenArgs(allocator, rows);
    defer allocator.free(args);
    return exec.exec(sql, args);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

test "buildInsertMany plain multi-row SQL" {
    const sql = try buildInsertMany(testing.allocator, "t", &.{ "a", "b" }, 3, .sqlite, null);
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("INSERT INTO t (a, b) VALUES (?,?),(?,?),(?,?)", sql);
}

test "buildInsertMany sqlite upsert suffix" {
    const sql = try buildInsertMany(testing.allocator, "t", &.{ "id", "name" }, 2, .sqlite, .{
        .conflict_columns = &.{"id"},
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "INSERT INTO t (id, name) VALUES (?,?),(?,?) ON CONFLICT (\"id\") DO UPDATE SET \"name\"=excluded.\"name\"",
        sql,
    );
}

test "buildInsertMany mysql upsert suffix" {
    const sql = try buildInsertMany(testing.allocator, "t", &.{ "id", "name" }, 1, .mysql, .{
        .conflict_columns = &.{"id"},
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "INSERT INTO t (id, name) VALUES (?,?) ON DUPLICATE KEY UPDATE name=VALUES(name)",
        sql,
    );
}

test "buildInsertMany rejects empty rows / columns / update list" {
    try testing.expectError(error.EmptyRows, buildInsertMany(testing.allocator, "t", &.{"a"}, 0, .sqlite, null));
    try testing.expectError(error.EmptyColumns, buildInsertMany(testing.allocator, "t", &.{}, 1, .sqlite, null));
    // All columns are conflict columns -> nothing to update.
    try testing.expectError(
        error.EmptyUpsertColumns,
        buildInsertMany(testing.allocator, "t", &.{"id"}, 1, .sqlite, .{ .conflict_columns = &.{"id"} }),
    );
}

test "flattenArgs concatenates rows in order" {
    const rows = [_][]const sqlx.Value{
        &.{ .{ .int = 1 }, .{ .string = "a" } },
        &[_]sqlx.Value{.{ .int = 2 }},
    };
    const flat = try flattenArgs(testing.allocator, &rows);
    defer testing.allocator.free(flat);
    try testing.expectEqual(@as(usize, 3), flat.len);
    try testing.expectEqual(@as(i64, 1), flat[0].int);
    try testing.expectEqualStrings("a", flat[1].string);
    try testing.expectEqual(@as(i64, 2), flat[2].int);
}
