# zmsaas — SaaS 业务框架参考工程（zigmodu 后端 + SolidStart 前端）

一个可直接运行的完整示例：**zigmodu 后端**（org 隔离的 `orders` 业务模块，
由 `zmodu saas` 生成）+ **saas-solidjs 前端**（管理页 + `zmoduFetch` REST
client，由 `zsaas/scripts/gen-business.mjs` 生成）。

## 结构

```
examples/zmsaas/
├── backend/              # zigmodu 后端（原 saas-kit 形态）
│   ├── build.zig / build.zig.zon / db_link.zig
│   └── src/
│       ├── main.zig      # 接线：sqlite + JWT/RBAC 中间件栈 + Router.mountAll
│       ├── auth/root.zig # 公开 login（签发租户 JWT）
│       ├── db/schema.zig # orders 表 + RBAC 授权 + 种子数据
│       ├── middleware/   # 框架最佳实践鉴权栈（沿用 tenant-mgmt）
│       └── modules/orders/  # zmodu saas 生成：model/persistence/service/api/module/root
├── frontend/             # saas-solidjs 前端（已排除 node_modules/.git/.output）
│   └── src/
│       ├── libs/apiClient.ts           # 类型化 zigmodu REST client（信封 + Bearer + 错误映射）
│       ├── components/data/            # 数据驱动收敛：DataTable.tsx + EntityForm.tsx
│       ├── models/Orders.ts            # 实体类型 + 字段 schema（表/表单共用）
│       └── routes/dashboard/orders/    # index.tsx CRUD 演示页（login → list → create/edit/delete）
├── scripts/dev.sh        # 双进程启动（后端 + 前端）
└── README.md
```

## 运行

```bash
# 一键双进程
bash examples/zmsaas/scripts/dev.sh

# 或分开：
cd examples/zmsaas/backend && zig build run          # http://127.0.0.1:18080
cd examples/zmsaas/frontend && npm install && npm run dev   # http://localhost:3000
```

后端 API：

```bash
TOKEN=$(curl -s -X POST http://127.0.0.1:18080/api/v1/auth/login | jq -r .token)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18080/api/v1/orders
```

无 token → 401；token 只访问自己 `org_id` 的数据（种子 org 1）。

后端自测：`cd examples/zmsaas/backend && zig build test` —— 跑生成的模块冒烟
（内存 sqlite CRUD + validate 负向 + transact），读路径走 typed
`row.scan`（按列名映射，无手写列下标）。

## 自定义业务逻辑演示

在生成代码之上叠加了三类扩展（框架能力，非生成物）：

- **状态机端点**：`POST /api/v1/orders/{id}/cancel` —— service 自定义
  `cancel()`（仅 `pending` 可取消，复用 `crud.get/crud.update`，零新 SQL），
  api.zig 同 nest 挂第二个 `OrdersActionsApi`（`assertNoDupes` 只查
  method+path 重复）；非法状态返回 409。
- **事件订阅**：`modules/orders/events.zig` 订阅 `CrudEvent`，写操作
  （含 cancel 走的 update）自动 publish，日志/通知/审计/外发与主流程解耦。
- **CRUD 方法覆盖**：service 声明同名方法即优先于内嵌 CrudService（可
  `self.crud.*` 复用基础行为）；未覆盖的仍零透传直通。
- **事务多写**：`POST /api/v1/orders/{id}/fulfill` —— `transactWith` 在单事务
  内完成 CAS 状态更新（pending→paid）+ 审计插入（`order_events`），状态不符
  返回 409，任一失败整体回滚。
- **DTO/批量/排序**：list/get 走 `OrdersDto` 白名单（内部列不上 wire）；
  `POST /orders/bulk` 批量创建；list 支持 `sort=amount&order=desc`
  （列名白名单防注入）；`total` 为真实 COUNT。

重新生成：`zmodu saas …` 后运行
`python3 examples/zmsaas/scripts/reapply-custom.py` 一键恢复自定义层。

## 运维面（基础框架标配）

- **版本化迁移**：DDL 走 `MigrationRunner`（`db/migrations/V1..V3__*.sql`），
  history 落 `_zigmodu_migrations`，重启幂等（实测重启后仍 3 条记录）；
- **健康检查**：`GET /health/live` + `GET /health/ready`（含 DB 连通性检查）；
- **指标**：`GET /metrics` Prometheus 格式（`http_requests_total`，请求计数
  中间件）；tracing 的 `x-trace-id` 一直开着；
