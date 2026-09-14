//! Error-body shape matrix.
//!
//! An application that fixes its error contract (e.g. "failures are always
//! RFC 7807 ProblemDetails") is only as consistent as the shape it *cannot*
//! reach. Before the process-wide renderers, three paths produced three
//! different bodies and an app could style one of them:
//!
//!   1. in-chain gates   → `{"code":404,"msg":"Unknown route module","data":null}`
//!   2. pre-routing      → `{"error":"Payload Too Large"}`
//!      (408/413/431/503, written straight to the socket before middleware)
//!   3. handler-owned    → whatever the handler writes
//!
//! These tests pin that (1) and (2) now follow one switch, that a gate with an
//! explicit `.reject` still wins over the process default, and that a handler
//! which never responds produces the same shape as everything else.

const std = @import("std");
const api = @import("../api/Server.zig");
const mw = @import("../api/Middleware.zig");
const cr = @import("../api/ComptimeRouter.zig");
const Testkit = @import("../http/Testkit.zig");

fn runMiddleware(m: api.Middleware, ctx: *api.Context) !void {
    const S = struct {
        fn exit(c: *api.Context) anyerror!void {
            _ = c;
        }
    };
    try m.func(ctx, S.exit, m.user_data);
}

const Harness = struct {
    server: api.Server,
    router: cr.Router(Catalog),
    slot: cr.CatalogSlot,
    api_state: Catalog,

    const Catalog = struct {
        pub const module_name = "catalog";
        pub const nest = .{};
        pub const State = @This();
        pub const routes = [_]cr.RouteSpec(State){
            .{ .method = .GET, .path = "products", .handler = hit, .meta = .{ .auth = .public } },
        };
        fn hit(ctx: *api.Context, _: *State) !void {
            try ctx.json(200, "{}");
        }
    };

    fn init(allocator: std.mem.Allocator) !Harness {
        var h: Harness = undefined;
        h.server = api.Server.init(std.testing.io, allocator, 0);
        h.api_state = .{};
        h.router = cr.Router(Catalog).init(std.testing.io, allocator, &h.server, &h.api_state);
        var root = h.router.scope("");
        try root.mountAll(.{.{ .Mod = Catalog, .state = &h.api_state }});
        h.slot = .{};
        h.slot.set(try h.router.finish());
        return h;
    }

    fn deinit(self: *Harness) void {
        self.slot.deinit();
        self.router.deinit();
        self.server.deinit();
    }
};

test "in-chain error shape: legacy envelope by default, problem+json under useRfc7807Errors" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const deny = mw.moduleGate(&h.slot, .{ .unknown = .deny });

    // No renderer installed: the gate's `.reject` default is `defaultReject`,
    // which is the legacy envelope.
    {
        var ctx = try api.Context.init(allocator, .GET, "/not-in-catalog");
        defer ctx.deinit();
        try runMiddleware(deny, &ctx);
        try std.testing.expectEqual(@as(u16, 404), ctx.status_code);
        try std.testing.expectEqualStrings("{\"code\":404,\"msg\":\"Unknown route module\",\"data\":null}", ctx.response_body.items);
    }

    mw.useRfc7807Errors();
    defer mw.clearDefaultReject();

    // Same gate, one startup switch: the 404 an unregistered path returns is now
    // the same shape the rest of the API uses.
    {
        var ctx = try api.Context.init(allocator, .GET, "/not-in-catalog");
        defer ctx.deinit();
        try runMiddleware(deny, &ctx);
        try std.testing.expectEqual(@as(u16, 404), ctx.status_code);
        try std.testing.expectEqualStrings("application/problem+json", ctx.response_headers.get("Content-Type").?);
        try std.testing.expectEqualStrings(
            "{\"status\":404,\"title\":\"Not Found\",\"detail\":\"Unknown route module\",\"instance\":\"/not-in-catalog\"}",
            ctx.response_body.items,
        );
    }

    // A gate with an explicit renderer keeps it — the process default does not
    // override a deliberate per-route choice.
    {
        var ctx = try api.Context.init(allocator, .GET, "/not-in-catalog");
        defer ctx.deinit();
        try runMiddleware(mw.moduleGate(&h.slot, .{ .unknown = .deny, .reject = mw.envelopeReject(.default) }), &ctx);
        try std.testing.expectEqualStrings("{\"code\":404,\"msg\":\"Unknown route module\",\"data\":null}", ctx.response_body.items);
    }

    // `.unknown = .deny` stays usable: the 404 body is restyled, the gate still
    // denies every path outside the catalog.
    {
        var ctx = try api.Context.init(allocator, .GET, "/health/live");
        defer ctx.deinit();
        try runMiddleware(deny, &ctx);
        try std.testing.expect(!ctx.responded);
    }
}

