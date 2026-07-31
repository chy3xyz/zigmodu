# Router（Zig-native）— comptime × 泛型 × std.Io × Modulith

> 状态：**推荐栈已钉死；scaffold 默认 RBAC；zent-modulith / tenant-shop 已迁；tenant-mgmt 用 CatalogPermDb**。  
> 推荐：`jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.rbac)` + `RolePermissionTable` / `CatalogPermDb` / 自定义 `CatalogPermissionLoader`。  
> 多门户 / 多主体 RBAC 最佳实践摘要：[`BEST_PRACTICES.md`](BEST_PRACTICES.md)「JWT / 多端身份」；细则 §7.1。  
> **AI**：[`AGENTS.md`](../AGENTS.md) DO/DON'T + 本文 §7；勿把 AuthInfo 写入 `user_data`。  
> Legacy：`security.auth.jwtAuth*` / `AppSecurity.rbacJwtMiddleware*` 现只写 **`auth_info`**，可与 ComptimeRouter `user_data` State 共存；读 auth 用 `getAuth` / `ctx.authInfo`，**勿再 `@ptrCast(user_data)` 当 AuthInfo**。  
> 前提：未生产化，**不做**旧 URL 兼容。

---

## 0. 推荐栈 vs Legacy（必读）

| | **ComptimeRouter（推荐）** | **Legacy AuthMiddleware** |
|--|---------------------------|---------------------------|
| JWT | `http.jwtAuthFromCatalogWithPermissions` | `security.auth.jwtAuth*` / `AppSecurity.rbacJwtMiddleware*` |
| 权限 | attr `permissions` + `.mode = .rbac` | `AuthInfo` in **`auth_info`** + `requirePermission` / `getAuth` |
| 状态共存 | ✅ 不碰 `user_data` | ✅ 亦不碰 `user_data`（State 保留） |
| 权限来源 | `RolePermissionTable` 或 `CatalogPermDb.loaderFromClient` | `PermissionLoader`（数字 `role_ids`） |
| 文档入口 | 本节 + §7 | `security/AuthMiddleware.zig` 头注释 |

**新应用 / scaffold `--with-auth`：仍用左列**（catalog 权限码 + `permissionGate`）。右列适合已有 `requirePermission` 链、又挂了 ComptimeRouter 的迁移期。

DB 权限表示例：

```zig
try zigmodu.security.CatalogPermDb.ensureSchema(&db_client);
try zigmodu.security.CatalogPermDb.grant(&db_client, "admin", "tenant:suspend");
try server.addMiddleware(http.jwtAuthFromCatalogWithPermissions(
    &sec, &slot, zigmodu.security.CatalogPermDb.loaderFromClient(&db_client), .{},
));
try server.addMiddleware(http.permissionGateWith(&slot, .{ .mode = .rbac }));
```

---

## 1. 一句话

**模块用 comptime `routes` 表声明路由；`mountAll(comptime modules, …)` 在编译期展开注册；`Router(State)` 泛型持有应用状态与 `std.Io`。**  
运行期零反射；请求路径完全确定。

---

## 2. 与「Axum 显式 mount」版的差别

| | 前一版（Axum 味） | 本版（Zig 味） |
|--|------------------|----------------|
| 注册 | 手写 `g.get("page", h, …)` | comptime `routes` 数组 + `inline for` 展开 |
| 状态 | `?*anyopaque` user_data | **`Router(State)`**，handler 拿 `*State`（或模块子状态指针） |
| 发现 | 小元组调 `mount` | **`mountAll(comptime .{ ModuleA, ModuleB })`** 仍是显式元组，但是泛型+comptime |
| Io | 只用 `Context.io` | **Router / Context 统一 `std.Io`**；需要 sleep/clock 的层走 Io |
| 自动化 | scaffold 生成 mount 正文 | scaffold 生成 **`pub const routes`**；编译期校验冲突 |

拍板保留：

1. Gate 首版 = **module**  
2. **WS 共用 meta**  
3. 注册 = **comptime 模块元组**（禁止文件系统扫描）

---

## 3. URL 约定（一种）

`/{scope}/{domain}/{resource}/{action}`，kebab。例：`GET /admin-api/crm/customer/page`。

---

## 4. 核心类型（泛型 + comptime）

### 4.1 Meta / Auth

```zig
pub const Auth = enum { inherit, public, jwt };

pub const RouteMeta = struct {
    auth: Auth = .inherit,
    /// 预留；首版 Gate 不读
    permission: ?[]const u8 = null,
    /// 默认取 nest/module 的 module 名
    module: ?[]const u8 = null,
};
```

