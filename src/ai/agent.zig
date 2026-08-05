//! First-class ReAct agent: AiProvider tool_calls ↔ SkillRegistry.dispatch.
//!
//! Does **not** execute shell/MCP by default — only registered Zig skills,
//! optionally filtered by `allowlist` and `hooks.on_tool_request`.

const std = @import("std");
const provider_mod = @import("provider.zig");
const skill_mod = @import("skill.zig");
const audit_mod = @import("audit.zig");
const run_audit_mod = @import("run_audit.zig");
const retriever_mod = @import("retriever.zig");
const quota_mod = @import("quota.zig");
const tokenizer = @import("tokenizer.zig");
const Budget = @import("budget.zig").Budget;
const ContextManager = @import("context.zig").ContextManager;
const AgentHandle = @import("handle.zig").AgentHandle;
const DistributedTracer = @import("../tracing/DistributedTracer.zig").DistributedTracer;

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
    /// Reasoning/thinking chain from reasoning models (empty when absent).
    /// Owned when `owned_reasoning` is set.
    reasoning: []const u8 = "",
    owned_reasoning: bool = false,
    /// Set when the run stopped early because the task budget was exhausted.
    budget_exhausted: bool = false,
    /// Set when the run stopped early because the handle was canceled.
    canceled: bool = false,

    pub fn deinit(self: *AgentResult, allocator: std.mem.Allocator) void {
        if (self.owned_answer and self.answer.len > 0) allocator.free(self.answer);
        if (self.owned_reasoning and self.reasoning.len > 0) allocator.free(self.reasoning);
        self.* = .{ .answer = "", .steps = 0, .budget_exhausted = false, .canceled = false };
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
    canceled: usize = 0,

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
        try buf.print(allocator, "# HELP zigmodu_ai_agent_canceled_total Runs canceled via AgentHandle.\n", .{});
        try buf.print(allocator, "# TYPE zigmodu_ai_agent_canceled_total counter\n", .{});
        try buf.print(allocator, "zigmodu_ai_agent_canceled_total{{agent=\"{s}\"}} {d}\n", .{ name, self.canceled });
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
    /// Optional durable run-audit store; every run writes one row (kind=agent).
    audit_store: ?*run_audit_mod.RunAuditStore = null,
    /// Optional RAG: retrieve(goal) and prepend formatted context to the system message.
    retriever: ?Retriever = null,
    retrieve_top_k: usize = 5,
    /// Optional per-tenant token budget (`TokenQuota.record` after each LLM step).
    quota: ?*TokenQuota = null,
    /// Optional hard task budget: reserved before each LLM step; when exhausted
    /// in `.stop` mode the run ends early with `budget_exhausted` set.
    budget: ?*Budget = null,
    /// Optional conversation context manager (auto-compact long histories).
    context: ?*ContextManager = null,
    /// Optional cooperative runtime control (cancel / pause / progress).
    handle: ?*AgentHandle = null,
    /// Optional distributed tracing (creates a run span when set with a parent).
    tracer: ?*DistributedTracer = null,
    parent_span: ?*DistributedTracer.Span = null,

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
        const started_ms = @import("../core/Time.zig").monotonicNowMilliseconds();

        const tools_json = try self.registry.toOpenAiFunctionsAlloc(allocator);
        defer allocator.free(tools_json);

        var messages = std.ArrayList(AiProvider.ChatMsg).empty;
        defer messages.deinit(allocator);

        var owned_strs = std.ArrayList([]const u8).empty;
        defer {
            for (owned_strs.items) |s| allocator.free(s);
            owned_strs.deinit(allocator);
        }
        var summary: ?[]const u8 = null;
        defer if (summary) |s| allocator.free(s);

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
        var canceled_stopped = false;
        var span: ?*DistributedTracer.Span = null;
        if (self.tracer) |tr| {
            if (self.parent_span) |p| span = try tr.startSpan(p, "ai.agent.run");
        }
        defer if (span) |s| s.end();
        while (steps < max_steps) : (steps += 1) {
            if (self.handle) |h| {
                if (h.isCanceled()) {
                    self.metrics.canceled += 1;
                    canceled_stopped = true;
                    break;
                }
                h.waitIfPaused();
                h.recordStep();
            }
            if (self.context) |cm| {
                if (cm.shouldCompact(messages.items)) {
                    const new_msgs = try cm.manage(allocator, messages.items, &summary);
                    messages.deinit(allocator);
                    messages = new_msgs;
                }
            }
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
                try self.recordRunAudit(allocator, skill_ctx, steps + 1, started_ms, if (budget_stopped) "budget_exhausted" else if (canceled_stopped) "canceled" else "completed");
                const answer = try allocator.dupe(u8, resp.content);
                // Surface the reasoning chain from reasoning models.
                const reasoning = if (resp.reasoning_content.len > 0)
                    try allocator.dupe(u8, resp.reasoning_content)
                else
                    "";
                return .{
                    .answer = answer,
                    .steps = steps + 1,
                    .owned_answer = true,
                    .reasoning = reasoning,
                    .owned_reasoning = reasoning.len > 0,
                    .budget_exhausted = budget_stopped,
                    .canceled = canceled_stopped,
                };
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
                defer skill_mod.freeValue(allocator, result);
                const result_s = try std.json.Stringify.valueAlloc(allocator, result, .{});
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
        try self.recordRunAudit(allocator, skill_ctx, steps, started_ms, "max_steps");
        const timeout_msg = try allocator.dupe(u8, "Agent stopped: max_steps exceeded");
        return .{ .answer = timeout_msg, .steps = steps, .owned_answer = true, .budget_exhausted = budget_stopped, .canceled = canceled_stopped };
    }

    fn recordRunAudit(
        self: *Agent,
        allocator: std.mem.Allocator,
        skill_ctx: *SkillContext,
        steps: usize,
        started_ms: i64,
        status: []const u8,
    ) !void {
        const store = self.audit_store orelse return;
        const now_ms = @import("../core/Time.zig").monotonicNowMilliseconds();
        const run_id = try std.fmt.allocPrint(allocator, "agent-{d}", .{now_ms});
        defer allocator.free(run_id);
        try store.record(.{
            .run_id = run_id,
            .kind = .agent,
            .status = status,
            .tenant_id = skill_ctx.tenant_id,
            .steps = steps,
            .duration_ms = now_ms - started_ms,
        });
    }
};

