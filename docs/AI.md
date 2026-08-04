# AI Chat Module — 使用指南

> 本文档描述 **LLM 对话 / Agent 产品能力**（`zmodu scaffold --with-aichat` / `--with-agent`）。  
> 写 ZigModu 框架代码的 coding agent 请读：[AGENTS.md](../AGENTS.md)。  
> `zmodu mcp` 是 **codegen** MCP 服务端，与运行时 `SkillRegistry` 正交。
> 在业务系统里完整接入 AI（KeyManager / Agent / Workflow / 自定义技能 / MCP）
> 请读：[AI_DEV_GUIDE.md](AI_DEV_GUIDE.md)。

## 核心 API（zigmodu.ai）

| 类型 | 作用 |
|------|------|
| `AiProvider` | OpenAI 兼容 chat；`chatWith(..., .{ .tools_json })`；解析 `tool_calls`；`chatStream`（`requestStream` + SSE `data:`；失败则缓冲回退） |
| `SkillRegistry` | 注册 Zig skill；`dispatch` / `dispatchAllowed` / `dispatchWith`（白名单 + 协作超时）；`toOpenAiFunctionsAlloc` |
| `Agent` | ReAct：`provider` + `registry` → `run`；`hooks`（含 `on_tool_request` 人机门）/ `metrics` / `audit` / `retriever` / `quota`；`tool_timeout_ms` |
| `MemoryStore` | 进程内记忆（复合键）；`dumpJson`/`loadJson`；`saveToFile`/`loadFromFile` |
| `AgentAuditLog` | 工具调用 / run 生命周期环形审计 |
| `Retriever` | RAG 可选接口；自带 `KeywordRetriever` 演示（非向量库） |
| `TokenQuota` | 租户 token 配额骨架（`tryConsume` / `record` / Prometheus） |

```zig
var registry = zigmodu.ai.SkillRegistry.init(allocator, io);
defer registry.deinit();
try registry.register(.{ .name = "ping", .description = "pong", .parameters = &.{}, .handler = ping });

var agent = zigmodu.ai.Agent{
    .provider = &provider,
    .registry = &registry,
    .allowlist = &.{"ping"}, // 安全：只允许列出的工具
    .tool_timeout_ms = 5_000, // 协作式超时（handler 应 checkDeadline）
};
var skill_ctx = zigmodu.ai.SkillContext{ .allocator = allocator };
var result = try agent.run(allocator, "ping the system", &skill_ctx, 5);
defer result.deinit(allocator);
```

**刻意不做**：默认任意 shell / 外部 MCP client。需要时自行 `register` 受控 handler。

## 能力状态

| 已落地 | 说明 |
|--------|------|
| Tool calling + ReAct `Agent` | `chatWith` / `tool_calls` ↔ `SkillRegistry` |
| 协作式 skill 超时 | `Tool.timeout_ms` / `Agent.tool_timeout_ms` + `checkDeadline` |
| `chatStream` SSE | `HttpClient.requestStream` + `data:` delta；流式 `tool_calls` 累积；失败缓冲回退 |
| Memory 复合键 + 落盘 | `saveToFile` / `loadFromFile` |
| HttpClient 出站 | `http://` 池化；`https://` 经 `std.http.Client`（系统 CA + TLS 1.3；HTTPS `requestStream` 真增量读循环） |
| Prometheus 指标 | `AiProvider.Metrics` / `AgentMetrics` / `TokenQuota.toPrometheusFormat` |
| 审计 | `Agent.audit = *AgentAuditLog`；scaffold Agent 写入 `ai_agent_run` |
| 人机确认门 | `hooks.on_tool_request` → `ToolApproval.allow/deny` |
| Retriever 注入 | `Agent.retriever` 在 run 时把检索结果并入 system prompt |
| Token 配额 | `TokenQuota` 按 tenant 记用量；`Agent.quota` / chat scaffold `setQuota` |

| 明确推迟 | 说明 |
|----------|------|
| 默认 shell / MCP client | 安全边界；自行注册受控 skill |
| 抢占式 skill 超时 | 当前为协作 + 返回后检查，非取消 in-flight handler |
| 向量库 / embedding | 通过 `Retriever` 自接；框架不内置 |

## 生成项目

```bash
zmodu scaffold --sql schema.sql --name myapp --with-aichat
```

