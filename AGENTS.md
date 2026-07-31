# ZigModu — AI Agent Guide

## Quick Reference

```zig
const zmodu = @import("zigmodu");

// Domain imports (canonical)
const http = zmodu.http;       // Server, Context, RouteGroup
const data = zmodu.data;       // SQLx, ORM, Cache, Redis
const sec  = zmodu.security;   // Auth, RBAC, Secrets
const obs  = zmodu.observability; // Metrics, Tracing, Logging

// Module definition (required contract)
pub const info = zmodu.api.Module{ .name = "my-module", .description = "...", .dependencies = &.{} };
pub fn init() !void { ... }
pub fn deinit() void { ... }

// App builder
var app = try zmodu.builder(allocator, io).withName("app").build(.{ModuleA, ModuleB});
defer app.deinit();
try app.start();
defer app.stop();

// Built-in Codegen & MCP CLI (tools/zmodu)
// zig build zmodu -- scaffold --sql schema.sql --name my_app
```


## Critical Rules (MUST follow)

### Zig 0.17.0 — what's REMOVED
| Removed | Replacement |
|---------|-------------|
| `std.Thread.sleep()` | busy-loop or `std.Io.sleep()` |
| `std.Thread.Mutex` | `std.Io.Mutex` — needs `io` param: `.lock(io)` / `.unlock(io)` |
| `std.Thread.WaitGroup` | no replacement; use `std.Io.Group` |
| `std.time.milliTimestamp()` | `@import("core/Time.zig").monotonicNowMilliseconds()` |
| `std.time.microTimestamp()` | same |
| `std.os.getpid()` | `@intFromPtr(&seed)` for entropy |
| `std.fs.cwd()` | `std.Io.Dir.cwd(io)` |
| `std.fs.File` | `std.Io.File` — needs `io` param everywhere |
| `std.posix.empty_sigset` | `std.posix.sigemptyset()` |
| `sigaction()` returns error | returns `void` in Zig 0.16 |
| `ArrayList(T).init(alloc)` | `ArrayList(T).empty` + pass allocator to each method |
| `file.writeAll(data)` | `file.writeStreamingAll(io, data)` |
| `buf.writer(allocator)` | `allocPrint + appendSlice` pattern |
| `std.hash.crc.Crc32Iscsi` | `std.hash.crc.@"CRC-32/ISCSI"` (0.17-dev≈1422+); use `@hasDecl` shim if supporting both |

### Zig 0.17.0 — patterns to USE
```zig
// ArrayList: .empty + explicit allocator
var list = std.ArrayList(T).empty;
defer list.deinit(allocator);
try list.append(allocator, item);

// Mutex: needs io
var mu: std.Io.Mutex = .init;
mu.lock(io) catch return;
defer mu.unlock(io);

// File I/O: always pass io
const file = try std.Io.Dir.cwd(io).createFile(io, path, .{});
defer file.close(io);
try file.writeStreamingAll(io, data);

// Env vars: use init.environ_map in main (Zig 0.17 Init)
if (init.environ_map.get("HTTP_PORT")) |p| { ... }

// Time: always use Time.zig
const now = Time.monotonicNowSeconds();
const now_ms = Time.monotonicNowMilliseconds();
```

## Architecture Rules

### HTTP routing (ComptimeRouter — preferred)
- Modules declare `pub const routes` + `module_name` + `nest`; wire with `http.Router.scope.mountAll`
- Auth stack: `jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.{ .mode = .rbac })`
- Permissions: static `Rbac.RolePermissionTable` or DB `CatalogPermDb.loaderFromClient`
- Multi-portal / PHP-compat: app-level identity issuer; map into `auth_info`/attrs — `docs/ROUTE_TABLE.md` §7.1 (no framework `type` claim)
- Legacy `rbacJwtMiddleware` / `jwtAuth` now write **`auth_info` only** (safe with ComptimeRouter State); prefer catalog JWT+RBAC for new apps; never `@ptrCast(user_data)` as AuthInfo
- Guide: `docs/ROUTE_TABLE.md`
- **Extractors**: `http.extractPath` / `extractQuery` / `extractJson` / `extractJsonValidated`; field defaults apply when missing
- **Errors**: `http.respondErr` + optional `http.setErrorMap`; RFC 7807 ProblemDetails
- **Scope middleware**: `RouteGroup.use(mw)` or `http.Scoped(...).use(mw)` before `mount` / route methods
- **Testkit**: `dispatch` / `dispatchOpts`, `signBearerToken`, `openMemorySqlite`, `tenantMiddleware`, `SseRecorder`
- **SSE**: `http.sse(ctx)` + `SseSpec` / `sse_routes` or `RouteMeta.sse = true`
- **Profiles**: `applyHttpDefaults` (CORS/requestId/recover/access/metrics) + `applyResilienceDefaults` (named CB/RL)
- **OpenAPI**: `openApiParamsFromStruct` + `RouteMeta.openapi_params` (merged in catalog export)
- **Outbox barrel**: `zigmodu.outbox.*`; idempotency → `http.idempotencyMiddleware` (header `idempotency-key`)
- Backlog status: `docs/FRAMEWORK_BACKLOG.md`

