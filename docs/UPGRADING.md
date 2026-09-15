# UPGRADING — 逐版本升级注意

> 每条变更标注 **Breaking?** / **影响面** / **一行改法**。
> 只记"会咬人"的：行为变化、公开签名变化、默认值变化、需要动手删代码的地方。
> 完整变更列表见 [`../CHANGELOG.md`](../CHANGELOG.md)；框架级迁移（Simplified → Application）
> 见 [`API-MIGRATION.md`](API-MIGRATION.md)。

自查命令（升级后先跑这两条）：

```bash
zig build test                          # 框架自测必须默认 -Ddb=all
bash scripts/check-production.sh        # 分层门禁（含热路径裸 catch、信封泄漏）
zmodu ci                                # 业务项目：build + fmt + verify + audit + deadcode
```

---

## v0.15.46

### 上传内容策略（**新增，可选**）

**Breaking?** 否。

**影响面**：所有收文件上传的端点。此前框架只解析 multipart（`http.Multipart`）并限制**体积**，
没有任何**内容**校验，于是每个应用各写一遍，而三种常见写法都有洞：只查扩展名（改名即绕过）、
只查 `Content-Type`（客户端自填）、放行 SVG（脚本容器 → stored-XSS）。

**改法**：

```zig
const mp = zigmodu.http.Multipart.Config.forBodyLimit(64 << 20);
var form = try zigmodu.http.extractMultipart(ctx, mp);      // 415/413/400 → ProblemDetails
defer form.deinit();
try zigmodu.http.UploadGuard.checkForm(&form, .{
    .extensions = &.{ "jpg", "jpeg", "png" },
    .formats = &.{ .jpeg, .png },
    .max_bytes = 5 << 20,
});
```

判定顺序（决定你拿到哪个错误）：大小 → 主动内容（SVG/HTML 默认拒绝）→ 扩展名白名单 →
格式白名单 → 扩展名与内容一致。细节见 `BEST_PRACTICES.md`「上传与 multipart」。

### `http.extractMultipart`（**新增**）

`ctx.multipart` 是裸解析器（错误由调用方映射）；新抽取器与 `extractJson*` 对齐，
失败直接产出 ProblemDetails：415（不是 multipart）/ 413（太大）/ 400（缺 boundary、畸形、part 过多）。

### `Multipart.Config.max_total_bytes` 默认值不可达（**文档修正 + 新 helper**）

**Breaking?** 否，但如果你**以为**设了 `max_total_bytes` 就限住了上传，请检查 `max_body_size`。

服务端在 `content_len > max_body_size`（默认 8 MB）时先 413，`Multipart.parse` 不会被调用 ——
所以默认 `max_total_bytes = 32 MB` 永远不触发。新增 `Multipart.Config.forBodyLimit(n)` 用同一个数字
对齐"单 part ≤ 总量 ≤ body"。

### `ctx.paramPath` → `ctx.nestedParam`（**弃用旧名，行为不变**）

**Breaking?** 否（`paramPath` 保留为别名）。

三个近义名此前各自语义不同，读代码的人会猜错：

| 调用 | 读什么 |
|------|--------|
| `ctx.param` / `ctx.pathParam` | **只读路由占位符**（`/orders/{id}`） |
| `ctx.queryParam` / `ctx.formValue` | 只读 query / 只读 form |
| `ctx.requestParam`（新增） | **form 优先，回退 query**（"客户端放哪都行"） |
| `ctx.nestedParam`（原 `paramPath`） | form/query 里的点号路径（`filter.tags`） |

### `ctx.route_template` 统一带前导斜杠（**标签值变化**）

**Breaking?** 对指标标签是——同一路由的 label 取值会变。

