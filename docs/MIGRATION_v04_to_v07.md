# Migration Guide: ZigModu v0.4 to v0.7

**ZigModu v0.7.0** introduces several breaking changes and improvements over v0.4. This guide helps you migrate your existing code.

---

## Breaking Changes

### 1. Module Definition Changes

#### Old API (v0.4)
```zig
const MyModule = struct {
    pub const info = ModuleInfo{
        .name = "my-module",
        .dependencies = &.{"other"},
    };
};
```

#### New API (v0.7)
```zig
const zigmodu = @import("zigmodu");

const MyModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "my-module",
        .description = "My module description",
        .dependencies = &.{"other"},
        .is_internal = false,
    };
};
```

**Changes:**
- `ModuleInfo` renamed to `zigmodu.api.Module`
- Added `.description` field (required)
- Added `.is_internal` field (default: `false`)

---

### 2. Time Source

All time-related functionality now uses `core/Time.zig` instead of hardcoded values.

#### Before (v0.4)
```zig
const now = 0; // Incorrect - was placeholder
```

#### After (v0.7)
```zig
const Time = @import("zigmodu").core.Time;
const now = Time.monotonicNowSeconds();
```

---

### 3. Application Initialization

#### Old API (v0.4)
```zig
var app = try Application.init(allocator, "app", modules);
try app.start();
```

#### New API (v0.7)
```zig
var app = try Application.init(
    std.testing.io,
    allocator,
    "app",
    modules,
    .{ .validate_on_start = true }
);
try app.start();
defer app.deinit();
```

**Changes:**
- `Application.init` now takes `std.Io` as first argument
- Added options struct as last parameter
- Added `.deinit()` method for cleanup

---

### 4. Error Types

Error types have been unified under `ZigModuError`.

#### Before (v0.4)
```zig
return error.ValidationError;
return error.LifecycleError;
```

#### After (v0.7)
```zig
return ZigModuError.ModuleInitializationFailed;
return ZigModuError.InvalidDependency;
```

---

### 5. EventBus API

#### Before (v0.4)
```zig
var bus = EventBus(EventType).init(allocator);
```

#### After (v0.7)
```zig
var bus = TypedEventBus(EventType).init(allocator);
```

---

## Removed Features

The following features were removed in v0.7:

| Feature | Reason | Replacement |
|---------|--------|-------------|
| `PasRaftAdapter` | Incomplete implementation | Use ClusterMembership |
| `TransportProtocols` | gRPC/MQTT stubs | Use DistributedEventBus |
| `ModuleCanvas` | Functionality overlap | Use ArchitectureTester |
| `C4ModelGenerator` | Template only | Use Documentation.zig |

---

## New Features in v0.7

### 1. StructuredLogger
```zig
const logger = StructuredLogger.init(allocator, io, .INFO, .stdout);
try logger.withField("module", "order");
try logger.log(.INFO, "Order created", .{});
```

### 2. HealthEndpoint
```zig
const health = HealthEndpoint.init(allocator);
try health.registerCheck("db", "Database health", checkDb);
const status = health.checkHealth();
```

### 3. PrometheusMetrics
```zig
const metrics = PrometheusMetrics.init(allocator);
const counter = try metrics.counter("requests_total", "Total requests");
counter.inc();
const gauge = try metrics.gauge("active_connections", "Active connections");
gauge.set(42.0);
```

### 4. DistributedEventBus
```zig
var bus = DistributedEventBus.init(allocator, io, "node-1");
try bus.start(8080);
try bus.publish(.{ .topic = "order", .payload = data });
```

---

## Recommended Update Sequence

1. **Update Module Definitions** - Change `ModuleInfo` to `zigmodu.api.Module`
2. **Add descriptions** - Add `.description` field to all modules
3. **Fix Time Usage** - Replace hardcoded `0` with `Time.monotonicNowSeconds()`
4. **Update Application Init** - Add `std.Io` parameter and options
5. **Migrate Error Handling** - Use `ZigModuError` instead of custom errors
6. **Update EventBus** - Rename to `TypedEventBus`

---

## Compatibility Notes

- All modules must have unique names
- Dependencies must form a DAG (no cycles)
- Module init/deinit must not block indefinitely
- Use `std.Io` for all async operations

---

## Getting Help

- [API Documentation](../docs/API.md)
- [Quick Start Guide](../QUICK-START.md)
- [GitHub Issues](https://github.com/knot3bot/zigmodu/issues)
