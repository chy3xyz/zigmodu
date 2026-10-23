# AI Chat and Agent Runtime

`zmodu.ai` provides an OpenAI-compatible chat module and a tool-calling agent runtime: providers, streamed output, memory, token budget and audit, with every tool call behind a fail-closed gate.

## Scope

- Covers `zmodu.ai` and the `zmodu scaffold --with-aichat` / `--with-agent` output.
- Writing framework code? Start at [AGENTS.md](../../AGENTS.md).
- `zmodu mcp` is a codegen MCP server; it is unrelated to the runtime `SkillRegistry`.
- Business integration end to end (KeyManager, workflows, custom skills, MCP): [AI_DEV_GUIDE.md](./AI_DEV_GUIDE.md).

## Core API

| Type | Role |
|------|------|
| `AiProvider` | OpenAI-compatible chat; `chatWith(..., .{ .tools_json })` parses `tool_calls`; `chatStream` reads SSE `data:` via `requestStream`, falling back to buffered output |
| `SkillRegistry` | Registers Zig skills; `dispatch` / `dispatchAllowed` / `dispatchWith` (allowlist + cooperative timeout); `toOpenAiFunctionsAlloc` |
| `Agent` | ReAct loop over `provider` + `registry`; `hooks` (including the `on_tool_request` human gate), `metrics`, `audit`, `retriever`, `quota`, `tool_timeout_ms` |
| `MemoryStore` | In-process memory keyed by namespace, category and detail; `dumpJson` / `loadJson`; `saveToFile` / `loadFromFile` |
| `AgentAuditLog` | Ring-buffer audit of tool calls and the run lifecycle |
| `Retriever` | Optional RAG interface; `KeywordRetriever` is a demo, not a vector store |
| `TokenQuota` | Per-tenant token quota skeleton (`tryConsume` / `record`, Prometheus export) |

```zig
var registry = zmodu.ai.SkillRegistry.init(allocator, io);
defer registry.deinit();
try registry.register(.{
    .name = "ping",
    .description = "pong",
    .parameters = &.{},
    .action = .read,      // .read / .propose / .execute (default .execute, the strictest)
    .handler = ping,
});
// Build through AgentSpec: a bare `Agent{}` without `.guard` is unbounded.
var guard = zmodu.ai.Guard.init(.{ .allow = &.{"ping"}, .allow_execute = false });
var spec = zmodu.ai.AgentSpec{
    .name = "ping-agent",  // identity for logs and metric labels
    .provider = &provider,
    .skills = &registry,
    .system_prompt = "You are a ping agent.",
    .guard = &guard,
    .allowlist = &.{"ping"},  // tool-name allowlist: the second gate
    .tool_timeout_ms = 5_000, // cooperative; handlers should call checkDeadline
};
var agent = spec.build();
var skill_ctx = zmodu.ai.SkillContext{ .allocator = allocator };
var result = try agent.run(allocator, "ping the system", &skill_ctx, 5);
defer result.deinit(allocator);
```

Gate, action-class and default-deny rules: [`AGENT_RUNTIME.md`](../reference/AGENT_RUNTIME.md). There is no default shell and no outbound MCP client; register a controlled handler when you need one.

## Generated chat module

```bash
zmodu scaffold --sql schema.sql --name myapp --with-aichat
```

Generated files under `src/modules/ai/chat/`: `provider.zig` and `sse.zig` re-export the framework types; `service.zig` holds multi-turn chat, memory and budget; `api.zig` holds the routes; `model.zig` and `persistence.zig` are the `AiConversation` / `AiMessage` ORM pair.

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/ai/chat/send?conversationId=N` | Send a message, return the reply |
| POST | `/ai/chat/stream?conversationId=N` | SSE stream (`Accept: text/event-stream`) |
| GET | `/ai/chat/conversations?pageNo=1&pageSize=10` | List conversations |
| GET | `/ai/chat/messages?conversationId=N&pageNo=1&pageSize=20` | Message history |
| POST | `/ai/chat/conversations?title=Chat` | Create a conversation |
| DELETE | `/ai/chat/conversations?id=N` | Delete a conversation and its messages |

## Provider setup

`HttpClient` handles `https://` through `std.http.Client` with system CAs, and pools plain `http://` connections.

```zig
var http_client = zmodu.http.HttpClient.init(allocator, io, 10, 30000);
defer http_client.deinit();

var ai_provider = ai_chat.provider.AiProvider.init(
    allocator, &http_client,
    "https://api.deepseek.com/v1/chat/completions",
    "Bearer sk-your-key",
    "deepseek-v4-flash",
);
defer ai_provider.deinit();
try ai_provider.enableRateLimit(io, 60); // requests per second
ai_chat_svc.setProvider(&ai_provider);
ai_chat_svc.setSystemPrompt("You are a helpful assistant.");
```

