//! Linear multi-step agent workflow (orchestration).
//!
//! Runs steps in order, recording a Saga-style per-step record (status, error,
//! output) and enforcing a shared `Budget` across LLM-consuming steps. WAL
//! persistence / crash recovery / resume is planned (P1); v1 is an in-process
//! runner that returns a full audit trail for the caller to persist.

const std = @import("std");
const provider_mod = @import("provider.zig");
const skill_mod = @import("skill.zig");
const agent_mod = @import("agent.zig");
const tokenizer = @import("tokenizer.zig");
const Budget = @import("budget.zig").Budget;
const WAL = @import("../core/eventbus/WAL.zig").WAL;
const Time = @import("../core/Time.zig");

pub const AiProvider = provider_mod.AiProvider;
pub const SkillRegistry = skill_mod.SkillRegistry;
pub const SkillContext = skill_mod.SkillContext;
pub const Agent = agent_mod.Agent;

/// What a workflow step does.
pub const StepKind = union(enum) {
    /// One plain LLM turn (no tools).
    llm: struct { prompt: []const u8 },
    /// One registered skill dispatch.
    skill: struct { name: []const u8, args: std.json.Value },
    /// A full ReAct agent run (tools allowed).
    agent: struct { goal: []const u8, max_steps: usize },
    /// Human-in-the-loop gate: run an approval flow for this step; the run
    /// stops with `.pending_human` when the flow escalates (resume after the
    /// human decides re-runs this step with the same policy).
    approval: struct { subject: []const u8, amount: i64 },
};

pub const Step = struct {
    name: []const u8,
    kind: StepKind,
    retry: usize = 0,
    /// DAG dependency: run only after these step names complete. Empty keeps
    /// linear (declaration order) semantics.
    depends_on: []const []const u8 = &.{},
};

pub const StepStatus = enum { pending, running, completed, failed };
pub const RunStatus = enum { completed, failed, budget_exhausted, pending_human };

pub const EscalateReason = enum { step_failed, budget_exhausted, verification_failed };

/// Verify the final output; return false to trigger a review re-run.
pub const VerifyFn = *const fn (
    ctx: *SkillContext,
    goal: []const u8,
    output: []const u8,
    allocator: std.mem.Allocator,
) anyerror!bool;

/// Called when the workflow cannot proceed (step failure, budget exhaustion,
/// persistent verification failure) so the app can escalate to a human.
pub const EscalateFn = *const fn (
    ctx: *SkillContext,
    reason: EscalateReason,
    step: ?[]const u8,
    allocator: std.mem.Allocator,
) anyerror!void;

pub const StepRecord = struct {
    name: []const u8,
    status: StepStatus,
    error_message: ?[]const u8 = null,
    output: []const u8 = "",
};

