# ZigModu Documentation

Comprehensive documentation for the ZigModu modular framework.

## 📚 Core Guides

| Guide | Description | Level |
|-------|-------------|-------|
| [Quick Start](QUICK-START.md) | Get started in 5 minutes | Beginner |
| [Modulith 高并发](MODULITH.md) | Day-one modulith boundaries + concurrency | All |
| [领域分层](MODULE_LAYERS.md) | model / persistence.Tx / service Cmd | All |
| [多租户店蓝图](MODULITH_TENANT_SHOP.md) | Module graph + directory for tenant shop | All |
| [ZigModu × zent](ZENT.md) | Orthogonal zent ORM + modulith practices | Intermediate |
| [zmodu CLI 生成器](ZMODU_CLI_INTEGRATION.md) | DDL schema generator + `@initialized` model + MCP | All |
| [Best Practices](BEST_PRACTICES.md) | Architecture evolution from 1K to 1M+ DAU | All |

| [Elegant Code Patterns](elegant-code-patterns.md) | Five-file layout + code samples | Intermediate |
| [API Reference](API.md) | Detailed API documentation | Advanced |
| [Architecture](ARCHITECTURE.md) | System design and patterns | Intermediate |

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