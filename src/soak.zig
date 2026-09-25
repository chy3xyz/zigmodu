//! `zig build soak` — concurrency soak tests.
//!
//! These are deliberately NOT part of `zig build test`: they spin up real
//! sockets, run N client threads against M tenants, and are sized by build
//! options (`-Dsoak-clients` / `-Dsoak-iterations`). The assertions are the
//! ones that matter for a tenant-scoped service:
//!
//!   1. no client ever reads another tenant's row (cross-tenant leak = 0),
//!   2. a frozen shared registry survives concurrent readers + failed writes,
//!   3. the connection counter returns to zero (no fd/slot leak).
//!
//! Usage: `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build soak`

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const build_options = @import("build_options");

const clients: usize = build_options.soak_clients;
const iterations: usize = build_options.soak_iterations;

const tenants = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8" };

var registry: zigmodu.FrozenStringMap(i64) = undefined;

fn tenantMiddleware(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
    // Stands in for the JWT middleware: the identity is established once, and
    // the handler only reads the attr.
    const t = ctx.header("X-Tenant-ID") orelse {
        try ctx.jsonStruct(401, .{ .message = "missing tenant" });
        return;
    };
    try ctx.setAttr("tenant_id", t);
    return next(ctx);
}

fn tenantHandler(ctx: *http.Context) anyerror!void {
    const t = ctx.getAttr("tenant_id") orelse {
        try ctx.jsonStruct(401, .{ .message = "missing tenant" });
        return;
    };
    const value = registry.get(t) orelse {
        try ctx.jsonStruct(404, .{ .message = "unknown tenant" });
        return;
    };
    try ctx.jsonStruct(200, .{ .tenant = t, .value = value });
}

const Failure = struct {
    count: std.atomic.Value(usize) = .init(0),
    first: std.atomic.Value(usize) = .init(0),

    fn record(self: *Failure, code: usize) void {
        if (self.count.fetchAdd(1, .monotonic) == 0) self.first.store(code, .monotonic);
    }
};

fn connectTo(addr: std.Io.net.IpAddress) !std.Io.net.Stream {
    return addr.connect(std.testing.io, .{ .mode = .stream });
}

/// Sends one request on a fresh connection and returns the bytes read.
fn request(addr: std.Io.net.IpAddress, tenant: []const u8, out: []u8) ![]u8 {
    var stream = try connectTo(addr);
    defer stream.close(std.testing.io);

    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET /data HTTP/1.1\r\nHost: soak\r\nX-Tenant-ID: {s}\r\nConnection: close\r\n\r\n", .{tenant});
    _ = std.posix.system.write(stream.socket.handle, req.ptr, req.len);

    var filled: usize = 0;
    while (filled < out.len) {
        var pfds = [_]std.posix.pollfd{.{
            .fd = stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfds, 3000) catch return error.Timeout;
        if (ready == 0) return error.Timeout;
        const n = std.posix.system.read(stream.socket.handle, out[filled..].ptr, out.len - filled);
        const e = std.posix.errno(n);
        if (e != .SUCCESS) return error.ReadFailed;
        const got: usize = @intCast(n);
        if (got == 0) break;
        filled += got;
    }
    return out[0..filled];
}

const ClientCtx = struct {
    addr: std.Io.net.IpAddress,
    tenant: []const u8,
    failure: *Failure,
};

fn clientWorker(ctx: *ClientCtx) void {
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const body = request(ctx.addr, ctx.tenant, &buf) catch {
            ctx.failure.record(1);
            continue;
        };
        var marker_buf: [64]u8 = undefined;
        const mine = std.fmt.bufPrint(&marker_buf, "\"tenant\":\"{s}\"", .{ctx.tenant}) catch {
            ctx.failure.record(2);
            continue;
        };
        if (std.mem.indexOf(u8, body, mine) == null) {
            ctx.failure.record(3); // missing my own tenant → wrong row
            continue;
        }
        // Any OTHER tenant marker in my response is a cross-tenant leak.
        for (tenants) |other| {
            if (std.mem.eql(u8, other, ctx.tenant)) continue;
            var other_buf: [64]u8 = undefined;
            const foreign = std.fmt.bufPrint(&other_buf, "\"tenant\":\"{s}\"", .{other}) catch continue;
            if (std.mem.indexOf(u8, body, foreign) != null) {
                ctx.failure.record(4);
                break;
            }
        }
    }
}

