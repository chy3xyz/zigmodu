//! Example tests — the module graph, the routed catalog, and the full request
//! path that `main.zig` wires, driven through `http.Testkit` instead of a
//! socket.
//!
//! `Stack` below is the part worth copying: it is `main.zig` minus
//! `server.start()` — in-memory SQLite, the same five global middlewares in the
//! same order, and the same `ComptimeRouter` mounts.
//!
//! Run with: `zig build test`

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const security = zigmodu.security;

const tenant_module = @import("modules/tenant/module.zig");
const user_module = @import("modules/user/module.zig");
const subscription_module = @import("modules/subscription/module.zig");

const tenant_mod = @import("modules/tenant/root.zig");
const user_mod = @import("modules/user/root.zig");
const subscription_mod = @import("modules/subscription/root.zig");
const middleware = @import("middleware/root.zig");
const db_backend = @import("db/backend.zig");
const schema = @import("db/schema.zig");

test "module graph: three modules scan, validate and run their lifecycle" {
    const allocator = std.testing.allocator;

    var modules = try zigmodu.scanModules(allocator, .{ tenant_module, user_module, subscription_module });
    defer modules.deinit();

    try std.testing.expectEqual(@as(usize, 3), modules.modules.count());
    try zigmodu.validateModules(&modules);

    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);
}

test "route catalog: /api/v1 resources map to their module and RBAC meta" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try http.Testkit.openMemorySqlite(allocator, io);
    defer client.deinit();
    try schema.apply(&client);

    // Same chain as main.zig — the handlers are never invoked here, only mounted.
    const Backend = db_backend.Backend;
    const tenant_persist = tenant_mod.persistence.TenantPersistence(Backend).init(allocator, &client);
    const user_persist = user_mod.persistence.UserPersistence(Backend).init(&client);
    const sub_persist = subscription_mod.persistence.SubscriptionPersistence(Backend).init(&client);

    var tenant_svc = tenant_mod.service.TenantService(@TypeOf(tenant_persist)).init(allocator, tenant_persist);
    var user_svc = user_mod.service.UserService(@TypeOf(user_persist)).init(user_persist);
    var sub_svc = subscription_mod.service.SubscriptionService(@TypeOf(sub_persist)).init(sub_persist);

    var tenant_api = tenant_mod.api.TenantApi(@TypeOf(tenant_svc)).init(&tenant_svc);
    var user_api = user_mod.api.UserApi(@TypeOf(user_svc)).init(&user_svc);
    var sub_api = subscription_mod.api.SubscriptionApi(@TypeOf(sub_svc)).init(&sub_svc);

    var server = http.Server.init(io, allocator, 0);
    defer server.deinit();

    const AppState = struct {};
    var app_state: AppState = .{};
    comptime http.assertNoDupes(.{ @TypeOf(tenant_api), @TypeOf(user_api), @TypeOf(sub_api) });

    var catalog_slot: http.CatalogSlot = .{};
    defer catalog_slot.deinit();

    var router = http.Router(AppState).init(io, allocator, &server, &app_state);
    defer router.deinit();

    var api_v1 = router.scope("/api/v1");
    try api_v1.mountAll(.{
        .{ .Mod = @TypeOf(tenant_api), .state = &tenant_api },
        .{ .Mod = @TypeOf(user_api), .state = &user_api },
        .{ .Mod = @TypeOf(sub_api), .state = &sub_api },
    });
    catalog_slot.set(try router.finish());

    const catalog = catalog_slot.get().?;
    try std.testing.expectEqualStrings("tenant", catalog.moduleFor("/api/v1/tenants").?);
    try std.testing.expectEqualStrings("user", catalog.moduleFor("/api/v1/users").?);
    try std.testing.expectEqualStrings("subscription", catalog.moduleFor("/api/v1/plans").?);

    // Nothing here is anonymous: the JWT middleware chain decided that, not a per-route flag.
    try std.testing.expect(!catalog.isPublic(.GET, "/api/v1/tenants"));

    // The one route that carries a fine-grained gate, resolved through the `{id}` placeholder.
    const suspend_route = catalog.findEntry(.DELETE, "/api/v1/tenants/42").?;
    try std.testing.expectEqualStrings("tenant", suspend_route.module);
    try std.testing.expectEqualStrings("tenant:suspend", suspend_route.permission.?);
}

