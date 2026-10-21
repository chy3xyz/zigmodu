# Upgrading

Version-by-version notes for zmodu changes that stop compilation or change behaviour.

## Find the versions that affect you

Every entry carries a **Breaking?** marker.

| Marker | Meaning | Action |
|---|---|---|
| **Compile error** | A type or signature changed | Apply the entry's one-line fix |
| **Behaviour change** | Compiles, behaves differently | Confirm your usage is outside the described range |
| **Non-breaking** | Bug fix or added capability | Usually nothing |

Upgrading from an old 0.x release: read Deprecated aliases and the removal plan first. Deprecated aliases are removed no earlier than 1.0, so no 0.x upgrade requires a rename.

The full change history is in [CHANGELOG.md](../../CHANGELOG.md); this file records only changes that need action.

```bash
zig build test                          # framework self-test; keep the default -Ddb=all
bash scripts/check-production.sh        # layering gate (bare catches, envelope leaks)
zmodu ci                                # app: build + fmt + verify + audit + deadcode
```

## Deprecated aliases and the removal plan

Deprecated aliases are removed no earlier than 1.0. The release that removes them is announced here and in that version's entry; nothing is deleted silently.

| Deprecated | Current name | Removal |
|---|---|---|
| `ctx.paramPath` | `ctx.nestedParam` | No earlier than 1.0 |
| `zmodu.startAll` | `Application.start()` | No earlier than 1.0 |
| `zmodu.stopAll` | `Application.stop()` | No earlier than 1.0 |
| `zmodu.http.http_server` | `http.Server` | No earlier than 1.0 |
| `ctx.sendSuccess` | `ctx.json` (200, data) — the `{code,msg,data}` envelope is no longer added | No earlier than 1.0 |
| `ctx.sendFail` | `ctx.json` (status, body) | No earlier than 1.0 |
| `ctx.sendPageResult` | `ctx.json` (200, body) — build the paging shape yourself | No earlier than 1.0 |
| `ctx.sendJsonItems` | `ctx.json` (200, body) | No earlier than 1.0 |
| `RateLimiter.acquire` | `RateLimiter.tryAcquire` (same meaning; it never waited) | No earlier than 1.0 |

### Near-identical names that are not deprecated

`param` → `paramPath` → `nestedParam` reads like three renames; it is one rename plus one synonym.
- `ctx.param` — current name, not deprecated; reads route placeholders (`/orders/{id}`). `ctx.pathParam` is a synonym added in v0.15.38. Both are supported API.
- `ctx.paramPath` — the only deprecated name in this chain. Renamed to `ctx.nestedParam` in v0.15.46 because it reads dotted paths from form/query (`filter.tags`), never route parameters. Removed no earlier than 1.0.
- Synonymous additions without a removal plan: `ctx.jsonValue` (= `jsonStruct`, v0.15.38) and `http.csrf()` (= `csrfWith(.{})`, v0.33.3).

A name is deprecated when it is in the table above **and** carries a `DEPRECATED` marker in code; `src/test/ApiFreeze.zig` checks both. A name with neither has no removal plan.

### Names removed during 0.x

Some names left before 1.0 because keeping them was worse: they never worked, were never exported, or would have silently changed meaning. Each is recorded in its version entry: `ScheduledTask.TaskScheduler` (0.15.1, a placeholder), `Runtime.cancelTimer(id) bool` (v0.28.0, `bool` could no longer report a pending timer), `sqlx.hasUnboundedPgReads` (v0.39.6, unbounded reads no longer exist), and `TransactionalEvent` / `src/persistence/Database.zig` (never exported from `root.zig`).

### File-level deprecation banners

Two files carry a whole-file `DEPRECATED` banner. They are neither table rows (no consumer-writable old name remains) nor removals (the file still exists).
- `src/extensions.zig` — the `zmodu.extensions` namespace is gone from the top level; the file is a type-alias shim reachable only as `@import("zmodu/src/extensions.zig")`, an internal path.
- `src/validation/Validator.zig` — the banner says "removed in v1.0". The file is aliases only (`pub const <name> = <home>.<name>;`), with no `pub fn`. Canonical homes: `src/validation/FieldRules.zig` for the rule shape, `src/validation/FieldValidation.zig` for the engine (`validateStruct`, `validateStructCollect`, violations, `MessageHook`, scalar checks). `http.FieldRules`, `http.validateRequest` and `http.extractJsonValidated` import the homes directly.

The gate pins the banner to the first 1500 bytes, checks the replacement paths resolve, checks `http.FieldRules` is the same type as `validation/FieldRules.zig`, and checks every `validateStruct*` declaration lives in `validation/FieldValidation.zig` while the deprecated file keeps one alias per spelling and no function bodies. Both files are still imported by the compile gate in `src/tests.zig`.

### Removed

