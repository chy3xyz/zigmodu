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
| Worker / 邮箱 / 定时器 / RingBuffer / **池化（§12）** | `docs/RUNTIME.md`（定位、契约、背压语义、兼容 10 条；§12.10 = WorkerPool Phase 1 落地边界） |
| 架构检查 / 依赖图 / `zmodu doctor` | `docs/ARCHITECTURE.md`「Architecture engine」+ `src/core/ModuleGraph.zig` |
| 集群成员读侧（请求路径选节点/健康度） | `docs/DISTRIBUTED.md`「集群读侧」+ `zigmodu.ClusterView`（`acquire`/`release`，别读写入侧的哈希表） |
| 长流程 / 崩溃续跑（Saga、补偿、检查点） | `docs/WORKFLOW.md` + `SagaOrchestrator.resumeInstance`（有副作用的一步必须幂等） |
| 改 `src/ai/**` 前（它只能依赖领域缝） | `docs/AI_BOUNDARY.md` + `src/test/AiBoundary.zig`（驱动层 import 数只减不增） |
| Agent 能做什么（默认不能执行） | `docs/AGENT_RUNTIME.md` + `ai.Guard` / `ai.AgentSpec` / `ai.ProposalPipeline` / `ai.AgentWorker`（闸门已接进 `Agent.run`；Agent 可跑成运行时 worker） |
| 观测 / 告警 / Grafana | `docs/OBSERVABILITY.md`（黄金信号 + 阈值 + dashboard JSON；夜间 `zig build soak` 见 CI `soak` job） |
| 部署拓扑（TLS 边车/探针/守护） | `examples/production-deploy/`（nginx · Envoy · k8s · systemd） |
| Extract / SSE / Testkit / Outbox | `docs/FRAMEWORK_BACKLOG.md` |
| 故障注入 / 契约门禁模板 | `src/test/FaultInjection.zig` · `src/test/ContractGate.zig` |
| 升级注意事项（breaking / 影响面 / 改法） | `docs/UPGRADING.md` |
| 外部反馈核实与处置 | `docs/ISSUES_FROM_ZAPI.md` · `docs/ISSUES_FROM_ZIGSHOP.md` |
| CLI 生成 | `docs/ZMODU_CLI_INTEGRATION.md` · `zig build zmodu -- scaffold …`（**必须从仓库根跑**，见下方"两个 zmodu 入口"） |
| 只跑一个/一组测试、filter 为什么不能瞎用 | 本文 §Testing「只跑匹配的测试」+ `scripts/test-fast.sh --help` |
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

// App builder — bind it first: a builder method takes `*Self`, and a temporary
// is `*const` (`error: expected type '*T', found '*const T'`).
var b = zmodu.builder(allocator, io);
defer b.deinit();
var app = try b.withName("app").build(.{ModuleA, ModuleB});
defer app.deinit();
try app.start();
defer app.stop();

