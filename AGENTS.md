# ZigModu — AI Agent Guide

> **面向 AI 的权威入口。** 写代码前先读本节「文档地图」与「近期栈 DO/DON'T」。  
> 人类长文：`docs/BEST_PRACTICES.md` · 路由/鉴权细则：`docs/ROUTE_TABLE.md` §7。  
> 哲学长文（可后读）：`docs/AI_METHODOLOGY.md`（以本文为准若冲突）。

## 文档地图（按任务选读）

| 任务 | 先读 |
|------|------|
| 新模块 / HTTP API | 本文 Critical Rules + `docs/ROUTE_TABLE.md` §1–4、§7 |
| JWT / 多门户 / RBAC | `docs/ROUTE_TABLE.md` §7.1 + `docs/BEST_PRACTICES.md`「JWT / 多端身份」 |
| model / Tx / service | `docs/MODULE_LAYERS.md` |
| Day-1 并发 / 反模式 | `docs/MODULITH.md` |
| 多租户列名 | `docs/ARCHITECTURE.md` § Multi-Tenancy |
| zent ORM（电商/社交主推组合） | `docs/ZENT.md`（勿与 sqlx 混事务；§4.8 场景能力矩阵） |
| SQLx 驱动链接 | `docs/SQLX_DRIVERS.md`（`-Ddb=` / `.db=`） |
| Extract / SSE / Testkit / Outbox | `docs/FRAMEWORK_BACKLOG.md` |
| CLI 生成 | `docs/ZMODU_CLI_INTEGRATION.md` · `zig build zmodu -- scaffold …` |
| LLM 对话模块（产品功能） | `docs/AI.md`（**不是** agent 指南） |
| AI 业务接入（KeyManager/Agent/Workflow/Skill/接入） | `docs/AI_DEV_GUIDE.md` + `docs/AI_SKILLS.md` + `docs/LLM_POLICIES.md` |

## Quick Reference

```zig
const zmodu = @import("zigmodu");

// Domain imports (canonical)
const http = zmodu.http;       // Server, Context, Router, Middleware, extract*, sse
const data = zmodu.data;       // SQLx, ORM, Cache, Redis
const sec  = zmodu.security;   // AppSecurity, CatalogPermDb, Secrets
const obs  = zmodu.observability; // Metrics, Tracing, OtlpExporter

// Module definition (required contract)
pub const info = zmodu.api.Module{ .name = "my-module", .description = "...", .dependencies = &.{} };
pub fn init() !void { ... }
pub fn deinit() void { ... }

// App builder
var app = try zmodu.builder(allocator, io).withName("app").build(.{ModuleA, ModuleB});
defer app.deinit();
try app.start();
defer app.stop();

// Codegen: zig build zmodu -- scaffold --sql schema.sql --name my_app [--with-auth]
```

## 近期栈 DO / DON'T（v0.14.x 升级后 · AI 必守）

| DO | DON'T |
|----|--------|
| `pub const routes` + `Router(State).scope.mountAll` | 新模块只写 `RouteGroup.get/post` 当默认 |
| Path A：`jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.rbac)` | 应用自签 PHP 形 JWT 再在 handler 里验一遍 |
| `generateTokenWithTenant(sub, roles, aud)`；roles=门户粗身份 | 在核心 JwtPayload 加 `type` enum；JWT 塞全量菜单树 |
| 自定义 `CatalogPermissionLoader(allocator, CatalogPermLoadInput)` 接业务表 | 三套门户 RBAC 硬塞进 `CatalogPermDb` |
| Handler 读 attrs：`user_id` / `tenant_id` / `permissions` | `@ptrCast(ctx.user_data)` 当 AuthInfo；handler 重复 Bearer 验签 |
| `user_data` = ComptimeRouter `*State` only | 把 AuthInfo / JWT 对象写入 `user_data` |
| Legacy `rbacJwtMiddleware` / `jwtAuth` → 只读 `auth_info` | 新应用默认走 legacy 中间件 |
| `ctx.json` / `http.respondErr` / extractors | `sendSuccess`/`sendFail`；拼用户输入进 SQL |
| OTLP / Vault：`http(s)://`（TLS 走 `std.http.Client` 系统信任库）；x402 **fail-closed** | 默认放行支付 |
| `http.HttpClient`：`https://` 经 `std.http.Client`（OTLP/Vault/AI 出站共用；`requestStream` HTTPS 真增量） | 自签证书未入系统信任库即报 TLS 失败 |
| WS：`on_message(session, msg, kind)` — **text+binary**（`WsFrameKind`）；`writeBinary`/`writeData` | 假定只收 0x1；丢弃 0x2（会破坏 OpenIM protobuf） |
| sqlx：`Client.open` 后注意 pool/client 指针；CB 传 `io` | 在 ConnPool 上缓存失效的 `*Client` |
| sqlx 驱动链接：`-Ddb=sqlite\|postgres\|mysql\|all`（默认 `all`） | 小系统用 `.db = "sqlite"`，勿默认三库全链 |

