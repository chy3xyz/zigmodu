# AI Orchestration

How agent work is shaped: multi-step tasks, budgets, triggers, sub-agents and human handoff. [AI_SKILLS.md](./AI_SKILLS.md) lists the "what"; this page covers how it runs.

All orchestration reuses business infrastructure (Saga/outbox/WAL, `Scheduler`, `EventBus`, quota, audit) and keeps the controlled-execution posture.

For gates and execution permission, read [`AGENT_RUNTIME.md`](../reference/AGENT_RUNTIME.md): `ai.Guard`, `ai.AgentSpec` (`isGuarded()` / `isInert()`), `skill.Tool.action` (default `.execute`), `ai.AgentWorker` and `ai.ProposalPipeline`.

## Workflow

```zig
const steps = [_]zmodu.ai.workflow.Step{
    .{ .name = "lookup", .kind = .{ .skill = .{ .name = "order.summary", .args = .{ .object = .{} } } } },
    .{ .name = "review", .kind = .{ .approval = .{ .subject = "order-42", .amount = 150_000 } }, .depends_on = &.{"lookup"} },
    .{ .name = "reply", .kind = .{ .llm = .{ .prompt = "Draft the customer reply" } }, .depends_on = &.{"review"} },
};

var wf = zmodu.ai.workflow.Workflow.init(&registry, &steps);
wf.wal = &wal;                        // crash recovery and replay
wf.approval_flow = flow.toPort();     // required for .approval steps
wf.max_parallel = 4;                  // DAG wave width
var result = try wf.run(allocator, &ctx); // one record per step
defer result.deinit();
```

| `StepKind` | Behaviour |
|------------|-----------|
| `.llm` | One LLM turn, no tools |
| `.skill` | One skill dispatch, result stringified into the record |
| `.agent` | A full ReAct agent run with tools |
| `.approval` | Human-in-the-loop gate (`{ subject, amount }`) |

Each step records status, error and output. A step may set `retry`; a failure stops the run and returns partial results with status `.failed`; a shared budget overrun stops it with `.budget_exhausted`.

`Workflow.toMermaid` renders the step graph as a Mermaid `flowchart` (implicit order edges for linear flows, dependency edges for DAGs, kind-annotated nodes).

**Human approval.** With `Workflow.approval_flow` set, an `.approval` step runs the approval chain: approved continues, rejected fails the step, and an escalation stops the run as `.pending_human` with earlier steps persisted. After the human decides, `resumeRun` re-runs the approval step under the same policy and continues.

**Linear or DAG.** Declared order is linear by default. Adding `depends_on` to any step switches the run to DAG mode: ready steps execute in parallel waves of `max_parallel` (`std.Io.Group`), and a cycle returns `error.CyclicDependency`. Budget, WAL persistence and human handoff work the same in both modes. The reflection quality gate applies to the final step of the linear path; for a DAG, verify at the sink or add a linear step after it.

**WAL recovery.** Each completed step is appended to `Workflow.wal` under the run id. After a crash, `resumeRun` replays finished steps and continues from the first unpersisted one.

**Reflection gate.** `Workflow.reflection` (`VerifyFn`) plus `max_reviews` re-runs the final step when output misses `Workflow.goal`; a persistent miss escalates to failure.

**Escalation hooks.** `Workflow.on_escalate` (`EscalateFn`) fires for `step_failed`, `budget_exhausted` and `verification_failed`, handing control to the application.

## Budget

```zig
var budget = zmodu.ai.Budget.init(2000);
budget.mode = .stop; // or .warn
```

`Budget` is a hard reservation, not after-the-fact accounting: each step reserves tokens before its LLM call, and an overrun stops the run (`AgentResult.budget_exhausted`, run status `.budget_exhausted`) or warns and continues. Attach it to one agent with `Agent.budget`.

## Business tools

| Component | Role |
|-----------|------|
| `ai.reporter.BusinessReporter` | Configured SQL query to Markdown business report; pair with `trigger.registerCron` and the outbox for daily delivery |
| `ai.alerts.BusinessAlert` | Rule-based SQL inspection; any hit triggers an alert through `on_alert` plus outbox write-back |
| `ai.ticket.TicketFlow` | Ticket triage: context query (reusing `BusinessReporter`), classification, draft reply, send or human approval (`on_send`), outbox write-back |
| `ai.refund.RefundFlow` | Refund compensation: validate, approve, refund command through the transactional outbox, notify; a failed notification emits `refund.reverse`, and `compensate()` reverses manually or automatically |
| `ai.risk.RiskReview` | Risk scoring from SQL rules with a configurable `DecideFn` (LLM or policy), tiering low/medium/high, decision approve/escalate/reject, `ai.risk` write-back |
| `ai.recon.ReconCheck` | Reconciliation of two SQL snapshots by key (missing / extra / mismatch), per-row `on_diff`, summary outbox event (`ai.recon`, CLEAN/DRIFT) and a Markdown report from `renderReport` |
| `ai.approval.ApprovalFlow` | Multi-level approval chain; each step's `policy` (LLM, RBAC or rules) returns approved / escalated / rejected; per-step and final events go to the transactional outbox (`ai.approval`). `registerApprovalSkills` exposes `approval.submit`; the default policy escalates everything |
| `ai.notify.NotificationHub` | Delivery to named channels: webhook through `HttpClient` (2xx means delivered), custom sinks (`userdata` + `call`), and a transactional outbox fallback (`ai.notify`). `registerNotifySkills` exposes `notification.send`; channel targets are registered by the application and can be allowlisted |
| `ai.kpi.KpiMetric` + `kpi.query` | Named metrics (name to SQL to value column); the model can only query by name, while the application owns definitions and SQL semantics. Programmatic access through `Kpi.query` |
| `ai.sla.SlaTracker` | SLA tracking on a monotonic clock: `check()` produces warnings inside the warn window and breaches past the deadline, delivered to `on_sla` and the outbox (`ai.sla`) |
| `ai.diagnose.DiagnosisFlow` | Diagnosis: run configured evidence SQL, pass it to the `diagnose` callback (LLM or rules), get root causes plus suggested actions, write back to `ai.diagnose` |

