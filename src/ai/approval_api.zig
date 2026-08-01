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
const SkillRegistry = @import("skill.zig").SkillRegistry;
const freeValue = @import("skill.zig").freeValue;

pub const PendingApproval = struct {
    run_id: []const u8,
    subject: []const u8,
    amount: i64,
    note: []const u8,
    step_name: []const u8,
    /// Optional tenant scope for multi-tenant deployments.
    tenant_id: ?i64 = null,
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
    pub fn resolve(self: *Self, run_id: []const u8, _tenant_id: ?i64) !bool {
        _ = _tenant_id;
        self.mu.lock(self.io) catch return error.LockFailed;
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

    /// Copy pending items into `out` (caller owns the strings).
    pub fn listPending(self: *Self, allocator: std.mem.Allocator, out: *std.ArrayList(PendingApproval), _tenant_id: ?i64) !void {
        _ = _tenant_id;
        self.mu.lock(self.io) catch return error.LockFailed;
        defer self.mu.unlock(self.io);
        for (self.items.items) |item| {
            try out.append(allocator, .{
                .run_id = try allocator.dupe(u8, item.run_id),
                .subject = try allocator.dupe(u8, item.subject),
                .amount = item.amount,
                .note = try allocator.dupe(u8, item.note),
                .step_name = try allocator.dupe(u8, item.step_name),
                .tenant_id = item.tenant_id,
            });
        }
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

/// Capability bundle for the `approval.request` skill bridge. The caller owns
/// this value and sets `SkillContext.userdata = &ctx` before dispatch.
pub const ApprovalCtx = struct {
    flow: *approval.ApprovalFlow,
    steps: []const approval.ApprovalStep,
};

/// Register `approval.request` — an Agent inside a workflow can submit an
/// approval request (subject + amount); the chain and policy stay
/// app-registered. Returns run_id + status.
pub fn registerApprovalRequestSkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "approval.request",
        .description = "Submit a business request through the app-registered approval chain; returns the approval run id and status (approved / pending_human / rejected)",
        .required_permission = "approval:decide",
        .parameters = &.{
            .{ .name = "subject", .type = .string, .description = "What is being approved", .required = true },
            .{ .name = "amount", .type = .number, .description = "Amount involved", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *ApprovalCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.ApprovalNotConfigured));
                const obj = args.object;
                const subject_v = obj.get("subject") orelse return error.InvalidArguments;
                const amount_v = obj.get("amount") orelse return error.InvalidArguments;
                if (subject_v != .string or amount_v != .float) return error.InvalidArguments;

                var result = try ac.flow.submit(sctx.allocator, sctx, subject_v.string, @intFromFloat(amount_v.float), ac.steps);
                defer result.deinit(sctx.allocator);
                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "run_id", .{ .string = try sctx.allocator.dupe(u8, result.run_id) });
                try putOwned(&out, sctx.allocator, "status", .{ .string = try sctx.allocator.dupe(u8, @tagName(result.status)) });
                return .{ .object = out };
            }
        }.h,
    });
}