// Codegen: zig build zmodu -- scaffold --sql schema.sql --name my_app [--with-auth]
```

**两个 zmodu 入口（踩过两次的坑）**：`zig build zmodu` **从仓库根**跑才装到 `zig-out/bin/zmodu` ——
CI、`scripts/ci-*.sh`、本文件都用那个。`cd tools/zmodu && zig build` 会装到
`tools/zmodu/zig-out/bin/zmodu`（那是它作为独立包时的入口，`release.sh` 会 bump 它的 `build.zig.zon`）。
**两个二进制同名但不同位置**，调错就会用陈旧生成器跑出旧产物 —— 改完生成器请用**根**入口重建，并用
`ls -la zig-out/bin/zmodu` 确认时间戳是刚生成的。

**别在框架仓库根冒烟测试写文件的子命令（踩过一次）**：`module` / `api` / `event` / `health` / `config`
默认按 **CWD 相对**路径写 `src/modules/<name>/…` 与 `src/config.zig`，**没有任何"这里是不是一个应用"的检测**
（框架仓库自己有 `build.zig.zon`，所以它也拦不住）。本会话就有一次冒烟测试把
`src/config.zig` / `src/modules/health.zig` 直接写进了框架树，而且事后被误报成"并行工作的产物"。
所以：跑这些命令要用 `--dry-run` 或**临时目录**，跑完 `git status --porcelain` 自查有没有多出未跟踪文件。

## 近期栈 DO / DON'T（v0.14.x 升级后 · AI 必守）

| DO | DON'T |
|----|--------|
| `pub const routes` + `Router(State).scope.mountAll` | 新模块只写 `RouteGroup.get/post` 当默认 |
| Path A：`jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.rbac)` | 应用自签 PHP 形 JWT 再在 handler 里验一遍 |
| `generateTokenWithTenant(sub, roles, aud)`；roles=门户粗身份 | 在核心 JwtPayload 加 `type` enum；JWT 塞全量菜单树 |
| 自定义 `CatalogPermissionLoader(allocator, CatalogPermLoadInput)` 接业务表 | 三套门户 RBAC 硬塞进 `CatalogPermDb` |
| Handler 读 attrs：`user_id` / `tenant_id` / `permissions` | `@ptrCast(ctx.user_data)` 当 AuthInfo；handler 重复 Bearer 验签 |
| `user_data` = ComptimeRouter `*State` only | 把 AuthInfo / JWT 对象写入 `user_data` |
| 取路由 State：`ctx.state(T)`（WS `on_connect` / legacy `RouteGroup` 回调同用） | 手写 `@ptrCast(@alignCast(ctx.user_data orelse unreachable))`（`unreachable` 在 ReleaseFast 是 UB） |
| Legacy `rbacJwtMiddleware` / `jwtAuth` → 只读 `auth_info` | 新应用默认走 legacy 中间件 |
| `ctx.json` / `http.respondErr` / extractors | `sendSuccess`/`sendFail`；拼用户输入进 SQL |
| OTLP / Vault：`http(s)://`（TLS 走 `std.http.Client` 系统信任库）；x402 **fail-closed** | 默认放行支付 |
| `http.HttpClient`：`https://` 经 `std.http.Client`（OTLP/Vault/AI 出站共用；`requestStream` HTTPS 真增量） | 自签证书未入系统信任库即报 TLS 失败 |
| WS：`on_message(session, msg, kind)` — **text+binary**（`WsFrameKind`）；`writeBinary`/`writeData` | 假定只收 0x1；丢弃 0x2（会破坏 OpenIM protobuf） |
| WS 路由：`ws_routes` 每项**显式** `.meta.auth = .public`（`ComptimeRouter.zig:734-758` 强制；非 public 或省掉 `.meta` 都是**编译错**，`permission`/`roles` 也被拒） | 省掉 `.meta`（`.auth` 默认 `.inherit` → 编译不过）；给 WS 路由挂 `permission`/`roles` |
| CSPRNG：`std.Io.randomSecure(io, buf)` —— 每次系统调用，失败即 `error.EntropyUnavailable`、**无回落** | `std.crypto.random`（**本工具链无此声明**）；`std.Io.random`（文档明写失败回落 pid+墙钟+ASLR）；单一时间戳种子；`std.Random.DefaultPrng.init(seed)`（时钟^指针 → 同一个 challenge） |
| sqlx：`Client.open` 后注意 pool/client 指针；CB 传 `io` | 在 ConnPool 上缓存失效的 `*Client` |
| sqlx 驱动链接：`-Ddb=sqlite\|postgres\|mysql\|all`（默认 `all`） | 小系统用 `.db = "sqlite"`，勿默认三库全链 |
| Runtime 监督树：`rt.spawnGroup(.one_for_one\|.one_for_all\|.rest_for_one\|.stop_group)` + `Supervision.group`；重建是原地 `deinit`+`init`（`docs/RUNTIME.md` §14） | 让 handler 自己 `catch` 装作没事（错误预算就废了）；把声明 `run` 的 worker 放进会重建的组（spawn 报 `NotRestartable`） |
| Agent：`AgentSpec{.guard=…}` + 技能声明 `.action`（默认 `execute`）；`ai.ProposalPipeline` 走提议→风险→执行 | 裸 `Agent{}` 不设 `guard`（= **无界**）；用 `MemoryStore.formatContext` 给 agent 喂记忆（`0` = 任意 = 跨租户） |
| Agent 跑成 worker：webhook / cron 路径用 `ai.AgentWorker`（`rt.spawn(ai.AgentWorker, …)` 拿 `*runtime.Handle(AgentWorker, cap)`，再 `ai.agent_worker.post(handle, goal)`）；被拒/失败经 `on_result` 回报，不占监督预算 | 在请求线程里同步 `Agent.run`（`ai.trigger.Trigger.fire` 是同步的，会占住 handler）；把失败当 supervisor 错误反复重试 |
| 共享注册表：`zmodu.FrozenMap/FrozenStringMap`，启动期填充后 `freeze()` | 文件作用域裸 HashMap 在 worker 池上并发写（撕裂元数据 → 进程崩溃） |
| Runtime：模块里 `ctx.runtime()`（app 拥有：首次创建即启动 ticker；`stop()` 先 join worker 再停模块） | 模块里自己 `Runtime.init`（线程没人 join）；在模块里 `rt.shutdown()`（提前打断别的模块的 worker） |
| 文档/注释里的 builder 片段：先 `var b = zmodu.builder(allocator, io); defer b.deinit();` 再链式 | 写 `builder(…).withName(…)`（临时值是 `*const`，编译不过）；注意 `src/test/DocSnippets.zig` 只抽查围栏代码块/文档注释里的 5 种形状（builder 临时值直链、`try app.runtime().…`、`Application.init(allocator…)`、`ctx.json(<数字>, .{…})`、`ctx.paramInt("…")`），并非全量编译文档 |
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
| 长尾 worker 用池化：`Runtime.initWithOptions(.{ .scheduler = .{ .max_pooled_workers = N } })` + `spawn(W, .{}, .{ .capacity = c, .mode = .pooled })`；应用里用 `builder.withMaxPooledWorkers(N)`（`Application.Config.max_pooled_workers` 同理）；跑起来的参照是 `examples/runtime-workers` 的 audit 那一环（`[pool] … dispatched>0`） | 不声明就用 `.pooled`（`error.PoolNotConfigured`）或超过声明上界（`error.PoolCapacityExceeded`）—— 上界是硬上限，环容量按它算 |
| `.pooled` 只给消息驱动 worker（`Message` + `handle`）；`run` 型必须 `.dedicated` | 把 `.pooled` 给 `run` 型（编译期报错，`scripts/check-pool-guard.sh` 兜底）；把 `poolStats().ready_push_failures` 当背压读数 |
| 就绪环的 token 是"一个 worker 的调度权"，不是消息：环满 = 调度器失联（断言 + 计数，不是丢） | 把环满当普通满队列丢掉（丢一个 token = 那个 worker 永久不再被调度，邮箱却继续收） |
| 模块依赖靠 `build(.{...})` 的编译期图检查拦住（环/缺失/自依赖/重名，报错带环路径） | 用 `@import` 跨模块直接引用对方内部文件（`zmodu doctor` 会报纠缠 + 文件:行） |
| 交付前跑 `zmodu doctor`（阻断项 exit 1，可直接进 CI） | 声明无法执行的架构规则（如"domain 不许 import db"却只在文档里写 —— 编译期看不到 import，交 `doctor`） |
| 集群读侧：`view.acquire()` → 用 → `release()`；选节点 `view.pick(key)`（rendezvous） | 在 handler 里直接读 `ClusterMembership` 的可变表（那是维护循环的状态），或为读它加锁 |
| 发布是单写者整份替换；`error.ReadersBusy` 当作"下个 tick 再发" | 把 `ReadersBusy` 当致命错误重试到死（读者卡住时该跳过这次发布） |
| 取参数：路由占位 `pathParam`；form/query 用 `requestParam`（form 优先）或 `nestedParam`（点号路径） | 以为 `ctx.param` 会回退到 query/form（它只读路由占位符） |
| 应用 root 接 `pub const panic = zmodu.panicHook`（panic 时输出当前请求 METHOD/path） | 请求路径 `catch unreachable` / `@panic`（audit b19–b21 拦截） |
| 生产配置 `max_connections` + `header_timeout_ms` + `body_timeout_ms`（连接洪泛/slowloris/Slow-POST）；发布前 `zig build soak` | 只设 `request_timeout_ms` 就当防住了慢连接（它只管 handler 阶段，`body_timeout_ms` 默认 30 s、`0` 关） |
| 租户来源：JWT `aud` → attr（`.tenant_source = .attr`） | 从 query 取租户（`.query` 可被客户端篡改，audit b22 拦截） |
| 生产一行接入：`http.productionProfile(&server, .{...}, &state)`（背压+安全+`/metrics`+`/health/*`+`/metrics` 黄金信号） | 在 `router.mountAll`/`addRoute` 之后再挂全局中间件（`addRoute` 注册时快照中间件链） |
| WS 出站：`Server.Config.ws_write_timeout_ms` + `WsFramer.isWritable()` 丢帧 | 对不读的慢客户端无限阻塞写（会卡住写线程与 `ConnectionRegistry` shard 锁） |
| 沙箱 CI：`zig build test -Dnet-tests=false` 跳过 socket 测试 | 在无 loopback 权限环境里跑默认套件（网络用例会失败/抖动） |
| 只跑匹配的测试：`bash scripts/test-fast.sh --filter <测试名子串> [--db all]`（运行期过滤；命中 0 个 → exit 2 并说明未验证任何东西） | `zig build test -- --test-filter X`（0.17 的 build runner 把 `--` 之后的参数全丢掉：跑全套 ~47s 仍 exit 0）；或 `zig test src/root.zig --test-filter X`（缺 `build_options`/驱动链接，且产物二进制运行期拒收该 flag） |
| 需要"确实重新执行过"的证据：`bash scripts/test-fast.sh --force-run`（或 `-Dtest-force-run=true`） | 以为第二次 `zig build test` 会重跑 —— Zig 连 test **运行**结果一起缓存，直接显示 `run test cached`，测试没执行、也没有任何计数 |
| 多副本后台任务：`cron.setLock(...)` / `runner.setLock(...)`（`zigmodu.DistributedLock`，表锁按 DB 自动分方言） | 多副本直接跑 cron / 迁移（每个副本都会执行 = 重复副作用、并发 DDL） |
| 长流程收尾：`SagaStep.timeout_seconds` **必须设**（`0` = 关掉预算）；进程重启后接 `zigmodu.TransactionJournal.initWithBackend(...)` + `recover()`，把悬挂（in-doubt）事务交人工处置 | 让某步卡死把 saga 永久挂在 `running`（`timeout_seconds = 0` 就是关掉预算）；重启后对 in-doubt 事务装作没发生 —— `recover()` 只**报告**，不会自动重试/回滚 |
| 指标标签用 `ctx.route_template`（模式）；用 `createCounterFamily` 限基数 | 把原始 path / id / 用户输入塞进 label（基数爆炸） |
| 公开但可能带身份的接口用 `auth = .optional`（有 token 就注入身份、永不 401） | 用 `.public` 后又在 handler 里手写 token 解析（或再加一条 `.jwt` 路由） |
| 启动跑 `zigmodu.Preflight.run(...)`（env/secret/DB/迁移/时钟） | 用占位 JWT secret 或默认配置上线（预检会拦，别绕过） |
| 生产接线的参考实现看 `examples/tenant-mgmt`（`productionProfile`）与 `examples/zmsaas`（Preflight + 池/积压指标） | 让示例停在上古手工接线（文档承诺、旗舰不用） |
| 换 JWT 密钥走 `JwksKeyRing` + `setKeyring`（带 kid，新旧双验） | 直接改 secret 重启（全员强制重登；或留下无法验证的旧 token） |
| outbox 用 `consumer.setMetrics` + `startPolling`；池/积压用 `metrics.setScrapeHook`；**运行时用 `Runtime.MetricsBridge` + `setScrapeHook`**（`messages_dropped` / `timer_lag_ms` 只在这里看得见，HTTP 侧完全无感；池化后还有 6 条 `zigmodu_runtime_pool_*`，其中 `pool_claimed` / `pool_ready_push_failures` 是 `RuntimeStats` 里根本没有的读数） | 只盯 HTTP 指标（outbox 停投、池打满、邮箱打满、ticker 饿死在 HTTP 层完全看不见） |
| 新增 `pub` 导出的组件时，**同时**写一条真正实例化它的测试（调用链要打通，不只是 `@import`） | 只导出、没调用者 —— Zig 惰性分析函数体，签名过期/编译不过要等用户真正调用才炸（`LogRotator` 就这么烂了很久） |
| 租户模型上声明 `pub const sql_tenant_column: ?[]const u8 = "tenant_id"`（`zmodu scaffold` 已默认生成）——隔离变成编译期强制 | 靠"记得调 `*ForTenant`"：无作用域变体在租户模型上照样跨租户返回 |
| 跨租户是合法需求时写 `*Unscoped`（`findByIdUnscoped` …），让危险操作在代码里一眼可见 | 为了绕过守卫而删掉 `sql_tenant_column` 声明 |
| 需要请求预算落到存储时 `orm.withContext(ctx.sqlContext())`（一次覆盖该请求所有查询）；裸 sqlx 用 `*Ctx` 变体 | 以为 `request_timeout_ms` 会中止慢查询 —— 它只在 handler 返回后补一个 408 |
| handler 日志用 `ctx.logScope("module")`（已带 trace_id） | 用 `LogScope.scope("module")` 而不带 id —— 漏了不报错，只是静默丢关联 |

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