pub const WorkflowResult = struct {
    status: RunStatus,
    steps: std.ArrayList(StepRecord),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WorkflowResult) void {
        for (self.steps.items) |rec| {
            self.allocator.free(rec.name);
            if (rec.error_message) |em| self.allocator.free(em);
            if (rec.output.len > 0) self.allocator.free(rec.output);
        }
        self.steps.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Aggregated counters for workflow runs. Attach via `Workflow.metrics`; the
/// counters are updated on every run / resume, including DAG waves.
pub const WorkflowMetrics = struct {
    runs: usize = 0,
    completed_steps: usize = 0,
    failed_steps: usize = 0,
    escalations: usize = 0,
    /// Reflection quality-gate re-runs.
    reviews: usize = 0,

    pub fn toPrometheusFormat(self: WorkflowMetrics, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.print(allocator, "# HELP zigmodu_ai_workflow_runs_total Workflow runs started.\n", .{});
        try buf.print(allocator, "# TYPE zigmodu_ai_workflow_runs_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_workflow_runs_total{{workflow=\"{s}\"}} {d}\n", .{ name, self.runs });
        try buf.print(allocator, "# TYPE zigmodu_ai_workflow_steps_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_workflow_steps_total{{workflow=\"{s}\",status=\"completed\"}} {d}\n", .{ name, self.completed_steps });
        try buf.print(allocator, "zigmodu_ai_workflow_steps_total{{workflow=\"{s}\",status=\"failed\"}} {d}\n", .{ name, self.failed_steps });
        try buf.print(allocator, "# TYPE zigmodu_ai_workflow_escalations_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_workflow_escalations_total{{workflow=\"{s}\"}} {d}\n", .{ name, self.escalations });
        try buf.print(allocator, "# TYPE zigmodu_ai_workflow_reviews_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_workflow_reviews_total{{workflow=\"{s}\"}} {d}\n", .{ name, self.reviews });
        return try buf.toOwnedSlice(allocator);
    }
};

const StepOutcome = struct {
    output: []const u8,
    budget_exhausted: bool = false,
    pending_human: bool = false,
};

pub const Workflow = struct {
    /// Only required when a step uses `.llm` or `.agent`.
    provider: ?*AiProvider = null,
    registry: *SkillRegistry,
    /// Required for DAG (parallel wave) execution.
    io: std.Io = undefined,
    /// Max steps run concurrently in a DAG wave.
    max_parallel: usize = 4,
    budget: ?*Budget = null,
    steps: []const Step,
    /// Reflection quality gate on the final step's output.
    reflection: ?VerifyFn = null,
    max_reviews: usize = 1,
    /// Human-escalation hook for unrecoverable outcomes.
    on_escalate: ?EscalateFn = null,
    /// Goal/context passed to the verifier.
    goal: []const u8 = "",
    /// Optional WAL for per-step persistence (crash recovery / resume).
    wal: ?*WAL = null,
    /// Identifier used to namespace persisted step records.
    run_id: []const u8 = "",
    /// Optional metrics sink; updated on every run / resume when set.
    metrics: ?*WorkflowMetrics = null,
    /// Approval flow used by `.approval` steps (required when such a step
    /// exists).
    approval_flow: ?*@import("approval.zig").ApprovalFlow = null,
    /// Optional durable run-audit store; every run / resume writes one row.
    audit: ?*@import("run_audit.zig").RunAuditStore = null,

    pub fn init(registry: *SkillRegistry, steps: []const Step) Workflow {
        return .{ .registry = registry, .steps = steps };
    }

    /// Render the workflow as a Mermaid `flowchart TD` graph (nodes annotated
    /// with their step kind; dependency edges for DAG steps, implicit order
    /// edges for linear steps). Caller owns the string.
    pub fn toMermaid(self: Workflow, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "flowchart TD\n");
        for (self.steps) |step| {
            const kind = switch (step.kind) {
                .llm => "llm",
                .skill => "skill",
                .agent => "agent",
                .approval => "approval",
            };
            try buf.print(allocator, "  {s}[\"{s} ({s})\"]\n", .{ step.name, step.name, kind });
        }
        if (self.hasDeps()) {
            for (self.steps) |step| {
                for (step.depends_on) |dep| {
                    try buf.print(allocator, "  {s} --> {s}\n", .{ dep, step.name });
                }
            }
        } else {
            var prev: ?[]const u8 = null;
            for (self.steps) |step| {
                if (prev) |p| try buf.print(allocator, "  {s} --> {s}\n", .{ p, step.name });
                prev = step.name;
            }
        }
        return buf.toOwnedSlice(allocator);
    }

    /// Execute all steps sequentially. Returns a partial result on step
    /// failure (status `.failed`) instead of erroring, so callers can inspect
    /// which steps completed.
    pub fn run(self: Workflow, allocator: std.mem.Allocator, ctx: *SkillContext) !WorkflowResult {
        const started_ms = Time.monotonicNowMilliseconds();
        var result = WorkflowResult{
            .status = .completed,
            .steps = std.ArrayList(StepRecord).empty,
            .allocator = allocator,
        };
        errdefer result.deinit();
        var completed = std.StringHashMap(void).init(allocator);
        defer completed.deinit();
        if (self.metrics) |m| m.runs += 1;
        try self.runSteps(allocator, ctx, 0, &completed, &result);
        if (self.audit) |a| {
            try @import("run_audit.zig").recordRun(a, allocator, ctx, self.run_id, .workflow, @tagName(result.status), result.steps.items.len, Time.monotonicNowMilliseconds() - started_ms);
        }
        return result;
    }

    /// Resume a run from its persisted step records: replays completed steps,
    /// then continues from the first unpersisted one. Requires `wal` and
    /// `run_id`.
    pub fn resumeRun(self: Workflow, allocator: std.mem.Allocator, ctx: *SkillContext, run_id: []const u8) !WorkflowResult {
        const started_ms = Time.monotonicNowMilliseconds();
        const w = self.wal orelse return error.WalRequired;
        var result = WorkflowResult{
            .status = .completed,
            .steps = std.ArrayList(StepRecord).empty,
            .allocator = allocator,
        };
        errdefer result.deinit();

        const entries = try w.readFrom(0);
        defer {
            for (entries) |e| {
                allocator.free(e.topic);
                allocator.free(e.payload);
                allocator.free(e.source_node);
            }
            allocator.free(entries);
        }

        var next_index: usize = 0;
        var completed = std.StringHashMap(void).init(allocator);
        defer completed.deinit();
        var replayed_failed = false;
        for (entries) |e| {
            if (!std.mem.eql(u8, e.source_node, run_id)) continue;
            const parsed = std.json.parseFromSlice(StepRecordJson, allocator, e.payload, .{}) catch continue;
            defer parsed.deinit();
            const rec = parsed.value;
            if (rec.index >= next_index) next_index = rec.index + 1;
            try result.steps.append(allocator, .{
                .name = try allocator.dupe(u8, rec.name),
                .status = if (std.mem.eql(u8, rec.status, "failed")) .failed else .completed,
                .error_message = if (rec.err_msg) |em| try allocator.dupe(u8, em) else null,
                .output = if (rec.output) |o| try allocator.dupe(u8, o) else "",
            });
            if (std.mem.eql(u8, rec.status, "failed")) replayed_failed = true;
            if (std.mem.eql(u8, rec.status, "completed")) try completed.put(rec.name, {});
        }
        if (replayed_failed) {
            result.status = .failed;
            if (self.audit) |a| {
                try @import("run_audit.zig").recordRun(a, allocator, ctx, run_id, .workflow, @tagName(result.status), result.steps.items.len, Time.monotonicNowMilliseconds() - started_ms);
            }
            return result;
        }
        if (next_index >= self.steps.len) {
            if (self.audit) |a| {
                try @import("run_audit.zig").recordRun(a, allocator, ctx, run_id, .workflow, @tagName(result.status), result.steps.items.len, Time.monotonicNowMilliseconds() - started_ms);
            }
            return result;
        }
        if (self.metrics) |m| m.runs += 1;
        try self.runSteps(allocator, ctx, next_index, &completed, &result);
        if (self.audit) |a| {
            try @import("run_audit.zig").recordRun(a, allocator, ctx, run_id, .workflow, @tagName(result.status), result.steps.items.len, Time.monotonicNowMilliseconds() - started_ms);
        }
        return result;
    }

    fn hasDeps(self: Workflow) bool {
        for (self.steps) |s| {
            if (s.depends_on.len > 0) return true;
        }
        return false;
    }

    /// Linear when no step declares dependencies; DAG (dependency-aware,
    /// parallel waves) otherwise.
    fn runSteps(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        start: usize,
        completed: *std.StringHashMap(void),
        result: *WorkflowResult,
    ) !void {
        if (self.hasDeps()) {
            return self.runDag(allocator, ctx, completed, result);
        }
        return self.runLinear(allocator, ctx, start, completed, result);
    }

    fn runLinear(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        start: usize,
        completed: *std.StringHashMap(void),
        result: *WorkflowResult,
    ) !void {
        var step_index: usize = 0;
        step_index = start;
        while (step_index < self.steps.len) : (step_index += 1) {
            const step = self.steps[step_index];
            if (completed.contains(step.name)) continue;
            var outcome = try self.executeStep(allocator, ctx, step, step_index, result);
            if (outcome == null) {
                try self.maybeEscalate(ctx, .step_failed, step.name, allocator);
                result.status = .failed;
                break;
            }
            try completed.put(step.name, {});
            if (outcome.?.budget_exhausted) {
                try self.maybeEscalate(ctx, .budget_exhausted, step.name, allocator);
                result.status = .budget_exhausted;
                break;
            }
            if (outcome.?.pending_human) {
                result.status = .pending_human;
                break;
            }

            // Reflection quality gate on the final step.
            if (step_index == self.steps.len - 1) {
                if (self.reflection) |vf| {
                    var reviews: usize = 0;
                    var verified = try vf(ctx, self.goal, outcome.?.output, allocator);
                    while (!verified) : (reviews += 1) {
                        if (self.metrics) |m| m.reviews += 1;
                        if (reviews >= self.max_reviews) {
                            try self.maybeEscalate(ctx, .verification_failed, step.name, allocator);
                            result.status = .failed;
                            break;
                        }
                        outcome = try self.executeStep(allocator, ctx, step, step_index, result);
                        if (outcome == null) {
                            try self.maybeEscalate(ctx, .step_failed, step.name, allocator);
                            result.status = .failed;
                            break;
                        }
                        verified = try vf(ctx, self.goal, outcome.?.output, allocator);
                    }
                    if (result.status == .failed) break;
                }
            }
        }
    }

    const DagState = struct {
        wf: Workflow,
        allocator: std.mem.Allocator,
        ctx: SkillContext,
        step: Step,
        index: usize,
        outcome: ?StepOutcome = null,
        last_err: anyerror = error.Unknown,
    };

    fn dagTask(st: *DagState) void {
        st.outcome = st.wf.attemptStep(st.allocator, &st.ctx, st.step) catch |err| blk: {
            st.last_err = err;
            break :blk null;
        };
    }

    /// Dependency-aware execution: ready steps (all deps completed) run in
    /// parallel waves of `max_parallel`; records/persistence are appended on
    /// the calling thread after each wave. Cycles return error.CyclicDependency.
    fn runDag(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        completed: *std.StringHashMap(void),
        result: *WorkflowResult,
    ) !void {
        var remaining: usize = self.steps.len;
        for (self.steps) |s| {
            if (completed.contains(s.name)) remaining -= 1;
        }

        while (remaining > 0) {
            var ready = std.ArrayList(usize).empty;
            defer ready.deinit(allocator);
            for (self.steps, 0..) |s, i| {
                if (completed.contains(s.name)) continue;
                var deps_ok = true;
                for (s.depends_on) |d| {
                    if (!completed.contains(d)) {
                        deps_ok = false;
                        break;
                    }
                }
                if (deps_ok) try ready.append(allocator, i);
            }
            if (ready.items.len == 0) return error.CyclicDependency;

            var wave: usize = 0;
            while (wave < ready.items.len) : (wave += self.max_parallel) {
                const end = @min(ready.items.len, wave + self.max_parallel);
                const count = end - wave;
                const states = try allocator.alloc(*DagState, count);
                defer allocator.free(states);
                var group = std.Io.Group.init;
                for (ready.items[wave..end], 0..) |idx, k| {
                    const st = try allocator.create(DagState);
                    st.* = .{
                        .wf = self,
                        .allocator = allocator,
                        .ctx = ctx.*,
                        .step = self.steps[idx],
                        .index = idx,
                    };
                    states[k] = st;
                    group.async(self.io, dagTask, .{st});
                }
                try group.await(self.io);

                for (states) |st| {
                    if (st.outcome) |o| {
                        try self.appendCompleted(result, allocator, st.step, st.index, o);
                        try completed.put(st.step.name, {});
                        if (o.budget_exhausted) {
                            try self.maybeEscalate(ctx, .budget_exhausted, st.step.name, allocator);
                            result.status = .budget_exhausted;
                        }
                    } else {
                        try self.appendFailed(result, allocator, st.step, st.index, st.last_err);
                        try self.maybeEscalate(ctx, .step_failed, st.step.name, allocator);
                        result.status = .failed;
                    }
                    if (st.outcome) |o| {
                        if (o.pending_human) result.status = .pending_human;
                    }
                }
                for (states) |st| allocator.destroy(st);
                if (result.status != .completed) return;
            }
            remaining -= ready.items.len;
        }
    }

    /// Run a step with its retry budget; appends the record to `result`.
    /// Returns null when all attempts failed (record is marked failed).
    fn executeStep(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        step: Step,
        step_index: usize,
        result: *WorkflowResult,
    ) !?StepOutcome {
        const outcome = self.attemptStep(allocator, ctx, step) catch |err| {
            try self.appendFailed(result, allocator, step, step_index, err);
            return null;
        };
        try self.appendCompleted(result, allocator, step, step_index, outcome);
        return outcome;
    }

    /// Run a step with its retry budget; does not record anything (records are
    /// appended by the caller — needed for parallel DAG waves).
    fn attemptStep(
        self: Workflow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        step: Step,
    ) !StepOutcome {
        var attempts: usize = 0;
        var last_err: anyerror = error.Unknown;
        while (attempts <= step.retry) : (attempts += 1) {
            const outcome = self.runStep(allocator, ctx, step) catch |err| {
                last_err = err;
                continue;
            };
            return outcome;
        }
        return last_err;
    }

    fn appendCompleted(
        self: Workflow,
        result: *WorkflowResult,
        allocator: std.mem.Allocator,
        step: Step,
        step_index: usize,
        outcome: StepOutcome,
    ) !void {
        if (self.metrics) |m| m.completed_steps += 1;
        try result.steps.append(allocator, .{
            .name = try allocator.dupe(u8, step.name),
            .status = .completed,
            .output = outcome.output,
        });
        try self.persistStep(allocator, step_index, step.name, "completed", null, outcome.output);
    }

    fn appendFailed(
        self: Workflow,
        result: *WorkflowResult,
        allocator: std.mem.Allocator,
        step: Step,
        step_index: usize,
        last_err: anyerror,
    ) !void {
        if (self.metrics) |m| m.failed_steps += 1;
        try result.steps.append(allocator, .{
            .name = try allocator.dupe(u8, step.name),
            .status = .failed,
            .error_message = if (last_err != error.Unknown)
                try allocator.dupe(u8, @errorName(last_err))
            else
                null,
        });
        try self.persistStep(
            allocator,
            step_index,
            step.name,
            "failed",
            if (last_err != error.Unknown) @errorName(last_err) else null,
            "",
        );
    }

    const StepRecordJson = struct {
        run_id: []const u8,
        index: usize,
        name: []const u8,
        status: []const u8,
        err_msg: ?[]const u8 = null,
        output: ?[]const u8 = null,
    };

    fn persistStep(
        self: Workflow,
        allocator: std.mem.Allocator,
        step_index: usize,
        name: []const u8,
        status: []const u8,
        err_msg: ?[]const u8,
        output: []const u8,
    ) !void {
        if (self.wal == null or self.run_id.len == 0) return;
        const json = try std.json.Stringify.valueAlloc(allocator, StepRecordJson{
            .run_id = self.run_id,
            .index = step_index,
            .name = name,
            .status = status,
            .err_msg = err_msg,
            .output = if (output.len > 0) output else null,
        }, .{});
        defer allocator.free(json);
        _ = try self.wal.?.append(.{ .topic = "ai.workflow", .payload = json, .source_node = self.run_id });
    }

    fn maybeEscalate(
        self: Workflow,
        ctx: *SkillContext,
        reason: EscalateReason,
        step: ?[]const u8,
        allocator: std.mem.Allocator,
    ) !void {
        if (self.metrics) |m| m.escalations += 1;
        if (self.on_escalate) |cb| try cb(ctx, reason, step, allocator);
    }

    fn runStep(self: Workflow, allocator: std.mem.Allocator, ctx: *SkillContext, step: Step) !StepOutcome {
        return switch (step.kind) {
            .llm => |s| blk: {
                const provider = self.provider orelse return error.ProviderRequired;
                var msgs = [_]AiProvider.ChatMsg{.{ .role = "user", .content = s.prompt }};
                if (self.budget) |b| {
                    if (!b.tryConsume(tokenizer.estimateMessages(&msgs))) return error.BudgetExhausted;
                }
                var resp = try provider.chat(msgs[0..]);
                defer provider.freeResponse(&resp);
                break :blk .{ .output = try allocator.dupe(u8, resp.content) };
            },
            .skill => |s| blk: {
                const value = try self.registry.dispatch(s.name, ctx, s.args);
                // Handlers allocate result strings with ctx.allocator — free
                // with the same allocator before owning the stringified copy.
                defer skill_mod.freeValue(ctx.allocator, value);
                break :blk .{ .output = try std.json.Stringify.valueAlloc(allocator, value, .{}) };
            },
            .agent => |s| blk: {
                const provider = self.provider orelse return error.ProviderRequired;
                var agent = Agent{
                    .provider = provider,
                    .registry = self.registry,
                    .budget = self.budget,
                };
                var ar = try agent.run(allocator, s.goal, ctx, s.max_steps);
                defer ar.deinit(allocator);
                break :blk .{
                    .output = try allocator.dupe(u8, ar.answer),
                    .budget_exhausted = ar.budget_exhausted,
                };
            },
            .approval => |s| blk: {
                const flow = self.approval_flow orelse return error.ApprovalFlowRequired;
                const steps = [_]@import("approval.zig").ApprovalStep{.{ .name = step.name }};
                var result = try flow.submit(allocator, ctx, s.subject, s.amount, &steps);
                defer result.deinit(allocator);
                switch (result.status) {
                    .approved => break :blk .{ .output = try allocator.dupe(u8, "approved") },
                    .rejected => return error.ApprovalRejected,
                    .pending_human => break :blk .{ .output = try allocator.dupe(u8, "pending_human"), .pending_human = true },
                }
            },
        };
    }
};