test "AgentResult deinit frees owned answer" {
    const a = std.testing.allocator;
    var r = AgentResult{ .answer = try a.dupe(u8, "done"), .steps = 1, .owned_answer = true };
    r.deinit(a);
}

test "Agent recordRunAudit persists agent runs" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend{ .allocator = allocator, .client = &client };
    var store = run_audit_mod.RunAuditStore.init(allocator, &backend);
    try store.migrate();

    var agent = Agent{
        .provider = undefined,
        .registry = undefined,
        .audit_store = &store,
    };
    var sctx = SkillContext{ .allocator = allocator, .tenant_id = 3 };
    try agent.recordRunAudit(allocator, &sctx, 4, @import("../core/Time.zig").monotonicNowMilliseconds(), "completed");

    try std.testing.expectEqual(@as(usize, 1), try store.count());
    var entries = std.ArrayList(run_audit_mod.RunAuditEntry).empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.run_id);
            allocator.free(e.status);
        }
        entries.deinit(allocator);
    }
    try store.list(allocator, &entries, .agent, 3, 10);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("completed", entries.items[0].status);
    try std.testing.expectEqual(@as(usize, 4), entries.items[0].steps);
}

test "Agent.run executes a full tool-call loop against a mock provider" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    const ServerCtx = struct {
        server: *std.Io.net.Server,
        calls: *std.atomic.Value(u32),
        fn run(ctx: *@This()) void {
            const accepted = ctx.server.accept(std.testing.io) catch return;
            defer accepted.close(std.testing.io);
            var buf: [8192]u8 = undefined;
            while (true) {
                var fds = [_]std.posix.pollfd{.{ .fd = accepted.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&fds, 3000) catch break;
                if (fds[0].revents == 0) continue;
                const n = std.posix.read(accepted.socket.handle, &buf) catch break;
                if (n == 0) break;
                const call = ctx.calls.fetchAdd(1, .monotonic);
                const body = if (call == 0)
                    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"ping\",\"arguments\":\"{}\"}}]}}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}"
                else
                    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"final answer\",\"reasoning_content\":\"chain of thought\"}}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}";
                var hbuf: [1024]u8 = undefined;
                const resp = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch break;
                _ = std.posix.system.write(accepted.socket.handle, resp.ptr, resp.len);
            }
        }
    };
    var call_count = std.atomic.Value(u32).init(0);
    var server_ctx = ServerCtx{ .server = &server, .calls = &call_count };
    const th = try std.Thread.spawn(.{}, ServerCtx.run, .{&server_ctx});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{port});
    var http = @import("../http/HttpClient.zig").HttpClient.init(allocator, std.testing.io, 1, 5000);
    defer http.deinit();
    var provider = provider_mod.AiProvider.init(allocator, &http, url, "Bearer sk-mock", "mock-model");

    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    const State = struct {
        var pinged: usize = 0;
    };
    try registry.register(.{
        .name = "ping",
        .description = "pong",
        .parameters = &.{},
        .handler = struct {
            fn h(_: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                State.pinged += 1;
                var obj = std.json.ObjectMap{};
                try obj.put(allocator, try allocator.dupe(u8, "ok"), .{ .bool = true });
                return .{ .object = obj };
            }
        }.h,
    });

    var hooks_calls: usize = 0;
    var agent = Agent{
        .provider = &provider,
        .registry = &registry,
        .hooks = .{
            .ctx = &hooks_calls,
            .on_tool = struct {
                fn cb(ctx: ?*anyopaque, _: []const u8, _: bool) void {
                    const p: *usize = @ptrCast(@alignCast(ctx.?));
                    p.* += 1;
                }
            }.cb,
        },
    };
    var sctx = SkillContext{ .allocator = allocator, .tenant_id = 1 };
    var result = try agent.run(allocator, "answer the question", &sctx, 5);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("final answer", result.answer);
    // Reasoning chain surfaces through Agent.run() to the caller.
    try std.testing.expectEqualStrings("chain of thought", result.reasoning);
    try std.testing.expectEqual(@as(usize, 1), State.pinged);
    try std.testing.expectEqual(@as(usize, 1), agent.metrics.tool_calls);
    try std.testing.expect(hooks_calls >= 1);
}

