//! Proposal → Risk → Execution, in that order and no other.
//!
//! `guard.zig` answers "may this agent act at all"; this file answers "and only
//! through which stages". `todo3.md` §八 requires that an agent *proposes*, that
//! risk decides, and only then that something happens.
//!
//! The engines already exist in this directory — `risk.RiskReview` scores SQL
//! rules and maps the score to approve/reject/escalate, `approval.ApprovalFlow`
//! runs the human chain — what was missing is the composition that makes
//! skipping a stage impossible: `executeStage` is private, and it starts at the
//! guard.
//!
//! Note what the nominal outcome for an agent is: **not** `executed`. It is
//! `execute_not_permitted` carrying the risk result — a proposal a human (or
//! another system) can act on. That is the shape §八 asks for, and it is what a
//! default policy (empty allow list, `allow_execute = false`) produces.

const std = @import("std");
const guard_mod = @import("guard.zig");
const risk_mod = @import("risk.zig");
const approval_mod = @import("approval.zig");
const SkillContext = @import("skill.zig").SkillContext;

/// Where a proposal ended up.
pub const Verdict = enum {
    /// Risk approved and the policy permits execution.
    executed,
    /// The policy does not even let this agent propose this action.
    propose_refused,
    /// Risk review rejected it.
    risk_rejected,
    /// Risk escalated and the human chain has not approved it (yet).
    needs_human,
    /// Risk said yes, but the policy does not let this agent execute — hand the
    /// proposal, with its risk result, to a human or another system. This is the
    /// **normal** verdict for an agent, not a failure.
    execute_not_permitted,
    /// The executor itself returned an error.
    executor_failed,
};

/// The effect side. Owned by the application — the framework only guarantees
/// the order in which it can be reached.
pub const ExecutorFn = *const fn (
    userdata: ?*anyopaque,
    ctx: *SkillContext,
    action: []const u8,
    payload: []const u8,
) anyerror!void;

pub const Proposal = struct {
    /// Action name, matched against the policy's `allow` / `deny` entries.
    action: []const u8,
    /// Handed to the risk stage and to the executor (order id, JSON, …).
    payload: []const u8,
    /// Risk subject, e.g. `order-1`. Defaults to `payload`.
    subject: ?[]const u8 = null,
    /// Amount involved, passed to the approval chain. The risk *score* is not a
    /// substitute for it — one is a judgement, the other is money.
    amount: i64 = 0,
    /// Tokens this execution would cost; charged to the guard only after the
    /// execute check succeeds.
    estimated_tokens: u64 = 0,
};

pub const Outcome = struct {
    verdict: Verdict,
    /// Present once the risk stage ran (borrows `Proposal` strings).
    risk: ?risk_mod.RiskResult = null,
    /// Present once the approval chain ran.
    approval_status: ?approval_mod.ApprovalStatus = null,

    pub fn executed(self: Outcome) bool {
        return self.verdict == .executed;
    }
};

