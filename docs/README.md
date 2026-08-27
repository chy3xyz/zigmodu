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

## 📁 Examples

| Example | Description |
|---------|-------------|
| [Basic](../examples/basic/) | Module fundamentals |
| [Event-Driven](../examples/event-driven/) | Publish-subscribe |
| [Testing](../examples/testing/) | Test utilities |
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
