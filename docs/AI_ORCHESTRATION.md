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

- **业务价值工具**：
  - `zigmodu.ai.reporter.BusinessReporter`——配置化 SQL 查询 → Markdown 经营简报
    （配合 `trigger.registerCron` + outbox 即可每日定时推送）；
  - `zigmodu.ai.alerts.BusinessAlert`——规则化 SQL 巡检，任一规则命中即触发
    预警（`on_alert` 回调 + outbox 回写），配合 cron trigger 做异常预警。
  - `zigmodu.ai.ticket.TicketFlow`——工单分诊：上下文查询（复用 BusinessReporter）
    → 分类 → 草稿回复 → 发送/人工审批门（`on_send`）→ outbox 回写。
  - `zigmodu.ai.refund.RefundFlow`——退款补偿编排：校验 → 审批 → 退款命令
    （事务性 outbox）→ 通知；通知失败自动发补偿命令（`refund.reverse`），并暴露
    `compensate()` 供下游失败时人工/自动冲正。
  - `zigmodu.ai.risk.RiskReview`——风控审核：规则化 SQL 命中累加风险分
    （可配 `DecideFn` 接 LLM/策略）→ 分档（low/medium/high）→ 决策
    （approve/escalate/reject）→ outbox 回写 `ai.risk`，供人工复核队列消费。
  - `zigmodu.ai.recon.ReconCheck`——数据对账巡检：源/目标两个 SQL 快照按
    key 对比（missing / extra / mismatch 三态），逐条 `on_diff` 回调 +
    outbox 汇总（`ai.recon`，CLEAN/DRIFT）+ Markdown 差异报告
    （`renderReport`）；配合 cron trigger 做定时对账。
  - `zigmodu.ai.approval.ApprovalFlow`——多级审批链：请求按配置的步骤列表
    逐级审批，每步由 `policy` 回调（可接 LLM/RBAC/规则引擎）决定
    approved / escalated / rejected，首次拒绝或转人工即停；逐步 + 终态事件
    写回事务性 outbox（`ai.approval`）作为审计与人工队列。
    `registerApprovalSkills` 暴露 `approval.submit` 技能桥（LLM 只提供
    subject/amount/request，审批链与策略由应用注册），默认策略为全部转人工。
  - `zigmodu.ai.notify.NotificationHub`——通知分发：消息投递到具名渠道——
    webhook（走 `HttpClient`，HTTP 2xx 才算送达）、自定义 sink
    （邮件/IM/站内信回调，`userdata` + `call` 模式）、无渠道时事务性 outbox
    持久化兜底（`ai.notify`）；`registerNotifySkills` 暴露 `notification.send`
    技能桥（LLM 只提供 channel/title/body，渠道目标由应用注册并可白名单）。
  - `zigmodu.ai.kpi.KpiMetric` + `kpi.query`——经营指标：应用注册具名指标
    （name → SQL → value 列），`kpi.query` 技能桥让 LLM 直接回答
    「本周营收/退款率多少」；指标定义与 SQL 语义由应用持有，LLM 只能按名查询，
    另有程序化 `Kpi.query`。
  - `zigmodu.ai.sla.SlaTracker`——SLA/时效管理：跟踪业务项（工单/审批/退款）
    的单调钟截止时间，`check()` 按 cron 节奏评估——截止前进入 warn 窗口触发
    提醒，超时触发 breach；事件进 `on_sla` 回调（可接 `ai.notify`）+ outbox
    （`ai.sla`），把「等处理」变成主动运营。
  - `zigmodu.ai.diagnose.DiagnosisFlow`——异常归因诊断：给定异常（来自
    `alerts`/`recon`/`sla`/应用代码），先跑配置的 evidence SQL 收集证据，
    再交给 `diagnose` 回调（可接 LLM/规则引擎）产出根因 + 建议动作，
    结果写回 outbox（`ai.diagnose`）。
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

## P0/P1 · outbox 消费闭环

`zigmodu.outbox.OutboxConsumer` 补齐事务性 outbox 的**读侧**：轮询 pending
条目（可按 topic 过滤）→ 分发到注册的 handler（`userdata + call`，topic/payload
为调用期稳定的副本）→ 生命周期推进 pending → processing → delivered，失败则
`retry_count++`（`error_message` 记录），耗尽重试后置 failed（DLQ 语义）。
所有 AI 业务工具（`ai.approval` / `ai.recon` / `ai.notify` / `ai.risk` /
`ai.alert`）的 outbox 回写都可被它消费，配合 `ai.trigger` 即可形成
「业务事件 → outbox → 消费者/人工队列」的完整闭环。

### 事件驱动编排（outbox → workflow）

`zigmodu.ai.bridge.OutboxWorkflowBridge` 把 outbox 条目按 topic（精确或前缀）
路由进 `ai.trigger` 的 `fire(input)`（run_fn 通常驱动 `Workflow`）——cron、
进程内 fire、outbox 事件三种触发源至此统一；运行结果再经 trigger 自身的 outbox
回写闭环。

### 人工审批队列（HTTP）

`zigmodu.ai.approval_api` 提供内存审批队列：`ApprovalFlow.on_escalated` 挂上
`queuedEscalation` 后，转人工的运行自动入队；`ApprovalApi` ComptimeRouter 模块
暴露 `GET /approvals/pending`、`POST /approvals/{id}/approve`、
`POST /approvals/{id}/reject`（后两者 `permission = approval:decide`）。
队列为应用持有的小存储，需要跨重启时配对 outbox consumer/数据库。

### LLM 默认策略（开箱即用）

`zigmodu.ai.llm` 提供 LLM-backed 策略回调：`llmDiagnose`（异常归因：
summary/causes/actions）、`llmApprove`（审批：approve/escalate/reject +
note）、`llmRiskDecide`（风控决策）。把 `SkillContext.userdata` 指向
`LlmPolicyCtx{ .provider, .json_fn, .system_hint }` 即可直接挂到对应 Flow；
模型失败或返回非法 JSON 时**安全回退到 escalate**，绝不静默放行。

## 边界（不做）

无界自主循环（每轮有限步骤 + 预算 + 可中止）；不新增 shell/MCP 能力。
