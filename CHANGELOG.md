# Changelog

## [0.15.46] - 2026-09-15

### Added
- **`http.UploadGuard` — 上传内容策略**（唯一被外部反馈认定为"真缺口"的一处）：框架此前只解析
  multipart 并限制体积，**没有任何内容校验**，于是每个收上传的应用各写一遍，而三种常见写法都有洞
  （只查扩展名 → 改名即绕过；只查 `Content-Type` → 客户端自填；放行 SVG → 脚本容器，从自己源站
  发出去就是 stored-XSS）。新增：
  - `sniff(bytes)`：JPEG/PNG/GIF/WebP/BMP/TIFF/PDF/ZIP/GZIP/**MP4（ISO-BMFF，校验 box size + `ftyp`）**
    /WebM/OGG/MP3/WAV，以及文本容器分类（`<svg`/`<!doctype html`/`<script` → 主动内容）。
  - `check(filename, data, policy)` / `checkForm(form, policy)`：判定顺序固定为
    **大小 → 主动内容 → 扩展名白名单 → 格式白名单 → 扩展名与内容一致**，因此错误可诊断：
    "`avatar.jpg` 里是 PHP" → `ContentNotAllowed`，"PNG 字节挂 `.jpg` 名" → `ExtensionContentMismatch`。
  - **SVG/HTML 默认拒绝**（`allow_active_content = true` 才放行），fail-closed。
- **`http.extractMultipart(ctx, config)`**：与 `extractJson*` 对齐的抽取器，失败直接产出 ProblemDetails
  —— 415（不是 multipart）/ 413（太大）/ 400（缺 boundary、畸形、part 过多）；`OutOfMemory` 不渲染。
- **`Multipart.Config.forBodyLimit(body_limit)`**：用同一个数字对齐"单 part ≤ 总量 ≤ 请求体上限"。
- `RateLimiterRegistry`：`max_keys`（`initWithCapacity`）+ LRU 淘汰、`remove(name)`、
  `retain(max_idle_seconds)`、`generateReport()`。
- `CircuitBreakerRegistry`：`count()`、`generateReport()`（真实 JSON）。
- `Context.requestParam(name)`：**form 优先、回退 query** 的取值器（Rails/Laravel/ThinkPHP `input()` 语义）。
- `Context.nestedParam(path)`：点号路径查找（原 `paramPath`，新名不再读起来像"路径参数"）。
- `CircuitBreaker`：`lastUsedAt()`；`PluginManager.dynamicLoadingSupported()`。
- `src/core/SpinLock.zig`：共享的短自适应自旋锁（自旋后 `yield`），供 io-free 热路径临界区复用。
- 测试：`http/UploadGuard.zig`（8 条：嗅探、ISO-BMFF 尺寸校验、主动内容、改名绕过、跨族改名、
  限额/扩展名、表单级）、`test/RouteTemplate.zig`（4 条：三条注册路径 + 未匹配）、
  `RateLimiterRegistry` 淘汰/LRU/retain 4 条、`CircuitBreakerRegistry` 指针稳定性 + 报告、
  `CapabilityRegistry.generateApiBoundaryReport`、`SpinLock` 2 条、`Multipart.Config.forBodyLimit`。

### Fixed
- **`ctx.route_template` 形状随注册方式而变**：`group.get("/health")` 得 `/health`、
  `group.get("health")` 得 `health`、ComptimeRouter `mountAll` 得 `orders/{id}`、
  `addRoute` 得 `/metrics` —— 同一套指标里两种拼法，写死的 dashboard 查询会漏一半流量。
  现在 `Router.addRoute` 里统一为"恰好一个前导斜杠"（该处本来就在 dupe 路径，零额外开销）；
  匹配逻辑不受影响（trie 按 `/` 切分，不用这个字符串）。
- **`CircuitBreakerRegistry` 与 `RateLimiterRegistry` 同族的两处缺陷**：按值存 breaker →
  `getOrCreate` 返回的内部指针**下一次插入 rehash 后失效**（悬垂指针，与 zent 连接池 UAF 同族）；
  且全程零同步。现改为堆分配指针 + 内部锁，指针在 registry 生命周期内稳定。
- **两个热路径锁是"纯自旋不让出"**：`http/AccessLog.zig`、`http/HttpMetrics.zig` 的
  `while (!mutex.tryLock()) spinLoopHint();` 在争用下烧 CPU。改用共享 `SpinLock`（自旋 32 次后
  `std.Thread.yield()`），并把 14 处 `self.mutex.state.store(...)` 的裸解锁换成 `mutex.unlock()`。
- **`Multipart.Config.max_total_bytes` 默认值永不生效**：`Server.Config.max_body_size`（默认 8 MB）
  在读体阶段先 413，`Multipart.parse` 不会被调用，所以默认 32 MB 的总量上限不可达。
  模块头/字段/`Context.multipart` 三处写明判定顺序，并新增 `forBodyLimit` 对齐工具。
  **默认值未改**（降成 8 MB 会静默改变"已抬 body 上限"的调用方行为）。
- **`generateReport` 占位串**（`RateLimiterRegistry`、`CircuitBreakerRegistry`、
  `CapabilityRegistry.generateApiBoundaryReport`）返回 `"pending … migration"`：改为真实 JSON 快照。
- **`PluginManager.loadPlugin` 是静默 no-op**（登记名字但不加载代码）：现在每次 warn 一行，
  并提供 `dynamicLoadingSupported() == false` 供调用方分支。
- `Transactional` 的日志串 `"Rollback transactionfailure: {}"` 缺空格；`core/Error.zig` /
  `ObjectValidator` / `SecurityScanner` / `ModuleBoundary` / `ApiVersioning` 中同一批"半翻译"注释
  （`ValidationRequired field`、`ValidationModule boundary`、`API versionRoute group` …）一并写清。
- `SecurityModule` 里错位的 `/// Validation JWT Token`（挂在 `setKeyring` 上方，与下一行冲突）删除。

### Changed
- **`RateLimiter` / `RateLimiterRegistry` / `SlidingWindowRateLimiter` / `CircuitBreakerRegistry` /
  `AccessLog` / `HttpMetrics` 的锁统一为 `core/SpinLock.zig`**（同一份实现，避免多份自旋逻辑漂移）。
- `CircuitBreakerRegistry.breakers` 类型 `std.StringHashMap(CircuitBreaker)` →
  `std.StringHashMap(*CircuitBreaker)`（破坏性，仅影响直读该字段的代码）。
- `Context.paramPath` → **DEPRECATED**，改用 `nestedParam`（行为不变）。
- `ShardRouter.ShardedQuery` **移除**：只能 `return error.NotImplemented`，且全仓无调用点
  （物理分表由 DB 层负责，模块头已写明）。
- `Partitioner.zig` 文件头"tests are disabled pending integration"是过期描述——测试实际在跑且通过，
  注释改为实情（仍未接入 `DistributedEventBus`，这点保留）。

### Docs
- `BEST_PRACTICES.md`：新增「上传与 multipart」整节（三个问题、限额优先级表、三种错误写法、
  `UploadGuard` 判定顺序与错误表、支持嗅探的格式清单、落盘路径提醒）。
- `UPGRADING.md`：补 v0.15.46 段（含 `route_template` 标签值变化的升级动作、
  `CircuitBreakerRegistry` 字段类型变化、`paramPath` 弃用）。
- `ISSUES_FROM_ZIGSHOP.md`：追加第二轮 4 条核实矩阵（含 #3 的机制更正与真问题定位）与顺带发现清单。
- `API.md`：Multipart 限额顺序、Uploads（`extractMultipart` + `UploadGuard`）、
  `nestedParam`/`requestParam`、`route_template` 规整、registry 淘汰与报告。
- `AGENTS.md`：DO/DON'T 加"上传内容校验""上传限额对齐""取参数用对名字"三行；文件地图加上传一节。
- **全仓 628 行被 `[...]` 污染的注释修复**（35 个文件；这批注释是 `6316708`「翻译所有中文注释」
  那次自动化替换留下的残骸——中文被吞、英文技术名词残留，出现 `/// Module contract[...]`、
  `/// [...]publish/consume[...]Event[...]API[...]` 这类半句）。按 `6316708^` 的原文核对语义后用
  英文重写（与各文件现存语言一致）；`Page.zig` 里 JSON 示例的 `[...]` 是合法省略号，保留。
  校验：逐文件比对"非注释行"与 HEAD，**34/35 文件零代码改动**（另一个是我本批的改动），全量测试通过。

## [0.15.45] - 2026-09-15

### Added
- **进程级错误渲染器**：框架自产错误体有三条出口（链内 `ctx.sendError`、路由前裸 socket、
  handler 自写），此前只有第三条能被应用改。新增
  `http.useRfc7807Errors()`（一次把前两条统一成 RFC 7807，media type
  `application/problem+json`）、`http.setDefaultReject(?AuthRejectFn)`、
  `http.clearDefaultReject()`、`http.problemReject`、
  `http.setTransportErrorRenderer(?TransportErrorFn)` / `http.problemTransportBody`
  （路由前 408/413/431/503 的体）、`Context.sendErrorEnvelope()`（绕过渲染器）。
  `ModuleGateConfig` 补 `reject: AuthRejectFn`，**可保留 `.unknown = .deny` 同时改 404 体**。
  装渲染器后"链尾中间件改 404 体 + 放弃 `.deny`"的 workaround 可删。
- **handler 侧权限匹配**：`Context.permissionsCsv()`（与 `rolesCsv()` 同形）、
  `Context.permissionMatches(expr)`、`http.permissionMatchesContext(ctx, expr)`、
  `http.permissionMatchesWith(ctx, expr, config)`（与某个 gate 完全同语义）。
  与 gate 的 OR 语义（`portal:user|portal:shop`）共用同一实现 —— 匹配原语下沉到
  `ZigModu.security.Rbac.exprMatchesCsv` / `exprMatchesAuthInfo`，
  `permissionGateWith` 改为委托，杜绝 handler 与 gate 两套语义漂移。
- 测试：`src/test/ErrorShape.zig`（链内/路由前/未捕获 500 的形状矩阵，含"装 `defaultReject`
  为默认渲染器不得自递归"）、`src/test/PermissionMatch.zig`（OR 表达式、AuthInfo 权威性、
  `.roles`/`.rbac` 同语义）、`resilience/RateLimiter.zig` 两个并发用例
  （去守卫会放行 117/100 —— 有牙）、`redis.zig` 三个 RESP 分帧用例。
- 文档：`docs/UPGRADING.md`（逐版本 breaking / 影响面 / 一行改法）、
  `docs/ISSUES_FROM_ZIGSHOP.md`（第 1–13 条核实矩阵：属实/部分/已存在/不属实 + 依据）。

### Fixed
- **Redis 客户端四件套**：① `pool_size <= 1` 的共享单流分支**不加锁** → 命令交叠、
  流错位后端点永久挂起；② 每条命令只 `readSome` 一次 → 大回包截断且余字节留在流里污染
  后续命令；③ `read_timeout_ms` / `write_timeout_ms` 声明了但全仓无读取点 → 读可以永久阻塞；
  ④ 解析失败后连接原样放回池。现在：按 RESP 分帧读（`$`/`*` 先读长度再读体，**尾部 CRLF
  从流里消费并校验**）、无池分支由 `stream_mu` 串行化、读路径每次阻塞前 poll 到 deadline
  （超时 `RedisTimeout`）、写路径 `SO_SNDTIMEO`、任一失败即 `evictStream()` 摘除该连接。
- **`ProblemDetails.toJson` 不做 JSON 转义**：`detail`/`instance`/`type` 含引号即产出非法
  JSON（校验消息会带用户输入）。现全部经 `std.json.Stringify` 转义，
  `ValidationProblem` 同步；`statusTitle` 补全 402/411/413/414/415/416/418/428/431/451/501/505/507。
- **`RateLimiter` / `RateLimiterRegistry` / `SlidingWindowRateLimiter` 无任何同步**：
  `current_tokens` 的读-改-写竞争会**同一枚令牌被两个线程花掉**（实测去掉守卫后 100 枚令牌
  放行 117 次）；registry 的 `StringHashMap.put` 会撕裂元数据。三类各加内部短守卫
  （先 `spinLoopHint`，32 次后 `std.Thread.yield()`；临界区只有一次 map 查找或两次浮点运算，
  故不自旋到死也不引入 `io` 参数）。
- **`RateLimiterRegistry` 按值存 `RateLimiter`**：`getOrCreate` 返回的 `*RateLimiter` 指向
  map 内部存储，**下一次插入触发 rehash 即悬垂**（与 zent 连接池 UAF 同族）。改为存
  `*RateLimiter`（堆分配），指针在 registry 生命周期内稳定 —— 有"插入 257 个 key 后旧指针
  仍可用"的测试。

### Changed
- `RateLimiterRegistry.limiters` 字段类型 `std.StringHashMap(RateLimiter)` →
  `std.StringHashMap(*RateLimiter)`（**破坏性**，仅影响直读该字段的代码；用
  `get`/`getOrCreate`/`count` 的调用方不受影响）。详见 `docs/UPGRADING.md`。
- `ctx.sendError` / `ctx.sendErrorResponse` 现在优先交给进程级渲染器；未装渲染器时行为
  与之前一致，仅 `msg` 改为 JSON 转义（含引号的消息此前会产出非法 JSON）。
  装渲染器后 `sendErrorResponse` 的业务 `code` 不被表达（RFC 7807 无业务码位）。
- `ModuleGateConfig.reject` 默认仍为 `defaultReject`（信封），但 `defaultReject` 经
  `ctx.sendError` 转发，故跟随进程级渲染器；`setDefaultReject(defaultReject)` 解析为
  "不装渲染器"，避免自递归。
- `RateLimiter.acquire` 标注 DEPRECATED（与 `tryAcquire` 同义）。
- `AGENTS.md` 测试计数不再抄写具体数字，改为"以 `zig build test` 输出为准"
  （`-Ddb` 收窄、平台、门控用例都会改变计数，抄下来必然漂移）。

### Docs
- `BEST_PRACTICES.md`：新增「错误响应形状：一条开关统一全框架」（三种形状 × 触发路径 ×
  三条守则）、「共享限流器 / 统计结构的线程安全」（三个自查问题）、
  「跨函数边界返回：必须具名类型」；「数据访问选型」补 sqlx `Client`/`Transaction`
  两套签名与 `Rows`/`ManagedRows`/`BorrowedRow`/`QueryResult` 所有权表（签名已与源码核对）。
- `API.md`：新增「Error response rendering」「Permission matching」两节，校正
  `RateLimiter`（`acquire` 返回 `bool`、补 `release`）、`RateLimiterRegistry`（补 `get`/`count`
  与指针稳定性）、补 `SlidingWindowRateLimiter`。
- `AGENTS.md`：文件地图加 `UPGRADING.md` / `ISSUES_FROM_*`；DO/DON'T 加错误体统一、
  单 gate 换形状、handler 问门户三行。

## [0.15.44] - 2026-09-12

### Changed
- **zent 适配 v0.39.2 → v0.41.1**（pin 升到发布 tag `?ref=v0.41.1#2611ade`）：
  - **采用 v0.40 的一行式释放**：示例里 23 处手写 `zent.codegen.deinitEntity(infos, info, &e, alloc)`
    （含 5 处 `for (...) deinitEntity; list.deinit()` 手写循环）全部改为生成客户端的
    `client.<entity>.deinitRow(&e)` / `deinitRows(&rows)`；整页释放需要把 `const rows` 改为
    `var rows`（helper 会重置调用方的列表并使其可复用）。
  - v0.41.0：`crud_helpers.queryRows` 被明确为**裸路径**（与 `driver.query` 同类，不带你配的
    软删/隐私/拦截器），必须用 `zent.scope` 组合 —— 已补进 `docs/ZENT.md` §15。
  - v0.41.1：修复 0.40.0 把 `deinitRows(rows: anytype)` 收窄成只认值、导致传 `&rows` 编译失败的
    回归；这条与本仓库「anytype 形参的契约写法」的规矩同源，已写进 §14。
- 文档：`docs/ZENT.md` 版本口径 / §14 兼容表（新增 0.40/0.41 三条）/ §15 使用边界、
  `AGENTS.md`、示例 README 同步；四个 zent 示例全部重建通过，zent-modulith 运行时
  实测（嵌套预加载 / 列表释放 / 裸 SQL 搜索 / 事务）零错误。

## [0.15.43] - 2026-09-12

### Added
- **公开 API 错误集快照**（建议第 3 条）：`src/test/ErrorSetSnapshot.zig` 用
  `@typeInfo` 反射钉住 `verifyToken` / `Multipart.parse` / `Server.start` 的错误集——
  ①消费方 `switch` 依赖的错误必须仍在，②总数不得超过记录的上限（**放宽即破坏性变更**，
  必须在本文件里显式确认），③退化成 `anyerror` 直接失败。基线：三者当前都是窄集
  （22 / 7 / 19），**没有 anyerror**。
- **组合矩阵测试**（建议第 7 条）：`src/test/CombinationMatrix.zig` 覆盖
  `moduleGate(.unknown = .deny) × skip_prefixes`（目录内放行 / 目录外拒绝 /
  `health/*` 等跳过前缀放行）与 `tenantResolver × JWT aud × override_existing`
  （默认 aud 优先、显式覆盖时 header 优先、`require` 时无租户即拒绝、query 回退）。
- **基数纪律写成明文禁令**（建议第 8 条）：`OBSERVABILITY.md` 明确禁止把
  `tenant_id`/`user_id`/`order_id` 直接做标签（几千租户 = 几十万序列），给出两条正解
  （受限基数 family 仅用于小集合 / 租户维度留给日志与 trace），并指出"按租户分流 =
  把基数变成部署维度"。
- **升级自查从"读文档"变成"跑命令"**（建议第 4 条的一部分）：`docs/ZENT.md` §14 顶部
  给出三条命令（`zmodu audit` / `zig build check-production` / `zig build test`，
  含形态与错误集快照、文档一致性）与"升级后先删 `.zig-cache`"的硬提醒。

## [0.15.42] - 2026-09-12

### Added
- **文档 ↔ 代码一致性门禁**（建议第 6 条）：新增 `src/test/DocsConsistency.zig`，
  扫描 `docs/API.md` 里所有 `pub fn` / `pub const` 声明，逐个核对 `src/` 中是否存在
  该声明（大写名字按"类型构造器"写法放宽、忽略仅注释里出现的词），缺失即 CI 失败。
  首次运行抓出 **4 个纯虚构 API**：`TransportProtocol`、`MqttTransport`、
  `TaskScheduler`、`PasRaftAdapter`——它们从未存在于本仓库，却被当作可用能力写在
  API 参考里。已修正文档（Transport 段改为真实情况：HTTP/1.1 + h2c + gRPC，
  MQTT 明确"未提供"；Scheduler 改为真实的 `zigmodu.cron.Scheduler` 签名；
  Raft 指向 `core/cluster/RaftElection.zig` 并标注 experimental），另修掉把
  `Context.body` 字段写成方法的条目。
  范围只含 API.md：BEST_PRACTICES 有意展示**应用侧**示例代码（`OrdersApi` 等），
  扫它全是误报。

### Changed
- **`anytype` 形参的契约显式化**（建议第 1 条）：`Preflight.dbCheck` /
  `Preflight.EnvCheck.fromMap` / `PrometheusMetrics.registerMetricsRoute[Path]` /
  `Dashboard.registerRoutes` 现在
  ①doc comment 首句写明"必须是**指针**、需要哪些方法"，
  ②加 `@compileError`（含 `@typeName` 与实际修法）把错误提到**调用点**，
  ③配一条"鸭子类型替身"回归测试固定契约。
  最佳实践写法（含分类：对象指针 / 鸭子 client / 任意事件值 / comptime 元组）落在
  `docs/BEST_PRACTICES.md`「`anytype` 形参的契约写法」。

## [0.15.41] - 2026-09-12

### Added
- **`Auth.optional`：公开但可个性化的路由（一等能力）**。`Auth` 此前只有
  `inherit | public | jwt`：`public` 完全跳过验签、`ctx.userId()` 恒为空，而需要身份就等于
  `.jwt`（游客直接 401）。C 端用户中心这类"公开但想看是谁"的接口只能靠 handler 里手写
  token 检查。现在：

  ```zig
  pub const routes = [_]cr.RouteSpec(State){
      .{ .method = .GET, .path = "me", .handler = me, .meta = .{ .auth = .optional } },
  };
  ```
  语义：**有 token 就验并注入身份，token 缺失/非法/过期一律不影响请求**，永不 401。
  与 `.public` 的差别被显式化并可测试（矩阵用例覆盖 optional×{无/有效/坏 token}、
  public×有效 token、jwt×{无/有效 token}）。同时把此前只在 `authFromCatalog(AuthBackend)`
  一支存在的"尽力而为验签"抽成 `attachIdentityBestEffort`，三处中间件行为一致；
  `permissionGate` 的 public 短路不覆盖 `.optional`（这类路由仍可带 permission/roles 元数据）。

### Added

### Changed
- **CI 门禁 `check-production.sh` 覆盖全仓**：原来只扫 9 个硬编码热文件 + `src/security/*`，
  其余文件（含 auth/tracing 中间件）长期是盲区。现在按前缀分层：
  `src/api|core|http|metrics|messaging|scheduler|security` **强制**，其余
  （`ai/`、`extensions/`、`im/`、`log/`）先**告警**（28 处，作为待收紧清单）。
  扫描同时忽略注释行（文档里提到该模式不再误报）。

### Fixed
- **`catch unreachable` 的可达性收敛**（第 2 类"把环境失败当成不可能"）：8 处
  `page_allocator.create(...) catch unreachable`（中间件构造：CORS / jwtAuth /
  jwtAuthFromCatalog / …WithPermissions / authFromCatalog / tenantResolver / moduleGate /
  tracing）在 `ReleaseFast` 下是 UB，现改为 `catch @panic("<可读原因>: out of memory")`；
  2 处测试内的 `catch unreachable` 改为 `try` / `error.TestUnexpectedResult`；
  `SO_SNDTIMEO` 设置失败从静默改为 **warn**（那意味着慢客户端能无限阻塞写线程）。
- **`PrometheusMetrics` 直方图可能半初始化**：`createHistogramFamily` 里
  `counts.append(0) catch {}` 失败时会留下"有桶无计数"的直方图（`le` 行永久错误），
  现改为清理并降级到 overflow 序列，保证桶与计数始终同步。
- 重点路径上 15 处 `catch {}` 改为带上下文的 debug/warn（分布式锁回收与释放、
  HTTP/2 窗口与 RST、连接池回收与退避、outbox/cron 睡眠、access-log、
  auto-instrumentation），符合仓库既有的"不吞错误"规则。

## [0.15.40] - 2026-09-12

### Changed
- **zent 适配 v0.37.0 → v0.39.2**：`examples/zent-modulith` 的 pin 升到发布 tag
  （`?ref=v0.39.2#1fbf86c`）。两个 minor 带来：
  - **BREAKING（0.38）**：`queryTargets` / `queryTargetsByValue` 改为 **fail-closed**
    （软删 → 隐私 → 拦截器，与 `WithEdge` 同契约）；旧的"仅软删"语义改名为
    `queryTargetsUnscoped` / `queryTargetsByValueUnscoped`。目标表带策略而无
    `privacy_ctx` 时返回 `error.PrivacyDenied` 而不是静默跳过过滤。
  - **安全（0.39）**：新增 `zent.scope`，让**手写 SQL** 也能拼上同一份读契约；
    此前裸 SQL 会静默绕过租户/隐私过滤。`<col>Like`（`Contains` 的诚实名字）、
    NULL 容忍扫描器（`scanRow*Lenient` / `queryAllLenient`）、`zent.version`。
- **文档同步**：`docs/ZENT.md` §4.7 补"裸 SQL 的安全前提（必须接 `zent.scope`）"，
  §14 兼容表新增 0.38/0.39 两条升级注意，§15 增加三条使用边界（scope、fail-closed
  邻居读取、宽松扫描器的适用面），版本口径与依赖示例更新到 v0.39.2。

## [0.15.39] - 2026-09-12

### Changed
- **`ctx.query` / `ctx.form` 升级为多值容器 `Params`**（zapi 反馈 P1-4）：重复键
  （`ids=1&ids=2`，即 `<select multiple>` / 复选框组的原生形态）不再被覆盖，括号键
  （`role_id[0]`、`tags[]`）按原样保留供上层解释。**兼容性**：`get()` 仍返回**最后**一次
  出现的值（与旧的单值 map 语义一致），消费侧 `ctx.query.get("page")` 无需改动。

  ```zig
  ctx.query.get("ids")            // 最后一次（历史语义）
  ctx.query.getFirst("ids")       // 第一次
  ctx.query.getAll("ids")         // 全部（到达顺序）
  ctx.queryArray(alloc, "ids")    // 重复键或 ids[0]/ids[]（索引排序）
  ctx.formArray(alloc, "role_id") // 表单同上
  ctx.paramPath("filter.tags")    // 点路径 → filter[tags]（form 优先、回退 query）
  ctx.bindForm(T) / bindQuery(T)  // 绑定契约不变；现也吃重复键与 role_id[0] 首元素
  ```
- **参数数量上限**：`Server.Config.max_params`（默认 1000，对标 PHP `max_input_vars`）。
  query 与 form 都按"出现次数"计数，超限返回 `error.TooManyParams`，**不静默截断**。

### Added
- `zigmodu.http.Params` 导出（`put`/`putOwned`/`get`/`getFirst`/`getAll`/`getArray`/
  `getPath`/`getSegments`/`count`/`totalValues`），6 个新测试覆盖重复键、括号数组
  （索引排序 + `[]` 追加 + 无括号回退）、点路径、参数上限与所有权转移。

## [0.15.38] - 2026-09-12

### Added
- **`multipart/form-data` 一等支持**（zapi 反馈 P1-5）：`src/http/Multipart.zig` +
  `ctx.multipart(cfg)` / `ctx.bindMultipart(T, cfg)`。

  ```zig
  var form = try ctx.multipart(.{});         // defer form.deinit();
  const title = form.value("title");         // 文本字段
  if (form.file("avatar")) |f| { ... }       // 文件：f.data / f.filename / f.content_type
  // 文本字段也可整批绑定：
  const Meta = struct { full_name: []const u8, age: i64 };
  const meta = try ctx.bindMultipart(Meta, .{});   // 与 bindForm 同一套 loose 绑定契约
  ```

  要点：文本查找**永不返回文件块**（`value()` 跳过带 filename 的 part）；「首次命中优先」
  与 `bindForm` 一致；整个 body 在内存中解析（框架本身已缓冲请求），因此防护是 `Config`
  限额 —— `max_parts` / `max_part_bytes` / `max_total_bytes`，超限分别返回
  `TooManyParts` / `PartTooLarge` / `PayloadTooLarge`，而非盲目分配。
  **不做流式落盘**（请求体已被缓冲，流式 API 只会假装省内存），落盘是应用决策。
  新增 5 个测试（boundary/Disposition 解析矩阵、混合表单含文件、四类拒绝路径、
  文本字段桥接、Context 端到端）。

### Added
- **静态文件服务**（`zigmodu.http.staticFiles` / `StaticFiles.staticMiddleware`，zapi 反馈 P1-6）：

  ```zig
  try zigmodu.http.staticFiles(io, &server, allocator, "/assets", "public", .{
      .cache_control = "public, max-age=3600",
  });
  ```

  实现为**中间件**而非路由：路由器现阶段的 `/prefix/*` 只匹配前缀本身，路由式挂载无法服务其下文件。
  行为约定：只服务 `GET`/`HEAD`（其余 405）；**不做目录索引/列表**（`/assets/` → 404）；
  路径先归一化再碰文件系统（`..`、绝对路径、反斜杠、`:`、NUL 一律拒绝）；
  `ETag`（size+mtime）支持 `If-None-Match` → 304；`Range` 支持 206 / 416（多段范围回落为整实体）；
  超过 `max_bytes`（默认 16 MiB）返回 413 而不是整文件读进内存；
  正文按 `chunk_bytes` 分块读取。挂载对象按进程生命周期分配（所有权契约写在文件头注释里）。

### Fixed
- **表单体的解码口径与 query 不一致**（`parseFormBody`，zapi 反馈 P0-1）：query 的
  key/value 都会 percent-decode，而 form body 原样 `dupe`。后果有两层：`formValue("name")`
  拿到的是 `%E5%BC%A0%E4%B8%89` 而不是 `张三`；更隐蔽的是 **key 也未解码**，浏览器把嵌套键
  编成 `role_id%5B0%5D`，于是 `formValue("role_id[0]")` 永远查不到。现在两条路径同一口径
  （`%XX` 与 `+`→空格 都在解析期处理）。
  ⚠️ **迁移提示**：消费侧若自己补了解码器（zapi 的 `contract/params.zig` 即此类），
  需要删掉，否则会对已经解过的值再解一次；这类解码器同时可删的还有"逐字符比较原始 key"
  的查找函数。
- **CORS 空 allowlist 的失败模式不可诊断**（`Middleware.cors`）：显式传空
  `allow_origins` 时所有跨域请求（含预检）一律 403 且无任何提示；现在启动时会 warn 一行。
  （默认值仍是 `&.{"*"}`，只有主动传空数组才会触发。）

### Added
- **`ctx.bindForm(T)` / `ctx.bindQuery(T)`**（zapi 反馈 P0-2）：表单与查询的声明式绑定，
  语义与所有权对齐 `bindJsonLoose` —— 字段名 loose 匹配（`role_id` ↔ `roleId`）、
  缺省值保留、字符串字段深拷贝（调用方统一 free）、缺必填字段返回 `error.MissingField`
  而不是静默零值。支持 `[]const u8` / 整数 / 浮点 / `bool`（`1/0/true/false/on/off`）
  及其 `?T`；其它类型是编译期错误（不静默跳过字段）。
  同时支持嵌套键的**首元素**绑定：字段 `role_id` 可直接吃下 `role_id[0]`。
- **`ctx.pathParam(name)`**：`param` 的显式别名，消除"路径参数 vs 任意参数"的误读。
- **`ctx.jsonValue(status, value)`**：`jsonStruct` 的别名。**注**：zapi 反馈称"框架只有
  `ctx.json(bytes)`"，实际 `jsonStruct(status, anytype)` 早已存在且正是"任意 Zig 值 →
  JSON"（P0-3 的真实缺口是命名可发现性，不是能力）。

### Added
- **Best-effort identity on `.public` routes.** `authFromCatalog` now verifies a
  presented token even when the catalog marks the route `.public` and attaches
  the resulting identity, instead of skipping verification outright. A missing,
  malformed, or expired token changes nothing — the route stays public and
  `verifyFn` never writes a response — but a *valid* one lets a public handler
  optionally personalize (`ctx.userId()` / `optionalPortalUser`). This closes
  the gap where a public-but-personalized endpoint (e.g. a C-end user center)
  always saw an anonymous caller, since the framework had no "optional auth"
  mode (`Auth` is `inherit | public | jwt`). Cost on public routes: one header
  lookup without a token, one JWT verification with one.

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.15.37] - 2026-09-12

### Fixed
- **CI `Test (DB=postgres)` 失败**：新增的真实 PG 锁用例连不上 CI 的 service 容器。
  根因是 sqlx 的 PG 驱动默认 `sslmode=require`（安全默认，保持不改），而测试用
  service 不支持 TLS —— 仅在该 job 里设 `PGSSLMODE: disable`（一次性测试库）。
  已用同一条件在本地复现并验证。
- **CI `Benchmark` job 首次真正执行即失败**：`benchmark-action` 需要 `gh-pages`
  分支，仓库还没有 → 加 `skip-fetch-gh-pages: true` 让其自举（该 job 此前因
  分支条件写错从未运行，v0.15.36 修好条件后才暴露）。

## [0.15.36] - 2026-09-12

### Changed
- **zent 适配 v0.33.0 → v0.37.0**：`examples/zent-modulith` 的 pin 升到发布 tag
  （`git+…?ref=v0.37.0#d36edb7`）。新版本带来：池 `max_wait_ms` 真正阻塞等待
  （默认 0 = 旧语义）、嵌套预加载每层一次查询（消除 N+1）、outbox 认领式派发
  （可并发 dispatcher）、迁移默认加锁 + checksum 校验、`StorageKey` 字段↔列名映射、
  `queryTargetsByValue`（UUID 主键也可遍历边）、`BulkInsert` 按参数上限分片、
  参数化原生谓词 `sql.RawArgs`、聚合助手、upsert 自定义表达式、边写入
  （`AddEdgeIDs`/`RemoveEdgeIDs`/`SetEdgeIDs`/`ClearEdge`）。
- **补齐 v0.36 的崩溃恢复语义**：`examples/zent-modulith` 的 dispatcher 每次派发前
  调 `Outbox.requeueStale(..., 300)`，把"认领后派发进程死掉"遗留的 `processing`
  行放回 `pending`（否则这些行永久卡住）。
- 文档同步：`docs/ZENT.md` 版本口径与 §14 兼容表（新增 0.34–0.37 四条升级注意）、
  `AGENTS.md` 已知事实、`examples/zent-modulith/README.md`、
  `examples/{shopdemo-zent,metaverse-creative}/build.zig.zon` 注释。

### Docs
- **最佳实践补全**：`docs/BEST_PRACTICES.md` 新增「生产就绪检查清单」（进程/HTTP/数据并发/
  可观测/验证发布五组，每条都标注承接它的能力）与「数据访问选型（zent / sqlx）」；
  修复目录与正文脱节（补上韧性/背压/预检/kid/迁移恢复/多副本/工具/陷阱/升级/协作等条目）并
  删除一处重复的「模块设计原则」标题残片。
- **`docs/ZENT.md` 新增 §15「v0.34–v0.37 实战用法与边界」**：逐能力给出"什么时候用 /
  什么时候不要用"，含 12 条易踩点（金额聚合用 `AggregateText`、边写入要包 `beginTx`、
  `requeueStale` 阈值须大于最长发布时间、池 `deinit` 静默期、预加载目标不带租户作用域、
  SQLite 表达式 upsert 换实现等）；§14 标题与目录对齐到 0.37。

### Added
- **故障注入测试**（`src/test/FaultInjection.zig`）：走完整 HTTP 链路验证韧性行为，
  而不只是状态机单测 —— 下游挂 → 两次失败后熔断 → **后续请求不再打下游**（断言
  调用计数不增长）→ 恢复窗口后半开探测 → 成功即闭合恢复；限流器 2 令牌后回 429。
- **契约门禁**（`src/test/ContractGate.zig`）：注册接口承诺（状态/响应体片段/头），
  经真实路由 dispatch 后逐条校验，漂移即构建失败；负例验证漂移会被报告而不是
  静默通过。`ContractVerificationResult` 新增 `deinit`（此前所有权无处释放）。
- **真实 PostgreSQL 的锁验证**：`DistributedLock` 的 `.postgres` 方言在 PG 17 上
  实测通过（双 owner 互斥、释放移交、过期回收）；经 `ZIGMODU_TEST_PG=1` 门控，
  CI 的 `test-postgres` job 已带上该变量与 PG 环境变量。
- **迁移失败恢复指引**：`docs/BEST_PRACTICES.md` 新增运维小节，写清 `success=false`
  重试语义、部分生效要求幂等、`ALTER TABLE` 失败被跳过的代价，及现场查询 SQL。
- **CI 夜间 soak job**：`schedule`（每天 03:17 UTC）+ 手动触发，
  `zig build soak -Dsoak-clients=64 -Dsoak-iterations=200`，带 30 分钟超时。
  跨租户泄漏与冻结注册表并发断言终于有了持续运行的场地（默认 push/PR 不跑，
  保持反馈速度）。
- **旗舰示例改用生产配置**：`examples/tenant-mgmt` 从手工拼中间件切到
  `http.productionProfile`（连接背压 + 安全/观测中间件 + `/metrics` +
  `/health/live` + `/health/ready`，删掉自带 health 路由避免重复）。
- **路由标签归一化**：ComptimeRouter 的模式不带前导 `/`，而 server 级路由带 ——
  指标标签统一补 `/`，避免同一接口裂成两条序列。
- **`zigmodu.Preflight`**（`src/core/Preflight.zig`）：启动预检，把"凌晨三点炸"变成
  "拒绝启动"。内置 `envCheck`（缺必填变量）/ `secretCheck`（占位或过短的 JWT
  secret）/ `dbCheck`（SELECT 1）/ `migrationCheck`（有待应用迁移）/
  `clockCheck`（时钟偏移）；`Severity.warn` 只告警，检查之间互不影响，不 panic。
  参考接线见 `examples/zmsaas/backend/src/main.zig`。
- **JWT 密钥轮换（kid）**：`SecurityModule.setKeyring(&JwksKeyRing)` —— 新 token 头部
  带 `kid`，验签按 `kid` 取密钥，旧密钥留在环里即可无缝轮换；未知 `kid` 返回
  `error.UnknownKeyId`（不退化成"用主密钥试一下"）。不设 keyring 时行为不变（无 kid）。
- **CORS 通配符告警**：`productionProfile` 在 `cors_origin = "*"` 时打 warn。
- **受限基数的指标标签**：`PrometheusMetrics.createCounterFamily` /
  `createHistogramFamily`（单标签 + 硬上限，超额统一进 `route="__other__"`）。
  `productionProfile` 的黄金信号全部按 **`ctx.route_template`**（匹配到的模式，
  不是带 id 的原始 path）打标签 —— 终于能回答"哪个接口在慢"。
  新增 `Context.route_template`，在两处分发点（`handleForTest` / connFiber）设置。
- **业务面黄金信号**：
  - `OutboxConsumer.setMetrics(metrics)` → `outbox_selected_total` /
    `outbox_delivered_total` / `outbox_failed_total` / `outbox_pending`；
    `pendingCount()` 查积压，`startPolling(io, interval_ms)` 内置后台轮询
    （取代手工 cron），失败计数 `consecutive_failures`。
  - `PrometheusMetrics.setScrapeHook(hook, userdata)`：**抓取时采样**，无需后台
    线程即可刷新连接池/积压等 gauge。
  - `Client.poolMetrics()`：暴露已有的 `ConnPool.PoolMetrics`
    （active / idle / waiters / 各项计数）。
- **`zigmodu.DistributedLock`**（`src/core/DistributedLock.zig`）：后台任务的跨实例互斥。
  接口 `Lock.tryAcquire(name, ttl_ms)` / `release(name)` + `NoopLock`（默认，保持
  单进程行为）+ `SqlLock(Client)`（表锁，`.sqlite` / `.postgres` 用
  `ON CONFLICT DO NOTHING`、`.mysql` 用 `INSERT IGNORE`，靠 `rows_affected`
  判定抢占，争用不是错误）。持有者崩溃后由 `ttl_ms` 过期回收。表名做标识符校验。
- **cron 跨实例互斥**：`Scheduler.setLock(lock, ttl_ms)` —— N 副本部署时每个 job
  每分钟只在一个副本上执行（`cron:<job>` 为锁名）；未设锁时行为与之前完全一致。
- **迁移跨实例锁**：`MigrationRunner.setLock(lock, ttl_ms)` —— 滚动发布时并发实例
  不会再抢着建历史表/执行 DDL；抢不到锁返回 `error.MigrationLocked`。
- **`http.productionProfile()`**（`src/http/Profiles.zig`，导出
  `zmodu.http.productionProfile` / `ProductionConfig` / `ProductionProfileState`）：
  一行接齐生产配置 —— 连接背压（`max_connections` / `over_limit_response` /
  `header_timeout_ms` / `request_timeout_ms`）、安全与观测中间件
  （CORS + request-id + recover + security headers + tracing + access log）、
  `GET /metrics`、`GET /health/live` + `/health/ready`、可选 dashboard。
  路径可配。**必须在 `router.mountAll` / `addRoute` 之前调用**（`addRoute` 会在
  注册时快照全局中间件链）。
- **黄金信号指标**：`productionProfile` 默认维护 `http_requests_total`、
  `http_responses_{2xx,3xx,4xx,5xx}_total` 与
  `http_request_duration_milliseconds` 直方图（1ms–5s 固定桶）。
- **`docs/OBSERVABILITY.md`** + **`docs/grafana/zigmodu-overview.json`**
  （7 面板）：PromQL 速查、告警阈值起点、Prometheus/K8s 抓取配置、上线自检。
- **生产部署参考** `examples/production-deploy/`：nginx / Envoy TLS 终结 +
  h2c 反代、docker-compose、K8s（探针/HPA/Prometheus 注解）、systemd
  （`Restart=always`）、多阶段 Dockerfile。
- **WebSocket 出站背压**：`Server.Config.ws_write_timeout_ms`（`SO_SNDTIMEO`，
  0 = 旧行为）+ `WsFramer.isWritable()` 水位探测。超时写返回
  `error.WriteTimeout` 并 shutdown 连接，慢客户端不再无限阻塞写线程。
- **`PrometheusMetrics.registerMetricsRoutePath`**：可自定义 metrics 路径。
- **`-Dnet-tests=false`**：沙箱环境跳过全部依赖 loopback 的测试（统一经
  `NetworkProbe.available()` 收口）。
- **`zmodu.NetworkProbe`** 导出。
- **连接级背压与慢连接防护**（`src/api/Server.zig`）：`Config.max_connections`
  （0 = 不限）+ `over_limit_response`（`.close` / `.unavailable` 回 503，走裸
  socket 写以免阻塞 accept 线程）、`Config.header_timeout_ms`（请求行 + header
  阶段总 deadline，超时回 408；header 读完后立即解除，不误杀慢速上传）。支持
  `HTTP_MAX_CONNECTIONS` / `HTTP_HEADER_TIMEOUT_MS` 环境变量。连接计数
  `active_connections` 在 accept 时预留、fiber 退出时释放。
- **并发浸泡测试**：`zig build soak`（`-Dsoak-clients` / `-Dsoak-iterations`）。
  真实 socket 的 N 并发 × M 租户压测，断言跨租户读取为 0、FrozenMap 在并发读 +
  拒写下不撕裂、连接计数回落 0。刻意不挂在 `zig build test` 上。
- **audit b22**：拦截 `.tenant_source = .query`（客户端可篡改的租户来源）。
- **`zmodu.NetworkProbe`** 导出（受限沙箱里 socket 测试的跳过探针）。
- **`FrozenMap` / `FrozenStringMap`**（`src/core/FrozenMap.zig`，导出
  `zmodu.FrozenMap/FrozenStringMap`）：启动期填充、`freeze()` 后只读的
  共享注册表容器。冻结后读无锁、任意并发安全；写返回 `error.Frozen`。
  针对 worker 池上并发 put/resize 撕裂 HashMap 元数据导致读者
  `panic: incorrect alignment` 的崩溃类别。
- **panic 钩子**（`src/api/PanicHook.zig`，导出 `zmodu.panicHook`）：
  Server 在 dispatch 前将当前请求 `METHOD /path` 写入 threadlocal，
  panic 时先输出该上下文（无分配、固定缓冲）再走
  `std.debug.defaultPanic`。应用 root 一行接入：
  `pub const panic = zmodu.panicHook;`。
- **`zmodu audit` 新规则**（`tools/zmodu/src/audit.zig`）：
  b19 请求路径裸 panic（`@panic` / 语句级 `unreachable;`）、
  b20 文件作用域共享可变 HashMap（建议 FrozenMap）、
  b21 请求路径裸 `@alignCast`（豁免 `ctx.user_data` 与
  `@alignCast(self)` 单例注册）。

### Security
- **zent-modulith 示例不再信任客户端租户**：`zent_crud.CrudApi` 的
  `.tenant_source` 由 `.query` 改为 `.attr`，products 五条路由接入
  `jwtAuthFromCatalog`（租户取自 JWT `aud` claim）。此前改一个 URL 参数
  `?tenant_id=` 即可跨租户读取。配套新增 dev-only 取 token 路由
  （`ZENT_DEV_TOKEN=1` 才挂载，明确标注为后门）与 README 更新。

### Fixed
- **CI benchmark job 从未执行**（`.github/workflows/ci.yml`）：`if` 只匹配
  `refs/heads/main`，而默认分支是 `master` → 性能回归门禁（`alert-threshold`
  150%）形同虚设。与其它 job 一致改为 `main || master`。
- **`HealthEndpoint.handleReadiness` 编译错误**（`const details` 却调用
  `components.deinit(*Self)`）——任何调用方都会编译失败，readiness 端点不可用。
- **`Dashboard.registerRoutes` 两处编译错误**：`handleModules` 的 `allocPrint`
  缺参数元组、`get` 需要 `*RouteGroup`。`productionProfile(.dashboard = true)`
  暴露了它们。
- **`config` 模块的 `readToEndAlloc` 失效 API**（`YamlToml` ×2 /
  `ConfigManager` / `TomlLoader`）：Zig 0.17 已移除该方法，`parseFile` /
  `loadJson` / `loadFile` 属于"导出但一用就编译失败"的公开 API，现改用
  `Dir.readFileAlloc`，并补 `YamlParser.parseFile` 端到端测试。
- **Server `stop()` 在 Linux 上唤醒阻塞的 `accept()`**（`src/api/Server.zig`
  `closeListener`）：先 `shutdown(SHUT_RDWR)` 再 close。Linux 下 close 不会
  中断阻塞中的 accept（内核为进行中的调用保持 socket 存活），accept 循环
  永不退出、`join` 死锁——ubuntu CI `Run tests` 曾因此挂起 50 分钟。
- **WS fiber 测试自定义栈 128KB → 2MB**（`src/api/Server.zig`）：glibc
  aarch64 `PTHREAD_STACK_MIN=131072` 恰为 128KB，TLS 无空间导致
  `pthread_create` EINVAL（std 内 unreachable panic）。
- **示例内存泄漏（audit b17）**：tenant-mgmt `getById` 结果在
  updateTier/suspendTenant/getTenant 三处从未释放；updateTier 混用静态
  字符串破坏 owned 语义（统一改为 dupe + defer freeTenant）。
  tenant-shop `Tx.priceCents` 改用 `freeScanned`。

### CI
- **CI 全链路修复并首次全绿**：job 级 `if` 误用 `env` 上下文导致工作流
  历史上从未调度（0s 失败）；mlugg/setup-zig 旧式 URL 404（改为直接从
  ziglang.org 下载 arch-first tarball，Zig pin 升至 0.17.0-dev.1970）；
  ubuntu 缺 `libmariadb-dev-compat`（`libmysqlclient.so` 由该包提供）；
  示例路径 `zfsaas`→`zmsaas` 改名未同步；integration / mysql /
  live-service 三个 job 失败时上传日志 artifact 便于诊断。

## [0.15.35] - 2026-09-03

### Security
- **`validateSqlFragment` 黑名单加固**（`src/sqlx/sqlx.zig`）：新增拒绝反引号
  （MySQL 标识符引用）、`#` 注释、`*/` 闭合注释，以及整词匹配（大小写不敏感）
  的语句关键字 `UNION` / `SELECT` / `INSERT` / `UPDATE` / `DELETE` / `DROP` /
  `ALTER` / `CREATE` / `ATTACH` / `DETACH` / `PRAGMA` / `EXEC` / `EXECUTE` /
  `TRUNCATE` / `GRANT` / `REVOKE` / `REPLACE`。标识符内子串（如
  `updated_at`、`selection`）不误伤；`IN (?, ?)` 等括号谓词不受影响。
  值仍必须走 `?` 占位符——此为纵深防御而非主防线。
- **JWT 空 `aud` 不再写入 `tenant_id` attr**（`src/api/Middleware.zig`）：
  原先空串 attr 会遮蔽 `X-Tenant-ID` 回退路径并让下游 int 解析失败；
  现在 `aud` 为空时 attr 缺省（`ctx.tenantId()` 返回 null）。

### Changed
- **EventBus 线程安全语义澄清**（`src/core/EventBus.zig`）：文件头原注释自称
  "Thread-safe" 与事实相反，已修正；`EventBus` / `TypedEventBus` /
  `UnifiedEventBus` 均显式标注 NOT thread-safe，并发场景指向
  `ThreadSafeEventBus`。`ThreadSafeEventBus` 新增 `publishedCount()`。
- **`CrudService.setEventBus` 改收 `*ThreadSafeEventBus`**（`src/data/CrudService.zig`）：
  CRUD 事件在 HTTP handler 线程发布，原 `*TypedEventBus` 无同步保护。
  zmodu 代码模板（`service_header.zig.tpl`、smoke 脚手架、`saas` 生成器）
  同步默认生成 `ThreadSafeEventBus`。
- **`tenant-mgmt` 示例落地真实租户隔离**：租户中间件从空壳改为
  JWT `aud` 优先、`X-Tenant-ID` 头回退（dev 路径）、两者冲突 403；
  user/subscription handler 改经 `requireTenantId(ctx)` 读 attr，
  不再信任 `?tenant_id=` query；`GET /subscriptions/{tenant_id}` 校验路径
  租户与上下文一致，跨租户 403。中间件顺序修正为 JWT → tenant。
  `ci-integration.sh` 新增三条租户隔离探针（401/200/403）。
- **`check-production.sh` 门禁覆盖全文**：`Server.zig` / `sqlx.zig` 的硬编码
  行号截断（1700/2739）改为与其它热路径一致的动态截断（首个 `test "` 行），
  消除后半文件不受约束的盲区；扩扫后当前零违规。