生成结构：

```
src/modules/ai/chat/
├── provider.zig    # AiProvider（re-export zigmodu.ai.AiProvider）
├── sse.zig         # SseWriter（re-export zigmodu.http.SseWriter）
├── service.zig     # 多轮对话 + 记忆 + token 预算
├── api.zig         # REST 端点
├── model.zig       # AiConversation, AiMessage
├── persistence.zig # ORM Repository
└── module.zig      # 模块声明
```

## 初始化 Provider

> `HttpClient` 支持 `https://`（`std.http.Client` + 系统 CA）。生产可直连 DeepSeek/OpenAI；也仍可用本地 TLS 终止代理。

```zig
// 创建 HTTP 客户端（连接池复用；HTTPS 走 std TLS，不进明文池）
var http_client = zigmodu.http.HttpClient.init(allocator, io, 10, 30000);
defer http_client.deinit();

// 初始化 AiProvider
var ai_provider = ai_chat.provider.AiProvider.init(
    allocator,
    &http_client,
    "https://api.deepseek.com/v1/chat/completions",
    "Bearer sk-your-key",
    "deepseek-v4-flash",
);
defer ai_provider.deinit();

// 可选：开启限流（每秒 N 次请求）
try ai_provider.enableRateLimit(io, 60);

// 注入 service（指针；与 Agent 一致）
ai_chat_svc.setProvider(&ai_provider);
ai_chat_svc.setSystemPrompt("你是一个有用的助手");
// 可选：租户配额
// var quota = zigmodu.ai.TokenQuota.init(allocator, io, 1_000_000);
// ai_chat_svc.setQuota(&quota);
```

## 完整 main.zig 示例

```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ai_chat = @import("modules/ai/chat/module.zig");
    var backend = zigmodu.data.SqlxBackend.init(allocator, "sqlite://app.db");
    var ai_chat_p = ai_chat.persistence.AiChatPersistence.init(backend);
    var ai_chat_svc = ai_chat.service.AiChatService.init(allocator, &ai_chat_p);

    // Provider
    var http_client = zigmodu.http.HttpClient.init(allocator, std.testing.io, 10, 30000);
    defer http_client.deinit();
    var ai_provider = ai_chat.provider.AiProvider.init(
        allocator, &http_client,
        "https://api.deepseek.com/v1/chat/completions",
        "Bearer sk-your-key", "deepseek-v4-flash",
    );
    defer ai_provider.deinit();
    try ai_provider.enableRateLimit(std.testing.io, 60);
    ai_chat_svc.setProvider(&ai_provider);
    ai_chat_svc.setSystemPrompt("你是一个有用的助手");

    // Memory（可选）
    var memory = zigmodu.ai.MemoryStore.init(allocator, std.testing.io);
    defer memory.deinit();
    ai_chat_svc.setMemory(&memory);

    // 服务器
    var server = zigmodu.http.Server.init(allocator, std.testing.io, 8080);
    var ai_chat_api = ai_chat.api.AiChatApi.init(&ai_chat_svc);
    try ai_chat_api.registerRoutes(&server.root);
    try server.start();
}
```

## API 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/ai/chat/send?conversationId=N` | 发送消息，返回 AI 回复 |
| POST | `/ai/chat/stream?conversationId=N` | SSE 流式输出（Accept: text/event-stream） |
| GET | `/ai/chat/conversations?pageNo=1&pageSize=10` | 会话列表 |
| GET | `/ai/chat/messages?conversationId=N&pageNo=1&pageSize=20` | 消息历史 |
| POST | `/ai/chat/conversations?title=闲聊` | 创建新会话 |
| DELETE | `/ai/chat/conversations?id=N` | 删除会话 |

## 多轮对话

`send()` 自动加载历史消息构建上下文，按缓存优先顺序排列：

```
[system prompt]  ← 静态，始终缓存
[memories]       ← 半静态，会话内缓存
[history 0..N]   ← 动态但前缀稳定
[user query]     ← 唯一不缓存的部分
```

DeepSeek V4 自动检测重复前缀，命中率通常 90%+。

## Token 预算

```zig
// 配置上下文窗口
ai_chat_svc.context_limit = 128000; // 128K，默认值
ai_chat_svc.max_context = 20;       // 最多加载 20 条历史消息

// 超出预算自动摘要
// summarizeHistory() 将历史压缩为 200 字/条摘要
```

