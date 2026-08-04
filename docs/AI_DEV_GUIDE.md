# AI 开发指南（ZigModu.ai 业务接入）

> 面向「在业务系统里接入 AI」的开发者：从 key / provider 供给到
> `Agent` / `Workflow` / 自定义技能 / 接入方式（HTTP、cron、outbox、MCP）
> 的完整接线。所有能力遵守**受控执行**姿态：白名单、权限码、配额、审计、
> 租户隔离，LLM 永不直接执行代码或 SQL。

配套文档：`AI_SKILLS.md`（技能「能做什么」目录）· `AI_ORCHESTRATION.md`
（编排层细节）· `LLM_POLICIES.md`（LLM 策略接线）· `MCP.md`（技能 → MCP 桥）·
`AI_METHODOLOGY.md`（框架哲学，写框架代码前先读）。

## 1. 分层总览

| 层 | 组件 | 职责 |
|----|------|------|
| 供给 | `ai.AiKeyManager` / `KeyPool` / `ProviderRegistry` / `CooldownStore` | key 池、轮换、冷却、provider fallback |
| 模型 | `ai.AiProvider` | OpenAI 兼容 chat / `chatStream`；`http://` 池化、`https://` 经 `std.http.Client` |
| 执行 | `ai.Agent` / `ai.workflow.Workflow` / `Budget` / `ContextManager` | ReAct 循环、多步编排、预算、长对话压缩 |
| 能力 | `SkillRegistry`（`db.query` / `kpi.query` / `approval.request` / `admin.*`…）+ `ai.llm` 策略 | 可被 LLM 调用的受控工具 + LLM-backed 决策 |
| 接入 | HTTP（ComptimeRouter）/ `trigger.registerCron` / `OutboxWorkflowBridge` / `ai.mcp` | 把 AI 暴露给用户、定时、事件、外部平台 |

依赖方向：**供给 → 模型 → 执行 → 能力**；接入层在应用侧组装。每层都是
普通 Zig 对象，无隐藏全局状态（`KeyPool` 的冷却计数除外，那是进程内观测）。

## 2. 从示例开始

| 示例 | 示范什么 |
|------|----------|
| [`examples/tenant-ai`](../examples/tenant-ai) | 多租户 AI：技能、审批队列、workflow、`AiMetrics`、`RunAuditStore` |
| [`examples/ai-ops`](../examples/ai-ops) | 业务工具全链路：告警 → 诊断 → 审批 → 通知 → 审计 |
| [`examples/llm-policies`](../examples/llm-policies) | LLM 策略真实接线（`json_fn` 注入可无模型测试） |
| [`examples/mcp-server`](../examples/mcp-server) | SkillRegistry → MCP stdio server（`tools/list` / `tools/call`） |

## 3. 最小链路

### 3.1 供给：AiKeyManager

生产建议用 `AiKeyManager` 而不是裸 `AiProvider`——它负责多 key 轮换、
429/401 冷却禁用和 provider fallback（详见 `LLM_POLICIES.md` §8）：

```zig
var mgr = zigmodu.ai.AiKeyManager.init(allocator, io);
defer mgr.deinit();
try mgr.applyConfig(&.{
    .{
        .name = "deepseek",
        .endpoint = "https://api.deepseek.com/v1/chat/completions",
        .api_keys = &.{ "sk-a", "sk-b" },   // 从 environ_map 读，勿硬编码
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

var http = zigmodu.http.HttpClient.init(allocator, io, 4, 30000);
defer http.deinit();
var provider = try mgr.providerFor(allocator, &http, "deepseek-v4-flash");
```

多实例共享同一批 key 时，接 Redis 冷却（`mgr.setSharedStore(...)`），
否则实例间互相不知道彼此的冷却/禁用状态。

### 3.2 能力：注册自定义 Skill

