# Issues from zigshop — 核实与处置

> 来源：**zigshop**（三门户 shop / supplier / C 端）全量真实化 + audit 门禁实战反馈，
> 第 1–13 条 + 附录 A/B/C（2026-09-13/14 基线 v0.15.44）。
> 处置版本：**v0.15.45**。
>
> 与 [`ISSUES_FROM_ZAPI.md`](ISSUES_FROM_ZAPI.md) 同体例：**先核实，再处置**。
> 结论分四类：**属实→已修** / **部分属实** / **已存在（反馈过期）** / **不属实/按设计**。
> 每条给 `file:line` 或 commit 作为依据——评估者应能自己复现结论。

## 汇总

| # | 反馈 | 核实结论 | 处置 |
|---|------|---------|------|
| 1 | sqlx Client/Transaction API 不对称 | **部分属实** | 缺方法已于 v0.15.11 补齐；签名差异属设计，补文档 |
| 2 | 匿名 struct 跨层类型不匹配 | **不属实**（Zig 语言语义） | 文档写明"跨函数边界必须具名" |
| 3 | create/update 参数契约不一致 | **不属实**（业务模型差异） | 不改 |
| 4 | audit 行级豁免注释 | **已存在（v0.15.11+）** | 无需改，反馈方直接用 |
| 5 | audit 规则精确化（b3/b1/b9/b13/b17） | **部分** | b3 已收窄；其余按设计，且都可用行级豁免 |
| 6 | `zmodu audit --explain` | **属实**（小缺口） | **Declined**（理由见下） |
| 7 | 错误集桥接 / 工具产物 / b4 误报 | **部分** | ErrorSetSnapshot 已覆盖；b4 按设计 |
| 8 | `sendError` 渲染信封，与 RFC 7807 冲突 | **属实** | **已修 v0.15.45** |
| 9 | Redis 客户端四件套（无池无锁/单次读/超时未生效/出错不重建） | **属实** | **已修 v0.15.45** |
| 10 | 错误体三种形状，只有一种能挂钩 | **属实** | **已修 v0.15.45** |
| 11 | `RateLimiter` 三类型都不是线程安全的 | **属实** | **已修 v0.15.45** |
| 12 | handler 侧缺权限匹配 + `Context` 缺 `permissionsCsv()` | **属实** | **已修 v0.15.45** |
| 13 | 形状 2 缺文档 / `defaultReject` 无全局 setter / AGENTS 测试计数漂移 | **属实** | **已修 v0.15.45** |
| 附 A | "现状复核"表 | **多处映射错误** | 见文末更正 |

---

## 已修：P0 两条

### #9 Redis 客户端四件套 ✅ v0.15.45

四条**全部复现属实**（`src/redis/redis.zig`）：

| 反馈 | 修复前 | 修复后 |
|------|--------|--------|
| 无池分支不加锁 | `acquireStream()` 无池时直接返回 `self.stream`，全程不持锁 | `stream_mu` 保护单流；`releaseStream(null)` 释放 |
| 每条命令只读一次 socket | 16 处 `sockread.readSome`（一次 `read()`），大回包截断且余字节留在流里 | `readWholeReply()` 按 RESP 分帧：`+`/`-`/`:` 读到 CRLF，`$`/`*` 先读长度再读体，尾部 CRLF **从流里消费** |
| 超时字段未生效 | `read_timeout_ms`/`write_timeout_ms` 全仓无读取点 | 读路径每次阻塞前 poll 到 deadline（超时 `RedisTimeout`）；写路径 `SO_SNDTIMEO` |
| 出错连接不重建 | `close()` 只在 deinit 路径 | 任一解析/超时失败 → `evictStream()`：池内槽位置空并关闭，绝不复用 |

**实测**：本机真实 Redis（`REDIS_URL=redis://127.0.0.1:6379`）下 `pool_size = 1` 单流 32 线程并发 INCR —
修复前该形状是 60 路并发 `11 × 500` 且随后端点永久挂起；现在 10 个 redis 测试（含 RESP 解析、真实命令解析、两个并发用例）全绿。