### 4.2 编译期路由说明（无函数指针生命周期问题：用 comptime 已知函数）

```zig
pub fn RouteSpec(comptime State: type) type {
    return struct {
        method: http.Method,
        /// 相对当前 nest，如 "page"
        path: []const u8,
        /// `fn (*http.Context, *State) anyerror!void`
        handler: *const fn (*http.Context, *State) anyerror!void,
        meta: RouteMeta = .{},
    };
}
```

> Zig 要点：handler 类型挂在 `State` 上，**消掉 `anyopaque`**；错误的 State 在编译期挂掉。

### 4.3 模块契约（modulith）

```zig
pub const CrmCustomer = struct {
    pub const module_name = "crm";
    pub const nest = .{ "crm", "customer" }; // 相对 scope group

    /// 每个实例状态（persistence/service 指针等）
    pub const State = struct {
        api: *CrmCustomerApi,
    };

    pub const routes = [_]RouteSpec(State){
        .{ .method = .GET, .path = "page", .handler = handlers.page },
        .{ .method = .GET, .path = "get", .handler = handlers.get },
        .{ .method = .POST, .path = "create", .handler = handlers.create },
        .{ .method = .POST, .path = "assign", .handler = handlers.assign },
    };

    // WS 同表或并列：
    pub const ws_routes = [_]WsSpec(State){
        .{ .path = "ws/im", .on_connect = ..., .on_message = ..., .on_close = ..., .meta = .{ .module = "crm" } },
    };
};
```

### 4.4 `Router(State)` + `std.Io`

```zig
pub fn Router(comptime AppState: type) type {
    return struct {
        io: std.Io,
        allocator: Allocator,
        server: *http.Server,
        state: *AppState,

        const Self = @This();

        pub fn group(self: *Self, prefix: []const u8) Group(AppState) { ... }

        /// 编译期展开 modules 元组；重复 method+path → compileError
        pub fn mountAll(self: *Self, comptime modules: anytype) !void {
            inline for (modules) |Mod| {
                try self.mountModule(Mod);
            }
        }

        fn mountModule(self: *Self, comptime Mod: type) !void {
            comptime {
                if (!@hasDecl(Mod, "routes")) @compileError(@typeName(Mod) ++ " missing routes");
                if (!@hasDecl(Mod, "module_name")) @compileError(...);
            }
            var g = self.group(scopePrefix).nestComptime(Mod.nest, Mod.module_name);
            inline for (Mod.routes) |spec| {
                try g.route(spec.method, spec.path, wrap(Mod.State, spec.handler), spec.meta);
            }
            if (@hasDecl(Mod, "ws_routes")) {
                inline for (Mod.ws_routes) |spec| {
                    try g.ws(spec.path, spec.on_connect, spec.on_message, spec.on_close, spec.meta);
                }
            }
        }

        pub fn finish(self: *Self) !RouteCatalog {
            // 运行期：建 public set、path→module；也可把冲突再 assert 一次
            return buildCatalog(self.server);
        }
    };
}
```

`wrap`：把 `fn(*Context,*Mod.State)` 收成现有 `HandlerFn`，从 `AppState` 取出子 State（comptime 偏移或指针字段约定）。

### 4.5 编译期冲突检测

```zig
fn assertNoDupes(comptime modules: anytype) void {
    comptime {
        var paths: []const []const u8 = &.{};
        // inline for 拼接 method+absolute path，重复则 @compileError
    }
}
```

调用：`comptime assertNoDupes(.{ CrmCustomer, InsuranceAgents, ... });`

---

## 5. `std.Io` 用在哪

| 点 | 用法 |
|----|------|
| `Router.io` | 与 `Server` / `Context.io` 同一来源（Zig 0.17 异步世界） |
| `Time.wallClockSeconds(io)` | catalog / access log 时间戳 |
| `std.Io.sleep` | 仅中间件或健康探测需要时；**路由注册本身不 sleep** |
| 文件导出 catalog | `std.Io.Dir` + `writeStreamingAll`（build/zmodu 工具侧） |

路由表是 comptime 数据；Io 属于 **运行期 Server/Router 生命周期**，二者正交、在 `Router(AppState){ .io = init.io, ... }` 汇合。

---

## 6. 应用侧（小元组 = 唯一「自动化」入口）

```zig
comptime http.assertNoDupes(.{ modules.crm.customer, modules.crm.contact });

var router = http.Router(AppState).init(init.io, allocator, &server, &app_state);
var admin = router.scope("/admin-api");
try admin.mountAll(.{
    .{ .Mod = modules.crm.customer, .state = &app_state.crm_customer },
    .{ .Mod = modules.crm.contact, .state = &app_state.crm_contact },
});
const catalog = try router.finish();
defer catalog.deinit();
```