- **README**：`DistributedEventBus` / `SagaOrchestrator`（及 zh 版
  ClusterMembership & Raft）补 ⚠️ experimental 标注；`examples/README.md`
  移除四个不存在的幽灵示例章节（dependency-injection / architecture /
  v2-showcase / ecommerce）并同步学习路径与统计表。
- `gen-jwt-token` 支持 `JWT_AUD`（生成带 `aud` 的 token，供租户探针使用）。
- **EventBus / DI 接入 Application**（闭环"主推抽象未接线"）：新增
  `core/EventRegistry.zig`（按 `@typeName(T)` 类型擦除的 get-or-create
  注册表，只发放 `ThreadSafeEventBus`）与 `core/ModuleContext.zig`
  （`allocator`/`io`/`events`/`services`）。模块可选声明
  `pub fn initWith(ctx: *ModuleContext) !void`——`ModuleScanner` 编译期
  探测（`@hasDecl`）、`Lifecycle.startAllWith` 优先调用（与 `init` 并存时
  只调 `initWith`；仅 `initWith` 而无 ctx 时启动失败并回滚）。
  `Application` 持有 `events` + `services`，`start()` 完成后
  `services.freeze()`（之后 `get` 为无锁只读、注册报 `ContainerFrozen`）；
  新增 `app.eventBus(T)` / `app.service(T, name)` 与
  `Builder.withService(T, name, ptr)`（借用注册，容器不销毁实例）。
  `di.Container` 新增 `registerBorrowed`（修复栈指针注册被 deinit 销毁的
  所有权陷阱）。shopdemo 成为首个真实使用者：order 服务经
  `app.eventBus(OrderEvent)` 接线并在 create 时发布事件。最佳实践文档：
  `docs/EVENTS_DI.md`（MODULITH.md §2.3/§4 与 AGENTS.md 文档地图已交叉引用）。

