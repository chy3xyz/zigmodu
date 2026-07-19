# CLAUDE.md — ZigModu Framework for Claude Code

## Project
ZigModu v0.14.1 — modular app framework for Zig 0.17.0. ~149 src files, 455 tests, ~95/100.

## Build & Test
```bash
zig build
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test   # 455 passed, 12 skipped
zig build check-api                                    # examples API gate
bash scripts/ci-integration.sh                         # tenant-mgmt + stress (HTTP_PORT=18080)
zig build docs
```

## Architecture (5 domain files)
```
src/http.zig          → zmodu.http.{Server, Context, RouteGroup, Middleware}
src/data.zig          → zmodu.data.{Client, sqlx, orm, Repository, redis}
src/security.zig      → zmodu.security.{SecurityModule, PasswordEncoder, SecretsManager}
src/observability.zig → zmodu.observability.{PrometheusMetrics, DistributedTracer}
src/root.zig          → Application, EventBus, deprecated flat aliases (v0.14.0 remove)
```

## Monolith maintenance (do NOT split without cause)
- `src/sqlx/sqlx.zig`, `src/api/Server.zig` — § sections + rules in `docs/PRODUCTION_ROADMAP.md`

## Zig 0.17 Rules (top 5 mistakes to avoid)
1. `ArrayList(T).init(alloc)` → `ArrayList(T).empty`, pass alloc to each method
2. `std.Thread.Mutex` → `std.Io.Mutex`, needs `io`: `.lock(io)`, `.unlock(io)`
3. `std.time.milliTimestamp()` → `Time.monotonicNowMilliseconds()`
4. `file.writeAll(x)` → `file.writeStreamingAll(io, x)`
5. Request headers are **lowercase** in `Context.headers` — use `"authorization"`, not `"Authorization"`
6. `std.hash.crc.Crc32Iscsi` → `std.hash.crc.@"CRC-32/ISCSI"` (Zig 0.17-dev≈1422+; Kafka CRC-32C)

## Code Generation Rules
- Module: `pub const info = zmodu.api.Module{...}` + `init() !void` + `deinit() void`
- HTTP: `const http = zmodu.http` — `ctx.json(status, body)` NOT `sendSuccess/sendFail`
- DB: `data.Client` via `zmodu.data` — parameterized `?` placeholders only
- Router: `*` wildcard, `{id}` path params; route paths without leading `/` in `addRoute`
- Logging: `std.log.err/warn/info` with `{s}/{d}` format, never emoji
- Deprecated root aliases: `zigmodu.http_server` → `zigmodu.http` (removed v0.14.0)

## Key Files
```
src/api/Server.zig      (~2400L) — Context, Router, Server, connFiber
src/api/Middleware.zig   (~500L) — cors, jwtAuth, csrf, requestId, recover
src/sqlx/sqlx.zig       (~3300L) — Client, ConnPool, PG/MySQL/SQLite
src/Application.zig      (~540L) — builder, run(), graceful shutdown
docs/PRODUCTION_ROADMAP.md — production phases + monolith boundaries
docs/MODULE_LAYERS.md — model / persistence.Tx / service Cmd (tenant-shop reference)
docs/MODULITH.md — day-one modulith + high-concurrency practices
```

## Examples
```
examples/tenant-mgmt/     — flagship runnable demo (CI integration)
examples/shopdemo/        — schema + generated-sample only (codegen reference)
examples/http-stress-test/  — load test binary
```
