# Architecture Guide

This document describes zmodu's modular architecture (modulith), subsystem map, module lifecycle, dependency graph validation, and multi-tenancy model.

For day-one concurrency and module layering conventions, see [Modulith Architecture](../guide/MODULITH.md) and [Domain Layers](../guide/MODULE_LAYERS.md).

## 1. Subsystem Map (`src/` → Documentation)

| `src/` Directory | Primary Types / Exports | Documentation |
|------------------|-------------------------|---------------|
| `runtime/` `scheduler/` `pool/` | `Runtime`, `Worker`, `Mailbox`, `HotBus`, `TimerWheel`, `PrecisionTimer`, `Supervision` | [RUNTIME.md](./RUNTIME.md) |
| `api/` `http/` | `Server`, `Context`, `Router`, `RouteSpec`, `Middleware`, `Extract`, `Sse`, `Testkit` | [ROUTE_TABLE.md](./ROUTE_TABLE.md) · [API.md](./API.md) |
| `core/` | `Application`, `ModuleGraph`, `EventBus`, `Time`, `Preflight`, `SagaOrchestrator`, `WAL` | [EVENTS_DI.md](../guide/EVENTS_DI.md) · [WORKFLOW.md](../guide/WORKFLOW.md) |
| `core/cluster/` `im/` | `ClusterBootstrap`, `RaftElection`, `RaftTransport`, `ClusterView`, `WsFramer` | [DISTRIBUTED.md](./DISTRIBUTED.md) |
| `data/` `sqlx/` `persistence/` | `Client`, `Repository`, `SqlxBackend`, `CrudService`, `ConnPool` | [SQLX_DRIVERS.md](../guide/SQLX_DRIVERS.md) · [MODULE_LAYERS.md](../guide/MODULE_LAYERS.md) |
| `migration/` | `MigrationRunner`, `MigrationEntry`, `AppliedMigration`, `MigrationStatus` | [API.md](./API.md) |
| `tenant/` `datapermission/` | `TenantContext`, `TenantInterceptor`, `ShardRouter`, `DataPermission` | Section 6 (Multi-Tenancy) below |
| `observability/` `metrics/` `tracing/` `log/` | `PrometheusMetrics`, `DistributedTracer`, `OtlpExporter`, `StructuredLogger`, `LogScope` | [OBSERVABILITY.md](./OBSERVABILITY.md) · [LOGGING.md](../guide/LOGGING.md) |
| `resilience/` | `CircuitBreaker`, `RateLimiter`, `SlidingWindowRateLimiter`, `Bulkhead`, `AdaptiveShedder` | [BEST_PRACTICES.md](../guide/BEST_PRACTICES.md) · [API.md](./API.md) |
| `security/` `secrets/` | `AppSecurity`, `CatalogPermDb`, `JwksKeyRing`, `PasswordEncoder`, `SecretsManager` | [ROUTE_TABLE.md](./ROUTE_TABLE.md) · [API.md](./API.md) |
| `cache/` `redis/` `config/` `di/` `validation/` | `CacheManager`, `Redis`, `ConfigManager`, `TomlLoader`, `Container`, `Validator`, `FieldRules` | [EVENTS_DI.md](../guide/EVENTS_DI.md) · [API.md](./API.md) |
| `ai/` | `AiProvider`, `AiKeyManager`, `SkillRegistry`, `Agent`, `Guard`, `Workflow`, `ProposalPipeline` | [AI Overview](../ai/README.md) · [AGENT_RUNTIME.md](./AGENT_RUNTIME.md) · [AI_BOUNDARY.md](./AI_BOUNDARY.md) |
| `web4/` | `DidKey`, `VerifiableCredential`, `x402`, `X402Store`, `ChallengeStore` | [WEB4.md](./WEB4.md) |

## 2. Core Concepts

### 2.1 Module Definition

A module is a self-contained domain unit with explicit dependencies and lifecycle hooks:

```zig
pub const OrderModule = struct {
    pub const info = zmodu.api.Module{
        .name = "order",
        .description = "Order management",
        .dependencies = &.{ "user", "inventory" },
    };

    pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        _ = ctx;
    }

    pub fn deinit() void {}
};
```

### 2.2 Layered Architecture

```text
+---------------------------------------------------+
| Application Layer (src/main.zig)                  |
| - Infrastructure wiring (DB pool, Redis, Server)  |
| - Module composition & route mounting             |
+---------------------------------------------------+
| Domain Module Layer (src/modules/<domain>/)       |
| - api.zig -> service.zig -> persistence.zig       |
| - model.zig / module.zig                          |
+---------------------------------------------------+
| Framework Layer (zmodu)                           |
| - Application, ComptimeRouter, EventBus, DI, SQLx |
| - Opt-in Runtime (Workers, Mailboxes, Timers)     |
+---------------------------------------------------+
```

