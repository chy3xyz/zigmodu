# ZigModu

[![Zig Version](https://img.shields.io/badge/Zig-0.15.2-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/yourusername/zigmodu/workflows/CI/badge.svg)](https://github.com/yourusername/zigmodu/actions)

> A modular application framework for Zig, inspired by Spring Modulith

[English](README.md) | [中文](README.zh.md)

## Overview

ZigModu is a modular application framework for Zig 0.15.2 that brings the power of modular architecture to the Zig ecosystem. It provides compile-time module validation, dependency injection, event-driven communication, and automatic documentation generation.

### Key Features

- 🏗️ **Modular Architecture** - Define modules with explicit dependencies
- ✅ **Compile-time Validation** - Module dependencies checked at compile time
- 🔄 **Event Bus** - Type-safe inter-module communication
- 📝 **Auto Documentation** - Generate PlantUML diagrams from module structure
- 💉 **Dependency Injection** - Simple DI container for service management
- ⚡ **Zero Runtime Overhead** - Compile-time module scanning
- 🧪 **Testing Support** - Module-level testing utilities
- 📊 **Observability** - Module-specific logging and lifecycle tracking

## Quick Start

### Installation

Add ZigModu to your `build.zig.zon`:

```zig
.{
    .name = "my-app",
    .version = "0.1.0",
    .dependencies = .{
        .zigmodu = .{
            .url = "https://github.com/yourusername/zigmodu/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...",
        },
    },
}
```

### Define a Module

```zig
const api = @import("zigmodu").api;

pub const info = api.Module{
    .name = "order",
    .description = "Order management module",
    .dependencies = &.{"inventory"},  // Depends on inventory module
};

pub fn init() !void {
    std.log.info("Order module initialized", .{});
}

pub fn deinit() void {
    std.log.info("Order module cleaned up", .{});
}
```

### Create Application

```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

const order = @import("modules/order.zig");
const inventory = @import("modules/inventory.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Scan modules
    var modules = try zigmodu.scanModules(allocator, .{ order, inventory });
    defer modules.deinit();

    // 2. Validate dependencies
    try zigmodu.validateModules(&modules);

    // 3. Generate documentation
    try zigmodu.generateDocs(&modules, "docs/modules.puml", allocator);

    // 4. Start all modules
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);

    std.log.info("Application started successfully!", .{});
}
```

### Run the Application

```bash
$ zig build run
info: ✅ All module dependencies validated
info: Order module initialized
info: Inventory module initialized
info: ✅ All modules started
info: Application started successfully!
info: Order module cleaned up
info: Inventory module cleaned up
info: ✅ All modules stopped
```

## Project Structure

```
my-app/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig
│   └── modules/
│       ├── order.zig
│       ├── inventory.zig
│       └── payment.zig
└── docs/
    └── modules.puml
```

## Documentation

- [API Reference](docs/API.md)
- [Architecture Guide](docs/ARCHITECTURE.md)
- [Examples](examples/)
- [Contributing](CONTRIBUTING.md)

## Core Concepts

### Module Definition

Each module is a Zig file that exports:
- `info`: Module metadata (name, description, dependencies)
- `init()`: Optional initialization function
- `deinit()`: Optional cleanup function

### Dependency Validation

ZigModu validates module dependencies at two levels:
1. **Compile-time**: Type checking of module references
2. **Runtime**: Verification that all dependencies exist

### Event Bus

Communicate between modules using type-safe events:

```zig
const EventBus = @import("zigmodu").EventBus;

const OrderEvent = struct {
    order_id: u64,
    status: OrderStatus,
};

var bus = EventBus(OrderEvent).init(allocator);
defer bus.deinit();

// Subscribe
try bus.subscribe(handleOrderEvent);

// Publish
bus.publish(.{ .order_id = 123, .status = .confirmed });
```

### Dependency Injection

```zig
const Container = @import("zigmodu").extensions.Container;

var container = Container.init(allocator);
defer container.deinit();

// Register service
var db = Database.init(allocator);
try container.register("database", &db);

// Retrieve service
const db_ptr = container.getTyped("database", Database);
```

## Testing

Run the test suite:

```bash
$ zig build test
```

Module-level testing:

```zig
const ModuleTestContext = @import("zigmodu").extensions.ModuleTestContext;

test "order module" {
    var ctx = try ModuleTestContext.init(allocator, "order");
    defer ctx.deinit();
    
    try ctx.start();
    // Test your module...
    ctx.stop();
}
```

## Benchmarks

```bash
$ zig build benchmark
```

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by [Spring Modulith](https://spring.io/projects/spring-modulith)
- Built with [Zig](https://ziglang.org/) 0.15.2
- Uses [zio](https://github.com/lalinsky/zio) for async runtime

## Roadmap

- [ ] YAML/TOML configuration support
- [ ] Module hot-reloading
- [ ] Distributed event bus
- [ ] Web interface for module monitoring
- [ ] Plugin system

---

**Made with ❤️ by the ZigModu team**