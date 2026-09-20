# ZigModu v0.31.0 安全审计

> 只读静态审计（无端到端 PoC）。**引用由仓库维护者逐条复核过**：
> 高危①的三处证据（`Server.zig:2657` 在 `router.match:2724` 之前、`RouteGroup.ws` 只写 `ws_handlers`、
> `findEntry` 跳过 `is_ws`、`Testkit.zig:218` 跳过 `is_ws`）与高危②的（`:1474` 只认 `": "`、
> 全文无 `transfer-encoding`、`Method.fromString` 未知方法一律折成 `.GET`）**均已独立验证成立**。
> 文中的"没读"清单同样重要 —— 集群帧解码与 `WsFramer` 是**未审计**的高风险段。


# ZigModu v0.31.0 安全审计（只读）

**结论（3 行）**
1. **最高危：WebSocket 路由完全绕过全局中间件链** —— `ws_routes` 声明的 `.auth = .jwt` 只是 catalog 里的元数据，升级请求在 `router.match`/`executeWithMiddleware` 之前就被处理掉了；仓库自带的 auth 审计还会主动跳过 `is_ws`。脚手架的 IM 模块因此用 `?userId=` 当身份。
2. **次高危：HTTP/1.1 请求边界只认 `Content-Length`（且只认 `": "` 写法）**，完全不处理 `Transfer-Encoding`，配合 keep-alive 复用同一 reader → 与任何按规范解析的代理（仓库自带 nginx/Envoy 拓扑）产生 CL/TE 请求走私。
3. 其余为 3 条「中等」（fail-open 的数据权限、agent `db.query` 无租户过滤、中间件工厂状态是函数级全局 + 权限门空 catalog 放行）与若干「低」。

---

## 1. 真实发现

### ① 高 — `src/api/Server.zig:2657-2674`（WS 升级）—— WebSocket 路由不经过任何全局中间件，`ws_routes` 的 `.auth` 声明不生效

证据（三处相互印证）：

```zig
// Server.zig:2657  —— 在 router.match(2724) 与 executeWithMiddleware(2745) 之前
if (server.ws_handlers.get(ws_lookup_path)) |ws_route| {
    if (std.mem.eql(u8, request.method.toString(), "GET")) {
        if (std.ascii.eqlIgnoreCase(upgrade_hdr, "websocket")) {
            ... framer.handshake(ws_key) ...          // 2666 先握手
            const session = ws_route.on_connect(&ctx, @ptrCast(&framer));  // 2674 直接调业务回调
```
```zig
// Server.zig:182-194 —— RouteGroup.ws 只写 ws_handlers，不注册进路由树
try self.server.ws_handlers.put(dup_path, .{ .on_connect = ..., });
```
```zig
// ComptimeRouter.zig:715-732 —— catalog 里仍然记 auth = .jwt
try group.ws(spec.path, spec.on_connect, ...);
try self.router.catalog_buf.append(..., .{ .method = .GET, .auth = auth, .is_ws = true, ... });
// ComptimeRouter.zig:143 —— 而 findEntry 对这条例目直接 continue（`if (e.is_ws) continue;`）
```
脚手架生成的 IM 模块正是这么写的：`tools/zmodu/src/main.zig:7706-7713` 声明 `ws_routes = .{ .{ .path="ws", ..., .meta = .{ .auth = .jwt } } }`；而它的 `accept()` 把 WS 身份取自**查询串**：`tools/zmodu/src/main.zig:7844` `const user_id = ctx.queryInt(u64, "userId", 0); if (user_id == 0) return null;` → `registry.register(user_id, ...)`。同一模板的 HTTP 侧 `listConversations` 也从 `?userId=` 取身份（:7724）。

为什么现有防护接不到它：
- `jwtAuthFromCatalogWithPermissions` / `permissionGateWith` / `moduleGate` / `x402Middleware` / `csrf()` 全部是**全局中间件**，只在 `executeWithMiddleware` 里跑；WS 分支在它之前 `return`（`Server.zig:2690` `return; // Fiber exits`）。
- catalog 即使被查询也查不到：`findEntry` 主动跳过 `is_ws`（`ComptimeRouter.zig:143`）。所以「catalog 是唯一 bypass 真相」这条设计在 WS 上两头都断。
- 仓库自己的审计也看不到：`src/http/Testkit.zig:218` `if (e.is_ws or e.is_sse) continue;` —— `auditAuthCoverage` 会**主动跳过** WS 条目，CI 里也永远报绿。
- `comptime_router.pathHasSkipPrefix` 与 `permissionGate` 都不会碰这条路径。

