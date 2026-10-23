# Engineering Best Practices

Version: zmodu **v0.43.1** · Zig 0.17.0

This guide consolidates the architectural, security, concurrency, resilience, and testing practices for building production services with zmodu.

## 1. Progressive Architecture Evolution

zmodu scales along two independent axes: the **Application Plane** (modules, HTTP fibers, database pools, distributed messaging) and the **Execution Plane** (stateful workers, bounded mailboxes, lock-free queues).

### 1.1 Application Plane Scaling Stages

| Stage | Scale | Architecture & Key Practices |
|-------|-------|------------------------------|
| **A1: Single Node** | 0–1k DAU | Single binary modulith, SQLite or single PostgreSQL/MySQL, compile-time module graph (`ApplicationBuilder.build`), in-process `ThreadSafeEventBus`. |
| **A2: Vertical Scale** | 1k–10k DAU | Configure `ConnPool` (`max_open`, `max_idle`), LRU `CacheManager`, request-scoped arena allocation, and `http.productionProfile`. |
| **A3: Horizontal Scale** | 10k–100k DAU | Stateless replicas behind a load balancer, externalized Redis cache and `redis_rate_limit`, transactional outbox (`zmodu.outbox.*`), and `DistributedLock` for cron/migrations. |
| **A4: Service Governance** | 100k–1M DAU | Per-dependency `CircuitBreaker`, `AdaptiveShedder`, `Bulkhead`, OpenTelemetry tracing (`OtlpExporter`), and bounded Prometheus label cardinality. |
| **A5: Distributed / Multi-Cluster** | 1M+ DAU | Tenant-aware `ShardRouter` (explicit `assignTenant` bindings), Kafka/RobustMQ event streaming, and optional service extraction for modules with divergent resource profiles. |

### 1.2 When to Enable the Execution Plane (`app.runtime()`)

Do not use `app.runtime()` for standard CRUD HTTP endpoints; the fiber server and database pool already handle request-response workloads without extra threads.

Enable `app.runtime()` when:
1. A component owns in-memory mutable state mutated sequentially by high-frequency events (order books, matching engines, session state machines).
2. You need bounded mailbox backpressure (`error.Full`) below the HTTP layer.
3. You need lock-free `HotBus` fan-out, millisecond/microsecond timers (`TimerWheel` / `PrecisionTimer`), supervision trees, or deterministic `ZDL1` delivery replay.

Execution location selection:

| Workload | Configuration |
|----------|---------------|
| Latency-critical stateful loop | `.mode = .dedicated` (1 worker = 1 OS thread) |
| Many low-duty-cycle message actors | `.mode = .pooled` + `withMaxPooledWorkers(N)` |
| Synchronous external I/O or slow syscalls | `.execution_class = .blocking` + `withBlockingThreads(N)` |
| Standard HTTP CRUD | Default HTTP fiber server (do not spawn a worker) |

## 2. Module & Data Layer Conventions

### 2.1 Five-File Module Discipline

Every domain module under `src/modules/<name>/` separates concerns across five files:
- `model.zig`: Struct definitions, `pub const sql_table_name`, and `pub const sql_tenant_column: ?[]const u8 = "tenant_id"`.
- `persistence.zig`: Parameterized SQL (`?` placeholders only) and `pub const Tx` for multi-table transactions.
- `service.zig`: Business validation, transaction boundaries (`beginTx` / `commit` / `rollback`), outbox writes, and event emission.
- `api.zig`: Declarative `pub const routes` (or `http.CrudApi`) and thin HTTP handlers.
- `module.zig`: `pub const info` and `init` / `initWith` / `deinit`.

### 2.2 Selecting `data.sqlx` vs `zent`