`Simplified` is not in the table: "no earlier than 1.0" is a promise about aliases that still exist, so a deleted name recorded that way would read as available.
- `zmodu.App` / `zmodu.ModuleImpl` — removed from `src/root.zig` in commit `557190a` (2026-05-12, "…+ Simplified removal"). Replacement: `Application` (`zmodu.builder(...).build(.{...})`). The Before section of [`API-MIGRATION.md`](../archive/status/API-MIGRATION.md) no longer compiles; it only documents what old code did. The implementation remains in `src/api/Simplified.zig`, reachable only as `@import("zmodu/src/api/Simplified.zig")`. `src/test/ApiFreeze.zig` pins both names as absent from the root.
- `zmodu.extensions` — the whole namespace, including `zmodu.extensions.HttpServer` and `zmodu.extensions.ModuleTestContext`. No commit or tag records the removal; the written evidence is `CHANGELOG.md` `[0.15.0]` (2026-08-01), which already lists `zmodu.ModuleTestContext` as a `root.zig` export. `@hasDecl(zmodu, "extensions")` is false. Replacements: `HttpServer` → `zmodu.http.Server`, `HttpContext` → `zmodu.http.Context`, `SqlxClient` → `zmodu.data.sqlx.Client`, `Orm` → `zmodu.data.orm.Orm`, `RedisClient` → `zmodu.data.redis.Redis`. `src/extensions.zig` still holds these aliases; its banner says "This file will be removed in v1.0".

### Adding a deprecation

All three, in one change: mark the declaration `DEPRECATED` and name the replacement; add a table row with the removal column filled; point that version's entry back here. `src/test/ApiFreeze.zig` fails on a row without a gate, a gate without a row, an empty removal column, or a target that no longer resolves.

### `RouteGroup` and `Server.group` are removed

Runtime registration uses `Scoped`; declarative routes use `routes`:

```zig
pub const routes = [_]http.RouteSpec(State){
    .{ .method = .GET, .path = "{id}", .handler = get, .meta = .{ .auth = .jwt } },
};
// Mount: router.scope("/api").mountAll(.{ .{ .Mod = OrderApi, .state = &st } })
// Runtime registration (plugins, admin panels, SSE): scope.get / scope.post / scope.ws
```

Migration is mechanical; method names are unchanged: `server.group("/api")` → `router.scope("/api")`, and `get/post/put/delete/patch/head/options`, `use` and `ws` keep their names.

The difference is metadata. `RouteMeta` keeps auth, permission, roles and OpenAPI in the same comptime table as the handler, duplicate paths fail before `finish()`, and `Testkit.auditAuthCoverage` can audit them. `Scoped` routes are **not** in the catalog: permission gates, OpenAPI and auth-coverage audits cannot see them; use `routes` / `ws_routes` / `sse_routes` when you need those. Framework-internal registration goes through `src/api/RouteRegistrar.zig`, which is not exported from `http.zig`.

## Zig 0.17 toolchain migration checklist

Errors your own application code hits after moving to Zig 0.17. Search for the compiler message and apply the fix.

| Compile error (keyword) | Fix | Note |
|---|---|---|
| `no member named 'allocPrint'` / `'allocPrintSentinel'` | `std.fmt.allocPrint(a, fmt, args)` → `a.print(fmt, args)` (returns `!void`); `allocPrintSentinel` → `a.printSentinel(fmt, args, sentinel)` | Or `std.Io.Writer.fixed` plus `print` |
| `no member named 'builtin' in 'std'` | `std.builtin.…` → `std.lang.…` (`Type`, `SourceLocation`, `CallingConvention`) | Type is unchanged |
| `no member named 'os'/'cpu'/'abi'/'object_format'` | `@import("builtin").os` → `builtin.target.os`, `cpu` → `target.cpu`, `abi` → `target.abi`, `object_format` → `target.ofmt` | Old names removed in 0.18.0 |
| `no member named 'DebugAllocator'` | `std.heap.SafeAllocator` | Same semantics, stricter leak detection |
| `hasDecl` (function form) | `@hasDecl` | Function form removed in 0.17 |
| `trimRight` / `trimLeft` | `trimEnd` / `trimStart` | Rename only |
| `@intFromEnum` / `@enumFromInt` | `@backingInt` / `@fromBackingInt` | `zig fmt` migrates most; `@fromBackingInt` needs the exact backing type |

Removed outright in 0.17 — compile errors, not deprecation warnings:

| Removed | Replacement |
|---|---|
| `std.Thread.sleep` / `std.Thread.Mutex` / `std.Thread.WaitGroup` | Busy loop or `std.Io.sleep` / `std.Io.Mutex` (`lock(io)`, `unlock(io)`) / `std.Io.Group` |
| `std.time.timestamp` / `milliTimestamp` / `microTimestamp` / `nanoTimestamp` | `Time.monotonicNowSeconds` / `Time.monotonicNowMilliseconds` for durations; `Time.wallClockSeconds(io)` / `Time.wallClockMilliseconds(io)` for stored timestamps (the wall clock can move backwards) |
| `std.os.getpid` | `@intFromPtr(&seed)` for a pid-shaped value; entropy comes from `std.Io.randomSecure` |
| `std.fs.cwd()` / `std.fs.File` | `std.Io.Dir.cwd(io)` / `std.Io.File`; `file.writeAll(data)` → `file.writeStreamingAll(io, data)` |
| `ArrayList(T).init(alloc)` | `ArrayList(T).empty` plus an allocator on every method |
| `file.reader()` / `buf.writer(allocator)` | `allocPrint` + `appendSlice`, or `std.Io.Writer` |

The full removed list for framework contributors, including POSIX signals and `crc.Crc32Iscsi`, is in [AGENTS.md](../../AGENTS.md) under "Zig 0.17.0 — what's REMOVED".

## v0.41 — rename ZigModu → zmodu (compile error)

