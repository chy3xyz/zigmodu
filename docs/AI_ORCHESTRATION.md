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

**线性 ↔ DAG 混合**：默认按声明顺序线性执行；给步骤加 `depends_on`（依赖的步骤
名列表）即自动切换为 **DAG 执行**——就绪步骤（依赖全部完成）按 `max_parallel`
并行波次执行（`std.Io.Group`），环检测返回 `error.CyclicDependency`。预算、
WAL 持久化、转人工在 DAG 下同样生效；反射质量门当前应用于线性路径的最终步骤
（DAG 汇点可用后续线性步骤校验）。

### `zigmodu.ai.Budget` — 任务级 token 预算

硬预留（`tryConsume`），非事后记账：多步任务/Agent 每步 LLM 前预留 token，
超支 `.stop` 提前终止（`AgentResult.budget_exhausted` / 运行状态
`.budget_exhausted`）或 `.warn` 继续。`Agent.budget` 可挂到单个 Agent 上。

### 已落地（本轮）

- **`zigmodu.ai.AgentHandle` 运行时控制**：协作式 cancel / pause / 进度计数
  （原子标志，Agent 每步边界检查）；`Agent.tracer` + `parent_span` 可选创建
  run 级 trace span（复用 DistributedTracer）；
- **`zigmodu.ai.context` 上下文管理**：按 token 阈值自动压缩长对话——旧消息
  交给 `SummarizeFn` 摘要（或直接丢弃）作为 system 消息前置，保留最近窗口；
  `Agent.context` 已接入（循环内自动触发）；
- **`zigmodu.ai.hierarchy` 分层编排**：planner 拆目标为子任务 → executor 并行
  （`std.Io.Group` 按 `max_parallel` 分波）→ 聚合；部分失败标记
  `.partial_failed`；planner/executor 均为回调，可接 Agent/Workflow；
- **`zigmodu.ai.trigger` 触发编排**：`fire(input)`（事件/Webhook 源直接调用）+
  `registerCron(scheduler, name, expr, input)`（定时源，上下文由 Trigger 持有）+
  可选 outbox 回写（`outbox` + `backend` 配置后每次 run 追加
  `{run_id, ok, message}` 到事务性 outbox）；
- **WAL 持久化 + `resumeRun(run_id)`**：每步完成后写入 WAL（`Workflow.wal` +
  `run_id`），崩溃后从最后已持久化步骤续跑（回放已完成步骤 → 继续剩余）；
- **反射质量门**：`Workflow.reflection`（`VerifyFn`）+ `max_reviews`——最终步骤
  输出不达标自动重跑最后一步，仍不达标升级为失败；
- **转人工钩子**：`Workflow.on_escalate`（`EscalateFn`），步骤失败（重试后）、
  预算超支、验证持续失败三种原因回调应用层。

## 边界（不做）

无界自主循环（每轮有限步骤 + 预算 + 可中止）；不新增 shell/MCP 能力。
