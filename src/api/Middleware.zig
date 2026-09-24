//! Lightweight middleware for ZigModu HTTP server.
//!
//! Recommended production middleware chain (order matters):
//!   recover → requestId → cors → jwtAuth → csrf → rateLimit → handler
//!
//! Example:
//!   server.addMiddleware(zigmodu.http_middleware.recover());
//!   server.addMiddleware(zigmodu.http_middleware.requestId());
//!   server.addMiddleware(zigmodu.http_middleware.cors(.{}));
//!   server.addMiddleware(zigmodu.http_middleware.jwtAuth("my-secret"));
//!   // Production (wall-clock exp): share a SecurityModule initialized with initWithIo
//!   server.addMiddleware(zigmodu.http_middleware.jwtAuthWithSecurity(&sec));
//!   server.addMiddleware(zigmodu.http_middleware.csrf());
//!
//! STRUCTURE:
//!   §1  Reject hooks & envelopes —— AuthRejectFn, defaultReject, problemReject, envelopeReject
//!   §2  CORS —— CorsConfig and the cors middleware
//!   §3  Core middleware —— requestId, logging, maxBodySize, requestTimeout, recover, legacy jwtAuth
//!   §4  Catalog JWT & permission loading —— jwtAuthFromCatalog*, CatalogPermissionLoader, attachIdentity
//!   §5  Pluggable auth backends —— AuthBackend and authFromCatalog (catalog = sole bypass truth)
//!   §6  Token extraction, JWT backend & tenant resolver —— extract*, jwtBackend*, tenantResolver
//!   §7  Module gate & permission gate —— moduleGate, permissionMatches*, permissionGate*
//!   §8  CSRF & security headers —— csrf, defaultSecurityHeaders, securityHeaders, defaultCsp
//!   §9  Tests —— auth / CORS / CSRF / gate unit tests
//!
//! Every section carries a matching `// ==== §N ... ====` anchor — `grep "§4"` jumps there.

const std = @import("std");
const api = @import("Server.zig");
const Time = @import("../core/Time.zig");
const SecurityModule = @import("../security/SecurityModule.zig").SecurityModule;
const ProblemDetails = @import("../http/ProblemDetails.zig").ProblemDetails;

// ==== §1  Reject hooks & envelopes ====

/// Consumer hook for auth rejections: renders the 401/403/500 body in any
/// envelope dialect without forking middleware. Default = `ctx.sendError`.
pub const AuthRejectFn = *const fn (ctx: *api.Context, status: u16, message: []const u8) anyerror!void;

/// Default rejection renderer: the legacy envelope
/// `{"code":status,"msg":…,"data":null}` via `ctx.sendError`.
///
/// `ctx.sendError` honours the process-wide error renderer, so a gate that
/// leaves `.reject` at this default follows `http.useRfc7807Errors()`. Use
/// `ctx.sendErrorEnvelope` from a custom renderer if you need the envelope
/// unconditionally.
pub fn defaultReject(ctx: *api.Context, status: u16, message: []const u8) anyerror!void {
    try ctx.sendError(status, message);
}

/// Rejection renderer emitting RFC 7807 ProblemDetails with `instance` set to
/// the request path, and media type `application/problem+json`.
///
/// Install process-wide with `setDefaultReject(problemReject)` /
/// `useRfc7807Errors()`, or per gate with `.reject = problemReject`.
pub fn problemReject(ctx: *api.Context, status: u16, message: []const u8) anyerror!void {
    const problem = ProblemDetails.init(status, message, ctx.path);
    const json = try problem.toJson(ctx.allocator);
    defer ctx.allocator.free(json);
    try ctx.json(status, json);
    try ctx.setHeader("Content-Type", "application/problem+json");
}

/// `api.TransportErrorFn` implementation: RFC 7807 body for errors raised
/// before routing, allocated into the caller's scratch buffer.
pub fn problemTransportBody(status: u16, message: []const u8, buf: []u8) api.TransportErrorBody {
    const problem = ProblemDetails.init(status, message, null);
    return .{
        .content_type = "application/problem+json",
        .body = problem.writeToBuf(buf),
    };
}

/// Install the process-wide renderer for in-chain errors — every internal
/// `ctx.sendError` / `ctx.sendErrorResponse` (moduleGate 403/404, CSRF 413/403,
/// request-timeout 408, the uncaught-handler 500, static-file errors) plus any
/// gate left at the `.reject = defaultReject` default.
///
/// Pass `null` to restore the legacy envelope. Call once at startup: the global
/// is read per request and is not synchronised with in-flight traffic.
pub fn setDefaultReject(renderer: ?AuthRejectFn) void {
    // `defaultReject` writes through `ctx.sendError`, which is the call the
    // renderer hook intercepts — installing it as the renderer would recurse.
    // `null` is how "keep the legacy envelope" is expressed.
    const resolved: ?AuthRejectFn = if (renderer) |f| (if (f == defaultReject) null else f) else null;
    api.setErrorRenderer(resolved);
}

/// Make every framework-generated error body RFC 7807 ProblemDetails, in one
/// call — both the middleware-chain sites and the pre-routing transport errors
/// (408/413/431/503). Call once during startup, before `app.start()`.
///
/// Handlers that already use `ctx.json` / `http.respondErr`, and gates given an
/// explicit `.reject` (e.g. `envelopeReject(.thinkphp)`), are unaffected.
pub fn useRfc7807Errors() void {
    setDefaultReject(problemReject);
    api.setTransportErrorRenderer(problemTransportBody);
}

/// Remove the process-wide renderers installed by `useRfc7807Errors`, restoring
/// the legacy envelope and `{"error":…}` bodies. Intended for tests.
pub fn clearDefaultReject() void {
    api.setErrorRenderer(null);
    api.setTransportErrorRenderer(null);
}

/// Rejection renderer for an envelope dialect: 401 → `ctx.unauth` (ThinkPHP
/// `{code:-1}` etc.); other statuses keep the HTTP status with an aligned code.
pub fn envelopeReject(dialect: api.EnvelopeDialect) AuthRejectFn {
    const S = struct {
        var d: api.EnvelopeDialect = .default;
        fn reject(ctx: *api.Context, status: u16, message: []const u8) anyerror!void {
            if (status == 401) {
                ctx.setEnvelope(d);
                return ctx.unauth(message);
            }
            try ctx.respondEnvelope(status, @intCast(status), message, "null");
        }
    };
    S.d = dialect;
    return S.reject;
}

// ==== §2  CORS ====

/// CORS middleware configuration
pub const CorsConfig = struct {
    allow_origins: []const []const u8 = &.{"*"},
    allow_methods: []const u8 = "GET,POST,PUT,DELETE,PATCH,HEAD,OPTIONS",
    allow_headers: []const u8 = "Content-Type,Authorization",
    max_age: u32 = 86400,
};

/// CORS middleware — config stored at module scope to avoid heap allocation.
pub fn cors(config: CorsConfig) api.Middleware {
    // An empty allowlist rejects every cross-origin request — including the
    // preflight — with no other signal, which reads as "CORS is broken" during
    // integration. Default is `&.{"*"}` (allow all), so this only fires when a
    // caller deliberately passed an empty list.
    if (config.allow_origins.len == 0) {
        std.log.warn("[cors] allow_origins is empty: every cross-origin request (and preflight) will be rejected with 403", .{});
    }
    // Per-instance configuration on `user_data` (allocated once, process
    // lifetime): multiple Servers / registrations with different configs no
    // longer overwrite each other via module-level statics.
    const cfg = std.heap.page_allocator.create(CorsConfig) catch @panic("cors middleware setup: out of memory");
    cfg.* = config;
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const c: *const CorsConfig = @ptrCast(@alignCast(user_data.?));
                // `header()` is case-insensitive (RFC 9110): request header keys are
                // lowercased at parse time, so `ctx.headers.get("Origin")` would never
                // match a browser's `Origin:` header and every origin would be treated
                // as same-origin. Regression test: "cors matches Origin case-insensitively".
                const origin = ctx.header("Origin") orelse "";

                // Validate origin against whitelist; reject if not allowed
                var origin_allowed = false;
                if (std.mem.eql(u8, origin, "")) {
                    origin_allowed = true; // Same-origin request
                } else {
                    for (c.allow_origins) |allowed| {
                        const matched = if (std.mem.eql(u8, allowed, "*")) true else if (std.mem.startsWith(u8, allowed, "*.")) std.mem.endsWith(u8, origin, allowed[1..]) else std.mem.eql(u8, allowed, origin);
                        if (matched) {
                            origin_allowed = true;
                            break;
                        }
                    }
                }

                if (!origin_allowed) {
                    ctx.status_code = 403;
                    ctx.responded = true;
                    return;
                }

                if (c.allow_origins.len > 0 and !std.mem.eql(u8, c.allow_origins[0], "*")) {
                    try ctx.setHeader("Access-Control-Allow-Origin", origin);
                    try ctx.setHeader("Vary", "Origin");
                } else if (c.allow_origins.len > 0) {
                    try ctx.setHeader("Access-Control-Allow-Origin", c.allow_origins[0]);
                }
                try ctx.setHeader("Access-Control-Allow-Methods", c.allow_methods);
                try ctx.setHeader("Access-Control-Allow-Headers", c.allow_headers);
                const max_age_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{c.max_age});
                defer ctx.allocator.free(max_age_str);
                try ctx.setHeader("Access-Control-Max-Age", max_age_str);
                if (ctx.method == .OPTIONS) {
                    ctx.status_code = 204;
                    ctx.responded = true;
                    return;
                }
                try next(ctx);
            }
        }.mw,
        .user_data = cfg,
    };
}

// ==== §3  Core middleware ====

var request_id_counter = std.atomic.Value(u64).init(0);

/// Request ID middleware - adds X-Request-Id header
pub fn requestId() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const id = try std.fmt.allocPrint(ctx.allocator, "{x:0>16}", .{request_id_counter.fetchAdd(1, .monotonic)});
                defer ctx.allocator.free(id);
                try ctx.setHeader("X-Request-Id", id);
                try next(ctx);
            }
        }.mw,
    };
}

/// Logging middleware - logs request method, path, status and duration
pub fn logging() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const start_ms = Time.monotonicNowMilliseconds();
                try next(ctx);
                const elapsed = Time.monotonicNowMilliseconds() - start_ms;
                std.log.info("{s} {s} {d} {d}ms", .{
                    ctx.method.toString(),
                    ctx.raw_path,
                    ctx.status_code,
                    elapsed,
                });
            }
        }.mw,
    };
}

/// Max body size middleware
pub fn maxBodySize(max_size: usize) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const limit = @as(usize, @intFromPtr(user_data));
                if (ctx.body) |body| {
                    if (body.len > limit) {
                        try ctx.sendError(413, "Payload Too Large");
                        return;
                    }
                }
                try next(ctx);
            }
        }.mw,
        .user_data = @ptrFromInt(max_size),
    };
}

/// Request timeout middleware — marks the response 504 when the handler
/// exceeded the budget (post-hoc: fiber-based handlers cannot be preempted).
pub fn requestTimeout(timeout_ms: u64) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const budget_ms: i64 = @intCast(@intFromPtr(user_data));
                const start_ms = Time.monotonicNowMilliseconds();
                try next(ctx);
                if (Time.monotonicNowMilliseconds() - start_ms > budget_ms and !ctx.responded) {
                    ctx.status_code = 504;
                }
            }
        }.mw,
        .user_data = @ptrFromInt(timeout_ms),
    };
}

/// Recovery middleware - catches panics and returns 500
pub fn recover() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                next(ctx) catch |err| {
                    std.log.warn("Handler panic: {any}", .{err});
                    if (!ctx.responded) {
                        try ctx.sendError(500, "Internal Server Error");
                    }
                };
            }
        }.mw,
    };
}