- **有自动化**：`inline for` + comptime 校验 + 统一 wrap  
- **无魔法**：模块列表仍是人手维护的元组（可跳转、可 code review）
- **State**：每个模块自带 `Mod.State`；`mount`/`mountAll` 传入对应指针（`wrap` 经 `ctx.user_data` 送达 handler）

Scope（admin/app/external）：推荐 **多个 `scope` + 各自 mountAll**（A）；模块级 `pub const scope` 分发（B）可后补。

---

## 7. 中间件 / Gate

- `auth == .public` → `jwtAuthFromCatalog` 跳过 JWT（`{id}` 段匹配；默认跳过 `health` / `dashboard` / `openapi.json`）
- ModuleGate → `moduleGate`：写入 `ctx` attr `module`；可选白名单 / deny-unknown
- PermissionGate → `permissionGateWith(slot, .{ .mode = .rbac })`：`RouteMeta.permission` 为**权限码**（如 `tenant:suspend`）；`|` = OR  
  - `.mode = .roles`（默认）仍按 JWT role 名匹配（兼容旧行为）  
  - `.rbac` 读 `permissions` attr（及可选 `ctx.auth_info`）
- JWT 加载权限 → `jwtAuthFromCatalogWithPermissions` + `RolePermissionTable` / `CatalogPermDb.loaderFromClient` / 自定义 `CatalogPermissionLoader`  
  **不写** `ctx.user_data`（与 ComptimeRouter 共存）；权限写入 attr `permissions`
- OpenAPI → `openApiFromCatalog(*CatalogSlot, …)` 每次请求从 catalog 生成
- 插件（IM / AI / Web4）：`routes` + `ws_routes` + `mountAll`
- scaffold `--with-auth`：默认生成 **RBAC 表骨架** + `.mode = .rbac`（非 role gate）

接线（细粒度 RBAC）：

```zig
const table = security.Rbac.RolePermissionTable{ .rows = &.{
    .{ .role = "admin", .permissions = &.{ "tenant:suspend", "tenant:write" } },
    .{ .role = "user", .permissions = &.{ "tenant:read" } },
} };
try server.addMiddleware(http.jwtAuthFromCatalogWithPermissions(
    &sec, &catalog_slot, http.catalogLoaderFromTable(&table), .{},
));
try server.addMiddleware(http.moduleGate(&catalog_slot, .{ .unknown = .allow }));
try server.addMiddleware(http.permissionGateWith(&catalog_slot, .{ .mode = .rbac }));
// … mountAll …
catalog_slot.set(try router.finish());
try server.addRoute(.{
    .method = .GET,
    .path = "openapi.json",
    .handler = http.openApiFromCatalog(&catalog_slot, .{ .title = "app", .version = "1.0" }),
});
```

路由声明：

```zig
.{ .method = .DELETE, .path = "{id}", .handler = suspend, .meta = .{ .permission = "tenant:suspend" } },
```

WS：`pub const ws_routes = [_]http.WsSpec(State){ .{ .path = "ws", .on_connect = … } };`

### SSE（Server-Sent Events）

- 客户端：`Accept: text/event-stream`（约定；路由不强制校验）
- Handler：`var sse = try http.sse(ctx);` — 设置 `responded`+`streaming`，避免 Server 二次 `writeResponse`
- 重连：`http.lastEventId(ctx)` 读 `last-event-id`；`sse.setId(...)` 写出 `id:`
- 模块表：`pub const sse_routes = [_]http.SseSpec(State){ .{ .path = "stream", .handler = stream } };`
- 或在普通 `routes` 行设 `meta = .{ .sse = true }`
- Catalog：`is_sse=true` → OpenAPI description 标注 SSE
- 多行 payload：`sendEvent` 按 `\n` 拆成多行 `data:`
- 详见 `docs/FRAMEWORK_BACKLOG.md`

### 7.1 多端 / 自定义身份 claim（应用层扩展 · 最佳实践）

框架 **不** 内置 `type=user|admin|shop_user|…` 枚举。多门户（C 端 / 店主 / 平台 / 供应商）用 **现有槽位** 扩展，避免第二套 JWT 核心模型。  
可执行清单与接线样例亦见 [`BEST_PRACTICES.md`](BEST_PRACTICES.md)「JWT / 多端身份」。

#### 分层（与现有组件对齐）