### Output-token parameter

`max_output_tokens` is sent as `max_tokens` by default, which is what DeepSeek, Qwen and self-hosted servers expect. OpenAI's reasoning-era models (`gpt-5*`, `gpt-6*`, `o1`/`o3`/`o4`) reject that field with `400 Unsupported parameter: 'max_tokens'` and only accept `max_completion_tokens`. `token_limit_param = .auto` (the default) chooses by model name, including gateway-qualified names such as `openrouter/openai/gpt-5-mini`.

```zig
ai_provider.token_limit_param = .auto;                   // default: pick by model name
ai_provider.token_limit_param = .max_completion_tokens;  // pin for a gateway that renamed the model
ai_provider.token_limit_param = .max_tokens;             // old field for an OpenAI-compatible proxy
```

## Server wiring

The generated `AiChatApi` is a ComptimeRouter module (`pub const routes`), mounted with `scope.mountAll`.

```zig
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const ai_chat = @import("modules/ai/chat/module.zig");

    var db_client = zmodu.data.Client.init(allocator, io, .{ .driver = .sqlite, .sqlite_path = "app.db" });
    defer db_client.deinit();
    try db_client.connect();
    var backend = zmodu.data.SqlxBackend{ .allocator = allocator, .client = &db_client };
    var ai_chat_p = ai_chat.persistence.AiChatPersistence.init(backend);
    var ai_chat_svc = ai_chat.service.AiChatService.init(allocator, &ai_chat_p);
    // provider + memory setup as above
    var server = zmodu.http.Server.init(io, allocator, 8080);
    defer server.deinit();
    var ai_chat_api = ai_chat.api.AiChatApi.init(&ai_chat_svc);
    const AppState = struct {};
    var app_state: AppState = .{};
    var router = zmodu.http.Router(AppState).init(io, allocator, &server, &app_state);
    defer router.deinit();
    try router.scope("").mountAll(.{.{ .Mod = @TypeOf(ai_chat_api), .state = &ai_chat_api }});
    try server.start();
}
```

Auth wiring for those routes: `docs/reference/ROUTE_TABLE.md` §7.

## Context and token budget

`send()` loads history and orders the prompt so the mutable part stays last. DeepSeek V4 detects the repeated prefix automatically.

```text
[system prompt]  static, always cached
[memories]       semi-static, cached per conversation
[history 0..N]   dynamic, stable prefix
[user query]     the only uncached part
```

```zig
ai_chat_svc.context_limit = 128000; // context window, default 128K
ai_chat_svc.max_context = 20;       // history messages loaded per turn
// Over budget, summarizeHistory() compresses history to 200-char summaries.
ai_provider.max_output_tokens = 4096;
ai_provider.temperature = 0.7;
```

## Memory

Keys use `namespace:category:detail`. Every call carries tenant and user, so recall cannot cross them. Caller frees each returned key and value, then the result slice.

```zig
var memory = zmodu.ai.MemoryStore.init(allocator, io);
defer memory.deinit();
try memory.remember("user:pref:lang", "en", tenant_id, user_id);
var recalled = try memory.recall(allocator, "user:pref", tenant_id, user_id);
// Free each e.key / e.value, then recall.deinit(allocator).
const block = try memory.formatContext(allocator, "user:pref", tenant_id, user_id, 10);
defer allocator.free(block);

memory.forget("user:pref:lang", tenant_id, user_id);
const snap = try memory.dumpJson(allocator); // or saveToFile / loadFromFile
defer allocator.free(snap);
try memory.loadJson(snap);
memory.max_entries = 50000; // default 10000, LRU eviction
```

Never feed `formatContext` output to an agent: `recall` treats tenant `0` as a wildcard. Agent paths use `Agent.memory` and `recallBlockAlloc` instead.

## Agent observability

```zig
var agent = spec.build();
agent.audit = &audit_log; // *AgentAuditLog

agent.hooks.on_tool_request = struct {
    fn f(_: ?*anyopaque, name: []const u8, _: []const u8) zmodu.ai.ToolApproval {
        if (std.mem.eql(u8, name, "delete_all")) return .deny;
        return .allow;
    }
}.f;

// agent.metrics: runs / steps / tool_calls / tool_errors / max_steps_hits
const prom = try agent.metrics.toPrometheusFormat(allocator, "ops");
defer allocator.free(prom);
```

