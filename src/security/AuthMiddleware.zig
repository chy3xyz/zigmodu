const std = @import("std");
const api = @import("../api/Server.zig");
const SecurityModule = @import("SecurityModule.zig").SecurityModule;
const Rbac = @import("Rbac.zig");

/// Loads permissions for the authenticated user into `auth.permissions`.
/// Called after JWT verification with `auth.role_ids` already populated.
/// Keys inserted into the map MUST be allocated with `allocator` — they are
/// freed by `AuthInfo.deinit`. Typically backed by a role→permission DB query:
///
///   fn loadPerms(allocator: std.mem.Allocator, auth: *Rbac.AuthInfo) !void {
///       for (auth.role_ids) |rid| {
///           const perms = try db.queryPermissions(rid);
///           for (perms) |p| try auth.permissions.put(try allocator.dupe(u8, p), true);
///       }
///   }
pub const PermissionLoader = *const fn (allocator: std.mem.Allocator, auth: *Rbac.AuthInfo) anyerror!void;

/// JWT authentication middleware — verifies token, builds AuthInfo, stores it in
/// `ctx.auth_info` only (does **not** touch `ctx.user_data`).
///
/// Safe with ComptimeRouter: route `*State` stays in `user_data`; read auth via
/// `getAuth(ctx)` / `ctx.authInfo(Rbac.AuthInfo)`. Catalog stack
/// (`http.jwtAuthFromCatalogWithPermissions`) remains preferred for new apps
/// (see `docs/ROUTE_TABLE.md`).
///
/// NOTE: `AuthInfo.permissions` stays empty with this variant, so requirePermission()
/// will always deny. Use `jwtAuthWithPermissions` when permission checks are needed.
pub fn jwtAuth(security: *SecurityModule, allocator: std.mem.Allocator) !api.Middleware {
    const Store = struct {
        security: *SecurityModule,
        allocator: std.mem.Allocator,
    };
    // One store per call: a function-level `var` is process-wide, so a second
    // `jwtAuth` (another server, another secret) would silently overwrite the
    // first one's security module and make both verify with the last secret.
    const stored = std.heap.page_allocator.create(Store) catch @panic("jwtAuth setup: out of memory");
    stored.* = .{ .security = security, .allocator = allocator };

    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const st: *const Store = @ptrCast(@alignCast(user_data.?));
                try runJwtAuth(ctx, next, st.security, st.allocator, null);
            }
        }.mw,
        .user_data = stored,
    };
}

/// JWT authentication + RBAC permission loading. Same as `jwtAuth`, but invokes
/// `loader` after token verification to populate `AuthInfo.permissions`, making
/// requirePermission/requireAnyPermission/requireAllPermissions functional.
pub fn jwtAuthWithPermissions(security: *SecurityModule, allocator: std.mem.Allocator, loader: PermissionLoader) !api.Middleware {
    const Store = struct {
        security: *SecurityModule,
        allocator: std.mem.Allocator,
        loader: PermissionLoader,
    };
    const stored = std.heap.page_allocator.create(Store) catch @panic("jwtAuthWithPermissions setup: out of memory");
    stored.* = .{ .security = security, .allocator = allocator, .loader = loader };

    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const st: *const Store = @ptrCast(@alignCast(user_data.?));
                try runJwtAuth(ctx, next, st.security, st.allocator, st.loader);
            }
        }.mw,
        .user_data = stored,
    };
}

