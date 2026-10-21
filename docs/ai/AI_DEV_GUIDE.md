# AI Integration Guide

Wire `zmodu.ai` into a business system: key supply, provider, Agent, Workflow, custom skills and entry points. Every capability keeps the controlled-execution posture: allowlists, permission codes, quotas, audit and tenant isolation, and the model never runs code or SQL of its own.

Companion docs: `AI_SKILLS.md` (skill catalog), `AI_ORCHESTRATION.md` (orchestration shapes), `LLM_POLICIES.md` (LLM policy wiring), `MCP.md` (skills to MCP bridge), `AI_METHODOLOGY.md` (framework philosophy; read before writing framework code).

## 1. Layers

| Layer | Components | Role |
|-------|------------|------|
| Supply | `ai.AiKeyManager`, `KeyPool`, `ProviderRegistry`, `CooldownStore` | Key pool, rotation, cooldown, provider fallback |
| Model | `ai.AiProvider` | OpenAI-compatible chat and `chatStream`; pooled `http://`, `https://` via `std.http.Client` |
| Execution | `ai.Agent`, `ai.workflow.Workflow`, `Budget`, `ContextManager` | ReAct loop, multi-step orchestration, budget, history compaction |
| Capability | `SkillRegistry` (`db.query`, `kpi.query`, `approval.request`, `admin.*`) plus `ai.llm` policies | Tools the model may call, and LLM-backed decisions |
| Entry points | HTTP (ComptimeRouter), `trigger.registerCron`, `OutboxWorkflowBridge`, `ai.mcp` | Users, schedules, events, external platforms |

Dependency direction is supply → model → execution → capability; the application assembles the entry points. Every layer is a plain Zig object without hidden global state, except `KeyPool` cooldown counters, which are process-local observations.

## 2. Examples

[`examples/ai-ops`](../../examples/ai-ops) shows the full business loop: alert, diagnose, approve, notify, audit, with the approval queue exposed over HTTP. [`examples/llm-policies`](../../examples/llm-policies) wires real LLM policies and injects `json_fn` so it runs without a model. [`examples/mcp-server`](../../examples/mcp-server) exposes a `SkillRegistry` as an MCP stdio server (`tools/list`, `tools/call`).

## 3. Minimal chain

### 3.1 Supply: AiKeyManager

Use `AiKeyManager` in production instead of a bare `AiProvider`. It rotates keys, cools down keys on 429/401, and falls back to another provider (details in `LLM_POLICIES.md` §8).

```zig
var mgr = zmodu.ai.AiKeyManager.init(allocator, io);
defer mgr.deinit();
try mgr.applyConfig(&.{
    .{ .name = "deepseek", .endpoint = "https://api.deepseek.com/v1/chat/completions",
       .api_keys = &.{ "sk-a", "sk-b" }, // read from environ_map; never hardcode
       .models = &.{"deepseek-v4-flash"}, .fallback_providers = &.{"openai"} },
    .{ .name = "openai", .endpoint = "https://api.openai.com/v1/chat/completions",
       .api_keys = &.{"sk-o1"}, .models = &.{"deepseek-v4-flash"} },
});

var http = zmodu.http.HttpClient.init(allocator, io, 4, 30000);
defer http.deinit();
var provider = try mgr.providerFor(allocator, &http, "deepseek-v4-flash");
```

When several instances share one key set, attach Redis cooldowns through `mgr.setSharedStore(...)`; otherwise each instance is blind to the others' cooldown and disable state.

### 3.2 Capability: register a skill

```zig
fn orderSummaryHandler(ctx: *zmodu.ai.SkillContext, args: std.json.Value) anyerror!std.json.Value {
    try ctx.checkDeadline();                     // cooperative timeout
    const order_id = args.object.get("order_id").?.integer;
    var obj = std.json.ObjectMap{};
    // Ownership: every key and string must come from ctx.allocator; freeValue deep-frees.
    try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "order_id"), .{ .integer = order_id });
    try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "total_cents"), .{ .integer = 5997 });
    return .{ .object = obj };
}

var registry = zmodu.ai.SkillRegistry.init(allocator, io);
defer registry.deinit();
try registry.register(.{
    .name = "order.summary",
    .description = "Read the order total",
    .parameters = &.{
        .{ .name = "order_id", .type = .number, .description = "Order id", .required = true },
    },
    .required_permission = "order:read", // otherwise error.PermissionDenied
    .action = .read,                     // .read / .propose / .execute (default .execute)
    .handler = orderSummaryHandler,
});
```

### 3.3 Execution: Agent

Build through `ai.AgentSpec`. A bare `Agent{}` without `.guard` is unbounded and can call any registered tool. Gate details: [`AGENT_RUNTIME.md`](../reference/AGENT_RUNTIME.md).

