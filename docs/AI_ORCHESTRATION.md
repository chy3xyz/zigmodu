# AI 编排能力规划与现状

> 与 [AI_SKILLS.md](AI_SKILLS.md)（Agent 能「做什么」的工具目录）互补，本文是
> Agent **怎么跑**的编排层：多步任务、预算、触发、子 Agent、人工交接。
> 所有能力复用业务层基建（Saga/outbox/WAL、Scheduler、EventBus、quota/audit），
> 遵守受控执行姿态。

## P0 · 已落地

### `zigmodu.ai.workflow` — 线性多步任务编排

```zig
var wf = zigmodu.ai.workflow.Workflow.init(&registry, &steps);
var result = try wf.run(allocator, &ctx);   // 顺序执行，逐步入记录
defer result.deinit();
```

步骤类型：

| StepKind | 说明 |
|----------|------|
| `.llm` | 单次 LLM 调用（无工具） |
| `.skill` | 一次 skill dispatch（结果 stringify 入记录） |
| `.agent` | 完整 ReAct Agent 运行（带工具） |

特性：每步记录（status/error/output）、步骤级重试（`retry`）、失败即停并返回
部分结果（status `.failed`）、共享预算超支即停（status `.budget_exhausted`）。

### `zigmodu.ai.Budget` — 任务级 token 预算

硬预留（`tryConsume`），非事后记账：多步任务/Agent 每步 LLM 前预留 token，
超支 `.stop` 提前终止（`AgentResult.budget_exhausted` / 运行状态
`.budget_exhausted`）或 `.warn` 继续。`Agent.budget` 可挂到单个 Agent 上。

### 后续（P1）

- **`AgentTrigger` 触发编排**：cron（Scheduler 已桥接）/ EventBus 事件 /
  Webhook → run → 结果回写 outbox；
- **子 Agent / 分层编排**：planner 拆任务 → executor 并行（复用 `Io.Group`
  并发模型）→ 聚合，失败隔离；

### 已落地（本轮）

- **WAL 持久化 + `resumeRun(run_id)`**：每步完成后写入 WAL（`Workflow.wal` +
  `run_id`），崩溃后从最后已持久化步骤续跑（回放已完成步骤 → 继续剩余）；
- **反射质量门**：`Workflow.reflection`（`VerifyFn`）+ `max_reviews`——最终步骤
  输出不达标自动重跑最后一步，仍不达标升级为失败；
- **转人工钩子**：`Workflow.on_escalate`（`EscalateFn`），步骤失败（重试后）、
  预算超支、验证持续失败三种原因回调应用层。

### P2

- **上下文管理**：长对话按 token 阈值自动摘要折叠；
- **运行时控制**：`AgentHandle`（cancel/pause/resume + 进度查询）+ 每步 trace
  span（复用 OTLP）。

## 边界（不做）

无界自主循环（每轮有限步骤 + 预算 + 可中止）；不内置 DAG 工作流引擎（复用
Saga 状态机即可）；不新增 shell/MCP 能力。
