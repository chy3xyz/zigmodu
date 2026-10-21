# Events & Dependency Injection

Applies to: zmodu v0.15.34+ · Zig 0.17

`Application` includes a built-in `EventRegistry` and `di.Container`. They provide three structural guarantees:
1. **Thread safety**: `app.eventBus(T)` returns `*ThreadSafeEventBus(T)`.
2. **Fail-fast startup**: Modules resolve required services inside `initWith(ctx)` during `app.start()`.
3. **Lock-free runtime reads**: `app.start()` freezes the DI container after module initialization; subsequent `register` calls return `error.ContainerFrozen`.

## 1. Lifecycle Overview

```text
main (Bootstrap)               Module (initWith)               Runtime / Handlers
----------------               -----------------               ------------------
builder.withService(...)  -->  ctx.service(T, name)       -->  app.service(T, name) (read-only)
app.eventBus(T)           -->  ctx.eventBus(T)            -->  bus.publish(event)
bus.subscribe(listener)        register module services        Container is frozen
```

## 2. Wiring Services and Events

### 2.1 Module Initialization (`initWith`)

Modules can declare `initWith(ctx: *zmodu.ModuleContext)` instead of `init()` to access the application's DI container, event buses, `allocator`, and `io`:

```zig
pub fn initWith(ctx: *zmodu.ModuleContext) !void {
    const bus = try ctx.eventBus(OrderEvent);
    const cfg = ctx.service(AppConfig, "config") orelse return error.MissingService;
    _ = bus;
    _ = cfg;
}
```

- If both `init` and `initWith` are declared, `Application.start()` calls `initWith`.
- Modules that only declare `initWith` require an `Application` (or `Lifecycle.startAllWith` in unit tests).

### 2.2 Application Bootstrap (`main.zig`)

Register shared infrastructure with `withService` (or batch register with `withServices`):

```zig
var db: Db = .{ .connected = true };
var cache: Cache = .{};

var b = zmodu.builder(allocator, io);
defer b.deinit();
_ = try b.withServices(.{
    .{ .name = "db", .instance = &db },
    .{ .name = "cache", .instance = &cache },
});
var app = try b.withName("shop")
    .build(.{ UserModule, OrderModule });
defer app.deinit();

try app.start(); // Runs initWith() on each module, then freezes the container
defer app.stop();

const order_bus = try app.eventBus(order_mod.service.OrderEvent);
try order_bus.subscribe(auditListener);
order_svc.withEvents(order_bus);
```

### 2.3 Publishing Events from a Service

Define events as a tagged union in `service.zig` and inject the bus explicitly:

```zig
pub const OrderEvent = union(enum) {
    created: struct { id: i64, total: f64 },
    updated: struct { id: i64 },
    deleted: struct { id: i64 },
};

event_bus: ?*zmodu.ThreadSafeEventBus(OrderEvent) = null,

pub fn withEvents(self: *Self, bus: *zmodu.ThreadSafeEventBus(OrderEvent)) void {
    self.event_bus = bus;
}

// After committing a write:
if (self.event_bus) |bus| {
    bus.publish(.{ .created = .{ .id = id, .total = total } });
}
```

## 3. DI Container Rules

### 3.1 Ownership (`register` vs `registerBorrowed`)

| Method | Ownership | Use Case |
|--------|-----------|----------|
| `register(T, name, ptr)` | Container owns `ptr` and destroys it on `deinit` | Heap objects created specifically for the container |
| `registerBorrowed(T, name, ptr)` | Caller retains ownership; container never frees `ptr` | Stack variables in `main`, long-lived pools, `builder.withService` |

`builder.withService` and `builder.withServices` always use borrowed registration. Ensure borrowed instances outlive `Application`.

### 3.2 Scoped Containers (`zmodu.ScopedContainer`)

For short-lived scopes that inherit from a parent container:
- `get` and `contains` fall back to `parent` if not found in the child scope.
- `register`, `registerBorrowed`, `remove`, and `serviceCount` operate only on the child scope and never mutate `parent`.

### 3.3 Container Scope Boundaries

- **Store in Container**: Process-wide infrastructure singletons (`config`, database client/pool, Redis client).
- **Do not store in Container**: Per-request state (use `http.Context` attributes or request arena) or cross-module service dependencies (pass those explicitly via `Service.init(&dep)` and declare them in `Module.info.dependencies`).

## 4. EventBus Rules

| Do | Don't |
|----|-------|
| Obtain buses via `app.eventBus(T)` or `ctx.eventBus(T)` | Instantiate a private `EventBus(T).init(...)` in each module |
| Define events as value-type unions carrying IDs and facts | Pass ORM entity pointers or database connections inside events |
| Keep listeners fast or write to the transactional outbox | Run slow blocking I/O inside synchronous `publish` listeners |
| Use `persistence.Tx` for atomic multi-table writes | Use in-memory events when atomic rollback is required |

### Delivery Semantics

- `ThreadSafeEventBus.publish` invokes listeners synchronously in the caller's thread with no persistence or retry.
- For guaranteed delivery across crashes, write to the transactional outbox (`zmodu.outbox.*`) inside the database transaction.
- For high-frequency, zero-allocation worker fan-out on the execution plane, use `runtime.HotBus(E, N)` instead (see [Runtime Reference](../reference/RUNTIME.md)).

## 5. Unit Testing Event Publishers

```zig
test "order service publishes created event" {
    const allocator = std.testing.allocator;
    var registry = zmodu.EventRegistry.init(allocator, std.testing.io);
    defer registry.deinit();

    const bus = try registry.bus(OrderEvent);
    var received: ?OrderEvent = null;
    try bus.subscribe(struct {
        fn capture(e: OrderEvent) void {
            received = e;
        }
    }.capture);

    var svc = OrderService.init(&persist);
    svc.withEvents(bus);
    _ = try svc.create(1, "item", 100);

    try std.testing.expect(received != null);
}
```
