//! AI run audit trail ("编排审计"): persists one row per workflow / agent /
//! approval run (run_id, kind, status, tenant, step count, duration) to a SQL
//! table and exposes `list` / `count` queries. Attach a store to
//! `Workflow.audit` and every run / resume is recorded automatically —
//! complementing the in-memory `AgentAuditLog` with durable history.

const std = @import("std");
const SqlxBackend = @import("../data.zig").SqlxBackend;
const sqlx = @import("../data.zig").sqlx;
const Time = @import("../core/Time.zig");
const SkillContext = @import("skill.zig").SkillContext;

pub const RunKind = enum { workflow, agent, approval };

pub const RunAuditEntry = struct {
    run_id: []const u8,
    kind: RunKind,
    status: []const u8,
    tenant_id: ?i64 = null,
    steps: usize = 0,
    duration_ms: i64 = 0,
    /// Actual model that served the run (empty when unknown / not captured).
    model: ?[]const u8 = null,
    /// Tokens the provider reported for this run. A durable ledger, unlike the
    /// in-memory `TokenQuota`: billing and tenant statements can be computed
    /// from these rows even after a restart.
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
};

pub const RunAuditStore = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    /// Table name — an *identifier*, interpolated into every statement below.
    /// Values are bound with `?`, identifiers cannot be, so each entry point
    /// runs it through `sqlx.validateIdentifier` first (same gate `ai.business`
    /// applies to its `EntitySpec.table`).
    table: []const u8 = "ai_run_audit",

    pub fn init(allocator: std.mem.Allocator, backend: *SqlxBackend) Self {
        return .{ .allocator = allocator, .backend = backend };
    }

    pub fn migrate(self: *Self) !void {
        try sqlx.validateIdentifier(self.table);
        const sql = try createTableSql(self.allocator, self.backend.dialect(), self.table);
        defer self.allocator.free(sql);
        _ = try self.backend.exec(sql, &.{});
        // Existing installs predate later columns (CREATE IF NOT EXISTS does not
        // add columns). Probe each one (fresh tables already have them), then
        // best-effort ALTER for legacy tables.
        const legacy_columns = [_]struct { name: []const u8, ddl: []const u8 }{
            .{ .name = "model", .ddl = "TEXT" },
            .{ .name = "prompt_tokens", .ddl = "INTEGER NOT NULL DEFAULT 0" },
            .{ .name = "completion_tokens", .ddl = "INTEGER NOT NULL DEFAULT 0" },
        };
        for (legacy_columns) |col| {
            if (try self.columnExists(col.name)) continue;
            const alter = try self.allocator.print("ALTER TABLE {s} ADD COLUMN {s} {s}", .{ self.table, col.name, col.ddl });
            defer self.allocator.free(alter);
            _ = self.backend.exec(alter, &.{}) catch |err| {
                std.log.debug("[ai.run_audit] best-effort legacy column add failed ({s})", .{@errorName(err)});
            };
        }
    }

    /// Whether `column` exists on the audit table.
    ///
    /// This used to be `SELECT <column> FROM <table> LIMIT 0`: a missing column
    /// is a prepare error, and the driver logs every prepare error at err
    /// level, which the test suite's log gate counts as a failure — probing a
    /// legacy table turned an upgrade into a red suite. Ask the catalog
    /// instead, per dialect; nothing here is an error path.
    fn columnExists(self: *Self, column: []const u8) !bool {
        try sqlx.validateIdentifier(self.table);
        try sqlx.validateIdentifier(column);
        switch (self.backend.dialect()) {
            .sqlite => {
                var cursor = try self.backend.client.queryCursorEx(
                    "SELECT COUNT(*) AS n FROM pragma_table_info(?) WHERE name = ?",
                    &.{ .{ .string = self.table }, .{ .string = column } },
                    .{},
                );
                defer cursor.deinit();
                const row = (try cursor.next()) orelse return false;
                return (row.get("n") orelse return false).int > 0;
            },
            // `information_schema.columns` is server-wide, so the statement is
            // built by `sqlx.catalogColumnProbe`: it pins the schema `ALTER
            // TABLE` will resolve against, and a same-named table in another
            // schema cannot answer "the column is there".
            .postgres, .mysql => |d| {
                const probe = sqlx.catalogColumnProbe(
                    if (d == .postgres) .postgres else .mysql,
                    self.table,
                    column,
                );
                var cursor = try self.backend.client.queryCursorEx(probe.sql, probe.bindArgs(), .{});
                defer cursor.deinit();
                return (try cursor.next()) != null;
            },
        }
    }

    pub fn record(self: *Self, entry: RunAuditEntry) !void {
        try sqlx.validateIdentifier(self.table);
        // Wall clock, not uptime: these rows outlive the process, and a tenant
        // statement or a cost window ("this month") is meaningless in seconds
        // since boot. `x402_store` stamps its ledger the same way for the same
        // reason.
        const now = Time.wallClockSeconds(self.backend.client.io);
        const sql = try self.allocator.print(
            "INSERT INTO {s} (run_id, kind, status, tenant_id, steps, duration_ms, created_at, model, prompt_tokens, completion_tokens) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            .{self.table},
        );
        defer self.allocator.free(sql);
        _ = try self.backend.exec(sql, &.{
            .{ .string = entry.run_id },
            .{ .string = @tagName(entry.kind) },
            .{ .string = entry.status },
            if (entry.tenant_id) |tid| .{ .int = tid } else .null,
            .{ .int = @intCast(entry.steps) },
            .{ .int = entry.duration_ms },
            .{ .int = now },
            if (entry.model) |m| .{ .string = m } else .null,
            .{ .int = @intCast(entry.prompt_tokens) },
            .{ .int = @intCast(entry.completion_tokens) },
        });
    }

    /// Copy matching rows into `out` (caller owns the strings; newest first).
    /// `kind` / `tenant_id` filters are optional.
    pub fn list(
        self: *Self,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(RunAuditEntry),
        kind: ?RunKind,
        tenant_id: ?i64,
        limit: usize,
    ) !void {
        try sqlx.validateIdentifier(self.table);
        var where = std.ArrayList(u8).empty;
        defer where.deinit(allocator);
        var args = std.ArrayList(@import("../data.zig").sqlx.Value).empty;
        defer args.deinit(allocator);
        var first = true;
        if (kind) |k| {
            try where.appendSlice(allocator, "kind = ?");
            try args.append(allocator, .{ .string = @tagName(k) });
            first = false;
        }
        if (tenant_id) |tid| {
            if (!first) try where.appendSlice(allocator, " AND ");
            try where.appendSlice(allocator, "tenant_id = ?");
            try args.append(allocator, .{ .int = tid });
        }

        const sql = if (where.items.len > 0) try allocator.print(
            "SELECT run_id, kind, status, tenant_id, steps, duration_ms, model, prompt_tokens, completion_tokens FROM {s} WHERE {s} ORDER BY id DESC LIMIT {d}",
            .{ self.table, where.items, limit },
        ) else try allocator.print(
            "SELECT run_id, kind, status, tenant_id, steps, duration_ms, model, prompt_tokens, completion_tokens FROM {s} ORDER BY id DESC LIMIT {d}",
            .{ self.table, limit },
        );
        defer allocator.free(sql);

        var cursor = try self.backend.client.queryCursorEx(sql, args.items, .{});
        defer cursor.deinit();
        while (try cursor.next()) |row| {
            try appendRow(allocator, out, row);
        }
    }

    /// Copy one audit row into `out`, which owns it from here.
    ///
    /// Each copy is guarded as it is made and the guards are disarmed by this
    /// `return`: built inside the `append` argument, a failed `status` /
    /// `model` copy stranded the copies before it and a failed `append`
    /// stranded all three (a call-site `errdefer` would instead stay armed past
    /// the hand-over and free what `out` already owns). The row's slices are
    /// borrowed from its arena, so they must be copied before `next()` moves on.
    fn appendRow(allocator: std.mem.Allocator, out: *std.ArrayList(RunAuditEntry), row: *sqlx.Row) !void {
        const run_id = try allocator.dupe(u8, row.get("run_id").?.string);
        errdefer allocator.free(run_id);
        const status = try allocator.dupe(u8, row.get("status").?.string);
        errdefer allocator.free(status);
        const model: ?[]const u8 = if (row.get("model")) |m| try allocator.dupe(u8, m.string) else null;
        errdefer if (model) |mm| allocator.free(mm);
        try out.append(allocator, .{
            .run_id = run_id,
            .kind = std.meta.stringToEnum(RunKind, row.get("kind").?.string) orelse .workflow,
            .status = status,
            .tenant_id = if (row.get("tenant_id")) |t| t.int else null,
            .steps = @intCast(row.get("steps").?.int),
            .duration_ms = row.get("duration_ms").?.int,
            .model = model,
            .prompt_tokens = if (row.get("prompt_tokens")) |v| @intCast(v.int) else 0,
            .completion_tokens = if (row.get("completion_tokens")) |v| @intCast(v.int) else 0,
        });
    }

    /// One billing/usage bucket: a `(kind, model)` pair within the optional
    /// tenant / time window. `model` is always an owned string (empty when the
    /// runs did not record one).
    pub const UsageRow = struct {
        kind: RunKind,
        model: []const u8,
        prompt_tokens: u64,
        completion_tokens: u64,
        runs: u64,
    };

    /// Aggregate persisted token usage. This is the query a tenant statement
    /// or a cost dashboard needs; `list` answers "what ran", this answers "how
    /// much did it cost", per tenant and model.
    ///
    /// `since_seconds` is Unix wall-clock seconds — the unit `record` stamps
    /// `created_at` with, so a window means the same thing after a restart.
    pub fn aggregate(
        self: *Self,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(UsageRow),
        tenant_id: ?i64,
        since_seconds: ?i64,
    ) !void {
        try sqlx.validateIdentifier(self.table);
        var where = std.ArrayList(u8).empty;
        defer where.deinit(allocator);
        var args = std.ArrayList(sqlx.Value).empty;
        defer args.deinit(allocator);
        var first = true;
        if (tenant_id) |tid| {
            try where.appendSlice(allocator, "tenant_id = ?");
            try args.append(allocator, .{ .int = tid });
            first = false;
        }
        if (since_seconds) |ts| {
            if (!first) try where.appendSlice(allocator, " AND ");
            try where.appendSlice(allocator, "created_at >= ?");
            try args.append(allocator, .{ .int = ts });
        }

        // `SUM(bigint)` is not a bigint on the servers: PostgreSQL widens it to
        // NUMERIC (the driver decodes that as decimal text) and MySQL to
        // DECIMAL. Cast where the server would widen, and read every shape
        // anyway — `numericValue` below.
        const base = switch (self.backend.dialect()) {
            .sqlite => "SELECT kind, model, SUM(prompt_tokens) AS prompt_tokens, SUM(completion_tokens) AS completion_tokens, COUNT(*) AS runs FROM ",
            .postgres => "SELECT kind, model, SUM(prompt_tokens)::BIGINT AS prompt_tokens, SUM(completion_tokens)::BIGINT AS completion_tokens, COUNT(*) AS runs FROM ",
            .mysql => "SELECT kind, model, CAST(SUM(prompt_tokens) AS SIGNED) AS prompt_tokens, CAST(SUM(completion_tokens) AS SIGNED) AS completion_tokens, COUNT(*) AS runs FROM ",
        };
        const sql = if (where.items.len > 0)
            try allocator.print("{s}{s} WHERE {s} GROUP BY kind, model ORDER BY kind, model", .{ base, self.table, where.items })
        else
            try allocator.print("{s}{s} GROUP BY kind, model ORDER BY kind, model", .{ base, self.table });
        defer allocator.free(sql);

        var cursor = try self.backend.client.queryCursorEx(sql, args.items, .{});
        defer cursor.deinit();
        while (try cursor.next()) |row| {
            const kind = std.meta.stringToEnum(RunKind, row.get("kind").?.string) orelse .workflow;
            const model = try allocator.dupe(u8, if (row.get("model")) |m| m.string else "");
            errdefer allocator.free(model);
            try out.append(allocator, .{
                .kind = kind,
                .model = model,
                .prompt_tokens = numericValue(row.get("prompt_tokens")),
                .completion_tokens = numericValue(row.get("completion_tokens")),
                .runs = numericValue(row.get("runs")),
            });
        }
    }

    pub fn count(self: *Self) !usize {
        try sqlx.validateIdentifier(self.table);
        const sql = try self.allocator.print("SELECT COUNT(*) AS n FROM {s}", .{self.table});
        defer self.allocator.free(sql);
        var cursor = try self.backend.client.queryCursorEx(sql, &.{}, .{});
        defer cursor.deinit();
        return @intCast(numericValue((try cursor.next()).?.get("n")));
    }
};

