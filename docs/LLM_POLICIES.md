# LLM 策略真实接线（LLM-Powered Policies）

> `zigmodu.ai.llm` 提供开箱即用的 LLM-backed 策略：审批、风控、异常归因、
> workflow 质量门。本文是**真实接线**指南——从 `AiProvider` 初始化到把
> 策略挂进 `ApprovalFlow` / `RiskReview` / `DiagnosisFlow` / `Workflow.reflection`，
> 含完整代码与验证方法。配套可编译示例：[`examples/llm-policies`](../examples/llm-policies)。

## 1. 前置：AiProvider

所有 LLM 策略共用同一个 `AiProvider`（OpenAI 兼容 chat completions）：

```zig
const zigmodu = @import("zigmodu");

// HTTP 客户端（HTTPS 走 std.http.Client；超时毫秒）
var http = zigmodu.http.HttpClient.init(allocator, io, 4, 30000);
defer http.deinit();

// endpoint 是完整的 chat/completions URL；api_key 是 Authorization 头的完整值
var provider = zigmodu.ai.AiProvider.init(
    allocator,
    &http,
    "https://api.openai.com/v1/chat/completions", // 或 DeepSeek / vLLM / Ollama 兼容端点
    "Bearer sk-...",                              // 环境变量注入，勿硬编码
    "gpt-4o-mini",                                // 或 deepseek-chat 等
);
```

生产建议：endpoint / key / model 从 `init.environ_map` 读取（见 `docs/BEST_PRACTICES.md`）。

## 2. LlmPolicyCtx：策略共享配置

```zig
var policy_ctx = zigmodu.ai.llm.LlmPolicyCtx{
    .provider = &provider,          // 真实模型
    // .json_fn = ...               // 测试时注入 fake（不填则用 provider）
    .system_hint = "公司审批政策：单笔>10万必须 CFO 签字。", // 附加 system 指导
    // .retriever = ...,            // 可选 RAG（见 §5）
    // .retrieval_query = "approval policy for large orders",
};
```

每个策略回调都从 `SkillContext.userdata` 取 `LlmPolicyCtx`：

```zig
var ctx = zigmodu.ai.SkillContext{
    .allocator = allocator,
    .tenant_id = 1,          // 多租户示例会把它用于隔离
    .userdata = &policy_ctx, // ← 关键
};
```

## 3. 挂进各 Flow

### 审批（ApprovalFlow）

```zig
var approval = zigmodu.ai.approval.ApprovalFlow.init(allocator, &backend, zigmodu.ai.llm.llmApprove);
approval.outbox = &outbox;                       // 审计写回（可选）
approval.on_escalated = ...;                     // 转人工入队（可选，见 AI_ORCHESTRATION.md）
var result = try approval.submit(allocator, &ctx, "order-42", 150000, &steps);
```

模型返回 `{"decision":"approve|escalate|reject","note":"..."}`；
**模型失败 / JSON 非法时安全回退 `escalated`**，绝不静默放行。

### 风控（RiskReview）

```zig
var risk = zigmodu.ai.risk.RiskReview.init(allocator, &backend);
risk.rules = &rules;             // SQL 规则累加风险分
risk.decide = zigmodu.ai.llm.llmRiskDecide;  // LLM 决策
var out = try risk.review(allocator, &ctx, "order-42");
```

### 异常归因（DiagnosisFlow）

```zig
var diag = zigmodu.ai.diagnose.DiagnosisFlow.init(allocator, &backend, zigmodu.ai.llm.llmDiagnose);
diag.evidence_queries = &queries; // 证据 SQL → prompt
diag.outbox = &outbox;
var res = try diag.run(allocator, &ctx, .{ .source = "alert", .subject = "orders", .severity = .critical, .description = "..." });
```

### Workflow 质量门（Workflow.reflection）

```zig
wf.reflection = zigmodu.ai.llm.llmVerify;  // 模型判断最终输出是否达标
wf.goal = "产出一份含退款金额的 Markdown 报告";
wf.max_reviews = 2;                        // 不达标重跑上限
```

## 4. 验证：无模型跑通（json_fn 注入）

`LlmPolicyCtx.json_fn` 让策略在**没有真实模型**时也可测（框架自带测试即用此法）：

```zig
const FakeJson = struct {
    fn f(_: *anyopaque, a: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!std.json.Value {
        var obj = std.json.ObjectMap{};
        try obj.put(a, try a.dupe(u8, "decision"), .{ .string = try a.dupe(u8, "approve") });
        return .{ .object = obj };
    }
};
var policy_ctx = zigmodu.ai.llm.LlmPolicyCtx{ .json_fn = FakeJson.f };
var ctx = zigmodu.ai.SkillContext{ .allocator = allocator, .userdata = &policy_ctx };
// 之后正常调 approval.submit / risk.review / diag.run —— 断言结果即可。
```

## 5. 可选：RAG 业务上下文

`LlmPolicyCtx.retriever` 把 top-k 检索块注入策略 prompt（政策、历史、playbook）：

```zig
var policy_ctx = zigmodu.ai.llm.LlmPolicyCtx{
    .provider = &provider,
    .retriever = my_retriever,               // 实现 zigmodu.ai.retriever.Retriever 接口
    .retrieval_query = "approval policy for large orders",
    .top_k = 3,
};
// 框架自带 KeywordRetriever 可做 demo；生产接自己的向量库（应用侧）。
```