Package, module and repository names are all `zmodu`. The compiler reports every site.
- Dependency key and module: `.zmodu = .{ … }` in `build.zig.zon`; `b.dependency("zmodu", …).module("zmodu")`; `@import("zmodu")`.
- The `zigmodu` module and the `ZIGMODU_*` environment variables are gone. Rename dependency key, module name, imports and env prefix in one pass; no alias is kept.
- The package fingerprint is `0xde7987a02b121580` (Zig requires a new value after a rename). Dependency hash prefixes changed from `zigmodu-` to `zmodu-`; run `zig fetch` again and update `.hash`.
- These wire contracts keep the old spelling on purpose: Prometheus metrics `zigmodu_*`, migration table `_zigmodu_migrations`, Raft snapshot prefix `zigmodu-raft-snapshot:`, model field `zigmodu_ignore_tenant`. They live in dashboards, existing databases, on-disk formats and application code; the rename happens at 1.0 with dual write and migration.
- Repository `https://github.com/chy3xyz/zmodu` (GitHub redirects the old URL). Docs use `--url-prefix zmodu`. `install.sh` installs to `~/.zmodu`; `~/.zigmodu` is not reused.

## v0.39.11

1. **`StaticFiles.staticMiddleware` returns `!api.Middleware`** (compile error). Construction can fail; add `try` at the call site.
2. **Failed migrations are no longer marked applied** (behaviour tightening). Only a provably redundant `ALTER TABLE ADD COLUMN` is exempt, verified with a `SELECT <column> FROM <table> LIMIT 0` probe. Everything else returns `error.MigrationFailed` and leaves the migration unapplied.
3. **TCP dial timeouts** (behaviour tightening). `KafkaProducerConfig.connect_timeout_ms = 5000` now takes effect — it was declared but never forwarded, so the kernel default applied; set `0` for the old behaviour. The Kafka consumer gains the same field and default. `DistributedEventBus` gains `connect_timeout_ms = 5000`. `redis` and `NATS` gain `connect_timeout_ms = 0` (kernel default, unchanged behaviour). `FluvioNative.connectWithTimeout` is new; `connect` is unchanged.
4. **`HttpClient.timeout_ms` is a request deadline** (behaviour change). A slow-drip response can no longer take N × `timeout_ms`; the budget is exhausted and `error.Timeout` is returned. `0` still means unlimited. New `max_response_bytes` (default `0` = unlimited): an oversized `Content-Length` is rejected before allocation, and decoded chunked bodies are truncated with `error.ResponseTooLarge`.
5. **`RateLimiterRegistry` is bounded by default** (behaviour tightening). `init` now uses `default_max_keys = 65_536` (LRU) instead of `0` (unbounded); `initWithCapacity(…, 0)` is still unbounded. Keys come from request input, so an unbounded registry is remotely triggerable memory growth.
6. **Raft snapshot accumulation is bounded** (behaviour tightening; only visible above 256 MiB). `ElectionConfig.max_snapshot_bytes` defaults to 256 MiB (`0` disables). An oversized stream is rejected and its buffer cleared; the leader resends from offset 0 on the next round. The buffer is released when a snapshot completes, is rejected, or is replaced.

## v0.39.10

**Per-node keys now authenticate the event bus** (behaviour change). Applies only to clusters that configure `own_key`/`peer_keys` without `cluster_secret`: the bus previously ran bare frames, and now `ClusterBootstrap` forwards the same key material to it, making the bus handshake mandatory. The Raft wire format is unchanged.

Rolling upgrade of such a cluster: new nodes demand a handshake while nodes at v0.39.9 and older still send bare frames, so the bus mesh disconnects between the two sides (Raft replication is unaffected). Configure `cluster_secret` on every node and roll once, then roll this version; remove `cluster_secret` in a separate roll if you do not want it. Clusters that already set it see no change.

## v0.39.6

1. **Middleware factories and slot-pool functions return errors** (compile error). Add `try` at every wiring point.

```zig
// Old
try server.addMiddleware(http.permissionGateWith(&slot, .{ .mode = .rbac }));
const loader = zmodu.security.CatalogPermDb.loaderFromClient(db);
// New: note the nested try
try server.addMiddleware(try http.permissionGateWith(&slot, .{ .mode = .rbac }));
const loader = try zmodu.security.CatalogPermDb.loaderFromClient(db);
```

The 13 factories returning `error{OutOfMemory}!api.Middleware`: `http.jwtAuthFromCatalog`, `http.jwtAuthFromCatalogWithPermissions`, `http.authFromCatalog`, `http.tenantResolver`, `http.moduleGate`, `http.permissionGate`, `http.permissionGateWith`, `http.compressionMiddleware`, and under `http.http_middleware`: `cors`, `jwtAuth`, `csrf`, `csrfWith`, `securityHeaders`, `rateLimitPerClient`. The slot pools returning `error{SlotPoolExhausted}`: `http.catalogLoaderFromTable` (64 slots), `zmodu.security.CatalogPermDb.loaderFromClient`, `zmodu.security.ApiKeyAuth` (also `apiKeyAuth`) and `ApiKeyAuthWithLoader`, `http.openApiFromCatalog` and `http.openApiRoutes` (16 slots). Let the error reach `main`; catching it leaves later routes without an authorization loader.