### Changed
- **zent 适配 v0.32.3**（sqlite 连接访问串行化修复，公共 API 无签名变化）：
  `examples/zent-modulith` pin 升至 `v0.32.3` tag；`docs/ZENT.md`
  版本口径与远程 zon 样例同步，§14 新增升级条目（`Rows` 持锁至
  `deinit()`、遍历完立即释放）；`AGENTS.md` / 示例 zon 注释同步。
  `examples/metaverse-creative` 修复 libpq 链接：`src/db.zig` 引用
  `zent.sql_postgres`，而 zent 在检测到 libpq 头文件时接入 `pg_c` 却
  不链库本体——`_shared/db_link.zig` 新增 `linkDetected()`（检测到才
  链接），示例 build.zig 经它为 `zent_mod` 链接 pq。
  `examples/zent-modulith/README.md` 的 products 载荷补必填的
  `price`（Decimal 列）字段。
- **zent 适配 v0.33.0**（`UseInterceptor` 覆盖 Create/BulkInsert——create
  上 `whereEq` 语义为"缺省才填"，显式值保留）：`examples/zent-modulith`
  pin 升至 `v0.33.0` tag，并落地真实拦截器演示路由
  `GET/POST /api/v1/tenant-injection`（`features_demo.InterceptorApi`）：
  独立 client + 哨兵租户 777，create 缺省填充、查询透明限定，验证
  v0.33.0 写路径拦截在消费端生效（此前头注释宣称该演示但实际未实现）。
  `docs/ZENT.md` §14 新增升级条目（**存量拦截器升级后会开始影响写入，
  需先审计**）；README 补对应章节。⚠️ 排障记录：Zig 0.17-dev 增量缓存
  对 path/fetch 依赖的模块变更可能不失效——升级依赖后行为未变时先删
  示例的 `.zig-cache` 再重建（本次实测：symbol 探针证明二进制里是旧版
  zent，清缓存后一次性通过）。

