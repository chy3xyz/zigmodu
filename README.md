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
- 🌐 **Distributed Event Bus** - Cross-node event communication via TCP
- 📝 **Auto Documentation** - Generate PlantUML diagrams from module structure
- 💉 **Dependency Injection** - Simple DI container for service management
- 🔌 **Plugin System** - Dynamic plugin loading framework
- 🔄 **Hot Reloading** - File watching and module reloading
- 🌐 **Web Monitor** - HTTP interface for module monitoring
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

## Examples

- [basic](examples/basic/) - Basic module usage
- [event-driven](examples/event-driven/) - Event bus communication
- [dependency-injection](examples/dependency-injection/) - DI container usage
- [distributed-events](examples/distributed-events/) - Distributed event bus (NEW!)
- [v2-showcase](examples/v2-showcase/) - v0.2.0 feature showcase: Simplified API, Distributed Event Bus, Web Monitor, Plugin System, Hot Reloading
- [metaverse-creative](examples/metaverse-creative/) - Complex modular application

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

### Distributed Event Bus

Communicate across multiple nodes in a cluster:

```zig
const DistributedEventBus = @import("zigmodu").DistributedEventBus;

var bus = DistributedEventBus.init(allocator);
defer bus.deinit();

// Start listening for connections
try bus.start(8080);

// Subscribe to events
try bus.subscribe("order.created", handleOrderEvent);

// Publish to all connected nodes
try bus.publish("order.created", "{\"order_id\": 123}");

// Connect to remote node
const addr = try std.net.Address.parseIp4("192.168.1.100", 8080);
try bus.connectToNode("node-2", addr);
```

### Web Monitor

HTTP interface for real-time module monitoring:

```zig
const WebMonitor = @import("zigmodu").WebMonitor;

var monitor = WebMonitor.init(allocator, 3000);
defer monitor.deinit();

// Start web server
try monitor.start(&modules);

// Access endpoints:
// GET /           - Dashboard
// GET /api/modules    - List all modules (JSON)
// GET /api/health     - Health check
// GET /api/metrics    - System metrics
```

### Plugin System

Dynamic plugin loading framework:

```zig
const PluginManager = @import("zigmodu").PluginManager;

var plugins = PluginManager.init(allocator, "./plugins");
defer plugins.deinit();

// Load all plugins from directory
try plugins.loadAllPlugins();

// Enable/disable plugins
try plugins.enablePlugin("my-plugin");
try plugins.disablePlugin("my-plugin");

// Check status
if (plugins.isPluginEnabled("my-plugin")) {
    // Plugin is active
}
```

### Hot Reloading

Watch files for changes and reload modules:

```zig
const HotReloader = @import("zigmodu").HotReloader;

var reloader = HotReloader.init(allocator);
defer reloader.deinit();

// Watch module directory
try reloader.watchPath("./src/modules");

// Set change callback
reloader.onChange(onModuleChanged);

// Start watching
try reloader.startWatching();

fn onModuleChanged(path: []const u8) void {
    std.log.info("Module changed: {s}", .{path});
    // Trigger reload
}
```

### YAML/TOML Configuration

Load configuration from YAML or TOML files:

```zig
const YamlParser = @import("zigmodu").YamlParser;
const TomlParser = @import("zigmodu").TomlParser;

var yaml = YamlParser.init(allocator);
var yaml_config = try yaml.parseFile("config.yaml");
defer yaml.deinitMap(&yaml_config);

var toml = TomlParser.init(allocator);
var toml_config = try toml.parseFile("config.toml");
defer toml.deinitMap(&toml_config);

const host = yaml_config.get("server.host");
const db_url = toml_config.get("database.url");
```

### WebSocket Real-Time Monitoring

Push real-time updates to connected clients:

```zig
const WebSocketMonitor = @import("zigmodu").WebSocketMonitor;

var ws = WebSocketMonitor.init(allocator, 8080);
defer ws.deinit();

try ws.start(&modules);

// Broadcast JSON updates to all connected clients
ws.ws_server.broadcast("{\"type\":\"metrics\",\"module_count\":5}");
```

### Cluster Membership

Gossip-based cluster membership with leader election:

```zig
const ClusterMembership = @import("zigmodu").ClusterMembership;

var bus = DistributedEventBus.init(allocator);
var cluster = try ClusterMembership.init(allocator, "node-1", address, &bus);

try cluster.start(.{});
try cluster.connectToSeed("node-2", seed_address);

if (cluster.isLeader()) {
    // Only leader performs coordination tasks
}
```

### Distributed Transactions

Two-Phase Commit (2PC) and Saga pattern support:

```zig
const TwoPhaseCommit = @import("zigmodu").TwoPhaseCommit;
const DistributedTransactionManager = @import("zigmodu").DistributedTransactionManager;

// 2PC Coordinator
var tpc = TwoPhaseCommit.init(allocator);
defer tpc.deinit();

try tpc.createCoordinator("tx-1");
try tpc.addParticipant("tx-1", "db-1", prepareFn, commitFn, rollbackFn);
try tpc.execute("tx-1");

// Saga pattern
var dtm = DistributedTransactionManager.init(allocator);
defer dtm.deinit();

const tx_id = try dtm.beginTransaction();
try dtm.addStep(tx_id, "deductInventory", deductFn, compensateDeductFn);
try dtm.addStep(tx_id, "chargePayment", chargeFn, compensateChargeFn);
try dtm.execute(tx_id);
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

- [x] ~~Module hot-reloading~~ ✅ Implemented
- [x] ~~Distributed event bus~~ ✅ Implemented  
- [x] ~~Web interface for module monitoring~~ ✅ Implemented
- [x] ~~Plugin system~~ ✅ Implemented
- [x] ~~YAML/TOML configuration support~~ ✅ Implemented
- [x] ~~WebSocket support for real-time monitoring~~ ✅ Implemented
- [x] ~~Cluster membership service~~ ✅ Implemented
- [x] ~~Distributed transactions~~ ✅ Implemented
- [ ] Raft consensus for cluster coordination
- [ ] GraphQL API gateway
- [ ] Service mesh integration

---

**Made with ❤️ by the ZigModu team**