# zmodu API reference

The public entry points of zmodu, the contracts they hold, and how to call them. Freeze policy: [`API_FREEZE.md`](./API_FREEZE.md). Deprecated aliases and removal dates: [`UPGRADING.md`](./UPGRADING.md).

## 1. Module contract

A module is `pub const info` plus `init` and `deinit`. `dependencies` lists module names, not import paths; the build graph rejects cycles, missing names and self-dependencies at compile time.

```zig
pub const Module = struct {
    name: []const u8,                         // unique
    description: []const u8 = "",
    dependencies: []const []const u8 = &.{},  // module names
    is_internal: bool = false,
};

pub fn scanModules(allocator: std.mem.Allocator, comptime modules: anytype) !ApplicationModules
pub fn validateModules(modules: *ApplicationModules) !void
```

```zig
const OrderModule = struct {
    pub const info = zmodu.api.Module{
        .name = "order",
        .description = "Order management module",
        .dependencies = &.{ "inventory", "payment" },
    };
    pub fn init() !void {}
    pub fn deinit() void {}
};
```

`Application.start()` starts modules in dependency order; `Application.stop()` stops them in reverse. The lower-level `zmodu.startAll` / `zmodu.stopAll` are deprecated (removal no earlier than 1.0) and require manual lifecycle handling. `zmodu.generateDocs(modules, path, allocator, io)` writes a PlantUML description of the graph.

## 2. Application

```zig
pub fn init(io: std.Io, allocator: std.mem.Allocator, name: []const u8, comptime modules: anytype, config: Config) !Application
```

| `Config` field | Default | Meaning |
|---|---|---|
| `name` | `"app"` | application name |
| `expect_drivers` | `&.{}` | SQL drivers the app uses; `start()` refuses to boot when one was not compiled in with `-Ddb=` |
| `validate_on_start` | `true` | validate module dependencies before starting |
| `auto_generate_docs` | `false` | write docs during `start()` |
| `docs_path` | `null` | output path for generated docs |
| `max_dependencies` | `8` | warn above this many dependencies per module; `0` disables |

`zmodu.builder(allocator, io)` returns an `ApplicationBuilder`. Bind it to a variable: builder methods take `*Self`, and a temporary is `*const`.

```zig
var builder = zmodu.builder(allocator, io);
defer builder.deinit();

var app = try builder.withName("myapp").withValidation(true).withAutoDocs(true)
    .build(.{ UserModule, OrderModule });
defer app.deinit();
try app.start();
```

`withService(T, name, instance)` registers a service that modules retrieve through `ModuleContext.service`.

## 3. Dependency injection

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn register(self: *Self, comptime T: type, name: []const u8, instance: *T) !void
pub fn registerBorrowed(self: *Self, comptime T: type, name: []const u8, instance: *T) !void
pub fn get(self: *Self, comptime T: type, name: []const u8) ?*T
pub fn getComptime(self: *Self, comptime T: type, comptime name: []const u8) ?*T
pub fn freeze(self: *Self) void
pub fn contains(self: *Self, name: []const u8) bool
pub fn remove(self: *Self, name: []const u8) void
pub fn serviceCount(self: *Self) usize
```

- `register` takes ownership; the container destroys the instance on `remove`/`deinit`.
- `registerBorrowed` does not own the instance.
- After `freeze()`, registration returns `error.ContainerFrozen`, `remove` warns and is a no-op, and `get`/`contains` are lock-free reads.

`zmodu.ScopedContainer.init(allocator, scope_name, parent)` resolves against a parent container.

| Falls through to `parent` | Local only |
|---|---|
| `get`, `contains` | `register`, `registerBorrowed`, `remove`, `serviceCount` |

A scope's own registrations win. `remove` never reaches the parent: unregistering a shared service would leave other readers holding a destroyed instance. `serviceCount` counts local registrations. There is no `freeze` or `getComptime`; the application `Container` is the freeze point.

## 4. Configuration

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

`zmodu.ConfigManager` stores dotted keys and parses JSON itself. `zmodu.TomlLoader.init(allocator)` then `loadFile(path, config)` fills an existing store: sections become dotted keys (`[server]` + `port` → `server.port`) and values keep their TOML type, so `getInt` and `getBool` work.

```zig
var config = zmodu.ConfigManager.init(allocator);
defer config.deinit();
var loader = zmodu.TomlLoader.init(allocator);
try loader.loadFile("app.toml", &config);
const port = config.getInt("server.port") orelse 8080;
```

`zmodu.ExternalizedConfig` merges sources by priority: `addSource(name, priority, loader)`, `load()`, `get(key)`, `watchFile(path, loader)`, `refresh()`.

`zmodu.YamlParser` and `zmodu.TomlParser` flatten a file to `StringHashMap([]const u8)` with `parseFile(path)` / `parse(content)`; numbers and booleans stay strings. Hand the map back to `deinitMap(map)` rather than freeing its fields.

## 5. Events

`zmodu.EventBus(T)` keys subscriptions by event type; payloads travel as `*anyopaque` and each callback casts back. One instance can hold many event types. Not thread-safe.

```zig
pub fn EventBus(comptime T: type) type
pub fn init(alloc: std.mem.Allocator) Self
pub fn initCapacity(alloc: std.mem.Allocator, capacity: usize) Self  // capacity is a hint
pub fn subscribe(self: *Self, event_type: T, callback: *const fn (T, *anyopaque) void) !void
pub fn unsubscribe(self: *Self, event_type: T, callback: *const fn (T, *anyopaque) void) void
pub fn publish(self: *Self, event_type: T, payload: *anyopaque) void
pub fn subscriberCount(self: *Self, event_type: T) usize
pub fn totalSubscriberCount(self: *Self) usize
```

```zig
const Topic = enum { order_created };
const OrderEvent = struct { order_id: u64, status: []const u8 };