/// JWT auth middleware — validates Bearer token via `SecurityModule.verifyToken`.
/// Uses `ctx.io` for wall-clock expiry when set; falls back to monotonic in unit tests.
///
/// The ephemeral `SecurityModule` here is a zero-allocation struct, so per-request
/// construction is free. The expiry argument is irrelevant for verification (the
/// token's own `exp` claim is checked) — it only matters for token GENERATION,
/// so use `jwtAuthWithSecurity` / `AppSecurity` when you also issue tokens.
pub fn jwtAuth(secret: []const u8) api.Middleware {
    const secret_copy = std.heap.page_allocator.create([]const u8) catch @panic("jwtAuth setup: out of memory");
    secret_copy.* = secret;
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const stored: []const u8 = @as(*const []const u8, @ptrCast(@alignCast(user_data.?))).*;
                // Expiry 0: verification-only module, never generates tokens.
                var sec = if (ctx.io) |io|
                    SecurityModule.initWithIo(ctx.allocator, stored, 0, io)
                else
                    SecurityModule.init(ctx.allocator, stored, 0);
                try verifyJwtAndNext(&sec, ctx, next);
            }
        }.mw,
        .user_data = @ptrCast(secret_copy),
    };
}

/// JWT auth using a long-lived `SecurityModule` (prefer `initWithIo` in production).
pub fn jwtAuthWithSecurity(security: *SecurityModule) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                try verifyJwtAndNext(@ptrCast(@alignCast(user_data.?)), ctx, next);
            }
        }.mw,
        .user_data = security,
    };
}

// ==== §4  Catalog JWT & permission loading ====

fn verifyJwtAndNext(sec: *SecurityModule, ctx: *api.Context, next: api.HandlerFn) !void {
    try verifyJwtLoadPermsAndNext(sec, ctx, next, null, defaultReject);
}

fn joinCsv(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");
    var total: usize = 0;
    for (parts, 0..) |p, i| {
        total += p.len;
        if (i > 0) total += 1;
    }
    const buf = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0) {
            buf[off] = ',';
            off += 1;
        }
        @memcpy(buf[off..][0..p.len], p);
        off += p.len;
    }
    return buf;
}

/// Input for `CatalogPermissionLoader` — identity + portal roles after JWT verify.
/// Simple loaders (static table / CatalogPermDb) may ignore `sub`/`aud`.
/// Multi-realm apps (e.g. shop/supplier/admin RBAC tables) use them to query per-user grants.
pub const CatalogPermLoadInput = struct {
    /// JWT `sub` (user id string).
    sub: []const u8,
    /// JWT `aud` (tenant / app id string).
    aud: []const u8,
    /// JWT `roles` slice (portal / coarse roles).
    roles: []const []const u8,
};

/// Optional: map identity + JWT roles → fine-grained permission codes (CSV on `permissions` attr).
pub const CatalogPermissionLoader = *const fn (
    allocator: std.mem.Allocator,
    input: CatalogPermLoadInput,
) anyerror![]u8;

/// Best-effort identity for `.optional` routes: attach `user_id`/`tenant_id`/
/// `roles` when a valid Bearer token is present, and do nothing at all when it
/// is missing, malformed, expired or unknown. Never writes a response, never
/// 401s — that is the whole difference from `verifyJwtLoadPermsAndNext`.
///
/// Failures are logged at debug level rather than swallowed silently (a bare
/// `catch {}` is banned on this path by the project's own gate).
pub fn attachIdentityBestEffort(sec: *SecurityModule, ctx: *api.Context) void {
    const auth = ctx.headers.get("authorization") orelse return;
    const token = SecurityModule.extractBearerToken(auth) orelse {
        std.log.debug("[auth] optional route {s} {s}: malformed Authorization header", .{ ctx.method.toString(), ctx.path });
        return;
    };
    const payload = sec.verifyToken(token) catch |err| {
        std.log.debug("[auth] optional route {s} {s}: token ignored ({s})", .{ ctx.method.toString(), ctx.path, @errorName(err) });
        return;
    };
    defer sec.freePayload(payload);

    ctx.setAttr("user_id", payload.sub) catch |err| {
        std.log.debug("[auth] optional route {s} {s}: user_id attr failed ({s})", .{ ctx.method.toString(), ctx.path, @errorName(err) });
        return;
    };
    if (payload.aud.len > 0) {
        ctx.setAttr("tenant_id", payload.aud) catch |err| {
            std.log.debug("[auth] optional route {s} {s}: tenant_id attr failed ({s})", .{ ctx.method.toString(), ctx.path, @errorName(err) });
            return;
        };
    }
    if (payload.roles.len > 0) {
        const roles_csv = joinCsv(ctx.allocator, payload.roles) catch return;
        defer ctx.allocator.free(roles_csv);
        ctx.setAttr("roles", roles_csv) catch |err| std.log.debug("[auth] optional route: roles attr failed ({s})", .{@errorName(err)});
    } else {
        ctx.setAttr("roles", "") catch |err| std.log.debug("[auth] optional route: empty roles attr failed ({s})", .{@errorName(err)});
    }
}

fn verifyJwtLoadPermsAndNext(
    sec: *SecurityModule,
    ctx: *api.Context,
    next: api.HandlerFn,
    loader: ?CatalogPermissionLoader,
    reject: AuthRejectFn,
) !void {
    const auth = ctx.headers.get("authorization") orelse {
        try reject(ctx, 401, "Unauthorized");
        return;
    };
    const token = SecurityModule.extractBearerToken(auth) orelse {
        try reject(ctx, 401, "Unauthorized");
        return;
    };

    const payload = sec.verifyToken(token) catch {
        try reject(ctx, 401, "Unauthorized");
        return;
    };
    defer sec.freePayload(payload);

    try ctx.setAttr("user_id", payload.sub);
    // Only set tenant attr when aud is present — an empty-string attr would
    // shadow the X-Tenant-ID fallback path and fail downstream int parsing.
    if (payload.aud.len > 0) try ctx.setAttr("tenant_id", payload.aud);
    // Comma-separated roles for permissionGate(.roles) and CatalogPermissionLoader.
    if (payload.roles.len > 0) {
        const roles_csv = try joinCsv(ctx.allocator, payload.roles);
        defer ctx.allocator.free(roles_csv);
        try ctx.setAttr("roles", roles_csv);
    } else {
        try ctx.setAttr("roles", "");
    }

    if (loader) |load| {
        const perms_csv = load(ctx.allocator, .{
            .sub = payload.sub,
            .aud = payload.aud,
            .roles = payload.roles,
        }) catch |err| {
            std.log.err("jwt perm loader failed: {s}", .{@errorName(err)});
            try reject(ctx, 500, "Failed to load permissions");
            return;
        };
        defer ctx.allocator.free(perms_csv);
        try ctx.setAttr("permissions", perms_csv);
    }

    try next(ctx);
}

const comptime_router = @import("ComptimeRouter.zig");
const Rbac = @import("../security/Rbac.zig");

pub const JwtFromCatalogConfig = struct {
    skip_prefixes: []const []const u8 = &.{ "health", "dashboard", "openapi.json" },
    /// Rejection renderer (default: `{"code":status,"msg":…,"data":null}`).
    /// Use `envelopeReject(.thinkphp)` etc. for consumer envelope dialects.
    reject: AuthRejectFn = defaultReject,
};

/// JWT that skips when catalog marks the route `.public`, or path matches skip_prefixes.
/// Fill `slot` with `slot.set(try router.finish())` after mounts.
pub fn jwtAuthFromCatalog(security: *SecurityModule, slot: *comptime_router.CatalogSlot, config: JwtFromCatalogConfig) api.Middleware {
    const Store = struct {
        sec: *SecurityModule,
        catalog_slot: *comptime_router.CatalogSlot,
        cfg: JwtFromCatalogConfig,
    };
    const stored = std.heap.page_allocator.create(Store) catch @panic("middleware setup: out of memory");
    stored.* = .{ .sec = security, .catalog_slot = slot, .cfg = config };
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const st: *const Store = @ptrCast(@alignCast(user_data.?));
                if (comptime_router.pathHasSkipPrefix(ctx.path, st.cfg.skip_prefixes)) {
                    try next(ctx);
                    return;
                }
                if (st.catalog_slot.get()) |cat| {
                    if (cat.isPublic(ctx.method, ctx.path)) {
                        try next(ctx);
                        return;
                    }
                    if (cat.isOptionalAuth(ctx.method, ctx.path)) {
                        attachIdentityBestEffort(st.sec, ctx);
                        try next(ctx);
                        return;
                    }
                }
                try verifyJwtLoadPermsAndNext(st.sec, ctx, next, null, st.cfg.reject);
            }
        }.mw,
        .user_data = stored,
    };
}

/// Like `jwtAuthFromCatalog`, but loads fine-grained permissions via `loader`
/// into ctx attr `permissions` (CSV). Does **not** overwrite `ctx.user_data`
/// (safe with ComptimeRouter). Pair with `permissionGateWith(..., .{ .mode = .rbac })`.
pub fn jwtAuthFromCatalogWithPermissions(
    security: *SecurityModule,
    slot: *comptime_router.CatalogSlot,
    loader: CatalogPermissionLoader,
    config: JwtFromCatalogConfig,
) api.Middleware {
    const Store = struct {
        sec: *SecurityModule,
        catalog_slot: *comptime_router.CatalogSlot,
        cfg: JwtFromCatalogConfig,
        load: CatalogPermissionLoader,
    };
    const stored = std.heap.page_allocator.create(Store) catch @panic("middleware setup: out of memory");
    stored.* = .{ .sec = security, .catalog_slot = slot, .cfg = config, .load = loader };
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const st: *const Store = @ptrCast(@alignCast(user_data.?));
                if (comptime_router.pathHasSkipPrefix(ctx.path, st.cfg.skip_prefixes)) {
                    try next(ctx);
                    return;
                }
                if (st.catalog_slot.get()) |cat| {
                    if (cat.isPublic(ctx.method, ctx.path)) {
                        try next(ctx);
                        return;
                    }
                    if (cat.isOptionalAuth(ctx.method, ctx.path)) {
                        attachIdentityBestEffort(st.sec, ctx);
                        try next(ctx);
                        return;
                    }
                }
                try verifyJwtLoadPermsAndNext(st.sec, ctx, next, st.load, st.cfg.reject);
            }
        }.mw,
        .user_data = stored,
    };
}

/// Build a `CatalogPermissionLoader` from a static `RolePermissionTable`.
/// Ignores `sub`/`aud` (role→permission map only).
/// Note: a `CatalogPermissionLoader` is a plain fn (no user_data context), so
/// this keeps a module-level table reference — safe in practice because the
/// table is a process-wide singleton. For multi-instance isolation pass a
/// custom loader closure instead.
pub fn catalogLoaderFromTable(table: *const Rbac.RolePermissionTable) CatalogPermissionLoader {
    const Holder = struct {
        var tbl: *const Rbac.RolePermissionTable = undefined;
        fn load(allocator: std.mem.Allocator, input: CatalogPermLoadInput) anyerror![]u8 {
            return @This().tbl.permissionsCsv(allocator, input.roles);
        }
    };
    Holder.tbl = table;
    return Holder.load;
}

// ==== §5  Pluggable auth backends ====

// ── Pluggable auth backends (catalog = sole bypass truth) ────────────────

/// Pluggable auth backend: verify a request and, on success, write identity
/// via `ctx.setIdentity(...)` (attrs are duped, so token payloads can be
/// freed inside `verifyFn`) and return true. Return false when
/// unauthenticated — the catalog wrapper emits the configured reject
/// envelope. JWT is one backend (`jwtBackend`); Redis/token-service schemes
/// implement the same shape. Keeping attr writes inside the backend avoids
/// any ownership transfer across the verify boundary.
pub const AuthBackend = struct {
    verifyFn: *const fn (ctx: *api.Context, user_data: ?*anyopaque) anyerror!bool,
    user_data: ?*anyopaque = null,
    /// Optional: load fine-grained permission codes after verify (CSV on the
    /// `permissions` attr). See `CatalogPermissionLoader`.
    loadPermissions: ?CatalogPermissionLoader = null,

    pub fn verify(self: *const AuthBackend, ctx: *api.Context) anyerror!bool {
        return self.verifyFn(ctx, self.user_data);
    }
};

