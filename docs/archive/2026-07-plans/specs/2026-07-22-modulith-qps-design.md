# Modulith-Scale QPS Design: Module Autonomy, Async Events, and Resource Isolation

**Goal:** Increase single-cluster QPS toward 10-million level without leaving the Modulith deployment model.

**Status:** Design draft — pending review.

---

## 1. Context & Constraints

`zigmodu` is positioned as a Modulith framework (see `docs/MODULITH.md`, `docs/MODULE_LAYERS.md`).
The latest release `v0.14.5` hardened the SQLx layer (pool lifecycle, streaming cursor, batch protocols), but single-cluster QPS is still bounded by:

1. **Synchronous cross-module calls** — modules call each other through repositories/services directly, creating long, blocking chains under load.
2. **Shared resource pools** — all modules compete for the same connection pool, rate limiter, and circuit breaker.
3. **No back-pressure per module** — a single misbehaving module can exhaust global resources and drag the whole process down.
4. **Best-effort events** — `core.EventBus` is in-memory and fire-and-forget; cross-module consistency relies on synchronous writes.

This design addresses those four constraints while keeping a **single deployable unit**.

### Constraints

- Target Zig `0.17.0-dev`.
- Keep changes inside existing module contracts (`api.Module` lifecycle).
- No new mandatory external dependencies; Redis / NATS / Kafka integrations are optional.
- Every allocation must have matching `defer`/`errdefer`.
- All tests must pass with `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`.

---

## 2. Design Principles

1. **Module boundaries are hard.** Modules communicate only through:
   - public commands (type-safe function calls within the same process),
   - domain events (async, via the internal EventBus + Outbox),
   - read models (local materialized views owned by the consumer module).
2. **Resources are owned, not shared.** Each module gets a quota of connections, workers, and rate-limit budget.
3. **Prefer async over sync.** Cross-module write chains become events; reads use local caches/materialized views.
4. **Reliable events.** Domain events are persisted to an Outbox table and delivered at-least-once to the internal bus and optional external MQ.
5. **Observable by module.** Every module exports independent QPS, latency, error-rate, and resource metrics.

---

## 3. Components

### 3.1 `core.ModuleRuntime` — Per-Module Resource Context

A new optional field in `api.Module`:

```zig
pub const Module = struct {
    name: []const u8,
    description: []const u8,
    dependencies: []const []const u8 = &.{},
    runtime: RuntimeOptions = .{},
};

pub const RuntimeOptions = struct {
    max_concurrent: u32 = 100,          // bulkhead semaphore
    max_qps: u32 = 0,                   // 0 = unlimited
    db_max_open: u32 = 0,               // 0 = share global pool
    db_max_idle: u32 = 0,
    worker_count: u32 = 0,              // dedicated async worker pool
    enable_outbox: bool = false,
};
```

`Application` builds a `ModuleRuntime` per module containing:

- `bulkhead: Bulkhead` — caps in-flight requests/commands for this module.
- `rate_limiter: RateLimiter` — per-module token bucket.
- `circuit_breaker: CircuitBreaker` — per-module failure isolation.
- `worker_pool: ?WorkerPool` — optional dedicated async workers.
- `db_pool_quota: ?PoolQuota` — optional slice of the global connection pool.
- `outbox: ?OutboxPublisher` — reliable event outbox.

Lifecycle: created in `init` order, destroyed in reverse `deinit` order.

### 3.2 `core.EventBus` — Reliable Internal Bus

Extend the existing `TypedEventBus(T)` with:

- **Async subscribers:** `subscribeAsync(handler, worker_pool)` — events are queued and processed by a worker pool instead of inline.
- **Dead-letter queue (DLQ):** already present in `core.eventbus.DLQ`; wire it into the bus.
- **Module-scoped channels:** events can be published to a specific module channel or broadcast.
- **Back-pressure:** when a subscriber queue is full, publisher can drop, block, or shed load based on policy.

### 3.3 `messaging.OutboxPublisher` — At-Least-Once Delivery

Enhance the existing Outbox implementation:

- **Module-scoped outbox tables:** `outbox_{module_name}` or a single table with `module` column.
- **Poller per module:** each module with `enable_outbox = true` gets its own poller thread/coroutine.
- **MQ bridge:** after DB commit, events are delivered to internal `EventBus` *and* optionally to external MQ (NATS / Kafka / Fluvio) via existing connectors.
- **Idempotency:** consumers declare handled event IDs to avoid duplicate processing.

### 3.4 `core.ModuleRegistry` — Quota Validation & Monitoring

At startup:

1. Collect all module runtime options.
2. Validate that the sum of `db_max_open` does not exceed the global `max_open_conns` (or declare that modules without quota share the remainder).
3. Validate that module dependency graph is still acyclic.
4. Expose per-module metrics endpoint.

### 3.5 `core.MaterializedView` — Local Read Models

A lightweight read-model builder:

```zig
pub fn MaterializedView(T) type {
    return struct {
        state: T,
        apply: *const fn (*T, Event) void,
        snapshot_version: u64,
    };
}
```