| Criteria | `data.sqlx` / `data.Repository` (Built-in) | `zent` ORM (External Package) |
|----------|--------------------------------------------|-------------------------------|
| Schema definition | SQL DDL + Zig structs (`zmodu scaffold`) | Schema-as-code in Zig (`zent` codegen) |
| Query style | Parameterized SQL + `Repository(T)` + `Tx` | Fluent type-safe query builder + `joinEdge` |
| Transactions | `client.beginTx()` (`sqlx.Transaction`) | `zent` client transactions (do not mix with `sqlx` transactions) |
| Driver linking | `-Ddb=sqlite\|postgres\|mysql\|all` | Set `.db = "none"` on `zmodu` dependency if all DB access goes through `zent` |

### 2.3 Propagating Request Deadlines to SQL

`Server.Config.request_timeout_ms` bounds handler execution time, but a slow query will continue running unless the SQL layer receives the deadline. Pass `ctx.sqlContext()` to ORM or SQLx calls:

```zig
const scoped_orm = orm.withContext(ctx.sqlContext());
```

### 2.4 Compile-Time Multi-Tenant Isolation

Declare `pub const sql_tenant_column: ?[]const u8 = "tenant_id"` on tenant-scoped models. Calling unscoped repository methods on a tenant model fails at compile time; use `*ForTenant` methods for normal queries and `*Unscoped` (`findByIdUnscoped`, etc.) only when cross-tenant access is intentional.

Never read `tenant_id` from unverified query parameters (`.tenant_source = .query` is rejected by `zmodu audit` rule `b22`). Derive the tenant from verified JWT `aud` attributes (`.tenant_source = .attr`).

## 3. HTTP Routing, Authentication & Security

### 3.1 Path A Authentication Stack (Default for All New Apps)

1. **Issue tokens with tenant and portal roles**: Use `AppSecurity.generateTokenWithTenant(sub, roles, aud)` where `sub` is the user ID, `aud` is the tenant ID, and `roles` identifies the portal (e.g., `"shop"`, `"admin"`).
2. **Mount catalog JWT + RBAC middleware**:
   - `http.jwtAuthFromCatalogWithPermissions(&sec, &slot, loader, .{})` verifies the token, loads fine-grained permissions via `CatalogPermissionLoader`, and writes `user_id`, `tenant_id`, and `permissions` into `ctx.attributes`.
   - `http.permissionGateWith(&slot, .{ .mode = .rbac })` checks `RouteMeta.roles` and `RouteMeta.permission` (supports `|` OR expressions such as `"portal:user|portal:shop"`).
3. **Orthogonal context slots**:
   - `ctx.user_data` holds `*State` for `ComptimeRouter` handlers (access via `ctx.state(T)`).
   - `ctx.attributes` holds `user_id`, `tenant_id`, `roles`, and `permissions` (access via `ctx.userId()`, `ctx.requireUserId()`, `ctx.tenantId()`, `ctx.permissionMatches(...)`).
   - Never `@ptrCast(ctx.user_data)` to `AuthInfo` and never re-parse Bearer tokens inside handlers.
4. **Optional authentication**: Use `.meta = .{ .auth = .optional }` for public endpoints that personalize responses when a valid token is present.
5. **JWT key rotation**: Attach a `JwksKeyRing` via `app_sec.module.setKeyring(&ring)` so tokens carry a `kid` header and old keys verify during rotation windows.

### 3.2 File Uploads & Multipart Limits

Always pair `Server.Config.max_body_size` with `Multipart.Config.forBodyLimit(n)` and validate uploaded content with `http.UploadGuard`:

```zig
const form = try http.extractMultipart(ctx, http.Multipart.Config.forBodyLimit(max_bytes));
defer form.deinit();
try http.UploadGuard.checkForm(&form, .{
    .max_files = 5,
    .max_file_bytes = 2 * 1024 * 1024,
});
```

`UploadGuard` verifies magic bytes against the declared `Content-Type`, rejects path traversal in filenames, and blocks active script containers such as `image/svg+xml` by default.

### 3.3 Cryptographic Randomness (CSPRNG)

Always use `std.Io.randomSecure(io, buf)` for salts, tokens, nonces, and challenges. It fails closed with `error.EntropyUnavailable` if the OS CSPRNG fails. Never use `std.Io.random` (which falls back to PID + clock) or seed `std.Random.DefaultPrng` (`Xoshiro256`) for security-sensitive values.

