//! First-class ReAct agent: AiProvider tool_calls ↔ SkillRegistry.dispatch.
//!
//! Does **not** execute shell/MCP by default — only registered Zig skills,
//! optionally filtered by `allowlist` and `hooks.on_tool_request`.

const std = @import("std");
const provider_mod = @import("provider.zig");
const skill_mod = @import("skill.zig");
const audit_mod = @import("audit.zig");
const retriever_mod = @import("retriever.zig");
const quota_mod = @import("quota.zig");
const tokenizer = @import("tokenizer.zig");
const Budget = @import("budget.zig").Budget;

pub const AiProvider = provider_mod.AiProvider;
pub const SkillRegistry = skill_mod.SkillRegistry;
pub const SkillContext = skill_mod.SkillContext;
pub const AgentAuditLog = audit_mod.AgentAuditLog;
pub const Retriever = retriever_mod.Retriever;
pub const TokenQuota = quota_mod.TokenQuota;

pub const AgentResult = struct {
    answer: []const u8,
    steps: usize,
    owned_answer: bool = false,
    /// Set when the run stopped early because the task budget was exhausted.
    budget_exhausted: bool = false,

    pub fn deinit(self: *AgentResult, allocator: std.mem.Allocator) void {
        if (self.owned_answer and self.answer.len > 0) allocator.free(self.answer);
        self.* = .{ .answer = "", .steps = 0, .budget_exhausted = false };
    }
};

/// Human-in-the-loop / policy gate before a tool runs.
pub const ToolApproval = enum {
    allow,
    deny,
};

/// Optional observation hooks (metrics / tracing / logs / approval).
pub const AgentHooks = struct {
    ctx: ?*anyopaque = null,
    on_step: ?*const fn (ctx: ?*anyopaque, step: usize, tool_calls: usize) void = null,
    /// Called before dispatch; return `.deny` to skip the tool (feeds error JSON to the model).
    on_tool_request: ?*const fn (ctx: ?*anyopaque, name: []const u8, arguments: []const u8) ToolApproval = null,
    on_tool: ?*const fn (ctx: ?*anyopaque, name: []const u8, ok: bool) void = null,
    on_finish: ?*const fn (ctx: ?*anyopaque, steps: usize, max_steps_hit: bool) void = null,
};

pub const AgentMetrics = struct {
    runs: usize = 0,
    steps: usize = 0,
    tool_calls: usize = 0,
    tool_errors: usize = 0,
    tool_denied: usize = 0,
    max_steps_hits: usize = 0,
    budget_exhausted: usize = 0,

    pub fn toPrometheusFormat(self: AgentMetrics, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.print(allocator, "# HELP zigmodu_ai_agent_runs_total Agent run invocations.\n", .{});
        try buf.print(allocator, "# TYPE zigmodu_ai_agent_runs_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_agent_runs_total{{agent=\"{s}\"}} {d}\n", .{ name, self.runs });
        try buf.print(allocator, "# HELP zigmodu_ai_agent_steps_total LLM steps executed.\n", .{});
        try buf.print(allocator, "# TYPE zigmodu_ai_agent_steps_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_agent_steps_total{{agent=\"{s}\"}} {d}\n", .{ name, self.steps });
        try buf.print(allocator, "# HELP zigmodu_ai_agent_tool_calls_total Tool dispatches.\n", .{});
        try buf.print(allocator, "# TYPE zigmodu_ai_agent_tool_calls_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_agent_tool_calls_total{{agent=\"{s}\"}} {d}\n", .{ name, self.tool_calls });
        try buf.print(allocator, "# HELP zigmodu_ai_agent_tool_errors_total Tool dispatch failures.\n", .{});
        try buf.print(allocator, "# TYPE zigmodu_ai_agent_tool_errors_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_agent_tool_errors_total{{agent=\"{s}\"}} {d}\n", .{ name, self.tool_errors });
        try buf.print(allocator, "# HELP zigmodu_ai_agent_tool_denied_total Tools denied by approval gate.\n", .{});
        try buf.print(allocator, "# TYPE zigmodu_ai_agent_tool_denied_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_agent_tool_denied_total{{agent=\"{s}\"}} {d}\n", .{ name, self.tool_denied });
        try buf.print(allocator, "# HELP zigmodu_ai_agent_max_steps_hits_total Runs stopped by max_steps.\n", .{});
        try buf.print(allocator, "# TYPE zigmodu_ai_agent_max_steps_hits_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_agent_max_steps_hits_total{{agent=\"{s}\"}} {d}\n", .{ name, self.max_steps_hits });
        try buf.print(allocator, "# HELP zigmodu_ai_agent_budget_exhausted_total Runs stopped by budget exhaustion.\n", .{});
        try buf.print(allocator, "# TYPE zigmodu_ai_agent_budget_exhausted_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_agent_budget_exhausted_total{{agent=\"{s}\"}} {d}\n", .{ name, self.budget_exhausted });
        return try buf.toOwnedSlice(allocator);
    }
};