2. **`Fx.Parallel` / `Fx.Map` run concurrently** (compile error). The first parameter is `io: std.Io`, so `zmodu.fx.Parallel(io, T, items, 4, func)`; `Parallel` dropped its unused allocator. Work is chunked by `max_workers` with `std.Io.Group`, so `func` must be thread-safe.
3. **JWT segments use strict base64url** (behaviour tightening). Segments with `=` padding are rejected, per RFC 7515. Make the issuer emit unpadded segments; standard implementations already do.
4. **Scheduler `push` waits instead of aborting** (non-breaking). When the spin/yield budget is exhausted, `push` sleeps 1 ms and retries until a slot appears or the scheduler stops. `ready_push_failures` now means "a push waited the whole budget" and must still stay 0; a non-zero value points at the host, not the framework.
5. **sqlx `query_timeout_ms = 0` falls back to the default** (behaviour change, one API removal). For postgres and mysql, `0` now means 30000 ms rather than unbounded; reads are always bounded. `sqlx.hasUnboundedPgReads` is removed. New `sqlx.DEFAULT_QUERY_TIMEOUT_MS` (30000) and `sqlx.effectiveQueryTimeoutMs`. MySQL's `MYSQL_OPT_READ_TIMEOUT` now uses this value, rounded up to whole seconds.
6. **TimerWheel fires equal deadlines FIFO** (behaviour change). Timers armed on the same deadline fire in arm order instead of reverse arm order. If you depended on the old order, reverse your arm order; better, do not depend on relative order within one deadline.

## v0.35.0

- **`ws_write_timeout_ms = 0` means "inherit", not "unlimited"** (behaviour change). Pushes now use `response_write_timeout_ms` (default 30 s). To restore the old behaviour, set `response_write_timeout_ms = 0`, which disables both budgets.
- **Every server write path has a budget** set by `response_write_timeout_ms`: H1 buffered responses, chunked/streaming, SSE, HTTP/2 frames and `Server` WS frames. `WebSocketServer` and `WebMonitor` have their own `setWriteTimeout` (default 30 s). The budget applies per `send`, so a slow but moving peer is not cut off; a peer that stops reading gets a truncated response and a closed connection. A failed write is sticky: later writes and flushes return the same error instead of a successful empty flush.
- **HTTP/2 responses larger than `max_pending_bytes` (default 4 MiB) are sent.** `max_pending_bytes` bounds the queue, not the body; workarounds that moved large H2 responses to H1 can be removed. New H2 streams start at the peer's `SETTINGS_INITIAL_WINDOW_SIZE` (RFC 9113 §6.5.2) instead of 65535.

## v0.33.6 → v0.34.0 (released as v0.34.0)

No breaking change in this release.
- New `zmodu.TomlLoader`: `var loader = zmodu.TomlLoader.init(allocator); try loader.loadFile("app.toml", &config);`. `[server]` + `port` becomes `server.port`, and types are preserved.
- `ScopedContainer.registerBorrowed` / `remove` / `serviceCount` complete the `Container` surface. Lookups (`get`, `contains`) fall through to the parent; mutations and `serviceCount` apply to the current scope only. `remove` never reaches the parent, because unregistering a shared service would leave other readers with a destroyed instance.
- `zmodu.runtime.affinity`: `supported` (comptime) and `pinCurrentThread(cpu_index)`. Linux uses `sched_setaffinity(0, …)` and pins the calling thread; macOS and Windows return `error.Unsupported`; a kernel refusal returns `error.PinFailed`. It never reports success it did not achieve. `spawn` has no `.affinity` field.
- `src/core/TransactionalEvent.zig` is removed. It was a 249-line stub whose functions were `_ = event;` and never a public export; only path imports break. Use `zmodu.outbox.*` or `zmodu.SagaOrchestrator`.
- `PrecisionTimer`'s 10 µs median bound depends on the host. On a shared runner or container, run its measurement test first and raise `spin_window_ns` (or set `0` to opt out). The 5 ms `Runtime` timer wheel is unaffected. `batch` stays at 16: measurement rejected only `1`, and 8/16/32/64 share one noise band. The pooled-worker latency tail comes from `idle_wait_ms = 1` polling, not `batch`.
- Delivery-log persistence: `src/runtime/delivery_log.zig` exists but is not exported from `runtime.zig`/`root.zig` and has no consumer, so `Runtime Replay` still cannot cross a process or a restart. `ReplayFromLog` is load-then-replay, needs a codec, rejects holes with `error.LogHasHoles` unless `allowHoles()` is called, and holds an allocator. Bind with `setCodec(id, C, E)` and `bindDecoded(id, handle)`; use `DeliveryLog.setCodecRef(track, C, E)` for tracks declared through `Runtime.spawn(.record)`.
- `Handle.after` records `.timer` and `send*` records `.message`. `Track.record(event)` is unchanged and equals `recordKind(..., .message)`; use `Track.recordKind(event, kind)` to choose. Replay from disk always delivers `.message`; the recorded kind stays on `LogStep.kind`. `Replayer.bind` no longer rejects a track that declared a codec, and `BindError` no longer has `error.CodecRequired`.

## v0.33.4 and v0.33.5

Compile errors:
- **Password verification returns `PasswordError!bool`** (`error{MalformedStoredHash} || std.mem.Allocator.Error`) from `PasswordEncoder.matches` and `SecurityModule.verifyPassword`. An undecodable stored hash or an allocation failure is no longer reported as "wrong password".

