// SQL Diff Engine — compares two SQL schemas at table/column level
const std = @import("std");
const main_mod = @import("main.zig");

pub const ChangeType = enum { added, removed, modified };
pub const ColumnChangeType = enum { added, removed, type_changed, nullable_changed, default_changed };

pub const ColumnChange = struct {
    column_name: []const u8,
    change_type: ColumnChangeType,
    old_type: ?[]const u8 = null,
    new_type: ?[]const u8 = null,
};

pub const TableDiff = struct {
    table_name: []const u8,
    change_type: ChangeType,
    column_changes: []ColumnChange = &.{},
};

/// Compare two sets of TableDefs and produce a list of diffs.
/// Caller owns the returned slice.
pub fn diffTables(allocator: std.mem.Allocator, old_tables: []const main_mod.TableDef, new_tables: []const main_mod.TableDef) ![]TableDiff {
    var diffs = std.ArrayList(TableDiff).empty;
    errdefer diffs.deinit(allocator);

    // Build lookup maps (old by name)
    var old_map = std.StringHashMap(*const main_mod.TableDef).init(allocator);
    defer old_map.deinit();
    for (old_tables) |*t| {
        try old_map.put(t.name, t);
    }

    var new_map = std.StringHashMap(*const main_mod.TableDef).init(allocator);
    defer new_map.deinit();
    for (new_tables) |*t| {
        try new_map.put(t.name, t);
    }

    // Find added and modified tables
    for (new_tables) |*new_t| {
        if (old_map.get(new_t.name)) |old_t| {
            const changes = try diffColumns(allocator, old_t.columns, new_t.columns);
            if (changes.len > 0) {
                try diffs.append(allocator, .{
                    .table_name = new_t.name,
                    .change_type = .modified,
                    .column_changes = changes,
                });
            }
        } else {
            try diffs.append(allocator, .{
                .table_name = new_t.name,
                .change_type = .added,
            });
        }
    }

    // Find removed tables
    for (old_tables) |*old_t| {
        if (new_map.get(old_t.name) == null) {
            try diffs.append(allocator, .{
                .table_name = old_t.name,
                .change_type = .removed,
            });
        }
    }

    return diffs.toOwnedSlice(allocator);
}

fn diffColumns(allocator: std.mem.Allocator, old_cols: []const main_mod.ColumnDef, new_cols: []const main_mod.ColumnDef) ![]ColumnChange {
    var changes = std.ArrayList(ColumnChange).empty;
    errdefer changes.deinit(allocator);

    var old_col_map = std.StringHashMap(*const main_mod.ColumnDef).init(allocator);
    defer old_col_map.deinit();
    for (old_cols) |*c| {
        try old_col_map.put(c.name, c);
    }

    var new_col_map = std.StringHashMap(*const main_mod.ColumnDef).init(allocator);
    defer new_col_map.deinit();
    for (new_cols) |*c| {
        try new_col_map.put(c.name, c);
    }

    // Added or changed columns
    for (new_cols) |*new_c| {
        if (old_col_map.get(new_c.name)) |old_c| {
            if (old_c.col_type != new_c.col_type) {
                try changes.append(allocator, .{
                    .column_name = new_c.name,
                    .change_type = .type_changed,
                    .old_type = @tagName(old_c.col_type),
                    .new_type = @tagName(new_c.col_type),
                });
            }
            if (old_c.nullable != new_c.nullable) {
                try changes.append(allocator, .{
                    .column_name = new_c.name,
                    .change_type = .nullable_changed,
                    .old_type = if (old_c.nullable) "nullable" else "not_null",
                    .new_type = if (new_c.nullable) "nullable" else "not_null",
                });
            }
            if (old_c.has_default != new_c.has_default) {
                try changes.append(allocator, .{
                    .column_name = new_c.name,
                    .change_type = .default_changed,
                    .old_type = if (old_c.has_default) "has_default" else "no_default",
                    .new_type = if (new_c.has_default) "has_default" else "no_default",
                });
            }
        } else {
            try changes.append(allocator, .{
                .column_name = new_c.name,
                .change_type = .added,
                .new_type = @tagName(new_c.col_type),
            });
        }
    }

    // Removed columns
    for (old_cols) |*old_c| {
        if (new_col_map.get(old_c.name) == null) {
            try changes.append(allocator, .{
                .column_name = old_c.name,
                .change_type = .removed,
                .old_type = @tagName(old_c.col_type),
            });
        }
    }

    return changes.toOwnedSlice(allocator);
}