pub const AuthFromCatalogConfig = struct {
    skip_prefixes: []const []const u8 = &.{ "health", "dashboard", "openapi.json" },
    /// Rejection renderer (default: `{"code":status,"msg":…,"data":null}`).
    reject: AuthRejectFn = defaultReject,
};

/// Catalog-driven auth around any `AuthBackend`: a request is skipped iff the
/// route catalog marks `(method, path)` `.public` (or matches a legacy
/// skip-prefix) — the catalog is the sole bypass truth, no parallel path
/// lists. On success sets identity attrs (`user_id` / `tenant_id` / `roles`)
/// and the optional `permissions` CSV; pair with `permissionGateWith`.
pub fn authFromCatalog(slot: *comptime_router.CatalogSlot, backend: AuthBackend, config: AuthFromCatalogConfig) api.Middleware {
    const Store = struct {
        catalog_slot: *comptime_router.CatalogSlot,
        backend: AuthBackend,
        cfg: AuthFromCatalogConfig,
    };
    const stored = std.heap.page_allocator.create(Store) catch @panic("middleware setup: out of memory");
    stored.* = .{ .catalog_slot = slot, .backend = backend, .cfg = config };
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const st: *const Store = @ptrCast(@alignCast(user_data.?));
                if (comptime_router.pathHasSkipPrefix(ctx.path, st.cfg.skip_prefixes)) {
                    try next(ctx);
                    return;
                }
                if (st.catalog_slot.get()) |cat| {
                    if (cat.isOptionalAuth(ctx.method, ctx.path)) {
                        // `.optional`: verify when a token is present, attach the
                        // identity, never reject (see Auth.optional).
                        if (st.backend.verify(ctx)) |_| {} else |err| {
                            std.log.debug("[auth] optional route {s} {s}: token ignored ({s})", .{
                                ctx.method.toString(), ctx.path, @errorName(err),
                            });
                        }
                        try next(ctx);
                        return;
                    }
                    if (cat.isPublic(ctx.method, ctx.path)) {
                        // Best-effort identity on public routes: when a token is
                        // presented, verify it so handlers may *optionally*
                        // personalize (ctx.userId() / optionalPortalUser) without a
                        // second route or an "optional auth" mode. Failures are
                        // ignored — the route stays public, and `verifyFn` never
                        // writes a response.
                        if (st.backend.verify(ctx)) |_| {} else |err| {
                            // A missing/expired/malformed token must not fail a
                            // public route — but it must not vanish either:
                            // debug keeps it out of production logs while
                            // remaining diagnosable, and this stays a real
                            // `catch` instead of a bare `catch {}` (banned by
                            // the project's own gate for I/O paths).
                            std.log.debug("[auth] public route {s} {s}: token ignored ({s})", .{
                                ctx.method.toString(), ctx.path, @errorName(err),
                            });
                        }
                        try next(ctx);
                        return;
                    }
                }
                const authed = st.backend.verify(ctx) catch |err| {
                    std.log.err("auth backend verify failed: {s}", .{@errorName(err)});
                    try st.cfg.reject(ctx, 401, "Unauthorized");
                    return;
                };
                if (!authed) {
                    try st.cfg.reject(ctx, 401, "Unauthorized");
                    return;
                }
                if (st.backend.loadPermissions) |load| {
                    var roles_list = std.ArrayList([]const u8).empty;
                    defer roles_list.deinit(ctx.allocator);
                    if (ctx.rolesCsv()) |csv| {
                        var it = std.mem.splitScalar(u8, csv, ',');
                        while (it.next()) |r| {
                            const trimmed = std.mem.trim(u8, r, " \t");
                            if (trimmed.len > 0) try roles_list.append(ctx.allocator, trimmed);
                        }
                    }
                    const perms_csv = load(ctx.allocator, .{
                        .sub = ctx.userId() orelse "",
                        .aud = ctx.tenantId() orelse "",
                        .roles = roles_list.items,
                    }) catch |err| {
                        std.log.err("auth perm loader failed: {s}", .{@errorName(err)});
                        try st.cfg.reject(ctx, 500, "Failed to load permissions");
                        return;
                    };
                    defer ctx.allocator.free(perms_csv);
                    try ctx.setAttr("permissions", perms_csv);
                }
                try next(ctx);
            }
        }.mw,
        .user_data = stored,
    };
}

// ==== §6  Token extraction, JWT backend & tenant resolver ====

// ── Token extractors ──────────────────────────────────────────────────────

/// Common token carrier locations, tried in order by `extractTokenAny`.
pub const TokenSource = enum {
    /// `Authorization: Bearer <token>`.
    bearer,
    /// `X-Token: <token>` header (ThinkPHP-style; optional Bearer prefix stripped).
    x_token,
    /// `?token=` query parameter.
    query,
    /// `token=` form field (application/x-www-form-urlencoded body).
    form,
};

/// Bearer token from the `Authorization` header.
pub fn extractBearer(ctx: *const api.Context) ?[]const u8 {
    const auth = ctx.headers.get("authorization") orelse return null;
    return SecurityModule.extractBearerToken(auth);
}

/// Token from an arbitrary header (e.g. `x-token`); an optional `Bearer `
/// prefix is stripped. Returns null when the header is absent or empty.
pub fn extractHeaderToken(ctx: *const api.Context, name: []const u8) ?[]const u8 {
    const v = ctx.header(name) orelse return null;
    if (v.len == 0) return null;
    return SecurityModule.extractBearerToken(v) orelse v;
}

/// Token from a query parameter (borrowed from the parsed query map).
pub fn extractQueryToken(ctx: *const api.Context, key: []const u8) ?[]const u8 {
    const v = ctx.queryParam(key) orelse return null;
    return if (v.len == 0) null else v;
}

/// Token from a form field (borrowed from the parsed form map).
pub fn extractFormToken(ctx: *const api.Context, key: []const u8) ?[]const u8 {
    const v = ctx.formValue(key) orelse return null;
    return if (v.len == 0) null else v;
}

/// First non-empty token across `sources`, in order.
pub fn extractTokenAny(ctx: *const api.Context, sources: []const TokenSource) ?[]const u8 {
    for (sources) |s| {
        const tok: ?[]const u8 = switch (s) {
            .bearer => extractBearer(ctx),
            .x_token => extractHeaderToken(ctx, "x-token"),
            .query => extractQueryToken(ctx, "token"),
            .form => extractFormToken(ctx, "token"),
        };
        if (tok) |t| return t;
    }
    return null;
}

// ── Built-in JWT backend ──────────────────────────────────────────────────

/// Built-in JWT `AuthBackend` over `SecurityModule`; accepts Bearer and
/// `X-Token` carriers. Pair with `authFromCatalog` (+ `permissionGateWith`).
pub fn jwtBackend(security: *SecurityModule) AuthBackend {
    return .{
        .user_data = security,
        .verifyFn = struct {
            fn verify(ctx: *api.Context, user_data: ?*anyopaque) anyerror!bool {
                const sec: *SecurityModule = @ptrCast(@alignCast(user_data.?));
                const token = extractTokenAny(ctx, &.{ .bearer, .x_token }) orelse return false;
                const payload = sec.verifyToken(token) catch return false;
                defer sec.freePayload(payload);
                const roles_csv = try joinCsv(ctx.allocator, payload.roles);
                defer ctx.allocator.free(roles_csv);
                try ctx.setIdentity(.{
                    .user_id = payload.sub,
                    .tenant_id = if (payload.aud.len > 0) payload.aud else null,
                    .roles = roles_csv,
                });
                return true;
            }
        }.verify,
    };
}

/// `jwtBackend` + fine-grained permission loading — the generic equivalent of
/// `jwtAuthFromCatalogWithPermissions`.
pub fn jwtBackendWithPermissions(security: *SecurityModule, loader: CatalogPermissionLoader) AuthBackend {
    var b = jwtBackend(security);
    b.loadPermissions = loader;
    return b;
}

// ── Tenant resolver ───────────────────────────────────────────────────────

pub const TenantResolverConfig = struct {
    /// Headers tried in order (lookup is case-insensitive): ThinkPHP-style
    /// `AppID`/`appid`, then common tenant headers.
    headers: []const []const u8 = &.{ "appid", "app-id", "x-tenant-id" },
    /// Query keys tried after headers.
    query_keys: []const []const u8 = &.{"app_id"},
    /// Context attr written on resolution.
    attr_key: []const u8 = "tenant_id",
    /// When true, an unresolved tenant rejects with 400 via `reject`.
    require: bool = false,
    /// When false (default), an existing attr (e.g. JWT `aud`) wins.
    override_existing: bool = false,
    reject: AuthRejectFn = defaultReject,
};

/// Resolves tenant from `AppID`/`appid`/`X-Tenant-Id` headers or `app_id`
/// query param into the `tenant_id` attr (M7). Register before handlers that
/// call `ctx.tenantId()`; with JWT auth, register after it so `aud` wins
/// unless `override_existing` is set.
pub fn tenantResolver(config: TenantResolverConfig) api.Middleware {
    const stored = std.heap.page_allocator.create(TenantResolverConfig) catch @panic("tenantResolver setup: out of memory");
    stored.* = config;
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const cfg: *const TenantResolverConfig = @ptrCast(@alignCast(user_data.?));
                if (!cfg.override_existing and ctx.getAttr(cfg.attr_key) != null) {
                    try next(ctx);
                    return;
                }
                var resolved: ?[]const u8 = null;
                for (cfg.headers) |name| {
                    if (ctx.header(name)) |v| {
                        if (v.len > 0) {
                            resolved = v;
                            break;
                        }
                    }
                }
                if (resolved == null) {
                    for (cfg.query_keys) |key| {
                        if (ctx.queryParam(key)) |v| {
                            if (v.len > 0) {
                                resolved = v;
                                break;
                            }
                        }
                    }
                }
                if (resolved) |v| {
                    try ctx.setAttr(cfg.attr_key, v);
                } else if (cfg.require) {
                    try cfg.reject(ctx, 400, "Missing tenant");
                    return;
                }
                try next(ctx);
            }
        }.mw,
        .user_data = stored,
    };
}

// ==== §7  Module gate & permission gate ====

pub const ModuleGateConfig = struct {
    allowed: ?[]const []const u8 = null,
    unknown: enum { allow, deny } = .allow,
    attr_key: []const u8 = "module",
    /// Path prefixes exempt from `unknown = .deny` (infra routes living outside
    /// the ComptimeRouter catalog, e.g. health/metrics probes).
    skip_prefixes: []const []const u8 = &.{ "health", "dashboard", "openapi.json" },
    /// Renderer for the 403 (module not in `allowed`) and 404 (unknown module
    /// under `.deny`). Defaults to the legacy envelope, which itself follows the
    /// process-wide renderer — pass `.reject = problemReject` to force RFC 7807
    /// on this gate, or `.allow` plus a chain-tail middleware to style 404s
    /// yourself.
    reject: AuthRejectFn = defaultReject,
};

/// Resolves catalog module → ctx attr; optional allow-list / deny-unknown.
pub fn moduleGate(slot: *comptime_router.CatalogSlot, config: ModuleGateConfig) api.Middleware {
    const Store = struct {
        catalog_slot: *comptime_router.CatalogSlot,
        cfg: ModuleGateConfig,
    };
    const stored = std.heap.page_allocator.create(Store) catch @panic("middleware setup: out of memory");
    stored.* = .{ .catalog_slot = slot, .cfg = config };
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const st: *const Store = @ptrCast(@alignCast(user_data.?));
                const cat = st.catalog_slot.get() orelse {
                    try next(ctx);
                    return;
                };
                if (cat.moduleFor(ctx.path)) |mod| {
                    try ctx.setAttr(st.cfg.attr_key, mod);
                    if (st.cfg.allowed) |allow| {
                        var ok = false;
                        for (allow) |a| {
                            if (std.mem.eql(u8, a, mod)) {
                                ok = true;
                                break;
                            }
                        }
                        if (!ok) {
                            try st.cfg.reject(ctx, 403, "Module not allowed");
                            return;
                        }
                    }
                } else if (st.cfg.unknown == .deny) {
                    if (!comptime_router.pathHasSkipPrefix(ctx.path, st.cfg.skip_prefixes)) {
                        try st.cfg.reject(ctx, 404, "Unknown route module");
                        return;
                    }
                }
                try next(ctx);
            }
        }.mw,
        .user_data = stored,
    };
}