攻击者需要满足：目标应用用 `ws_routes`/`group.ws` 暴露了 WS（把身份判断留给 `on_connect`）。此时任何客户端无需 token 即可完成握手并触发 `on_connect`；用脚手架模板时可直接 `?userId=<任意人>` 订阅/发送任意用户的消息（`tools/zmodu/src/main.zig:7844-7863`）。

---

### ② 高 — `src/api/Server.zig:1459-1499` ＋ `:2504` —— 请求头只认 `": "`、完全不处理 `Transfer-Encoding`：与前置代理的请求边界不一致（CL/TE 走私）

证据：
```zig
// Server.zig:1474  解析只在 ": "（冒号+空格）时成立
if (std.mem.indexOf(u8, header_line, ": ")) |colon_pos| { ... try headers.put(key_raw, value); }
//   否则这行被静默丢弃 —— "Content-Length:5"（无空格）等于该头不存在
// Server.zig:1484  整个解析函数里唯一影响 body 的头
if (headers.get("content-length")) |len_str| { ... }
//   全文没有 headers.get("transfer-encoding")（grep 只在响应构造 1976/1991 出现）
// Server.zig:1431-1441  请求行只取 method 与 path，第三段（HTTP 版本）不校验、也不拒绝多余字段
// Server.zig:2504/2559  同一 reader 上循环解析下一个请求（keep-alive，默认 max_requests_per_conn=100，:2068）
```
即：`Transfer-Encoding: chunked` 的请求体不会被消费，它会留在 reader 里，被当成**下一个请求的请求行**（`Server.zig:2559`）。`Content-Length:5`（无空格）同理。而请求行本身很宽松：`Method.fromString` 把任何未知/畸形方法都变成 `.GET`（`Server.zig:53-67`，`else => .GET`），且 `request_line.len >= 14` 之后只按空格切 method/path（:1434-1441）——所以 chunk-size 行可以写成 `1;GET /admin HTTP/1.1`，后端会把它解析成 `GET /admin` 并进路由。

为什么现有防护接不到它：`max_body_size`/`BodyTooLarge`、`header_limits`(100 行 / 16KB)、`header_timeout_ms` 都只约束单个请求的规模与时序，不比对「哪个头定义边界」；`validateSqlFragment`、审计规则、`productionProfile` 都不涉及 HTTP 框架层。响应侧的 `Transfer-Encoding: chunked` 支持（:831）反而容易让人误以为请求侧也支持。

攻击者需要满足：请求经过一个按 RFC 解析的代理/网关——nginx 接受 `Content-Length:5`（冒号后空格可选），Envoy/nginx 会拒绝同时出现 TE+CL，但**只出现 `Content-Length:5` 或只出现 TE 的形态不受该拒绝保护**。仓库自带 `examples/production-deploy/`（nginx、Envoy、k8s、systemd）正是这种拓扑。直接影响：后端解析出的请求数与代理不一致 → 响应队列错位（A 的响应发给 B）、绕过代理侧 ACL、缓存投毒。**我没有跑端到端 PoC**（见第 2 节）。

---

### ③ 中 — `src/datapermission/DataPermission.zig:44-51` — `.dept_custom` 的空/坏 `dept_ids` 返回 `null`，按契约等于「全放行」

证据：
```zig
.dept_custom => {
    if (self.dept_ids) |ids| {
        if (ids.len == 0) return null;      // 46: 空列表 → 无过滤
        ...
    }
    return null;                            // 50: 解析失败/缺失 → 无过滤
},
```
```zig
/// `Scope clause for the current context (null = everything allowed).`   // :88
```
```zig
// :20-34 fromRoles: 角色 JSON 解析失败被吞成 null → 走 50 行
ctx.dept_ids = parseDeptIds(allocator, json_str) catch null;
// :123-131 parseDeptIds: 每个 token 解析失败都 `catch continue` → 全失败 = 空列表
```
调用方的用法就是「null 即不过滤」：`examples/zmsaas/backend/src/shard.zig:126-141`
```zig
const filter = try interceptor.andWhere(&dp, "region", "owner_id");
... "SELECT ... WHERE org_id = ?";
if (filter) |f| { sql.appendSlice(" AND "); sql.appendSlice(f.clause); }   // filter=null → 无任何数据权限子句
```