```zig
fn orderSummaryHandler(ctx: *zigmodu.ai.SkillContext, args: std.json.Value) anyerror!std.json.Value {
    try ctx.checkDeadline();                       // 协作式超时
    const order_id = args.object.get("order_id").?.integer;
    var obj = std.json.ObjectMap{};
    // 所有权约定：key/字符串必须用 ctx.allocator dupe（freeValue 会深释放）
    try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "order_id"), .{ .integer = order_id });
    try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "total_cents"), .{ .integer = 5997 });
    return .{ .object = obj };
}

var registry = zigmodu.ai.SkillRegistry.init(allocator, io);
defer registry.deinit();
try registry.register(.{
    .name = "order.summary",
    .description = "查询订单金额（只读）",
    .parameters = &.{
        .{ .name = "order_id", .type = .number, .description = "订单 ID", .required = true },
    },
    .required_permission = "order:read",   // 未授权直接 error.PermissionDenied
    .handler = orderSummaryHandler,
});
```

### 3.3 执行：Agent

```zig
var budget = zigmodu.ai.Budget.init(2000);          // 硬 token 预算（预留制）
var audit_log = try zigmodu.ai.AgentAuditLog.init(allocator, io, 256);
var agent = zigmodu.ai.Agent{
    .provider = &provider,
    .registry = &registry,
    .allowlist = &.{"order.summary"},               // 安全：只允许列出的工具
    .tool_timeout_ms = 5_000,
    .budget = &budget,
    .audit = &audit_log,
    // .context = &ctx_mgr,                         // 可选：长对话自动压缩
    // .tracer = &tracer,                           // 可选：run 级 trace span
};

var skill_ctx = zigmodu.ai.SkillContext{
    .allocator = allocator,
    .tenant_id = 1,
    .user_id = 42,
    .permissions = &.{"order:read"},
};
var result = try agent.run(allocator, "查询订单 42 的金额", &skill_ctx, 5);
defer result.deinit(allocator);
if (result.budget_exhausted) { /* 配额超支：提示降级 */ }
if (result.canceled) { /* 用户/编排方中止 */ }
```

### 3.4 编排：Workflow

```zig
var wf = zigmodu.ai.workflow.Workflow.init(&registry, &.{
    .{ .name = "check", .kind = .{ .skill = .{ .name = "order.summary", .args = .{ .object = .{} } } } },
    .{ .name = "risk",  .kind = .{ .skill = .{ .name = "risk.review", .args = .{ .object = .{} } } }, .depends_on = &.{"check"} },
    .{ .name = "report", .kind = .{ .llm = .{ .prompt = "把风险结论汇总为一段话" } }, .depends_on = &.{"risk"} },
});
wf.wal = &wal;                          // 崩溃恢复 / 幂等重放
wf.reflection = zigmodu.ai.llm.llmVerify;
wf.goal = "输出订单风险结论";
wf.max_reviews = 2;
var wf_result = try wf.run(allocator, &skill_ctx);
defer wf_result.deinit();
```

审批门：步骤 `.{ .approval = .{ .subject = "order-42", .amount = 150000 } }`
挂 `wf.approval_flow` 后走审批链，转人工时 run 以 `.pending_human` 停下，
人工处理后 `wf.resumeRun(allocator, &skill_ctx, run_id)` 继续。

## 4. 自定义技能开发规范

| 规范 | 要求 |
|------|------|
| 参数声明 | `Param{ name, type, description, required }` → 自动映射 JSON Schema（function calling） |
| 返回值所有权 | handler 结果树里**所有 key 与字符串**用 `ctx.allocator` dupe；调用方 `ai.freeValue` 深释放 |
| 权限 | `required_permission` 设置权限码；`SkillContext.permissions` 不含则 `error.PermissionDenied` |
| 白名单 | `Agent.allowlist` / `dispatchWith(.{ .allowlist })` 二次收口 |
| 超时 | handler 循环内 `ctx.checkDeadline()`；框架另有返回后超时检查（非抢占） |
| 租户 | `SkillContext.tenant_id` 贯穿；实体类技能自动追加租户条件 |
| 只读优先 | 写动作走 `ai.actions`（事务性 outbox + 幂等键），不要直接 handler 里裸 SQL |

## 5. 选型：Agent / Workflow / LLM 策略 / Skill 桥