var bus = zmodu.EventBus(Topic).init(allocator);
defer bus.deinit();
try bus.subscribe(.order_created, onOrderCreated); // fn (Topic, *anyopaque) void
var event = OrderEvent{ .order_id = 123, .status = "completed" };
bus.publish(.order_created, &event);
```

For concurrent use take `zmodu.ThreadSafeEventBus`, or the application bus from `ModuleContext.eventBus(...)`.

`zmodu.TypedEventBus(T)` carries one event type by value (`fn (T) void`), also single-threaded: `init`, `subscribe`, `subscribeAsync(pool, handler)`, `unsubscribe`, `publish`, `subscriberCount`, `publishedCount`, `droppedAsyncCount`.

`zmodu.DistributedEventBus` connects nodes: `init`, `start(port)`, `stop`, `connectToNode`, `publish(topic, payload)`, `subscribe(topic, callback)`, `snapshotNodes(allocator)`, `getConnectedNodes`, `getNodeCount`. Use `snapshotNodes`: it copies the registry under its lock and the caller owns the result until `deinit()`. `getConnectedNodes` holds no lock and its slice can be invalidated by a concurrent connect or disconnect.

There is no transactional event bus. For durable publish use `zmodu.outbox.OutboxConsumer`; for compensating flows use `zmodu.SagaOrchestrator`.

## 6. Resilience

```zig
pub fn init(allocator: std.mem.Allocator, name: []const u8, config: Config) !Self
pub fn call(self: *Self, operation: *const fn () anyerror!void) Result
pub fn reset(self: *Self) void
pub fn forceOpen(self: *Self) void
pub fn getState(self: *Self) State
pub fn getStats(self: *Self) Stats

pub const State = enum { closed, open, half_open };
pub const Config = struct {
    failure_threshold: usize = 5,
    timeout_ms: u64 = 30000,
    half_open_max_calls: usize = 3,
};
```

`zmodu.CircuitBreakerRegistry` keeps one breaker per dependency name: `getOrCreate(name)`, `get(name)`, `resetAll()`.

`zmodu.RateLimiter` is a thread-safe token bucket: `init(allocator, name, max_tokens, refill_rate)`, `tryAcquire()`, `tryAcquireMany(count)`, `release()`, `availableTokens()`, `reset()`, `getStats()`. `acquire()` is deprecated and behaves like `tryAcquire()`.

`RateLimiterRegistry` is LRU-bounded at `max_keys` (default 65536): once full, a new key evicts the least-recently-used limiter. `0` means unbounded and is only safe for a controlled key set. `getOrCreate*` pointers stay valid for the life of the registry. Methods: `getOrCreate`, `getOrCreateForClient(client_id, max_tokens, refill_rate)`, `get`, `remove`, `retain(max_idle_seconds)`, `count`, `generateReport(allocator)`.

`zmodu.SlidingWindowRateLimiter.init(allocator, name, window_size_seconds, max_requests)` counts requests inside a fixed window; `tryAcquire()` and `currentCount()`. Thread-safe.

`zmodu.http.HttpClient.RetryPolicy` provides exponential backoff: `default()`, `calculateDelay(attempt)`.

## 7. Observability

`zmodu.observability.DistributedTracer` is OpenTelemetry-compatible: `init(allocator, tracer_name, service_name)`, `startTrace(name)`, `startSpan(parent, name)`, `endSpan(span)`, `exportJaeger(span, allocator)`, `exportZipkin(span, allocator)`, `injectContext(span, headers)`, `extractContext(headers)`. Spans support `setAttribute(allocator, key, value)`, `addEvent(allocator, name)` and `end()`.

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn createCounter(self: *Self, name: []const u8, help: []const u8) (FrozenError || std.mem.Allocator.Error)!*Counter
pub fn createGauge(self: *Self, name: []const u8, help: []const u8) (FrozenError || std.mem.Allocator.Error)!*Gauge
pub fn createHistogram(self: *Self, name: []const u8, help: []const u8, buckets: []const f64) (FrozenError || std.mem.Allocator.Error)!*Histogram
pub fn createSummary(self: *Self, name: []const u8, help: []const u8) (FrozenError || std.mem.Allocator.Error)!*Summary
pub fn freeze(self: *Self) void
pub fn isFrozen(self: *const Self) bool
pub fn toPrometheusFormat(self: *Self, allocator: std.mem.Allocator) ![]const u8
```

