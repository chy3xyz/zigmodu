# ZigModu Framework Backlog

Status tracker for framework ergonomics improvements (Zig 0.17).  
Monolith boundaries unchanged — see `docs/PRODUCTION_ROADMAP.md`.

**Consumer-driven open items (zapi / ThinkPHP port):** see
[`ISSUES_FROM_ZAPI.md`](ISSUES_FROM_ZAPI.md) (auth catalog, envelope dialect,
typed identity). Sibling ORM backlog: `zig_ws/zent/docs/ISSUES_FROM_ZAPI.md`.

| # | Item | Status | Entry point |
|---|------|--------|-------------|
| 1 | Typed extractors (Path / Query / Json) | **Landed** | `http.extractPath/Query/Json` + field defaults → `src/api/Extract.zig` |
| 2 | Unified error → ProblemDetails | **Landed** | `respondProblem` / `respondErr` + `setErrorMap` |
| 3 | Scope-local middleware | **Landed** | `RouteGroup.use`, `Scoped.use` |
| 4 | Router oneshot / Testkit | **Landed** | `Testkit.dispatch` / `dispatchOpts` |
| 5 | Security / Obs / Resilience profiles | **Landed** | `productionProfile`（生产一键：背压+中间件+`/metrics`+`/health/*`）；散件 `applyHttpDefaults` + `applyResilienceDefaults` |
| 6 | Testkit JWT / SQLite / tenant / SSE | **Landed** | `signBearerToken`, `openMemorySqlite`, `tenantMiddleware`, `SseRecorder` |
| 7 | Outbox / Idempotency | **Landed** | `zigmodu.outbox.*`, `idempotencyMiddleware` (+ sample tests) |
| 8 | Config / health / shutdown | **Landed** | `requireEnv`, `ShutdownChecklist` |
| 9 | OpenAPI ↔ extractors / SSE | **Landed** | `openApiParamsFromStruct` + `RouteMeta.openapi_params` merged in catalog |
| + | **SSE first-class** | **Landed** | `http.sse` sets `streaming` (no double write); `SseSpec`/`sse_routes`; `lastEventId`; multiline `data:`; `SseRecorder` + live stream test |
| + | Validation ↔ Extract | **Landed** | `extractJsonValidated(ctx, T, rules)` |
| + | Example migration | **Landed** | `examples/zent-modulith` + `tools/zmodu/.../api_standalone.zig.tpl` |
| + | **WS binary frames** | **Landed** | `WsFrameKind` + `on_message(..., kind)` text/binary; `WsFramer.writeBinary` |
| + | **OpenAPI UI Suite** | **Landed** | `http.swaggerUiHandler`, `http.scalarUiHandler`, `http.openApiRoutes` zero-config HTML embed & one-line route tuple |

---

## 2026-09 加固批次（production hardening）

| # | 能力 | 入口 | 解决什么 |
|---|------|------|----------|
| 1 | 生产一键接线 | `http.productionProfile(&server, cfg, &state)` | 背压 + 安全/观测中间件 + `/metrics` 黄金信号 + `/health/*`；**必须在 `addRoute` 之前** |
| 2 | 连接背压 / 慢连接 | `Server.Config.max_connections` · `over_limit_response` · `header_timeout_ms` · `ws_write_timeout_ms` | accept 洪泛、slowloris、慢 WS 客户端阻塞写线程 |
| 3 | 共享注册表 | `zmodu.FrozenMap` / `FrozenStringMap` | 启动期填充后 `freeze()`，消除并发 put/resize 撕裂（`panic: incorrect alignment`） |
| 4 | panic 归因 | `pub const panic = zmodu.panicHook;` | panic 输出带上正在处理的 `METHOD /path` |
| 5 | 启动预检 | `zmodu.Preflight.run(...)` | 缺 env、占位 JWT secret、DB 不通、待应用迁移、时钟偏移 → 拒绝启动 |
| 6 | 密钥轮换 | `SecurityModule.setKeyring(&JwksKeyRing)` | token 带 `kid`，新旧双验，无需全员重登 |
| 7 | 后台任务互斥 | `cron.setLock(...)` · `runner.setLock(...)`（`zmodu.DistributedLock`） | 多副本重复执行 job / 并发 DDL |
| 8 | 业务面指标 | `OutboxConsumer.setMetrics/startPolling` · `Client.poolMetrics` · `metrics.setScrapeHook` | outbox 停投、池打满这类 HTTP 层看不见的静默失败 |
| 9 | 指标下钻 | `createCounterFamily` / `createHistogramFamily` + `ctx.route_template` | 受限基数地按路由看延迟与错误 |
| 10 | 审计规则 | `zmodu audit` b19–b22 | 请求路径裸 panic / 共享可变 HashMap / 裸 `@alignCast` / query 取租户 |
| 11 | 验证手段 | `zig build soak` · `src/test/FaultInjection.zig` · `src/test/ContractGate.zig` | 跨租户泄漏、熔断恢复行为、接口契约漂移 |