> 分帧读还顺带抓出一个**实现层**缺陷：`$N` 的结尾 CRLF 原先是凭空补的、没从 socket 消费，于是每个 bulk 回复都在流里留下 2 字节 —— 正是"下一条命令 desync"的老病根。现在 `readCrlf()` 消费并校验它。

### #10 错误体三种形状 → 一条开关 ✅ v0.15.45

反馈属实。三种形状 × 触发路径 × 修复前能否挂钩：

| 形状 | 触发路径 | 修复前 |
|------|---------|--------|
| `{"code":status,"msg":…,"data":null}` | `ctx.sendError`/`sendErrorResponse`：moduleGate 403/404、CSRF、413、请求超时 408、**未捕获 handler 500**、静态文件错误 | 只有 4 个 gate 有 `.reject`，内部站点够不到；无全局 setter |
| `{"error":"…"}` | 路由**之前**写裸 socket：400/408/413 `BodyTooLarge`/431 `TooManyHeaders`、accept 线程超额 503 | 中间件链之外，任何钩子都够不到 |
| `{status,title,detail,instance}` | `http.respondErr` / `respondProblem` / 显式 `.reject` | 能挂钩，但只有被显式接上的地方 |

修复后：

```zig
// 启动期一行：之后框架生成的错误体全部是 RFC 7807
zigmodu.http.useRfc7807Errors();
```

- 链内：`http.setDefaultReject(renderer)` 装进程级渲染器，`ctx.sendError`/`sendErrorResponse` 一律走它 —— 于是**所有内部调用点**一次到位（`Server.zig` 8 处 + `Middleware.zig` 4 处，含 `handleRequest` catch 里的 500，中间件永远抓不到那个；gate 经 `cfg.reject` 默认转发的站点同样覆盖，因为 `defaultReject` 就是走 `ctx.sendError`）。
- 路由前：`http.setTransportErrorRenderer(fn)` + 现成的 `http.problemTransportBody`；默认行为一字未改。
- `ModuleGateConfig` 补 `reject: AuthRejectFn` —— 应用可以**保留** `.unknown = .deny` 同时改 404 体，不必再退回 `.allow`。
- 逃生口：`ctx.sendErrorEnvelope(status, code, msg)` 绕过渲染器；`http.clearDefaultReject()` 复位（测试用）。
- 防自递归：`setDefaultReject(defaultReject)` 解析为"不装渲染器"（`defaultReject` 正是经 `ctx.sendError` 转发，装它会无限递归）。

顺带修掉 `ProblemDetails` 自身的两个缺陷：`toJson` 对 `detail`/`instance`/`type` **不做 JSON 转义**（校验消息带引号就会产出非法 JSON），以及 `statusTitle` 缺 402/413/431/414/415/416/428/451/501/505/507 等本框架真会发出的状态码。

> 反馈方在 8.1 节写的应用侧 workaround（`problem_fallback.zig` 链尾中间件 + 把 `moduleGate` 改成 `.allow`）现在**可以删掉**，并且可以把 `.unknown` 收回 `.deny`。

---

## 已修：P1 两条

### #11 `RateLimiter` 三个类型都无同步 ✅ v0.15.45

属实：`grep -c "Mutex|atomic|fetchAdd"` = 0。并发下的实际后果**不是抽象风险**：

- `RateLimiter.current_tokens` 的读-改-写竞争 → **同一枚令牌被两个线程花掉**（超额放行）。
  实测：把守卫临时去掉后，100 枚令牌的并发用例被放行 **117** 次（`expected 100, found 117`）。
- `RateLimiterRegistry` 的 `StringHashMap.put` → 元数据撕裂（与应用侧 `http_metrics` 那次同类）。
- `SlidingWindowRateLimiter.requests` 的 `ArrayList.append` → realloc 时竞争。

