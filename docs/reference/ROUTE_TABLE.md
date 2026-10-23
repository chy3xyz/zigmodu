# Declarative Routing & Authentication (`ComptimeRouter`)

This reference defines zmodu's compile-time HTTP routing (`Router(State)` + `RouteSpec`), Path A catalog JWT authentication, RBAC permission gates, WebSocket/SSE route tables, and production server profiles.

## 1. Recommended Stack vs Legacy Middleware

| Feature | `ComptimeRouter` + Path A (Recommended) | Legacy Auth Middleware |
|---------|-----------------------------------------|------------------------|
| Route declaration | `pub const routes = [_]http.RouteSpec(State){ ... }` | Runtime `router.scope(p).get(...)` |
| JWT verification | `http.jwtAuthFromCatalogWithPermissions` | `security.auth.jwtAuth*` / `rbacJwtMiddleware*` |
| Authorization gate | `http.permissionGateWith(&slot, .{ .mode = .rbac })` | `ctx.auth_info` + manual `requirePermission` |
| Handler state | `ctx.user_data` holds `*State` (read via `ctx.state(T)`) | `ctx.user_data` untouched (`AuthInfo` in `ctx.auth_info`) |
| Identity attributes | `ctx.userId()`, `ctx.tenantId()`, `ctx.permissionMatches(...)` | `ctx.authInfo()` |

Use the **left column** (`ComptimeRouter` + Path A catalog JWT/RBAC) for all new applications and `zmodu scaffold --with-auth` projects.

## 2. Core Routing Types

### 2.1 `RouteMeta` and `Auth`

```zig
pub const Auth = enum { inherit, public, optional, jwt };

pub const RouteMeta = struct {
    auth: Auth = .inherit,
    /// Permission code (`|` = OR); checked when `permissionGateWith` runs in `.mode = .rbac`
    permission: ?[]const u8 = null,
    /// Coarse portal/role name (`|` = OR); checked before `permission`
    roles: ?[]const u8 = null,
    /// Defaults to the mounted module's `module_name`
    module: ?[]const u8 = null,
    /// OpenAPI annotations (do not affect runtime authentication)
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    request_body: ?[]const u8 = null,
    sse: bool = false,
    openapi_params: []const http.ApiParam = &.{},
};
```

### 2.2 `RouteSpec(State)`

```zig
pub fn RouteSpec(comptime State: type) type {
    return struct {
        method: http.Method,
        /// Relative path without leading slash (e.g. "{id}" or "login")
        path: []const u8,
        /// Typed handler receiving `*http.Context` and `*State`
        handler: *const fn (*http.Context, *State) anyerror!void,
        meta: RouteMeta = .{},
    };
}
```

Path parameter limit: each route supports up to **8** `{...}` segments (`RouteParams.MAX`). Exceeding 8 parameters returns `error.TooManyRouteParams` at route registration time.

### 2.3 Module Route Table Contract

```zig
const http = @import("zmodu").http;

pub fn OrderApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        service: *Service,

        pub const module_name = "order";
        pub const nest = .{"orders"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "{id}", .handler = getOrder, .meta = .{ .auth = .jwt } },
            .{ .method = .DELETE, .path = "{id}", .handler = cancelOrder, .meta = .{ .permission = "order:cancel" } },
            .{ .method = .POST, .path = "login", .handler = login, .meta = .{ .auth = .public } },
        };

        // WebSocket routes MUST explicitly set `.meta.auth = .public` (enforced at compile time)
        pub const ws_routes = [_]http.WsSpec(State){
            .{
                .path = "ws",
                .on_connect = onConnect,
                .on_message = onMessage,
                .on_close = onClose,
                .meta = .{ .auth = .public, .module = "order" },
            },
        };

        fn getOrder(ctx: *http.Context, self: *State) !void {
            const id = try ctx.paramInt(i64, "id");
            _ = self;
            try ctx.jsonStruct(200, .{ .id = id, .tenant = ctx.tenantId() });
        }

        fn cancelOrder(ctx: *http.Context, _: *State) !void {
            try ctx.jsonStruct(200, .{ .cancelled = true });
        }

        fn login(ctx: *http.Context, _: *State) !void {
            try ctx.jsonStruct(200, .{ .token = "..." });
        }
    };
}
```

### 2.4 Mounting Modules & Compile-Time Duplicate Detection

```zig
comptime http.assertNoDupes(.{ OrderApi, UserApi });

var router = http.Router(AppState).init(init.io, allocator, &server, &app_state);
defer router.deinit();

var api_v1 = router.scope("/api/v1");
try api_v1.mountAll(.{
    .{ .Mod = OrderApi, .state = &order_api },
    .{ .Mod = UserApi, .state = &user_api },
});

catalog_slot.set(try router.finish());
```

For dynamic runtime routes (plugins, ad-hoc admin endpoints), use `router.scope("/api").get("ping", handler, null)`. Runtime routes do not enter `RouteCatalog` and are not inspected by `permissionGate`, OpenAPI export, or `Testkit.auditAuthCoverage`.

## 3. Path A Authentication & Multi-Portal RBAC

### 3.1 Wiring Catalog JWT + RBAC Gate