fn runJwtAuth(
    ctx: *api.Context,
    next: api.HandlerFn,
    security: *SecurityModule,
    allocator: std.mem.Allocator,
    loader: ?PermissionLoader,
) anyerror!void {
    const auth_header = ctx.headers.get("authorization") orelse {
        try ctx.sendErrorResponse(401, 401, "Missing Authorization header");
        return;
    };

    const token = SecurityModule.extractBearerToken(auth_header) orelse {
        try ctx.sendErrorResponse(401, 401, "Invalid Authorization header format");
        return;
    };

    // verifyToken returns JwtPayload directly. Its failure set holds two
    // different kinds of failure and does not tag which is which, so the ones
    // that describe *the presented token* are listed here and everything else
    // is answered 500. Without that split an allocation failure inside
    // verification — or any internal fault added later — is reported as
    // "Invalid or expired token": the legacy path is the only one that writes
    // `auth_info`, so a 401 here is indistinguishable from a genuine bad token
    // and the real fault would never surface.
    //
    // The same classification, by the same error names, is what
    // `api.Middleware.noteVerifyFailure` does for the catalog/backend path
    // (private there, so it cannot be shared); this is its counterpart for the
    // legacy middleware. Enumerating the token's errors rather than ours means
    // an error added to `verifyToken` later surfaces as a 5xx — the safe
    // direction — instead of silently joining the 401 group.
    const payload = security.verifyToken(token) catch |err| {
        switch (err) {
            // The client's credential is unusable/expired — retrying the same
            // token cannot help, and 401 is what every consumer expects.
            error.InvalidToken,
            error.InvalidSignature,
            error.TokenExpired,
            error.UnsupportedAlgorithm,
            // A `kid` we hold no key for: the token names a key we retired.
            error.UnknownKeyId,
            // Base64 errors fire on whichever segment is malformed. The header
            // segment is client data decoded before the signature check; the
            // payload segment is decoded after it, so this name also covers a
            // corrupt token we signed ourselves. The error set cannot tell the
            // two apart at this layer, and both mean "unusable credential".
            error.InvalidEncoding,
            error.InvalidPadding,
            error.InvalidCharacter,
            => try ctx.sendErrorResponse(401, 401, "Invalid or expired token"),
            // Our side: the module's allocator refused (OutOfMemory), a decode
            // ran out of destination space, or a payload we signed failed to
            // parse as JSON — none of it is a property of the request's token.
            //
            // `warn`, not `err`: `scripts/test-runner.zig` fails the suite on
            // any err-level log, so a branch a test can drive has to warn (the
            // same call `ClusterBootstrap`'s cluster-auth gate made — see
            // `docs/dev/cluster-auth-design.md` §"实现期对设计的两处收紧").
            else => {
                std.log.warn("jwt verification failed inside the server: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "Token verification failed");
            },
        }
        return;
    };
    defer security.freePayload(payload);

    // Build AuthInfo from JWT payload. Reject malformed numeric fields.
    const user_id = std.fmt.parseInt(i64, payload.sub, 10) catch {
        try ctx.sendErrorResponse(401, 401, "Invalid token: sub claim is not a valid user ID");
        return;
    };
    const tenant_id = std.fmt.parseInt(i64, payload.aud, 10) catch {
        try ctx.sendErrorResponse(401, 401, "Invalid token: aud claim is not a valid tenant ID");
        return;
    };
    var auth = Rbac.AuthInfo{
        .user_id = user_id,
        .tenant_id = tenant_id,
        .username = allocator.dupe(u8, payload.sub) catch return error.OutOfMemory,
        .role_ids = &.{},
        .permissions = std.StringHashMap(bool).init(allocator),
    };

    // Copy role strings. Reject malformed role IDs.
    if (payload.roles.len > 0) {
        const role_ids = allocator.alloc(i64, payload.roles.len) catch return error.OutOfMemory;
        for (payload.roles, 0..) |role_str, i| {
            role_ids[i] = std.fmt.parseInt(i64, role_str, 10) catch {
                allocator.free(role_ids);
                var partial = auth;
                partial.role_ids = &.{};
                partial.deinit(allocator);
                try ctx.sendErrorResponse(401, 401, "Invalid token: role claim contains non-numeric value");
                return;
            };
        }
        auth.role_ids = role_ids;
    }

    // Store auth only in auth_info — never overwrite user_data (ComptimeRouter State).
    const auth_ptr = allocator.create(Rbac.AuthInfo) catch return error.OutOfMemory;
    auth_ptr.* = auth;
    ctx.auth_info = @ptrCast(auth_ptr);
    defer {
        auth_ptr.deinit(allocator);
        allocator.destroy(auth_ptr);
        ctx.auth_info = null;
    }

    // Populate permissions from roles (RBAC) before the handler chain runs.
    if (loader) |load| {
        load(allocator, auth_ptr) catch |err| {
            std.log.err("permission loader failed for user {d}: {s}", .{ user_id, @errorName(err) });
            try ctx.sendErrorResponse(500, 500, "Failed to load permissions");
            return;
        };
    }

    try next(ctx);
}

/// Permission middleware — must run after jwtAuth.
/// `perm` is captured at comptime (use a string literal).
pub fn requirePermission(comptime perm: []const u8) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const auth = getAuth(ctx) orelse {
                    try ctx.sendErrorResponse(403, 403, "Authentication required before permission check");
                    return;
                };

                if (!auth.hasPermission(perm)) {
                    try ctx.sendErrorResponse(403, 403, "Permission denied");
                    return;
                }
                try next(ctx);
            }
        }.mw,
    };
}

/// Require any of the given permissions (comptime list of string literals).
pub fn requireAnyPermission(comptime perms: []const []const u8) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const auth = getAuth(ctx) orelse {
                    try ctx.sendErrorResponse(403, 403, "Authentication required before permission check");
                    return;
                };

                if (!auth.hasAnyPermission(perms)) {
                    try ctx.sendErrorResponse(403, 403, "Permission denied");
                    return;
                }
                try next(ctx);
            }
        }.mw,
    };
}

