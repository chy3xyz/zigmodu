# Structured Logging

## Quick Start

```zig
const log = @import("zigmodu").observability.StructuredLogger;

var logger = try log.init(allocator, .{
    .level = .info,
    .format = .json,
    .output = .stdout,
});
defer logger.deinit();

logger.info("server_started", .{ .port = 8080 });
// {"level":"info","msg":"server_started","port":8080,"timestamp":1715500000}
```

## Levels

| Level | Use case |
|-------|----------|
| `debug` | Development diagnostics |
| `info` | Normal operations (startup, shutdown, health) |
| `warn` | Recoverable issues (retry, timeout, circuit open) |
| `err` | Errors requiring attention (DB down, auth failure) |

## Production Configuration

```zig
var logger = try StructuredLogger.init(allocator, .{
    .level = .info,
    .format = .json,
    .output = .file,
    .file_path = "/var/log/zigmodu/app.log",
    .rotation = .{
        .max_size_mb = 100,
        .max_files = 5,
    },
});

// Module-scoped logger
const module_log = logger.scope("order");
module_log.info("order_created", .{ .order_id = 42 });
// {"level":"info","scope":"order","msg":"order_created","order_id":42}
```

## Migration from std.log

```zig
// Before (v0.8)
std.log.info("Order {d} created", .{order_id});

// After (v0.9)
logger.info("order_created", .{ .order_id = order_id });
```

## Best Practices

1. **Use structured fields**: `logger.info("event_name", .{ .key = value })` not string interpolation
2. **Scope your logger**: `const log = logger.scope("module_name")` for module-level filtering
3. **Never log secrets**: `Authorization`, `X-API-Key`, `Cookie` are auto-redacted
4. **Log at boundary**: log at module entry/exit, not every internal function
5. **Include correlation IDs**: use `requestId()` middleware for request tracing