为什么现有防护接不到它：这是纯运行期数据（角色行 `data_scope=2` + `data_scope_dept_ids='[]'` 或 `'["a"]'`），编译期 guard 不涉及；框架在 **zent 侧**已经修过同类问题（v0.66「空 `dept_ids` 拒绝而非放行」），sqlx 侧的这条路径没有同步。

攻击者需要满足：拥有一个「自定义部门范围」但没勾选部门（管理后台很容易产出 `'[]'`）或该字段被写成非数字的用户角色 → 该角色用户能看到本应被部门范围限制的全部数据（同一租户内越权读）。这是自上而下 fail-open，`buildWhere` 里 `.dept_and_child` 还被实现成单部门等值（:57-61），说明这段的分支语义本就没有被认真核对。

---

### ④ 中 — `src/ai/business.zig:104-150` — `db.query` 技能对 agent 开放任意 SELECT，**没有**租户过滤（同文件的 `entity.*` 有）

证据：`db.query` 的全部校验是
```zig
if (sql.len < 6 or !std.ascii.eqlIgnoreCase(sql[0..6], "SELECT")) return error.ReadOnlyQueryRequired;  // :121
try sqlx.validateSqlStatement(sql); // 只挡字面量/注释/; （:122）
```
对比同文件的兄弟技能确实做了租户约束：
```zig
if (spec.tenant_column) |tc| { if (ctx.tenant_id) |tid| { ... } }   // :183-190、:244-250
```
测试用例也证明了这一点——`db.query` 的测试要 agent **自己**把 `WHERE tenant_id = ?` 写进 SQL（:294-297）。

为什么现有防护接不到它：`ai.Guard` 的模型是「`.read` 默认允许」（`src/ai/skill.zig:509` `.{ "db.query", .read }`），行数上限（默认 20/上限 100，:126）只限条数不限范围；`AiBoundary` 只查 import 方向。于是「read-only」被当成安全属性，而泄漏恰恰发生在读侧。

攻击者需要满足：应用把 `db.query` 注册进 agent（框架提供的现成能力），且 agent 的 SQL 参数可被间接控制（提示注入 / 用户可控的 goal）。跨租户读全表，可反复调用绕过行数上限。

---

### ⑤ 中 — `src/api/Middleware.zig:975-1042`（＋ `:318-327`、`src/security/AuthMiddleware.zig:29-66`）—— 中间件工厂把配置存在**函数级全局**；`permissionGateWith` 在 catalog 为空时放行

证据：
```zig
pub fn permissionGateWith(slot: *comptime_router.CatalogSlot, config: PermissionGateConfig) api.Middleware {
    const Store = struct {                   // 非泛型函数内的嵌套 struct → 进程内唯一
        var catalog_slot: *comptime_router.CatalogSlot = undefined;
        var cfg: PermissionGateConfig = .{};
    };
    Store.catalog_slot = slot; Store.cfg = config;   // 第二次调用覆盖第一次
```
```zig
const cat = Store.catalog_slot.get() orelse { try next(ctx); return; };   // :989-992 无 catalog = 直接放行
```
同一模式还有 `securityHeaders`（S.stored，:1104-1114）与 legacy `jwtAuth`（`AuthMiddleware.zig:30-34` `var stored_security`）。对照：`jwtAuthFromCatalog*`/`authFromCatalog`/`tenantResolver`/`moduleGate` 都是 `page_allocator.create(Store)` 每调用一份（`Middleware.zig:481、524、803、868`）——**同一个文件里两种写法并存**，说明 `permissionGateWith` 是有意为之还是疏漏无人核对。

为什么现有防护接不到它：编译期图检查只查模块依赖；一个进程里跑两个 `Server`（如公网 API + 内网 admin，或相互独立的测试 server）是合法用法，此时：
- `permissionGateWith` 会读**另一个** server 的 catalog → 若目标路径在那份 catalog 里是 `.public`，本 server 上的权限检查被跳过；
- `.mode`/`deny_by_default` 等配置也会互相覆盖；
- legacy `jwtAuth` 的 `stored_security` 会让第二个 server 用**最后一个** secret 验签（跨实例身份混淆）。
另外 `Store.catalog_slot.get()` 返回 null 时权限门 fail-open，而同族的 `jwtAuth*` 在同样状态下 fail-closed（`Middleware.zig:534-545`）——不对称。