`toPrometheusFormat` freezes the registry before reading it. After a freeze every `create*` returns `error.Frozen` (`FrozenError = error{Frozen}`) and inserts nothing, which is what lets scrape threads read without a lock. `freeze()` is idempotent; there is no unfreeze.

Metric operations: `Counter.inc()`, `Counter.add(value)`; `Gauge.set(value)`, `Gauge.inc()`, `Gauge.dec()`; `Histogram.observe(value)`.

Bounded-label families add a series cap: `createCounterFamily(name, help, label, max_series, io)` and `createHistogramFamily(name, help, label, max_series, buckets, io)`. `family.get(value)` returns a `*Counter` or `*Histogram`; past `max_series` all new values share one `__other__` series. `setScrapeHook(hook, userdata)` samples extra values at scrape time. Label values must be low-cardinality: use `Context.route_template`, never the raw path.

`zmodu.observability.AutoInstrumentation` records module lifecycle and API spans: `init(allocator, metrics, tracer)`, `recordModuleInit`, `recordModuleShutdown`, `recordEventPublished`, `recordApiRequestStart`.

`zmodu.observability.StructuredLogger` writes one JSON object per line: `init(allocator, level, output)`, `withField(key, value)`, `debug` / `info` / `warn` / `err(message, fields)`. In handlers prefer `ctx.logScope("module")`, which carries the request trace id.

## 8. HTTP server

```zig
pub fn init(io: std.Io, allocator: std.mem.Allocator, port: u16) Server
pub fn initWithConfig(io: std.Io, allocator: std.mem.Allocator, config: Config) Server
pub fn fromEnv(io: std.Io, allocator: std.mem.Allocator, env: std.process.Environ) !Server
pub fn start(self: *Server) !void          // blocks; runs the accept loop
pub fn stop(self: *Server) void
pub fn deinit(self: *Server) void
pub fn addMiddleware(self: *Server, mw: Middleware) !void
pub fn addRoute(self: *Server, route: Route) !void
pub fn withGracefulDrain(self: *Server, counter: *std.atomic.Value(u64)) void
```

Each connection runs on its own fiber. `addRoute` rejects a path with more than 8 `{…}` segments (`RouteParams.MAX`) with `error.TooManyRouteParams` at registration; `router.mountAll` propagates it, so the process fails at startup instead of answering 404 to every request.

| Field | Default | Meaning |
|---|---|---|
| `port` | `8080` | listen port |
| `name` | `"zmodu-api"` | server name |
| `max_body_size` | `8 MiB` | request body limit; larger bodies get 413 |
| `max_params` | `1000` | query/form value cap; over it `error.TooManyParams` |
| `request_timeout_ms` | `30000` | handler-stage budget |
| `max_requests_per_conn` | `100` | keep-alive reuse cap |
| `header_limits` | `.{ .max_count = 100, .max_total_bytes = 16 KiB }` | header-bomb guard |
| `connection_stack_size` | `128 KiB` | accept-loop thread stack (`runInBackground`), not per connection |
| `max_connections` | `0` (unlimited) | concurrent accepted connections; over it the socket is closed |
| `over_limit_response` | `.close` | `.close` is cheapest; `.unavailable` sends a raw `503` first |
| `header_timeout_ms` | `10_000` | request line and headers deadline; `0` disables; cleared after headers |
| `body_timeout_ms` | `30_000` | request body deadline, armed at the blank line; over it answers `408`; `0` disables |
| `response_write_timeout_ms` | `30_000` | per-send budget for buffered, chunked, SSE and HTTP/2 writes; a peer that stops reading gets a truncated response and a closed connection; `0` makes writes unbounded |
| `ws_write_timeout_ms` | `0` = inherit `response_write_timeout_ms` | WebSocket write timeout; on timeout the frame fails with `error.WriteTimeout` and the socket shuts down |
| `enable_http2` | `false` | h2c support |