// ── Request-path tests (http.Testkit) ──────────────────────────────────────

/// `main.zig`'s wiring without `server.start()`: real SQLite, the five global
/// middlewares, the routed catalog. Handlers, services and persistence are all
/// the production ones — only the transport is replaced.
const Stack = struct {
    const Backend = db_backend.Backend;
    const TenantPersist = tenant_mod.persistence.TenantPersistence(Backend);
    const UserPersist = user_mod.persistence.UserPersistence(Backend);
    const TenantSvc = tenant_mod.service.TenantService(TenantPersist);
    const UserSvc = user_mod.service.UserService(UserPersist);
    const TenantApiT = tenant_mod.api.TenantApi(TenantSvc);
    const UserApiT = user_mod.api.UserApi(UserSvc);
    const AppState = struct {};

    allocator: std.mem.Allocator,
    io: std.Io,
    db: zigmodu.data.Client,
    sec: security.AppSecurity,
    slot: http.CatalogSlot,
    app_state: AppState,
    tenant_persist: TenantPersist,
    user_persist: UserPersist,
    tenant_svc: TenantSvc,
    user_svc: UserSvc,
    tenant_api: TenantApiT,
    user_api: UserApiT,
    server: http.Server,
    router: http.Router(AppState),

    /// Takes `*Stack`: every layer keeps a pointer to the one above it, so the
    /// stack must already live at its final address (`Client` is stored by
    /// pointer in the persistence layers, the router in the server).
    fn setup(self: *Stack, allocator: std.mem.Allocator, io: std.Io) !void {
        self.allocator = allocator;
        self.io = io;

        self.db = try http.Testkit.openMemorySqlite(allocator, io);
        // `:memory:` is per-connection, so pin the pool to one connection —
        // otherwise a second pooled connection would see an empty database.
        self.db.config.max_open_conns = 1;
        self.db.config.max_idle_conns = 1;
        try schema.apply(&self.db);
        try security.CatalogPermDb.ensureSchema(&self.db);
        // Same grants as main.zig: role names are the coarse JWT identity,
        // permissions are what `permissionGateWith(.rbac)` checks.
        try security.CatalogPermDb.grant(&self.db, "admin", security.Rbac.Permissions.tenant_read);
        try security.CatalogPermDb.grant(&self.db, "admin", security.Rbac.Permissions.tenant_write);
        try security.CatalogPermDb.grant(&self.db, "admin", security.Rbac.Permissions.tenant_suspend);
        try security.CatalogPermDb.grant(&self.db, "user", security.Rbac.Permissions.tenant_read);

        self.sec = http.Testkit.testSecurity(allocator, io);
        self.slot = .{};
        self.app_state = .{};

        self.tenant_persist = TenantPersist.init(allocator, &self.db);
        self.user_persist = UserPersist.init(&self.db);
        self.tenant_svc = TenantSvc.init(allocator, self.tenant_persist);
        self.user_svc = UserSvc.init(self.user_persist);
        self.tenant_api = TenantApiT.init(&self.tenant_svc);
        self.user_api = UserApiT.init(&self.user_svc);

        self.server = http.Server.init(io, allocator, 0);
        // Every middleware must be registered before the mounts below:
        // `addRoute` snapshots the global chain at registration time.
        try self.server.addMiddleware(http.tracingMiddleware());
        try self.server.addMiddleware(middleware.jwtAuthMiddleware(&self.sec.module, &self.slot, &self.db));
        try self.server.addMiddleware(middleware.tenantMiddleware());
        try self.server.addMiddleware(middleware.moduleGateMiddleware(&self.slot));
        try self.server.addMiddleware(middleware.permissionGateMiddleware(&self.slot));
        try self.server.addMiddleware(middleware.dataPermissionMiddleware());

        comptime http.assertNoDupes(.{ TenantApiT, UserApiT });
        self.router = http.Router(AppState).init(io, allocator, &self.server, &self.app_state);
        var api_v1 = self.router.scope("/api/v1");
        try api_v1.mountAll(.{
            .{ .Mod = TenantApiT, .state = &self.tenant_api },
            .{ .Mod = UserApiT, .state = &self.user_api },
        });
        self.slot.set(try self.router.finish());
    }

    fn teardown(self: *Stack) void {
        self.router.deinit();
        self.server.deinit();
        self.slot.deinit();
        self.db.deinit();
    }

    /// Dispatch with `Authorization: Bearer <token>` (or anonymously).
    fn call(self: *Stack, method: http.Method, path: []const u8, token: ?[]const u8) !http.Testkit.TestResponse {
        const t = token orelse return http.Testkit.dispatch(&self.server, method, path, null);
        var bearer_buf: [1024]u8 = undefined;
        const bearer = try http.Testkit.formatBearer(&bearer_buf, t);
        return http.Testkit.dispatchOpts(&self.server, method, path, .{
            .headers = &.{.{ "authorization", bearer }},
        });
    }

    /// Token whose `aud` is the tenant id — the claim the catalog JWT
    /// middleware turns into the request's `tenant_id` attr.
    fn tenantToken(self: *Stack, tenant_id: i64, roles: []const []const u8) ![]const u8 {
        var aud_buf: [24]u8 = undefined;
        const aud = try std.fmt.bufPrint(&aud_buf, "{d}", .{tenant_id});
        return self.sec.module.generateTokenWithTenant("1", roles, aud);
    }
};