### Imports
- NEVER use `zigmodu.http_server` — use `zigmodu.http.Context`
- NEVER use `zigmodu.orm.Orm(...)` — use `zigmodu.data.Repository(T)`
- NEVER use `zigmodu.PasswordEncoder` — use `zigmodu.security.PasswordEncoder`
- Domain files are CANONICAL: `http.zig`, `data.zig`, `security.zig`, `observability.zig`

### Module lifecycle
```zig
// Every module MUST satisfy this contract:
pub const info = zmodu.api.Module{
    .name = "order",
    .description = "Order management module",
    .dependencies = &.{"user", "product"},  // module names, NOT import paths
};

pub fn init() !void {
    // Called at startup in dependency order (deps before dependents)
}

pub fn deinit() void {
    // Called at shutdown in REVERSE dependency order
}
```

### Error handling
- Use `ZigModuError` from `zmodu.ZigModuError` (NOT raw `error{...}`)
- Log errors — never `catch {}` on I/O or DB operations
- Use `zmodu.Result(T)` for fallible operations

### Security
- Passwords: `sec.PasswordEncoder` (PBKDF2-HMAC-SHA256, 100K iterations)
- JWT: `sec.AppSecurity.init(allocator, io, .{ .jwt_secret = ... })` + `jwtMiddleware()` (wall clock); RBAC via `sec.auth.jwtAuth`
- Secrets: `sec.SecretsManager` (env > file > vault KV v2 HTTP > default); `initWithIo` + `configureVault` / `loadFromVault`
- CSRF: `http_middleware.csrf()` double-submit cookie pattern
- CSPRNG: multi-source entropy, never single-timestamp seed

### Multi-tenancy (optional)
- Default SQL/model column is `tenant_id`. ZigShop-style schemas use `app_id` — call once at startup:
  ```zig
  zigmodu.setTenantColumn("app_id");
  ```
- Model field name must match the column (`app_id: i64`). `TenantInterceptor` appends `{column} = ?` via `tenantColumn()`.
- Codegen: `zmodu scaffold|orm|add --tenant-column app_id` emits matching `WHERE` and scaffold `main` calls `setTenantColumn`.
- Details: `docs/ARCHITECTURE.md` § Multi-Tenancy; CLI: `docs/ZMODU_CLI_INTEGRATION.md`

## Generated Code Patterns

### HTTP API handler
```zig
const http = @import("zigmodu").http;

pub fn registerRoutes(group: *http.RouteGroup) !void {
    try group.get("/users/{id}", getUser, null);
}

fn getUser(ctx: *http.Context) !void {
    const id = try ctx.paramInt("id");
    const page = ctx.queryInt("page", 0);
    // Use ctx.json(200, body) — NOT ctx.sendSuccess/sendFail (deprecated)
}
```

### Database
```zig
const data = @import("zigmodu").data;

// One-step init (preferred)
var db = try data.Client.open(allocator, io, .{ .driver = .sqlite, .path = "app.db" });
defer db.deinit();

// Repository pattern
const repo = data.Repository(model.User){ .backend = backend };
const users = try repo.list(page, size);
```

### Events
```zig
var bus = zmodu.EventBus(MyEvent).init(allocator);
try bus.subscribe(myHandler);
bus.publish(.{ .id = 42 });
```

