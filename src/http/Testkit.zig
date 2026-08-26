//! HTTP test helpers — dispatch requests without listening on a port.
//!
//! Usage:
//!   const resp = try http.Testkit.dispatch(&server, .GET, "/health", null);
//!   defer resp.deinit(allocator);
//!
//! JWT + tenant:
//!   var sec = try http.Testkit.testSecurity(allocator, io);
//!   defer sec.deinit(); // no-op today; frees via allocator on tokens
//!   const token = try http.Testkit.signBearerToken(&sec, allocator, "42", &.{"admin"});
//!   defer allocator.free(token);

const std = @import("std");
const server_mod = @import("../api/Server.zig");
const AppSecurity = @import("../security/AppSecurity.zig").AppSecurity;
const data = @import("../data.zig");
const Sse = @import("Sse.zig");

pub const Method = server_mod.Method;
pub const Server = server_mod.Server;
pub const Context = server_mod.Context;
pub const Middleware = server_mod.Middleware;
pub const SseRecorder = Sse.SseRecorder;

pub const TestResponse = struct {
    status_code: u16,
    body: []const u8,
    body_owned: bool,

    pub fn deinit(self: *TestResponse, allocator: std.mem.Allocator) void {
        if (self.body_owned) allocator.free(self.body);
        self.* = undefined;
    }
};

pub const HeaderPair = struct { []const u8, []const u8 };
pub const AttrPair = struct { []const u8, []const u8 };

pub const DispatchOptions = struct {
    body: ?[]const u8 = null,
    /// Request headers (keys should be lowercase, matching production parser).
    headers: []const HeaderPair = &.{},
    /// Context attributes (e.g. `tenant_id`) injected before the middleware chain.
    attrs: []const AttrPair = &.{},
};

/// Match `path`, run middleware chain + handler, return response snapshot.
pub fn dispatch(server: *Server, method: Method, path: []const u8, body: ?[]const u8) !TestResponse {
    return dispatchOpts(server, method, path, .{ .body = body });
}

/// Same as `dispatch` with optional headers and attributes.
pub fn dispatchOpts(server: *Server, method: Method, path: []const u8, opts: DispatchOptions) !TestResponse {
    const allocator = server.allocator;

    var ctx = try Context.init(allocator, method, path);
    errdefer ctx.deinit();

    var body_owned: ?[]u8 = null;
    defer if (body_owned) |b| allocator.free(b);

    if (opts.body) |b| {
        body_owned = try allocator.dupe(u8, b);
        ctx.body = body_owned;
    }

    for (opts.headers) |pair| {
        const k = try allocator.dupe(u8, pair[0]);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, pair[1]);
        errdefer allocator.free(v);
        try ctx.headers.put(k, v);
    }

    for (opts.attrs) |pair| {
        try ctx.setAttr(pair[0], pair[1]);
    }

    try server.handleForTest(&ctx);

    const status = ctx.status_code;
    const response_body = try allocator.dupe(u8, ctx.response_body.items);

    ctx.deinit();

    return .{
        .status_code = status,
        .body = response_body,
        .body_owned = true,
    };
}

// ── JWT / SQLite / tenant helpers ──

/// Placeholder JWT for handler tests that do not verify signatures.
pub fn stubBearerToken(sub: []const u8) []const u8 {
    _ = sub;
    return "test-token-stub";
}

/// Create `AppSecurity` for tests (`jwt_secret = "testkit-secret"`).
pub fn testSecurity(allocator: std.mem.Allocator, io: std.Io) AppSecurity {
    return AppSecurity.init(allocator, io, .{ .jwt_secret = "testkit-secret" });
}

/// Mint a real HS256 JWT (caller frees with `allocator.free`).
pub fn signBearerToken(
    sec: *AppSecurity,
    allocator: std.mem.Allocator,
    user_id: []const u8,
    roles: []const []const u8,
) ![]const u8 {
    _ = allocator;
    return sec.generateToken(user_id, roles);
}

/// Format `Authorization: Bearer …` into `buf`. Returns the written slice.
pub fn formatBearer(buf: []u8, token: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "Bearer {s}", .{token});
}

