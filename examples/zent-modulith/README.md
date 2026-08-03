# zent-modulith — ZigModu + zent

Demonstrates **ZigModu** (Application / HTTP / **ComptimeRouter**) with **[zent](https://github.com/chy3xyz/zent)** v0.12+ as the schema-as-code data layer.

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
  modules/catalog/
  model.zig              # zent Schema("Tenant"|"Product")
  persistence.zig        # zent Client wrappers
  service.zig            # validation / Cmd
  zent_crud.zig          # 泛型 CrudApi 适配器（包 zent CrudService）
  api.zig                # 自定义端点（counts/search/bulk/SSE）
  module.zig             # ZigModu module contract
```

**Do not** mix `zent.Driver` into `zigmodu.data.sqlx.Client` — keep stacks separate.
