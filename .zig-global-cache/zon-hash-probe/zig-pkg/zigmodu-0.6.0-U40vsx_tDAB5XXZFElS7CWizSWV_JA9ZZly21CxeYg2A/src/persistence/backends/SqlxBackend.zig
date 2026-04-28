//! SqlxBackend - default ORM backend adapter for sqlx
//!
//! Bridges the unified ORM layer (src/persistence/Orm.zig) to sqlx.
//! Future backends (e.g., zorm) can follow the same pattern.

const std = @import("std");
const sqlx = @import("../../sqlx/sqlx.zig");
const orm = @import("../Orm.zig");

pub const SqlxBackend = struct {
    allocator: std.mem.Allocator,
    client: *sqlx.Client,

    pub const Value = sqlx.Value;
    pub const ExecResult = sqlx.ExecResult;
    pub const Tx = sqlx.Transaction;

    pub fn fromOrmValue(v: orm.OrmValue) Value {
        return switch (v) {
            .null => .null,
            .int => |i| .{ .int = i },
            .float => |f| .{ .float = f },
            .string => |s| .{ .string = s },
            .bool => |b| .{ .bool = b },
        };
    }

    pub fn queryRow(self: @This(), comptime T: type, sql_str: []const u8, args: []const Value) !?T {
        return self.client.queryRow(T, sql_str, args) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
    }

    pub fn queryRows(self: @This(), comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        return self.client.queryRows(T, sql_str, args);
    }

    pub fn exec(self: @This(), sql_str: []const u8, args: []const Value) !ExecResult {
        return self.client.exec(sql_str, args);
    }

    pub fn beginTx(self: @This()) !Tx {
        return self.client.beginTx();
    }

    pub fn commitTx(_: @This(), tx: *Tx) !void {
        try tx.commit();
    }

    pub fn rollbackTx(_: @This(), tx: *Tx) !void {
        try tx.rollback();
    }

    pub fn execTx(_: @This(), tx: *Tx, sql_str: []const u8, args: []const Value) !ExecResult {
        return tx.exec(sql_str, args);
    }

    pub fn queryRowTx(self: @This(), tx: *Tx, comptime T: type, sql_str: []const u8, args: []const Value) !?T {
        var rows = try tx.query(self.allocator, sql_str, args);
        defer rows.deinit();
        if (rows.rows.len == 0) return null;
        return try rows.rows[0].scan(self.allocator, T);
    }

    pub fn queryRowsTx(self: @This(), tx: *Tx, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        var rows = try tx.query(self.allocator, sql_str, args);
        defer rows.deinit();
        const result = try self.allocator.alloc(T, rows.rows.len);
        errdefer {
            for (result) |item| sqlx.freeScanned(self.allocator, T, item);
            self.allocator.free(result);
        }
        for (rows.rows, 0..) |row, i| {
            result[i] = try row.scan(self.allocator, T);
        }
        return result;
    }
};

test "ORM with SqlxBackend end-to-end (sqlite)" {
    const allocator = std.testing.allocator;

    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    // Create table manually (migrations would do this in real app)
    _ = try client.exec("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)", &.{});

    const backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var orm_instance = orm.Orm(SqlxBackend){ .backend = backend };
    const UserRepo = orm.Orm(SqlxBackend).Repository(User);
    const repo = UserRepo{ .orm = &orm_instance };

    // Insert
    const inserted = try repo.insert(.{ .id = 1, .name = "Alice", .age = 30 });
    try std.testing.expectEqual(@as(i64, 1), inserted.id);
    try std.testing.expectEqualStrings("Alice", inserted.name);

    // Find by id
    const found = try repo.findById(@as(i64, 1));
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("Alice", found.?.name);
    try std.testing.expectEqual(@as(i64, 30), found.?.age);
    if (found) |u| allocator.free(u.name);

    // Update
    try repo.update(.{ .id = 1, .name = "Alice Smith", .age = 31 });
    const updated = try repo.findById(@as(i64, 1));
    try std.testing.expect(updated != null);
    try std.testing.expectEqualStrings("Alice Smith", updated.?.name);
    try std.testing.expectEqual(@as(i64, 31), updated.?.age);
    if (updated) |u| allocator.free(u.name);

    // Find all
    _ = try repo.insert(.{ .id = 2, .name = "Bob", .age = 25 });
    const all = try repo.findAll();
    defer allocator.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    for (all) |u| allocator.free(u.name);

    // Delete
    try repo.delete(@as(i64, 1));
    const deleted = try repo.findById(@as(i64, 1));
    try std.testing.expect(deleted == null);

    // Transaction
    const tx_result = try repo.transact(i64, struct {
        fn doTx(tx: *orm.Tx(SqlxBackend)) !i64 {
            const r = try tx.exec("INSERT INTO User (id, name, age) VALUES (?, ?, ?)", &.{
                sqlx.Value{ .int = 3 },
                sqlx.Value{ .string = "Charlie" },
                sqlx.Value{ .int = 40 },
            });
            return @intCast(r.rows_affected);
        }
    }.doTx);
    try std.testing.expectEqual(@as(i64, 1), tx_result);

    const charlie = try repo.findById(@as(i64, 3));
    try std.testing.expect(charlie != null);
    try std.testing.expectEqualStrings("Charlie", charlie.?.name);
    if (charlie) |u| allocator.free(u.name);
}

const User = struct {
    id: i64,
    name: []const u8,
    age: i64,
};

