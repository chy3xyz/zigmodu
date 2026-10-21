# LLM Policies

`zmodu.ai.llm` turns a model into a decision callback for approvals, risk, diagnosis and workflow quality gates. This page wires a provider into `ApprovalFlow`, `RiskReview`, `DiagnosisFlow` and `Workflow.reflection`.

The runnable example is [`examples/llm-policies`](../../examples/llm-policies).

## 1. Provider

All policies share one `AiProvider` (OpenAI-compatible chat completions).

```zig
const zmodu = @import("zmodu");

// HTTPS goes through std.http.Client; the last argument is the timeout in ms
var http = zmodu.http.HttpClient.init(allocator, io, 4, 30000);
defer http.deinit();

// endpoint is the full chat/completions URL; api_key is the whole Authorization header
var provider = zmodu.ai.AiProvider.init(
    allocator,
    &http,
    "https://api.openai.com/v1/chat/completions", // or DeepSeek, vLLM, Ollama-compatible
    "Bearer sk-...",                              // inject from env; never hardcode
    "gpt-4o-mini",
);
```

Read endpoint, key and model from `init.environ_map` in production (see `docs/BEST_PRACTICES.md`).

## 2. LlmPolicyCtx

```zig
var policy_ctx = zmodu.ai.llm.LlmPolicyCtx{
    .provider = &provider,   // real model
    // .json_fn = ...        // inject a fake for tests; defaults to the provider
    .system_hint = "Company policy: any amount above 100k needs CFO sign-off.",
    // .retriever = ...,     // optional RAG (see §5)
    // .retrieval_query = "approval policy for large orders",
};
```

Every policy callback reads it from `SkillContext.userdata`:

```zig
var ctx = zmodu.ai.SkillContext{
    .allocator = allocator,
    .tenant_id = 1,          // used for isolation in multi-tenant apps
    .userdata = &policy_ctx, // required
};
```

## 3. Attaching policies

### Approval

```zig
var approval = zmodu.ai.approval.ApprovalFlow.init(allocator, &backend, zmodu.ai.llm.llmApprove);
approval.outbox = &outbox;      // optional audit write-back
approval.on_escalated = hook;   // optional human queue (see AI_ORCHESTRATION.md)
var result = try approval.submit(allocator, &ctx, "order-42", 150000, &steps);
```

The model returns `{"decision":"approve|escalate|reject","note":"..."}`. A model failure or invalid JSON escalates; it never approves silently.

### Risk

```zig
var risk = zmodu.ai.risk.RiskReview.init(allocator, &backend);
risk.rules = &rules;                       // SQL rules accumulate a score
risk.decide = zmodu.ai.llm.llmRiskDecide;  // LLM verdict
var out = try risk.review(allocator, &ctx, "order-42");
```

### Diagnosis

```zig
var diag = zmodu.ai.diagnose.DiagnosisFlow.init(allocator, &backend, zmodu.ai.llm.llmDiagnose);
diag.evidence_queries = &queries; // evidence SQL feeds the prompt
diag.outbox = &outbox;
var res = try diag.run(allocator, &ctx, .{
    .source = "alert",
    .subject = "orders",
    .severity = .critical,
    .description = "...",
});
```

### Workflow quality gate

```zig
wf.reflection = zmodu.ai.llm.llmVerify; // does the output meet the goal?
wf.goal = "Produce a Markdown report containing the refund total";
wf.max_reviews = 2;                     // re-run limit
```

## 4. Testing without a model

`LlmPolicyCtx.json_fn` replaces the model call, so policy wiring is testable offline (framework tests do this):

```zig
const FakeJson = struct {
    fn f(_: *anyopaque, a: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!std.json.Value {
        var obj = std.json.ObjectMap{};
        try obj.put(a, try a.dupe(u8, "decision"), .{ .string = try a.dupe(u8, "approve") });
        return .{ .object = obj };
    }
};
var policy_ctx = zmodu.ai.llm.LlmPolicyCtx{ .json_fn = FakeJson.f };
var ctx = zmodu.ai.SkillContext{ .allocator = allocator, .userdata = &policy_ctx };
// Call approval.submit / risk.review / diag.run as usual and assert the outcome.
```

## 5. RAG context

`LlmPolicyCtx.retriever` injects the top-k chunks (policies, past cases, playbooks) into every policy prompt:

```zig
var policy_ctx = zmodu.ai.llm.LlmPolicyCtx{
    .provider = &provider,
    .retriever = my_retriever, // implements zmodu.ai.retriever.Retriever
    .retrieval_query = "approval policy for large orders",
    .top_k = 3,
};
```

