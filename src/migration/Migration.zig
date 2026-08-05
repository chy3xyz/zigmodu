const std = @import("std");
const Time = @import("../core/Time.zig");

/// Split a migration script into statements on `;`, ignoring semicolons inside:
///   - single-quoted strings (`'...'`, `''` escape)
///   - double-quoted identifiers (`"..."`)
///   - line comments (`-- …`) and block comments (`/* … */`)
///   - dollar-quoted bodies (`$$…$$` / `$tag$…$tag$`) — PL/pgSQL functions,
///     triggers and DO blocks contain internal semicolons
/// Returns owned slices (caller frees each + the slice).
fn splitSqlStatements(allocator: std.mem.Allocator, sql: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    var start: usize = 0;
    var i: usize = 0;
    while (i < sql.len) {
        switch (sql[i]) {
            '\'' => {
                i += 1;
                while (i < sql.len) {
                    if (sql[i] == '\'') {
                        if (i + 1 < sql.len and sql[i + 1] == '\'') {
                            i += 2;
                            continue;
                        }
                        i += 1;
                        break;
                    }
                    i += 1;
                }
            },
            '"' => {
                i += 1;
                while (i < sql.len and sql[i] != '"') i += 1;
                if (i < sql.len) i += 1;
            },
            '-' => {
                if (i + 1 < sql.len and sql[i + 1] == '-') {
                    while (i < sql.len and sql[i] != '\n') i += 1;
                } else i += 1;
            },
            '/' => {
                if (i + 1 < sql.len and sql[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) i += 1;
                    i += 2;
                } else i += 1;
            },
            '$' => {
                if (dollarQuoteTagLen(sql, i)) |tag_len| {
                    const tag = sql[i .. i + tag_len];
                    i += tag_len;
                    if (std.mem.indexOfPos(u8, sql, i, tag)) |close| {
                        i = close + tag.len;
                    } else {
                        i = sql.len;
                    }
                } else i += 1;
            },
            ';' => {
                const stmt = std.mem.trim(u8, sql[start..i], " \t\r\n");
                if (stmt.len > 0) try out.append(allocator, try allocator.dupe(u8, stmt));
                i += 1;
                start = i;
            },
            else => i += 1,
        }
    }
    const tail = std.mem.trim(u8, sql[start..], " \t\r\n");
    if (tail.len > 0) try out.append(allocator, try allocator.dupe(u8, tail));
    return try out.toOwnedSlice(allocator);
}

/// Length of a dollar-quote opening tag at `pos` (`$$` or `$tag$`, tag =
/// alphanumerics/underscore), or null. `$1`-style parameter placeholders do
/// not match (no trailing `$`).
fn dollarQuoteTagLen(sql: []const u8, pos: usize) ?usize {
    if (sql[pos] != '$') return null;
    var j = pos + 1;
    while (j < sql.len and (std.ascii.isAlphanumeric(sql[j]) or sql[j] == '_')) j += 1;
    if (j < sql.len and sql[j] == '$') return j + 1 - pos;
    return null;
}

/// Database migration[...]
pub const MigrationEntry = struct {
    /// [...] ([...]: YYYYMMDDHHMMSS)
    version: i64,
    /// [...]
    description: []const u8,
    /// SQL [...]
    sql: []const u8,
    /// [...] SQL ([...])
    rollback_sql: ?[]const u8 = null,
    /// [...] (SHA256)
    checksum: ?[]const u8 = null,
};

/// [...]
pub const AppliedMigration = struct {
    version: i64,
    description: []const u8,
    applied_at: i64,
    checksum: []const u8,
    execution_time_ms: u64,
    success: bool,
};

/// [...]
pub const MigrationStatus = enum {
    pending,
    applied,
    failed,
    skipped,
};

/// [...] (for getMigrationStatus)
pub const MigrationStatusEntry = struct {
    version: i64,
    description: []const u8,
    status: MigrationStatus,
};