test "Testkit.dispatch: /api/v1/tenants sits behind the JWT gate" {
    const allocator = std.testing.allocator;

    var s: Stack = undefined;
    try s.setup(allocator, std.testing.io);
    defer s.teardown();

    _ = try s.tenant_persist.insert(.{
        .id = 0,
        .name = "Acme",
        .domain = "acme.io",
        .status = 1,
        .tier = "pro",
        .created_at = 0,
        .updated_at = 0,
    });

    // Anonymous: the catalog middleware answers before the handler runs.
    var anon = try s.call(.GET, "/api/v1/tenants", null);
    defer anon.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 401), anon.status_code);
    try std.testing.expect(std.mem.indexOf(u8, anon.body, "Acme") == null);

    // `signBearerToken` mints a token this server actually verifies.
    const token = try http.Testkit.signBearerToken(&s.sec, allocator, "42", &.{"admin"});
    defer allocator.free(token);

    var authed = try s.call(.GET, "/api/v1/tenants", token);
    defer authed.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), authed.status_code);
    try std.testing.expectEqualStrings(
        "{\"tenants\":[{\"id\":1,\"name\":\"Acme\",\"domain\":\"acme.io\",\"tier\":\"pro\",\"status\":1}]}",
        authed.body,
    );

    // A token signed by a different secret is rejected — the gate is real.
    var other = security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "some-other-secret" });
    const forged = try http.Testkit.signBearerToken(&other, allocator, "42", &.{"admin"});
    defer allocator.free(forged);

    var rejected = try s.call(.GET, "/api/v1/tenants", forged);
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 401), rejected.status_code);
}

