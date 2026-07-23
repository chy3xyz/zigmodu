# ShopDemo — Minimal Runnable ZigModu Example

> **Scope**: This directory is now a **minimal runnable app** that uses only the single `order` module extracted from `generated-sample/`.  
> The full 152-table e-commerce schema remains in `schema.sql`; generating all 30+ modules requires the [zmodu CLI](https://github.com/chy3xyz/zigmodu).

## Quick Start

```bash
cd examples/shopdemo
zig build run
```

The server listens on `0.0.0.0:8080` by default (override with `HTTP_PORT=...`).

### Smoke test

```bash
curl -s http://127.0.0.1:8080/api/v1/orders
# {"items":[],"page":0,"size":10,"total":0,"total_page":0}

curl -s http://127.0.0.1:8080/health/live
# {"status":"UP"}
```

## What is included

| Path | Purpose |
|------|---------|
| `build.zig` / `build.zig.zon` | Build manifest copied and adapted from `examples/tenant-mgmt` |
| `src/main.zig` | Entry point: SQLite client, schema application, module lifecycle, HTTP server |
| `src/db/backend.zig` | Shared `*data.Client` backend alias |
| `src/db/schema.zig` | SQLite DDL for the single `zmodu_order` table |
| `src/modules/order/` | The `order` module migrated from `generated-sample/` |

## Generating the full project

The original `schema.sql` contains 152 tables across ~30 modules. To scaffold the complete project:

```bash
# Install zmodu CLI
npm install -g @chy3xyz/zmodu

# Generate all modules from SQL schema
zmodu orm --sql schema.sql --out src/modules --enable-events --force

# Full project scaffold (build.zig, main.zig, etc.)
zmodu scaffold --sql schema.sql --name shopdemo --force
```

## Module Map (full schema)

| Module | Tables | Domain |
|--------|:------:|--------|
| supplier | 18 | Vendor management |
| user | 17 | User accounts, profiles |
| agent | 12 | Agent/distributor |
| order | 11 | Order lifecycle |
| shop | 8 | Store management |
| live | 7 | Live streaming commerce |
| product | 6 | Product catalog |
| app | 6 | Mini-program config |
| bargain | 5 | Bargain/haggle |
| seckill | 4 | Flash sales |
| delivery | 4 | Logistics |
| assemble | 4 | Product assembly |
| store | 3 | Physical stores |
| ... | ... | +17 more modules |

## Architecture

```
src/modules/order/
├── model.zig          # Order, OrderAddress, OrderProduct, ... structs
├── persistence.zig    # data.Repository(T) repositories
├── service.zig        # CRUD delegation + event hooks
├── api.zig            # HTTP handlers under /api/v1/orders
├── module.zig         # Module lifecycle contract
└── root.zig           # Barrel re-exports
```