攻击者需要满足：部署形态是「一个进程两个 server/两个 catalog slot」（框架未禁止、也未检测），或在权限门尚未 `slot.set()` 的窗口期发请求。仅一个 server 时不可利用。

---

### ⑥ 中 — `src/security/ApiKeyAuth.zig:119-136` — API key 生成器的种子是「毫秒 + 栈地址 + 常量 42」，输出可预测

证据：
```zig
var seed: [32]u8 = undefined;
std.mem.writeInt(u64, seed[0..8], @intCast(Time.monotonicNowMilliseconds()), .little);
std.mem.writeInt(u64, seed[8..16], @intCast(42), .little);          // 常量
std.mem.writeInt(u64, seed[16..24], @intFromPtr(&buf), .little);    // 栈地址（ASLR）
std.mem.writeInt(u64, seed[24..32], @intCast(Time.monotonicNowMilliseconds() * 1000), .little);  // 同上，可导出
var csprng = std.Random.DefaultCsprng.init(seed);                    // ChaCha20 以 seed 为 key
```
同样写法出现在：`PasswordEncoder.zig:19-28`（密码盐）、`SecurityModule.zig:288-296`（`hashPassword` 的盐）、`kit/random.zig:11-29`（`uuid()` / `bytes()` 的进程级 CSPRNG）。

为什么现有防护接不到它：`std.crypto.random`（OS CSPRNG）可用但这里没用；`docs`/AGENTS.md 把这套自称「multi-source entropy, never single-timestamp seed」，字面上成立，但真正的问题不是「单一来源」——**全部来源都是非秘密、低熵、且同一进程内共享的**（除 42 与常量 0xAA 外只有 ASLR slide 与毫秒）。密钥/盐的熵上限≈ASLR 位数（2²⁰ 量级），且同一进程的所有生成共享同一个 slide；一旦观测到该进程的**任意一个** key/uuid，其余的输出立刻可枚举。`kit.random.uuid()` 若被应用当会话/幂等键用，问题同样成立。

攻击者需要满足：能看到该进程产出的一个 key/uuid（日志、响应、已泄露凭据），或能对 ASLR slide 做在线暴力；不需要控制任何配置。`ApiKeyGenerator` 是公开导出（`security.ApiKeyGenerator`），不只是测试用。

---

### ⑦ 中 — `src/persistence/Orm.zig:324-329` — 租户谓词直接接在调用方 WHERE 之后，没有括号包裹

证据：
```zig
fn tenantClause(allocator, comptime col: []const u8, where_sql: []const u8) ![]const u8 {
    if (where_sql.len == 0) return std.fmt.allocPrint(allocator, "WHERE {s} = ?", .{col});
    return std.fmt.allocPrint(allocator, "{s} AND {s} = ?", .{ where_sql, col });   // 328
}
```
`findPageFilteredForTenant`（:1027-1071）的 `args` 顺序（tenant 在末尾）与 SQL 占位符顺序是**一致的**，这点没问题；问题在谓词优先级：`where_sql = "WHERE owner_id = ? OR is_public = 1"` 生成 `... owner_id = ? OR is_public = 1 AND tenant_id = ?` → 等价于 `owner_id = ? OR (is_public = 1 AND tenant_id = ?)` → **租户隔离对 OR 的第一个分支失效**。

为什么现有防护接不到它：`sqlx.validateSqlFragment`（`sqlx.zig:138-158`）的字符/关键字黑名单**不禁止 `OR`/`AND`/`IN`**（只禁 `'`/`"`/`;`/注释/`SELECT`/`UNION` 等），所以这段 `where_sql` 能顺利通过校验；`comptimeGuardTenantScope`（:317-321）只拦「调了不带 ForTenant 的方法」，拦不住「参数里带 OR」。编译期看不到运行期 SQL 逻辑。

攻击者需要满足：**需要应用真的把带 OR 的谓词传给 `*ForTenant`**（这不是攻击者可控输入，是应用写法）——因此算「框架给的坑」而不是可远程利用的漏洞；一旦应用这么写，租户隔离静默失效，且没有任何报错。严重度按「调用方一句话写错就静默跨租户」计为中。

---

### ⑧ 低 — `src/web4/middleware.zig:126-187` — did:key 中间件默认没有 challenge，签名可无限重放