`fromEnv` reads `HTTP_PORT`, `HTTP_MAX_BODY`, `HTTP_MAX_CONNECTIONS`, `HTTP_HEADER_TIMEOUT_MS`, `HTTP_BODY_TIMEOUT_MS`, `HTTP_RESPONSE_WRITE_TIMEOUT_MS`, `WS_WRITE_TIMEOUT_MS`.

### Shutdown

- `stop()` is bounded against peers: every upgraded WebSocket connection still held by the fiber path has its socket shut down, so a client that sends no frames and no FIN cannot hold the drain.
- In-flight HTTP/1.1 and HTTP/2 requests are awaited, not cancelled.
- Callbacks (`on_connect` / `on_message` / `on_close`) run on the connection fiber and are not interruptible; a blocking callback holds `stop()` for as long as it blocks.
- Connections adopted by `setWsUring` belong to the ring: `WsUring.stop()` / `deinit()` end them and close the descriptor once. A refused handoff leaves the descriptor with the fiber, and a rejected connection still gets a close frame and its `on_close` call.

### ws_uring boundary

`WsUring.init` starts with `if (builtin.os.tag != .linux) @compileError(...)` (`src/http/ws_uring.zig:91`), so non-Linux targets fail at compile time rather than falling back at runtime. The `linux` / `IoUring` aliases are stubs elsewhere, which keeps the rest of the file (frame parser, admission and drain accounting) analysable on every platform.

Nine tests run on all platforms: four parser tests, control-frame size rejection, `user_data` encoding, two admission/drain contract tests (`adopt`, `teardown`), and one forced-analysis test. Linux adds the assertion that teardown closes the fd. No test drives a real ring: `runLoop`, `submitRead` and `copy_cqes` are not exercised in-tree, and CI has no io_uring-specific step.

Parser correctness comes from the shared validator: `parseFrame` calls `WsFramer.validateFrameHeader`, `WsFramer.Assembler` and `closeCodeFor`, the same rules the fiber path uses. Re-check this section when a test or example drives `WsUring.init`/`setWsUring`, when std's `Io` gains an equivalent primitive, or when CI adds a platform leg.

### productionProfile

One call wires backpressure, security and observability middleware, `/metrics`, and liveness/readiness probes.

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

pub fn productionProfile(server: *Server, cfg: ProductionConfig, state: *ProductionProfileState) !void
```

`addRoute` snapshots the global middleware chain at registration, so `productionProfile` must run before any `server.addRoute` or `router.mountAll`. `state` must outlive the server.

| Default golden signal | Type |
|---|---|
| `http_requests_total` | counter |
| `http_responses_2xx_total`, `_3xx_`, `_4xx_`, `_5xx_` | counters |
| `http_request_duration_milliseconds` | histogram (1/5/10/25/50/100/250/500/1000/2500/5000 ms) |

Thresholds, PromQL and dashboards: [`OBSERVABILITY.md`](./OBSERVABILITY.md).

`applyHttpDefaults(server, ProfileConfig, *HttpProfileState)` installs only CORS, request id, panic recovery, access log and in-memory metrics. `ResilienceProfileState.init(allocator, deps)` / `applyResilienceDefaults` create a `CircuitBreaker` and `RateLimiter` per dependency; nothing is enforced until a handler calls `breaker(name)` or `limiter(name)`. `PrometheusMetrics.registerMetricsRoute(server)` serves `GET /metrics`; `registerMetricsRoutePath(server, path)` changes the path.

## 9. Routing, context and middleware

```zig
pub const Method = enum { GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS };
pub const HandlerFn = *const fn (*Context) anyerror!void;
pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: HandlerFn,
    middleware: []const Middleware = &.{},
    user_data: ?*anyopaque = null,
};
```

Request access: `queryParam(key)`, `pathParam(key)` (alias `param`), `header(key)`, `formValue(key)`, and the `body` field. Path placeholders never fall back to query or form; use `requestParam` (form first, then query) or `nestedParam` for dotted paths.

Response helpers: `json(status, data)`, `jsonStruct(status, value)`, `text(status, data)`, `sendError(status, message)`, `sendErrorResponse(status, code, message)`, `setHeader(key, value)`.

```zig
pub fn bindJson(self: *const Context, comptime T: type) !T
pub fn parseReq(self: *Context, comptime T: type, sources: anytype) !T