Runtime control and longer-running shapes:

- `ai.AgentHandle`: cooperative cancel, pause and step counting (atomic flags checked between steps); `Agent.tracer` with `parent_span` optionally opens a run-level span.
- `ai.context.ContextManager`: compacts long histories past a token budget by summarizing older messages (or dropping them) into a leading system message; attached through `Agent.context`.
- `ai.hierarchy.Hierarchy`: planner splits the goal into subtasks, executor runs them in parallel waves by `max_parallel`, results aggregate; partial failures surface as `.partial_failed`. Planner and executor are callbacks, so they can wrap an Agent or a Workflow.
- `ai.trigger`: `fire(input)` for events and webhooks, `registerCron(scheduler, name, expr, input)` for schedules (context is held by the trigger), and optional outbox write-back of `{run_id, ok, message}` per run.

```zig
var trigger = zmodu.ai.trigger.Trigger.init(allocator, io, run_fn, skill_ctx);
trigger.outbox = &outbox;   // write {run_id, ok, message} per run
trigger.backend = &backend;
try trigger.registerCron(&scheduler, "nightly", "0 3 * * *", "nightly report");
_ = try trigger.fire(allocator, "webhook-event");
```

## Outbox loop

`zmodu.outbox.OutboxConsumer` completes the transactional outbox on the read side:

1. Poll pending entries, optionally filtered by topic.
2. Dispatch each to a registered handler (`userdata` + `call`; topic and payload are stable copies for the call).
3. Advance pending → processing → delivered, or increment `retry_count` and record `error_message`; exhausted retries become `failed` (dead-letter).

All AI business tools (`ai.approval`, `ai.recon`, `ai.notify`, `ai.risk`, `ai.alerts`) write outbox events this consumer can drain, forming the loop from business event to consumer or human queue.

`zmodu.ai.bridge.OutboxWorkflowBridge` routes outbox entries by topic (exact or prefix) into `trigger.fire`, where the run function usually drives a `Workflow`. Cron, in-process fire and outbox events become one trigger surface, and results flow back through the trigger's own outbox write-back.

## Approval queue

`zmodu.ai.approval_api` provides an in-memory queue: attach `queuedEscalation` to `ApprovalFlow.on_escalated` and escalated runs enqueue themselves. The `ApprovalApi` ComptimeRouter module exposes `GET /approvals/pending`, `POST /approvals/{id}/approve` and `POST /approvals/{id}/reject`, the last two gated by `permission = approval:decide`. The queue is application-owned memory; pair it with an outbox consumer or a database when it must survive restarts.

`zmodu.ai.approval_store.PersistentApprovalQueue` has the same interface (`push`, `listPending`, `resolve`, `count`) but stores rows in SQL (`migrate()` creates the table, so restarts do not lose state). `queuedEscalationPersistent` is its escalation hook, and `ApprovalApi` is generic over both (`ApprovalApi(ApprovalQueue)` or `ApprovalApi(PersistentApprovalQueue)`).

`registerApprovalRequestSkills` exposes `approval.request` (subject plus amount; chain and policy are application-registered), so an `.agent` step can request approval and the run resumes with `resumeRun` after a human decides.

## LLM policies

`zmodu.ai.llm` provides LLM-backed policy callbacks: `llmDiagnose` (summary, causes, actions), `llmApprove` (approve/escalate/reject plus note) and `llmRiskDecide`. Point `SkillContext.userdata` at `LlmPolicyCtx{ .provider, .json_fn, .system_hint }` and attach the callback to the matching flow. When the model fails or returns invalid JSON, the policy escalates rather than approving silently.

`LlmPolicyCtx.retriever` plus `retrieval_query` injects top-k retrieval chunks (policies, past decisions, playbooks) into all three prompts, so decisions rest on business context. `buildContext` assembles that block.

## Observability

`zmodu.ai.WorkflowMetrics` (attached to `Workflow.metrics`) accumulates `runs`, `completed_steps`, `failed_steps`, `escalations` and `reviews` per run or resume, and exports `zigmodu_ai_workflow_*` series.

`zmodu.ai.observability.AiMetrics` merges workflow, agent and token-quota series into one Prometheus document, so one `/metrics` endpoint covers the AI stack.

`zmodu.ai.run_audit.RunAuditStore` persists each workflow, agent and approval run (run id, kind, status, tenant, step count, duration); attach it to `Workflow.audit` and run/resume writes a row. `list(kind, tenant, limit)` filters by kind and tenant.

## Boundaries

No unbounded autonomous loop: every run has a finite step count, a budget and cooperative cancellation. No shell or new MCP capability is added by orchestration.
