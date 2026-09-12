//! Cross-instance mutual exclusion for background work — cron jobs and
//! migrations.
//!
//! Background work that must not run twice across replicas needs a lock that
//! lives outside the process. This module gives one small vtable-based
//! interface plus a table-backed implementation that works on SQLite,
//! PostgreSQL and MySQL through the framework's sqlx client, so it carries no
//! dialect branch and is testable in memory:
//!
//! ```zig
//! var sql_lock = zigmodu.scheduler.DistributedLock.SqlLock(@TypeOf(db)).init(
//!     allocator, io, &db, "zmodu_lock",
//! );
//! defer sql_lock.deinit();
//!
//! cron.setLock(sql_lock.lock());        // one replica runs each job per minute
//! runner.setLock(sql_lock.lock());      // one replica applies migrations
//! ```
//!
//! Semantics: acquire is "insert a row if nobody holds it", release is a
//! delete scoped to our own owner id, and a holder that dies without releasing
//! is reaped once `ttl_ms` passes. A job whose runtime exceeds its TTL can be
//! run concurrently by another replica in the next window — set the TTL above
//! the worst-case job duration.
//!
//! Postgres users who prefer server-side advisory locks can implement the same
//! `Lock` interface over `pg_try_advisory_lock` / `pg_advisory_unlock`
//! (MySQL: `GET_LOCK` / `RELEASE_LOCK`) — the call sites only need
//! `tryAcquire(name, ttl_ms)` and `release(name)`.

const std = @import("std");
const Time = @import("Time.zig");

/// Type-erased lock handle. Copyable; the backing object must outlive it.
pub const Lock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returns true when this caller now holds `name` for `ttl_ms`.
        /// Errors are real failures (connection down, bad table name) and are
        /// deliberately distinct from "held by someone else" (false).
        tryAcquire: *const fn (ptr: *anyopaque, name: []const u8, ttl_ms: u64) anyerror!bool,
        /// Idempotent; only releases the lock if this owner holds it.
        release: *const fn (ptr: *anyopaque, name: []const u8) void,
    };

    pub fn tryAcquire(self: Lock, name: []const u8, ttl_ms: u64) anyerror!bool {
        return self.vtable.tryAcquire(self.ptr, name, ttl_ms);
    }

    pub fn release(self: Lock, name: []const u8) void {
        self.vtable.release(self.ptr, name);
    }
};