**跨平台编译**：默认只有 `-Ddb=none` 可行（三条驱动都链不上——探测逻辑是主机的，Zig 不会去目标 sysroot 找）；带驱动要给**目标平台**的库 + `SQLITE_LIB` / `PQ_*` / `MYSQL_*` 覆盖，glibc 目标还须写 glibc 版本（`-Dtarget=aarch64-linux-gnu.2.34`，否则 `@GLIBC_2.34` 一屏未定义符号）。跨目标**跑不了测试**，且内存大头是优化等级不是"跨"：ReleaseSafe/Fast ~0.86 GB vs Debug ~0.27 GB，只编产物用 `-Doptimize=ReleaseSmall`（~0.42 GB）或 Debug，配 `-j2 --maxrss 1G --skip-oom-steps`。实测数字与配方 → **[`docs/SQLX_DRIVERS.md`](docs/SQLX_DRIVERS.md) §12**。

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
| `std.os.getpid()` | `@intFromPtr(&seed)`（pid **形状**的值；**不是**熵源 —— 熵一律走 `std.Io.randomSecure`，见下） |
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
- **Path params**: 每条路由最多 8 个 `{…}` 段（`RouteParams.MAX`）；超了是**注册期** `error.TooManyRouteParams`（`Router.addRoute`/`Server.addRoute`，过去是静默 404）
- Auth stack (Path A): `jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.{ .mode = .rbac })` + optional `moduleGate`
- Auth (v0.15.31+, §7.2): 非 JWT 后端用 `authFromCatalog(slot, backend)` + `AuthBackend`（内置 `jwtBackend`）；拒绝信封 `AuthRejectFn` / `envelopeReject(.thinkphp)`；handler 读 `ctx.userId()/requireUserId()/tenantId()`；信封方言 `ctx.setEnvelope` + `ok/fail/unauth/paginated`；租户 `tenantResolver`；路由级 `RouteMeta.roles`；token 提取 `extractTokenAny`；CI 审计 `Testkit.auditAuthCoverage`
- Permissions: `catalogLoaderFromTable` / `CatalogPermDb.loaderFromClient`，或多主体自定义 loader（`CatalogPermLoadInput{ sub, aud, roles }`）
- Multi-portal: JWT `roles` = 门户；业务 RBAC → `permissions` CSV + `portal:*` — §7.1（**无**框架 `type` claim）
- Attrs: middleware 写 `user_id`/`tenant_id`/`permissions`；handler **只读 attrs**
- Legacy JWT 中间件只写 **`auth_info`**；禁止 `@ptrCast(user_data)` 当 AuthInfo
- **Route state**: `ctx.state(T)` 取 ComptimeRouter `*State`（WS `on_connect`/`on_close`、legacy `RouteGroup` 回调同用）；缺 state 返 `error.NoRouteState`，别写 `@ptrCast(@alignCast(ctx.user_data orelse unreachable))`
- **Extractors**: `extractPath` / `extractQuery` / `extractJson` / `extractJsonValidated`
- **Errors**: `respondErr` + optional `setErrorMap`（RFC 7807）
- **Scope MW**: `RouteGroup.use` / `Scoped.use` before mount
- **Testkit**: `dispatch`（`DispatchOptions.query` 传 percent-encoded 原样串，与 path 自带 `?…` 可共存）/ `signBearerToken` / `openMemorySqlite` / `SseRecorder`
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
- 数据层默认 = 框架自带 `data.sqlx` / `data.Repository`（`SqlxBackend` 是自带 backend）；**zent 是平行栈**（`docs/ZENT.md`），按 git tag 在应用/示例里单独引入，**不是框架依赖**，两者不共享驱动与事务

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
- Log errors — never **swallow** a failure you depend on. `catch {}` on an I/O or DB call whose result the rest of the code needs is a violation (audit `b10`); on *best-effort cleanup* — `errdefer` teardown, a `rollback` you can no longer act on, `sendError` writing to an already-failing response — the original error is what matters and the cleanup failure is secondary, so a bare `catch {}` is idiomatic there. **但两条链的口径不同，别只看这一条**：`zmodu audit` 的 b10 豁免是**整行子串匹配** `errdefer` / `rollback` / `sendError`（行尾注释、`self.rollback_cmd`、`self.sendError_queue.peek()` 这类同名列同样会被豁免——实测如此），`// audit: ignore b10` 也必须与该行同处一行；而 `zig build check` 的 hot-path catch 扫描（`scripts/check-production.sh`）**不豁免这三类、也没有 ignore 标记**，在它 `ENFORCED_PREFIXES` 下的生产代码里写这三种形状照样判红。要两边都过就按扫描器的口径写：`catch |err|` + 非空 body（清理场景可以只降级成 debug 日志）。
- Use `zmodu.Result(T)` for fallible operations