## 3. Module Communication

| Pattern | Mechanism | Coupling | Latency | Use Case |
|---------|-----------|----------|---------|----------|
| Synchronous Service / `Tx` | Direct function call or `persistence.Tx` | Explicit (`info.dependencies`) | Immediate (in-process) | Atomic multi-table transactions, synchronous queries |
| In-Process EventBus | `app.eventBus(T)` (`ThreadSafeEventBus`) | Decoupled (shared event union) | Immediate (synchronous listener) | In-process notifications |
| Transactional Outbox | `zmodu.outbox.OutboxPublisher` / `OutboxConsumer` | Decoupled | Asynchronous (durable) | Reliable cross-module or external side effects |

## 4. Architecture Engine & Dependency Validation (v0.18+)

Module dependencies are enforced at two levels:

| Check | Input | When it Runs | What it Enforces |
|-------|-------|--------------|------------------|
| `src/core/ModuleGraph.zig` (`ApplicationBuilder.build`) | Module types | Compile time | Rejects missing dependencies, self-dependencies, duplicate module names, and dependency cycles (with cycle path in `@compileError`) |
| `zmodu doctor` | Source directory | CLI / CI | Runs the same graph checks plus source-level `@import` scanning to catch cross-module internal file imports (`file:line`) |

```bash
zmodu doctor                 # Exit 1 on blocking graph/entanglement errors
zmodu doctor --json          # Machine-readable report for CI
zmodu doctor --max-deps 6    # Warn when a module exceeds N dependencies
zmodu doctor --allow a->b    # Allow a specific cross-module import edge
zmodu graph --out graph.mmd  # Export Mermaid dependency diagram
```

Severity rules:
- **Blocking (exit 1 / compile error)**: Dependency cycles, missing dependencies, self-dependencies, duplicate module names, and undeclared cross-module file imports.
- **Warning**: Dependency count exceeding threshold or isolated leaf modules (`shared` / `util`).

## 5. Lifecycle & Memory Management

### 5.1 Module Lifecycle Sequence

```text
ApplicationBuilder.build(.{...})  -> Compile-time graph validation
app.start()                       -> Runs init/initWith in topological dependency order, then freezes DI container
Operating                         -> Requests and workers run against frozen container and registries
app.stop()                        -> Joins runtime workers, then runs module deinit() in reverse topological order
app.deinit()                      -> Destroys per-module state (`ctx.state(T)`) in reverse creation order
```

### 5.2 Ownership Rules

1. **Explicit allocators**: Every allocating function accepts an explicit `std.mem.Allocator`.
2. **Borrowed DI services**: `builder.withService(T, name, ptr)` registers a borrowed pointer; the caller (`main`) owns the instance and frees it after `app.deinit()`.
3. **Zero-allocation hot paths**: The HTTP server uses a per-connection arena that resets between keep-alive requests; the runtime execution plane enforces zero heap allocations on mailbox, ring, `HotBus`, and timer hot paths.

## 6. Multi-Tenancy (Optional)

Multi-tenancy is opt-in. Single-tenant applications omit tenant middleware and `sql_tenant_column` declarations without overhead.

| Component | Path | Purpose |
|-----------|------|---------|
| `TenantContext` | `src/tenant/TenantContext.zig` | Request-scoped tenant ID; `zmodu.setTenantColumn("app_id")` customizes the SQL column name (defaults to `"tenant_id"`) |
| `sql_tenant_column` | Model declaration | Compile-time guard requiring `*ForTenant` (or explicit `*Unscoped`) repository calls |
| `ShardRouter` | `src/tenant/ShardRouter.zig` | Maps `tenant_id` to database shard pools |
| `DataPermission` | `src/datapermission/` | Row-level data permission filters paired with RBAC |
| Catalog JWT `aud` | `http.jwtAuthFromCatalogWithPermissions` | Extracts `aud` from tokens minted via `generateTokenWithTenant` into the `tenant_id` context attribute |

### Database Sharding (`ShardRouter`)

`ShardRouter.route` resolves a tenant's database pool in order:
1. Returns `null` if `TenantContext` is inactive or no pools are configured.
2. Uses the explicit binding from `assignTenant(tenant_id, pool_idx)` if present.
3. Falls back to `tenant_id % pools.len`.

> Because modulo fallback (`tenant_id % pools.len`) shifts assignments when `pools.len` changes, production deployments with data-affinity requirements must use explicit `assignTenant` bindings.
