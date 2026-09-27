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
const skill = @import("skill.zig");
const json_shape = @import("json_shape.zig");

/// `X-Tenant-ID` as a scope. Absent means the caller did not scope the request
/// (the queue then answers with everything it holds); **present but
/// unparseable** is a malformed request, not a missing scope. Reading it as
/// `null` turned `X-Tenant-ID: abc` into an unscoped listing — a typo away
/// from crossing tenants.
fn parseTenantHeader(ctx: *http.Context) error{MalformedTenant}!?i64 {
    const h = ctx.header("X-Tenant-ID") orelse return null;
    return std.fmt.parseInt(i64, h, 10) catch error.MalformedTenant;
}

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
        try self.mu.lock(self.io);
        defer self.mu.unlock(self.io);
        try self.items.append(self.allocator, item);
    }

    /// Resolve an item by run_id: returns true when found and removed. A
    /// non-null `tenant_id` narrows the search to that tenant, which is what
    /// `PersistentApprovalQueue.resolve` does with `WHERE … AND tenant_id = ?`.
    pub fn resolve(self: *Self, run_id: []const u8, tenant_id: ?i64) !bool {
        try self.mu.lock(self.io);
        defer self.mu.unlock(self.io);
        for (self.items.items, 0..) |item, i| {
            if (!tenantMatches(tenant_id, item.tenant_id)) continue;
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

    /// `requested == null` is an unscoped caller and sees every item; a
    /// requested tenant sees only its own rows — an item pushed without a
    /// tenant is *not* visible under a scope, exactly as `tenant_id = NULL`
    /// does not match `WHERE tenant_id = 1` in the SQL queue. The framework
    /// cannot tell which tenant an unscoped escalation belongs to, and guessing
    /// is how the queue answered across tenants before.
    fn tenantMatches(requested: ?i64, item_tenant: ?i64) bool {
        const want = requested orelse return true;
        const have = item_tenant orelse return false;
        return want == have;
    }

    pub fn count(self: *Self) usize {
        // Uncancelable: a fabricated `0` reads as "nothing is pending approval" —
        // the reading the approvals dashboard and the API's own list endpoint are
        // built from — and `usize` has no error channel to report the cancelation
        // in. One list length. Red: `ai.approval_api.test.push, resolve,
        // listPending and count answer a canceled lock wait honestly`.
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.items.items.len;
    }

    /// Copy pending items into `out` (caller owns the strings). Scoped by
    /// `tenant_id` the same way `resolve` is.
    pub fn listPending(self: *Self, allocator: std.mem.Allocator, out: *std.ArrayList(PendingApproval), tenant_id: ?i64) !void {
        try self.mu.lock(self.io);
        defer self.mu.unlock(self.io);
        for (self.items.items) |item| {
            if (!tenantMatches(tenant_id, item.tenant_id)) continue;
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
    sctx: *SkillContext,
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
        // The escalation carries the tenant the run is scoped to; without this
        // the item is tenant-less and a scoped listing cannot see it (see
        // `ApprovalQueue.tenantMatches`).
        .tenant_id = sctx.tenant_id,
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
        .action = .propose,
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
                const obj = try json_shape.object(args);
                const subject_v = obj.get("subject") orelse return error.InvalidArguments;
                const amount_v = obj.get("amount") orelse return error.InvalidArguments;
                if (subject_v != .string) return error.InvalidArguments;
                // The declaration is `.number`, so an integral amount arrives as
                // `.integer` (`{"amount":100}` — what a model usually sends) and
                // a huge/NaN one must not reach `@intFromFloat`, which is UB.
                const amount = json_shape.numberToI64(amount_v) catch return error.InvalidArguments;

                var result = try ac.flow.submit(sctx.allocator, sctx, subject_v.string, amount, ac.steps);
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
            const tenant_id = parseTenantHeader(ctx) catch {
                try ctx.json(400, "{\"err\":\"malformed X-Tenant-ID\"}");
                return;
            };
            try self.queue.listPending(ctx.allocator, &items, tenant_id);

            const body = try buildPendingBody(ctx.allocator, items.items);
            defer ctx.allocator.free(body);
            try ctx.setHeader("Content-Type", "application/json");
            try ctx.json(200, body);
        }

        fn approve(ctx: *http.Context, self: *State) !void {
            try resolveOne(ctx, self, true);
        }

        fn reject(ctx: *http.Context, self: *State) !void {
            try resolveOne(ctx, self, false);
        }

        fn resolveOne(ctx: *http.Context, self: *State, approved: bool) !void {
            const id = try ctx.paramStr("id");
            const tenant_id = parseTenantHeader(ctx) catch {
                try ctx.json(400, "{\"err\":\"malformed X-Tenant-ID\"}");
                return;
            };
            const resolved = try self.queue.resolve(id, tenant_id);
            if (!resolved) {
                try ctx.setHeader("Content-Type", "application/json");
                try ctx.json(404, "{\"err\":\"not found or already resolved\"}");
                return;
            }
            const body = try skill.encodeJsonObject(ctx.allocator, &.{
                .{ .key = "ok", .value = .{ .bool = true } },
                .{ .key = "run_id", .value = .{ .string = id } },
                .{ .key = "decision", .value = .{ .string = if (approved) "approved" else "rejected" } },
            });
            defer ctx.allocator.free(body);
            try ctx.setHeader("Content-Type", "application/json");
            try ctx.json(200, body);
        }

        /// The pending list, rendered by the encoder: `subject` / `note` /
        /// `step_name` can come from a model-authored escalation, and a quote in
        /// any of them used to make the response body unparseable.
        fn buildPendingBody(allocator: std.mem.Allocator, items: []const PendingApproval) ![]u8 {
            var rows = std.json.Array.init(allocator);
            for (items) |item| {
                var row = std.json.ObjectMap{};
                try skill.putJsonField(allocator, &row, "run_id", .{ .string = item.run_id });
                try skill.putJsonField(allocator, &row, "subject", .{ .string = item.subject });
                try skill.putJsonField(allocator, &row, "amount", .{ .integer = item.amount });
                try skill.putJsonField(allocator, &row, "note", .{ .string = item.note });
                try skill.putJsonField(allocator, &row, "step", .{ .string = item.step_name });
                try rows.append(.{ .object = row });
            }
            var obj = std.json.ObjectMap{};
            errdefer skill.freeValue(allocator, .{ .object = obj });
            try skill.putJsonField(allocator, &obj, "pending", .{ .array = rows });
            // Freed here; the only statement left cannot fail, so the `errdefer`
            // above cannot double-free. (`valueAlloc` takes `anytype`, so the
            // value must be typed `std.json.Value` — an inline literal would be
            // stringified as an anonymous struct instead.)
            const tree: std.json.Value = .{ .object = obj };
            const out = try std.json.Stringify.valueAlloc(allocator, tree, .{});
            skill.freeValue(allocator, tree);
            return out;
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
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = @import("../data.zig").SqlxBackend{ .allocator = allocator, .client = &client };

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

test "a tenant-scoped queue does not answer across tenants" {
    const allocator = std.testing.allocator;
    var queue = ApprovalQueue.init(allocator, std.testing.io);
    defer queue.deinit();

    const push = struct {
        fn f(q: *ApprovalQueue, a: std.mem.Allocator, run_id: []const u8, tenant: ?i64) !void {
            try q.push(.{
                .run_id = try a.dupe(u8, run_id),
                .subject = try a.dupe(u8, run_id),
                .amount = 1,
                .note = try a.dupe(u8, ""),
                .step_name = try a.dupe(u8, "finance"),
                .tenant_id = tenant,
            });
        }
    }.f;
    try push(&queue, allocator, "a", 1);
    try push(&queue, allocator, "b", 2);
    try push(&queue, allocator, "c", null); // e.g. an escalation from an unscoped run

    var out = std.ArrayList(PendingApproval).empty;
    const freeAll = struct {
        fn f(a: std.mem.Allocator, list: *std.ArrayList(PendingApproval)) void {
            for (list.items) |item| {
                a.free(item.run_id);
                a.free(item.subject);
                a.free(item.note);
                a.free(item.step_name);
            }
            list.clearRetainingCapacity();
        }
    }.f;
    defer {
        freeAll(allocator, &out);
        out.deinit(allocator);
    }

    // Tenant 1 sees its own row — not tenant 2's, and not the tenant-less one,
    // which is exactly what `WHERE … AND tenant_id = 1` does in the SQL queue.
    try queue.listPending(allocator, &out, 1);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("a", out.items[0].run_id);
    try std.testing.expectEqual(@as(i64, 1), out.items[0].tenant_id.?);
    freeAll(allocator, &out);

    // ...and cannot resolve another tenant's item, while that tenant can.
    try std.testing.expect(!try queue.resolve("b", 1));
    try std.testing.expect(try queue.resolve("b", 2));

    // An unscoped caller is the only one that sees the tenant-less item.
    try queue.listPending(allocator, &out, null);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}

test "ApprovalApi mounts with both in-memory and persistent queues" {
    const allocator = std.testing.allocator;

    // In-memory queue + API module.
    var mem_queue = ApprovalQueue.init(allocator, std.testing.io);
    defer mem_queue.deinit();
    const MemApi = ApprovalApi(ApprovalQueue);
    var mem_api = MemApi{ .queue = &mem_queue };

    // Persistent queue + API module.
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = @import("../data.zig").SqlxBackend{ .allocator = allocator, .client = &client };
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
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = @import("../data.zig").SqlxBackend{ .allocator = allocator, .client = &client };
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

/// Park `read` on `mutex` with a cancel request already placed on its thread, then
/// let it through: the lock wait becomes the cancelation point. `std.Io.Mutex.lock`'s
/// uncontended fast path does not check for cancellation, so it is the contended
/// wait that can come back canceled.
fn readUnderCanceledLockWait(
    comptime T: type,
    target: *T,
    mutex: *std.Io.Mutex,
    io: std.Io,
    comptime read: fn (*T) void,
) !void {
    const Gate = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn run(t: *T) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            read(t);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Gate.entered.store(false, .monotonic);
    Gate.open.store(false, .monotonic);

    try mutex.lock(io);

    var read_fut = try io.concurrent(Gate.run, .{target});
    while (!Gate.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Gate.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Gate.open.store(true, .release);
    while (mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);
}

// Four lock waits, answered by whether the caller can be told:
//   - `push`, `resolve` and `listPending` return errors and abandon nothing (the
//     queue is untouched), so the cancelation is *propagated* as `error.Canceled`
//     — the only error `std.Io.Mutex.lock` has. `error.LockFailed` named
//     lock-machinery failure for it, which a caller cannot tell from "this
//     queue's lock is broken";
//   - `count` returns `usize`, and a fabricated `0` reads as "nothing is pending
//     approval" — the reading an operator dashboard is built from — so it *waits*
//     (`lockUncancelable`). One list length.
//
// Red evidence: with the old shapes the first assertion below reads `expected
// error.Canceled, found error.LockFailed` (and the `count` one reads
// `expected 1, found 0`). Each `try` ends the test at the first failure, so the
// later assertions are only exercised green.
test "push, resolve, listPending and count answer a canceled lock wait honestly" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var queue = ApprovalQueue.init(allocator, io);
    defer queue.deinit();

    // Empty strings on purpose: a `push` that goes through hands the item to the
    // queue, whose `deinit` frees those fields — a literal would be a bad free.
    const PushRead = struct {
        var seen: ?anyerror = null;
        fn read(q: *ApprovalQueue) void {
            seen = null;
            q.push(.{ .run_id = "", .subject = "", .amount = 1, .note = "", .step_name = "" }) catch |err| {
                seen = err;
            };
        }
    };
    PushRead.seen = null;
    try readUnderCanceledLockWait(ApprovalQueue, &queue, &queue.mu, io, PushRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), PushRead.seen);

    const ResolveRead = struct {
        var seen: ?anyerror = null;
        fn read(q: *ApprovalQueue) void {
            seen = null;
            _ = q.resolve("ap-none", null) catch |err| {
                seen = err;
                return;
            };
        }
    };
    ResolveRead.seen = null;
    try readUnderCanceledLockWait(ApprovalQueue, &queue, &queue.mu, io, ResolveRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), ResolveRead.seen);

    const ListRead = struct {
        var seen: ?anyerror = null;
        fn read(q: *ApprovalQueue) void {
            seen = null;
            var out = std.ArrayList(PendingApproval).empty;
            defer {
                for (out.items) |item| {
                    std.testing.allocator.free(item.run_id);
                    std.testing.allocator.free(item.subject);
                    std.testing.allocator.free(item.note);
                    std.testing.allocator.free(item.step_name);
                }
                out.deinit(std.testing.allocator);
            }
            q.listPending(std.testing.allocator, &out, null) catch |err| {
                seen = err;
            };
        }
    };
    ListRead.seen = null;
    try readUnderCanceledLockWait(ApprovalQueue, &queue, &queue.mu, io, ListRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), ListRead.seen);

    // Seeded on this thread (the queue frees these), so `1` is unambiguous
    // evidence that the canceled wait was answered with a fabricated `0`.
    try queue.push(.{
        .run_id = try allocator.dupe(u8, "ap-1"),
        .subject = try allocator.dupe(u8, "order-1"),
        .amount = 1,
        .note = try allocator.dupe(u8, "needs CFO"),
        .step_name = try allocator.dupe(u8, "finance"),
    });
    const CountRead = struct {
        var seen: usize = 0;
        fn read(q: *ApprovalQueue) void {
            seen = q.count();
        }
    };
    CountRead.seen = 0;
    try readUnderCanceledLockWait(ApprovalQueue, &queue, &queue.mu, io, CountRead.read);
    try std.testing.expectEqual(@as(usize, 1), CountRead.seen);
}

test "GET /approvals/pending escapes quotes in the pending rows" {
    const allocator = std.testing.allocator;

    var queue = ApprovalQueue.init(allocator, std.testing.io);
    defer queue.deinit();
    try queue.push(.{
        .run_id = try allocator.dupe(u8, "ap-\"1\""),
        .subject = try allocator.dupe(u8, "order \"9\""),
        .amount = 50000,
        .note = try allocator.dupe(u8, "needs \\ CFO"),
        .step_name = try allocator.dupe(u8, "finance"),
    });

    const Api = ApprovalApi(ApprovalQueue);
    var api_state = Api{ .queue = &queue };
    const AppState = struct {};
    var app: AppState = .{};
    var server = @import("../api/Server.zig").Server.initWithConfig(std.testing.io, allocator, .{ .port = 18097 });
    defer server.deinit();
    var router = http.Router(AppState).init(std.testing.io, allocator, &server, &app);
    defer router.deinit();
    var root = router.scope("");
    try root.mount(Api, &api_state);
    var slot: @import("../api/ComptimeRouter.zig").CatalogSlot = .{};
    defer slot.deinit();
    slot.set(try router.finish());

    var resp = try @import("../http/Testkit.zig").dispatch(&server, .GET, "/approvals/pending", null);
    defer resp.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
    defer parsed.deinit();
    const pending = parsed.value.object.get("pending").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    const row = pending[0].object;
    try std.testing.expectEqualStrings("ap-\"1\"", row.get("run_id").?.string);
    try std.testing.expectEqualStrings("order \"9\"", row.get("subject").?.string);
    try std.testing.expectEqual(@as(i64, 50000), row.get("amount").?.integer);
    try std.testing.expectEqualStrings("needs \\ CFO", row.get("note").?.string);
    try std.testing.expectEqualStrings("finance", row.get("step").?.string);
}