### Selective SQL linking（消费者）

```zig
// build.zig — 只链实际用到的驱动（减小 dylib 依赖；ReleaseSmall 省几十 KB 量级）
const zigmodu_dep = b.dependency("zigmodu", .{
    .target = target,
    .optimize = optimize,
    .db = "sqlite", // 或 "postgres" | "mysql" | "sqlite,postgres" | "all"
});
```

框架自测必须用默认 `-Ddb=all`（`zig build test`）。窄化 `-Ddb=` 只适合应用/示例构建。

权威细则（取值表、stub、`DriverNotEnabled`、scaffold、symlink/Windows、体积预期）→ **[`docs/SQLX_DRIVERS.md`](docs/SQLX_DRIVERS.md)**。

权威细则与接线样例 → `docs/BEST_PRACTICES.md`「JWT / 多端身份」· `docs/ROUTE_TABLE.md` §7。

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
- Auth stack (Path A): `jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.{ .mode = .rbac })` + optional `moduleGate`
- Auth (v0.15.31+, §7.2): 非 JWT 后端用 `authFromCatalog(slot, backend)` + `AuthBackend`（内置 `jwtBackend`）；拒绝信封 `AuthRejectFn` / `envelopeReject(.thinkphp)`；handler 读 `ctx.userId()/requireUserId()/tenantId()`；信封方言 `ctx.setEnvelope` + `ok/fail/unauth/paginated`；租户 `tenantResolver`；路由级 `RouteMeta.roles`；token 提取 `extractTokenAny`；CI 审计 `Testkit.auditAuthCoverage`
- Permissions: `catalogLoaderFromTable` / `CatalogPermDb.loaderFromClient`，或多主体自定义 loader（`CatalogPermLoadInput{ sub, aud, roles }`）
- Multi-portal: JWT `roles` = 门户；业务 RBAC → `permissions` CSV + `portal:*` — §7.1（**无**框架 `type` claim）
- Attrs: middleware 写 `user_id`/`tenant_id`/`permissions`；handler **只读 attrs**
- Legacy JWT 中间件只写 **`auth_info`**；禁止 `@ptrCast(user_data)` 当 AuthInfo
- **Extractors**: `extractPath` / `extractQuery` / `extractJson` / `extractJsonValidated`
- **Errors**: `respondErr` + optional `setErrorMap`（RFC 7807）
- **Scope MW**: `RouteGroup.use` / `Scoped.use` before mount
- **Testkit**: `dispatch` / `signBearerToken` / `openMemorySqlite` / `SseRecorder`
- **SSE**: `http.sse(ctx)`（设 `streaming`）+ `SseSpec`/`sse_routes` + `lastEventId`
- **Profiles**: `applyHttpDefaults` + `applyResilienceDefaults`
- **OpenAPI**: `openApiParamsFromStruct` + `RouteMeta.openapi_params`；`openApiRoutes` / `swaggerUiHandler` / `scalarUiHandler` HTML 零配置一键挂载 UI
- **Outbox**: `zigmodu.outbox.*`；幂等 `idempotencyMiddleware`（header `idempotency-key`）
- Guide: `docs/ROUTE_TABLE.md` · recipes: `docs/FRAMEWORK_BACKLOG.md`

### Imports
- NEVER use `zigmodu.http_server` — use `zigmodu.http.Context`
- NEVER use `zigmodu.orm.Orm(...)` — use `zigmodu.data.Repository(T)`
- NEVER use `zigmodu.PasswordEncoder` — use `zigmodu.security.PasswordEncoder`
- Domain files are CANONICAL: `http.zig`, `data.zig`, `security.zig`, `observability.zig`