### Removed
- **`persistence/Database.zig` 的 stub `Repository(T)`**：纯空壳
  （所有方法 no-op）且无任何租户变体，与 `Orm.zig` 的 `Repository(T)`
  同名并存易误用。零调用点，直接删除。规范入口仍是 `data.Repository(T)`。
- **`TenantContext.getDefault()`**：返回非原子可变全局指针、标注
  "non-concurrent use" 且零调用点，属待触发隐患。新增
  `TenantContext.fromAttr(?[]const u8) ?TenantContext` 桥接 HTTP attr
  通路与 TenantContext 类型（attr 缺失/非法/非正数 → null）。

## [0.15.34] - 2026-08-31

### Changed
- **zent 升级 v0.32.1 → v0.32.2**（纯修复，零 breaking）：v0.32.2 修复连接池
  use-after-free（`swapRemove` 移动尾元素导致借出指针被污染，空闲驱逐后
  health-check 段错误）、MySQL 非整数主键 upsert（字符串/UUID PK 回退
  `VALUES(pk)` 而非 `LAST_INSERT_ID`）、多线程池测试改用线程安全 allocator。
  `examples/zent-modulith` zon 锁定 `git+https#v0.32.2`（hash
  `zent-0.32.2-oiur-xP7DwCyv9mm_lt74G6jR5qmlJYBW6hGBJ3bkXUv`），文档版本口径同步。

## [0.15.33] - 2026-08-31

### Fixed
- **accept 循环被 keep-alive 连接卡死（服务器整体停止 accept 的挂死）**：
  `Server.start` 原先用 `conn_group.async` 派发 connFiber。`std.Io.Threaded`
  的 `groupAsync` 在 `busy_count >= async_limit`（默认 cpu_count-1）时回退为
  `groupAsyncEager`——在 accept 线程上同步执行 connFiber。connFiber 是
  keep-alive 读循环，客户端挂机不发下一请求时永久阻塞在 `readv`，accept
  循环从此被占死、对所有新连接静默。修复：改用 `conn_group.concurrent`
  （默认 `concurrent_limit = .unlimited`，**不会 eager 回退**，超限时返回
  错误而非劫持调用线程）；超限时拒绝该连接并继续 accept。同类隐患一并修复：
  `WebSocket.zig` / `DistributedEventBus.zig` 的 accept 循环派发
  handleConnection 同样由 `async` 改为 `concurrent`。

### Changed
- **zent 升级 v0.32.0 → v0.32.1**（纯新增 + CI 修复，零 breaking）：v0.32.1
  新增 interceptor 多租户查询改写示例与 eager/upsert 基准，并修复四个既有
  CI 失败；已 pin zigmodu v0.15.32 并移除其 libc 补丁。`examples/zent-modulith`
  zon 锁定 `git+https#v0.32.1`（hash `zent-0.32.1-oiur-3jiDwAri-…`），
  文档版本口径同步 v0.32.1。

## [0.15.32] - 2026-08-27

### Added
- **sqlx 读写分离（read/write splitting）**：`Client.withReplica(&replica)`
  注册只读副本——`query`/`queryCursor` 及其派生（queryRow/queryRows/
  findOne 等）路由到副本，`exec`/`beginTx`/batch 写入恒走主库；副本读失败
  自动回退主库（降级为单主模式而非报错），副本自身的熔断器打开时直接用
  主库。附路由正确性与故障回退两组回归测试。
- **HTTP header 数量/总字节上限（header 炸弹 DoS 防护）**：
  `Server.Config.header_limits`（默认 100 个 header / 16KB 总量），超限返回
  `error.TooManyHeaders` → HTTP 431。此前 body 有 `max_body_size` 但 header
  无上限，攻击者可发大量合法小 header 耗尽请求 arena。

### Fixed
- **`zmodu` CLI 缺 `link_libc`**：`build.zig` 里 zmodu 模块未设
  `link_libc = true`，Zig 0.17-dev.813 起 `@cImport` 不再隐式链接 libc，
  依赖方（如 zent CI）需打补丁兜底。现已与框架主模块一致显式链接。
- **Cron scheduler `deinit` 潜在 UB**：mutex lock 失败被吞后继续 unlock
  （futex 后端下 unlock 未锁住的 mutex 是未定义行为）——现在 lock 失败时
  记录错误并跳过配对 unlock 与任务清理。
- WebSocket：pong 发送失败静默吞噬 → debug 日志（对端会由下次心跳暴露）；
  升级拒绝路径补 best-effort 注释。HttpClient 连接池回收路径同注释化。
- **`ComptimeRouter.wrapHandler` 双重缺陷**：`handler` 改为 comptime 参数并移除
  共享的容器级 `var Store`——旧实现里同一 `State` 的所有 wrapper 共享一个
  `Store.fn_ptr`（后写覆盖），`openApiRoutes` 的 `openapi.json`/`docs`/`scalar`
  三条路由会串台到最后注册的 handler；且在 `pub const routes` 等 comptime
  上下文中触发 `unable to evaluate comptime expression`。
  `openApiFromCatalog` 的运行时状态同步提升为容器级 `OpenApiRouteStore`
  （单 catalog 契约已注释声明），公共 API 签名不变。新增独立派发回归测试。
- **`zmodu orm --backend zent` 外键解析两处 bug**：表级
  `FOREIGN KEY (col) REFERENCES …` 的列名被截成 `col)`（右括号未剥）并再次被
  内联扫描重复抓取；内联 `col TYPE NOT NULL REFERENCES …` 回溯只吃一个类型词、
  把修饰词误当列名。修复：第二遍跳过 `)` 结尾的表级引用，回溯改为抓到行首/
  逗号后按「修饰词剥离 + 类型词丢弃」取列名。**同时新增外键 → edge 声明生成**
  （`edge.From("<name>", Ref).Field("col")`），两种 FK 书写形式均验证通过。

### Changed
- **OTLP / Vault 支持 HTTPS**（此前文档口径「待 stdlib」实际是滞后）：
  `OtlpExporter.exportSpans` 与 `SecretsManager.loadFromVault` 复用
  HttpClient 的 `std.http.Client` TLS 1.3 通道（系统 CA 信任库），
  移除 `OtlpTlsNotSupported` / `VaultTlsNotSupported` 短路；https 端点
  现在直达，证书链需入系统信任库。AGENTS 文档口径同步。
- **WebSocket 显式 `max_frame_size`**：`WebSocketServer.max_frame_size`
  （默认 4096）+ `setMaxFrameSize`，帧读取 buffer 按该值动态分配，替换原先
  隐含在 4KB 栈缓冲里的硬上限。
- **zent 升级 v0.29.8 → v0.32.0**（纯新增版本，零 breaking 验证）：
  `examples/zent-modulith` zon 锁定 `git+https#v0.32.0`
  （hash `zent-0.32.0-oiur-4vYDwDyEvLh_lnPwxRmJdXAc5920URMil2NQatJ`），
  `examples/shopdemo-zent` 按本地 sibling v0.32.0 构建通过；新增能力可用：
  `SaveOrUpdateOn`/`SaveIgnore` upsert、`Row.tryGet*`、`field.Decimal`（精确
  金额列）、`WithEdgeOptions` inner-join eager loading、`beginTxFromDriver`、
  `managedEntity`/`dupeEntityTo` allocator 安全 teardown、v0.32 Interceptor
  运行时查询拦截、PreparedCache 字节级 key 比对（hash 碰撞修复）。
- **`zmodu orm --backend zent` 模板修复**（生成代码此前无法编译）：
  `client.zig` 返回类型改为泛型实例化 `zent.codegen.client.Client(infos)` 并
  导出 `pub const infos/Client`；schema 体改 `pub const` 并由 client 经
  `schemas.*` 引用；移除 zent 已不存在的 `.Required()` 链式调用（字段默认
  NOT NULL，nullable 列才 `.Optional()`）；`.Default` 按列类型发零值字面量
  （Int→`0`，旧 `""` 在 PG 上是非法 DDL）；zent 版 `module.zig` barrel 改为
  导出实际生成的 `schema`/`client`。生成结果已对 zent v0.32.0 实测编译通过。

### Documentation
- **`docs/ZENT.md` 升级为电商/社交主推组合指南**（版本口径 v0.32.0）：顶部新增
  主推定位；§2 决策表电商/社交默认 zent；新增 §4.8「电商 / 社交主推能力矩阵
  （v0.30–v0.32）」（`field.Decimal` 精确金额、`SaveOrUpdateOn`/`SaveIgnore`
  业务键幂等、`WithEdgeOptions(.inner)` 防 limit skew、`beginTxFromDriver`
  池上事务、`ManagedEntity`/`dupeEntityTo` 请求级 arena、`SelectExpr` 聚合
  DTO、`Row.tryGet*` NULL 安全）；§14 升级表补 v0.28–v0.31（含 ⚠️ v0.29
  `field.Time` 全方言改 BIGINT epoch 的 PG 存量表迁移提醒）。README /
  README.zh / docs/README / AGENTS 文档地图同步主推标注。
- `examples/zent-modulith` 新增 v0.30–v0.32 能力演示端点：`PUT /api/v1/sku-stock`
  （业务键 upsert + Decimal）、`GET /api/v1/feed2/authors-with-posts`
  （inner-join eager load + arena 深拷贝），并已在文档中注明 Interceptor
  接入位置。
- **文档基线校准**：`AGENTS.md` 测试计数 820→990/1009（19 skipped）、
  `docs/EVALUATION_REPORT.md` 与 `docs/PRODUCTION_ROADMAP.md` 版本口径/结论
  统一到 v0.15.32；`scripts/release.sh` 版本校验与 bump 范围扩到这两个
  长期被漏掉的文件。

## [0.15.31] - 2026-08-26

### Added
- **可插拔 AuthBackend + catalog 唯一 bypass 真相**（ISSUES_FROM_ZAPI M1/M3）：
  `http.authFromCatalog(&slot, backend, .{})` 包住任意 `AuthBackend`
  （`verifyFn(ctx) → ?Identity`），仅 `RouteMeta.auth == .public` 跳过验签；
  内置 `http.jwtBackend(&sec)` / `http.jwtBackendWithPermissions(&sec, loader)`
  （≡ `jwtAuthFromCatalogWithPermissions`）。消费端可删除并行 `public_paths` 清单。
- **认证拒绝信封钩子**（M4）：`JwtFromCatalogConfig.reject` /
  `PermissionGateConfig.reject` / `AuthFromCatalogConfig.reject` 接受
  `AuthRejectFn`；`http.envelopeReject(.thinkphp)` 让 401 产出
  `{code:-1,msg,data:null}`，无需 fork 中间件。
- **类型化身份与属性读取**（M5/M11）：`ctx.setIdentity` / `ctx.identity()` /
  `ctx.userId()` / `ctx.userIdInt(T)` / `ctx.requireUserId()` /
  `ctx.requireUserIdInt(T)` / `ctx.tenantId()` / `ctx.rolesCsv()`，及
  `ctx.getAttrInt(T, key)` / `ctx.getAttrEnum(E, key)`。
- **响应信封方言**（M6）：`http.EnvelopeDialect`（`.default` / `.thinkphp` /
  `.ruoyi`）+ `ctx.setEnvelope` + `ctx.ok` / `ctx.okValue` / `ctx.fail` /
  `ctx.failCode` / `ctx.unauth` / `ctx.paginated`（RuoYi 分页为
  `{code,msg,rows,total}`；msg 一律 JSON 转义）。
- **租户解析中间件**（M7）：`http.tenantResolver(.{ .require = … })` 按
  `AppID`/`appid`/`X-Tenant-Id` 头或 `app_id` query 写 `tenant_id` attr；
  JWT `aud` 已存在时默认优先（可 `override_existing`）。
- **路由级门户 roles**（M8）：`RouteMeta.roles = "admin|ops"`（`|` = OR），
  `permissionGateWith` 在细粒度 permission 之前按身份 roles 拦截；catalog
  新增 `rolesFor`。
- **Token 提取器**（M12）：`http.TokenSource` + `extractBearer` /
  `extractHeaderToken` / `extractQueryToken` / `extractFormToken` /
  `extractTokenAny`（Bearer / X-Token / query / form）。
- **meta ↔ runtime 认证审计**（M2）：`http.Testkit.auditAuthCoverage(alloc,
  &server, &slot)` 无凭证分发全部 catalog 路由，返回漂移清单（`{param}` 段
  以 `1` 分发；WS/SSE 跳过）；空切片 = 通过，可接入 CI。
- **OpenAPI securitySchemes**（M14）：`OpenApiGenerator.bearer_auth` +
  `ApiEndpoint.requires_auth`；catalog 导出自动标注非 public 路由
  `security: [{bearerAuth: []}]`，并生成
  `components.securitySchemes.bearerAuth`（http/bearer/JWT）。
  `OpenApiFromCatalogConfig.bearer_auth` 默认开启。

### Documentation
- `docs/ROUTE_TABLE.md` 新增 §7.2（AuthBackend / 身份 / 信封）与
  §7.3（Resilience profiles 接线，M9）。
- `docs/ISSUES_FROM_ZAPI.md` 状态更新：M1–M9、M11、M12、M14 landed；
  M10 deferred（dispatch 层改动大，M6 已覆盖主要诉求）、M13 declined（审美性）。

### Fixed
- **HttpMetricsCollector.generateReport 自死锁**：持锁（非递归自旋锁）期间调用
  会再次加锁的公开方法 `avgDuration()`，`tryLock` 失败导致 100% CPU 永久自旋
  （也是 `zig build test` 卡 853/929 的根因——该死锁长期掩盖了后续测试的真实
  结果）。改为持锁内联计算均值。
- **bindJsonLoose / extractJsonLoose 丢字段默认值**：原实现用
  `std.mem.zeroes(T)` 初始化，`"id": null` 或缺字段时声明的默认值（如
  `id: ?i64 = 7`）被抹成零值。改为两段式：先填匹配字段，再给未匹配字段
  回填**声明默认值**（切片默认值同样 deep-copy，返回值所有字段统一自有，
  可一致释放）。同步修复相关测试的字符串泄漏。

## [0.15.30] - 2026-08-17

### Fixed
- **SQLx pgDecodeNumeric base-10000 boundary**: PG stores numeric values in a compressed form that strips trailing zero base-10000 groups. For numbers like `100000` (= 10 * 10000^1), PG may send `ndigits=1, weight=1, digits=[10]` instead of `ndigits=2, weight=1, digits=[10, 0]`. The previous code only handled the non-stripped form correctly, mis-decoding stripped values (e.g. `100000 → '10'`). The integer-part writer now pads with the missing high-order zeros when `int_out < int_chars`, so both stripped and non-stripped encodings produce the same decimal string. No migration needed: DB data is unchanged.

## [0.15.29] - 2026-08-17

### Fixed
- **SQLx arena ownership clarity**: `QueryResult` (sqlx.zig) now documents the arena contract explicitly and exposes a new `deinitArena()` method that takes no allocator. The arena path of `deinit(allocator)` ignores the `allocator` argument and uses the arena's own backing allocator (captured at scan time). When callers mix allocator identities and pass a different allocator than the one backing the arena, `ReleaseSafe`'s `SafeAllocator` rejects the free; `deinitArena()` makes the intent explicit and removes the ambiguity that produced the heysen `len: 7` panic in nested-allocator chains.

## [0.15.28] - 2026-08-15

### Added
- **分布式限流**：`data.redis_rate_limit.RateLimiter` —— Redis INCR + 首次
  EXPIRE 固定窗口（跨实例共享），fail-closed（Redis 不可用 → error，不静默
  放行）。`max=0` 立即拒绝。
- **跨实例 WS fanout 接线文档**：`DistributedEventBus` 订阅 → 本地
  `WebSocketServer.broadcast`（任意实例 publish → 全集群广播），无需新组件。

## [0.15.27] - 2026-08-14

### Added
- **Repository INSERT 回填自增 id**：`insert` / `insertOmitNulls` 现在把
  DB 生成的 `last_insert_id`（SQLite/MySQL）或 Postgres `SELECT lastval()`
  写回 `entity.id`（上游 PR：heysen_saas `orm-insert-id` 补丁合并，含
  `@hasDecl(B, "dialect")` 守卫与更完整的 `insert` 覆盖）。
- **对称 rows_affected 守卫**：`deleteByIdReturning(id) !u64` 与
  `updateReturning(entity) !u64`——0 表示记录不存在（乐观锁/NotFound 守卫），
  对齐既有 `deleteForTenant`/`updateForTenant`。

## [0.15.26] - 2026-08-14