/// [...]
/// [...] Flyway / Liquibase [...]Database migration[...]
pub const MigrationRunner = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    migrations: std.ArrayList(MigrationEntry),
    history: std.ArrayList(AppliedMigration),
    /// Migration history[...]
    history_table: []const u8,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .migrations = std.ArrayList(MigrationEntry).empty,
            .history = std.ArrayList(AppliedMigration).empty,
            .history_table = "_zigmodu_migrations",
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.migrations.items) |m| {
            self.allocator.free(m.description);
            self.allocator.free(m.sql);
            if (m.rollback_sql) |rs| self.allocator.free(rs);
            if (m.checksum) |cs| self.allocator.free(cs);
        }
        self.migrations.deinit(self.allocator);

        for (self.history.items) |h| {
            self.allocator.free(h.description);
            self.allocator.free(h.checksum);
        }
        self.history.deinit(self.allocator);
        self.* = undefined;
    }

    /// [...]
    pub fn addMigration(self: *Self, version: i64, description: []const u8, sql: []const u8) !void {
        const desc_copy = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_copy);

        const sql_copy = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(sql_copy);

        // [...]
        const checksum = try computeChecksum(self.allocator, sql);

        try self.migrations.append(self.allocator, .{
            .version = version,
            .description = desc_copy,
            .sql = sql_copy,
            .checksum = checksum,
        });
    }

    /// [...]
    pub fn addMigrationWithRollback(
        self: *Self,
        version: i64,
        description: []const u8,
        sql: []const u8,
        rollback_sql: []const u8,
    ) !void {
        const desc_copy = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_copy);

        const sql_copy = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(sql_copy);

        const rb_copy = try self.allocator.dupe(u8, rollback_sql);
        errdefer self.allocator.free(rb_copy);

        const checksum = try computeChecksum(self.allocator, sql);

        try self.migrations.append(self.allocator, .{
            .version = version,
            .description = desc_copy,
            .sql = sql_copy,
            .rollback_sql = rb_copy,
            .checksum = checksum,
        });
    }

    /// Get pending migration list
    pub fn getPendingMigrations(self: *Self, buf: []MigrationEntry) []MigrationEntry {
        var count: usize = 0;
        for (self.migrations.items) |migration| {
            var already_applied = false;
            for (self.history.items) |applied| {
                if (applied.version == migration.version and applied.success) {
                    already_applied = true;
                    break;
                }
            }
            if (!already_applied and count < buf.len) {
                buf[count] = migration;
                count += 1;
            }
        }
        return buf[0..count];
    }

    /// [...]
    pub fn getMigrationStatus(self: *Self, buf: []MigrationStatusEntry) []MigrationStatusEntry {
        var count: usize = 0;
        for (self.migrations.items) |migration| {
            var status: MigrationStatus = .pending;
            for (self.history.items) |applied| {
                if (applied.version == migration.version) {
                    status = if (applied.success) .applied else .failed;
                    break;
                }
            }
            if (count < buf.len) {
                buf[count] = .{ .version = migration.version, .description = migration.description, .status = status };
                count += 1;
            }
        }
        return buf[0..count];
    }

    /// [...]
    pub fn recordMigration(
        self: *Self,
        version: i64,
        description: []const u8,
        checksum: []const u8,
        execution_time_ms: u64,
        success: bool,
    ) !void {
        const desc_copy = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_copy);

        const cs_copy = try self.allocator.dupe(u8, checksum);
        errdefer self.allocator.free(cs_copy);

        try self.history.append(self.allocator, .{
            .version = version,
            .description = desc_copy,
            .applied_at = Time.monotonicNowSeconds(),
            .checksum = cs_copy,
            .execution_time_ms = execution_time_ms,
            .success = success,
        });
    }

    /// Get applied migration count
    pub fn getAppliedCount(self: *Self) usize {
        var count: usize = 0;
        for (self.history.items) |h| {
            if (h.success) count += 1;
        }
        return count;
    }

    /// [...]
    pub fn getTotalCount(self: *Self) usize {
        return self.migrations.items.len;
    }

    /// Execute all pending migrations against a database client.
    /// Runs each migration's SQL in order, records results in the history table.
    pub fn run(self: *Self, client: anytype) !void {
        // Ensure history table exists
        const ddl = self.generateHistoryTableDDL() catch return error.OutOfMemory;
        defer self.allocator.free(ddl);
        _ = client.exec(ddl, &.{}) catch return error.QueryExecutionFailed;
        // Load previously applied migrations from the DB — a fresh runner must
        // not re-run them (history is persisted, not just in-memory).
        try self.loadHistory(client);

        for (self.migrations.items) |migration| {
            // Skip already-applied migrations
            var already_applied = false;
            for (self.history.items) |h| {
                if (h.version == migration.version and h.success) {
                    already_applied = true;
                    break;
                }
            }
            if (already_applied) continue;

            const start_ms = @import("../core/Time.zig").monotonicNowMilliseconds();
            // Semicolon-aware splitter: PL/pgSQL bodies ($$…$$), quoted
            // strings, identifiers and comments keep their internal `;`.
            const stmts = try splitSqlStatements(self.allocator, migration.sql);
            defer {
                for (stmts) |s| self.allocator.free(s);
                self.allocator.free(stmts);
            }
            var mig_ok = true;
            for (stmts) |stmt| {
                const trimmed = std.mem.trim(u8, stmt, " \t\r\n");
                if (trimmed.len == 0) continue;
                _ = client.exec(trimmed, &.{}) catch |err| {
                    if (std.mem.startsWith(u8, trimmed, "ALTER TABLE")) {
                        std.log.info("[Migration] ALTER TABLE statement skipped (column may already exist): {s}", .{trimmed});
                    } else {
                        std.log.err("[Migration] Error executing V{d} statement: {s} ({s})", .{ migration.version, trimmed, @errorName(err) });
                        mig_ok = false;
                        break;
                    }
                };
            }
            const elapsed_ms = @import("../core/Time.zig").monotonicNowMilliseconds() - start_ms;

            const checksum = migration.checksum orelse "";
            if (mig_ok) {
                try self.recordMigration(migration.version, migration.description, checksum, @intCast(elapsed_ms), true);
                try self.insertHistoryRecord(client, migration.version, migration.description, checksum, @intCast(elapsed_ms), true);
            } else {
                try self.recordMigration(migration.version, migration.description, checksum, @intCast(elapsed_ms), false);
                try self.insertHistoryRecord(client, migration.version, migration.description, checksum, @intCast(elapsed_ms), false);
                return error.MigrationFailed;
            }
        }
    }

    /// Load applied migrations from the history table into `self.history`.
    pub fn loadHistory(self: *Self, client: anytype) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT version, description, applied_at, checksum, execution_time_ms, success FROM {s} ORDER BY version", .{self.history_table});
        defer self.allocator.free(sql);
        var result = try client.queryRows(AppliedMigration, sql, &.{});
        defer result.deinit(self.allocator);
        for (result.items) |h| {
            // queryRows strings borrow the result arena — dup into our own
            // allocator so history survives result.deinit.
            const desc = try self.allocator.dupe(u8, h.description);
            errdefer self.allocator.free(desc);
            const cs = try self.allocator.dupe(u8, h.checksum);
            try self.history.append(self.allocator, .{
                .version = h.version,
                .description = desc,
                .applied_at = h.applied_at,
                .checksum = cs,
                .execution_time_ms = h.execution_time_ms,
                .success = h.success,
            });
        }
    }

    /// Persist one applied-migration record so restarts skip it.
    fn insertHistoryRecord(self: *Self, client: anytype, version: i64, description: []const u8, checksum: []const u8, elapsed_ms: u64, success: bool) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO {s} (version, description, applied_at, checksum, execution_time_ms, success) VALUES (?, ?, ?, ?, ?, ?)", .{self.history_table});
        defer self.allocator.free(sql);
        _ = try client.exec(sql, &.{
            .{ .int = version },
            .{ .string = description },
            .{ .int = Time.monotonicNowSeconds() },
            .{ .string = checksum },
            .{ .int = @intCast(elapsed_ms) },
            .{ .bool = success },
        });
    }

    /// [...]Migration history[...] SQL
    pub fn generateHistoryTableDDL(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\CREATE TABLE IF NOT EXISTS {s} (
            \\    version BIGINT PRIMARY KEY,
            \\    description VARCHAR(500) NOT NULL,
            \\    applied_at BIGINT NOT NULL,
            \\    checksum VARCHAR(64) NOT NULL,
            \\    execution_time_ms BIGINT NOT NULL,
            \\    success BOOLEAN NOT NULL DEFAULT TRUE
            \\);
        , .{self.history_table});
    }

    /// Validation[...]
    pub fn validateChecksums(self: *Self) !bool {
        for (self.history.items) |applied| {
            if (!applied.success) continue;

            for (self.migrations.items) |migration| {
                if (migration.version == applied.version) {
                    if (migration.checksum) |expected_cs| {
                        if (!std.mem.eql(u8, expected_cs, applied.checksum)) {
                            std.log.warn(
                                "[Migration] Checksum mismatch for V{d}: expected {s}, got {s}",
                                .{ applied.version, expected_cs, applied.checksum },
                            );
                            return false;
                        }
                    }
                    break;
                }
            }
        }
        return true;
    }
};