## 跨会话记忆

```zig
var memory = zigmodu.ai.MemoryStore.init(allocator, io);
defer memory.deinit();

// 键格式：namespace:category:detail
try memory.remember("user:pref:lang", "zh", tenant_id, user_id);
try memory.remember("user:pref:style", "简洁", tenant_id, user_id);
try memory.remember("user:fact:role", "admin", tenant_id, user_id);

// 召回（前缀匹配，隔离租户/用户）
var recalled = try memory.recall(allocator, "user:pref", tenant_id, user_id);
defer {
    for (recalled.items) |e| { allocator.free(e.key); allocator.free(e.value); }
    recalled.deinit(allocator);
}
for (recalled.items) |e| {
    std.debug.print("{s} = {s}\n", .{ e.key, e.value });
}

// 格式化注入 system prompt
const ctx = try memory.formatContext(allocator, "user:pref", tenant_id, user_id, 10);
defer allocator.free(ctx);

// 删除（须带 tenant/user，与 remember 同作用域）
memory.forget("user:pref:lang", tenant_id, user_id);

// 快照持久化（应用侧写文件）
const snap = try memory.dumpJson(allocator);
defer allocator.free(snap);
try memory.loadJson(snap);

// 或落盘（cwd 相对路径）
try memory.saveToFile("memory.json");
try memory.loadFromFile("memory.json");

// 容量控制（默认 10000 条，LRU 淘汰）
memory.max_entries = 50000;
```

## Agent 观测

```zig
var agent = zigmodu.ai.Agent{
    .provider = &provider,
    .registry = &registry,
    .allowlist = &.{"ping"},
    .hooks = .{
        .on_tool = struct {
            fn f(_: ?*anyopaque, name: []const u8, ok: bool) void {
                std.log.info("tool {s} ok={}", .{ name, ok });
            }
        }.f,
    },
};
// agent.metrics.runs / steps / tool_calls / tool_errors / max_steps_hits
const prom = try agent.metrics.toPrometheusFormat(allocator, "ops");
defer allocator.free(prom);

// 审计
var audit = try zigmodu.ai.AgentAuditLog.init(allocator, io, 256);
defer audit.deinit();
agent.audit = &audit;

// 人机 / 策略门：拒绝危险工具
agent.hooks.on_tool_request = struct {
    fn f(_: ?*anyopaque, name: []const u8, _: []const u8) zigmodu.ai.ToolApproval {
        if (std.mem.eql(u8, name, "delete_all")) return .deny;
        return .allow;
    }
}.f;

// RAG（可选）
var kr = zigmodu.ai.KeywordRetriever.init(allocator);
defer kr.deinit();
try kr.add("pol", "Refunds within 14 days", "policy");
const chunks = try kr.asRetriever().retrieve(allocator, "refund", 3);
defer kr.asRetriever().free(allocator, chunks);
```

## 流式 vs 非流式

```zig
// 非流式 — 直接返回完整 JSON
const msg = try ai_chat_svc.send(conv_id, "你好", null);

// 流式 SSE — 逐字输出
var sse = try zigmodu.http.SseWriter.init(ctx);
const msg = try ai_chat_svc.send(conv_id, "讲个故事", &sse);
try sse.done();
```

## SSE API 参考

```zig
var sse = try zigmodu.http.SseWriter.init(ctx);

// 命名事件
try sse.sendEvent("message", "hello");
try sse.send("update", data); // 等同 sendEvent

// 纯数据事件（浏览器默认 "message" 类型）
try sse.sendData("{json}");

// 多行数据
try sse.sendMultiLine("result", &.{ "line1", "line2" });

// 设置重连 ID + 间隔
sse.setId("42");
try sse.sendRetry(3000); // 3 秒后重连

// 心跳（防止代理超时）
try sse.heartbeat(); // 发送 ": ping\n"

// 结束
try sse.done();       // event: done, data: [DONE]
try sse.sendError("something went wrong");
```

## 缓存指标

```zig
// 读取累计指标
const m = ai_provider.metrics;
// m.total_requests, m.total_prompt_tokens
// m.total_completion_tokens, m.cache_hit_tokens
// m.cache_miss_tokens, m.rate_limited_count

const ratio = ai_provider.cacheHitRatio(); // 0.0 - 1.0
```