/// `permission` may be a single code or OR-alternatives separated by `|`.
/// Delegates to `Rbac.exprMatchesCsv` so the gate and the handler-side
/// `Context.permissionMatches` cannot diverge.
pub fn permissionMatchesRoles(roles_csv: []const u8, permission: []const u8) bool {
    return Rbac.exprMatchesCsv(roles_csv, permission);
}

/// See `permissionMatchesRoles`. Delegates to `Rbac.exprMatchesAuthInfo`.
pub fn permissionMatchesAuthInfo(auth: *const Rbac.AuthInfo, permission: []const u8) bool {
    return Rbac.exprMatchesAuthInfo(auth, permission);
}

/// Handler-side counterpart of `permissionGateWith`.
///
/// A gate may accept `portal:user|portal:shop` (OR), after which the handler
/// often still needs to know *which* branch this request satisfied — to pick a
/// response shape, or to run a portal-specific check. Re-implementing the match
/// in the handler is how a route that accepts both portals ends up 403-ing one
/// of them.
///
/// `expr` is the route's expression verbatim. Any attached identity source may
/// satisfy it (AuthInfo, `permissions` attr, `roles` attr).
pub fn permissionMatchesContext(ctx: *const api.Context, expr: []const u8) bool {
    return ctx.permissionMatches(expr);
}

/// `permissionMatchesContext` pinned to one gate's exact semantics — same mode
/// and attr names, so the handler's answer cannot differ from the gate's:
///
///   `http.permissionMatchesWith(ctx, expr, .{ .mode = .rbac })`
///
/// In `.rbac` mode an attached `AuthInfo` is authoritative (the gate does not
/// fall back to the attr), and in `.roles` mode only the roles attr is read.
pub fn permissionMatchesWith(ctx: *const api.Context, expr: []const u8, config: PermissionGateConfig) bool {
    return switch (config.mode) {
        .roles => Rbac.exprMatchesCsv(ctx.getAttr(config.role_attr) orelse "", expr),
        .rbac => blk: {
            if (ctx.authInfo(Rbac.AuthInfo)) |ai| break :blk Rbac.exprMatchesAuthInfo(ai, expr);
            const perms = ctx.getAttr(config.permission_attr) orelse break :blk false;
            break :blk Rbac.exprMatchesCsv(perms, expr);
        },
    };
}

pub const PermissionMode = enum {
    /// Match `RouteMeta.permission` against JWT role names (legacy v1.1).
    roles,
    /// Match against fine-grained permission codes (`permissions` attr and/or AuthInfo).
    rbac,
};

pub const PermissionGateConfig = struct {
    mode: PermissionMode = .roles,
    /// Context attr holding comma-separated JWT roles (set by jwtAuth*).
    role_attr: []const u8 = "roles",
    /// Context attr holding comma-separated permission codes (set by jwtAuthFromCatalogWithPermissions).
    permission_attr: []const u8 = "permissions",
    /// When true, writes matched permission expression to ctx attr `permission`.
    set_permission_attr: bool = true,
    /// When true, routes without a `RouteMeta.permission` are DENIED (403)
    /// instead of passing through. Public routes always pass. Default
    /// `false` = allow-unannotated (current behavior).
    deny_by_default: bool = false,
    /// Rejection renderer (default: `{"code":status,"msg":…,"data":null}`).
    reject: AuthRejectFn = defaultReject,
};

/// Enforces `RouteMeta.permission` (default mode = JWT roles, `|` = OR).
/// Skips public routes and paths without a permission.
pub fn permissionGate(slot: *comptime_router.CatalogSlot) api.Middleware {
    return permissionGateWith(slot, .{});
}

pub fn permissionGateWith(slot: *comptime_router.CatalogSlot, config: PermissionGateConfig) api.Middleware {
    const Store = struct {
        catalog_slot: *comptime_router.CatalogSlot,
        cfg: PermissionGateConfig,
    };
    // One store per call — a function-level `var` would be process-wide, so a
    // second gate (another server, another catalog slot, another `.mode`) would
    // silently overwrite this one's slot and config. Same shape as
    // `jwtAuthFromCatalog*` / `authFromCatalog` / `tenantResolver` / `moduleGate`.
    const stored = std.heap.page_allocator.create(Store) catch @panic("middleware setup: out of memory");
    stored.* = .{ .catalog_slot = slot, .cfg = config };
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const st: *const Store = @ptrCast(@alignCast(user_data.?));
                const cat = st.catalog_slot.get() orelse {
                    // No catalog = the gate cannot know whether this route is
                    // public, what permission it needs, or whether it is even
                    // registered. It used to call `next` here, which let a
                    // request through un-permission-checked whenever the slot
                    // was not filled (or was filled by a different server).
                    // Rejecting is the fail-closed twin of `jwtAuthFromCatalog*`,
                    // which forces authentication in exactly this state; a gate
                    // has no token to require, so it refuses instead. 503 (and
                    // not 403) keeps a wiring mistake from being read as a
                    // genuine permission denial — same status and wording as
                    // `openApiCatalogHandler` for the same condition.
                    try st.cfg.reject(ctx, 503, "Route catalog not ready");
                    return;
                };
                if (cat.isPublic(ctx.method, ctx.path)) {
                    try next(ctx);
                    return;
                }
                // `.optional` routes are public for *auth* purposes but may still
                // carry permission/role metadata, so they fall through to the
                // checks below exactly like `.jwt`.
                // Route-level portal roles (RouteMeta.roles, `|` = OR): matched
                // against the identity roles attr before fine-grained permission.
                if (cat.rolesFor(ctx.method, ctx.path)) |route_roles| {
                    const roles = ctx.getAttr(st.cfg.role_attr) orelse "";
                    if (!permissionMatchesRoles(roles, route_roles)) {
                        try st.cfg.reject(ctx, 403, "Forbidden");
                        return;
                    }
                }
                const perm = cat.permissionFor(ctx.method, ctx.path) orelse {
                    if (st.cfg.deny_by_default) {
                        try st.cfg.reject(ctx, 403, "Forbidden");
                        return;
                    }
                    try next(ctx);
                    return;
                };

                const allowed = switch (st.cfg.mode) {
                    .roles => blk: {
                        const roles = ctx.getAttr(st.cfg.role_attr) orelse break :blk false;
                        break :blk permissionMatchesRoles(roles, perm);
                    },
                    .rbac => blk: {
                        if (ctx.authInfo(Rbac.AuthInfo)) |ai| {
                            break :blk permissionMatchesAuthInfo(ai, perm);
                        }
                        const perms = ctx.getAttr(st.cfg.permission_attr) orelse break :blk false;
                        break :blk permissionMatchesRoles(perms, perm);
                    },
                };
                if (!allowed) {
                    try st.cfg.reject(ctx, 403, "Forbidden");
                    return;
                }
                if (st.cfg.set_permission_attr) {
                    try ctx.setAttr("permission", perm);
                }
                try next(ctx);
            }
        }.mw,
        .user_data = stored,
    };
}

// ==== §8  CSRF & security headers ====

/// Constant-time byte-slice comparison for CSRF tokens.
///
/// Zig 0.17's `std.crypto.timing_safe.eql` only accepts arrays/vectors, so the
/// slice loop is spelled out here (the same shape as `security.PasswordEncoder`).
/// The value a client sends must not decide how long the check takes beyond the
/// single "all bytes equal" bit — that bit is the accept/reject decision itself.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, 0..) |x, i| diff |= x ^ b[i];
    // `diff -% 1` borrows to 0xFF exactly when every byte matched; widening to
    // u16 and shifting by 8 turns that into the branchless answer.
    const widened: u16 = diff;
    return (widened -% 1) >> 8 != 0;
}

/// CSRF protection: double-submit cookie **plus** an Origin/Referer gate.
///
/// GET/HEAD/OPTIONS pass through. State-changing methods require an
/// `X-CSRF-Token` header matching the `csrf_token` cookie — compared in
/// constant time — and, when the request carries `Origin` (or a degraded
/// `Referer`), a value naming this server.
///
/// Why the origin gate: plain double-submit is only as strong as the cookie
/// jar. Anyone who can write `csrf_token` on the parent domain — a sibling
/// app, a taken-over subdomain, any page that forgot `__Host-` / domain
/// scoping — can forge both halves of the pair, so the token check alone does
/// not stop a cross-site POST. `Origin` is set by the browser and cannot be
/// forged by page script, so comparing it closes that path.
///
/// Requests with neither header keep the token-only behaviour: CLIs, cron
/// jobs, server-to-server callers and most test harnesses send no `Origin`
/// (browsers always do for a cross-site POST), and rejecting them would be a
/// wire-level break, not a security win.
///
/// Deployment note: the comparison is against `Host` (and `X-Forwarded-Host`,
/// see `csrfOriginAllowed`). A reverse proxy that rewrites `Host` to an
/// upstream name must forward the client's host as `X-Forwarded-Host`, or
/// state-changing browser requests are refused.
///
/// The token is deliberately **not** signed/HMAC-bound to the session. A
/// session-bound token (`nonce.hmac(nonce, session_key)`) would close the same
/// hole without depending on `Origin` — and is the better long-term design —
/// but it changes the format every client must mint and echo, so it needs a
/// migration of its own rather than a silent change here.
pub fn csrf() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                switch (ctx.method) {
                    .GET, .HEAD, .OPTIONS => return next(ctx),
                    else => {
                        if (!csrfOriginAllowed(ctx)) {
                            try ctx.sendError(403, "CSRF origin mismatch");
                            return;
                        }
                        const header_token = ctx.header("x-csrf-token") orelse "";
                        const cookie_header = ctx.header("cookie") orelse "";
                        // Extract csrf_token=... from Cookie header
                        var cookie_match = false;
                        var it = std.mem.splitScalar(u8, cookie_header, ';');
                        while (it.next()) |part| {
                            const trimmed = std.mem.trim(u8, part, " ");
                            if (std.mem.startsWith(u8, trimmed, "csrf_token=")) {
                                const token = trimmed["csrf_token=".len..];
                                if (token.len > 0 and constantTimeEql(token, header_token)) {
                                    cookie_match = true;
                                }
                                break;
                            }
                        }
                        if (!cookie_match) {
                            try ctx.sendError(403, "CSRF token mismatch");
                            return;
                        }
                        return next(ctx);
                    },
                }
            }
        }.mw,
    };
}

/// `scheme` + authority split out of an `Origin`/`Referer` value.
const OriginValue = struct { scheme: []const u8, host: []const u8 };

/// Parse `scheme://host[:port]` out of `Origin` / `Referer`.
///
/// `null` for anything that is not a plain http(s) origin — including the
/// literal `null` a sandboxed iframe (or a `data:` / `file:` page) sends, which
/// is a shape only a hostile embedding produces.
fn parseOrigin(raw: []const u8) ?OriginValue {
    const trimmed = std.mem.trim(u8, raw, " \t");
    // `Origin` holds a single value; a proxy that rewrites headers may append a
    // list, in which case the first entry is the originating one.
    const value = if (std.mem.indexOfScalar(u8, trimmed, ',')) |comma|
        std.mem.trim(u8, trimmed[0..comma], " \t")
    else
        trimmed;
    if (value.len == 0 or std.mem.eql(u8, value, "null")) return null;

    const sep = std.mem.indexOf(u8, value, "://") orelse return null;
    const scheme = value[0..sep];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return null;

    var rest = value[sep + 3 ..];
    // `Referer` is a full URL; keep only the authority.
    if (std.mem.indexOfAny(u8, rest, "/?#")) |end| rest = rest[0..end];
    if (rest.len == 0) return null;
    // `user@host` never appears in a browser-sent origin and would hide the
    // real host behind a decoy one.
    if (std.mem.indexOfScalar(u8, rest, '@') != null) return null;
    return .{ .scheme = scheme, .host = rest };
}

