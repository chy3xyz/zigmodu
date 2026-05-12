# ShopDemo — 152-table Modulith E-Commerce

Full-featured e-commerce schema demonstrating ZigModu's modulith architecture.
Auto-partitioned into 30 modules by table prefix.

## Generate

```bash
# Install zmodu CLI
npm install -g @chy3xyz/zmodu

# Generate 30 modules from SQL schema
zmodu orm --sql schema.sql --out src/modules --enable-events --force

# Full project scaffold (build.zig, main.zig, etc.)
zmodu scaffold --sql schema.sql --name shopdemo --force
```

## Module Map

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
src/modules/
├── order/
│   ├── model.zig          # Order, OrderLine, OrderPayment structs
│   ├── persistence.zig    # data.orm.Orm(data.SqlxBackend) repositories
│   ├── service.zig        # CRUD + event hooks
│   ├── api.zig            # http.Context REST endpoints
│   ├── events.zig         # TypedEventBus (--enable-events)
│   ├── module.zig         # Lifecycle + health check
│   └── root.zig           # Barrel re-exports
├── user/
├── product/
└── ...
```

## Cross-Module Events

With `--enable-events`, each module publishes domain events:

```zig
// order/events.zig
pub const OrderCreated = struct { order_id: i64, timestamp_ms: i64 };
pub const OrderEvent = union(enum) { OrderCreated: OrderCreated, ... };

// product module subscribes
order.events.bus.subscribe(.OrderCreated, product.onOrderCreated);
```