证据：`DidAuthConfig.challenge_store: ?*challenge_mod.ChallengeStore = null`（:117），而校验块整体是 `if (c.challenge_store) |cs| { ... verifyAndConsume ... }`（:145-150）——**默认配置下只验签名，不验新鲜度**：任意一次被抓到的 `(x-did, x-did-message, x-did-signature)` 三元组可以永久复用；消息内容也不与方法/路径绑定。测试只覆盖了「有 challenge_store」的那条路径（:223-266）。

为什么现有防护接不到它：`challenge.zig` 的防重放只在显式接线时生效；框架没有「未配置 challenge → 拒绝」的 fail-closed 默认（对比 x402 的 fail-closed 默认，这里选择了 fail-open 的可用性优先）。

攻击者需要满足：能观测到一次合法 did:key 请求（同一网络/日志/中间人）。若应用按文档显式传了 `challenge_store`，则不成立。

---

### ⑨ 低 — `src/api/Middleware.zig:783-843` — `override_existing = true` 时客户端头覆盖 JWT 的 `aud`（租户）

证据：
```zig
/// When false (default), an existing attr (e.g. JWT `aud`) wins.
override_existing: bool = false,
...
if (!cfg.override_existing and ctx.getAttr(cfg.attr_key) != null) { try next(ctx); return; }
var resolved: ?[]const u8 = null;
for (cfg.headers) |name| { if (ctx.header(name)) |v| { if (v.len > 0) { resolved = v; break; } } }   // :814-821
```
默认是安全的（JWT `aud` 先写入 `tenant_id`，`Middleware.zig:436`），但仓库自己的用例把「header 赢」当成规范行为断言：`src/test/CombinationMatrix.zig:105`（`tenantResolver: ... header wins with override_existing`）。一旦应用开这个开关（多租户切换的常见需求），**任何已认证用户只要改 `X-Tenant-Id` 就能把数据域切到别的租户**，而框架不提供「该用户是否属于该租户」的校验钩子，也不在文档里要求 loader 自己查。

为什么现有防护接不到它：审计规则（AGENTS.md 提到的 b22）只拦 `.query` 取租户；header 来源在 `.attr` 语义下被放行。攻击者需要满足：应用显式开了这个开关（**这是配置依赖，所以按你的规则降为低**）。

---

### 其余低/信息（同格式压缩）

- **低** `src/messaging/OutboxConsumer.zig:202-209` — `topic_filter` 用 `'{s}'` 直接插进 SQL（唯一一处绕过 `?` 参数的动态值）。证据：`"... AND topic = '{s}' ORDER BY ..."`。现有防护：`validateSqlFragment` 在这个文件里没有被调用。前置：应用把 topic 过滤值设成含单引号的字符串（通常是编译期常量，写成 `consumer.setTopicFilter(user_input)` 才会被利用）。
- **低** `src/secrets/SecretsManager.zig:198-199` — Vault 地址允许 `http://` 且不告警：`if (!startsWith(addr,"http://") and !startsWith(addr,"https://")) return error.InvalidVaultAddress;` → 明文信道里 Vault token 外泄、响应可被替换为任意 secret。缓解事实（我核对了实现）：优先级 env=0 < file < vault（:5-13、:287-306），所以 MITM 覆盖不了 env/file 已有的键，只能注入缺失键 → 影响有限，故低。
- **低** `src/api/Middleware.zig:467/593/853` ＋ `src/http/Dashboard.zig:41-46` — 三个 catalog 中间件的默认 `skip_prefixes` 都含 `"dashboard"`，而 `registerRoutes` 就是在 `/dashboard` 挂系统信息页（`pathHasSkipPrefix` 要求段边界，所以 `/api/dashboard/*` 那三个 JSON 端点**不在**豁免内）。前置：应用把 dashboard 挂上并依赖默认 skip 列表 → `/dashboard` 未认证暴露版本/模块数/运行时长。
- **低** `src/api/Server.zig:53-67` — `Method.fromString` 把一切未知方法折叠成 `GET`（`"PROPFIND"`、`"FOO"`、`"1;GET"` → GET）。路由器按 method 分桶（`Router.match:1803-1804`）所以拿不到跨方法的 handler，但：`csrf()` 只 `switch (ctx.method)`（`Middleware.zig:1053-1054`，未知方法即走 GET 分支跳过校验）、访问日志与 `route_template` 指标会记下客户端从未发送的方法。
- **信息** `src/security/JwksKeyRing.zig:10/57` — `is_active` 字段**全仓库没有任何读取点**，也没有 `removeKey`：轮换出去的旧密钥在进程生命周期内一直可验签（只能靠重启回收），「停用某 kid」做不到。