const MyReq = struct { id: u32, page: u32 };
const req = try ctx.parseReq(MyReq, .{ .id = .path, .page = .query });
// GET /users/42?page=3 -> req.id = 42, req.page = 3
```

```zig
pub const MiddlewareFn = *const fn (*Context, HandlerFn, ?*anyopaque) anyerror!void;
pub const Middleware = struct { func: MiddlewareFn, user_data: ?*anyopaque = null };
```

Execution order is global middleware, then route middleware, then handler. Call `try next(ctx, next, user_data)` to continue.

```zig
fn authMiddleware(ctx: *Context, next: HandlerFn, user_data: ?*anyopaque) anyerror!void {
    _ = ctx.header("Authorization") orelse return ctx.sendError(401, "Unauthorized");
    try next(ctx, next, user_data);
}
try server.addMiddleware(.{ .func = authMiddleware });
```

Runtime routes live on a scope (`router.scope("/api/v1").get(...)`) and are not in the permission catalog.

## 10. Params

`ctx.query` and `ctx.form` are `zmodu.Params`, which keeps repeated names instead of collapsing them.

```zig
pub fn put(self, name, value) !void            // appends; repeated names accumulate
pub fn putOwned(self, name, value) !void       // takes ownership
pub fn get(self, name) ?[]const u8             // last occurrence
pub fn getFirst(self, name) ?[]const u8
pub fn getAll(self, name) []const []const u8
pub fn getArray(self, allocator, name) ![][]const u8   // name[0..n] sorted, then name[]
pub fn getPath(self, path) ?[]const u8         // "filter.tags" -> filter[tags]
pub fn totalValues(self) usize                 // occurrences counted by the guard
```

Context helpers: `queryValues`, `formValues`, `queryArray`, `formArray`, `nestedParam`, `requestParam`. `Server.Config.max_params` (default 1000) bounds the total. `route_template` is the metric label and is normalised to a leading `/` at registration, so `group.get("health")` and a `ComptimeRouter` mount report the same shape.

## 11. Multipart and uploads

```zig
pub const Config = struct {
    max_parts: usize = 64,
    max_part_bytes: usize = 8 MiB,
    max_total_bytes: usize = 32 MiB,
    pub fn forBodyLimit(body_limit: usize) Config
};
pub fn parse(allocator, body, content_type, config) Error!Form
pub const Form = struct {
    pub fn value(self, name) ?[]const u8      // text fields
    pub fn file(self, name) ?*const Part      // filename, data, content_type
    pub fn textFields(self, allocator) !std.StringHashMap([]const u8)
    pub fn deinit(self) void
};
```

Derive limits from the server body limit with `Multipart.Config.forBodyLimit(n)`. `Server.Config.max_body_size` (8 MiB) rejects a body before any multipart limit is consulted, so a larger total is unreachable until the server limit is raised.

`ctx.multipart(config)` parses, `ctx.bindMultipart(T, config)` binds fields, and `http.extractMultipart(ctx, config)` renders failures as ProblemDetails: 415 not multipart, 413 too large, 400 missing boundary / malformed / too many parts.

`http.UploadGuard` decides what a file is from its bytes:

```zig
pub const Policy = struct {
    extensions: []const []const u8 = &.{},   // allowlist, lowercase, no dot
    formats: []const Format = &.{},
    max_bytes: usize = 0,                    // per file
    require_extension_match: bool = true,
    allow_active_content: bool = false,      // SVG/HTML refused by default
};
pub fn check(filename: []const u8, data: []const u8, policy: Policy) Error!Accepted
pub fn checkForm(form: *const Multipart.Form, policy: Policy) Error!void
pub fn sniff(data: []const u8) Format
pub fn extensionOf(filename: []const u8) ?[]const u8
pub fn extensionMatchesFormat(ext: []const u8, format: Format) bool
```

`check` decides in this order: size, active content, extension allowlist, format allowlist, extension vs sniffed content. A renamed script fails on content; a renamed image of another family fails the mismatch.

```zig
pub const GuardedUpload = struct {
    multipart: Multipart.Config = .{},
    policy: UploadGuard.Policy,
    reject_status: u16 = 415,  // 422 when the type is allowed but the payload is not
};
pub fn extractMultipartGuarded(ctx: *Context, config: GuardedUpload) !Multipart.Form
```

Parse failures keep the 415/413/400 responses. A policy refusal renders ProblemDetails at `reject_status` and returns the guard error unchanged; the form is freed on rejection and owned by the caller only on success.

## 12. Static files

`http.staticFiles(io, server, allocator, prefix, root_dir, config)` and `http.staticMiddleware(...)` install a file handler as middleware, because the router's `/prefix/*` matches only the prefix.

`GET` and `HEAD` only, no directory index; paths are normalised before touching the filesystem. `ETag` / `If-None-Match` give 304, `Range` gives 206/416, and bodies over `max_bytes` (16 MiB default) get 413. Bodies above the chunk size stream from disk: `Content-Length` appears only for `HEAD` and small bodies, so HTTP/1.0 clients without chunked support should use `HEAD` or `Range`.

## 13. Error responses

Two hooks turn framework-generated errors into RFC 7807 ProblemDetails (`application/problem+json`): the in-chain renderer for `ctx.sendError`, and the transport renderer for errors written to a raw socket before routing.

```zig
pub fn useRfc7807Errors() void                        // chain + transport in one call
pub fn setDefaultReject(renderer: ?AuthRejectFn) void // chain only; null restores the envelope
pub fn problemReject(ctx: *Context, status: u16, message: []const u8) anyerror!void
pub fn setTransportErrorRenderer(renderer: ?TransportErrorFn) void  // transport only
pub fn problemTransportBody(status: u16, message: []const u8, buf: []u8) TransportErrorBody
pub fn sendErrorEnvelope(self: *Context, status: u16, code: i32, message: []const u8) !void  // bypasses renderers
```

`ModuleGateConfig` accepts `reject`, so a gate can keep `.unknown = .deny` and still change the 404 body. Call `useRfc7807Errors()` at startup, before the middleware chain and routes are built.

## 14. Security

`zmodu.security.SecurityModule` signs and verifies JWTs: `init(allocator, jwt_secret, token_expiry_seconds)`, `generateToken(payload)`, `verifyToken(token)`, `hashPassword(password)`, `verifyPassword(password, hash)`.

`verifyPassword` returns `false` only for a wrong password. An undecodable stored hash surfaces as `error.MalformedStoredHash` and an allocation failure as `error.OutOfMemory`, so callers can answer 5xx instead of 401. `zmodu.security.PasswordEncoder.matches` has the same shape.

Handlers should evaluate the same expression the route meta uses: `ctx.rolesCsv()`, `ctx.permissionsCsv()`, `ctx.permissionMatches(expr)`. `http.permissionMatchesWith(ctx, expr, config)` pins one gate's semantics (`.roles` reads roles, `.rbac` prefers AuthInfo when present); `permissionMatchesContext` and `permissionMatchesAuthInfo` are the other entry points. `expr` supports `a|b` alternatives.

`security.JwksKeyRing` with `SecurityModule.setKeyring(&ring)` makes new tokens carry a `kid`. Verification uses the named key and rejects unknown kids with `error.UnknownKeyId`. Rotate by adding a new primary key and keeping the old one until its tokens expire.

`security.SecurityScanner` runs static rules: `init(allocator, config)`, `registerRule(rule)`, `scanSourceCode(path, source)`, `scanModule(path)`, `generateReport(result)`, `isSecure(result)`.

## 15. Transport

`http.Server` ships HTTP/1.1 and h2c (`enable_http2`); gRPC runs over HTTP/2 through `extensions/GrpcTransport.zig` and `GrpcServiceRegistry`. There is no `TransportProtocol` enum and no built-in MQTT transport.

Both HTTP/2 limits are `ServeOptions` fields that `Server.http2ServeOptions` fills from `Config`.

| Limit | Default | Effect |
|---|---|---|
| `max_pending_bytes` | 4 MiB | Outbound bytes queued before the peer's window drains. A larger body is staged frame by frame as earlier frames leave (`OutboundScheduler.refill`), so a 6 MiB body is served over h2 as it is over HTTP/1.1. Only `0` refuses a stream, because no slice can be staged. |
| `max_pending_streams` | 64 | Concurrent outbound streams; over it the stream is refused with `REFUSED_STREAM`. |

A stream's send window starts at the peer's `SETTINGS_INITIAL_WINDOW_SIZE` at stream creation (RFC 9113 §6.5.2), then follows per-stream `WINDOW_UPDATE`. The h2 stall test in `api/Server.zig` covers this.

```zig
// In-process (modulith)
var registry = zmodu.GrpcServiceRegistry.init(allocator);
defer registry.deinit();
try registry.registerService("echo.Echo");
try registry.registerMethod("echo.Echo", "Say", .unary, handler);

var client = zmodu.GrpcClient.init(allocator);
defer client.deinit();
client.bindLocal(&registry);
var resp = try client.call("echo.Echo", "Say", proto_bytes);

// HTTP/1.1 application/grpc
var net = zmodu.GrpcClient.initWithIo(allocator, io);
defer net.deinit();
try net.registerEndpoint("echo.Echo", "127.0.0.1", 50051);
var remote = try net.call("echo.Echo", "Say", proto_bytes);

// Framing helpers: zmodu.GrpcFrame.encode(allocator, bytes) / decode(framed)
```

Server side: `registry.handleHttpUnary(path, body)` sets `grpc-status` / `grpc-message` and returns the framed body.

```zig
var sm = zmodu.security.SecretsManager.initWithIo(allocator, io);
defer sm.deinit();
try sm.configureVaultEx(.{ .address = "http://127.0.0.1:8200", .token = "dev-root-token", .mount_path = "secret" });
try sm.loadFromVault("database/creds"); // GET /v1/secret/data/database/creds
const host = sm.get("DB_HOST");         // env > file > vault > default
```

- `applyVaultKvJson(body)` injects a KV JSON payload without HTTP.
- Vault addresses are plain HTTP; `https://` returns `error.VaultTlsNotSupported`. Terminate TLS in a proxy.
- Live smoke: `VAULT_ADDR` + `VAULT_TOKEN`, optionally `VAULT_MOUNT` / `VAULT_SECRET_PATH`.

`zmodu.http.HttpClient` pools connections: `init(allocator, max_connections, timeout_ms)`, `request(req)`, `get(url)`, `post(url, body)`, `put(url, body)`, `delete(url)`. `https://` uses `std.http.Client` and the system trust store.

## 16. Hardening primitives

`zmodu.FrozenMap(K, V)` and `zmodu.FrozenStringMap(V)` are read-only after `freeze()`: fill during startup, then reads are lock-free and writes fail with `error.Frozen` instead of racing a resize. Methods: `init`, `deinit`, `freeze`, `isFrozen`, `put`, `remove`, `get`, `contains`, `count`, `iterator`.

`zmodu.panicHook` records `METHOD /path` in a thread-local before dispatch; on panic it prints that to stderr without allocating, then delegates to `std.debug.defaultPanic`. Wire it in the application root file (the one with `main`) with `pub const panic = zmodu.panicHook;`. The process still aborts; recovery comes from a supervisor (`Restart=always`, Kubernetes `restartPolicy: Always`).

`zmodu.Preflight.run(allocator, checks)` returns a `Report` and never panics; one failure does not hide the others. Ready-made probes: `envCheck`, `secretCheck` (rejects placeholders and short values), `dbCheck` (`SELECT 1`), `migrationCheck` (pending migrations fail), `clockCheck`. Severity is `.warn` or `.fatal`.

`zmodu.DistributedLock` gives cross-instance exclusion for cron jobs and migrations: `tryAcquire(name, ttl_ms)`, `release(name)`, `SqlLock(Client)` with a `sqlite` / `postgres` / `mysql` dialect. Claiming is one atomic statement (`ON CONFLICT DO NOTHING` / `INSERT IGNORE`), so contention is `rows_affected == 0`, not an error; a crashed holder is reaped after `ttl_ms`.

Consumers: `cron.Scheduler.setLock(lock, ttl_ms)` (key `cron:<job>`) and `data.MigrationRunner.setLock(lock, ttl_ms)` (key `zmodu:migration`, returns `error.MigrationLocked` when held elsewhere). SQLite in-memory and PostgreSQL 17 are tested; the MySQL variant has no live-server test.

`zmodu.NetworkProbe.available()` reports whether loopback TCP works. Socket-dependent tests return `error.SkipZigTest` when it is false; `zig build test -Dnet-tests=false` forces it false.

`zmodu.im.WsFramer` exposes outbound control: `setSendTimeout(timeout_ms)` (`0` = unbounded) and `isWritable()` (O(1) send-buffer probe). Drop frames when `isWritable()` is false; otherwise a slow reader blocks the write thread and the connection shard lock.

`zmodu.outbox.OutboxConsumer` reports delivery state: `setMetrics(metrics)`, `pendingCount()`, `refreshPending()`, `startPolling(io, interval_ms)`, `stopPolling()`, `pollOnce()`.

## 17. Data and repository

```zig
pub fn Repository(comptime T: type) type {
    pub fn findById(self: *Self, id: i64) !?T
    pub fn findByIds(self: *Self, allocator: Allocator, ids: []const i64) !QueryResult(T)  // one round trip
    pub fn insert(self: *Self, entity: T) !T
    pub fn insertMany(self: *Self, allocator: Allocator, entities: []const T) !void         // one round trip
    pub fn upsertMany(self: *Self, allocator: Allocator, entities: []const T, conflict_columns: []const []const u8) !void
    pub fn update(self: *Self, entity: T) !void
    pub fn delete(self: *Self, id: i64) !void
    pub fn findAll(self: *Self, buf: []T) ![]T
}
```

`data.bulk` (`src/sqlx/Bulk.zig`) generates multi-row statements for hand-written SQL: `bulk.insertMany(alloc, &client, table, columns, rows, dialect, .{ .conflict_columns = ... })`. `sqlx.Client`, `sqlx.Transaction` and `SqlxBackend` are all valid exec targets. A conflict suffix renders as `ON CONFLICT (...) DO UPDATE` on SQLite/PostgreSQL and `ON DUPLICATE KEY UPDATE` on MySQL.

### Embedded tables — startup DDL, per dialect

The framework ships a few tables of its own. Each entry point builds its DDL from the connection's dialect (SQLite / PostgreSQL / MySQL), so the same call works on all three; run them once at startup:

| Table | Call | Notes |
|-------|------|-------|
| `event_outbox` | `OutboxPublisher.ensureTable(&client)` | `migrationSql()` alone answers MySQL DDL; prefer `ensureTable` / `migrationSqlFor(driver)` |
| `ai_run_audit` | `RunAuditStore.init(alloc, &backend).migrate()` | adds missing columns; `created_at` is Unix wall-clock seconds |
| `approval_queue` | `PersistentApprovalQueue.init(alloc, &backend).migrate()` | durable human-approval queue |
| `web4_invoice` | `X402Store.init(alloc, &backend).migrate()` | x402 invoice ledger |
| `role_permission` | `CatalogPermDb.ensureSchema(&client)` + `grant(&client, role, perm)` | Path A RBAC catalog; `grant` is idempotent |

`RunAuditStore.aggregate()` and `kpi.query` read `SUM`/`COUNT` columns through a driver-neutral reader: PostgreSQL returns `NUMERIC` as decimal text and MySQL returns `DECIMAL` as a float, and both are accepted.

## 18. Cluster

`zmodu.ClusterMembership.init(allocator, node_id, address, bus)` plus `start(config)`, `stop()`, `connectToSeed(node_id, address)`, `getNodeCount()`, `getHealthyNodeCount()`, `getLeader()`. For request-path reads use `zmodu.ClusterView` (`acquire` / `release`, `pick(key)`), not the membership table maintained by the gossip loop. Leader election lives in `src/core/cluster/RaftElection.zig` and is experimental; see [`PRODUCTION_ROADMAP.md`](../archive/status/PRODUCTION_ROADMAP.md).

## 19. Testing

`zmodu.ModuleTestContext.init(allocator, module_name)` boots a subset of modules with mocks: `registerMockModule(info)`, `start()`, `stop()`.

`zmodu.IntegrationTest.init(allocator, config)` wires a test app: `http()`, `setUp()`, `tearDown()`, `waitFor(condition, timeout_ms)`. Use `http.Testkit.dispatch` for in-process requests without a socket.

`zmodu.Benchmark.init(allocator, name, config)` runs benchmarks: `run(bench_name, BenchFn, bench_ctx)`, `generateReport()`.

## 20. Extensions

`zmodu.WebSocketServer` (`src/extensions/WebSocket.zig`) is an RFC 6455 server; `zmodu.WebSocketMonitor` adds a 5 s metrics loop. `init(allocator, io, port)`, `start()`, `stop()`, `onConnect(callback)`, `onMessage(callback)`, `broadcast(message)`, `clientCount()`.

Callbacks run on the connection fiber and must return. `stop()` can only end a wait on a socket, never a wait inside a callback, so a blocking callback holds shutdown for as long as it blocks. After 5 s of draining it logs `connection fiber(s) still running after …ms` at `err` level and keeps waiting.

`start()` dispatches through `Group.concurrent`; when the concurrency budget is exhausted it fails with `error.ConcurrencyUnavailable` and rolls back (`abortStart`) instead of borrowing the calling thread. Under `std.testing.io` the budget is unlimited, so the branch is covered by tests that install a bounded `Io.Threaded` (`src/extensions/WebSocket.zig:1951`). See [`DISTRIBUTED.md`](./DISTRIBUTED.md).

`zmodu.CacheManager.init(allocator, max_size, ttl_seconds, policy)` provides `set`, `get`, `remove`, `clear`, `getStats`.

`zmodu.cron.Scheduler` (`src/scheduler/Cron.zig`) parses `* * * * *` expressions and runs a background thread: `init(allocator, io)`, `addJob(name, schedule, task, context)`, `setLock(lock, ttl_ms)`, `start()`, `stop()`, `tick(now)` for deterministic tests. Multi-replica deployments must set a `DistributedLock`.

`zmodu.HotReloader` watches files only. Zig links statically, so `reloadModule` records the request and returns; rebuild or restart from the `onChange` callback. Methods: `init`, `watchPath`, `startWatching`, `stopWatching`, `reloadModule`.

`zmodu.PluginManager` records plugin names and logs a warning: `init(allocator, plugin_dir)`, `loadPlugin(name, path)`, `unloadPlugin(name)`, `enablePlugin(name)`, `loadAllPlugins()`, `getLoadedPlugins()`. `dynamicLoadingSupported()` returns `false` and no shared library is loaded. Use modules and `Application` for real extension points.

See [examples](../../examples/) for complete applications.
