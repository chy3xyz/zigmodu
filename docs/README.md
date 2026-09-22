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

## 📎 Other documents

These are referenced by task but were not indexed before — kept as-is.

| Doc | What it covers |
|-----|----------------|
| [LOGGING.md](LOGGING.md) | Structured logging: levels, fields, sinks |
| [MIGRATION_v04_to_v07.md](MIGRATION_v04_to_v07.md) | Historical upgrade guide v0.4 → v0.7 (older than [UPGRADING.md](UPGRADING.md)) |
| [ZIGMODU_NOTES.md](ZIGMODU_NOTES.md) | Field notes from a real project integration (v0.14.x) |
| [docs/dev/](dev/) | Internal review / assessment / roadmap scratch notes (not user-facing contracts). **先看 [dev/README.md](dev/README.md)** —— 22 份里哪几份仍生效、哪几份被哪一份取代、哪些路径被源码按字面引用不能动 |

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
