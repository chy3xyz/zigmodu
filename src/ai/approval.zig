//! Multi-level approval chains ("审批链"): a request travels through a
//! configured list of approval steps; each step is decided by a policy
//! callback (or the default escalate-to-human rule) and the chain stops on the
//! first rejection or human escalation. Every decision is written to the
//! transactional outbox (`ai.approval`) for audit and downstream automation.
//! A thin skill bridge (`registerApprovalSkills`) lets an Agent submit
//! approvals that use the app-registered chain — the LLM only supplies the
//! subject/amount/request description, never policy logic.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const SkillRegistry = @import("skill.zig").SkillRegistry;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const sqlx = @import("../sqlx/sqlx.zig");

/// What happened at one approval step.
pub const ApprovalDecision = enum { approved, escalated, rejected };

/// One step in the chain. `name` is caller-owned (e.g. "line manager",
/// "finance").
pub const ApprovalStep = struct {
    name: []const u8,
};

/// A resolved step: the decision plus an optional human note. The note is
/// owned by the approval chain and freed by `ApprovalResult.deinit`.
pub const ApprovalEntry = struct {
    step: []const u8,
    decision: ApprovalDecision,
    note: []const u8 = "",
};

pub const ApprovalStatus = enum { approved, pending_human, rejected };

/// Policy hook: the app decides each step (wire to an LLM, RBAC matrix, or
/// rule engine). On approval the chain advances; on escalation the chain stops
/// and waits for a human (the outbox event is the queue for the human queue);
/// on rejection the chain stops as failed.
/// `out_note` may be set to a caller-allocated string; the flow takes
/// ownership and frees it via the chain deinit.
pub const DecidePolicyFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    subject: []const u8,
    amount: i64,
    step_index: usize,
    step_name: []const u8,
    context_block: []const u8,
    out_note: *[]const u8,
) anyerror!ApprovalDecision;