test "workflow runs skill steps and records results" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var count: usize = 0;
    const T = struct {
        fn incr(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
            _ = args;
            const c: *usize = @ptrCast(@alignCast(ctx.userdata.?));
            c.* += 1;
            var out = std.json.ObjectMap{};
            try out.put(ctx.allocator, try ctx.allocator.dupe(u8, "count"), .{ .integer = @intCast(c.*) });
            return .{ .object = out };
        }
    };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "incr",
        .description = "increment",
        .parameters = &.{},
        .handler = T.incr,
    });

    var ctx = SkillContext{ .allocator = a, .userdata = @ptrCast(&count) };
    const steps = [_]Step{
        .{ .name = "step-a", .kind = .{ .skill = .{ .name = "incr", .args = .{ .object = .{} } } } },
        .{ .name = "step-b", .kind = .{ .skill = .{ .name = "incr", .args = .{ .object = .{} } } } },
    };
    var wf = Workflow.init(&registry, &steps);
    var result = try wf.run(allocator, &ctx);
    defer result.deinit();

    try std.testing.expectEqual(RunStatus.completed, result.status);
    try std.testing.expectEqual(@as(usize, 2), result.steps.items.len);
    try std.testing.expectEqual(StepStatus.completed, result.steps.items[1].status);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(std.mem.indexOf(u8, result.steps.items[1].output, "\"count\":2") != null);
}

