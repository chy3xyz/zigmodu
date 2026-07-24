# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **zent support — shared helper for examples**: `examples/_shared/zent_helpers.zig` provides `StoreEnv(Driver, Infos).open / inMemory / openWith` (RAII wrapper that replaces the open-driver + migrate + make-client dance) and `TestEnv(schemas).init / reset / deinit` (per-test in-memory SQLite with fresh migrations). Both `examples/zent-modulith/` and `examples/shopdemo-zent/` now use it; `examples/_shared/build.zig` runs the helper's own tests.
- **zent docs extended**: `docs/ZENT.md` adds `§6.1 Testing` (TestEnv pattern), `§6.2 Production: ConnPool` (production driver wrapping), `§6.3 Observability` (zent `sql_logger` → ZigModu logger adapter), and `§6.4 Transactions` (beginTx + savepoint). Shared helper callout at the top.
- **`examples/shopdemo-zent` runnable**: parallel of `examples/shopdemo/` using `zent` (ent-style schema-as-code ORM) instead of `zigmodu.data.sqlx`. Single `order` module with `Order` + `OrderItem` zent Schemas, `OrderStore` persistence, `OrderService` validation, and `OrderApi` exposing `POST/GET /api/v1/orders` plus `POST /api/v1/orders/{order_no}/items`. Demonstrates `docs/ZENT.md`'s orthogonal data-stack rule: each module picks one driver and does not mix or share transactions.
- **Completeness Phase 3 — distributed event bus wiring**: `DistributedEventBus` now actually routes through `Partitioner.route(topic)`, captures send failures in `DLQ` after `max_send_failures` threshold, drains DLQ via a retry fiber, and exposes `connectToNode` / `nodeId` / `clusterSize` for membership integration. `WAL.readFrom` is implemented so `replayFromWal` and `restoreFromWal` actually recover uncommitted entries. `ClusterMembership` keeps the partitioner ring in sync on join / leave / failure.
- **SQLx MySQL binary protocol hardening**: `mysqlFetchStringColumn` re-reads oversized values via `mysql_stmt_fetch_column` instead of silently truncating; `mysqlParseDecimal` / `mysqlParseDateTime` / `mysqlParseJson` validate input strictly (negative TIME allowed, fractional seconds `.[0-9]{1,6}`, JSON via `std.json.parseFromSlice`).
- **`examples/shopdemo` runnable**: `build.zig` / `build.zig.zon` / `src/main.zig` / `src/db/*` added; the single `order` module from `generated-sample/` is migrated with API compatibility fixes; `zig build run` starts the app and `GET /api/v1/orders` returns 200.
- **WorkerPool / EventBus observability**: `WorkerPool.WorkerPoolStats.toPrometheusFormat` renders pool stats as Prometheus text; `TypedEventBus` tracks `published_total` and `dropped_async_total` atomically with `publishedCount` / `droppedAsyncCount` getters.
- **Modulith QPS Phase 2 — async EventBus + WorkerPools**: `core.WorkerPool` (bounded queue, graceful stop, error isolation), `TypedEventBus.subscribeAsync` / `ThreadSafeEventBus.subscribeAsync`, `api.Module.RuntimeOptions.worker_count`, and per-module `WorkerPool` integration in `core.ModuleRuntime`. Includes cross-module pilot test and `max_worker_count = 128` guard (`error.ConfigurationError` for 0 or overflow).
- **Modulith QPS Phase 1 — per-module resource isolation**: `api.Module.RuntimeOptions`, `core.ModuleRuntime` (bulkhead + rate limiter + circuit breaker), `core.ModuleRegistry`, and `Application.getModuleRuntime()`. Thread-safe admission via `std.Io.Mutex`, overflow-safe quota validation, and full backward compatibility for modules without runtime options.
- **SQLx connection pool lifecycle**: per-connection `created_at`/`idle_since` timestamps, max-lifetime / max-idle-time eviction, FIFO waiter fairness, and `PoolMetrics` (acquired/released/created/closed/stale-evicted totals, wait time, max active/idle).
- **SQLx streaming cursor**: `Client.queryCursorEx(sql, args, .{ .mode = .streaming })` with driver-native streaming for MySQL (`mysql_use_result`) and PostgreSQL (`PQsendQueryParams` + `PQsetSingleRowMode`). SQLite falls back to buffered mode.
- **SQLx batch protocols**: `Client.batchInsertEx(table, columns, rows, .{ .mode = .protocol })` uses MySQL prepared-statement multi-execute and PostgreSQL `COPY ... FROM STDIN` (CSV). Falls back to multi-row `INSERT` SQL on failure or SQLite.