**我确认过、不报的（避免噪音）**：`UploadGuard` 确实按字节嗅探 + 扩展名一致性 + active content 先于白名单拒绝（`src/http/UploadGuard.zig:127-154、168-202、243-249`，`sniff("")`→`unknown`，`check("a.png","")`→`ContentNotAllowed`）；`StaticFiles.relativePath` 的穿越防护是真的（逐段拒绝 `..`/`:`/NUL/`\`，`StaticFiles.zig:207-226`，且 percent-encoded `%2e%2e` 因不解码而落成不存在的文件名 → 404）；x402 默认 fail-closed（`web4/x402.zig:56-80`，`x402Middleware` 默认 `verifyPaymentReject`，`web4/middleware.zig:23/77`）；`verifyToken` 固定 HMAC-SHA256、无 `none` 分支、`exp` 必填且校验、`kid` 未知即拒（`SecurityModule.zig:194-235、187-192`）；`PasswordEncoder.matches` 是常数时间比较（:79-80）；`sockread.writeFull/writevAll` 的短写与 `EAGAIN` 处理正确。

---

## 2. 值得怀疑但**未能确认**

1. **CL/TE 走私的端到端可复现性**（发现②）。为什么无法确认：需要真实网络 + 一个具体代理（nginx/Envoy 的原始解析行为、是否拒绝 TE+CL、是否重写 `Content-Length`）。我做了只读代码阅读（parser 只读 `content-length`、无 TE、`: "` 才认头、请求行第三段不校验），但**没有启动服务、没有发过任何请求**，因此「chunk-size 行被解析成合法请求行」这一步是用 `Method.fromString` + 请求行切分推导的，不是实测。
2. **`Where` 之外的 `TenantInterceptor` / `sqlx.Bulk` 路径是否也有谓词拼接问题**。为什么无法确认：`src/sqlx/sqlx.zig` 有 348 KB，我只做了 keyword 级检索（`ForTenant`/`sql_tenant_column`/`Unscoped` 在它里面**零命中**，租户逻辑集中在 `src/persistence/Orm.zig`），没有逐段读完 Bulk/Upsert 的 SQL 生成。
3. **Postgres/MySQL 方言下的行为**。为什么无法确认：本机没有 PG/MySQL 服务端；`writeBackInsertedId` 的 `SELECT lastval()`（`Orm.zig:1078-1091`）、`IN (...)` 空列表、锁语义都需要真实服务端。仓库的 PG 锁用例本身是 `ZIGMODU_TEST_PG=1` 门控的。
4. **WS 在 io_uring 分发路径下是否同样绕过中间件**。为什么无法确认：`Server.zig:2682-2690` 的 adopt 分支与 fiber 分支在同一个「已握手」块内，我读到的结论是同样绕过，但没有网络环境验证 `WsFramer`/uring 实际行为。
5. **`ctx.path` 是否始终是未 percent-decode 的原始串**。我读到 `path = raw_path[0..query_start]`（`Server.zig:1441-1453`）未解码，这是 StaticFiles 安全的前提；但没有跑用例确认没有别处（如 `path_rewriter`、H2 路径）改写 `ctx.path`。
6. **`ai.Guard` 在 `AgentSpec` 未设 guard 时的实际默认**。只读了 `guard.zig` 的 `Decision/check` 与 `skill.zig:509` 的 action 表，没有追 `Agent.run` 里 guard 缺省的分支。

---

## 3. 结构性观察