pub const Pipeline = struct {
    guard: *guard_mod.Guard,
    executor: ExecutorFn,
    executor_userdata: ?*anyopaque = null,
    /// Optional risk engine. Without it the pipeline still refuses to execute
    /// unless the policy says `allow_execute` — the risk stage is what turns a
    /// bare refusal into an informed one.
    risk: ?*risk_mod.RiskReview = null,
    /// Optional human chain, consulted when risk escalates. Without it an
    /// escalation is a hard stop: an agent never approves itself.
    approval: ?*approval_mod.ApprovalFlow = null,
    approval_steps: []const approval_mod.ApprovalStep = &.{},

    pub fn init(guard: *guard_mod.Guard, executor: ExecutorFn) Pipeline {
        return .{ .guard = guard, .executor = executor };
    }

    /// Run one proposal through the stages. A *refusal* is not an error — the
    /// verdict carries the reason; the error set is reserved for infrastructure
    /// failures inside the risk / approval engines.
    pub fn submit(self: *Pipeline, allocator: std.mem.Allocator, ctx: *SkillContext, p: Proposal) !Outcome {
        if (self.guard.check(.propose, p.action, 0) != .allowed) {
            return .{ .verdict = .propose_refused };
        }

        const subject = p.subject orelse p.payload;
        var risk_result: ?risk_mod.RiskResult = null;
        var approval_status: ?approval_mod.ApprovalStatus = null;

        // Risk runs *before* the execute check on purpose: a refused execution
        // should still carry a verdict someone can act on.
        if (self.risk) |review| {
            const r = try review.review(allocator, ctx, subject);
            risk_result = r;
            switch (r.decision) {
                .reject => return .{ .verdict = .risk_rejected, .risk = r },
                .approve => {},
                .escalate => {
                    const flow = self.approval orelse return .{ .verdict = .needs_human, .risk = r };
                    var res = try flow.submit(allocator, ctx, subject, p.amount, self.approval_steps);
                    defer res.deinit(allocator);
                    approval_status = res.status;
                    switch (res.status) {
                        .rejected => return .{ .verdict = .risk_rejected, .risk = r, .approval_status = approval_status },
                        .pending_human => return .{ .verdict = .needs_human, .risk = r, .approval_status = approval_status },
                        .approved => {},
                    }
                },
            }
        }

        return .{
            .verdict = self.executeStage(ctx, p),
            .risk = risk_result,
            .approval_status = approval_status,
        };
    }

    /// The only path to the executor, and it starts at the policy.
    fn executeStage(self: *Pipeline, ctx: *SkillContext, p: Proposal) Verdict {
        if (self.guard.check(.execute, p.action, p.estimated_tokens) != .allowed) {
            return .execute_not_permitted;
        }
        self.executor(self.executor_userdata, ctx, p.action, p.payload) catch return .executor_failed;
        return .executed;
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

const budget_mod = @import("budget.zig");
const sqlx = @import("../data.zig").sqlx;
const SqlxBackend = @import("../data.zig").SqlxBackend;

const TestExec = struct {
    var calls: usize = 0;
    var last_action: []const u8 = "";
    var last_payload: []const u8 = "";

    fn run(_: ?*anyopaque, _: *SkillContext, action: []const u8, payload: []const u8) anyerror!void {
        calls += 1;
        last_action = action;
        last_payload = payload;
    }

    fn fail(_: ?*anyopaque, _: *SkillContext, _: []const u8, _: []const u8) anyerror!void {
        return error.ExecutorBoom;
    }

    fn reset() void {
        calls = 0;
        last_action = "";
        last_payload = "";
    }
};

fn approveAllPolicy(
    _: std.mem.Allocator,
    _: *SkillContext,
    _: []const u8,
    _: i64,
    _: usize,
    _: []const u8,
    _: []const u8,
    _: *[]const u8,
) anyerror!approval_mod.ApprovalDecision {
    return .approved;
}

test "Pipeline: a policy that grants nothing refuses at the proposal stage" {
    const allocator = std.testing.allocator;
    TestExec.reset();

    var guard = guard_mod.Guard.init(.{});
    var pipeline = Pipeline.init(&guard, TestExec.run);
    var ctx = SkillContext{ .allocator = allocator };

    const out = try pipeline.submit(allocator, &ctx, .{ .action = "order.submit", .payload = "order-1" });
    try std.testing.expectEqual(Verdict.propose_refused, out.verdict);
    try std.testing.expectEqual(@as(usize, 0), TestExec.calls);
    try std.testing.expectEqual(@as(u64, 1), guard.stats().denied_not_listed);
}

test "Pipeline: a proposal the agent may not execute is handed over, not run" {
    const allocator = std.testing.allocator;
    TestExec.reset();

    // Listed in `allow` but `allow_execute` is off: the agent may propose, not act.
    var guard = guard_mod.Guard.init(.{ .allow = &.{"order.submit"} });
    var pipeline = Pipeline.init(&guard, TestExec.run);
    var ctx = SkillContext{ .allocator = allocator };

    const out = try pipeline.submit(allocator, &ctx, .{ .action = "order.submit", .payload = "order-7" });
    try std.testing.expectEqual(Verdict.execute_not_permitted, out.verdict);
    try std.testing.expect(!out.executed());
    try std.testing.expectEqual(@as(usize, 0), TestExec.calls);

    const s = guard.stats();
    try std.testing.expectEqual(@as(u64, 1), s.allowed); // the proposal itself was allowed
    try std.testing.expectEqual(@as(u64, 1), s.denied_execute_class);
}

test "Pipeline: execution needs the policy's second switch, and a failure is reported" {
    const allocator = std.testing.allocator;
    TestExec.reset();

    var guard = guard_mod.Guard.init(.{ .allow = &.{"order.submit"}, .allow_execute = true });
    guard.budget = budget_mod.Budget.init(100);
    var pipeline = Pipeline.init(&guard, TestExec.run);
    var ctx = SkillContext{ .allocator = allocator };

    const out = try pipeline.submit(allocator, &ctx, .{
        .action = "order.submit",
        .payload = "order-9",
        .estimated_tokens = 5,
    });
    try std.testing.expect(out.executed());
    try std.testing.expectEqual(@as(usize, 1), TestExec.calls);
    try std.testing.expectEqualStrings("order.submit", TestExec.last_action);
    try std.testing.expectEqualStrings("order-9", TestExec.last_payload);
    try std.testing.expectEqual(@as(u64, 5), guard.stats().tokens_used);

    // Same policy, an executor that fails: the verdict says so instead of
    // pretending the effect happened.
    var failing = Pipeline.init(&guard, TestExec.fail);
    const out2 = try failing.submit(allocator, &ctx, .{ .action = "order.submit", .payload = "order-10" });
    try std.testing.expectEqual(Verdict.executor_failed, out2.verdict);
}

test "Pipeline: risk rejects or escalates before the executor is reached" {
    const allocator = std.testing.allocator;
    TestExec.reset();

    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, amount INTEGER)", &.{});
    _ = try client.exec("INSERT INTO orders (amount) VALUES (5000)", &.{});
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };

    const hot_rules = [_]risk_mod.RiskRule{
        .{ .name = "whale", .sql = "SELECT id FROM orders WHERE amount >= 1000", .score = 150 },
    };
    const warm_rules = [_]risk_mod.RiskRule{
        .{ .name = "large", .sql = "SELECT id FROM orders WHERE amount >= 1000", .score = 60 },
    };

    var guard = guard_mod.Guard.init(.{ .allow = &.{"order.submit"}, .allow_execute = true });
    var ctx = SkillContext{ .allocator = allocator };

    // High score → the review itself rejects.
    var hot = risk_mod.RiskReview.init(allocator, &backend);
    hot.rules = &hot_rules;
    var p1 = Pipeline.init(&guard, TestExec.run);
    p1.risk = &hot;
    const out1 = try p1.submit(allocator, &ctx, .{ .action = "order.submit", .payload = "order-1" });
    try std.testing.expectEqual(Verdict.risk_rejected, out1.verdict);
    try std.testing.expectEqual(risk_mod.RiskLevel.high, out1.risk.?.level);
    try std.testing.expectEqual(@as(usize, 0), TestExec.calls);

    // Medium score → escalate, and no chain is configured: a hard stop. The
    // agent does not get to approve itself just because nobody is around.
    var warm = risk_mod.RiskReview.init(allocator, &backend);
    warm.rules = &warm_rules;
    var p2 = Pipeline.init(&guard, TestExec.run);
    p2.risk = &warm;
    const out2 = try p2.submit(allocator, &ctx, .{ .action = "order.submit", .payload = "order-2" });
    try std.testing.expectEqual(Verdict.needs_human, out2.verdict);
    try std.testing.expectEqual(risk_mod.RiskLevel.medium, out2.risk.?.level);
    try std.testing.expectEqual(@as(?approval_mod.ApprovalStatus, null), out2.approval_status);
    try std.testing.expectEqual(@as(usize, 0), TestExec.calls);

    // Clean score → approve → now the execute stage may run.
    var clean = risk_mod.RiskReview.init(allocator, &backend);
    var p3 = Pipeline.init(&guard, TestExec.run);
    p3.risk = &clean;
    const out3 = try p3.submit(allocator, &ctx, .{ .action = "order.submit", .payload = "order-3", .amount = 200 });
    try std.testing.expectEqual(Verdict.executed, out3.verdict);
    try std.testing.expectEqual(risk_mod.RiskLevel.low, out3.risk.?.level);
    try std.testing.expectEqual(@as(usize, 1), TestExec.calls);
}