// ── Tests ──

test "diffTables detects added table" {
    const allocator = std.testing.allocator;
    const old_tables = [_]main_mod.TableDef{};
    const new_tables = [_]main_mod.TableDef{.{
        .name = "users",
        .columns = &[_]main_mod.ColumnDef{.{
            .name = "id", .col_type = .int, .nullable = false,
            .is_primary_key = true, .is_unique = false, .has_default = false, .comment = null,
        }},
        .foreign_keys = &.{},
    }};

    const diffs = try diffTables(allocator, &old_tables, &new_tables);
    defer allocator.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expect(diffs[0].change_type == .added);
    try std.testing.expectEqualStrings("users", diffs[0].table_name);
}

test "diffTables detects removed table" {
    const allocator = std.testing.allocator;
    const old_tables = [_]main_mod.TableDef{.{
        .name = "old_table", .columns = &.{}, .foreign_keys = &.{},
    }};
    const new_tables = [_]main_mod.TableDef{};

    const diffs = try diffTables(allocator, &old_tables, &new_tables);
    defer allocator.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expect(diffs[0].change_type == .removed);
}

test "diffTables detects added column" {
    const allocator = std.testing.allocator;
    const old_cols = [_]main_mod.ColumnDef{.{
        .name = "id", .col_type = .int, .nullable = false,
        .is_primary_key = true, .is_unique = false, .has_default = false, .comment = null,
    }};
    const new_cols = [_]main_mod.ColumnDef{
        .{ .name = "id", .col_type = .int, .nullable = false,
           .is_primary_key = true, .is_unique = false, .has_default = false, .comment = null },
        .{ .name = "email", .col_type = .string, .nullable = true,
           .is_primary_key = false, .is_unique = false, .has_default = false, .comment = null },
    };
    const old_tables = [_]main_mod.TableDef{.{ .name = "users", .columns = &old_cols, .foreign_keys = &.{} }};
    const new_tables = [_]main_mod.TableDef{.{ .name = "users", .columns = &new_cols, .foreign_keys = &.{} }};

    const diffs = try diffTables(allocator, &old_tables, &new_tables);
    defer {
        for (diffs) |d| if (d.column_changes.len > 0) allocator.free(d.column_changes);
        allocator.free(diffs);
    }
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expect(diffs[0].change_type == .modified);
    try std.testing.expectEqual(@as(usize, 1), diffs[0].column_changes.len);
    try std.testing.expect(diffs[0].column_changes[0].change_type == .added);
    try std.testing.expectEqualStrings("email", diffs[0].column_changes[0].column_name);
}

test "diffTables detects type change" {
    const allocator = std.testing.allocator;
    const old_cols = [_]main_mod.ColumnDef{.{
        .name = "val", .col_type = .int, .nullable = false,
        .is_primary_key = false, .is_unique = false, .has_default = false, .comment = null,
    }};
    const new_cols = [_]main_mod.ColumnDef{.{
        .name = "val", .col_type = .string, .nullable = false,
        .is_primary_key = false, .is_unique = false, .has_default = false, .comment = null,
    }};
    const old_tables = [_]main_mod.TableDef{.{ .name = "t", .columns = &old_cols, .foreign_keys = &.{} }};
    const new_tables = [_]main_mod.TableDef{.{ .name = "t", .columns = &new_cols, .foreign_keys = &.{} }};

    const diffs = try diffTables(allocator, &old_tables, &new_tables);
    defer {
        for (diffs) |d| if (d.column_changes.len > 0) allocator.free(d.column_changes);
        allocator.free(diffs);
    }
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expect(diffs[0].column_changes[0].change_type == .type_changed);
}

test "diffTables no changes produces empty diff" {
    const allocator = std.testing.allocator;
    const cols = [_]main_mod.ColumnDef{.{
        .name = "id", .col_type = .int, .nullable = false,
        .is_primary_key = true, .is_unique = false, .has_default = false, .comment = null,
    }};
    const tables = [_]main_mod.TableDef{.{ .name = "users", .columns = &cols, .foreign_keys = &.{} }};

    const diffs = try diffTables(allocator, &tables, &tables);
    defer allocator.free(diffs);
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}
