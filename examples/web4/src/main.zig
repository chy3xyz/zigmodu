//! web4: DID identity + x402 payment gating example.
//!
//! Two protected routes on one server:
//!   GET /api/paywall   — x402 gate: no proof → 402 + invoice; proof + valid
//!                        verifier → 200 (dev uses verifyPaymentAllowAll).
//!   GET /api/identity  — did:key auth: missing/invalid signature → 401;
//!                        valid signature → 200 with the DID.
//!
//! Run:  cd examples/web4 && zig build run
//! Test: zig build test

const std = @import("std");
const zigmodu = @import("zigmodu");

const http = zigmodu.http;
const web4 = zigmodu.web4;

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io, true);
}

fn run(allocator: std.mem.Allocator, io: std.Io, serve: bool) !void {
    // Production-grade stores: persisted invoices + one-time challenges.
    var client = zigmodu.data.sqlx.Client.init(allocator, io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = zigmodu.data.SqlxBackend{ .allocator = allocator, .client = &client };
    var invoice_store = web4.x402_store.X402Store.init(allocator, &backend);
    try invoice_store.migrate();
    var challenge_store = web4.challenge.ChallengeStore.init(allocator, io);
    defer challenge_store.deinit();
    var security = zigmodu.security.AppSecurity.init(allocator, io, .{ .jwt_secret = "web4-demo-secret" });

    var server = http.Server.init(io, allocator, 18089);
    defer server.deinit();

    // x402 gate: invoices persisted; proofs redeemed exactly once.
    var x402_cfg = web4.middleware.X402Config{
        .store = &invoice_store,
        .path_prefix = "/api/paywall",
        .payee_did = "did:key:z6MkWeb4Demo",
        .description = "web4 demo access",
    };
    try server.addMiddleware(web4.middleware.x402Middleware(&x402_cfg));

    // DID auth: protect /api/identity only.
    var did_cfg = web4.middleware.DidAuthConfig{
        .path_prefix = "/api/identity",
        .challenge_store = &challenge_store,
        .jwt_issuer = &security,
    };
    try server.addMiddleware(web4.middleware.didAuthMiddleware(&did_cfg));

    const AppState = struct {};
    var app: AppState = .{};
    var router = http.Router(AppState).init(io, allocator, &server, &app);
    defer router.deinit();

    try server.addRoute(.{
        .method = .GET,
        .path = "api/paywall",
        .handler = struct {
            fn h(ctx: *http.Context) anyerror!void {
                try ctx.json(200, "{\"paid\":true,\"route\":\"paywall\"}");
            }
        }.h,
    });
    try server.addRoute(.{
        .method = .GET,
        .path = "api/identity",
        .handler = struct {
            fn h(ctx: *http.Context) anyerror!void {
                const did = ctx.getAttr("did") orelse "?";
                const body = try std.fmt.allocPrint(ctx.allocator, "{{\"authenticated\":true,\"did\":\"{s}\"}}", .{did});
                defer ctx.allocator.free(body);
                try ctx.json(200, body);
            }
        }.h,
    });
    _ = try router.finish();

    if (serve) {
        std.debug.print("web4 example on :18089\n", .{});
        std.debug.print("  curl -i http://127.0.0.1:18089/api/paywall             # 402 + invoice\n", .{});
        std.debug.print("  # redeem the invoice_id from the 402 body (exactly once; replay → 410)\n", .{});
        std.debug.print("  curl -i http://127.0.0.1:18089/api/identity            # 401\n", .{});
        std.debug.print("  # issue a challenge, sign it with your did:key, send x-did* headers → 200 + x-did-token\n", .{});
        try server.start();
    }
}

test "web4 x402 gate: 402 without proof, 200 with proof" {
    const allocator = std.testing.allocator;
    const AppState = struct {};
    var server = http.Server.initWithConfig(std.testing.io, allocator, .{ .port = 18089 });
    defer server.deinit();
    var client = zigmodu.data.sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = zigmodu.data.SqlxBackend{ .allocator = allocator, .client = &client };
    var invoice_store = web4.x402_store.X402Store.init(allocator, &backend);
    try invoice_store.migrate();
    var x402_cfg = web4.middleware.X402Config{ .store = &invoice_store, .path_prefix = "/api/paywall" };
    try server.addMiddleware(web4.middleware.x402Middleware(&x402_cfg));
    try server.addRoute(.{
        .method = .GET,
        .path = "api/paywall",
        .handler = struct {
            fn h(ctx: *http.Context) anyerror!void {
                try ctx.json(200, "{\"paid\":true}");
            }
        }.h,
    });
    var app_state: AppState = .{};
    var router = http.Router(AppState).init(std.testing.io, allocator, &server, &app_state);
    defer router.deinit();
    _ = try router.finish();

    // No proof → 402 with a persisted invoice.
    var ctx1 = try http.Context.init(allocator, .GET, "/api/paywall");
    defer ctx1.deinit();
    try server.handleForTest(&ctx1);
    try std.testing.expectEqual(@as(u16, 402), ctx1.status_code);
    const body1 = try std.json.parseFromSlice(std.json.Value, allocator, ctx1.response_body.items, .{});
    defer body1.deinit();
    const invoice_id = body1.value.object.get("data").?.object.get("invoice_id").?.string;

    // With proof → 200 (redeemed).
    var ctx2 = try http.Context.init(allocator, .GET, "/api/paywall");
    defer ctx2.deinit();
    try ctx2.headers.put(try allocator.dupe(u8, "x402-tx-hash"), try allocator.dupe(u8, "0xabc"));
    try ctx2.headers.put(try allocator.dupe(u8, "x402-invoice-id"), try allocator.dupe(u8, invoice_id));
    try server.handleForTest(&ctx2);
    try std.testing.expectEqual(@as(u16, 200), ctx2.status_code);

    // Replay of the same invoice → 410 (anti-replay).
    var ctx3 = try http.Context.init(allocator, .GET, "/api/paywall");
    defer ctx3.deinit();
    try ctx3.headers.put(try allocator.dupe(u8, "x402-tx-hash"), try allocator.dupe(u8, "0xabc2"));
    try ctx3.headers.put(try allocator.dupe(u8, "x402-invoice-id"), try allocator.dupe(u8, invoice_id));
    try server.handleForTest(&ctx3);
    try std.testing.expectEqual(@as(u16, 410), ctx3.status_code);
}

test "web4 did auth: 401 without signature, 200 with valid signature" {
    const allocator = std.testing.allocator;
    const AppState = struct {};
    var server = http.Server.initWithConfig(std.testing.io, allocator, .{ .port = 18089 });
    defer server.deinit();
    var challenge_store = web4.challenge.ChallengeStore.init(allocator, std.testing.io);
    defer challenge_store.deinit();
    var did_cfg = web4.middleware.DidAuthConfig{ .path_prefix = "/api/identity", .challenge_store = &challenge_store };
    try server.addMiddleware(web4.middleware.didAuthMiddleware(&did_cfg));
    try server.addRoute(.{
        .method = .GET,
        .path = "api/identity",
        .handler = struct {
            fn h(ctx: *http.Context) anyerror!void {
                try ctx.json(200, "{\"ok\":true}");
            }
        }.h,
    });
    var app_state: AppState = .{};
    var router = http.Router(AppState).init(std.testing.io, allocator, &server, &app_state);
    defer router.deinit();
    _ = try router.finish();

    var ctx1 = try http.Context.init(allocator, .GET, "/api/identity");
    defer ctx1.deinit();
    try server.handleForTest(&ctx1);
    try std.testing.expectEqual(@as(u16, 401), ctx1.status_code);

    // Generate a did:key identity, sign an issued challenge, attach headers.
    var key = try web4.DidKey.generate(allocator, std.testing.io);
    defer allocator.free(key.did);
    const message = try challenge_store.issue(allocator, key.did);
    defer allocator.free(message);
    const sig = try key.sign(allocator, message);
    defer allocator.free(sig);
    const enc = std.base64.standard.Encoder;
    const b64_len = enc.calcSize(sig.len);
    const sig_b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(sig_b64);
    _ = enc.encode(sig_b64, sig);

    var ctx2 = try http.Context.init(allocator, .GET, "/api/identity");
    defer ctx2.deinit();
    try ctx2.headers.put(try allocator.dupe(u8, "x-did"), try allocator.dupe(u8, key.did));
    try ctx2.headers.put(try allocator.dupe(u8, "x-did-message"), try allocator.dupe(u8, message));
    try ctx2.headers.put(try allocator.dupe(u8, "x-did-signature"), try allocator.dupe(u8, sig_b64));
    try server.handleForTest(&ctx2);
    try std.testing.expectEqual(@as(u16, 200), ctx2.status_code);
}
