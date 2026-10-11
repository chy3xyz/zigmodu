# ZigModu Documentation

Comprehensive documentation for the ZigModu modular framework.

## 🤖 For AI agents

| Doc | Role |
|-----|------|
| [**AGENTS.md**](../AGENTS.md) | **Canonical** — doc map, DO/DON'T, ComptimeRouter, Path A auth |
| [CLAUDE.md](../CLAUDE.md) | Compact Claude Code rules (points to AGENTS) |
| [AI_METHODOLOGY.md](AI_METHODOLOGY.md) | Why modulith + AI; anti-patterns (philosophy) |
| [ROUTE_TABLE.md](ROUTE_TABLE.md) §7 | Auth / RBAC detail |
| [BEST_PRACTICES.md](BEST_PRACTICES.md) | DAU + JWT checklist |
| [AI.md](AI.md) | LLM **chat product** module (`--with-aichat`) — not agent ops |
| [AI_DEV_GUIDE.md](AI_DEV_GUIDE.md) | **AI 开发指南**：KeyManager → Provider → Skill → Agent/Workflow → 接入（HTTP/cron/outbox/MCP） |
| [AI_SKILLS.md](AI_SKILLS.md) | 内置 AI 技能目录（db.query / kpi / approval / admin…） |
| [AI_ORCHESTRATION.md](AI_ORCHESTRATION.md) | Workflow 编排（线性/DAG/审批门/WAL 恢复/触发/审计） |
| [LLM_POLICIES.md](LLM_POLICIES.md) | LLM 策略真实接线（审批/风控/诊断/质量门 + KeyPool） |
| [MCP.md](MCP.md) | SkillRegistry → MCP 桥（外部 LLM 平台调用框架技能） |

## 📚 Core Guides

| Guide | Description | Level |
|-------|-------------|-------|
| [Quick Start](QUICK-START.md) | Get started in 5 minutes | Beginner |
| [Modulith 高并发](MODULITH.md) | Day-one modulith boundaries + concurrency | All |
| [领域分层](MODULE_LAYERS.md) | model / persistence.Tx / service Cmd | All |
| [多租户店蓝图](MODULITH_TENANT_SHOP.md) | Module graph + directory for tenant shop | All |
| [ZigModu × zent](ZENT.md) | **电商/社交主推组合**：zent ORM + modulith practices | Intermediate |
| [SQLx 驱动链接](SQLX_DRIVERS.md) | `-Ddb=` / `.db=` 选择性链接、stub、测试约定 | All |
| [zmodu CLI 生成器](ZMODU_CLI_INTEGRATION.md) | DDL schema generator + `@initialized` model + MCP | All |
| [Best Practices](BEST_PRACTICES.md) | Architecture evolution + JWT / auth checklist | All |
| [Declarative Routes](ROUTE_TABLE.md) | ComptimeRouter + catalog JWT / RBAC gate (§7) | All |
| [Elegant Code Patterns](elegant-code-patterns.md) | Five-file layout + code samples | Intermediate |
| [API Reference](API.md) | Detailed API documentation | Advanced |
| [Architecture](ARCHITECTURE.md) | System design and patterns | Intermediate |
| [Framework Backlog](FRAMEWORK_BACKLOG.md) | Extractors / SSE / Testkit recipes | Intermediate |
| [**Observability**](OBSERVABILITY.md) | 黄金信号、PromQL、告警阈值、Grafana dashboard、上线自检 | Advanced |
| [Production Roadmap](PRODUCTION_ROADMAP.md) | 维护边界、prefork 边界、`src/ai` 可剔离域 | Advanced |
| [部署参考](../examples/production-deploy/README.md) | TLS 边车、探针语义、`Restart=always`、Dockerfile | Advanced |

## 🧱 Core specifications

The contracts the rest of the docs defer to. Read these before the guides above —
they are where "what does the framework actually promise" is written down.

| Spec | Covers |
|------|--------|
| [**RUNTIME.md**](RUNTIME.md) | Execution plane: workers, mailboxes, pools, priorities, supervision, determinism, metrics (§8 / §12 / §15). **2 630 lines — the single largest doc, and the one most often needed.** |
| [**DISTRIBUTED.md**](DISTRIBUTED.md) | Raft / bus / membership, the transport-encryption boundary (A-2), per-node identity, rotation |
| [**API_FREEZE.md**](API_FREEZE.md) | The frozen API surface vs the preview surface, before 1.0 |
| [**ARCHITECTURE.md**](ARCHITECTURE.md) | System design and the module/layer rules everything else assumes |
| [**API.md**](API.md) | Full API reference |
| [**EVENTS_DI.md**](EVENTS_DI.md) | EventBus + DI: how `Application` wires them, and the runnable sample |
| [**WORKFLOW.md**](WORKFLOW.md) | Long-running, resumable processes |
| [**AGENT_RUNTIME.md**](AGENT_RUNTIME.md) | Agent runtime — **agents cannot act by default** (v0.21+) |
| [**AI_BOUNDARY.md**](AI_BOUNDARY.md) | Preconditions for extracting the `ai` package (v0.20.1+) |
| [**CLUSTER-QUICKSTART.md**](CLUSTER-QUICKSTART.md) | Single-node cluster in five minutes |
| [**WEB4.md**](WEB4.md) | DID identity + x402 payments |

## 📎 Field notes & project history

Not contracts. Kept because each records something that happened in a real
integration, and the lesson is worth more than the rule it produced.