```zig
var catalog_slot = http.CatalogSlot.init();
defer catalog_slot.deinit(allocator);

const table = security.Rbac.RolePermissionTable{
    .rows = &.{
        .{ .role = "admin", .permissions = &.{ "tenant:suspend", "tenant:write" } },
        .{ .role = "user", .permissions = &.{"tenant:read"} },
    },
};

try server.addMiddleware(try http.jwtAuthFromCatalogWithPermissions(
    &sec,
    &catalog_slot,
    try http.catalogLoaderFromTable(&table),
    .{},
));
try server.addMiddleware(try http.moduleGate(&catalog_slot, .{ .unknown = .allow }));
try server.addMiddleware(try http.permissionGateWith(&catalog_slot, .{ .mode = .rbac }));

// Mount all modules, then populate catalog_slot:
try api_v1.mountAll(.{ ... });
catalog_slot.set(try router.finish());
```

For database-backed role permissions, pass `try zmodu.security.CatalogPermDb.loaderFromClient(&db_client)`.

Seed the catalog with `CatalogPermDb.ensureSchema(&db_client)` + `CatalogPermDb.grant(&db_client, role, permission)` once at startup; both are dialect-aware, so the same call works on SQLite, PostgreSQL and MySQL (`grant` is idempotent — re-running it is a no-op).

### 3.2 Multi-Portal Identity & Custom Permission Loaders

zmodu does not add a custom `type` enum to `JwtPayload`. Instead, map multi-portal identities (e.g., storefront customer, merchant staff, supplier, platform admin) onto standard JWT claims:

| Concept | JWT / Framework Slot | Rule |
|---------|----------------------|------|
| User ID | JWT `sub` → attr `"user_id"` | Read via `ctx.userId()` / `ctx.requireUserId()` |
| Tenant / Store ID | JWT `aud` → attr `"tenant_id"` | Mint with `generateTokenWithTenant(sub, roles, aud)`; read via `ctx.tenantId()` |
| Portal / Coarse Role | JWT `roles` → attr `"roles"` | Gate with `RouteMeta.roles = "shop\|admin"` |
| Fine-Grained RBAC | `CatalogPermissionLoader` → attr `"permissions"` (CSV) | Gate with `RouteMeta.permission = "order:cancel"` |
| Route Handler State | `ctx.user_data` (`*State`) | Read via `ctx.state(T)`; never store `AuthInfo` in `user_data` |

Custom `CatalogPermissionLoader` signature:

```zig
// CatalogPermLoadInput = struct { sub: []const u8, aud: []const u8, roles: []const []const u8 }
pub const CatalogPermissionLoader = *const fn (
    allocator: std.mem.Allocator,
    input: http.CatalogPermLoadInput,
) anyerror![]u8;
```

### 3.3 Pluggable `AuthBackend`, Envelopes & CI Coverage Audit

- **Custom auth backends**: Use `http.authFromCatalog(&slot, backend, .{})` to wrap non-JWT backends (session stores, Redis tokens) while keeping `RouteMeta.auth == .public` as the single bypass source of truth.
- **Response envelope dialects**: Call `ctx.setEnvelope(.thinkphp | .ruoyi | .default)` and use `ctx.okValue(v)`, `ctx.fail(msg)`, `ctx.failCode(code, msg)`, `ctx.unauth(msg)`, and `ctx.paginated(items, total)`.
- **CI auth coverage audit**: Call `http.Testkit.auditAuthCoverage(allocator, &server, &slot)` in tests to dispatch unauthenticated requests to every catalog route and verify that all non-public routes return `401` and all `.public` routes do not return `401`.

## 4. Extractors, `resultHandler`, and SSE

### 4.1 Typed Request Extractors

```zig
const id = (try http.extractPath(ctx, .{ .id = u64 })).id;
const query = try http.extractQuery(ctx, .{ .page = u32, .size = u32 });
const body = try http.extractJsonValidated(ctx, CreateOrderDto, order_rules);
```

### 4.2 Thin Handlers with `http.resultHandler`

Wrap handlers that return a value directly so the framework serializes the `200 OK` envelope automatically:

```zig
fn getUser(ctx: *http.Context, self: *State) !UserDto {
    const id = try ctx.paramInt(i64, "id");
    return self.svc.findUser(id);
}

pub const routes = [_]http.RouteSpec(State){
    .{ .method = .GET, .path = "{id}", .handler = http.resultHandler(State, UserDto, getUser) },
};
```

### 4.3 Server-Sent Events (SSE)

Declare SSE routes in `pub const sse_routes = [_]http.SseSpec(State){ ... }` (or set `.meta = .{ .sse = true }`). Inside the handler:

```zig
var sse = try http.sse(ctx);
if (http.lastEventId(ctx)) |last_id| {
    _ = last_id;
}
try sse.sendEvent("update", "{\"progress\":50}");
try sse.done();
```

## 5. Production Profile & Backpressure Ordering

Mount `http.productionProfile` **before** registering any routes:

| Layer | Configuration Field | Protection |
|-------|---------------------|------------|
| Connection limit | `max_connections` / `over_limit_response` | Prevents file descriptor and memory exhaustion under connection floods |
| Header deadline | `header_timeout_ms` | Guards against Slowloris attacks; cleared once headers are parsed |
| Body deadline | `body_timeout_ms` (default 30s) | Guards against Slow-POST attacks; returns HTTP `408` on timeout |
| HTTP/2 limits | Inherited via `Server.http2ServeOptions` | Applies `max_body_size`, 16 KiB / 100 header limits (`SETTINGS_MAX_HEADER_LIST_SIZE`), and idle read timeout to h2c/HTTP/2 |
| Handler timeout | `request_timeout_ms` | Bounds handler execution duration |
| WebSocket outbound | `ws_write_timeout_ms` + `WsFramer.isWritable()` | Prevents slow WebSocket readers from blocking writer threads |
