# shopdemo-zent

A **zent-backed** parallel of [`examples/shopdemo/`](../shopdemo/).

## What this is

`examples/shopdemo/` is the canonical ZigModu order example — it uses
`zigmodu.data` (sqlx) for persistence. This example does the **same
thing** but swaps the persistence layer for
[zent](https://github.com/chy3xyz/zent), the Zig / ent-style
schema-as-code ORM.

Per [`docs/ZENT.md`](../../docs/ZENT.md), zent and `data.sqlx` are
**orthogonal**: a module picks one, never both. This directory
demonstrates the zent choice for a small order domain.

## Layout

```
shopdemo-zent/
├── build.zig            # ZigModu + zent (sqlite3 + optional pq/mysql)
├── build.zig.zon        # .name = .shopdemo_zent, zent = ../../../zent
└── src/
    ├── main.zig         # driver open → migrate → store → service → api → http
    └── modules/order/
        ├── model.zig        # Order + OrderItem (zent Schema)
        ├── persistence.zig  # OrderStore (zent Client) + OrderRow DTO
        ├── service.zig      # input validation + delegate
        ├── api.zig          # /api/v1/orders CRUD + items
        ├── module.zig       # zigmodu.api.Module lifecycle
        └── root.zig         # barrel
```

## Schemas (zent)

```zig
pub const Order = Schema("Order", .{
    .fields = &.{
        field.String("order_no"),
        field.String("status"),
        field.Int("amount_cents"),
        field.Int("user_id"),
    },
});

pub const OrderItem = Schema("OrderItem", .{
    .fields = &.{
        field.String("order_no"),  // string FK
        field.String("sku"),
        field.Int("qty"),
        field.Int("unit_price_cents"),
    },
});
```

## Routes

| Method | Path | Query / path params | Response |
|--------|------|---------------------|----------|
| `GET` | `/health/live` | — | `200 {"status":"UP","data":"zent"}` |
| `POST` | `/api/v1/orders` | `?order_no=&status=&amount_cents=&user_id=` | `201 {"id":N}` |
| `GET` | `/api/v1/orders` | — | `200 {"orders":[{...}]}` |
| `GET` | `/api/v1/orders/{order_no}` | — | `200 {...}` or `404` |
| `POST` | `/api/v1/orders/{order_no}/items` | `?sku=&qty=&unit_price_cents=` | `201 {"id":N}` |

## Run

Requires a sibling checkout of `zent`:

```
zig_ws/
├── zigmodu/
└── zent/
```

```bash
cd examples/shopdemo-zent
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build run
# or pick a port + persistent file:
SHOPDEMO_ZENT_SQLITE=./shopdemo.db HTTP_PORT=18200 zig build run
```

Default port is `18200`; default DB is SQLite `:memory:`. Override both
via `HTTP_PORT` and `SHOPDEMO_ZENT_SQLITE`.

## Compare to sqlx parallel

| | `examples/shopdemo/` | `examples/shopdemo-zent/` |
|---|---|---|
| HTTP | `zigmodu.http.Server` | `zigmodu.http.Server` |
| Modules | `zigmodu.api.Module` | `zigmodu.api.Module` |
| Schema | hand-written sqlx struct | `zent.Schema` + `field.*` |
| CRUD | `data.Repository` / `data.SqlxBackend` | `zent.codegen.client.makeClient` + `Create`/`Query` |
| Migrations | manual DDL | `zent.sql_schema.migrateSchema` |
| DTO | struct with `jsonStringify` | `OrderRow` (duped strings, `free` method) |

Both produce a `shopdemo`-shaped API on `/api/v1/orders`; switch the
persistence layer by switching examples, not by rewriting handlers.
