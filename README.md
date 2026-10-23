# zmodu v0.43.2

A compile-time modular application framework and worker execution runtime for Zig 0.17.

[![Zig](https://img.shields.io/badge/Zig-0.17+-orange?style=flat-square)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/github/v/release/chy3xyz/zmodu?style=flat-square)]()
[![CI](https://github.com/chy3xyz/zmodu/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/chy3xyz/zmodu/actions/workflows/ci.yml)

[English](README.md) | [Chinese](README.zh.md)

## Overview

zmodu provides two orthogonal planes in a single library:

| Plane | Capabilities | Entry Point |
|-------|--------------|-------------|
| **Application Plane** (default) | Compile-time module graph validation, lifecycle hooks, DI container, HTTP/1.1 + HTTP/2 + WebSocket + gRPC, SQLx / ORM / migrations, Redis + LRU cache, EventBus + transactional outbox, JWT / RBAC / multi-tenancy, resilience primitives, Prometheus metrics, OpenTelemetry tracing | [Quick Start](docs/guide/QUICK-START.md) · [Modulith Guide](docs/guide/MODULITH.md) |
| **Execution Plane** (opt-in) | Single-owner state workers, bounded mailboxes, lock-free SPSC/MPSC rings, lock-free `HotBus` fan-out, millisecond `TimerWheel` and microsecond `PrecisionTimer`, supervision trees, deterministic delivery log replay (`ZDL1`) | [Runtime Reference](docs/reference/RUNTIME.md) |

Applications that do not call `app.runtime()` spawn zero background runtime threads. The execution plane is designed for workloads where one fiber per request is insufficient, such as order books, realtime gateways, AI agent loops, and stateful pipelines.

## Quick Start

### 1. Prerequisites

Install Zig `0.17.0` (pinned in `.github/workflows/ci.yml`):

```bash
zigup 0.17.0
zig version
```

### 2. Dependency Configuration

Add `zmodu` to `build.zig.zon`:

```zig
.{
    .name = .myapp,
    .version = "0.1.0",
    .fingerprint = 0x0, // Replace with the fingerprint suggested by the first `zig build`
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .zmodu = .{ .path = "../zmodu" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

In `build.zig`, select the database drivers to link (`sqlite`, `postgres`, `mysql`, `none`, or `all`):

```zig
const db_opt = b.option([]const u8, "db", "SQL drivers: all|sqlite|postgres|mysql|none") orelse "sqlite";

const zmodu_dep = b.dependency("zmodu", .{
    .target = target,
    .optimize = optimize,
    .db = db_opt,
});
exe_mod.addImport("zmodu", zmodu_dep.module("zmodu"));
```

### 3. Domain Imports

Import only the domains your module needs:

```zig
const zmodu = @import("zmodu");

const http = zmodu.http;              // Server, Router, Context, Middleware, extract*, sse
const data = zmodu.data;              // SQLx, Repository, MigrationRunner, Cache, Redis
const sec  = zmodu.security;          // AppSecurity, CatalogPermDb, PasswordEncoder, Secrets
const obs  = zmodu.observability;     // PrometheusMetrics, DistributedTracer, OtlpExporter
```

### 4. Minimal Application & HTTP Server

```zig
const std = @import("std");
const zmodu = @import("zmodu");
const http = zmodu.http;

pub const panic = zmodu.panicHook;

pub const UserModule = struct {
    pub const info = zmodu.api.Module{
        .name = "user",
        .description = "User management module",
        .dependencies = &.{},
    };

    pub fn init() !void {}
    pub fn deinit() void {}
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Bind the builder first because builder methods take `*Self`.
    var b = zmodu.builder(allocator, io);
    defer b.deinit();
    var app = try b.withName("myapp").build(.{UserModule});
    defer app.deinit();

    try app.start();
    defer app.stop();

    var server = http.Server.init(io, allocator, 8080);
    defer server.deinit();

    var profile = http.ProductionProfileState.init(allocator);
    defer profile.deinit(allocator);
    try http.productionProfile(&server, .{
        .max_connections = 4096,
        .header_timeout_ms = 10_000,
    }, &profile);

    try server.addRoute(.{
        .method = .GET,
        .path = "/api/ping",
        .handler = struct {
            fn handle(ctx: *http.Context) anyerror!void {
                try ctx.jsonStruct(200, .{ .ok = true });
            }
        }.handle,
    });

    try server.start();
}
```

## Documentation

| Category | Documents |
|----------|-----------|
| **Getting Started** | [Quick Start](docs/guide/QUICK-START.md) · [CLI & Codegen](docs/guide/ZMODU_CLI_INTEGRATION.md) · [Modulith Architecture](docs/guide/MODULITH.md) · [Domain Layers](docs/guide/MODULE_LAYERS.md) |
| **Core Guides** | [Events & DI](docs/guide/EVENTS_DI.md) · [SQLx Drivers](docs/guide/SQLX_DRIVERS.md) · [Workflow & Saga](docs/guide/WORKFLOW.md) · [Logging](docs/guide/LOGGING.md) · [Best Practices](docs/guide/BEST_PRACTICES.md) |
| **Reference** | [Architecture](docs/reference/ARCHITECTURE.md) · [Declarative Routing & Auth](docs/reference/ROUTE_TABLE.md) · [Runtime](docs/reference/RUNTIME.md) · [Observability](docs/reference/OBSERVABILITY.md) · [Distributed](docs/reference/DISTRIBUTED.md) · [Zent ORM](docs/reference/ZENT.md) · [Web4](docs/reference/WEB4.md) · [API Reference](docs/reference/API.md) · [Upgrading](docs/reference/UPGRADING.md) |
| **AI Subsystem** | [AI Overview](docs/ai/README.md) · [AI Developer Guide](docs/ai/AI_DEV_GUIDE.md) · [Agent Runtime](docs/reference/AGENT_RUNTIME.md) · [Built-in Skills](docs/ai/AI_SKILLS.md) · [Orchestration](docs/ai/AI_ORCHESTRATION.md) · [LLM Policies](docs/ai/LLM_POLICIES.md) · [MCP Bridge](docs/ai/MCP.md) |
| **Contributors & AI Agents** | [AGENTS.md](AGENTS.md) · [API Freeze](docs/reference/API_FREEZE.md) · [Readiness Status](docs/dev/v1.0-readiness-v0.35.md) |

## Architecture & Features

### Application Plane
- **Module System**: Compile-time dependency graph checks (cycles, missing modules, duplicates) via `ApplicationBuilder.build` and source-level import checks via `zmodu doctor`.
- **HTTP & API**: Fiber-based HTTP/1.1 and HTTP/2 server, `ComptimeRouter` route tables, typed request extractors, SSE streaming, WebSocket (RFC 6455 text and binary frames), unary/streaming gRPC, and OpenAPI 3.0/3.1 generation.
- **Security**: `AppSecurity` JWT issuance and verification, `JwksKeyRing` key rotation, catalog-driven RBAC permission gates (`permissionGateWith(.rbac)`), PBKDF2-HMAC-SHA256 password encoding, CSRF double-submit cookies, and `SecretsManager` (env, file, Vault KV v2).
- **Data Access**: SQLx client for SQLite, PostgreSQL, and MySQL with connection pooling, `Repository(T)`, versioned `MigrationRunner`, LRU `CacheManager`, and Redis client.
- **Resilience & Observability**: `CircuitBreaker`, token-bucket and sliding-window `RateLimiter`, `AdaptiveShedder`, `Bulkhead`, `SagaOrchestrator`, `PrometheusMetrics`, and `OtlpExporter`.

### Execution Plane (`zmodu.runtime`)
- **Workers & Pools**: Dedicated thread per worker (`.dedicated`) or M:N scheduling over a worker pool (`.pooled`) while preserving single-thread state ownership per worker.
- **Blocking Pool**: `.execution_class = .blocking` isolates blocking I/O onto a separate thread pool.
- **Queues & Fan-Out**: Bounded `Mailbox`, lock-free SPSC `RingBuffer`, Vyukov `MpscRing`, and lock-free `HotBus` fan-out.
- **Timers & Replay**: O(1) hierarchical `TimerWheel` (ms), min-heap `PrecisionTimer` (us), injectable `Clock`, and `DeliveryLog` (`ZDL1` segment files) for deterministic replay.
- **Supervision**: `Supervision.group` with `.one_for_one`, `.one_for_all`, `.rest_for_one`, and `.stop_group` restart policies and bounded error budgets.

## Operational Boundaries

Review these boundaries before deploying zmodu in production:

- **Pre-1.0 Status**: The public API surface is feature-frozen ahead of 1.0 (see [API_FREEZE.md](docs/reference/API_FREEZE.md)). There is no independent third-party security audit; see [Readiness Status](docs/dev/v1.0-readiness-v0.35.md) and [SECURITY.md](SECURITY.md).
- **Cluster Wire Protocol**: Cluster frames (Raft and `DistributedEventBus`) use plaintext TCP with per-frame HMAC-SHA256 authentication (`own_key` / `peer_keys` or `cluster_secret`). HMAC provides integrity and authentication, not confidentiality. Run cluster ports on trusted private networks or terminate mTLS in a sidecar (see [`examples/production-deploy/cluster-sidecar/`](examples/production-deploy/cluster-sidecar/)).
- **Experimental Modules**: `SagaOrchestrator`, `DistributedEventBus`, `ClusterMembership`, `TwoPhaseCommit`, `PluginManager`, `WebMonitor`, and `HotReloader` are marked experimental.

## Verification Gates

All CI verification gates can be run locally:

```bash
# Full unit and integration test suite (-Ddb=all by default)
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test

# Run a filtered subset of tests
bash scripts/test-fast.sh --db all --filter "RaftElection" --force-run

# Static and production gates
zig build fmt-check
zig build check
zig build check-api
bash scripts/check-deadcode.sh
bash scripts/check-doc-paths.sh
bash scripts/check-version.sh

# Long-running stress and soak harnesses
zig build soak
zig build soak-cluster
zig build runtime-stress

# CLI project gates
zig build zmodu
./zig-out/bin/zmodu ci examples/basic
./zig-out/bin/zmodu doctor examples/tenant-mgmt
```

## Examples

See [`examples/README.md`](examples/README.md) for the full list of runnable examples:

| Example | Description |
|---------|-------------|
| [`tenant-mgmt`](examples/tenant-mgmt/) | Multi-tenant SaaS reference with `productionProfile`, catalog RBAC, and SQLite |
| [`tenant-shop`](examples/tenant-shop/) | E-commerce domain layers (`model`, `persistence.Tx`, `service`, `api`) and outbox |
| [`zent-modulith`](examples/zent-modulith/) | Schema-as-code `zent` ORM integration |
| [`runtime-workers`](examples/runtime-workers/) | Workers, mailboxes, `HotBus`, pooled scheduling, and supervision |
| [`alpha-engine`](examples/alpha-engine/) | Low-latency trading pipeline on the execution plane |
| [`quant-replay`](examples/quant-replay/) | Deterministic segment log recording and replay |
| [`ai-ops`](examples/ai-ops/) · [`llm-policies`](examples/llm-policies/) · [`mcp-server`](examples/mcp-server/) | AI agent operations, LLM policy gates, and stdio MCP server |
| [`production-deploy`](examples/production-deploy/) | Nginx/Envoy TLS sidecars, Kubernetes manifests, systemd units, and smuggling e2e |

## Project Structure

```text
zmodu/
├── src/
│   ├── root.zig              # Top-level exports and domain aliases
│   ├── Application.zig       # Application builder, lifecycle, DI, and runtime owner
│   ├── http.zig              # HTTP domain barrel (Server, Router, Context, Middleware, Testkit)
│   ├── data.zig              # Data domain barrel (SQLx, Repository, Cache, Redis)
│   ├── security.zig          # Security domain barrel (AppSecurity, RBAC, PasswordEncoder, Secrets)
│   ├── observability.zig     # Observability domain barrel (PrometheusMetrics, Tracer, OtlpExporter)
│   ├── runtime.zig           # Execution plane barrel (Runtime, Worker, Mailbox, HotBus, Timers)
│   ├── api/ · http/          # HTTP/1.1, HTTP/2, ComptimeRouter, extractors, middleware, SSE, OpenAPI
│   ├── core/                 # Module graph, EventBus, Time, Preflight, cluster/ (Raft, Bootstrap)
│   ├── runtime/              # Scheduler, worker pools, supervision, ring buffers, delivery log
│   ├── sqlx/ · persistence/  # Database drivers (SQLite, PostgreSQL, MySQL) and ORM backend
│   ├── ai/                   # Optional AI subsystem (Provider, SkillRegistry, Agent, Guard, Workflow)
│   └── test/                 # Contract, boundary, and snippet verification gates
├── tools/zmodu/              # Built-in CLI (scaffold, module, audit, deadcode, doctor, ci)
├── examples/                 # 18 runnable example projects
└── docs/                     # Documentation (guide/, reference/, ai/)
```

## Contributing & License

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines. Licensed under the [MIT License](LICENSE).