/// A numeric result column as an unsigned integer.
///
/// The same `SUM()`/`COUNT()` arrives in a different union tag per driver:
/// SQLite hands back `.int`, MySQL a `.float` (DECIMAL), PostgreSQL a
/// `.string` (NUMERIC decoded as decimal text). Reading `.int`
/// unconditionally panicked on PostgreSQL — "access of union field 'int' while
/// field 'string' is active" — on the very query a tenant statement runs.
fn numericValue(v: ?sqlx.Value) u64 {
    const value = v orelse return 0;
    return switch (value) {
        .int => |i| if (i > 0) @intCast(i) else 0,
        .float => |f| if (f > 0) @intFromFloat(f) else 0,
        .string => |s| blk: {
            if (std.fmt.parseInt(u64, s, 10)) |i| break :blk i else |_| {}
            if (std.fmt.parseFloat(f64, s)) |f| break :blk if (f > 0) @intFromFloat(f) else 0 else |_| {}
            break :blk 0;
        },
        else => 0,
    };
}

///
/// This used to be one SQLite statement (`INTEGER PRIMARY KEY AUTOINCREMENT`).
/// PostgreSQL and MySQL reject that spelling, so `migrate()` failed on them and
/// the first `record()` reported `relation "ai_run_audit" does not exist` — the
/// table had never been created. Keep the three arms in one place so the row
/// shape cannot drift between them: only the id syntax and the types MySQL
/// insists on (`VARCHAR`, no unbounded `TEXT` key) differ.
fn createTableSql(allocator: std.mem.Allocator, driver: sqlx.Driver, table: []const u8) ![]u8 {
    return switch (driver) {
        .sqlite => allocator.print(
            "CREATE TABLE IF NOT EXISTS {s} (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, tenant_id INTEGER, steps INTEGER NOT NULL DEFAULT 0, duration_ms INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, model TEXT, prompt_tokens INTEGER NOT NULL DEFAULT 0, completion_tokens INTEGER NOT NULL DEFAULT 0)",
            .{table},
        ),
        .postgres => allocator.print(
            "CREATE TABLE IF NOT EXISTS {s} (id BIGSERIAL PRIMARY KEY, run_id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, tenant_id BIGINT, steps BIGINT NOT NULL DEFAULT 0, duration_ms BIGINT NOT NULL DEFAULT 0, created_at BIGINT NOT NULL, model TEXT, prompt_tokens BIGINT NOT NULL DEFAULT 0, completion_tokens BIGINT NOT NULL DEFAULT 0)",
            .{table},
        ),
        .mysql => allocator.print(
            "CREATE TABLE IF NOT EXISTS {s} (id BIGINT AUTO_INCREMENT PRIMARY KEY, run_id VARCHAR(255) NOT NULL, kind VARCHAR(32) NOT NULL, status VARCHAR(64) NOT NULL, tenant_id BIGINT NULL, steps BIGINT NOT NULL DEFAULT 0, duration_ms BIGINT NOT NULL DEFAULT 0, created_at BIGINT NOT NULL, model VARCHAR(255) NULL, prompt_tokens BIGINT NOT NULL DEFAULT 0, completion_tokens BIGINT NOT NULL DEFAULT 0)",
            .{table},
        ),
    };
}