| 场景 | 用 | 说明 |
|------|----|------|
| 一次对话、多轮工具调用 | `Agent` | ReAct 循环，适合「用户提问 → 查数据 → 总结」 |
| 固定流程多步、含审批/并行/恢复 | `Workflow` | 线性 / DAG（`depends_on`）/ `.approval` / WAL 恢复 |
| 让模型做审批/风控/诊断/质量门决策 | `ai.llm` 策略 | `llmApprove` / `llmRiskDecide` / `llmDiagnose` / `llmVerify`，失败安全回退 escalate |
| 给外部 LLM 平台暴露技能 | `ai.mcp` 桥 | `serveStdio` 起 MCP server，`tools/list` + `tools/call` |
| 定时/事件触发运行 | `ai.trigger` | `registerCron` / `fire`；可经 outbox 回写结果 |

## 6. 接入方式

**HTTP（ComptimeRouter）**：handler 里组装 `SkillContext` 后调
`agent.run` / `wf.run`，把 `result.answer` 用 `ctx.json` 返回；权限来自 JWT
中间件写的 attrs（`user_id` / `tenant_id` / `permissions`），参考 `tenant-ai`。

**cron**：

```zig
var trigger = zigmodu.ai.trigger.Trigger.init(allocator, io, run_fn, skill_ctx);
try trigger.registerCron(&scheduler, "nightly-report", "0 3 * * *", "nightly report");
_ = trigger.fire(allocator, "webhook-event");   // 事件源即时触发
```

**outbox**：`ai.bridge.OutboxWorkflowBridge` 按 topic 把 outbox 条目路由进
`trigger.fire`；业务工具（`ai.approval` / `ai.risk` / `ai.notify`…）的写回可被
`outbox.OutboxConsumer` 消费，形成「业务事件 → outbox → AI → 审计/人工」闭环。

**MCP**：`ai.mcp.serveStdio(io, allocator, &registry, ctx_template)` 起 stdio
server，`tools/list` 自动从注册表推导参数 schema，`admin.*` 默认不进
`tools/list`（需显式 allowlist）。

## 7. 安全与受控执行清单

- [ ] key 从 `init.environ_map` 读，端点/模型白名单由应用配置
- [ ] `Agent.allowlist` 只列业务需要的技能；管理类技能（`admin.*`）默认关闭
- [ ] 写操作技能设 `required_permission` + 事务性 outbox + 幂等键（`run_id`）
- [ ] handler 返回值全部 `ctx.allocator` 持有，调用方 `freeValue`
- [ ] `SkillContext.tenant_id` 从请求/JWT 注入，实体技能自动租户隔离
- [ ] 长任务设 `deadline_ms` / `tool_timeout_ms` / `Budget`
- [ ] 生产打开 `audit`（`AgentAuditLog` / `RunAuditStore`）与指标
- [ ] LLM 决策「拿不准就转人工」，绝不静默批准（`ai.llm` 已内建该姿态）

## 8. 观测与调试

- `zigmodu.ai.observability.AiMetrics`：合并 `WorkflowMetrics` + `AgentMetrics`
  + `TokenQuota` 为一份 Prometheus 文档（`tenant-ai` 的 `GET /api/ai/metrics`）。
- `zigmodu.ai.run_audit.RunAuditStore`：workflow / agent / approval 运行历史
  （`GET /api/ai/runs`，租户隔离）。
- `mgr.listProviders(io, allocator)`：每个 provider/key 的 status / failures /
  调用计数快照；`enableKey` / `enableProvider` 人工介入。
- 无模型调试：`LlmPolicyCtx.json_fn` 注入 fake JSON（`examples/llm-policies`），
  或 `AiProvider` 指向本地 mock OpenAI 端点（框架 Agent 端到端测试同法）。

## 边界（刻意不做）

无界自主循环（每轮有限步骤 + 预算 + 可中止）；不内置 shell / 任意 URL 抓取 /
裸 SQL 写 / 跨租户访问 / 向量库（`Retriever` 自接）；管理类技能必须显式
加入 allowlist。
