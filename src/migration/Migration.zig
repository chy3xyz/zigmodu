const std = @import("std");
const Time = @import("../core/Time.zig");
const DistributedLock = @import("../core/DistributedLock.zig");

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
                if (stmt.len > 0) {
                    const copy = try allocator.dupe(u8, stmt);
                    errdefer allocator.free(copy);
                    try out.append(allocator, copy);
                }
                i += 1;
                start = i;
            },
            else => i += 1,
        }
    }
    const tail = std.mem.trim(u8, sql[start..], " \t\r\n");
    if (tail.len > 0) {
        // The copy's guard ends with this block, before `toOwnedSlice` — that
        // call failing frees `out`'s items, so a guard still armed here would
        // free this one a second time.
        const copy = try allocator.dupe(u8, tail);
        errdefer allocator.free(copy);
        try out.append(allocator, copy);
    }
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

/// Remove SQL comments from one statement before it reaches a driver.
///
/// The splitter already has to know where comments are (a `;` inside one must
/// not end the statement), but it deliberately kept them in the emitted text —
/// so a migration file's header comment or an inline `-- note` was sent to the
/// server as part of the DDL. Comments are legal SQL and most servers take
/// them; a server that does not (HeliosDB, observed by a consumer) fails the
/// whole migration on the first one.
///
/// Stripping happens after splitting, at the last point that can still tell a
/// comment from the things that merely look like one:
///   - `-- …` and `/* … */` outside literals become **one space** (so
///     `a/*x*/b` does not turn into `ab`);
///   - MySQL executable comments `/*! … */` and optimizer hints `/*+ … */`
///     are copied verbatim — they are SQL, not commentary;
///   - single-quoted strings (`''` escape), double-quoted identifiers and
///     dollar-quoted bodies are copied byte for byte (`'-- not a comment'`
///     keeps its text).
fn stripSqlComments(allocator: std.mem.Allocator, sql: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < sql.len) {
        switch (sql[i]) {
            '\'' => {
                const start = i;
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
                try out.appendSlice(allocator, sql[start..i]);
            },
            '"' => {
                const start = i;
                i += 1;
                while (i < sql.len and sql[i] != '"') i += 1;
                if (i < sql.len) i += 1;
                try out.appendSlice(allocator, sql[start..i]);
            },
            '$' => {
                if (dollarQuoteTagLen(sql, i)) |tag_len| {
                    const start = i;
                    const tag = sql[i .. i + tag_len];
                    i += tag_len;
                    if (std.mem.indexOfPos(u8, sql, i, tag)) |close| {
                        i = close + tag.len;
                    } else {
                        i = sql.len;
                    }
                    try out.appendSlice(allocator, sql[start..i]);
                } else {
                    try out.append(allocator, sql[i]);
                    i += 1;
                }
            },
            '-' => {
                if (i + 1 < sql.len and sql[i + 1] == '-') {
                    while (i < sql.len and sql[i] != '\n') i += 1;
                    try out.append(allocator, ' ');
                } else {
                    try out.append(allocator, sql[i]);
                    i += 1;
                }
            },
            '/' => {
                if (i + 1 < sql.len and sql[i + 1] == '*') {
                    const executable = i + 2 < sql.len and (sql[i + 2] == '!' or sql[i + 2] == '+');
                    const start = i;
                    i += 2;
                    while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) i += 1;
                    i = @min(i + 2, sql.len);
                    if (executable) {
                        try out.appendSlice(allocator, sql[start..i]);
                    } else {
                        try out.append(allocator, ' ');
                    }
                } else {
                    try out.append(allocator, sql[i]);
                    i += 1;
                }
            },
            else => {
                try out.append(allocator, sql[i]);
                i += 1;
            },
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Database migration entry
pub const MigrationEntry = struct {
    /// Version number (timestamp format: YYYYMMDDHHMMSS)
    version: i64,
    /// Migration description
    description: []const u8,
    /// SQL body
    sql: []const u8,
    /// Rollback SQL (optional)
    rollback_sql: ?[]const u8 = null,
    /// Checksum (SHA256)
    checksum: ?[]const u8 = null,
};

/// Applied migration record
pub const AppliedMigration = struct {
    version: i64,
    description: []const u8,
    applied_at: i64,
    checksum: []const u8,
    execution_time_ms: u64,
    success: bool,
};

/// Migration status
pub const MigrationStatus = enum {
    pending,
    applied,
    failed,
    skipped,
};

/// Migration status entry (for getMigrationStatus)
pub const MigrationStatusEntry = struct {
    version: i64,
    description: []const u8,
    status: MigrationStatus,
};

/// Migration runner
/// Database migration management similar to Flyway / Liquibase
pub const MigrationRunner = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    migrations: std.ArrayList(MigrationEntry),
    history: std.ArrayList(AppliedMigration),
    /// Migration history table name
    history_table: []const u8,
    /// Cross-instance guard so a rolling deploy cannot apply the same DDL
    /// twice. Default null = no guard (single instance / local dev).
    lock: ?DistributedLock.Lock = null,
    lock_ttl_ms: u64 = 300_000,
    lock_name: []const u8 = "zigmodu:migration",

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

    /// Guard `run()` with a cross-instance lock. `ttl_ms` must exceed the
    /// slowest migration: it is the window after which a crashed holder's lock
    /// is considered stale and may be taken over. The lock object must outlive
    /// the runner.
    pub fn setLock(self: *Self, lock: DistributedLock.Lock, ttl_ms: u64) void {
        self.lock = lock;
        self.lock_ttl_ms = ttl_ms;
    }

    /// Register a migration
    pub fn addMigration(self: *Self, version: i64, description: []const u8, sql: []const u8) !void {
        const desc_copy = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_copy);

        const sql_copy = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(sql_copy);

        // Compute the checksum
        const checksum = try computeChecksum(self.allocator, sql);

        try self.migrations.append(self.allocator, .{
            .version = version,
            .description = desc_copy,
            .sql = sql_copy,
            .checksum = checksum,
        });
    }

    /// Register a migration together with its rollback SQL
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

    /// Record a migration as already applied **without executing it** — for
    /// bootstrapping an existing database whose migrations were applied
    /// manually (e.g. legacy `psql -f` runs). Requires the history table.
    pub fn markApplied(self: *Self, client: anytype, version: i64) !void {
        const ddl = self.generateHistoryTableDDL() catch return error.OutOfMemory;
        defer self.allocator.free(ddl);
        _ = client.exec(ddl, &.{}) catch return error.QueryExecutionFailed;

        var description: []const u8 = "marked applied";
        var checksum: []const u8 = "";
        for (self.migrations.items) |m| {
            if (m.version == version) {
                description = m.description;
                checksum = m.checksum orelse "";
                break;
            }
        }
        try self.insertHistoryRecord(client, version, description, checksum, 0, true);
        // Reload from DB so the in-memory history reflects the bootstrap
        // without double-counting (loadHistory replaces the snapshot).
        try self.loadHistory(client);
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

    /// Get the status of every registered migration
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

    /// Record the result of a migration run
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

    /// Get the total number of registered migrations
    pub fn getTotalCount(self: *Self) usize {
        return self.migrations.items.len;
    }

    /// Execute all pending migrations against a database client.
    /// Runs each migration's SQL in order, records results in the history table.
    pub fn run(self: *Self, client: anytype) !void {
        // Cross-instance guard first: two replicas starting together must not
        // race on the history table or the DDL itself.
        var locked = false;
        if (self.lock) |l| {
            const acquired = try l.tryAcquire(self.lock_name, self.lock_ttl_ms);
            if (!acquired) return error.MigrationLocked;
            locked = true;
        }
        defer if (locked) self.lock.?.release(self.lock_name);

        // Ensure history table exists
        const ddl = self.generateHistoryTableDDL() catch return error.OutOfMemory;
        defer self.allocator.free(ddl);
        _ = client.exec(ddl, &.{}) catch return error.QueryExecutionFailed;
        // Load previously applied migrations from the DB — a fresh runner must
        // not re-run them (history is persisted, not just in-memory).
        try self.loadHistory(client);

        // Fail fast on duplicate versions in the registered list: the second
        // occurrence would otherwise be skipped as "already applied" after the
        // first one executes, silently dropping a migration.
        var seen = std.AutoHashMap(i64, void).init(self.allocator);
        defer seen.deinit();
        for (self.migrations.items) |migration| {
            if (seen.contains(migration.version)) return error.DuplicateVersion;
            try seen.put(migration.version, {});
        }

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
                // Comments are legal SQL, but a server that rejects them
                // (HeliosDB) turned a header comment into a failed migration.
                // Strip here — after splitting, before exec — and drop chunks
                // that were only commentary.
                const stripped = try stripSqlComments(self.allocator, stmt);
                defer self.allocator.free(stripped);
                const trimmed = std.mem.trim(u8, stripped, " \t\r\n");
                if (trimmed.len == 0) continue;
                _ = client.exec(trimmed, &.{}) catch |err| {
                    // The only skippable failure is a redundant `ALTER TABLE …
                    // ADD COLUMN` — one whose postcondition provably already
                    // holds. Everything else (syntax error, missing table,
                    // permission denied) fails the migration: recording it as
                    // applied would skip it forever, i.e. silent schema drift.
                    if (self.isRedundantAlter(client, trimmed)) {
                        std.log.info("[Migration] V{d}: ALTER TABLE ADD COLUMN skipped — target column already exists: {s}", .{ migration.version, trimmed });
                        continue;
                    }
                    // warn, not err: the failure itself is returned to the
                    // caller as error.MigrationFailed, and an err-level line
                    // here trips the test suite's log gate (scripts/test-runner.zig)
                    // for the failure-path tests that must exercise this branch.
                    std.log.warn("[Migration] Error executing V{d} statement: {s} ({s})", .{ migration.version, trimmed, @errorName(err) });
                    mig_ok = false;
                    break;
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
        // The DB history is the authoritative snapshot — replace, don't append
        // (markApplied + run can both load). Free the previously loaded
        // entries first (deinit only sees what remains after this).
        for (self.history.items) |h| {
            self.allocator.free(h.description);
            self.allocator.free(h.checksum);
        }
        self.history.clearRetainingCapacity();
        const sql = try self.allocator.print("SELECT version, description, applied_at, checksum, execution_time_ms, success FROM {s} ORDER BY version", .{self.history_table});
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
        const sql = try self.allocator.print("INSERT INTO {s} (version, description, applied_at, checksum, execution_time_ms, success) VALUES (?, ?, ?, ?, ?, ?)", .{self.history_table});
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

    /// True when a failed `ALTER TABLE <t> ADD [COLUMN] <c> …` is provably
    /// redundant — the column it was supposed to add already exists, which is
    /// the one failure a re-run migration is allowed to skip.
    ///
    /// The drivers cannot answer this from the error value: SQLite reports a
    /// duplicate column and a syntax error as the same `error.DatabaseError`,
    /// PostgreSQL folds SQLSTATE 42701 (duplicate_column) and 42601
    /// (syntax_error) into `error.DatabaseError` alike, MySQL maps
    /// ER_DUP_FIELDNAME to that same name, and no driver surfaces the message
    /// through `exec`. So the proof is the postcondition instead of the error:
    /// `SELECT <c> FROM <t> LIMIT 0` compiles on all three dialects iff the
    /// column exists. A failed ALTER whose postcondition does not hold —
    /// missing table, bad syntax, refused permission — is not exempted here
    /// and fails the migration.
    fn isRedundantAlter(self: *Self, client: anytype, stmt: []const u8) bool {
        const target = alterAddColumnTarget(stmt) orelse return false;
        // Both names passed isBareIdentifier, so interpolation is safe
        // (placeholders cannot bind identifiers anyway).
        const probe = self.allocator.print("SELECT {s} FROM {s} LIMIT 0", .{ target.column, target.table }) catch return false;
        defer self.allocator.free(probe);
        _ = client.exec(probe, &.{}) catch return false;
        return true;
    }

    /// Generate the migration history table creation SQL
    pub fn generateHistoryTableDDL(self: *Self) ![]const u8 {
        return self.allocator.print(
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

    /// Validate the checksums of applied migrations
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

const AlterAddColumn = struct { table: []const u8, column: []const u8 };

/// Extract (table, column) from `ALTER TABLE <t> ADD [COLUMN] <c> …`, or null
/// for every other shape: ADD CONSTRAINT / PRIMARY KEY / INDEX / RENAME /
/// DROP, quoted identifiers, multi-action statements — only a plain column
/// add may earn the redundancy exemption, everything else fails the
/// migration. Keyword matching is case-insensitive; identifiers must be bare
/// because they are interpolated into the probe statement.
fn alterAddColumnTarget(stmt: []const u8) ?AlterAddColumn {
    // A top-level comma separates further actions (`ADD COLUMN c INT, ADD
    // COLUMN d INT`): exempting on the first column would silently skip the
    // rest, so the whole statement is refused the exemption.
    if (hasTopLevelComma(stmt)) return null;

    var it = std.mem.tokenizeAny(u8, stmt, " \t\r\n");
    const kw_alter = it.next() orelse return null;
    if (!std.ascii.eqlIgnoreCase(kw_alter, "alter")) return null;
    const kw_table = it.next() orelse return null;
    if (!std.ascii.eqlIgnoreCase(kw_table, "table")) return null;
    var tok = it.next() orelse return null;
    if (std.ascii.eqlIgnoreCase(tok, "if")) { // PostgreSQL: ALTER TABLE IF EXISTS t
        const kw_exists = it.next() orelse return null;
        if (!std.ascii.eqlIgnoreCase(kw_exists, "exists")) return null;
        tok = it.next() orelse return null;
    }
    const table = tok;
    if (!isBareIdentifier(table)) return null;
    const kw_add = it.next() orelse return null;
    if (!std.ascii.eqlIgnoreCase(kw_add, "add")) return null;
    var col = it.next() orelse return null;
    if (std.ascii.eqlIgnoreCase(col, "column")) {
        col = it.next() orelse return null;
    }
    if (std.ascii.eqlIgnoreCase(col, "if")) { // MySQL/MariaDB: ADD COLUMN IF NOT EXISTS c
        const kw_not = it.next() orelse return null;
        if (!std.ascii.eqlIgnoreCase(kw_not, "not")) return null;
        const kw_exists = it.next() orelse return null;
        if (!std.ascii.eqlIgnoreCase(kw_exists, "exists")) return null;
        col = it.next() orelse return null;
    }
    // ADD <constraint-kind> … is not a column add.
    const constraint_kinds = [_][]const u8{ "constraint", "primary", "foreign", "unique", "index", "key", "check", "fulltext", "spatial" };
    for (constraint_kinds) |kw| {
        if (std.ascii.eqlIgnoreCase(col, kw)) return null;
    }
    if (!isBareIdentifier(col)) return null;
    return .{ .table = table, .column = col };
}

/// Same shape rule as `sqlx.validateIdentifier` (`[A-Za-z_][A-Za-z0-9_.]*`),
/// kept local so this file stays free of a driver import.
fn isBareIdentifier(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s, 0..) |c, i| {
        const ok = switch (c) {
            'a'...'z', 'A'...'Z', '_' => true,
            '0'...'9', '.' => i > 0,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

/// True when `sql` has a comma outside parens and string/identifier quotes.
fn hasTopLevelComma(sql: []const u8) bool {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < sql.len) : (i += 1) {
        switch (sql[i]) {
            '\'' => {
                i += 1;
                while (i < sql.len and sql[i] != '\'') i += 1;
            },
            '"' => {
                i += 1;
                while (i < sql.len and sql[i] != '"') i += 1;
            },
            '(' => depth += 1,
            ')' => depth -|= 1,
            ',' => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
}

/// SQL migration file loader
pub const MigrationLoader = struct {
    /// Load a migration from a SQL file string
    /// Expected format: -- version: YYYYMMDDHHMMSS
    ///           -- description: xxx
    /// -- rollback: ... (optional)
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

        // Extract the SQL content
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

    /// Parse version and description from a V{version}__{description}.sql filename
    pub fn parseMigrationFilename(filename: []const u8) ?struct { version: i64, description: []const u8 } {
        // Format: V{YYYYMMDDHHMMSS}__{description}.sql
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

/// Compute the SHA256 checksum of a string
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

test "stripSqlComments drops comments, keeps literals and executable comments" {
    const allocator = std.testing.allocator;

    // Header + inline line comment; the comment inside the string literal is
    // text, not a comment.
    {
        const sql =
            \\-- migration header
            \\CREATE TABLE t (a TEXT DEFAULT '-- not a comment', b INT /* inline */);
        ;
        const got = try stripSqlComments(allocator, sql);
        defer allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "-- migration header") == null);
        try std.testing.expect(std.mem.indexOf(u8, got, "not a comment") != null);
        try std.testing.expect(std.mem.indexOf(u8, got, "inline") == null);
        // The block comment became a space, not nothing: tokens on either side
        // must not fuse.
        try std.testing.expect(std.mem.indexOf(u8, got, "b INT ") != null);
    }

    // MySQL executable comments and optimizer hints are SQL: kept verbatim.
    {
        const sql = "/*!40101 SET NAMES utf8 */ SELECT /*+ MAX_EXECUTION_TIME(1000) */ 1";
        const got = try stripSqlComments(allocator, sql);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(sql, got);
    }

    // Dollar-quoted bodies keep their `--` and `/* */` text.
    {
        const sql = "CREATE FUNCTION f() RETURNS void AS $$ -- keep /* this */ $$ LANGUAGE plpgsql";
        const got = try stripSqlComments(allocator, sql);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(sql, got);
    }

    // A statement that was only commentary becomes empty (the caller skips it).
    {
        const got = try stripSqlComments(allocator, "-- only a note\n/* and a block */");
        defer allocator.free(got);
        try std.testing.expectEqual(@as(usize, 0), std.mem.trim(u8, got, " \t\r\n").len);
    }
}

test "MigrationRunner sends statements without comments" {
    const allocator = std.testing.allocator;
    const sqlx = @import("../sqlx/sqlx.zig");

    const Recording = struct {
        allocator: std.mem.Allocator,
        statements: std.ArrayList([]const u8) = .empty,

        fn deinit(self: *@This()) void {
            for (self.statements.items) |s| self.allocator.free(s);
            self.statements.deinit(self.allocator);
        }
        pub fn exec(self: *@This(), sql: []const u8, args: []const sqlx.Value) !sqlx.ExecResult {
            _ = args;
            try self.statements.append(self.allocator, try self.allocator.dupe(u8, sql));
            return .{};
        }
        pub fn queryRows(self: *@This(), comptime T: type, sql: []const u8, args: []const sqlx.Value) !MockRows(T) {
            _ = self;
            _ = sql;
            _ = args;
            return .{};
        }
    };

    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();
    try runner.addMigration(20260101000000, "comments everywhere",
        \\-- header note
        \\CREATE TABLE t (a INT); /* trailing */
        \\-- between statements
        \\INSERT INTO t VALUES (1); -- after
        \\-- only a comment
        \\;
        \\SELECT 'x;y' /* keep the ; inside the literal */;
    );

    var client = Recording{ .allocator = allocator };
    defer client.deinit();
    try runner.run(&client);

    var migration_statements: usize = 0;
    for (client.statements.items) |s| {
        // Only statements that came from the migration file: the generated
        // history DDL and the history INSERT are comment-free by construction.
        if (std.mem.indexOf(u8, s, "_zigmodu_migrations") != null) continue;
        migration_statements += 1;
        try std.testing.expect(std.mem.indexOf(u8, s, "--") == null);
        try std.testing.expect(std.mem.indexOf(u8, s, "/*") == null);
    }
    // Three executable statements: CREATE, INSERT, SELECT. The comment-only
    // chunk (`-- after` + the standalone note before the bare `;`) and the
    // trailing block comment never reach the client.
    try std.testing.expectEqual(@as(usize, 3), migration_statements);
    // The quoted semicolon survived (the splitter and the stripper both let
    // literals through untouched); the history INSERT is the last statement, so
    // the whole recording is searched rather than its tail.
    var saw_literal = false;
    for (client.statements.items) |s| {
        if (std.mem.indexOf(u8, s, "'x;y'") != null) saw_literal = true;
    }
    try std.testing.expect(saw_literal);
}

test "MigrationRunner rejects duplicate versions" {
    const allocator = std.testing.allocator;
    const sqlx = @import("../sqlx/sqlx.zig");
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();
    try runner.addMigration(1, "a", "SELECT 1;");
    try runner.addMigration(1, "b", "SELECT 2;"); // same version — must fail fast

    try std.testing.expectError(error.DuplicateVersion, runner.run(&client));
}

/// Test client for the ALTER-exemption paths. A real driver answers a
/// rejected statement with an error **and** an err-level log line, and the
/// suite's runner fails any test that logs one (scripts/test-runner.zig) — so
/// the failing/redundant ALTER cases run against this log-free double instead
/// of sqlite. (`run` takes `client: anytype`; only `exec` and `queryRows` are
/// touched on these paths.)
const MockMigrationClient = struct {
    const sqlx = @import("../sqlx/sqlx.zig");

    allocator: std.mem.Allocator,
    /// `exec` fails with error.MockFailed when the statement contains this.
    fail_substring: []const u8,
    /// Whether the redundancy probe (`SELECT <col> FROM <table> LIMIT 0`)
    /// answers success, i.e. the failed statement's postcondition holds.
    probe_ok: bool,
    /// The `success` argument of every INSERT into the history table.
    inserted_success: std.ArrayList(bool) = .empty,

    fn deinit(self: *@This()) void {
        self.inserted_success.deinit(self.allocator);
    }

    pub fn exec(self: *@This(), sql: []const u8, args: []const sqlx.Value) !sqlx.ExecResult {
        if (std.mem.indexOf(u8, sql, self.fail_substring) != null) return error.MockFailed;
        if (std.mem.startsWith(u8, sql, "SELECT ") and std.mem.endsWith(u8, sql, " LIMIT 0")) {
            if (!self.probe_ok) return error.MockFailed;
            return .{};
        }
        if (std.mem.startsWith(u8, sql, "INSERT INTO ")) {
            try self.inserted_success.append(self.allocator, args[5].bool);
        }
        return .{};
    }

    pub fn queryRows(self: *@This(), comptime T: type, sql: []const u8, args: []const sqlx.Value) !MockRows(T) {
        _ = self;
        _ = sql;
        _ = args;
        return .{};
    }
};

fn MockRows(comptime T: type) type {
    return struct {
        items: []const T = &.{},
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
}

test "MigrationRunner: a failing ALTER fails the migration and stays unapplied" {
    const allocator = std.testing.allocator;
    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();
    // The ALTER's target can never exist: both the statement and the
    // redundancy probe fail, so the migration must fail rather than being
    // recorded as applied (silent schema drift).
    try runner.addMigration(20260101000000, "bad alter", "ALTER TABLE no_such_table ADD COLUMN c INTEGER;");

    var client = MockMigrationClient{ .allocator = allocator, .fail_substring = "no_such_table", .probe_ok = false };
    defer client.deinit();

    try std.testing.expectError(error.MigrationFailed, runner.run(&client));
    try std.testing.expectEqual(@as(usize, 0), runner.getAppliedCount());

    var status_buf: [4]MigrationStatusEntry = undefined;
    const statuses = runner.getMigrationStatus(&status_buf);
    try std.testing.expectEqual(@as(usize, 1), statuses.len);
    try std.testing.expectEqual(MigrationStatus.failed, statuses[0].status);

    // The run persisted the outcome as a failure — a fresh runner retries the
    // migration instead of skipping it as applied.
    try std.testing.expectEqual(@as(usize, 1), client.inserted_success.items.len);
    try std.testing.expectEqual(false, client.inserted_success.items[0]);
}

test "MigrationRunner: a redundant ALTER TABLE ADD COLUMN is the one exempt failure" {
    const allocator = std.testing.allocator;
    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();
    try runner.addMigration(20260101000000, "add c", "ALTER TABLE t ADD COLUMN c INTEGER;");

    // The driver rejects the duplicate ADD COLUMN, but the postcondition
    // probe finds the column already there — the one failure a re-run may skip.
    var client = MockMigrationClient{ .allocator = allocator, .fail_substring = "ADD COLUMN", .probe_ok = true };
    defer client.deinit();

    try runner.run(&client);
    try std.testing.expectEqual(@as(usize, 1), runner.getAppliedCount());
    try std.testing.expectEqual(@as(usize, 1), client.inserted_success.items.len);
    try std.testing.expectEqual(true, client.inserted_success.items[0]);
}

test "alterAddColumnTarget parses only plain ADD COLUMN forms" {
    const t1 = alterAddColumnTarget("ALTER TABLE t ADD COLUMN c INTEGER").?;
    try std.testing.expectEqualStrings("t", t1.table);
    try std.testing.expectEqualStrings("c", t1.column);
    // Case-insensitive keywords; MySQL shorthand without the COLUMN keyword;
    // PostgreSQL IF EXISTS; MySQL IF NOT EXISTS.
    const t2 = alterAddColumnTarget("alter table if exists s.t add c integer").?;
    try std.testing.expectEqualStrings("s.t", t2.table);
    const t3 = alterAddColumnTarget("ALTER TABLE t ADD COLUMN IF NOT EXISTS c INT").?;
    try std.testing.expectEqualStrings("c", t3.column);
    // Not a column add, quoted identifiers, or several actions in one
    // statement: no exemption, the migration fails loudly instead.
    try std.testing.expect(alterAddColumnTarget("ALTER TABLE t ADD CONSTRAINT fk FOREIGN KEY (c) REFERENCES o (id)") == null);
    try std.testing.expect(alterAddColumnTarget("ALTER TABLE t ADD PRIMARY KEY (id)") == null);
    try std.testing.expect(alterAddColumnTarget("ALTER TABLE t RENAME COLUMN a TO b") == null);
    try std.testing.expect(alterAddColumnTarget("ALTER TABLE t DROP COLUMN c") == null);
    try std.testing.expect(alterAddColumnTarget("ALTER TABLE \"my table\" ADD COLUMN c INT") == null);
    try std.testing.expect(alterAddColumnTarget("ALTER TABLE t ADD COLUMN c INT, ADD COLUMN d INT") == null);
    try std.testing.expect(alterAddColumnTarget("ALTER TABLE t ADD COLUMN") == null);
    // A comma inside parens or a string literal is not a second action.
    const t4 = alterAddColumnTarget("ALTER TABLE t ADD COLUMN c DECIMAL(10,2)").?;
    try std.testing.expectEqualStrings("c", t4.column);
    const t5 = alterAddColumnTarget("ALTER TABLE t ADD COLUMN c TEXT DEFAULT 'a,b'").?;
    try std.testing.expectEqualStrings("c", t5.column);
}

test "MigrationRunner markApplied bootstraps existing migrations" {
    const allocator = std.testing.allocator;
    const sqlx = @import("../sqlx/sqlx.zig");
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();
    try runner.addMigration(20260101000000, "orders", "CREATE TABLE orders (id INTEGER PRIMARY KEY);");

    // Mark as applied without executing; a subsequent run skips it.
    try runner.markApplied(&client, 20260101000000);
    try std.testing.expectEqual(@as(usize, 1), runner.getAppliedCount());
    try runner.run(&client);
    try std.testing.expectEqual(@as(usize, 1), runner.getAppliedCount());
    var pending: [8]MigrationEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), runner.getPendingMigrations(&pending).len);
}

test "migration: a second replica refuses to run while the lock is held" {
    const allocator = std.testing.allocator;
    const SqlClient = @import("../sqlx/sqlx.zig").Client;
    var db = SqlClient.init(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 1,
        .max_idle_conns = 1,
    });
    defer db.deinit();

    var runner = MigrationRunner.init(allocator);
    defer runner.deinit();
    try runner.addMigration(20260101000000, "create widget", "CREATE TABLE widget (id INTEGER PRIMARY KEY)");

    var lock = try DistributedLock.SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, "zmodu_migration_lock", .sqlite);
    defer lock.deinit();
    runner.setLock(lock.lock(), 300_000);

    // Another replica holds the migration lock (mid-run, or crashed with an
    // unexpired TTL): this replica must not touch the schema.
    var other = try DistributedLock.SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, "zmodu_migration_lock", .sqlite);
    defer other.deinit();
    try std.testing.expect(try other.lock().tryAcquire("zigmodu:migration", 300_000));

    try std.testing.expectError(error.MigrationLocked, runner.run(&db));

    // Lock free again → the migration applies and the slot is released.
    other.lock().release("zigmodu:migration");
    try runner.run(&db);
    try std.testing.expectEqual(@as(usize, 1), runner.getAppliedCount());
    try std.testing.expect(try other.lock().tryAcquire("zigmodu:migration", 300_000));

    // Idempotent: a second run with the history persisted is a no-op.
    runner.lock = null;
    try runner.run(&db);
    try std.testing.expectEqual(@as(usize, 1), runner.getAppliedCount());
}