## 4. Resilience, Backpressure & Production Readiness

### 4.1 One-Line Production Profile

Mount `http.productionProfile` **before** registering any routes (`addRoute` / `mountAll`):

```zig
pub const panic = zmodu.panicHook;

var profile = http.ProductionProfileState.init(allocator);
defer profile.deinit(allocator);
try http.productionProfile(&server, .{
    .max_connections = 4096,
    .over_limit_response = .close,
    .header_timeout_ms = 10_000,
    .body_timeout_ms = 30_000,
    .request_timeout_ms = 30_000,
}, &profile);
```

### 4.2 Unified Error Envelopes (RFC 7807)

Call `http.useRfc7807Errors()` at startup (or pass `.reject = http.problemReject` to individual gates) so middleware rejections, 404s, and `http.respondErr` all emit RFC 7807 `application/problem+json` responses. Validation failures return HTTP `422` with a non-zero error code.

### 4.3 Startup Preflight (`zmodu.Preflight`)

Run `zmodu.Preflight.run(...)` before `server.start()` to verify required environment variables, reject placeholder JWT secrets, ping the database, check pending migrations, and validate system clock sanity.

### 4.4 Multi-Replica Background Tasks & Distributed Transactions

- **Cron and Migrations**: Attach `zmodu.DistributedLock` via `cron.setLock(&lock)` and `migration_runner.setLock(&lock)` so only one replica executes scheduled jobs or DDL migrations at a time.
- **2PC Recovery**: Attach `zmodu.TransactionJournal.initWithBackend(allocator, backend)` to `TwoPhaseCommit` and call `recover()` on startup to surface in-doubt (`prepared`) transactions for operator resolution.
- **Saga Step Timeouts**: Always set a non-zero `SagaStep.timeout_seconds`.

## 5. Memory Management & Error Handling (Zig 0.17)

1. **No inline allocations in arguments**: Never pass `try allocator.dupe(...)` or `try allocator.print(...)` directly as a function argument (e.g., `try map.put(allocator, try allocator.dupe(u8, k), try allocator.dupe(u8, v))`). If the second allocation or `put` fails, the first allocation leaks. Bind each allocation to a local variable with `errdefer allocator.free(...)`. Both `zig build check` (`INLINE_ALLOC_ENFORCED`) and `zmodu audit` rule `b25` enforce this rule.
2. **No silent error swallowing**: Do not write bare `catch {}` on I/O, database, or hot-path calls. In cleanup blocks (`errdefer` or rollback), capture the error (`catch |err| std.log.debug(...)`) so both `zig build check` and `zmodu audit` rule `b10` pass.
3. **No `@panic` or `catch unreachable` in request paths**: Enforced by `zmodu audit` rules `b19`–`b21`.
4. **Freeze shared maps before serving**: Use `zmodu.FrozenMap` / `FrozenStringMap` for shared registries initialized at boot and read concurrently by workers or request fibers.
5. **Lock discipline**: Never perform network I/O, disk I/O, or unbounded allocations while holding a mutex.

## 6. Testing & Verification

### Running Focused Tests

Do not use `zig build test -- --test-filter X` (Zig 0.17's build runner ignores arguments after `--`). Use `scripts/test-fast.sh`:

```bash
# Run only tests matching a substring (fails with exit code 2 if 0 tests match)
bash scripts/test-fast.sh --db all --filter "RaftElection"

# Force execution even when Zig's test cache is warm
bash scripts/test-fast.sh --force-run
```

### Pre-Release Checklist

- [ ] `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test` passes with `-Ddb=all`.
- [ ] `zig build fmt-check && zig build check && zig build check-api` pass.
- [ ] `bash scripts/check-deadcode.sh && bash scripts/check-doc-paths.sh && bash scripts/check-version.sh` pass.
- [ ] `zmodu ci` passes on the target application repository.
- [ ] `http.productionProfile`, `zmodu.panicHook`, and `zmodu.Preflight` are wired in `src/main.zig`.

---
Version: zmodu **v0.43.1**