### Changed
- **SecretsManager / Vault**: Implemented HashiCorp KV v2 HTTP (`loadFromVault` + `applyVaultKvJson`). Plain HTTP + `X-Vault-Token`; `https://` → `VaultTlsNotSupported`. Live smoke: `VAULT_ADDR` + `VAULT_TOKEN`.
- **gRPC**: Removed EXPERIMENTAL. Unary production path — `GrpcFrame`, `GrpcServiceRegistry.invoke` / `handleHttpUnary`, `GrpcClient.bindLocal` + `initWithIo` HTTP/1.1 `application/grpc`. Streaming still returns `UNIMPLEMENTED`.
- **Kafka**: Hardened wire layer — Produce response error-code check, RecordBatch value parse, Fetch value scan; added roundtrip unit tests. Live smoke still via `KAFKA_BOOTSTRAP` / `ROBUSTMQ_URL`.
- **SQLx**: Removed broken `withRows` helper from `data.zig` re-export (no in-tree callers; called `client.queryRows` without the `T` type parameter).

## [0.14.15] - 2026-07-24

### Fixed
- **SQLx `Client.open` pool self-pointer dangling after by-value return**: `ensurePool` stored `ConnPool.client = &local` then `return client` moved the struct, leaving `pool.client` pointing at the dead temporary (SIGSEGV at low addresses like `0x70` on next pool use). `open` no longer creates the pool; call `warmPool()` on the final `*Client` for idle warmup. `ensurePool` always rebinds `pool.client = self`.

## [0.14.14] - 2026-07-24

### Fixed
- **SQLx `Client.ensureBreaker` race / segfault**: `cb` was a lazily initialized `?CircuitBreaker`. Concurrent first-touch from worker fibers could tear the optional write (null/`Io.vtable` → segfault on next `allow`/`record*`, often at low addresses like `0x1a0`). `cb` is now a non-optional `CircuitBreaker` eagerly created in `Client.init`; `ensureBreaker` removed.

## [0.14.13] - 2026-07-24

### Fixed
- **SQLx PostgreSQL SafeAllocator panic (alloc=N+1 / free=N)**: `PostgresConn.stmt_cache` stored `allocZ` (`[:0]u8`) names as `[]const u8`, so LRU eviction / close freed without the sentinel. Cache values are now `CachedStmt([:0]u8)`. Same coerce bug fixed in `queryCursorFn` (`if (args.len==0) slice else [:0]`). `bufPrintZ` reserves the last byte for `\0`. `pgDecodeNumeric` no longer writes through a fixed `[256]u8` stack buffer (heap `ArrayList` + safe `dscale`/`lead_zeros` math).

## [0.8.2] - 2026-05-10

### Fixed
- **SecretsManager**: Inverted priority comparator (`<=` → `>=`) so env > file > vault > default works correctly.
- **SecretsManager**: Double-free in `setWithPriority` when replacing entries — old key freed before `HashMap.remove`.
- **ContractTest**: Double-free in `verifyContract` status check — `allocPrint` strings freed by both local `defer` and `deinit`.
- **LoadShedder**: `now_ms = 0` replaced with `Time.monotonicNowMilliseconds()` — rolling window now advances correctly.
- **Migration parse test**: Isolated with `ArenaAllocator` to prevent allocator-state corruption from prior tests.
- **Version sync**: All version strings unified to v0.8.x across `build.zig.zon`, `main.zig`, and `CHANGELOG.md`.