test "workflow metrics track runs, steps and escalations" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    const Ok = struct {
        fn h(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            return .{ .string = try ctx.allocator.dupe(u8, "ok") };
        }
    };
    try registry.register(.{ .name = "ok", .description = "", .parameters = &.{}, .handler = Ok.h });
    const Fail = struct {
        fn h(_: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            return error.Boom;
        }
    };
    try registry.register(.{ .name = "boom", .description = "", .parameters = &.{}, .handler = Fail.h });

    var metrics = WorkflowMetrics{};
    var ctx = SkillContext{ .allocator = allocator };

    const good_steps = [_]Step{
        .{ .name = "a", .kind = .{ .skill = .{ .name = "ok", .args = .{ .object = .{} } } } },
        .{ .name = "b", .kind = .{ .skill = .{ .name = "ok", .args = .{ .object = .{} } } } },
    };
    var good = Workflow.init(&registry, &good_steps);
    good.metrics = &metrics;
    var good_result = try good.run(allocator, &ctx);
    defer good_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), metrics.runs);
    try std.testing.expectEqual(@as(usize, 2), metrics.completed_steps);

    const bad_steps = [_]Step{
        .{ .name = "a", .kind = .{ .skill = .{ .name = "ok", .args = .{ .object = .{} } } } },
        .{ .name = "bad", .kind = .{ .skill = .{ .name = "boom", .args = .{ .object = .{} } } }, .retry = 1 },
    };
    var bad = Workflow.init(&registry, &bad_steps);
    bad.metrics = &metrics;
    var bad_result = try bad.run(allocator, &ctx);
    defer bad_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), metrics.runs);
    try std.testing.expectEqual(@as(usize, 1), metrics.failed_steps);
    try std.testing.expectEqual(@as(usize, 1), metrics.escalations);

    const prom = try metrics.toPrometheusFormat(allocator, "wf");
    defer allocator.free(prom);
    try std.testing.expect(std.mem.indexOf(u8, prom, "zigmodu_ai_workflow_runs_total{workflow=\"wf\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "status=\"failed\"} 1") != null);
}