```
签发/验签（唯一源 · 路径 A）
  └─ AppSecurity / SecurityModule（sub / iss / aud / roles）
     登录只发门户 roles + aud + sub；勿塞全量菜单树

请求上下文（正交）
  ├─ ctx.user_data     → ComptimeRouter *State（模块状态）
  ├─ ctx.auth_info     → 可选 AuthInfo（legacy rbacJwt；读 getAuth）
  └─ ctx.attributes    → user_id、tenant_id、roles、permissions CSV

门禁（由粗到细）
  ├─ RouteMeta.auth = .public | .jwt | .inherit
  ├─ permissionGateWith(.rbac) ← permissions 码（推荐；含 portal:*）
  ├─ permissionGate / .roles   ← JWT roles 名（粗）
  └─ 应用薄 helper              ← 只读 attrs（勿再验签）
```

#### 多业务主体 × 各自 RBAC（ZigShop 类 · 推荐模型）

典型库表是 **多套同构、互不合并** 的 RBAC（shop / supplier / saas-admin），不是一张全局 `role_permission`。

```
┌─────────────────────────────────────────────────────────────┐
│  ZigModu（通用）                                              │
│  JWT: sub + aud(租户) + roles(门户粗身份)                      │
│  Middleware: verify → CatalogPermissionLoader → permissions │
│  Gate: RouteMeta.permission + permissionGateWith(.rbac)     │
└───────────────────────────┬─────────────────────────────────┘
                            │ loader 按门户选数据源
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
   shop_* RBAC         supplier_* RBAC      admin role/access
   (app_id)            (app_id+supplier_id) (saas)
```

| 层 | 谁拥有 | 框架是否内置 |
|----|--------|--------------|
| 门户身份 | JWT `roles` 如 `shop`/`supplier`/`admin`/`user` | ✅ 标准 claim |
| 租户 | JWT `aud` | ✅ |
| 主体内职务/菜单权限 | **应用自己的** `*_role` / `*_access` 表 | ❌ 不合并进框架表 |
| HTTP 门禁 | `permissions` attr + catalog gate | ✅ |
| 展开职务→权限码 | **应用** `CatalogPermissionLoader` | ✅ **扩展点** |

**最佳实践：**

1. **不要**把三套业务表迁进 `CatalogPermDb.role_permission`（那只适合简单单租户演示）。  
2. **不要**在 JWT 塞全量 access 树（token 膨胀、撤权滞后）。  
3. 登录只发 **门户 role + aud + sub**；每次请求由 loader **按 (portal, aud, sub)** 查对应表族，展开 path/码 → `permissions` CSV。  
4. `RouteMeta.permission` 与各端 `access.path`（或规范化码 / `portal:*`）对齐；BFF scope 与门户 role 一致。  
5. Super 账号（`is_super`）：loader 内短路为该门户全量权限或约定码。  
6. Handler **禁止**新增重复 Bearer 验签；gate 通过后只读 `user_id` / `tenant_id` / `permissions`。

**框架 loader 入参：**  
`CatalogPermissionLoader = fn(allocator, CatalogPermLoadInput) ![]u8`，`CatalogPermLoadInput = { sub, aud, roles }`（导出：`http.CatalogPermLoadInput`）。  
- 静态表 / `CatalogPermDb.loaderFromClient` **忽略** `sub`/`aud`，只映射 roles。  
- 多主体应用用 `(sub, aud, roles)` 查业务表族 → `permissions` CSV。  
- JWT 验签后写入 `user_id`（sub）与 `tenant_id`（aud）。

#### 三条路径（选一条作主路径，勿双签发）

| 路径 | 适用 | 做法 |
|------|------|------|
| **A. Catalog 默认** | **所有新应用**、tenant-mgmt、ZigShop 目标态 | `AppSecurity` + `jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.rbac)`；多端用 **permission 码** / roles；多主体 RBAC 用自定义 loader |
| **B. 应用 identity** | 遗留过渡（勿新开） | 应用内签发验签；尽快迁 A |
| **C. 适配桥** | 仅渐迁 B→A | 旧 claim 映射为 `roles`/`aud` 后再走 gate |

#### 推荐约定（claim → 框架槽）

| 业务概念 | 推荐落点 | 勿做 |
|----------|----------|------|
| 租户 / 店铺 | JWT `aud`（及 SQL 租户列） | 框架强制改名业务列 |
| 门户 | JWT `roles`（粗） | 核心 JwtPayload 加必填 `type` |
| 主体内 RBAC | 业务表 → loader → `permissions` | 三套表合成一张全局角色表 |
| 细权限门禁 | `RouteMeta.permission` | 仅靠门户 role 守所有写接口 |
| 模块 State | `user_data` | 鉴权对象写入 `user_data` |

