# Modulith Architecture & Concurrency Guide

Applies to: zmodu v0.35+ · Zig 0.17

This guide explains how to structure a zmodu application as a **modulith** (a single deployable binary with strict internal module boundaries) and scale it for high-concurrency workloads.

> This document covers the **application plane** (modules, fibers, connection pools, caching, and messaging). For stateful workers, bounded mailboxes, lock-free queues, and deterministic replay, see the [Runtime Reference](../reference/RUNTIME.md).

## 1. Core Principles

1. **Define module boundaries on day one**: Declare explicit dependencies in `Module.info.dependencies`. The compiler rejects circular or missing dependencies during `ApplicationBuilder.build`.
2. **Call services in-process for strong consistency**: Use `persistence.Tx` helpers across modules when operations must share a single database transaction.
3. **Publish events for cross-domain side effects**: Use `app.eventBus(T)` for in-process notifications and the transactional outbox (`zmodu.outbox.*`) for reliable asynchronous delivery.
4. **Scale horizontally before splitting services**: Run stateless application instances behind a load balancer with shared database pools, Redis, and Kafka/RobustMQ. Extract a module into a separate process only when independent scaling or deployment is required.

```text
+---------------------------------------------------------+
|                 Application (Single Process)            |
|  +--------+   +---------+   +--------+   +---------+    |
|  |  user  |   | product |   | order  |   | payment |    |
|  +---+----+   +----+----+   +---+----+   +----+----+    |
|      +-------------+--- EventBus -------------+         |
|  DB Pool · Redis · RobustMQ · JWT / RateLimit / Breaker |
+---------------------------------------------------------+
```

## 2. Module Boundaries and Layout

### 2.1 Standard Five-File Module Structure

Each domain module under `src/modules/<domain>/` uses a flat five-file layout (with an optional `root.zig` barrel):

```text
src/modules/<domain>/
├── model.zig         # Data structs, table names, and pure domain helpers
├── persistence.zig   # Parameterized SQL queries (`?` placeholders) and `pub const Tx`
├── service.zig       # Business validation, transactions, and event publishing
├── api.zig           # Declarative `pub const routes` and HTTP handlers
├── module.zig        # `pub const info`, `init` / `initWith`, and `deinit`
└── root.zig          # Barrel exports
```

| Layer | Responsibility | Disallowed |
|-------|----------------|------------|
| `api` | Parse inputs, read auth attributes, serialize JSON responses | Business branching, transaction orchestration, raw SQL |
| `service` | Validate inputs, open transactions, call `Tx` helpers, publish events | Direct access to `http.Context` |
| `persistence` | Parameterized SQL queries, `pub const Tx` unit-of-work helpers | Business branching, reading wall/monotonic clocks |
| `module` | Module metadata, dependency list, lifecycle hooks | Business logic |
| `model` | Row structs, `sql_table_name`, enum conversions | SQL queries, I/O |

### 2.2 Module Contract

```zig
pub const info = zmodu.api.Module{
    .name = "order",
    .description = "Order management",
    .dependencies = &.{ "user", "product" }, // Module names, not file paths
};

pub fn init() !void {}
pub fn deinit() void {}
```

### 2.3 Cross-Module Communication Rules

| Scenario | Mechanism | Reference |
|----------|-----------|-----------|
| Atomic multi-table write | Orchestrating `service` + sibling `persistence.Tx` | [MODULE_LAYERS.md](./MODULE_LAYERS.md) |
| Cross-domain side effect | `app.eventBus(T)` or transactional outbox | [EVENTS_DI.md](./EVENTS_DI.md) |
| Cross-instance messaging | Kafka / RobustMQ (`zmodu.KafkaProducer`) | [DISTRIBUTED.md](../reference/DISTRIBUTED.md) |

Do not import another module's internal files directly; `zmodu doctor` flags cross-module file imports.

## 3. High-Concurrency Practices

The HTTP server uses an asynchronous M:N fiber model (kqueue on macOS/BSD, epoll/io_uring on Linux).

### 3.1 Day-One Configuration

1. **Database connection pooling**: Configure `max_open` and `max_idle` on `data.Client` / `ConnPool`. Never open a new database connection per request.
2. **Per-request arena allocation**: Allocate request-scoped data from `ctx.allocator`. Do not store request pointers in long-lived globals.
3. **Non-blocking handlers**: Avoid synchronous blocking calls (`posix.poll`, `posix.read`, or long sleeps) inside HTTP handlers; offload heavy work to the outbox or a `.blocking` runtime worker.
4. **Idempotent writes**: Protect payment, order creation, and inventory mutations with business idempotency keys or `idempotencyMiddleware`.
5. **Connection backpressure**: Configure `http.productionProfile` with `max_connections`, `header_timeout_ms`, and `body_timeout_ms`.

### 3.2 Scaling Stages

| Stage | Architecture | Key Additions |
|-------|--------------|---------------|
| 0–1k DAU | Single-node modulith + SQLite/PostgreSQL | Strict module boundaries, `EventBus` |
| 1k–10k DAU | Vertical scaling | `ConnPool`, Redis cache, rate limiting, circuit breakers |
| 10k–100k+ DAU | Stateless horizontal replicas + LB | Shared Redis rate limiter, transactional outbox + Kafka/RobustMQ, read replicas |
| Service extraction | Split specific module into standalone binary | Only when resource profile or release cadence diverges |

## 4. Application Bootstrap Pattern

Keep `src/main.zig` focused on wiring infrastructure, registering services, and mounting routes:

```zig
const std = @import("std");
const zmodu = @import("zmodu");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var b = zmodu.builder(allocator, io);
    defer b.deinit();
    var app = try b.withName("shop")
        .build(.{ UserModule, ProductModule, OrderModule, PaymentModule });
    defer app.deinit();

    try app.start();
    defer app.stop();
}
```

## 5. Per-Application Module State

Do not store mutable module state in file-scope `pub var` variables, as they persist across multiple `Application` instances in tests or multi-phase runs. Use `initWith` and `ctx.state(T)` to allocate state scoped to the `Application` instance:

```zig
const BookState = struct {
    open_orders: usize = 0,
    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

pub fn initWith(ctx: *zmodu.core.ModuleContext) !void {
    const st = try ctx.state(BookState);
    st.open_orders = 0;
}
```

- State is keyed by `(module_name, T)`.
- `app.stop()` leaves the state readable for module `deinit` hooks; `app.deinit()` calls `T.deinit` (if declared) in reverse creation order and frees the memory.

## 6. Zig 0.17 Concurrency & Safety Rules

| Area | Rule |
|------|------|
| Mutexes | Use `std.Io.Mutex` with `.lock(io)` / `.unlock(io)` |
| Dynamic arrays | Use `std.ArrayList(T).empty` and pass `allocator` to each method |
| Time | Use `Time.monotonicNowMilliseconds()` for durations/deadlines and `Time.wallClockSeconds(io)` for stored timestamps |
| HTTP headers | Header keys in `Context.headers` are lowercase (e.g., `"authorization"`) |
| SQL | Always use `?` parameter placeholders; never interpolate user input |
| HTTP responses | Use `ctx.json` / `ctx.jsonStruct` / `http.respondErr`; do not use deprecated `sendSuccess` / `sendFail` |

## Related Documentation

- [Domain Layers](./MODULE_LAYERS.md)
- [Events & Dependency Injection](./EVENTS_DI.md)
- [Declarative Routing & Auth](../reference/ROUTE_TABLE.md)
- [Multi-Tenant Store Blueprint](./MODULITH_TENANT_SHOP.md)