const MockAgentServer = struct {
    server: std.Io.net.Server,
    calls: *std.atomic.Value(u32),
    allocator: std.mem.Allocator,
    state: *State,
    thread: std.Thread,

    const State = struct {
        server: std.Io.net.Server,
        calls: *std.atomic.Value(u32),
    };

    fn start(allocator: std.mem.Allocator, io: std.Io, comptime body_for: fn (u32) []const u8) !MockAgentServer {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try addr.listen(io, .{ .reuse_address = true });
        const calls = try allocator.create(std.atomic.Value(u32));
        calls.* = .init(0);
        const state = try allocator.create(State);
        state.* = .{ .server = server, .calls = calls };
        const S = struct {
            fn run(ctx: *State) void {
                const accepted = ctx.server.accept(std.testing.io) catch return;
                defer accepted.close(std.testing.io);
                var buf: [8192]u8 = undefined;
                while (true) {
                    var fds = [_]std.posix.pollfd{.{ .fd = accepted.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                    _ = std.posix.poll(&fds, 3000) catch break;
                    if (fds[0].revents == 0) continue;
                    const n = std.posix.read(accepted.socket.handle, &buf) catch break;
                    if (n == 0) break;
                    const body = body_for(ctx.calls.fetchAdd(1, .monotonic));
                    var hbuf: [2048]u8 = undefined;
                    const resp = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch break;
                    _ = std.posix.system.write(accepted.socket.handle, resp.ptr, resp.len);
                }
            }
        };
        const th = try std.Thread.spawn(.{}, S.run, .{state});
        return .{ .server = server, .calls = calls, .allocator = allocator, .state = state, .thread = th };
    }

    fn port(self: *const MockAgentServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn deinit(self: *MockAgentServer) void {
        self.thread.join();
        self.server.deinit(std.testing.io);
        self.allocator.destroy(self.calls);
        self.allocator.destroy(self.state);
    }
};

const mock_tool_call_body =
    \\{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"ping","arguments":"{}"}}]}}],"usage":{"prompt_tokens":40,"completion_tokens":20}}
;
const mock_final_body =
    \\{"choices":[{"message":{"role":"assistant","content":"done"}}],"usage":{"prompt_tokens":40,"completion_tokens":5}}
;

