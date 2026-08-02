# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

_Nothing yet._

## [0.15.0] - 2026-08-01

### Changed
- **AI 编排栈完整化（本轮大版本主题）**：workflow 线性↔DAG 混合 + 人工审批门
  （`.approval` step、`pending_human`、resume 恢复不重提）+ WAL 恢复 + LLM
  反射验证（`ai.llm.llmVerify`）+ `WorkflowMetrics` 观测 + `toMermaid` 图导出；
  触发三源统一（cron / fire / outbox，`ai.bridge.OutboxWorkflowBridge`）；
  业务工具 11 件（reporter/alerts/ticket/refund/risk/recon/approval/notify/kpi/
  sla/diagnose）；审批技能桥 `approval.request`（`required_permission` 门控）；
  LLM 策略 + RAG 上下文（`ai.llm`，失败安全回退 escalate）；持久化审批队列
  （`PersistentApprovalQueue`，tenant_id 隔离）+ HTTP API；outbox 消费端
  （`OutboxConsumer`）；运行审计（`RunAuditStore`，workflow + agent）；
  AI 观测聚合（`AiMetrics`）；技能注册表 OpenAPI/CLI 导出
  （`ai.skill_export` + `zmodu ai`）；多租户 AI 示例（tenant-ai）、LLM 接线
  教程（docs/LLM_POLICIES.md）、AI 全链路示例（ai-ops）。

