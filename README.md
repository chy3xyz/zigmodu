# ZigModu

A modular application framework for Zig 0.16.0, inspired by Spring Modulith. Build scalable applications from monolithic to distributed systems with progressive architecture evolution.

[![Zig](https://img.shields.io/badge/Zig-0.16.0+-orange?style=flat-square)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Build](https://img.shields.io/badge/Build-Passing-green?style=flat-square)](https://github.com/knot3bot/zigmodu/actions)
[![Tests](https://img.shields.io/badge/Tests-334%20passed-green?style=flat-square)]()
[![Version](https://img.shields.io/badge/Version-0.8.0-blue?style=flat-square)]()
[![Score](https://img.shields.io/badge/Production_Readiness-75%2F100-yellow?style=flat-square)]()

## 📚 Documentation

| Guide | Description |
|-------|-------------|
| [Quick Start](docs/QUICK-START.md) | Get started in 5 minutes |
| [Best Practices](docs/BEST_PRACTICES.md) | Architecture evolution from 1K to 1M+ DAU |
| [API Reference](docs/API.md) | Detailed API documentation |
| [Architecture](docs/ARCHITECTURE.md) | System design and patterns |
| [Evaluation Report](docs/EVALUATION_REPORT.md) | Production readiness assessment (75/100) |
| [Examples](examples/) | Runnable example projects |
| [ZModu CLI](tools/zmodu/README.md) | Code generator for modules, ORM, APIs |

## ✨ Features

### Core Framework
- **Module System** — Declarative module definition with compile-time dependency validation
- **Lifecycle Management** — Automatic init/deinit orchestration in dependency order
- **Dependency Injection** — Type-safe container with compile-time hash checking (CRC32)
- **Event System** — TypedEventBus + DistributedEventBus + TransactionalEvent + Outbox pattern
- **Application Builder** — Fluent API with shutdown hooks and graceful termination

### HTTP & API
- **HTTP Server** — Async fiber-based server (kqueue/io_uring), trie router, middleware chains
- **WebSocket** — RFC 6455 server/client with origin validation and monitoring
- **gRPC** ⚠️ — Service registry + Proto parser + 16 status codes (experimental)
- **OpenAPI** — 3.0/3.1 JSON document generator from route metadata
- **Idempotency** — Request deduplication middleware with TTL-based store

### Resilience & Flow Control
- **Circuit Breaker** — Three-state (closed/open/half-open) with configurable thresholds
- **Rate Limiter** — Token bucket with per-client overrides
- **Retry Policy** — Exponential backoff with configurable jitter
- **Load Shedder** — Adaptive concurrency limiting
- **Saga Orchestrator** — Automatic compensation with reverse-order rollback + step logging

### Data & Persistence
- **SQLx** — PostgreSQL / MySQL / SQLite with connection pooling + circuit breaker
- **ORM** — Type-safe repository pattern with compile-time table mapping
- **Database Migrations** — Flyway/Liquibase-style versioned migrations with SHA256 checksums
- **Cache Manager** — LRU cache with TTL expiration
- **Redis Client** — Connection pooling and command pipeline
- **Connection Pool** — Generic resource pool with health checking

### Distributed Systems
- **DistributedEventBus** — Cross-node event pub/sub with heartbeat
- **ClusterMembership** ⚠️ — Gossip-based node discovery + health check (experimental)
- **DistributedTransaction** ⚠️ — 2PC + Saga patterns (experimental, needs persistence)
- **Kafka Connector** — Producer/Consumer with topic stats + EventBridge
- **Sharding** — Tenant-aware ShardRouter with configurable pools

### Observability
- **Distributed Tracing** — OpenTelemetry-compatible, Jaeger/Zipkin export
- **Prometheus Metrics** — Counter / Gauge (lock-free CAS) / Histogram / Summary
- **Structured Logging** — JSON-formatted with log rotation and levels
- **Auto Instrumentation** — Automatic lifecycle/event/API instrumentation
- **Health Endpoints** — K8s-compatible liveness/readiness/module-health probes

### Security
- **JWT Authentication** — Token generation/verification with expiry
- **RBAC** — Role-based access control
- **Password Encoder** — Scrypt-based password hashing
- **Security Scanner** — Static SAST with configurable rules
- **Secrets Manager** — Multi-source secrets (env > file > Vault > default) with priority resolution
- **Multi-Tenancy** — TenantContext + DataPermission + ShardRouter

### Developer Experience
- **Architecture Tester** — Compile-time dependency rule validation
- **Module Interaction Verifier** — Spring Modulith verify()-style interaction model checking
- **Contract Testing** — Pact-style consumer-driven contract verification
- **Plugin System** ⚠️ — Dynamic extension loading (experimental)
- **Web Monitor** ⚠️ — HTTP dashboard for module inspection (experimental)
- **Hot Reloader** ⚠️ — File-watch based module change detection (experimental)
- **CI/CD Pipeline** — GitHub Actions: matrix build (linux/macOS), lint, benchmark, Docker, release

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

### Quick HTTP Server

```zig
const Server = zigmodu.http_server.Server;
const Context = zigmodu.http_server.Context;

pub fn main(init: std.process.Init) !void {
    var server = Server.init(init.io, init.gpa, 8080);
    defer server.deinit();

    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                try ctx.json(200, "{\"status\":\"ok\"}");
            }
        }.handle,
    });

    try server.start();
}
```

### Docker Compose Quick Start

```bash
# Start full stack (zigmodu + PostgreSQL + Redis)
docker compose up -d

# With Vault and Jaeger
docker compose --profile secrets --profile tracing up -d
```

## 📁 Project Structure

```
zigmodu/
├── src/
│   ├── root.zig                       # Public API (PRIMARY / ADVANCED / DEPRECATED)
│   ├── Application.zig                # Application builder + lifecycle
│   ├── api/                           # Public API types
│   │   ├── Module.zig                 # Module / Modulith structs
│   │   ├── Server.zig                 # HTTP server + router
│   │   └── Middleware.zig             # Middleware framework
│   ├── core/                          # Core framework
│   │   ├── Module.zig                 # ModuleInfo, ApplicationModules
│   │   ├── ModuleScanner.zig          # Compile-time module scanning
│   │   ├── ModuleValidator.zig        # Dependency validation
│   │   ├── ModuleInteractionVerifier.zig  # Interaction model verification
│   │   ├── EventBus.zig               # Type-safe event bus
│   │   ├── DistributedEventBus.zig    # Cross-node event bus
│   │   ├── Lifecycle.zig              # startAll/stopAll
│   │   ├── Time.zig                   # Monotonic time utility
│   │   ├── GrpcTransport.zig          # gRPC service registry + proto parser
│   │   ├── KafkaConnector.zig         # Kafka producer/consumer
│   │   ├── SagaOrchestrator.zig       # Saga auto-compensation orchestrator
│   │   ├── DistributedTransaction.zig # 2PC + Saga transactions
│   │   ├── HealthEndpoint.zig         # K8s liveness/readiness probes
│   │   ├── HotReloader.zig            # File-watch hot reload
│   │   ├── PluginManager.zig          # Dynamic plugin system
│   │   └── ...
│   ├── http/                          # HTTP & API
│   │   ├── HttpClient.zig             # HTTP client with pooling
│   │   ├── Idempotency.zig            # Request deduplication middleware
│   │   └── OpenApi.zig                # OpenAPI 3.x doc generator
│   ├── migration/                     # Database migrations
│   │   └── Migration.zig              # Flyway-style migration runner
│   ├── secrets/                       # Secrets management
│   │   └── SecretsManager.zig         # Multi-source secrets with Vault
│   ├── resilience/                    # Resilience patterns
│   │   ├── CircuitBreaker.zig
│   │   ├── RateLimiter.zig
│   │   ├── Retry.zig
│   │   └── LoadShedder.zig
│   ├── metrics/                       # Observability
│   │   ├── PrometheusMetrics.zig
│   │   └── AutoInstrumentation.zig
│   ├── tracing/                       # Distributed tracing
│   │   └── DistributedTracer.zig
│   ├── security/                      # Authentication & authorization
│   │   ├── SecurityModule.zig
│   │   ├── SecurityScanner.zig
│   │   ├── Rbac.zig
│   │   └── PasswordEncoder.zig
│   ├── tenant/                        # Multi-tenancy
│   │   ├── TenantContext.zig
│   │   └── ShardRouter.zig
│   ├── sqlx/                          # Database drivers
│   ├── redis/                         # Redis client
│   ├── pool/                          # Connection pool
│   ├── cache/                         # Cache (LRU)
│   ├── scheduler/                     # Task scheduler (Cron)
│   ├── messaging/                     # Message queue + Outbox
│   ├── di/                            # DI container
│   ├── config/                        # Configuration (JSON/YAML/TOML)
│   ├── log/                           # Structured logging
│   ├── test/                          # Testing utilities
│   │   ├── ContractTest.zig           # Pact-style contract testing
│   │   ├── IntegrationTest.zig
│   │   └── ModuleTest.zig
│   └── validation/                    # Object validation
├── docs/                              # Documentation
├── examples/                          # Example projects
├── shopdemo/                          # Full reference app (42 modules, 152 tables)
├── tools/zmodu/                       # zmodu CLI code generator
├── Dockerfile                         # Multi-stage Docker build
├── docker-compose.yml                 # Full stack (PG + Redis + Vault + Jaeger)
└── .github/workflows/ci.yml           # CI/CD pipeline
```

## 🎯 Progressive Evolution

ZigModu grows with your application:

| Stage | DAU | Architecture | Key Capabilities |
|-------|-----|--------------|------------------|
| 1 | <1K | Monolith | Module + Lifecycle |
| 2 | 1K-10K | Vertical Scale | Events + Cache |
| 3 | 10K-100K | Multi-Instance | CircuitBreaker + RateLimiter |
| 4 | 100K-1M | Distributed | DistributedEventBus + Cluster |
| 5 | >1M | Platform | HotReload + Plugins + Kafka |

See [Best Practices](docs/BEST_PRACTICES.md) for detailed evolution guide.

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

# Run benchmarks
zig build benchmark

# Format code
zig fmt src/

# Docker
docker compose up -d              # Start full stack
docker compose --profile tracing up -d  # With Jaeger
```

## 📦 Examples

| Example | Description |
|---------|-------------|
| [Basic](examples/basic/) | Module fundamentals |
| [Event-Driven](examples/event-driven/) | Publish-subscribe patterns |
| [Testing](examples/testing/) | Test utilities |
| [HTTP Stress Test](examples/http-stress-test/) | Concurrent connections |
| [Metaverse Creative](examples/metaverse-creative/) | Creative demo |
| [Distributed](examples/distributed/) | Multi-node deployment |
| [ShopDemo](shopdemo/) | Full e-commerce (42 modules, 790+ APIs) |

## 🤝 Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
git clone https://github.com/yourusername/zigmodu.git
git checkout -b feature/my-feature
zig build test
git commit -m "feat: add feature"
```

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.
