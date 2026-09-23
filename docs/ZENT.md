# ZigModu × zent 最佳实践

**zent**: [chy3xyz/zent](https://github.com/chy3xyz/zent) — Zig 版 [ent](https://entgo.io/)（schema-as-code ORM）  
**版本口径**: zent **v0.76.2**（**0.76 起可按驱动裁剪构建**：`b.dependency("zent", .{ .pg = false, .mysql = false })`，翻译期跳过对应 `translate-c`；**0.75 起** junction 表名与某个实体表名撞车时 `checkSchema` 报 **`junction_name_collision`** 并归为 read-breaking，`migrateSchema` 计划建表时 `warn` —— 只有一方能存在，改名是调用方的决定；0.76.1 修三处 OOM 路径泄漏（`Builder.initCapacity`/`takeQuery`/`Selector.init`）；0.73 起 `CrudService.get` → **`getOwned`**、配套 `deinitRowWith(allocator, &e)`；0.73 起 `Sum`/`Avg` 空集报 `EmptyAggregate`；0.70 起 **SQLite 强制外键**（`PRAGMA foreign_keys = ON`）；0.70 起 PG 的 `23502/23503` 不再误报 `UniqueViolation`；0.69 起 `SaveError` 增 `InconsistentRowFields`/`MissingPrimaryKey`；0.72 起 `Restore` 受策略过滤与拦截器约束；0.74 起 EntQL 拒绝未知字段；0.54 起 `CrudService.create(entity, tenant_id)` 双参；0.57 起 MySQL 的 `String`/`Enum` 落 `VARCHAR(255)`；0.40 起一行式实体释放 `deinitRows`/`deinitRow`/`deinitEdgeRows`；0.38 起 `queryTargets*` fail-closed；0.39 起 `zent.scope` 让裸 SQL 也走同一套读契约，见 §14/§15）· 本仓库示例按 **v0.76.2** 验证；`create` 双参签名要求 **≥ v0.54.0**，`getOwned` 要求 **≥ v0.73.0**，按驱动裁剪要求 **≥ v0.76.0**，其余条目见 §14 · ZigModu **v0.15.22+** · Zig **≥ 0.17**  
**主推组合**: **电商 / 社交类项目默认选 ZigModu + zent**（见 §2 决策表与 §4.8 场景能力矩阵）；只有存量 SQL 繁重、报表主导或 DBA 强管控的项目才默认 sqlx。这是**新项目选型建议**，与框架自带的默认实现不是一件事——口径见 §1「与框架自带那条的关系」。

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
14. [升级注意（0.6 → 0.37）](#14-升级注意zent-06--012--013--027--031--037)
15. [v0.34–v0.37 实战用法与边界](#15-v034v037-实战用法与边界)

---

## 1. 定位：正交，不要混栈

### 与框架自带那条的关系（先读这一段）

框架**自带的默认数据层是 sqlx，不是 zent**，两者层次不同，别把本文的"默认"读成"框架默认值变了"：

- `data.SqlxBackend` 是框架默认的 ORM backend，`data.Repository(T)` 就是
  `orm.Orm(SqlxBackend).Repository`（见 [`src/data.zig`](../src/data.zig)）；
- `build.zig.zon` 的 `.dependencies = .{}` —— **zent 不是框架依赖**，只在示例/应用里
  按 git tag 单独 pin（见 §11 依赖接入）。

所以本文说"电商 / 社交新项目**默认选** zent"，指的是**新项目选型建议**（§2、§4.8），
不是"框架默认改成 zent 了"。框架默认值决定"你不选也能跑什么"，本文决定"你该选什么"。

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
| **电商（商品/订单/库存/多店铺）** | **zent（主推）**：领域图密 + 金额精确（`field.Decimal`）+ 幂等 upsert + 行级隔离 |
| **社交（关注/feed/点赞/私信）** | **zent（主推）**：关系图一等公民 + 边预加载/过滤/排序 + Privacy 可见性 |
| 快速 CRUD、已有 SQL、报表/复杂手写查询 | **sqlx**（`zigmodu.data`） |
| 关系图密、codegen Client、migrate、privacy、hooks | **zent** |
| 下单→支付→Outbox→消息编排 | **sqlx 或 zent + ZigModu EventBus**（编排与 ORM 选型正交） |
| 同进程两套都用 | **按模块选型**（见 §3） |

**一句话**：编排与消息归 ZigModu；领域图与行级策略归 zent；简单表与存量 SQL 归 sqlx。电商/社交新项目的领域模块**默认 zent**，报表/对账等边缘读路径可单开 sqlx 只读模块（§4.7）。

**多租户边界**：`TenantContext`（租户来源：JWT / 中间件 → 运行时 id）是
引擎无关的，sqlx 与 zent 模块都直接用；行级隔离按引擎走惯用法，**不要跨引擎
混用**——sqlx 模块用框架的 `TenantInterceptor` / `DataPermission`
（字符串 SQL 拦截，`zigmodu.tenant` / `zigmodu.datapermission`），zent 模块用
Privacy Filter 或显式 `tenant_id` predicate（§8 / §9）。两套都做 = 双重租户
真相源，谁为准会打架。

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

**租户来源铁律（zent-modulith `CrudApi`）**：`CrudApiOpts.tenant_source` 有两个取值：

| 取值 | 含义 | 何时可用 |
|------|------|----------|
| `.attr`（推荐） | 从请求上下文 attr 取租户，由 JWT 中间件从 token `aud` claim 注入 | **生产唯一选择** |
| `.query` | 从 URL query 取租户 | 仅公开 demo |

`.query` 让客户端自己声明租户——改一个 `?tenant_id=` 就能跨租户读，
不是"配置不严"而是**可直接利用的越权**。`zmodu audit` 规则 b22 会拦截。
参考实现：`examples/zent-modulith/src/main.zig`（`.attr` +
`jwtAuthFromCatalog`，dev 取 token 走 `ZENT_DEV_TOKEN=1` 才挂载的路由）。

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

### 4.6 商城 / 社交场景补充能力（v0.20+）

| 场景 | 用法 | 说明 |
|------|------|------|
| 库存防超卖（原子扣减） | `u.setExprArgs("stock", "stock - ?", &.{.{.int = n}})` + `Where(idEQ, stockGTE)` | `?` 由表达式参数绑定（SET 先于 WHERE 入参）；`rows_affected == 0` 即库存不足。纯乐观锁（读改写 + version）在高并发下有争抢，秒杀优先走原子表达式。 |
| 乐观锁更新 | `field.Version()` | Update/Delete 自动 `WHERE version = ?` + `version = version + 1`，冲突返回 `OptimisticLockConflict`。 |
| 批量写 / upsert | `BulkInsertBuilder.SaveOrUpdate`（zent）；`data.bulk.insertMany`（zigmodu sqlx） | 下单商品明细 N 次 round-trip → 1 次。 |
| 两级关系预加载 | `q.WithEdge("posts.comments")` | 一次主查询 + 每级一次 IN 邻居查询；第三级为编译错误（终点无 edges 容器），逐层手动查询即可。 |
| 关注/好友/点赞 | `edge.To/From` + `graph.neighbors` | m2m 邻居查询（has/with 谓词）覆盖"我关注的人发的动态"。 |
| 时间戳自动维护 | `TimeMixin` + v0.22 | `created_at`/`updated_at` 列自动获得 epoch `DEFAULT`（方言感知）；`UpdateBuilder` 自动刷新 `updated_at`（显式设置优先）。 |
| 边排序 / 每父限量 | `edge.To(...).OrderBy("created_at").Desc().Limit(10)` | 预加载列表按目标列排序；每父 `LIMIT` 用 `ROW_NUMBER() OVER (PARTITION BY fk …)`（O2M/O2O；M2M/M2O 声明 limit 报 `UnsupportedEdgeLimit`）。显式 FK 用 `.Field("post_id")` 绑定（v0.22 修复）。 |
| 边过滤 | `edge.To(...).WhereRaw("\"hidden\" = ?", &.{.{ .bool = false }})` | 预加载邻居先过滤再排序/限量（v0.23）；例如 feed 只加载可见评论。 |
| 复合 keyset 游标 | `q.CursorKeyset("created_at", .{.int = ts}, id, desc)` + `Limit(n)` | `WHERE (col > ?) OR (col = ? AND id > ?) ORDER BY col, id`（v0.23）；同秒平局跨页不丢，自动补 id 决胜。 |
| 嵌套事务 | `beginTx` 内再 `beginTx` | 同一连接自动降级 `SAVEPOINT`（v0.24）；内层 rollback 只回滚内层写入，适合服务编排。 |
| 提交后回调 / 事务事件 | `tx.afterCommit(...)` + `enqueueEvent` / `takePendingEvents` | v0.24：提交成功后才投递（outbox/审计/通知），回滚不触发。 |
| 分布式 ID | `core.id.uuidv4() / uuidv7(now_ms)` + `field.UUID("id")` | v0.24：uuid 主键、跨分片安全、时间有序适合游标。 |
| 敏感字段掩码 | `zent.codegen.toMaskedJson(...)` | v0.24+（根导出 v0.27）：`Sensitive()` 字段输出 `"***"`，禁止直接序列化实体。 |
| 审计用户 / 内置校验 | `AuditMixin` + `NotEmpty/Length/Email/Phone/Custom` | v0.25：`created_by/updated_by` 自动填 `PrivacyContext.user_id`；校验在 Create/Update 自动执行。 |
| 软删恢复 / 批量软删 | `DeleteBuilder.Restore(id)` / `BulkDelete` + `IN` | v0.25/v0.26：恢复清 `deleted_at`；批量软删一条 UPDATE 置位。 |
| 列投影 / 批量插入 | `q.Select(&.{"id","name"})` / `CrudService.insertMany` | v0.26/v0.24：跳过 text/blob 大字段；批量写一条语句。 |

### 4.7 复杂报表与 join 边界（架构取舍）

zent 是 ent-style：**关系走 Edges 预加载，不做跨表 JOIN 查询**（无 join builder）。
商城对账、经营报表等需要 `ORDER BY` 多表聚合/join 的场景，按以下边界处理：

1. **优先**：`client.product.Query()` 拿本表数据 + `WithEdge` 组装，或 `CountBy` / `Sum` / `GroupBy` 做单表聚合。
2. **复杂报表**：用 zent driver 裸 SQL（`client.driver.query(...)`）或 zigmodu `data.sqlx` 写 JOIN —— **不要在 zent 与 sqlx 之间共享事务**（见 §1 定位；报表只读连接可独立）。

   ⚠️ **裸 SQL 的安全前提（v0.39 起）**：手写语句**不会**自动带上软删 / 隐私策略 /
   拦截器谓词——`client.driver.query()` 绕过了整条读契约，租户过滤会被静默跳过。
   必须在手写语句里用 `zent.scope` 拼上同一份契约：

   ```zig
   const scope = zent.scope.forClient(persist.infos, "product", &client.product, .{});
   const frag = try scope.withClause(allocator);   // 软删 → 隐私 → 拦截器
   defer allocator.free(frag);
   const sql = try std.fmt.allocPrint(allocator, "SELECT id, name FROM product WHERE 1=1 {s} ORDER BY id", .{frag});
   ```

   带策略的表若没有 `privacy_ctx`，`withClause` 直接返回 `error.PrivacyDenied`
   （fail-closed），而不是给你一段"没有过滤"的 SQL。`:alias` 会对每个注入谓词做限定，
   JOIN 时不会歧义；`table` 是 comptime 参数，写错表名是**编译错误**。
3. 报表查询建议独立 `report/` 模块持有自己的 `sqlx.Client`，与写路径（zent）解耦，避免把复杂 SQL 混进 domain 模块。

### 4.8 电商 / 社交主推能力矩阵（zent v0.30–v0.74）

这两版把电商/社交最常见的「钱、幂等、列表、可见性」四类痛点补成了一等能力，是主推组合的直接理由：

**电商**

| 场景 | 用法 | 说明 |
|------|------|------|
| 金额精确存储 | `field.Decimal("price")` | PG `NUMERIC` / MySQL `DECIMAL(38,10)` / SQLite `TEXT`；扫描为 `[]const u8`，**不再静默截断成 f64**。迁移自 `Float` 金额列时按 zent `UPGRADING.md` 处理存量数据。 |
| 业务键幂等写入 | `CreateBuilder.SaveOrUpdateOn(&.{"order_no"})` | 支付回调/重试安全：PG/SQLite `ON CONFLICT (cols) DO UPDATE`、MySQL ODKU；冲突目标显式，不靠猜主键。 |
| 防重复插入 | `SaveIgnore()` | MySQL `INSERT IGNORE` / PG `ON CONFLICT DO NOTHING`：券领取、唯一收藏等「插过就算」场景。 |
| 订单列表不丢单 | `q.WithEdgeOptions("payment", .{ .join = .inner })` | eager edge 走 schema 感知 EXISTS inner-join，`Limit` 在边过滤**之后**生效——「只列已支付订单」不再因 limit skew 少返回。 |
| 从共享池开事务 | `zent.codegen.beginTxFromDriver(infos, pool.asDriver(), alloc)` | 无 root Client 也能开类型化 `TxClient`；重入自动降级 savepoint（§6.4）。 |

**社交**

| 场景 | 用法 | 说明 |
|------|------|------|
| feed 关系过滤 | `WithEdgeOptions("author", .{ .join = .inner })` + Privacy Filter | 「我关注的人的动态」在 SQL 层过滤，避免拉回再筛。 |
| 聚合 DTO 直出 | `sql.SelectExpr("COUNT(*)", "like_count")` + `Selector.addColumn` + `Row.columnIndex("like_count")` | 点赞数/评论数随主查询一次返回，alias 三方言带引号；配 `sql.OrderExprSql` 排序。 |
| 请求级实体生命周期 | `codegen.ManagedEntity` / `managedEntity` + `dupeEntityTo(arena, …)` | allocator 绑定实体，teardown 不会选错 allocator；HTTP handler 里深拷贝（含 typed JSON、两级边）进请求 arena，响应结束一把放。 |
| NULL 安全读取 | `Row.tryGetInt/tryGetText/…` | 返回 `error.NullColumn` 而不是静默零值——统计列、可空外键不再读错。 |

**通用**

| 场景 | 用法 | 说明 |
|------|------|------|
| 借出字符串统一释放 | `crud_helpers.freeOwnedStrings` | escape-ledger 场景成批释放 owned 字符串。 |
| MySQL LIKE 转义 | `ContainsEscaped` | v0.30 起 ESCAPE 用 `!`（`\` 是 MySQL 字符串转义符，会污染 LIKE 模式）。 |

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

## 5.1 ORM 写模式差异（nullable + DB DEFAULT）

两种 ORM 的**写入语义**不同，混用时最容易踩的坑是「nullable 字段显式写 NULL 覆盖 DB DEFAULT」：

| | zigmodu（sqlx Repository） | zent（Create/UpdateBuilder） |
|---|---|---|
| 写模式 | **entity 全字段**：`insert(entity)` 把 struct 所有列写入 | **builder**：`Create.setFieldValue` / `Update.set` 显式设字段 |
| nullable + null | 显式写 `NULL` → 覆盖 DB `DEFAULT` | **不写入**（未 `set` 的字段不进 SQL）→ `DEFAULT` 天然生效 |
| INSERT 部分字段 | 需 `insertOmitNulls(allocator, entity)`（v0.15.25 新增） | 天然支持 |
| UPDATE 部分更新 | 需 `updatePartial(allocator, entity)`（v0.15.25 新增） | 天然 partial（`set` 只写已设字段） |

**关键**：zent 的 `CreateBuilder.saveInternal` 只 `for (self.values.items)`（显式 setValue 过的字段），未设置的列完全不在 INSERT 里——所以 zent **不存在**「nullable 覆盖 DEFAULT」的问题。

**zigmodu 侧**：默认 `insert`/`update` 保持全字段语义（`null` = 显式清空，便于完整覆盖）；要「DEFAULT 接管 / 部分更新」用 opt-in 变体：

```zig
// zigmodu — 省略 nullable-null 列，DB DEFAULT 接管
_ = try repo.insertOmitNulls(allocator, entity);
// zigmodu — 只改非 null 字段（部分更新，null 保持原值）
try repo.updatePartial(allocator, entity);
```

zent 侧无需改动（builder 模式天然规避）。

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

zent v0.31+ 支持不经 root Client、直接从共享 Driver/连接池开类型化事务：
`zent.codegen.beginTxFromDriver(infos, pool.asDriver(), alloc)`（重入调用自动降级 savepoint）——
定时任务、事件消费者等没有 root Client 的路径优先用它。

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
        // 整页释放走生成客户端的一行式 helper（zent ≥ 0.40）：需要 `var found`，
        // 它会把调用方的列表重置为空并释放每行持有的字符串。
        var found = try q.All();
        defer self.client.product.deinitRows(&found);
        // dupe 成 ProductRow DTO …
    }
};
```

约定：

| 方法前缀 | 语义 |
|----------|------|
| `find*` | `!?T`（无则 null） |
| `get*` / `list*` | `!T` / `![]T` |
| 结果释放 | `client.<entity>.deinitRow(&e)` / `deinitRows(&rows)`（生成客户端上的一行式 helper，zent ≥ 0.40）；手写 `deinitEntity` 循环是旧写法，本仓库示例已全部改掉 |
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
| `Query().All()` | `Managed(Entity)`；首选生成客户端的一行式 `client.<entity>.deinitRows(&rows)`（列表要 `var`）；底层手写形态 `deinitEntity(infos, info, &e, alloc)` + `list.deinit()` 仍然可用 |
| `Create()` builder | `defer builder.deinit()` |
| `driver.Tx` / `TxClient` | commit/rollback 后**恰好一次** `deinit` |
| `deinitEntity` | 传 **可变指针** `&entity`（非 `*const`） |
| DTO 字符串 | persistence `dupe`；上层 `free*` |
| 请求域深拷贝（v0.31） | `dupeEntityTo(req_arena, …)` 深拷贝字段/typed JSON/两级边进请求 arena，响应结束统一释放；`managedEntity` 绑定 owning allocator，杜绝 teardown 选错 allocator |

错误：persistence 上抛领域/驱动错误；api 映射为 HTTP 状态与文案，不吞 I/O / DB 错误。

---

## 11. 依赖接入

zent **v0.76.2** 提供 `build.zig.zon`（模块名 `zent`；生产 pin git tag，本地开发可换 path 依赖）。

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
    .url = "https://github.com/chy3xyz/zent/archive/refs/tags/v0.76.2.tar.gz",
    .hash = "<zig fetch 后填入>",
},
```

**按驱动裁剪（≥ v0.76.0，可选）：** 消费方声明自己链哪些驱动，zent 就跳过其余的
`translate-c` 期：

```zig
const zent_dep = b.dependency("zent", .{
    .target = target,
    .optimize = optimize,
    .pg = false,     // 不 import zent.sql_postgres 时关掉
    .mysql = false,  // 不 import zent.sql_mysql 时关掉
});
```

关掉一个**确实 import 了**的驱动会在首次使用时编译失败（`no module named 'pg_c'`），
不会静默降级。本仓库两个示例都用了它（`examples/zent-modulith` 关 pg+mysql，
`examples/metaverse-creative` 只用 sqlite+pg 所以只关 mysql），但**实测在本机不改变
端到端开销**（763 MiB / 80 s vs 默认 723 MiB / 82 s）：被省掉的两条 translate-c 是与
SQLite 那条（~597 MiB）**并行**的 ~23 s / 30 MiB 步骤，只有它们在某些主机上成为主项时
才有明显收益（上游给的数是每驱动 ~26 s / ~590 MB）。

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
- [ ] 列表：`client.<entity>.deinitRows(&rows)`（zent ≥0.40 的一行式释放；手写 `deinitEntity` 循环是旧写法）
- [ ] Create builder / Tx：**defer deinit**
- [ ] 租户：predicate 或 PrivacyContext
- [ ] 对外 DTO，不泄漏 zent 实体生命周期
- [ ] 未把 zent Driver 传入 sqlx Client
- [ ] 跨模块同事务 → 同栈；跨域 → EventBus/Outbox
- [ ] 生产用 ConnPool + 保守 migrate

---

## 14. 升级注意（zent 0.6 → 0.12 → 0.13 → … → 0.74 → 0.76）

> **升级自查（先跑命令，再读条目）**：
> ```bash
> zmodu audit .                 # 租户来源 / 裸 panic / 共享 map / 裸 alignCast / 分配器归属 / 熵源（b19–b24）
> zig build check-production    # 裸 catch / catch unreachable
> zig build test                # 形态与错误集快照（含文档↔代码一致性）
> ```
> 依赖版本升级后**先删 `.zig-cache` 再构建**（Zig 0.17-dev 增量缓存会沿用旧 fetch 模块）。

| 主题 | 动作 / 新特性 |
|------|--------------|
| **v0.76.0 按驱动裁剪 translate-c（消费者构建开销）** | `b.dependency("zent", .{ …, .pg = false, .mysql = false })`：zent 只为声明的驱动做 `translate-c`。默认仍是"有头文件就译"，所以不传=旧行为；**关掉一个确实 import 的驱动会在首次使用时编译失败**（`no module named 'pg_c'`/`sqlite3_c`/`mysql_c`），是刻意 fail-loud 而不是静默降级。本仓库两个示例都用上了（`zent-modulith` 关 pg+mysql，`metaverse-creative` 只用 sqlite+pg 故只关 mysql）；**本机实测端到端不变**（763 MiB / 80 s vs 默认 723 MiB / 82 s）——省下的两条 translate-c 与 SQLite 那条（~597 MiB）并行，各 ~23 s / 30 MiB，只有它们在某些主机上成为主项时才明显（上游：每驱动 ~26 s / ~590 MB）。 |
| **v0.75.0 junction 表名撞车报 `junction_name_collision`（BREAKING，schema 检查）** | `junctionTableForEdge` 推导的 `<a>_<b>` 可能正好是某个实体声明的表名，而两者都 `CREATE TABLE IF NOT EXISTS`、实体先建 —— 于是联结表的 `CREATE` 成了 no-op，该边的每次遍历都在**另一张表**上选列。以前 `checkSchema` 报的是症状（`missing_column` 之类）；现在报这个具名错误并归 **read-breaking**，`assertSchema(…, .read_breaking_only)` 会因此拦下一次发布。`migrateSchema` 在建联结表时（含 dry-run）只 `warn`：只有一个名字能存在，改哪个由调用方决定。本仓库示例不涉及撞名。 |
| **v0.76.1 三处 OOM 路径泄漏** | `Builder.initCapacity` / `Builder.takeQuery` / `Selector.init`：同一种形状——同一个表达式里前面的 `try` 已经交出所有权、后面的 `try` 才失败，于是 OOM 时泄漏。非 OOM 路径完全看不出来，是 `std.testing.checkAllAllocationFailures` 扫出来的。消费方无动作，升级即得。 |
| **v0.73.0 `CrudService.get` → `getOwned`（BREAKING，命名）** | 它返回的是复制进**调用方 allocator** 的行，而 `client.<entity>.deinitRow(&e)` 用 **client 的 allocator** 释放——两边是同一个 `Entity` 类型，除了调用点没人说得出哪个 allocator 才对，配错就是跨分配器 free（请求 arena 被写坏，或 `free of invalid memory` 打死进程）。改名把所有权写在了调用点上，配套 `client.<entity>.deinitRowWith(allocator, &e)` 是这类行的释放。本仓库 `zent_crud.get` 已改 `getOwned`（那段"这里为什么故意不 deinitRow"的注释保留，理由没变）。这也是 `zmodu audit` b23 拦的那一类，上游把它变成显式的了。 |
| **v0.74.0 EntQL 拒绝实体上不存在的字段** | 解析器不认识 schema：typo 以前原样下发（服务端才报错，且各方言不同）；更糟的是 `has(...)` 里的联结列会绑到联结表，把过滤退化成对外层行的条件，**无声地给出答案**。现在在 lowering 之前按解析树检查，API 名与物理列名两种拼法都接受；答案是 `error.UnknownField`。 |
| **v0.73.0 `Sum`/`Avg` 空集报 `EmptyAggregate`（BREAKING，错误集）** | 以前空集报 `error.TypeMismatch` —— 与"值不是数字"同一个错误，"没有数据"被报成类型问题，两者分不开。成员只加在 `Sum`/`Avg` 的专属错误集上（`QueryError \|\| error{EmptyAggregate}`），共享读取器（`All`/`First`/`Count` …）不被加宽；`SumOrZero`、`Max`/`Min` 不变。穷尽 `switch` 会被打到。 |
| **v0.72.0 `Restore` 受策略过滤与拦截器约束（行为变更，安全）** | `Delete().Restore(id)` 以前查了策略判定却丢掉 `result.getFilters()`，也从不跑拦截器链 —— 唯一两条都没做的写路径（兄弟 `Save`、两种软/硬删、两条批量路径都做了）。按租户/策略限定范围的策略因此允许调用方**复活任何它叫得出名字的行**。现在越界的 restore 匹配不到行并回答 `false`。 |
| **v0.72.0 `queryTargets*` / `QueryEdge` 中途失败不再给短页** | 读完最后一行后没问 `nextError()`，于是读一半的驱动失败（deadline 触发、消费到一半服务端报错）被当成"读完了"，把已读到的行当整页交给调用方，既无错误也无标记。其它批量读取器都会问，只有它例外。 |
| **v0.70.0 SQLite 强制外键（BREAKING，行为）** | `SQLiteDriver.open` 在每条连接上发 `PRAGMA foreign_keys = ON` 并**回读确认**（pragma 是 per-connection，且在事务里静默无效却仍答 `SQLITE_OK`，"发了"不等于"生效"）。SQLite 默认关，于是 `migrateSchema` 写下的 `FOREIGN KEY` 一直只被记录、从未被检查：悬空引用被接受、级联删除什么都不删、删被引用的父表会成功。现在悬空引用报 `error.ForeignKeyViolation`、级联真的删子行、`DROP TABLE` 被引用的表会失败 —— **测试与清理顺序跟着改（先删子表/联结表）**。库里已有悬空引用的可按连接退出：`.{ .enforce_foreign_keys = false }`，它的意思就是"不再检查引用"。 |
| **v0.70.0 PG 的 `23502`/`23503` 不再误报 `UniqueViolation`** | `sqlstateToError` 读的是 SQLSTATE 的第 2 位（`5`），整个 `235xx` 家族都命中唯一冲突分支，于是 not-null 与外键冲突在 PostgreSQL 上被当成唯一冲突。按 `ForeignKeyViolation` 分支、或拿 `UniqueViolation` 做 upsert 回退的消费者会走错路。 |
| **v0.69.0 `SaveError` 增两个成员（BREAKING，错误集）** | `InconsistentRowFields`、`MissingPrimaryKey`。前者出自 `MultiInsert`：语句只带**第一行**的列清单，而每行的值按自己的顺序铺开，字段少/多的行于是写错列或越界（长度断言因为缓冲区是按列清单算的，两边都拦不住）；现在任何一行与第一行**逐位置**不一致就在语句执行前报错，顺序不同也算不一致。后者是"uuid 主键没设"在 MySQL 上被当成键为 `""` 的实体 —— 现在语句执行前就报，不会留下无名行。 |
| **v0.68.0 预加载目标按字段顺序投影** | 邻居查询原来 `SELECT <target>.*`，列顺序是**表**的物理顺序，而结果集是按位置扫描的；`ALTER TABLE … ADD COLUMN`（`migrateSchema` 加字段的方式）会把列追加到末尾，所以在任何长期迁移过的库上，预加载目标都会把值读进错误的字段。MySQL 报 `TypeMismatch`，SQLite 静默给错值。现在 SELECT 列表取自扫描用的同一份 `TypeInfo`，投影与扫描不可能不一致。 |
| **v0.67.0 无 `last_insert_id` 报错 / MySQL 批量逐行（BREAKING）** | `CreateBuilder.Save` 以前在驱动没给 id 时把 `0` 写进主键（`res.last_insert_id orelse 0`）——`0` 与真 key 无法区分，调用方拿着一个"看起来已存在"的实体；MySQL 的 `BulkInsert/SaveOrUpdate` 还按 `base + i` 编造一串 id，只要 chunk 里有 `ON DUPLICATE KEY UPDATE` 命中，编造就是错的。现在没有 id 直接 `error.MissingLastInsertId`（**行已写入，只是 key 未知**），MySQL 改为一行一条语句（每行用驱动回报的 id；代价是每行一次往返，且 chunk 中途失败不再原子）。 |
| **v0.66.0 空 `dept_ids` 拒绝而非放行（BREAKING，安全）** | `.dept_custom` / `.dept_and_child` 拿到**空列表**时旧行为把谓词留成 `null`，而 `null` 在本模块就是"无限制"——于是没带部门的请求读到**全表**（相邻的"超长列表"分支却拒绝）。现在空列表与超长同样处理：物化恒假 `1 = 0` 并告警。`.all` 不受影响。本仓库 smoke 已把"空 `dept_ids` → 空结果"钉成断言（升级前那条会返回全表）。 |
| **v0.66.0 无谓词 `BulkDelete` 报错（BREAKING）** | `BulkDelete().Exec()` 不带谓词时，旧行为取决于**实体 schema**：软删实体静默什么都不做并返回 `0`（调用方读作"没有匹配行"），硬删实体**删全表**。现在统一 `error.NoPredicate`。与 v0.45.0 对无 `SET` 的 `UPDATE` 报 `NoFieldsToUpdate` 同一条规矩。 |
| **v0.54.0 `CrudService.create(entity, tenant_id)`（BREAKING，签名）** | 旧签名 `create(entity)` 从实体里读租户列，而写循环会**复制每个字段**（含租户列），拦截器又只填"缺失"的列——于是调用方新建实体的租户字段是 0 时，0 赢了绑定的租户并把 `0` 写进库。现在租户是**形参**，不再从实体读。本仓库 `zent_crud.CrudApi.create` 已改为 `create(buildEntity(tenant, body), tenant)`。 |
| **v0.57.0 / 0.58–0.59 `driver.Error` 扩张（BREAKING，错误集）** | 新增 `ParamCountMismatch`、`PoolWaitTimeout`；错误集不可扩展，**没有 `else` 的穷尽 `switch` 会编译失败**。另外 MySQL 的 `field.String`/`field.Enum` 现在落 `VARCHAR(255)`（此前 `TEXT`，而 MySQL 不允许 TEXT 做唯一键/默认值/索引 → 建表直接失败）。SQLite 也不再容忍绑定参数个数错误（此前多绑被丢、少绑读成 NULL，语句照跑但语义不同）。 |
| **⚠️ 升级陷阱：`deinitRow` 与 `CrudService.get` 的分配器不匹配（本仓库实测踩中）** | `CrudService.get(allocator, …)` 返回的是 **`ownedCopy(allocator, …)`**——字符串归**调用方传入的 allocator**（通常请求 arena），而 `client.<entity>.deinitRow(&e)` 用 **client 的 allocator** 释放 → 分配器不匹配，SafeAllocator 报 `free of invalid memory` 并**打死进程**（实测 `len: 6` 就是被释放两次的那 6 字节名字）。v0.15.44 那轮把 `deinitEntity(…, ctx.allocator)`（arena，Zig 0.17 里 `ArenaAllocator.free` 是 no-op，无害）机械替换成 `deinitRow`，才把这个潜伏错误变成崩溃。**v0.73.0 从 API 层面取消了这份心算**：`CrudService.get` 已改名 `getOwned`，这类行的释放是 `client.<entity>.deinitRowWith(allocator, &e)`（见本表首行）。**规矩**：`deinitRow(s)` 只用于**驱动扫描出来**的行（`client.X.Query().All()` / builder `Save()` 的返回值）；凡是从"带 allocator 形参"的函数拿到的（`get` / `queryRowOwned` / `scanRowsToOwned` …）都不要交给它，arena 会自己回收。`Query().AllIn(arena)` 是同一类：zent 的注释明说这些行"must **not** be passed to `deinitRows`/`deinitEntity`, which would free them into the wrong allocator"。**`zmodu audit` b23 拦这一类**（判据：`deinitRow(s)` 的目标绑定自一个参数里出现 allocator/arena 的调用）；确属误报就在同一行写 `// audit: ignore b23` 并注明出处。 |
| **⚠️ 升级陷阱：Zig 0.17-dev 增量缓存会沿用旧 fetch 依赖** | 改完 pin 直接 `zig build` 可能**继续用旧版本模块**：本仓库实测在 pin 已改成 v0.67.0 的情况下，"编译通过"且崩溃栈里的源码路径仍是 `zent-0.41.1`。**改 pin 后先 `rm -rf .zig-cache`（并删 `zig-pkg/<旧版本>`）再构建**，否则你验证的不是新版本。 |
| **v0.41.1 `deinitRows` 重新接受指针（0.40.0 回归修复）** | 0.40.0 把 `crud_helpers.deinitRows(rows: anytype)` 的实现收窄成只认值（`var list = rows; deinitEntityList(…, &list)`），于是所有传 `&rows` 的调用方**编译失败**（`expected type 'T', found '*T'`）；注释还声称"保持按值签名"，是错的。0.41.1 在 comptime 归一化：可变指针直通（调用方的列表被清空且可复用）、值与 `*const` 走可变副本。三个形态都有回归测试。**教训**：`anytype` 的"接受形态"一旦收窄就是静默破坏性变更——本仓库的 `docs/BEST_PRACTICES.md`「anytype 形参的契约写法」与 `src/test/ErrorSetSnapshot.zig` 就是为这类问题立的规矩。 |
| **v0.41.0 裸路径审计（哪些有作用域、哪些没有）** | `crud_helpers.queryRows` 只是 `driver.query` 的映射器，**按你写的语句原样执行**——与 `zent.scope` 要解决的裸路径同类，只是位置更高一层；其文档现在明说并给出组合写法，`BEST_PRACTICES` §5 列出每条裸路径的要求，并有端到端测试（未加作用域 3 租户行 → 加作用域 1 行）。另两条经审计确认安全：`PreparedCache` 以最终 SQL 文本逐字节为键（跨租户语句永不共享）、`explainSql` 只包一层 `EXPLAIN`（`Format` 无 `ANALYZE`，不会真执行）。 |
| **v0.40.0 一行式实体释放** | `deinitRows` / `deinitRow` / `deinitEdgeRows`（生成客户端与 builder 上都有），取代"N 次 `deinitEntity(infos, info, &e, alloc)` + `list.deinit()`"的长写法（zent 报告侧的统计是 607 处手写 vs 0 处用现成 helper）。**本仓库的 zent-modulith 示例已全部改用**（23 处手写调用 → `client.<entity>.deinitRow(&e)` / `deinitRows(&rows)`；注意列表形态需要 `var rows`，因为 helper 会重置调用方的列表）。 |
| **v0.39.0 `zent.scope` + 宽松扫描器 + `zent.version`** | ① `zent.scope.forClient(infos, table, &client.entity, opts)` 把与 fluent 路径**同一份**读契约（软删 → 隐私 → 拦截器）渲染成 SQL 片段，供手写语句 splice —— 此前裸 SQL 会静默跳过租户/隐私过滤（本文件 §4.7 已补警告）。带策略的表缺 `privacy_ctx` → `error.PrivacyDenied`。② `queryAllLenient` / `queryOneLenient` 把 v0.38 的宽松扫描带到查询层（NULL/缺列 → 保留字段默认值，而非 `error.TypeMismatch`），适合 LEFT JOIN/DTO。③ `<col>Contains` 的诚实名字 `<col>Like`（`Contains` 保留为别名，不破坏）。④ `zent.version` 让消费侧校验版本而不必比对 git 提交。 |
| **v0.38.0 `queryTargets*` 改为 fail-closed（BREAKING）** | 旧行为（目标只过滤软删、**不带**租户/隐私/拦截器）与 `WithEdge` 的读契约不一致，是真实的跨租户泄漏面。现在两个批量邻居读取器都走同一份 `appendTargetScopePreds`，目标带策略而无上下文时返回 `error.PrivacyDenied`；旧的"仅软删"语义保留在显式命名的 `queryTargetsUnscoped` / `queryTargetsByValueUnscoped`（**用它们就等于声明放弃隔离**，评审要写明理由）。同时新增 NULL 容忍扫描器 `scanRowLenient*` / `scanRowNamedLenient*`（LEFT JOIN、聚合输出、可空 DTO 的第二契约），严格扫描器不变。迁移步骤：zent `UPGRADING.md` §11。 |
| **v0.37.0 池阻塞等待 + 嵌套预加载** | `Options.max_wait_ms` 不再形同虚设：非 0 时 `borrow` 会在池条件变量上等待（由 `release` 唤醒），预算耗尽才 `error.PoolExhausted`，之后仍回落到原有 `max_retries` 路径；`max_wait_ms = 0`（默认）语义与旧版完全一致（非阻塞）。**升级自查**：此前"传了但无效"的 `max_wait_ms` 现在真的会排队。`ConnPool.deinit` 的调用约定明确要求静默期——不能靠 deinit 打断正在等待（parked）的借用者。`WithEdge("posts.comments")` 这类嵌套预加载从"每父实体一次查询"改为**每层一次查询**（实测 3 所有者两级 = 3 条语句），行为不变但 N+1 消失。 |
| **v0.36.0 迁移默认加锁 / outbox 认领可恢复 / 建表要求 allocator** | ① `MigrateOptions.lock_timeout_ms` 默认 10s，PG 用 `pg_advisory_lock`、MySQL 用 `GET_LOCK`，并发实例串行化，超时 `error.MigrationLockTimeout`（不支持/被拒时降级为告警继续）；已应用文件迁移的 checksum 会与磁盘比对，改动过的迁移报 `error.MigrationChecksumMismatch`。② outbox 认领新增可空 `claimed_at` 列（**存量库需迁移**；`migrateSchema` 会自动补列），崩溃在 publish 中途的行不再永久卡在 `processing`——用 `Outbox.requeueStale(allocator, client, older_than_secs)` 定期回收（示例已接：`examples/zent-modulith` 的 dispatcher 每次派发前先回收）。③ `createAllTables` / `createTables` 现在第一个参数是 allocator（不再内部用 page_allocator）。 |
| **v0.35.0 认领式 outbox 派发 + 边写入** | `Outbox.claim` 原子地把一批行从 `pending` 置为 `processing`（PG/SQLite 单条 `UPDATE … RETURNING`，PG 加 `FOR UPDATE SKIP LOCKED`；MySQL 走事务内的 `SELECT … FOR UPDATE SKIP LOCKED` + `UPDATE`），并发 dispatcher 不会再重复发布同一行；`pending` 保留为只读路径。`UpdateBuilder` 新增 `AddEdgeIDs` / `RemoveEdgeIDs` / `SetEdgeIDs` / `ClearEdge`，M2M 写关联表、o2m/o2o 走目标表 FK，非空 FK 拒绝 detach（错误在编译期）。 |
| **v0.34.0 参数化原生谓词 + 聚合/upsert 表达式** | `sql.RawArgs(sql_text, args)` 让裸 SQL 片段按方言重绑占位符（PG `$N`），与类型化谓词 `sql.And/Or` 组合，标记与参数数量不匹配直接报 `error.RawArgCountMismatch`。聚合：`SumOrZero` / `AggregateOne` / `AggregateText`（金额用精确十进制文本）/ `AggregateBy`（分组聚合，带谓词与软删过滤）。upsert：`SaveOrUpdateOnWith` 支持 `{t:col}` / `{x:col}` 表达式（计数器自增等），SQLite 上带表达式时改用 `ON CONFLICT DO UPDATE`（不再是 delete+insert）。 |
| **v0.33.0 拦截器覆盖写路径** | `UseInterceptor` 现在也拦截 `Create`/`BulkInsert`：`whereEq` 在 create 上语义为"缺省才填"（显式值保留），无该字段的表仍报 `UnknownField`。**自查存量拦截器**：v0.32 里只影响查询/更新/删除的拦截器，升级后会开始影响写入——这正是把租户注入收敛到拦截器的正确时机（见 `examples/zent-modulith` 的 `tenant-injection` 演示路由）。⚠️ 升级依赖后若行为未变，删 `.zig-cache` 重建——Zig 0.17-dev 增量缓存可能用过期的 path/fetch 依赖模块（本次适配实测踩中）。 |
| **v0.32.3 sqlite 连接串行化** | `SQLiteDriver` 内置 RecursiveMutex，所有连接访问串行——修复并发请求下 `sqlite3_prepare_v2` SEGV。**消费侧注意**：① `query()` 返回的 `Rows` 持有锁直到 `Rows.deinit()`，遍历完立即释放，不要持锁做慢操作（如同步 HTTP 调用）；② 单连接 sqlite 的并发吞吐本质是串行的，写重场景考虑 `beginTxFromDriver` + 池或换 PG/MySQL；③ 公共 API 无签名变化，纯升级即可。 |
| **v0.31 精确金额 / 边 inner-join / 池上事务** | `field.Decimal`（PG NUMERIC / MySQL DECIMAL(38,10)，扫描为 owned `[]const u8`）；`WithEdgeOptions(.{ .join = .inner })` 消除 eager-load limit skew；`beginTxFromDriver` 从共享 Driver/池直开 `TxClient`；`ManagedEntity`/`dupeEntityTo` allocator 安全 teardown；`SelectExpr`/`OrderExprSql`/`Row.columnIndex` 别名 DTO 映射。 |
| **v0.30 显式冲突目标 upsert** | `SaveOrUpdateOn(conflict_columns)`（PG/SQLite `ON CONFLICT (cols)`、MySQL ODKU）与 `SaveIgnore()`；`Row.tryGet*` NULL 显式报错；**MySQL `ContainsEscaped` ESCAPE 改为 `!`**（旧 `\` 会污染 LIKE 模式，自查依赖该行为的查询）。 |
| **v0.29 约束错误分类 / JSONValue / ⚠️ Time 列类型** | `UniqueViolation`/`NotNullViolation`/`ForeignKeyViolation` 三方言统一（不再误报 `NotFound`）；`field.JSONValue` 无类型 JSON 文档；**`field.Time` 全方言改 BIGINT epoch 秒（PG 原为 TIMESTAMPTZ，存量 PG 表需迁移列类型）**；`WhereEntQL` 支持 `has/not_has(edge)`；Privacy 按操作（OnCreate/OnQuery…）生效。 |
| **v0.28 JSON 所有权统一** | 查询/预加载路径的 JSON 解析进 per-entity arena，由 `deinitEntity` 释放；调用方不要再自行 free scan 出的 JSON。 |
| **查询超时控制 (`withTimeout`)** | zent v0.13+ 支持 `client.product.Query().withTimeout(2000)`，通过 `ExecutionContext` 在底层 SQL 驱动触发超时下发（Postgres `statement_timeout` / MySQL `MAX_EXECUTION_TIME` / SQLite `deadline`），有效防止 ZigModu 异步 Fiber 场景下的长查询阻塞。 |
| **MySQL 原生 Upsert** | `SaveOrUpdate` 升级为生成 `INSERT ... ON DUPLICATE KEY UPDATE` 原生 DDL，保持主键与关联子行原子更新。 |
| **`deinitEntity` 可变指针** | `&entity` 统一清理内存 |
| **迁移表 `zent_schema_migrations`** | 幂等；勿手删 |
| **Pool `max_wait_ms`** | 改用 `max_retries` + backoff |
| **`build.zig.zon` fingerprint** | `zig build` 提示值写入 |
| **CRC / std 滚动** | 跟 Zig 0.17-dev（见 AGENTS.md） |
| **v0.21 原子表达式** | `setExprArgs`：`SET stock = stock - ? WHERE id = ? AND stock >= ?`，`rows_affected == 0` 即库存不足，防超卖。 |
| **v0.22 时间戳自动维护** | `.time` 列获得方言感知 epoch `DEFAULT`；`UpdateBuilder` 自动刷新 `updated_at`。 |
| **v0.23 边过滤 / keyset 游标** | `WhereRaw` 过滤邻居；`CursorKeyset` 复合 `(col, id)` 游标平局不丢。 |
| **v0.24 嵌套事务 / afterCommit / uuid / 掩码** | `beginTx` 内再 `beginTx` 降级 savepoint；`afterCommit` + `enqueueEvent`；`uuidv7` 主键；`toMaskedJson` 敏感掩码。 |
| **v0.25 审计用户 / 校验器 / 恢复** | `AuditMixin` 自动填 `created_by/updated_by`；`NotEmpty/Length/Email/Phone/Custom` 自动校验；`Restore` 恢复软删。 |
| **v0.26 投影 / 批量软删** | `Select(cols)` 列投影跳过 text/blob；soft-delete 实体 `BulkDelete` 一条 UPDATE 置位；`or_in` 值语义谓词修悬垂。 |
| **v0.27 根导出补全** | `codegen.toMaskedJson` 根导出；optional 字段 create/get/update/bulk 全路径修复。 |


---

## 15. v0.34–v0.37 实战用法与边界

新能力不是"知道有"就够，关键是**什么时候用、什么时候不要用**。

| 能力（版本） | 用它的场合 | 不要用的场合 / 坑 |
|---|---|---|
| `sql.RawArgs(sql_text, args)`（0.34） | `BETWEEN`、函数调用、复杂 `IN`——类型化谓词表达不了的片段，且需要参数化 | 能用类型化谓词就别写裸 SQL；拼接字符串仍在 `zmodu audit`/评审红线。标记与参数数量不匹配会报 `error.RawArgCountMismatch`（比"悄悄拼错"好，但仍是运行期） |
| `SumOrZero` / `AggregateOne` / `AggregateText` / `AggregateBy`（0.34） | 统计口径：空集要 0 而不是 NULL、单值聚合、**金额用 `AggregateText` 拿精确十进制文本** | 金额别用 `AggregateBy`（f64 舍入）；`AggregateBy` 返回 `Managed(GroupMetric)`，记得 `freeGroupMetrics` |
| `SaveOrUpdateOnWith`（0.34） | upsert 里需要表达式，如 `{t:receive_num} + 1` 计数 | SQLite 上带表达式会从 `INSERT OR REPLACE`（delete+insert，破坏 FK/ROWID）切到 `ON CONFLICT DO UPDATE`——**行为差异要考虑**；占位列名只允许 `[A-Za-z0-9_]` |
| 边写入 `AddEdgeIDs` / `RemoveEdgeIDs` / `SetEdgeIDs` / `ClearEdge`（0.35） | 关联维护（M2M 关联表、o2m/o2o 移 FK），不想手写 junction SQL | 非原子：语句按父更新谓词作用域，**要原子就包 `beginTx`**；非空 FK 拒绝 detach（编译期报错，别绕过） |
| 类型化谓词 `In`/`NotIn`/`IsNull`/`NotNil`/`HasPrefix`/`HasSuffix`/`ContainsFold`/`EQFold`（0.35） | 用户输入做 LIKE/前缀匹配 | LIKE 变体会转义通配符（用户输入按字面匹配）——如果业务真的需要 `%` 通配，那就不是"用户输入"了，务必显式说明 |
| `Outbox.claim` 认领式派发（0.35） | **多 dispatcher 并发**（多副本 / 多 worker）：认领先于发布，同一行不会被重复发布 | `pending` 变成只读路径，别再拿它驱动派发；认领后进程崩溃会留下 `processing` 行 → 必须配 `requeueStale`（下条） |
| `Outbox.requeueStale(allocator, client, older_than_secs)`（0.36） | 周期性 sweeper，回收"认领后派发进程死掉"的行（NULL `claimed_at` 一律视为陈旧） | 阈值要**大于最长发布时间**（示例用 300s），否则会把还在发布中的行抢回；UPDATE 幂等，多个 sweeper 同时跑无害 |
| 迁移默认加锁 + checksum 校验（0.36） | 多实例滚动发布同时启动 | 角色没有 advisory lock 权限时：PG 会降级为告警继续（**要确认是"继续"还是"锁失败"**）；已应用迁移文件一旦被改动即 `error.MigrationChecksumMismatch`——**不要改历史迁移** |
| `StorageKey`（0.36） | 采用 zent 但既有库表列名不合字段命名规范（`user_name` vs `userName`） | 一旦使用，字段名与列名分叉：`whereEq`、谓词、DDL 都用**字段名**，只有物理列名不同——排障时以 `codegen.graph.columnName` 为准 |
| `queryTargetsByValue`（0.36） | 主键是 UUID / 文本的实体也要遍历边 | `queryTargets` 仍是 i64 专用包装；两者语义一致（空列表短路、目标软删过滤、调用方拥有结果） |
| `client.<entity>.deinitRow(&e)` / `deinitRows(&rows)` / `deinitEdgeRows(edge, &rows)`（0.40+） | 释放查询结果：单行、整页+列表、边页 | **整页要 `var rows`**（helper 会把调用方的列表重置为空、可复用）；`&rows` 与 `rows` 都接受，但传值只释放副本、调用方的列表变陈旧（0.40.0 曾把这条收窄导致消费方编译失败，见 §14） |
| `crud_helpers.queryRows`（0.41 明确） | 需要自己拼 SQL 的读写 | 它是**裸路径**：不带你配的软删/隐私/拦截器，必须用 `zent.scope` 组合（同 `driver.query`） |
| `zent.scope.forClient` + `withClause`（0.39） | 手写 SQL（报表/JOIN）要保住租户与隐私过滤 | 别把它当"可选装饰"：带策略的表没上下文会 `PrivacyDenied`，这正是 fail-closed 的意义；`table` 是 comptime，别名/表名写错当场报错 |
| `queryTargets` / `queryTargetsByValue`（0.38 起 fail-closed） | 一次性批量读邻居实体，且希望与 `WithEdge` 同样的租户/隐私作用域 | 真需要"不加隔离"时必须显式改叫 `*Unscoped`，并在评审里说明理由——别为了绕过 `PrivacyDenied` 无脑替换 |
| `scanRowNamedLenient*` / `queryAllLenient`（0.38/0.39） | LEFT JOIN、聚合输出、字段可空的 DTO | 实体读仍用严格扫描器：非空列出现 NULL 说明行不符合 schema，宽松化会把"数据坏了"变成静默默认值 |
| `BulkInsert` 分片 + `chunkRows(n)`（0.36） | 批量插入行数大（SQLite <3.32 的参数上限 999；MySQL `max_allowed_packet`） | 分片后仍是多次语句：**要么整批在事务里**，要么接受部分成功；`chunkRows` 只在你明确要控制语句大小时才用 |
| 池阻塞等待 `max_wait_ms`（0.37） | 可以接受排队而不是立刻失败（推荐配 3–5s 的预算 + 指标） | 默认 `0` = 非阻塞（旧语义）。**`ConnPool.deinit` 要求静默期**：不能拿 deinit 去打断正在 parked 的借用者，必须确保没有线程在 `borrow`/`release`/`asDriver` 中 |
| 嵌套预加载每层一次查询（0.37） | `WithEdge("posts.comments")` 这类两级加载，之前是 N+1 | 语义没变但**要记住预加载目标的读契约**：只过滤软删，**不带租户/行级隐私作用域**——跨租户数据不能靠预加载来"顺带"过滤，需要在父查询或目标查询上显式加谓词 |

**升级自查（踩过的坑）**：改完 `build.zig.zon` 的 pin 后若行为/编译结果没变，**先删
`.zig-cache` 再构建**——Zig 0.17-dev 的增量缓存会沿用旧的 fetch 模块（本次 v0.33→v0.37
适配实测：`zig build --verbose` 显示仍在用 `zig-pkg/zent-0.33.0-…`）。

---

## 参考入口

| 资源 | 用途 |
|------|------|
| [`examples/zent-modulith/`](../examples/zent-modulith/) | ZigModu HTTP + zent 分层冒烟 |
| [`examples/tenant-shop/`](../examples/tenant-shop/) | sqlx + Tx/Outbox 旗舰路径 |
| [MODULE_LAYERS.md](MODULE_LAYERS.md) | model / persistence / service 通则 |
| [chy3xyz/zent](https://github.com/chy3xyz/zent) | ORM 本体与 `run-complex` / `run-pool` |
