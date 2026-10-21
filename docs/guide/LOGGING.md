# Structured Logging

## 1. Quick Start

```zig
const StructuredLogger = @import("zmodu").observability.StructuredLogger;

var logger = try StructuredLogger.init(allocator, .{
    .level = .info,
    .format = .json,
    .output = .stdout,
});
defer logger.deinit();

logger.info("server_started", .{ .port = 8080 });
// {"level":"info","msg":"server_started","port":8080,"timestamp":1715500000}
```

## 2. Log Levels

| Level | Usage |
|-------|-------|
| `debug` | Development diagnostics |
| `info` | Normal lifecycle events (startup, shutdown, configuration) |
| `warn` | Recoverable anomalies (retries, timeouts, open circuit breakers) |
| `err` | Actionable failures (database unreachable, unexpected I/O failure) |

## 3. File Output and Rotation

```zig
var logger = try StructuredLogger.init(allocator, .{
    .level = .info,
    .format = .json,
    .output = .file,
    .file_path = "/var/log/zmodu/app.log",
    .rotation = .{
        .max_size_mb = 100,
        .max_files = 5,
    },
});
defer logger.deinit();

const order_log = logger.scope("order");
order_log.info("order_created", .{ .order_id = 42 });
// {"level":"info","scope":"order","msg":"order_created","order_id":42}
```

## 4. Request-Scoped Logging with Trace IDs

Inside HTTP handlers, use `ctx.logScope("module")` instead of a detached logger scope. When `tracingMiddleware` (included in `http.productionProfile`) is active, `ctx.logScope` automatically attaches the request's `trace_id`:

```zig
fn createOrder(ctx: *http.Context, self: *State) !void {
    const log = ctx.logScope("order");
    log.info("order_placed", .{ .user_id = ctx.userId() });
    _ = self;
}
```

## 5. Conventions

1. **Use structured fields**: Pass key-value structs to `logger.info("event", .{ .key = val })` instead of interpolating strings.
2. **Use `ctx.logScope` in HTTP handlers**: Preserves `trace_id` correlation across logs and traces.
3. **Never log credentials**: `Authorization`, `X-API-Key`, and `Cookie` headers are redacted automatically by the HTTP access log.