test "workflow toMermaid renders linear and DAG graphs" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();

    const linear = [_]Step{
        .{ .name = "a", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
        .{ .name = "b", .kind = .{ .approval = .{ .subject = "x", .amount = 1 } } },
        .{ .name = "c", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
    };
    var lwf = Workflow.init(&registry, &linear);
    const l = try lwf.toMermaid(allocator);
    defer allocator.free(l);
    try std.testing.expect(std.mem.indexOf(u8, l, "flowchart TD") != null);
    try std.testing.expect(std.mem.indexOf(u8, l, "b[\"b (approval)\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, l, "a --> b") != null);
    try std.testing.expect(std.mem.indexOf(u8, l, "b --> c") != null);

    const dag = [_]Step{
        .{ .name = "start", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
        .{ .name = "left", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } }, .depends_on = &.{"start"} },
        .{ .name = "right", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } }, .depends_on = &.{"start"} },
        .{ .name = "join", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } }, .depends_on = &.{ "left", "right" } },
    };
    var dwf = Workflow.init(&registry, &dag);
    const d = try dwf.toMermaid(allocator);
    defer allocator.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "start --> left") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "left --> join") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "right --> join") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "start --> left") != null);
}

test "workflow approval step gates on human decision" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend{ .allocator = allocator, .client = &client };
    const Policy = struct {
        fn decide(_: std.mem.Allocator, _: *SkillContext, _: []const u8, amount: i64, _: usize, _: []const u8, _: []const u8, _: *[]const u8) anyerror!@import("approval.zig").ApprovalDecision {
            return if (amount <= 1000) .approved else .escalated;
        }
    };
    var flow = @import("approval.zig").ApprovalFlow.init(allocator, &backend, Policy.decide);
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = allocator };

    // Approved gate → completed.
    const ok_steps = [_]Step{
        .{ .name = "review", .kind = .{ .approval = .{ .subject = "order-1", .amount = 100 } } },
    };
    var ok_wf = Workflow.init(&registry, &ok_steps);
    ok_wf.approval_flow = &flow;
    var ok_result = try ok_wf.run(allocator, &ctx);
    defer ok_result.deinit();
    try std.testing.expectEqual(RunStatus.completed, ok_result.status);

    // Escalated gate → pending_human, run stops.
    const gate_steps = [_]Step{
        .{ .name = "review", .kind = .{ .approval = .{ .subject = "order-2", .amount = 99999 } } },
    };
    var gate_wf = Workflow.init(&registry, &gate_steps);
    gate_wf.approval_flow = &flow;
    var gate_result = try gate_wf.run(allocator, &ctx);
    defer gate_result.deinit();
    try std.testing.expectEqual(RunStatus.pending_human, gate_result.status);
    try std.testing.expectEqual(@as(usize, 1), gate_result.steps.items.len);
}