### Added
- **宽松 JSON 绑定**（camelCase 拒收 + id:null 两个 bug 的框架侧根治）：
  - `Context.bindJsonLoose(T)` — 字段名 snake_case↔camelCase 双向匹配
    （`user_name` ↔ `userName`），`null` 视为缺失（零值默认），缺字段不报
    MissingField。
  - `http.extractJsonLoose(ctx, T)` — 同语义的 canonical extractor。
  - 默认 `bindJson`/`extractJson` 保持严格语义不变；存量 handler 只需把
    方法名换成 Loose 变体（sed 即可）。

## [0.15.25] - 2026-08-13

### Added
- **Repository opt-in 部分写入**（方案 C）：
  - `insertOmitNulls(allocator, entity)` — nullable 且为 null 的列省略，
    让 DB `DEFAULT` 接管（默认 `insert` 仍写显式 NULL 全量覆盖）。
  - `updatePartial(allocator, entity)` — 只 SET 非 null 字段（null 保持
    原值），pk 恒用于 WHERE。
  - 文档：`docs/ZENT.md` §5.1 对照 zent（builder 模式天然规避此问题）。

## [0.15.24] - 2026-08-13

### Added
- **migration barrel 导出（F2）**: `zigmodu.migration` 全量导出
  MigrationRunner/Entry/Applied/Status/Loader——业务侧可弃用自研 migrate.sh。

### Fixed
- **zmodu CLI Windows 交叉编译 3 处修复**: `wallClockSeconds` 用
  `RtlGetSystemTimePrecise`（原 `GetSystemTimeAsFileTime` 已从 std 移除）；
  `std.c.getenv` → `init.environ_map`（避免 libc 依赖）；args 迭代
  `iterate()` → `iterateAllocator`（Windows UTF-16 需 allocator）+ deinit。

### Changed
- **CI**: 新增 `windows-cross` job（`-Ddb=none -Dtarget=x86_64-windows`
  守护 Windows 分支）；push/pull_request branches 补 `master`（默认分支）。
- **examples/zent-modulith**: 依赖升级 **zent v0.29.8**（benchmark canary
  + outbox/shard/mysql-driver 测试补强 + docs 治理）。

## [0.15.23] - 2026-08-11

### Added
- **Swagger UI / Scalar UI 路由**：`swaggerUiHandler` / `scalarUiHandler` /
  `openApiRoutes` / `wrapHandler`（ComptimeRouter + `http.zig` 导出）——OpenAPI
  文档可直接在浏览器渲染。
- **`Context.html(status, data)`**：HTML 响应助手（自动 `text/html; charset=utf-8`）。

### Changed
- **HTTP/2 增强**：Hpack / Http2Server / HttpClient 迭代（含客户端路径调整）。
- **examples/zent-modulith**: 依赖升级 **zent v0.29.5**（`git+https#v0.29.5`，
  hash `zent-0.29.5-oiur-70vDgA9kXdpRrJUN1MRmz721OldWiTrrOJKSNF6`，ORM 迭代与
  适配更新）。

## [0.15.22] - 2026-08-10

### Changed
- **examples/zent-modulith**: 依赖升级 **zent v0.29.4**（pool UAF 修复——
  Rows 持有连接至 deinit；Sum f64；From edge FK 去重；codegen quota 1M）。

### Fixed
- **AccessLogger 线程安全**：全局中间件被所有连接线程共享，并发 `log()`
  append 同一 ArrayList 触发数据竞争 → SafeAllocator panic → 服务崩溃
  （并发 ≥10 即现）——已加锁。
- **HttpMetrics 线程安全**：`HttpMetricsCollector` 加自旋锁
  （beginRequest/endRequest/recordRequest/snapshot）；`metricsMiddleware`
  改用守卫的 begin/endRequest（原先裸改 `in_flight`）。
- **libpq 同步查询永久挂死**（Threaded Io）：`SO_RCVTIMEO` socket 读超时
  （`Config.query_timeout_ms`，默认 30s）+ `connect_timeout=10`——同步
  `PQexec*` 挂起不再永久卡死 fiber；超时后连接由池 ping / 重连回收。
- **ConnPool 等待不可中断**：acquire 池满等待改 50ms 分段 futex——响应
  fiber 取消与池关闭；slice 超时继续等待至 `max_wait_ms`（语义不变）。

## [0.15.21] - 2026-08-07

### Changed
- **examples/zent-modulith**: 依赖升级 **zent v0.29.3**（bool scan / WhereIn
  Zig 0.17 / defaultValueStr quota 修复）；改用 `git+https#v0.29.3` tag 依赖
  （tarball archive hash 不稳定，git tag 内容哈希稳定且锚定更规范）。

## [0.15.20] - 2026-08-07

### Added
- **Outbox 拆分出口治理**（对齐 Spring Modulith 决策记录）：
  - `OutboxPublisher.buildResubmit(policy)` 显式重发 API——failed/DLQ 条目按
    `max_attempts` / `older_than_seconds` / `tenant_id` 策略回 pending 重投
    （对齐 `FailedEventPublications.resubmit()` + Staleness Monitor）。
  - `OutboxPublisher.externalize(...)` 事件契约映射层——内部 topic →
    对外稳定契约 + `{"event","data"}` 信封（对齐 `@Externalized`）。
- **audit b17**：`collectModelStructs` 收集缩进局部 `const X = struct` 与
  单行 struct——函数内局部标量行类型误报消除（22 处边界收口）。

### Changed
- **docs**：EVALUATION_REPORT v5.8（Agent 流式化/tools_json/Metrics 原子化等
  实分重估）；BEST_PRACTICES 新增「Threaded Io 下同步阻塞」契约；
  PRODUCTION_ROADMAP 新增 gRPC「一等公民≠近期投入」与「拆分出口=事件契约+
  outbox」两条决策记录。

## [0.15.19] - 2026-08-07

### Changed
- **examples/zent-modulith**: 依赖从本地 sibling path 改为固定 git
  tarball **zent v0.29.2**（含 migrate 生成 quota 运行时化修复）。
  `.gitignore` 忽略 zig 0.17 的 `zig-pkg/` 包缓存目录。

## [0.15.18] - 2026-08-07

### Fixed
- **tools_json 非法 JSON**: `SkillRegistry.toOpenAiFunctionsAlloc` 每个工具
  多输出一个 `}`（`appendSlice` 字面 `]}}}}` vs `print` 的 `{{` 转义混用），
  导致 DeepSeek/OpenAI 对工具定义报 400 → ProviderError。已改为 `]}}}`，
  并给生成器测试补 `std.json.parse` 合法性断言防回归。

## [0.15.17] - 2026-08-07

### Added
- **Metrics 快照读取**: `AiProvider.Metrics.toStats()` 与
  `AgentMetrics.toStats()` 返回普通字段快照——外部读取/日志不再逐字段
  `.load(.monotonic)`，也避免 `{d}` 直接传 `atomic.Value` 的编译错误。

## [0.15.16] - 2026-08-06

### Fixed
- **HttpClient.requestStream 本地 HTTP 挂起（根治）**: `executeRequestStream`
  写请求后漏 `flush`（请求停在缓冲、与 server 死锁）；流式读取改
  `waitForReadable + posix.read`（同步调用链兼容）。此前本地 HTTP mock
  全挂（真实 HTTPS 因走 std.http.Client 正常）——现本地 SSE mock 可用。

### Added
- **Agent 流式正式落地（TODO #4）**: `Agent.run` 主循环切换到
  `chatStream + DeltaBridge`——`AgentHooks.on_delta` 真实触发（旁路推送
  content/reasoning delta，内部仍聚合完整响应供 ReAct 决策）。Agent mock
  测试全部改为 SSE 响应并恢复通过。

## [0.15.15] - 2026-08-06

### Added
- **CircuitBreaker 上下文感知调用**: `callWithContext(ctx, operation)` —
  熔断有状态调用（如 `*AiProvider`），补上"函数指针无法捕获调用方状态"
  的缺口；`call` 保持兼容。含上下文透传/失败/trip 测试。

## [0.15.14] - 2026-08-06

### Added
- **JWT 凭据版本（服务端会话吊销）**: `JwtPayload.ver` claim +
  `generateTokenWithTenantAndVersion`（`generateTokenWithTenant` 委派
  ver=0 兼容）。应用侧可 `payload.ver != users.token_version` 判定吊销
  （踢人）。修复 `verifyToken` 重建 payload 时漏拷 `ver` 的隐藏 bug；
  含 ver 往返测试。

## [0.15.13] - 2026-08-06

### Changed
- **Agent 流式切换验证记录**: `Agent.run` 的 chatStream 切换已用真实 DeepSeek
  API 验证（content delta 旁路推送 + done + 聚合一致）；因框架 mock 基建
  无法驱动 requestStream（本地 HTTP 挂起，Content-Length/chunked 均复现，
  真实 HTTPS 正常——已记录为 requestStream 本地路径 bug 候选），切换保留
  TODO 待 SSE mock harness 或修复后落地。

## [0.15.12] - 2026-08-06

### Added
- **Metrics 原子化**: `AiProvider.Metrics` 与 `AgentMetrics` 全字段改
  `std.atomic.Value(usize)`（threaded io 多 fiber 并发计数不再丢更新）。
- **audit b18 伪事务拦截**: `beginTx()` 后同函数仍用池连接 `client/backend
  exec` 静态报错——事务内读写必须走 tx 句柄（`tx.exec`/`execTx`），否则
  rollback 无效（自动提交）。
- **`RateLimiterRegistry` barrel 导出**（此前漏导出）。

### Changed
- **Lifecycle 文档统一**: QUICK-START/API.md 主 API 改为
  `Application.start/stop`，`startAll/stopAll` 标注为底层 Lifecycle。

## [0.15.11] - 2026-08-06

### Fixed
- **Time.zig**: Windows 时钟改用 `ntdll.RtlQueryPerformanceCounter`（本版 std 已移除 `std.os.windows.QueryPerformanceCounter`）。
- **README 版本漂移**: release.sh 的 perl bump 静默失配导致 README 停在 v0.15.4；补版本引用一致性校验（release.sh + check-release-tag.sh）。
- **静默吞错补日志**: provider JSON 降级 / Agent 工具参数 / Workflow WAL 坏条目。
- **Migration**: `run()` 重复 version 现 fail-fast（`error.DuplicateVersion`）；`loadHistory` 改为 DB 权威快照（修 markApplied+run 双算）。

### Added
- **中间件多实例隔离**: cors/jwtAuth/jwtAuthFromCatalog*/moduleGate/rateLimitPerClient 配置改存 `user_data`（page_allocator 一次性分配），同进程多 Server 不再互相覆盖。
- **`Transaction.queryRowPartial`**（事务内缺失列置零）；**`RouteCatalog.allPermissions()`**（菜单↔路由权限比对）。
- **Migration `markApplied(version)`**（bootstrap 旧库，不执行 SQL）。
- **audit 行级豁免**（`// audit: ignore` / `// audit: ignore b13`）与 **b3 精确化**（空字符串字面量不误报注入）。
- **`AgentHooks.on_delta`** + `chatStream` model 透出 + run_audit `model` 列（AgentResult.model 联动）。
- **事务范式文档**（BEST_PRACTICES.md：伪事务警示 + transact/三件套两种范式）。

### Changed
- **examples/zent-modulith**: 适配 zent v0.29.1（实体序列化改 `toMaskedJson`，跳过 json_arena/Allocator 注入字段）。

## [0.15.10] - 2026-08-05

### Fixed
- **StructuredLogger**: struct-field keys（comptime 字面量）入 map 前 dupe，消除
  释放只读内存导致的 ABRT。
- **ForTenant × camelCase**: 租户字段检查按模型 camel_case 推导（新增
  `snakeToCamel`），`findPageForTenant` 等在 camelCase 模型上可用。
- **Migration 切分**: 替换裸 `;` 切分为状态机（引号/注释/美元引号感知），
  支持含 PL/pgSQL 函数、触发器、DO 块的迁移脚本。

### Added
- **Repository ForTenant 全方法集**: `findByIdForTenant` / `findAllForTenant` /
  `updateForTenant` / `deleteForTenant`（rows-affected 守卫：跨租户操作返回
  0 行，`== 0 → NotFound` 模式可用）；`Tx(B)` 提供事务内
  `deleteForTenant` / `updateForTenant`。
- **软删读过滤**: 模型含 `deleted` 字段时所有读方法（含 ForTenant 变体）自动
  追加 `AND deleted = 0`；无该字段的模型零影响。
- **自动时间戳（opt-in）**: 模型声明 `sql_auto_timestamps = true` 时 insert
  自动填 `create_time`/`update_time`、update 刷新 `update_time`。
- **SqlxBackend borrowed 透传 + queryScalar**: `queryRowBorrowed` /
  `queryRowPartialBorrowed` / `queryScalar`（字符串类型编译期拒绝、自动释放）；
  `typeHasStrings(T)` / `QueryResult(T).has_strings` 编译期元数据。
- **Outbox 方言化**: `migrationSqlWithDialect`（mysql/postgres/sqlite）。
- **PermissionGate `deny_by_default`**: 未标注 permission 的路由可配置 403。
- **audit b10**: 豁免 best-effort `sendError`（SSE 断连等）。

## [0.15.9] - 2026-08-05

### Added
- **AiProvider reasoning_content 支持**: `ChatResponse` 新增
  `reasoning_content` 字段（推理模型如 DeepSeek-R1 的思维链），非流式
  `message.reasoning_content` 与流式 `delta.reasoning_content` 均解析；
  `StreamDelta` 新增 `reasoning_delta`，`chatStream`/buffered fallback
  透出；`freeResponse` 同步释放。已用真实 deepseek-reasoner 集成验证。

## [0.15.8] - 2026-08-05

### Changed
- **AI 开发文档完善**: 新增 `docs/AI_DEV_GUIDE.md`（业务接入全链路：KeyManager →
  Provider → 自定义 Skill → Agent/Workflow → HTTP/cron/outbox/MCP 接线、
  技能所有权/权限/超时规范、安全清单、观测调试）；`docs/README.md` 索引补全
  AI 编排/技能/LLM 策略/MCP 文档；AGENTS.md 文档地图加「AI 业务接入」入口；
  AI.md 顶部指向新指南；AI_SKILLS.md 补「开发自定义技能」指引。
- **queryRow 系字符串所有权契约落地**: `queryRow` / `queryRowPartial` 文档
  明确返回 **owned** 字符串（dupe 进 client allocator，row arena 返回前已释放；
  调用方须 `freeScanned`，否则泄漏）；新增显式命名别名 `queryRowOwned` /
  `queryRowPartialOwned`；新增 arena-借用 RAII 变体 `queryRowBorrowed` /
  `queryRowPartialBorrowed`（`BorrowedRow.deinit()` 一次释放、无需逐字段
  free；CachedConn 提供无缓存直通）。
- **audit 规则修正**: b10 豁免 `errdefer` / `rollback` 上下文里的 best-effort
  空 `catch {}`（事务回滚不再误报为吞错）；新增 b17 检查 owned `queryRow*`
  结果在函数内既未 `freeScanned` 也未 `return` 委托的泄漏点。
- **CrudApi 多租户 attr 可配置**: `CrudOpts` 新增 `tenant_attr`（默认
  `"tenant_id"`，即 catalog JWT 中间件 aud→attr 标准桥）；多门户场景可配置
  其他 attr 名。
- **Outbox 多租户支持**: `event_outbox` 迁移 SQL 内置可空 `tenant_id` 列
  （向后兼容）；新增 `buildInsertForTenant(topic, payload, tenant_id)`；
  `OutboxEntry` 与 `buildSelectPending` 带 `tenant_id`。
- **Repository 租户感知查询**: 新增 `findPageForTenant` / `findByIdsForTenant`
  / `findPageFilteredForTenant` / `countForTenant`（comptime 列名；模型缺租户
  字段时编译期报错，fail-closed）；原有方法签名不变。
- **API.md 旧别名清理**: `zigmodu.http_server.*` 示例统一为 `zigmodu.http.*`。

## [0.15.7] - 2026-08-04

### Changed
- **Bulk writes（`Repository` + `data.bulk`）**: `Repository.insertMany` /
  `upsertMany` 一条多行 SQL（SQLite/PG `ON CONFLICT ("id") DO UPDATE SET`、
  MySQL `ON DUPLICATE KEY UPDATE`，冲突 SET 默认除 id 外全列）；
  `Repository.findByIds` 单次 round-trip `WHERE pk IN (…)` 取代循环单行；
  `data.bulk` 方言感知批量 INSERT builder + 参数扁平化，exec 目标兼容
  Client/Transaction/SqlxBackend（新增 `SqlxBackend.dialect()`）。空行 /
  空列 / all-conflict upsert 均有守卫 + 回归测试（套件 858 pass），
  docs/API.md 补 Repository + bulk 参考。
- **zent-modulith 示例按 zent v0.27 能力沉淀**: 原子表达式防超卖、两级预加载
  + 边过滤/每父排序限量、复合 keyset 游标（平局不丢）、嵌套事务（savepoint）
  + `afterCommit` 事务事件、uuidv7 主键 + 敏感字段掩码、审计/校验/投影/
  批量插入/批量软删全链路 HTTP 演示；`tx_demo.zig` 下单编排（库存不足 409
  且整单回滚、事件提交后恰好一次投递）。文档同步：docs/ZENT.md 版本口径升至
  zent **v0.27.0+**（远程依赖示例 v0.27.0，升级注意补 v0.21–v0.27 要点）；
  AGENTS.md 工作区事实更新；两个 zent 示例依赖注释指向 `#v0.27.0`。
