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
};

pub const Step = struct {
    name: []const u8,
    kind: StepKind,
    retry: usize = 0,
};

pub const StepStatus = enum { pending, running, completed, failed };
pub const RunStatus = enum { completed, failed, budget_exhausted };

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

const StepOutcome = struct {
    output: []const u8,
    budget_exhausted: bool = false,
};

pub const Workflow = struct {
    /// Only required when a step uses `.llm` or `.agent`.
    provider: ?*AiProvider = null,
    registry: *SkillRegistry,
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

    pub fn init(registry: *SkillRegistry, steps: []const Step) Workflow {
        return .{ .registry = registry, .steps = steps };
    }

    /// Execute all steps sequentially. Returns a partial result on step
    /// failure (status `.failed`) instead of erroring, so callers can inspect
    /// which steps completed.
    pub fn run(self: Workflow, allocator: std.mem.Allocator, ctx: *SkillContext) !WorkflowResult {
        var result = WorkflowResult{
            .status = .completed,
            .steps = std.ArrayList(StepRecord).empty,
            .allocator = allocator,
        };
        errdefer result.deinit();
        try self.runSteps(allocator, ctx, 0, &result);
        return result;
    }

    /// Resume a run from its persisted step records: replays completed steps,
    /// then continues from the first unpersisted one. Requires `wal` and
    /// `run_id`.
    pub fn resumeRun(self: Workflow, allocator: std.mem.Allocator, ctx: *SkillContext, run_id: []const u8) !WorkflowResult {
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
        }
        if (replayed_failed) {
            result.status = .failed;
            return result;
        }
        if (next_index >= self.steps.len) return result;
        try self.runSteps(allocator, ctx, next_index, &result);
        return result;
    }

    fn runSteps(self: Workflow, allocator: std.mem.Allocator, ctx: *SkillContext, start: usize, result: *WorkflowResult) !void {
        var step_index: usize = 0;
        step_index = start;
        while (step_index < self.steps.len) : (step_index += 1) {
            const step = self.steps[step_index];
            var outcome = try self.executeStep(allocator, ctx, step, step_index, result);
            if (outcome == null) {
                try self.maybeEscalate(ctx, .step_failed, step.name, allocator);
                result.status = .failed;
                break;
            }
            if (outcome.?.budget_exhausted) {
                try self.maybeEscalate(ctx, .budget_exhausted, step.name, allocator);
                result.status = .budget_exhausted;
                break;
            }

            // Reflection quality gate on the final step.
            if (step_index == self.steps.len - 1) {
                if (self.reflection) |vf| {
                    var reviews: usize = 0;
                    var verified = try vf(ctx, self.goal, outcome.?.output, allocator);
                    while (!verified) : (reviews += 1) {
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
        var attempts: usize = 0;
        var last_err: anyerror = error.Unknown;
        while (attempts <= step.retry) : (attempts += 1) {
            const outcome = self.runStep(allocator, ctx, step) catch |err| {
                last_err = err;
                continue;
            };
            try result.steps.append(allocator, .{
                .name = try allocator.dupe(u8, step.name),
                .status = .completed,
                .output = outcome.output,
            });
            try self.persistStep(allocator, step_index, step.name, "completed", null, outcome.output);
            return outcome;
        }
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
        return null;
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