### Added
- **Graceful shutdown**: `Server.in_flight` request counter + `withGracefulDrain()` wired into `Application.run()` (30s drain timeout, SIGINT/SIGTERM handlers).
- **Prometheus /metrics**: `PrometheusMetrics.registerMetricsRoute()` — one-line `/metrics` in Prometheus text format.
- **Health check context**: `HealthCheck.check_fn` now takes `?*anyopaque` context; `databaseCheck`, `redisCheck`, `diskSpaceCheck` work with real connections.
- **Config validation**: `ExternalizedConfig.validateRequired()` returns missing keys for clear startup errors.
- **ThreadSafeEventBus**: `ThreadSafeEventBus(T)` wraps `TypedEventBus` with `std.Thread.Mutex`.
- **E2E tests**: Server middleware chain + error path, Application lifecycle smoke test, in-flight counter tracking.
- **API Migration Guide**: `docs/API-MIGRATION.md` — Simplified.zig → Application migration path.

### Changed
- **root.zig**: Reorganized from flat 297-line list into 14 named sections with clear category headers.
- **Emoji logs**: Removed all emoji prefixes from production log messages in Application, Lifecycle, ModuleValidator, docs.
- **README**: Updated test count (338 passed, 0 failed), honest production readiness score (84/100), experimental markers on gRPC/Cluster/DistTx/Plugin/WebMonitor/HotReload.
- **CI**: Removed broken `--test-filter` flags from lint job (unsupported by build.zig).

## [0.8.0] - 2026-05-08

### Added

#### Production Hardening (Phase 7)
- **Database Migrations** (`src/migration/Migration.zig`) — Flyway/Liquibase-style versioned migrations with SHA256 checksums, rollback support, status tracking (pending/applied/failed), DDL generation, and filename parsing (`V{timestamp}__{description}.sql`). 10 tests.
- **Secrets Manager** (`src/secrets/SecretsManager.zig`) — Multi-source secrets with priority resolution (env > file > vault > default). Supports K8s/Docker secrets, Vault placeholder, JSON/env content loading, getInt/getBool/getOrDefault/listKeys/exportAsEnv. 10 tests.
- **Docker Support** (`Dockerfile` + `docker-compose.yml`) — Multi-stage build (zig:0.16.0 → alpine:3.21), non-root user, health check. Compose stack includes PostgreSQL 17, Redis 7, Vault 1.18 (profile), Jaeger 1.65 (profile).
- **Timestamp Audit** — Verified all 16 production sites use `Time.monotonicNowSeconds()`. 9 remaining `timestamp=0` in test-only code.

#### Network Verification & Integration (Phase 8)
- **Idempotency Middleware** (`src/http/Idempotency.zig`) — `IdempotencyKey` header-based request deduplication with TTL store, automatic eviction, purge-expired. 5 tests.
- **Module Interaction Verifier** (`src/core/ModuleInteractionVerifier.zig`) — Spring Modulith `verify()`-style architecture validation. Checks circular dependencies, self-dependency, max dependencies, generates ASCII violation reports. 6 tests.
- **OpenAPI Generator** (`src/http/OpenApi.zig`) — Generates OpenAPI 3.0/3.1 JSON from route metadata. Supports endpoints, tags, path/query/header params, response schemas. 4 tests.