const HostPort = struct { host: []const u8, port: ?[]const u8 };

/// Split `host[:port]`, keeping IPv6 literals (`[::1]:8080`) intact and
/// dropping a trailing DNS dot.
fn splitHostPort(raw: []const u8) HostPort {
    var h = std.mem.trim(u8, raw, " \t");
    var port: ?[]const u8 = null;
    if (h.len > 1 and h[0] == '[') {
        if (std.mem.indexOfScalar(u8, h, ']')) |close| {
            if (close + 1 < h.len and h[close + 1] == ':') port = h[close + 2 ..];
            h = h[0 .. close + 1];
        }
    } else if (std.mem.lastIndexOfScalar(u8, h, ':')) |colon| {
        // Exactly one `:` separates a port. Several means an unbracketed IPv6
        // address, which is not a legal `Host` value: leave it whole (it then
        // simply fails to match anything) instead of guessing where the split is.
        if (std.mem.indexOfScalar(u8, h, ':').? == colon) {
            port = h[colon + 1 ..];
            h = h[0..colon];
        }
    }
    if (port) |p| {
        if (p.len == 0) port = null;
    }
    while (h.len > 1 and h[h.len - 1] == '.') h = h[0 .. h.len - 1];
    return .{ .host = h, .port = port };
}

/// Same host and same effective port? Browsers omit default ports from
/// `Origin`; proxies routinely leave `:443` in `Host`, so `example.com:443`
/// and `https://example.com` must count as one origin.
fn hostMatches(expected_raw: []const u8, origin_host_raw: []const u8, origin_scheme: []const u8) bool {
    const expected = splitHostPort(expected_raw);
    const origin = splitHostPort(origin_host_raw);
    if (!std.ascii.eqlIgnoreCase(expected.host, origin.host)) return false;
    const default_port = if (std.ascii.eqlIgnoreCase(origin_scheme, "https")) "443" else "80";
    return std.mem.eql(u8, expected.port orelse default_port, origin.port orelse default_port);
}

/// Match the origin against a comma-separated proxy host list
/// (`X-Forwarded-Host`): any entry may be the one a fronting proxy set.
fn forwardedHostMatches(list: []const u8, origin_host: []const u8, origin_scheme: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |part| {
        const candidate = std.mem.trim(u8, part, " \t");
        if (candidate.len == 0) continue;
        if (hostMatches(candidate, origin_host, origin_scheme)) return true;
    }
    return false;
}

/// A header value, treating a blank one as absent: `Origin:` with an empty
/// value is how some clients spell "not applicable", and the `Referer`
/// fallback should still get its turn.
fn nonBlank(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (std.mem.trim(u8, v, " \t").len > 0) v else null;
}

/// First non-empty entry of a comma-separated proxy header value.
fn firstForwardedValue(raw: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const value = std.mem.trim(u8, part, " \t");
        if (value.len > 0) return value;
    }
    return null;
}

/// Origin/Referer gate for state-changing requests.
///
/// `true` when the request carries neither header (see `csrf`), or when the
/// browser-supplied origin names a host this server answers for. Any candidate
/// host that is present must match: a *positive* mismatch rejects, while a
/// request with no `Host` at all (HTTP/1.0 shape, bare test context) is left to
/// the token check rather than refused.
///
/// `X-Forwarded-Host` / `X-Forwarded-Proto` are honoured because the Context
/// carries no TLS or listener identity of its own — behind a TLS-terminating
/// proxy the backend name (`127.0.0.1:8080`) would otherwise never equal the
/// browser's origin. Trusting them is a real boundary: a browser can only set
/// them when the app's CORS policy allows those header names (a non-simple
/// request is preflighted), so keep `CorsConfig.allow_headers` narrow.
fn csrfOriginAllowed(ctx: *api.Context) bool {
    const raw = nonBlank(ctx.header("origin")) orelse nonBlank(ctx.header("referer")) orelse return true;
    const origin = parseOrigin(raw) orelse return false;

    // Scheme is checkable only when a proxy told us the client-facing one:
    // without that header the framework has no view of TLS, and the host check
    // below is the load-bearing part.
    if (ctx.header("x-forwarded-proto")) |proto| {
        if (firstForwardedValue(proto)) |scheme| {
            if (!std.ascii.eqlIgnoreCase(scheme, origin.scheme)) return false;
        }
    }

    var have_candidate = false;
    if (ctx.header("x-forwarded-host")) |forwarded| {
        have_candidate = true;
        if (forwardedHostMatches(forwarded, origin.host, origin.scheme)) return true;
    }
    if (ctx.header("host")) |host| {
        have_candidate = true;
        if (hostMatches(host, origin.host, origin.scheme)) return true;
    }
    return !have_candidate;
}

/// Security response header pair.
pub const SecurityHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Baseline Content-Security-Policy carried by the opt-in `securityHeaders`
/// middleware. See `defaultSecurityHeaders` for why it is *not* part of the
/// data-only default set.
pub const defaultCsp = "object-src 'none'; base-uri 'self'; frame-ancestors 'none'";

/// Production-grade default security headers (HSTS, frame/type protections,
/// referrer policy) — deliberately **without** a Content-Security-Policy.
///
/// These are the headers that cannot change how a page renders, so they are
/// safe to hand out as data (`zigmodu.security.defaultHeaders` aliases this
/// set). A CSP is the one header that *can* break a working site — inline
/// `<script>`, CDN assets, `data:` images all stop loading under a policy that
/// does not name them — so it is not imposed here; an application that wants a
/// policy opts into `securityHeaders`, which supplies `defaultCsp`.
pub const defaultSecurityHeaders = [_]SecurityHeader{
    .{ .name = "Strict-Transport-Security", .value = "max-age=31536000; includeSubDomains" },
    .{ .name = "X-Frame-Options", .value = "DENY" },
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    .{ .name = "Referrer-Policy", .value = "strict-origin-when-cross-origin" },
    .{ .name = "X-Permitted-Cross-Domain-Policies", .value = "none" },
    .{ .name = "X-Download-Options", .value = "noopen" },
    .{ .name = "X-DNS-Prefetch-Control", .value = "off" },
};

/// `defaultSecurityHeaders` plus `defaultCsp` — what `securityHeaders(null)`
/// installs, and the set `defaultCsp` is meant to be tightened from.
pub const defaultSecurityHeadersWithCsp = defaultSecurityHeaders ++ [_]SecurityHeader{
    .{ .name = "Content-Security-Policy", .value = defaultCsp },
};

/// Injects security response headers on every response. `null` uses the
/// built-in defaults plus `defaultCsp`; pass a custom slice for a tailored
/// policy (the middleware then sends exactly that slice — no CSP unless the
/// caller included one).
///
/// The built-in CSP is the hardening subset that cannot break rendering:
/// `object-src 'none'` (no plugin/`<embed>` documents), `base-uri 'self'`
/// (an injected `<base href>` cannot move relative URLs off-site) and
/// `frame-ancestors 'none'` (the CSP twin of the `X-Frame-Options: DENY`
/// already in the defaults). No `default-src` / `script-src` / `style-src` /
/// `form-action` here: those are policies only the application can get right —
/// they decide whether its inline scripts, CDNs and payment redirect forms
/// keep working. Add them by passing your own slice.
///
/// One store per call (like `cors` / `moduleGate`): a function-level `var` would
/// be process-wide, so a second `securityHeaders(custom)` in the same process
/// would silently retarget the first middleware's headers too.
pub fn securityHeaders(headers: ?[]const SecurityHeader) api.Middleware {
    const Store = struct {
        headers: []const SecurityHeader,
    };
    const stored = std.heap.page_allocator.create(Store) catch @panic("securityHeaders setup: out of memory");
    stored.* = .{ .headers = headers orelse &.{} };
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const st: *const Store = @ptrCast(@alignCast(user_data.?));
                const hdrs: []const SecurityHeader = if (st.headers.len > 0) st.headers else &defaultSecurityHeadersWithCsp;
                for (hdrs) |h| {
                    try ctx.setHeader(h.name, h.value);
                }
                try next(ctx);
            }
        }.mw,
        .user_data = stored,
    };
}

// ==== §9  Tests ====

test "csrf rejects state-changing requests without a matching token" {
    const allocator = std.testing.allocator;
    const mw = csrf();
    var ctx = try api.Context.init(allocator, .POST, "/api/orders");
    defer ctx.deinit();
    try ctx.headers.put(try allocator.dupe(u8, "cookie"), try allocator.dupe(u8, "csrf_token=abc"));
    try mw.func(&ctx, struct {
        fn h(_: *api.Context) anyerror!void {}
    }.h, null);
    try std.testing.expectEqual(@as(u16, 403), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "csrf allows matching double-submit tokens" {
    const allocator = std.testing.allocator;
    const mw = csrf();
    var ctx = try api.Context.init(allocator, .POST, "/api/orders");
    defer ctx.deinit();
    try ctx.headers.put(try allocator.dupe(u8, "cookie"), try allocator.dupe(u8, "csrf_token=tok123"));
    try ctx.headers.put(try allocator.dupe(u8, "x-csrf-token"), try allocator.dupe(u8, "tok123"));
    const State = struct {
        var reached = false;
    };
    try mw.func(&ctx, struct {
        fn h(_: *api.Context) anyerror!void {
            State.reached = true;
        }
    }.h, null);
    try std.testing.expect(State.reached);
    try std.testing.expectEqual(@as(u16, 200), ctx.status_code);
}

test "csrf rejects a cross-origin Origin even with a matching double-submit token" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .POST, "/api/orders");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "cookie", "csrf_token=tok123");
    try putRequestHeader(&ctx, "x-csrf-token", "tok123");
    try putRequestHeader(&ctx, "host", "app.example.com");
    try putRequestHeader(&ctx, "origin", "https://evil.example.com");

    const S = struct {
        var reached: bool = false;
    };
    S.reached = false;
    const mw = csrf();
    try mw.func(&ctx, struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
            S.reached = true;
        }
    }.n, null);

    try std.testing.expectEqual(@as(u16, 403), ctx.status_code);
    try std.testing.expect(ctx.responded);
    try std.testing.expect(!S.reached);
}

test "csrf accepts same-origin Origin and leaves missing Origin/Referer alone" {
    const allocator = std.testing.allocator;
    const mw = csrf();
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    // Same-origin: browser fetch/XHR from the site itself.
    {
        var ctx = try api.Context.init(allocator, .POST, "/api/orders");
        defer ctx.deinit();
        try putRequestHeader(&ctx, "cookie", "csrf_token=tok123");
        try putRequestHeader(&ctx, "x-csrf-token", "tok123");
        try putRequestHeader(&ctx, "host", "app.example.com");
        try putRequestHeader(&ctx, "origin", "https://app.example.com");
        try mw.func(&ctx, next, null);
        try std.testing.expect(!ctx.responded);
    }
    // No Origin, no Referer: CLI / cron / server-to-server keep the old
    // token-only behaviour (CSRF defends browsers, not these clients).
    {
        var ctx = try api.Context.init(allocator, .POST, "/api/orders");
        defer ctx.deinit();
        try putRequestHeader(&ctx, "cookie", "csrf_token=tok123");
        try putRequestHeader(&ctx, "x-csrf-token", "tok123");
        try mw.func(&ctx, next, null);
        try std.testing.expect(!ctx.responded);
    }
    // Referer fallback carries a full URL, path included; the default port is
    // omitted by browsers and often present in `Host`.
    {
        var ctx = try api.Context.init(allocator, .DELETE, "/api/orders/7");
        defer ctx.deinit();
        try putRequestHeader(&ctx, "cookie", "csrf_token=tok123");
        try putRequestHeader(&ctx, "x-csrf-token", "tok123");
        try putRequestHeader(&ctx, "host", "app.example.com:443");
        try putRequestHeader(&ctx, "referer", "https://app.example.com/admin/orders?page=2");
        try mw.func(&ctx, next, null);
        try std.testing.expect(!ctx.responded);
    }
    // A blank `Origin:` counts as absent, so the same-origin Referer still gets
    // its turn instead of the request being refused on an empty value.
    {
        var ctx = try api.Context.init(allocator, .PUT, "/api/orders/7");
        defer ctx.deinit();
        try putRequestHeader(&ctx, "cookie", "csrf_token=tok123");
        try putRequestHeader(&ctx, "x-csrf-token", "tok123");
        try putRequestHeader(&ctx, "host", "app.example.com");
        try putRequestHeader(&ctx, "origin", "");
        try putRequestHeader(&ctx, "referer", "https://app.example.com/admin/orders");
        try mw.func(&ctx, next, null);
        try std.testing.expect(!ctx.responded);
    }
}

