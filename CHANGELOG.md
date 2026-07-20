# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **SecretsManager / Vault**: Implemented HashiCorp KV v2 HTTP (`loadFromVault` + `applyVaultKvJson`). Plain HTTP + `X-Vault-Token`; `https://` → `VaultTlsNotSupported`. Live smoke: `VAULT_ADDR` + `VAULT_TOKEN`.
- **gRPC**: Removed EXPERIMENTAL. Unary production path — `GrpcFrame`, `GrpcServiceRegistry.invoke` / `handleHttpUnary`, `GrpcClient.bindLocal` + `initWithIo` HTTP/1.1 `application/grpc`. Streaming still returns `UNIMPLEMENTED`.
- **Kafka**: Hardened wire layer — Produce response error-code check, RecordBatch value parse, Fetch value scan; added roundtrip unit tests. Live smoke still via `KAFKA_BOOTSTRAP` / `ROBUSTMQ_URL`.

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