test "soak: N clients x M tenants — zero cross-tenant reads" {
    const allocator = std.testing.allocator;
    if (!zigmodu.NetworkProbe.available()) return error.SkipZigTest;

    registry = zigmodu.FrozenStringMap(i64).init(allocator);
    defer registry.deinit();
    for (tenants, 0..) |t, i| {
        try registry.put(t, @intCast(1000 + i));
    }
    // The whole point: the shared registry is sealed before serving starts, so
    // concurrent readers can never observe a resize/tear.
    registry.freeze();

    var server = http.Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .max_connections = 64,
        .header_timeout_ms = 3000,
    });
    defer server.deinit();
    var group = server.group("");
    var scoped = try group.use(http.Middleware{ .func = tenantMiddleware, .user_data = null });
    try scoped.get("data", tenantHandler, null);

    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *http.Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    defer th.join();
    // Registered *after* the join on purpose (defers run LIFO): `stop()` is what
    // lets the accept thread return, so the join above needs it to have run
    // first. With the only `stop()` sitting at the end of the success path, any
    // `try` in between left the process hung instead of failing the test —
    // measured: the red line printed and then `timeout 45` had to kill it
    // (EXIT=124), and `--test-timeout` does not reach the harness's runner.
    defer server.stop();

    var port: u16 = 0;
    var tries: usize = 0;
    while (tries < 300) : (tries += 1) {
        if (server.listener) |*l| {
            port = l.socket.address.getPort();
            break;
        }
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(port != 0);
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    var failure = Failure{};
    const threads = try allocator.alloc(std.Thread, clients);
    defer allocator.free(threads);
    const ctxs = try allocator.alloc(ClientCtx, clients);
    defer allocator.free(ctxs);

    for (0..clients) |i| {
        ctxs[i] = .{ .addr = addr, .tenant = tenants[i % tenants.len], .failure = &failure };
        threads[i] = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, clientWorker, .{&ctxs[i]});
    }
    for (threads) |t| t.join();

    // code 1 = transport error, 2 = self-check bug, 3 = missing own tenant,
    // 4 = another tenant's row in my response (the leak that must never happen).
    try std.testing.expectEqual(@as(usize, 0), failure.first.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), failure.count.load(.monotonic));

    // Every client disconnected: the slot counter must drain back to zero.
    var drain_tries: usize = 0;
    while (drain_tries < 200 and server.active_connections.load(.monotonic) != 0) : (drain_tries += 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expectEqual(@as(u64, 0), server.active_connections.load(.monotonic));

    // No `server.stop()` here: it is a `defer` registered after the join, so it
    // has already run by the time this line is reached — and it is the reason a
    // failure *above* this line now exits instead of hanging.
}

const MapCtx = struct {
    map: *zigmodu.FrozenStringMap(i64),
    tenant: []const u8,
    expect: i64,
    failure: *Failure,
};

fn mapWorker(ctx: *MapCtx) void {
    var i: usize = 0;
    while (i < iterations * 10) : (i += 1) {
        // Reads must stay correct while other threads attempt writes.
        const got = ctx.map.get(ctx.tenant) orelse {
            ctx.failure.record(10);
            continue;
        };
        if (got != ctx.expect) ctx.failure.record(11);
        if (ctx.map.put(ctx.tenant, 0)) |_| {
            ctx.failure.record(12); // a frozen map accepted a write
        } else |_| {}
    }
}

test "soak: frozen registry — concurrent readers + rejected writers" {
    const allocator = std.testing.allocator;
    var map = zigmodu.FrozenStringMap(i64).init(allocator);
    defer map.deinit();
    for (tenants, 0..) |t, i| try map.put(t, @intCast(i));
    map.freeze();

    var failure = Failure{};
    const workers = 16;
    const threads = try allocator.alloc(std.Thread, workers);
    defer allocator.free(threads);
    const ctxs = try allocator.alloc(MapCtx, workers);
    defer allocator.free(ctxs);

    for (0..workers) |i| {
        ctxs[i] = .{
            .map = &map,
            .tenant = tenants[i % tenants.len],
            .expect = @intCast(i % tenants.len),
            .failure = &failure,
        };
        threads[i] = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, mapWorker, .{&ctxs[i]});
    }
    for (threads) |t| t.join();

    // 10 = read of a frozen key failed, 11 = torn/wrong value, 12 = write accepted.
    try std.testing.expectEqual(@as(usize, 0), failure.first.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), failure.count.load(.monotonic));
    try std.testing.expect(map.isFrozen());
    for (tenants, 0..) |t, i| {
        try std.testing.expectEqual(@as(?i64, @intCast(i)), map.get(t));
    }
}