test "csrf rejects Origin null, decoy userinfo and a cross-host Referer" {
    const allocator = std.testing.allocator;
    const mw = csrf();
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;
    // Each value is a shape a hostile page can produce (or a sandboxed iframe):
    // `null`, an authority hiding behind userinfo, another host, garbage.
    const bad_origins = [_][]const u8{
        "null",
        "https://app.example.com@evil.example.com",
        "https://evil.example.com",
        "https://evil.example.com:auth",
        "app.example.com",
    };
    for (bad_origins) |bad| {
        var ctx = try api.Context.init(allocator, .POST, "/api/orders");
        defer ctx.deinit();
        try putRequestHeader(&ctx, "cookie", "csrf_token=tok123");
        try putRequestHeader(&ctx, "x-csrf-token", "tok123");
        try putRequestHeader(&ctx, "host", "app.example.com");
        try putRequestHeader(&ctx, "origin", bad);
        try mw.func(&ctx, next, null);
        try std.testing.expectEqual(@as(u16, 403), ctx.status_code);
    }

    var ctx = try api.Context.init(allocator, .POST, "/api/orders");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "cookie", "csrf_token=tok123");
    try putRequestHeader(&ctx, "x-csrf-token", "tok123");
    try putRequestHeader(&ctx, "host", "app.example.com");
    try putRequestHeader(&ctx, "referer", "https://evil.example.com/admin");
    try mw.func(&ctx, next, null);
    try std.testing.expectEqual(@as(u16, 403), ctx.status_code);
}

test "csrf compares against X-Forwarded-Host and X-Forwarded-Proto behind a proxy" {
    const allocator = std.testing.allocator;
    const mw = csrf();
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    // TLS terminated in front: the backend sees 127.0.0.1, the browser sees
    // https://app.example.com. The proxy headers make that same-origin.
    {
        var ctx = try api.Context.init(allocator, .POST, "/api/orders");
        defer ctx.deinit();
        try putRequestHeader(&ctx, "cookie", "csrf_token=tok123");
        try putRequestHeader(&ctx, "x-csrf-token", "tok123");
        try putRequestHeader(&ctx, "host", "127.0.0.1:8080");
        try putRequestHeader(&ctx, "x-forwarded-host", "app.example.com");
        try putRequestHeader(&ctx, "x-forwarded-proto", "https");
        try putRequestHeader(&ctx, "origin", "https://app.example.com");
        try mw.func(&ctx, next, null);
        try std.testing.expect(!ctx.responded);
    }
    // The proxy says the request arrived over http while the browser claims
    // https: not the same origin.
    {
        var ctx = try api.Context.init(allocator, .POST, "/api/orders");
        defer ctx.deinit();
        try putRequestHeader(&ctx, "cookie", "csrf_token=tok123");
        try putRequestHeader(&ctx, "x-csrf-token", "tok123");
        try putRequestHeader(&ctx, "host", "127.0.0.1:8080");
        try putRequestHeader(&ctx, "x-forwarded-host", "app.example.com");
        try putRequestHeader(&ctx, "x-forwarded-proto", "http");
        try putRequestHeader(&ctx, "origin", "https://app.example.com");
        try mw.func(&ctx, next, null);
        try std.testing.expectEqual(@as(u16, 403), ctx.status_code);
    }
    // The proxy headers name the site; the browser says it is somewhere else.
    {
        var ctx = try api.Context.init(allocator, .POST, "/api/orders");
        defer ctx.deinit();
        try putRequestHeader(&ctx, "cookie", "csrf_token=tok123");
        try putRequestHeader(&ctx, "x-csrf-token", "tok123");
        try putRequestHeader(&ctx, "host", "127.0.0.1:8080");
        try putRequestHeader(&ctx, "x-forwarded-host", "app.example.com");
        try putRequestHeader(&ctx, "origin", "https://evil.example.com");
        try mw.func(&ctx, next, null);
        try std.testing.expectEqual(@as(u16, 403), ctx.status_code);
    }
}

test "csrf blocks a cross-origin POST through the dispatch path" {
    const allocator = std.testing.allocator;
    const Testkit = @import("../http/Testkit.zig");
    var server = api.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    try server.addMiddleware(csrf());
    var group = server.group("");
    try group.post("orders", struct {
        fn h(ctx: *api.Context) anyerror!void {
            try ctx.jsonStruct(200, .{ .ok = true });
        }
    }.h, null);

    const cross_origin = [_]Testkit.HeaderPair{
        .{ "cookie", "csrf_token=tok123" },
        .{ "x-csrf-token", "tok123" },
        .{ "host", "app.example.com" },
        .{ "origin", "https://evil.example.com" },
    };
    var resp = try Testkit.dispatchOpts(&server, .POST, "/orders", .{ .headers = &cross_origin });
    defer resp.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 403), resp.status_code);

    const same_origin = [_]Testkit.HeaderPair{
        .{ "cookie", "csrf_token=tok123" },
        .{ "x-csrf-token", "tok123" },
        .{ "host", "app.example.com" },
        .{ "origin", "https://app.example.com" },
    };
    var resp_ok = try Testkit.dispatchOpts(&server, .POST, "/orders", .{ .headers = &same_origin });
    defer resp_ok.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), resp_ok.status_code);
}

test "SecurityHeader: defaults carry no CSP, securityHeaders(null) adds one" {
    const allocator = std.testing.allocator;
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    // The data-only default set is CSP-free: `security.defaultHeaders` (the
    // alias below) is handed to callers that never opted into a policy.
    for (defaultSecurityHeaders) |h| {
        try std.testing.expect(!std.mem.eql(u8, h.name, "Content-Security-Policy"));
    }
    for (@import("../security/SecurityHeaders.zig").defaultHeaders) |h| {
        try std.testing.expect(!std.mem.eql(u8, h.name, "Content-Security-Policy"));
    }

    // The opt-in middleware, default policy → CSP present.
    {
        const mw = securityHeaders(null);
        var ctx = try api.Context.init(allocator, .GET, "/");
        defer ctx.deinit();
        try mw.func(&ctx, next, mw.user_data);
        try std.testing.expectEqualStrings(defaultCsp, ctx.response_headers.get("Content-Security-Policy").?);
        try std.testing.expect(ctx.response_headers.get("X-Frame-Options") != null);
    }
    // A caller-supplied slice replaces the whole set (CSP included, if wanted).
    {
        const custom = [_]SecurityHeader{.{ .name = "X-Policy-A", .value = "a" }};
        const mw = securityHeaders(&custom);
        var ctx = try api.Context.init(allocator, .GET, "/");
        defer ctx.deinit();
        try mw.func(&ctx, next, mw.user_data);
        try std.testing.expect(ctx.response_headers.get("Content-Security-Policy") == null);
        try std.testing.expect(ctx.response_headers.get("Strict-Transport-Security") == null);
    }
}

test "securityHeaders injects defaults and calls through" {
    const allocator = std.testing.allocator;
    const mw = securityHeaders(null);
    var ctx = try api.Context.init(allocator, .GET, "/");
    defer ctx.deinit();
    const State = struct {
        var reached = false;
    };
    try mw.func(&ctx, struct {
        fn h(_: *api.Context) anyerror!void {
            State.reached = true;
        }
    }.h, mw.user_data);
    try std.testing.expect(State.reached);
    try std.testing.expect(ctx.response_headers.get("Strict-Transport-Security") != null);
    try std.testing.expect(ctx.response_headers.get("X-Frame-Options") != null);
}

test "each securityHeaders instance keeps its own headers" {
    const allocator = std.testing.allocator;
    const custom_a = [_]SecurityHeader{.{ .name = "X-Policy-A", .value = "a" }};
    const custom_b = [_]SecurityHeader{.{ .name = "X-Policy-B", .value = "b" }};
    const mw_a = securityHeaders(&custom_a);
    const mw_b = securityHeaders(&custom_b);
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var ctx_a = try api.Context.init(allocator, .GET, "/");
    defer ctx_a.deinit();
    try mw_a.func(&ctx_a, next, mw_a.user_data);
    try std.testing.expectEqualStrings("a", ctx_a.response_headers.get("X-Policy-A").?);
    try std.testing.expect(ctx_a.response_headers.get("X-Policy-B") == null);

    var ctx_b = try api.Context.init(allocator, .GET, "/");
    defer ctx_b.deinit();
    try mw_b.func(&ctx_b, next, mw_b.user_data);
    try std.testing.expectEqualStrings("b", ctx_b.response_headers.get("X-Policy-B").?);
}

test "cors middleware sets headers" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const cfg = CorsConfig{};
    const mw = cors(cfg);
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqualStrings("*", ctx.response_headers.get("Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("GET,POST,PUT,DELETE,PATCH,HEAD,OPTIONS", ctx.response_headers.get("Access-Control-Allow-Methods").?);
}

test "cors matches Origin case-insensitively (lowercased request headers)" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/api/v1/users");
    defer ctx.deinit();
    // Request header keys are lowercased at parse time; a browser's
    // `Origin:` header arrives with key "origin".
    try ctx.headers.put(try allocator.dupe(u8, "origin"), try allocator.dupe(u8, "https://app.example.com"));

    const mw = cors(.{ .allow_origins = &.{"https://app.example.com"} });
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqualStrings("https://app.example.com", ctx.response_headers.get("Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("Origin", ctx.response_headers.get("Vary").?);
}

test "cors rejects origins outside the allow-list with 403" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/api/v1/users");
    defer ctx.deinit();
    try ctx.headers.put(try allocator.dupe(u8, "origin"), try allocator.dupe(u8, "https://evil.example.com"));

    const mw = cors(.{ .allow_origins = &.{"https://app.example.com"} });
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 403), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "cors instances with different configs stay isolated (no static overwrite)" {
    const allocator = std.testing.allocator;
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    // Register the first instance, then a second with a different whitelist.
    // With the old module-level static storage, mw_b would overwrite mw_a's
    // config and a.example.com would be rejected.
    const mw_a = cors(.{ .allow_origins = &.{"https://a.example.com"} });
    const mw_b = cors(.{ .allow_origins = &.{"https://b.example.com"} });

    var ctx_a = try api.Context.init(allocator, .GET, "/api/v1/users");
    defer ctx_a.deinit();
    try ctx_a.headers.put(try allocator.dupe(u8, "origin"), try allocator.dupe(u8, "https://a.example.com"));
    try mw_a.func(&ctx_a, next, mw_a.user_data);
    try std.testing.expectEqualStrings("https://a.example.com", ctx_a.response_headers.get("Access-Control-Allow-Origin").?);

    var ctx_b = try api.Context.init(allocator, .GET, "/api/v1/users");
    defer ctx_b.deinit();
    try ctx_b.headers.put(try allocator.dupe(u8, "origin"), try allocator.dupe(u8, "https://b.example.com"));
    try mw_b.func(&ctx_b, next, mw_b.user_data);
    try std.testing.expectEqualStrings("https://b.example.com", ctx_b.response_headers.get("Access-Control-Allow-Origin").?);
}

test "maxBodySize middleware rejects large payload" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .POST, "/test");
    defer ctx.deinit();
    ctx.body = "this is a test body that is longer than ten bytes";

    const mw = maxBodySize(10);
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 413), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "recover middleware catches panic" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const mw = recover();
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
            return error.SomePanic;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 500), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "jwtAuth middleware rejects missing authorization" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const mw = jwtAuth("secret");
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