## 6. 端到端冒烟

```bash
# examples/llm-policies —— 设置真实凭据后运行
cd examples/llm-policies
LLM_ENDPOINT=https://api.openai.com/v1/chat/completions \
LLM_API_KEY='Bearer sk-...' \
LLM_MODEL=gpt-4o-mini \
zig build run
```

程序会依次跑：审批（llmApprove）→ 风控（llmRiskDecide）→ 诊断（llmDiagnose）→
质量门（llmVerify），打印每个策略的真实模型响应。未配置 key 时优雅降级为
`json_fn` 演示（escalate/approve 回退），保证 `zig build test` 恒绿。

## 7. 行为契约速查

## 8. AiKeyManager：provider + key 轮换（高并发）

`zigmodu.ai.AiKeyManager` 是 `AiProvider` 的上游供给层，分四层文件：

| 文件 | 职责 |
|------|------|
| `ai/key_pool.zig` | key 池：round-robin 健康 key、429/配额指数冷却退避、连续 401 自动禁用、恢复与观测 |
| `ai/cooldown_store.zig` | 冷却状态存储接口：内存实现（默认）+ Redis 实现（跨进程、fail-open 本地镜像回退） |
| `ai/provider_registry.zig` | provider 注册表：endpoint + key 池 + 模型路由 + fallback provider 链（provider 轮换） |
| `ai/provider.zig` | 挂池：`bindKeyPool` 后 `chat`/`chatWith` 在 401/403/402/429 自动换 key 重试一次 |
| `ai/module.zig` | `AiKeyManager`：`ProviderConfig`（api_keys + 生命周期）+ `providerFor` 便捷构造 |

簿记用 `std.Io.Mutex` 保护（微秒级），HTTP 调用不持锁，可高并发。

```zig
var mgr = zigmodu.ai.AiKeyManager.init(allocator, io);
defer mgr.deinit();
try mgr.applyConfig(&.{
    .{
        .name = "deepseek",
        .endpoint = "https://api.deepseek.com/v1/chat/completions",
        .api_keys = &.{ "sk-a", "sk-b" },
        .models = &.{"deepseek-v4-flash"},
        .fallback_providers = &.{"openai"},
    },
    .{
        .name = "openai",
        .endpoint = "https://api.openai.com/v1/chat/completions",
        .api_keys = &.{"sk-o1"},
        .models = &.{"deepseek-v4-flash"},
    },
});

var provider = try mgr.providerFor(allocator, http, "deepseek-v4-flash");
// chat/chatWith 遇 401/403/402/429 自动换池内下一个健康 key 并重试一次；
// 连续 401 会禁用该 key，池耗尽时自动降级到 openai provider。
// 反馈用 provider 自身（可能已内部换 key）：provider.reportSuccess() /
// provider.reportError(.rate_limit)，不要用旧 lease 的 onSuccess（会重置失败 key）。
```

错误分类：`KeyErrorKind.fromHttpStatus(401/403/402/429/5xx)`，或手动传
`.auth` / `.rate_limit` / `.quota` / `.server` / `.network` / `.timeout`。
观测：`mgr.listProviders(io, allocator)` 返回每个 provider/key 的
status/failures/调用与错误计数快照；`enableKey` / `enableProvider` 支持人工介入。

### 跨进程 cooldown（多实例共享同一批 key）

单实例（一个进程多 fiber）默认走内存 `MemoryCooldownStore`，零依赖。水平扩容
多实例共享同一批 key 时，用 Redis 协调冷却/禁用状态（否则实例 A 冷却的 key，
实例 B–N 不知情继续打 429，且 401 禁用阈值会被放大 N 倍）：

```zig
var redis_store = try zigmodu.ai.RedisCooldownStore.init(allocator, io, &redis_client);
defer redis_store.deinit();
var store = redis_store.asStore();
mgr.setSharedStore(&store); // 之后注册的 provider 池都走 Redis 冷却
```

实现：`SET key 1 EX ttl`（冷却/禁用按 TTL 过期，无需时钟对齐）、
`INCR + EXPIRE`（失败计数）、`DEL`（恢复）；Redis 不可用时 **fail-open**
回退本地镜像并 warn（对齐 `RedisRateLimiter` 先例），key 轮换不会因基础设施
故障而阻塞。key 形如 `zigmodu:llm:key:<provider>:<idx>`。

| 策略 | 模型返回 | 失败回退 |
|------|----------|----------|
| `llmApprove` | `{"decision":"approve\|escalate\|reject","note":"..."}` | `escalated` + note |
| `llmRiskDecide` | `{"decision":"approve\|escalate\|reject"}` | `escalate` |
| `llmDiagnose` | `{"summary","causes":[],"actions":[]}` | 返回 `error.MalformedLlmResponse` |
| `llmVerify` | `{"pass":bool,"reason":"..."}` | `false`（触发重跑/升级） |

安全原则：**拿不准就转人工，绝不静默批准**。所有策略都遵守 deadline
（`SkillContext.checkDeadline` / `deadline_ms`），长任务不会被模型拖死。