权威细节：[`BEST_PRACTICES.md`](BEST_PRACTICES.md)「韧性 / 上线前预检 / 多副本」
· [`OBSERVABILITY.md`](OBSERVABILITY.md) · [`ROUTE_TABLE.md`](ROUTE_TABLE.md) §7.4
· `examples/production-deploy/`。

---

## Quick recipes

### Extractors + defaults

```zig
const QueryDto = struct { page: u32 = 0, q: ?[]const u8 = null };
const q = try http.extractQuery(ctx, QueryDto); // missing page → 0
```

### Validated JSON

```zig
const body = try http.extractJsonValidated(ctx, CreateDto, .{
    .name = http.FieldRules{ .required = true, .min_len = 2 },
});
```

### Custom error map

```zig
http.setErrorMap(&.{.{ .err = error.QuotaExceeded, .status = 429 }});
try http.respondErr(ctx, err);
```

### Profiles

```zig
var http_state = http.HttpProfileState.init(allocator);
defer http_state.deinit(allocator);
try http.applyHttpDefaults(&server, .{}, &http_state);

var res = try http.applyResilienceDefaults(allocator, &.{
    .{ .name = "db", .max_qps = 200 },
    .{ .name = "payment", .max_qps = 50 },
});
defer res.deinit();
```

生产环境用一键入口（**必须在路由注册之前**调用，否则全局中间件不会进已注册路由）：

```zig
var profile = http.ProductionProfileState.init(allocator);
defer profile.deinit(allocator);
try http.productionProfile(&server, .{
    .max_connections = 4096,
    .header_timeout_ms = 10_000,
}, &profile);
// → 背压 + CORS/request-id/recover/tracing/access-log + GET /metrics
//   + GET /health/live + /health/ready（+ 可选 dashboard）
```

细节与告警阈值：[`OBSERVABILITY.md`](OBSERVABILITY.md) · 接线顺序：[`ROUTE_TABLE.md`](ROUTE_TABLE.md) §7.4。

### Testkit

```zig
var sec = http.Testkit.testSecurity(allocator, io);
const token = try http.Testkit.signBearerToken(&sec, allocator, "42", &.{"admin"});
defer allocator.free(token);
var db = try http.Testkit.openMemorySqlite(allocator, io);
defer db.deinit();
var rec = http.SseRecorder.init(allocator);
defer rec.deinit();
try rec.sendEvent("message", "{}");
```

### OpenAPI params on routes

```zig
const params = http.openApiParamsFromStruct(QueryDto, .query);
.{ .method = .GET, .path = "search", .handler = search, .meta = .{ .openapi_params = &params } }
```

### Idempotency + Outbox

```zig
var store = http.IdempotencyStore.init(allocator, 10_000);
defer store.deinit();
try server.addMiddleware(http.idempotencyMiddleware(&store)); // header: idempotency-key

var outbox = zmodu.outbox.OutboxPublisher.init(allocator, .{});
const insert = try outbox.buildInsert("order.created", payload_json);
// exec insert.sql with insert.params inside the same DB transaction
```

See `src/messaging/outbox_sample.zig` for unit smoke tests.

### SSE

```zig
pub const sse_routes = [_]http.SseSpec(State){ .{ .path = "events", .handler = stream } };
fn stream(ctx: *http.Context, _: *State) !void {
    // Optional reconnect cursor:
    // if (http.lastEventId(ctx)) |id| { ... }
    var w = try http.sse(ctx); // sets responded+streaming (Server skips buffered rewrite)
    try w.sendEvent("tick", "{}");
    try w.done();
}
```

---

## Related docs

- [ROUTE_TABLE.md](./ROUTE_TABLE.md)
- [PRODUCTION_ROADMAP.md](./PRODUCTION_ROADMAP.md)
- [MODULITH.md](./MODULITH.md)
- [AGENTS.md](../AGENTS.md)