修复：三类各加内部 `Guard`（短自适应自旋锁：先 `spinLoopHint`，32 次后 `std.Thread.yield()`）。
选自旋锁而非 `std.Io.Mutex` 的原因写在文件头：临界区只有一次 map 查找或两次浮点运算，而 `std.Io.Mutex.lock/unlock` 需要 `Io`，会被迫改 `init`/`tryAcquire`/`authRateLimitMiddleware`/`RedisRateLimiter.allowWithFallback` 四个公开签名；真出现争用时该做的是**分片限流器**，不是加锁。

顺带修掉一个**同类 UAF 隐患**（与反馈方引用的 zent 连接池 bug 同族）：`RateLimiterRegistry` 原先 `StringHashMap(RateLimiter)` **按值存**，`getOrCreate` 返回的 `*RateLimiter` 指向 map 内部存储，**下一次插入触发 rehash 就失效**。现在改存 `*RateLimiter`（堆分配），指针在 registry 生命周期内稳定 —— 有测试（插入 257 个 key 后旧指针仍可用）。

### #12 handler 侧权限匹配 + `permissionsCsv()` ✅ v0.15.45

属实：gate 的 OR 语义（`portal:user|portal:shop`）是公开契约，但 handler 侧没有等价入口；`Context` 有 `userId/userIdInt/tenantId/rolesCsv` 却独缺 `permissionsCsv()`。

修复（并把匹配原语下沉到叶子模块 `src/security/Rbac.zig`，gate 与 handler 共用一份实现，杜绝两套语义漂移）：

| API | 用途 |
|-----|------|
| `ctx.permissionsCsv()` | 与 `rolesCsv()` 同形，读 `PermissionGateConfig.permission_attr` |
| `ctx.permissionMatches(expr)` | handler 问"我是哪一边"：AuthInfo / `permissions` / `roles` 任一命中即为真 |
| `http.permissionMatchesContext(ctx, expr)` | 上者的函数式别名 |
| `http.permissionMatchesWith(ctx, expr, config)` | **与某个 gate 完全同语义**（`.roles` 只读 roles；`.rbac` 有 AuthInfo 时以它为准），handler 的答案不会与 gate 不同 |

---

## 部分属实 / 已存在 / 不属实

### #1 Client/Transaction API 不对称 —— 部分属实

**仍属实**的是签名差异；**已不属实**的是"方法不存在"：

- `Transaction.queryRowPartial`（`sqlx.zig:5122`）与 `Transaction.queryRows`（`:5131`）自 **v0.15.11**（commit `3fcc2b8`，2026-08-06）起已存在。反馈方若仍报"不存在"，是在更早的版本或未同步的 pin 上。
- 签名差异保留：Client `queryRow(T, sql, args)` 无 allocator，Transaction `queryRow(allocator, T, sql, args)` 需要 —— `Transaction` 不持有 allocator（它借连接），必须由调用方给。这是类型决定的事实，不是笔误，已在 [`BEST_PRACTICES.md`](BEST_PRACTICES.md) 写清两套签名与 `Rows.deinit` / `ManagedRows.deinit` 的生命周期归属。

### #2 匿名 struct 跨层类型不匹配 —— 不属实（语言语义）

Zig 里同名内联 struct 是**不同类型**，`expected A, found B` 是正确诊断。框架能做的是提供具名容器（`data.PageResult(T)` 已在），文档写明"跨函数边界返回必须具名类型"。已在 BEST_PRACTICES 补条目。

### #3 create/update 参数契约不一致 —— 不属实（业务模型差异）

`assemble`/`bargain`/`point`/`seckill` 的"活动商品"字段不同是**业务事实**，不是框架 API 的契约。`autoCrud` / `data.CrudService(Entity, Persistence)` 的 create 与 update 由**同一实体**派生，不存在"create 全字段 / update 动态 SET"的框架级不一致。

### #4 audit 行级豁免 —— 已存在（v0.15.11+），反馈过期