```zig
const ok = encoder.matches(input, stored) catch |err| switch (err) {
    error.OutOfMemory => return err,                                    // → 5xx
    error.MalformedStoredHash => { log.err("unusable stored hash", .{}); return err; },
};
if (!ok) return unauthorized();
```

The stored hash length must now equal the derived key length exactly; the old prefix comparison accepted a valid 32-byte digest followed by one byte of garbage.

- **`Middleware.attachIdentityBestEffort` returns `!void`** and fails closed: `try attachIdentityBestEffort(ctx, claims, alloc);`. Normal `http.addMiddleware(http.jwtAuthFromCatalog(...))` wiring needs no change.
- **`EventBus(T).subscribe` returns `!void`**: `try bus.subscribe(MyEvent, handler);`. Module listeners use `ApplicationModuleListener.subscribe()`, which already returned `!void`.
- **`RedisCluster.init(allocator, io)`** — the old implementation used `std.testing.io`, a compile error outside tests.

Behaviour changes:
- Redis infrastructure failures raise instead of returning `false`, `0` or `-1`; real server answers keep their meaning. A form with more fields than `Server.Config.max_params` returns 400 instead of 200 with an empty form, and allocation failures while parsing return 500.
- `CachedConn` treats a corrupt cache entry as a miss, re-queries and repairs it. `BufferPool.acquire` returns `error.Canceled`; `release` / `available` / `stats` wait instead of returning fabricated readings, as do `HttpClient.ConnectionPool.release` / `discard`.
- Auth middleware: token failures 401, our-side failures 500, unknown `kid` 401 plus a warning. `authFromCatalog` fails the request on our-side errors, including on `.public` / `.optional` routes. API key comparison is constant-time.
- `SkillRegistry.register` replaces duplicates and returns errors instead of panicking; `ProviderRegistry.register` retires the replaced provider until `deinit` (`retiredCount()`).
- `MemoryStore.loadJson` / `loadFromFile` reject an unusable scope (`error.InvalidMemoryScope`); `recall` reads `0` as "any scope", so the old default leaked rows across tenants.
- `PrometheusMetrics` freezes after the first scrape or `freeze()`: late `create*` returns `error.Frozen`, and duplicate names across the exposition return `error.DuplicateName`. Append label values with `getCounter` / `getGauge`.
- `WebSocketClient.sendText` / `sendJson` return `{error.NotConnected, error.WriteFailed}`; a failed pong write closes the connection.
- Cluster callbacks are edge-triggered: one `leave` per `join`, `on_leader_change_cb` only on a real change, recovery fires `on_node_join_cb`.
- `IntegrationTest.InstrumentationContext.init(self, allocator) !void` constructs in place; `instrumentation` is `?*InstrumentationContext`.
- Lock waits that swallowed cancellation now wait or return `error.Canceled` (`EventBus`, `EventStore`, `cache.Lru`, `Runtime.shutdown`, `Mailbox`, the redis pool, `ai` key pool / memory / skill / audit / quota). The `src/ai/*` lock errors `LockFailed`, `RegistryLockFailed`, `QuotaLockFailed`, `RateLimitLockFailed` are now `error.Canceled`.
- `AgentAuditLog` has a public `owned: []bool` field; use `AgentAuditLog.init`. MySQL returns a mapped error when fields exist without metadata. `OutboxConsumer` dead-letters unparsable rows (`status = 3`).

## v0.33.3