/// Single-instance lock: always acquires. This is the no-lock default, so a
/// deployment that never configures a lock keeps its previous behavior.
pub const NoopLock = struct {
    var instance: NoopLock = .{};

    pub fn lock(self: *NoopLock) Lock {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = Lock.VTable{
        .tryAcquire = tryAcquire,
        .release = release,
    };

    fn tryAcquire(_: *anyopaque, _: []const u8, _: u64) anyerror!bool {
        return true;
    }

    fn release(_: *anyopaque, _: []const u8) void {}
};

/// SQL dialects the table-backed lock knows how to claim rows on. The caller
/// states it (rather than the lock sniffing the client type) because `Client`
/// is duck-typed here.
pub const Dialect = enum { sqlite, postgres, mysql };

/// Table-backed lock. `Client` is the framework sqlx client (or any type with
/// `exec(sql, params)` returning `.rows_affected` and
/// `queryRows(T, sql, params)`).
///
/// Claiming is a single atomic statement (`INSERT … ON CONFLICT DO NOTHING`,
/// or `INSERT IGNORE` on MySQL), so two replicas racing on the same name can
/// never both win — and contention is not an error, just `rows_affected == 0`.
pub fn SqlLock(comptime Client: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        client: *Client,
        table: []const u8,
        dialect: Dialect,
        owner: [16]u8,
        table_ready: bool = false,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, client: *Client, table: []const u8, dialect: Dialect) !Self {
            if (!isSafeIdentifier(table)) return error.InvalidLockTable;
            var seed: [8]u8 = undefined;
            std.Io.random(io, &seed);
            const owner = std.fmt.bytesToHex(seed, .lower);
            return .{
                .allocator = allocator,
                .io = io,
                .client = client,
                .table = try allocator.dupe(u8, table),
                .dialect = dialect,
                .owner = owner,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.table);
            self.* = undefined;
        }

        pub fn lock(self: *Self) Lock {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        const vtable = Lock.VTable{
            .tryAcquire = tryAcquire,
            .release = release,
        };

        fn tryAcquire(ptr: *anyopaque, name: []const u8, ttl_ms: u64) anyerror!bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.ensureTable();

            const now_ms = Time.wallClockMilliseconds(self.io);
            const expires = now_ms + @as(i64, @intCast(ttl_ms));

            // Reap a holder that died without releasing (best effort: another
            // replica's cleanup is equally fine).
            const reap_sql = try std.fmt.allocPrint(self.allocator, "DELETE FROM {s} WHERE name = ? AND expires_at <= ?", .{self.table});
            defer self.allocator.free(reap_sql);
            _ = self.client.exec(reap_sql, &.{ .{ .string = name }, .{ .int = now_ms } }) catch |err| std.log.debug("[lock] reap of '{s}' failed ({s}); a stale row may linger until the next attempt", .{ name, @errorName(err) });

            // Atomic claim: exactly one racer gets rows_affected == 1.
            const insert_sql = switch (self.dialect) {
                .sqlite, .postgres => try std.fmt.allocPrint(self.allocator, "INSERT INTO {s} (name, owner, expires_at) VALUES (?, ?, ?) ON CONFLICT(name) DO NOTHING", .{self.table}),
                .mysql => try std.fmt.allocPrint(self.allocator, "INSERT IGNORE INTO {s} (name, owner, expires_at) VALUES (?, ?, ?)", .{self.table}),
            };
            defer self.allocator.free(insert_sql);
            const res = try self.client.exec(insert_sql, &.{
                .{ .string = name },
                .{ .string = &self.owner },
                .{ .int = expires },
            });
            if (res.rows_affected > 0) return true;

            // No row inserted: somebody holds it. Confirm a holder exists —
            // absence would mean the statement was a no-op for another reason.
            const Row = struct { owner: []const u8 };
            const select_sql = try std.fmt.allocPrint(self.allocator, "SELECT owner FROM {s} WHERE name = ?", .{self.table});
            defer self.allocator.free(select_sql);
            var rows = try self.client.queryRows(Row, select_sql, &.{.{ .string = name }});
            defer rows.deinit(self.allocator);
            if (rows.items.len == 0) return error.LockClaimFailed;
            // Re-entrant call by the same owner still counts as held.
            return std.mem.eql(u8, rows.items[0].owner, &self.owner);
        }

        fn release(ptr: *anyopaque, name: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const sql = std.fmt.allocPrint(self.allocator, "DELETE FROM {s} WHERE name = ? AND owner = ?", .{self.table}) catch return;
            defer self.allocator.free(sql);
            _ = self.client.exec(sql, &.{ .{ .string = name }, .{ .string = &self.owner } }) catch |err| std.log.debug("[lock] release of '{s}' failed ({s}); ttl will expire it", .{ name, @errorName(err) });
        }

        fn ensureTable(self: *Self) !void {
            if (self.table_ready) return;
            // VARCHAR(191): fits MySQL's index limit even on older utf8mb4
            // configurations; BIGINT is portable across the three drivers.
            const ddl = try std.fmt.allocPrint(self.allocator, "CREATE TABLE IF NOT EXISTS {s} (name VARCHAR(191) PRIMARY KEY, owner VARCHAR(64) NOT NULL, expires_at BIGINT NOT NULL)", .{self.table});
            defer self.allocator.free(ddl);
            _ = try self.client.exec(ddl, &.{});
            self.table_ready = true;
        }
    };
}

/// Table names are interpolated into DDL/DML (they cannot be bound), so they
/// must be a plain identifier.
fn isSafeIdentifier(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name, 0..) |c, i| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_';
        if (!ok) return false;
        if (i == 0 and std.ascii.isDigit(c)) return false;
    }
    return true;
}

test "noop lock always acquires and release is a no-op" {
    var noop: NoopLock = .{};
    const l = noop.lock();
    try std.testing.expect(try l.tryAcquire("job", 1000));
    l.release("job");
}

test "SqlLock: second owner cannot take a held lock, then can after release" {
    const allocator = std.testing.allocator;
    var db = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:", .max_open_conns = 2, .max_idle_conns = 1 });
    defer db.deinit();

    var a = try SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, "zmodu_lock_test", .sqlite);
    defer a.deinit();
    var b = try SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, "zmodu_lock_test", .sqlite);
    defer b.deinit();

    // A holds it: B is rejected (this is the two-replica case).
    try std.testing.expect(try a.lock().tryAcquire("cron:nightly", 60_000));
    try std.testing.expect(!try b.lock().tryAcquire("cron:nightly", 60_000));

    // Different names never contend.
    try std.testing.expect(try b.lock().tryAcquire("cron:hourly", 60_000));
    try std.testing.expect(!try a.lock().tryAcquire("cron:hourly", 60_000));

    // Release hands it over.
    a.lock().release("cron:nightly");
    try std.testing.expect(try b.lock().tryAcquire("cron:nightly", 60_000));
    // ...and the former holder can no longer take it back while B owns it.
    try std.testing.expect(!try a.lock().tryAcquire("cron:nightly", 60_000));
    // Different names never contend.
    try std.testing.expect(try a.lock().tryAcquire("cron:weekly", 60_000));
}