`tools/zmodu/src/audit.zig:1010` 起 `lineHasIgnore()`：裸 `// audit: ignore`（全部规则）与 `// audit: ignore b13,b17`（指定规则）都会丢弃**该行**的违规，精确替代"规则级 disabled（太宽）"与"基线吸收（噪音）"。落地 commit `636f688`（2026-08-06，v0.15.11）。**不需要新机制，直接用。**

### #5 audit 规则精确化 —— 部分

| 规则 | 反馈的误报 | 现状 |
|------|-----------|------|
| b3 | 常量 `'points_config'`、`''`、`%Y-%m` | 空字面量**已排除**（同 v0.15.11）；非空常量仍报 —— 一行文本里区分"常量"与"用户输入"是猜测，规则消息直接告诉你怎么写 `?`。误报用行级豁免 |
| b17 | 函数内局部标量 struct | 规则是"queryRow/queryRowPartial 的所有权字符串未释放"（`audit.zig:1075`），不是类型作用域问题；确认已释放的用豁免 |
| b1 | 动态 WHERE 列表查询 | 只扫 `api.zig` 的 `.exec(`/`queryRow(`/`queryRows`/`queryCursor` —— SQL 应在 persistence/service。读查询也不例外（BFF 边界应下沉一层） |
| b13 | 全项目模板直接返实体 | 只扫 `api.zig` 的裸 `jsonStruct(实体)`；无敏感列也仍建议走 DTO，或者用豁免写明理由 |
| b9 | oss/identity 手动 Bearer | 只扫 `api.zig` 的 `Authorization`/`parseBearer`/`bearer_*`；反馈场景在 `oss`/`identity` 模块（不在 `api.zig`）本就不会触发 |

### #6 `zmodu audit --explain` —— 属实，**Declined**

未实现。但每条违规消息本身已经含"含义 + 为什么 + 豁免写法"（例：`请求路径裸 @alignCast … 确认来源后用 // audit: ignore b21 并注明出处`）。再维护一张 id → 说明的**第二份**规则表，只会与现场消息漂移（这正是本仓 `DocsConsistency` 门禁在防的那类问题）。若确实需要，正确做法是把消息抽成 `const` 表、现场与 `--explain` 同源——作为 backlog，优先级低于上面两条 P0。

### #7 错误集桥接 / 工具产物 / b4 误报 —— 部分

- 错误集：`src/test/ErrorSetSnapshot.zig`（v0.15.43）已把公开 API 错误集快照化，**无 `anyerror`**，放宽即门禁失败。handler 侧 `anyerror`（`HandlerFn`）是刻意的：中间件链要能传播任意错误。
- `tools/zmodu` 与根 `build` 的产物路径：已补文档。
- b4（`@ptrCast` + `user_data` 同行）：**按设计**。`user_data` 只应放 ComptimeRouter 的 `*State`（见 `AGENTS.md`），把 AuthInfo 塞进去正是要禁的写法。

---

## 附录 A"现状复核"表的更正

反馈方对照 CHANGELOG 做的映射有几处对不上，照抄会误判进度：

| 反馈方的映射 | 实际 |
|-------------|------|
| "第 3 条 Repository/CRUD 参数契约 → 已落地：`ErrorSetSnapshot`" | 不相关。`ErrorSetSnapshot` 是**公开 API 错误集快照**；第 3 条（各模块商品字段不同）是业务模型差异，非框架项 |
| "第 6 条 audit 规则文档内建 → 已落地：`DocsConsistency.zig`" | 不相关。`DocsConsistency` 查的是**文档里的 API 签名与源码一致**；audit 规则说明是另一套 |
| "第 7 条 框架/工具 → 已落地：`CombinationMatrix.zig`" | 仅部分：`CombinationMatrix` 覆盖 `moduleGate × skip_prefixes`、`tenantResolver × aud`，不含"错误集桥接"与"zmodu 产物文档化" |
| "第 4 条 audit 行级豁免 → 部分落地（只有 ZENT.md 自查三命令）" | 实际**早已完整落地**（`// audit: ignore bNN`，v0.15.11） |
| "第 1 条 → 未看到 Client/Tx 同名同形签名对齐" | 缺方法已对齐（v0.15.11）；allocator 参数差异是类型决定的，不会对齐 |

