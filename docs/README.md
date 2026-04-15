# ZigModu Documentation

Comprehensive documentation for the ZigModu modular framework.

## 📚 Core Guides

| Guide | Description | Level |
|-------|-------------|-------|
| [Quick Start](../QUICK-START.md) | Get started in 5 minutes | Beginner |
| [Best Practices](../BEST_PRACTICES.md) | Architecture evolution from 1K to 1M+ DAU | All |
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
- PasRaftAdapter - Consensus

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
| [DI](../examples/dependency-injection/) | Dependency injection |
| [Testing](../examples/testing/) | Test utilities |

## 🌍 Translations

- [English](../README.md)
- [中文](../README.zh.md)

## 🤝 Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md)

## 📄 License

MIT - See [LICENSE](../LICENSE)