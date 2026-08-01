//! Human approval queue + HTTP API ("人工审批队列"): escalated approval runs
//! land in an in-memory queue (via `queuedEscalation` hooked onto
//! `ApprovalFlow`), and a ComptimeRouter module exposes
//! `GET /approvals/pending`, `POST /approvals/{id}/approve` and
//! `POST /approvals/{id}/reject` so a human (or another service) can close
//! the loop. The queue is a small, app-owned store — pair it with the outbox
//! consumer / a database when the queue must survive restarts.

const std = @import("std");
const http = @import("../http.zig");
const approval = @import("approval.zig");
const SkillContext = @import("skill.zig").SkillContext;

pub const PendingApproval = struct {
    run_id: []const u8,
    subject: []const u8,
    amount: i64,
    note: []const u8,
    step_name: []const u8,
};

/// Thread-safe in-memory queue of escalated approvals. The queue owns the
/// item strings (`deinit` frees them).
pub const ApprovalQueue = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    items: std.ArrayList(PendingApproval),
    mu: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{ .allocator = allocator, .io = io, .items = std.ArrayList(PendingApproval).empty };
    }

    pub fn deinit(self: *Self) void {
        for (self.items.items) |item| {
            self.allocator.free(item.run_id);
            self.allocator.free(item.subject);
            self.allocator.free(item.note);
            self.allocator.free(item.step_name);
        }
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *Self, item: PendingApproval) !void {
        self.mu.lock(self.io) catch return error.LockFailed;
        defer self.mu.unlock(self.io);
        try self.items.append(self.allocator, item);
    }

    /// Resolve an item by run_id: returns true when found and removed.
    pub fn resolve(self: *Self, run_id: []const u8) bool {
        self.mu.lock(self.io) catch return false;
        defer self.mu.unlock(self.io);
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.run_id, run_id)) {
                _ = self.items.orderedRemove(i);
                self.allocator.free(item.run_id);
                self.allocator.free(item.subject);
                self.allocator.free(item.note);
                self.allocator.free(item.step_name);
                return true;
            }
        }
        return false;
    }

    pub fn count(self: *Self) usize {
        self.mu.lock(self.io) catch return 0;
        defer self.mu.unlock(self.io);
        return self.items.items.len;
    }
};

/// Hook for `ApprovalFlow.on_escalated` that copies the escalated run into
/// the queue (userdata must be `*ApprovalQueue`).
pub fn queuedEscalation(
    userdata: *anyopaque,
    allocator: std.mem.Allocator,
    _: *SkillContext,
    subject: []const u8,
    amount: i64,
    step_name: []const u8,
    note: []const u8,
) anyerror!void {
    const queue: *ApprovalQueue = @ptrCast(@alignCast(userdata));
    try queue.push(.{
        .run_id = try allocator.dupe(u8, subject),
        .subject = try allocator.dupe(u8, subject),
        .amount = amount,
        .note = try allocator.dupe(u8, note),
        .step_name = try allocator.dupe(u8, step_name),
    });
}

/// ComptimeRouter module exposing the human approval queue.
pub fn ApprovalApi(comptime ComptimeState: type) type {
    _ = ComptimeState;
    return struct {
        const Self = @This();
        queue: *ApprovalQueue,
        pub const module_name = "approvals";
        pub const nest = .{"approvals"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "pending", .handler = listPending, .meta = .{ .auth = .jwt } },
            .{ .method = .POST, .path = "{id}/approve", .handler = approve, .meta = .{ .auth = .jwt, .permission = "approval:decide" } },
            .{ .method = .POST, .path = "{id}/reject", .handler = reject, .meta = .{ .auth = .jwt, .permission = "approval:decide" } },
        };

        fn listPending(ctx: *http.Context, self: *State) !void {
            const io = ctx.io orelse return error.ContextWithoutIo;
            self.queue.mu.lock(io) catch return error.QueueLockFailed;
            defer self.queue.mu.unlock(io);
            var arr = std.json.Array.init(ctx.allocator);
            for (self.queue.items.items) |item| {
                var o = std.json.ObjectMap{};
                try putOwned(&o, ctx.allocator, "run_id", .{ .string = try ctx.allocator.dupe(u8, item.run_id) });
                try putOwned(&o, ctx.allocator, "subject", .{ .string = try ctx.allocator.dupe(u8, item.subject) });
                try putOwned(&o, ctx.allocator, "amount", .{ .integer = item.amount });
                try putOwned(&o, ctx.allocator, "note", .{ .string = try ctx.allocator.dupe(u8, item.note) });
                try putOwned(&o, ctx.allocator, "step", .{ .string = try ctx.allocator.dupe(u8, item.step_name) });
                try arr.append(.{ .object = o });
            }
            try ctx.jsonStruct(200, .{ .pending = arr });
        }

        fn approve(ctx: *http.Context, self: *State) !void {
            try resolveOne(ctx, self, true);
        }

        fn reject(ctx: *http.Context, self: *State) !void {
            try resolveOne(ctx, self, false);
        }

        fn resolveOne(ctx: *http.Context, self: *State, approved: bool) !void {
            const id = try ctx.paramStr("id");
            if (!self.queue.resolve(id)) {
                try ctx.jsonStruct(404, .{ .err = "not found or already resolved" });
                return;
            }
            try ctx.jsonStruct(200, .{ .ok = true, .run_id = id, .decision = if (approved) "approved" else "rejected" });
        }
    };
}

/// ObjectMap does not copy keys and deinit does not free them; results must
/// own every key so the caller can free them with `freeValue`.
fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

test "ApprovalQueue push/resolve lifecycle" {
    const allocator = std.testing.allocator;
    var queue = ApprovalQueue.init(allocator, std.testing.io);
    defer queue.deinit();
    try queue.push(.{
        .run_id = try allocator.dupe(u8, "ap-1"),
        .subject = try allocator.dupe(u8, "order-9"),
        .amount = 50000,
        .note = try allocator.dupe(u8, "needs CFO"),
        .step_name = try allocator.dupe(u8, "finance"),
    });
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expect(queue.resolve("ap-1"));
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    try std.testing.expect(!queue.resolve("ap-1"));
}

test "queuedEscalation pushes escalated runs into the queue" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend{ .allocator = allocator, .client = &client };

    var queue = ApprovalQueue.init(allocator, std.testing.io);
    defer queue.deinit();

    const Escalate = struct {
        fn policy(_: std.mem.Allocator, _: *SkillContext, _: []const u8, _: i64, _: usize, _: []const u8, _: []const u8, _: *[]const u8) anyerror!approval.ApprovalDecision {
            return .escalated;
        }
    };
    var flow = approval.ApprovalFlow.init(allocator, &backend, Escalate.policy);
    flow.on_escalated = queuedEscalation;
    flow.escalated_userdata = &queue;

    const steps = [_]approval.ApprovalStep{.{ .name = "finance" }};
    var ctx = SkillContext{ .allocator = allocator };
    var res = try flow.submit(allocator, &ctx, "order-1", 9000, &steps);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqualStrings("order-1", queue.items.items[0].run_id);
    try std.testing.expectEqualStrings("finance", queue.items.items[0].step_name);
}
