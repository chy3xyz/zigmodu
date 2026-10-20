# zmodu 领域分层最佳实践（model / persistence / service）

**适用**：zmodu v0.14+ · Zig 0.17  
**参考实现**：[`examples/tenant-shop/`](../../examples/tenant-shop/)（sqlx）；zent 栈见 [`examples/zent-modulith/`](../../examples/zent-modulith/) + [ZENT.md](../reference/ZENT.md)

相关文档：

| 文档 | 关系 |
|------|------|
| [MODULITH.md](./MODULITH.md) | 模块边界与并发 |
| [elegant-code-patterns.md](../archive/elegant-code-patterns.md) | 五文件样例 |
| [MODULITH_TENANT_SHOP.md](./MODULITH_TENANT_SHOP.md) | 多租户店蓝图 |
| [ZENT.md](../reference/ZENT.md) | zent ORM 正交接入（schema / Client / migrate） |
| [BEST_PRACTICES.md](./BEST_PRACTICES.md) | DAU 演进 + JWT / 多端身份 |
| [ROUTE_TABLE.md](../reference/ROUTE_TABLE.md) | ComptimeRouter + catalog 鉴权门禁 |
| [AGENTS.md](../../AGENTS.md) | AI 操作手册 |

---

## 1. 职责一句话

| 层 | 做 | 不做 |
|----|----|------|
| **model** | 行形状、`sql_table_name`、纯函数（枚举↔字符串） | SQL、HTTP、事务 |
| **persistence** | 参数化 SQL、`tenant_id` 过滤、`Tx` 工作单元助手 | 业务 if/else、开事务 |
| **service** | 校验、编排、`beginTx`、写 outbox、Cmd/Result | 拼长 SQL、碰 `Context` |
| **api / BFF** | 解析入参、错误文案、`ctx.json` | 业务规则、直接 SQL |

---

## 2. model

```zig
pub const Product = struct {
    id: i64,
    tenant_id: i64,
    name: []const u8,
    price_cents: i64,
    status: i32,
    created_at: i64,
    updated_at: i64,

    pub const sql_table_name = "products";
};
```

建议：

1. **状态集中到 `business/enums.zig`**（或模块内 enum），service 边界做 toString / fromString。
2. **字符串所有权写清**：scan 出来的 `[]const u8` 由谁 free；跨请求持有必须 `dupe`。
3. **避免 `id = 0` 哨兵**（进阶可用 `NewProduct` 无 id 写入 DTO）。
4. 纯计算可放 model（如 `available = qty - reserved`），不要放 api。

---

## 3. persistence

### 3.1 CRUD：`Persistence(Backend)`

```zig
// `Backend` 是装配处选定的**具体类型**（comptime 形参），它只决定下面用哪套方法：
//   *data.Client     → queryRowPartial / queryRowsPartial（返回自有字符串，调用方 free）
//   data.SqlxBackend → queryRowPartialBorrowed（借用单行：字符串在 BorrowedRow(T).deinit()
//                      前有效）/ queryRows（整页自有）——见 src/persistence/backends/SqlxBackend.zig
pub fn ProductPersistence(comptime Backend: type) type {
    return struct {
        db: Backend,
        pub fn init(db: Backend) @This() { return .{ .db = db }; }

        // products 表自带 tenant_id → 业务键是 (tenant_id, id)。
        // 表本身就是租户主表、没有 tenant_id 列时（tenant-shop 的 tenants），
        // 签名退化为 findById(self, id) —— 见
        // examples/tenant-shop/src/modules/tenant/persistence.zig。
        pub fn findById(self: *@This(), tenant_id: i64, id: i64) !?model.Product {
            return self.db.queryRowPartial(model.Product, "... WHERE tenant_id = ? AND id = ?", &.{
                .{ .int = tenant_id }, .{ .int = id },
            }) catch |err| switch (err) {
                error.NotFound => null,
                else => err,
            };
        }
    };
};
```

