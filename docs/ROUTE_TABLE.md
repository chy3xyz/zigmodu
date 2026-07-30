# Router（Zig-native）— comptime × 泛型 × std.Io × Modulith

> 状态：**推荐栈已钉死；scaffold 默认 RBAC；zent-modulith / tenant-shop 已迁；tenant-mgmt 用 CatalogPermDb**。  
> 推荐：`jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.rbac)` + `RolePermissionTable` / `CatalogPermDb`。  
> Legacy：`security.auth.jwtAuth*` / `AppSecurity.rbacJwtMiddleware*`（写 `user_data`，勿与 ComptimeRouter 混用）。  
> 前提：未生产化，**不做**旧 URL 兼容。

---

## 0. 推荐栈 vs Legacy（必读）

| | **ComptimeRouter（推荐）** | **Legacy AuthMiddleware** |
|--|---------------------------|---------------------------|
| JWT | `http.jwtAuthFromCatalogWithPermissions` | `security.auth.jwtAuth*` / `AppSecurity.rbacJwtMiddleware*` |
| 权限 | attr `permissions` + `.mode = .rbac` | `AuthInfo` in **`user_data`** + `requirePermission` |
| 状态共存 | ✅ 不碰 `user_data`（路由 State 可用） | ❌ 覆盖 `user_data`，与 typed handler 冲突 |
| 权限来源 | `RolePermissionTable` 或 `CatalogPermDb.loaderFromClient` | `PermissionLoader`（数字 `role_ids`） |
| 文档入口 | 本节 + §7 | `security/AuthMiddleware.zig` 头注释 |

**新应用 / scaffold `--with-auth`：只用左列。**

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

- 客户端：`Accept: text/event-stream`
- Handler：`var sse = try http.sse(ctx);` 然后 `sendEvent` / `done`
- 模块表：`pub const sse_routes = [_]http.SseSpec(State){ .{ .path = "stream", .handler = stream } };`
- 或在普通 `routes` 行设 `meta = .{ .sse = true }`
- Catalog：`is_sse=true` → OpenAPI description 标注 SSE
- 额外 query/path 文档：`RouteMeta.openapi_params = &http.openApiParamsFromStruct(QueryDto, .query)`（与路径 `{id}` 合并导出）
- 详见 `docs/FRAMEWORK_BACKLOG.md`

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
