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

        var budget_exhausted = false;
        for (self.steps) |step| {
            var attempts: usize = 0;
            var last_err: anyerror = error.Unknown;
            var outcome: ?StepOutcome = null;

            while (attempts <= step.retry) : (attempts += 1) {
                outcome = self.runStep(allocator, ctx, step) catch |err| {
                    last_err = err;
                    continue;
                };
                break;
            }

            if (outcome) |o| {
                try result.steps.append(allocator, .{
                    .name = try allocator.dupe(u8, step.name),
                    .status = .completed,
                    .output = o.output,
                });
                budget_exhausted = budget_exhausted or o.budget_exhausted;
                if (o.budget_exhausted) {
                    result.status = .budget_exhausted;
                    break;
                }
            } else {
                try result.steps.append(allocator, .{
                    .name = try allocator.dupe(u8, step.name),
                    .status = .failed,
                    .error_message = if (last_err != error.Unknown)
                        try allocator.dupe(u8, @errorName(last_err))
                    else
                        null,
                });
                result.status = .failed;
                break;
            }
        }
        return result;
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
