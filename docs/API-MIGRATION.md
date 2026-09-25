# API Migration Guide: Simplified API → Application API

ZigModu v0.8+ recommends `Application` as the primary API. The legacy `Simplified.zig`
(`App`, `Module`, `ModuleImpl`) was **removed from the root exports** in commit `557190a`
(2026-05-12): `zigmodu.App` / `zigmodu.ModuleImpl` no longer compile. The file is still in the
tree, reachable only by internal path — see [`UPGRADING.md`](UPGRADING.md) 「已移除」.

## Quick Comparison

| Feature | Simplified (deprecated, off the root) | Application (recommended) |
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

> ⚠️ **这段是历史，不是能照抄的代码。** `zigmodu.App` / `zigmodu.ModuleImpl` 已在 commit `557190a`（2026-05-12）
> 从根导出里**移除**，所以下面那两行 `const` 今天**编译不过**（后面用到的 `App` 也随之未定义）。
> `src/api/Simplified.zig` 仍在树里，但只能**越路径**触达：
> `const Simplified = @import("zigmodu/src/api/Simplified.zig");` —— 那不是受支持的消费面，
> 见 [`UPGRADING.md`](UPGRADING.md) 的「已移除」。保留这段只是为了看懂旧代码在写什么。

```zig
// 旧代码长这样（前两行今天编译不过：顶层不再导出这两个名字）
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

    var b = zmodu.builder(allocator, std.testing.io);   // 先绑定：builder 方法收 *Self
    defer b.deinit();
    var app = try b.withName("my-app")
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

The flat aliases (`zigmodu.http_server`, `zigmodu.sqlx`, `zigmodu.orm`,
`zigmodu.SqlxBackend`, `zigmodu.PasswordEncoder`, `zigmodu.SecurityModule`,
`zigmodu.Cache`) and the `zigmodu.deprecated` namespace were **removed in
v0.15.1** (the planned removal version was v0.14.0). Use the canonical domain
imports: `zigmodu.http`, `zigmodu.data`, `zigmodu.security`, `zigmodu.cache`.

## JWT & Security (v0.13.15+)

Production apps should use **wall-clock** JWT expiry (not monotonic time).

```zig
const zmodu = @import("zigmodu");
const sec = zmodu.security;

// Recommended: builder helper (uses initWithIo internally)
var b = zmodu.builder(allocator, io);   // 先绑定：builder 方法收 *Self，临时值是 *const
defer b.deinit();
_ = b.withName("my-app");
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