fn putRequestHeader(ctx: *api.Context, key: []const u8, value: []const u8) !void {
    const k = try ctx.allocator.dupe(u8, key);
    errdefer ctx.allocator.free(k);
    const v = try ctx.allocator.dupe(u8, value);
    errdefer ctx.allocator.free(v);
    try ctx.headers.put(k, v);
}

fn putBearerAuth(ctx: *api.Context, token: []const u8) !void {
    const k = try ctx.allocator.dupe(u8, "authorization");
    errdefer ctx.allocator.free(k);
    const v = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{token});
    errdefer ctx.allocator.free(v);
    try ctx.headers.put(k, v);
}

test "jwtAuth middleware accepts valid token" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "secret", 3600);
    const token = try sec.generateToken("user-1", &.{});
    defer allocator.free(token);

    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();
    try putBearerAuth(&ctx, token);

    const S = struct {
        var reached: bool = false;
    };
    S.reached = false;
    const mw = jwtAuth("secret");
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
            S.reached = true;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(S.reached);
    try std.testing.expect(!ctx.responded);
}

test "jwtAuth middleware rejects tampered token" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "secret", 3600);
    const token = try sec.generateToken("user-1", &.{});
    defer allocator.free(token);

    var tampered = try allocator.dupe(u8, token);
    defer allocator.free(tampered);
    if (tampered.len > 10) tampered[tampered.len - 5] +%= 1;

    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();
    try putBearerAuth(&ctx, tampered);

    const mw = jwtAuth("secret");
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "jwtAuth middleware rejects expired token" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "secret", -1);
    const token = try sec.generateToken("user-1", &.{});
    defer allocator.free(token);

    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();
    try putBearerAuth(&ctx, token);

    const mw = jwtAuth("secret");
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "jwtAuthWithSecurity uses wall clock from SecurityModule io" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.initWithIo(allocator, "secret", 3600, std.testing.io);
    const token = try sec.generateToken("user-1", &.{});
    defer allocator.free(token);

    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();
    ctx.io = std.testing.io;
    try putBearerAuth(&ctx, token);

    var reached = false;
    const mw = jwtAuthWithSecurity(&sec);
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    reached = !ctx.responded;
    try std.testing.expect(reached);
}

test "csrf middleware rejects POST without matching token" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .POST, "/test");
    defer ctx.deinit();

    const mw = csrf();
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 403), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "csrf middleware accepts POST with double-submit token" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .POST, "/test");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "x-csrf-token", "abc123");
    try putRequestHeader(&ctx, "cookie", "csrf_token=abc123");

    const S = struct {
        var reached: bool = false;
    };
    S.reached = false;
    const mw = csrf();
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
            S.reached = true;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(S.reached);
    try std.testing.expect(!ctx.responded);
}

test "csrf middleware allows GET without token" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const S = struct {
        var reached: bool = false;
    };
    S.reached = false;
    const mw = csrf();
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
            S.reached = true;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(S.reached);
}

test "jwtAuthFromCatalog skips public and skip_prefixes" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/open"),
        .auth = .public,
        .module = "open",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    var sec = SecurityModule.init(alloc, "test-secret", 3600);
    const mw = jwtAuthFromCatalog(&sec, &slot, .{});
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var pub_ctx = try api.Context.init(alloc, .GET, "/api/v1/open");
    defer pub_ctx.deinit();
    try mw.func(&pub_ctx, next, mw.user_data);
    try std.testing.expect(!pub_ctx.responded);

    var health_ctx = try api.Context.init(alloc, .GET, "/health/live");
    defer health_ctx.deinit();
    try mw.func(&health_ctx, next, mw.user_data);
    try std.testing.expect(!health_ctx.responded);

    var priv_ctx = try api.Context.init(alloc, .GET, "/api/v1/secret");
    defer priv_ctx.deinit();
    try mw.func(&priv_ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), priv_ctx.status_code);
}

test "moduleGate sets attr and can deny unknown" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/users"),
        .auth = .jwt,
        .module = "user",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const mw = moduleGate(&slot, .{ .unknown = .deny });
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var ok_ctx = try api.Context.init(alloc, .GET, "/api/v1/users");
    defer ok_ctx.deinit();
    try mw.func(&ok_ctx, next, mw.user_data);
    try std.testing.expectEqualStrings("user", ok_ctx.getAttr("module").?);

    var bad_ctx = try api.Context.init(alloc, .GET, "/api/v1/nope");
    defer bad_ctx.deinit();
    try mw.func(&bad_ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 404), bad_ctx.status_code);
}

test "permissionGate requires role matching RouteMeta.permission" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .DELETE,
        .path = try alloc.dupe(u8, "api/v1/tenants/{id}"),
        .auth = .jwt,
        .module = "tenant",
        .permission = "admin",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const mw = permissionGate(&slot);
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var deny_ctx = try api.Context.init(alloc, .DELETE, "/api/v1/tenants/1");
    defer deny_ctx.deinit();
    try deny_ctx.setAttr("roles", "user");
    try mw.func(&deny_ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 403), deny_ctx.status_code);

    var allow_ctx = try api.Context.init(alloc, .DELETE, "/api/v1/tenants/1");
    defer allow_ctx.deinit();
    try allow_ctx.setAttr("roles", "user,admin");
    try mw.func(&allow_ctx, next, mw.user_data);
    try std.testing.expect(!allow_ctx.responded);
    try std.testing.expectEqualStrings("admin", allow_ctx.getAttr("permission").?);
}

test "permissionMatchesRoles supports OR alternatives" {
    try std.testing.expect(permissionMatchesRoles("user,owner", "admin|owner"));
    try std.testing.expect(!permissionMatchesRoles("user", "admin|owner"));
    try std.testing.expect(permissionMatchesRoles(" admin ", "admin"));
}

test "permissionGate accepts any OR alternative" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .DELETE,
        .path = try alloc.dupe(u8, "api/v1/tenants/{id}"),
        .auth = .jwt,
        .module = "tenant",
        .permission = "admin|owner",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const mw = permissionGate(&slot);
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var ok_ctx = try api.Context.init(alloc, .DELETE, "/api/v1/tenants/1");
    defer ok_ctx.deinit();
    try ok_ctx.setAttr("roles", "owner");
    try mw.func(&ok_ctx, next, mw.user_data);
    try std.testing.expect(!ok_ctx.responded);
}

test "each permissionGateWith keeps its own catalog slot and config" {
    const alloc = std.testing.allocator;
    // Gate A: slot A marks the route `.jwt` + permission "admin".
    var entries_a = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries_a[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/tenants"),
        .auth = .jwt,
        .module = "tenant",
        .permission = "admin",
    };
    var slot_a: comptime_router.CatalogSlot = .{};
    defer slot_a.deinit();
    slot_a.set(.{ .allocator = alloc, .entries = entries_a });

    // Gate B: slot B has the same path with no permission, and denies
    // unannotated routes.
    var entries_b = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries_b[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/tenants"),
        .auth = .jwt,
        .module = "tenant",
    };
    var slot_b: comptime_router.CatalogSlot = .{};
    defer slot_b.deinit();
    slot_b.set(.{ .allocator = alloc, .entries = entries_b });

    const mw_a = permissionGateWith(&slot_a, .{});
    const mw_b = permissionGateWith(&slot_b, .{ .deny_by_default = true });
    const S = struct {
        var reached = false;
        fn n(_: *api.Context) anyerror!void {
            reached = true;
        }
    };

    // A gate must read the slot and config it was built with. Sharing one
    // function-level `var` made the second call overwrite the first, so mw_a
    // would have run against slot_b / deny_by_default and 403'd here.
    S.reached = false;
    var ctx_a = try api.Context.init(alloc, .GET, "/api/v1/tenants");
    defer ctx_a.deinit();
    try ctx_a.setAttr("roles", "admin");
    try mw_a.func(&ctx_a, S.n, mw_a.user_data);
    try std.testing.expect(!ctx_a.responded);
    try std.testing.expect(S.reached);

    // mw_b keeps `.deny_by_default`: the route carries no permission → 403.
    S.reached = false;
    var ctx_b = try api.Context.init(alloc, .GET, "/api/v1/tenants");
    defer ctx_b.deinit();
    try ctx_b.setAttr("roles", "admin");
    try mw_b.func(&ctx_b, S.n, mw_b.user_data);
    try std.testing.expectEqual(@as(u16, 403), ctx_b.status_code);
    try std.testing.expect(!S.reached);
}

test "permissionGateWith fails closed before the catalog is ready" {
    const alloc = std.testing.allocator;
    var slot: comptime_router.CatalogSlot = .{}; // never `.set()` — startup window / unwired server
    defer slot.deinit();

    const mw = permissionGateWith(&slot, .{});
    const S = struct {
        var reached = false;
        fn n(_: *api.Context) anyerror!void {
            reached = true;
        }
    };

    var ctx = try api.Context.init(alloc, .GET, "/api/v1/tenants");
    defer ctx.deinit();
    try mw.func(&ctx, S.n, mw.user_data);

    // Nothing may run un-permission-checked just because the gate cannot see
    // which routes exist. `jwtAuthFromCatalog*` forces authentication in the
    // same state; a gate has no token to demand, so it refuses.
    try std.testing.expect(!S.reached);
    try std.testing.expectEqual(@as(u16, 503), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "permissionGate rbac mode uses permissions attr not roles" {
    const alloc = std.testing.allocator;

    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .DELETE,
        .path = try alloc.dupe(u8, "api/v1/tenants/{id}"),
        .auth = .jwt,
        .module = "tenant",
        .permission = "tenant:suspend",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const mw = permissionGateWith(&slot, .{ .mode = .rbac });
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    // Has role admin but no permission code → deny
    var deny_ctx = try api.Context.init(alloc, .DELETE, "/api/v1/tenants/1");
    defer deny_ctx.deinit();
    try deny_ctx.setAttr("roles", "admin");
    try deny_ctx.setAttr("permissions", "tenant:read");
    try mw.func(&deny_ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 403), deny_ctx.status_code);

    var allow_ctx = try api.Context.init(alloc, .DELETE, "/api/v1/tenants/1");
    defer allow_ctx.deinit();
    try allow_ctx.setAttr("roles", "user");
    try allow_ctx.setAttr("permissions", "tenant:read,tenant:suspend");
    try mw.func(&allow_ctx, next, mw.user_data);
    try std.testing.expect(!allow_ctx.responded);
    try std.testing.expectEqualStrings("tenant:suspend", allow_ctx.getAttr("permission").?);
}

test "jwtAuthFromCatalogWithPermissions loads permission CSV" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "api/v1/tenants"),
        .auth = .jwt,
        .module = "tenant",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const table = Rbac.RolePermissionTable{ .rows = &.{
        .{ .role = "admin", .permissions = &.{ Rbac.Permissions.tenant_suspend, Rbac.Permissions.tenant_read } },
    } };
    var sec = SecurityModule.init(alloc, "test-secret", 3600);
    const token = try sec.generateTokenWithTenant("u1", &.{"admin"}, "42");
    defer alloc.free(token);

    const mw = jwtAuthFromCatalogWithPermissions(&sec, &slot, catalogLoaderFromTable(&table), .{});
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var ctx = try api.Context.init(alloc, .GET, "/api/v1/tenants");
    defer ctx.deinit();
    const auth_hdr = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    defer alloc.free(auth_hdr);
    try ctx.headers.put(try alloc.dupe(u8, "authorization"), try alloc.dupe(u8, auth_hdr));
    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(!ctx.responded);
    try std.testing.expectEqualStrings("u1", ctx.getAttr("user_id").?);
    try std.testing.expectEqualStrings("42", ctx.getAttr("tenant_id").?);
    const perms = ctx.getAttr("permissions").?;
    try std.testing.expect(std.mem.indexOf(u8, perms, "tenant:suspend") != null);
}

