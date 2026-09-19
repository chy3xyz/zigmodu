# ZigModu v0.29.0

A modular application framework for Zig 0.17, inspired by Spring Modulith. Build scalable applications from monolithic to distributed systems with progressive architecture evolution.

[![Zig](https://img.shields.io/badge/Zig-0.17+-orange?style=flat-square)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/github/v/release/chy3xyz/zigmodu?style=flat-square)]()
[![Quality](https://img.shields.io/badge/Quality-98%25-A-green?style=flat-square)](docs/EVALUATION_REPORT.md)

## 📚 Documentation

| Guide | Description |
|-------|-------------|
| [**AGENTS.md**](AGENTS.md) | **AI agent handbook** (DO/DON'T, Path A auth, ComptimeRouter) |
| [Quick Start](docs/QUICK-START.md) | Get started in 5 minutes |
| [Modulith & Concurrency](docs/MODULITH.md) | Day-one modulith + high-concurrency practices |
| [Events & DI](docs/EVENTS_DI.md) | `initWith(ctx)` + `app.eventBus` + container freeze |
| [Declarative Routes](docs/ROUTE_TABLE.md) | ComptimeRouter + catalog JWT/RBAC |
| [ZigModu × zent](docs/ZENT.md) | **Recommended pairing for commerce/social**: zent ORM integration best practices |
| [Best Practices](docs/BEST_PRACTICES.md) | Architecture evolution + JWT checklist + resilience (panic / backpressure / FrozenMap) |
| [Agent Runtime](docs/AGENT_RUNTIME.md) | **Agents can't act by default**: `Guard` (two fail-closed axes — an `execute` second switch + empty-by-default allow list) |
| [Observability](docs/OBSERVABILITY.md) | Golden signals, PromQL, alert thresholds, Grafana dashboard |
| [Production Roadmap](docs/PRODUCTION_ROADMAP.md) | Maintenance boundaries, prefork limits, `src/ai` boundary |
| [API Reference](docs/API.md) | Detailed API documentation |
| [Architecture](docs/ARCHITECTURE.md) | System design and patterns |
| [Evaluation Report](docs/EVALUATION_REPORT.md) | Production readiness assessment (~98/100) |
| [Examples](examples/) | Runnable example projects |
| [Production deploy](examples/production-deploy/) | TLS sidecar (nginx/Envoy), k8s, systemd, Dockerfile |
| [ZModu CLI](docs/ZMODU_CLI_INTEGRATION.md) | Built-in codegen (`zig build zmodu`) |

## ✨ Features

ZigModu provides two complementary execution models. Adopt either one, or both:

1. **Application Runtime** — modules, DI, HTTP, events, data, security. The default;
   nothing here changes if you never touch the second one.
2. **High-Performance Runtime** — workers, mailboxes, lock-free queues, hot events,
   timers. Opt-in via `app.runtime()`; an app that never calls it spawns no extra
   threads. See [Runtime](docs/RUNTIME.md).

### Core Framework
- **Module System** — Declarative module definition with compile-time dependency validation
- **Lifecycle Management** — Automatic init/deinit orchestration in dependency order; modules opt into framework facilities via `initWith(ctx)`
- **Dependency Injection** — Type-safe container built into `Application`: register at startup (`withService` / `registerBorrowed`), frozen after `start()`, lock-free reads thereafter
- **Event System** — Application-wide `EventRegistry` hands out thread-safe per-type buses (`app.eventBus(T)`); plus TypedEventBus, TransactionalEvent + Outbox pattern
- **Application Builder** — Fluent API with shutdown hooks and graceful termination

### HTTP & API
- **HTTP Server** — Async fiber-based server (kqueue/io_uring), trie router, middleware chains
- **WebSocket** — RFC 6455 server (text + **binary** data frames via `WsFrameKind`); origin validation and monitoring
- **gRPC** — Unary framing + registry invoke + HTTP/1.1 `application/grpc` client (`GrpcFrame` / `GrpcClient.bindLocal`)
- **OpenAPI** — 3.0/3.1 JSON document generator from route metadata
- **Idempotency** — Request deduplication middleware with TTL-based store

### Resilience & Flow Control
- **Circuit Breaker** — Three-state (closed/open/half-open) with configurable thresholds
- **Rate Limiter** — Token bucket with per-client overrides
- **Retry Policy** — Exponential backoff with configurable jitter
- **Load Shedder** — Adaptive concurrency limiting
- **Saga Orchestrator** ⚠️ — Automatic compensation with reverse-order rollback + step logging (experimental)

### Data & Persistence
- **SQLx** — PostgreSQL / MySQL / SQLite with connection pooling + circuit breaker
- **ORM** — Type-safe repository pattern with compile-time table mapping
- **Database Migrations** — Flyway/Liquibase-style versioned migrations with SHA256 checksums
- **Cache Manager** — LRU cache with TTL expiration
- **Redis Client** — Connection pooling and command pipeline
- **Connection Pool** — Generic resource pool with health checking

### Distributed Systems
- **DistributedEventBus** ⚠️ — Cross-node event pub/sub with heartbeat (experimental)
- **ClusterMembership** ⚠️ — Gossip-based node discovery + health check (experimental)
- **DistributedTransaction** ⚠️ — 2PC + Saga patterns (experimental; 2PC coordinator state persists via `TransactionJournal`)
- **Kafka Connector** — Producer/Consumer with topic stats + EventBridge
- **Sharding** — Tenant-aware ShardRouter with configurable pools

### Observability
- **Distributed Tracing** — OpenTelemetry-compatible (`OtlpExporter` OTLP/HTTP JSON + retries)
- **Prometheus Metrics** — Counter / Gauge (lock-free CAS) / Histogram / Summary
- **Structured Logging** — JSON-formatted with log rotation and levels
- **Auto Instrumentation** — Automatic lifecycle/event/API instrumentation
- **Health Endpoints** — K8s-compatible liveness/readiness/module-health probes

### Security
- **AppSecurity** — Production JWT (`initWithIo`, wall-clock exp, middleware helpers)
- **JWKS Key Rotation** — Dynamic multi-key management with `JwksKeyRing` & `kid` indexing
- **JWT Authentication** — Unified verify via `SecurityModule`; RBAC optional
- **Password Encoder** — PBKDF2-HMAC-SHA256 + timing-safe comparison
- **Security Scanner** — Static SAST with configurable rules
- **Secrets Manager** — Multi-source secrets (env > file > Vault KV v2 HTTP > default)
- **Multi-Tenancy (optional)** — TenantContext + DataPermission + ShardRouter; skip for single-tenant

### Tooling & CLI
- **zmodu CLI** — Built-in code generator (`zig build zmodu`) supporting SQL DDL parsing, `@initialized` model & MCP Server

- **Security Headers** — HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy
- **CSRF Protection** — Double-submit cookie pattern with CSPRNG tokens
- **Path Sanitizer** — Traversal prevention (rejects `..`, null, `/`, `\`)
- **Auth Rate Limiting** — Login brute-force protection

### AI & LLM
- **AI Provider** — Cache-optimized OpenAI-compatible client with connection pool
- **SkillRegistry** — Agent tool registration + dispatch (Thread-safe, `EnsureTotalCapacity`)
- **MemoryStore** — Cross-session memory with `remember`/`recall`/`forget`, LRU eviction
- **SSE Writer** — Server-Sent Events with retry, heartbeat, multi-line data
- **ReAct Loop** — Autonomous agent (think→act→observe→repeat)
- **Agent Guard** — Fail-closed authority gate: `read`/`propose`/`execute` classes, `execute` needs an explicit second switch, empty allow list = inert agent

### Performance
- **ArenaAllocator** — Per-connection arena (0 heap allocs/request, resets on keep-alive)
- **Object Pool** — ConnectionEntry free-list (0 allocs in IM register/unregister)
- **`ensureTotalCapacity`** — Pre-allocate HashMap/ArrayList in 4 hot-path containers
- **`@branchHint`** — Hot-path hints on CircuitBreaker + RateLimiter
- **Path Rewriter** — Pre-routing URL transformation (ThinkPHP compat, prefix stripping)

### High-Performance Runtime

Opt-in via `app.runtime()` — see [docs/RUNTIME.md](docs/RUNTIME.md) and the
[runtime-workers example](examples/runtime-workers).

- **Worker** — One struct with `handle` (per-message) or `run` (long-lived loop); the
  runtime owns its thread, its mailbox and its lifecycle (`init`/`deinit` run once,
  shutdown joins every worker)
- **Mailbox** — Bounded blocking hand-off between threads; a full mailbox is
  `error.Full` at the producer, never an unbounded grow (**backpressure below HTTP**)
- **RingBuffer (SPSC)** — Lock-free, cache-line-separated indices, fixed capacity
- **MpscRing** — Vyukov many-producer/single-consumer queue (per-producer order kept)
- **HotBus** — L0 fan-out into worker mailboxes; frozen after construction, so `publish`
  takes no lock and allocates nothing; drops on full and counts it
- **TimerWheel** — Hierarchical O(1) schedule/cancel; lateness surfaces as
  `timer_lag_max_ms`
- **Clock** — Injectable time source (`monotonic` in production, `manual` in tests/replay)
- **Supervision** — Per-worker failure policy: fail-fast, or a bounded error budget
  inside a window, plus an `onError` hook to decide on the spot
- **Runtime metrics** — `RuntimeStats` + `MetricsBridge`, which publishes
  `zigmodu_runtime_*` gauges; drops and timer lag are invisible from the HTTP side
- **Worker trace context** — `sendTraced` / `sendBlockingTraced` carry a 16-byte
  `TraceId` **in the mailbox slot** (no allocation, no shared producer state); the
  handler reads it back with `ctx.traceId()`, `after` hands it to the timer, and
  runtime error logs tag the offending message's trace
- **EventRecorder** — Opt-in, zero-allocation log of the delivery stream: attach a
  `Recorder(E, capacity)` to a `HotBus` before `freeze()` and every publish is
  recorded with a monotonic seq and the injected clock; `replay` drives a
  `Clock.Manual` over the log, so a recorded run replays without sleeping. A full
  log returns `error.Full` (never a silent drop), counts `record_dropped` and
  makes `publish` return false

### Developer Experience
- **Architecture Tester** — Compile-time dependency rule validation
- **Module Interaction Verifier** — Spring Modulith verify()-style interaction model checking
- **Contract Testing** — Pact-style consumer-driven contract verification
- **Plugin System** ⚠️ — Dynamic extension loading (experimental)
- **Web Monitor** ⚠️ — HTTP dashboard for module inspection (experimental)
- **Hot Reloader** ⚠️ — File-watch based module change detection (experimental)
- **CI/CD Pipeline** — GitHub Actions: matrix build (linux/macOS), lint, benchmark, Docker, release

## 🚀 Quick Start

### Fast Compilation

For large projects, import only the domains you need:

```zig
const zmodu = @import("zigmodu");

// Builder wiring. This is a fragment, not a whole `main`: `allocator` / `io`
// come from `std.process.Init` (see "Bootstrap Application") and `UserModule`
// is defined in "Create Your First Module". Bind the builder first — a builder
// method takes `*Self`, and a temporary materialises as `*const`:
var b = zmodu.builder(allocator, io);
defer b.deinit();
var app = try b.build(.{UserModule});
_ = app;

// Fast import: only HTTP + Core (skips SQLx, Redis, Kafka, etc.):
const http = zmodu.http;       // Server, middleware, client, OpenAPI
const data = zmodu.data;       // SQLx, Redis, ORM, Cache, Migrations
const sec  = zmodu.security;   // Auth, RBAC, API keys, Secrets
const obs  = zmodu.observability; // Prometheus, Tracing, Logging
```

Each domain file is self-contained — importing `zmodu.http` does not compile `sqlx` or `redis`.

### Project setup: `build.zig.zon` + `build.zig`

Declare the dependency in `build.zig.zon`. The first `zig build` rejects the
placeholder `.fingerprint` and prints the exact value to paste in:

```zig
.{
    .name = .myapp,                 // must be a valid Zig identifier
    .version = "0.1.0",
    .fingerprint = 0x0,             // ← paste the value `zig build` suggests
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        // Local checkout (what examples/basic uses — no `.hash` needed):
        .zigmodu = .{ .path = "../zigmodu" },
        // …or a tagged release; `zig fetch --save <url>` fills in `.hash`:
        // .zigmodu = .{ .url = "git+https://github.com/chy3xyz/zigmodu?ref=v0.25.0" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

Then link only the database drivers you need (the dependency's default is `all`,
which pulls in all three):

```zig
const zigmodu_dep = b.dependency("zigmodu", .{
    .target = target,
    .optimize = optimize,
    .db = db_opt, // or postgres | mysql | "sqlite,postgres" | all
});
```

`-Ddb=` on the command line only exists if *your* `build.zig` declares the
option (the framework examples that support it do the same):

```zig
const db_opt = b.option([]const u8, "db", "SQL drivers to link: all|sqlite|postgres|mysql (comma-list)") orelse "sqlite";
```

```bash
zig build -Ddb=sqlite          # apps / examples (needs the option above)
zig build test                 # framework tests: keep default all
zig build soak                 # concurrency soak: N clients x M tenants (real sockets)
```

A complete `build.zig` (install + `run` + `test` steps) is in
[docs/QUICK-START.md](docs/QUICK-START.md) Step 3.

Production: one call wires backpressure, security, `/metrics` (golden signals)
and `/health/*`. It must run **before** routes are registered. Fragment —
`server` / `allocator` come from your own `main` (runnable wiring:
[`examples/tenant-mgmt/`](examples/tenant-mgmt/)):

```zig
var server = zigmodu.http.Server.init(io, allocator, 8080);
var profile = zigmodu.http.ProductionProfileState.init(allocator);
defer profile.deinit(allocator);
try zigmodu.http.productionProfile(&server, .{
    .max_connections = 4096,
    .over_limit_response = .close,  // or .unavailable to answer 503 first
    .header_timeout_ms = 10_000,    // request line + headers (slowloris guard)
}, &profile);
```

Deployment topology (TLS at a sidecar/gateway, graceful restarts, probes):
[`examples/production-deploy/`](examples/production-deploy/) ·
dashboards & alerting: [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md).

Disabled drivers → C stubs; runtime `error.DriverNotEnabled` (HTTP 400). Full guide: **[docs/SQLX_DRIVERS.md](docs/SQLX_DRIVERS.md)**.

### Prerequisites

```bash
# Install the pinned Zig toolchain — CI uses this exact dev build:
zigup 0.17.0-dev.2151+2ec5523d5
# (https://ziglang.org/download/ · https://github.com/marler8997/zigup)

# dev builds are garbage-collected from ziglang's mirrors (old ones start
# returning 404), so the version above goes stale by design — treat
# `.github/workflows/ci.yml` → `ZIG_VERSION` as the source of truth.
# `brew install zig` installs a *stable* Zig, which does NOT compile this repo
# (the framework needs the dev API: `std.process.Init`, `std.Io.Mutex`, …).
```

### Create Your First Module

```zig
// src/modules/user.zig
const std = @import("std");
const zigmodu = @import("zigmodu");

// `pub` matters: `main.zig` refers to it as `user.UserModule`.
pub const UserModule = struct {
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

    var modules = try zigmodu.scanModules(allocator, .{user.UserModule});
    defer modules.deinit();

    try zigmodu.validateModules(&modules);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);

    std.log.info("Application started!", .{});
}
```

### Events & DI (Application built-in)

Fragment — `OrderModule` / `OrderEvent` / `AppConfig` / `auditListener` are
yours, and `allocator` / `io` come from `std.process.Init`:

```zig
// Module opts into framework facilities via initWith(ctx):
pub fn initWith(ctx: *zmodu.ModuleContext) !void {
    const bus = try ctx.eventBus(OrderEvent);            // shared thread-safe bus
    const cfg = ctx.service(AppConfig, "config") orelse
        return error.MissingService;                     // fail fast at startup
    _ = bus; _ = cfg;
}

// main wires shared services; container freezes after start():
var b = zmodu.builder(allocator, io);                    // bind first: a builder method takes *Self
defer b.deinit();
var app = try b
    .withService(AppConfig, "config", &config)           // borrowed: not destroyed by container
    .build(.{OrderModule});
defer app.deinit();
try app.start();                                          // initWith runs → services frozen

const bus = try app.eventBus(OrderEvent);                // ThreadSafeEventBus only
try bus.subscribe(auditListener);
```

Full rules and anti-patterns: [docs/EVENTS_DI.md](docs/EVENTS_DI.md) · runnable wiring: `examples/shopdemo`.

### Quick HTTP Server

Self-contained — it needs only `build.zig` + `build.zig.zon` and this file:

```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

const http = zigmodu.http;

const Server = http.Server;
const Context = http.Context;

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
│   │   ├── EventRegistry.zig          # Per-type shared buses (thread-safe only)
│   │   ├── ModuleContext.zig          # Startup context: events + services + io
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
│   ├── runtime/                       # High-performance runtime (opt-in)
│   │   ├── runtime.zig                # Runtime, Worker, supervision, stats
│   │   ├── ring.zig                   # RingBuffer (SPSC) + MpscRing (Vyukov)
│   │   ├── mailbox.zig                # Bounded blocking mailbox (backpressure)
│   │   ├── hot_bus.zig                # L0 fan-out, frozen after construction
│   │   ├── timer_wheel.zig            # Hierarchical timer wheel
│   │   ├── clock.zig                  # Injectable time source
│   │   ├── object_pool.zig            # Fixed-capacity reuse pool
│   │   └── sequencer.zig              # Lock-free sequence numbers
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
├── examples/                          # Runnable example projects
│   ├── tenant-mgmt/                   # ★ Flagship: multi-tenant SaaS demo (CI integrated)
│   └── shopdemo/                      # Schema + codegen sample (not a full runnable app)
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
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test

# API import gate (examples must use zmodu.http)
zig build check-api

# Production hot-path gate (no bare catch {} in hot modules)
zig build check

# Formatting gate (src + tools + examples)
zig fmt --check src tools examples

# Static runtime wiring of a project (workers + mailbox capacities, timer sites;
# reads source only — live queue depth / dropped_full come from /metrics)
zig build zmodu && ./zig-out/bin/zmodu runtime examples/alpha-engine

# Integration probes (tenant-mgmt + stress test; needs curl)
HTTP_PORT=18080 bash scripts/ci-integration.sh

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
| **[Tenant Mgmt](examples/tenant-mgmt/)** | **Flagship example**: multi-tenant SaaS, middleware chain, health probes, `zigmodu.http` |
| [Basic](examples/basic/) | Module fundamentals + test utilities (`src/tests.zig`) |
| [Event-Driven](examples/event-driven/) | Publish-subscribe patterns |
| [HTTP Stress Test](examples/http-stress-test/) | Concurrent load (CI integration) |
| [Metaverse Creative](examples/metaverse-creative/) | Creative demo |
| [Distributed](examples/distributed/) | Cross-node event bus (`DistributedEventBus`); **no leader election** — see `docs/DISTRIBUTED.md` for the cluster stack and its fail-closed multi-node startup |
| [ShopDemo](examples/shopdemo/) | **Codegen reference**: a 152-table schema + `generated-sample/` (use the zmodu CLI to generate the full app) |

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