test "workflow approval gate resumes after the human approves" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend{ .allocator = allocator, .client = &client };

    const EscalateAlways = struct {
        fn decide(_: std.mem.Allocator, _: *SkillContext, _: []const u8, _: i64, _: usize, _: []const u8, _: []const u8, _: *[]const u8) anyerror!@import("approval.zig").ApprovalDecision {
            return .escalated;
        }
    };
    var flow = @import("approval.zig").ApprovalFlow.init(allocator, &backend, EscalateAlways.decide);

    const wal_dir = "ai_wf_wal_approval";
    std.Io.Dir.cwd().deleteTree(std.testing.io, wal_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, wal_dir) catch {};
    var wal = try WAL.init(allocator, std.testing.io, .{ .dir_path = wal_dir, .max_segment_size = 1024 * 1024 });
    defer wal.deinit();

    var registry = try setupPingRegistry(allocator);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = a };
    const steps = [_]Step{
        .{ .name = "review", .kind = .{ .approval = .{ .subject = "order-9", .amount = 50000 } } },
        .{ .name = "publish", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.approval_flow = &flow;
    wf.wal = &wal;
    wf.run_id = "run-approval";

    // Run 1: the gate escalates → pending_human; the review step is persisted.
    var first = try wf.run(allocator, &ctx);
    defer first.deinit();
    try std.testing.expectEqual(RunStatus.pending_human, first.status);
    try std.testing.expectEqual(@as(usize, 1), first.steps.items.len);

    // Human approves; resume continues from the persisted gate (skips review).
    var resumed = try wf.resumeRun(allocator, &ctx, "run-approval");
    defer resumed.deinit();
    try std.testing.expectEqual(RunStatus.completed, resumed.status);
    try std.testing.expectEqual(@as(usize, 2), resumed.steps.items.len);
    try std.testing.expectEqualStrings("review", resumed.steps.items[0].name);
    try std.testing.expectEqualStrings("publish", resumed.steps.items[1].name);
}

test "workflow approval gate stops a DAG run at pending_human" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend{ .allocator = allocator, .client = &client };
    const Escalate = struct {
        fn decide(_: std.mem.Allocator, _: *SkillContext, _: []const u8, _: i64, _: usize, _: []const u8, _: []const u8, _: *[]const u8) anyerror!@import("approval.zig").ApprovalDecision {
            return .escalated;
        }
    };
    var flow = @import("approval.zig").ApprovalFlow.init(allocator, &backend, Escalate.decide);
    var registry = try setupPingRegistry(allocator);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = allocator };

    const steps = [_]Step{
        .{ .name = "prepare", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
        .{ .name = "left", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } }, .depends_on = &.{"prepare"} },
        .{ .name = "right", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } }, .depends_on = &.{"prepare"} },
        .{ .name = "gate", .kind = .{ .approval = .{ .subject = "order-9", .amount = 90000 } }, .depends_on = &.{ "left", "right" } },
        .{ .name = "publish", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } }, .depends_on = &.{"gate"} },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.approval_flow = &flow;
    wf.io = std.testing.io;
    var result = try wf.run(allocator, &ctx);
    defer result.deinit();

    try std.testing.expectEqual(RunStatus.pending_human, result.status);
    // prepare/left/right completed; gate reached but pending; publish never ran.
    try std.testing.expectEqual(@as(usize, 4), result.steps.items.len);
    try std.testing.expectEqualStrings("gate", result.steps.items[3].name);
    try std.testing.expectEqual(StepStatus.completed, result.steps.items[3].status);
}

test "workflow records run audit automatically" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend{ .allocator = allocator, .client = &client };
    var store = @import("run_audit.zig").RunAuditStore.init(allocator, &backend);
    try store.migrate();

    var registry = try setupPingRegistry(allocator);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = allocator, .tenant_id = 7 };
    const steps = [_]Step{
        .{ .name = "a", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
        .{ .name = "b", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.audit = &store;
    wf.run_id = "run-audit-1";
    var result = try wf.run(allocator, &ctx);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), try store.count());
    var entries = std.ArrayList(@import("run_audit.zig").RunAuditEntry).empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.run_id);
            allocator.free(e.status);
        }
        entries.deinit(allocator);
    }
    try store.list(allocator, &entries, null, 7, 10);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("run-audit-1", entries.items[0].run_id);
    try std.testing.expectEqualStrings("completed", entries.items[0].status);
    try std.testing.expectEqual(@as(usize, 2), entries.items[0].steps);
}

