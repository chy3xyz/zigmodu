# Architecture Guide

## Overview

ZigModu is designed around the concept of **modular architecture**, where an application is composed of loosely coupled, highly cohesive modules. This guide explains the architectural decisions and how to effectively use ZigModu in your projects.

## Core Concepts

### What is a Module?

A module in ZigModu is:
- A logical unit of functionality
- A collection of related features
- An independently deployable unit (in theory)
- A namespace for related code

### Module Characteristics

```
┌─────────────────────────────────────┐
│           Module                    │
├─────────────────────────────────────┤
│  • Public API (exports)             │
│  • Internal Implementation          │
│  • Dependencies (other modules)     │
│  • Lifecycle (init/deinit)          │
│  • Configuration                    │
│  • Events (in/out)                  │
└─────────────────────────────────────┘
```

## System Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────┐
│                    Application                           │
├─────────────────────────────────────────────────────────┤
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐   │
│  │ Module A │  │ Module B │  │ Module C │  │ Module D │   │
│  │         │  │         │  │         │  │         │   │
│  │ • API   │  │ • API   │  │ • API   │  │ • API   │   │
│  │ • Impl  │  │ • Impl  │  │ • Impl  │  │ • Impl  │   │
│  │ • Tests │  │ • Tests │  │ • Tests │  │ • Tests │   │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘   │
│       │            │            │            │         │
│       └────────────┴────────────┴────────────┘         │
│                    Event Bus                             │
└─────────────────────────────────────────────────────────┘
```

### Layered Architecture

```
┌─────────────────────────────────────┐
│  Application Layer (main.zig)       │
│  - Module composition               │
│  - Configuration                    │
│  - Bootstrap                        │
├─────────────────────────────────────┤
│  Module Layer (modules/*.zig)       │
│  - Business logic                   │
│  - Module API                       │
│  - Event handlers                   │
├─────────────────────────────────────┤
│  Framework Layer (zigmodu)          │
│  - Module management                │
│  - Event bus                        │
│  - DI container                     │
│  - Lifecycle management             │
├─────────────────────────────────────┤
│  Infrastructure Layer               │
│  - std library                      │
│  - External dependencies            │
└─────────────────────────────────────┘
```

## Module Communication

### Dependency-Based Communication

```
Order Module ──────► Inventory Module
      │                      │
      │ depends on           │
      │                      │
      └──────────────────────┘
         Direct API calls
```

### Event-Based Communication

```
Order Module         Inventory Module
     │                       │
     │  OrderCreatedEvent    │
     ├──────────────────────►│
     │                       │
     │  StockReservedEvent   │
     │◄──────────────────────┤
     │                       │
```

### Comparison

| Aspect | Direct Dependencies | Event-Based |
|--------|-------------------|-------------|
| Coupling | Tight | Loose |
| Latency | Immediate | Async |
| Complexity | Simple | More complex |
| Testing | Mock dependencies | Subscribe to events |
| Use case | Core dependencies | Cross-cutting concerns |

## Dependency Management

### Valid Dependency Patterns

```
✅ Valid:
   User ──► Order ──► Payment

✅ Valid:
   Inventory ◄── Order
   Payment   ◄── Order

❌ Invalid (Circular):
   A ──► B ──► C ──► A
```

### Dependency Declaration

```zig
// Good: Explicit dependencies
pub const info = api.Module{
    .name = "order",
    .dependencies = &."user", "inventory" },
};

// Good: No dependencies for base modules
pub const info = api.Module{
    .name = "user",
    .dependencies = &.{},
};
```

## Lifecycle Management

### Module Lifecycle

```
┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
│ Created │────►│  Init   │────►│ Running │────►│  Stop   │────►│Cleaned Up│
└─────────┘     └─────────┘     └─────────┘     └─────────┘     └─────────┘
     │               │               │               │               │
     │               │               │               │               │
  scanModules()  startAll()      Operating      stopAll()      deinit()
```

### Lifecycle Hooks

```zig
pub fn init() !void {
    // Called during startAll()
    // - Allocate resources
    // - Connect to databases
    // - Subscribe to events
    // - Initialize caches
}

pub fn deinit() void {
    // Called during stopAll()
    // - Free resources
    // - Close connections
    // - Unsubscribe from events
    // - Flush caches
}
```

### Error Handling in Lifecycle

```zig
pub fn init() !void {
    // If init fails, the module won't be marked as started
    // Other modules that depend on it will fail to start
    
    db_connection = try Database.connect();
    errdefer db_connection.close();
    
    cache = try Cache.init(allocator);
    errdefer cache.deinit();
    
    try event_bus.subscribe(handleEvent);
}
```

## Memory Management

### Ownership Model

```
Application (owner)
    │
    ├──► ApplicationModules (manages modules)
    │       └──► ModuleInfo (references)
    │
    ├──► EventBus (manages listeners)
    │       └──► Listener functions
    │
    ├──► Container (manages services)
    │       └──► Service pointers (not owners!)
    │
    └──► Services (owned by application)
            └──► Database, Cache, etc.
```

### Best Practices

1. **Explicit Allocators**: Always pass allocators explicitly
2. **Defer Cleanup**: Use `defer` for resource cleanup
3. **No Hidden Allocations**: Framework avoids hidden allocations
4. **Service Ownership**: DI container stores pointers, not owners

```zig
// Good: Explicit ownership
var db = try Database.init(allocator);
defer db.deinit();

try container.register("database", &db);

// Bad: Hidden allocation
// try container.createAndRegister("database", Database);
```

## Testing Strategy

### Unit Testing

Test individual modules in isolation:

```zig
test "order module - calculate total" {
    const order = Order{
        .items = &[_]Item{
            .{ .price = 10.0, .quantity = 2 },
            .{ .price = 5.0, .quantity = 1 },
        },
    };
    
    const total = order.calculateTotal();
    try std.testing.expectEqual(@as(f64, 25.0), total);
}
```

### Integration Testing

Test module interactions:

```zig
test "order -> inventory integration" {
    var ctx = try ModuleTestContext.init(allocator, "order");
    defer ctx.deinit();
    
    // Mock inventory module
    const mock_inventory = createMockModule(
        "inventory",
        "Mock inventory",
        &.{},
    );
    try ctx.registerMockModule(mock_inventory);
    
    try ctx.start();
    defer ctx.stop();
    
    // Test order creation affects inventory
}
```

### End-to-End Testing

Test the full application:

```zig
test "full application" {
    var modules = try scanModules(allocator, .{
        user_module,
        order_module,
        payment_module,
    });
    defer modules.deinit();
    
    try validateModules(&modules);
    try startAll(&modules);
    defer stopAll(&modules);
    
    // Run full workflow tests
}
```

## Performance Considerations

### Compile-Time Optimizations

- Module scanning happens at compile time
- No runtime reflection
- Static dispatch for events
- Zero-cost abstractions

### Runtime Performance

```
Operation                    Complexity
─────────────────────────────────────────
Module registration          O(1)
Dependency lookup            O(1)  (hash map)
Event publish                O(n)  (n = listeners)
Service retrieval (DI)       O(1)  (hash map)
Documentation generation     O(m)  (m = modules)
```

### Memory Usage

```
Per Module:
- ModuleInfo: ~64 bytes + strings
- Dependencies: ~8 bytes per dependency
- Event listeners: ~8 bytes per listener

Example: 100 modules, avg 3 deps each
≈ 100 * (64 + 24) = 8.8 KB + strings
```

## Scalability Patterns

### Horizontal Scaling

Modules can be distributed across processes:

```
Process 1              Process 2              Process 3
┌─────────┐           ┌─────────┐           ┌─────────┐
│ Module A │◄────────►│ Module B │◄────────►│ Module C │
│ Module D │   IPC    │ Module E │   IPC    │ Module F │
└─────────┘           └─────────┘           └─────────┘
```

### Lazy Loading

Modules can be loaded on demand:

```zig
pub fn init() !void {
    // Only initialize heavy resources when needed
    if (config.lazy_loading) {
        return; // Defer to first use
    }
    
    try initializeHeavyResources();
}
```

## Anti-Patterns

### ❌ Circular Dependencies

```zig
// BAD: Circular dependency
// A depends on B, B depends on A
pub const info = api.Module{
    .name = "a",
    .dependencies = &."b" },
};

pub const info = api.Module{
    .name = "b",
    .dependencies = &."a" ],
};
```

**Solution**: Introduce an abstraction or merge modules.

### ❌ God Modules

```zig
// BAD: Module does everything
pub const info = api.Module{
    .name = "god_module",
    .dependencies = &."db", "cache", "http", "email", "queue" },
};
```

**Solution**: Split into focused modules.

### ❌ Leaky Abstractions

```zig
// BAD: Exposing internal types in public API
pub const InternalDatabaseConnection = struct { ... };

pub fn getConnection() InternalDatabaseConnection { ... }
```

**Solution**: Define public types, hide implementation details.

## Migration Guide

### From Monolith to Modular

1. **Identify boundaries**: Find natural seams in your code
2. **Extract modules**: Move related code into module files
3. **Define APIs**: Create clean public interfaces
4. **Manage dependencies**: Explicitly declare dependencies
5. **Add lifecycle**: Implement init/deinit hooks
6. **Test incrementally**: Ensure each module works independently

### Example Migration

```
Before:
src/
├── main.zig
├── user.zig
├── order.zig
├── payment.zig
└── utils.zig

After:
src/
├── main.zig
└── modules/
    ├── user/
    │   ├── module.zig
    │   ├── api.zig
    │   └── internal.zig
    ├── order/
    │   ├── module.zig
    │   ├── api.zig
    │   └── internal.zig
    └── payment/
        ├── module.zig
        ├── api.zig
        └── internal.zig
```

## Conclusion

ZigModu's architecture promotes:
- **Modularity**: Clear boundaries and responsibilities
- **Testability**: Easy to test in isolation
- **Maintainability**: Changes are localized
- **Scalability**: Grow your application incrementally

By following these architectural principles, you can build robust, maintainable applications with ZigModu.