test "Testkit.signBearerToken: DELETE /tenants/{id} needs the tenant:suspend permission" {
    const allocator = std.testing.allocator;

    var s: Stack = undefined;
    try s.setup(allocator, std.testing.io);
    defer s.teardown();

    const tenant_id = try s.tenant_persist.insert(.{
        .id = 0,
        .name = "Acme",
        .domain = "acme.io",
        .status = 1,
        .tier = "pro",
        .created_at = 0,
        .updated_at = 0,
    });
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/v1/tenants/{d}", .{tenant_id});

    // Role `user` carries tenant:read only → the permission gate stops it.
    const reader = try http.Testkit.signBearerToken(&s.sec, allocator, "7", &.{"user"});
    defer allocator.free(reader);
    var forbidden = try s.call(.DELETE, path, reader);
    defer forbidden.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 403), forbidden.status_code);

    // Role `admin` carries tenant:suspend → the handler runs.
    const admin = try http.Testkit.signBearerToken(&s.sec, allocator, "1", &.{"admin"});
    defer allocator.free(admin);
    var ok = try s.call(.DELETE, path, admin);
    defer ok.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), ok.status_code);
    try std.testing.expectEqualStrings("{\"status\":\"suspended\"}", ok.body);

    // The suspended tenant is gone from the active list — the same request
    // that listed it a moment ago now returns an empty page.
    var listed = try s.call(.GET, "/api/v1/tenants", admin);
    defer listed.deinit(allocator);
    try std.testing.expectEqualStrings("{\"tenants\":[]}", listed.body);
}

test "tenant isolation: the token's aud scopes every /users query" {
    const allocator = std.testing.allocator;

    var s: Stack = undefined;
    try s.setup(allocator, std.testing.io);
    defer s.teardown();

    const globex = try s.tenant_persist.insert(.{
        .id = 0,
        .name = "Globex",
        .domain = "globex.io",
        .status = 1,
        .tier = "pro",
        .created_at = 0,
        .updated_at = 0,
    });
    const initech = try s.tenant_persist.insert(.{
        .id = 0,
        .name = "Initech",
        .domain = "initech.io",
        .status = 1,
        .tier = "free",
        .created_at = 0,
        .updated_at = 0,
    });
    _ = try s.user_svc.create(globex, "alice", "alice@globex.io", "admin");
    _ = try s.user_svc.create(initech, "bob", "bob@initech.io", "member");

    var alice_id: i64 = 0;
    var globex_users = try s.user_svc.listByTenant(globex);
    defer globex_users.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), globex_users.items.len);
    alice_id = globex_users.items[0].id;

    const globex_token = try s.tenantToken(globex, &.{"user"});
    defer allocator.free(globex_token);
    const initech_token = try s.tenantToken(initech, &.{"user"});
    defer allocator.free(initech_token);

    // Tenant 1 lists exactly its own user.
    var globex_list = try s.call(.GET, "/api/v1/users", globex_token);
    defer globex_list.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), globex_list.status_code);
    try std.testing.expectEqualStrings(
        "{\"users\":[{\"id\":1,\"tenant_id\":1,\"username\":\"alice\",\"email\":\"alice@globex.io\",\"role\":\"admin\"}]}",
        globex_list.body,
    );

    // Tenant 2 sees the mirror image — no row of the other tenant leaks in.
    var initech_list = try s.call(.GET, "/api/v1/users", initech_token);
    defer initech_list.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), initech_list.status_code);
    try std.testing.expect(std.mem.indexOf(u8, initech_list.body, "bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, initech_list.body, "alice") == null);

    // Guessing the other tenant's row id is a 404, not a leak.
    var path_buf: [64]u8 = undefined;
    const alice_path = try std.fmt.bufPrint(&path_buf, "/api/v1/users/{d}", .{alice_id});
    var stolen = try s.call(.GET, alice_path, initech_token);
    defer stolen.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), stolen.status_code);
    try std.testing.expect(std.mem.indexOf(u8, stolen.body, "alice") == null);

    // The owner still reads it.
    var own = try s.call(.GET, alice_path, globex_token);
    defer own.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), own.status_code);

    // No token at all: still a 401, tenant context or not.
    var anon = try s.call(.GET, "/api/v1/users", null);
    defer anon.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 401), anon.status_code);

    // A hand-written X-Tenant-ID contradicting the token's aud is refused
    // instead of silently switching tenants.
    var aud_buf: [24]u8 = undefined;
    const initech_aud = try std.fmt.bufPrint(&aud_buf, "{d}", .{initech});
    var bearer_buf: [1024]u8 = undefined;
    const bearer = try http.Testkit.formatBearer(&bearer_buf, globex_token);
    var conflict = try http.Testkit.dispatchOpts(&s.server, .GET, "/api/v1/users", .{
        .headers = &.{
            .{ "authorization", bearer },
            .{ "x-tenant-id", initech_aud },
        },
    });
    defer conflict.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 403), conflict.status_code);
}