// The rows are inserted with the test allocator before the scan; the failing
// allocator covers `appendRow`'s copies and the growth of `out`, never the
// driver's own storage (the client has its own allocator).
test "RunAuditStore.list hands back its rows at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = RunAuditStore.init(allocator, &backend);
    try store.migrate();
    try store.record(.{ .run_id = "r1", .kind = .workflow, .status = "completed", .tenant_id = 1, .steps = 3, .duration_ms = 12, .model = "deepseek-v4" });
    try store.record(.{ .run_id = "r2", .kind = .agent, .status = "failed", .steps = 1, .duration_ms = 4 });

    const Scan = struct {
        fn run(a: std.mem.Allocator, s: *RunAuditStore) !void {
            var out = std.ArrayList(RunAuditEntry).empty;
            defer {
                for (out.items) |e| {
                    a.free(e.run_id);
                    a.free(e.status);
                    if (e.model) |m| a.free(m);
                }
                out.deinit(a);
            }
            try s.list(a, &out, null, null, 10);
            try std.testing.expectEqual(@as(usize, 2), out.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{&store});
}

test "RunAuditStore records, filters and lists run history" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = RunAuditStore.init(allocator, &backend);
    try store.migrate();

    try store.record(.{ .run_id = "r1", .kind = .workflow, .status = "completed", .tenant_id = 1, .steps = 3, .duration_ms = 12 });
    try store.record(.{ .run_id = "r2", .kind = .approval, .status = "pending_human", .tenant_id = 2, .steps = 1, .duration_ms = 4 });
    try store.record(.{ .run_id = "r3", .kind = .workflow, .status = "failed", .tenant_id = 1, .steps = 1, .duration_ms = 9 });

    try std.testing.expectEqual(@as(usize, 3), try store.count());
    var all = std.ArrayList(RunAuditEntry).empty;
    defer {
        for (all.items) |e| {
            allocator.free(e.run_id);
            allocator.free(e.status);
            if (e.model) |m| allocator.free(m);
        }
        all.deinit(allocator);
    }
    try store.list(allocator, &all, null, null, 10);
    try std.testing.expectEqual(@as(usize, 3), all.items.len);

    var wf_only = std.ArrayList(RunAuditEntry).empty;
    defer {
        for (wf_only.items) |e| {
            allocator.free(e.run_id);
            allocator.free(e.status);
            if (e.model) |m| allocator.free(m);
        }
        wf_only.deinit(allocator);
    }
    try store.list(allocator, &wf_only, .workflow, 1, 10);
    try std.testing.expectEqual(@as(usize, 2), wf_only.items.len);
    try std.testing.expectEqualStrings("r3", wf_only.items[0].run_id); // newest first
}