| Doc | What it covers |
|-----|----------------|
| [LOGGING.md](LOGGING.md) | Structured logging: levels, fields, sinks |
| [elegant-code-patterns.md](elegant-code-patterns.md) | Five-file layout + handler/input/response conventions |
| [best-practices-heysen-lessons.md](best-practices-heysen-lessons.md) | Lessons from a real SaaS integration (SQLx / ORM / route conventions) |
| [ZIGMODU_NOTES.md](ZIGMODU_NOTES.md) | Field notes from another real integration (v0.14.x) |
| [ISSUES_FROM_ZAPI.md](ISSUES_FROM_ZAPI.md) | Backlog raised by one downstream project |
| [ISSUES_FROM_ZIGSHOP.md](ISSUES_FROM_ZIGSHOP.md) | Issues raised by another — with what was verified and how |
| ~~[COMPLETENESS_REPORT.md](archive/superseded/COMPLETENESS_REPORT.md)~~ | 2026-05-08 / v0.8.0 的历史快照，已归档——**看到就别照做** |
| [MIGRATION_v04_to_v07.md](MIGRATION_v04_to_v07.md) | Historical upgrade guide v0.4 → v0.7 (older than [UPGRADING.md](UPGRADING.md)) |
| [API-MIGRATION.md](API-MIGRATION.md) | Simplified API → `Application` API (older than [UPGRADING.md](UPGRADING.md)) |
| *(`modules.md`)* | Generated by `zig build docs` — not tracked, so there is nothing to link. The long form is [MODULE_LAYERS.md](MODULE_LAYERS.md) |

## 🔒 Project status & governance

| Doc | What it covers |
|-----|----------------|
| [**EVALUATION_2026-10.md**](EVALUATION_2026-10.md) | **Current** quality & competitiveness assessment (86.4/100, 7 weighted axes) |
| [EVALUATION_REPORT.md](EVALUATION_REPORT.md) | ⛔ Superseded 2026-10-10 — kept because source comments cite it by path. **Do not quote its numbers.** |
| [`../GOVERNANCE.md`](../GOVERNANCE.md) | Who decides what, and how to push for a change |
| [`../SECURITY.md`](../SECURITY.md) | Reporting a vulnerability; the attack surface this project admits to |
| [FRAMEWORK_BACKLOG.md](FRAMEWORK_BACKLOG.md) | Deferred work, kept visible rather than forgotten |
| [PRODUCTION_ROADMAP.md](PRODUCTION_ROADMAP.md) | Maintenance boundaries, prefork boundary, removable domains |
| [docs/dev/](dev/README.md) | Internal review / assessment / roadmap notes (not user-facing contracts). **先看 [dev/README.md](dev/README.md)** —— 哪几份仍生效、哪几份被哪一份取代、哪些路径被源码按字面引用不能动 |
| [docs/archive/](archive/README.md) | 已完成的实施计划（2026-07 的 modulith / sqlx 批次）。产出早已落在正式文档里，计划本身只作史料 |

## 🔧 Features

### Core
- Module definition and lifecycle
- Dependency validation
- Event-driven architecture

### Distributed
- DistributedEventBus - Cross-node communication
- ClusterMembership - Node discovery
- DistributedTransaction - Saga pattern

### Resilience
- CircuitBreaker - Prevent cascade failures
- RateLimiter - Token bucket throttling

### Observability
- DistributedTracer - OpenTelemetry compatible tracing
- PrometheusMetrics - Counter, Gauge, Histogram
- `productionProfile` - `/metrics` golden signals (traffic / status classes /
  latency histogram) + `/health/live` + `/health/ready` in one call
- Grafana dashboard + alert thresholds: [`OBSERVABILITY.md`](OBSERVABILITY.md)

### Production hardening
- Connection backpressure (`max_connections`, `over_limit_response`) and header
  deadline (`header_timeout_ms`, slowloris)
- WebSocket outbound backpressure (`ws_write_timeout_ms`, `WsFramer.isWritable`)
- `FrozenMap` / `FrozenStringMap` - freeze shared registries before serving
- `panicHook` - panic output carries the in-flight `METHOD /path`
- Deployment topology reference: [`../examples/production-deploy/`](../examples/production-deploy/)
- `DistributedLock` - one replica runs each cron job / applies migrations
  (`cron.setLock` / `MigrationRunner.setLock`). Table lock tested on SQLite and
  on a real PostgreSQL 17 (`ZIGMODU_TEST_PG=1`, CI `test-postgres`); the MySQL
  dialect (`INSERT IGNORE`) is implemented but not yet covered by a real server
  test
- `Preflight` - refuse to boot on missing env / placeholder secrets / unreachable
  DB / pending migrations / skewed clock
- JWT key rotation (`JwksKeyRing`) - tokens carry `kid`, old keys keep verifying
- Outbox + DB pool metrics (`setMetrics` / `poolMetrics` / `setScrapeHook`)
- Test templates: fault injection (`src/test/FaultInjection.zig`) and contract
  gate (`src/test/ContractGate.zig`)

## 📁 Examples

| Example | Description |
|---------|-------------|
| [Basic](../examples/basic/) | Module fundamentals |
| [Event-Driven](../examples/event-driven/) | Publish-subscribe |
| [Testing](../examples/basic/) | Test utilities (`src/tests.zig` in basic) |
| [HTTP Stress Test](../examples/http-stress-test/) | Concurrent connections |
| [zent-modulith](../examples/zent-modulith/) | ZigModu HTTP + zent schema-as-code ORM |
| [Metaverse Creative](../examples/metaverse-creative/) | Creative demo |

## 🌍 Translations

- [English](../README.md)
- [中文](../README.zh.md)

## 🤝 Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md)

## 📄 License

MIT - See [LICENSE](../LICENSE)