`KeywordRetriever` is a built-in demo; production uses an application-owned vector store.

## 6. End-to-end smoke

```bash
cd examples/llm-policies
LLM_ENDPOINT=https://api.openai.com/v1/chat/completions \
LLM_API_KEY='Bearer sk-...' \
LLM_MODEL=gpt-4o-mini \
zig build run
```

The example runs approval (`llmApprove`), risk (`llmRiskDecide`), diagnosis (`llmDiagnose`) and the quality gate (`llmVerify`), printing each real model response. Without a key it falls back to `json_fn` demos, so `zig build test` stays offline and green.

## 7. Behaviour contracts

| Policy | Model response | Failure fallback |
|--------|----------------|------------------|
| `llmApprove` | `{"decision":"approve\|escalate\|reject","note":"..."}` | `escalated` plus note |
| `llmRiskDecide` | `{"decision":"approve\|escalate\|reject"}` | `escalate` |
| `llmDiagnose` | `{"summary","causes":[],"actions":[]}` | `error.MalformedLlmResponse` |
| `llmVerify` | `{"pass":bool,"reason":"..."}` | `false`, triggering a re-run or escalation |

All policies honour the deadline (`SkillContext.checkDeadline` / `deadline_ms`), so a stuck model cannot pin a task. The security rule is uniform: when unsure, escalate; never approve silently.

## 8. AiKeyManager: provider and key rotation

`zmodu.ai.AiKeyManager` sits above `AiProvider` and is split across these files:

| File | Responsibility |
|------|----------------|
| `ai/key_pool.zig` | Key pool: round-robin healthy keys, exponential cooldown on 429/quota, automatic disable after repeated 401, recovery and observation |
| `ai/cooldown_store.zig` | Cooldown storage interface: in-memory (default) and Redis (cross-process, fail-open with a local mirror) |
| `ai/provider_registry.zig` | Provider registry: endpoint, key pool, model routing and fallback chain |
| `ai/provider.zig` | Bound pool: after `bindKeyPool`, `chat`/`chatWith` retry once with another key on 401/403/402/429 |
| `ai/module.zig` | `AiKeyManager`: `ProviderConfig` (keys plus lifecycle) and the `providerFor` constructor |

Bookkeeping runs under `std.Io.Mutex` for microseconds; HTTP calls hold no lock, so concurrency is not reduced.

```zig
var mgr = zmodu.ai.AiKeyManager.init(allocator, io);
defer mgr.deinit();
try mgr.applyConfig(&.{
    .{ .name = "deepseek", .endpoint = "https://api.deepseek.com/v1/chat/completions",
       .api_keys = &.{ "sk-a", "sk-b" }, .models = &.{"deepseek-v4-flash"},
       .fallback_providers = &.{"openai"} },
    .{ .name = "openai", .endpoint = "https://api.openai.com/v1/chat/completions",
       .api_keys = &.{"sk-o1"}, .models = &.{"deepseek-v4-flash"} },
});

var provider = try mgr.providerFor(allocator, &http, "deepseek-v4-flash");
// On 401/403/402/429 the provider switches to the next healthy key and retries once;
// repeated 401 disables that key; an exhausted pool falls back to the openai provider.
// Report back on the provider itself (it may have rotated internally):
// provider.reportSuccess() / provider.reportError(.rate_limit)
```

Error classification: `KeyErrorKind.fromHttpStatus(401/403/402/429/5xx)`, or pass `.auth`, `.rate_limit`, `.quota`, `.server`, `.network` or `.timeout` manually. `mgr.listProviders(allocator)` returns a status, failure and call-count snapshot per provider and key; `enableKey` / `enableProvider` allow manual intervention.

### Cross-process cooldown

One process with many fibers uses `MemoryCooldownStore` and needs no dependencies. When several instances share a key set, put cooldown state in Redis; otherwise a key cooled down on instance A keeps taking 429s on B through N, and the 401 disable threshold is multiplied by the instance count.

```zig
var redis_store = try zmodu.ai.RedisCooldownStore.init(allocator, io, &redis_client);
defer redis_store.deinit();
var store = redis_store.asStore();
mgr.setSharedStore(&store); // pools registered afterwards use Redis cooldowns
```

The implementation uses `SET key 1 EX ttl` (cooldown and disable expire by TTL, no clock alignment), `INCR` plus `EXPIRE` for failure counts, and `DEL` for recovery. If Redis is unreachable it fails open to the local mirror and logs a warning, matching the `RedisRateLimiter` precedent, so key rotation is never blocked by infrastructure. Keys look like `zmodu:llm:key:<provider>:<idx>`.