### Security
- Passwords: `sec.PasswordEncoder` (PBKDF2-HMAC-SHA256, 100K iterations)
- JWT (new apps): `AppSecurity` + `generateTokenWithTenant` + catalog JWT + `permissionGateWith(.rbac)`
- JWT (legacy only): `rbacJwtMiddleware*` / `sec.auth.jwtAuth*` → `auth_info` only
- Secrets: `SecretsManager`（env > file > vault KV v2）；`http(s)://` 均可，HTTPS 用系统 CA
- CSRF: `http_middleware.csrf()` double-submit cookie。**默认不采信 `X-Forwarded-Host`/`Proto`**（要求前置代理把外部
  host 写进 `Host`）；确有反代时 `csrfWith(.{ .trust_forwarded_host = true })`，前提是代理**每个请求都覆写**这两个头。
  `csrfWith(.{ .sign_key = k })` 让 token 变成 `nonce.HMAC-SHA256`（`csrfMintSignedToken` 签发，常数时间比较）。
  **`csrf()` = `csrfWith(.{})`，两条路径都要求中间件在 `user_data` 上拿到 `CsrfConfig`**（手工 `mw.func(ctx, next, null)` 会 panic）。
- 响应压缩: `http.compressionMiddleware`（`CompressionConfig`，deflate/zlib 容器；默认 `min_size = 1024`、类型白名单、
  候选类型无条件加 `Vary: Accept-Encoding` 并与已有值合并、只有变小才替换且此时**移除 `Content-Length`**）。不做 brotli/zstd
  与流式增量压缩；`ctx.streaming` 跳过。装在 security headers 之后、且**别对已经压过的响应重复装**