pub const ApprovalResult = struct {
    run_id: []const u8,
    subject: []const u8,
    amount: i64,
    status: ApprovalStatus,
    entries: []ApprovalEntry,

    /// Final outcome; pending_human means the chain stopped at an escalation.
    pub fn deinit(self: *ApprovalResult, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.subject);
        for (self.entries) |e| {
            allocator.free(e.step);
            if (e.note.len > 0) allocator.free(e.note);
        }
        allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Signature for the human-escalation hook on `ApprovalFlow`.
pub const EscalatedFn = *const fn (
    userdata: *anyopaque,
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    subject: []const u8,
    amount: i64,
    step_name: []const u8,
    note: []const u8,
) anyerror!void;

pub const ApprovalFlow = struct {
    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    policy: DecidePolicyFn,
    /// Optional hook fired when a step escalates to a human (e.g. push the
    /// run into a human approval queue). Strings are call-scoped; the hook
    /// must copy anything it keeps.
    on_escalated: ?EscalatedFn = null,
    escalated_userdata: *anyopaque = undefined,
    outbox: ?*OutboxPublisher = null,
    outbox_topic: []const u8 = "ai.approval",
    /// Optional reporter queries rendered as context for the policy callback.
    context_queries: []const @import("reporter.zig").ReportQuery = &.{},

    pub fn init(allocator: std.mem.Allocator, backend: *SqlxBackend, policy: DecidePolicyFn) ApprovalFlow {
        return .{ .allocator = allocator, .backend = backend, .policy = policy };
    }

    /// Run an approval request through the chain. Caller owns the returned
    /// result (`deinit`). Writes one outbox event per step + one final event.
    pub fn submit(
        self: *ApprovalFlow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        subject: []const u8,
        amount: i64,
        steps: []const ApprovalStep,
    ) !ApprovalResult {
        const run_id = try std.fmt.allocPrint(allocator, "ap-{x}", .{@intFromPtr(subject.ptr)});
        errdefer allocator.free(run_id);

        var context_block: []const u8 = "";
        if (self.context_queries.len > 0) {
            var rep = @import("reporter.zig").BusinessReporter.init(allocator, self.backend, "Approval context", self.context_queries);
            const block = try rep.generate(allocator);
            context_block = block;
        }
        defer if (context_block.len > 0) allocator.free(@constCast(context_block));

        var entries = std.ArrayList(ApprovalEntry).empty;
        errdefer {
            for (entries.items) |e| {
                allocator.free(e.step);
                if (e.note.len > 0) allocator.free(e.note);
            }
            entries.deinit(allocator);
        }

        var status: ApprovalStatus = .approved;
        for (steps, 0..) |step, idx| {
            var note: []const u8 = "";
            const decision = try self.policy(allocator, ctx, subject, amount, idx, step.name, context_block, &note);
            try entries.append(allocator, .{
                .step = try allocator.dupe(u8, step.name),
                .decision = decision,
                .note = note,
            });
            try self.writeOutbox(allocator, run_id, subject, amount, step.name, decision, note);
            if (decision == .rejected) {
                status = .rejected;
                break;
            }
            if (decision == .escalated) {
                if (self.on_escalated) |cb| try cb(self.escalated_userdata, allocator, ctx, subject, amount, step.name, note);
                status = .pending_human;
                break;
            }
        }

        // Final event summarizes the chain outcome.
        try self.writeFinal(allocator, run_id, subject, amount, status, entries.items.len);

        return .{
            .run_id = run_id,
            .subject = try allocator.dupe(u8, subject),
            .amount = amount,
            .status = status,
            .entries = try entries.toOwnedSlice(allocator),
        };
    }

    fn writeOutbox(
        self: *ApprovalFlow,
        allocator: std.mem.Allocator,
        run_id: []const u8,
        subject: []const u8,
        amount: i64,
        step: []const u8,
        decision: ApprovalDecision,
        note: []const u8,
    ) !void {
        const ob = self.outbox orelse return;
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"run_id\":\"{s}\",\"subject\":\"{s}\",\"amount\":{d},\"step\":\"{s}\",\"decision\":\"{s}\",\"note\":\"{s}\"}}",
            .{ run_id, subject, amount, step, @tagName(decision), note },
        );
        defer allocator.free(payload);
        const insert = try ob.buildInsert(self.outbox_topic, payload);
        _ = try self.backend.exec(insert.sql, &.{
            .{ .string = insert.params.topic },
            .{ .string = insert.params.payload },
            .{ .int = @intCast(insert.params.max_retries) },
            .{ .int = insert.params.created_at },
            .{ .int = insert.params.updated_at },
        });
    }

    fn writeFinal(
        self: *ApprovalFlow,
        allocator: std.mem.Allocator,
        run_id: []const u8,
        subject: []const u8,
        amount: i64,
        status: ApprovalStatus,
        steps_done: usize,
    ) !void {
        const ob = self.outbox orelse return;
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"run_id\":\"{s}\",\"subject\":\"{s}\",\"amount\":{d},\"status\":\"{s}\",\"steps_done\":{d}}}",
            .{ run_id, subject, amount, @tagName(status), steps_done },
        );
        defer allocator.free(payload);
        const insert = try ob.buildInsert(self.outbox_topic, payload);
        _ = try self.backend.exec(insert.sql, &.{
            .{ .string = insert.params.topic },
            .{ .string = insert.params.payload },
            .{ .int = @intCast(insert.params.max_retries) },
            .{ .int = insert.params.created_at },
            .{ .int = insert.params.updated_at },
        });
    }
};

/// Default policy: escalate every step to a human (safe default). Apps replace
/// this with rule/LLM-driven policies.
pub fn defaultPolicy(
    _: std.mem.Allocator,
    _: *SkillContext,
    _: []const u8,
    _: i64,
    _: usize,
    _: []const u8,
    _: []const u8,
    _: *[]const u8,
) anyerror!ApprovalDecision {
    return .escalated;
}

/// Capability bundle for the approval skill bridge. The caller owns this value
/// (keep it alive for the registry's lifetime) and sets
/// `SkillContext.userdata = &approval_ctx` before dispatch.
pub const ApprovalCtx = struct {
    flow: *ApprovalFlow,
    steps: []const ApprovalStep,
};