---

## 相关文档

- 升级注意事项（含本版 breaking 项与影响面）→ [`UPGRADING.md`](UPGRADING.md)
- 错误形状表 / anytype 契约 / 线程安全级别 → [`BEST_PRACTICES.md`](BEST_PRACTICES.md)
- 代码 ↔ 文档一致性门禁 → `src/test/DocsConsistency.zig`

---

# 第二轮反馈（v0.15.46 处置）

4 条，来自"三门户全量真实化"之后的再次实战。**3 条属实、1 条机制说反了**。

## 汇总

| # | 反馈 | 核实结论 | 处置 |
|---|------|---------|------|
| 1 | 上传内容策略是唯一真缺口 | **属实** | 新增 `http.UploadGuard`（嗅探 + 一致性 + SVG 拒绝） |
| 2 | 没有 `extractMultipart` | **属实** | 新增 `http.extractMultipart`（415/413/400 → ProblemDetails） |
| 3 | `route_template` 在 legacy `addRoute` 路径为 null | **不属实**（机制）；但**存在真问题**：同一概念两种标签形状 | 注册期统一前导斜杠 + 4 条测试 |
| 4 | `Multipart.max_total_bytes` 默认值永不生效 | **属实** | 文档写明判定顺序 + 新增 `Config.forBodyLimit` |

## #1 上传内容策略 ✅ v0.15.46

属实。`grep -n "magic\|sniff\|extension\|whitelist\|MIME" src/http/Multipart.zig` → **零命中**：
框架只解析 + 限体积（`max_parts` / `max_part_bytes` / `max_total_bytes`），没有任何内容校验。
反馈方列的三种错法全部成立，其中 SVG 那条最危险——它是脚本容器，从自己的源站发出去就是 stored-XSS。

新增 `src/http/UploadGuard.zig`：

- `sniff(bytes)`：JPEG/PNG/GIF/WebP/BMP/TIFF/PDF/ZIP/GZIP/**MP4（ISO-BMFF：校验 box size 与 `ftyp`，
  而不是只在固定偏移看到 `ftyp` 就放行）**/WebM/OGG/MP3/WAV + 文本容器分类（`<svg`/`<!doctype html`/
  `<script` → 主动内容，其它文本 → `plain`）。
- `check(filename, data, policy)`：判定顺序**故意固定**为 大小 → 主动内容 → 扩展名白名单 → 格式白名单 →
  扩展名与内容一致。于是"`avatar.jpg` 里是 PHP"报 `ContentNotAllowed`（内容不是接受的格式），
  而"PNG 字节挂 `.jpg` 名"报 `ExtensionContentMismatch`（两边各自合法但互不相符）。
- **SVG/HTML 默认拒绝**，即使 `extensions`/`formats` 里写了它 —— 必须显式 `allow_active_content = true`。
  默认 fail-closed，与 x402 同一取向。
- `checkForm(form, policy)`：遍历 file part（无 filename 的文本字段跳过），第一个不合规即拒绝。

## #2 `extractMultipart` ✅ v0.15.46

属实：抽取器有 `extractPath/Query/Json/JsonValidated/JsonLoose`，唯独 multipart 没有，
`http.Multipart` 只是裸解析器，错误得由每个 handler 自己映射成状态码。

新增 `http.extractMultipart(ctx, config)`，与 `extractJson*` 同款：415（不是 multipart）、
413（太大）、400（缺 boundary / 畸形 / part 过多）都直接产出 ProblemDetails；
`OutOfMemory` 不渲染（那是服务端的 500，不是客户端的错）。

## #3 `route_template` —— 机制说反了，但问题存在 ✅ v0.15.46