### Module lifecycle
```zig
pub const info = zmodu.api.Module{
    .name = "order",
    .description = "Order management module",
    .dependencies = &.{"user", "product"},  // module names, NOT import paths
};

pub fn init() !void {}   // deps before dependents
pub fn deinit() void {}  // reverse order
```

### Error handling
- Use `ZigModuError` from `zmodu.ZigModuError` (NOT raw `error{...}`)
- Log errors — never `catch {}` on I/O or DB operations
- Use `zmodu.Result(T)` for fallible operations

### Security
- Passwords: `sec.PasswordEncoder` (PBKDF2-HMAC-SHA256, 100K iterations)
- JWT (new apps): `AppSecurity` + `generateTokenWithTenant` + catalog JWT + `permissionGateWith(.rbac)`
- JWT (legacy only): `rbacJwtMiddleware*` / `sec.auth.jwtAuth*` → `auth_info` only
- Secrets: `SecretsManager`（env > file > vault KV v2）；`http(s)://` 均可，HTTPS 用系统 CA
- CSRF: `http_middleware.csrf()` double-submit cookie
- CSPRNG: multi-source entropy, never single-timestamp seed
- x402: fail-closed；dev 才注入 `verifyPaymentAllowAll`

### Multi-tenancy (optional)
- Default column `tenant_id`；ZigShop 风格用 `app_id`：
  ```zig
  zigmodu.setTenantColumn("app_id");
  ```
- 模型字段名必须与列名一致；codegen：`zmodu … --tenant-column app_id`
- JWT `aud` → catalog 中间件写 attr `tenant_id`（SQL 列名可仍是 `app_id`）
- Details: `docs/ARCHITECTURE.md` § Multi-Tenancy

### Observability / protocols (recent)
- OTLP: `OtlpExporter.exportSpans` → `http(s)://` + retries（HTTPS 经 std.http.Client）
- gRPC：unary + stream 四态；HTTP/2 priority / h2c / `Http2Tls` sidecar ALPN
- Kafka CG：assignor（含 cooperative_sticky）+ `acknowledgeRevocation`；live 需 `KAFKA_BOOTSTRAP`

## Generated Code Patterns

### HTTP — ComptimeRouter（默认生成这个）

```zig
const http = @import("zigmodu").http;

pub fn OrderApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service;
        pub const module_name = "order";
        pub const nest = .{"orders"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "{id}", .handler = getOrder, .meta = .{ .auth = .jwt } },
            .{ .method = .DELETE, .path = "{id}", .handler = cancel, .meta = .{ .permission = "order:cancel" } },
            .{ .method = .POST, .path = "login", .handler = login, .meta = .{ .auth = .public } },
        };

        fn getOrder(ctx: *http.Context, self: *State) !void {
            const id = try ctx.paramInt("id");
            // tenant: ctx.getAttr("tenant_id") — 勿再验 Bearer
            _ = self;
            _ = id;
            try ctx.json(200, .{ .ok = true });
        }
        fn cancel(ctx: *http.Context, _: *State) !void { try ctx.json(200, .{ .ok = true }); }
        fn login(ctx: *http.Context, _: *State) !void { try ctx.json(200, .{ .token = "..." }); }
    };
}

// main: CatalogSlot → jwtAuthFromCatalogWithPermissions → permissionGateWith(.rbac)
//       → router.scope.mountAll(.{ order_api, ... }) → catalog_slot.set(try router.finish())
```

### HTTP — Legacy RouteGroup（仅兼容旧代码）

```zig
try group.get("users/{id}", getUser, null); // 路径无前导 /
fn getUser(ctx: *http.Context) !void {
    const id = try ctx.paramInt("id");
    try ctx.json(200, .{ .id = id }); // NOT sendSuccess/sendFail
}
```

### Database
```zig
var db = try data.Client.open(allocator, io, .{ .driver = .sqlite, .path = "app.db" });
defer db.deinit();
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
├── model.zig          # 行形状、枚举；不写 SQL
├── persistence.zig    # 参数化 SQL；可选 pub const Tx
├── service.zig        # Cmd/Result；beginTx；写 outbox
├── api.zig            # routes / handlers；禁止 SQL
├── events.zig         # EventBus 类型（可选）
├── module.zig         # info + init/deinit
└── root.zig           # barrel
```