### Changed
- **Remaining zero-test coverage**: added tests for `src/util.zig` (`randomHex`/`randomUuid` length + hex charset, `pluralize` english rules incl. vowel-y, `hexEncode` + `HashKit` MD5/SHA-256 known vectors) and `sqlx.errors.sqlStateToError` (SQLState → kind mapping, unknown → Other) — which surfaced two missing mappings (`57014` Timeout, `53300` TooManyConnections) now added. The remaining zero-test files are barrels (http/observability/security/data/root/docs/outbox/im/extensions/ai/web4), C bindings (sqlite3_c/libpq_c/libmysql_c + stubs), platform-specific io_uring stubs and the usage `main.zig`/benchmark entry — none require unit tests.
- **Fluvio native transport + thin-component tests**: `messaging.FluvioNative.NativeTransport` replaces the `fluvio` CLI subprocess with a pluggable TCP transport (line protocol over a socket; loopback server for tests/dev — end-to-end createTopic/produce/consume/list verified). `FluvioConnector` gains a `transport` field so apps inject the native transport or a faithful Fluvio SC/SPU protocol implementation. Added tests for the remaining zero-test thin components: `core.Event` (tagged-union payloads), `log.ModuleLogger` (+ `LogScope`), `metrics.MetricsBackend` (vtable routing).
- **Zero-test component hardening**: added tests for `sqlx.CircuitBreaker` (open/half-open/closed state machine incl. timeout re-open and half-open failure), `core.EventPublisher` (TypedEventBus publish + event validation + metadata) and `core.ApplicationModuleListener` (subscribe + receive). Fixing them surfaced three more lazily-compiled broken implementations: `EventPublisherMixin` validated against the wrong bus type (`EventBus` vs `TypedEventBus`), `ModuleListener.subscribe` called a 2-arg `EventBus.subscribe` with one argument and wrapped the handler with the wrong signature — both now compile and pass tests. `FluvioConnector` CLI-fallback stub semantics confirmed covered by existing tests.
- **Productization pass (per component audit)**: (1) **Security consolidation** — `http_middleware.securityHeaders()` (default HSTS/X-Frame-Options/CSP/etc.) is the canonical security-header middleware; deleted the broken `security/SecurityHeaders.zig` middleware (wrong return type + wrong `next` call, never compiled) and the duplicate broken `security/Csrf.zig` (`CsrfProtection` — invalid API calls, never compiled); `Middleware.csrf()` is now the single CSRF implementation. Added tests for csrf allow/reject and security-header injection. (2) **EventStore productionized** — JSON event serialization, replay invoking the application handler, snapshot-based replay (state + events after snapshot), thread safety via `std.Io.Mutex`, owned metadata; tests cover append/serialize/replay and snapshot replay. (3) **Removed deprecated `ScheduledTask.zig`** (placeholder `start()`/`calculateNextCronRun`; AI bridge uses `Cron.zig`) — `zigmodu.TaskScheduler` export dropped. (4) **gRPC audit** — server/client/bidi/bidi-pump streaming are fully implemented and tested (corrects an earlier "streaming UNIMPLEMENTED" note). (5) PluginManager comment dedupe + HealthEndpoint test.
- **Web4 production hardening**: `web4.x402_store.X402Store` — persisted invoices (SQL) with exactly-once redemption (`redeem(invoice_id, tx_hash)` → redeemed / not_found / already_used / expired), wired into `x402Middleware` via `X402Config.store` (invoices created on 402, proofs redeemed once, replay → 410). `web4.challenge.ChallengeStore` — one-time DID challenges (issue + verifyAndConsume, TTL, anti-replay), wired into `didAuthMiddleware` via `DidAuthConfig.challenge_store`. `DidAuthConfig.jwt_issuer` issues a JWT (`x-did-token` header) after DID auth so clients continue on the framework's JWT/RBAC chain. Fixed pre-existing did.zig leaks (credential issue/verify buffers). `examples/web4` upgraded to the production path (402→200→410 replay rejection; DID challenge + JWT issuance); docs/WEB4.md documents the hardening.
- **Web4 middleware + example**: `zigmodu.web4.middleware` — `x402Middleware` (no proof → 402 + invoice, invalid → 403, valid → pass; fail-closed default verifier, optional per-route `path_prefix` + `on_invoice` pricing hook) and `didAuthMiddleware` (did:key signature verification → writes `did` / `user_id` attrs; per-route `path_prefix`). New `examples/web4` demonstrates both flows end-to-end (402→200 with proof, 401→200 with a generated did:key signature), `docs/WEB4.md` documents protocol + wiring + security defaults. Added to CI example builds.
- **LLM policy real-chain fixes**: `llmJson` now deep-copies the parsed response out of the parser arena before returning (callers `freeValue` it safely — previously the arena-resident tree caused invalid frees; only fake `json_fn` tests exercised that path until now). Added an end-to-end test that drives `llmApprove` through a real loopback mock OpenAI endpoint (provider.chat → llmJson → decision), plus fixed a dangling-pointer in `examples/llm-policies` (provider/http moved to function scope). Verified live against DeepSeek: llmApprove/llmRiskDecide/llmDiagnose/llmVerify all return real model decisions.
- **Write-operation AI skills (P1 落地)**: `zigmodu.ai.actions` — `entity.create/update` (whitelisted writable columns via `EntitySpec.writable`, tenant column forced from `SkillContext.tenant_id` and rejected from the model, PK forbidden, permission `entity:write`), `command.execute` (app-registered commands via the transactional outbox, idempotency key = `SkillContext.run_id`, permission `command:execute`) and `report.generate` (app-registered aggregations → CSV/JSON, row-capped). Closes the "AI 只读 → AI 可执行" gap; `EntitySpec` gains a `writable` field (backward compatible).
- **Dead-code analyzer fixes (`zmodu deadcode`)**: fixed two false-positive roots in the zdeadcode reference resolver — (1) a `test "name"` whose name equals a function name shadowed the function in `name_map`, so references resolved to the (already-live) test and the function was reported dead; (2) container members (enum variants/fields/methods) shadowed same-named top-level declarations (e.g. `const deadcode = @import(...)` + `enum { deadcode }`). Members no longer overwrite top-level names; both cases have regression tests. Also fixed an arena leak in the CLI adapter and wired the analyzer's own unit tests (analyze + scanner) into `zig build test` (was previously only compiled, not run). Repo scan dropped from 45 to 39 findings (0.4%), with the remaining items genuine unused imports/functions plus layout field `WALEntryHeader._pad` (kept).
- **Dead-code checker (`zmodu deadcode`)**: integrated the zdeadcode analyzer (rustc `dead_code`-style reachability: unused top-level fns/consts/vars, container fields, enum variants, methods, never-imported modules; `.gitignore`-aware scanning; human + JSON output; exit code 0/1/2 for CI). Its unit tests ship with the zmodu CLI test suite (framework suite now 825/843). CI adds a deadcode smoke asserting detection + valid JSON.
- **AI hardening pass**: (1) `Agent.audit_store` — standalone agent runs now persist to `RunAuditStore` (kind=agent, status/steps/duration), closing the durable-audit gap next to workflow runs; (2) `Tool.required_permission` + `SkillContext.permissions` — dispatch refuses with `error.PermissionDenied` when the tool's required permission is not granted; `approval.request` now requires `approval:decide`; (3) `skill_export.toOpenApi` gains optional bearer security (`OpenApiOpts.security_scheme` → components.securitySchemes + per-operation security); (4) barrel integrity test asserts the public `ai.*` API surface and caught a missing `ai.schedule` export (fixed); (5) docs synced — `docs/AI_SKILLS.md` now lists implemented business skills (kpi.query / approval.request / notification.send) vs planned ones, `docs/AI.md` reflects the removed `TaskScheduler`; (6) CI adds a `zmodu ai export-skills + openapi` smoke test asserting valid JSON.
- **AI skill registry → OpenAPI + CLI**: `zigmodu.ai.skill_export` renders a `SkillRegistry` as a JSON catalog (`toSkillsJson`) or an OpenAPI 3.0 document (`toOpenApi`, one `POST /skills/{name}` per skill with schema derived from parameters). `zmodu ai export-skills --out` writes the built-in catalog and `zmodu ai openapi --in/--out` converts any catalog (built-in or app-exported) to OpenAPI. tenant-ai serves both at `GET /api/ai/skills` / `GET /api/ai/skills/openapi` (verified live).
- **LLM policy wiring guide + example**: new `docs/LLM_POLICIES.md` walks through wiring a real `AiProvider` into `llmApprove` / `llmRiskDecide` / `llmDiagnose` / `llmVerify` (LlmPolicyCtx, RAG, json_fn testing, behavior contract), with a companion runnable `examples/llm-policies` (real-model mode via env vars, fake-json fallback so tests stay network-free). Fixed `llmDiagnose` summary parsing (missing `.string`) surfaced by the example, with a regression test. Added to CI example builds.
- **Durable AI run audit**: `zigmodu.ai.run_audit.RunAuditStore` persists one row per workflow/agent/approval run (run_id, kind, status, tenant, steps, duration); attached via `Workflow.audit`, run/resume record automatically. `list(kind, tenant, limit)` filters history; tenant-ai serves it at `GET /api/ai/runs` (tenant-isolated, verified live). `zigmodu.Time` exported from the barrel.
- **AI observability aggregation**: `zigmodu.ai.observability.AiMetrics` merges `WorkflowMetrics` + `AgentMetrics` + `TokenQuota` into one Prometheus document (attach pointers + labels) for a single `/metrics` endpoint; tenant-ai serves it at `GET /api/ai/metrics` (verified live alongside workflow runs).
- **tenant-ai example extended**: workflow endpoints now carry `WorkflowMetrics` and a `GET /api/ai/workflow/graph` Mermaid export of the step pipeline (incl. the approval gate); `ai.WorkflowMetrics` re-exported from the barrel. Verified live.
- **Approval skill bridge**: `registerApprovalRequestSkills` exposes `approval.request` (subject + amount; chain + policy app-registered) so an Agent inside a workflow `.agent` step can submit approvals directly; the escalated run lands in the queue and `resumeRun` continues after the human decides.
- **Workflow graph export**: `Workflow.toMermaid` renders the step graph as a Mermaid `flowchart` — implicit order edges for linear runs, dependency edges for DAG runs, nodes annotated with their kind (llm/skill/agent/approval). Tests cover both layouts.
- **LLM-backed workflow verification**: `zigmodu.ai.llm.llmVerify` implements `VerifyFn` for `Workflow.reflection` — the model judges whether the final output meets the goal (`{"pass":...}`); failures and malformed responses conservatively return `false` (re-run / escalate). Tests cover pass, fail and provider-error paths.
- **Workflow approval gate resume lifecycle**: end-to-end test proving run → `.pending_human` (gate persisted to WAL) → human approves → `resumeRun` continues from the persisted gate and finishes the remaining steps — the human decision is not re-submitted on resume.
- **Workflow approval gate (human-in-the-loop)**: new `.approval` step kind (`{ subject, amount }`) driven by `Workflow.approval_flow` — approved continues, rejected fails the step, escalated stops the run with a new `.pending_human` status so the app can hand the queue to a human and `resumeRun` afterwards (the gate re-runs under the same policy). Test covers both approved → completed and escalated → pending_human.
- **Workflow observability**: `zigmodu.ai.WorkflowMetrics` attaches to `Workflow.metrics` and accumulates `runs` / `completed_steps` / `failed_steps` / `escalations` / `reviews` (reflection re-runs) on every run/resume — including DAG waves; `toPrometheusFormat` exports `zigmodu_ai_workflow_*` counters alongside `AgentMetrics` and `TokenQuota`.
- **Multi-tenant AI example**: `examples/tenant-ai` — two tenants share one app with tenant-scoped AI operations: per-tenant KPI (`kpi.query`), business reports, alert rules, an approval chain with a `PersistentApprovalQueue` that carries `tenant_id` (tenants cannot see or resolve each other's pending items), and a workflow running the registered skills. `ApprovalApi` + `PersistentApprovalQueue` gained optional tenant scoping (`listPending`/`resolve`/`count` take `?i64`); `ai.freeValue` is now exported from the barrel. Added to CI example builds.
- **AI orchestration P2 (RAG context for LLM policies)**: `LlmPolicyCtx` accepts an optional `retriever` + `retrieval_query`; `buildContext` injects top-k retrieved chunks (policies / history / playbooks) into the `llmDiagnose` / `llmApprove` / `llmRiskDecide` prompts so decisions are grounded in business context. Test: keyword retriever chunk appears in the approval prompt and drives the outcome.
- **AI orchestration P2 (persistent approval queue)**: `zigmodu.ai.approval_store.PersistentApprovalQueue` — SQL-backed human approval queue with the same interface as the in-memory one (`push` / `listPending` / `resolve` / `count`, `migrate()` DDL) and a `queuedEscalationPersistent` hook. `ApprovalApi` is now generic over the queue type, so both in-memory and persistent queues mount into the ComptimeRouter unchanged.
- **AI orchestration P2 (outbox→workflow bridge)**: `zigmodu.ai.bridge.OutboxWorkflowBridge` routes outbox entries (exact or prefix topic) into `ai.trigger.fire(input)` — cron / in-process fire / outbox events are now three unified trigger sources; run outcomes flow back through the trigger's outbox writeback.
- **AI orchestration P2 (human approval queue + HTTP API)**: `zigmodu.ai.approval_api` — `ApprovalQueue` (thread-safe in-memory queue), `queuedEscalation` hook for `ApprovalFlow.on_escalated`, and an `ApprovalApi` ComptimeRouter module exposing `GET /approvals/pending`, `POST /approvals/{id}/approve`, `POST /approvals/{id}/reject` (`approval:decide` permission).
- **AI orchestration P2 (LLM default policies)**: `zigmodu.ai.llm` provides `llmDiagnose` / `llmApprove` / `llmRiskDecide` — LLM-backed callbacks for DiagnosisFlow / ApprovalFlow / RiskReview via `LlmPolicyCtx` (`provider` + injectable `json_fn` + `system_hint`); model failures or malformed JSON fall back to escalate (never silently approve). `ApprovalFlow` gains an `on_escalated` hook (+ `escalated_userdata`).
- **End-to-end AI ops example**: `examples/ai-ops` chains the built-in business tools into one runnable pipeline — `BusinessAlert` detect → `DiagnosisFlow` diagnose → `ApprovalFlow` approve (auto-approve small / escalate large) → `NotificationHub` notify → `OutboxConsumer` audit; `zig build run` prints the trace and `zig build test` asserts every stage. Added to CI example builds and the examples README.
- **Built-in business tool (P1, anomaly diagnosis)**: `zigmodu.ai.diagnose.DiagnosisFlow` takes a detected anomaly (from alerts/recon/sla/app code), gathers evidence via configured SQL queries and hands symptom + evidence to a `diagnose` callback (LLM or rule engine) producing likely causes + recommended actions; the result is written to the outbox (`ai.diagnose`) for audit/automation.
- **Built-in business tool (P1, SLA tracker)**: `zigmodu.ai.sla.SlaTracker` tracks monotonic deadlines on business items (tickets/approvals/refunds); `check()` (cron-driven) fires a `warn` when an item enters the deadline window and a `breach` once past it — events go to an `on_sla` callback (e.g. route into `ai.notify`) and the outbox (`ai.sla`) for audit/automation.
- **Built-in business tool (P1, KPI metric queries)**: `zigmodu.ai.kpi` registers app-owned named metrics (name → SQL → value column); the `kpi.query` skill lets an Agent answer business questions like "本周营收多少" by name only, and a programmatic `Kpi.query` returns the metric value for dashboards/automation.
- **Outbox read side (consumer)**: `zigmodu.outbox.OutboxConsumer` polls pending entries (optional topic filter), dispatches to a registered handler (`userdata` + `call`; topic/payload handed over as call-scoped copies) and advances the lifecycle pending → processing → delivered, with `retry_count++` + `error_message` on failure and failed/DLQ after retries are exhausted. Closes the loop for the AI business-tool outbox writebacks (`ai.approval` / `ai.recon` / `ai.notify` / `ai.risk` / `ai.alert`).
- **Built-in business tool (P1, notification hub)**: `zigmodu.ai.notify.NotificationHub` delivers a message to named channels — webhook (via `HttpClient`, HTTP 2xx counts as delivered), custom sink (email/IM/in-app callback with `userdata`+`call`) or durable outbox fallback (`ai.notify`) when no channel matches; delivery failures propagate, nothing is silently dropped. `registerNotifySkills` exposes the `notification.send` skill bridge (LLM supplies channel/title/body; channel targets stay app-registered with an optional allowlist).
- **Built-in business tool (P1, approval chain)**: `zigmodu.ai.approval.ApprovalFlow` runs a request through a configured multi-level chain — each step is decided by a `policy` callback (LLM/RBAC/rule engine) as approved / escalated / rejected, stopping on first rejection or human escalation; every step + a final event is written to the transactional outbox (`ai.approval`). `registerApprovalSkills` exposes the `approval.submit` skill bridge (LLM supplies subject/amount/request only; chain + policy stay app-registered; safe default policy escalates to a human).
- **Built-in business tools (P1, risk + recon)**: `zigmodu.ai.risk.RiskReview` scores a subject via configurable SQL rules → level (low/medium/high) → decision (approve/escalate/reject, `DecideFn` hook for LLM/policy) → outbox writeback (`ai.risk`); `zigmodu.ai.recon.ReconCheck` compares source/target SQL snapshots by key (missing / extra / mismatch), fires per-diff `on_diff`, writes a CLEAN/DRIFT summary to the outbox (`ai.recon`) and renders a Markdown diff report (`renderReport`).
- **Built-in business tool (P1, refund with compensation)**: `zigmodu.ai.refund.RefundFlow` validates → approves → executes a refund as a transactional outbox command → notifies; notify failure auto-emits the compensation command (`refund.reverse`), plus app-initiated `compensate()`.
- **Built-in business tool (P1, ticket triage)**: `zigmodu.ai.ticket.TicketFlow` loads customer/order context, classifies, drafts a reply, runs an approval/send gate (`on_send`) and writes the outcome to the outbox.
- **Built-in business tools (P0)**: `zigmodu.ai.reporter.BusinessReporter` renders configured SQL queries as a Markdown report (cron + outbox = scheduled delivery); `zigmodu.ai.alerts.BusinessAlert` runs SQL rules and alerts (callback + outbox writeback) on any violation row.
- **Workflow linear ↔ DAG hybrid**: steps can declare `depends_on`; when any step has dependencies the runner switches to dependency-aware parallel waves (`max_parallel` via `std.Io.Group`) with cycle detection (`error.CyclicDependency`). Budget, WAL persistence, retry and escalation apply in DAG mode too; reflection stays on the linear final step.
- **AI orchestration P2 (runtime control)**: `zigmodu.ai.AgentHandle` cooperative cancel / pause / step progress (checked at step boundaries; `canceled` flag + metric); `Agent.tracer` + `parent_span` create a run-level span via `DistributedTracer`.
- **AI orchestration P2 (context management)**: `zigmodu.ai.context` auto-compacts long conversations by token threshold — older messages are summarized (via `SummarizeFn`) or dropped, prepended as a system message, keeping a recent window; wired into `Agent` (`Agent.context`, checked each loop iteration).
- **AI orchestration P1 (hierarchical)**: `zigmodu.ai.hierarchy` planner → concurrent executor (`std.Io.Group`, `max_parallel` waves) → aggregation; partial failures surface as `.partial_failed`. Planner/executor are callbacks wireable to `Agent`/`Workflow`.
- **AI orchestration P1 (AgentTrigger)**: `zigmodu.ai.trigger` unifies cron / event / webhook sources into `fire(input)` + `registerCron`; optional transactional-outbox writeback of `{run_id, ok, message}` when an `OutboxPublisher` + SQL backend are configured.
- **AI orchestration P1 (WAL persistence + resume)**: `Workflow.wal` + `run_id` persist each step record to the WAL; `resumeRun(run_id)` replays completed steps and continues from the first unpersisted one (crash recovery / idempotent replay).
- **AI orchestration P1 (reflection + escalation)**: `Workflow` gains a reflection quality gate (`VerifyFn` + `max_reviews` — re-runs the final step until verified) and a human-escalation hook (`on_escalate` on step failure after retries / budget exhaustion / persistent verification failure).
- **AI orchestration (P0)**: `zigmodu.ai.workflow` linear multi-step runner (`.llm` / `.skill` / `.agent` steps, per-step records, retry, stop-on-failure, shared budget) and `zigmodu.ai.Budget` (hard token reservation per step; `.stop`/`.warn` modes; wired into `Agent` — `budget_exhausted` flag + metric). Plan + roadmap in `docs/AI_ORCHESTRATION.md`.
- **sockread performance pass**: `readSome`/`readFull` drop the redundant `poll` (std.Io sockets are blocking, so a bare `read` already waits — syscall count halves); new `sockread.Reader` buffered reader collapses many small reads into one larger syscall, adopted by `WsFramer` frame parsing and the Kafka transport; new `sockread.writevAll` sends header+body in a single `writev` (adopted by `WsFramer.writeFrame`, `ClusterConnection.send`, Kafka `writeFrame`). HttpClient keeps its timeout `waitForReadable`.
- **Built-in business AI skills (P0)**: `zigmodu.ai.business` registers `db.query` (read-only parameterized SELECT, row-capped, rejects literals/comments), `entity.lookup` / `entity.list` (app-registered entity whitelist, tenant-scoped when configured) via `SkillContext.backend_ptr`. Scheduler bridge completed with `list_jobs` / `cancel_job` (`ScheduleCtx` via `SkillContext.userdata`). New `ai.freeValue` defines result ownership (handlers dupe keys/strings; callers deep-free). Plan + roadmap in `docs/AI_SKILLS.md`.
- **Raw socket reads for all long-blocking io read paths**: new `core/sockread` helper (`readSome`/`readFull`/`writeFull`, `posix.poll` + `posix.read`/`write`) now backs the reads that wait for peer data — Redis responses (16 call sites), NATS reads (4), Kafka `readExact`, `DistributedEventBus` connection loop, `ClusterConnection.recv` (fixes partial-header reads) and `send` (loops on partial writes so frames are never split), and `HttpClient` `readResponse`/streaming body reads. Same class of fix as the fiber-mode WebSocket read: with the Threaded Io shared across threads, io-based socket reads can block forever even with data in the kernel buffer.
- **Fiber-mode WebSocket read fixed**: `WsFramer.readFrame` / `WebSocketClient` reads now use raw `posix.poll + posix.read` instead of `io.operate(net_read)`. With the Threaded Io shared across the accept thread, worker fibers and clients, io-based socket reads block forever even when data is in the kernel buffer (reproduced: `poll` readable + `MSG_PEEK` shows bytes, `readv` hangs) — so WS client→server frames, ping/close handling and `on_close` never fired. Writes were unaffected. Added an end-to-end regression test (handshake → masked frame → `on_message` → client close → `on_close`).
- **AI ⇄ cron 薄桥**: `Cron.Scheduler` fixed — the background loop now ticks periodically (`std.Io.sleep`), `addJob` is thread-safe (mutex + name copy) with public `tick()` for deterministic scheduling; `every` is a blocking one-shot helper. New `zigmodu.ai.registerScheduleSkills` exposes `list_schedulable_tasks` / `schedule_job` tools so an Agent can attach pre-registered named tasks to cron expressions (LLM never supplies code). `ScheduledTask.TaskScheduler` marked deprecated (never looped; placeholder next-run math) for removal in v1.0.
- **`HttpClient` pure-HTTP path fixed**: the buffered request writer was never flushed, so the request never reached the peer and `request()` deadlocked in a plain `main` (misdiagnosed earlier as an event-loop dependency). `executeRequest` now flushes after writing headers/body. `timeout_ms` (previously stored but unused) is now honored via `posix.poll` in `readResponse` (`error.Timeout` on a stalled peer). Added loopback end-to-end tests: live request round-trip and stalled-peer timeout.
- **`ctx.header()` is now case-insensitive** (RFC 9110): mixed-case lookups like `"User-Agent"` or `"X-Tenant-ID"` resolve to the lowercased parse-time keys. Fixes latent null-header bugs in `AccessLog`, `middleware/Validation`, and the tenant-mgmt example.
- **Postgres `?N` placeholder bug fixed**: `convertPlaceholders` now consumes sqlite-style `?N` digits so `?1` maps to `$1` (previously `$11`, SQLSTATE 42P18), numbers placeholders sequentially, and skips `?` inside quoted strings/identifiers and `--`/`/* */` comments. Added unit tests covering `?`, `?N`, mixed forms, `?12`, literals and comments.
- **Engineering-quality pass**: repo-wide `zig fmt` (src/tools/examples); fixed `examples/zent-modulith` struct-field syntax error; `Server` global-middleware errors on unmatched routes are now logged; silent I/O/DB error swallows converted to logged catches in redis / ClusterMembership / RaftElection / Orm / WAL / Nats / EventBus / HealthEndpoint / ApplicationView / WorkerPool.
- **`check-production` gate extended** to hot-path modules (redis, Nats, ClusterMembership, DistributedEventBus, RaftElection, WAL, Orm) — previously only Server/sqlx/security were scanned.
- **`DistributedEventBus` connection read loop fixed** for the real `std.Io` (threaded) reader: `readSliceShort` returns a byte count, not a slice; the loop previously failed to compile when a real connection path was instantiated (surfaced by `examples/distributed`).
- **`HttpClient.ConnectionPool` tests now use a real loopback listener** instead of always skipping on `ConnectionRefused` to port 9999.
- **Network-dependent tests skip gracefully** in sandboxed/restricted environments via `src/test/NetworkProbe.zig` (raw-syscall probe) instead of crashing the whole test binary with `errnoBug` on `EPERM`.
- **CI hardening**: `ZIG_VERSION` pinned to `0.17.0-dev.1422+e863bf3be`; `zig fmt --check` now covers `src tools examples`; new `examples` job builds all nine examples (incl. `zent-modulith` with a sibling `zent` checkout); `test-live-services` adds a real Kafka broker (`apache/kafka:3.7.2` KRaft) via `KAFKA_BOOTSTRAP`.
- **Module test helpers are public API**: `zigmodu.ModuleTestContext` and `zigmodu.createMockModule` exported from `root.zig` (consistent with `IntegrationTest`/`Benchmark`/`ContractTest`); `examples/testing` updated off the deprecated `zigmodu.extensions` namespace.
- **Repo hygiene**: tracked `wal_test`/`wal_test2` artifacts removed; `.gitignore` covers `wal_test*` and `.codegraph/`.

### Added
- **WebSocket binary frames**: `on_message` receives text (0x1) **and** binary (0x2) with `WsFrameKind`; fiber + io_uring paths; `WsFramer.writeBinary` / `writeData`. Unblocks OpenIM-style protobuf over WS. **Breaking**: `WsMessageFn` gains `kind` parameter.
- **Selective SQL driver linking**: `-Ddb=all|sqlite|postgres|mysql` (comma-list) via `examples/_shared/db_link.zig`; `build_options.enable_*`; disabled drivers use C stubs (no link) and `Client.connect` returns `error.DriverNotEnabled` (also in `ZigModuError`, HTTP 400). Package consumers: `b.dependency("zigmodu", .{ .db = "sqlite" })`. Scaffold/`--from-db` maps DSN → `.db=`. Framework `zig build test` keeps default `all`; CI integration builds use `-Ddb=sqlite`. Guide: [`docs/SQLX_DRIVERS.md`](docs/SQLX_DRIVERS.md).

### Added
- **zent support — shared helper for examples**: `examples/_shared/zent_helpers.zig` provides `StoreEnv(Driver, Infos).open / inMemory / openWith` (RAII wrapper that replaces the open-driver + migrate + make-client dance) and `TestEnv(schemas).init / reset / deinit` (per-test in-memory SQLite with fresh migrations). Both `examples/zent-modulith/` and `examples/shopdemo-zent/` now use it; `examples/_shared/build.zig` runs the helper's own tests.
- **zent docs extended**: `docs/ZENT.md` adds `§6.1 Testing` (TestEnv pattern), `§6.2 Production: ConnPool` (production driver wrapping), `§6.3 Observability` (zent `sql_logger` → ZigModu logger adapter), and `§6.4 Transactions` (beginTx + savepoint). Shared helper callout at the top.
- **`examples/shopdemo-zent` runnable**: parallel of `examples/shopdemo/` using `zent` (ent-style schema-as-code ORM) instead of `zigmodu.data.sqlx`. Single `order` module with `Order` + `OrderItem` zent Schemas, `OrderStore` persistence, `OrderService` validation, and `OrderApi` exposing `POST/GET /api/v1/orders` plus `POST /api/v1/orders/{order_no}/items`. Demonstrates `docs/ZENT.md`'s orthogonal data-stack rule: each module picks one driver and does not mix or share transactions.
- **Completeness Phase 3 — distributed event bus wiring**: `DistributedEventBus` now actually routes through `Partitioner.route(topic)`, captures send failures in `DLQ` after `max_send_failures` threshold, drains DLQ via a retry fiber, and exposes `connectToNode` / `nodeId` / `clusterSize` for membership integration. `WAL.readFrom` is implemented so `replayFromWal` and `restoreFromWal` actually recover uncommitted entries. `ClusterMembership` keeps the partitioner ring in sync on join / leave / failure.
- **SQLx MySQL binary protocol hardening**: `mysqlFetchStringColumn` re-reads oversized values via `mysql_stmt_fetch_column` instead of silently truncating; `mysqlParseDecimal` / `mysqlParseDateTime` / `mysqlParseJson` validate input strictly (negative TIME allowed, fractional seconds `.[0-9]{1,6}`, JSON via `std.json.parseFromSlice`).
- **`examples/shopdemo` runnable**: `build.zig` / `build.zig.zon` / `src/main.zig` / `src/db/*` added; the single `order` module from `generated-sample/` is migrated with API compatibility fixes; `zig build run` starts the app and `GET /api/v1/orders` returns 200.
- **WorkerPool / EventBus observability**: `WorkerPool.WorkerPoolStats.toPrometheusFormat` renders pool stats as Prometheus text; `TypedEventBus` tracks `published_total` and `dropped_async_total` atomically with `publishedCount` / `droppedAsyncCount` getters.
- **Modulith QPS Phase 2 — async EventBus + WorkerPools**: `core.WorkerPool` (bounded queue, graceful stop, error isolation), `TypedEventBus.subscribeAsync` / `ThreadSafeEventBus.subscribeAsync`, `api.Module.RuntimeOptions.worker_count`, and per-module `WorkerPool` integration in `core.ModuleRuntime`. Includes cross-module pilot test and `max_worker_count = 128` guard (`error.ConfigurationError` for 0 or overflow).
- **Modulith QPS Phase 1 — per-module resource isolation**: `api.Module.RuntimeOptions`, `core.ModuleRuntime` (bulkhead + rate limiter + circuit breaker), `core.ModuleRegistry`, and `Application.getModuleRuntime()`. Thread-safe admission via `std.Io.Mutex`, overflow-safe quota validation, and full backward compatibility for modules without runtime options.
- **SQLx connection pool lifecycle**: per-connection `created_at`/`idle_since` timestamps, max-lifetime / max-idle-time eviction, FIFO waiter fairness, and `PoolMetrics` (acquired/released/created/closed/stale-evicted totals, wait time, max active/idle).
- **SQLx streaming cursor**: `Client.queryCursorEx(sql, args, .{ .mode = .streaming })` with driver-native streaming for MySQL (`mysql_use_result`) and PostgreSQL (`PQsendQueryParams` + `PQsetSingleRowMode`). SQLite falls back to buffered mode.
- **SQLx batch protocols**: `Client.batchInsertEx(table, columns, rows, .{ .mode = .protocol })` uses MySQL prepared-statement multi-execute and PostgreSQL `COPY ... FROM STDIN` (CSV). Falls back to multi-row `INSERT` SQL on failure or SQLite.

### Changed
- **SecretsManager / Vault**: Implemented HashiCorp KV v2 HTTP (`loadFromVault` + `applyVaultKvJson`). Plain HTTP + `X-Vault-Token`; `https://` → `VaultTlsNotSupported`. Live smoke: `VAULT_ADDR` + `VAULT_TOKEN`.
- **gRPC**: Removed EXPERIMENTAL. Unary production path — `GrpcFrame`, `GrpcServiceRegistry.invoke` / `handleHttpUnary`, `GrpcClient.bindLocal` + `initWithIo` HTTP/1.1 `application/grpc`. Streaming still returns `UNIMPLEMENTED`.
- **Kafka**: Hardened wire layer — Produce response error-code check, RecordBatch value parse, Fetch value scan; added roundtrip unit tests. Live smoke still via `KAFKA_BOOTSTRAP` / `ROBUSTMQ_URL`.
- **SQLx**: Removed broken `withRows` helper from `data.zig` re-export (no in-tree callers; called `client.queryRows` without the `T` type parameter).

### Fixed
- **SSE Server lifecycle**: `http.sse` / `markSseResponse` sets `ctx.streaming` so Server does not double-`writeResponse` after the handler; `lastEventId(ctx)`; multiline `data:` splitting; `sendRetry` write-buffer alias fix.

### Added
- **zigmodu.ai Agent P0/P1**: `AiProvider.chatWith` + `tool_calls` parse; `SkillRegistry.toOpenAiFunctionsAlloc` / `dispatchAllowed` / `validateArgs`; first-class `ai.Agent` ReAct loop + `AgentHooks`/`AgentMetrics`; `chatStream` buffered shim; `MemoryStore` composite tenant/user keys + `dumpJson`/`loadJson`.
- **zigmodu.ai skill timeout skeleton**: `Tool.timeout_ms`, `SkillContext.deadline_ms` / `expired` / `checkDeadline`, `dispatchWith` → `error.ToolTimeout` (cooperative; not preemptive).
- **HttpClient.requestStream + AiProvider SSE chatStream**: chunked/content-length/EOF body streaming; OpenAI `data:` delta parse with buffered fallback.
- **MemoryStore file persistence + Agent tool timeout**: `saveToFile`/`loadFromFile`; `Agent.tool_timeout_ms` via `dispatchWith`.
- **HttpClient request wire**: auto `Host` + `Content-Length`; path+query; `https://` → `TlsNotSupported` (plain HTTP only, same posture as Vault/OTLP).
- **AI observability / RAG hooks**: `AgentAuditLog`; `Retriever` + `KeywordRetriever`; `Metrics.toPrometheusFormat` for provider and agent.
- **HttpClient HTTPS**: `https://` via `std.http.Client` (system CA, TLS 1.3); HTTPS `requestStream` incremental body read loop; finer transport errors (`TlsHandshakeFailed` / `DnsFailed` / `Timeout`).
- **Agent HITL + RAG wire-up**: `hooks.on_tool_request` / `ToolApproval`; optional `retriever` merges context into system prompt; scaffold `--with-agent` uses core `zigmodu.ai.Agent` + `AiProvider`.
- **AI stream tool_calls + quota**: `chatStream` accumulates streamed `delta.tool_calls`; `TokenQuota` per-tenant skeleton; scaffold `--with-aichat` uses `*AiProvider` + `chatStream` + shared quota; Agent scaffold persists `ai_agent_run`.
- **AiProvider HTTP status mapping**: `AuthError` / `RateLimited` / `UpstreamError` / transport errors.
## [0.14.17] - 2026-07-31

### Added
- **ComptimeRouter + catalog JWT/RBAC**: modules declare `pub const routes` + `mountAll`; `jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.rbac)`; `CatalogPermLoadInput{ sub, aud, roles }` for custom permission loaders.
- **HTTP ergonomics stack**: typed extractors, ProblemDetails/`respondErr`, scope middleware, Testkit, HTTP/resilience profiles, SSE (`http.sse` / `sse_routes`), OpenAPI param merge, outbox/idempotency barrels.
- **HTTP/2 / gRPC / Kafka depth**: H2 stream states + pump, PRIORITY scheduling, h2c Upgrade, WINDOW_UPDATE/SETTINGS, `Http2Tls` ALPN sidecar; ConnWriter write coalesce and GOAWAY/RST isolation; Kafka consumer-group assignors (incl. cooperative_sticky) + `acknowledgeRevocation`.
- **OTLP/HTTP exporter**: `OtlpExporter.exportSpans` POSTs JSON over plain `http://` with retries (`https://` → `OtlpTlsNotSupported`).

### Changed
- **Legacy JWT middleware**: `rbacJwtMiddleware*` / `jwtAuth*` write **`auth_info` only** (safe with ComptimeRouter `user_data` State); new apps prefer catalog Path A.
- **x402 payment verify**: fail-closed by default; inject `PaymentVerifier` / `verifyPaymentAllowAll` only for explicit dev paths.
- **Docs / AI guides**: `AGENTS.md` canonical agent entry (doc map + DO/DON'T); `CLAUDE.md` / `AI_METHODOLOGY` / `BEST_PRACTICES` / `ROUTE_TABLE` §7 aligned to Path A + ComptimeRouter.

### Fixed
- **OpenAPI JSON strings**: escape quotes/backslashes/control chars in title/version/description/summary via `emitJsonStr`.

## [0.14.16] - 2026-07-24

### Changed
- **SQLx circuit breaker Io handle**: `sqlx/breaker.CircuitBreaker` no longer stores `io`. `allow` / `recordSuccess` / `recordFailure` take `io: std.Io` from the caller (`Client` passes `self.io`), so futex waits always use the live Io handle instead of a copy captured at `Client.init`.

## [0.14.15] - 2026-07-24

### Fixed
- **SQLx `Client.open` pool self-pointer dangling after by-value return**: `ensurePool` stored `ConnPool.client = &local` then `return client` moved the struct, leaving `pool.client` pointing at the dead temporary (SIGSEGV at low addresses like `0x70` on next pool use). `open` no longer creates the pool; call `warmPool()` on the final `*Client` for idle warmup. `ensurePool` always rebinds `pool.client = self`.

## [0.14.14] - 2026-07-24

### Fixed
- **SQLx `Client.ensureBreaker` race / segfault**: `cb` was a lazily initialized `?CircuitBreaker`. Concurrent first-touch from worker fibers could tear the optional write (null/`Io.vtable` → segfault on next `allow`/`record*`, often at low addresses like `0x1a0`). `cb` is now a non-optional `CircuitBreaker` eagerly created in `Client.init`; `ensureBreaker` removed.

## [0.14.13] - 2026-07-24

### Fixed
- **SQLx PostgreSQL SafeAllocator panic (alloc=N+1 / free=N)**: `PostgresConn.stmt_cache` stored `allocZ` (`[:0]u8`) names as `[]const u8`, so LRU eviction / close freed without the sentinel. Cache values are now `CachedStmt([:0]u8)`. Same coerce bug fixed in `queryCursorFn` (`if (args.len==0) slice else [:0]`). `bufPrintZ` reserves the last byte for `\0`. `pgDecodeNumeric` no longer writes through a fixed `[256]u8` stack buffer (heap `ArrayList` + safe `dscale`/`lead_zeros` math).

## [0.8.2] - 2026-05-10

### Fixed
- **SecretsManager**: Inverted priority comparator (`<=` → `>=`) so env > file > vault > default works correctly.
- **SecretsManager**: Double-free in `setWithPriority` when replacing entries — old key freed before `HashMap.remove`.
- **ContractTest**: Double-free in `verifyContract` status check — `allocPrint` strings freed by both local `defer` and `deinit`.
- **LoadShedder**: `now_ms = 0` replaced with `Time.monotonicNowMilliseconds()` — rolling window now advances correctly.
- **Migration parse test**: Isolated with `ArenaAllocator` to prevent allocator-state corruption from prior tests.
- **Version sync**: All version strings unified to v0.8.x across `build.zig.zon`, `main.zig`, and `CHANGELOG.md`.

### Added
- **Graceful shutdown**: `Server.in_flight` request counter + `withGracefulDrain()` wired into `Application.run()` (30s drain timeout, SIGINT/SIGTERM handlers).
- **Prometheus /metrics**: `PrometheusMetrics.registerMetricsRoute()` — one-line `/metrics` in Prometheus text format.
- **Health check context**: `HealthCheck.check_fn` now takes `?*anyopaque` context; `databaseCheck`, `redisCheck`, `diskSpaceCheck` work with real connections.
- **Config validation**: `ExternalizedConfig.validateRequired()` returns missing keys for clear startup errors.
- **ThreadSafeEventBus**: `ThreadSafeEventBus(T)` wraps `TypedEventBus` with `std.Thread.Mutex`.
- **E2E tests**: Server middleware chain + error path, Application lifecycle smoke test, in-flight counter tracking.
- **API Migration Guide**: `docs/API-MIGRATION.md` — Simplified.zig → Application migration path.

### Changed
- **root.zig**: Reorganized from flat 297-line list into 14 named sections with clear category headers.
- **Emoji logs**: Removed all emoji prefixes from production log messages in Application, Lifecycle, ModuleValidator, docs.
- **README**: Updated test count (338 passed, 0 failed), honest production readiness score (84/100), experimental markers on gRPC/Cluster/DistTx/Plugin/WebMonitor/HotReload.
- **CI**: Removed broken `--test-filter` flags from lint job (unsupported by build.zig).

## [0.8.0] - 2026-05-08

### Added

#### Production Hardening (Phase 7)
- **Database Migrations** (`src/migration/Migration.zig`) — Flyway/Liquibase-style versioned migrations with SHA256 checksums, rollback support, status tracking (pending/applied/failed), DDL generation, and filename parsing (`V{timestamp}__{description}.sql`). 10 tests.
- **Secrets Manager** (`src/secrets/SecretsManager.zig`) — Multi-source secrets with priority resolution (env > file > vault > default). Supports K8s/Docker secrets, Vault placeholder, JSON/env content loading, getInt/getBool/getOrDefault/listKeys/exportAsEnv. 10 tests.
- **Docker Support** (`Dockerfile` + `docker-compose.yml`) — Multi-stage build (zig:0.16.0 → alpine:3.21), non-root user, health check. Compose stack includes PostgreSQL 17, Redis 7, Vault 1.18 (profile), Jaeger 1.65 (profile).
- **Timestamp Audit** — Verified all 16 production sites use `Time.monotonicNowSeconds()`. 9 remaining `timestamp=0` in test-only code.

#### Network Verification & Integration (Phase 8)
- **Idempotency Middleware** (`src/http/Idempotency.zig`) — `IdempotencyKey` header-based request deduplication with TTL store, automatic eviction, purge-expired. 5 tests.
- **Module Interaction Verifier** (`src/core/ModuleInteractionVerifier.zig`) — Spring Modulith `verify()`-style architecture validation. Checks circular dependencies, self-dependency, max dependencies, generates ASCII violation reports. 6 tests.
- **OpenAPI Generator** (`src/http/OpenApi.zig`) — Generates OpenAPI 3.0/3.1 JSON from route metadata. Supports endpoints, tags, path/query/header params, response schemas. 4 tests.

#### Modulith Deep Features (Phase 9)
- **gRPC Transport** (`src/core/GrpcTransport.zig`) — Full gRPC service registry with method registration, 16 standard status codes with HTTP mapping, proto file parser (service/method extraction), client stub with endpoint management. 6 tests.
- **Kafka Connector** (`src/core/KafkaConnector.zig`) — Producer with send/sendBatch/flush/close + per-topic statistics, Consumer with subscribe/unsubscribe/getSubscriptions, EventBridge for Kafka ↔ DistributedEventBus integration. Configurable acks, compression, auto_offset_reset. 7 tests.
- **Saga Orchestrator** (`src/core/SagaOrchestrator.zig`) — Automatic compensation with reverse-order rollback on step failure. Saga registration, step logging (started/completed/failed/compensated), instance tracking, active instance listing. 5 tests.
- **Contract Testing** (`src/test/ContractTest.zig`) — Consumer-Driven Contract (Pact-style) verification. Validates HTTP status, response body contains, and response headers against defined contracts. Generates ASCII pass/fail reports. 6 tests.
- **CI/CD Pipeline** (`.github/workflows/ci.yml`) — GitHub Actions workflow with matrix build (ubuntu + macOS), caching, fmt check, full test suite, architecture validation, security scan, benchmarks (ReleaseFast), multi-platform Docker build (amd64/arm64), GitHub Release with artifacts.

### Changed
- **`root.zig`** — Added 30+ new exports for Phases 7-9 modules in ADVANCED API section
- **`tests.zig`** — Added compilation gates for all new modules
- **`AGENTS.md`** — Updated with all new module conventions, middleware patterns, migration/secrets/saga/Kafka/gRPC usage examples
- **`README.md`** — Comprehensive update with new features, project structure, Docker quick start
- **`docs/API.md`** — Added API references for Migration, Secrets, Idempotency, OpenAPI, gRPC, Kafka, Saga, ContractTest
- **`docs/COMPLETENESS_REPORT.md`** — Updated scores: 93/100 production readiness
- **`docs/EVALUATION_REPORT.md`** — Final evaluation with Phase 7-9 coverage

### Test Results
- **282 passed**, 5 skipped, 2 failed (pre-existing)
- +53 new tests across Phases 7-9
- All timestamp-related bugs resolved; no `timestamp=0` in production code

## [0.7.0] - 2026-04-23

### ⚠️ Breaking Changes

- **`ModuleInfo.init()`** now takes 3 arguments `(name, desc, deps)` instead of 4. The `ptr` field is now `?*anyopaque` (nullable, default `null`). Update all call sites.
- **`ModuleInfo.init_fn` / `deinit_fn`** signatures changed from `fn(*anyopaque)` to `fn(?*anyopaque)`.

### Added

- **`core/Time.zig`** — Centralized monotonic time utility using `clock_gettime(CLOCK_MONOTONIC)`. Replaces all hardcoded `const now = 0` throughout the codebase (16 occurrences across 10 files).
- **`root.zig`** — Exports `time` module as `zigmodu.time`.
- **3 new tests** for Time.zig (monotonicity, positive values).

### Fixed

- 🔴 **Timestamp system**: All time-dependent subsystems now use real monotonic time:
  - `CircuitBreaker` — OPEN→HALF_OPEN timeout transition now works
  - `RateLimiter` — Token bucket refill now works with real elapsed time
  - `SlidingWindowRateLimiter` — Window cleanup now works
  - `CacheManager` — TTL expiration now works
  - `DistributedTracer` — Span durations now have real values
  - `TaskScheduler` / `Cron` — Scheduling now uses real time
  - `HttpClient.Connection.isAlive()` — Idle timeout detection now works
  - `ClusterMembership` — Health check timeout detection now works
  - `sqlx/breaker.zig` — Circuit breaker now works

- 🔴 **`ModuleInfo.ptr` UB**: Eliminated `undefined` initialization. Ptr is now nullable `?*anyopaque` with default `null`. Tests no longer trigger undefined behavior.

- 🔴 **Version inconsistency**: Unified version to `0.7.0` across `build.zig.zon`, `main.zig`, `CHANGELOG.md`, and `AGENTS.md`.

- 🔴 **build.zig test paths**: Replaced hardcoded macOS Homebrew paths with dynamic detection via `detectPqPaths()`/`detectMysqlPaths()`. Tests now work on Linux/CI.

- **`ApplicationModules.register()`**: Now invalidates cached `sorted_order` to prevent stale topological sort after module set changes.
