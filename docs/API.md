# ZigModu API Reference

Complete API reference for the ZigModu modular framework.

---

## Table of Contents

1. [Core API](#core-api)
2. [Application](#application)
3. [Dependency Injection](#dependency-injection)
4. [Configuration](#configuration)
5. [Event System](#event-system)
6. [Resilience](#resilience)
7. [Observability](#observability)
8. [HTTP Server & Profiles](#http-server--profiles)
9. [Transport](#transport)
10. [Security](#security)
11. [Testing](#testing)
12. [Hardening primitives](#hardening-primitives)

---

## Core API

### Module Definition

#### `zigmodu.api.Module`

Declarative module definition with metadata.

```zig
pub const Module = struct {
    name: []const u8,                          // Unique module name
    description: []const u8 = "",              // Module description
    dependencies: []const []const u8 = &.{},   // Module dependencies
    is_internal: bool = false,                 // Internal-only flag
};
```

**Example:**
```zig
const OrderModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "order",
        .description = "Order management module",
        .dependencies = &.{"inventory", "payment"},
    };
    
    pub fn init() !void { ... }
    pub fn deinit() void { ... }
};
```

### Module Scanning

#### `zigmodu.scanModules`

Scan modules at compile time and extract metadata.

```zig
pub fn scanModules(
    allocator: std.mem.Allocator,
    comptime modules: anytype
) !ApplicationModules
```

**Example:**
```zig
var modules = try zigmodu.scanModules(allocator, .{
    UserModule,
    OrderModule,
    PaymentModule,
});
defer modules.deinit();
```

### Module Validation

#### `zigmodu.validateModules`

Validate that all module dependencies are satisfied.

```zig
pub fn validateModules(modules: *ApplicationModules) !void
```

### Lifecycle Management

#### `Application.start` / `Application.stop`（推荐）

启动/停止整个应用（依赖顺序启动、逆序停止，内部调用 Lifecycle）。

```zig
pub fn start(self: *Self) !void
pub fn stop(self: *Self) void
```

#### `zigmodu.startAll` / `zigmodu.stopAll`（底层 Lifecycle）

`Application.start/stop` 的内部实现；直接使用需自行管理模块生命周期。

```zig
pub fn startAll(modules: *ApplicationModules) !void
pub fn stopAll(modules: *ApplicationModules) void
```

### Documentation Generation

#### `zigmodu.generateDocs`

Generate PlantUML documentation.

```zig
pub fn generateDocs(
    modules: *ApplicationModules,
    path: []const u8,
    allocator: std.mem.Allocator
) !void
```

---

## Application

### Application Builder

#### `zigmodu.Application`

High-level application abstraction.

```zig
pub fn init(
    allocator: std.mem.Allocator,
    name: []const u8,
    modules: anytype,
    config: Config
) !Application
```

**Config Options:**
```zig
pub const Config = struct {
    validate_on_start: bool = true,
    auto_generate_docs: bool = false,
    docs_path: ?[]const u8 = null,
};
```

**Example:**
```zig
var app = try zigmodu.Application.init(
    allocator,
    "myapp",
    .{UserModule, OrderModule},
    .{
        .validate_on_start = true,
        .auto_generate_docs = true,
    }
);
defer app.deinit();
try app.start();
```

#### `zigmodu.builder`

Fluent builder pattern for application creation.

```zig
pub fn builder(allocator: std.mem.Allocator) ApplicationBuilder
```

**Example:**
```zig
var builder = zigmodu.builder(allocator);
defer builder.deinit();

var app = try builder
    .withName("myapp")
    .withValidation(true)
    .withAutoDocs(true)
    .build(.{UserModule, OrderModule});
```

---

## Dependency Injection

### Container

#### `zigmodu.di.Container`

Service container for dependency injection.

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn deinit(self: *Self) void
pub fn register(self: *Self, comptime T: type, name: []const u8, instance: *T) !void
pub fn get(self: *Self, comptime T: type, name: []const u8) ?*T
pub fn contains(self: *Self, name: []const u8) bool
pub fn remove(self: *Self, name: []const u8) void
pub fn serviceCount(self: *Self) usize
```

**Example:**
```zig
var container = zigmodu.di.Container.init(allocator);
defer container.deinit();

try container.register(Database, "main_db", &db_instance);
const db = container.get(Database, "main_db");
```

### Scoped Container

#### `zigmodu.di.ScopedContainer`

Scoped dependency container with parent resolution.

```zig
pub fn init(allocator: std.mem.Allocator, scope_name: []const u8, parent: ?*Container) Self
```

---

## Configuration

### ConfigManager

#### `zigmodu.config.ConfigManager`

Centralized configuration management.

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn loadJson(self: *Self, path: []const u8) !void
pub fn getString(self: *Self, key: []const u8) ?[]const u8
pub fn getInt(self: *Self, key: []const u8) ?i64
pub fn getFloat(self: *Self, key: []const u8) ?f64
pub fn getBool(self: *Self, key: []const u8) ?bool
pub fn set(self: *Self, key: []const u8, value: ConfigValue) !void
pub fn has(self: *Self, key: []const u8) bool
```

### ExternalizedConfig

#### `zigmodu.config.ExternalizedConfig`

External configuration with priority-based loading.

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn addSource(self: *Self, name: []const u8, priority: u8, loader: LoaderFn) !void
pub fn load(self: *Self) !void
pub fn get(self: *Self, key: []const u8) ?[]const u8
pub fn watchFile(self: *Self, filepath: []const u8, loader: LoaderFn) !void
pub fn refresh(self: *Self) !void
```

### YAML/TOML Parser

```zig
// YAML
pub fn parseFile(self: *Self, path: []const u8) !std.StringHashMap([]const u8)

// TOML
pub fn parseFile(self: *Self, path: []const u8) !std.StringHashMap([]const u8)
```

---

## Event System

### EventBus

#### `zigmodu.core.EventBus(T)`

Type-safe event bus for inter-module communication.

```zig
pub fn EventBus(comptime T: type) type

// Methods
pub fn init(alloc: std.mem.Allocator) Self
pub fn deinit(self: *Self) void
pub fn subscribe(self: *Self, listener: *const fn (T) void) !void
pub fn unsubscribe(self: *Self, listener: *const fn (T) void) void
pub fn publish(self: *Self, event: T) void
pub fn subscriberCount(self: *Self) usize
```

**Example:**
```zig
const OrderEvent = struct { order_id: u64, status: []const u8 };
const Bus = zigmodu.core.EventBus(OrderEvent);

var bus = Bus.init(allocator);
defer bus.deinit();

try bus.subscribe(handleOrder);
bus.publish(.{ .order_id = 123, .status = "completed" });
```

### TypedEventBus

#### `zigmodu.core.TypedEventBus(T)`

Simplified event bus for single event type.

```zig
pub fn TypedEventBus(comptime T: type) type
```

### DistributedEventBus

#### `zigmodu.core.DistributedEventBus`

Cross-node event communication.

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn start(self: *Self, port: u16) !void
pub fn stop(self: *Self) void
pub fn connectToNode(self: *Self, node_id: []const u8, address: std.net.Address) !void
pub fn publish(self: *Self, topic: []const u8, payload: []const u8) !void
pub fn subscribe(self: *Self, topic: []const u8, callback: Callback) !void
pub fn getConnectedNodes(self: *Self) []const Node
pub fn getNodeCount(self: *Self) usize
```

### TransactionalEvent

#### `zigmodu.core.TransactionalEvent`

Event with saga transaction support.

```zig
pub fn TransactionManager.init(allocator: std.mem.Allocator) TM
pub fn begin(self: *TM) Transaction
pub fn stageEvent(self: *TM, event: anytype) !void

pub fn Transaction.commit(self: *Transaction) !void
pub fn Transaction.rollback(self: *Transaction) void
```

---

## Resilience

### CircuitBreaker

#### `zigmodu.resilience.CircuitBreaker`

Prevent cascade failures with circuit breaker pattern.

```zig
pub fn init(allocator: std.mem.Allocator, name: []const u8, config: Config) !Self
pub fn deinit(self: *Self) void
pub fn call(self: *Self, operation: *const fn () anyerror!void) Result
pub fn reset(self: *Self) void
pub fn forceOpen(self: *Self) void
pub fn getState(self: *Self) State
pub fn getStats(self: *Self) Stats

pub const State = enum { closed, open, half_open }

pub const Config = struct {
    failure_threshold: usize = 5,
    timeout_ms: u64 = 30000,
    half_open_max_calls: usize = 3,
};
```

**Example:**
```zig
var cb = try CircuitBreaker.init(allocator, "order_service", .{
    .failure_threshold = 5,
    .timeout_ms = 30000,
});
defer cb.deinit();

const result = cb.call(&myOperation);
```

### CircuitBreaker Registry

```zig
pub fn CircuitBreakerRegistry.init(allocator: std.mem.Allocator, default_config: Config) Self
pub fn getOrCreate(self: *Self, name: []const u8) !*CircuitBreaker
pub fn get(self: *Self, name: []const u8) ?*CircuitBreaker
pub fn resetAll(self: *Self) void
```

### RateLimiter

#### `zigmodu.resilience.RateLimiter`

Token bucket rate limiting.

```zig
pub fn init(allocator: std.mem.Allocator, name: []const u8, max_tokens: u32, refill_rate: u32) !Self
pub fn deinit(self: *Self) void
pub fn tryAcquire(self: *Self) bool
pub fn acquire(self: *Self) void
pub fn tryAcquireMany(self: *Self, count: u32) bool
pub fn availableTokens(self: *Self) u32
pub fn reset(self: *Self) void
pub fn getStats(self: *Self) Stats
```

### RateLimiter Registry

```zig
pub fn RateLimiterRegistry.init(allocator: std.mem.Allocator, default_max_tokens: u32, default_refill_rate: u32) Self
pub fn getOrCreate(self: *Self, name: []const u8) !*RateLimiter
pub fn getOrCreateForClient(self: *Self, client_id: []const u8, max_tokens: u32, refill_rate: u32) !*RateLimiter
```

### Retry Policy

#### `zigmodu.http.RetryPolicy`

Exponential backoff retry strategy.

```zig
pub fn default() RetryPolicy
pub fn calculateDelay(self: RetryPolicy, attempt: u32) u64
```

---

## Observability

### Distributed Tracing

#### `zigmodu.tracing.DistributedTracer`

OpenTelemetry-compatible distributed tracing.

```zig
pub fn init(allocator: std.mem.Allocator, tracer_name: []const u8, service_name: []const u8) !Self
pub fn deinit(self: *Self) void
pub fn startTrace(self: *Self, span_name: []const u8) !*Span
pub fn startSpan(self: *Self, parent: *Span, span_name: []const u8) !*Span
pub fn endSpan(self: *Self, span: *Span) void
pub fn exportJaeger(self: *Self, span: *Span, allocator: std.mem.Allocator) ![]const u8
pub fn exportZipkin(self: *Self, span: *Span, allocator: std.mem.Allocator) ![]const u8
pub fn injectContext(self: *Self, span: *Span, headers: *std.StringHashMap([]const u8)) !void
pub fn extractContext(self: *Self, headers: std.StringHashMap([]const u8)) ?TraceId
```

**Span Methods:**
```zig
pub fn setAttribute(self: *Span, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void
pub fn addEvent(self: *Span, allocator: std.mem.Allocator, name: []const u8) !void
pub fn end(self: *Span) void
```

### Prometheus Metrics

#### `zigmodu.metrics.PrometheusMetrics`

Prometheus-compatible metrics collection.

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn deinit(self: *Self) void
pub fn createCounter(self: *Self, name: []const u8, help: []const u8) !*Counter
pub fn createGauge(self: *Self, name: []const u8, help: []const u8) !*Gauge
pub fn createHistogram(self: *Self, name: []const u8, help: []const u8, buckets: []const f64) !*Histogram
pub fn createSummary(self: *Self, name: []const u8, help: []const u8) !*Summary
pub fn toPrometheusFormat(self: *Self, allocator: std.mem.Allocator) ![]const u8
```

**Metric Types:**
```zig
// Counter - monotonically increasing
pub fn inc(self: *Counter) void
pub fn add(self: *Counter, value: u64) void

// Gauge - can go up and down
pub fn set(self: *Gauge, value: f64) void
pub fn inc(self: *Gauge) void
pub fn dec(self: *Gauge) void

// Histogram - distribution of values
pub fn observe(self: *Histogram, value: f64) void
```

### Auto Instrumentation

#### `zigmodu.metrics.AutoInstrumentation`

Automatic instrumentation for modules.

```zig
pub fn init(allocator: std.mem.Allocator, metrics: *PrometheusMetrics, tracer: *DistributedTracer) !Self
pub fn recordModuleInit(self: *Self, module_name: []const u8, duration_seconds: f64, success: bool) void
pub fn recordModuleShutdown(self: *Self, module_name: []const u8) void
pub fn recordEventPublished(self: *Self, event_name: []const u8, module_name: []const u8) !?*Span
pub fn recordApiRequestStart(self: *Self, api_name: []const u8, module_name: []const u8) !*Span
```

### Structured Logging

#### `zigmodu.log.StructuredLogger`

JSON-formatted structured logging.

```zig
pub fn init(allocator: std.mem.Allocator, level: LogLevel, output: Output) Self
pub fn withField(self: *Self, key: []const u8, value: []const u8) !void
pub fn log(self: *Self, level: LogLevel, message: []const u8, fields: anytype) !void
pub fn debug(self: *Self, message: []const u8, fields: anytype) !void
pub fn info(self: *Self, message: []const u8, fields: anytype) !void
pub fn warn(self: *Self, message: []const u8, fields: anytype) !void
pub fn err(self: *Self, message: []const u8, fields: anytype) !void
```

---

## HTTP Server & Profiles

### `zigmodu.http.Server`

```zig
pub fn init(io: std.Io, allocator: std.mem.Allocator, port: u16) Server
pub fn initWithConfig(io: std.Io, allocator: std.mem.Allocator, config: Config) Server
pub fn fromEnv(io: std.Io, allocator: std.mem.Allocator, env: std.process.Environ) !Server
pub fn start(self: *Server) !void          // blocks; runs the accept loop
pub fn stop(self: *Server) void
pub fn deinit(self: *Server) void
pub fn addMiddleware(self: *Server, mw: Middleware) !void
pub fn addRoute(self: *Server, route: Route) !void
pub fn group(self: *Server, prefix: []const u8) RouteGroup
pub fn withGracefulDrain(self: *Server, counter: *std.atomic.Value(u64)) void
```

#### `Server.Config`

| Field | Default | Meaning |
|-------|---------|---------|
| `port` | `8080` | listen port |
| `name` | `"zigmodu-api"` | server name |
| `max_body_size` | `8 MiB` | body limit (413 over) |
| `request_timeout_ms` | `30000` | **handler stage** budget |
| `max_requests_per_conn` | `100` | keep-alive reuse cap |
| `header_limits` | `.{ .max_count = 100, .max_total_bytes = 16 KiB }` | header-bomb guard |
| `connection_stack_size` | `128 KiB` | per-connection stack |
| `max_connections` | `0` (unlimited) | concurrent accepted connections; over the limit the socket is closed |
| `over_limit_response` | `.close` | `.close` = cheapest, `.unavailable` = raw-socket `503` first |
| `header_timeout_ms` | `10_000` | request line + headers deadline (slowloris); `0` disables; cleared once headers are read |
| `ws_write_timeout_ms` | `0` (unbounded) | `SO_SNDTIMEO` for WebSocket writes; on timeout the frame fails with `error.WriteTimeout` and the socket is shut down |

Environment equivalents (`fromEnv`): `HTTP_PORT`, `HTTP_MAX_BODY`,
`HTTP_MAX_CONNECTIONS`, `HTTP_HEADER_TIMEOUT_MS`, `WS_WRITE_TIMEOUT_MS`.

### `zigmodu.http.productionProfile`

One call: backpressure + security/observability middleware + `/metrics` +
liveness/readiness probes (+ optional dashboard).

```zig
pub const ProductionConfig = struct {
    max_connections: usize = 0,
    over_limit_response: Server.OverLimitResponse = .close,
    header_timeout_ms: u32 = 10_000,
    request_timeout_ms: ?u32 = null,
    http: ProfileConfig = .{},
    prometheus: bool = true,
    metrics_path: []const u8 = "/metrics",
    health: bool = true,
    liveness_path: []const u8 = "health/live",
    readiness_path: []const u8 = "health/ready",
    dashboard: bool = false,
    tracing: bool = true,
};

pub const ProductionProfileState = struct {
    pub fn init(allocator: std.mem.Allocator) ProductionProfileState
    pub fn deinit(self: *ProductionProfileState, allocator: std.mem.Allocator) void
};

pub fn productionProfile(server: *Server, cfg: ProductionConfig, state: *ProductionProfileState) !void
```

**Ordering constraint**: `Server.addRoute` snapshots the global middleware chain at
registration time, so `productionProfile` must run **before** any
`server.addRoute` / `router.mountAll`. `state` must outlive the server.

Golden signals created by default (label-free, fixed cardinality):

| Metric | Type |
|--------|------|
| `http_requests_total` | counter |
| `http_responses_2xx_total` / `_3xx_` / `_4xx_` / `_5xx_` | counters |
| `http_request_duration_milliseconds` | histogram (1/5/10/25/50/100/250/500/1000/2500/5000 ms) |

Thresholds, PromQL and the Grafana dashboard: [`OBSERVABILITY.md`](OBSERVABILITY.md).

### Existing profiles

| Symbol | Purpose |
|--------|---------|
| `applyHttpDefaults(server, ProfileConfig, *HttpProfileState)` | CORS / request-id / recover / access log / in-memory metrics middleware only |
| `ResilienceProfileState.init(allocator, deps)` / `applyResilienceDefaults` | per-dependency `CircuitBreaker` + `RateLimiter` holders — nothing is enforced until handlers use `breaker(name)` / `limiter(name)` |

### `zigmodu.http.PrometheusMetrics`

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn createCounter(self: *Self, name: []const u8, help: []const u8) !*Counter
pub fn createGauge(self: *Self, name: []const u8, help: []const u8) !*Gauge
pub fn createHistogram(self: *Self, name: []const u8, help: []const u8, buckets: []const f64) !*Histogram
pub fn toPrometheusFormat(self: *Self, allocator: std.mem.Allocator) ![]const u8
pub fn registerMetricsRoute(self: *Self, server: anytype) !void            // GET /metrics
pub fn registerMetricsRoutePath(self: *Self, server: anytype, path: []const u8) !void
```

---

## Hardening primitives

### `zigmodu.FrozenMap` / `zigmodu.FrozenStringMap`

Build-time-populated, run-time read-only maps for app-level shared registries.
Fill during startup, `freeze()` before serving; afterwards reads are lock-free
and safe for any number of concurrent readers, and writes fail with
`error.Frozen` instead of racing a resize (the `panic: incorrect alignment`
class).

```zig
pub fn FrozenMap(comptime K: type, comptime V: type) type
pub fn FrozenStringMap(comptime V: type) type
// methods: init(allocator), deinit(), freeze(), isFrozen(), put(K, V), remove(K),
//          get(K) ?V, contains(K), count(), iterator()
```

### `zigmodu.panicHook`

Request-aware panic handler. The server records `METHOD /path` into a threadlocal
slot before dispatch; on panic the hook prints it to stderr (no allocation)
before delegating to `std.debug.defaultPanic`.

```zig
// in the application root file (the one with `main`):
const zmodu = @import("zigmodu");
pub const panic = zmodu.panicHook;
```

A panic still aborts the process — the hook is the *diagnosis* half. Recovery
comes from a supervisor (`Restart=always`, k8s `restartPolicy: Always`); see
[`BEST_PRACTICES.md`](BEST_PRACTICES.md)「韧性」and
[`PRODUCTION_ROADMAP.md`](PRODUCTION_ROADMAP.md) for the prefork boundary.

### `zigmodu.http.Params` (multi-value query/form)

`ctx.query` and `ctx.form` are `Params`, not `StringHashMap`: HTML's two native
"several values for one name" shapes are kept.

```zig
pub fn put(self, name, value) !void            // duplicates; repeated names accumulate
pub fn putOwned(self, name, value) !void       // takes ownership (parsers use this)
pub fn get(self, name) ?[]const u8             // LAST occurrence (compat with the old map)
pub fn getFirst(self, name) ?[]const u8
pub fn getAll(self, name) []const []const u8
pub fn getArray(self, allocator, name) ![][]const u8   // name[0..n] sorted, then name[]
pub fn getPath(self, path) ?[]const u8         // "filter.tags" → filter[tags]
pub fn totalValues(self) usize                 // occurrences — what the guard counts
```

Context helpers: `queryValues` / `formValues` / `queryArray` / `formArray` /
`paramPath`. Guard: `Server.Config.max_params` (default 1000 → `error.TooManyParams`).

### `zigmodu.http.Multipart`

```zig
pub const Config = struct { max_parts: usize = 64, max_part_bytes: usize = 8 MiB, max_total_bytes: usize = 32 MiB };
pub fn parse(allocator, body, content_type, config) Error!Form
pub const Form = struct {
    pub fn value(self, name) ?[]const u8      // text fields only
    pub fn file(self, name) ?*const Part      // filename/data/content_type
    pub fn textFields(self, allocator) !std.StringHashMap([]const u8)
    pub fn deinit(self) void
};

// Context:
pub fn multipart(self: *const Context, config: Multipart.Config) Multipart.Error!Multipart.Form
pub fn bindMultipart(self: *const Context, comptime T: type, config: Multipart.Config) !T
```

### `zigmodu.http.staticFiles` (static file serving)

```zig
pub fn staticFiles(io, server: *Server, allocator, prefix: []const u8, root_dir: []const u8, config: Config) !void
pub fn staticMiddleware(io, allocator, prefix, root_dir, config) Middleware
```

Implemented as middleware (the router's `/prefix/*` matches only the prefix
itself). Serves `GET`/`HEAD` only; no directory index; normalizes paths before
touching the filesystem; `ETag` + `If-None-Match` → 304; `Range` → 206/416;
bodies above `max_bytes` (16 MiB default) → 413.

### Metrics with bounded labels

```zig
pub fn createCounterFamily(self, name, help, label, max_series: usize, io: std.Io) !*CounterFamily
pub fn createHistogramFamily(self, name, help, label, max_series: usize, buckets: []const f64, io: std.Io) !*HistogramFamily
// family.get(label_value) -> *Counter / *Histogram   (cap → shared "__other__" series)
pub fn setScrapeHook(self, hook: ?ScrapeHook, userdata: ?*anyopaque) void  // sampled at scrape time
```

Labels must be low-cardinality by construction: `productionProfile` labels the
golden signals with `Context.route_template` (the matched pattern), never the raw
path. See [`OBSERVABILITY.md`](OBSERVABILITY.md).

### `zigmodu.outbox.OutboxConsumer`

```zig
pub fn setMetrics(self: *Self, metrics: *PrometheusMetrics) !void   // selected/delivered/failed + pending gauge
pub fn pendingCount(self: *Self) !u64
pub fn refreshPending(self: *Self) void
pub fn startPolling(self: *Self, io: std.Io, interval_ms: u64) !void
pub fn stopPolling(self: *Self) void
pub fn pollOnce(self: *Self) !PollStats
```

### `zigmodu.Preflight`

Startup checks that turn "it broke at 3am" into "it refused to start".

```zig
pub const Severity = enum { warn, fatal };
pub const Check = struct { name, severity = .fatal, run, ctx };
pub const Report = struct { pub fn ok(self) bool; pub fn log(self) void; pub fn deinit(self) void };
pub fn run(allocator, checks: []const Check) Report

// ready-made probes
pub fn envCheck(*EnvCheck) Check                     // EnvCheck.fromMap(init.environ_map, names)
pub fn secretCheck(*SecretCheck) Check               // rejects placeholders / < min_len
pub fn dbCheck(client: anytype) Check                // SELECT 1
pub fn migrationCheck(*MigrationCheck) Check         // pending > 0 → error
pub fn clockCheck(*ClockCheck) Check                 // wall-clock sanity
```

Checks never panic and are isolated: one failure does not hide the others.
See [`BEST_PRACTICES.md`](BEST_PRACTICES.md)「上线前预检」.

### `zigmodu.security.JwksKeyRing` (key rotation)

`SecurityModule.setKeyring(&ring)` makes new tokens carry `kid`; verification
uses the key the token names and rejects unknown kids (`error.UnknownKeyId`).
Rotate by adding a new primary key and keeping the old one in the ring until
its tokens expire.

### `zigmodu.DistributedLock`

Cross-instance mutual exclusion for background work (cron jobs, migrations).

```zig
pub const Lock = struct {
    pub fn tryAcquire(self: Lock, name: []const u8, ttl_ms: u64) anyerror!bool
    pub fn release(self: Lock, name: []const u8) void
};
pub const NoopLock = struct { pub fn lock(self: *NoopLock) Lock };
pub const Dialect = enum { sqlite, postgres, mysql };
pub fn SqlLock(comptime Client: type) type // init(allocator, io, client, table, dialect)
```

Consumers: `cron.Scheduler.setLock(lock, ttl_ms)` (key `cron:<job>`) and
`data.MigrationRunner.setLock(lock, ttl_ms)` (key `zigmodu:migration`, returns
`error.MigrationLocked` when another instance holds it).

Coverage: SQLite in-memory, plus a real PostgreSQL 17 test gated on
`ZIGMODU_TEST_PG=1` (CI's `test-postgres` job sets it, along with `PGHOST` /
`PGPORT` / `PGUSER` / `PGPASSWORD` / `PGDATABASE`). The MySQL variant
(`INSERT IGNORE`) is implemented but still awaits a real-server test. Claiming is one atomic
statement (`ON CONFLICT DO NOTHING` / `INSERT IGNORE`), so contention is
`rows_affected == 0`, not an error; a crashed holder is reaped after `ttl_ms`.
See [`BEST_PRACTICES.md`](BEST_PRACTICES.md)「多副本后台任务」.

### `zigmodu.NetworkProbe`

```zig
pub fn available() bool   // loopback TCP usable?
```

Used by socket-dependent tests to `return error.SkipZigTest` in sandboxes.
`zig build test -Dnet-tests=false` forces it to `false` so the whole suite skips
network cases.

### `zigmodu.im.WsFramer` (outbound control)

```zig
pub fn setSendTimeout(self: *WsFramer, timeout_ms: u32) void  // 0 = unbounded
pub fn isWritable(self: *WsFramer) bool                       // O(1) send-buffer probe
```

---

## Transport

### Transport Protocols

ZigModu ships HTTP/1.1 and h2c in `http.Server` (`enable_http2`), and gRPC over
HTTP/2 via `extensions/GrpcTransport.zig` + `GrpcServiceRegistry`. There is no
`TransportProtocol` enum and no built-in MQTT transport — bring your own client
for those (an MQTT client is not part of the framework).

### gRPC Transport (unary)

```zig
// Local (modulith)
var registry = zigmodu.GrpcServiceRegistry.init(allocator);
defer registry.deinit();
try registry.registerService("echo.Echo");
try registry.registerMethod("echo.Echo", "Say", .unary, handler);

var client = zigmodu.GrpcClient.init(allocator);
defer client.deinit();
client.bindLocal(&registry);
var resp = try client.call("echo.Echo", "Say", proto_bytes);
defer resp.deinit();

// HTTP/1.1 application/grpc
var net = zigmodu.GrpcClient.initWithIo(allocator, io);
defer net.deinit();
try net.registerEndpoint("echo.Echo", "127.0.0.1", 50051);
var remote = try net.call("echo.Echo", "Say", proto_bytes);
defer remote.deinit();

// Framing helpers
const framed = try zigmodu.GrpcFrame.encode(allocator, proto_bytes);
defer allocator.free(framed);
const payload = try zigmodu.GrpcFrame.decode(framed);
```

HTTP unary server side: `registry.handleHttpUnary(path, body)` → set `grpc-status` / `grpc-message` headers + framed body.

### SecretsManager (Vault KV v2)

```zig
var sm = zigmodu.security.SecretsManager.initWithIo(allocator, io);
defer sm.deinit();
try sm.configureVaultEx(.{
    .address = "http://127.0.0.1:8200",
    .token = "dev-root-token",
    .mount_path = "secret",
});
try sm.loadFromVault("database/creds"); // GET /v1/secret/data/database/creds
const host = sm.get("DB_HOST"); // priority: env > file > vault > default
```

- `applyVaultKvJson(body)` — unit-test / inject KV JSON without HTTP.
- `https://` → `error.VaultTlsNotSupported` (plain HTTP only; use local Vault or TLS-terminating proxy).
- Live smoke: `VAULT_ADDR` + `VAULT_TOKEN` (+ optional `VAULT_MOUNT` / `VAULT_SECRET_PATH`).

### MQTT Transport

Not provided. Use an external MQTT client library; the framework's HTTP stack
(`http.HttpClient`) is unrelated to MQTT.

### HTTP Client

#### `zigmodu.http.HttpClient`

HTTP client with connection pooling.

```zig
pub fn init(allocator: std.mem.Allocator, max_connections: usize, timeout_ms: u64) Self
pub fn deinit(self: *Self) void
pub fn request(self: *Self, req: HttpRequest) !HttpResponse
pub fn get(self: *Self, url: []const u8) !HttpResponse
pub fn post(self: *Self, url: []const u8, body: []const u8) !HttpResponse
pub fn put(self: *Self, url: []const u8, body: []const u8) !HttpResponse
pub fn delete(self: *Self, url: []const u8) !HttpResponse
```

### HTTP Server



#### Overview



ZigModu provides an async fiber-based HTTP server built on `std.Io`. It supports routing, middleware chains, keep-alive connections, and structured request handling aligned with go-zero's rest package.



**Architecture**: Each incoming connection is handled by an independent fiber via `std.Io.Group.async`, enabling true concurrent request processing without manual thread pools. The underlying I/O uses kqueue (macOS) or io_uring/epoll (Linux) for efficient async operations.



#### Server



`zigmodu.http.Server` — Main async HTTP server.



```zig

pub fn init(io: std.Io, allocator: std.mem.Allocator, port: u16) Server

pub fn deinit(self: *Server) void



// Route management

pub fn addRoute(self: *Server, route: Route) !void

pub fn group(self: *Server, prefix: []const u8) RouteGroup

pub fn addMiddleware(self: *Server, mw: Middleware) !void



// Lifecycle

pub fn start(self: *Server) !void  // Blocks until stop() is called

pub fn stop(self: *Server) void    // Gracefully stops accepting new connections

```



**Server Options:**



| Field | Default | Description |

|-------|---------|-------------|

| `max_body_size` | 8 MB | Maximum request body size |

| `request_timeout_ms` | 30000 | Request timeout in milliseconds |

| `max_requests_per_conn` | 100 | Maximum keep-alive requests per connection |



**Example:**



```zig

const std = @import("std");

const zigmodu = @import("zigmodu");



const Server = zigmodu.http.Server;

const Context = zigmodu.http.Context;



pub fn main(init: std.process.Init) !void {

    const allocator = init.gpa;

    const io = init.io;



    var server = Server.init(io, allocator, 8080);

    defer server.deinit();



    // Register routes

    try server.addRoute(.{

        .method = .GET,

        .path = "/health",

        .handler = struct {

            fn handle(ctx: *Context) anyerror!void {

                try ctx.json(200, "{\"status\":\"ok\"}");

            }

        }.handle,

    });



    // Start server (blocks until stop() is called)

    try server.start();

}

```



#### HTTP Methods



```zig

pub const Method = enum { GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS };



pub fn fromString(s: []const u8) Method

pub fn toString(self: Method) []const u8

```



#### Route Definition



```zig

pub const Route = struct {

    method: Method,

    path: []const u8,

    handler: HandlerFn,

    middleware: []const Middleware = &.{},  // Per-route middleware

    user_data: ?*anyopaque = null,

};

```



#### Handler Function



```zig

pub const HandlerFn = *const fn (*Context) anyerror!void;

```



#### Context



`Context` holds request data and provides response helpers. Automatically cleaned up per request via arena allocation.



**Request Access:**



```zig

pub fn queryParam(self: *const Context, key: []const u8) ?[]const u8

pub fn param(self: *const Context, key: []const u8) ?[]const u8       // Path param like /users/{id}

pub fn header(self: *const Context, key: []const u8) ?[]const u8

pub fn formValue(self: *const Context, key: []const u8) ?[]const u8

body: ?[]const u8            // field, not a method

```



**Response Helpers:**



```zig

pub fn json(self: *Context, status: u16, data: []const u8) !void

pub fn text(self: *Context, status: u16, data: []const u8) !void

pub fn sendError(self: *Context, status: u16, message: []const u8) !void

pub fn sendErrorResponse(self: *Context, status: u16, code: i32, message: []const u8) !void

pub fn setHeader(self: *Context, key: []const u8, value: []const u8) !void

```



**JSON Binding:**



```zig

pub fn bindJson(self: *const Context, comptime T: type) !T

pub fn parseReq(self: *Context, comptime T: type, sources: anytype) !T

```



**Example — Auto parameter binding:**



```zig

const MyReq = struct { id: u32, page: u32 };

const req = try ctx.parseReq(MyReq, .{ .id = .path, .page = .query });

// GET /users/42?page=3 → req.id = 42, req.page = 3

```



#### Route Groups



Group routes under a common prefix:



```zig

var api = server.group("/api/v1");

try api.get("/users", handleUsers, null);

try api.post("/orders", handleOrders, null);

// Routes: GET /api/v1/users, POST /api/v1/orders

```



#### Middleware



```zig

pub const Middleware = struct {

    func: MiddlewareFn,

    user_data: ?*anyopaque = null,

};



pub const MiddlewareFn = *const fn (*Context, HandlerFn, ?*anyopaque) anyerror!void;

```



Middleware executes in order: global middleware → route middleware → handler. Call the next handler via `try next(ctx, next, user_data)`.



**Example — Auth middleware:**



```zig

fn authMiddleware(ctx: *Context, next: HandlerFn, user_data: ?*anyopaque) anyerror!void {

    const token = ctx.header("Authorization") orelse {

        return ctx.sendError(401, "Unauthorized");

    };

    // Validate token...

    try next(ctx, next, user_data);

}



try server.addMiddleware(.{ .func = authMiddleware });

```



#### Complete Example



```zig

const std = @import("std");

const zigmodu = @import("zigmodu");

const Server = zigmodu.http.Server;

const Context = zigmodu.http.Context;



pub fn main(init: std.process.Init) !void {

    var server = Server.init(init.io, init.gpa, 8080);

    defer server.deinit();



    // JSON endpoint

    try server.addRoute(.{

        .method = .GET,

        .path = "/api/health",

        .handler = struct {

            fn handle(ctx: *Context) anyerror!void {

                try ctx.json(200, "{\"status\":\"ok\"}");

            }

        }.handle,

    });



    // Plain text endpoint

    try server.addRoute(.{

        .method = .GET,

        .path = "/ping",

        .handler = struct {

            fn handle(ctx: *Context) anyerror!void {

                try ctx.text(200, "pong");

            }

        }.handle,

    });



    // Route group with path params

    var users = server.group("/api/users");

    try users.get("/{id}", struct {

        fn handle(ctx: *Context) anyerror!void {

            const id = ctx.param("id") orelse return ctx.sendError(400, "missing id");

            try ctx.json(200, try std.fmt.allocPrint(ctx.allocator, "{{\"id\":\"{s}\"}}", .{id}));

        }

    }.handle, null);



    try server.start();

}

```
---

## Security

### JWT Authentication

#### `zigmodu.security.JwtModule`

JWT token generation and verification.

```zig
pub fn init(allocator: std.mem.Allocator, jwt_secret: []const u8, token_expiry_seconds: i64) Self
pub fn generateToken(self: *Self, payload: JwtPayload) ![]const u8
pub fn verifyToken(self: *Self, token_string: []const u8) !JwtPayload
pub fn hashPassword(self: *Self, password: []const u8) ![]const u8
pub fn verifyPassword(self: *Self, password: []const u8, hash: []const u8) bool
```

### Security Scanner

#### `zigmodu.security.SecurityScanner`

Static security analysis for source code.

```zig
pub fn init(allocator: std.mem.Allocator, config: Config) Self
pub fn registerRule(self: *Self, rule: SecurityRule) !void
pub fn scanSourceCode(self: *Self, file_path: []const u8, source_code: []const u8) !void
pub fn scanModule(self: *Self, module_path: []const u8) !ScanResult
pub fn generateReport(self: *Self, result: *const ScanResult) ![]const u8
pub fn isSecure(self: *Self, result: *const ScanResult) bool
```

---

## Testing

### Module Testing

#### `zigmodu.test.ModuleTestContext`

Testing context for module testing.

```zig
pub fn init(allocator: std.mem.Allocator, module_name: []const u8) !Self
pub fn deinit(self: *Self) void
pub fn registerMockModule(self: *Self, info: ModuleInfo) !void
pub fn start(self: *Self) !void
pub fn stop(self: *Self) void
```

### Integration Testing

#### `zigmodu.test.IntegrationTest`

Full integration test framework.

```zig
pub fn init(allocator: std.mem.Allocator, config: TestConfig) !Self
pub fn deinit(self: *Self) void
pub fn http(self: *Self) !*HttpTestClient
pub fn setUp(self: *Self) !void
pub fn tearDown(self: *Self) !void
pub fn waitFor(self: *Self, condition: fn () bool, timeout_ms: u64) !void
```

### Benchmark

#### `zigmodu.test.Benchmark`

Performance benchmarking utilities.

```zig
pub fn init(allocator: std.mem.Allocator, name: []const u8, config: Config) !Self
pub fn run(self: *Self, bench_name: []const u8, comptime BenchFn: type, bench_ctx: anytype) !void
pub fn generateReport(self: *Self) ![]const u8
```

---

## Additional Components

### Cache

```zig
pub const CacheManager = struct {
    pub fn init(allocator: std.mem.Allocator, max_size: usize, ttl_seconds: u64, policy: EvictionPolicy) Self
    pub fn set(self: *Self, key: []const u8, value: []const u8) !void
    pub fn get(self: *Self, key: []const u8) ?[]const u8
    pub fn remove(self: *Self, key: []const u8) bool
    pub fn clear(self: *Self) void
    pub fn getStats(self: *Self) CacheStats
};
```

### Scheduler

#### `zigmodu.cron.Scheduler` (`src/scheduler/Cron.zig`)

Cron expression jobs (`* * * * *`), driven by a background thread. For
multi-replica deployments guard it with `DistributedLock` (see
[`BEST_PRACTICES.md`](BEST_PRACTICES.md)「多副本后台任务」).

```zig
pub fn init(allocator: std.mem.Allocator, io: std.Io) Scheduler
pub fn deinit(self: *Scheduler) void
pub fn addJob(self: *Scheduler, name: []const u8, schedule: Expression, task: *const fn (*anyopaque) void, context: *anyopaque) !void
pub fn setLock(self: *Scheduler, lock: DistributedLock.Lock, ttl_ms: u64) void
pub fn start(self: *Scheduler) !void
pub fn stop(self: *Scheduler) void
pub fn tick(self: *Scheduler, now: i64) void   // deterministic driving, used by tests
```

### Database / Repository

```zig
pub const Database = struct {
    pub fn init(allocator: std.mem.Allocator, connection_string: []const u8) !Self
    pub fn query(self: *Self, sql: []const u8, params: QueryParams) QueryResult
    pub fn execute(self: *Self, sql: []const u8, params: QueryParams) !void
    pub fn beginTransaction(self: *Self) !Transaction
};

pub fn Repository(comptime T: type) type {
    pub fn findById(self: *Self, id: i64) !?T
    pub fn findByIds(self: *Self, allocator: Allocator, ids: []const i64) !QueryResult(T)  // WHERE pk IN (…) 一次 round-trip
    pub fn insert(self: *Self, entity: T) !T
    pub fn insertMany(self: *Self, allocator: Allocator, entities: []const T) !void    // 多行 VALUES (?,?),(?,?) 一次 round-trip
    pub fn upsertMany(self: *Self, allocator: Allocator, entities: []const T, conflict_columns: []const []const u8) !void
    pub fn update(self: *Self, entity: T) !void
    pub fn delete(self: *Self, id: i64) !void
    pub fn findAll(self: *Self, buf: []T) ![]T
}
```

`data.bulk` (`src/sqlx/Bulk.zig`) 提供底层批量写助手，供手写 SQL 代码直接使用
（`sqlx.Client` / `Transaction` / `SqlxBackend` 均可作为 exec 目标）：

```zig
pub const bulk = zigmodu.data.bulk;
_ = try bulk.insertMany(alloc, &client, "order_product", &.{ "order_id", "sku" }, &rows, .sqlite, .{
    .conflict_columns = &.{"id"},
}); // upsert 后缀：SQLite/PG → ON CONFLICT ("id") DO UPDATE SET …；MySQL → ON DUPLICATE KEY UPDATE
```

批量写是 API 演进而非范式问题：手写 sqlx 与 Repository 两条路径共用同一
生成器；对 zigshop 这类裸 sqlx 项目，换用 `bulk.insertMany` 即可把
下单商品从 N 次 round-trip 降为 1 次，无需引入 zent。

### Cluster Membership

```zig
pub const ClusterMembership = struct {
    pub fn init(allocator: std.mem.Allocator, node_id: []const u8, address: std.net.Address, bus: *DistributedEventBus) !Self
    pub fn start(self: *Self, config: Config) !void
    pub fn stop(self: *Self) void
    pub fn connectToSeed(self: *Self, node_id: []const u8, address: std.net.Address) !void
    pub fn getNodeCount(self: *Self) usize
    pub fn getHealthyNodeCount(self: *Self) usize
    pub fn getLeader(self: *Self) ?[]const u8
};
```

### Raft (experimental)

Leader election lives in `src/core/cluster/RaftElection.zig` (plus
`ClusterMembership` / `ClusterHealth`). It is marked **experimental** — see
[`PRODUCTION_ROADMAP.md`](PRODUCTION_ROADMAP.md) for the position on using it
in production. The older `PasRaftAdapter` documented here never existed in this
repository.

### Hot Reloader

```zig
pub const HotReloader = struct {
    pub fn init(allocator: std.mem.Allocator) Self
    pub fn watchPath(self: *Self, path: []const u8) !void
    pub fn startWatching(self: *Self) !void
    pub fn stopWatching(self: *Self) void
    pub fn reloadModule(self: *Self, module_path: []const u8) !void
};
```

### Plugin System

```zig
pub const PluginManager = struct {
    pub fn init(allocator: std.mem.Allocator, plugin_dir: []const u8) Self
    pub fn loadPlugin(self: *Self, name: []const u8, path: []const u8) !void
    pub fn unloadPlugin(self: *Self, name: []const u8) void
    pub fn enablePlugin(self: *Self, name: []const u8) !void
    pub fn loadAllPlugins(self: *Self) !void
    pub fn getLoadedPlugins(self: *Self) []const Plugin
};
```

---

*Last updated: 2025-04-15*
*For more examples, see [examples](../examples/)*