此前模板形状取决于**注册方式**：`group.get("/health")` 带斜杠，`group.get("health")` 与
ComptimeRouter 的 `mountAll`（`nest` + `spec.path`）都不带，于是同一套指标里既有
`/metrics` 又有 `orders/{id}`，写死的 dashboard 查询会漏掉一半。现在注册期统一规整为
`/...` 形式（`Router.addRoute` 的 `normalizeRoutePath`），匹配逻辑不受影响。
**升级动作**：如果 dashboard / 告警里按旧形状（无前导斜杠）过滤，改成带斜杠的形式。

### `CircuitBreakerRegistry` 指针化 + 加锁（**行为修复，一处类型变化**）

**Breaking?** 一处：`breakers` 字段类型 `std.StringHashMap(CircuitBreaker)` →
`std.StringHashMap(*CircuitBreaker)`（仅影响直接读该字段的代码；用 `getOrCreate`/`get` 的不受影响）。

修的是与 `RateLimiterRegistry` 同族的两处缺陷：按值存导致 `getOrCreate` 返回的内部指针在**下一次插入
rehash 后失效**（悬垂指针），以及全程无同步。现在指针在 registry 生命周期内稳定，且所有访问持内部锁。
新增 `count()`；`generateReport()` 从占位串改为真实 JSON。

### `http.UploadGuard` / `SpinLock` 之外的小项

- `RateLimiterRegistry`：新增 `max_keys`（`initWithCapacity`）与 LRU 淘汰、`remove(name)`、
  `retain(max_idle_seconds)`、`generateReport()`。**`max_keys` 默认 0 = 行为不变**；但按 IP 建 key 的
  部署建议设上限：registry 以前只增不减。
- `ShardRouter.ShardedQuery`：**移除**（只能返回 `error.NotImplemented`，且无调用点）。物理分表仍由
  DB 层负责，模块头已写明。
- `PluginManager.loadPlugin`：仍只登记名字、不加载代码，但现在会 **warn 一行**并提供
  `dynamicLoadingSupported() == false`，便于调用方分支（以前是静默 no-op）。
- `ModuleCapabilities.generateApiBoundaryReport` / `CircuitBreakerRegistry.generateReport` /
  `RateLimiterRegistry.generateReport`：占位字符串改为真实 JSON 快照。
- `http.AccessLog` / `http.HttpMetrics`：手写的 `tryLock` 纯自旋（不让出 CPU）改为共享 `SpinLock`
  （自旋后 `yield`）。

---

## v0.15.45

### 错误体可全局统一为 RFC 7807（**行为变化，需显式开启**）

**Breaking?** 否 —— 不调用新 API 时行为**一字未变**。

**影响面**：所有依赖框架自产错误体的地方。修复前有三种形状、只有一种能挂钩：

| 形状 | 触发路径 |
|------|---------|
| `{"code":status,"msg":…,"data":null}` | `ctx.sendError`/`sendErrorResponse`（moduleGate、CSRF、413、408、未捕获 handler 500、静态文件） |
| `{"error":"…"}` | 路由之前写裸 socket（400/408/413/431、accept 线程超额 503） |
| `{status,title,detail,instance}` | `http.respondErr` 等 |

**改法**（启动期一次）：

```zig
// 链内 + 路由前，全部 RFC 7807（media type application/problem+json）
zigmodu.http.useRfc7807Errors();
```

只想要其中一半：

```zig
zigmodu.http.setDefaultReject(zigmodu.http.problemReject);          // 仅链内
zigmodu.http.setTransportErrorRenderer(zigmodu.http.problemTransportBody); // 仅路由前
zigmodu.http.setDefaultReject(null);                                 // 复位
```

- 单个 gate 想自行决定：`.reject = problemReject` / `.reject = envelopeReject(.thinkphp)`；`ModuleGateConfig` 新增 `reject`，**`.unknown = .deny` 可保留**。
- 单条响应想保留旧形状：`ctx.sendErrorEnvelope(status, code, msg)`。
- 装 `useRfc7807Errors()` 后，应用侧"链尾中间件改 404 体"的 workaround 可以删除。
- `ProblemDetails.toJson` 现在正确转义字符串（`detail` 可安全携带校验消息等不可信文本），`statusTitle` 补全 402/411/413/414/415/416/418/428/431/451/501/505/507。

