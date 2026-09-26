# ZigModu v0.35.1

**Compile-time modular application framework + worker-oriented execution runtime, for Zig 0.17.**

Two planes, one library — adopt either, or both:

| Plane | What you get | Start here |
|-------|--------------|-----------|
| **Application plane** (the default) | Modules with compile-time dependency validation, lifecycle, DI, HTTP/1.1 + h2c + WebSocket + gRPC, SQLx / ORM / migrations, cache + Redis, events + transactional outbox, JWT / RBAC / multi-tenancy, resilience, metrics + tracing | [Quick Start](docs/QUICK-START.md) · [Modulith](docs/MODULITH.md) |
| **Execution plane** (opt-in) | Workers that own their state, bounded mailboxes, lock-free queues, a fan-out whose `publish` takes no lock, timers (ms **and** µs), supervision, delivery replay from a segment log | [Runtime](docs/RUNTIME.md) |

An app that never calls `app.runtime()` spawns **no extra threads** — the application plane stands alone.
The execution plane is where one-fiber-per-request stops being the right shape: market data and order
books, realtime gateways, AI agent loops, IoT state machines. It is not a port of anything: comptime
track types, hand-written queues, no hidden allocation on the hot path (that last one is a **tested
contract**, not a slogan — see [how it is verified](#-how-it-is-verified)).

The module system follows the **Modulith** idea — one process, hard module boundaries, split into
services only after the boundary is proven — with the dependency rules enforced at compile time.

[![Zig](https://img.shields.io/badge/Zig-0.17+-orange?style=flat-square)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/github/v/release/chy3xyz/zigmodu?style=flat-square)]()
[![CI](https://github.com/chy3xyz/zigmodu/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/chy3xyz/zigmodu/actions/workflows/ci.yml)

## 📚 Documentation

| Guide | Description |
|-------|-------------|
| [**AGENTS.md**](AGENTS.md) | **AI agent handbook** (DO/DON'T, Path A auth, ComptimeRouter) |
| [Quick Start](docs/QUICK-START.md) | Get started in 5 minutes |
| [**Runtime**](docs/RUNTIME.md) | **The execution plane**: workers, mailboxes, scheduler, timers, supervision, replay |
| [Modulith & Concurrency](docs/MODULITH.md) | Day-one modulith + high-concurrency practices |
| [Best Practices](docs/BEST_PRACTICES.md) | Both planes: architecture evolution, JWT checklist, resilience, and where the runtime earns its keep |
| [Declarative Routes](docs/ROUTE_TABLE.md) | ComptimeRouter + catalog JWT/RBAC |
| [Events & DI](docs/EVENTS_DI.md) | `initWith(ctx)` + `app.eventBus` + container freeze |
| [ZigModu × zent](docs/ZENT.md) | **Recommended pairing for commerce/social**: zent ORM integration best practices |
| [SQLx drivers](docs/SQLX_DRIVERS.md) | Selective driver linking (`-Ddb=`, `.db=`) |
| [Distributed](docs/DISTRIBUTED.md) | Multi-instance, cluster stack, fail-closed startup |
| [Agent Runtime](docs/AGENT_RUNTIME.md) | **Agents can't act by default**: `Guard` (two fail-closed axes — an `execute` second switch + empty-by-default allow list) |
| [Observability](docs/OBSERVABILITY.md) | Golden signals, PromQL, alert thresholds, Grafana dashboard |
| [API Reference](docs/API.md) | Detailed API documentation |
| [Architecture](docs/ARCHITECTURE.md) | System design and patterns |
| [Upgrading](docs/UPGRADING.md) | Per-version notes: what changed in behavior, and the one-line fixes |
| [Status & readiness](docs/dev/v1.0-readiness-v0.35.md) | **What is proven and what is not** — dated, per item, with evidence (for the older self-scoring report, see [Evaluation Report](docs/EVALUATION_REPORT.md)) |
| [Examples](examples/) | Runnable example projects |
| [Production deploy](examples/production-deploy/) | TLS sidecar (nginx/Envoy), k8s, systemd, Dockerfile, request-smuggling e2e |
| [ZModu CLI](docs/ZMODU_CLI_INTEGRATION.md) | Built-in codegen (`zig build zmodu`) |

## ✨ Features


### Core Framework
- **Module System** — Declarative module definition with compile-time dependency validation
- **Lifecycle Management** — Automatic init/deinit orchestration in dependency order; modules opt into framework facilities via `initWith(ctx)`
- **Dependency Injection** — Type-safe container built into `Application`: register at startup (`withService` / `registerBorrowed`), frozen after `start()`, lock-free reads thereafter
- **Event System** — Application-wide `EventRegistry` hands out thread-safe per-type buses (`app.eventBus(T)`); plus TypedEventBus and the transactional outbox pattern (`zigmodu.outbox.*`)
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

### High-Performance Runtime (the execution plane)

Opt-in via `app.runtime()`. Spec: [docs/RUNTIME.md](docs/RUNTIME.md) · runnable:
[runtime-workers](examples/runtime-workers) · workload: [alpha-engine](examples/alpha-engine).

**Workers & scheduling**
- **Worker** — One struct with `handle` (per-message) or `run` (long-lived loop); the
  runtime owns its thread, its mailbox and its lifecycle (`init`/`deinit` run once,
  shutdown joins every worker)
- **Worker pool** — `.mode = .dedicated` (one worker, one thread) or `.mode = .pooled`
  (N workers over N pool threads). Worker **state ownership** is preserved across the
  pool: a claim token guarantees only one thread runs a given worker at a time, and the
  mailbox FIFO and `error.Full` backpressure are unchanged
- **Blocking pool** — `.execution_class = .blocking` moves a worker off the CPU pool
  (declare the width with `Application.withBlockingThreads`); a DB round trip then cannot
  drain the pool the scheduler dispatches from. Declared, never guessed: nothing detects
  a blocking call for you
- **Stop policy & supervision** — per-worker failure policy (fail-fast or a bounded error
  budget inside a window) plus an `onError` hook to decide on the spot

**Queues & fan-out**
- **Mailbox** — Bounded blocking hand-off between threads; a full mailbox is
  `error.Full` at the producer, never an unbounded grow (**backpressure below HTTP**)
- **RingBuffer (SPSC)** — Lock-free, cache-line-separated indices, fixed capacity
- **MpscRing** — Vyukov many-producer/single-consumer queue (per-producer order kept)
- **HotBus** — L0 fan-out into worker mailboxes; frozen after construction, so `publish`
  takes no lock and allocates nothing; drops on full and counts it. Deliberately **not** a
  general-purpose event bus — the application plane already has one

**Time**
- **TimerWheel** — Hierarchical O(1) schedule/cancel, millisecond slots; lateness surfaces
  as `timer_lag_max_ms`
- **PrecisionTimer** — the µs tool, and a different one on purpose: min-heap + spin window,
  measured **p50 0 ns / p99 1 µs**. Not a replacement for the wheel, and not a new clock type
- **Clock** — Injectable time source (`monotonic` in production, `manual` in tests/replay)

**Replay & observability**
- **EventRecorder** — Opt-in, zero-allocation log of the delivery stream: attach a
  `Recorder(E, capacity)` to a `HotBus` before `freeze()` and every publish is recorded
  with a monotonic seq and the injected clock. A full log returns `error.Full` (never a
  silent drop), counts `record_dropped` and makes `publish` return false
- **Replay from disk** — `DeliveryLog` writes the same tracks to segment files
  (`ZDL1`, per-track cursors, holes counted), and `ReplayFromLog` replays *from those
  bytes* through a caller-supplied `Codec(E)`. Still out of scope, on purpose: a CLI,
  retention/compaction, encryption, cross-process transport
- **Runtime metrics** — `RuntimeStats` + `MetricsBridge` publishes **25**
  `zigmodu_runtime_*` gauges (13 general + 6 CPU pool + 6 blocking pool); drops, timer lag
  and pool depth are invisible from the HTTP side
- **Worker trace context** — `sendTraced` / `sendBlockingTraced` carry a 16-byte
  `TraceId` **in the mailbox slot** (no allocation, no shared producer state); the
  handler reads it back with `ctx.traceId()`, `after` hands it to the timer, and
  runtime error logs tag the offending message's trace
- **Affinity** — `runtime.affinity.pinCurrentThread(cpu)` pins the *calling* thread on
  Linux; macOS and Windows return `error.Unsupported` rather than reporting a pin that
  did not happen. There is no `.affinity` field on `spawn` yet, and the reason is in
  [RUNTIME.md §12.7](docs/RUNTIME.md)

**What this plane deliberately does not have (yet)** — priority / weighted fairness,
a deterministic-execution mode, remote workers. Each is refused with a stated reason
rather than half-built; the list is in [RUNTIME.md](docs/RUNTIME.md) §12.7.

### Developer Experience
- **Architecture Tester** — Compile-time dependency rule validation
- **Module Interaction Verifier** — Spring Modulith verify()-style interaction model checking
- **Contract Testing** — Pact-style consumer-driven contract verification
- **Plugin System** ⚠️ — Dynamic extension loading (experimental)
- **Web Monitor** ⚠️ — HTTP dashboard for module inspection (experimental)
- **Hot Reloader** ⚠️ — File-watch based module change detection (experimental)
- **CI/CD Pipeline** — GitHub Actions: matrix build (linux/macOS), lint, benchmark, Docker, release

## 🚧 What it is not (price these in before adopting)

A feature list is the least useful half of a README. These boundaries decide deployment shape:

- **Cluster upgrades are a hard cut.** The Raft frame format and the bus handshake changed, and an old
  and a new binary do not understand each other in either direction — deliberately, so that there is no
  "degrade to unauthenticated" path. A mixed-version rolling upgrade has **never been run**; it is the
  first item in the [readiness assessment](docs/dev/v1.0-readiness-v0.35.md).
- **No encryption on the wire.** Cluster frames are plaintext today; production uses a TLS-terminating
  sidecar ([examples/production-deploy](examples/production-deploy/)). `src/core/cluster/TlsTransport.zig`
  exists and has no callers.
- **Cluster identity: per-node on the bus, shared-PSK on Raft.** Holding the Raft `cluster_secret` lets
  one node impersonate another; the bus got per-node credentials and a challenge-response handshake,
  Raft did not (yet). No rotation, no revocation.
- **`ws_uring` is Linux-only** (io_uring); other platforms take the portable path.
- **⚠️ marks experimental modules** — Saga, SecurityScanner, DistributedEventBus, ClusterMembership,
  2PC, Plugin, WebMonitor, HotReloader. They have tests; they do not have a production track record here.
- **AI is an optional domain, not the core.** `src/ai` is a small share of the tree and the
  HTTP / data / security / observability core does not depend on it. Agents cannot act by default
  ([AGENT_RUNTIME.md](docs/AGENT_RUNTIME.md)).
- **Self-assessed.** Every "done" here was produced by the same maintainers and their AI agents; there
  has been no independent audit. The dated, per-item version of that sentence is
  [docs/dev/v1.0-readiness-v0.35.md](docs/dev/v1.0-readiness-v0.35.md).

## 🔬 How it is verified

The gates are the reason to trust any of the above, and all of them run locally:

| Gate | What it proves | Command |
|------|----------------|---------|
| Full suite (`-Ddb=all`) | 2000+ tests over 6 artifacts | `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test` |
| Allocation **contract** | exact zero allocations on the mailbox / ring / HotBus / `send` / timer hot paths | `src/runtime/alloc_contract_test.zig` |
| Production gate | no bare `catch {}` in hot modules, CSPRNG source, fuzz declarations match the tree | `zig build check` |
| API import gate | examples go through the canonical `zigmodu.http` | `zig build check-api` |
| Dead-code ratchet | baseline 28 in `src`+`tools`, 0 in `examples` | `bash scripts/check-deadcode.sh` |
| Benchmark ratchet | 32 metrics against a CI baseline + 32 allocation budgets | `bash scripts/check-bench.sh` |
| Soak (HTTP + tenants) | cross-tenant leaks, FrozenMap concurrency, fd/slot growth | `zig build soak` |
| Soak (cluster) | 3-node raft + bus: seq continuity, leader stability, log convergence, fd/RSS | `zig build soak-cluster` |
| Runtime stress | supervision, pools, ready ring, timers and zero-allocation under interleaving | `zig build runtime-stress` |
| Smuggling e2e | a real nginx in front: every request the backend served is one the gateway saw | `examples/production-deploy/smuggling-e2e/run.sh` |
| Cross-compile | x86_64-linux (plus a Windows leg in CI) compiles clean | `zig build test -Dtarget=x86_64-linux -Ddb=none` (compile-only off Linux; the run step cannot execute) |

Readings follow one convention so a number means exactly one thing:
[docs/dev/READING_NUMBERS.md](docs/dev/READING_NUMBERS.md).

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

```text
zigmodu/
├── src/
│   ├── root.zig                     # Public API (PRIMARY / ADVANCED / DEPRECATED)
│   ├── Application.zig              # Application builder: lifecycle, DI, runtime wiring
│   ├── api/                         # Public API surface: Module, Server, ComptimeRouter,
│   │                                #   Extract, Middleware (+ middleware/: auth, csrf, …), Crud
│   ├── core/                        # Module graph/scanner/validator, EventBus + EventRegistry,
│   │                                #   Lifecycle, Preflight, Time, sockread (bounded writes),
│   │                                #   DistributedEventBus, cluster/ (Raft, transport, bootstrap),
│   │                                #   DistributedTransaction, Saga, TransactionJournal
│   ├── runtime/                     # ── the execution plane ──
│   │   ├── runtime.zig              # Runtime / Worker / spawn (dedicated|pooled), StopPolicy, stats
│   │   ├── scheduler.zig            # CPU pool + blocking pool (ready ring, claim, park)
│   │   ├── supervisor.zig           # failure policy, error budget, onError
│   │   ├── mailbox.zig  ring.zig    # bounded mailbox; SPSC ring + Vyukov MpscRing
│   │   ├── hot_bus.zig  sequencer.zig  object_pool.zig
│   │   ├── timer_wheel.zig  precision_timer.zig  clock.zig  affinity.zig
│   │   ├── recorder.zig  delivery_log.zig        # delivery log, ZDL1 segments, ReplayFromLog
│   │   └── alloc_contract_test.zig               # the zero-allocation contract, as tests
│   ├── http/                        # HTTP/2 + HPACK, HttpClient (+pool), SSE, static, multipart,
│   │                                #   OpenAPI, Page/Params, AccessLog, Testkit
│   ├── data.zig · sqlx/ · data/ · persistence/ · cache/ · redis/ · pool/   # data plane
│   ├── security/ · tenant/ · datapermission/                               # authn / authz / tenancy
│   ├── di/ · config/ · log/ · metrics/ · tracing/ · validation/ · test/    # supporting
│   ├── extensions/                  # gRPC transport, WebSocket, WebMonitor, Plugin, HotReloader
│   ├── ai/                          # optional domain: provider, skills, memory, agent guard
│   ├── im/ · messaging/ · scheduler/ · migration/ · secrets/ · resilience/ · util/ · kit/ · web4/
│   ├── soak.zig · soak_cluster.zig · runtime_stress.zig · benchmark.zig   # the long-run harnesses
│   └── tests.zig · main.zig · docs.zig
├── docs/                            # this documentation set (see the table at the top)
├── examples/                        # runnable projects (table below)
├── tools/zmodu/                     # the zmodu CLI: codegen, audit, ci
├── Dockerfile · docker-compose.yml
└── .github/workflows/ci.yml         # the gate set this README points at
```

## 🎯 Progressive Evolution

ZigModu grows along **two independent axes**. You can move on one without the other, and neither one
requires splitting anything into services:

| Axis | Stage | What you add | Where it lands |
|------|-------|--------------|----------------|
| **Application** | one process | modules with compile-time dependency rules, DI, HTTP, data | [BEST_PRACTICES.md](docs/BEST_PRACTICES.md) |
| | several instances | rate limiting, circuit breakers, distributed locks, cache/Redis, outbox | same |
| | a cluster | `DistributedEventBus` + Raft via `ClusterBootstrap`, Kafka, sharding | [DISTRIBUTED.md](docs/DISTRIBUTED.md) — mind the hard-cut upgrade boundary |
| **Execution** | request → response | nothing to do: fibers plus a pool already serve this shape | [MODULITH.md](docs/MODULITH.md) |
| | owned state | workers that keep state across requests (`app.runtime()`) | [RUNTIME.md](docs/RUNTIME.md) |
| | many of the same worker | `.mode = .pooled` — N workers over N pool threads, state still exclusive | same |
| | latency-critical | `.dedicated` workers, µs `PrecisionTimer`, delivery replay for backtests | [alpha-engine](examples/alpha-engine) |
| | off-machine work | `.execution_class = .blocking` for anything that waits on the outside world | same |

The rules that keep the first axis honest (dependency validation at compile time) and the second one
predictable (bounded queues, zero-allocation hot paths) are the same rules this repo's own gates enforce.
Detailed guide: [Best Practices](docs/BEST_PRACTICES.md).

## 🛠️ Commands

```bash
# Build & run
zig build                        # build the framework
zig build run                    # run the in-repo app

# ---- gates (each one is a CI job, or a step of one) ----
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test   # full suite (-Ddb=all by default)
bash scripts/test-fast.sh --filter RaftElection --db none --force-run   # one family of tests
zig fmt --check src tools examples                      # formatting
zig build check                     # hot-path gate: no bare catch {}, CSPRNG, fuzz declarations
zig build check-api                 # examples must route through zigmodu.http
bash scripts/check-deadcode.sh      # dead-code ratchet
bash scripts/check-bench.sh         # benchmark + allocation ratchets
bash scripts/check-production.sh    # layered production checks

# ---- long-run harnesses ----
zig build soak                      # HTTP + tenants: leaks, FrozenMap, fd/slot growth
zig build soak-cluster              # 3-node raft + bus: seq/leader/log/fd/RSS invariants
zig build runtime-stress            # runtime under interleaving: supervision, pools, timers

# ---- runtime & project tooling ----
zig build zmodu && ./zig-out/bin/zmodu runtime examples/alpha-engine   # static runtime wiring report
./zig-out/bin/zmodu audit .         # audit rules (b19–b23: bare panic, shared maps, tenant scope, …)
./zig-out/bin/zmodu ci              # business projects: build + fmt + verify + audit + deadcode

# ---- misc ----
zig build benchmark                 # benchmarks (the ratchet lives in scripts/check-bench.sh)
zig build docs                      # generate docs
HTTP_PORT=18080 bash scripts/ci-integration.sh   # integration probes (needs curl)
bash scripts/release.sh X.Y.Z --push             # cut a release (bumps every version ref, gates, tags)

# Docker
docker compose up -d                             # full stack (PG + Redis + Vault + Jaeger)
docker compose --profile tracing up -d           # with tracing
```

## 📦 Examples

Each directory is a runnable project with its own README; the index is
[examples/README.md](examples/README.md). The ones worth reading first:

| Example | What it shows |
|---------|---------------|
| **[tenant-mgmt](examples/tenant-mgmt/)** | **Application plane, end to end**: multi-tenant SaaS, module graph, middleware chain, catalog-permission auth, health probes, CI integration target |
| **[runtime-workers](examples/runtime-workers/)** | **Execution plane**: workers, mailboxes, HotBus, supervision — the smallest complete use of `app.runtime()` |
| **[alpha-engine](examples/alpha-engine/)** | **The load the execution plane exists for**: feed → order book → alpha → risk → execution, with the blocking pool for the off-machine parts |
| **[tenant-shop](examples/tenant-shop/)** | Module layers: `model` / `persistence` / `service` / `api` with `Tx` — see [MODULE_LAYERS.md](docs/MODULE_LAYERS.md) |
| **[zent-modulith](examples/zent-modulith/)** | The zent ORM pairing (schema-as-code) — see [ZENT.md](docs/ZENT.md) |
| **[production-deploy](examples/production-deploy/)** | TLS sidecar (nginx/Envoy), k8s, systemd, Dockerfile, and the request-smuggling e2e with a real proxy |
| **[zmsaas](examples/zmsaas/)** | A generated SaaS skeleton (what `zmodu saas` produces, then customised) |
| **[ai-ops](examples/ai-ops/) · [llm-policies](examples/llm-policies/) · [mcp-server](examples/mcp-server/)** | The AI side: ops agent, policy enforcement, MCP server |
| [basic](examples/basic/) · [event-driven](examples/event-driven/) · [distributed](examples/distributed/) · [http-stress-test](examples/http-stress-test/) | Small focused demos (modules, events + outbox, cross-node bus, load) |
| [shopdemo](examples/shopdemo/) | Codegen reference: a 152-table schema + `generated-sample/` |

## 🤝 Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md). Before a PR, run what CI runs:

```bash
git clone https://github.com/chy3xyz/zigmodu.git
git checkout -b feature/my-feature
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test    # full suite
zig build check check-api && zig fmt --check src tools examples
bash scripts/check-deadcode.sh
git commit -m "feat: add feature"
```

Conclusions belong in `docs/` (or `AGENTS.md`) rather than in a review thread — that is why this repo
keeps per-batch dated notes and a [readiness assessment](docs/dev/v1.0-readiness-v0.35.md) next to the code.

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.