1. **「已声明但无人执行」的元数据**：`ws_routes` 的 `auth`/`permission`/`roles` 在 catalog、OpenAPI、审计里都有一席之地，却没有执行点（发现①）。这是本仓库最典型的结构问题——元数据被当成「已接线」的证据。
2. **中间件工厂的两种生命周期写法并存**（`page_allocator.create` vs 函数级 `var`，发现⑤）——没有编译期或审计规则约束，靠作者记得。建议的机械规则：任何 `api.Middleware` 工厂都不得持有非 comptime 的函数级 `var`。
3. **fail-open / fail-closed 在同一族里不一致**：`permissionGateWith` 空 catalog → 放行（:989）；`jwtAuthFromCatalog*` 空 catalog → 全站强制鉴权（:534-545、:502）；`authFromCatalog` 空 catalog → 后端必须验（:653）；x402 默认拒；did:key 默认不防重放（发现⑧）；`datapermission` 空范围 → 放行（发现③）。没有一处把这些默认值集中声明或测试。
4. **仍然依赖「调用方记得」的清单（我核对过这些是设计选择，不是漏洞，但都属静默失败）**：`UploadGuard.check` 不会自动跑（要应用显式调用）；`tenantResolver` 必须注册在 JWT 之后（默认才是安全的）；`sockread.setRecvTimeout` 不调用则 `readFull` 无限等（慢速 WS 对端可长期占用 fiber）；模型的 `sql_tenant_column` 不声明就等于没有租户隔离（编译期只对已声明的模型生效）。
5. **`ctx.auth_info` 是 `?*anyopaque` + `authInfo(T)` 裸 `@ptrCast`**（`Server.zig:335、583-590`）。目前唯一写入者是 `AuthMiddleware.runJwtAuth`（写的都是 `Rbac.AuthInfo`），所以不可利用；但 `.rbac` 模式的权限门会按 `Rbac.AuthInfo` 解释这个指针（`Middleware.zig:1024`），一旦某个应用/中间件往里放自己的身份结构，就是无类型标签的类型混淆（可能误判 `hasPermission` 或崩溃），且框架没有任何断言（如 magic 字段）能拦住。
6. **审计的覆盖盲区本身是结构问题**：`Testkit.auditAuthCoverage` 跳过 `is_ws` 与 `is_sse`（`Testkit.zig:218`），而 SSE 其实走了 `group.get`（`ComptimeRouter.zig:698`）——跳过 SSE 只是少了一层保险，跳过 WS 则是**覆盖了唯一本可以发现问题①的自动化检查**。

---

## 我读了什么 / 我没读什么

**读了（逐行）**：`security/{PasswordEncoder,PathSanitizer,AuthMiddleware,Rbac,AppSecurity,CatalogPermDb,JwksKeyRing,SecurityModule(部分),ApiKeyAuth(部分)}.zig`、`api/{Middleware.zig §4–§8,ComptimeRouter.zig(catalog/findEntry/pathHasPrefix/mount),Server.zig §1/§4/connFiber/WS 升级块/路由匹配)}`、`persistence/Orm.zig`（租户 guard、tenantClause、findPageFiltered*）、`datapermission/DataPermission.zig`（全部 169 行）、`http/{UploadGuard.zig 全 553 行,StaticFiles.zig 全 368 行,Dashboard.zig 部分}`、`sqlx/sqlx.zig`（`validateSqlFragment`/`validateSqlChars`/banned keywords）、`web4/{x402.zig 全 112 行,middleware.zig 全 267 行,challenge.zig 部分}`、`messaging/OutboxConsumer.zig`（select/update 全部 SQL）、`secrets/SecretsManager.zig`（Vault 段）、`core/sockread.zig`（全 256 行）、`ai/{guard.zig 头部,business.zig db.query/entity.* 段,skill.zig action 表}`、`http/Testkit.zig auditAuthCoverage`、`tools/zmodu/src/main.zig` 的 IM 模板段。

**没读 / 没验证**：`Server.zig` 剩余约 4000 行（H2/gRPC/SSE/静态页与各测试）、`sqlx.zig` 的绝大部分（Transaction/Bulk/Upsert/驱动胶水/方言）、`core/cluster/**`（Raft/TLS 传输/成员视图 — 你点名的帧解码边界检查我**没做**）、`im/**`（WsFramer 帧解析、ConnectionRegistry）、`ai/**` 的 memory/run/policy/approval 全链路、`extensions/**`、`runtime/**`（监督树/池化）、`cache/redis/**`、`config/**` 的 Preflight 实现、`zsaas/` 与 `examples/**` 的其余部分、`zent`（不是本仓库依赖）。**我没有运行任何测试或服务**：全部结论都是静态阅读 + `ls/grep/git log`，唯一"命令证据"是仓库内我引用到的既有测试内容。故未覆盖面 = 上面这份"没读"清单，其中集群帧解码与 WsFramer 是风险最高的一段未审计代码。