- CSPRNG: `std.Io.randomSecure(io, buf)` —— 每次系统调用，失败即 `error.EntropyUnavailable`，**没有回落**
  （`src/security/ApiKeyAuth.zig:129` · `PasswordEncoder.zig:24` · `SecurityModule.zig:290` · `src/kit/random.zig:17,42`）。
  熵入口要 `io`：忘了传是**编译错误**，这是有意的。
  **不要**用 `std.crypto.random`（本工具链上不存在，实测编译不过）、也**不要**用 `std.Io.random`
  （它的文档明写失败时回落到 pid + 墙钟 + ASLR —— 那正是 §"CSPRNG" 这条修掉的缺陷类别）、也不要**播种**
  非 CSPRNG 的 PRNG 来取 challenge/nonce/令牌/盐值（`std.Random.DefaultPrng` = `Xoshiro256`，种子由调用方
  自己拼：时钟 ^ 指针即可复现，`src/web4/challenge.zig` 就这么签发过可预测的防重放 challenge）。
  `check-production` 的熵扫描 + `audit` b24 已把「播种非加密 PRNG」纳入；豁免是**逐处**的人工评审，
  不落仓库目录白名单：`check-production` 看 `scripts/lib/zig-scan.awk` 的 `ENTROPY_OK` 表，`audit` 用
  `// audit: ignore b24 <缘由>`（测试固定种子做可复现属于正当用法）。