/// SQL [...]
pub const MigrationLoader = struct {
    /// [...] SQL [...]
    /// [...]: -- version: YYYYMMDDHHMMSS
    ///           -- description: xxx
    /// -- rollback: ... ([...])
    ///           SQL statements...
    pub fn parseMigrationFile(allocator: std.mem.Allocator, content: []const u8) !struct {
        version: i64,
        description: []const u8,
        sql: []const u8,
        rollback_sql: ?[]const u8,
    } {
        var version: ?i64 = null;
        var description: ?[]const u8 = null;
        var sql_start: usize = 0;
        var rollback_sql: ?[]const u8 = null;

        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_no: usize = 0;
        while (lines.next()) |line| : (line_no += 1) {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (std.mem.startsWith(u8, trimmed, "-- version:")) {
                const ver_str = std.mem.trim(u8, trimmed["-- version:".len..], " \t");
                version = std.fmt.parseInt(i64, ver_str, 10) catch {
                    return error.InvalidMigrationVersion;
                };
            } else if (std.mem.startsWith(u8, trimmed, "-- description:")) {
                const desc = std.mem.trim(u8, trimmed["-- description:".len..], " \t");
                description = try allocator.dupe(u8, desc);
            } else if (std.mem.startsWith(u8, trimmed, "-- rollback:")) {
                const rb = std.mem.trim(u8, trimmed["-- rollback:".len..], " \t");
                rollback_sql = try allocator.dupe(u8, rb);
            } else if (!std.mem.startsWith(u8, trimmed, "--") and trimmed.len > 0) {
                if (sql_start == 0) {
                    sql_start = line_no;
                }
            }
        }

        if (version == null or description == null or sql_start == 0) {
            if (description) |d| allocator.free(d);
            if (rollback_sql) |r| allocator.free(r);
            return error.InvalidMigrationFormat;
        }

        // [...] SQL [...]
        var sql_buf = std.ArrayList(u8).empty;
        defer sql_buf.deinit(allocator);
        var lines2 = std.mem.splitScalar(u8, content, '\n');
        var l: usize = 0;
        while (lines2.next()) |line| : (l += 1) {
            if (l >= sql_start) {
                try sql_buf.appendSlice(allocator, line);
                try sql_buf.append(allocator, '\n');
            }
        }

        return .{
            .version = version.?,
            .description = description.?,
            .sql = try sql_buf.toOwnedSlice(allocator),
            .rollback_sql = rollback_sql,
        };
    }

    /// [...] V{version}__{description}.sql Parse version and description from filename
    pub fn parseMigrationFilename(filename: []const u8) ?struct { version: i64, description: []const u8 } {
        // [...]: V{YYYYMMDDHHMMSS}__{description}.sql
        if (!std.mem.startsWith(u8, filename, "V")) return null;
        if (!std.mem.endsWith(u8, filename, ".sql")) return null;

        const inner = filename[1 .. filename.len - 4]; // Strip V prefix and .sql suffix

        const sep = std.mem.indexOf(u8, inner, "__") orelse return null;
        const ver_str = inner[0..sep];
        const desc = inner[sep + 2 ..];

        const version = std.fmt.parseInt(i64, ver_str, 10) catch return null;
        return .{ .version = version, .description = desc };
    }
};

