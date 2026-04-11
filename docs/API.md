# API Reference

## Core Modules

### Module Definition

#### `api.Module`

Defines a business module with metadata.

```zig
pub const Module = struct {
    name: []const u8,                    // Unique module name
    description: []const u8 = "",       // Human-readable description
    dependencies: []const []const u8 = &.{},  // Dependencies
    is_internal: bool = false,          // Internal API flag
};
```

**Example:**
```zig
pub const info = api.Module{
    .name = "order",
    .description = "Order management module",
    .dependencies = &."inventory",
};
```

#### `api.Modulith`

Marks the entire modular application.

```zig
pub const Modulith = struct {
    name: []const u8,
    base_path: []const u8,
    validate: bool = true,
    generate_docs: bool = true,
};
```

### Module Management

#### `scanModules`

Scans modules at compile time and extracts metadata.

```zig
pub fn scanModules(
    allocator: std.mem.Allocator,
    comptime modules: anytype
) !ApplicationModules
```

**Parameters:**
- `allocator`: Memory allocator
- `modules`: Tuple of module types

**Returns:** `ApplicationModules` containing all scanned modules

**Example:**
```zig
var modules = try zigmodu.scanModules(allocator, .{
    order_module,
    inventory_module,
});
```

#### `validateModules`

Validates that all module dependencies are satisfied.

```zig
pub fn validateModules(modules: *ApplicationModules) !void
```

**Errors:**
- `error.DependencyNotFound`: A dependency is missing

#### `startAll`

Starts all modules by calling their `init` functions.

```zig
pub fn startAll(modules: *ApplicationModules) !void
```

#### `stopAll`

Stops all modules by calling their `deinit` functions.

```zig
pub fn stopAll(modules: *ApplicationModules) void
```

### Event Bus

#### `EventBus(T)`

Type-safe event bus for inter-module communication.

```zig
pub fn EventBus(comptime T: type) type
```

**Methods:**

##### `init`

```zig
pub fn init(alloc: std.mem.Allocator) Self
```

##### `subscribe`

```zig
pub fn subscribe(
    self: *Self,
    listener: *const fn (T) void
) !void
```

**Example:**
```zig
const EventBus = zigmodu.EventBus;

const MyEvent = struct {
    id: u64,
    data: []const u8,
};

var bus = EventBus(MyEvent).init(allocator);
defer bus.deinit();

try bus.subscribe(handleEvent);
```

##### `publish`

```zig
pub fn publish(self: *Self, event: T) void
```

**Example:**
```zig
bus.publish(.{
    .id = 123,
    .data = "Hello",
});
```

##### `deinit`

```zig
pub fn deinit(self: *Self) void
```

### Documentation

#### `generateDocs`

Generates PlantUML documentation for modules.

```zig
pub fn generateDocs(
    modules: *ApplicationModules,
    path: []const u8,
    allocator: std.mem.Allocator
) !void
```

**Example:**
```zig
try zigmodu.generateDocs(&modules, "docs/modules.puml", allocator);
```

## Extensions

### Dependency Injection

#### `Container`

Simple DI container for service management.

```zig
pub const Container = struct {
    pub fn init(allocator: std.mem.Allocator) Self
    pub fn deinit(self: *Self) void
    pub fn register(self: *Self, name: []const u8, instance: *anyopaque) !void
    pub fn get(self: *Self, name: []const u8) ?*anyopaque
    pub fn getTyped(self: *Self, name: []const u8, comptime T: type) ?*T
};
```

**Example:**
```zig
const Container = zigmodu.extensions.Container;

var container = Container.init(allocator);
defer container.deinit();

var db = Database.init();
try container.register("database", &db);

const db_ptr = container.getTyped("database", Database);
```

#### `ModuleContainer`

Module-scoped DI container.

```zig
pub const ModuleContainer = struct {
    pub fn init(allocator: std.mem.Allocator, module_name: []const u8) Self
    pub fn deinit(self: *Self) void
    pub fn register(self: *Self, name: []const u8, instance: *anyopaque) !void
    pub fn get(self: *Self, name: []const u8) ?*anyopaque
    pub fn getTyped(self: *Self, name: []const u8, comptime T: type) ?*T
};
```

### Configuration

#### `ConfigLoader`

Loads configuration from JSON files.