- Each module owns its own read model built from events it consumes.
- Snapshot can be persisted to a local table or in-memory.
- Replaces synchronous cross-module repository calls.

---

## 4. Data Flow

### 4.1 Write Path (Order → Inventory → Payment)

```
HTTP POST /orders
    ↓
OrderModule API handler
    ↓
OrderModule Service: validate, persist order
    ↓
OrderModule Outbox: write "OrderCreated" event in same DB transaction
    ↓
DB COMMIT
    ↓
OutboxPoller: read uncommitted event
    ↓
Internal EventBus.publish(OrderCreated)
    ↓
InventoryModule async subscriber: reserve stock
PaymentModule async subscriber: create payment intent
    ↓
Each module publishes its own events (StockReserved, PaymentInitiated)
```

**Why it increases QPS:**
- The HTTP request returns as soon as the Order DB transaction commits.
- Inventory/Payment processing happens asynchronously, consuming CPU only when workers are available.
- Bulkheads prevent downstream slowness from backing up the Order module.

### 4.2 Read Path

```
GET /orders/{id}
    ↓
OrderModule API handler
    ↓
OrderModule MaterializedView or cache (no DB hit for hot data)
    ↓
Return response
```

**Fallback:** if view is stale/missing, query the local OrderModule repository.

---

## 5. Error Handling

| Failure | Handling |
|---------|----------|
| Module bulkhead full | Return `ServiceOverloaded` (HTTP 503) immediately. |
| Module rate limit exceeded | Return `RateLimitExceeded` (HTTP 429). |
| Module circuit breaker open | Fast-fail with `CircuitBreakerOpen`. |
| Async event handler fails | Retry with exponential backoff; persist to DLQ after max retries. |
| Outbox poller fails | Stop polling, alert, resume from last committed offset. |
| Materialized view stale | Accept temporary staleness or serve fallback read. |

---

## 6. Public API Additions

All additions are additive; existing modules keep working without `ModuleRuntime`.

```zig
// Module declaration
pub const info = zmodu.api.Module{
    .name = "order",
    .dependencies = &.{"inventory", "payment"},
    .runtime = .{
        .max_concurrent = 200,
        .max_qps = 5000,
        .db_max_open = 10,
        .worker_count = 8,
        .enable_outbox = true,
    },
};

// Publishing domain events
pub fn createOrder(ctx: *http.Context) !void {
    var order = try orderService.create(...);
    try ctx.module().publish(.OrderCreated, order); // outbox + eventbus
    try ctx.json(201, order);
}

// Subscribing to events
pub fn init() !void {
    try zmodu.events().subscribe(.OrderCreated, onOrderCreated);
}
```

---

## 7. Testing Strategy

1. **Module isolation test:** Saturate one module with requests and verify another module still responds within SLA.
2. **Outbox delivery test:** Insert event into Outbox, crash process, restart, assert event still delivered.
3. **Event-driven consistency test:** Order creation → eventual Inventory reservation within timeout.
4. **Bulkhead test:** Exceed `max_concurrent` for a module and assert `ServiceOverloaded`.
5. **Metrics test:** Verify per-module counters increment independently.

---

## 8. Implementation Phases

### Phase 1 — Per-Module Bulkhead + Rate Limiter
- Add `ModuleRuntime` struct.
- Wire bulkhead and rate limiter into `Application` request dispatch.
- Add module-level metrics.

### Phase 2 — Async EventBus + Worker Pools
- Add async subscriber support to `EventBus`.
- Add per-module worker pools.
- Convert one cross-module synchronous call chain to events as a pilot.

### Phase 3 — Outbox Productionization
- Module-scoped outbox tables.
- Poller per module.
- Integration with internal EventBus and optional external MQ.

### Phase 4 — Materialized Views
- Introduce `MaterializedView(T)`.
- Build read models from events.
- Replace hot synchronous cross-module reads.

### Phase 5 — CQRS / Read-Replica Routing
- Automatic read/write split in SQLx.
- Query-side cache warming from events.

---

## 9. Relation to Existing Modules

| Existing Module | How It Is Extended |
|-----------------|-------------------|
| `core.EventBus` | Async subscribers, DLQ, back-pressure. |
| `resilience.*` | Per-module bulkhead/rate limiter/circuit breaker. |
| `messaging.OutboxPublisher` | Module-scoped tables, per-module poller, MQ bridge. |
| `api.Module` | Optional `runtime` field. |
| `metrics.PrometheusMetrics` | Per-module metric labels. |
| `cache.CacheManager` | Module namespaced caches. |
| `tenant.ShardRouter` | Optional per-module sharding policy. |

---

## 10. Success Criteria

- Existing test suite still passes: `490+ passed; 0 failed`.
- New tests demonstrate module isolation under synthetic load.
- A pilot module pair (e.g. order → inventory) runs fully event-driven with Outbox.
- Single-process benchmark shows measurably higher throughput and lower P99 under cross-module load.

---

## 11. Out of Scope (for this design)

- Microservice decomposition (splitting repositories).
- External service mesh / Istio.
- Multi-region active-active replication.
- Changing Zig version or adding non-optional C dependencies.
