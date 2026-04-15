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
8. [Transport](#transport)
9. [Security](#security)
10. [Testing](#testing)

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

#### `zigmodu.startAll`

Start all modules in dependency order.

```zig
pub fn startAll(modules: *ApplicationModules) !void
```

#### `zigmodu.stopAll`

Stop all modules in reverse dependency order.

```zig
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

## Transport

### Transport Protocols

#### `zigmodu.core.TransportProtocol`

Supported transport protocols.

```zig
pub const TransportProtocol = enum {
    http,
    grpc,
    mqtt,
};
```

### gRPC Transport

```zig
pub const GrpcTransport = struct {
    pub fn init(allocator: Allocator, endpoint: []const u8) !Self
    pub fn deinit(self: *Self) void
    pub fn call(self: *Self, method: []const u8, payload: []const u8) ![]const u8
};
```

### MQTT Transport

```zig
pub const MqttTransport = struct {
    pub fn init(allocator: Allocator, broker: []const u8, port: u16) !Self
    pub fn deinit(self: *Self) void
    pub fn publish(self: *Self, topic: []const u8, payload: []const u8) !void
};
```

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

### HTTP Server / Router

#### `zigmodu.api.Router`

HTTP routing and middleware.

```zig
pub fn init(allocator: std.mem.Allocator, prefix: []const u8) Self
pub fn get(self: *Self, path: []const u8, handler: RequestHandler) !void
pub fn post(self: *Self, path: []const u8, handler: RequestHandler) !void
pub fn put(self: *Self, path: []const u8, handler: RequestHandler) !void
pub fn delete(self: *Self, path: []const u8, handler: RequestHandler) !void
pub fn use(self: *Self, middleware: Middleware) !void
pub fn handle(self: *Self, request: Request) !Response
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

```zig
pub const TaskScheduler = struct {
    pub fn init(allocator: std.mem.Allocator) Self
    pub fn addCronTask(self: *Self, name: []const u8, cron: []const u8, task: fn () void) !void
    pub fn addIntervalTask(self: *Self, name: []const u8, interval_ms: u64, task: fn () void) !void
    pub fn start(self: *Self) !void
    pub fn stop(self: *Self) void
};
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
    pub fn save(self: *Self, entity: T) !void
    pub fn delete(self: *Self, id: i64) !void
    pub fn findAll(self: *Self, buf: []T) ![]T
}
```

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

### PasRaft Consensus

```zig
pub const PasRaftAdapter = struct {
    pub fn init(allocator: std.mem.Allocator, config: Config) !Self
    pub fn deinit(self: *Self) void
    pub fn proposeModuleOperation(self: *Self, operation: Operation) ![]const u8
    pub fn getClusterStatus(self: *Self) ![]const u8
};
```

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