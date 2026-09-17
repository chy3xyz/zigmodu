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
| 模块间事件 / DI 注入 | `docs/EVENTS_DI.md`（`initWith(ctx)` + `app.eventBus` + freeze） |
| 多租户列名 | `docs/ARCHITECTURE.md` § Multi-Tenancy |
| zent ORM（电商/社交主推组合） | `docs/ZENT.md`（勿与 sqlx 混事务；§4.8 场景能力矩阵） |
| SQLx 驱动链接 | `docs/SQLX_DRIVERS.md`（`-Ddb=` / `.db=`） |
| 生产接线 / 背压 / 编排 | `docs/ROUTE_TABLE.md` §7.4 + `docs/BEST_PRACTICES.md`「韧性」 |
| 文件上传 / 内容校验 / 限额顺序 | `docs/BEST_PRACTICES.md`「上传与 multipart」 |
| Worker / 邮箱 / 定时器 / RingBuffer（v0.16 运行时） | `docs/RUNTIME.md`（定位、契约、背压语义、兼容 10 条） |
| 观测 / 告警 / Grafana | `docs/OBSERVABILITY.md`（黄金信号 + 阈值 + dashboard JSON；夜间 `zig build soak` 见 CI `soak` job） |
| 部署拓扑（TLS 边车/探针/守护） | `examples/production-deploy/`（nginx · Envoy · k8s · systemd） |
| Extract / SSE / Testkit / Outbox | `docs/FRAMEWORK_BACKLOG.md` |
| 故障注入 / 契约门禁模板 | `src/test/FaultInjection.zig` · `src/test/ContractGate.zig` |
| 升级注意事项（breaking / 影响面 / 改法） | `docs/UPGRADING.md` |
| 外部反馈核实与处置 | `docs/ISSUES_FROM_ZAPI.md` · `docs/ISSUES_FROM_ZIGSHOP.md` |
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
| 共享注册表：`zmodu.FrozenMap/FrozenStringMap`，启动期填充后 `freeze()` | 文件作用域裸 HashMap 在 worker 池上并发写（撕裂元数据 → 进程崩溃） |
| 错误体统一：启动期 `http.useRfc7807Errors()`（链内 + 路由前一次到位） | 写链尾中间件改 404 体（需把 `moduleGate` 降成 `.unknown = .allow`）；靠 `curl` 才发现形状不一致 |
| 单 gate 换形状：`.reject = http.problemReject`（`ModuleGateConfig` 也支持 `reject`） | 为改 404 体而放弃 `.unknown = .deny` |
| handler 问门户：`ctx.permissionMatches("portal:user\|portal:shop")`（与路由声明同表达式） | handler 重写门户检查只认一侧（OR meta 会被窄化成 403） |
| 上传：`http.extractMultipart(ctx, mp)` + `http.UploadGuard.checkForm(&form, …)` | 只查扩展名 / 只信 `Content-Type` / 放行 SVG（脚本容器 → stored-XSS） |
| 上传限额：`Multipart.Config.forBodyLimit(n)` 与 `Server.Config.max_body_size` 用同一个数 | 只设 `Multipart.Config.max_total_bytes`（服务端 8MB 先 413，它永不触发） |
| 高并发/热路径：`rt.spawn(W, init, cap)` + 邮箱（状态单线程独占，无锁）· 完整见 `docs/RUNTIME.md` | 多个线程共享可变状态再加锁；把 L0 热事件塞进 `app.eventBus`（那是 L1 业务事件通道） |
| 队列满时必须显式处理：`catch error.Full` → 丢弃/合并/退避，并读 `stats().dropped_full` | 让队列"自己长大"（邮箱容量是 comptime 有界的，`error.Full` 是唯一出口） |
| 定时器只投消息：`handle.after(ms, msg)`（在 worker 线程上处理） | 在 ticker 线程上跑业务回调（会破坏 worker 的单线程状态所有权） |
| 运行时是 opt-in：不调用 `app.runtime()` 就零线程、零定时器（v0.16 起） | 为普通 CRUD API 引入 worker（多一层，没有收益） |
| 会持续失败的 worker 用 `spawnActor` + `max_errors`/`window_ms` 预算（停 + 计数），需要现场判断就声明 `onError` | 让"每条消息都出错"的 actor 永远只记录不停止（线程活着、邮箱在收，但是个 CPU 黑洞） |
| 一个事件多个消费者且发布方不能等：`runtime.HotBus(E,N)` + 启动期 `subscribe(...)` + `freeze()` | 把 L0 扇出接到 `app.eventBus`（L1 会分配、可慢），或在热路径上自己遍历订阅者加锁 |
| 取参数：路由占位 `pathParam`；form/query 用 `requestParam`（form 优先）或 `nestedParam`（点号路径） | 以为 `ctx.param` 会回退到 query/form（它只读路由占位符） |
| 应用 root 接 `pub const panic = zmodu.panicHook`（panic 时输出当前请求 METHOD/path） | 请求路径 `catch unreachable` / `@panic`（audit b19–b21 拦截） |
| 生产配置 `max_connections` + `header_timeout_ms`（连接洪泛/slowloris）；发布前 `zig build soak` | 只设 `request_timeout_ms` 就当防住了慢连接（它只管 handler 阶段） |
| 租户来源：JWT `aud` → attr（`.tenant_source = .attr`） | 从 query 取租户（`.query` 可被客户端篡改，audit b22 拦截） |
| 生产一行接入：`http.productionProfile(&server, .{...}, &state)`（背压+安全+`/metrics`+`/health/*`+`/metrics` 黄金信号） | 在 `router.mountAll`/`addRoute` 之后再挂全局中间件（`addRoute` 注册时快照中间件链） |
| WS 出站：`Server.Config.ws_write_timeout_ms` + `WsFramer.isWritable()` 丢帧 | 对不读的慢客户端无限阻塞写（会卡住写线程与 `ConnectionRegistry` shard 锁） |
| 沙箱 CI：`zig build test -Dnet-tests=false` 跳过 socket 测试 | 在无 loopback 权限环境里跑默认套件（网络用例会失败/抖动） |
| 多副本后台任务：`cron.setLock(...)` / `runner.setLock(...)`（`zigmodu.DistributedLock`，表锁按 DB 自动分方言） | 多副本直接跑 cron / 迁移（每个副本都会执行 = 重复副作用、并发 DDL） |
| 指标标签用 `ctx.route_template`（模式）；用 `createCounterFamily` 限基数 | 把原始 path / id / 用户输入塞进 label（基数爆炸） |
| 公开但可能带身份的接口用 `auth = .optional`（有 token 就注入身份、永不 401） | 用 `.public` 后又在 handler 里手写 token 解析（或再加一条 `.jwt` 路由） |
| 启动跑 `zigmodu.Preflight.run(...)`（env/secret/DB/迁移/时钟） | 用占位 JWT secret 或默认配置上线（预检会拦，别绕过） |
| 生产接线的参考实现看 `examples/tenant-mgmt`（`productionProfile`）与 `examples/zmsaas`（Preflight + 池/积压指标） | 让示例停在上古手工接线（文档承诺、旗舰不用） |
| 换 JWT 密钥走 `JwksKeyRing` + `setKeyring`（带 kid，新旧双验） | 直接改 secret 重启（全员强制重登；或留下无法验证的旧 token） |
| outbox 用 `consumer.setMetrics` + `startPolling`；池/积压用 `metrics.setScrapeHook` | 只盯 HTTP 指标（outbox 停投、池打满在 HTTP 层完全看不见） |

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
// 应用级共享总线（ThreadSafeEventBus，Application 持有）：
// 模块在 initWith(ctx) 里取总线/注册服务；容器在 start() 完成后冻结。
pub fn initWith(ctx: *zmodu.ModuleContext) !void {
    const bus = try ctx.eventBus(MyEvent);
    try bus.subscribe(myHandler);
    const db = ctx.service(sqlx.Client, "db"); // Builder.withService 预注册
}
// 外部（handler/测试）: const bus = try app.eventBus(MyEvent); bus.publish(.{ .id = 42 });
// 单线程局部用途才用裸 EventBus/TypedEventBus（非线程安全）。
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
- Framework: **v0.17.0** (`build.zig.zon`)
- Zig: **0.17.0-dev.1970+67f39b551**（CI 同款锁定版本，见 `.github/workflows/ci.yml` → `ZIG_VERSION`；避免 fmt 行为漂移。注意 ziglang 镜像会回收旧 dev 构建——dev.1567 已 404，升级时本地先验证再改 CI）
- Tests: **以 `zig build test` 输出为准**（`ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`）。
  本文件不再抄写具体数字：`-Ddb` 收窄、平台（Linux/macOS）、门控用例都会改变计数，
  抄下来的数字必然漂移。要在文档里写数字，先跑一次并与输出核对。
  门控用例：真实 PostgreSQL 锁（`ZIGMODU_TEST_PG=1`，CI `test-postgres` job 启用）、
  `REDIS_URL` 门控的 Redis 用例。
