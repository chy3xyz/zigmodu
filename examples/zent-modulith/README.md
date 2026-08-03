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
curl -s -X POST 'http://127.0.0.1:18100/api/v1/products?tenant_id=1&name=Widget&price_cents=1999'
curl -s 'http://127.0.0.1:18100/api/v1/products?tenant_id=1'
```

## zent 新特性演示

- **paged()**：`GET /api/v1/products/paged?tenant_id=1&page=1&size=2`
  → `{"total":N,"products":[...]}`（内建 count + limit/offset，统一释放）。
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
    api.zig                # pub const routes (ComptimeRouter)
    module.zig             # ZigModu module contract
```

**Do not** mix `zent.Driver` into `zigmodu.data.sqlx.Client` — keep stacks separate.
