# ZigModu × zent 最佳实践

**zent**: [chy3xyz/zent](https://github.com/chy3xyz/zent) — Zig 版 [ent](https://entgo.io/)（schema-as-code ORM）  
**版本口径**: zent **v0.13.0+** · ZigModu **v0.14.9+** · Zig **≥ 0.17**  

**参考实现**: [`examples/zent-modulith/`](../examples/zent-modulith/)  
**zent 自带示例**: `zig build run-start` / `run-complex` / `run-pool`（在 zent 仓库内）

相关文档：[MODULE_LAYERS.md](MODULE_LAYERS.md) · [MODULITH.md](MODULITH.md) · [BEST_PRACTICES.md](BEST_PRACTICES.md) · [SQLX_DRIVERS.md](SQLX_DRIVERS.md)（zigmodu 侧 `-Ddb=`）· [DATA / sqlx](../src/data.zig)

---

## 目录

1. [定位：正交，不要混栈](#1-定位正交不要混栈)
2. [何时用 zent、何时用 sqlx](#2-何时用-zent何时用-sqlx)
3. [模块级独立选型](#3-模块级独立选型)
4. [能力价值与业务场景](#4-能力价值与业务场景)
5. [分层映射（对齐 MODULE_LAYERS）](#5-分层映射对齐-module_layers)
6. [启动流水线](#6-启动流水线)
   - [6.1 Testing](#61-testing)
   - [6.2 Production: ConnPool](#62-production-connpool)
   - [6.3 Observability](#63-observability)
   - [6.4 Transactions](#64-transactions)
7. [Schema / Edge 写法](#7-schema--edge-写法)
8. [Persistence 契约](#8-persistence-契约)
9. [Privacy 与 Hooks](#9-privacy-与-hooks)
10. [内存与错误](#10-内存与错误)
11. [依赖接入](#11-依赖接入)
12. [反模式](#12-反模式)
13. [检查清单](#13-检查清单)
14. [升级注意（0.6 → 0.12）](#14-升级注意zent-06--012)

---

## 1. 定位：正交，不要混栈

> **Shared helper**：示例级生命周期和测试工具位于
> [`examples/_shared/zent_helpers.zig`](../examples/_shared/zent_helpers.zig)。它只封装
> `open → migrate → makeClient → deinit`，不属于 ZigModu core，也不改变 zent 与 `data.sqlx` 的正交边界。

| 层 | 用 ZigModu | 用 zent |
|----|------------|---------|
| HTTP / 中间件 / 模块生命周期 | ✅ `http.Server` / `Application` | ❌ |
| Schema-as-code / 图关系 / 生成 Client | ❌（或手写 sqlx struct） | ✅ `Schema` + `makeClient` |
| 参数化 SQL CRUD | ✅ `data.sqlx` / `Repository` | ✅ Fluent Query/Create |
| Redis / metrics / JWT / Outbox | ✅ | ❌ |

**禁止**把 `zent.sql_driver.Driver` 塞进 `zigmodu.data.Client`。两套连接池、方言、迁移表各自管理。

```
Application / http.Server
        │
        ├─ modules/*/api → service
        │                    │
        │         ┌──────────┴──────────┐
        │         ▼                     ▼
        │   zigmodu.data.sqlx      zent Client
        │   (tenant-shop 等)       (zent-modulith 等)
        └─ redis / observability / EventBus …
```

ZigModu **核心库不强制依赖 zent**；应用或示例按需 path/url 引入。

---

## 2. 何时用 zent、何时用 sqlx

| 需求 | 建议 |
|------|------|
| 快速 CRUD、已有 SQL、报表/复杂手写查询 | **sqlx**（`zigmodu.data`） |
| 关系图密、codegen Client、migrate、privacy、hooks | **zent** |
| 下单→支付→Outbox→消息编排 | **sqlx + ZigModu EventBus**（与 ORM 选型正交） |
| 同进程两套都用 | **按模块选型**（见 §3） |

**一句话**：编排与消息归 ZigModu；领域图与行级策略归 zent；简单表与存量 SQL 归 sqlx。

---

## 3. 模块级独立选型

**可以**让不同模块各自决定用 sqlx 或 zent——这是推荐做法，不是临时妥协。

```
Application / http
        │
   ┌────┴────┐
   │         │
 catalog   order
 (zent)    (sqlx)
```

| 可以 | 不行 |
|------|------|
| 模块 A 用 zent Client，模块 B 用 `data.sqlx` | 同一 `Transaction` 里混两套驱动 |
| 各自 migrate / 连接池 | 把 zent Driver 塞进 sqlx Client |
| service 只交换 DTO / 接口 | 跨栈指望同一条 DB 事务自动一致 |

跨模块协作：

- **同库同事务强一致** → 两模块必须同栈，或把写收口到一个 persistence
- **跨域副作用** → EventBus / Outbox（与 ORM 无关）
- **共享的只有** `allocator` / `io` / HTTP Context

实践：把驱动关在 `persistence.zig`，`api` / `service` 不泄漏 `zent.*` 或 `sqlx.*` 类型，以后换实现只动一层。

---

## 4. 能力价值与业务场景

这四项的价值不在「多写几行 CRUD」，而在把**领域关系、访问控制、横切副作用**从 service 散落的 if/SQL 收到 schema / ORM 边界。

### 4.1 边（Edges）

**价值**：O2M / M2O / M2M 一等公民，查询走图导航，少手写 JOIN + 中间表。

| 适合 | 不适合 |
|------|--------|
| 订单→明细→商品→标签 | 单表 CRUD、报表直查 SQL |
| 组织树、关注图、RBAC 角色图 | 临时分析、数仓 |
| 多跳「用户的店的商品」 | 几乎无跨表关联 |

**典型业务**：电商目录、社交图谱、权限图、租户–成员–资源。

### 4.2 Codegen Client

**价值**：`client.product.Query()` / `Create()` / predicate 编译期类型安全；migrate 与图一致。

| 适合 | 不适合 |
|------|--------|
| 实体多、关系多、多人改 schema | 已有大量手写 SQL、DBA 主导迁移 |
| 「改 schema → 客户端/迁移跟着变」 | 一表两接口、原型最快出活 |

### 4.3 Privacy（策略）

**价值**：读/写默认带策略（Allow / Deny / Filter），少依赖每个 handler 记得加 `WHERE tenant_id=?`。

| 适合 | 不适合 |
|------|--------|
| 多租户 SaaS、按角色看不同行 | 全员同权的内部工具 |
| 「只能改自己的订单 / 只能看本店商品」 | 复杂审批流（仍要工作流） |
| 防漏过滤导致越权 | 纯公开只读 API |

配置了 policy 必须 `withContext`，否则易得 `PrivacyDenied`。

### 4.4 Hooks（before / after）

**价值**：create/update/delete/query 进出库前统一校验、审计、软删、默认值；`before` 可取消写。

| 适合 | 不适合 |
|------|--------|
| 软删、审计日志、`updated_at` | 跨服务编排（下单→支付→发 MQ） |
| 写前状态机一步校验 | 长事务 Saga（用 Outbox） |
| 轻量领域不变量 | 重业务规则堆满 hook（难测） |

### 4.5 场景速查

```
简单 CRUD / 已有 SQL / 报表              → sqlx
领域图密 + 多租户行级隔离 + 写路径横切   → zent
下单支付 Outbox / BFF / 限流熔断         → ZigModu（与 ORM 无关）
```

`tenant-shop` 核心痛点是编排与消息 → **sqlx 更合适**；同一应用里「商品–类目–标签 + 店员只能改本店 + 软删审计」→ **该模块用 zent**。

---

## 5. 分层映射（对齐 MODULE_LAYERS）

| ZigModu 文件 | zent 写法 | 职责 |
|--------------|-----------|------|
| `model.zig` | `Schema` + `field.*` + `edge.*` +（可选）`policy` / hooks | 形状与关系；无 HTTP、无 SQL 字符串 |
| `persistence.zig` | 持有 `Client(infos)`；`Create`/`Query`/`beginTx` | **无业务 if**；对外 DTO |
| `service.zig` | 校验、Cmd、编排；可 `beginTx` | 不碰 `Context`、不拼 SQL |
| `api.zig` | 只调 service；`ctx.json` | 不 import `zent.sql_*` |
| `module.zig` | ZigModu `info` / `init` / `deinit` | 与数据栈无关 |

同事务跨实体：用 `zent.codegen.client.beginTx`，不要开两个独立 Driver 事务。

Persistence **dupe 成普通 DTO** 再交给上层（见 `zent-modulith`），避免把 `Managed` / `deinitEntity` 漏到 HTTP。

---

## 6. 启动流水线

最小路径：

```zig
const graph = comptime zent.codegen.graph.buildGraph(&.{ Tenant, Product });
var drv = try zent.sql_sqlite.SQLiteDriver.open(alloc, path);
defer drv.close();
try zent.sql_schema.migrateSchema(alloc, drv.asDriver(), graph.types);
var client = zent.codegen.client.makeClient(graph.types, alloc, drv.asDriver());
```

生产建议：

1. **`ConnPool`**：`zent.sql_pool.ConnPool(SQLiteDriver)` → `asDriver()` 交给 `makeClient`（`Options.io` 对齐 ZigModu fiber）。参考 zent `examples/pool`。
2. **Migrate**：默认保守；`drop_columns` / `allow_data_loss` 必须显式 `MigrateOptions`。
3. **单连接 `:memory:`**：勿多连接拆库（与 sqlx 相同）。
4. **启动顺序**：`open/pool → migrateSchema → makeClient → 注入 persistence → start modules → listen`。

### 6.1 Testing

示例级测试可以使用共享的 `TestEnv` 工厂。它为每个测试创建单连接内存 SQLite，避免测试之间共享状态；需要在同一测试中复用环境时，调用 `reset()` 删除所有 schema 表并重新迁移：

```zig
const Env = zent_helpers.TestEnv(infos);
var env = try Env.init(std.testing.allocator);
defer env.deinit();

// Arrange / Act / Assert …
try env.reset(); // 下一组断言从全新 schema 开始
```

`TestEnv` 是 `examples/_shared/zent_helpers.zig` 中的示例工具，不会把 zent 引入 ZigModu core。

### 6.2 Production: ConnPool

生产环境将连接池作为 zent driver 交给生成 Client；不要把池里的单个连接泄漏给模块。池会按 `min_connections` 预热，并通过 `asDriver()` 保持 Client 接口不变：

```zig
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const Pool = zent.sql_pool.ConnPool(SQLiteDriver);
var pool = try Pool.init(allocator, .{
    .io = io,
    .min_connections = 2,
    .max_connections = 8,
    .connect = struct {
        fn open(a: std.mem.Allocator) !SQLiteDriver {
            return SQLiteDriver.open(a, "app.db");
        }
    }.open,
});
defer pool.deinit();
try zent.sql_schema.migrateSchema(allocator, pool.asDriver(), infos);
var client = zent.codegen.client.makeClient(infos, allocator, pool.asDriver());
```

使用 pool 时，`:memory:` 只适合单连接测试；生产使用文件或服务器数据库。关闭池前必须确保没有并发 borrow / query 正在进行。

### 6.3 Observability

zent 的 `sql_logger.Logger` 回调没有额外 context 参数，因此最简单且无状态的适配器是转发到 ZigModu 的 `std.log` 后端（生产应用也可以在回调中转发到自己的 `StructuredLogger` 实例）：

```zig
fn onQuery(c: zent.sql_logger.LogContext) void {
    std.log.debug("zent query [{s}] {s} ({d}us, {d} rows)", .{ c.table_name, c.sql, c.duration_us, c.rows_affected });
}
fn onExec(c: zent.sql_logger.LogContext) void {
    std.log.debug("zent exec [{s}] {s} ({d}us, {d} rows)", .{ c.table_name, c.sql, c.duration_us, c.rows_affected });
}
fn onError(c: zent.sql_logger.LogContext) void {
    std.log.err("zent SQL error [{s}] {s}: {any}", .{ c.table_name, c.sql, c.@"error" });
}
const logger = zent.sql_logger.Logger{ .onQuery = onQuery, .onExec = onExec, .onError = onError };
zent.codegen.client.SetLogger(infos, &client, logger);
```

日志回调只应记录 SQL 元数据；不要输出密码、token 或敏感字段值。需要 trace 关联时，在 `LogContext.trace_id` 中传递应用层 trace id。

### 6.4 Transactions

跨实体写入使用同一个 `TxClient`。需要在一个大事务中局部回滚时，可通过底层 `Tx` 执行 SQL savepoint；最终仍然只 commit/rollback 一次并 `deinit` 一次：

```zig
var tx = try zent.codegen.client.beginTx(infos, client);
defer tx.deinit();

_ = try tx.tx.exec("SAVEPOINT order_item", &.{});
// tx.client.order.Create() / tx.client.order_item.Create() …
if (optional_item_error) {
    _ = try tx.tx.exec("ROLLBACK TO SAVEPOINT order_item", &.{});
    _ = try tx.tx.exec("RELEASE SAVEPOINT order_item", &.{});
} else {
    _ = try tx.tx.exec("RELEASE SAVEPOINT order_item", &.{});
}
try tx.commit();
```

出现不可恢复错误时调用 `tx.rollback()`（不要再调用 `commit()`）；savepoint 只提供局部回滚，不替代最外层事务的最终提交或回滚。

---

## 7. Schema / Edge 写法

```zig
const zent = @import("zent");
const field = zent.core.field;
const edge = zent.core.edge;
const Schema = zent.core.schema.Schema;

pub const Tenant = Schema("Tenant", .{
    .fields = &.{
        field.String("name"),
        field.String("domain"),
    },
});

pub const Product = Schema("Product", .{
    .fields = &.{
        field.Int("tenant_id"),
        field.String("name"),
        field.Int("price_cents"),
    },
});

// 有边时：在图里注册双方，用 edge.To / From / M2M
// pub const edges = &.{ edge.To("products", Product) };
```

约定：

- 表/实体名稳定；改名视为迁移，不静默糊弄
- 租户键显式字段（`tenant_id`）或 Privacy Filter，二者至少其一
- 索引、枚举、JSON、TimeMixin 跟 zent schema API，不在 service 里补 DDL

---

## 8. Persistence 契约

推荐形态（摘自 `examples/zent-modulith`）：

```zig
const graph = zent.codegen.graph.buildGraph(&.{ model.Tenant, model.Product });
pub const infos = graph.types;
pub const Client = zent.codegen.client.Client(infos);

pub const CatalogStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn createProduct(self: *CatalogStore, tenant_id: i64, name: []const u8, price_cents: i64) !i64 {
        var b = try self.client.product.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("price_cents", price_cents);
        const row = try b.Save();
        return row.id;
    }

    pub fn listProducts(self: *CatalogStore, tenant_id: i64) ![]ProductRow {
        var q = self.client.product.Query();
        defer q.deinit();
        const preds = self.client.product.predicates;
        _ = try q.Where(.{preds.tenant_idEQ(.{ .int = tenant_id })});
        var found = try q.All();
        defer {
            for (found.items) |*p| {
                zent.codegen.deinitEntity(infos, ProductInfo, p, self.allocator);
            }
            found.deinit();
        }
        // dupe 成 ProductRow DTO …
    }
};
```

约定：

| 方法前缀 | 语义 |
|----------|------|
| `find*` | `!?T`（无则 null） |
| `get*` / `list*` | `!T` / `![]T` |
| 租户过滤 | predicate 或 Privacy，**默认带上** |
| 对外返回 | DTO；调用方 `free*` 写清 |

---

## 9. Privacy 与 Hooks

**Privacy**

- Schema 挂 `policy`；请求路径注入 `PrivacyContext`（角色、tenant、viewer）
- 规则用 Allow / Deny / Filter；Filter 适合「只能看见本店行」
- 测试：无 context、错 tenant、跨租户读，应失败或空结果

**Hooks**

- `before`：校验失败返回 `ValidationFailed` / `Forbidden`，取消写
- `after`：审计、缓存失效通知（轻量）；重异步仍走 Outbox
- 不要在 hook 里开第二套 Driver 事务或发阻塞远程调用

---

## 10. 内存与错误

| 对象 | 规则 |
|------|------|
| `Query().All()` | `Managed(Entity)`；每项 `deinitEntity(infos, info, &e, alloc)`，再 `list.deinit()` |
| `Create()` builder | `defer builder.deinit()` |
| `driver.Tx` / `TxClient` | commit/rollback 后**恰好一次** `deinit` |
| `deinitEntity` | 传 **可变指针** `&entity`（非 `*const`） |
| DTO 字符串 | persistence `dupe`；上层 `free*` |

错误：persistence 上抛领域/驱动错误；api 映射为 HTTP 状态与文案，不吞 I/O / DB 错误。

---

## 11. 依赖接入

zent **v0.12** 提供 `build.zig.zon`（模块名 `zent`）。

**本地 sibling（开发）：**

```zon
.dependencies = .{
    .zent = .{ .path = "../../../zent" },
},
```

```zig
const zent_dep = b.dependency("zent", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zent", zent_dep.module("zent"));
```

**远程：**

```zon
.zent = .{
    .url = "https://github.com/chy3xyz/zent/archive/refs/tags/v0.12.0.tar.gz",
    .hash = "<zig fetch 后填入>",
},
```

期望目录（path 依赖）：

```
zig_ws/
  zigmodu/
  zent/          # git clone https://github.com/chy3xyz/zent.git
```

**zigmodu 侧驱动链接**：`examples/zent-modulith` 等 path 依赖仍 `addImport("zigmodu")`，并用 `db_link.Features.sqlite_only`，避免 zigmodu sqlx 再链 libpq/mysql。业务只走 zent 时也建议如此。完整约定见 [SQLX_DRIVERS.md](SQLX_DRIVERS.md) §8。

---

## 12. 反模式

| 反模式 | 正确做法 |
|--------|---------|
| api 里 `import zent` 拼 Query | 只调 service → persistence |
| zent Driver ↔ sqlx Client 互塞 | 分池、分模块 |
| 跨模块同事务混栈 | 同栈或 Outbox |
| 列表漏 `deinitEntity` | 固定 defer 模板 |
| 全靠 hook 写业务流程 | hook 只横切；编排在 service |
| 无 Privacy 又漏 `tenant_id` | predicate 或 policy 二选一强制 |
| 生产默认 `allow_data_loss` | 显式、可审计的 MigrateOptions |
| `:memory:` 多连接 | 单连接或文件/真库 |

---

## 13. 检查清单

- [ ] Schema 在 `model.zig`，HTTP **不** import `zent.sql_*`
- [ ] 启动：`open/pool → migrateSchema → makeClient`
- [ ] 列表：`deinitEntity` + `Managed.deinit`
- [ ] Create builder / Tx：**defer deinit**
- [ ] 租户：predicate 或 PrivacyContext
- [ ] 对外 DTO，不泄漏 zent 实体生命周期
- [ ] 未把 zent Driver 传入 sqlx Client
- [ ] 跨模块同事务 → 同栈；跨域 → EventBus/Outbox
- [ ] 生产用 ConnPool + 保守 migrate

---

## 14. 升级注意（zent 0.6 → 0.12 → 0.13+）

| 主题 | 动作 / 新特性 |
|------|--------------|
| **查询超时控制 (`withTimeout`)** | zent v0.13+ 支持 `client.product.Query().withTimeout(2000)`，通过 `ExecutionContext` 在底层 SQL 驱动触发超时下发（Postgres `statement_timeout` / MySQL `MAX_EXECUTION_TIME` / SQLite `deadline`），有效防止 ZigModu 异步 Fiber 场景下的长查询阻塞。 |
| **MySQL 原生 Upsert** | `SaveOrUpdate` 升级为生成 `INSERT ... ON DUPLICATE KEY UPDATE` 原生 DDL，保持主键与关联子行原子更新。 |
| **`deinitEntity` 可变指针** | `&entity` 统一清理内存 |
| **迁移表 `zent_schema_migrations`** | 幂等；勿手删 |
| **Pool `max_wait_ms`** | 改用 `max_retries` + backoff |
| **`build.zig.zon` fingerprint** | `zig build` 提示值写入 |
| **CRC / std 滚动** | 跟 Zig 0.17-dev（见 AGENTS.md） |


---

## 参考入口

| 资源 | 用途 |
|------|------|
| [`examples/zent-modulith/`](../examples/zent-modulith/) | ZigModu HTTP + zent 分层冒烟 |
| [`examples/tenant-shop/`](../examples/tenant-shop/) | sqlx + Tx/Outbox 旗舰路径 |
| [MODULE_LAYERS.md](MODULE_LAYERS.md) | model / persistence / service 通则 |
| [chy3xyz/zent](https://github.com/chy3xyz/zent) | ORM 本体与 `run-complex` / `run-pool` |