`agent.retriever` takes any `zmodu.ai.Retriever`; `KeywordRetriever` is the built-in demo (`add` chunks, then `asRetriever().retrieve`).

## Streaming

Scaffold module: pass `null` for a single JSON reply, or an `SseWriter` for SSE.

```zig
const msg = try ai_chat_svc.send(conv_id, "Hello", null);
var sse = try zmodu.http.SseWriter.init(ctx);
_ = try ai_chat_svc.send(conv_id, "Tell me a story", &sse);
try sse.done();
```

Framework level: `Agent.run` pushes provider deltas to `hooks.on_delta`, and `ai.stream_sse.DeltaSse(W)` bridges that callback to any SSE sink. Reference: `examples/ai-ops` (`POST /api/ai/chat/stream`, with an in-process mock LLM test).

```zig
var sse = try zmodu.http.sse(ctx);
var bridge = ai.stream_sse.DeltaSse(@TypeOf(sse)).init(allocator, &sse);
agent.hooks.ctx = &bridge;
agent.hooks.on_delta = @TypeOf(bridge).onDelta;

var result = try agent.run(allocator, goal, &skill_ctx, 8);
defer result.deinit(allocator);
try sse.sendData(try std.json.Stringify.valueAlloc(allocator, .{
    .answer = result.answer, .steps = result.steps,
}, .{}));
try sse.done();
```

`DeltaEvent` (`src/ai/stream_sse.zig`) tags each `data:` payload: `{"content":{"delta":"Hel"}}` per content delta, `{"reasoning":{...}}` for chain-of-thought, `{"tool":{"name":...,"arguments_delta":...}}` for streamed `tool_calls`, and `{"done":{}}` plus SSE `event: done` on upstream `[DONE]`.

`SseWriter` also has `send` (alias of `sendEvent`), `sendData` for unnamed events, `sendMultiLine`, `setId`, `sendRetry(ms)`, `heartbeat` (`": ping"`) and `sendError`.

## Metrics and concurrency

```zig
const m = ai_provider.metrics; // requests, prompt/completion tokens, cache hit/miss, rate_limited
const ratio = ai_provider.cacheHitRatio(); // 0.0 - 1.0
const tokens = zmodu.ai.estimateTokens("Hello, world");
// ~4 Latin chars per token, ~1 CJK char per token, within ±20% of DeepSeek
```

`AiProvider` is safe across fibers (pooled connections under `HttpClient`), `RateLimiter` guards itself with a mutex, `MemoryStore` follows the `SkillRegistry` pattern, `estimateTokens` is a pure function, and `SseWriter` serves one stream from one fiber.

Backends: DeepSeek V4 (Pro / Flash, recommended, automatic prefix caching), OpenAI `/v1/chat/completions`, Ollama `/api/chat` on localhost, and any OpenAI-compatible endpoint.

## Scheduler bridge (AI to cron)

The bridge is bounded and one-directional: an agent may schedule a pre-registered named task, and the model never supplies code.

```zig
const tasks = [_]ai.ScheduledTask{
    .{ .name = "daily_report", .description = "Build the daily report", .task = dailyReport, .context = &app },
    .{ .name = "health_check", .description = "Check service health", .task = healthCheck, .context = &app },
};
var scheduler = zmodu.cron.Scheduler.init(allocator, io);
try scheduler.start(); // ticks once per second, minute-granularity cron
defer scheduler.stop();

var sched_ctx = ai.schedule.ScheduleCtx{ .scheduler = &scheduler, .tasks = &tasks };
try ai.registerScheduleSkills(&registry);
// Before each run: skill_ctx.userdata = @ptrCast(&sched_ctx)
```

The agent can then call `list_schedulable_tasks`, `schedule_job { "task": "daily_report", "expr": "0 9 * * *" }`, `list_jobs` and `cancel_job`.

- `schedule_job` accepts only a registered task name plus a cron expression. Unknown names return `error.TaskNotFound`.
- The reverse direction needs no bridge: call `AiProvider.chat` / `chatStream` inside a scheduler task. Mind the thread-level io rules in [ZMODU_NOTES.md](../archive/status/ZMODU_NOTES.md) item 3.
- `ScheduledTask.TaskScheduler` (the old placeholder) is removed; scheduling is `Scheduler` plus `zmodu.ai.registerScheduleSkills`.

Built-in business skills (`db.query`, `entity.lookup`, `entity.list`, and the write/admin catalogs): [AI_SKILLS.md](./AI_SKILLS.md).