- **`Cursor.next` returns `errors.ResultT(?*Row)`** (compile error). Mid-stream driver errors were folded into `null`, so a truncated result looked complete. `while (cursor.next()) |row|` → `while (try cursor.next()) |row|`; `cursor.next() == null` → `(try cursor.next()) == null`.
- **`csrf()` requires `CsrfConfig` on `user_data`** (runtime panic). `csrf()` is `csrfWith(.{})`, and a manual `mw.func(ctx, next, null)` panics; pass `mw.user_data`. `X-Forwarded-Host` / `Proto` are not trusted by default; behind a proxy use `csrfWith(.{ .trust_forwarded_host = true })` and overwrite both headers on every request. `sign_key` makes the cookie token `nonce.HMAC-SHA256` (`csrfMintSignedToken`).
- `sqlx.Builder` reports allocation failures from `toSql()` instead of silently dropping a `where` / `join` / `groupBy` / `having` / `orderBy` / `selectColumns` clause. Signatures are unchanged.
- `OtlpExporter` and `SecretsManager` hold a long-lived `HttpClient`; `max_connections` is per instance. Do not `deinit` while requests are in flight.
- H2 reaches parity with H1: form bodies (with `max_params`), `path_rewriter`, query splitting from `:path` (400 when it cannot split), and a per-request `ctx.allocator` arena. `ctx.stream` is still `null` on H2, and streaming handlers get 501.
- H2 sends handler response headers. Connection-specific fields (`connection`, `keep-alive`, `proxy-connection`, `transfer-encoding`, `upgrade`) are dropped with a warning, a mismatched `content-length` is dropped, and fields over the peer's header budget are dropped with a warning.
- h2c upgrade dispatches the upgrading request as stream 1 after applying `HTTP2-Settings`, and methods other than `GET` are allowed. `HEAD` responses carry no body (H1's `startChunked` path and `writeErrorResponse` still write one). H1 writes a single `Content-Length`, and only when it matches the body.
- Two `Server` instances in one process are isolated: OpenAPI state is keyed by `*CatalogSlot`, the permission table by `RolePermissionTable` pointer. Both loaders are wiring-time APIs with fixed pools (64 and 16 slots) and return `error.SlotPoolExhausted` when exhausted; do not call them in a loop or on the request path.
- PG: allocation failure returns `error.OutOfMemory`, not `error.DatabaseError`.

## v0.33.1

- Validation middleware options `structured_errors` and `message_hook` (`withStructuredErrors()`, `withMessageHook()`). With structured errors, a 422 carries `errors: [{field, rule, message}]` in `data` and the first message in `msg`. `Validator.validateStructCollect` returns all violations; `Validator.MessageHook` localises default rule messages. Defaults are unchanged: flat string messages, business code 4220.
- New `zig build soak-cluster`, an `alloc/op` CI gate for the benchmark suite, and the first fuzz targets (`zig build --fuzz test`).

## v0.32.0

- **WebSocket routes must declare `.meta.auth = .public`** (compile error). WS upgrades are answered before `router.match` and before global middleware, so `auth` / `permission` / `roles` on `ws_routes` have no execution point. Verify identity in `on_connect`.

```zig
pub const ws_routes = [_]http.WsSpec(State){
    .{ .path = "ws", .on_connect = …, .on_message = …, .meta = .{ .auth = .public } },
};
```

A missing `.meta`, a non-`.public` auth, or `permission` / `roles` all fail to compile. Scaffolded IM gateways default `ImGateway.verifier` to `null` and reject connections until a verifier is set.

- **CSPRNG uses `std.Io.randomSecure(io, buf)`** (compile error). The old seed was milliseconds, a constant, a stack address and milliseconds × 1000 — public, low-entropy and shared inside the process. Entropy entry points now take `io`; failure is `error.EntropyUnavailable` with no fallback.

```text
Old                                          New
ApiKeyGenerator.generate(allocator)          ApiKeyGenerator.generate(allocator, io)
PasswordEncoder.init(allocator)              PasswordEncoder.init(allocator, io)
PasswordEncoder.initWithIterations(a, n)     PasswordEncoder.initWithIterations(a, io, n)
kit.random.uuid(allocator)                   kit.random.uuid(allocator, io)
```

`std.crypto.random` does not exist on this toolchain. Do not substitute `std.Io.random`, which falls back to pid + wall clock + ASLR on failure.

- **`db.query` rejects a tenant context without a declared column** (runtime rejection). With a tenant context the statement is wrapped: `SELECT * FROM ( <model SQL> ) AS _zt_tenant_scope WHERE _zt_tenant_scope.<col> = ?`. The tenant value is bound as `?` and never enters the SQL text. No declared column → `error.TenantScopeUnavailable`. Multi-tenant applications must use `ai.business.registerBusinessSkillsWith(&registry, &.{}, .{ .db_query_tenant_column = "tenant_id" })`, and the SELECT must include the tenant column.
- **Request boundary hardening** (behaviour change plus signature change). A valid header with no space (`Host:x`, `Content-Length:5`) is now parsed instead of dropped. `Transfer-Encoding` returns 400; this server has no chunked request decoder. Conflicting, duplicate or non-decimal `Content-Length`, or `CL` plus `TE`, returns 400. An unknown method, including legitimate extensions such as `PROPFIND`, returns 501. A request line without three parts or a version other than `HTTP/1.x` returns 400. `http.Method.fromString` returns `?Method`, with `null` for unknown.
- **Three defaults became fail-closed.** `.dept_custom` with empty or unparsable `dept_ids` sets `deny_clause = "1 = 0"`; only `.all` produces `null` (no filter). `permissionGateWith` keeps its configuration per call instead of in a function-level global, and an empty catalog denies. `tenantClause` parenthesises the caller's predicate, so `owner_id = ? OR is_public = 1` no longer lets the tenant predicate bind to one branch.
- `RaftElection.handleAppendEntries` adds `error.InvalidLogIndex` (compile error only for exhaustive `switch`). It fixes an unsigned underflow on `entry.index == 0`.
- **Multi-node `.peers` entries need `@id`** (startup rejection). `.peers = &.{"node-b@127.0.0.1:9001"}`; a missing id on a cluster with `raft_cluster_size > 1` returns `error.PeerIdRequired`. Single-node clusters need no change. `PeerDiscovery.Peer` gained an `id` field.

## v0.28.0

`Runtime.cancelTimer(id) bool` is removed and split in two.

```zig
// Old: "it is still pending" — no longer expressible after the ticker rewrite
if (rt.cancelTimer(id)) { ... }

// Hot path: the request is handed to the runtime, effective after about one tick (5 ms)
try rt.requestCancelTimer(id);

// Control plane: waits for the owner to execute, returns the final result
if (try rt.cancelTimerSync(id)) { ... }  // true = pending at call time
```

`after` now means "at least `delay_ms` from the call", with an upper bound of `delay_ms` + enqueue delay + `tick_interval_ms`. A full command queue returns `error.Full` instead of dropping the timer.

## v0.27.0

- `zmodu audit` and `zmodu ci` audit nested modules (`src/modules/a/b/…`, including `--with-agent` output). Re-run `zmodu audit .` after upgrading and fix new findings; use `// audit: ignore <rule>` for a false positive.
- Route state comes from `ctx.state(T)`, which returns `error.NoRouteState` instead of letting `orelse unreachable` become UB in ReleaseFast.

```zig
// Old — b4 reports this
const self: *MyApi = @ptrCast(@alignCast(ctx.user_data orelse unreachable));
// New
const self: *MyApi = ctx.state(MyApi) catch return null;
```

- Generated scaffolds log swallowed audit and relay failures with `std.log.warn`, and tenant `update` / `delete` return 404 when no rows matched (events only when `rows > 0`). Regenerate.
- Scaffolded `shared/response.zig` wrote an invalid success envelope; regenerate. Scaffold output is now reproducible: `.fingerprint` is derived from the package name.
- `sqlx.Transaction` gains the `Client` method set: `queryRowsPartial(Ctx)`, `queryScalar(Ctx)`, `queryRowBorrowed(Ctx)`, `queryRowPartialBorrowed(Ctx)`, `findOne(Partial)(Ctx)`, `findAll(Partial)(Ctx)`, `batchExec(Ctx)`, `ping(Ctx)`, plus `*Ctx` forms of `queryRow`, `queryRowPartial` and `queryRows`.
- `src/persistence/Database.zig` is removed. Use `data.sqlx` or `data.Repository` (`Orm(Backend)`).

## v0.25.0

- `ClusterBootstrap.tick()` also drives `raft.tick()`: one call runs `membership.runOnce()` → `view.sync()` → `raft.tick()`. With `.transport` set, `start()` listens on `config.port` (`error.RaftInboundListenFailed` if it cannot bind). Do not give the same port to `DistributedEventBus.start(port)`. Run `tick()` on a timer with `worker.after(1000, .tick)` and call `cluster.tick()` from the worker's handler.
- Raft counts peer votes only and does not count its own twice; a single-node cluster elects itself on the first election.
- `SagaStep.timeout_seconds` is enforced: an over-budget step is persisted, compensated in reverse order including itself, ends in `.timed_out`, and returns `error.SagaStepTimeout`. `0` disables the budget. `run` callers must handle the new error.
- New `zmodu.TransactionJournal` for in-doubt transactions: append-only, INSERT-only, dialect-neutral, in-memory when no backend is configured, and fail-closed once a backend is set. `recover()` reports "prepared with no outcome" and does not retry or roll back.

## v0.24.0

- `examples/testing/`, `examples/deprecated/`, `examples/cluster-demo/` and `examples/example_tests.zig` are removed; their content moved into `examples/basic/src/tests.zig` and `examples/distributed/README.md`. `zig build test -Dexample=testing` → `zig build test -Dexample=basic`.
- `build.zig.zon` sets `minimum_zig_version` to `0.17.0`; older toolchains are rejected by Zig.

## v0.23.0

- **Multi-node `ClusterBootstrap` is fail-closed.** With `raft_cluster_size > 1` (the default is 3), `start()` returns `error.RaftTransportUnavailable` unless one of three options is set: a real transport, an explicit acknowledgement that elections happen elsewhere, or single-node mode.

```zig
var cluster = try zmodu.ClusterBootstrap.init(allocator, io, .{
    .node_id = "node-1",
    .port = 9000,
    .transport = my_raft_transport,          // real transport
    // .allow_stub_raft_transport = true,    // or: elections happen elsewhere
    // .raft_cluster_size = 1,               // or: single node
});
```

- `RaftTransport` (`src/core/cluster/RaftTransport.zig`) implements the wire format (4-byte length prefix, 1-byte tag), the peer-to-address book, outbound votes and log replication, and inbound dispatch with replies on the same connection. A custom transport only needs to send; `ClusterBootstrap.start()` listens and dispatches. `NetworkTransport.connect` is dead code.

## v0.22.0

- `ctx.runtime()` is the only way a module creates workers or timers. `Application.stop()` joins workers before stopping modules; a bare `Lifecycle.startAllWith` harness returns `error.RuntimeUnavailable` instead of creating a runtime. The first call starts the ticker, and modules must not call `Runtime.init` or `rt.shutdown()`.

```zig
pub fn initWith(ctx: *zmodu.ModuleContext) !void {
    const rt = try ctx.runtime();   // the application runtime
    _ = rt;                         // rt.spawn(...) / handle.after(...)
}
```

- `skill.Tool.action` defaults to `.execute`. Read-only tools must declare `.action = .read` or `.propose`, or `allow_execute = false` policies reject them.
- `Agent.memory` injects memory for the run's tenant and user. A missing or zero identity injects nothing, because `recall` treats `0` as "any scope". Do not feed agents through `MemoryStore.formatContext`.
- `src/test/DocSnippets.zig` checks fenced `zig` blocks in docs and doc comments. The most common failure is chaining builder methods onto the `zmodu.builder(…)` temporary, which is `*const`: bind it first with `var b = zmodu.builder(allocator, io); defer b.deinit();` and call `b.withName(…).build(…)`.

## v0.15.46

- **Upload content policy** (optional). `http.Multipart` only enforced size, so applications reimplemented content checks, usually with one of three holes: extension only, `Content-Type` only, or SVG allowed.

```zig
const mp = zmodu.http.Multipart.Config.forBodyLimit(64 << 20);
var form = try zmodu.http.extractMultipart(ctx, mp);      // 415 / 413 / 400 → ProblemDetails
defer form.deinit();
try zmodu.http.UploadGuard.checkForm(&form, .{
    .extensions = &.{ "jpg", "jpeg", "png" },
    .formats = &.{ .jpeg, .png },
    .max_bytes = 5 << 20,
});
```

Check order decides the error: size → active content (SVG/HTML rejected by default) → extension allowlist → format allowlist → extension/content agreement. `http.extractMultipart` maps failures to ProblemDetails: 415 (not multipart), 413 (too large), 400 (missing boundary, malformed, too many parts).

- `Multipart.Config.forBodyLimit(n)` aligns `max_total_bytes` with `max_body_size`. The server rejects `content_len > max_body_size` (default 8 MB) before `Multipart.parse` runs, so the default `max_total_bytes` of 32 MB never triggers on its own.
- `ctx.paramPath` is deprecated in favour of `ctx.nestedParam` (removal no earlier than 1.0). The names differ by source:

| Call | Reads |
|---|---|
| `ctx.param` / `ctx.pathParam` | Route placeholders only (`/orders/{id}`) |
| `ctx.queryParam` / `ctx.formValue` | Query only / form only |
| `ctx.requestParam` | Form first, then query |
| `ctx.nestedParam` (was `ctx.paramPath`) | Dotted paths in form/query (`filter.tags`) |

- `ctx.route_template` always has a leading slash. Dashboards and alerts filtering on the old shape (`orders/{id}`) must add the slash.
- `CircuitBreakerRegistry.breakers` is `std.StringHashMap(*CircuitBreaker)`; pointers stay valid across rehashes and access is locked. `count()` is new and `generateReport()` returns real JSON.
- `RateLimiterRegistry` gains `max_keys` (via `initWithCapacity`), LRU eviction, `remove(name)`, `retain(max_idle_seconds)` and `generateReport()`. `max_keys = 0` keeps the old behaviour, but registries keyed by IP should set a bound.
- `ShardRouter.ShardedQuery` is removed (it only returned `error.NotImplemented`). `PluginManager.loadPlugin` logs a warning and reports `dynamicLoadingSupported() == false` instead of doing nothing silently. `http.AccessLog` / `http.HttpMetrics` share `SpinLock`.

## v0.15.45

- **RFC 7807 error bodies** (opt-in). Framework errors used to come in three shapes, only one of which could be hooked. Call once at startup: `zmodu.http.useRfc7807Errors();` — chain plus pre-router, `application/problem+json`. Partial wiring: `setDefaultReject(http.problemReject)`, `setTransportErrorRenderer(http.problemTransportBody)`, `setDefaultReject(null)` to reset. Per gate: `.reject = problemReject` or `.reject = envelopeReject(.thinkphp)`; `ModuleGateConfig` gained `reject` and `.unknown = .deny` still works. Per response: `ctx.sendErrorEnvelope(status, code, msg)`. With this enabled, chain-tail middleware that rewrites the 404 body can be deleted. `ProblemDetails.toJson` escapes strings, and `statusTitle` covers 402/411/413/414/415/416/418/428/431/451/501/505/507.
- **Handler-side permission matching.** When a route meta uses OR (`portal:user|portal:shop`) and the handler needs to know which side it is on, reuse the same expression instead of narrowing one branch: `ctx.permissionMatches("portal:user|portal:shop")`. For exactly a gate's semantics (`.rbac` prefers AuthInfo when present) use `zmodu.http.permissionMatchesWith(ctx, "portal:shop", .{ .mode = .rbac })`. `ctx.permissionsCsv()` is new alongside `ctx.rolesCsv()`.
- Redis client: framed RESP reads, a lock on the shared no-pool stream, working `read_timeout_ms` / `write_timeout_ms`, and a connection that fails to parse is closed and removed from the pool.
- `RateLimiterRegistry.limiters` is `std.StringHashMap(*RateLimiter)`; read through `get` / `getOrCreate` rather than the field. `RateLimiter.acquire` is deprecated in favour of `tryAcquire` (it never waited); removal is no earlier than 1.0. `ProblemDetails.statusTitle(418)` is `"I'm a Teapot"` rather than `"Unknown Error"`.

## v0.15.36 – v0.15.41

- `Auth` gains `.optional` in v0.15.41: verify the token when present, ignore failures, never return 401. Use it for public endpoints that personalise when a user is known instead of hand-writing a best-effort check in a `.public` handler.
- Use `ctx.route_template` for metric labels, not `ctx.path`. `path` contains ids and blows up Prometheus cardinality.
- Connection-level backpressure and slow-connection protection are on by default; `max_connections`, `over_limit_response` and `header_timeout_ms` are described in [BEST_PRACTICES.md](../guide/BEST_PRACTICES.md) under "resilience".

## Release template

The cycle section is headed `## v<previous release> (unreleased batch)` and points at CHANGELOG's `[Unreleased]` entry. At release the heading becomes `## v<new version>` and in-body `[Unreleased]` references are repointed.

Each entry records `Breaking?` (and what stops compiling or changes behaviour), scope (which call sites and version range), and the one-line fix. A rename or deprecation entry must also complete the three steps in Adding a deprecation. The release before a removal announces it here and in that version's entry.