test "SqlLock: an expired holder (crashed replica) is reaped" {
    const allocator = std.testing.allocator;
    var db = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:", .max_open_conns = 2, .max_idle_conns = 1 });
    defer db.deinit();

    var a = try SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, "zmodu_lock_reap", .sqlite);
    defer a.deinit();
    var b = try SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, "zmodu_lock_reap", .sqlite);
    defer b.deinit();

    // A takes the lock with an already-elapsed TTL and never releases —
    // exactly what a crashed replica looks like.
    try std.testing.expect(try a.lock().tryAcquire("migration", 0));
    try std.testing.expect(try b.lock().tryAcquire("migration", 60_000));
}

test "SqlLock rejects unsafe table identifiers" {
    const allocator = std.testing.allocator;
    var db = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:", .max_open_conns = 2, .max_idle_conns = 1 });
    defer db.deinit();
    try std.testing.expectError(error.InvalidLockTable, SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, "locks; DROP TABLE users;--", .sqlite));
    try std.testing.expectError(error.InvalidLockTable, SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, "", .sqlite));
}

// Real-database coverage for the `.postgres` dialect. Opt-in via
// `ZIGMODU_TEST_PG=1` (CI's `test-postgres` job sets it) plus optional
// `PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` / `PGDATABASE`.
//
// The SQLite path above proves the algorithm; this proves the dialect string
// (`ON CONFLICT (name) DO NOTHING`) and `rows_affected` really behave that way
// on the server.
test "SqlLock claims and reaps locks on a real PostgreSQL" {
    const allocator = std.testing.allocator;
    const enabled = std.c.getenv("ZIGMODU_TEST_PG") orelse return error.SkipZigTest;
    if (std.mem.eql(u8, std.mem.span(enabled), "0")) return error.SkipZigTest;

    const envVar = struct {
        fn get(comptime name: [:0]const u8, default: []const u8) []const u8 {
            const raw = std.c.getenv(name) orelse return default;
            return std.mem.span(raw);
        }
    };

    const SqlClient = @import("../sqlx/sqlx.zig").Client;
    var db = SqlClient.init(allocator, std.testing.io, .{
        .driver = .postgres,
        .host = envVar.get("PGHOST", "127.0.0.1"),
        .port = std.fmt.parseInt(u16, envVar.get("PGPORT", "5432"), 10) catch 5432,
        .username = envVar.get("PGUSER", "postgres"),
        .password = envVar.get("PGPASSWORD", ""),
        .database = envVar.get("PGDATABASE", "postgres"),
        .max_open_conns = 2,
        .max_idle_conns = 1,
    });
    defer db.deinit();
    try db.connect();

    // Unique table per run so parallel/repeat runs never collide.
    var table_buf: [64]u8 = undefined;
    var seed: [8]u8 = undefined;
    std.Io.random(std.testing.io, &seed);
    const table = try std.fmt.bufPrint(&table_buf, "zmodu_lock_pg_{s}", .{std.fmt.bytesToHex(seed, .lower)});
    defer {
        var drop_buf: [96]u8 = undefined;
        const drop = std.fmt.bufPrint(&drop_buf, "DROP TABLE IF EXISTS {s}", .{table}) catch "";
        if (drop.len > 0) _ = db.exec(drop, &.{}) catch {};
    }

    var a = try SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, table, .postgres);
    defer a.deinit();
    var b = try SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, table, .postgres);
    defer b.deinit();

    // Two replicas race for the same name: exactly one wins.
    try std.testing.expect(try a.lock().tryAcquire("cron:nightly", 60_000));
    try std.testing.expect(!try b.lock().tryAcquire("cron:nightly", 60_000));

    // Release hands it over.
    a.lock().release("cron:nightly");
    try std.testing.expect(try b.lock().tryAcquire("cron:nightly", 60_000));

    // An expired holder (crashed replica) is reaped.
    b.lock().release("cron:nightly");
    try std.testing.expect(try a.lock().tryAcquire("cron:nightly", 0));
    try std.testing.expect(try b.lock().tryAcquire("cron:nightly", 60_000));
}