/// Require all of the given permissions (comptime list of string literals).
pub fn requireAllPermissions(comptime perms: []const []const u8) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const auth = getAuth(ctx) orelse {
                    try ctx.sendErrorResponse(403, 403, "Authentication required before permission check");
                    return;
                };

                if (!auth.hasAllPermissions(perms)) {
                    try ctx.sendErrorResponse(403, 403, "Permission denied");
                    return;
                }
                try next(ctx);
            }
        }.mw,
    };
}

/// Read AuthInfo set by `jwtAuth` / `jwtAuthWithPermissions` / `rbacJwtMiddleware*`.
/// Only `ctx.auth_info` — never cast `user_data` (may be ComptimeRouter State).
pub fn getAuth(ctx: *api.Context) ?*Rbac.AuthInfo {
    return ctx.authInfo(Rbac.AuthInfo);
}

fn testPutBearerAuth(ctx: *api.Context, token: []const u8) !void {
    const k = try ctx.allocator.dupe(u8, "authorization");
    errdefer ctx.allocator.free(k);
    const v = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{token});
    errdefer ctx.allocator.free(v);
    try ctx.headers.put(k, v);
}

test "jwtAuthWithPermissions loads permissions and passes requirePermission" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "test-secret", 3600);
    const token = try sec.generateTokenWithTenant("42", &.{"7"}, "1");
    defer allocator.free(token);

    var ctx = try api.Context.init(allocator, .GET, "/tenants");
    defer ctx.deinit();
    try testPutBearerAuth(&ctx, token);

    const S = struct {
        var loader_called: bool = false;
        var handler_reached: bool = false;
        var seen_role: i64 = 0;

        fn loadPerms(alloc: std.mem.Allocator, auth: *Rbac.AuthInfo) anyerror!void {
            loader_called = true;
            if (auth.role_ids.len > 0) seen_role = auth.role_ids[0];
            try auth.permissions.put(try alloc.dupe(u8, "tenant:read"), true);
        }

        fn handler(c: *api.Context) anyerror!void {
            const auth = getAuth(c) orelse return error.MissingAuth;
            if (!auth.hasPermission("tenant:read")) return error.PermissionDenied;
            handler_reached = true;
        }
    };

    const auth_mw = try jwtAuthWithPermissions(&sec, allocator, S.loadPerms);

    // Chain: jwtAuthWithPermissions → requirePermission → handler
    const Chain = struct {
        fn permThenHandler(c: *api.Context) anyerror!void {
            const perm_mw = requirePermission("tenant:read");
            try perm_mw.func(c, S.handler, perm_mw.user_data);
        }
    };

    try auth_mw.func(&ctx, Chain.permThenHandler, auth_mw.user_data);

    try std.testing.expect(S.loader_called);
    try std.testing.expectEqual(@as(i64, 7), S.seen_role);
    try std.testing.expect(S.handler_reached);
    try std.testing.expect(!ctx.responded);
}

test "jwtAuth without loader leaves permissions empty (requirePermission denies)" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "test-secret", 3600);
    const token = try sec.generateTokenWithTenant("42", &.{}, "1");
    defer allocator.free(token);

    var ctx = try api.Context.init(allocator, .GET, "/tenants");
    defer ctx.deinit();
    try testPutBearerAuth(&ctx, token);

    const S = struct {
        var denied: bool = false;
        fn checkPerms(c: *api.Context) anyerror!void {
            const auth = getAuth(c) orelse return error.MissingAuth;
            denied = !auth.hasPermission("tenant:read");
        }
    };

    const auth_mw = try jwtAuth(&sec, allocator);
    try auth_mw.func(&ctx, S.checkPerms, auth_mw.user_data);
    try std.testing.expect(S.denied);
}

test "jwtAuth preserves ComptimeRouter user_data State" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "test-secret", 3600);
    const token = try sec.generateTokenWithTenant("42", &.{}, "1");
    defer allocator.free(token);

    const RouteState = struct { n: i32 };
    var state = RouteState{ .n = 99 };

    var ctx = try api.Context.init(allocator, .GET, "/page");
    defer ctx.deinit();
    ctx.user_data = @ptrCast(&state);
    try testPutBearerAuth(&ctx, token);

    const S = struct {
        var saw_state: i32 = 0;
        var saw_auth: bool = false;
        fn handler(c: *api.Context) anyerror!void {
            const st = c.userData(RouteState) orelse return error.MissingRouteState;
            saw_state = st.n;
            saw_auth = getAuth(c) != null;
        }
    };

    const auth_mw = try jwtAuth(&sec, allocator);
    try auth_mw.func(&ctx, S.handler, auth_mw.user_data);
    try std.testing.expectEqual(@as(i32, 99), S.saw_state);
    try std.testing.expect(S.saw_auth);
    try std.testing.expect(ctx.userData(RouteState) != null);
    try std.testing.expectEqual(@as(i32, 99), ctx.userData(RouteState).?.n);
}