// ── Observability: log line ← trace id ────────────────────────────────────
//
// The correlation recipe, end to end on the real chain:
//
//   inbound `X-Trace-Id` → `http.tracingMiddleware` → `ctx.setTraceId` (attr)
//     → handler reads `ctx.traceId()` → `TenantLog.withField("trace_id", …)`
//     → every line that handler writes ends with `trace_id=<id>`
//
// So a slow span (or an OTLP trace) can be walked to its log lines, and an
// error line back to its trace, with no ambient/global state in between.
test "trace id: the tenant handler's log scope carries the request's trace id" {
    const allocator = std.testing.allocator;
    const trace_id = "demo-trace-4bf92f35";

    var s: Stack = undefined;
    try s.setup(allocator, std.testing.io);
    defer s.teardown();

    const tenant_id = try s.tenant_persist.insert(.{
        .id = 0,
        .name = "Acme",
        .domain = "acme.io",
        .status = 1,
        .tier = "pro",
        .created_at = 0,
        .updated_at = 0,
    });
    const admin = try http.Testkit.signBearerToken(&s.sec, allocator, "1", &.{"admin"});
    defer allocator.free(admin);

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/v1/tenants/{d}", .{tenant_id});
    var bearer_buf: [1024]u8 = undefined;
    const bearer = try http.Testkit.formatBearer(&bearer_buf, admin);

    // Drive the real chain and keep the `Context` (Testkit.dispatch deinits it
    // and hands back status+body only) so the assertions can read the attrs and
    // headers the handler actually ran with.
    var ctx = try http.Context.init(allocator, .DELETE, path);
    defer ctx.deinit();
    try ctx.headers.put(try allocator.dupe(u8, "authorization"), try allocator.dupe(u8, bearer));
    try ctx.headers.put(try allocator.dupe(u8, "x-trace-id"), try allocator.dupe(u8, trace_id));

    // The test runner's log sink drops everything below warn; raise it here so
    // the handler's real line shows up in this test's output.
    const prev_level = std.testing.log_level;
    std.testing.log_level = .info;
    defer std.testing.log_level = prev_level;

    try s.server.handleForTest(&ctx);

    try std.testing.expectEqual(@as(u16, 200), ctx.status_code);

    // Producer half: the inbound id reached the handler's context and is echoed
    // back to the caller. (Without the tracing middleware both are null.)
    try std.testing.expectEqualStrings(trace_id, ctx.traceId().?);
    try std.testing.expectEqualStrings(trace_id, ctx.response_headers.get("x-trace-id").?);

    // Log half: `tracedLog` is the very function `suspendTenant` logs through, so
    // this asserts the handler's binding, not a re-typed copy of it. Zig's test
    // runner owns `std.log`'s sink, so a test cannot capture the emitted line
    // itself — `src/log/ModuleLogger.zig` pins "the suffix really lands in the
    // line", and the line itself is printed by the call above.
    const log = tenant_mod.api.tracedLog(&ctx);
    var suffix_buf: [zigmodu.observability.LogScope.suffix_capacity]u8 = undefined;
    try std.testing.expectEqualStrings(" trace_id=demo-trace-4bf92f35", log.fieldSuffix(&suffix_buf));
}