## File Organization
```
src/modules/{name}/
├── model.zig          # Structs, table mappings
├── persistence.zig    # Repository / data access
├── service.zig        # Business logic
├── api.zig            # HTTP handlers (registerRoutes)
├── events.zig         # EventBus types + publisher
├── module.zig         # Module lifecycle + dependencies
└── root.zig           # Barrel re-exports
```

## Testing
```zig
test "my test" {
    const allocator = std.testing.allocator;
    // Use std.testing.io for I/O-dependent tests
    // Use std.testing.tmpDir() for file-dependent tests
}
```

## Version
- Framework: **v0.14.16** (`build.zig.zon`)
- Zig: **0.17.0**
- Tests: **664+ passed**, 20 skipped, 0 failed (`ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`)
- Roadmap: `docs/PRODUCTION_ROADMAP.md` (phases 1–9 ✅)
- Modulith day-one practices: `docs/MODULITH.md`
- Domain layering (model / persistence.Tx / service Cmd): `docs/MODULE_LAYERS.md`
- Built-in Tooling: `tools/zmodu` (run with `zig build zmodu`) · guide `docs/ZMODU_CLI_INTEGRATION.md`
- ZigModu × zent (orthogonal ORM): `docs/ZENT.md` · example `examples/zent-modulith/`
- Declarative HTTP routes: `docs/ROUTE_TABLE.md` — Zig-native comptime `routes` + `Router(State)` + `std.Io`; scaffold emits RouteSpec via `zmodu scaffold`
- Score: ~98/100 (`docs/EVALUATION_REPORT.md` v5.6)

## Learned User Preferences

- Respond in 中文 for user-facing communication.
- Do not create git commits unless the user explicitly asks.
- Prefer the production-readiness plan without physically splitting `sqlx.zig` or `Server.zig`; use section comments plus `docs/PRODUCTION_ROADMAP.md` maintenance boundaries instead.
- When generating framework code from SQL scripts (zmodu), follow zigmodu best practices for complete module output and place reusable templates in a dedicated templates folder.
- When refining architecture or best practices, land them in docs (`docs/ZENT.md`, `MODULITH.md`, `MODULE_LAYERS.md`, `BEST_PRACTICES.md`) rather than chat-only advice.
- When restructuring examples, preserve existing domain/business logic unless explicitly asked to change it.

## Learned Workspace Facts

- Project targets Zig 0.17.0; package version **v0.14.16** (`build.zig.zon`; GitHub `chy3xyz/zigmodu`, default branch `master`).
- If Zig global cache fails in sandboxed runs, use `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`.
- Production roadmap and monolith maintenance rules live in `docs/PRODUCTION_ROADMAP.md`.
- Current test baseline: **664+ passed**, 20 skipped (`ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`).
- x402 payment verify is **fail-closed** by default; inject `PaymentVerifier` / `verifyPaymentAllowAll` only for explicit dev paths.
- OTLP: `observability.OtlpExporter.exportSpans` POSTs JSON over `http://` with retries; `https://` → `OtlpTlsNotSupported` (same boundary as Vault).

- Optional data stack: [chy3xyz/zent](https://github.com/chy3xyz/zent) (v0.12+) is orthogonal to `data.sqlx` — modules may choose either independently, but do not mix drivers or share a transaction across them; see `docs/ZENT.md`.
- zent reference apps: `examples/zent-modulith/` (minimal) and `examples/metaverse-creative/` (settlement/outbox creative-monetization demo).
- gRPC / HTTP/2：stream 四种 + pump；PRIORITY 存储；h2c Upgrade；WINDOW_UPDATE/SETTINGS；`Http2Tls` sidecar ALPN
- Kafka CG：FindCoordinator + Metadata + assignor（含 cooperative_sticky）+ `acknowledgeRevocation` 两阶段
- CI：`bash scripts/ci-integration.sh`（tenant-mgmt + stress + shopdemo）
- Kafka Consumer Group: offline solo 或 live `joinGroup`/`heartbeat`/`leaveGroup`（需 `KAFKA_BOOTSTRAP`）
- Vault secrets: `security.SecretsManager` supports HashiCorp KV v2 over plain HTTP (`initWithIo` + `configureVault` / `loadFromVault`); `https://` returns `VaultTlsNotSupported`.