- x402: fail-closed；dev 才注入 `verifyPaymentAllowAll`。**`X402Store` 是台账不是校验器**：它只持久化发票并记录"每张恰好核销一次"，校验**始终**走 `X402Config.verifier`（配了 store 也一样）；把两者混同会让任意客户端自报 tx hash 就过关。发票另**绑定付款人**（签发时记 `payer_did`，来源是 attr 不是 header；核销不符 → `payer_mismatch`/403 且不消耗发票）——所以 `x402Middleware` 必须挂在身份中间件**之后**。

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
- **HTTP/2 现在跟随 H1 的限额与超时**（`Server.http2ServeOptions` 是唯一构造点）：`max_body_size` / `header_limits`（解压后头列 16 KiB、100 条，并通告 `SETTINGS_MAX_HEADER_LIST_SIZE`）/ `header_timeout_ms`（空闲读超时，超时 GOAWAY `ENHANCE_YOUR_CALM`）。**两处对 h2 是新行为**：过去 h2 既无头列预算也无空闲超时（浏览器挂着的 h2 连接现在会在 10 s 空闲后断开）；`header_timeout_ms = 0` 可关，但会同时关掉 H1 的 slowloris 闸门
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
            const id = try ctx.paramInt(i64, "id");
            // tenant: ctx.getAttr("tenant_id") — 勿再验 Bearer
            _ = self;
            _ = id;
            try ctx.jsonStruct(200, .{ .ok = true });
        }
        fn cancel(ctx: *http.Context, _: *State) !void { try ctx.jsonStruct(200, .{ .ok = true }); }
        fn login(ctx: *http.Context, _: *State) !void { try ctx.jsonStruct(200, .{ .token = "..." }); }
    };
}

