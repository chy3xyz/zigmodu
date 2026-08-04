//! Notification hub ("通知分发"): deliver a message to named channels —
//! webhooks (via `HttpClient`), custom sinks (email/IM/in-app via a callback),
//! or a durable transactional-outbox fallback. Reporter / alerts / recon /
//! approval outputs can be routed here, and the `notification.send` skill
//! bridge lets an Agent dispatch app-registered notifications (channels and
//! targets stay app-owned; the LLM only supplies recipient/title/body).

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const SkillRegistry = @import("skill.zig").SkillRegistry;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const HttpClient = @import("../http/HttpClient.zig").HttpClient;

/// A named delivery channel. Caller owns the strings and the callback.
pub const NotificationChannel = struct {
    name: []const u8,
    kind: Kind,

    pub const Kind = union(enum) {
        webhook: WebhookTarget,
        sink: Sink,
    };

    pub const WebhookTarget = struct {
        url: []const u8,
    };

    pub const Sink = struct {
        userdata: *anyopaque,
        call: SinkFn,
    };

    /// Custom sink (e.g. email/IM): `body` is the JSON payload to deliver.
    pub const SinkFn = *const fn (
        userdata: *anyopaque,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        channel_name: []const u8,
        body: []const u8,
    ) anyerror!void;
};

pub const DeliveryReport = struct {
    delivered: usize,
    channels: usize,

    pub fn all(self: *const DeliveryReport) bool {
        return self.delivered == self.channels;
    }
};

pub const NotificationHub = struct {
    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    http: *HttpClient,
    channels: []const NotificationChannel = &.{},
    outbox: ?*OutboxPublisher = null,
    outbox_topic: []const u8 = "ai.notify",

    pub fn init(allocator: std.mem.Allocator, backend: *SqlxBackend, http: *HttpClient) NotificationHub {
        return .{ .allocator = allocator, .backend = backend, .http = http };
    }

    /// Deliver `body` (JSON) to every configured channel. Webhooks are posted
    /// immediately (HTTP 2xx counts as delivered); sinks are invoked; when no
    /// channel matches, the message is persisted to the outbox as a durable
    /// fallback. Never silently drops: delivery failures propagate.
    pub fn deliver(
        self: *NotificationHub,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        body: []const u8,
    ) !DeliveryReport {
        var delivered: usize = 0;
        for (self.channels) |ch| {
            switch (ch.kind) {
                .webhook => |target| {
                    var req = HttpClient.HttpRequest.init(allocator, "POST", target.url);
                    defer req.deinit();
                    try req.setBody(body);
                    try req.setHeader("Content-Type", "application/json");
                    var resp = try self.http.request(req);
                    defer resp.deinit();
                    if (!resp.isSuccess()) return error.WebhookRejected;
                    delivered += 1;
                },
                .sink => |sink| {
                    try sink.call(sink.userdata, allocator, ctx, ch.name, body);
                    delivered += 1;
                },
            }
        }

        // No channel configured/matched → durable outbox fallback.
        if (self.channels.len == 0) {
            if (self.outbox) |ob| {
                const insert = try ob.buildInsert(self.outbox_topic, body);
                _ = try self.backend.exec(insert.sql, &.{
                    .{ .string = insert.params.topic },
                    .{ .string = insert.params.payload },
                    .{ .int = @intCast(insert.params.max_retries) },
                    .{ .int = insert.params.created_at },
                    .{ .int = insert.params.updated_at },
                });
                delivered += 1;
            }
        }

        return .{ .delivered = delivered, .channels = @max(self.channels.len, 1) };
    }
};

/// Capability bundle for the `notification.send` skill bridge.
pub const NotificationCtx = struct {
    hub: *NotificationHub,
    /// Channels the LLM may address by name (subset of `hub.channels`).
    allowed: []const []const u8 = &.{},
};

