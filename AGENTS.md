# ZigModu Framework Agent Guide

## Project Overview
ZigModu is a modular application framework for Zig 0.16.0, aligned with Spring Modulith core features. **Currently fully implemented and working.**

## Critical Constraints
- **Zig Version**: Must use Zig 0.16.0 exactly
- **No GC**: Framework avoids hidden allocations; uses explicit memory management
- **Compile-time Validation**: Module dependencies checked at compile time where possible
- **Explicit Lifecycle**: Modules must implement `init() !void` and `deinit() void`

## Project Structure
```
zigmodu/
├── build.zig                  # Build system (Zig 0.16.0 syntax)
├── build.zig.zon              # Dependency management
├── AGENTS.md                  # This file
├── dev.md                     # Design document
├── src/
│   ├── root.zig              # Framework public API exports
│   ├── main.zig              # Framework entry point
│   ├── extensions.zig        # Extensions (DI, Config, Log, Test)
│   ├── api/
│   │   └── Module.zig        # Module and Modulith structs
│   ├── core/
│   │   ├── Module.zig        # ModuleInfo, ApplicationModules
│   │   ├── ModuleScanner.zig # Compile-time module scanning
│   │   ├── ModuleValidator.zig # Dependency validation
│   │   ├── EventBus.zig      # Type-safe event bus
│   │   ├── Lifecycle.zig     # startAll/stopAll functions
│   │   └── Documentation.zig # PlantUML doc generation
│   ├── di/
│   │   └── Container.zig     # Dependency injection container
│   ├── config/
│   │   └── Loader.zig        # Configuration loader (JSON)
│   ├── log/
│   │   └── ModuleLogger.zig  # Module-specific logging
│   └── test/
│       └── ModuleTest.zig    # Module testing utilities
└── example/
    └── src/
        ├── app.zig           # Example application entry
        ├── order/module.zig  # Order module
        ├── payment/module.zig # Payment module
        └── inventory/module.zig # Inventory module
```

## Essential Commands
- `zig build` - Compile the framework
- `zig build test` - Run tests
- `zig build run` - Run example application

## Dependencies (from build.zig.zon)
- **zio**: v0.9.0+ (async runtime) - already configured
- Note: zig-yaml removed (404 error), zig-events and zig-di referenced but not used

## Framework Conventions (CRITICAL)

### 1. Module Definition
```zig
const api = @import("zigmodu").api;

pub const info = api.Module{
    .name = "order",                    // Unique module name
    .description = "订单模块",
    .dependencies = &.{"inventory"},    // Dependencies as string literals
    .is_internal = false,
};

pub fn init() !void {
    std.log.info("订单模块初始化", .{});
}

pub fn deinit() void {
    std.log.info("订单模块释放", .{});
}
```

### 2. Application Entry Point
```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

const order = @import("order/module.zig");
const inventory = @import("inventory/module.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // REQUIRED sequence:
    var modules = try zigmodu.scanModules(allocator, .{ order, inventory });
    defer modules.deinit();
    
    try zigmodu.validateModules(&modules);
    try zigmodu.generateDocs(&modules, "modules.puml", allocator);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);
}
```

### 3. build.zig.zon Format (Zig 0.16.0)
```zig
.{
    .name = .zigmodu,  // MUST be enum literal, not string!
    .version = "0.1.0",
    .fingerprint = 0x7aa42d07b32f8d53,  // Required for new packages
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zio = .{
            .url = "https://github.com/lalinsky/zio/archive/refs/tags/v0.9.0.tar.gz",
            .hash = "12202c874628a8fc488cd8bcfdd08c2cbfb9e4e09b64313e49a2129d410c0c50ea13",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

### 4. build.zig Format (Zig 0.16.0)
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create module with root_module (NOT root_source_file!)
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);
}
```

## Common Mistakes to Avoid

1. **build.zig.zon**: `.name` must be enum literal (`.zigmodu`), NOT string (`"zigmodu"`)
2. **build.zig**: Use `root_module = b.createModule(...)` NOT `root_source_file = ...`
3. **Module dependencies**: Use `&.{}` syntax for empty dependencies
4. **scanModules signature**: `scanModules(allocator, .{ mod1, mod2 })` - allocator FIRST
5. **File writer**: Use `std.ArrayList(u8)` with `.writer(allocator)` - File has no `.print()` method

## Verification
- ✅ `zig build` compiles successfully
- ✅ `zig build test` runs all tests successfully
- ✅ `zig build run` outputs module validation and startup messages
- ✅ `modules.puml` is generated with correct PlantUML syntax
- ✅ Module init/deinit functions are properly called
- ✅ Memory is properly cleaned up

## Current Status
**FULLY IMPLEMENTED** - All core features working:
- Module definition and registration
- Compile-time module scanning with init/deinit function extraction
- Dependency validation
- Event bus (type-safe)
- Lifecycle management (startAll/stopAll) with proper function calls
- PlantUML documentation generation with dynamic buffer
- Working example with order/payment/inventory modules
- Proper memory management (deinit called)
- Dependency injection container (src/di/)
- Configuration loading (src/config/)
- Module-specific logging (src/log/)
- Module testing utilities (src/test/)
- Comprehensive unit tests