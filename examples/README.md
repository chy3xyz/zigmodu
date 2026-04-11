# ZigModu Examples

This directory contains comprehensive examples demonstrating various features of ZigModu.

## 📚 Example Index

### 1. Basic Example (`examples/basic`)
**Demonstrates**: Core module system features

- Module definition with dependencies
- Application initialization
- Dependency validation
- Lifecycle management (init/deinit)
- Topological ordering

**Key Concepts**:
```zig
const MyModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "my-module",
        .dependencies = &."other-module"},
    };
};

var app = try zigmodu.Application.init(allocator, "app", .{MyModule}, .{});
try app.start();
```

**Run**: `cd examples/basic && zig build run`

---

### 2. Event-Driven Example (`examples/event-driven`)
**Demonstrates**: Publish-subscribe event pattern

- Domain events definition
- EventBus usage
- Multiple subscribers
- Decoupled communication

**Key Concepts**:
```zig
const OrderCreated = struct {
    order_id: u64,
    total: f64,
};

var bus = EventBus(OrderCreated).init(allocator);
try bus.subscribe(handleOrderCreated);
bus.publish(.{ .order_id = 123, .total = 99.99 });
```

**Run**: `cd examples/event-driven && zig build run`

---

### 3. Dependency Injection (`examples/dependency-injection`)
**Demonstrates**: Container and service management

- Service registration
- Type-safe retrieval
- Dependency resolution
- Scoped containers

**Key Concepts**:
```zig
var container = Container.init(allocator);
try container.register(Database, "db", &db);
const db = container.get(Database, "db");
```

**Run**: `cd examples/dependency-injection && zig build run`

---

### 4. Testing Example (`examples/testing`)
**Demonstrates**: Module testing and mocking

- ModuleTestContext
- Mock modules
- Test lifecycle
- Assertion patterns

**Key Concepts**:
```zig
var ctx = try ModuleTestContext.init(allocator, "test-module");
try ctx.start();
// Test logic
ctx.stop();
```

**Run**: `cd examples/testing && zig build test`

---

### 5. Architecture Validation (`examples/architecture`)
**Demonstrates**: Architecture testing and rules

- Dependency validation
- Cycle detection
- Custom architecture rules
- Documentation generation

**Key Concepts**:
```zig
var tester = ArchitectureTester.init(allocator, &modules);
try tester.ruleNoCircularDependencies();
try tester.ruleLimitedDependencies(5);
```

**Run**: `cd examples/architecture && zig build run`

---

### 6. Complete Application (`examples/ecommerce`)
**Demonstrates**: Real-world complex application

- Multiple modules
- Event-driven architecture
- DI container
- Configuration management
- Testing strategy

**Features**:
- User management
- Product catalog
- Shopping cart
- Order processing
- Payment handling
- Inventory management

**Run**: `cd examples/ecommerce && zig build run`

---

## 🚀 Quick Start

### Prerequisites
- Zig 0.15.2 or later
- Git

### Running Examples

```bash
# Clone the repository
git clone https://github.com/yourusername/zigmodu.git
cd zigmodu

# Run basic example
cd examples/basic
zig build run

# Run all tests
cd ../..
zig build test

# Run specific example test
cd examples/testing
zig build test
```

---

## 📖 Learning Path

### Beginner
1. Start with **Basic Example** to understand core concepts
2. Read the module definition patterns
3. Understand dependency validation

### Intermediate
4. Explore **Event-Driven Example** for decoupled architecture
5. Study **DI Example** for service management
6. Review **Testing Example** for quality assurance

### Advanced
7. Implement **Architecture Validation** in your project
8. Build a **Complete Application** using all features
9. Contribute new examples!

---

## 🎯 Example Patterns

### Pattern 1: Simple Module
```zig
const SimpleModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "simple",
        .description = "A simple module",
        .dependencies = &.{},
    };

    pub fn init() !void {
        std.log.info("Simple module initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("Simple module cleaned up", .{});
    }
};
```

### Pattern 2: Module with Dependencies
```zig
const DependentModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "dependent",
        .description = "Depends on other modules",
        .dependencies = &.{"simple"},
    };

    pub fn init() !void {
        // Can access SimpleModule
        std.log.info("Dependent module initialized", .{});
    }
};
```

### Pattern 3: Event-Driven Module
```zig
const EventModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "eventful",
        .dependencies = &.{},
    };

    pub fn processEvent(event: MyEvent) void {
        // Handle event
    }
};
```

---

## 🔧 Common Tasks

### Adding a New Example

1. Create directory: `mkdir examples/my-example`
2. Create `build.zig`:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my-example",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zigmodu dependency
    const zigmodu_dep = b.dependency("zigmodu", .{});
    exe.root_module.addImport("zigmodu", zigmodu_dep.module("zigmodu"));

    b.installArtifact(exe);
}
```

3. Create `src/main.zig`
4. Add to examples index
5. Submit PR

### Updating Examples

When updating ZigModu API:
1. Update all examples
2. Run `zig build test` in each
3. Update documentation
4. Test manually

---

## 🐛 Troubleshooting

### Common Issues

**Q: Module not found?**
```
error: Module 'xxx' not found
```
A: Ensure the module is listed in Application.init()

**Q: Circular dependency?**
```
error: Circular dependency detected
```
A: Check dependency declarations and remove cycles

**Q: Compilation errors in examples?**
```
error: expected type 'xxx', found 'yyy'
```
A: Update to latest ZigModu version

---

## 🤝 Contributing

Want to add an example?

1. Check if similar example exists
2. Follow existing patterns
3. Include README.md
4. Add to this index
5. Submit PR

### Example Template

```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

// ============================================
// Example: [Name]
// ============================================
// Demonstrates: [What it shows]

const Module1 = struct {
    pub const info = zigmodu.api.Module{
        .name = "module1",
        .dependencies = &.{},
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    var app = try zigmodu.Application.init(gpa.allocator(), "example", .{Module1}, .{});
    defer app.deinit();
    
    try app.start();
    std.log.info("Example completed!", .{});
}
```

---

## 📚 Additional Resources

- [API Documentation](../docs/API.md)
- [Quick Start Guide](../QUICK-START.md)
- [Spring Modulith Comparison](../docs/SPRING_MODULITH_COMPARISON.md)
- [Contributing Guide](../CONTRIBUTING.md)

---

## 📊 Example Statistics

| Example | Lines | Complexity | Status |
|---------|-------|------------|--------|
| Basic | 150 | Beginner | ✅ Ready |
| Event-Driven | 200 | Intermediate | ✅ Ready |
| DI | 180 | Intermediate | ✅ Ready |
| Testing | 120 | Intermediate | ✅ Ready |
| Architecture | 160 | Advanced | 🚧 WIP |
| E-commerce | 500+ | Advanced | 🚧 WIP |

---

*Last updated: 2025-01-09*