## Token 估算

```zig
const zigmodu = @import("zigmodu");

const tokens = zigmodu.ai.estimateTokens("Hello, 你好");
// 英文 ~4 chars/token, 中日韩 ~1 char/token
// 精度 ±20%

const msgs = &[_]zigmodu.ai.AiProvider.ChatMsg{
    .{ .role = "system", .content = "You are helpful." },
    .{ .role = "user", .content = "Hi" },
};
const total = zigmodu.ai.estimateMessages(msgs);
```

## 配置选项

```zig
ai_chat_svc.context_limit = 128000;   // 上下文窗口（token）
ai_chat_svc.max_context = 20;          // 最大历史消息数
ai_chat_svc.system_prompt = "你是一个..." // 系统提示

ai_provider.max_output_tokens = 4096;  // 最大输出 token
ai_provider.temperature = 0.7;         // 温度
```

## 并发安全

| 组件 | 并发模型 | 说明 |
|------|----------|------|
| AiProvider | HttpClient 内置 mutex | 连接池复用，支持多 fiber 并发 |
| RateLimiter | 独立 mutex | `tryAcquire()` 原子操作 |
| MemoryStore | 内部 mutex | 同 SkillRegistry 模式 |
| tokenizer | 无锁 | 纯计算，无副作用 |
| SseWriter | 单 fiber | stream 写，不复用 |

## 支持的后端

- DeepSeek V4 (Pro / Flash) — 推荐，自动缓存
- OpenAI /v1/chat/completions
- Ollama /api/chat (localhost)
- 任何 OpenAI 兼容端点

## 与 Scheduler 集成（AI → cron 薄桥）

框架提供**受控的排程桥**：Agent 只能把**预先注册的命名任务**挂到 cron 表达式上，
LLM 永远不提供代码（保持「受控执行」姿态）。桥接方向：`zigmodu.ai.registerScheduleSkills`。

```zig
const Scheduler = zigmodu.cron.Scheduler;
const ai = zigmodu.ai;

// 1) 预注册可排程任务（纯 Zig 函数）
const tasks = [_]ai.ScheduledTask{
    .{ .name = "daily_report", .description = "生成每日报告", .task = dailyReport, .context = &app },
    .{ .name = "health_check", .description = "巡检服务健康", .task = healthCheck, .context = &app },
};

// 2) 启动线程化调度器（周期 tick；addJob 线程安全）
var scheduler = Scheduler.init(allocator, io);
try scheduler.start();
defer scheduler.stop();

// 3) 打包能力（调度器 + 可排程任务白名单）并注册 schedule skills
var sched_ctx = ai.ScheduleCtx{ .scheduler = &scheduler, .tasks = &tasks };
try ai.registerScheduleSkills(&registry);
// 每次 dispatch/run 前：skill_ctx.userdata = @ptrCast(&sched_ctx)

// Agent 现在可以通过工具调用：
//   list_schedulable_tasks → ["daily_report", "health_check"]
//   schedule_job { "task": "daily_report", "expr": "0 9 * * *" } → 每天 09:00
//   list_jobs / cancel_job → 查看/取消已排任务
```

内置业务 skill（`db.query` / `entity.lookup` / `entity.list`，只读参数化 SQL +
实体白名单 + 租户隔离）见 [docs/AI_SKILLS.md](AI_SKILLS.md)。

要点：

- `Scheduler` 是线程化的：`start()` 起后台线程，每秒 tick 一次，按分钟粒度触发 cron 任务；`addJob` 与 `tick` 互斥保护，可随时加任务。
- `schedule_job` 只接受**已注册任务名 + cron 表达式**；未知任务返回 `error.TaskNotFound`。
- 另一个方向（cron → AI）：`Scheduler` 的 task 里直接同步调用 `AiProvider.chat/chatStream` 即可（如定时摘要）；注意 HTTP 出站在线程内的 io 使用约束（见 ZIGMODU_NOTES 第 3 条）。
- `ScheduledTask.TaskScheduler`（旧占位实现）**已移除**；调度统一走
  `Scheduler`（线程化）与 `zigmodu.ai.registerScheduleSkills` 技能桥。
