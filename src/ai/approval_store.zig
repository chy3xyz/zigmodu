//! Persistent human approval queue: the same interface as the in-memory
//! `ApprovalQueue` but backed by a SQL table, so escalated runs survive
//! restarts and can be audited. Drop into the `ApprovalApi` module or drive
//! it directly; the escalation hook `queuedEscalationPersistent` mirrors the
//! memory version.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const approval_api = @import("approval_api.zig");

pub const PendingApproval = approval_api.PendingApproval;

pub const PersistentApprovalQueue = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    table: []const u8 = "approval_queue",

    pub fn init(allocator: std.mem.Allocator, backend: *SqlxBackend) Self {
        return .{ .allocator = allocator, .backend = backend };
    }

    /// Create the queue table (idempotent). Call once at startup.
    pub fn migrate(self: *Self) !void {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "CREATE TABLE IF NOT EXISTS {s} (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, subject TEXT NOT NULL, amount INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '', step_name TEXT NOT NULL, status INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
            .{self.table},
        );
        defer self.allocator.free(sql);
        _ = try self.backend.exec(sql, &.{});
    }

    pub fn push(self: *Self, item: PendingApproval) !void {
        const now = @import("../core/Time.zig").monotonicNowSeconds();
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO {s} (run_id, subject, amount, note, step_name, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 0, ?, ?)",
            .{self.table},
        );
        defer self.allocator.free(sql);
        _ = try self.backend.exec(sql, &.{
            .{ .string = item.run_id },
            .{ .string = item.subject },
            .{ .int = item.amount },
            .{ .string = item.note },
            .{ .string = item.step_name },
            .{ .int = now },
            .{ .int = now },
        });
    }

    /// Copy all pending rows into `out` (caller-allocated slices; caller owns
    /// the strings and must free them). Rows are ordered oldest first.
    pub fn listPending(self: *Self, allocator: std.mem.Allocator, out: *std.ArrayList(PendingApproval)) !void {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT run_id, subject, amount, note, step_name FROM {s} WHERE status = 0 ORDER BY id ASC",
            .{self.table},
        );
        defer self.allocator.free(sql);
        var cursor = try self.backend.client.queryCursorEx(sql, &.{}, .{});
        defer cursor.deinit();
        while (cursor.next()) |row| {
            try out.append(allocator, .{
                .run_id = try allocator.dupe(u8, row.get("run_id").?.string),
                .subject = try allocator.dupe(u8, row.get("subject").?.string),
                .amount = row.get("amount").?.int,
                .note = try allocator.dupe(u8, row.get("note").?.string),
                .step_name = try allocator.dupe(u8, row.get("step_name").?.string),
            });
        }
    }

    /// Mark the first pending row with `run_id` resolved. Returns true when
    /// a row was updated.
    pub fn resolve(self: *Self, run_id: []const u8) !bool {
        const now = @import("../core/Time.zig").monotonicNowSeconds();
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE {s} SET status = 1, updated_at = ? WHERE run_id = ? AND status = 0",
            .{self.table},
        );
        defer self.allocator.free(sql);
        const result = try self.backend.exec(sql, &.{ .{ .int = now }, .{ .string = run_id } });
        return result.rows_affected > 0;
    }

    pub fn count(self: *Self) !usize {
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) AS n FROM {s} WHERE status = 0", .{self.table});
        defer self.allocator.free(sql);
        var cursor = try self.backend.client.queryCursorEx(sql, &.{}, .{});
        defer cursor.deinit();
        return @intCast(cursor.next().?.get("n").?.int);
    }
};

/// Hook for `ApprovalFlow.on_escalated` backed by the persistent queue
/// (userdata must be `*PersistentApprovalQueue`).
pub fn queuedEscalationPersistent(
    userdata: *anyopaque,
    _: std.mem.Allocator,
    _: *SkillContext,
    subject: []const u8,
    amount: i64,
    step_name: []const u8,
    note: []const u8,
) anyerror!void {
    const queue: *PersistentApprovalQueue = @ptrCast(@alignCast(userdata));
    try queue.push(.{
        .run_id = subject,
        .subject = subject,
        .amount = amount,
        .note = note,
        .step_name = step_name,
    });
}

test "PersistentApprovalQueue push, list and resolve across queries" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };

    var queue = PersistentApprovalQueue.init(allocator, &backend);
    try queue.migrate();
    try queue.push(.{
        .run_id = "ap-1",
        .subject = "order-9",
        .amount = 50000,
        .note = "needs CFO",
        .step_name = "finance",
    });
    try queue.push(.{
        .run_id = "ap-2",
        .subject = "order-10",
        .amount = 200,
        .note = "",
        .step_name = "ops manager",
    });

    try std.testing.expectEqual(@as(usize, 2), try queue.count());
    var items = std.ArrayList(PendingApproval).empty;
    defer {
        for (items.items) |it| {
            allocator.free(it.run_id);
            allocator.free(it.subject);
            allocator.free(it.note);
            allocator.free(it.step_name);
        }
        items.deinit(allocator);
    }
    try queue.listPending(allocator, &items);
    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqualStrings("ap-1", items.items[0].run_id);
    try std.testing.expectEqualStrings("finance", items.items[0].step_name);

    try std.testing.expect(try queue.resolve("ap-1"));
    try std.testing.expectEqual(@as(usize, 1), try queue.count());
    try std.testing.expect(!try queue.resolve("ap-1"));
}