```zig
pub const ConfigLoader = struct {
    pub fn init(allocator: std.mem.Allocator) Self
    pub fn loadJson(self: *Self, path: []const u8) !std.json.Parsed(std.json.Value)
    pub fn getString(config: std.json.Parsed(std.json.Value), key: []const u8) ?[]const u8
    pub fn getInt(config: std.json.Parsed(std.json.Value), key: []const u8) ?i64
    pub fn getBool(config: std.json.Parsed(std.json.Value), key: []const u8) ?bool
};
```

**Example:**
```zig
const ConfigLoader = zigmodu.extensions.ConfigLoader;

var loader = ConfigLoader.init(allocator);
var config = try loader.loadJson("config.json");
defer config.deinit();

const db_host = ConfigLoader.getString(config, "db_host");
```

### Logging

#### `ModuleLogger`

Module-specific logger with context.

```zig
pub const ModuleLogger = struct {
    pub fn init(module_name: []const u8) Self
    pub fn debug(self: *const Self, comptime fmt: []const u8, args: anytype) void
    pub fn info(self: *const Self, comptime fmt: []const u8, args: anytype) void
    pub fn warn(self: *const Self, comptime fmt: []const u8, args: anytype) void
    pub fn err(self: *const Self, comptime fmt: []const u8, args: anytype) void
};
```

**Example:**
```zig
const ModuleLogger = zigmodu.extensions.ModuleLogger;

var logger = ModuleLogger.init("order");
logger.info("Processing order {d}", .{order_id});
```

### Testing

#### `ModuleTestContext`

Test context for module-level testing.

```zig
pub const ModuleTestContext = struct {
    pub fn init(allocator: std.mem.Allocator, module_name: []const u8) !Self
    pub fn deinit(self: *Self) void
    pub fn registerMockModule(self: *Self, info: ModuleInfo) !void
    pub fn start(self: *Self) !void
    pub fn stop(self: *Self) void
};
```

**Example:**
```zig
const ModuleTestContext = zigmodu.extensions.ModuleTestContext;

test "order module" {
    var ctx = try ModuleTestContext.init(allocator, "order");
    defer ctx.deinit();
    
    try ctx.start();
    // Test code...
    ctx.stop();
}
```

#### `createMockModule`

Helper to create mock modules for testing.

```zig
pub fn createMockModule(
    name: []const u8,
    description: []const u8,
    dependencies: []const []const u8,
) ModuleInfo
```

## Types

### ModuleInfo

Internal representation of a module.

```zig
pub const ModuleInfo = struct {
    name: []const u8,
    desc: []const u8,
    deps: []const []const u8,
    ptr: *anyopaque,
    init_fn: ?*const fn (*anyopaque) anyerror!void = null,
    deinit_fn: ?*const fn (*anyopaque) void = null,
};
```

### ApplicationModules

Collection of registered modules.

```zig
pub const ApplicationModules = struct {
    pub fn init(allocator: std.mem.Allocator) ApplicationModules
    pub fn register(self: *ApplicationModules, info: ModuleInfo) !void
    pub fn get(self: *ApplicationModules, name: []const u8) ?ModuleInfo
    pub fn deinit(self: *ApplicationModules) void
};
```

## Error Handling

### Common Errors

- `error.DependencyNotFound`: Module dependency not found
- `error.ModuleNotFound`: Module not found in registry
- `error.OutOfMemory`: Allocation failure
- `error.FileNotFound`: Configuration file not found

### Error Handling Pattern

```zig
var modules = zigmodu.scanModules(allocator, .{mod1, mod2}) catch |err| {
    std.log.err("Failed to scan modules: {}", .{err});
    return;
};
defer modules.deinit();
```

## Best Practices

### Module Design

1. **Keep modules focused**: Each module should have a single responsibility
2. **Explicit dependencies**: Always declare dependencies explicitly
3. **Clean lifecycle**: Implement both `init` and `deinit` for resource management
4. **Error handling**: Handle errors gracefully in lifecycle hooks

### Memory Management

1. **Use allocators**: Always pass allocators explicitly
2. **Defer cleanup**: Use `defer` to ensure resources are freed
3. **Container ownership**: DI container doesn't own services

### Testing

1. **Mock dependencies**: Use `createMockModule` for isolated testing
2. **Test lifecycle**: Test both success and failure scenarios
3. **Integration tests**: Test module interactions

## Examples

See the `/examples` directory for complete working examples:
- `basic/` - Basic module setup
- `event_bus/` - Event-driven communication
- `dependency_injection/` - Service management