/// [...] SHA256 [...]
fn computeChecksum(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);

    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    return encodeHex(allocator, &hash);
}

/// Encode byte slice as hex string
fn encodeHex(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    var result = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0F];
    }
    return result;
}

test "MigrationRunner basic" {
    const allocator = std.testing.allocator;
    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();

    try runner.addMigration(20260101000000, "create users table",
        \\CREATE TABLE users (id BIGINT PRIMARY KEY, name VARCHAR(255));
    );

    try std.testing.expectEqual(@as(usize, 1), runner.getTotalCount());
    try std.testing.expectEqual(@as(usize, 0), runner.getAppliedCount());
}

test "MigrationRunner pending" {
    const allocator = std.testing.allocator;
    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();

    try runner.addMigration(20260101000000, "v1",
        \\CREATE TABLE t1 (id INT);
    );
    try runner.addMigration(20260102000000, "v2",
        \\CREATE TABLE t2 (id INT);
    );

    // Record v1 as applied
    try runner.recordMigration(20260101000000, "v1", "abc123", 100, true);

    // SAFETY: Buffer is immediately filled by getPendingMigrations() and never read uninitialized
    var buf: [10]MigrationEntry = undefined;
    const pending = runner.getPendingMigrations(&buf);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(@as(i64, 20260102000000), pending[0].version);
}