test "jwtAuth answers 5xx, not 401, when verification fails on our side" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "test-secret", 3600);
    const token = try sec.generateTokenWithTenant("42", &.{}, "1");
    defer allocator.free(token);

    var ctx = try api.Context.init(allocator, .GET, "/tenants");
    defer ctx.deinit();
    try testPutBearerAuth(&ctx, token);

    // Every allocation `verifyToken` makes from here on fails, so the failure
    // cannot be a property of the token: it is a genuine, unexpired one.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    sec.allocator = failing.allocator();

    const S = struct {
        var reached: bool = false;
        fn handler(_: *api.Context) anyerror!void {
            reached = true;
        }
    };
    S.reached = false;
    const auth_mw = try jwtAuth(&sec, allocator);
    try auth_mw.func(&ctx, S.handler, auth_mw.user_data);

    try std.testing.expect(!S.reached);
    try std.testing.expectEqual(@as(u16, 500), ctx.status_code);
}

test "jwtAuth still answers 401 for a token that is genuinely bad" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "test-secret", 3600);
    // Signed with a secret this middleware does not hold.
    var other = SecurityModule.init(allocator, "another-secret", 3600);
    const foreign = try other.generateTokenWithTenant("42", &.{}, "1");
    defer allocator.free(foreign);

    const S = struct {
        var reached: bool = false;
        fn handler(_: *api.Context) anyerror!void {
            reached = true;
        }
    };

    var ctx_bad = try api.Context.init(allocator, .GET, "/tenants");
    defer ctx_bad.deinit();
    try testPutBearerAuth(&ctx_bad, foreign);
    const mw = try jwtAuth(&sec, allocator);
    try mw.func(&ctx_bad, S.handler, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), ctx_bad.status_code);
    try std.testing.expect(!S.reached);

    // …and for an expired one, which is a client-side fact, not our fault.
    var expiring = SecurityModule.init(allocator, "test-secret", -1);
    const expired = try expiring.generateTokenWithTenant("42", &.{}, "1");
    defer allocator.free(expired);

    var ctx_expired = try api.Context.init(allocator, .GET, "/tenants");
    defer ctx_expired.deinit();
    try testPutBearerAuth(&ctx_expired, expired);
    const mw2 = try jwtAuth(&expiring, allocator);
    try mw2.func(&ctx_expired, S.handler, mw2.user_data);
    try std.testing.expectEqual(@as(u16, 401), ctx_expired.status_code);
    try std.testing.expect(!S.reached);
}

test "each jwtAuth keeps its own security module" {
    const allocator = std.testing.allocator;
    var sec_a = SecurityModule.init(allocator, "secret-a", 3600);
    var sec_b = SecurityModule.init(allocator, "secret-b", 3600);
    const token_a = try sec_a.generateTokenWithTenant("42", &.{}, "1");
    defer allocator.free(token_a);

    const mw_a = try jwtAuth(&sec_a, allocator);
    const mw_b = try jwtAuth(&sec_b, allocator);

    const S = struct {
        var reached: bool = false;
        fn handler(_: *api.Context) anyerror!void {
            reached = true;
        }
    };

    // A token signed with A's secret must verify against A's middleware — the
    // two middlewares may not share one `stored_security`, or the last one built
    // would decide for both (cross-instance identity confusion).
    var ctx_a = try api.Context.init(allocator, .GET, "/tenants");
    defer ctx_a.deinit();
    try testPutBearerAuth(&ctx_a, token_a);
    try mw_a.func(&ctx_a, S.handler, mw_a.user_data);
    try std.testing.expect(!ctx_a.responded);
    try std.testing.expect(S.reached);

    // …and B's rejects it.
    S.reached = false;
    var ctx_b = try api.Context.init(allocator, .GET, "/tenants");
    defer ctx_b.deinit();
    try testPutBearerAuth(&ctx_b, token_a);
    try mw_b.func(&ctx_b, S.handler, mw_b.user_data);
    try std.testing.expectEqual(@as(u16, 401), ctx_b.status_code);
    try std.testing.expect(!S.reached);
}