```zig
var budget = zmodu.ai.Budget.init(2000); // hard reservation, not after-the-fact accounting
var audit_log = try zmodu.ai.AgentAuditLog.init(allocator, io, 256);
var memory = zmodu.ai.MemoryStore.init(allocator, io);
var guard = zmodu.ai.Guard.init(.{
    .allow = &.{"order.summary"}, // listing a name is not permission to execute
    .allow_execute = false,       // second switch for the execute class
});

var spec = zmodu.ai.AgentSpec{
    .name = "order-assistant",    // identity in logs and Prometheus labels
    .provider = &provider,
    .skills = &registry,
    .system_prompt = "You are an order assistant. Use only granted tools.",
    .guard = &guard,              // omit and the agent is unbounded; assert spec.isGuarded()
    .memory = &memory,            // nothing is injected without a non-zero tenant and user
    .budget = &budget,
    .allowlist = &.{"order.summary"}, // tool-name allowlist; can coexist with guard
    .tool_timeout_ms = 5_000,
    .audit = &audit_log,
};

var agent = spec.build();
var skill_ctx = zmodu.ai.SkillContext{
    .allocator = allocator,
    .tenant_id = 1,
    .user_id = 42,
    .permissions = &.{"order:read"},
};
var result = try agent.run(allocator, "What is the total of order 42?", &skill_ctx, 5);
defer result.deinit(allocator);
if (result.budget_exhausted) { /* degrade */ }
if (result.canceled) { /* aborted by user or orchestrator */ }
```

### 3.4 Orchestration: Workflow

```zig
var wf = zmodu.ai.workflow.Workflow.init(&registry, &.{
    .{ .name = "check", .kind = .{ .skill = .{ .name = "order.summary", .args = .{ .object = .{} } } } },
    .{ .name = "risk",  .kind = .{ .skill = .{ .name = "risk.review", .args = .{ .object = .{} } } }, .depends_on = &.{"check"} },
    .{ .name = "report", .kind = .{ .llm = .{ .prompt = "Summarize the risk verdict in one paragraph" } }, .depends_on = &.{"risk"} },
});
wf.wal = &wal;                          // crash recovery and idempotent replay
wf.reflection = zmodu.ai.llm.llmVerify; // quality gate
wf.goal = "Produce an order risk verdict";
wf.max_reviews = 2;
var wf_result = try wf.run(allocator, &skill_ctx);
defer wf_result.deinit();
```

Approval gate: a step `.{ .approval = .{ .subject = "order-42", .amount = 150000 } }` runs through the approval chain once `wf.approval_flow` is set. When the flow escalates, the run stops with `.pending_human`; after a human decides, `wf.resumeRun(allocator, &skill_ctx, run_id)` continues.

## 4. Custom skill rules

| Rule | Requirement |
|------|-------------|
| Parameters | `Param{ name, type, description, required }` maps to JSON Schema for function calling |
| Ownership | Every key and string in the result uses `ctx.allocator`; the caller releases with `ai.freeValue` |
| Permission | Set `required_permission`; dispatch returns `error.PermissionDenied` unless `SkillContext.permissions` holds it |
| Structured failure | `return ctx.fail("rate_limited", "try later", true)`; the agent feeds back `{"error":{"code","message","retryable"}}`. Known errors (`PermissionDenied`, `ToolTimeout`, `InvalidArguments`, …) map to stable codes; unknown ones keep `{"error":"Name"}` |
| Allowlist | `Agent.allowlist` or `dispatchWith(.{ .allowlist })` is the second narrowing |
| Timeout | Call `ctx.checkDeadline()` in handler loops; the framework also checks after return, without preempting |
| Tenant | `SkillContext.tenant_id` must be honoured by the skill: entity skills use the entity's `tenant_column`, `db.query` uses `BusinessSkillsConfig.db_query_tenant_column` (`error.TenantScopeUnavailable` when unset, never an unfiltered read) |
| Read first | Write actions go through `ai.actions` (transactional outbox plus idempotency key), not raw SQL in a handler |

## 5. Choosing a layer

| Situation | Use | Notes |
|-----------|-----|-------|
| One conversation with repeated tool calls | `Agent` | ReAct loop: question, data lookup, answer |
| Fixed multi-step flow with approval, parallelism or resume | `Workflow` | Linear, DAG (`depends_on`), `.approval`, WAL recovery |
| Model decides approve, risk, diagnosis or quality | `ai.llm` policies | `llmApprove` / `llmRiskDecide` / `llmDiagnose` / `llmVerify`; failures escalate |
| Expose skills to an external LLM platform | `ai.mcp` bridge | `serveStdio` runs an MCP server with `tools/list` and `tools/call` |
| Scheduled or event-driven runs | `ai.trigger` | `registerCron` / `fire`; results can be written back through the outbox |