test "MigrationRunner history table DDL" {
    const allocator = std.testing.allocator;
    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();

    const ddl = try runner.generateHistoryTableDDL();
    defer allocator.free(ddl);

    try std.testing.expect(std.mem.containsAtLeast(u8, ddl, 1, "CREATE TABLE"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ddl, 1, "_zigmodu_migrations"));
}

test "MigrationRunner status tracking" {
    const allocator = std.testing.allocator;
    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();

    try runner.addMigration(20260101000000, "v1", "CREATE TABLE t1;");
    try runner.addMigration(20260102000000, "v2", "CREATE TABLE t2;");

    try runner.recordMigration(20260101000000, "v1", "abc", 50, true);
    try runner.recordMigration(20260102000000, "v2", "def", 30, false);

    var status_buf: [10]MigrationStatusEntry = undefined;
    const statuses = runner.getMigrationStatus(&status_buf);
    try std.testing.expectEqual(@as(usize, 2), statuses.len);
    try std.testing.expectEqual(MigrationStatus.applied, statuses[0].status);
    try std.testing.expectEqual(MigrationStatus.failed, statuses[1].status);
}

test "MigrationRunner checksum validation" {
    const allocator = std.testing.allocator;
    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();

    try runner.addMigration(20260101000000, "v1", "CREATE TABLE t1;");
    try runner.recordMigration(20260101000000, "v1", "wrong_checksum", 50, true);

    const valid = try runner.validateChecksums();
    try std.testing.expect(!valid);
}

test "MigrationRunner persists history and skips applied on re-run" {
    const allocator = std.testing.allocator;
    const sqlx = @import("../sqlx/sqlx.zig");
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    {
        var runner = MigrationRunner.init(allocator);
        defer runner.deinit();
        try runner.addMigration(20260101000000, "orders", "CREATE TABLE orders (id INTEGER PRIMARY KEY);");
        try runner.run(&client);
        try std.testing.expectEqual(@as(usize, 1), runner.getAppliedCount());
    }
    {
        // A fresh runner on the same database must load V1 as applied and
        // skip re-running it (history count stays 1, no duplicate record).
        var runner2 = MigrationRunner.init(allocator);
        defer runner2.deinit();
        try runner2.addMigration(20260101000000, "orders", "CREATE TABLE orders (id INTEGER PRIMARY KEY);");
        try runner2.run(&client);
        try std.testing.expectEqual(@as(usize, 1), runner2.getAppliedCount());
        var rows = try client.queryRows(struct { version: i64 }, "SELECT version FROM _zigmodu_migrations", &.{});
        defer rows.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    }
    {
        // An added migration on top applies while V1 stays skipped → 2 applied.
        var runner3 = MigrationRunner.init(allocator);
        defer runner3.deinit();
        try runner3.addMigration(20260101000000, "orders", "CREATE TABLE orders (id INTEGER PRIMARY KEY);");
        try runner3.addMigration(20260102000000, "indexes", "CREATE INDEX idx_orders_id ON orders (id);");
        try runner3.run(&client);
        try std.testing.expectEqual(@as(usize, 2), runner3.getAppliedCount());
    }
}