模块间依赖不走 DI Container，一律上面的构造注入（`init(db)` 显式传依赖）——
Container 的定位边界见 [EVENTS_DI.md「Container 的定位边界」](./EVENTS_DI.md)。

约定：

| 方法前缀 | 语义 |
|----------|------|
| `find*` | `!?T`（NotFound → null） |
| `get*` / `list*` | `!T` / `![]T`（找不到就错或空切片） |
| `Backend` | 装配处传入的具体类型：`*data.Client`（自有扫描）或 `data.SqlxBackend`（借用扫描，`BorrowedRow` 作用域内有效） |
| 带 `tenant_id` 列的表 | 所有查询的第一个业务键是 **`tenant_id`** |
| 租户主表（无 `tenant_id` 列） | 按主键查即可（`findById(self, id)`）；隔离由鉴权层（JWT `aud` → 租户中间件/作用域）负责，这一层没有可加的谓词 |

### 3.2 跨表同一事务：`pub const Tx`

同进程 Unit-of-Work（下单扣库存）允许编排模块 **import 兄弟模块的 `persistence.Tx`**（仅 SQL，无业务分支），**禁止**互相调用对方 Service 却共享未声明的连接。

```zig
// inventory/persistence.zig
pub const Tx = struct {
    pub fn reserve(tx: *data.sqlx.Transaction, tenant_id: i64, product_id: i64, qty: i64, now: i64) !void { ... }
    pub fn release(...) !void { ... }
    pub fn commitSale(...) !void { ... }
};
```

```zig
// order/service.zig — 编排可读如伪代码
try inventory_persist.Tx.reserve(&tx, ...);
const order_id = try order_persist.Tx.insertOrder(&tx, ...);
try outbox_write.insertPending(&tx, ...);
try cart_persist.Tx.clearItems(&tx, ...);
try tx.commit();
```

规则：

- `Tx.*` **只含 SQL**（`rows_affected` 检查可留在 Tx，视为持久化契约）。
- 「库存够不够」等业务判断留在 **service**。
- Outbox INSERT 放 `foundation/outbox_write.zig`，避免每个域复制 DDL 形状。

### 3.3 禁止

- handler / BFF 里写 SQL  
- 业务模块互相 `import` 对方 **Service** 却绕过依赖声明去摸 **非 Tx** 的内部表细节（应走 service API 或事件）  
- `catch {}` 吞 DB 错误  

---

## 4. service

### 4.1 CRUD 服务

```zig
pub fn ProductService(comptime Persistence: type) type {
    return struct {
        persistence: Persistence,
        pub fn create(self: *@This(), tenant_id: i64, name: []const u8, price_cents: i64) !model.Product {
            const now: i64 = @intCast(zmodu.time.monotonicNowSeconds());
            // 组装 model → persistence.insert → 填 id
        }
    };
};
```

时间戳由 **service** 写入，persistence 不读时钟。

### 4.2 工作流服务（checkout / charge）

```zig
pub const CheckoutCmd = struct { tenant_id: i64, user_id: i64 };
pub const CheckoutResult = struct { order_id: i64 };

pub fn checkout(self: *Self, cmd: CheckoutCmd) !CheckoutResult {
    var tx = try self.db.beginTx();
    errdefer tx.rollback() catch |err| std.log.err("[order] rollback: {}", .{err});
    // Tx helpers…
    try tx.commit();
    return .{ .order_id = order_id };
}
```

| 做法 | 说明 |
|------|------|
| **Cmd / Result** | 少用一长串标量；API 层组装 Cmd |
| **幂等** | 支付等写路径用业务键；先查再写（范式见 [BEST_PRACTICES.md「幂等：网络重试去重 vs 业务幂等键」](./BEST_PRACTICES.md)） |
| **同事务 outbox** | 业务行 + outbox 同行提交，再由 poller → RobustMQ |
| **错误稳定** | `InvalidInput` / `NotFound` / `ConstraintViolation`；API 再映射文案 |