/// Register `approval.submit` — an Agent submits a subject/amount/request and
/// the app-registered chain runs with the flow's policy. Returns the run id +
/// final status so the LLM can report it.
pub fn registerApprovalSkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "approval.submit",
        .description = "Submit a business request through the configured multi-level approval chain; returns the approval run id and status (approved / pending_human / rejected)",
        .parameters = &.{
            .{ .name = "subject", .type = .string, .description = "What is being approved, e.g. order number or refund id", .required = true },
            .{ .name = "amount", .type = .integer, .description = "Monetary amount involved (cents or minor units)", .required = true },
            .{ .name = "request", .type = .string, .description = "Human-readable request description", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *ApprovalCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.ApprovalNotConfigured));
                const obj = args.object;
                const subj_v = obj.get("subject") orelse return error.InvalidArguments;
                const amt_v = obj.get("amount") orelse return error.InvalidArguments;
                _ = obj.get("request") orelse return error.InvalidArguments;
                if (subj_v != .string or amt_v != .integer) return error.InvalidArguments;

                const result = try ac.flow.submit(sctx.allocator, sctx, subj_v.string, amt_v.integer, ac.steps);
                defer result.deinit(sctx.allocator);
                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "run_id", .{ .string = try sctx.allocator.dupe(u8, result.run_id) });
                try putOwned(&out, sctx.allocator, "status", .{ .string = try sctx.allocator.dupe(u8, @tagName(result.status)) });
                return .{ .object = out };
            }
        }.h,
    });
}

/// ObjectMap does not copy keys and deinit does not free them; results must
/// own every key so `freeValue` can release them.
fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

test "ApprovalFlow advances, escalates and rejects with outbox audit" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });

    const T = struct {
        fn policy(
            a: std.mem.Allocator,
            _: *SkillContext,
            _: []const u8,
            amount: i64,
            step_index: usize,
            _: []const u8,
            _: []const u8,
            out_note: *[]const u8,
        ) anyerror!ApprovalDecision {
            if (step_index == 0) return .approved;
            if (amount > 10000) {
                out_note.* = try a.dupe(u8, "needs CFO sign-off");
                return .escalated;
            }
            return .rejected;
        }
    };

    var flow = ApprovalFlow.init(allocator, &backend, T.policy);
    flow.outbox = &outbox;
    const steps = [_]ApprovalStep{
        .{ .name = "line manager" },
        .{ .name = "finance" },
        .{ .name = "CFO" },
    };
    var ctx = SkillContext{ .allocator = allocator };

    // Escalation stops the chain at step 2.
    var res = try flow.submit(allocator, &ctx, "order-1", 50000, &steps);
    defer res.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), res.entries.len);
    try std.testing.expectEqual(ApprovalDecision.approved, res.entries[0].decision);
    try std.testing.expectEqual(ApprovalDecision.escalated, res.entries[1].decision);
    try std.testing.expectEqualStrings("needs CFO sign-off", res.entries[1].note);
    try std.testing.expectEqual(ApprovalStatus.pending_human, res.status);

    // Rejection path.
    var res2 = try flow.submit(allocator, &ctx, "order-2", 100, &steps);
    defer res2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), res2.entries.len);
    try std.testing.expectEqual(ApprovalDecision.rejected, res2.entries[1].decision);
    try std.testing.expectEqual(ApprovalStatus.rejected, res2.status);

    // Outbox audit trail: 2 step events + 1 final event per run.
    var cursor = try client.queryCursorEx(
        "SELECT payload FROM event_outbox WHERE topic = 'ai.approval'",
        &.{},
        .{},
    );
    defer cursor.deinit();
    var n: usize = 0;
    while (cursor.next()) |row| {
        _ = row.get("payload").?.string;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), n);
}

test "ApprovalFlow default policy escalates every step to a human" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var flow = ApprovalFlow.init(allocator, &backend, defaultPolicy);
    const steps = [_]ApprovalStep{.{ .name = "manager" }};
    var ctx = SkillContext{ .allocator = allocator };
    var res = try flow.submit(allocator, &ctx, "order-9", 1, &steps);
    defer res.deinit(allocator);
    try std.testing.expectEqual(ApprovalStatus.pending_human, res.status);
}
