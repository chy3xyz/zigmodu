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
    /// Request budget shared by every statement this backend issues. Defaults
    /// to "no deadline" (`.{}`), so an untouched backend behaves exactly as
    /// before; `Orm.withContext` stamps it per request.
    ///
    /// `SqlContext.isDone()` only refuses a statement that has **not started**
    /// yet — sqlx has no mid-flight cancellation — so this bounds the pile-up
    /// of queries behind an exhausted budget, it does not abort one in flight.
    ctx: sqlx.SqlContext = .{},

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
        return self.client.queryRowCtx(self.ctx, T, sql_str, args) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
    }

    /// Alias for queryRow — returns single result or null.
    pub fn queryOne(self: @This(), comptime T: type, sql_str: []const u8, args: []const Value) !?T {
        return self.queryRow(T, sql_str, args);
    }

    pub fn queryRows(self: @This(), comptime T: type, sql_str: []const u8, args: []const Value) !sqlx.QueryResult(T) {
        return self.client.queryRowsCtx(self.ctx, T, sql_str, args);
    }

    /// Arena-borrowed single row: strings point into the returned
    /// `BorrowedRow`'s arena; `deinit()` frees everything (no freeScanned).
    pub fn queryRowBorrowed(self: @This(), comptime T: type, sql_str: []const u8, args: []const Value) !sqlx.BorrowedRow(T) {
        return self.client.queryRowBorrowedCtx(self.ctx, T, sql_str, args);
    }

    /// Partial-scan arena-borrowed single row (missing columns zeroed).
    pub fn queryRowPartialBorrowed(self: @This(), comptime T: type, sql_str: []const u8, args: []const Value) !sqlx.BorrowedRow(T) {
        return self.client.queryRowPartialBorrowedCtx(self.ctx, T, sql_str, args);
    }

    /// One-shot scalar query (string-free `T` only; owned strings freed
    /// internally). See `sqlx.Client.queryScalar`.
    pub fn queryScalar(self: @This(), comptime T: type, sql_str: []const u8, args: []const Value) !?T {
        return self.client.queryScalarCtx(self.ctx, T, sql_str, args);
    }

    pub fn exec(self: @This(), sql_str: []const u8, args: []const Value) !ExecResult {
        return self.client.execCtx(self.ctx, sql_str, args);
    }

    /// Driver dialect for dialect-aware SQL generation (bulk upsert).
    pub fn dialect(self: @This()) sqlx.Driver {
        return self.client.config.driver;
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

    pub fn queryRowsTx(self: @This(), tx: *Tx, comptime T: type, sql_str: []const u8, args: []const Value) !sqlx.QueryResult(T) {
        var rows = try tx.query(self.allocator, sql_str, args);
        return sqlx.scanRowsToOwned(T, &rows, false) catch |err| {
            rows.deinit();
            return err;
        };
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
    var all = try repo.findAll();
    defer all.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), all.items.len);

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

test "Orm.withContext arms the request budget for every repository call" {
    const allocator = std.testing.allocator;

    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    _ = try client.exec("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)", &.{});
    _ = try client.exec("INSERT INTO User (id, name, age) VALUES (1, 'Alice', 30)", &.{});

    var orm_instance = orm.Orm(SqlxBackend){ .backend = .{ .allocator = allocator, .client = &client } };
    const UserRepo = orm.Orm(SqlxBackend).Repository(User);

    // Unarmed: `.{}` means no deadline, so nothing changes for code that never
    // calls `withContext`.
    const plain = UserRepo{ .orm = &orm_instance };
    const found = (try plain.findById(@as(i64, 1))).?;
    defer allocator.free(found.name);
    try std.testing.expectEqualStrings("Alice", found.name);

    // Armed with a budget that is already spent: every statement is refused
    // before it is sent, on every read/write path this backend serves.
    const expired = sqlx.SqlContext.withDeadline(Time.monotonicNowMilliseconds() - 1);
    var scoped_orm = orm_instance.withContext(expired);
    const scoped = UserRepo{ .orm = &scoped_orm };

    try std.testing.expectError(error.Timeout, scoped.findById(@as(i64, 1)));
    try std.testing.expectError(error.Timeout, scoped.findAll());
    try std.testing.expectError(error.Timeout, scoped.count());
    try std.testing.expectError(error.Timeout, scoped.update(.{ .id = 1, .name = "x", .age = 1 }));
    try std.testing.expectError(error.Timeout, scoped.delete(@as(i64, 1)));
    // `insert` goes through `exec` — the write path is covered too.
    try std.testing.expectError(error.Timeout, scoped.insert(.{ .id = 9, .name = "z", .age = 9 }));

    // The deadline is a *budget*, not a kill switch: a live one still runs.
    var fresh_orm = orm_instance.withContext(sqlx.SqlContext.withTimeout(60_000));
    const fresh = UserRepo{ .orm = &fresh_orm };
    const still_there = (try fresh.findById(@as(i64, 1))).?;
    defer allocator.free(still_there.name);
    try std.testing.expectEqualStrings("Alice", still_there.name);

    // And `withContext` copies — the original keeps its own (empty) budget.
    try std.testing.expect(orm_instance.backend.ctx.deadline_ms == null);
}

const Time = @import("../../core/Time.zig");