test "RunAuditStore stamps created_at with the wall clock, not uptime" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = RunAuditStore.init(allocator, &backend);
    try store.migrate();

    const before = Time.wallClockSeconds(std.testing.io);
    try store.record(.{ .run_id = "clock", .kind = .agent, .status = "ok" });

    var cursor = try client.queryCursorEx("SELECT created_at FROM ai_run_audit ORDER BY id DESC LIMIT 1", &.{}, .{});
    defer cursor.deinit();
    const stamped = (try cursor.next()).?.get("created_at").?.int;
    // Uptime seconds on a fresh test process are tiny; the band only absorbs
    // clock granularity and the test's own runtime.
    try std.testing.expect(stamped >= before);
    try std.testing.expect(stamped <= before + 300);
}

test "numericValue reads the SUM/COUNT shapes each driver returns" {
    // SQLite: INTEGER.
    try std.testing.expectEqual(@as(u64, 150), numericValue(.{ .int = 150 }));
    // PostgreSQL: NUMERIC, decoded as decimal text by the driver.
    try std.testing.expectEqual(@as(u64, 150), numericValue(.{ .string = "150" }));
    try std.testing.expectEqual(@as(u64, 150), numericValue(.{ .string = "150.000" }));
    // MySQL: DECIMAL, decoded as a float.
    try std.testing.expectEqual(@as(u64, 150), numericValue(.{ .float = 150.0 }));
    // Absent / unusable.
    try std.testing.expectEqual(@as(u64, 0), numericValue(null));
    try std.testing.expectEqual(@as(u64, 0), numericValue(.{ .string = "NaN" }));
    try std.testing.expectEqual(@as(u64, 0), numericValue(.{ .int = -1 }));
}