无 `ext/`、`handler.zig`、`service_ext.zig` 分裂层（除非既有仓库已有）。

## Testing

```zig
test "my test" {
    const allocator = std.testing.allocator;
    // std.testing.io · tmpDir · http.Testkit.dispatch / signBearerToken
}
```

```bash
# Framework tests: keep default -Ddb=all (do not narrow drivers)
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
# Apps/examples: zig build -Ddb=sqlite
bash scripts/ci-integration.sh   # tenant-mgmt + stress + shopdemo（-Ddb=sqlite）
```

## Version
- Framework: **v0.15.34** (`build.zig.zon`)
- Zig: **0.17.0-dev.1422+e863bf3be**（CI 同款锁定版本，见 `.github/workflows/ci.yml` → `ZIG_VERSION`；避免 fmt 行为漂移）
- Tests: **990/1009 passed**, 19 skipped（`ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`）
- Score: ~98/100（`docs/EVALUATION_REPORT.md` v5.6）
- Roadmap: `docs/PRODUCTION_ROADMAP.md`（phases 1–9 ✅）

### Release 流程（强制）
- 发布一律走 `bash scripts/release.sh <x.y.z> [--push]`：自动 bump 全部版本引用
  （`build.zig.zon` / `src/ai/mcp.zig` / README* / CLAUDE.md / AGENTS.md /
  AI_METHODOLOGY.md）、promote CHANGELOG `[Unreleased]`、跑门禁
  （fmt + 全量测试 + deadcode）、commit + annotated tag，收尾断言 tag 与
  包内 version 一致。
- 推 tag 前本地先过 `bash scripts/check-release-tag.sh`；CI 的 `release-verify`
  job 会在任何 `v*` tag push 时复核（tag == `build.zig.zon` version，且
  CHANGELOG 有条目）。两者任一失败 = 发布无效。
- 业务项目发布前置门禁：`zmodu ci`（build + fmt + verify + audit + deadcode）。

## Learned User Preferences

- Respond in 中文 for user-facing communication.
- Do not create git commits unless the user explicitly asks.
- Prefer the production-readiness plan without physically splitting `sqlx.zig` or `Server.zig`; use section comments plus `docs/PRODUCTION_ROADMAP.md` maintenance boundaries instead.
- When generating framework code from SQL scripts (zmodu), follow zigmodu best practices for complete module output and place reusable templates in a dedicated templates folder.
- When refining architecture or best practices, land them in docs (`docs/ZENT.md`, `MODULITH.md`, `MODULE_LAYERS.md`, `BEST_PRACTICES.md`, `ROUTE_TABLE.md`, `SQLX_DRIVERS.md`, **`AGENTS.md`**) rather than chat-only advice.
- When restructuring examples, preserve existing domain/business logic unless explicitly asked to change it.

## Learned Workspace Facts

- Package **v0.15.34** · Zig **0.17.0** · GitHub `chy3xyz/zigmodu` · branch `master`.
- Sandbox cache：`ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`.
- Auth Path A + `CatalogPermLoadInput` 已落地；legacy JWT 只写 `auth_info`。
- x402 fail-closed；OTLP/Vault 已支持 HTTPS（系统 CA）。
- zent v0.32.2 与 `data.sqlx` 正交，勿混驱动/共享事务（`docs/ZENT.md`）；`examples/zent-modulith` 按 v0.32.2 能力演示（v0.13 起向后兼容）。
- SQLx 选择性链接：`-Ddb=` / `.db=`，默认 `all`；框架测试勿收窄；见 `docs/SQLX_DRIVERS.md`。
- WS：`WsMessageFn` 含 `WsFrameKind`；fiber/io_uring 分发 text+binary（OpenIM protobuf OK）。
- CI：`bash scripts/ci-integration.sh`（tenant-mgmt + stress + shopdemo，`-Ddb=sqlite`）。
- 旗舰示例：`examples/tenant-mgmt`（CatalogPermDb）；多主体门户参考应用侧 Alignment 文档（如 ZigShop）。