#### 演进阶梯（多 BFF 应用）

1. P0：`AppSecurity` + catalog JWT/gate；loader（静态或 DB）；登录发框架 token。  
2. P1：试点一个 BFF：`portal:*` + 路由 meta；handler 改读 attrs。  
3. P2：批改其余门户 / BFF。  
4. P3：删除应用侧 PHP 形签发/验签；只保留 password/OAuth 等业务逻辑。  

参考落地：ZigShop `docs/AUTH_FRAMEWORK_ALIGNMENT.md`（路径 A · P0–P3）。

#### 刻意不做（框架边界）

- 不在核心 JWT 增加必填 `type` enum / 多端枚举 API  
- 不内置 `zigshop_shop_role` 一类业务表  
- `CatalogPermDb` 保持可选简易后端，**不是**多主体 RBAC 的唯一实现  

示例：`examples/tenant-mgmt`（单套 `CatalogPermDb`）；多主体见应用自定义 loader（ZigShop）。

### Typed extractors + scope middleware

```zig
const id = (try http.extractPath(ctx, .{ .id = u64 })).id;
const page = (try http.extractQuery(ctx, .{ .page = u32, .size = u32 })).page;
const body = try http.extractJson(ctx, CreateDto) catch return;
try http.respondErr(ctx, err);

var g = try server.group("admin-api").use(myMiddleware);
```

Extractors → `src/api/Extract.zig` · Testkit → `http.Testkit.dispatch`

---

## 8. Scaffold / zmodu

生成：

```zig
pub const routes = [_]http.RouteSpec(State){ ... };
pub fn page(ctx: *http.Context, state: *State) !void { ... }
```

而不是生成一长串 `group.get`。

---

## 9. 实现切片

| 步 | 内容 | Zig 特性 | 状态 |
|----|------|----------|------|
| 1 | `RouteSpec(State)`、`wrap`、现有 Server 可挂 typed handler | 泛型 | ✅ `ComptimeRouter.zig` |
| 2 | `Router(AppState)` + `scope`/`mount`/`mountAll` + `inline for routes` | comptime / inline for | ✅ |
| 3 | `assertNoDupes` | comptime `@compileError` | ✅ |
| 4 | `finish` → public + path→module；中间件改读索引 | 运行期 | ✅ `jwtAuthFromCatalog` + `moduleGate` + `permissionGate` |
| 5 | WS `WsSpec(State)` 并入 mount | 泛型一致 | ✅ |
| 6 | 试点一模块 + `app_modules` 元组；删 `register_routes` 片段 | modulith | ✅ `examples/tenant-mgmt` 三模块 |
| 7 | scaffold 出 `routes` 表 | 工具链 | ✅ `tools/zmodu` api_header + `mountAll` |
| 8 | catalog → OpenAPI | 运行期 | ✅ `exportOpenApi` + `openApiFromCatalog`（live） |
| 9 | 插件 IM/AI/Web4 → ComptimeRouter | 工具链 | ✅ scaffold `routes` + pre-finish `mountAll` |
| 10 | permission OR (`\|`) | 中间件 | ✅ `permissionMatchesRoles` |
| 11 | WS → catalog | comptime | ✅ `ws_routes` + IM scaffold |
| 12 | 细粒度 RBAC（非 role） | 中间件 | ✅ `.mode=.rbac` + `RolePermissionTable` |
| 13 | 推荐栈文档 + scaffold 默认 RBAC | 工具/文档 | ✅ |
| 14 | example 迁 ComptimeRouter | 生态 | ✅ `zent-modulith` + `tenant-shop`（`default_auth=.public` smoke） |
| 15 | SQLite permission loader | 样例 | ✅ `security.CatalogPermDb`（tenant-mgmt 已接） |

---

## 10. 刻意不用的「假 Zig」

- 运行时 `@import` 扫 `src/modules/**`  
- 用 `anyopaque` 冒充泛型却无 `Router(State)`  
- 在路由匹配热路径上 `std.Io.sleep`  
- comptime 生成几千条字符串再在运行期解析（表应直接是函数指针）  

---

## 11. 决策汇总

| 项 | 选择 |
|----|------|
| 风格 | **Zig comptime 路由表 + 泛型 Router(State)** |
| 自动化边界 | comptime 元组展开；非反射 |
| Io | Router/Server/Context 共享 `std.Io` |
| Gate | module 级 + permission 码（`.rbac`）/ role（`.roles`） |
| WS | 同 meta / 同 mount 管道 |
| 旧 URL | 不做 |
| 真相源 | 模块 `pub const routes` |
