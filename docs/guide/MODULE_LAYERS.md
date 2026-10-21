# Domain Layering Guide (`model` / `persistence` / `service` / `api`)

Applies to: zmodu v0.14+ · Zig 0.17  
Reference implementations: [`examples/tenant-shop/`](../../examples/tenant-shop/) (SQLx) · [`examples/zent-modulith/`](../../examples/zent-modulith/) (zent ORM)

## 1. Layer Responsibilities

| Layer | Responsibilities | Disallowed |
|-------|------------------|------------|
| **model** | Row structs, `sql_table_name`, `sql_tenant_column`, enum conversions, pure calculations | SQL queries, HTTP types, transactions |
| **persistence** | Parameterized SQL queries, tenant filtering, `pub const Tx` unit-of-work helpers | Business branching, starting transactions, reading clocks |
| **service** | Input validation, orchestration, `beginTx`, outbox writes, `Cmd` / `Result` types | Raw multi-line SQL, accessing `http.Context` |
| **api / BFF** | Request extraction, reading auth attributes, error mapping, `ctx.jsonStruct` | Business logic, direct persistence calls, raw SQL |

## 2. Model Layer (`model.zig`)

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
    pub const sql_tenant_column: ?[]const u8 = "tenant_id";
};
```

Conventions:
- Declare `pub const sql_tenant_column: ?[]const u8 = "tenant_id"` on multi-tenant models so unscoped queries fail at compile time unless explicitly calling `*Unscoped` methods.
- Document string ownership: strings scanned via `queryRowPartial` / `queryRowsPartial` are owned by the caller's allocator; strings from `queryRowPartialBorrowed` are valid only within the `BorrowedRow(T)` scope.
- Keep pure domain calculations (such as `available = qty - reserved`) on the model struct rather than in HTTP handlers.

## 3. Persistence Layer (`persistence.zig`)

### 3.1 Repository & Query Methods

```zig
pub fn ProductPersistence(comptime Backend: type) type {
    return struct {
        db: Backend,

        pub fn init(db: Backend) @This() {
            return .{ .db = db };
        }

        pub fn findById(self: *@This(), tenant_id: i64, id: i64) !?model.Product {
            return self.db.queryRowPartial(
                model.Product,
                "SELECT id, tenant_id, name, price_cents, status, created_at, updated_at FROM products WHERE tenant_id = ? AND id = ?",
                &.{ .{ .int = tenant_id }, .{ .int = id } },
            ) catch |err| switch (err) {
                error.NotFound => null,
                else => err,
            };
        }
    };
};
```

Naming conventions:
- `find*`: Returns `!?T` (`error.NotFound` mapped to `null`).
- `get*` / `list*`: Returns `!T` or `![]T`.
- For tenant-scoped tables, `tenant_id` is always the first business parameter after `self`.

### 3.2 Cross-Module Transactions (`pub const Tx`)

When a workflow spans multiple tables across modules in a single database transaction (e.g., checkout reserving inventory and creating an order), expose stateless SQL helpers on `pub const Tx`:

```zig
// inventory/persistence.zig
pub const Tx = struct {
    pub fn reserve(
        tx: *data.sqlx.Transaction,
        tenant_id: i64,
        product_id: i64,
        qty: i64,
        now: i64,
    ) !void {
        _ = tx; _ = tenant_id; _ = product_id; _ = qty; _ = now;
    }
};
```

The orchestrating service imports the sibling module's `persistence.Tx` and runs all steps on the same `Transaction`:

```zig
// order/service.zig
try inventory_persist.Tx.reserve(&tx, cmd.tenant_id, cmd.product_id, cmd.qty, now);
const order_id = try order_persist.Tx.insertOrder(&tx, cmd, now);
try outbox_write.insertPending(&tx, cmd.tenant_id, "order.created", payload, now);
try cart_persist.Tx.clearItems(&tx, cmd.tenant_id, cmd.user_id);
try tx.commit();
```

Rules for `Tx`:
- `Tx` functions execute parameterized SQL and check affected rows; business validation stays in `service.zig`.
- Never import another module's non-`Tx` persistence methods to bypass its service layer.

## 4. Service Layer (`service.zig`)

### 4.1 Command and Result Structs

Group workflow parameters into explicit `Cmd` and `Result` structs rather than long positional argument lists:

```zig
pub const CheckoutCmd = struct {
    tenant_id: i64,
    user_id: i64,
};

pub const CheckoutResult = struct {
    order_id: i64,
};

pub fn checkout(self: *Self, cmd: CheckoutCmd) !CheckoutResult {
    var tx = try self.db.beginTx();
    errdefer tx.rollback() catch |err| std.log.err("[order] rollback failed: {}", .{err});

    const now: i64 = @intCast(zmodu.Time.wallClockSeconds(self.io));
    const order_id = try order_persist.Tx.insertOrder(&tx, cmd, now);
    try tx.commit();
    return .{ .order_id = order_id };
}
```

### 4.2 Zero-Boilerplate CRUD (`data.CrudService`)

For standard CRUD modules without custom workflow orchestration, embed `zmodu.data.CrudService(Entity, Persistence)`:

```zig
pub const OrdersService = struct {
    pub const module_name = "orders";
    pub const nest = .{"orders"};
    pub const impl = zmodu.data.CrudService(model.Orders, persistence.OrdersPersistence);
    crud: impl,

    pub fn init(p: *persistence.OrdersPersistence) @This() {
        return .{ .crud = impl.init(p) };
    }
};
```

Write operations on `CrudService` automatically publish `CrudEvent{ .created, .updated, .deleted }` when an event bus is attached.

## 5. API / BFF Layer (`api.zig`)

- Depend only on `service.zig`, never on `persistence.zig`.
- Map internal models to response DTOs via `http.Extract.toDto` / `respondDto` to avoid leaking internal columns.
- BFF modules (`shop_bff`, `admin_bff`) aggregate multiple domain services and own no database tables.

## 6. Module State Hygiene

Allocate module state per `Application` instance via `ctx.state(T)` in `initWith` or pass state pointers through `ComptimeRouter` `State`. If a module uses file-scope synchronization primitives (such as latches in multi-phase harnesses), reset all fields in `deinit()` so subsequent runs in the same process do not inherit stale state.

## Checklist

- [ ] Every domain module has `model.zig`, `persistence.zig`, `service.zig`, `api.zig`, and `module.zig`.
- [ ] Multi-table workflows use `persistence.Tx` helpers inside `service.zig`.
- [ ] All tenant-scoped models declare `pub const sql_tenant_column` and filter by `tenant_id`.
- [ ] Outbox records are inserted inside the same database transaction as the business write.