test "Pipeline: an approval chain is what turns an escalation into execution" {
    const allocator = std.testing.allocator;
    TestExec.reset();

    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, amount INTEGER)", &.{});
    _ = try client.exec("INSERT INTO orders (amount) VALUES (5000)", &.{});
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };

    const warm_rules = [_]risk_mod.RiskRule{
        .{ .name = "large", .sql = "SELECT id FROM orders WHERE amount >= 1000", .score = 60 },
    };
    var warm = risk_mod.RiskReview.init(allocator, &backend);
    warm.rules = &warm_rules;

    const steps = [_]approval_mod.ApprovalStep{.{ .name = "finance" }};
    var guard = guard_mod.Guard.init(.{ .allow = &.{"order.submit"}, .allow_execute = true });
    var ctx = SkillContext{ .allocator = allocator };

    // The framework's own default policy escalates every step to a human, so an
    // escalation stays pending — nothing runs on the model's say-so.
    var human_chain = approval_mod.ApprovalFlow.init(allocator, &backend, approval_mod.defaultPolicy);
    var p1 = Pipeline.init(&guard, TestExec.run);
    p1.risk = &warm;
    p1.approval = &human_chain;
    p1.approval_steps = &steps;
    const out1 = try p1.submit(allocator, &ctx, .{ .action = "order.submit", .payload = "order-1", .amount = 5000 });
    try std.testing.expectEqual(Verdict.needs_human, out1.verdict);
    try std.testing.expectEqual(@as(?approval_mod.ApprovalStatus, .pending_human), out1.approval_status);
    try std.testing.expectEqual(@as(usize, 0), TestExec.calls);

    // A chain that actually approves (an app-owned policy) is the one path that
    // reaches the executor after an escalation.
    var approving_chain = approval_mod.ApprovalFlow.init(allocator, &backend, approveAllPolicy);
    var p2 = Pipeline.init(&guard, TestExec.run);
    p2.risk = &warm;
    p2.approval = &approving_chain;
    p2.approval_steps = &steps;
    const out2 = try p2.submit(allocator, &ctx, .{ .action = "order.submit", .payload = "order-2", .amount = 5000 });
    try std.testing.expectEqual(Verdict.executed, out2.verdict);
    try std.testing.expectEqual(@as(?approval_mod.ApprovalStatus, .approved), out2.approval_status);
    try std.testing.expectEqual(@as(usize, 1), TestExec.calls);
}
