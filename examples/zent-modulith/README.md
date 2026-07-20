# zent-modulith — ZigModu + zent

Demonstrates **ZigModu** (Application / HTTP / modules) with **[zent](https://github.com/chy3xyz/zent)** v0.12+ as the schema-as-code data layer.

See framework guide: [`docs/ZENT.md`](../../docs/ZENT.md)（选型、分层、Privacy/Hooks、反模式、检查清单）.


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
curl -s -X POST 'http://127.0.0.1:18100/api/v1/tenants?name=Acme&domain=acme.test'
curl -s -X POST 'http://127.0.0.1:18100/api/v1/products?tenant_id=1&name=Widget&price_cents=1999'
curl -s 'http://127.0.0.1:18100/api/v1/products?tenant_id=1'
```

## Layout

```
src/
  main.zig                 # ZigModu HTTP + zent migrate/client
  modules/catalog/
    model.zig              # zent Schema("Tenant"|"Product")
    persistence.zig        # zent Client wrappers
    service.zig            # validation / Cmd
    api.zig                # HTTP
    module.zig             # ZigModu module contract
```

**Do not** mix `zent.Driver` into `zigmodu.data.sqlx.Client` — keep stacks separate.
