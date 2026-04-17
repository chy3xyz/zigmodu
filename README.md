# ZigModu

A modular application framework for Zig 0.16.0, inspired by Spring Modulith. Build scalable applications from monolithic to distributed systems with progressive architecture evolution.

[![Zig](https://img.shields.io/badge/Zig-0.16.0+-orange?style=flat-square)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Build](https://img.shields.io/badge/Build-Passing-green?style=flat-square)](https://github.com/knot3bot/zigmodu/actions)

## 📚 Documentation

| Guide | Description |
|-------|-------------|
| [Quick Start](QUICK-START.md) | Get started in 5 minutes |
| [Best Practices](BEST_PRACTICES.md) | Architecture evolution from 1K to 1M+ DAU |
| [API Reference](docs/API.md) | Detailed API documentation |
| [Architecture](docs/ARCHITECTURE.md) | System design and patterns |
| [Examples](examples/) | Runnable example projects |

## ✨ Features

### Core Framework
- **Module System** - Declarative module definition with metadata
- **Dependency Validation** - Compile-time dependency checking
- **Lifecycle Management** - Automatic init/deinit orchestration
- **Event-Driven** - Type-safe event bus for decoupled communication

### Distributed Capabilities
- **DistributedEventBus** - Cross-node event communication
- **ClusterMembership** - Node discovery and health checking
- **PasRaft Consensus** - Leader election and log replication

### Resilience Patterns
- **Circuit Breaker** - Prevent cascade failures
- **Rate Limiter** - Token bucket throttling
- **Retry Policy** - Exponential backoff

### Transport & API
- **GraphQL Gateway** - Query language for APIs
- **gRPC Transport** - High-performance RPC
- **MQTT Transport** - IoT message queue

### Observability
- **Distributed Tracing** - OpenTelemetry compatible
- **Prometheus Metrics** - Counter, Gauge, Histogram
- **Structured Logging** - JSON formatted logs

### Developer Experience
- **Hot Reloading** - Runtime module updates
- **Plugin System** - Dynamic extension loading
- **Web Monitor** - HTTP dashboard for module inspection
- **Architecture Tester** - Validate design rules

## 🚀 Quick Start

### Prerequisites

```bash
# Install Zig 0.16.0
brew install zig@0.16.0  # macOS
# or
apt install zig=0.16.0   # Linux
```

### Create Your First Module

```zig
// src/modules/user.zig
const std = @import("std");
const zigmodu = @import("zigmodu");

const UserModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "user",
        .description = "User management module",
        .dependencies = &.{},
    };

    pub fn init() !void {
        std.log.info("User module initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("User module cleaned up", .{});
    }
};
```

### Bootstrap Application

```zig
// src/main.zig
const std = @import("std");
const zigmodu = @import("zigmodu");

const user = @import("modules/user.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var modules = try zigmodu.scanModules(allocator, .{user});
    defer modules.deinit();

    try zigmodu.validateModules(&modules);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);

    std.log.info("Application started!", .{});
}
```

### Build and Run

```bash
zig build run
```

## 📖 Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    ZigModu Application                   │
│  ┌─────────────────────────────────────────────────────┐ │
│  │                 Module System                       │ │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │ │
│  │  │  User   │ │  Order  │ │ Payment │ │ Product │  │ │
│  │  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘  │ │
│  │       └───────────┴────────────┴───────────┘        │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
         │
    ┌─────┴─────┐
    │           │
┌───▼───┐   ┌──▼────┐
│ Event │   │  DI   │
│  Bus  │   │Container│
└───────┘   └───────┘
```

## 📁 Project Structure

```
zigmodu/
├── src/
│   ├── core/           # Core framework
│   │   ├── Module.zig
│   │   ├── EventBus.zig
│   │   ├── Lifecycle.zig
│   │   └── ...
│   ├── extensions/      # Extended features
│   │   ├── di/
│   │   ├── config/
│   │   └── log/
│   ├── resilience/      # Resilience patterns
│   │   ├── CircuitBreaker.zig
│   │   └── RateLimiter.zig
│   ├── tracing/        # Observability
│   │   └── DistributedTracer.zig
│   ├── metrics/        # Metrics
│   │   └── PrometheusMetrics.zig
│   └── api/            # Public API
│       └── Simplified.zig
├── docs/               # Documentation
├── examples/           # Example projects
│   ├── basic/          # Basic module demo
│   ├── event-driven/   # Event-driven architecture
│   ├── distributed/    # Distributed deployment
│   └── ...
└── tests/              # Test suite
```

## 🎯 Progressive Evolution

ZigModu grows with your application:

| Stage | Users/Day | Architecture | Key Capabilities |
|-------|-----------|--------------|------------------|
| 1 | 0-1K | Monolith | Module + Lifecycle |
| 2 | 1K-10K | Vertical Scale | Cache + Async |
| 3 | 10K-100K | Multi-Instance | DistributedEventBus + Cluster |
| 4 | 100K-1M | Service Mesh | CircuitBreaker + Tracing + gRPC |
| 5 | 1M+ | Global Scale | PasRaft + Hot Reload + Plugins |

See [Best Practices](BEST_PRACTICES.md) for detailed evolution guide.

## 🛠️ Commands

```bash
# Build
zig build

# Run tests
zig build test

# Run example
zig build run

# Generate documentation
zig build docs

# Format code
zig fmt
```

## 📦 Examples

| Example | Description | Run |
|---------|-------------|-----|
| [Basic](examples/basic/) | Module fundamentals | `cd examples/basic && zig build run` |
| [Event-Driven](examples/event-driven/) | Publish-subscribe | `cd examples/event-driven && zig build run` |
| [DI](examples/dependency-injection/) | Service container | `cd examples/dependency-injection && zig build run` |
| [Testing](examples/testing/) | Test utilities | `cd examples/testing && zig build test` |
| [v2-Showcase](examples/v2-showcase/) | All features | `cd examples/v2-showcase && zig build run` |

## 🤝 Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
# Fork and clone
git clone https://github.com/yourusername/zigmodu.git

# Create feature branch
git checkout -b feature/my-feature

# Run tests
zig build test

# Commit and push
git add . && git commit -m "feat: add feature" && git push
```

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

- [Spring Modulith](https://github.com/spring-projects/spring-modulith) - Architecture inspiration
- [Zig Community](https://ziglang.org/community/) - Language ecosystem
- [Contributors](https://github.com/knot3bot/zigmodu/graphs/contributors) - Code contributions