test "MigrationRunner add with rollback" {
    const allocator = std.testing.allocator;
    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();

    try runner.addMigrationWithRollback(20260101000000, "v1", "CREATE TABLE t1;", "DROP TABLE t1;");

    try std.testing.expectEqual(@as(usize, 1), runner.getTotalCount());
    try std.testing.expect(runner.migrations.items[0].rollback_sql != null);
}

test "MigrationLoader parse filename" {
    const parsed = MigrationLoader.parseMigrationFilename("V20260101120000__create_users_table.sql").?;
    try std.testing.expectEqual(@as(i64, 20260101120000), parsed.version);
    try std.testing.expectEqualStrings("create_users_table", parsed.description);
}

test "MigrationLoader parse filename - invalid" {
    try std.testing.expect(MigrationLoader.parseMigrationFilename("not_valid.sql") == null);
    try std.testing.expect(MigrationLoader.parseMigrationFilename("Vabc__desc.sql") == null);
}

test "MigrationLoader parse migration file content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const content =
        \\-- version: 20260101000000
        \\-- description: Create users table
        \\-- rollback: DROP TABLE users;
        \\CREATE TABLE users (
        \\    id BIGINT PRIMARY KEY,
        \\    name VARCHAR(255) NOT NULL
        \\);
        \\
        \\CREATE INDEX idx_users_name ON users(name);
    ;

    const result = try MigrationLoader.parseMigrationFile(allocator, content);

    try std.testing.expectEqual(@as(i64, 20260101000000), result.version);
    try std.testing.expectEqualStrings("Create users table", result.description);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.sql, 1, "CREATE TABLE"));
    try std.testing.expectEqualStrings("DROP TABLE users;", result.rollback_sql.?);
}

test "splitSqlStatements handles quotes, comments and dollar quotes" {
    const allocator = std.testing.allocator;
    const sql =
        \\CREATE TABLE a (id INT);
        \\INSERT INTO t VALUES ('x;y');
        \\CREATE TABLE "semi;colon" (id INT);
        \\-- comment ; ignored
        \\/* block ; comment */
        \\SELECT 1;
        \\CREATE FUNCTION f() RETURNS void AS $$ BEGIN PERFORM 1; END; $$ LANGUAGE plpgsql;
        \\SELECT 2
    ;
    const stmts = try splitSqlStatements(allocator, sql);
    defer {
        for (stmts) |s| allocator.free(s);
        allocator.free(stmts);
    }
    try std.testing.expectEqual(@as(usize, 6), stmts.len);
    try std.testing.expect(std.mem.indexOf(u8, stmts[1], "'x;y'") != null);
    try std.testing.expect(std.mem.indexOf(u8, stmts[2], "\"semi;colon\"") != null);
    // PL/pgSQL body keeps its internal semicolons.
    try std.testing.expect(std.mem.indexOf(u8, stmts[4], "BEGIN PERFORM 1; END;") != null);
    // Trailing statement without a semicolon is preserved.
    try std.testing.expectEqualStrings("SELECT 2", stmts[5]);
}

test "splitSqlStatements dollar-tag and parameter placeholder" {
    const allocator = std.testing.allocator;
    const sql =
        \\DO $fn$ BEGIN EXECUTE 'x;y'; END; $fn$;
        \\SELECT $1;
    ;
    const stmts = try splitSqlStatements(allocator, sql);
    defer {
        for (stmts) |s| allocator.free(s);
        allocator.free(stmts);
    }
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    try std.testing.expect(std.mem.indexOf(u8, stmts[0], "BEGIN EXECUTE 'x;y'; END;") != null);
    // $1 is a parameter placeholder, not a dollar-quote tag.
    try std.testing.expectEqualStrings("SELECT $1", stmts[1]);
}