### handler 侧权限匹配（**新增，可选**）

**Breaking?** 否。

**影响面**：路由 meta 用 OR（`portal:user|portal:shop`）而 handler 又需要区分门户的地方 —— 此前只能在 handler 里重写门户检查，窄化一处就 403 一整类用户。

**改法**：

```zig
// before：handler 自己拼门户判断，只认其中一个分支 → 另一门户整类 403
//   （反馈方的真实故障：路由 meta 是 portal:user|portal:shop，
//      handler 复用了只认 .shop 的 requireAppAuth）
if (!shopOnlyAuth(ctx)) { try zigmodu.http.respondErr(ctx, error.Forbidden); return; }

// after：用与路由声明完全相同的表达式问"我是哪一边"
if (!ctx.permissionMatches("portal:user|portal:shop")) {
    try zigmodu.http.respondErr(ctx, error.Forbidden);
    return;
}
// 需要与某个 gate 完全同语义（.roles 只看 roles；.rbac 有 AuthInfo 时以它为准）：
const ok = zigmodu.http.permissionMatchesWith(ctx, "portal:shop", .{ .mode = .rbac });
```

配套新增 `ctx.permissionsCsv()`（与 `rolesCsv()` 同形）。

### Redis 客户端：分帧读 + 单流加锁 + 真超时（**bug 修复**）

**Breaking?** 否（除非依赖了"大回包被截断"的行为，那本就不是契约）。

**影响面**：`RedisConfig.pool_size <= 1`（共享单流）的部署、>4KB 的回复、Redis 不响应时的挂起。修复内容：按 RESP 分帧读到完整回包、无池分支加锁、`read_timeout_ms`/`write_timeout_ms` 真正生效、解析失败即 `close()` 该连接并摘出池。

### `RateLimiter` / `RateLimiterRegistry` / `SlidingWindowRateLimiter` 线程安全（**bug 修复**）

**Breaking?** 是，一处：`RateLimiterRegistry.limiters` 字段类型由 `std.StringHashMap(RateLimiter)` 变为 `std.StringHashMap(*RateLimiter)`。

**影响面**：只有直接读 `.limiters` 的代码（框架内无）。用 `get`/`getOrCreate`/`count` 的调用方不受影响 —— 反而修好了"插入后旧 `*RateLimiter` 失效"的隐患。

**改法**（若你直读过该字段）：

```zig
// before
const lim = registry.limiters.getPtr("key").?;
// after
const lim = registry.get("key").?;            // 或 getOrCreate("key")
```

### `ProblemDetails.statusTitle` 补全状态码

**Breaking?** 否，除非断言过 `statusTitle(418) == "Unknown Error"`（现为 `"I'm a Teapot"`）。新增 402/411/413/414/415/416/418/428/431/451/501/505/507。

---

## v0.15.41

### `Auth.optional` 一等化

**Breaking?** 否。`Auth = inherit | public | jwt` 新增 `.optional`：有 token 就验、失败忽略、**永不 401**，供"公开但可个性化"的接口（C 端用户中心）使用，替代在 `.public` 分支里手写尽力而为的验签。

---

## v0.15.36

### `route_template` 指标标签

**Breaking?** 否，但**建议**把指标 label 从 `ctx.path` 换成 `ctx.route_template`：`path` 带 id，会把 Prometheus 基数打爆。

### 韧性默认值（限流/熔断/背压）

**影响面**：新增连接级背压与慢连接防护；`max_connections` / `over_limit_response` / `header_timeout_ms` 语义见 `BEST_PRACTICES.md`「韧性」。

---

## 模板

```markdown
## vX.Y.Z

### <变更一句话>

**Breaking?** 是/否（若是：一句话说清什么会编译不过或行为改变）

**影响面**：谁会受影响（调用点类型/数量、版本区间）

**改法**：

```zig
// before
// after
```
```