- **事务性 outbox**：`fulfill` 在业务事务内同时写 `event_outbox`
  （`order.fulfilled` 事件），投递至少一次；投递侧可接
  `POST /api/v1/outbox/flush`（`src/ops.zig`，单线程安全）演示一轮投递：
  pending → processing → delivered（实测 status 0→2）；生产把
  `deliverPending` 挂到 cron 周期任务或 DistributedEventBus 消费者。
  文件 DB 模式下自动启动 **cron 周期投递**（每分钟，`Scheduler` 后台线程 +
  池化 client 保证线程安全）：`fulfill` 后无需 flush，一个周期内自动
  delivered（实测 status 0→2）。
- **前端真实登录态**：orders 页 token 存 sessionStorage，未登录显示登录表单，
  登出清态；401 时错误提示。生产把 SolidStart 会话兑换成带租户/角色的 JWT。

## 多租户纵深（shard + 数据权限）

- **ShardRouter 分片**：`GET /api/v1/shard/route?org_id=N` 演示租户→分片路由
  （org 1→shard_a，org 2→shard_b）；`POST /api/v1/shard/orders` 把订单写到
  租户所在分片（两个 sqlite 文件），`GET /api/v1/shard/orders` 从分片读回。
- **数据权限**：列表按 JWT 角色过滤——`login` 默认 admin（全量），
  `login?role=user&uid=42` 签发 user（`DataPermissionContext.fromRoles` +
  `buildWhere("region","owner_id")` 的 `.self_` 作用域：只见本人行）。
  实测 admin 见全部、user(42) 只见 owner_id=42，跨分片一致。
  角色→作用域解析已下沉到统一 `dataPermissionMiddleware`（写 `data_scope`
  attr）；SQL 注入用框架 `DataPermissionInterceptor`（镜像 TenantInterceptor，
  由 `DataPermissionContext` 产出 scope 子句），handler 不再手写过滤条件。
- **分片负载/再平衡**：`GET /shard/load` 显示每分片行数；
  `POST /shard/rebalance?org_id=N` 在「目标分片 + 本租户行数 < 当前分片行数」
  时把租户连同数据迁到更轻分片并更新路由（稳定规则，避免振荡）。
  实测：22/14 → org1 迁移 4 行 → 18/18 均衡；再次调用保持不变。
  幂等：`key` 参数 + `rebalance_events` 表（V4 迁移）——同 key 重放直接返回
  存储结果（实测 `idempotent:true` 不重跑）；行级用
  `(org_id, source_id)` 唯一索引 + `INSERT OR IGNORE`，部分失败重试不重复
  （实测迁移后无重复行）。
- 生产：分片为 PG/MySQL 时直接用 `ShardRouter.buildSqlxConfig(pool)` 建连接；
  数据权限可下沉到 TenantInterceptor/中间件统一注入。

## 多语言错误消息

框架 `respondErr` 原生支持本地化：`http.setErrorLocalizations(&.{
  .{ .err = error.ValidationFailed, .zh = "校验失败", .en = "Validation failed" }, … })`
后，请求带 `Accept-Language: zh` 时所有走 `respondErr` 的错误（autoCrud、
自定义路由全覆盖）返回中文 detail，否则英文/`@errorName`。实测：
`zh → "校验失败"`、`en → "Validation failed"`、`zh 409 → "状态冲突"`。

## 前端 CRUD 收敛（DataTable / EntityForm）

`/dashboard/orders` 演示了「数据驱动 CRUD」：页面不手写表格行/表单控件，
只声明列与字段 schema：

- `DataTable<T>`：列定义（key/header/render）、分页、loading/空态、行操作；
- `EntityForm`：字段定义（text/number/textarea/select + required）→ 自动渲染、
  必填校验、提交/取消；
- `models/Orders.ts`：`Order` 类型 + `orderFields` schema，两端共用，新增模块
  照此收敛；
- `libs/apiClient.ts`：解析后端信封（`{code,items,total}` / `{code,data}`），
  401/非零 code 统一抛错，路径拼接兼容带/不带尾斜杠的 `VITE_API_URL`。

## 重新生成业务模块

```bash
# 改 zsaas/examples/orders.model.json 后：
zmodu saas zsaas/examples/orders.model.json --out examples/zmsaas/backend/src/modules
node zsaas/scripts/gen-business.mjs zsaas/examples/orders.model.json examples/zmsaas/frontend
```

新增实体 → 追加到模型文件 → 两端重新生成（schema 记得同步 `db/schema.zig`）。
字段若需要下拉/枚举，在模型 JSON 的字段上加 `"options": [{"value","label"}]`，
前后端生成都会自动变成 select 控件 + Badge 列。
