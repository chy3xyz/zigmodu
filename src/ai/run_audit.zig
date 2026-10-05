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
        const sql = try self.allocator.print(
            "CREATE TABLE IF NOT EXISTS {s} (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, tenant_id INTEGER, steps INTEGER NOT NULL DEFAULT 0, duration_ms INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, model TEXT)",
            .{self.table},
        );
        defer self.allocator.free(sql);
        _ = try self.backend.exec(sql, &.{});
        // Existing installs predate the `model` column (CREATE IF NOT EXISTS
        // does not add columns). Probe first (fresh tables already have it),
        // then best-effort ALTER for legacy tables.
        const probe = try self.allocator.print("SELECT model FROM {s} LIMIT 0", .{self.table});
        defer self.allocator.free(probe);
        if (self.backend.exec(probe, &.{})) |_| {
            // column already exists
        } else |_| {
            const alter = try self.allocator.print("ALTER TABLE {s} ADD COLUMN model TEXT", .{self.table});
            defer self.allocator.free(alter);
            _ = self.backend.exec(alter, &.{}) catch |err| {
                std.log.debug("[ai.run_audit] best-effort legacy column add failed ({s})", .{@errorName(err)});
            };
        }
    }

    pub fn record(self: *Self, entry: RunAuditEntry) !void {
        try sqlx.validateIdentifier(self.table);
        const now = Time.monotonicNowSeconds();
        const sql = try self.allocator.print(
            "INSERT INTO {s} (run_id, kind, status, tenant_id, steps, duration_ms, created_at, model) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
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
            "SELECT run_id, kind, status, tenant_id, steps, duration_ms, model FROM {s} WHERE {s} ORDER BY id DESC LIMIT {d}",
            .{ self.table, where.items, limit },
        ) else try allocator.print(
            "SELECT run_id, kind, status, tenant_id, steps, duration_ms, model FROM {s} ORDER BY id DESC LIMIT {d}",
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
        });
    }

    pub fn count(self: *Self) !usize {
        try sqlx.validateIdentifier(self.table);
        const sql = try self.allocator.print("SELECT COUNT(*) AS n FROM {s}", .{self.table});
        defer self.allocator.free(sql);
        var cursor = try self.backend.client.queryCursorEx(sql, &.{}, .{});
        defer cursor.deinit();
        return @intCast((try cursor.next()).?.get("n").?.int);
    }
};

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
