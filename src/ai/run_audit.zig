//! AI run audit trail ("编排审计"): persists one row per workflow / agent /
//! approval run (run_id, kind, status, tenant, step count, duration) to a SQL
//! table and exposes `list` / `count` queries. Attach a store to
//! `Workflow.audit` and every run / resume is recorded automatically —
//! complementing the in-memory `AgentAuditLog` with durable history.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
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
};

pub const RunAuditStore = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    table: []const u8 = "ai_run_audit",

    pub fn init(allocator: std.mem.Allocator, backend: *SqlxBackend) Self {
        return .{ .allocator = allocator, .backend = backend };
    }

    pub fn migrate(self: *Self) !void {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "CREATE TABLE IF NOT EXISTS {s} (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, tenant_id INTEGER, steps INTEGER NOT NULL DEFAULT 0, duration_ms INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)",
            .{self.table},
        );
        defer self.allocator.free(sql);
        _ = try self.backend.exec(sql, &.{});
    }

    pub fn record(self: *Self, entry: RunAuditEntry) !void {
        const now = Time.monotonicNowSeconds();
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO {s} (run_id, kind, status, tenant_id, steps, duration_ms, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
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
        var where = std.ArrayList(u8).empty;
        defer where.deinit(allocator);
        var args = std.ArrayList(@import("../sqlx/sqlx.zig").Value).empty;
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

        const sql = if (where.items.len > 0) try std.fmt.allocPrint(
            allocator,
            "SELECT run_id, kind, status, tenant_id, steps, duration_ms FROM {s} WHERE {s} ORDER BY id DESC LIMIT {d}",
            .{ self.table, where.items, limit },
        ) else try std.fmt.allocPrint(
            allocator,
            "SELECT run_id, kind, status, tenant_id, steps, duration_ms FROM {s} ORDER BY id DESC LIMIT {d}",
            .{ self.table, limit },
        );
        defer allocator.free(sql);

        var cursor = try self.backend.client.queryCursorEx(sql, args.items, .{});
        defer cursor.deinit();
        while (cursor.next()) |row| {
            try out.append(allocator, .{
                .run_id = try allocator.dupe(u8, row.get("run_id").?.string),
                .kind = std.meta.stringToEnum(RunKind, row.get("kind").?.string) orelse .workflow,
                .status = try allocator.dupe(u8, row.get("status").?.string),
                .tenant_id = if (row.get("tenant_id")) |t| t.int else null,
                .steps = @intCast(row.get("steps").?.int),
                .duration_ms = row.get("duration_ms").?.int,
            });
        }
    }

    pub fn count(self: *Self) !usize {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) AS n FROM {s}", .{self.table});
        defer self.allocator.free(sql);
        var cursor = try self.backend.client.queryCursorEx(sql, &.{}, .{});
        defer cursor.deinit();
        return @intCast(cursor.next().?.get("n").?.int);
    }
};

test "RunAuditStore records, filters and lists run history" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
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
        }
        wf_only.deinit(allocator);
    }
    try store.list(allocator, &wf_only, .workflow, 1, 10);
    try std.testing.expectEqual(@as(usize, 2), wf_only.items.len);
    try std.testing.expectEqualStrings("r3", wf_only.items[0].run_id); // newest first
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