test "CatalogPermissionLoader receives sub and aud" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "shop/products"),
        .auth = .jwt,
        .module = "shop",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const S = struct {
        var seen_sub: []u8 = &.{};
        var seen_aud: []u8 = &.{};
        var seen_role: []u8 = &.{};
        fn load(allocator: std.mem.Allocator, input: CatalogPermLoadInput) anyerror![]u8 {
            // Copy: payload slices are freed after verify returns.
            if (seen_sub.len > 0) allocator.free(seen_sub);
            if (seen_aud.len > 0) allocator.free(seen_aud);
            if (seen_role.len > 0) allocator.free(seen_role);
            seen_sub = try allocator.dupe(u8, input.sub);
            seen_aud = try allocator.dupe(u8, input.aud);
            seen_role = if (input.roles.len > 0) try allocator.dupe(u8, input.roles[0]) else &.{};
            return try std.fmt.allocPrint(allocator, "portal:shop,shop.product:write@{s}/{s}", .{ input.aud, input.sub });
        }
    };

    var sec = SecurityModule.init(alloc, "test-secret", 3600);
    const token = try sec.generateTokenWithTenant("99", &.{"shop"}, "1001");
    defer alloc.free(token);

    const mw = jwtAuthFromCatalogWithPermissions(&sec, &slot, S.load, .{});
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var ctx = try api.Context.init(alloc, .GET, "/shop/products");
    defer ctx.deinit();
    const auth_hdr = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    defer alloc.free(auth_hdr);
    try ctx.headers.put(try alloc.dupe(u8, "authorization"), try alloc.dupe(u8, auth_hdr));
    try mw.func(&ctx, next, mw.user_data);
    defer {
        if (S.seen_sub.len > 0) alloc.free(S.seen_sub);
        if (S.seen_aud.len > 0) alloc.free(S.seen_aud);
        if (S.seen_role.len > 0) alloc.free(S.seen_role);
    }
    try std.testing.expectEqualStrings("99", S.seen_sub);
    try std.testing.expectEqualStrings("1001", S.seen_aud);
    try std.testing.expectEqualStrings("shop", S.seen_role);
    const perms = ctx.getAttr("permissions").?;
    try std.testing.expect(std.mem.indexOf(u8, perms, "1001/99") != null);
}

test "authFromCatalog wraps a custom backend; catalog is sole bypass truth" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 2);
    entries[0] = .{ .method = .GET, .path = try alloc.dupe(u8, "api/open"), .auth = .public, .module = "open" };
    entries[1] = .{ .method = .POST, .path = try alloc.dupe(u8, "api/orders"), .auth = .jwt, .module = "order" };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    // Redis/token-service style backend: accepts `X-Token: good` only.
    const backend = AuthBackend{
        .verifyFn = struct {
            fn verify(ctx: *api.Context, _: ?*anyopaque) anyerror!bool {
                const tok = extractHeaderToken(ctx, "x-token") orelse return false;
                if (!std.mem.eql(u8, tok, "good")) return false;
                try ctx.setIdentity(.{ .user_id = "u-7", .tenant_id = "shop-1", .roles = "admin" });
                return true;
            }
        }.verify,
    };
    const mw = authFromCatalog(&slot, backend, .{ .reject = envelopeReject(.thinkphp) });
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    // public route passes without any token
    var pub_ctx = try api.Context.init(alloc, .GET, "/api/open");
    defer pub_ctx.deinit();
    try mw.func(&pub_ctx, next, mw.user_data);
    try std.testing.expect(!pub_ctx.responded);

    // protected route without token → 401 in ThinkPHP envelope
    var no_ctx = try api.Context.init(alloc, .POST, "/api/orders");
    defer no_ctx.deinit();
    try mw.func(&no_ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), no_ctx.status_code);
    try std.testing.expectEqualStrings("{\"code\":-1,\"msg\":\"Unauthorized\",\"data\":null}", no_ctx.response_body.items);

    // protected route with valid token → identity attrs set
    var ok_ctx = try api.Context.init(alloc, .POST, "/api/orders");
    defer ok_ctx.deinit();
    try ok_ctx.headers.put(try alloc.dupe(u8, "x-token"), try alloc.dupe(u8, "good"));
    try mw.func(&ok_ctx, next, mw.user_data);
    try std.testing.expect(!ok_ctx.responded);
    try std.testing.expectEqualStrings("u-7", ok_ctx.userId().?);
    try std.testing.expectEqualStrings("shop-1", ok_ctx.tenantId().?);
    try std.testing.expectEqualStrings("admin", ok_ctx.rolesCsv().?);
}

test "authFromCatalog with jwtBackend verifies real tokens" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{ .method = .GET, .path = try alloc.dupe(u8, "api/me"), .auth = .jwt, .module = "user" };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    var sec = SecurityModule.init(alloc, "test-secret", 3600);
    const token = try sec.generateTokenWithTenant("42", &.{"admin"}, "tenant-a");
    defer alloc.free(token);

    const mw = authFromCatalog(&slot, jwtBackend(&sec), .{});
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var ctx = try api.Context.init(alloc, .GET, "/api/me");
    defer ctx.deinit();
    try putBearerAuth(&ctx, token);
    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expect(!ctx.responded);
    try std.testing.expectEqual(@as(?i64, 42), ctx.userIdInt(i64));
    try std.testing.expectEqualStrings("tenant-a", ctx.tenantId().?);

    var bad = try api.Context.init(alloc, .GET, "/api/me");
    defer bad.deinit();
    try mw.func(&bad, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), bad.status_code);
}

test "tenantResolver resolves header/query and respects existing attr" {
    const alloc = std.testing.allocator;
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    const mw = tenantResolver(.{});
    var ctx = try api.Context.init(alloc, .POST, "/api/orders");
    defer ctx.deinit();
    try ctx.headers.put(try alloc.dupe(u8, "appid"), try alloc.dupe(u8, "shop-9"));
    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqualStrings("shop-9", ctx.tenantId().?);

    // existing attr (e.g. JWT aud) wins by default
    var ctx2 = try api.Context.init(alloc, .POST, "/api/orders");
    defer ctx2.deinit();
    try ctx2.setAttr("tenant_id", "jwt-tenant");
    try ctx2.headers.put(try alloc.dupe(u8, "appid"), try alloc.dupe(u8, "shop-9"));
    try mw.func(&ctx2, next, mw.user_data);
    try std.testing.expectEqualStrings("jwt-tenant", ctx2.tenantId().?);

    // require → 400 when unresolved
    const mw_req = tenantResolver(.{ .require = true });
    var ctx3 = try api.Context.init(alloc, .POST, "/api/orders");
    defer ctx3.deinit();
    try mw_req.func(&ctx3, next, mw_req.user_data);
    try std.testing.expectEqual(@as(u16, 400), ctx3.status_code);
}

test "token extractors cover bearer, x-token, query" {
    const alloc = std.testing.allocator;
    var ctx = try api.Context.init(alloc, .GET, "/");
    defer ctx.deinit();

    try std.testing.expect(extractTokenAny(&ctx, &.{ .bearer, .x_token, .query }) == null);
    try ctx.query.put("token", "q-tok"); // Params duplicates internally
    try std.testing.expectEqualStrings("q-tok", extractTokenAny(&ctx, &.{ .bearer, .query }).?);
    try ctx.headers.put(try alloc.dupe(u8, "x-token"), try alloc.dupe(u8, "x-tok"));
    try std.testing.expectEqualStrings("x-tok", extractTokenAny(&ctx, &.{ .x_token, .query }).?);
    try ctx.headers.put(try alloc.dupe(u8, "authorization"), try alloc.dupe(u8, "Bearer b-tok"));
    try std.testing.expectEqualStrings("b-tok", extractTokenAny(&ctx, &.{ .bearer, .x_token }).?);
    // bare header value without Bearer prefix is accepted as-is
    try std.testing.expectEqualStrings("x-tok", extractHeaderToken(&ctx, "x-token").?);
}

test "permissionGate enforces RouteMeta.roles before permission" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(comptime_router.CatalogEntry, 1);
    entries[0] = .{
        .method = .GET,
        .path = try alloc.dupe(u8, "admin-api/setting"),
        .auth = .jwt,
        .module = "setting",
        .roles = "admin|ops",
    };
    var slot: comptime_router.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(.{ .allocator = alloc, .entries = entries });

    const mw = permissionGateWith(&slot, .{ .reject = envelopeReject(.thinkphp) });
    const next = struct {
        fn n(_: *api.Context) anyerror!void {}
    }.n;

    var deny = try api.Context.init(alloc, .GET, "/admin-api/setting");
    defer deny.deinit();
    try deny.setAttr("roles", "cashier");
    try mw.func(&deny, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 403), deny.status_code);
    try std.testing.expectEqualStrings("{\"code\":403,\"msg\":\"Forbidden\",\"data\":null}", deny.response_body.items);

    var allow = try api.Context.init(alloc, .GET, "/admin-api/setting");
    defer allow.deinit();
    try allow.setAttr("roles", "ops");
    try mw.func(&allow, next, mw.user_data);
    try std.testing.expect(!allow.responded);
}

test "Auth.optional: identity when a token is valid, no 401 otherwise" {
    const allocator = std.testing.allocator;
    const Testkit = @import("../http/Testkit.zig");
    const cr = @import("ComptimeRouter.zig");

    const AppState = struct {};

    const Api = struct {
        pub const module_name = "profile";
        pub const nest = .{};
        pub const State = @This();

        pub const routes = [_]cr.RouteSpec(State){
            // Public: never sees identity in this middleware stack.
            .{ .method = .GET, .path = "public", .handler = whoami, .meta = .{ .auth = .public } },
            // Optional: same route code, personalized when a token is present.
            .{ .method = .GET, .path = "optional", .handler = whoami, .meta = .{ .auth = .optional } },
            // Required: still 401s without a token.
            .{ .method = .GET, .path = "private", .handler = whoami, .meta = .{ .auth = .jwt } },
        };

        fn whoami(ctx: *@import("Server.zig").Context, _: *State) !void {
            try ctx.jsonStruct(200, .{ .user = ctx.userId() });
        }
    };

    var sec = SecurityModule.init(allocator, "optional-auth-test-secret", 3600);
    defer sec.deinit();
    var slot: cr.CatalogSlot = .{};
    defer slot.deinit();
    var app_state: AppState = .{};
    var api_state: Api = .{};

    var server = @import("Server.zig").Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    // Ordering matters (and the framework says so): middleware added *after*
    // routes are registered is not part of those routes' chain snapshot.
    try server.addMiddleware(jwtAuthFromCatalog(&sec, &slot, .{}));

    var router = cr.Router(AppState).init(std.testing.io, allocator, &server, &app_state);
    defer router.deinit();
    var root = router.scope("");
    try root.mountAll(.{.{ .Mod = Api, .state = &api_state }});
    slot.set(try router.finish());

    const token = try sec.generateTokenWithTenant("user-42", &.{"user"}, "tenant-9");
    defer allocator.free(token);
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(bearer);

    // optional, no token → 200 with no identity
    {
        var resp = try Testkit.dispatch(&server, .GET, "/optional", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"user\":null") != null);
    }
    // optional, valid token → 200 **with** identity (the whole point)
    {
        var opts = Testkit.DispatchOptions{};
        opts.headers = &.{.{ "authorization", bearer }};
        var resp = try Testkit.dispatchOpts(&server, .GET, "/optional", opts);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"user\":\"user-42\"") != null);
    }
    // optional, garbage token → still 200, still anonymous (never 401)
    {
        var opts = Testkit.DispatchOptions{};
        opts.headers = &.{.{ "authorization", "Bearer not-a-jwt" }};
        var resp = try Testkit.dispatchOpts(&server, .GET, "/optional", opts);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"user\":null") != null);
    }
    // public stays anonymous even with a valid token (documented difference)
    {
        var opts = Testkit.DispatchOptions{};
        opts.headers = &.{.{ "authorization", bearer }};
        var resp = try Testkit.dispatchOpts(&server, .GET, "/public", opts);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"user\":null") != null);
    }
    // jwt still enforces: no token → 401
    {
        var resp = try Testkit.dispatch(&server, .GET, "/private", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    }
    // jwt with a valid token → 200 with identity
    {
        var opts = Testkit.DispatchOptions{};
        opts.headers = &.{.{ "authorization", bearer }};
        var resp = try Testkit.dispatchOpts(&server, .GET, "/private", opts);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"user\":\"user-42\"") != null);
    }
}