test "sendError follows the process-wide renderer (the uncaught-handler 500 path)" {
    const allocator = std.testing.allocator;

    // The framework raises this from `handleRequest`'s catch, outside the
    // middleware chain — no middleware can intercept it, which is why the hook is
    // process-wide rather than per-route.
    {
        var ctx = try api.Context.init(allocator, .GET, "/api/v1/x");
        defer ctx.deinit();
        try ctx.sendError(500, @errorName(error.HandlerBoom));
        try std.testing.expectEqualStrings("{\"code\":500,\"msg\":\"HandlerBoom\",\"data\":null}", ctx.response_body.items);
    }

    mw.useRfc7807Errors();
    defer mw.clearDefaultReject();

    {
        var ctx = try api.Context.init(allocator, .GET, "/api/v1/x");
        defer ctx.deinit();
        try ctx.sendError(500, @errorName(error.HandlerBoom));
        try std.testing.expectEqualStrings(
            "{\"status\":500,\"title\":\"Internal Server Error\",\"detail\":\"HandlerBoom\",\"instance\":\"/api/v1/x\"}",
            ctx.response_body.items,
        );
    }

    // `sendErrorResponse`'s business `code` has no RFC 7807 equivalent, so it is
    // dropped and the HTTP status is preserved. The escape hatch keeps both.
    {
        var ctx = try api.Context.init(allocator, .GET, "/api/v1/x");
        defer ctx.deinit();
        try ctx.sendErrorResponse(422, 4711, "Nope");
        try std.testing.expectEqual(@as(u16, 422), ctx.status_code);
        try std.testing.expectEqualStrings(
            "{\"status\":422,\"title\":\"Unprocessable Entity\",\"detail\":\"Nope\",\"instance\":\"/api/v1/x\"}",
            ctx.response_body.items,
        );
    }
    {
        var ctx = try api.Context.init(allocator, .GET, "/api/v1/x");
        defer ctx.deinit();
        try ctx.sendErrorEnvelope(422, 4711, "Nope");
        try std.testing.expectEqualStrings("{\"code\":4711,\"msg\":\"Nope\",\"data\":null}", ctx.response_body.items);
    }
}

test "server dispatch: unregistered path and uncaught handler error take the process shape" {
    const allocator = std.testing.allocator;
    const Handlers = struct {
        fn ok(ctx: *api.Context) anyerror!void {
            try ctx.json(200, "{}");
        }
        fn boom(_: *api.Context) anyerror!void {
            return error.HandlerBoom;
        }
    };

    var server = api.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var group = server.group("");
    try group.get("live", Handlers.ok, null);
    try group.get("boom", Handlers.boom, null);

    // Baseline: 404 for a path nobody registered (the common client-typo /
    // half-migrated-frontend case) and 500 for a handler that fails before
    // responding.
    {
        var resp = try Testkit.dispatch(&server, .GET, "/typo", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 404), resp.status_code);
        try std.testing.expectEqualStrings("{\"code\":404,\"msg\":\"Not Found\",\"data\":null}", resp.body);
    }
    {
        var resp = try Testkit.dispatch(&server, .GET, "/boom", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 500), resp.status_code);
        try std.testing.expectEqualStrings("{\"code\":500,\"msg\":\"HandlerBoom\",\"data\":null}", resp.body);
    }

    mw.useRfc7807Errors();
    defer mw.clearDefaultReject();

    // Both now match the contract the application advertises for its handlers.
    {
        var resp = try Testkit.dispatch(&server, .GET, "/typo", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 404), resp.status_code);
        try std.testing.expectEqualStrings(
            "{\"status\":404,\"title\":\"Not Found\",\"detail\":\"Not Found\",\"instance\":\"/typo\"}",
            resp.body,
        );
    }
    {
        var resp = try Testkit.dispatch(&server, .GET, "/boom", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 500), resp.status_code);
        try std.testing.expectEqualStrings(
            "{\"status\":500,\"title\":\"Internal Server Error\",\"detail\":\"HandlerBoom\",\"instance\":\"/boom\"}",
            resp.body,
        );
    }
    // A responding handler is untouched: the switch only styles framework errors.
    {
        var resp = try Testkit.dispatch(&server, .GET, "/live", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expectEqualStrings("{}", resp.body);
    }
}

test "pre-routing transport errors follow the same switch" {
    var buf: [512]u8 = undefined;

    // Default body, unchanged — these requests never reach a Context, so there is
    // no middleware to intercept them.
    const legacy = api.renderTransportError(413, "Payload Too Large", &buf);
    try std.testing.expectEqualStrings("application/json", legacy.content_type);
    try std.testing.expectEqualStrings("{\"error\":\"Payload Too Large\"}", legacy.body);

    mw.useRfc7807Errors();
    defer mw.clearDefaultReject();

    const problem = api.renderTransportError(413, "Payload Too Large", &buf);
    try std.testing.expectEqualStrings("application/problem+json", problem.content_type);
    try std.testing.expectEqualStrings(
        "{\"status\":413,\"title\":\"Content Too Large\",\"detail\":\"Payload Too Large\"}",
        problem.body,
    );

    // The renderer must not allocate: it runs on the accept thread.
    const oversized = api.renderTransportError(431, "Request Header Fields Too Large", &buf);
    try std.testing.expectEqualStrings(
        "{\"status\":431,\"title\":\"Request Header Fields Too Large\",\"detail\":\"Request Header Fields Too Large\"}",
        oversized.body,
    );
}

test "installing the envelope renderer as the process default cannot recurse" {
    const allocator = std.testing.allocator;

    // `defaultReject` sends through `ctx.sendError`, which is what the renderer
    // hook intercepts — so `setDefaultReject(defaultReject)` must resolve to
    // "no renderer" rather than to an unbounded loop.
    mw.setDefaultReject(mw.defaultReject);
    defer mw.clearDefaultReject();
    {
        var ctx = try api.Context.init(allocator, .GET, "/x");
        defer ctx.deinit();
        try ctx.sendError(404, "Gone");
        try std.testing.expectEqualStrings("{\"code\":404,\"msg\":\"Gone\",\"data\":null}", ctx.response_body.items);
    }

    // `null` means the same thing explicitly.
    mw.setDefaultReject(mw.problemReject);
    mw.setDefaultReject(null);
    {
        var ctx = try api.Context.init(allocator, .GET, "/x");
        defer ctx.deinit();
        try ctx.sendError(404, "Gone");
        try std.testing.expectEqualStrings("{\"code\":404,\"msg\":\"Gone\",\"data\":null}", ctx.response_body.items);
    }
}