- **`zmodu market` Phase 2：远程发现 + 安装闭环**: `market update`（std.http 拉取
  远程索引 → `.zmodu/market-index.json`，坏缓存自动忽略、tmp+rename 原子写入）、
  `list/search/info` 改为本地 + 远程合并浏览（按 id 去重）、`market install
  <id> --dir … [--dry-run] [--verify]`（递归复制源码树，跳过 node_modules/.git/
  .output/.zig-cache 等；verify 就地跑 `zig build`）。签名、build.zig.zon 自动
  写入、CI 回归钩子留在 ADR-016（Phase 2c）。4 个新单测（合并去重 + copyTree
  跳过 junk 目录），CLI 套件 50 pass。docs/ZMODU_CLI_INTEGRATION 更新阶段表。
- **`zmodu market` 模块市场（Phase 1 本地策展目录）**: `tools/zmodu/src/
  marketplace/catalog.json`（schema_version 1）登记 12 个策展条目（zmsaas /
  tenant-mgmt / ai-ops / llm-policies / mcp-server / web4 / tenant-shop /
  shopdemo / basic + wechat-pay / aliyun-oss / apns stub）；`zmodu market
  list|search <q>|info <id>` 支持 `--json` 与 `--catalog PATH` 外部目录。设计
  取舍（ADR-015 式）：Phase 1 只做可发现性，远程 registry/自动安装/签名包
  延后（质量门优先）。2 个单测并入 CLI 套件；docs/ZMODU_CLI_INTEGRATION 补
  章节。
- **zsaas — SaaS 业务框架（zigmodu 后端 + saas-solidjs 前端）**: 新增 `zsaas/`
  目录。同一份业务模型 JSON 生成两端：后端 `zmodu saas <model.json>` 产出
  org 隔离的 zigmodu 模块（model/persistence/service/api/module/root 六文件、
  参数化 SQL 强制 `org_id` 租户过滤、ComptimeRouter `.auth=.jwt` + permission
  门控、ctx.json、saas-schema.sql 迁移产物），生成模块已在真实 zigmodu 工程
  编译通过；前端 `scripts/gen-business.mjs` 生成 SolidStart 管理页（列表/新建/
  编辑/删除 + i18n + 导航）+ `zmoduFetch` REST client（`/api/v1/<entity>`，
  Bearer 鉴权），tsc 全绿；`scripts/check-gen.mjs` 自检。
  **一键新建前后端**：`scripts/create-project.mjs <model.json> --name <app>` 同时
  创建 zigmodu 后端工程（自动把 zigmodu 依赖指向本地仓库，规避 `zmodu new`
  的旧 tag 占位 hash）与 saas-solidjs 前端工程（模板复制 + 业务页面），端到端
  验证：后端 `zig build` 编译通过 + `zmodu verify` 全过、前端页面生成、零泄漏。
  顺带修复 `zmodu new` 的既有 bug：生成 main.zig 引用未定义 `project_name`、
  未使用 allocator/init，以及 `generateLifeDir` 两处 ArrayList 泄漏。
- **AI key 轮换 bug 修复（审查发现）**: (1) `AiProvider` 自动换 key 重试后，调用方
  旧 lease 指向已失败的 key——`mgr.onSuccess(lease)` 会把刚 429 的 key 重置回
  健康、撤销冷却；新增 `provider.reportSuccess()` / `reportError(kind)` 用当前
  key 反馈，providerFor 文档同步；(2) `RedisCooldownStore` 冷却标记（SET）与
  失败计数（INCR）共用同一 key，cool 会覆盖计数——拆分为 `:fail` 子键，失败数
  跨进程准确；(3) `chatWith` 传输层错误补上报 `.network` 给池（chatStream 已有）。
  新增外部共享 store 路由单测（套件 838 pass）。
- **跨进程 KeyPool cooldown（CooldownStore）**: 新增 `ai/cooldown_store.zig`——
  `CooldownStore` 接口（isCooling/cool/bumpFailures/reset）+ `MemoryCooldownStore`
  （默认，单进程零依赖）+ `RedisCooldownStore`（跨进程：SET EX / INCR+EXPIRE /
  DEL，fail-open 本地镜像回退，对齐 RedisRateLimiter 先例）。`KeyPool` 的冷却/
  失败/禁用状态改为经 store 读写（多实例共享 key 时协调一致），计数器仍留本地
  观测；`AiKeyManager.setSharedStore` 一键接入。3 个新单测（套件 837 pass），
  docs/LLM_POLICIES.md §8 补跨进程接线。

## [0.15.4] - 2026-08-02

### Changed
- **AI AiKeyManager（provider + key 轮换，四层结构）**: `ai/key_pool.zig`
  （key 池：round-robin、429/配额指数冷却、连续 401 禁用、恢复与观测）、
  `ai/provider_registry.zig`（provider 注册表：endpoint + key 池 + 模型路由 +
  fallback provider 链）、`ai/provider.zig` 挂池（`bindKeyPool` 后
  chat/chatWith 对 401/403/402/429 自动换 key 重试一次）、`ai/module.zig`
  （`AiKeyManager`：`ProviderConfig` api_keys 配置 + 生命周期 +
  `providerFor`）。簿记 `std.Io.Mutex` 保护、HTTP 调用不持锁，适合高并发；
  10 个单测并入框架套件（834 pass）。docs/LLM_POLICIES.md §8 更新为四层接线。
- **git 依赖打包修复 + catch 反模式规则**: (1) `build.zig.zon` 的 `.paths` 增加
  `examples/_shared`——git+https 依赖按 `.paths` 打包，此前 `_shared`（及整个
  examples/）不会出现在拉取包里，业务方换版本必须重打 zig-pkg workaround，现
  已根治（`zig fetch` 后包内自带 `db_link.zig` / `zent_helpers.zig`）；(2) audit
  新增 `b11` 规则：未使用 catch 捕获（`catch |err| { _ = err; }` / `catch |_|` →
  应写 `catch {`），并修复 `src/ai/provider.zig` 存量；(3) `scripts/release.sh`
  移除 fingerprint 重算步骤——按 Zig 文档 fingerprint 是包永久身份、同包永不改
  （改了有信任/安全影响）；docs/SQLX_DRIVERS.md 补充 git 消费者说明。

## [0.15.3] - 2026-08-02

### Changed
- **`zmodu audit` 业务最佳实践检查器**: 新 CLI 命令，两组规则——architecture
  （模块自依赖/循环依赖/缺失描述/命名规范/依赖上限/未知依赖/base 模块依赖，
  与 `zigmodu.ArchitectureTester` 默认规则对齐）与 business（handler/model 含
  SQL、非参数化 SQL、`@ptrCast(ctx.user_data)`、legacy sendSuccess/sendFail、
  banned 导入、已移除 Zig 0.17 API、跨模块直接文件导入）。支持 `-j` JSON、
  `--group`/`--max-deps`/`--base-modules`、`.zmodu/audit-baseline.json` 基线
  （与 deadcode 同语义，`--update` 收缩）；CLI 单测 4 个并入 `zig build test`。
  同时把 `zigmodu.ArchitectureTester` 导出到 root（修复与
  docs/AI_METHODOLOGY.md 的断点），docs/ZMODU_CLI_INTEGRATION.md 补章节。
- **zmodu 工具链增强（P0/P1 落地）**: (1) `zmodu ci` 一站式门禁——`zig build`
  → `fmt --check` → `verify` → `audit` → `deadcode`，单命令面向 CI；(2)
  `zmodu graph [dir] [--out]` 输出模块依赖 Mermaid 图；(3) `zmodu diff old.sql
  new.sql --migration <name>` 自动生成 Flyway 迁移 SQL（CREATE/ALTER/DROP），
  并修复迁移时间戳恒为 `V19700101000000` 的既有 bug（改用 REALTIME 时钟）；(4)
  audit 规则配置 `.zmodu/rules.json`（`max_deps` / `disabled`）与两条新规则
  `b9`（handler 手工解析 Authorization/Bearer）、`b10`（空 catch 吞错）；(5)
  MCP server 新增 `zmodu_audit` / `zmodu_graph` 工具；(6) 修复既有 bug：
  `verify` 字面量 details 被 free 导致的无效释放崩溃、`module_integrity` warn
  details 泄漏、`parseSqlSchema` 对 `CREATE TABLE IF NOT EXISTS` 的表名泄漏、
  sql_diff 测试 const 数组协变编译错误（此前 zmodu CLI 测试产物为缓存旧态）。

## [0.15.2] - 2026-08-02

### Changed
- **freeValue 内存安全审计**: 全代码审计 `std.json.Value` 树所有权（handler 返回树必须由
  `ctx.allocator` dup 全部 key/字符串，调用方统一 `freeValue`）。修复
  `ai.business.db.query` / `entity.list` 返回树使用字面量 key `"rows"`/`"count"`
  （`ObjectMap.put` 按引用存 key，`freeValue` 会释放字符串字面量 → 无效释放；新增
  `std.testing.allocator` 回归测试，修复前实测 crash），以及 `Agent.run` 工具结果在
  `Stringify.valueAlloc` 失败时未释放的 OOM 路径泄漏。