/// ComptimeRouter module exposing a human approval queue. `QueueT` is either
/// `ApprovalQueue` (in-memory) or `PersistentApprovalQueue` (SQL-backed) —
/// both implement `push` / `listPending` / `resolve` / `count`.
pub fn ApprovalApi(comptime QueueT: type) type {
    return struct {
        const Self = @This();
        queue: *QueueT,
        pub const module_name = "approvals";
        pub const nest = .{"approvals"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "pending", .handler = listPending },
            .{ .method = .POST, .path = "{id}/approve", .handler = approve, .meta = .{ .permission = "approval:decide" } },
            .{ .method = .POST, .path = "{id}/reject", .handler = reject, .meta = .{ .permission = "approval:decide" } },
        };

        fn listPending(ctx: *http.Context, self: *State) !void {
            var items = std.ArrayList(@import("approval_api.zig").PendingApproval).empty;
            defer {
                for (items.items) |item| {
                    ctx.allocator.free(item.run_id);
                    ctx.allocator.free(item.subject);
                    ctx.allocator.free(item.note);
                    ctx.allocator.free(item.step_name);
                }
                items.deinit(ctx.allocator);
            }
            const tenant_id = blk: {
                const h = ctx.header("X-Tenant-ID") orelse break :blk null;
                break :blk std.fmt.parseInt(i64, h, 10) catch null;
            };
            try self.queue.listPending(ctx.allocator, &items, tenant_id);

            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"pending\":[");
            var first = true;
            for (items.items) |item| {
                if (!first) try buf.appendSlice(ctx.allocator, ",");
                first = false;
                try buf.appendSlice(ctx.allocator, "{\"run_id\":\"");
                try buf.appendSlice(ctx.allocator, item.run_id);
                try buf.appendSlice(ctx.allocator, "\",\"subject\":\"");
                try buf.appendSlice(ctx.allocator, item.subject);
                try buf.print(ctx.allocator, "\",\"amount\":{d},\"note\":\"", .{item.amount});
                try buf.appendSlice(ctx.allocator, item.note);
                try buf.appendSlice(ctx.allocator, "\",\"step\":\"");
                try buf.appendSlice(ctx.allocator, item.step_name);
                try buf.appendSlice(ctx.allocator, "\"}");
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.setHeader("Content-Type", "application/json");
            try ctx.json(200, buf.items);
        }

        fn approve(ctx: *http.Context, self: *State) !void {
            try resolveOne(ctx, self, true);
        }

        fn reject(ctx: *http.Context, self: *State) !void {
            try resolveOne(ctx, self, false);
        }

        fn resolveOne(ctx: *http.Context, self: *State, approved: bool) !void {
            const id = try ctx.paramStr("id");
            const tenant_id = blk: {
                const h = ctx.header("X-Tenant-ID") orelse break :blk null;
                break :blk std.fmt.parseInt(i64, h, 10) catch null;
            };
            const resolved = try self.queue.resolve(id, tenant_id);
            if (!resolved) {
                try ctx.setHeader("Content-Type", "application/json");
                try ctx.json(404, "{\"err\":\"not found or already resolved\"}");
                return;
            }
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"run_id\":\"{s}\",\"decision\":\"{s}\"}}", .{ id, if (approved) "approved" else "rejected" });
            defer ctx.allocator.free(body);
            try ctx.setHeader("Content-Type", "application/json");
            try ctx.json(200, body);
        }
    };
}

const approval_api_mod = @This();

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
    try std.testing.expect(try queue.resolve("ap-1", null));
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    try std.testing.expect(!try queue.resolve("ap-1", null));
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

test "ApprovalApi mounts with both in-memory and persistent queues" {
    const allocator = std.testing.allocator;

    // In-memory queue + API module.
    var mem_queue = ApprovalQueue.init(allocator, std.testing.io);
    defer mem_queue.deinit();
    const MemApi = ApprovalApi(ApprovalQueue);
    var mem_api = MemApi{ .queue = &mem_queue };

    // Persistent queue + API module.
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend{ .allocator = allocator, .client = &client };
    var persistent = @import("approval_store.zig").PersistentApprovalQueue.init(allocator, &backend);
    try persistent.migrate();
    const PersApi = ApprovalApi(@import("approval_store.zig").PersistentApprovalQueue);
    var pers_api = PersApi{ .queue = &persistent };

    const AppState = struct {};
    var app: AppState = .{};
    var server = @import("../api/Server.zig").Server.initWithConfig(std.testing.io, allocator, .{ .port = 18098 });
    defer server.deinit();
    var router = http.Router(AppState).init(std.testing.io, allocator, &server, &app);
    defer router.deinit();
    var mem_scope = router.scope("/mem");
    try mem_scope.mount(MemApi, &mem_api);
    var pers_scope = router.scope("/pers");
    try pers_scope.mount(PersApi, &pers_api);

    var catalog = try router.finish();
    defer catalog.deinit();
    try std.testing.expect(catalog.entries.len == 6);
    try std.testing.expect(catalog.findEntry(.GET, "mem/approvals/pending") != null);
    try std.testing.expect(catalog.findEntry(.GET, "pers/approvals/pending") != null);
    try std.testing.expect(catalog.findEntry(.POST, "pers/approvals/x/approve") != null);
}

test "approval.request skill submits and reports the chain status" {
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
    var ac = ApprovalCtx{ .flow = &flow, .steps = &steps };

    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerApprovalRequestSkills(&registry);
    const perms = [_][]const u8{"approval:decide"};
    var sctx = SkillContext{ .allocator = allocator, .userdata = &ac, .permissions = &perms };
    var args_map = std.json.ObjectMap{};
    try putOwned(&args_map, allocator, "subject", .{ .string = try allocator.dupe(u8, "order-7") });
    try putOwned(&args_map, allocator, "amount", .{ .float = 9000 });

    const res = try registry.dispatch("approval.request", &sctx, .{ .object = args_map });
    defer freeValue(allocator, res);
    defer freeValue(allocator, .{ .object = args_map });
    try std.testing.expectEqualStrings("pending_human", res.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqualStrings("order-7", queue.items.items[0].run_id);
}
