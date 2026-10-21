# Agent Runtime & Execution Guard (`zmodu.ai`)

Applies to: zmodu v0.21+

By default, **AI agents in zmodu cannot execute state-mutating actions**. Every tool invocation passes through a fail-closed authority gate (`ai.Guard`), and high-risk actions follow the `Proposal -> Risk -> Execution` pipeline (`ai.ProposalPipeline`).

| Layer | Type | Role |
|-------|------|------|
| **Authority Gate** | `ai.Guard` (`src/ai/guard.zig`) | Enforces two independent fail-closed axes: action class and tool allow/deny lists |
| **Tool Action Class** | `skill.Tool.action` | Declares whether a skill is `.read`, `.propose`, or `.execute` (defaults to `.execute`) |
| **Staged Pipeline** | `ai.ProposalPipeline` (`src/ai/proposal.zig`) | Enforces the `Propose -> RiskReview -> ApprovalFlow -> Execute` sequence |
| **Worker Execution** | `ai.AgentWorker` (`src/ai/agent_worker.zig`) | Runs `Agent.run` inside a bounded-mailbox runtime worker off the HTTP request thread |

## 1. Two Fail-Closed Axes (`ai.Guard`)

| Axis | Default | Behavior |
|------|---------|----------|
| **Action Class** (`.read` / `.propose` / `.execute`) | `allow_execute = false` | Listing a tool name in `allow` does **not** permit `.execute` tools unless `allow_execute = true` is also set |
| **Tool Name** (`allow` / `deny`) | `allow = &.{}` (empty) | An empty `allow` list permits nothing (`guard.isInert() == true`); `deny` always overrides `allow` |

- Denied tool calls do **not** consume token budget.
- Denials are counted by specific cause (`denied_not_listed`, `denied_explicitly`, `denied_execute_class`, `denied_budget`) in fixed evaluation order (`deny` → `allow` membership → `allow_execute` switch).
- Use `registry.auditPolicy(allocator, guard.permissions)` (or `spec.auditPolicy(allocator)`) at startup to detect policies that are inert or list `.execute` tools while `allow_execute = false` (`hasClassBlindSpot()`).

## 2. Declarative Agent Wiring (`ai.AgentSpec`)

Always construct agents through `ai.AgentSpec` rather than a bare `Agent{}` struct literal (which leaves `guard = null` and therefore unbounded):

```zig
var guard = ai.Guard.init(.{
    .allow = &.{ "market.quote", "order.draft", "order.submit" },
    .deny = &.{},
    .allow_execute = false,
});

var spec = ai.AgentSpec{
    .name = "trader",
    .provider = &provider,
    .skills = &registry,
    .guard = &guard,
    .memory = &memory,
    .system_prompt = "You are a trading assistant.",
};
var agent = spec.build();

try registry.register(.{
    .name = "order.draft",
    .action = .propose,
    .description = "Draft an order proposal",
    .parameters = &.{},
    .handler = draftOrder,
});
```

When a tool call is denied during `agent.run`, `Agent` returns `{"error":"ToolDenied","reason":"denied_execute_class"}` as the tool observation so the model can fall back to a `.propose` tool, while incrementing `AgentMetrics.tool_denied` and recording an audit entry.

## 3. Staged Execution (`ai.ProposalPipeline`)

`ai.ProposalPipeline` enforces the `Proposal -> Risk -> Approval -> Execution` sequence:

```text
guard.check(.propose, action)  --refuse-->  .propose_refused
        |
risk.RiskReview.review         --reject-->  .risk_rejected
        |                      --escalate-> approval.ApprovalFlow --pending--> .needs_human
        |                                            | approved
guard.check(.execute, action)  --refuse-->  .execute_not_permitted
        |
executor(...)                  --error--->  .executor_failed
        |
    .executed
```

```zig
var pipeline = ai.ProposalPipeline.init(&guard, executorFn);
pipeline.risk = review.toPort();
pipeline.approval = chain.toPort();
pipeline.approval_steps = &steps;

const out = try pipeline.submit(allocator, &ctx, .{
    .action = "order.submit",
    .payload = "order-1",
    .amount = 150_000,
});
switch (out.verdict) {
    .executed => {},
    .execute_not_permitted => queueForHuman(out),
    else => |v| std.log.warn("proposal refused: {s}", .{@tagName(v)}),
}
```

## 4. Tenant-Isolated Memory Injection

`Agent.memory` uses `MemoryStore.recallBlockAlloc`: both `tenant_id` and `user_id` must be present and non-zero, or zero memory entries are injected into the prompt. Do not use `MemoryStore.formatContext` on agent paths, because `MemoryStore.recall` treats `tenant_id == 0` as a wildcard across tenants.

## 5. Running an Agent as a Runtime Worker (`ai.AgentWorker`)

`Agent.run` blocks for the duration of LLM round-trips. For webhook or cron triggers, spawn `ai.AgentWorker` on the application runtime so requests enqueue goals into a bounded mailbox and return immediately:

```zig
const ai = zmodu.ai;

fn onDone(ud: ?*anyopaque, d: ai.AgentDone) void {
    const me: *MyApp = @ptrCast(@alignCast(ud.?));
    if (d.err) |e| return me.alerts.push("agent failed: {s}", .{@errorName(e)});
    me.answers.push(d.result.?.answer); // Borrowed slice; copy if retaining past callback
}

// Inside module `initWith(ctx)`:
const rt = try ctx.runtime();
const worker = try rt.spawn(ai.AgentWorker, .{
    .allocator = ctx.allocator,
    .agent = &my_agent,
    .on_result = onDone,
    .ud = self,
}, 32);

// Inside HTTP handler or webhook:
try ai.agent_worker.post(ctx.allocator, 32, worker, goal_text, tenant_id, user_id);
```

Provider or tool failures are reported via `on_result(d.err)` rather than counting against the supervisor's crash budget (`stats().handler_errors` stays `0`).