// main: CatalogSlot → jwtAuthFromCatalogWithPermissions → permissionGateWith(.rbac)
//       → router.scope.mountAll(.{ order_api, ... }) → catalog_slot.set(try router.finish())
```

### HTTP — Legacy RouteGroup（仅兼容旧代码）

```zig
try group.get("users/{id}", getUser, null); // 路径无前导 /
fn getUser(ctx: *http.Context) !void {
    const id = try ctx.paramInt(i64, "id");
    try ctx.jsonStruct(200, .{ .id = id }); // NOT sendSuccess/sendFail
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

### 只跑匹配的测试（以及哪些形式不可信）

```bash
bash scripts/test-fast.sh --db all --filter "RaftElection: a tick"   # 只跑名字含该子串的用例
bash scripts/test-fast.sh --force-run                               # 整跑，且强制真的执行
bash scripts/test-fast.sh --help
```

filter 是**测试全限定名的子串**（形如 `core.cluster.RaftElection.test.<测试名>`，见 `zm-test-runner:` 摘要行）。
实现的机制是**运行期**过滤：`-Dtest-filter=` 给 `test` step 的每个 test artifact 装上
`scripts/test-runner.zig`（`mode = .simple`），整套先编译、只有命中的才执行。

**哪些形式不可信（都在 0.17.0-dev.2151 实测过）**：

| 形式 | 实际行为 |
|------|----------|
| `zig build test -- --test-filter X` | build runner 把 `--` 之后的参数**整体丢弃**：filter 无效，全套照跑（~47s），**exit 0** |
| `zig test src/root.zig --test-filter X` | 缺 `build_options` 模块与 SQL 驱动链接；就算用 `-Mroot=` 拼出来，产物二进制在**运行期拒绝** `--test-filter`（该 flag 是编译期的） |
| Zig 自带 `--test-filter`（`Compile.filters`） | **编译期**过滤：被排除的 test 连函数体都不分析，它 body 里的 `@import` 不会发生 → 被导入文件的测试**根本不在编译里**。本仓库整套挂在一个聚合测试下（`src/tests.zig` → `test "compile all source files"`），所以实测 `-Dtest-filter=RaftElection` 编出的二进制只有 1 个测试（`root.test_0`，无名 `test { … }` 块，任何 filter 都匹配不到）且 **exit 0**；只有 `-Dtest-filter=.`（匹配一切）能跑满 1416 |
| 命中 0 个 | 自带机制打印 `All 0 tests passed.` 且 **exit 0**。`scripts/test-fast.sh` 汇总 5 个 test 二进制的 `zm-test-runner:` 行，总数 0 时 **exit 2** 并明确说"没有验证任何东西" |
| 第二次 `zig build test`（缓存热） | Zig 连 test **运行**结果一起缓存：输出 `run test cached`，测试**没有执行**、也没有计数。要能引用的证据就加 `--force-run` |

> 一个二进制里若 filter 命中 0 个，runner **不会**单独失败（5 个 test artifact 里通常只有一个含目标用例，
> 逐个失败会否掉所有正常的聚焦运行）；判定权在脚本的汇总。旧脚本 `bash scripts/test-fast.sh <name>` 的裸参数形式仍可用。

## Version
- Framework: **v0.34.0** (`build.zig.zon`)
- Zig: **0.17.0-dev.1970+67f39b551**（CI 同款锁定版本，见 `.github/workflows/ci.yml` → `ZIG_VERSION`；避免 fmt 行为漂移。注意 ziglang 镜像会回收旧 dev 构建——dev.1567 已 404，升级时本地先验证再改 CI）
- Tests: **以 `zig build test` 输出为准**（`ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`）。
  本文件不再抄写具体数字：`-Ddb` 收窄、平台（Linux/macOS）、门控用例都会改变计数，
  抄下来的数字必然漂移。要在文档里写数字，先跑一次并与输出核对。
  门控用例：真实 PostgreSQL 锁（`ZIGMODU_TEST_PG=1`，CI `test-postgres` job 启用）、
  `REDIS_URL` 门控的 Redis 用例。
- 其它测试入口：`zig build soak`（N 并发 × M 租户，默认 16×50；CI 夜间 64×200）·
  `zig build test -Dnet-tests=false`（沙箱里跳过全部 socket 用例）·
  `bash scripts/test-fast.sh [--filter …]`（聚焦单测/强制重跑；见 §Testing）
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
- 业务项目发布前置门禁：`zmodu ci`（build + fmt + verify + audit + deadcode + **doctor**，共 **6 步**）。

## Learned User Preferences

- Respond in 中文 for user-facing communication.
- Do not create git commits unless the user explicitly asks.
- Prefer the production-readiness plan without physically splitting `sqlx.zig` or `Server.zig`; use section comments plus `docs/PRODUCTION_ROADMAP.md` maintenance boundaries instead.
- When generating framework code from SQL scripts (zmodu), follow zigmodu best practices for complete module output and place reusable templates in a dedicated templates folder.
- When refining architecture or best practices, land them in docs (`docs/ZENT.md`, `MODULITH.md`, `MODULE_LAYERS.md`, `BEST_PRACTICES.md`, `ROUTE_TABLE.md`, `SQLX_DRIVERS.md`, **`AGENTS.md`**) rather than chat-only advice.
- When restructuring examples, preserve existing domain/business logic unless explicitly asked to change it.

## Learned Workspace Facts

- Package **v0.34.0** · Zig **0.17.0** · GitHub `chy3xyz/zigmodu` · branch `master`.
- Sandbox cache：`ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`.
- Auth Path A + `CatalogPermLoadInput` 已落地；legacy JWT 只写 `auth_info`。
- x402 fail-closed；OTLP/Vault 已支持 HTTPS（系统 CA）。
- zent **v0.76.2**（示例按此验证）与 `data.sqlx` 正交，勿混驱动/共享事务（`docs/ZENT.md`）。**0.76 起可按驱动裁剪构建**：`b.dependency("zent", .{ …, .pg = false, .mysql = false })` 跳过对应 `translate-c`（关掉一个确实 import 的驱动会在首次使用时编译失败而非静默降级；本仓库两个示例已用，但本机实测端到端开销不变——省下的两条与 SQLite 那条并行）。**0.75 起** junction 表名与实体表名撞车报 `junction_name_collision`（read-breaking；`migrateSchema` 只 `warn`，改名是调用方的决定）。0.76.1 修三处 OOM 路径泄漏。v0.54 起 `CrudService.create(entity, tenant_id)` 为双参（租户是形参，不再从实体读）；v0.66 起空 `dept_ids` 拒绝而非放行、无谓词 `BulkDelete` 报 `NoPredicate`；v0.67 起无 `last_insert_id` 报 `MissingLastInsertId`、MySQL 批量改逐行；v0.57 起 MySQL 的 `String`/`Enum` 落 `VARCHAR(255)`；v0.58–0.59 `driver.Error` 新增 `ParamCountMismatch`/`PoolWaitTimeout`（**无 `else` 的穷尽 switch 会编译失败**）。**两条升级陷阱**：① `client.<entity>.deinitRow(&e)` 只适用于驱动扫描出来的行——`CrudService.getOwned`（zent 0.73 改名，旧名 `get`）返回的是 `ownedCopy(ctx.allocator, …)`，这类行的释放是 `deinitRowWith(allocator, &e)`；交给 `deinitRow` 会分配器不匹配并打死进程（实测 `free of invalid memory`），`zmodu audit` 的 b23 规则拦这一类；② 改 pin 后先 `rm -rf .zig-cache`，增量缓存会沿用旧 fetch 模块（实测"编译通过"却仍跑旧版本）。v0.32.3 起 sqlite 单连接串行化（`Rows` 持锁至 `deinit()`）；v0.33.0 起 `UseInterceptor` 覆盖 Create/BulkInsert（create 上 `whereEq` = 缺省才填）；v0.35.0 起 outbox 认领式派发（崩溃遗留用 `requeueStale` 回收）；v0.36.0 起迁移默认加锁、outbox 新增 `claimed_at` 列、`createAllTables` 增加 allocator 参数；v0.37.0 起 `max_wait_ms` 真正阻塞等待、嵌套预加载每层一次查询；v0.38.0 起 `queryTargets*` fail-closed（旧语义改名 `*Unscoped`），新增 NULL 容忍扫描器；v0.39.0 起 `zent.scope` 让手写 SQL 也能带上软删/隐私/拦截器契约（**裸 SQL 不再自动隔离，必须接 scope**），并有 `<col>Like` 与 `zent.version`；v0.40.0 起一行式释放 `deinitRows`/`deinitRow`/`deinitEdgeRows`，v0.41.0 明确 `crud_helpers.queryRows` 也是需要 `zent.scope` 的裸路径，v0.41.1 修复 `deinitRows` 指针形态回归。
- SQLx 选择性链接：`-Ddb=` / `.db=`，默认 `all`；框架测试勿收窄；见 `docs/SQLX_DRIVERS.md`。
- WS：`WsMessageFn` 含 `WsFrameKind`；fiber/io_uring 分发 text+binary（OpenIM protobuf OK）。
- CI：`bash scripts/ci-integration.sh`（tenant-mgmt + stress + shopdemo，`-Ddb=sqlite`）。
- Runtime 监督树（v0.31，`docs/RUNTIME.md` §14）：`rt.spawnGroup(policy)` + `Supervision.group`；重建是**原地** `deinit`+`init`（同线程同循环，handle 不换、邮箱不关）。声明 `run` 的 worker 进会重建的组 = spawn 报 `NotRestartable`。**多了一个"接收者可以回来"的理由**：`Mailbox.wake` / `recvWakeable` —— 成员必须在**读 `restart_requested` 之前**取 epoch，落在这两步之间的 `wake()` 否则会丢（`stop()` 靠关邮箱唤醒，重启不能关邮箱）。
- 旗舰示例：`examples/tenant-mgmt`（CatalogPermDb）；多主体门户参考应用侧 Alignment 文档（如 ZigShop）。
