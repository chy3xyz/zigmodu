//! Notification hub ("通知分发"): deliver a message to named channels —
//! webhooks (via `HttpClient`), custom sinks (email/IM/in-app via a callback),
//! or a durable transactional-outbox fallback. Reporter / alerts / recon /
//! approval outputs can be routed here, and the `notification.send` skill
//! bridge lets an Agent dispatch app-registered notifications (channels and
//! targets stay app-owned; the LLM only supplies recipient/title/body).

const std = @import("std");
const SqlxBackend = @import("../data.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const SkillRegistry = @import("skill.zig").SkillRegistry;
const skill = @import("skill.zig");
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
        .action = .propose,
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
                //
                // The filtered list is declared *outside* the block on purpose: with
                // it inside, the `defer` freed the buffer at block exit while the
                // slice it returned was then walked by `deliver` — a use-after-free
                // on the ordinary path (the agent names a channel, the filter
                // matches, so the list is not empty).
                var named = std.ArrayList(NotificationChannel).empty;
                defer named.deinit(sctx.allocator);
                for (nc.hub.channels) |c| {
                    if (std.mem.eql(u8, c.name, ch_v.string)) try named.append(sctx.allocator, c);
                }

                const payload = try skill.encodeJsonObject(sctx.allocator, &.{
                    .{ .key = "channel", .value = .{ .string = ch_v.string } },
                    .{ .key = "title", .value = .{ .string = title_v.string } },
                    .{ .key = "body", .value = .{ .string = body_v.string } },
                });
                defer sctx.allocator.free(payload);

                const saved_channels = nc.hub.channels;
                nc.hub.channels = named.items;
                defer nc.hub.channels = saved_channels;
                const report = try nc.hub.deliver(sctx.allocator, sctx, payload);

                var out = std.json.ObjectMap{};
                // The tree is the caller's on success and freed here on
                // failure — a second field's failure used to strand the first
                // field's key.
                errdefer skill.freeValue(sctx.allocator, .{ .object = out });
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
    // The key copy needs its own guard: built as the `put` argument it was
    // stranded whenever the map refused the field. The disarmed-by-`return`
    // guard leaves the value's contract alone — a `.string` here is still
    // owned by the caller.
    const k = try allocator.dupe(u8, key);
    errdefer allocator.free(k);
    try obj.put(allocator, k, value);
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
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
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

    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
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

test "notification.send payload escapes quotes and backslashes in the message text" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var http = HttpClient.init(allocator, std.testing.io, 1, 1000);
    defer http.deinit();

    // The sink records exactly the bytes the hub was handed, so parsing that
    // back is the same check a downstream webhook consumer would do.
    var seen = std.ArrayList(u8).empty;
    defer seen.deinit(allocator);
    var sink_state = SinkState{ .seen = &seen };
    const channels = [_]NotificationChannel{
        .{ .name = "ops", .kind = .{ .sink = .{ .userdata = &sink_state, .call = SinkState.sink } } },
    };
    var hub = NotificationHub.init(allocator, &backend, &http);
    hub.channels = &channels;
    var nc = NotificationCtx{ .hub = &hub };

    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerNotifySkills(&registry);

    const title = "disk \"full\" on /var";
    const body = "line1\nline2 with a \\ backslash";
    var args_map = std.json.ObjectMap{};
    try putOwned(&args_map, allocator, "channel", .{ .string = try allocator.dupe(u8, "ops") });
    try putOwned(&args_map, allocator, "title", .{ .string = try allocator.dupe(u8, title) });
    try putOwned(&args_map, allocator, "body", .{ .string = try allocator.dupe(u8, body) });

    var sctx = SkillContext{ .allocator = allocator, .userdata = &nc };
    const res = try registry.dispatch("notification.send", &sctx, .{ .object = args_map });
    defer skill.freeValue(allocator, res);
    defer skill.freeValue(allocator, .{ .object = args_map });

    try std.testing.expectEqual(@as(i64, 1), res.object.get("delivered").?.integer);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, seen.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ops", parsed.value.object.get("channel").?.string);
    try std.testing.expectEqualStrings(title, parsed.value.object.get("title").?.string);
    try std.testing.expectEqualStrings(body, parsed.value.object.get("body").?.string);
}

// The failing allocator is swapped into the `SkillContext`: the walk covers
// the handler's payload encoding, the channel filter list and the result map
// (the sink below allocates nothing, so the delivery itself adds no points).
// The production context allocator is the agent worker's, not an arena — this
// path must own its failure exits.
//
// Red before the fix: the result map had no guard, so a failed second put
// stranded the first field's key; and inside `putOwned` the key copy built as
// the `put` argument was stranded whenever the map refused the field.
test "notification.send hands back its report at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var http = HttpClient.init(allocator, std.testing.io, 1, 1000);
    defer http.deinit();

    const NoopSink = struct {
        var calls: usize = 0;
        fn sink(_: *anyopaque, _: std.mem.Allocator, _: *SkillContext, _: []const u8, _: []const u8) anyerror!void {
            calls += 1;
        }
    };
    var sink_ud: u8 = 0;
    const channels = [_]NotificationChannel{
        .{ .name = "ops", .kind = .{ .sink = .{ .userdata = &sink_ud, .call = NoopSink.sink } } },
    };
    var hub = NotificationHub.init(allocator, &backend, &http);
    hub.channels = &channels;
    var nc = NotificationCtx{ .hub = &hub };

    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerNotifySkills(&registry);
    var base_ctx = SkillContext{ .allocator = allocator, .userdata = &nc };

    const Scan = struct {
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, base: *SkillContext) !void {
            var sctx = base.*;
            sctx.allocator = a;
            var args = std.json.ObjectMap{};
            defer skill.freeValue(a, .{ .object = args });
            try skill.putJsonField(a, &args, "channel", .{ .string = "ops" });
            try skill.putJsonField(a, &args, "title", .{ .string = "disk full" });
            try skill.putJsonField(a, &args, "body", .{ .string = "/var at 99%" });
            const res = try reg.dispatch("notification.send", &sctx, .{ .object = args });
            defer skill.freeValue(a, res);
            try std.testing.expectEqual(@as(i64, 1), res.object.get("delivered").?.integer);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &base_ctx });
}