- 其它测试入口：`zig build soak`（N 并发 × M 租户，默认 16×50；CI 夜间 64×200）·
  `zig build test -Dnet-tests=false`（沙箱里跳过全部 socket 用例）
- Score: ~98/100（`docs/EVALUATION_REPORT.md` v5.6；该报告早于 2026-09 加固批次，
  当前状态以本文件与 `CHANGELOG.md` 为准）
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

- Package **v0.17.0** · Zig **0.17.0** · GitHub `chy3xyz/zigmodu` · branch `master`.
- Sandbox cache：`ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`.
- Auth Path A + `CatalogPermLoadInput` 已落地；legacy JWT 只写 `auth_info`。
- x402 fail-closed；OTLP/Vault 已支持 HTTPS（系统 CA）。
- zent **v0.67.0**（示例按此验证）与 `data.sqlx` 正交，勿混驱动/共享事务（`docs/ZENT.md`）。v0.54 起 `CrudService.create(entity, tenant_id)` 为双参（租户是形参，不再从实体读）；v0.66 起空 `dept_ids` 拒绝而非放行、无谓词 `BulkDelete` 报 `NoPredicate`；v0.67 起无 `last_insert_id` 报 `MissingLastInsertId`、MySQL 批量改逐行；v0.57 起 MySQL 的 `String`/`Enum` 落 `VARCHAR(255)`；v0.58–0.59 `driver.Error` 新增 `ParamCountMismatch`/`PoolWaitTimeout`（**无 `else` 的穷尽 switch 会编译失败**）。**两条升级陷阱**：① `client.<entity>.deinitRow(&e)` 只适用于驱动扫描出来的行——`CrudService.get` 返回的是 `ownedCopy(ctx.allocator, …)`，交给它会分配器不匹配并打死进程（实测 `free of invalid memory`）；② 改 pin 后先 `rm -rf .zig-cache`，增量缓存会沿用旧 fetch 模块（实测"编译通过"却仍跑旧版本）。v0.32.3 起 sqlite 单连接串行化（`Rows` 持锁至 `deinit()`）；v0.33.0 起 `UseInterceptor` 覆盖 Create/BulkInsert（create 上 `whereEq` = 缺省才填）；v0.35.0 起 outbox 认领式派发（崩溃遗留用 `requeueStale` 回收）；v0.36.0 起迁移默认加锁、outbox 新增 `claimed_at` 列、`createAllTables` 增加 allocator 参数；v0.37.0 起 `max_wait_ms` 真正阻塞等待、嵌套预加载每层一次查询；v0.38.0 起 `queryTargets*` fail-closed（旧语义改名 `*Unscoped`），新增 NULL 容忍扫描器；v0.39.0 起 `zent.scope` 让手写 SQL 也能带上软删/隐私/拦截器契约（**裸 SQL 不再自动隔离，必须接 scope**），并有 `<col>Like` 与 `zent.version`；v0.40.0 起一行式释放 `deinitRows`/`deinitRow`/`deinitEdgeRows`，v0.41.0 明确 `crud_helpers.queryRows` 也是需要 `zent.scope` 的裸路径，v0.41.1 修复 `deinitRows` 指针形态回归。
- SQLx 选择性链接：`-Ddb=` / `.db=`，默认 `all`；框架测试勿收窄；见 `docs/SQLX_DRIVERS.md`。
- WS：`WsMessageFn` 含 `WsFrameKind`；fiber/io_uring 分发 text+binary（OpenIM protobuf OK）。
- CI：`bash scripts/ci-integration.sh`（tenant-mgmt + stress + shopdemo，`-Ddb=sqlite`）。
- 旗舰示例：`examples/tenant-mgmt`（CatalogPermDb）；多主体门户参考应用侧 Alignment 文档（如 ZigShop）。