test "workflow marks a failing step and stops" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const T = struct {
        fn boom(_: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            return error.Boom;
        }
    };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "boom",
        .description = "always fails",
        .parameters = &.{},
        .handler = T.boom,
    });

    var ctx = SkillContext{ .allocator = a };
    const steps = [_]Step{
        .{ .name = "bad", .kind = .{ .skill = .{ .name = "boom", .args = .{ .object = .{} } } }, .retry = 1 },
        .{ .name = "never", .kind = .{ .skill = .{ .name = "boom", .args = .{ .object = .{} } } } },
    };
    var wf = Workflow.init(&registry, &steps);
    var result = try wf.run(allocator, &ctx);
    defer result.deinit();

    try std.testing.expectEqual(RunStatus.failed, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.steps.items.len);
    try std.testing.expectEqual(StepStatus.failed, result.steps.items[0].status);
    try std.testing.expectEqualStrings("Boom", result.steps.items[0].error_message.?);
}

const RefState = struct {
    verify_calls: usize = 0,
    escalated: ?EscalateReason = null,
};
const RefHooks = struct {
    fn verify(ctx: *SkillContext, goal: []const u8, output: []const u8, allocator: std.mem.Allocator) anyerror!bool {
        _ = goal;
        _ = output;
        _ = allocator;
        const st: *RefState = @ptrCast(@alignCast(ctx.userdata.?));
        st.verify_calls += 1;
        return st.verify_calls >= 2;
    }
    fn escalate(ctx: *SkillContext, reason: EscalateReason, step: ?[]const u8, allocator: std.mem.Allocator) anyerror!void {
        _ = step;
        _ = allocator;
        const st: *RefState = @ptrCast(@alignCast(ctx.userdata.?));
        st.escalated = reason;
    }
    fn verifyAlwaysFail(_: *SkillContext, _: []const u8, _: []const u8, _: std.mem.Allocator) anyerror!bool {
        return false;
    }
};

test "workflow reflection re-runs the final step until verified" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var state = RefState{};
    const T = struct {
        fn ping(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            var out = std.json.ObjectMap{};
            try out.put(ctx.allocator, try ctx.allocator.dupe(u8, "ok"), .{ .bool = true });
            return .{ .object = out };
        }
    };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "ping",
        .description = "pong",
        .parameters = &.{},
        .handler = T.ping,
    });

    var ctx = SkillContext{ .allocator = a, .userdata = @ptrCast(&state) };
    const steps = [_]Step{
        .{ .name = "plan", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
        .{ .name = "final", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.reflection = RefHooks.verify;
    wf.max_reviews = 2;
    wf.goal = "produce a report";

    var result = try wf.run(allocator, &ctx);
    defer result.deinit();

    try std.testing.expectEqual(RunStatus.completed, result.status);
    try std.testing.expectEqual(@as(usize, 3), result.steps.items.len); // plan + final + final(review)
    try std.testing.expectEqual(@as(usize, 2), state.verify_calls);
    try std.testing.expect(state.escalated == null);
}

test "workflow escalates on persistent verification failure" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var state = RefState{};
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "ok",
        .description = "succeeds",
        .parameters = &.{},
        .handler = struct {
            fn ok(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                var out = std.json.ObjectMap{};
                try out.put(ctx.allocator, try ctx.allocator.dupe(u8, "ok"), .{ .bool = true });
                return .{ .object = out };
            }
        }.ok,
    });

    var ctx = SkillContext{ .allocator = a, .userdata = @ptrCast(&state) };
    const steps = [_]Step{.{ .name = "final", .kind = .{ .skill = .{ .name = "ok", .args = .{ .object = .{} } } } }};
    var wf = Workflow.init(&registry, &steps);
    wf.reflection = RefHooks.verifyAlwaysFail;
    wf.max_reviews = 0;
    wf.on_escalate = RefHooks.escalate;

    var result = try wf.run(allocator, &ctx);
    defer result.deinit();

    try std.testing.expectEqual(RunStatus.failed, result.status);
    try std.testing.expectEqual(EscalateReason.verification_failed, state.escalated.?);
}

test "workflow escalates when a step fails after retries" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var state = RefState{};
    const T = struct {
        fn boom(_: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
            return error.Boom;
        }
    };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "boom",
        .description = "fails",
        .parameters = &.{},
        .handler = T.boom,
    });

    var ctx = SkillContext{ .allocator = a, .userdata = @ptrCast(&state) };
    const steps = [_]Step{.{ .name = "step", .kind = .{ .skill = .{ .name = "boom", .args = .{ .object = .{} } } } }};
    var wf = Workflow.init(&registry, &steps);
    wf.on_escalate = RefHooks.escalate;

    var result = try wf.run(allocator, &ctx);
    defer result.deinit();

    try std.testing.expectEqual(RunStatus.failed, result.status);
    try std.testing.expectEqual(EscalateReason.step_failed, state.escalated.?);
}

const PingSkill = struct {
    fn ping(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
        var out = std.json.ObjectMap{};
        try out.put(ctx.allocator, try ctx.allocator.dupe(u8, "ok"), .{ .bool = true });
        return .{ .object = out };
    }
};

