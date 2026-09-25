# ZigModu API Reference

Complete API reference for the ZigModu modular framework.

> 1.0 冻结的入口类别、0.x 允许破坏的 preview 面（`runtime.*`），以及每一条对应的门禁：
> [`API_FREEZE.md`](API_FREEZE.md)。弃用别名与删除时点见 [`UPGRADING.md`](UPGRADING.md) 顶部那张表。

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
13. [Error response rendering](#error-response-rendering)
14. [Uploads](#uploads)

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

**DEPRECATED**（不早于 1.0 删除）：改用 `Application.start()` / `Application.stop()`，见
[`UPGRADING.md`](UPGRADING.md) 的弃用别名表。

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
    io: std.Io,
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
    // 启动期超限告警（warnOverDependencyLimit）；0 关闭
    max_dependencies: usize = 8,
};
```

**Example:**
```zig
var app = try zigmodu.Application.init(
    io,
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
var builder = zigmodu.builder(allocator, io);   // io 来自 std.process.Init / 应用的 Io
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

#### `zigmodu.Container`

Service container for dependency injection.

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn deinit(self: *Self) void
pub fn freeze(self: *Self) void
pub fn register(self: *Self, comptime T: type, name: []const u8, instance: *T) !void
pub fn registerBorrowed(self: *Self, comptime T: type, name: []const u8, instance: *T) !void
pub fn get(self: *Self, comptime T: type, name: []const u8) ?*T
pub fn getComptime(self: *Self, comptime T: type, comptime name: []const u8) ?*T
pub fn contains(self: *Self, name: []const u8) bool
pub fn remove(self: *Self, name: []const u8) void
pub fn serviceCount(self: *Self) usize
```

`register` takes ownership (the container destroys the instance on
`remove`/`deinit`); `registerBorrowed` does not. After `freeze()`, `register` and
`registerBorrowed` return `error.ContainerFrozen`, `remove` warns and is a no-op,
and `get`/`contains` are lock-free reads.

**Example:**
```zig
var container = zigmodu.Container.init(allocator);
defer container.deinit();

try container.register(Database, "main_db", &db_instance);
const db = container.get(Database, "main_db");
```

### Scoped Container

#### `zigmodu.ScopedContainer`

Scoped dependency container with parent resolution. Hoisted like `zigmodu.Container`
(there is no `zigmodu.di` namespace); own registrations win, misses fall through to
`parent`.

```zig
pub fn init(allocator: std.mem.Allocator, scope_name: []const u8, parent: ?*Container) Self
pub fn deinit(self: *Self) void
pub fn register(self: *Self, comptime T: type, name: []const u8, instance: *T) !void
pub fn registerBorrowed(self: *Self, comptime T: type, name: []const u8, instance: *T) !void
pub fn get(self: *Self, comptime T: type, name: []const u8) ?*T
pub fn contains(self: *Self, name: []const u8) bool
pub fn remove(self: *Self, name: []const u8) void
pub fn serviceCount(self: *Self) usize
```

**Semantics — the two halves do not fall through the same way:**

| Falls through to `parent` | Local only |
|---|---|
| `get`, `contains` | `register`, `registerBorrowed`, `remove`, `serviceCount` |

`remove` drops this scope's own registration and never reaches the parent: a
scope unregistering a shared service would leave every other reader of the parent
container holding a destroyed instance. `serviceCount` counts this scope's
registrations only — the same name may be registered at both levels and would
otherwise count twice. There is no `freeze` and no `getComptime` here: a scope is
short-lived, the framework's freeze point is the application `Container` after
`start()`, and the local→parent lookups are runtime branches that a comptime
specialization cannot hoist away.

---

## Configuration

### ConfigManager

#### `zigmodu.ConfigManager`

Centralized configuration management. Hoisted from `src/config/ConfigManager.zig`
(there is no `zigmodu.config` namespace); `ModuleConfig` gives one module a key
prefix over the same store.

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

The store loads JSON itself; TOML arrives through `zigmodu.TomlLoader` below.

### TomlLoader

#### `zigmodu.TomlLoader`

Fills an existing `ConfigManager` from a `.toml` file — sections become
dotted keys (`[server]` + `port` → `server.port`) and values keep their TOML
type, so `getInt` / `getBool` / `getFloat` work on them. Owned by the caller:
construct it per load, and `deinit` the store as usual.

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn loadFile(self: *Self, path: []const u8, config: *ConfigManager) !void
```

```zig
var config = zigmodu.ConfigManager.init(allocator);
defer config.deinit();

var loader = zigmodu.TomlLoader.init(allocator);
try loader.loadFile("app.toml", &config);

const port = config.getInt("server.port") orelse 8080;
```

For a flat string→string map instead (no typed reads), `zigmodu.TomlParser` in
the parser section below does the same job without a store.

### ExternalizedConfig

#### `zigmodu.ExternalizedConfig`

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

#### `zigmodu.YamlParser` / `zigmodu.TomlParser`

Both flatten a file into a `StringHashMap([]const u8)` — values stay strings, so
numbers and booleans need parsing by hand. Reach for `zigmodu.TomlLoader` above
instead when you want typed reads out of the same key space.

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn parseFile(self: *Self, path: []const u8) !std.StringHashMap([]const u8)
pub fn parse(self: *Self, content: []const u8) !std.StringHashMap([]const u8)
pub fn deinitMap(self: *Self, map: *std.StringHashMap([]const u8)) void
```

Ownership: the returned map and the strings in it are the parser's allocations —
hand the map back to `deinitMap` rather than freeing it field by field.

---

## Event System

### EventBus

#### `zigmodu.EventBus(T)`

**无类型事件总线**：`T` 是**事件类型键**（枚举等可哈希类型），payload 以
`*anyopaque` 传递、由回调自己转回来；一个实例可挂任意多个事件类型。
**非线程安全**；并发场景用 `ThreadSafeEventBus`（根导出
`zigmodu.ThreadSafeEventBus`），或模块里 `ModuleContext.eventBus(...)`
拿到的应用级总线。

```zig
pub fn EventBus(comptime T: type) type

// Methods
pub fn init(alloc: std.mem.Allocator) Self
pub fn initCapacity(alloc: std.mem.Allocator, capacity: usize) Self   // 容量是提示，失败只 warn
pub fn deinit(self: *Self) void
pub fn subscribe(self: *Self, event_type: T, callback: *const fn (T, *anyopaque) void) !void
pub fn unsubscribe(self: *Self, event_type: T, callback: *const fn (T, *anyopaque) void) void
pub fn publish(self: *Self, event_type: T, payload: *anyopaque) void
pub fn subscriberCount(self: *Self, event_type: T) usize
pub fn totalSubscriberCount(self: *Self) usize
```

**Example:**
```zig
const Topic = enum { order_created };
const OrderEvent = struct { order_id: u64, status: []const u8 };

const Bus = zigmodu.EventBus(Topic);

var bus = Bus.init(allocator);
defer bus.deinit();

var event = OrderEvent{ .order_id = 123, .status = "completed" };
try bus.subscribe(.order_created, onOrderCreated);
bus.publish(.order_created, &event);

fn onOrderCreated(topic: Topic, payload: *anyopaque) void {
    _ = topic;
    const e: *OrderEvent = @ptrCast(@alignCast(payload));
    _ = e.order_id;
}
```

### TypedEventBus

#### `zigmodu.TypedEventBus(T)`

单事件类型的简化总线：payload **按值**传递（`fn (T) void`），不用 `*anyopaque`
转换。同样**非线程安全**。

```zig
pub fn TypedEventBus(comptime T: type) type

// Methods
pub fn init(alloc: std.mem.Allocator) Self
pub fn deinit(self: *Self) void
pub fn subscribe(self: *Self, listener: *const fn (T) void) !void
pub fn subscribeAsync(self: *Self, pool: *WorkerPool, handler: *const fn (T) void) !void
pub fn unsubscribe(self: *Self, listener: *const fn (T) void) void
pub fn publish(self: *Self, event: T) void
pub fn subscriberCount(self: *Self) usize
pub fn publishedCount(self: *Self) u64              // publish 被调用过多少次
pub fn droppedAsyncCount(self: *Self) u64           // 异步投递因分配/派发失败而丢弃的次数
```

**Example:**
```zig
const OrderEvent = struct { order_id: u64, status: []const u8 };
const Bus = zigmodu.TypedEventBus(OrderEvent);

var bus = Bus.init(allocator);
defer bus.deinit();

try bus.subscribe(handleOrder);
bus.publish(.{ .order_id = 123, .status = "completed" });
```

### DistributedEventBus

#### `zigmodu.DistributedEventBus`

Cross-node event communication.

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn start(self: *Self, port: u16) !void
pub fn stop(self: *Self) void
pub fn connectToNode(self: *Self, node_id: []const u8, address: std.net.Address) !void
pub fn publish(self: *Self, topic: []const u8, payload: []const u8) !void
pub fn subscribe(self: *Self, topic: []const u8, callback: Callback) !void
// 安全遍历（推荐）：在注册表锁内整份拷贝，返回的元素归调用方，用完 deinit()
pub fn snapshotNodes(self: *Self, allocator: std.mem.Allocator) !NodeSnapshot
// 无锁视图（不持有注册表锁，切片可能在并发 connect/disconnect 时 realloc/失效）：
// 只在调用方自行保证独占时合法，其他场合请用 snapshotNodes
pub fn getConnectedNodes(self: *Self) []const *Node
pub fn getNodeCount(self: *Self) usize
```

### TransactionalEvent — removed

`src/core/TransactionalEvent.zig` was deleted: it was a stub, not an implementation.
`TransactionManager.stageEvent` and `Transaction.addEvent` discarded their argument
(`_ = event;`), `commit` only flipped a local state field, and `EventOutbox.store`
allocated a zero-length payload. It had no `root.zig` export and no caller anywhere in
`src/`, `examples/` or `tools/`, so there was nothing to keep for. The working
implementations are the outbox (`zigmodu.outbox.OutboxPublisher` / `OutboxPoller`, see
§ `zigmodu.outbox.OutboxConsumer` below) and, for compensating long-running flows,
`zigmodu.SagaOrchestrator`.

---

## Resilience

### CircuitBreaker

#### `zigmodu.CircuitBreaker`

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

#### `zigmodu.RateLimiter`

Token bucket rate limiting. **线程安全**（内部短自旋守卫），可跨线程共享。

```zig
pub fn init(allocator: std.mem.Allocator, name: []const u8, max_tokens: u32, refill_rate: u32) !Self
pub fn deinit(self: *Self) void
pub fn tryAcquire(self: *Self) bool
pub fn acquire(self: *Self) bool          // DEPRECATED: 同 tryAcquire（同步上下文无法阻塞等待）
pub fn tryAcquireMany(self: *Self, count: u32) bool
pub fn release(self: *Self) void          // 归还一枚令牌（预留后未用上的场景）
pub fn availableTokens(self: *Self) u32
pub fn reset(self: *Self) void
pub fn getStats(self: *Self) Stats
```

### RateLimiter Registry

```zig
pub fn RateLimiterRegistry.init(allocator: std.mem.Allocator, default_max_tokens: u32, default_refill_rate: u32) Self
pub fn initWithCapacity(allocator, default_max_tokens, default_refill_rate, max_keys: usize) Self
pub fn getOrCreate(self: *Self, name: []const u8) !*RateLimiter
pub fn getOrCreateForClient(self: *Self, client_id: []const u8, max_tokens: u32, refill_rate: u32) !*RateLimiter
pub fn get(self: *Self, name: []const u8) ?*RateLimiter
pub fn remove(self: *Self, name: []const u8) bool
pub fn retain(self: *Self, max_idle_seconds: i64) usize
pub fn count(self: *Self) usize
pub fn generateReport(self: *Self, allocator: std.mem.Allocator) ![]const u8
```

`max_keys` (default 0 = unbounded) caps tracked limiters and evicts the
least-recently-used on insert. Per-client keys come from the request, so an
unbounded registry grows for as long as someone invents new keys — set a cap when
you key by IP. `getOrCreate*` returns a pointer that stays valid for the life of
the registry.

### SlidingWindowRateLimiter

#### `zigmodu.SlidingWindowRateLimiter`

窗口内计数限流；**线程安全**。Hoisted like `zigmodu.RateLimiter` (there is no
`zigmodu.resilience` namespace).

```zig
pub fn init(allocator: std.mem.Allocator, name: []const u8, window_size_seconds: u64, max_requests: u32) !Self
pub fn deinit(self: *Self) void
pub fn tryAcquire(self: *Self) bool
pub fn currentCount(self: *Self) usize
```

### Retry Policy

#### `zigmodu.http.HttpClient.RetryPolicy`

Exponential backoff retry strategy.

```zig
pub fn default() RetryPolicy
pub fn calculateDelay(self: RetryPolicy, attempt: u32) u64
```

---

## Observability

### Distributed Tracing

#### `zigmodu.observability.DistributedTracer`

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

#### `zigmodu.observability.PrometheusMetrics`

Prometheus-compatible metrics collection.

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn deinit(self: *Self) void

// 六个 create* 返回的都是 (FrozenError || std.mem.Allocator.Error)!*T，
// 其中 pub const FrozenError = error{Frozen}（见下方生命周期说明）。
pub fn createCounter(self: *Self, name: []const u8, help: []const u8) (FrozenError || std.mem.Allocator.Error)!*Counter
pub fn createGauge(self: *Self, name: []const u8, help: []const u8) (FrozenError || std.mem.Allocator.Error)!*Gauge
pub fn createHistogram(self: *Self, name: []const u8, help: []const u8, buckets: []const f64) (FrozenError || std.mem.Allocator.Error)!*Histogram
pub fn createSummary(self: *Self, name: []const u8, help: []const u8) (FrozenError || std.mem.Allocator.Error)!*Summary

pub fn freeze(self: *Self) void                             // 显式封注册表；幂等，没有 unfreeze
pub fn isFrozen(self: *const Self) bool
pub fn toPrometheusFormat(self: *Self, allocator: std.mem.Allocator) ![]const u8
```

**`error.Frozen`（注册表生命周期）**：`toPrometheusFormat` 在读取任何容器**之前**
自己先 `freeze()`；显式 `freeze()` 只是把这道封印提前。封印之后所有 `create*`
返回 `error.Frozen` 且**不插入任何东西**——注册是启动期动作，不是 handler 动作。
之所以能这样封，是因为封印之后容器不再被写入，抓取线程读它们才能不加锁。
`freeze()` 幂等、无 `unfreeze`；`isFrozen()` 查状态。
家族入口（`createCounterFamily` / `createHistogramFamily`）同样受此约束，
见下文「Metrics with bounded labels」。

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

#### `zigmodu.observability.AutoInstrumentation`

Automatic instrumentation for modules.

```zig
pub fn init(allocator: std.mem.Allocator, metrics: *PrometheusMetrics, tracer: *DistributedTracer) !Self
pub fn recordModuleInit(self: *Self, module_name: []const u8, duration_seconds: f64, success: bool) void
pub fn recordModuleShutdown(self: *Self, module_name: []const u8) void
pub fn recordEventPublished(self: *Self, event_name: []const u8, module_name: []const u8) !?*Span
pub fn recordApiRequestStart(self: *Self, api_name: []const u8, module_name: []const u8) !*Span
```

### Structured Logging

#### `zigmodu.observability.StructuredLogger`

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

`addRoute` returns `error.TooManyRouteParams` when a path carries more than
**8** `{…}` segments (`RouteParams.MAX`, `{id}` counts as one). The check runs at
registration, before the trie is touched, and `router.mountAll` propagates it —
so a too-wide route fails at startup. It used to register and then 404 every
request (details: `docs/ROUTE_TABLE.md` §4.6).

#### `Server.Config`

| Field | Default | Meaning |
|-------|---------|---------|
| `port` | `8080` | listen port |
| `name` | `"zigmodu-api"` | server name |
| `max_body_size` | `8 MiB` | body limit (413 over) |
| `request_timeout_ms` | `30000` | **handler stage** budget |
| `max_requests_per_conn` | `100` | keep-alive reuse cap |
| `header_limits` | `.{ .max_count = 100, .max_total_bytes = 16 KiB }` | header-bomb guard |
| `connection_stack_size` | `128 KiB` | accept-loop thread stack (`runInBackground`; raised to `min_thread_stack_size`) — not per-connection |
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

### `zigmodu.observability.PrometheusMetrics`（HTTP profile 接线）

与上文是**同一个类型**，这里只列 HTTP profile 侧用到的入口。

```zig
pub fn init(allocator: std.mem.Allocator) Self
// 三个 create* 的冻结语义同上：封印后 error.Frozen，不插入任何东西
pub fn createCounter(self: *Self, name: []const u8, help: []const u8) (FrozenError || std.mem.Allocator.Error)!*Counter
pub fn createGauge(self: *Self, name: []const u8, help: []const u8) (FrozenError || std.mem.Allocator.Error)!*Gauge
pub fn createHistogram(self: *Self, name: []const u8, help: []const u8, buckets: []const f64) (FrozenError || std.mem.Allocator.Error)!*Histogram
pub fn freeze(self: *Self) void
pub fn isFrozen(self: *const Self) bool
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

### `zigmodu.Params` (multi-value query/form)

Hoisted to the root (there is no `zigmodu.http.Params` alias; `PageParams` stays
under `zigmodu.http`).

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
`nestedParam` (dotted path, was `paramPath`) / `requestParam` (form first, then
query). Guard: `Server.Config.max_params` (default 1000 → `error.TooManyParams`).

Path placeholders are `pathParam` (alias `param`) only — they do not fall back to
query/form. `route_template` is the metric label to use; it is normalised to a
leading `/` at registration, so `group.get("health")` and a ComptimeRouter mount
both report the same shape as `group.get("/health")`.

### `zigmodu.http.Multipart`

```zig
pub const Config = struct {
    max_parts: usize = 64,
    max_part_bytes: usize = 8 MiB,
    max_total_bytes: usize = 32 MiB,
    // Limits subdivided from a server body limit — use this so the two cannot
    // disagree: parts may not together exceed the body the server accepted.
    pub fn forBodyLimit(body_limit: usize) Config
};
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

`Server.Config.max_body_size` (default 8 MiB) rejects a body **before** any
`Config` limit here is consulted, so the 32 MiB default total is unreachable
until that is raised — see `docs/BEST_PRACTICES.md`「上传与 multipart」.

### Uploads

```zig
// http.Extract: multipart failures rendered as ProblemDetails
pub fn extractMultipart(ctx: *Context, config: Multipart.Config) !Multipart.Form
//   415 not multipart · 413 too large · 400 missing boundary / malformed / too many parts

// http.UploadGuard — decide what a file *is* from its bytes
pub const Format = enum { jpeg, png, gif, webp, bmp, tiff, pdf, zip, gzip, mp4, webm, ogg, mp3, wav, plain, svg, html, unknown };
pub const Policy = struct {
    extensions: []const []const u8 = &.{},   // allowlist, lowercase, no dot
    formats: []const Format = &.{},
    max_bytes: usize = 0,                    // per file
    require_extension_match: bool = true,
    allow_active_content: bool = false,      // SVG/HTML: refused by default
};
pub fn check(filename: []const u8, data: []const u8, policy: Policy) Error!Accepted
pub fn checkForm(form: *const Multipart.Form, policy: Policy) Error!void
pub fn sniff(data: []const u8) Format
pub fn extensionOf(filename: []const u8) ?[]const u8
pub fn extensionMatchesFormat(ext: []const u8, format: Format) bool

// Extraction: parse + content-check in one call (recommended entry point)
pub const GuardedUpload = struct {
    multipart: Multipart.Config = .{},
    policy: UploadGuard.Policy,
    reject_status: u16 = 415,                // 422 for "type ok, payload not"
};
pub fn extractMultipartGuarded(ctx: *Context, config: GuardedUpload) !Multipart.Form
//   parse failures keep extractMultipart's 415/413/400; a policy refusal renders
//   ProblemDetails at `reject_status` and returns the guard error unchanged.
//   The form is freed on the rejection path — the caller owns it only on success.
```

`check` decides in a fixed order: size → active content (SVG/HTML refused unless
`allow_active_content`) → extension allowlist → format allowlist → extension vs
content agreement. The rule it enforces: **sniff the bytes and require the
sniffed format to agree with the extension** — a renamed script fails on content,
a renamed image cross-family fails on the mismatch.

`extractMultipartGuarded` is `extractMultipart` + `checkForm` in one call, so an
endpoint cannot ship with the policy defined but never applied; it renders the
refusal (415 by default) and still returns the guard error for handlers that
branch on it.

### `zigmodu.http.staticFiles` (static file serving)

```zig
pub fn staticFiles(io, server: *Server, allocator, prefix: []const u8, root_dir: []const u8, config: Config) !void
pub fn staticMiddleware(io, allocator, prefix, root_dir, config) Middleware
```

Implemented as middleware (the router's `/prefix/*` matches only the prefix
itself). Serves `GET`/`HEAD` only; no directory index; normalizes paths before
touching the filesystem; `ETag` + `If-None-Match` → 304; `Range` → 206/416;
bodies above `max_bytes` (16 MiB default) → 413.

Bodies larger than the serving chunk size are sent **chunked** (streamed from
disk) instead of buffered whole — so a `Content-Length` is only present for
`HEAD` and for bodies at or below the chunk threshold. HTTP/1.0 clients that
cannot read chunked framing should use `HEAD` or `Range` for large files.

### Metrics with bounded labels

```zig
// 冻结后同样 error.Frozen（见上文「Prometheus Metrics」）
pub fn createCounterFamily(self, name, help, label, max_series: usize, io: std.Io) (FrozenError || std.mem.Allocator.Error)!*CounterFamily
pub fn createHistogramFamily(self, name, help, label, max_series: usize, buckets: []const f64, io: std.Io) (FrozenError || std.mem.Allocator.Error)!*HistogramFamily
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



pub fn fromString(s: []const u8) ?Method

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

## Error response rendering

### `zigmodu.http.useRfc7807Errors`

框架自产的错误体有三条出口（链内 `ctx.sendError`、路由前裸 socket、handler 自写）。
这两条钩子把前两条统一成 RFC 7807 ProblemDetails（media type `application/problem+json`）：

```zig
pub fn useRfc7807Errors() void                       // 链内 + 路由前，一次到位
pub fn setDefaultReject(renderer: ?AuthRejectFn) void // 仅链内；null = 复原信封
pub fn clearDefaultReject() void                      // 复位（测试用）

pub fn problemReject(ctx: *Context, status: u16, message: []const u8) anyerror!void
pub fn problemTransportBody(status: u16, message: []const u8, buf: []u8) TransportErrorBody

pub fn setTransportErrorRenderer(renderer: ?TransportErrorFn) void  // 仅路由前
pub fn renderTransportError(status: u16, message: []const u8, buf: []u8) TransportErrorBody

// Context
pub fn sendError(self: *Context, status: u16, message: []const u8) !void
pub fn sendErrorResponse(self: *Context, status: u16, code: i32, message: []const u8) !void
pub fn sendErrorEnvelope(self: *Context, status: u16, code: i32, message: []const u8) !void  // 绕过渲染器

// Middleware 配置：ModuleGateConfig 新增 reject（保留 .unknown = .deny 同时改 404 体）
pub const ModuleGateConfig = struct { reject: AuthRejectFn = defaultReject, ... };
```

细节与三条守则见 [`BEST_PRACTICES.md`](BEST_PRACTICES.md)「错误响应形状」。

---

## Security

### JWT Authentication

#### `zigmodu.security.SecurityModule`

JWT token generation and verification.

```zig
pub fn init(allocator: std.mem.Allocator, jwt_secret: []const u8, token_expiry_seconds: i64) Self
pub fn generateToken(self: *Self, payload: JwtPayload) ![]const u8
pub fn verifyToken(self: *Self, token_string: []const u8) !JwtPayload
pub fn hashPassword(self: *Self, password: []const u8) ![]const u8
// 失败在两处不同来源之间可区分：存储记录不可用 vs 我们这侧出错（分配失败）。
pub fn verifyPassword(self: *Self, password: []const u8, hash: []const u8) PasswordError!bool
pub const PasswordError = error{MalformedStoredHash} || std.mem.Allocator.Error;
```

> `verifyPassword` / `PasswordEncoder.matches` 返回**错误联合**（不是裸 `bool`）：以前存储哈希
> 不可解码、或解码时分配失败，都会被答成 `false`，调用方只能回 401 —— 把一个"我们这边出错"记成
> "口令错"。现在 `error.MalformedStoredHash`（记录不可用）与 `error.OutOfMemory` 各自冒泡，
> 调用方按需回 5xx；口令**不匹配**仍然只是 `false`。
> `zigmodu.security.PasswordEncoder.matches` 同形。

### Permission matching

handler 侧使用**与路由 meta 完全相同的表达式**判断身份，避免"路由允许 OR、handler 只认一侧"把一整类用户 403 掉：

```zig
// Context
pub fn rolesCsv(self: *const Context) ?[]const u8           // 逗号分隔门户角色
pub fn permissionsCsv(self: *const Context) ?[]const u8     // 逗号分隔权限码（同形）
pub fn permissionMatches(self: *const Context, expr: []const u8) bool

// http（Middleware）
pub fn permissionMatchesContext(ctx: *const Context, expr: []const u8) bool
pub fn permissionMatchesWith(ctx: *const Context, expr: []const u8, config: PermissionGateConfig) bool
pub fn permissionMatchesRoles(roles_csv: []const u8, permission: []const u8) bool
pub fn permissionMatchesAuthInfo(auth: *const Rbac.AuthInfo, permission: []const u8) bool
```

`expr` 支持 `a|b` 备选语法。`permissionMatches` 命中任一身份来源（AuthInfo / `permissions` / `roles`）；
`permissionMatchesWith` 则**锁定某个 gate 的语义**（`.roles` 只读 roles；`.rbac` 有 AuthInfo 时以它为准）。
两者共用 `zigmodu.security.Rbac.exprMatchesCsv` / `exprMatchesAuthInfo`，与 gate 同一份实现。

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

#### `zigmodu.ModuleTestContext`

Testing context for module testing.

```zig
pub fn init(allocator: std.mem.Allocator, module_name: []const u8) !Self
pub fn deinit(self: *Self) void
pub fn registerMockModule(self: *Self, info: ModuleInfo) !void
pub fn start(self: *Self) !void
pub fn stop(self: *Self) void
```

### Integration Testing

#### `zigmodu.IntegrationTest`

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

#### `zigmodu.Benchmark`

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

**File watching only** (⚠️ 有条件). Zig links statically, so `reloadModule` logs the
request and returns without replacing code; drive your own response (rebuild, restart,
hot-swap via `ModuleSnapshot`) from the `onChange` callback.

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

**Registration only.** `loadPlugin` records the name and logs a warning;
`dynamicLoadingSupported()` returns `false` and no shared library is ever loaded
(see `docs/UPGRADING.md`). For a real extension point use modules + `Application`.

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

*Last updated: 2026-09-15*
*For more examples, see [examples](../examples/)*