- **Agent composition tests + AI benchmark + optional real-provider CI**: (1) `Agent.run` integration tests for the composed paths — context auto-compaction (`ContextManager` summarize invoked mid-run), budget exhaustion (early stop + `budget_exhausted`), and cooperative cancel (requested from `on_step`, stops next iteration); (2) `zig build benchmark` gains an AI section (workflow 20-step × 100 ≈ 5 ms); (3) CI adds an optional `ai-real-provider` job that runs `examples/llm-policies` against a real LLM when `LLM_API_KEY` is configured (GitHub secret). AGENTS/AI_METHODOLOGY docs synced.
- **SkillRegistry → MCP bridge**: `zigmodu.ai.mcp` exposes registered AI skills as Model Context Protocol tools — `toMcpTools` (MCP `tools/list` payload with inputSchema derived from tool parameters), `handleToolCall` (dispatch to the registry, text content result) and `serveStdio` (JSON-RPC 2.0 MCP server over stdin/stdout). Applications serve a session `SkillContext` (tenant/user/permissions), so `required_permission` gates and admin.* allowlists still apply. docs/MCP.md documents wiring + security.
- **MCP 真实链路示例 + 客户端冒烟 + 泄漏修复**: new `examples/mcp-server` exposes `kpi.query` (in-memory SQLite) + `ping` over real MCP stdio; `scripts/mcp-client-test.py` drives a real session (initialize / tools/list / tools/call) asserting protocol 2024-11-05 and KPI sum — verified locally with zero leaks. Fixes a `handleToolCall` leak (response tree was never freed after stringify). Added to CI example builds.
- **Admin/ops AI skills (P2 落地)**: `zigmodu.ai.admin` — `admin.cache.invalidate` / `admin.cache.clear` (whitelisted caches, wildcard keys rejected, `all=true` opt-in for clears), `admin.config.get` / `admin.config.set` (ConfigStore with mutable-keys whitelist), `admin.audit.export` (RunAuditStore query with kind/tenant/limit filters) and `admin.user.manage` / `admin.tenant.provision` (app-callback delegation). Each requires its own permission code and **must be explicitly allowlisted** — off by default, per the controlled-execution posture.
- **Dead-code baseline gate**: `scripts/check-deadcode.sh` fails CI when the repo gains new dead declarations (identity `file:kind:name:parent`, so line moves don't false-positive); removals are allowed and `--update` shrinks the baseline (`scripts/deadcode-baseline.json`, 37 items). Wired into CI after the deadcode smoke.
- **Agent end-to-end test**: `Agent.run` driven against a loopback mock OpenAI endpoint — tool_calls → skill dispatch → final answer, asserting `answer`, `metrics.tool_calls`, tool hook invocation.
- **Workflow DAG approval-gate test**: a `.approval` step in a DAG stops the run with `pending_human` after dependencies complete; downstream steps never run.

## [0.15.1] - 2026-08-02

### Changed

- **Remaining zero-test coverage**: added tests for `src/util.zig` (`randomHex`/`randomUuid` length + hex charset, `pluralize` english rules incl. vowel-y, `hexEncode` + `HashKit` MD5/SHA-256 known vectors) and `sqlx.errors.sqlStateToError` (SQLState → kind mapping, unknown → Other) — which surfaced two missing mappings (`57014` Timeout, `53300` TooManyConnections) now added. The remaining zero-test files are barrels (http/observability/security/data/root/docs/outbox/im/extensions/ai/web4), C bindings (sqlite3_c/libpq_c/libmysql_c + stubs), platform-specific io_uring stubs and the usage `main.zig`/benchmark entry — none require unit tests.
- **Fluvio native transport + thin-component tests**: `messaging.FluvioNative.NativeTransport` replaces the `fluvio` CLI subprocess with a pluggable TCP transport (line protocol over a socket; loopback server for tests/dev — end-to-end createTopic/produce/consume/list verified). `FluvioConnector` gains a `transport` field so apps inject the native transport or a faithful Fluvio SC/SPU protocol implementation. Added tests for the remaining zero-test thin components: `core.Event` (tagged-union payloads), `log.ModuleLogger` (+ `LogScope`), `metrics.MetricsBackend` (vtable routing).
- **Zero-test component hardening**: added tests for `sqlx.CircuitBreaker` (open/half-open/closed state machine incl. timeout re-open and half-open failure), `core.EventPublisher` (TypedEventBus publish + event validation + metadata) and `core.ApplicationModuleListener` (subscribe + receive). Fixing them surfaced three more lazily-compiled broken implementations: `EventPublisherMixin` validated against the wrong bus type (`EventBus` vs `TypedEventBus`), `ModuleListener.subscribe` called a 2-arg `EventBus.subscribe` with one argument and wrapped the handler with the wrong signature — both now compile and pass tests. `FluvioConnector` CLI-fallback stub semantics confirmed covered by existing tests.
- **Productization pass (per component audit)**: (1) **Security consolidation** — `http_middleware.securityHeaders()` (default HSTS/X-Frame-Options/CSP/etc.) is the canonical security-header middleware; deleted the broken `security/SecurityHeaders.zig` middleware (wrong return type + wrong `next` call, never compiled) and the duplicate broken `security/Csrf.zig` (`CsrfProtection` — invalid API calls, never compiled); `Middleware.csrf()` is now the single CSRF implementation. Added tests for csrf allow/reject and security-header injection. (2) **EventStore productionized** — JSON event serialization, replay invoking the application handler, snapshot-based replay (state + events after snapshot), thread safety via `std.Io.Mutex`, owned metadata; tests cover append/serialize/replay and snapshot replay. (3) **Removed deprecated `ScheduledTask.zig`** (placeholder `start()`/`calculateNextCronRun`; AI bridge uses `Cron.zig`) — `zigmodu.TaskScheduler` export dropped. (4) **gRPC audit** — server/client/bidi/bidi-pump streaming are fully implemented and tested (corrects an earlier "streaming UNIMPLEMENTED" note). (5) PluginManager comment dedupe + HealthEndpoint test.
- **Web4 production hardening**: `web4.x402_store.X402Store` — persisted invoices (SQL) with exactly-once redemption (`redeem(invoice_id, tx_hash)` → redeemed / not_found / already_used / expired), wired into `x402Middleware` via `X402Config.store` (invoices created on 402, proofs redeemed once, replay → 410). `web4.challenge.ChallengeStore` — one-time DID challenges (issue + verifyAndConsume, TTL, anti-replay), wired into `didAuthMiddleware` via `DidAuthConfig.challenge_store`. `DidAuthConfig.jwt_issuer` issues a JWT (`x-did-token` header) after DID auth so clients continue on the framework's JWT/RBAC chain. Fixed pre-existing did.zig leaks (credential issue/verify buffers). `examples/web4` upgraded to the production path (402→200→410 replay rejection; DID challenge + JWT issuance); docs/WEB4.md documents the hardening.
- **Web4 middleware + example**: `zigmodu.web4.middleware` — `x402Middleware` (no proof → 402 + invoice, invalid → 403, valid → pass; fail-closed default verifier, optional per-route `path_prefix` + `on_invoice` pricing hook) and `didAuthMiddleware` (did:key signature verification → writes `did` / `user_id` attrs; per-route `path_prefix`). New `examples/web4` demonstrates both flows end-to-end (402→200 with proof, 401→200 with a generated did:key signature), `docs/WEB4.md` documents protocol + wiring + security defaults. Added to CI example builds.
- **LLM policy real-chain fixes**: `llmJson` now deep-copies the parsed response out of the parser arena before returning (callers `freeValue` it safely — previously the arena-resident tree caused invalid frees; only fake `json_fn` tests exercised that path until now). Added an end-to-end test that drives `llmApprove` through a real loopback mock OpenAI endpoint (provider.chat → llmJson → decision), plus fixed a dangling-pointer in `examples/llm-policies` (provider/http moved to function scope). Verified live against DeepSeek: llmApprove/llmRiskDecide/llmDiagnose/llmVerify all return real model decisions.
- **Write-operation AI skills (P1 落地)**: `zigmodu.ai.actions` — `entity.create/update` (whitelisted writable columns via `EntitySpec.writable`, tenant column forced from `SkillContext.tenant_id` and rejected from the model, PK forbidden, permission `entity:write`), `command.execute` (app-registered commands via the transactional outbox, idempotency key = `SkillContext.run_id`, permission `command:execute`) and `report.generate` (app-registered aggregations → CSV/JSON, row-capped). Closes the "AI 只读 → AI 可执行" gap; `EntitySpec` gains a `writable` field (backward compatible).
- **Dead-code analyzer fixes (`zmodu deadcode`)**: fixed two false-positive roots in the zdeadcode reference resolver — (1) a `test "name"` whose name equals a function name shadowed the function in `name_map`, so references resolved to the (already-live) test and the function was reported dead; (2) container members (enum variants/fields/methods) shadowed same-named top-level declarations (e.g. `const deadcode = @import(...)` + `enum { deadcode }`). Members no longer overwrite top-level names; both cases have regression tests. Also fixed an arena leak in the CLI adapter and wired the analyzer's own unit tests (analyze + scanner) into `zig build test` (was previously only compiled, not run). Repo scan dropped from 45 to 39 findings (0.4%), with the remaining items genuine unused imports/functions plus layout field `WALEntryHeader._pad` (kept).
- **Dead-code checker (`zmodu deadcode`)**: integrated the zdeadcode analyzer (rustc `dead_code`-style reachability: unused top-level fns/consts/vars, container fields, enum variants, methods, never-imported modules; `.gitignore`-aware scanning; human + JSON output; exit code 0/1/2 for CI). Its unit tests ship with the zmodu CLI test suite (framework suite now 825/843). CI adds a deadcode smoke asserting detection + valid JSON.

## [0.15.0] - 2026-08-01

### Changed
- **AI 编排栈完整化（本轮大版本主题）**：workflow 线性↔DAG 混合 + 人工审批门
  （`.approval` step、`pending_human`、resume 恢复不重提）+ WAL 恢复 + LLM
  反射验证（`ai.llm.llmVerify`）+ `WorkflowMetrics` 观测 + `toMermaid` 图导出；
  触发三源统一（cron / fire / outbox，`ai.bridge.OutboxWorkflowBridge`）；
  业务工具 11 件（reporter/alerts/ticket/refund/risk/recon/approval/notify/kpi/
  sla/diagnose）；审批技能桥 `approval.request`（`required_permission` 门控）；
  LLM 策略 + RAG 上下文（`ai.llm`，失败安全回退 escalate）；持久化审批队列
  （`PersistentApprovalQueue`，tenant_id 隔离）+ HTTP API；outbox 消费端
  （`OutboxConsumer`）；运行审计（`RunAuditStore`，workflow + agent）；
  AI 观测聚合（`AiMetrics`）；技能注册表 OpenAPI/CLI 导出
  （`ai.skill_export` + `zmodu ai`）；多租户 AI 示例（tenant-ai）、LLM 接线
  教程（docs/LLM_POLICIES.md）、AI 全链路示例（ai-ops）。

### Changed
- **AI hardening pass**: (1) `Agent.audit_store` — standalone agent runs now persist to `RunAuditStore` (kind=agent, status/steps/duration), closing the durable-audit gap next to workflow runs; (2) `Tool.required_permission` + `SkillContext.permissions` — dispatch refuses with `error.PermissionDenied` when the tool's required permission is not granted; `approval.request` now requires `approval:decide`; (3) `skill_export.toOpenApi` gains optional bearer security (`OpenApiOpts.security_scheme` → components.securitySchemes + per-operation security); (4) barrel integrity test asserts the public `ai.*` API surface and caught a missing `ai.schedule` export (fixed); (5) docs synced — `docs/AI_SKILLS.md` now lists implemented business skills (kpi.query / approval.request / notification.send) vs planned ones, `docs/AI.md` reflects the removed `TaskScheduler`; (6) CI adds a `zmodu ai export-skills + openapi` smoke test asserting valid JSON.
- **AI skill registry → OpenAPI + CLI**: `zigmodu.ai.skill_export` renders a `SkillRegistry` as a JSON catalog (`toSkillsJson`) or an OpenAPI 3.0 document (`toOpenApi`, one `POST /skills/{name}` per skill with schema derived from parameters). `zmodu ai export-skills --out` writes the built-in catalog and `zmodu ai openapi --in/--out` converts any catalog (built-in or app-exported) to OpenAPI. tenant-ai serves both at `GET /api/ai/skills` / `GET /api/ai/skills/openapi` (verified live).
- **LLM policy wiring guide + example**: new `docs/LLM_POLICIES.md` walks through wiring a real `AiProvider` into `llmApprove` / `llmRiskDecide` / `llmDiagnose` / `llmVerify` (LlmPolicyCtx, RAG, json_fn testing, behavior contract), with a companion runnable `examples/llm-policies` (real-model mode via env vars, fake-json fallback so tests stay network-free). Fixed `llmDiagnose` summary parsing (missing `.string`) surfaced by the example, with a regression test. Added to CI example builds.
- **Durable AI run audit**: `zigmodu.ai.run_audit.RunAuditStore` persists one row per workflow/agent/approval run (run_id, kind, status, tenant, steps, duration); attached via `Workflow.audit`, run/resume record automatically. `list(kind, tenant, limit)` filters history; tenant-ai serves it at `GET /api/ai/runs` (tenant-isolated, verified live). `zigmodu.Time` exported from the barrel.
- **AI observability aggregation**: `zigmodu.ai.observability.AiMetrics` merges `WorkflowMetrics` + `AgentMetrics` + `TokenQuota` into one Prometheus document (attach pointers + labels) for a single `/metrics` endpoint; tenant-ai serves it at `GET /api/ai/metrics` (verified live alongside workflow runs).
- **tenant-ai example extended**: workflow endpoints now carry `WorkflowMetrics` and a `GET /api/ai/workflow/graph` Mermaid export of the step pipeline (incl. the approval gate); `ai.WorkflowMetrics` re-exported from the barrel. Verified live.
- **Approval skill bridge**: `registerApprovalRequestSkills` exposes `approval.request` (subject + amount; chain + policy app-registered) so an Agent inside a workflow `.agent` step can submit approvals directly; the escalated run lands in the queue and `resumeRun` continues after the human decides.
- **Workflow graph export**: `Workflow.toMermaid` renders the step graph as a Mermaid `flowchart` — implicit order edges for linear runs, dependency edges for DAG runs, nodes annotated with their kind (llm/skill/agent/approval). Tests cover both layouts.
- **LLM-backed workflow verification**: `zigmodu.ai.llm.llmVerify` implements `VerifyFn` for `Workflow.reflection` — the model judges whether the final output meets the goal (`{"pass":...}`); failures and malformed responses conservatively return `false` (re-run / escalate). Tests cover pass, fail and provider-error paths.
- **Workflow approval gate resume lifecycle**: end-to-end test proving run → `.pending_human` (gate persisted to WAL) → human approves → `resumeRun` continues from the persisted gate and finishes the remaining steps — the human decision is not re-submitted on resume.
- **Workflow approval gate (human-in-the-loop)**: new `.approval` step kind (`{ subject, amount }`) driven by `Workflow.approval_flow` — approved continues, rejected fails the step, escalated stops the run with a new `.pending_human` status so the app can hand the queue to a human and `resumeRun` afterwards (the gate re-runs under the same policy). Test covers both approved → completed and escalated → pending_human.
- **Workflow observability**: `zigmodu.ai.WorkflowMetrics` attaches to `Workflow.metrics` and accumulates `runs` / `completed_steps` / `failed_steps` / `escalations` / `reviews` (reflection re-runs) on every run/resume — including DAG waves; `toPrometheusFormat` exports `zigmodu_ai_workflow_*` counters alongside `AgentMetrics` and `TokenQuota`.
- **Multi-tenant AI example**: `examples/tenant-ai` — two tenants share one app with tenant-scoped AI operations: per-tenant KPI (`kpi.query`), business reports, alert rules, an approval chain with a `PersistentApprovalQueue` that carries `tenant_id` (tenants cannot see or resolve each other's pending items), and a workflow running the registered skills. `ApprovalApi` + `PersistentApprovalQueue` gained optional tenant scoping (`listPending`/`resolve`/`count` take `?i64`); `ai.freeValue` is now exported from the barrel. Added to CI example builds.
- **AI orchestration P2 (RAG context for LLM policies)**: `LlmPolicyCtx` accepts an optional `retriever` + `retrieval_query`; `buildContext` injects top-k retrieved chunks (policies / history / playbooks) into the `llmDiagnose` / `llmApprove` / `llmRiskDecide` prompts so decisions are grounded in business context. Test: keyword retriever chunk appears in the approval prompt and drives the outcome.
- **AI orchestration P2 (persistent approval queue)**: `zigmodu.ai.approval_store.PersistentApprovalQueue` — SQL-backed human approval queue with the same interface as the in-memory one (`push` / `listPending` / `resolve` / `count`, `migrate()` DDL) and a `queuedEscalationPersistent` hook. `ApprovalApi` is now generic over the queue type, so both in-memory and persistent queues mount into the ComptimeRouter unchanged.
- **AI orchestration P2 (outbox→workflow bridge)**: `zigmodu.ai.bridge.OutboxWorkflowBridge` routes outbox entries (exact or prefix topic) into `ai.trigger.fire(input)` — cron / in-process fire / outbox events are now three unified trigger sources; run outcomes flow back through the trigger's outbox writeback.
- **AI orchestration P2 (human approval queue + HTTP API)**: `zigmodu.ai.approval_api` — `ApprovalQueue` (thread-safe in-memory queue), `queuedEscalation` hook for `ApprovalFlow.on_escalated`, and an `ApprovalApi` ComptimeRouter module exposing `GET /approvals/pending`, `POST /approvals/{id}/approve`, `POST /approvals/{id}/reject` (`approval:decide` permission).
- **AI orchestration P2 (LLM default policies)**: `zigmodu.ai.llm` provides `llmDiagnose` / `llmApprove` / `llmRiskDecide` — LLM-backed callbacks for DiagnosisFlow / ApprovalFlow / RiskReview via `LlmPolicyCtx` (`provider` + injectable `json_fn` + `system_hint`); model failures or malformed JSON fall back to escalate (never silently approve). `ApprovalFlow` gains an `on_escalated` hook (+ `escalated_userdata`).
- **End-to-end AI ops example**: `examples/ai-ops` chains the built-in business tools into one runnable pipeline — `BusinessAlert` detect → `DiagnosisFlow` diagnose → `ApprovalFlow` approve (auto-approve small / escalate large) → `NotificationHub` notify → `OutboxConsumer` audit; `zig build run` prints the trace and `zig build test` asserts every stage. Added to CI example builds and the examples README.
- **Built-in business tool (P1, anomaly diagnosis)**: `zigmodu.ai.diagnose.DiagnosisFlow` takes a detected anomaly (from alerts/recon/sla/app code), gathers evidence via configured SQL queries and hands symptom + evidence to a `diagnose` callback (LLM or rule engine) producing likely causes + recommended actions; the result is written to the outbox (`ai.diagnose`) for audit/automation.
- **Built-in business tool (P1, SLA tracker)**: `zigmodu.ai.sla.SlaTracker` tracks monotonic deadlines on business items (tickets/approvals/refunds); `check()` (cron-driven) fires a `warn` when an item enters the deadline window and a `breach` once past it — events go to an `on_sla` callback (e.g. route into `ai.notify`) and the outbox (`ai.sla`) for audit/automation.
- **Built-in business tool (P1, KPI metric queries)**: `zigmodu.ai.kpi` registers app-owned named metrics (name → SQL → value column); the `kpi.query` skill lets an Agent answer business questions like "本周营收多少" by name only, and a programmatic `Kpi.query` returns the metric value for dashboards/automation.
- **Outbox read side (consumer)**: `zigmodu.outbox.OutboxConsumer` polls pending entries (optional topic filter), dispatches to a registered handler (`userdata` + `call`; topic/payload handed over as call-scoped copies) and advances the lifecycle pending → processing → delivered, with `retry_count++` + `error_message` on failure and failed/DLQ after retries are exhausted. Closes the loop for the AI business-tool outbox writebacks (`ai.approval` / `ai.recon` / `ai.notify` / `ai.risk` / `ai.alert`).
- **Built-in business tool (P1, notification hub)**: `zigmodu.ai.notify.NotificationHub` delivers a message to named channels — webhook (via `HttpClient`, HTTP 2xx counts as delivered), custom sink (email/IM/in-app callback with `userdata`+`call`) or durable outbox fallback (`ai.notify`) when no channel matches; delivery failures propagate, nothing is silently dropped. `registerNotifySkills` exposes the `notification.send` skill bridge (LLM supplies channel/title/body; channel targets stay app-registered with an optional allowlist).
- **Built-in business tool (P1, approval chain)**: `zigmodu.ai.approval.ApprovalFlow` runs a request through a configured multi-level chain — each step is decided by a `policy` callback (LLM/RBAC/rule engine) as approved / escalated / rejected, stopping on first rejection or human escalation; every step + a final event is written to the transactional outbox (`ai.approval`). `registerApprovalSkills` exposes the `approval.submit` skill bridge (LLM supplies subject/amount/request only; chain + policy stay app-registered; safe default policy escalates to a human).
- **Built-in business tools (P1, risk + recon)**: `zigmodu.ai.risk.RiskReview` scores a subject via configurable SQL rules → level (low/medium/high) → decision (approve/escalate/reject, `DecideFn` hook for LLM/policy) → outbox writeback (`ai.risk`); `zigmodu.ai.recon.ReconCheck` compares source/target SQL snapshots by key (missing / extra / mismatch), fires per-diff `on_diff`, writes a CLEAN/DRIFT summary to the outbox (`ai.recon`) and renders a Markdown diff report (`renderReport`).
- **Built-in business tool (P1, refund with compensation)**: `zigmodu.ai.refund.RefundFlow` validates → approves → executes a refund as a transactional outbox command → notifies; notify failure auto-emits the compensation command (`refund.reverse`), plus app-initiated `compensate()`.
- **Built-in business tool (P1, ticket triage)**: `zigmodu.ai.ticket.TicketFlow` loads customer/order context, classifies, drafts a reply, runs an approval/send gate (`on_send`) and writes the outcome to the outbox.
- **Built-in business tools (P0)**: `zigmodu.ai.reporter.BusinessReporter` renders configured SQL queries as a Markdown report (cron + outbox = scheduled delivery); `zigmodu.ai.alerts.BusinessAlert` runs SQL rules and alerts (callback + outbox writeback) on any violation row.
- **Workflow linear ↔ DAG hybrid**: steps can declare `depends_on`; when any step has dependencies the runner switches to dependency-aware parallel waves (`max_parallel` via `std.Io.Group`) with cycle detection (`error.CyclicDependency`). Budget, WAL persistence, retry and escalation apply in DAG mode too; reflection stays on the linear final step.
- **AI orchestration P2 (runtime control)**: `zigmodu.ai.AgentHandle` cooperative cancel / pause / step progress (checked at step boundaries; `canceled` flag + metric); `Agent.tracer` + `parent_span` create a run-level span via `DistributedTracer`.
- **AI orchestration P2 (context management)**: `zigmodu.ai.context` auto-compacts long conversations by token threshold — older messages are summarized (via `SummarizeFn`) or dropped, prepended as a system message, keeping a recent window; wired into `Agent` (`Agent.context`, checked each loop iteration).
- **AI orchestration P1 (hierarchical)**: `zigmodu.ai.hierarchy` planner → concurrent executor (`std.Io.Group`, `max_parallel` waves) → aggregation; partial failures surface as `.partial_failed`. Planner/executor are callbacks wireable to `Agent`/`Workflow`.
- **AI orchestration P1 (AgentTrigger)**: `zigmodu.ai.trigger` unifies cron / event / webhook sources into `fire(input)` + `registerCron`; optional transactional-outbox writeback of `{run_id, ok, message}` when an `OutboxPublisher` + SQL backend are configured.
- **AI orchestration P1 (WAL persistence + resume)**: `Workflow.wal` + `run_id` persist each step record to the WAL; `resumeRun(run_id)` replays completed steps and continues from the first unpersisted one (crash recovery / idempotent replay).
- **AI orchestration P1 (reflection + escalation)**: `Workflow` gains a reflection quality gate (`VerifyFn` + `max_reviews` — re-runs the final step until verified) and a human-escalation hook (`on_escalate` on step failure after retries / budget exhaustion / persistent verification failure).
- **AI orchestration (P0)**: `zigmodu.ai.workflow` linear multi-step runner (`.llm` / `.skill` / `.agent` steps, per-step records, retry, stop-on-failure, shared budget) and `zigmodu.ai.Budget` (hard token reservation per step; `.stop`/`.warn` modes; wired into `Agent` — `budget_exhausted` flag + metric). Plan + roadmap in `docs/AI_ORCHESTRATION.md`.
- **sockread performance pass**: `readSome`/`readFull` drop the redundant `poll` (std.Io sockets are blocking, so a bare `read` already waits — syscall count halves); new `sockread.Reader` buffered reader collapses many small reads into one larger syscall, adopted by `WsFramer` frame parsing and the Kafka transport; new `sockread.writevAll` sends header+body in a single `writev` (adopted by `WsFramer.writeFrame`, `ClusterConnection.send`, Kafka `writeFrame`). HttpClient keeps its timeout `waitForReadable`.
- **Built-in business AI skills (P0)**: `zigmodu.ai.business` registers `db.query` (read-only parameterized SELECT, row-capped, rejects literals/comments), `entity.lookup` / `entity.list` (app-registered entity whitelist, tenant-scoped when configured) via `SkillContext.backend_ptr`. Scheduler bridge completed with `list_jobs` / `cancel_job` (`ScheduleCtx` via `SkillContext.userdata`). New `ai.freeValue` defines result ownership (handlers dupe keys/strings; callers deep-free). Plan + roadmap in `docs/AI_SKILLS.md`.
- **Raw socket reads for all long-blocking io read paths**: new `core/sockread` helper (`readSome`/`readFull`/`writeFull`, `posix.poll` + `posix.read`/`write`) now backs the reads that wait for peer data — Redis responses (16 call sites), NATS reads (4), Kafka `readExact`, `DistributedEventBus` connection loop, `ClusterConnection.recv` (fixes partial-header reads) and `send` (loops on partial writes so frames are never split), and `HttpClient` `readResponse`/streaming body reads. Same class of fix as the fiber-mode WebSocket read: with the Threaded Io shared across threads, io-based socket reads can block forever even with data in the kernel buffer.
- **Fiber-mode WebSocket read fixed**: `WsFramer.readFrame` / `WebSocketClient` reads now use raw `posix.poll + posix.read` instead of `io.operate(net_read)`. With the Threaded Io shared across the accept thread, worker fibers and clients, io-based socket reads block forever even when data is in the kernel buffer (reproduced: `poll` readable + `MSG_PEEK` shows bytes, `readv` hangs) — so WS client→server frames, ping/close handling and `on_close` never fired. Writes were unaffected. Added an end-to-end regression test (handshake → masked frame → `on_message` → client close → `on_close`).
- **AI ⇄ cron 薄桥**: `Cron.Scheduler` fixed — the background loop now ticks periodically (`std.Io.sleep`), `addJob` is thread-safe (mutex + name copy) with public `tick()` for deterministic scheduling; `every` is a blocking one-shot helper. New `zigmodu.ai.registerScheduleSkills` exposes `list_schedulable_tasks` / `schedule_job` tools so an Agent can attach pre-registered named tasks to cron expressions (LLM never supplies code). `ScheduledTask.TaskScheduler` marked deprecated (never looped; placeholder next-run math) for removal in v1.0.
- **`HttpClient` pure-HTTP path fixed**: the buffered request writer was never flushed, so the request never reached the peer and `request()` deadlocked in a plain `main` (misdiagnosed earlier as an event-loop dependency). `executeRequest` now flushes after writing headers/body. `timeout_ms` (previously stored but unused) is now honored via `posix.poll` in `readResponse` (`error.Timeout` on a stalled peer). Added loopback end-to-end tests: live request round-trip and stalled-peer timeout.
- **`ctx.header()` is now case-insensitive** (RFC 9110): mixed-case lookups like `"User-Agent"` or `"X-Tenant-ID"` resolve to the lowercased parse-time keys. Fixes latent null-header bugs in `AccessLog`, `middleware/Validation`, and the tenant-mgmt example.
- **Postgres `?N` placeholder bug fixed**: `convertPlaceholders` now consumes sqlite-style `?N` digits so `?1` maps to `$1` (previously `$11`, SQLSTATE 42P18), numbers placeholders sequentially, and skips `?` inside quoted strings/identifiers and `--`/`/* */` comments. Added unit tests covering `?`, `?N`, mixed forms, `?12`, literals and comments.
- **Engineering-quality pass**: repo-wide `zig fmt` (src/tools/examples); fixed `examples/zent-modulith` struct-field syntax error; `Server` global-middleware errors on unmatched routes are now logged; silent I/O/DB error swallows converted to logged catches in redis / ClusterMembership / RaftElection / Orm / WAL / Nats / EventBus / HealthEndpoint / ApplicationView / WorkerPool.
- **`check-production` gate extended** to hot-path modules (redis, Nats, ClusterMembership, DistributedEventBus, RaftElection, WAL, Orm) — previously only Server/sqlx/security were scanned.
- **`DistributedEventBus` connection read loop fixed** for the real `std.Io` (threaded) reader: `readSliceShort` returns a byte count, not a slice; the loop previously failed to compile when a real connection path was instantiated (surfaced by `examples/distributed`).
- **`HttpClient.ConnectionPool` tests now use a real loopback listener** instead of always skipping on `ConnectionRefused` to port 9999.
- **Network-dependent tests skip gracefully** in sandboxed/restricted environments via `src/test/NetworkProbe.zig` (raw-syscall probe) instead of crashing the whole test binary with `errnoBug` on `EPERM`.
- **CI hardening**: `ZIG_VERSION` pinned to `0.17.0-dev.1422+e863bf3be`; `zig fmt --check` now covers `src tools examples`; new `examples` job builds all nine examples (incl. `zent-modulith` with a sibling `zent` checkout); `test-live-services` adds a real Kafka broker (`apache/kafka:3.7.2` KRaft) via `KAFKA_BOOTSTRAP`.
- **Module test helpers are public API**: `zigmodu.ModuleTestContext` and `zigmodu.createMockModule` exported from `root.zig` (consistent with `IntegrationTest`/`Benchmark`/`ContractTest`); `examples/testing` updated off the deprecated `zigmodu.extensions` namespace.
- **Repo hygiene**: tracked `wal_test`/`wal_test2` artifacts removed; `.gitignore` covers `wal_test*` and `.codegraph/`.

### Added
- **WebSocket binary frames**: `on_message` receives text (0x1) **and** binary (0x2) with `WsFrameKind`; fiber + io_uring paths; `WsFramer.writeBinary` / `writeData`. Unblocks OpenIM-style protobuf over WS. **Breaking**: `WsMessageFn` gains `kind` parameter.
- **Selective SQL driver linking**: `-Ddb=all|sqlite|postgres|mysql` (comma-list) via `examples/_shared/db_link.zig`; `build_options.enable_*`; disabled drivers use C stubs (no link) and `Client.connect` returns `error.DriverNotEnabled` (also in `ZigModuError`, HTTP 400). Package consumers: `b.dependency("zigmodu", .{ .db = "sqlite" })`. Scaffold/`--from-db` maps DSN → `.db=`. Framework `zig build test` keeps default `all`; CI integration builds use `-Ddb=sqlite`. Guide: [`docs/SQLX_DRIVERS.md`](docs/SQLX_DRIVERS.md).

### Added
- **zent support — shared helper for examples**: `examples/_shared/zent_helpers.zig` provides `StoreEnv(Driver, Infos).open / inMemory / openWith` (RAII wrapper that replaces the open-driver + migrate + make-client dance) and `TestEnv(schemas).init / reset / deinit` (per-test in-memory SQLite with fresh migrations). Both `examples/zent-modulith/` and `examples/shopdemo-zent/` now use it; `examples/_shared/build.zig` runs the helper's own tests.
- **zent docs extended**: `docs/ZENT.md` adds `§6.1 Testing` (TestEnv pattern), `§6.2 Production: ConnPool` (production driver wrapping), `§6.3 Observability` (zent `sql_logger` → ZigModu logger adapter), and `§6.4 Transactions` (beginTx + savepoint). Shared helper callout at the top.
- **`examples/shopdemo-zent` runnable**: parallel of `examples/shopdemo/` using `zent` (ent-style schema-as-code ORM) instead of `zigmodu.data.sqlx`. Single `order` module with `Order` + `OrderItem` zent Schemas, `OrderStore` persistence, `OrderService` validation, and `OrderApi` exposing `POST/GET /api/v1/orders` plus `POST /api/v1/orders/{order_no}/items`. Demonstrates `docs/ZENT.md`'s orthogonal data-stack rule: each module picks one driver and does not mix or share transactions.
- **Completeness Phase 3 — distributed event bus wiring**: `DistributedEventBus` now actually routes through `Partitioner.route(topic)`, captures send failures in `DLQ` after `max_send_failures` threshold, drains DLQ via a retry fiber, and exposes `connectToNode` / `nodeId` / `clusterSize` for membership integration. `WAL.readFrom` is implemented so `replayFromWal` and `restoreFromWal` actually recover uncommitted entries. `ClusterMembership` keeps the partitioner ring in sync on join / leave / failure.
- **SQLx MySQL binary protocol hardening**: `mysqlFetchStringColumn` re-reads oversized values via `mysql_stmt_fetch_column` instead of silently truncating; `mysqlParseDecimal` / `mysqlParseDateTime` / `mysqlParseJson` validate input strictly (negative TIME allowed, fractional seconds `.[0-9]{1,6}`, JSON via `std.json.parseFromSlice`).
- **`examples/shopdemo` runnable**: `build.zig` / `build.zig.zon` / `src/main.zig` / `src/db/*` added; the single `order` module from `generated-sample/` is migrated with API compatibility fixes; `zig build run` starts the app and `GET /api/v1/orders` returns 200.
- **WorkerPool / EventBus observability**: `WorkerPool.WorkerPoolStats.toPrometheusFormat` renders pool stats as Prometheus text; `TypedEventBus` tracks `published_total` and `dropped_async_total` atomically with `publishedCount` / `droppedAsyncCount` getters.
- **Modulith QPS Phase 2 — async EventBus + WorkerPools**: `core.WorkerPool` (bounded queue, graceful stop, error isolation), `TypedEventBus.subscribeAsync` / `ThreadSafeEventBus.subscribeAsync`, `api.Module.RuntimeOptions.worker_count`, and per-module `WorkerPool` integration in `core.ModuleRuntime`. Includes cross-module pilot test and `max_worker_count = 128` guard (`error.ConfigurationError` for 0 or overflow).
- **Modulith QPS Phase 1 — per-module resource isolation**: `api.Module.RuntimeOptions`, `core.ModuleRuntime` (bulkhead + rate limiter + circuit breaker), `core.ModuleRegistry`, and `Application.getModuleRuntime()`. Thread-safe admission via `std.Io.Mutex`, overflow-safe quota validation, and full backward compatibility for modules without runtime options.
- **SQLx connection pool lifecycle**: per-connection `created_at`/`idle_since` timestamps, max-lifetime / max-idle-time eviction, FIFO waiter fairness, and `PoolMetrics` (acquired/released/created/closed/stale-evicted totals, wait time, max active/idle).
- **SQLx streaming cursor**: `Client.queryCursorEx(sql, args, .{ .mode = .streaming })` with driver-native streaming for MySQL (`mysql_use_result`) and PostgreSQL (`PQsendQueryParams` + `PQsetSingleRowMode`). SQLite falls back to buffered mode.
- **SQLx batch protocols**: `Client.batchInsertEx(table, columns, rows, .{ .mode = .protocol })` uses MySQL prepared-statement multi-execute and PostgreSQL `COPY ... FROM STDIN` (CSV). Falls back to multi-row `INSERT` SQL on failure or SQLite.

### Changed
- **SecretsManager / Vault**: Implemented HashiCorp KV v2 HTTP (`loadFromVault` + `applyVaultKvJson`). Plain HTTP + `X-Vault-Token`; `https://` → `VaultTlsNotSupported`. Live smoke: `VAULT_ADDR` + `VAULT_TOKEN`.
- **gRPC**: Removed EXPERIMENTAL. Unary production path — `GrpcFrame`, `GrpcServiceRegistry.invoke` / `handleHttpUnary`, `GrpcClient.bindLocal` + `initWithIo` HTTP/1.1 `application/grpc`. Streaming still returns `UNIMPLEMENTED`.
- **Kafka**: Hardened wire layer — Produce response error-code check, RecordBatch value parse, Fetch value scan; added roundtrip unit tests. Live smoke still via `KAFKA_BOOTSTRAP` / `ROBUSTMQ_URL`.
- **SQLx**: Removed broken `withRows` helper from `data.zig` re-export (no in-tree callers; called `client.queryRows` without the `T` type parameter).

### Fixed
- **SSE Server lifecycle**: `http.sse` / `markSseResponse` sets `ctx.streaming` so Server does not double-`writeResponse` after the handler; `lastEventId(ctx)`; multiline `data:` splitting; `sendRetry` write-buffer alias fix.

### Added
- **zigmodu.ai Agent P0/P1**: `AiProvider.chatWith` + `tool_calls` parse; `SkillRegistry.toOpenAiFunctionsAlloc` / `dispatchAllowed` / `validateArgs`; first-class `ai.Agent` ReAct loop + `AgentHooks`/`AgentMetrics`; `chatStream` buffered shim; `MemoryStore` composite tenant/user keys + `dumpJson`/`loadJson`.
- **zigmodu.ai skill timeout skeleton**: `Tool.timeout_ms`, `SkillContext.deadline_ms` / `expired` / `checkDeadline`, `dispatchWith` → `error.ToolTimeout` (cooperative; not preemptive).
- **HttpClient.requestStream + AiProvider SSE chatStream**: chunked/content-length/EOF body streaming; OpenAI `data:` delta parse with buffered fallback.
- **MemoryStore file persistence + Agent tool timeout**: `saveToFile`/`loadFromFile`; `Agent.tool_timeout_ms` via `dispatchWith`.
- **HttpClient request wire**: auto `Host` + `Content-Length`; path+query; `https://` → `TlsNotSupported` (plain HTTP only, same posture as Vault/OTLP).
- **AI observability / RAG hooks**: `AgentAuditLog`; `Retriever` + `KeywordRetriever`; `Metrics.toPrometheusFormat` for provider and agent.
- **HttpClient HTTPS**: `https://` via `std.http.Client` (system CA, TLS 1.3); HTTPS `requestStream` incremental body read loop; finer transport errors (`TlsHandshakeFailed` / `DnsFailed` / `Timeout`).
- **Agent HITL + RAG wire-up**: `hooks.on_tool_request` / `ToolApproval`; optional `retriever` merges context into system prompt; scaffold `--with-agent` uses core `zigmodu.ai.Agent` + `AiProvider`.
- **AI stream tool_calls + quota**: `chatStream` accumulates streamed `delta.tool_calls`; `TokenQuota` per-tenant skeleton; scaffold `--with-aichat` uses `*AiProvider` + `chatStream` + shared quota; Agent scaffold persists `ai_agent_run`.
- **AiProvider HTTP status mapping**: `AuthError` / `RateLimited` / `UpstreamError` / transport errors.
## [0.14.17] - 2026-07-31

### Added
- **ComptimeRouter + catalog JWT/RBAC**: modules declare `pub const routes` + `mountAll`; `jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.rbac)`; `CatalogPermLoadInput{ sub, aud, roles }` for custom permission loaders.
- **HTTP ergonomics stack**: typed extractors, ProblemDetails/`respondErr`, scope middleware, Testkit, HTTP/resilience profiles, SSE (`http.sse` / `sse_routes`), OpenAPI param merge, outbox/idempotency barrels.
- **HTTP/2 / gRPC / Kafka depth**: H2 stream states + pump, PRIORITY scheduling, h2c Upgrade, WINDOW_UPDATE/SETTINGS, `Http2Tls` ALPN sidecar; ConnWriter write coalesce and GOAWAY/RST isolation; Kafka consumer-group assignors (incl. cooperative_sticky) + `acknowledgeRevocation`.
- **OTLP/HTTP exporter**: `OtlpExporter.exportSpans` POSTs JSON over plain `http://` with retries (`https://` → `OtlpTlsNotSupported`).

### Changed
- **Legacy JWT middleware**: `rbacJwtMiddleware*` / `jwtAuth*` write **`auth_info` only** (safe with ComptimeRouter `user_data` State); new apps prefer catalog Path A.
- **x402 payment verify**: fail-closed by default; inject `PaymentVerifier` / `verifyPaymentAllowAll` only for explicit dev paths.
- **Docs / AI guides**: `AGENTS.md` canonical agent entry (doc map + DO/DON'T); `CLAUDE.md` / `AI_METHODOLOGY` / `BEST_PRACTICES` / `ROUTE_TABLE` §7 aligned to Path A + ComptimeRouter.

### Fixed
- **OpenAPI JSON strings**: escape quotes/backslashes/control chars in title/version/description/summary via `emitJsonStr`.

## [0.14.16] - 2026-07-24

### Changed
- **SQLx circuit breaker Io handle**: `sqlx/breaker.CircuitBreaker` no longer stores `io`. `allow` / `recordSuccess` / `recordFailure` take `io: std.Io` from the caller (`Client` passes `self.io`), so futex waits always use the live Io handle instead of a copy captured at `Client.init`.

## [0.14.15] - 2026-07-24

### Fixed
- **SQLx `Client.open` pool self-pointer dangling after by-value return**: `ensurePool` stored `ConnPool.client = &local` then `return client` moved the struct, leaving `pool.client` pointing at the dead temporary (SIGSEGV at low addresses like `0x70` on next pool use). `open` no longer creates the pool; call `warmPool()` on the final `*Client` for idle warmup. `ensurePool` always rebinds `pool.client = self`.

## [0.14.14] - 2026-07-24

### Fixed
- **SQLx `Client.ensureBreaker` race / segfault**: `cb` was a lazily initialized `?CircuitBreaker`. Concurrent first-touch from worker fibers could tear the optional write (null/`Io.vtable` → segfault on next `allow`/`record*`, often at low addresses like `0x1a0`). `cb` is now a non-optional `CircuitBreaker` eagerly created in `Client.init`; `ensureBreaker` removed.

## [0.14.13] - 2026-07-24

### Fixed
- **SQLx PostgreSQL SafeAllocator panic (alloc=N+1 / free=N)**: `PostgresConn.stmt_cache` stored `allocZ` (`[:0]u8`) names as `[]const u8`, so LRU eviction / close freed without the sentinel. Cache values are now `CachedStmt([:0]u8)`. Same coerce bug fixed in `queryCursorFn` (`if (args.len==0) slice else [:0]`). `bufPrintZ` reserves the last byte for `\0`. `pgDecodeNumeric` no longer writes through a fixed `[256]u8` stack buffer (heap `ArrayList` + safe `dscale`/`lead_zeros` math).

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
