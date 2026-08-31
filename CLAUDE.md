# CLAUDE.md — ZigModu Framework for Claude Code

## Project
ZigModu **v0.15.34** — modular app framework for Zig **0.17.0**. ~98/100 (`docs/EVALUATION_REPORT.md`).

**AI 权威指南：[`AGENTS.md`](AGENTS.md)**（文档地图 + 近期栈 DO/DON'T）。冲突时以 AGENTS 为准。

## Build & Test
```bash
zig build
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test   # 须默认 -Ddb=all
zig build -Ddb=sqlite                                  # 应用/示例收窄驱动（见 docs/SQLX_DRIVERS.md）
zig build check-api                                    # examples API gate
bash scripts/ci-integration.sh                         # tenant-mgmt + stress + shopdemo（-Ddb=sqlite）
zig build docs
zig build zmodu -- scaffold --sql schema.sql --name my_app --with-auth
```

## Architecture (5 domain files)
```
src/http.zig          → Server, Context, Router, Middleware, sse, extract*, Testkit, applyHttpDefaults
src/data.zig          → Client, sqlx, orm, Repository, redis
src/security.zig      → AppSecurity, CatalogPermDb, PasswordEncoder, SecretsManager
src/observability.zig → PrometheusMetrics, DistributedTracer, OtlpExporter
src/root.zig          → Application, EventBus, outbox
```

## AI 必守（近期升级）
1. **路由**：`pub const routes` + `Router(State).mountAll` — 见 `docs/ROUTE_TABLE.md`
2. **鉴权 Path A**：`jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.rbac)`；签发用 `generateTokenWithTenant`
3. **槽位**：`user_data` = `*State` only；鉴权在 attrs / `auth_info`；handler **勿**重复验 Bearer
4. **多门户**：JWT `roles`=门户；业务 RBAC 用自定义 `CatalogPermissionLoader(CatalogPermLoadInput)`；**勿**加 JWT `type`
5. **HTTP**：`ctx.json` / `respondErr` / extractors；**勿** `sendSuccess`/`sendFail`
6. **租户列**：默认 `tenant_id`；`app_id` → `setTenantColumn("app_id")` + `--tenant-column app_id`
7. **OTLP / Vault**：仅 `http://`；x402 **fail-closed**

## Zig 0.17 Rules（易错）
1. `ArrayList(T).init(alloc)` → `.empty` + 方法传 allocator
2. `std.Thread.Mutex` → `std.Io.Mutex` + `.lock(io)` / `.unlock(io)`
3. `milliTimestamp()` → `Time.monotonicNowMilliseconds()`
4. `file.writeAll` → `file.writeStreamingAll(io, …)`
5. Headers **lowercase**：`"authorization"`
6. `Crc32Iscsi` → `std.hash.crc.@"CRC-32/ISCSI"`

## Code Generation Rules
- Module: `info` + `init`/`deinit`
- DB: `data.Client` · 仅 `?` 占位符
- Route paths：无前导 `/`（`addRoute` / RouteSpec.path）
- Logging：`std.log.*` + `{s}/{d}`，无 emoji
- 分层：`docs/MODULE_LAYERS.md`（model / persistence.Tx / service / api）

## Key Files
```
src/api/Server.zig / Middleware.zig — HTTP + catalog JWT
src/sqlx/sqlx.zig / Application.zig — DB + lifecycle
docs/ROUTE_TABLE.md · BEST_PRACTICES.md · MODULE_LAYERS.md · MODULITH.md · ZENT.md
docs/PRODUCTION_ROADMAP.md — monolith boundaries（勿无故拆 sqlx/Server）
```

## Examples
```
examples/tenant-mgmt/       — flagship（CatalogPermDb + CI）
examples/shopdemo/          — minimal order + CI smoke
examples/zent-modulith/     — zent ORM
examples/http-stress-test/  — load
```
