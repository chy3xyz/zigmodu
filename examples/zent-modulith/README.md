# zent-modulith — ZigModu + zent

Demonstrates **ZigModu** (Application / HTTP / **ComptimeRouter**) with **[zent](https://github.com/chy3xyz/zent)** v0.32.0 as the schema-as-code data layer (demos span v0.21–v0.32 capabilities).

See framework guides: [`docs/ZENT.md`](../../docs/ZENT.md) · [`docs/ROUTE_TABLE.md`](../../docs/ROUTE_TABLE.md).


## Prerequisites

- Zig ≥ 0.17
- Sibling clone of zent:

```bash
# expected layout
zig_ws/
  zigmodu/
  zent/          # git clone https://github.com/chy3xyz/zent.git
```

`build.zig.zon` path-depends on `../../../zent`.

## Run

```bash
cd examples/zent-modulith
HTTP_PORT=18100 zig build run
```

## Smoke

```bash
curl -s http://127.0.0.1:18100/health/live
curl -s http://127.0.0.1:18100/openapi.json | head
curl -s -X POST 'http://127.0.0.1:18100/api/v1/tenants?name=Acme&domain=acme.test'
curl -s -X POST 'http://127.0.0.1:18100/api/v1/products?tenant_id=1' \
  -H 'Content-Type: application/json' -d '{"name":"Widget","price_cents":1999}'
curl -s 'http://127.0.0.1:18100/api/v1/products?tenant_id=1&page=1&page_size=20'
curl -s 'http://127.0.0.1:18100/api/v1/products/1?tenant_id=1'
```

## 泛型 CRUD（`zent_crud.CrudApi`）

手写 5 个 handler 由一行声明替代——`zent_crud.CrudApi(infos, ProductInfo, .{
module_name, nest, tenant_col, tenant_source })` 生成标准的
list/create/get/update/delete 五条路由（ComptimeRouter），内部包
`zent.crud.CrudService`（租户过滤 + CrudEvent）。租户来源可配：
`.attr`（JWT 中间件写 `tenant_id`）或 `.query`（本演示）。

```bash
# list（paged 信封 {code, items, total}；page/page_size 自动钳制）
curl -s 'http://127.0.0.1:18100/api/v1/products?tenant_id=1&page_size=10000'
# create（JSON body；tenant 来自 query/attr，不入 body）
curl -s -X POST 'http://127.0.0.1:18100/api/v1/products?tenant_id=1' \
  -H 'Content-Type: application/json' -d '{"name":"Widget","price_cents":1999}'
# get / update / delete（跨租户访问返回 404）
curl -s 'http://127.0.0.1:18100/api/v1/products/1?tenant_id=1'
curl -s -X PUT 'http://127.0.0.1:18100/api/v1/products/1?tenant_id=1' \
  -H 'Content-Type: application/json' -d '{"name":"Widget Pro","price_cents":2199}'
curl -s -X DELETE 'http://127.0.0.1:18100/api/v1/products/1?tenant_id=1'
```

自定义端点（counts/search/bulk/SSE）与泛型 CRUD 同 `module_name`/`nest`
共存，`assertNoDupes` 只拦截重复 method+path。

## Outbox（事务性事件 + cron 投递）

`zent.outbox.Outbox` 演示：事件行与业务写在同一事务里
（`beginTx → enqueueTx → commit`），提交后 `dispatch` 至少一次投递，失败自动
重试（attempts+1），超 `max_attempts` 标记 failed。

```bash
# 事务入队（与业务变更原子提交）
curl -s -X POST 'http://127.0.0.1:18100/api/v1/outbox/enqueue?aggregate_type=product&aggregate_id=1&event_type=product.created&payload=%7B%22id%22%3A1%7D'
# 手动投递（cron 每分钟自动投递，需要 ZENT_SQLITE=文件路径）
curl -s -X POST 'http://127.0.0.1:18100/api/v1/outbox/dispatch'
```

后台 cron 使用**独立连接**（file-backed SQLite），不与请求 fiber 共享 driver；
`:memory:` 模式会告警并跳过 cron（手动 dispatch 仍可用）。

## Data-scope 行级权限（中间件下沉）

`Doc` schema 挂了 `zent.data_scope.Policy`：scope 中间件从请求解析出
`user_id/tenant_id/scope/self_dept_id/dept_ids` 写入 attrs，handler 构建
`DataScopeFilter` 并通过 scoped zent client 查询——行级过滤发生在 SQL 层，
缺上下文直接 `PrivacyDenied`。

```bash
# self_：只看 owner_id = user_id 的行
curl -s 'http://127.0.0.1:18100/api/v1/docs?user_id=1&tenant_id=1&scope=self_'
# dept_custom：只看 dept_ids 命中行
curl -s 'http://127.0.0.1:18100/api/v1/docs?user_id=1&tenant_id=1&scope=dept_custom&dept_ids=9'
# dept_only：看本部门行
curl -s 'http://127.0.0.1:18100/api/v1/docs?user_id=1&tenant_id=1&scope=dept_only&self_dept_id=3'
# all：全量
curl -s 'http://127.0.0.1:18100/api/v1/docs?user_id=1&tenant_id=1&scope=all'
```

## 商城/社交能力（v0.21）

**原子库存扣减（`setExprArgs`，防超卖）**：一条语句完成
`SET stock = stock - ? WHERE id = ? AND stock >= ?`，`rows_affected == 0`
即库存不足（409）。

```bash
curl -s http://127.0.0.1:18100/api/v1/inventory/1          # {"stock":100,...}
curl -s -X POST 'http://127.0.0.1:18100/api/v1/inventory/decrement?product_id=1&qty=30'
curl -s -X POST 'http://127.0.0.1:18100/api/v1/inventory/decrement?product_id=1&qty=80'  # 409 insufficient_stock
```

**两级嵌套预加载 + 边过滤（`WithEdge("posts.comments")` + `WhereRaw`）**：
主查询 + 每级一次 IN 邻居查询，返回 Author → posts → comments 嵌套
JSON。`comments` 边声明了 `WhereRaw("\"hidden\" = ?", false)` + 
`OrderBy("id").Desc().Limit(2)`——每篇 post 只带**最新 2 条可见**评论
（过滤先于排序/限量，每父 `LIMIT` 走窗口函数 `ROW_NUMBER() OVER
(PARTITION BY …)`；种子数据里有一条 hidden 的 spam 评论永不加载）。

```bash
curl -s http://127.0.0.1:18100/api/v1/feed/authors
```

## 事务编排 / 分布式 ID / 游标 / 批量软删（v0.23–0.26）

**下单事务编排（`beginTx` 嵌套 savepoint + `afterCommit` 事件收集）**：
`POST /api/v1/orders` 演示 v0.24 的三件套——外层 `beginTx` 建订单，
内层 `beginTx`（同一连接自动降级为 `SAVEPOINT`）做原子库存扣减（不足时
只回滚 savepoint、整单回滚返回 409），`enqueueEvent` 收集事务内事件，
`afterCommit` 钩子在提交成功后恰好一次 `takePendingEvents` 投递。

```bash
# 先建商品（订单总额 = 单价 × qty）
curl -s -X POST 'http://127.0.0.1:18100/api/v1/products?tenant_id=1' \
  -H 'Content-Type: application/json' -d '{"name":"Widget","price_cents":1999}'
# 下单：库存 100→97，events_delivered=2（order.created + stock.decremented）
curl -s -X POST 'http://127.0.0.1:18100/api/v1/orders?product_id=1&qty=3'
# 库存不足：409，且不产生订单行、库存不变
curl -s -X POST 'http://127.0.0.1:18100/api/v1/orders?product_id=1&qty=100'
curl -s 'http://127.0.0.1:18100/api/v1/orders/1'
```

**分布式 ID + 敏感掩码（uuidv7 + `toMaskedJson`）**：`Account` 用
`field.UUID("id")` 主键，服务端生成时间有序 uuidv7（跨分片安全）；
`api_key` 声明 `.Sensitive()`，读接口必须走 `toMaskedJson` 输出 `"***"`，
直接把 entity 序列化会泄漏密钥。

```bash
curl -s -X POST 'http://127.0.0.1:18100/api/v1/accounts?name=bob&api_key=sk-bob-9'
curl -s 'http://127.0.0.1:18100/api/v1/accounts/<返回的uuid>'
# -> {"id":"…","name":"bob","api_key":"***"}
```

**复合 keyset 游标（`CursorKeyset`）**：`GET /api/v1/feed/comments` 按
`(created_at, id)` 游标分页，`WHERE (created_at > ?) OR (created_at = ? AND
id > ?)`——同一秒写入的评论（种子数据故意制造平局）跨页不丢。`page_size=1`
翻第二页时，平局的第二条评论仍会返回。

```bash
curl -s 'http://127.0.0.1:18100/api/v1/feed/comments?page_size=1'
# page 1 -> nice post (created_at=100, id=1)；next_cursor_ts=100, next_cursor_id=1
curl -s 'http://127.0.0.1:18100/api/v1/feed/comments?cursor_ts=100&cursor_id=1&page_size=1'
# page 2 -> thanks (created_at=100, id=2) —— 平局行没被跳过
```

**批量软删（`BulkDelete` + `IN`）**：`POST /api/v1/feed/bulk-delete` 一次
UPDATE 把所有 id 的 `deleted_at` 置位（Post 是 soft_delete 实体），随后
`/feed/trashed` 可见、`/{id}/restore` 可恢复。

```bash
curl -s -X POST 'http://127.0.0.1:18100/api/v1/feed/bulk-delete' \
  -H 'Content-Type: application/json' -d '{"ids":[1,2]}'
curl -s 'http://127.0.0.1:18100/api/v1/feed/trashed'
```

**审计 / 校验 / 投影 / 批量 / 软删（v0.25-0.26 能力）**

```bash
# 创建时校验器自动执行（name NotEmpty+Length），审计字段自动填 user 1
curl -s -X POST 'http://127.0.0.1:18100/api/v1/products?tenant_id=1' \
  -H 'Content-Type: application/json' -d '{"name":"widget","price_cents":99,"description":"big"}'
# 投影列表（跳过 description 大字段）
curl -s 'http://127.0.0.1:18100/api/v1/products/summary'
# 批量插入（CrudService.insertMany，一条语句）
curl -s -X POST 'http://127.0.0.1:18100/api/v1/products/batch' \
  -H 'Content-Type: application/json' -d '[{"tenant_id":1,"name":"b1","price_cents":10}]'
# 软删 + 恢复（Post）
curl -s -X DELETE 'http://127.0.0.1:18100/api/v1/feed/1'
curl -s 'http://127.0.0.1:18100/api/v1/feed/trashed'
curl -s -X POST 'http://127.0.0.1:18100/api/v1/feed/1/restore'
```

## zent 新特性演示

- **paged()**：泛型 list 即 `GET /api/v1/products?tenant_id=1&page=1&page_size=2`
  → `{"code":0,"items":[...],"total":N}`（内建 count + limit/offset，统一释放）。
- **CountBy()**：`GET /api/v1/products/counts` → 每租户行数（单条 GROUP BY）。
- **ContainsEscaped()**：`GET /api/v1/products/search?tenant_id=1&q=100%25`
  —— `%`/`_` 渲染期转义按字面匹配（实测 q=100% 只命中含 `100%` 的行，
  不命中 `100x…`）。
- **BulkInsert.SaveOrUpdate()**：`POST /api/v1/products/bulk`（JSON 数组，id
  必填，按 id upsert）→ 更新既有行 + 插入新行一次完成（SQLite 走
  `ON CONFLICT ("id") DO UPDATE SET`）。

查询参数支持 RFC 3986 百分号解码（`%25`→`%`、`+`→空格），搜索含
空格/`%` 的关键词可直接传编码值。

## Layout

```
src/
  main.zig                 # ZigModu ComptimeRouter + zent migrate/client
  outbox_demo.zig          # outbox 事务入队 + dispatch（HTTP + cron）
  data_scope_demo.zig      # scope 中间件 + DocApi（行级权限）
  features_demo.zig        # 原子库存扣减 + 两级预加载（feed）
  tx_demo.zig              # 下单事务编排 + uuidv7 账户/敏感掩码
  modules/catalog/
  model.zig              # zent Schema("Tenant"|"Product")
  persistence.zig        # zent Client wrappers
  service.zig            # validation / Cmd
  zent_crud.zig          # 泛型 CrudApi 适配器（包 zent CrudService）
  api.zig                # 自定义端点（counts/search/bulk/SSE）
  module.zig             # ZigModu module contract
```

**Do not** mix `zent.Driver` into `zigmodu.data.sqlx.Client` — keep stacks separate.