## 6. Entry points

HTTP (ComptimeRouter): build the context with `ai.http.skillContext(ctx)`, then call `agent.run` or `wf.run`.

```zig
fn runAgent(ctx: *http.Context, self: *State) !void {
    const sctx = try ai.http.skillContext(ctx); // fails closed, never guesses
    var result = try self.agent.run(ctx.allocator, goal, &sctx, 8);
    try ctx.jsonStruct(200, .{ .answer = result.answer });
}
```

`skillContext` reads only the JWT middleware attributes (`user_id`, `tenant_id`, `permissions`), never headers or bodies. Missing or non-numeric ids raise `error.TenantRequired`, `error.UserRequired`, `error.MalformedTenant` or `error.MalformedUser`. Permission CSV is split into `ctx.allocator` memory that lives for the request. Single-tenant deployments should write the `SkillContext` literal explicitly instead of guessing.

Cron:

```zig
var trigger = zmodu.ai.trigger.Trigger.init(allocator, io, run_fn, skill_ctx);
try trigger.registerCron(&scheduler, "nightly-report", "0 3 * * *", "nightly report");
_ = trigger.fire(allocator, "webhook-event"); // immediate event trigger
```

Outbox: `ai.bridge.OutboxWorkflowBridge` routes outbox entries by topic (exact or prefix) into `trigger.fire`. Write-backs from `ai.approval`, `ai.risk`, `ai.notify` and peers can then be consumed by `outbox.OutboxConsumer`, closing the loop from business event to AI to audit or a human queue.

MCP: `ai.mcp.serveStdio(io, allocator, &registry, ctx_template)` runs a stdio server that derives parameter schemas from the registry. It lists only the skills the session context can call (permission-gated tools are hidden unless `ctx_template.permissions` holds the code). For an explicit name allowlist, call `ai.mcp.serveStdioFiltered(..., .{ .allowlist = &.{ "db.query", "kpi.query" }, .permissions = ctx_template.permissions })`; pass `.{ .permissions = null }` to list everything. Keep `admin.*` out of registries exposed to external callers. See `MCP.md`.

## 7. Security checklist

- [ ] Keys come from `init.environ_map`; endpoints and models are an application-side allowlist.
- [ ] Both `guard.allow` (empty permits nothing) and `Agent.allowlist` (`null` permits every registered tool) list only what the business needs; no `admin.*` on an exposed surface.
- [ ] Write skills set `required_permission`, write through the transactional outbox, and use an idempotency key (`run_id`).
- [ ] Handler results are allocated from `ctx.allocator`; callers release with `freeValue`.
- [ ] HTTP boundaries use `ai.http.skillContext(ctx)`; tenant-aware apps use `registerBusinessSkillsWith(..., .{ .db_query_tenant_column = "<column>" })`, since the default entry point makes `db.query` fail closed.
- [ ] Approval APIs (`ai.approval_api.ApprovalApi`) scope by the verified `tenant_id` attribute. `X-Tenant-ID` is honoured only with `Config.allow_tenant_header = true`, and a conflict with the attribute returns 403. An unscoped request is now 403 rather than listing every tenant.
- [ ] Retrievers partition or filter by tenant; never treat "shared index plus similarity cutoff" as isolation. For a shared index, set `Retriever.retrieveScopedFn`, which receives the run's `tenant_id`/`user_id`; an unscoped scoped run logs one process-wide warning.
- [ ] `GET /approvals/pending` shares the `approval:decide` permission with approve/reject. Read-only auditors need their own role and endpoint.
- [ ] Long tasks set `deadline_ms`, `tool_timeout_ms` and `Budget`; production enables audit (`AgentAuditLog`, `RunAuditStore`) and metrics.
- [ ] LLM decisions escalate when uncertain and never approve silently (`ai.llm` already behaves this way).
- [ ] Tool results are untrusted input: the framework wraps them as `[untrusted tool output …]` and truncates at `Agent.tool_result_limit_bytes` (32 KiB by default, with a truncation marker). Do not paste external text into a system prompt.

### RAG

`ai.rag` covers the steps that are easiest to get wrong:

- `chunkText`: UTF-8 safe, overlapping, splits at whitespace. Hand-slicing `text[i..i+800]` can cut a multi-byte character in half.
- `VectorIndex`: entries are stored per tenant and `search` returns only same-tenant entries. A search without a tenant sees only global entries, never everything (fail-closed).
- `IndexRetriever`: adapts an application `EmbedFn` to `Retriever.retrieveScopedFn`, so the agent passes the run scope automatically.
- `ai.embedding.OpenAiEmbeddings`: OpenAI-compatible `/embeddings` client with batching, optional `dimensions`, and response validation; a count or dimension mismatch is rejected. `Adapter` is the ready-made `EmbedFn`:

```zig
var emb = ai.embedding.OpenAiEmbeddings{ .allocator = alloc, .http = &client,
    .endpoint = "https://api.openai.com/v1/embeddings", .api_key = key };
var adapter = ai.embedding.Adapter{ .impl = &emb };
var index_retriever = ai.rag.IndexRetriever{ .index = &index, .embed_ctx = &adapter,
    .embed_fn = ai.embedding.Adapter.embed };
```

Writes use `index.add(.{ .tenant_id = … }, id, text, source, vector)`; a dimension mismatch returns `error.DimensionMismatch` instead of truncating or zero-padding.

### Parallel tool calls

Models often emit several independent calls per turn. Execution stays sequential unless both conditions hold:

- the `Agent`/`Spec` has `io` (`std.Io`) set;
- every tool in the batch declares `parallel_safe = true`.

All or nothing: one tool without the declaration keeps the whole batch sequential. `Spec.max_parallel_tools` bounds concurrency (default 8, `0` = uncapped); batches run in waves, so slow tools create backpressure. Guard checks and the approval hook run serially before spawning (guard counters are not atomic, and hooks are caller code). Results are joined and written back in `tool_call` order, and `on_tool` plus audit records follow the same order.

The contract for `parallel_safe = true`: the handler is thread-safe and allocates everything from `ctx.allocator`. The agent gives each call its own context copy and arena (`dispatchWith` sets `deadline_ms`, and the request arena is not thread-safe), then keeps only serialized text. Shared `userdata` / `backend_ptr` remain your responsibility; a single-connection DB tool must not be marked parallel-safe.

### Core and ops boundary

`zmodu.ai` has two kinds of modules; do not mix them.

- Core (`Agent`, `skill`, `provider`, `workflow`, `guard`, `budget`, `memory`, `retriever`, `quota`, `context`, supply layer) knows no business nouns and depends only on `SkillContext`. `ai.http` is an adapter; core does not import HTTP.
- Ops extensions (`src/ai/ops/`, reached as `ai.ops.*`): `business`, `actions`, `admin`, `alerts`, `kpi`, `recon`, `refund`, `ticket`, `sla`, `notify`, `bridge`, `trigger`, `schedule`, `approval_api`, `approval_store`. They bind directly to `data.sqlx` and concrete tables; rewrite or replace them per business. Core must not import them (`check-production.sh` enforces this), and the built-in catalog is registered through `ai.ops.builtin.registerBuiltinCatalog(&registry)`. Top-level paths such as `ai.alerts` still work.

`approval`, `risk`, `diagnose` and `reporter` remain under `src/ai/`, but core (`agent`, `skill`, `workflow`, `llm`, `proposal`) depends only on `ai/ports.zig`. `ports.ApprovalPort` and `ports.RiskPort` are behavioural interfaces; value types (`ApprovalStatus`, `RiskResult`, `EvidenceBlock`, …) live there too. Concrete engines attach through adapters:

```zig
var flow = ai.approval.ApprovalFlow.init(allocator, &backend, policy);
wf.approval_flow = flow.toPort();
p.risk = review.toPort();
```

`check-production.sh` rejects top-level imports of these four engines from core files; imports inside test blocks are allowed.

## 8. Observability

- `zmodu.ai.observability.AiMetrics` merges `WorkflowMetrics`, `AgentMetrics` and `TokenQuota` into one Prometheus document; attach the pointers and names and a single `/metrics` endpoint covers the AI stack.
- `zmodu.ai.run_audit.RunAuditStore` stores workflow, agent and approval run history (`GET /api/ai/runs`, tenant-scoped). Each row carries `prompt_tokens` / `completion_tokens` (`Agent` accumulates them; `recordRunWithUsage` serves custom entry points), making it the persistent usage ledger. In-memory `TokenQuota` is lost on restart, so billing and settlement read this table. `migrate()` adds missing columns by consulting the catalog.
- `mgr.listProviders(allocator)` snapshots status, failures and call counts per provider/key; `enableKey` and `enableProvider` allow manual intervention.
- Model-free debugging: inject fake JSON through `LlmPolicyCtx.json_fn` (`examples/llm-policies`), or point `AiProvider` at a local mock OpenAI endpoint (the agent end-to-end tests do this).

## Boundaries

No unbounded autonomous loop: every run has a step cap, a budget and cooperative cancellation. Not built: shell, arbitrary URL fetching, raw SQL writes, cross-tenant access, a vector store (`Retriever` is the seam). Administrative skills stay out of any registry exposed through MCP or external callers.
