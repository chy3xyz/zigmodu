# ZigModu — AI Agent Guide

## Quick Reference

```zig
const zmodu = @import("zigmodu");

// Domain imports (canonical)
const http = zmodu.http;       // Server, Context, RouteGroup
const data = zmodu.data;       // SQLx, ORM, Cache, Redis
const sec  = zmodu.security;   // Auth, RBAC, Secrets
const obs  = zmodu.observability; // Metrics, Tracing, Logging

// Module definition (required contract)
pub const info = zmodu.api.Module{ .name = "my-module", .description = "...", .dependencies = &.{} };
pub fn init() !void { ... }
pub fn deinit() void { ... }

// App builder
var app = try zmodu.builder(allocator, io).withName("app").build(.{ModuleA, ModuleB});
defer app.deinit();
try app.start();
defer app.stop();
```

## Critical Rules (MUST follow)

### Zig 0.17.0 — what's REMOVED
| Removed | Replacement |
|---------|-------------|
| `std.Thread.sleep()` | busy-loop or `std.Io.sleep()` |
| `std.Thread.Mutex` | `std.Io.Mutex` — needs `io` param: `.lock(io)` / `.unlock(io)` |
| `std.Thread.WaitGroup` | no replacement; use `std.Io.Group` |
| `std.time.milliTimestamp()` | `@import("core/Time.zig").monotonicNowMilliseconds()` |
| `std.time.microTimestamp()` | same |
| `std.os.getpid()` | `@intFromPtr(&seed)` for entropy |
| `std.fs.cwd()` | `std.Io.Dir.cwd(io)` |
| `std.fs.File` | `std.Io.File` — needs `io` param everywhere |
| `std.posix.empty_sigset` | `std.posix.sigemptyset()` |
| `sigaction()` returns error | returns `void` in Zig 0.16 |
| `ArrayList(T).init(alloc)` | `ArrayList(T).empty` + pass allocator to each method |
| `file.writeAll(data)` | `file.writeStreamingAll(io, data)` |
| `buf.writer(allocator)` | `allocPrint + appendSlice` pattern |
| `std.crypto.random.bytes()` | DELETED — use multi-source seed + Csprng |

### Zig 0.17.0 — patterns to USE
```zig
// ArrayList: .empty + explicit allocator
var list = std.ArrayList(T).empty;
defer list.deinit(allocator);
try list.append(allocator, item);

// Mutex: needs io
var mu: std.Io.Mutex = .init;
mu.lock(io) catch return;
defer mu.unlock(io);

// File I/O: always pass io
const file = try std.Io.Dir.cwd(io).createFile(io, path, .{});
defer file.close(io);
try file.writeStreamingAll(io, data);

// Env vars: use init.environ_map in main (Zig 0.17 Init)
if (init.environ_map.get("HTTP_PORT")) |p| { ... }

// Time: always use Time.zig
const now = Time.monotonicNowSeconds();
const now_ms = Time.monotonicNowMilliseconds();
```

## Architecture Rules

### Imports
- NEVER use `zigmodu.http_server` — use `zigmodu.http.Context`
- NEVER use `zigmodu.orm.Orm(...)` — use `zigmodu.data.Repository(T)`
- NEVER use `zigmodu.PasswordEncoder` — use `zigmodu.security.PasswordEncoder`
- Domain files are CANONICAL: `http.zig`, `data.zig`, `security.zig`, `observability.zig`

### Module lifecycle
```zig
// Every module MUST satisfy this contract:
pub const info = zmodu.api.Module{
    .name = "order",
    .description = "Order management module",
    .dependencies = &.{"user", "product"},  // module names, NOT import paths
};

pub fn init() !void {
    // Called at startup in dependency order (deps before dependents)
}

pub fn deinit() void {
    // Called at shutdown in REVERSE dependency order
}
```

### Error handling
- Use `ZigModuError` from `zmodu.ZigModuError` (NOT raw `error{...}`)
- Log errors — never `catch {}` on I/O or DB operations
- Use `zmodu.Result(T)` for fallible operations

### Security
- Passwords: `sec.PasswordEncoder` (PBKDF2-HMAC-SHA256, 100K iterations)
- JWT: `sec.AppSecurity.init(allocator, io, .{ .jwt_secret = ... })` + `jwtMiddleware()` (wall clock); RBAC via `sec.auth.jwtAuth`
- Secrets: `sec.SecretsManager` (env > file > vault > default priority)
- CSRF: `http_middleware.csrf()` double-submit cookie pattern
- CSPRNG: multi-source entropy, never single-timestamp seed

## Generated Code Patterns

### HTTP API handler
```zig
const http = @import("zigmodu").http;

pub fn registerRoutes(group: *http.RouteGroup) !void {
    try group.get("/users/{id}", getUser, null);
}

fn getUser(ctx: *http.Context) !void {
    const id = try ctx.paramInt("id");
    const page = ctx.queryInt("page", 0);
    // Use ctx.json(200, body) — NOT ctx.sendSuccess/sendFail (deprecated)
}
```

### Database
```zig
const data = @import("zigmodu").data;

// One-step init (preferred)
var db = try data.Client.open(allocator, io, .{ .driver = .sqlite, .path = "app.db" });
defer db.deinit();

// Repository pattern
const repo = data.Repository(model.User){ .backend = backend };
const users = try repo.list(page, size);
```

### Events
```zig
var bus = zmodu.EventBus(MyEvent).init(allocator);
try bus.subscribe(myHandler);
bus.publish(.{ .id = 42 });
```

## File Organization
```
src/modules/{name}/
├── model.zig          # Structs, table mappings
├── persistence.zig    # Repository / data access
├── service.zig        # Business logic
├── api.zig            # HTTP handlers (registerRoutes)
├── events.zig         # EventBus types + publisher
├── module.zig         # Module lifecycle + dependencies
└── root.zig           # Barrel re-exports
```

## Testing
```zig
test "my test" {
    const allocator = std.testing.allocator;
    // Use std.testing.io for I/O-dependent tests
    // Use std.testing.tmpDir() for file-dependent tests
}
```

## Version
- Framework: **v0.13.15**
- Zig: **0.17.0**
- Tests: **413 passed**, 5 skipped, 0 failed
- Roadmap: `docs/PRODUCTION_ROADMAP.md` (phases 1–5 ✅)
- Score: ~92/100 (`docs/EVALUATION_REPORT.md` v4)

## Learned User Preferences

- Respond in 中文 for user-facing communication.
- Do not create git commits unless the user explicitly asks.
- Prefer the production-readiness plan without physically splitting `sqlx.zig` or `Server.zig`; use section comments plus `docs/PRODUCTION_ROADMAP.md` maintenance boundaries instead.
- When generating framework code from SQL scripts (zmodu), follow zigmodu best practices for complete module output and place reusable templates in a dedicated templates folder.

## Learned Workspace Facts

- Project targets Zig 0.17.0; current release tag is v0.13.15 (GitHub `chy3xyz/zigmodu`, default branch `master`).
- If Zig global cache fails in sandboxed runs, use `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`.
- Production roadmap and monolith maintenance rules live in `docs/PRODUCTION_ROADMAP.md`.
- Current test baseline: **413 passed**, 5 skipped with `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`.