/// Open in-memory SQLite via sqlx (`sqlite_path = ":memory:"`). Caller `deinit`s the client.
pub fn openMemorySqlite(allocator: std.mem.Allocator, io: std.Io) !data.Client {
    return data.Client.open(allocator, io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
}

/// Document-only hint (prefer `openMemorySqlite`).
pub fn memorySqliteHint() []const u8 {
    return "http.Testkit.openMemorySqlite(allocator, io)";
}

/// Middleware that injects `tenant_id` for scoped tests.
pub fn tenantMiddleware(tenant_id: []const u8) Middleware {
    const S = struct {
        var id: []const u8 = "";
        fn mw(ctx: *Context, next: server_mod.HandlerFn, _: ?*anyopaque) anyerror!void {
            try ctx.setAttr("tenant_id", id);
            try next(ctx);
        }
    };
    S.id = tenant_id;
    return .{ .func = S.mw, .user_data = null };
}

// ── Auth coverage audit (meta ↔ runtime) ─────────────────────────────────

const comptime_router = @import("../api/ComptimeRouter.zig");
const http_middleware = @import("../api/Middleware.zig");

pub const AuthAuditMismatch = struct {
    method: Method,
    /// Template path borrowed from the catalog (valid while the catalog lives).
    path: []const u8,
    expected_401: bool,
    /// 0 when the handler errored before responding (treated as "handler reached").
    got_status: u16,
};

/// Dispatch every catalog route WITHOUT credentials and verify meta ↔ runtime
/// agreement: non-public routes must reject 401, public routes must reach their
/// handler (any non-401 status). Returns the mismatches — empty slice = OK.
/// Wire the test server with the same middleware chain as production, fill
/// `slot` with `router.finish()`, then:
///
/// ```zig
/// const mismatches = try http.Testkit.auditAuthCoverage(alloc, &server, &slot);
/// defer alloc.free(mismatches);
/// try std.testing.expectEqual(@as(usize, 0), mismatches.len);
/// ```
///
/// `{param}` segments are dispatched as `1`; WS/SSE entries are skipped.
/// Paths in the result are borrowed from the catalog. Caller frees the slice.
pub fn auditAuthCoverage(
    allocator: std.mem.Allocator,
    server: *Server,
    slot: *const comptime_router.CatalogSlot,
) ![]AuthAuditMismatch {
    var out = std.ArrayList(AuthAuditMismatch).empty;
    errdefer out.deinit(allocator);
    const cat = slot.get() orelse return try out.toOwnedSlice(allocator);
    for (cat.entries) |e| {
        if (e.is_ws or e.is_sse) continue;
        const path = try concreteCatalogPath(allocator, e.path);
        defer allocator.free(path);
        const expect_401 = e.auth != .public;
        var resp = dispatch(server, e.method, path, null) catch {
            // Handler ran and errored (e.g. no recover middleware) → reached.
            if (expect_401) {
                try out.append(allocator, .{ .method = e.method, .path = e.path, .expected_401 = true, .got_status = 0 });
            }
            continue;
        };
        defer resp.deinit(allocator);
        if (expect_401 != (resp.status_code == 401)) {
            try out.append(allocator, .{ .method = e.method, .path = e.path, .expected_401 = expect_401, .got_status = resp.status_code });
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn concreteCatalogPath(allocator: std.mem.Allocator, template: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, template, '/');
    var first = true;
    while (it.next()) |seg| {
        if (!first) try out.append(allocator, '/');
        first = false;
        if (seg.len >= 2 and seg[0] == '{' and seg[seg.len - 1] == '}') {
            try out.appendSlice(allocator, "1");
        } else {
            try out.appendSlice(allocator, seg);
        }
    }
    return try out.toOwnedSlice(allocator);
}

test "dispatch hits registered route" {
    const allocator = std.testing.allocator;
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    try server.addRoute(.{
        .method = .GET,
        .path = "ping",
        .handler = struct {
            fn handle(ctx: *Context) !void {
                try ctx.text(200, "pong");
            }
        }.handle,
    });

    var resp = try dispatch(&server, .GET, "ping", null);
    defer resp.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("pong", resp.body);
}

test "dispatchOpts injects headers and attrs" {
    const allocator = std.testing.allocator;
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    try server.addRoute(.{
        .method = .GET,
        .path = "who",
        .handler = struct {
            fn handle(ctx: *Context) !void {
                const auth = ctx.header("authorization") orelse return error.Unauthorized;
                const tid = ctx.getAttr("tenant_id") orelse return error.Forbidden;
                try ctx.text(200, tid);
                _ = auth;
            }
        }.handle,
    });

    var auth_buf: [64]u8 = undefined;
    const auth = try formatBearer(&auth_buf, stubBearerToken("u1"));

    var resp = try dispatchOpts(&server, .GET, "who", .{
        .headers = &.{.{ "authorization", auth }},
        .attrs = &.{.{ "tenant_id", "acme" }},
    });
    defer resp.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("acme", resp.body);
}

test "signBearerToken verifies with AppSecurity" {
    const allocator = std.testing.allocator;
    var sec = testSecurity(allocator, std.testing.io);
    const token = try signBearerToken(&sec, allocator, "42", &.{"admin"});
    defer allocator.free(token);

    const payload = try sec.module.verifyToken(token);
    defer sec.module.freePayload(payload);
    try std.testing.expectEqualStrings("42", payload.sub);
}

test "openMemorySqlite connects" {
    const allocator = std.testing.allocator;
    var client = try openMemorySqlite(allocator, std.testing.io);
    defer client.deinit();
    _ = try client.exec("SELECT 1", &.{});
}

test "dispatch 404 for unknown route" {
    const allocator = std.testing.allocator;
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    var resp = try dispatch(&server, .GET, "/nope", null);
    defer resp.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
}

test "tenantMiddleware sets attr" {
    const allocator = std.testing.allocator;
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    try server.addMiddleware(tenantMiddleware("t-42"));
    try server.addRoute(.{
        .method = .GET,
        .path = "tenant",
        .handler = struct {
            fn handle(ctx: *Context) !void {
                try ctx.text(200, ctx.getAttr("tenant_id") orelse "missing");
            }
        }.handle,
    });

    var resp = try dispatch(&server, .GET, "tenant", null);
    defer resp.deinit(allocator);
    try std.testing.expectEqualStrings("t-42", resp.body);
}

test "auditAuthCoverage flags meta ↔ runtime drift" {
    const allocator = std.testing.allocator;
    const comptime_router2 = comptime_router;
    const SecurityModule = @import("../security/SecurityModule.zig").SecurityModule;

    const AppState = struct {};
    var app: AppState = .{};
    const Mod = struct {
        pub const module_name = "order";
        pub const nest = .{"orders"};
        pub const State = struct {};
        fn ok(ctx: *Context, _: *State) !void {
            try ctx.text(200, "ok");
        }
        pub const routes = [_]comptime_router2.RouteSpec(State){
            .{ .method = .GET, .path = "health", .handler = ok, .meta = .{ .auth = .public } },
            .{ .method = .GET, .path = "list", .handler = ok, .meta = .{ .auth = .jwt } },
            .{ .method = .GET, .path = "{id}", .handler = ok, .meta = .{ .auth = .jwt } },
        };
    };
    var st = Mod.State{};

    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var router = comptime_router2.Router(AppState).init(std.testing.io, allocator, &server, &app);
    defer router.deinit();

    // Middleware must be registered BEFORE mounts: combined_middleware is a
    // snapshot of global_middleware at addRoute time.
    var slot: comptime_router2.CatalogSlot = .{};
    defer slot.deinit();
    var sec = SecurityModule.init(allocator, "test-secret", 3600);
    try server.addMiddleware(http_middleware.jwtAuthFromCatalog(&sec, &slot, .{}));

    var scope = router.scope("/api");
    try scope.mount(Mod, &st);
    slot.set(try router.finish());

    // meta matches runtime → no mismatches
    const good = try auditAuthCoverage(allocator, &server, &slot);
    defer allocator.free(good);
    try std.testing.expectEqual(@as(usize, 0), good.len);

    // Without the auth middleware the jwt routes are reachable → drift flagged.
    var bare_server = Server.init(std.testing.io, allocator, 0);
    defer bare_server.deinit();
    var router2 = comptime_router2.Router(AppState).init(std.testing.io, allocator, &bare_server, &app);
    defer router2.deinit();
    var scope2 = router2.scope("/api");
    try scope2.mount(Mod, &st);
    var slot2: comptime_router2.CatalogSlot = .{};
    defer slot2.deinit();
    slot2.set(try router2.finish());

    const bad = try auditAuthCoverage(allocator, &bare_server, &slot2);
    defer allocator.free(bad);
    try std.testing.expectEqual(@as(usize, 2), bad.len);
    for (bad) |m| {
        try std.testing.expect(m.expected_401);
        try std.testing.expectEqual(@as(u16, 200), m.got_status);
    }
}
