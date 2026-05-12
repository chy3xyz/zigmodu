const std = @import("std");
const Time = @import("../core/Time.zig");

/// 数据库迁移条目
pub const MigrationEntry = struct {
    /// 版本号 (时间戳格式: YYYYMMDDHHMMSS)
    version: i64,
    /// 迁移描述
    description: []const u8,
    /// SQL 内容
    sql: []const u8,
    /// 回滚 SQL (可选)
    rollback_sql: ?[]const u8 = null,
    /// 校验和 (SHA256)
    checksum: ?[]const u8 = null,
};

/// 已执行的迁移记录
pub const AppliedMigration = struct {
    version: i64,
    description: []const u8,
    applied_at: i64,
    checksum: []const u8,
    execution_time_ms: u64,
    success: bool,
};

/// 迁移状态
pub const MigrationStatus = enum {
    pending,
    applied,
    failed,
    skipped,
};

/// 迁移状态条目 (用于 getMigrationStatus)
pub const MigrationStatusEntry = struct {
    version: i64,
    description: []const u8,
    status: MigrationStatus,
};

/// 迁移执行器
/// 类似 Flyway / Liquibase 的数据库迁移管理
pub const MigrationRunner = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    migrations: std.ArrayList(MigrationEntry),
    history: std.ArrayList(AppliedMigration),
    /// 迁移历史表名
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
    }

    /// 注册迁移
    pub fn addMigration(self: *Self, version: i64, description: []const u8, sql: []const u8) !void {
        const desc_copy = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_copy);

        const sql_copy = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(sql_copy);

        // 计算校验和
        const checksum = try computeChecksum(self.allocator, sql);

        try self.migrations.append(self.allocator, .{
            .version = version,
            .description = desc_copy,
            .sql = sql_copy,
            .checksum = checksum,
        });
    }

    /// 注册带回滚的迁移
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

    /// 获取待执行的迁移列表
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

    /// 获取所有迁移的状态
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

    /// 记录迁移执行结果
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

    /// 获取已应用的迁移数量
    pub fn getAppliedCount(self: *Self) usize {
        var count: usize = 0;
        for (self.history.items) |h| {
            if (h.success) count += 1;
        }
        return count;
    }

    /// 获取迁移总数
    pub fn getTotalCount(self: *Self) usize {
        return self.migrations.items.len;
    }

    /// Execute all pending migrations against a database client.
    /// Runs each migration's SQL in order, records results in the history table.
    pub fn run(self: *Self, client: anytype) !void {
        // Ensure history table exists
        _ = client.exec(self.generateHistoryTableDDL() catch return error.OutOfMemory, &.{}) catch return error.QueryExecutionFailed;

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
            const result = client.exec(migration.sql, &.{});
            const elapsed_ms = @import("../core/Time.zig").monotonicNowMilliseconds() - start_ms;

            const checksum = migration.checksum orelse "";
            if (result) |_| {
                try self.recordMigration(migration.version, migration.description, checksum, @intCast(elapsed_ms), true);
            } else |_| {
                try self.recordMigration(migration.version, migration.description, checksum, @intCast(elapsed_ms), false);
                return error.MigrationFailed;
            }
        }
    }

    /// 生成迁移历史表创建 SQL
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

    /// 验证已应用迁移的校验和
    pub fn validateChecksums(self: *Self) !bool {
        for (self.history.items) |applied| {
            if (!applied.success) continue;

            for (self.migrations.items) |migration| {
                if (migration.version == applied.version) {
                    if (migration.checksum) |expected_cs| {
                        if (!std.mem.eql(u8, expected_cs, applied.checksum)) {
                            std.log.err(
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

/// SQL 迁移文件加载器
pub const MigrationLoader = struct {
    /// 从 SQL 文件字符串加载迁移
    /// 期望格式: -- version: YYYYMMDDHHMMSS
    ///           -- description: xxx
    ///           -- rollback: ... (可选)
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

        // 提取 SQL 内容
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

    /// 从 V{version}__{description}.sql 文件名解析版本和描述
    pub fn parseMigrationFilename(filename: []const u8) ?struct { version: i64, description: []const u8 } {
        // 格式: V{YYYYMMDDHHMMSS}__{description}.sql
        if (!std.mem.startsWith(u8, filename, "V")) return null;
        if (!std.mem.endsWith(u8, filename, ".sql")) return null;

        const inner = filename[1 .. filename.len - 4]; // 去掉 V 和 .sql

        const sep = std.mem.indexOf(u8, inner, "__") orelse return null;
        const ver_str = inner[0..sep];
        const desc = inner[sep + 2 ..];

        const version = std.fmt.parseInt(i64, ver_str, 10) catch return null;
        return .{ .version = version, .description = desc };
    }
};

/// 计算字符串的 SHA256 校验和
fn computeChecksum(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);

    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    return encodeHex(allocator, &hash);
}

/// 将字节切片编码为十六进制字符串
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