反馈称"该字段只在 ComptimeRouter 的两条派发路径被赋值，`addRoute` 注册的路由拿到 null"。
**核实不成立**：全仓只有两个派发点（`Server.zig` 的 `handleForTest` 与 `handleRequest`），
**都**执行 `ctx.route_template = m.route.path`，而 `/metrics` 正是经 `addRoute` → `self.router.match`
进来的（`PrometheusMetrics.registerMetricsRoutePath` 走同一条路）。

用测试钉住真相后发现**另一个真问题**（`src/test/RouteTemplate.zig` 4 条用例）：

| 注册方式 | 修复前的 `route_template` |
|---------|------------------------|
| `group.get("/health", …)` | `/health` |
| `group.get("health", …)` | `health` |
| ComptimeRouter `mountAll`（`nest` + `spec.path`） | `orders/{id}` |
| `addRoute(.{ .path = "/metrics" })` | `/metrics` |

即形状取决于**调用方怎么写**，而 `ctx.path` 永远是带斜杠的形式 —— 同一套指标里既有 `/metrics`
又有 `orders/{id}`，写死的 dashboard 查询会漏掉一半。

修复：`Router.addRoute` 里新增 `normalizeRoutePath`（那里本来就在 dupe 路径，**零额外开销**），
统一为"恰好一个前导斜杠"。匹配逻辑不受影响（trie 按 `/` 切分并跳过空段，不用这个字符串）。

## #4 `Multipart.max_total_bytes` 默认值不可达 ✅ v0.15.46

属实。`Server.zig:1331` 在读体阶段就 `content_len > max_body_size` → 413，
`Multipart.parse` 根本不会被调用；默认 8 MB（body）< 32 MB（multipart 总量），所以后者永不触发。

处置（按反馈给的两个选项**都做**）：

1. 文档：`Multipart.zig` 模块头 + `Multipart.Config.max_total_bytes` + `Context.multipart`
   三处写明判定顺序与"必须先抬 `max_body_size`"；新增 `BEST_PRACTICES.md`「上传与 multipart」
   一节（含限额优先级表）。
2. 代码：新增 `Multipart.Config.forBodyLimit(body_limit)`，用同一个数字对齐
   "单 part ≤ 总量 ≤ body"，避免手算。

**未改默认值**：把 32 MB 降成 8 MB 会改变"已抬 body 上限但依赖 32 MB 总量的调用方"的行为——
那是静默破坏，不是修复。宁可把顺序写清楚，并提供对齐工具。

## 顺带发现（同族缺陷，一并修）

- **`CircuitBreakerRegistry` 有与 `RateLimiterRegistry` 同族的两处缺陷**（反馈未提）：
  按值存 `CircuitBreaker` → `getOrCreate` 返回的内部指针**下一次插入 rehash 后失效**；全程零同步。
  已改为堆分配指针 + 内部锁，`generateReport` 从占位串改为真实 JSON。
- **两个热路径锁是"纯自旋不让出"**（`http/AccessLog.zig:35`、`http/HttpMetrics.zig:51`）：
  `while (!mutex.tryLock()) spinLoopHint();` 在争用下烧 CPU。改为共享 `core/SpinLock.zig`
  （自旋 32 次后 `std.Thread.yield()`），并把 14 处 `self.mutex.state.store(...)` 的裸解锁
  换成 `self.mutex.unlock()`。
- **`ShardRouter.ShardedQuery.tableForTenant`**：只能 `return error.NotImplemented` 且无任何调用点 ——
  删除（物理分表本来就交由 DB 层），模块头写明。
- **`PluginManager.loadPlugin`** 注册名字但不加载代码（静默 no-op）：改为每次都 warn，
  并新增 `dynamicLoadingSupported()` 让调用方可以分支。
- **`Partitioner.zig` 文件头自称"tests are disabled"**：实际 3 条测试都在跑且通过 —— 注释改为实情
  （该模块确实未被 `DistributedEventBus` 使用，这点保留）。
- **`FluvioConnector`**：log 降级模式**已经**是显式且可检测的（`isCliAvailable()`），无需改动。