test "RunAuditStore rejects a table name that is not a plain identifier" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = RunAuditStore.init(allocator, &backend);
    // `self.table` is the only part of these statements not bound with `?`, so
    // a caller-supplied one has to be rejected before any SQL is built — on
    // every entry point, not just the one that happens to run first.
    store.table = "audit; DROP TABLE users";
    try std.testing.expectError(error.InvalidSqlIdentifier, store.migrate());
    try std.testing.expectError(error.InvalidSqlIdentifier, store.count());
    try std.testing.expectError(error.InvalidSqlIdentifier, store.record(.{ .run_id = "r", .kind = .workflow, .status = "ok" }));
    var out = std.ArrayList(RunAuditEntry).empty;
    defer out.deinit(allocator);
    try std.testing.expectError(error.InvalidSqlIdentifier, store.list(allocator, &out, null, null, 10));
}

test "RunAuditStore emits each dialect's CREATE TABLE" {
    const allocator = std.testing.allocator;

    // PostgreSQL and MySQL parse neither `AUTOINCREMENT` nor each other's id
    // syntax, so the arms are asserted apart rather than assumed equivalent.
    const pg = try createTableSql(allocator, .postgres, "ai_run_audit");
    defer allocator.free(pg);
    try std.testing.expect(std.mem.indexOf(u8, pg, "BIGSERIAL PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg, "AUTOINCREMENT") == null);
    try std.testing.expect(std.mem.indexOf(u8, pg, "AUTO_INCREMENT") == null);

    const my = try createTableSql(allocator, .mysql, "ai_run_audit");
    defer allocator.free(my);
    try std.testing.expect(std.mem.indexOf(u8, my, "AUTO_INCREMENT PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, my, "AUTOINCREMENT") == null);

    const lite = try createTableSql(allocator, .sqlite, "ai_run_audit");
    defer allocator.free(lite);
    try std.testing.expect(std.mem.indexOf(u8, lite, "INTEGER PRIMARY KEY AUTOINCREMENT") != null);

    // Same row shape everywhere: a row written on one server must be readable
    // from the others, so every column appears in every arm.
    const columns = [_][]const u8{ "run_id", "kind", "status", "tenant_id", "steps", "duration_ms", "created_at", "model", "prompt_tokens", "completion_tokens" };
    for ([_][]const u8{ pg, my, lite }) |sql| {
        for (columns) |column| {
            try std.testing.expect(std.mem.indexOf(u8, sql, column) != null);
        }
    }
}

/// Convenience: record a run with the tenant from the SkillContext.
pub fn recordRun(
    store: *RunAuditStore,
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    run_id: []const u8,
    kind: RunKind,
    status: []const u8,
    steps: usize,
    duration_ms: i64,
) !void {
    try store.record(.{
        .run_id = run_id,
        .kind = kind,
        .status = status,
        .tenant_id = ctx.tenant_id,
        .steps = steps,
        .duration_ms = duration_ms,
    });
    _ = allocator;
}

/// Record a run together with the provider-reported token usage. `recordRun`
/// stays the token-less convenience form (workflow steps do not necessarily
/// call a model).
pub fn recordRunWithUsage(
    store: *RunAuditStore,
    ctx: *SkillContext,
    run_id: []const u8,
    kind: RunKind,
    status: []const u8,
    steps: usize,
    duration_ms: i64,
    prompt_tokens: u64,
    completion_tokens: u64,
    model: ?[]const u8,
) !void {
    try store.record(.{
        .run_id = run_id,
        .kind = kind,
        .status = status,
        .tenant_id = ctx.tenant_id,
        .steps = steps,
        .duration_ms = duration_ms,
        .model = model,
        .prompt_tokens = prompt_tokens,
        .completion_tokens = completion_tokens,
    });
}

test "RunAuditStore persists token usage and upgrades a legacy table" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    // Shape written by an older zmodu: no model / token columns.
    _ = try client.exec(
        "CREATE TABLE ai_run_audit (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, tenant_id INTEGER, steps INTEGER NOT NULL DEFAULT 0, duration_ms INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)",
        &.{},
    );
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = RunAuditStore.init(allocator, &backend);
    // migrate() must ALTER the missing columns in, not silently skip them.
    try store.migrate();
    try store.record(.{
        .run_id = "r-tokens",
        .kind = .agent,
        .status = "completed",
        .tenant_id = 7,
        .steps = 2,
        .duration_ms = 50,
        .model = "deepseek-chat",
        .prompt_tokens = 120,
        .completion_tokens = 30,
    });

    var out = std.ArrayList(RunAuditEntry).empty;
    defer {
        for (out.items) |e| {
            allocator.free(e.run_id);
            allocator.free(e.status);
            if (e.model) |m| allocator.free(m);
        }
        out.deinit(allocator);
    }
    try store.list(allocator, &out, .agent, 7, 10);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u64, 120), out.items[0].prompt_tokens);
    try std.testing.expectEqual(@as(u64, 30), out.items[0].completion_tokens);
}

test "RunAuditStore aggregates token usage per tenant, kind and model" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = RunAuditStore.init(allocator, &backend);
    try store.migrate();

    try store.record(.{ .run_id = "a1", .kind = .agent, .status = "ok", .tenant_id = 1, .steps = 1, .duration_ms = 1, .model = "m1", .prompt_tokens = 100, .completion_tokens = 20 });
    try store.record(.{ .run_id = "a2", .kind = .agent, .status = "ok", .tenant_id = 1, .steps = 1, .duration_ms = 1, .model = "m1", .prompt_tokens = 50, .completion_tokens = 10 });
    try store.record(.{ .run_id = "a3", .kind = .agent, .status = "ok", .tenant_id = 1, .steps = 1, .duration_ms = 1, .model = "m2", .prompt_tokens = 7, .completion_tokens = 3 });
    try store.record(.{ .run_id = "b1", .kind = .agent, .status = "ok", .tenant_id = 2, .steps = 1, .duration_ms = 1, .model = "m1", .prompt_tokens = 999, .completion_tokens = 1 });

    var rows = std.ArrayList(RunAuditStore.UsageRow).empty;
    defer {
        for (rows.items) |r| allocator.free(r.model);
        rows.deinit(allocator);
    }
    try store.aggregate(allocator, &rows, 1, null);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    // Ordered by kind, model: m1 then m2, tenant 1 only.
    try std.testing.expectEqualStrings("m1", rows.items[0].model);
    try std.testing.expectEqual(@as(u64, 150), rows.items[0].prompt_tokens);
    try std.testing.expectEqual(@as(u64, 30), rows.items[0].completion_tokens);
    try std.testing.expectEqual(@as(u64, 2), rows.items[0].runs);
    try std.testing.expectEqualStrings("m2", rows.items[1].model);
    try std.testing.expectEqual(@as(u64, 7), rows.items[1].prompt_tokens);
}
