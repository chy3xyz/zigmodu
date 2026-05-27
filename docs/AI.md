# AI Chat Module — 使用指南

基于 zigmodu.ai 框架的 LLM 对话模块。支持多轮对话、跨会话记忆、SSE 流式输出、DeepSeek V4 缓存优化。

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

```zig
// 创建 HTTP 客户端（连接池复用，高并发友好）
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

// 注入 service
ai_chat_svc.setProvider(ai_provider);
ai_chat_svc.setSystemPrompt("你是一个有用的助手");
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
    ai_chat_svc.setProvider(ai_provider);
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

// 删除
memory.forget("user:pref:lang");

// 容量控制（默认 10000 条，LRU 淘汰）
memory.max_entries = 50000;
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