pub const Agent = struct {
    provider: *AiProvider,
    registry: *SkillRegistry,
    system_prompt: []const u8 = "You are a helpful agent. Prefer tools for factual lookups. When finished, reply with the final answer only.",
    allowlist: ?[]const []const u8 = null,
    tool_timeout_ms: ?u64 = null,
    hooks: AgentHooks = .{},
    metrics: AgentMetrics = .{},
    audit: ?*AgentAuditLog = null,
    /// Optional RAG: retrieve(goal) and prepend formatted context to the system message.
    retriever: ?Retriever = null,
    retrieve_top_k: usize = 5,
    /// Optional per-tenant token budget (`TokenQuota.record` after each LLM step).
    quota: ?*TokenQuota = null,
    /// Optional hard task budget: reserved before each LLM step; when exhausted
    /// in `.stop` mode the run ends early with `budget_exhausted` set.
    budget: ?*Budget = null,

    pub fn run(
        self: *Agent,
        allocator: std.mem.Allocator,
        goal: []const u8,
        skill_ctx: *SkillContext,
        max_steps: usize,
    ) !AgentResult {
        if (max_steps == 0) return error.InvalidMaxSteps;
        self.metrics.runs += 1;
        if (self.audit) |log| {
            log.record(.run_start, "", goal, skill_ctx.tenant_id orelse 0, skill_ctx.user_id orelse 0);
        }

        const tools_json = try self.registry.toOpenAiFunctionsAlloc(allocator);
        defer allocator.free(tools_json);

        var messages = std.ArrayList(AiProvider.ChatMsg).empty;
        defer messages.deinit(allocator);

        var owned_strs = std.ArrayList([]const u8).empty;
        defer {
            for (owned_strs.items) |s| allocator.free(s);
            owned_strs.deinit(allocator);
        }

        var system_content: []const u8 = self.system_prompt;
        if (self.retriever) |r| {
            if (r.retrieve(allocator, goal, self.retrieve_top_k)) |chunks| {
                defer r.free(allocator, chunks);
                if (chunks.len > 0) {
                    const ctx_block = try retriever_mod.KeywordRetriever.formatContext(allocator, chunks);
                    defer allocator.free(ctx_block);
                    const merged = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ self.system_prompt, ctx_block });
                    try owned_strs.append(allocator, merged);
                    system_content = merged;
                }
            } else |_| {}
        }

        try messages.append(allocator, .{ .role = "system", .content = system_content });
        try messages.append(allocator, .{ .role = "user", .content = goal });

        var owned_tool_call_slices = std.ArrayList([]AiProvider.ToolCall).empty;
        defer {
            for (owned_tool_call_slices.items) |slice| {
                for (slice) |tc| {
                    allocator.free(tc.id);
                    allocator.free(tc.name);
                    allocator.free(tc.arguments);
                }
                allocator.free(slice);
            }
            owned_tool_call_slices.deinit(allocator);
        }

        var steps: usize = 0;
        var budget_stopped = false;
        while (steps < max_steps) : (steps += 1) {
            if (self.budget) |b| {
                const est = tokenizer.estimateMessages(messages.items);
                if (!b.tryConsume(est)) {
                    switch (b.mode) {
                        .stop => {
                            self.metrics.budget_exhausted += 1;
                            budget_stopped = true;
                            break;
                        },
                        .warn => std.log.warn("[Agent] budget exhausted, continuing (limit={d})", .{b.limit}),
                    }
                }
            }
            var resp = try self.provider.chatWith(messages.items, .{ .tools_json = tools_json });
            defer self.provider.freeResponse(&resp);

            if (self.quota) |q| {
                try q.record(skill_ctx.tenant_id orelse 0, resp.prompt_tokens, resp.completion_tokens);
            }

            self.metrics.steps += 1;
            if (self.hooks.on_step) |cb| cb(self.hooks.ctx, steps + 1, resp.tool_calls.len);

            if (resp.tool_calls.len == 0) {
                if (self.hooks.on_finish) |cb| cb(self.hooks.ctx, steps + 1, false);
                if (self.audit) |log| {
                    log.record(.run_finish, "", resp.content, skill_ctx.tenant_id orelse 0, skill_ctx.user_id orelse 0);
                }
                const answer = try allocator.dupe(u8, resp.content);
                return .{ .answer = answer, .steps = steps + 1, .owned_answer = true, .budget_exhausted = budget_stopped };
            }

            const tc_copy = try allocator.alloc(AiProvider.ToolCall, resp.tool_calls.len);
            for (resp.tool_calls, 0..) |tc, i| {
                tc_copy[i] = .{
                    .id = try allocator.dupe(u8, tc.id),
                    .name = try allocator.dupe(u8, tc.name),
                    .arguments = try allocator.dupe(u8, tc.arguments),
                };
            }
            try owned_tool_call_slices.append(allocator, tc_copy);

            const content_copy = try allocator.dupe(u8, resp.content);
            try owned_strs.append(allocator, content_copy);

            try messages.append(allocator, .{
                .role = "assistant",
                .content = content_copy,
                .tool_calls = tc_copy,
            });

            for (tc_copy) |tc| {
                self.metrics.tool_calls += 1;

                if (self.hooks.on_tool_request) |cb| {
                    if (cb(self.hooks.ctx, tc.name, tc.arguments) == .deny) {
                        self.metrics.tool_denied += 1;
                        if (self.hooks.on_tool) |tcb| tcb(self.hooks.ctx, tc.name, false);
                        if (self.audit) |log| {
                            log.record(.tool_denied, tc.name, "denied", skill_ctx.tenant_id orelse 0, skill_ctx.user_id orelse 0);
                        }
                        const err_s = try allocator.dupe(u8, "{\"error\":\"ToolDenied\"}");
                        try owned_strs.append(allocator, err_s);
                        const tid = try allocator.dupe(u8, tc.id);
                        try owned_strs.append(allocator, tid);
                        try messages.append(allocator, .{
                            .role = "tool",
                            .tool_call_id = tid,
                            .content = err_s,
                        });
                        continue;
                    }
                }

                var parsed_opt: ?std.json.Parsed(std.json.Value) = null;
                defer if (parsed_opt) |*p| p.deinit();

                const args_val: std.json.Value = blk: {
                    if (tc.arguments.len == 0 or std.mem.eql(u8, tc.arguments, "{}")) {
                        break :blk .{ .object = .{} };
                    }
                    const parsed = std.json.parseFromSlice(std.json.Value, allocator, tc.arguments, .{}) catch {
                        break :blk .{ .object = .{} };
                    };
                    parsed_opt = parsed;
                    break :blk parsed.value;
                };

                const result = self.registry.dispatchWith(tc.name, skill_ctx, args_val, .{
                    .allowlist = self.allowlist,
                    .timeout_ms = self.tool_timeout_ms,
                }) catch |err| {
                    self.metrics.tool_errors += 1;
                    if (self.hooks.on_tool) |cb| cb(self.hooks.ctx, tc.name, false);
                    if (self.audit) |log| {
                        log.record(.tool_err, tc.name, @errorName(err), skill_ctx.tenant_id orelse 0, skill_ctx.user_id orelse 0);
                    }
                    const err_s = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
                    try owned_strs.append(allocator, err_s);
                    const tid = try allocator.dupe(u8, tc.id);
                    try owned_strs.append(allocator, tid);
                    try messages.append(allocator, .{
                        .role = "tool",
                        .tool_call_id = tid,
                        .content = err_s,
                    });
                    continue;
                };

                if (self.hooks.on_tool) |cb| cb(self.hooks.ctx, tc.name, true);
                if (self.audit) |log| {
                    log.record(.tool_ok, tc.name, "", skill_ctx.tenant_id orelse 0, skill_ctx.user_id orelse 0);
                }
                const result_s = try std.json.Stringify.valueAlloc(allocator, result, .{});
                skill_mod.freeValue(allocator, result);
                try owned_strs.append(allocator, result_s);
                const tid = try allocator.dupe(u8, tc.id);
                try owned_strs.append(allocator, tid);
                try messages.append(allocator, .{
                    .role = "tool",
                    .tool_call_id = tid,
                    .content = result_s,
                });
            }
        }

        self.metrics.max_steps_hits += 1;
        if (self.hooks.on_finish) |cb| cb(self.hooks.ctx, steps, true);
        if (self.audit) |log| {
            log.record(.run_max_steps, "", "max_steps exceeded", skill_ctx.tenant_id orelse 0, skill_ctx.user_id orelse 0);
        }
        const timeout_msg = try allocator.dupe(u8, "Agent stopped: max_steps exceeded");
        return .{ .answer = timeout_msg, .steps = steps, .owned_answer = true, .budget_exhausted = budget_stopped };
    }
};

test "AgentResult deinit frees owned answer" {
    const a = std.testing.allocator;
    var r = AgentResult{ .answer = try a.dupe(u8, "done"), .steps = 1, .owned_answer = true };
    r.deinit(a);
}

test "SkillRegistry tools json for agent" {
    const a = std.testing.allocator;
    var reg = SkillRegistry.init(a, std.testing.io);
    defer reg.deinit();
    try reg.register(.{
        .name = "ping",
        .description = "pong",
        .parameters = &.{},
        .handler = struct {
            fn h(_: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                return .{ .string = "pong" };
            }
        }.h,
    });
    const json = try reg.toOpenAiFunctionsAlloc(a);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"ping\"") != null);
}

test "ToolApproval enum" {
    try std.testing.expect(ToolApproval.deny != ToolApproval.allow);
}
