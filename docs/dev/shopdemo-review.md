# ShopDemo Architecture Review & ZModu Generator Optimization

## Current State

152 MySQL tables → 30 modules auto-partitioned by `zmodu_<prefix>` naming convention.

```
Top modules by table count:
  supplier(18)  user(17)  agent(12)  order(11)  shop(8)
  live(7)  product(6)  app(6)  bargain(5)  seckill(4)
```

## Architecture Issues

### 1. Single-level prefix is fragile
`zmodu_order_payment` lands in `order/`, not `payment/`. A 3-level order sub-module
(`order/payment`, `order/delivery`, `order/refund`) would be more cohesive.

**Fix**: Support `--module-depth=2` for `{prefix}_{submodule}` partitioning.
`zmodu_order_payment` → `order/payment/`, `zmodu_order_delivery` → `order/delivery/`.

### 2. No cross-module dependency inference
`order` depends on `user` and `product` — discoverable from foreign keys or naming conventions
(`user_id`, `product_id` columns). Generated `module.zig` should auto-declare these.

**Fix**: Infer dependencies from column naming (`{module}_id` pattern) and add to `api.Module.dependencies`.

### 3. All CRUD, no domain logic
Generated code is 100% CRUD scaffolding. Real apps need:
- Event publishing (`order.created` → notify payment, inventory)
- Saga transactions (`createOrder` → reserveInventory → chargePayment)
- Validation rules (e.g., `min_order_amount`)

**Fix**: Add `--with-events` flag to generate `events.zig` + `saga.zig` per module.

### 4. No API gateway / BFF layer
30 modules × 6 files = 180 files of CRUD endpoints. No aggregation layer for
composed endpoints like `/api/order-detail` (joins order + user + product).

**Fix**: Add `zmodu gateway <name>` to generate aggregation endpoints with
cross-module joins.

### 5. Auth integration is manual
Every module needs auth wiring. Currently done per-endpoint — repetitive and
error-prone.

**Fix**: Add `--with-auth` flag that generates JWT middleware config per module.

## ZModu Generator Optimizations

### P0 — Add to zmodu CLI

| Command | Generates |
|---------|-----------|
| `zmodu events <module>` | `events.zig` with publish/subscribe helpers |
| `zmodu saga <name>` | `saga.zig` with multi-step transaction orchestration |
| `zmodu gateway <name>` | `gateway.zig` with cross-module aggregation endpoints |
| `zmodu orm --with-events` | Full module including events + saga scaffolding |

### P1 — Improve ORM generator

| Feature | Current | Target |
|---------|---------|--------|
| Dependency inference | Manual | Auto from `{module}_id` columns |
| Sub-module depth | 1 level | Configurable N levels |
| Validation rules | None | Auto from NOT NULL, UNIQUE, VARCHAR(len) |
| Auth middleware | Manual per-file | `--with-auth` flag generates once |
| Event scaffolding | None | `--with-events` generates publisher + subscriber |

### P2 — Module template improvements

Current template generates 6 files per module:
```
root.zig      — barrel re-export
module.zig    — metadata + lifecycle
model.zig     — struct + table_name
persistence.zig — repository pattern
service.zig   — CRUD business logic
api.zig       — HTTP handlers
```

Should add (when flags enabled):
```
events.zig    — TypedEventBus publisher + subscriber
saga.zig      — SagaOrchestrator definition
gateway.zig   — cross-module aggregation
test.zig      — integration test scaffold
```

## ShopDemo as Best-Practice Showcase

### What it demonstrates well
- 152-table Modulith partitioning
- Auto-generated type-safe CRUD
- One-module-per-domain cohesion

### What's missing to be a true showcase
- Inter-module event flow (order.created → payment.processed → delivery.scheduled)
- Saga transactions (placeOrder saga across order + inventory + payment)
- Gateway aggregation (/api/order-detail combining 3 modules)
- Auth integration (JWT middleware per module)
- Cluster deployment config (ClusterBootstrap for multi-node)

### Recommended demo structure

```
shopdemo/
├── src/
│   ├── main.zig              # Application entry + ClusterBootstrap
│   ├── cluster.zig           # Multi-node config
│   ├── gateway/
│   │   └── order.zig         # Cross-module order aggregation
│   └── modules/
│       ├── order/
│       │   ├── events.zig    # OrderCreated, OrderShipped
│       │   └── saga.zig      # PlaceOrder saga
│       ├── product/
│       ├── user/
│       └── ...
├── docker-compose.yml        # 3-node cluster
└── init.sql                  # 152-table schema
```
