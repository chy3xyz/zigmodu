# zmodu Documentation

Comprehensive documentation for the zmodu modular framework.

**官网**：[https://chy3xyz.github.io/zmodu/](https://chy3xyz.github.io/zmodu/)

## 📁 目录结构

| 目录 | 放什么 | 判断依据 |
|------|--------|---------|
| [`guide/`](./guide/QUICK-START.md) | 教程与任务导向：「我要做 X」 | 按**上手路径**组织 |
| [`reference/`](./reference/RUNTIME.md) | 契约：框架实际承诺什么 | **零历史、零待办**，只描述现状 |
| [`ai/`](./ai/AI.md) | AI 子系统（与上面两组正交） | 按**能力切面**分：产品 chat / 编排 / 技能 / 策略 / MCP |
| `dev/` | 内部设计笔记、方法论 | 不面向使用者 |
| [`archive/`](./archive/README.md) | 已归档史料与状态快照 | **有时效**，会过期 |
| `README.md` `index.md` | 本索引 / 站点首页 | — |

**手册区只有 `guide/` `reference/` `ai/` 三处。** 评估报告、生产路线图、backlog、
外部反馈台账都搬进了 [`archive/`](./archive/README.md)——它们是**某一时点的裁决**，
框架怎么用不取决于它们。原 `meta/` 目录已不再存在。

> 分组依据是**文档之间的实际引用**，不是主题相似度。实测链接图只聚为两簇
> （交叉率 5%），所以没有按「运行时/数据/网络」这类主题再切——那样做只会把
> 互链切断 58%。`ai/` 是例外：它自成一体、互链密集，且与其余文档正交。

## 🤖 For AI agents

**权威路由是 [`AGENTS.md`](../AGENTS.md)** —— 它的"文档地图"一节已经给出每类任务该读哪份。
下表只是从本索引进来的快捷方式。

| Doc | Role |
|-----|------|
| [**AGENTS.md**](../AGENTS.md) | **Canonical** — doc map, DO/DON'T, ComptimeRouter, Path A auth |
| [CLAUDE.md](../CLAUDE.md) | Compact Claude Code rules (points to AGENTS) |
| [ROUTE_TABLE.md](./reference/ROUTE_TABLE.md) §7 | Auth / RBAC detail |
| [BEST_PRACTICES.md](./guide/BEST_PRACTICES.md) | DAU + JWT checklist |
| [**ai/**](./ai/README.md) | **AI 子系统入口** — 先看这一页定位你要哪条线，再进具体文档 |
| [AI_DEV_GUIDE.md](./ai/AI_DEV_GUIDE.md) | **AI 开发指南**：KeyManager → Provider → Skill → Agent/Workflow → 接入（HTTP/cron/outbox/MCP） |
| [AI_SKILLS.md](./ai/AI_SKILLS.md) | 内置 AI 技能目录（db.query / kpi / approval / admin…） |
| [AI_ORCHESTRATION.md](./ai/AI_ORCHESTRATION.md) | Workflow 编排（线性/DAG/审批门/WAL 恢复/触发/审计） |
| [LLM_POLICIES.md](./ai/LLM_POLICIES.md) | LLM 策略真实接线（审批/风控/诊断/质量门 + KeyPool） |
| [MCP.md](./ai/MCP.md) | SkillRegistry → MCP 桥（外部 LLM 平台调用框架技能） |

## 📚 Core Guides

| Guide | Description | Level |
|-------|-------------|-------|
| [Quick Start](./guide/QUICK-START.md) | Get started in 5 minutes | Beginner |
| [Modulith 高并发](./guide/MODULITH.md) | Day-one modulith boundaries + concurrency | All |
| [领域分层](./guide/MODULE_LAYERS.md) | model / persistence.Tx / service Cmd | All |
| [多租户店蓝图](./guide/MODULITH_TENANT_SHOP.md) | Module graph + directory for tenant shop | All |
| [zmodu × zent](./reference/ZENT.md) | **电商/社交主推组合**：zent ORM + modulith practices | Intermediate |
| [SQLx 驱动链接](./guide/SQLX_DRIVERS.md) | `-Ddb=` / `.db=` 选择性链接、stub、测试约定 | All |
| [zmodu CLI 生成器](./guide/ZMODU_CLI_INTEGRATION.md) | DDL schema generator + `@initialized` model + MCP | All |
| [Best Practices](./guide/BEST_PRACTICES.md) | Architecture evolution + JWT / auth checklist | All |
| [Declarative Routes](./reference/ROUTE_TABLE.md) | ComptimeRouter + catalog JWT / RBAC gate (§7) | All |
| [Elegant Code Patterns](./archive/elegant-code-patterns.md) | Five-file layout + code samples | Intermediate |
| [API Reference](./reference/API.md) | Detailed API documentation | Advanced |
| [Architecture](./reference/ARCHITECTURE.md) | System design and patterns | Intermediate |
| [Framework Backlog](./archive/status/FRAMEWORK_BACKLOG.md) | Extractors / SSE / Testkit recipes | Intermediate |
| [**Observability**](./reference/OBSERVABILITY.md) | 黄金信号、PromQL、告警阈值、Grafana dashboard、上线自检 | Advanced |
| [Production Roadmap](./archive/status/PRODUCTION_ROADMAP.md) | 维护边界、prefork 边界、`src/ai` 可剔离域 | Advanced |
| [部署参考](./README.md) | TLS 边车、探针语义、`Restart=always`、Dockerfile | Advanced |

## 🧱 Core specifications

The contracts the rest of the docs defer to. Read these before the guides above —
they are where "what does the framework actually promise" is written down.

| Spec | Covers |
|------|--------|
| [**RUNTIME.md**](./reference/RUNTIME.md) | Execution plane: workers, mailboxes, pools, priorities, supervision, determinism, metrics (§8 / §12 / §15). **The largest contract doc, and the one most often needed** |
| [**DISTRIBUTED.md**](./reference/DISTRIBUTED.md) | Raft / bus / membership, the transport-encryption boundary (A-2), per-node identity, rotation |
| [**API_FREEZE.md**](./reference/API_FREEZE.md) | The frozen API surface vs the preview surface, before 1.0 |
| [**ARCHITECTURE.md**](./reference/ARCHITECTURE.md) | System design and the module/layer rules everything else assumes |
| [**API.md**](./reference/API.md) | Full API reference |
| [**EVENTS_DI.md**](./guide/EVENTS_DI.md) | EventBus + DI: how `Application` wires them, and the runnable sample |
| [**WORKFLOW.md**](./guide/WORKFLOW.md) | Long-running, resumable processes |
| [**AGENT_RUNTIME.md**](./reference/AGENT_RUNTIME.md) | Agent runtime — **agents cannot act by default** (v0.21+) |
| [**AI_BOUNDARY.md**](./reference/AI_BOUNDARY.md) | 抽包前置条件（v0.20.1+）；`src/test/AiBoundary.zig` 持续核对，是**活的契约**不是决策记录 |
| [**CLUSTER-QUICKSTART.md**](./guide/CLUSTER-QUICKSTART.md) | Single-node cluster in five minutes |
| [**WEB4.md**](./reference/WEB4.md) | DID identity + x402 payments |

## 📎 Field notes

Not contracts. Kept because each records something that happened in a real
integration, and the lesson is worth more than the rule it produced.

| Doc | What it covers |
|-----|----------------|
| [LOGGING.md](./guide/LOGGING.md) | Structured logging: levels, fields, sinks |
| [elegant-code-patterns.md](./archive/elegant-code-patterns.md) | Five-file layout + handler/input/response conventions |
| [best-practices-heysen-lessons.md](./archive/best-practices-heysen-lessons.md) | Lessons from a real SaaS integration (SQLx / ORM / route conventions) |
| [ZMODU_NOTES.md](./archive/status/ZMODU_NOTES.md) | Field notes from another real integration (v0.14.x) |
| [ISSUES_FROM_ZAPI.md](./archive/status/ISSUES_FROM_ZAPI.md) | Backlog raised by one downstream project |
| [ISSUES_FROM_ZIGSHOP.md](./archive/status/ISSUES_FROM_ZIGSHOP.md) | Issues raised by another — with what was verified and how |
| *(`modules.md`)* | Generated by `zig build docs` — not tracked, so there is nothing to link. The long form is [MODULE_LAYERS.md](./guide/MODULE_LAYERS.md) |

## 🗄 Historical & superseded

**这些不是现行指引。** 保留是因为源码注释按路径引用它们（移动会打断 367 处指针），
或因为它们记录了真实的版本演进。**照着做会错**——每份都在文件头写明了作废理由。

| Doc | Status |
|-----|--------|
| [MIGRATION_v04_to_v07.md](./archive/status/MIGRATION_v04_to_v07.md) | 历史升级指南 v0.4 → v0.7，已被 [UPGRADING.md](./reference/UPGRADING.md) 覆盖 |
| [API-MIGRATION.md](./archive/status/API-MIGRATION.md) | 旧 Simplified API → `Application` API，已被 [UPGRADING.md](./reference/UPGRADING.md) 覆盖 |
| ~~[COMPLETENESS_REPORT.md](./archive/superseded/COMPLETENESS_REPORT.md)~~ | 2026-05-08 / v0.8.0 快照，已归档——**看到就别照做** |
| [EVALUATION_REPORT.md](./archive/status/EVALUATION_REPORT.md) | ⛔ 分数与逐维读数**全部作废**（2026-10-10），取代它的是 [EVALUATION_2026-10.md](./archive/status/EVALUATION_2026-10.md) |

## 🔒 Project status & governance

| Doc | What it covers |
|-----|----------------|
| [**EVALUATION_2026-10.md**](./archive/status/EVALUATION_2026-10.md) | **Current** quality & competitiveness assessment (86.4/100, 7 weighted axes) |
| [`../GOVERNANCE.md`](../GOVERNANCE.md) | Who decides what, and how to push for a change |
| [`../SECURITY.md`](../SECURITY.md) | Reporting a vulnerability; the attack surface this project admits to |
| [FRAMEWORK_BACKLOG.md](./archive/status/FRAMEWORK_BACKLOG.md) | Deferred work, kept visible rather than forgotten |
| [PRODUCTION_ROADMAP.md](./archive/status/PRODUCTION_ROADMAP.md) | Maintenance boundaries, prefork boundary, removable domains |
| [docs/dev/](./dev/README.md) | Internal design notes and methodology (not user-facing contracts). **先看 [dev/README.md](./dev/README.md)** —— 哪几份仍生效、哪几份被哪一份取代 |
| [docs/archive/](./archive/README.md) | 已归档史料与状态快照（评估、路线图、backlog、外部反馈）。**从 [archive/README.md](./archive/README.md) 进** |

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
- Grafana dashboard + alert thresholds: [`OBSERVABILITY.md`](./reference/OBSERVABILITY.md)

### Production hardening
- Connection backpressure (`max_connections`, `over_limit_response`) and header
  deadline (`header_timeout_ms`, slowloris)
- WebSocket outbound backpressure (`ws_write_timeout_ms`, `WsFramer.isWritable`)
- `FrozenMap` / `FrozenStringMap` - freeze shared registries before serving
- `panicHook` - panic output carries the in-flight `METHOD /path`
- Deployment topology reference: [`../examples/production-deploy/`](../examples/production-deploy/)
- `DistributedLock` - one replica runs each cron job / applies migrations
  (`cron.setLock` / `MigrationRunner.setLock`). Table lock tested on SQLite and
  on a real PostgreSQL 17 (`ZMODU_TEST_PG=1`, CI `test-postgres`); the MySQL
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
| [zent-modulith](../examples/zent-modulith/) | zmodu HTTP + zent schema-as-code ORM |
| [Metaverse Creative](../examples/metaverse-creative/) | Creative demo |

## 🌍 Translations

- [English](./README.md)
- [中文](../README.zh.md)

## 🤝 Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md)

## 📄 License

MIT - See [LICENSE](../LICENSE)