---

## 5. api / BFF

- 只依赖 **service**，不依赖 persistence。  
- `queryRows*` 结果：调用方 `defer allocator.free(slice)`（字符串所有权另见 sqlx 文档）。  
- BFF：编排多个 service，不复制域 SQL。

---

## 6. 与 Modulith 通信规则的关系

| 场景 | 做法 |
|------|------|
| 强一致、同事务 | service 编排 + 各模块 `persistence.Tx` |
| 跨域最终一致 | Outbox → RobustMQ / EventBus |
| 只读聚合 | 调对方 **service** 公开方法 |

详见 [MODULITH.md §2.3](./MODULITH.md)。

---

## 7. 模块状态与多相位卫生

**状态结构体由 `initWith` 期 heap 分配、`deinit` 释放**；句柄经
`ctx.services.register(T, "name", ptr)` 进 per-Application 的 Container（字段在
`src/Application.zig:76`，随相位销毁），或经路由 `State` 传递。文件级 `pub var`
**仅限无状态句柄**（`?*Inbox` 这类纯指针，相位结束置 `null` 即干净）。

若必须文件级静态（句柄缓存、跨函数可见的同步原语），**`deinit` 必须复位全部字段** ——
值类型 Latch / 计数器一并回初值。先例与教训同在
[`examples/alpha-engine/src/modules/exec/module.zig`](../../examples/alpha-engine/src/modules/exec/module.zig)：
`:34-36` 的文件级 `c.Latch`（`drained` / `authorized_done`）曾在 deinit 只置空句柄指针的年份里
跨相位残留（上一相位的 armed 状态带进下一相位，调试计数器悄悄累计、专门误导定位）；现行
`:56-64` 的 `deinit` 已补上 `drained.reset()` / `authorized_done.reset()`（`:61-62`，注释原文
"Same-process rebuilds must not inherit the previous phase's flags"）。Latch 谁复位是**作者责任**，
框架不查 —— 验收型多相位进程（同一 `main` 里 build / stop / build 多个相位）写文件级静态时
把这条当 checklist。这类残留也正是"状态进 Container / State"方向要消灭的类别，别当范式照抄。

模块仪式（`pub var inbox` + `initWith` spawn + `deinit` 置 null）的 handle 存取当前是手写：
ModuleScanner 只扫 `info` / `init` / `initWith` / `deinit` 四个声明
（`src/core/ModuleScanner.zig:13-53`），由它代劳 handle 存取属 **1.x 候选**；官方收敛方向 =
状态进 Container / State，仪式自然缩短。runtime worker 的 spawn / join 归属见
[RUNTIME.md §3d](../reference/RUNTIME.md)；Container 能装什么、不能装什么见
[EVENTS_DI.md「Container 的定位边界」](./EVENTS_DI.md) §3.4。

---

## 8. 落地检查清单

- [ ] 每个域有 `model` / `persistence` / `service` / `api` / `module`  
- [ ] 工作流 SQL 不在 service 内联超过 ~10 行；已抽 `Tx` 或 `*_write`  
- [ ] 所有租户查询带 `tenant_id`  
- [ ] checkout / charge 使用 Cmd/Result  
- [ ] outbox 与业务同事务；poller 在 foundation  
- [ ] `:memory:` SQLite 用单连接；文件库才开后台 poller  

---

## 9. tenant-shop 对照

| 模块 | 分层要点 |
|------|----------|
| product / cart / inventory | CRUD `Persistence` + `Tx`（reserve / priceCents / clearItems） |
| order | `OrderPersistence` + `Tx`；`CheckoutCmd` 编排 |
| payment | `PaymentPersistence` + `Tx`；`ChargeCmd` 幂等 |
| foundation | `outbox_write` / `outbox.Poller` / `mq.Publisher` |
| shop_bff / admin_bff | 只调 service / poller |