test "Agent.run compacts long context via the ContextManager" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = try MockAgentServer.start(allocator, std.testing.io, struct {
        fn f(call: u32) []const u8 {
            return if (call < 4) mock_tool_call_body else mock_final_body;
        }
    }.f);
    defer server.deinit();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{server.port()});
    var http = @import("../http/HttpClient.zig").HttpClient.init(allocator, std.testing.io, 1, 5000);
    defer http.deinit();
    var provider = provider_mod.AiProvider.init(allocator, &http, url, "Bearer sk", "mock");

    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "ping",
        .description = "pong",
        .parameters = &.{},
        .handler = struct {
            fn h(c: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                var obj = std.json.ObjectMap{};
                try obj.put(c.allocator, try c.allocator.dupe(u8, "ok"), .{ .bool = true });
                return .{ .object = obj };
            }
        }.h,
    });

    var cm = @import("context.zig").ContextManager{ .max_tokens = 90, .keep_recent_tokens = 40 };
    const State = struct {
        var summaries: usize = 0;
    };
    cm.summarize = struct {
        fn f(a: std.mem.Allocator, _: []const @import("context.zig").ChatMsg, summary: *[]const u8) anyerror!void {
            State.summaries += 1;
            summary.* = try a.dupe(u8, "compacted");
        }
    }.f;
    var agent = Agent{ .provider = &provider, .registry = &registry, .context = &cm };
    var sctx = SkillContext{ .allocator = allocator };
    var result = try agent.run(allocator, "question", &sctx, 8);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("done", result.answer);
    try std.testing.expect(State.summaries >= 1);
}

test "Agent.run stops early when the budget is exhausted" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = try MockAgentServer.start(allocator, std.testing.io, struct {
        fn f(_: u32) []const u8 {
            return mock_tool_call_body;
        }
    }.f);
    defer server.deinit();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{server.port()});
    var http = @import("../http/HttpClient.zig").HttpClient.init(allocator, std.testing.io, 1, 5000);
    defer http.deinit();
    var provider = provider_mod.AiProvider.init(allocator, &http, url, "Bearer sk", "mock");
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "ping",
        .description = "pong",
        .parameters = &.{},
        .handler = struct {
            fn h(c: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                var obj = std.json.ObjectMap{};
                try obj.put(c.allocator, try c.allocator.dupe(u8, "ok"), .{ .bool = true });
                return .{ .object = obj };
            }
        }.h,
    });

    // Tiny budget: the first reservation succeeds, the next loop iteration fails.
    var budget = @import("budget.zig").Budget.init(50);
    var agent = Agent{ .provider = &provider, .registry = &registry, .budget = &budget };
    var sctx = SkillContext{ .allocator = allocator };
    var result = try agent.run(allocator, "q", &sctx, 8);
    defer result.deinit(allocator);
    try std.testing.expect(result.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 1), agent.metrics.budget_exhausted);
}

test "Agent.run stops when a cancel is requested mid-run" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = try MockAgentServer.start(allocator, std.testing.io, struct {
        fn f(call: u32) []const u8 {
            return if (call < 3) mock_tool_call_body else mock_final_body;
        }
    }.f);
    defer server.deinit();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{server.port()});
    var http = @import("../http/HttpClient.zig").HttpClient.init(allocator, std.testing.io, 1, 5000);
    defer http.deinit();
    var provider = provider_mod.AiProvider.init(allocator, &http, url, "Bearer sk", "mock");
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "ping",
        .description = "pong",
        .parameters = &.{},
        .handler = struct {
            fn h(c: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                var obj = std.json.ObjectMap{};
                try obj.put(c.allocator, try c.allocator.dupe(u8, "ok"), .{ .bool = true });
                return .{ .object = obj };
            }
        }.h,
    });

    const State = struct {
        var handle: ?*@import("handle.zig").AgentHandle = null;
    };
    var handle = @import("handle.zig").AgentHandle.init();
    State.handle = &handle;
    var agent = Agent{
        .provider = &provider,
        .registry = &registry,
        .handle = &handle,
        .hooks = .{
            .on_step = struct {
                fn cb(_: ?*anyopaque, _: usize, _: usize) void {
                    // Cancel after the first step so the next loop iteration stops.
                    if (State.handle) |h| h.requestCancel();
                }
            }.cb,
        },
    };
    var sctx = SkillContext{ .allocator = allocator };
    var result = try agent.run(allocator, "q", &sctx, 8);
    defer result.deinit(allocator);
    try std.testing.expect(result.canceled);
    try std.testing.expectEqual(@as(usize, 1), agent.metrics.canceled);
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
