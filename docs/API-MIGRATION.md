# API Migration Guide: Simplified API → Application API

ZigModu v0.8+ recommends `Application` as the primary API. The legacy `Simplified.zig`
(`App`, `Module`, `ModuleImpl`) is deprecated and will be removed in v1.0.

## Quick Comparison

| Feature | Simplified (deprecated) | Application (recommended) |
|---------|------------------------|---------------------------|
| Entry point | `App.init()` | `Application.init()` / `builder()` |
| Module type | `Module` (VTable) | `api.Module` (comptime) |
| Registration | `app.register(ModuleImpl(T).interface(&inst))` | `builder().build(.{T})` |
| Validation | Manual | `validate_on_start: true` (default) |
| Lifecycle | `app.start()` / `app.stop()` | `app.start()` / `app.stop()` + graceful drain |
| Shutdown hooks | Not supported | `app.onShutdown(hook)` |
| Health checks | Not supported | `HealthEndpoint` + K8s probes |
| Metrics | Not supported | `PrometheusMetrics` + `/metrics` |

## Migration Steps

### Before: Simplified API

```zig
const zmodu = @import("zigmodu");
const Simplified = zmodu.App;
const ModuleImpl = zmodu.ModuleImpl;

const UserModule = struct {
    pub fn name(_: *UserModule) []const u8 { return "user"; }
    pub fn init(self: *UserModule, _: *anyopaque) !void {
        std.log.info("user init", .{});
    }
    pub fn start(self: *UserModule) !void {}
    pub fn stop(self: *UserModule) void {}
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var app = App.init(allocator);
    defer app.deinit();

    var user_mod = UserModule{};
    try app.register(ModuleImpl(UserModule).interface(&user_mod));
    try app.start();
    defer app.stop();
}
```

### After: Application API

```zig
const zmodu = @import("zigmodu");

const UserModule = struct {
    pub const info = zmodu.api.Module{
        .name = "user",
        .description = "User management module",
        .dependencies = &.{},
    };
    pub fn init() !void {
        std.log.info("user init", .{});
    }
    pub fn deinit() void {}
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var app = try zmodu.builder(allocator, std.testing.io)
        .withName("my-app")
        .build(.{UserModule});
    defer app.deinit();

    // app.run() handles signals + graceful drain (recommended for production)
    try app.start();
    defer app.stop();
}
```

## Key Changes

1. **Module definition**: Use `pub const info = zmodu.api.Module{...}` instead of VTable methods
2. **No instance needed**: `Application` calls `init()`/`deinit()` directly, no `self` pointer
3. **Compile-time safety**: `scanModules()` validates dependencies at compile time
4. **Graceful shutdown**: `app.run()` handles SIGINT/SIGTERM + drains in-flight requests
5. **No VTable**: Direct function calls instead of indirect VTable dispatch

## Domain Import Convergence (v0.13.15+)

Canonical imports — use these in all new code:

```zig
const zmodu = @import("zigmodu");
const http = zmodu.http;
const data = zmodu.data;
const sec = zmodu.security;
const obs = zmodu.observability;
```

| Deprecated (remove v0.14.0) | Canonical replacement |
|-----------------------------|------------------------|
| `zigmodu.http_server.Server` | `zigmodu.http.Server` |
| `zigmodu.http_server.Context` | `zigmodu.http.Context` |
| `zigmodu.sqlx.Client` | `zigmodu.data.Client` |
| `zigmodu.orm` | `zigmodu.data.orm` |
| `zigmodu.SqlxBackend` | `zigmodu.data.SqlxBackend` |
| `zigmodu.PasswordEncoder` | `zigmodu.security.PasswordEncoder` |
| `zigmodu.SecurityModule` | `zigmodu.security.SecurityModule` |
| `zigmodu.Cache` | `@import("cache/Lru.zig").Cache` (generic) |

Flat aliases remain on `zigmodu` root via `zigmodu.deprecated` for one release cycle.
See `src/deprecated.zig` for the full list and `REMOVAL_VERSION`.

## JWT & Security (v0.13.15+)

Production apps should use **wall-clock** JWT expiry (not monotonic time).

```zig
const zmodu = @import("zigmodu");
const sec = zmodu.security;

// Recommended: builder helper (uses initWithIo internally)
var b = zmodu.builder(allocator, io).withName("my-app");
var app_sec = b.security("your-secret", 3600);
try server.addMiddleware(app_sec.jwtMiddleware());

// RBAC handlers (AuthInfo in ctx.user_data)
const rbac_mw = try app_sec.rbacJwtMiddleware(allocator);
try server.addMiddleware(rbac_mw);

// Token issuance (same clock as verify when using AppSecurity)
const token = try app_sec.generateToken("user-id", &.{ "admin" });
defer allocator.free(token);
```

| API | Use when |
|-----|----------|
| `security.AppSecurity.init(allocator, io, .{ .jwt_secret = ... })` | Production HTTP server |
| `http_middleware.jwtAuthWithSecurity(&sec.module)` | Manual wiring |
| `http_middleware.jwtAuth("secret")` | Quick dev / tests (`ctx.io` enables wall clock) |
| `security.auth.jwtAuth(&sec.module, allocator)` | RBAC + tenant claims |

CI / local probes: `JWT_SECRET=dev-secret zig build gen-jwt-token && ./zig-out/bin/gen-jwt-token`

## Multi-Tenancy (Optional)

ZigModu **does not require** multi-tenancy. Core apps (`examples/basic`) run without `TenantContext` or `tenant_id` columns.

| Need | Use |
|------|-----|
| Single-tenant API | `AppSecurity` + `jwtMiddleware()` only |
| Row-level tenant isolation | `TenantContext` + explicit `WHERE tenant_id = ?` or `TenantInterceptor` |
| JWT tenant claim | `generateTokenWithTenant` + `security.auth.jwtAuth` (RBAC) |
| Full SaaS stack | See `examples/tenant-mgmt` |

Skip tenant filtering: `TenantContext.ignoreTenant()` or struct field `zigmodu_ignore_tenant`.

### HTTP responses

Prefer `ctx.json(status, body)` or `ctx.jsonStruct(status, value)`.
`ctx.sendSuccess` / `ctx.sendFail` are deprecated compat helpers (see `Server.zig`).