/// Register `notification.send` — an Agent sends a notification to a named
/// channel; channel targets remain app-registered.
pub fn registerNotifySkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "notification.send",
        .description = "Send a notification (title + body) to a named channel; returns delivered/sent counts",
        .parameters = &.{
            .{ .name = "channel", .type = .string, .description = "Channel name", .required = true },
            .{ .name = "title", .type = .string, .description = "Notification title", .required = true },
            .{ .name = "body", .type = .string, .description = "Notification body", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const nc: *NotificationCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.NotifyNotConfigured));
                const obj = args.object;
                const ch_v = obj.get("channel") orelse return error.InvalidArguments;
                const title_v = obj.get("title") orelse return error.InvalidArguments;
                const body_v = obj.get("body") orelse return error.InvalidArguments;
                if (ch_v != .string or title_v != .string or body_v != .string) return error.InvalidArguments;

                var allowed = nc.allowed.len == 0;
                for (nc.allowed) |a| {
                    if (std.mem.eql(u8, a, ch_v.string)) allowed = true;
                }
                if (!allowed) return error.ChannelNotAllowed;

                // Find the named channel; deliver to it only.
                const named = blk: {
                    var list = std.ArrayList(NotificationChannel).empty;
                    defer list.deinit(sctx.allocator);
                    for (nc.hub.channels) |c| {
                        if (std.mem.eql(u8, c.name, ch_v.string)) try list.append(sctx.allocator, c);
                    }
                    break :blk list.items;
                };

                const payload = try std.fmt.allocPrint(
                    sctx.allocator,
                    "{{\"channel\":\"{s}\",\"title\":\"{s}\",\"body\":\"{s}\"}}",
                    .{ ch_v.string, title_v.string, body_v.string },
                );
                defer sctx.allocator.free(payload);

                const saved_channels = nc.hub.channels;
                nc.hub.channels = named;
                defer nc.hub.channels = saved_channels;
                const report = try nc.hub.deliver(sctx.allocator, sctx, payload);

                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "delivered", .{ .integer = @intCast(report.delivered) });
                try putOwned(&out, sctx.allocator, "channels", .{ .integer = @intCast(report.channels) });
                return .{ .object = out };
            }
        }.h,
    });
}

/// ObjectMap does not copy keys and deinit does not free them; results must
/// own every key so `freeValue` can release them.
fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

const SinkState = struct {
    seen: *std.ArrayList(u8),
    fn sink(s: *anyopaque, a: std.mem.Allocator, _: *SkillContext, _: []const u8, body: []const u8) anyerror!void {
        const st: *SinkState = @ptrCast(@alignCast(s));
        try st.seen.appendSlice(a, body);
    }
};

test "NotificationHub delivers to sink and outbox fallback" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });
    var http = HttpClient.init(allocator, std.testing.io, 1, 1000);
    defer http.deinit();

    var seen = std.ArrayList(u8).empty;
    defer seen.deinit(allocator);
    var sink_state = SinkState{ .seen = &seen };

    const channels = [_]NotificationChannel{
        .{ .name = "ops", .kind = .{ .sink = .{ .userdata = &sink_state, .call = SinkState.sink } } },
    };

    var hub = NotificationHub.init(allocator, &backend, &http);
    hub.channels = &channels;
    hub.outbox = &outbox;
    var ctx = SkillContext{ .allocator = allocator };
    const report = try hub.deliver(allocator, &ctx, "{\"level\":\"warn\"}");
    try std.testing.expectEqual(@as(usize, 1), report.delivered);
    try std.testing.expect(report.all());
    try std.testing.expectEqualStrings("{\"level\":\"warn\"}", seen.items);
}

test "NotificationHub webhook posts to loopback server" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    const ServerCtx = struct {
        server: *std.Io.net.Server,
        buf: *[512]u8,
        len: *usize,
        mu: *std.Io.Mutex,
        fn run(ctx: *@This()) void {
            const accepted = ctx.server.accept(std.testing.io) catch return;
            defer accepted.close(std.testing.io);
            var total: usize = 0;
            var seen: [4096]u8 = undefined;
            while (total < seen.len) {
                var fds = [_]std.posix.pollfd{.{ .fd = accepted.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&fds, 3000) catch break;
                if (fds[0].revents == 0) break;
                const n = std.posix.read(accepted.socket.handle, seen[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, seen[0..total], "\r\n\r\n") != null) break;
            }
            ctx.mu.lock(std.testing.io) catch return;
            defer ctx.mu.unlock(std.testing.io);
            const n = @min(total, ctx.buf.len);
            @memcpy(ctx.buf[0..n], seen[0..n]);
            ctx.len.* = n;
            const resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
            _ = std.posix.system.write(accepted.socket.handle, resp.ptr, resp.len);
        }
    };

    var body_buf: [512]u8 = undefined;
    var body_len: usize = 0;
    var mu: std.Io.Mutex = .init;
    var server_ctx = ServerCtx{ .server = &server, .buf = &body_buf, .len = &body_len, .mu = &mu };
    const th = try std.Thread.spawn(.{}, ServerCtx.run, .{&server_ctx});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hook", .{port});

    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var http = HttpClient.init(allocator, std.testing.io, 1, 3000);
    defer http.deinit();

    const channels = [_]NotificationChannel{
        .{ .name = "web", .kind = .{ .webhook = .{ .url = url } } },
    };
    var hub = NotificationHub.init(allocator, &backend, &http);
    hub.channels = &channels;
    var ctx = SkillContext{ .allocator = allocator };
    const report = try hub.deliver(allocator, &ctx, "{\"ping\":1}");
    try std.testing.expectEqual(@as(usize, 1), report.delivered);
    try std.testing.expect(std.mem.indexOf(u8, body_buf[0..body_len], "{\"ping\":1}") != null);
}