#### Modulith Deep Features (Phase 9)
- **gRPC Transport** (`src/core/GrpcTransport.zig`) — Full gRPC service registry with method registration, 16 standard status codes with HTTP mapping, proto file parser (service/method extraction), client stub with endpoint management. 6 tests.
- **Kafka Connector** (`src/core/KafkaConnector.zig`) — Producer with send/sendBatch/flush/close + per-topic statistics, Consumer with subscribe/unsubscribe/getSubscriptions, EventBridge for Kafka ↔ DistributedEventBus integration. Configurable acks, compression, auto_offset_reset. 7 tests.
- **Saga Orchestrator** (`src/core/SagaOrchestrator.zig`) — Automatic compensation with reverse-order rollback on step failure. Saga registration, step logging (started/completed/failed/compensated), instance tracking, active instance listing. 5 tests.
- **Contract Testing** (`src/test/ContractTest.zig`) — Consumer-Driven Contract (Pact-style) verification. Validates HTTP status, response body contains, and response headers against defined contracts. Generates ASCII pass/fail reports. 6 tests.
- **CI/CD Pipeline** (`.github/workflows/ci.yml`) — GitHub Actions workflow with matrix build (ubuntu + macOS), caching, fmt check, full test suite, architecture validation, security scan, benchmarks (ReleaseFast), multi-platform Docker build (amd64/arm64), GitHub Release with artifacts.

### Changed
- **`root.zig`** — Added 30+ new exports for Phases 7-9 modules in ADVANCED API section
- **`tests.zig`** — Added compilation gates for all new modules
- **`AGENTS.md`** — Updated with all new module conventions, middleware patterns, migration/secrets/saga/Kafka/gRPC usage examples
- **`README.md`** — Comprehensive update with new features, project structure, Docker quick start
- **`docs/API.md`** — Added API references for Migration, Secrets, Idempotency, OpenAPI, gRPC, Kafka, Saga, ContractTest
- **`docs/COMPLETENESS_REPORT.md`** — Updated scores: 93/100 production readiness
- **`docs/EVALUATION_REPORT.md`** — Final evaluation with Phase 7-9 coverage

### Test Results
- **282 passed**, 5 skipped, 2 failed (pre-existing)
- +53 new tests across Phases 7-9
- All timestamp-related bugs resolved; no `timestamp=0` in production code

## [0.7.0] - 2026-04-23

### ⚠️ Breaking Changes

- **`ModuleInfo.init()`** now takes 3 arguments `(name, desc, deps)` instead of 4. The `ptr` field is now `?*anyopaque` (nullable, default `null`). Update all call sites.
- **`ModuleInfo.init_fn` / `deinit_fn`** signatures changed from `fn(*anyopaque)` to `fn(?*anyopaque)`.

### Added

- **`core/Time.zig`** — Centralized monotonic time utility using `clock_gettime(CLOCK_MONOTONIC)`. Replaces all hardcoded `const now = 0` throughout the codebase (16 occurrences across 10 files).
- **`root.zig`** — Exports `time` module as `zigmodu.time`.
- **3 new tests** for Time.zig (monotonicity, positive values).

### Fixed

- 🔴 **Timestamp system**: All time-dependent subsystems now use real monotonic time:
  - `CircuitBreaker` — OPEN→HALF_OPEN timeout transition now works
  - `RateLimiter` — Token bucket refill now works with real elapsed time
  - `SlidingWindowRateLimiter` — Window cleanup now works
  - `CacheManager` — TTL expiration now works
  - `DistributedTracer` — Span durations now have real values
  - `TaskScheduler` / `Cron` — Scheduling now uses real time
  - `HttpClient.Connection.isAlive()` — Idle timeout detection now works
  - `ClusterMembership` — Health check timeout detection now works
  - `sqlx/breaker.zig` — Circuit breaker now works

- 🔴 **`ModuleInfo.ptr` UB**: Eliminated `undefined` initialization. Ptr is now nullable `?*anyopaque` with default `null`. Tests no longer trigger undefined behavior.

- 🔴 **Version inconsistency**: Unified version to `0.7.0` across `build.zig.zon`, `main.zig`, `CHANGELOG.md`, and `AGENTS.md`.

- 🔴 **build.zig test paths**: Replaced hardcoded macOS Homebrew paths with dynamic detection via `detectPqPaths()`/`detectMysqlPaths()`. Tests now work on Linux/CI.

- **`ApplicationModules.register()`**: Now invalidates cached `sorted_order` to prevent stale topological sort after module set changes.