fn setupPingRegistry(allocator: std.mem.Allocator) !SkillRegistry {
    var registry = SkillRegistry.init(allocator, std.testing.io);
    try registry.register(.{
        .name = "ping",
        .description = "pong",
        .parameters = &.{},
        .handler = PingSkill.ping,
    });
    return registry;
}

test "workflow persists steps to WAL and resume replays them" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const wal_dir = "ai_wf_wal_test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, wal_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, wal_dir) catch {};
    var wal = try WAL.init(allocator, std.testing.io, .{ .dir_path = wal_dir, .max_segment_size = 1024 * 1024 });
    defer wal.deinit();

    var registry = try setupPingRegistry(allocator);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = a };

    const steps = [_]Step{
        .{ .name = "step-a", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
        .{ .name = "step-b", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.wal = &wal;
    wf.run_id = "run-1";

    var result = try wf.run(allocator, &ctx);
    defer result.deinit();
    try std.testing.expectEqual(RunStatus.completed, result.status);
    try std.testing.expectEqual(@as(usize, 2), result.steps.items.len);

    var resumed = try wf.resumeRun(allocator, &ctx, "run-1");
    defer resumed.deinit();
    try std.testing.expectEqual(RunStatus.completed, resumed.status);
    try std.testing.expectEqual(@as(usize, 2), resumed.steps.items.len);
    try std.testing.expectEqualStrings("step-a", resumed.steps.items[0].name);
    try std.testing.expect(std.mem.indexOf(u8, resumed.steps.items[1].output, "\"ok\":true") != null);
}

test "workflow resume continues from the last persisted step" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const wal_dir = "ai_wf_wal_test2";
    std.Io.Dir.cwd().deleteTree(std.testing.io, wal_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, wal_dir) catch {};
    var wal = try WAL.init(allocator, std.testing.io, .{ .dir_path = wal_dir, .max_segment_size = 1024 * 1024 });
    defer wal.deinit();

    // Simulate a crash after step 0: only one completed record persisted.
    const Rec = struct {
        run_id: []const u8,
        index: usize,
        name: []const u8,
        status: []const u8,
        err_msg: ?[]const u8,
        output: ?[]const u8,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, Rec{
        .run_id = "run-2",
        .index = 0,
        .name = "step-a",
        .status = "completed",
        .err_msg = null,
        .output = "partial",
    }, .{});
    defer allocator.free(json);
    _ = try wal.append(.{ .topic = "ai.workflow", .payload = json, .source_node = "run-2" });

    var registry = try setupPingRegistry(allocator);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = a };
    const steps = [_]Step{
        .{ .name = "step-a", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
        .{ .name = "step-b", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.wal = &wal;

    var resumed = try wf.resumeRun(allocator, &ctx, "run-2");
    defer resumed.deinit();
    try std.testing.expectEqual(RunStatus.completed, resumed.status);
    try std.testing.expectEqual(@as(usize, 2), resumed.steps.items.len);
    try std.testing.expectEqualStrings("partial", resumed.steps.items[0].output);
    try std.testing.expectEqualStrings("step-b", resumed.steps.items[1].name);
    try std.testing.expectEqual(StepStatus.completed, resumed.steps.items[1].status);
}

test "workflow runs a DAG respecting dependencies" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try setupPingRegistry(allocator);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = a };

    const steps = [_]Step{
        .{ .name = "a", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } } },
        .{ .name = "b", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } }, .depends_on = &.{"a"} },
        .{ .name = "c", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } }, .depends_on = &.{"a"} },
        .{ .name = "d", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } }, .depends_on = &.{ "b", "c" } },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.io = std.testing.io;
    wf.max_parallel = 2;

    var result = try wf.run(allocator, &ctx);
    defer result.deinit();

    try std.testing.expectEqual(RunStatus.completed, result.status);
    try std.testing.expectEqual(@as(usize, 4), result.steps.items.len);
    for (result.steps.items) |rec| {
        try std.testing.expectEqual(StepStatus.completed, rec.status);
    }
    // Dependency order: b/c appear after a, d appears after b and c.
    var a_idx: ?usize = null;
    var b_idx: ?usize = null;
    var c_idx: ?usize = null;
    var d_idx: ?usize = null;
    for (result.steps.items, 0..) |rec, i| {
        if (std.mem.eql(u8, rec.name, "a")) a_idx = i;
        if (std.mem.eql(u8, rec.name, "b")) b_idx = i;
        if (std.mem.eql(u8, rec.name, "c")) c_idx = i;
        if (std.mem.eql(u8, rec.name, "d")) d_idx = i;
    }
    try std.testing.expect(a_idx.? < b_idx.? and a_idx.? < c_idx.?);
    try std.testing.expect(b_idx.? < d_idx.? and c_idx.? < d_idx.?);
}

test "workflow detects cyclic dependencies" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try setupPingRegistry(allocator);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = a };

    const steps = [_]Step{
        .{ .name = "x", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } }, .depends_on = &.{"y"} },
        .{ .name = "y", .kind = .{ .skill = .{ .name = "ping", .args = .{ .object = .{} } } }, .depends_on = &.{"x"} },
    };
    var wf = Workflow.init(&registry, &steps);
    wf.io = std.testing.io;

    const err = wf.run(allocator, &ctx) catch |e| e;
    try std.testing.expectEqual(error.CyclicDependency, err);
}
