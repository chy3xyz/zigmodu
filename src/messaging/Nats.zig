//! NATS message queue client (default: localhost:4222).
//!
//! Implements the NATS protocol over TCP:
//!   CONNECT, PUB, SUB, UNSUB, MSG, PING/PONG, +OK/-ERR.
//! Supports publish, subscribe with callback, request-reply, and queue groups.

const std = @import("std");
const builtin = @import("builtin");
const Time = @import("../core/Time.zig");

pub const NatsConfig = struct {
    url: []const u8 = "localhost",
    port: u16 = 4222,
    token: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    name: []const u8 = "zigmodu-nats",
    ping_interval_ms: u64 = 30_000,
    max_reconnect_attempts: usize = 10,
};

pub const NatsClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    config: NatsConfig,
    stream: ?std.Io.net.Stream = null,
    sid_counter: u64 = 0,
    subscriptions: std.StringHashMap(Subscription),
    reconnect_attempts: usize = 0,

    pub const Subscription = struct {
        sid: u64,
        subject: []const u8,
        queue_group: ?[]const u8 = null,
        callback: *const fn (Message) void,
    };

    pub const Message = struct {
        subject: []const u8,
        reply_to: ?[]const u8 = null,
        payload: []const u8,
        sid: u64,
    };

    /// Info returned by NATS server on connect (parsed from INFO JSON).
    pub const ServerInfo = struct {
        server_id: []const u8 = "",
        server_name: []const u8 = "",
        version: []const u8 = "",
        host: []const u8 = "",
        port: u16 = 0,
        max_payload: usize = 1024 * 1024,
        raw_json: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: NatsConfig) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .subscriptions = std.StringHashMap(Subscription).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Unsubscribe all active subscriptions first
        {
            var it = self.subscriptions.iterator();
            while (it.next()) |entry| {
                self.unsubscribeRaw(entry.value_ptr.sid) catch {};
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.subject);
                if (entry.value_ptr.queue_group) |qg| self.allocator.free(qg);
            }
        }
        self.subscriptions.deinit();

        if (self.stream) |*s| {
            s.close(self.io);
            self.stream = null;
        }
        self.* = undefined;
    }

    /// Establish TCP connection, parse server INFO, and send CONNECT frame.
    /// Returns server info parsed from the INFO line.
    pub fn connect(self: *Self) !ServerInfo {
        const addr = try std.Io.net.IpAddress.parseIp4(self.config.url, self.config.port);
        const stream = try addr.connect(self.io, .{ .mode = .stream });
        errdefer stream.close(self.io);

        // ── Read server INFO ──
        // NATS sends an INFO JSON line on each new connection:
        //   INFO {"server_id":"...","version":"...",...}\r\n
        var info_line = std.ArrayList(u8).empty;
        defer info_line.deinit(self.allocator);

        // Read bytes until newline
        while (true) {
            var byte_buf: [1]u8 = undefined;
            _ = stream.read(self.io, data: { var d: [1][]u8 = .{&byte_buf}; break :data &d; }) catch return error.ConnectionError;
            if (byte_buf[0] == '\n') break;
            try info_line.append(self.allocator, byte_buf[0]);
        }

        // Strip trailing \r if present
        const raw: []const u8 = if (info_line.items.len > 0 and info_line.items[info_line.items.len - 1] == '\r')
            info_line.items[0 .. info_line.items.len - 1]
        else
            info_line.items;

        // Parse "INFO " prefix
        const info_body: []const u8 = if (std.mem.startsWith(u8, raw, "INFO "))
            raw[5..]
        else
            raw;

        var server_info = ServerInfo{ .raw_json = info_body };
        server_info.server_id = extractJsonString(info_body, "server_id") orelse "";
        server_info.server_name = extractJsonString(info_body, "server_name") orelse "";
        server_info.version = extractJsonString(info_body, "version") orelse "";
        server_info.host = extractJsonString(info_body, "host") orelse "";
        server_info.port = extractJsonU16(info_body, "port") orelse 4222;
        server_info.max_payload = extractJsonUsize(info_body, "max_payload") orelse 1024 * 1024;

        // ── Send CONNECT ──
        var connect_json = std.ArrayList(u8).empty;
        defer connect_json.deinit(self.allocator);

        // Build JSON using allocPrint + appendSlice (Zig 0.17 no writer() on ArrayList)
        const open = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\"", .{self.config.name});
        defer self.allocator.free(open);
        try connect_json.appendSlice(self.allocator, open);

        const fixed = try std.fmt.allocPrint(self.allocator, ",\"verbose\":false,\"pedantic\":false,\"lang\":\"zig\",\"version\":\"0.9\"", .{});
        defer self.allocator.free(fixed);
        try connect_json.appendSlice(self.allocator, fixed);

        if (self.config.username) |u| {
            const user_part = try std.fmt.allocPrint(self.allocator, ",\"user\":\"{s}\"", .{u});
            defer self.allocator.free(user_part);
            try connect_json.appendSlice(self.allocator, user_part);
        }
        if (self.config.password) |p| {
            const pass_part = try std.fmt.allocPrint(self.allocator, ",\"pass\":\"{s}\"", .{p});
            defer self.allocator.free(pass_part);
            try connect_json.appendSlice(self.allocator, pass_part);
        }
        if (self.config.token) |t| {
            const token_part = try std.fmt.allocPrint(self.allocator, ",\"auth_token\":\"{s}\"", .{t});
            defer self.allocator.free(token_part);
            try connect_json.appendSlice(self.allocator, token_part);
        }
        try connect_json.append(self.allocator, '}');

        var wbuf: [4096]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.writeAll("CONNECT ");
        try w.interface.writeAll(connect_json.items);
        try w.interface.writeAll("\r\n");
        try w.interface.flush();

        self.stream = stream;
        return server_info;
    }

    /// Publish a message to a subject.
    pub fn publish(self: *Self, subject: []const u8, payload: []const u8) !void {
        try self.publishReply(subject, null, payload);
    }

    /// Publish with optional reply subject (for request-reply).
    pub fn publishReply(self: *Self, subject: []const u8, reply_to: ?[]const u8, payload: []const u8) !void {
        const s = self.stream orelse return error.NotConnected;
        var wbuf: [4096]u8 = undefined;
        var w = s.writer(self.io, &wbuf);

        // PUB <subject> [reply-to] <#bytes>\r\n<payload>\r\n
        try w.interface.writeAll("PUB ");
        try w.interface.writeAll(subject);
        try w.interface.writeAll(" ");
        if (reply_to) |rt| {
            try w.interface.writeAll(rt);
            try w.interface.writeAll(" ");
        }
        var size_buf: [32]u8 = undefined;
        const size_str = try std.fmt.bufPrint(&size_buf, "{d}", .{payload.len});
        try w.interface.writeAll(size_str);
        try w.interface.writeAll("\r\n");
        try w.interface.writeAll(payload);
        try w.interface.writeAll("\r\n");
        try w.interface.flush();
    }

    /// Subscribe to a subject with callback. Returns subscription ID (sid).
    pub fn subscribe(self: *Self, subject: []const u8, callback: *const fn (Message) void) !u64 {
        return try self.subscribeGroup(subject, null, callback);
    }

    /// Subscribe with queue group for load-balanced delivery.
    pub fn subscribeGroup(self: *Self, subject: []const u8, queue_group: ?[]const u8, callback: *const fn (Message) void) !u64 {
        const s = self.stream orelse return error.NotConnected;

        self.sid_counter += 1;
        const sid = self.sid_counter;

        var wbuf: [4096]u8 = undefined;
        var w = s.writer(self.io, &wbuf);

        // SUB <subject> [queue group] <sid>\r\n
        try w.interface.writeAll("SUB ");
        try w.interface.writeAll(subject);
        if (queue_group) |qg| {
            try w.interface.writeAll(" ");
            try w.interface.writeAll(qg);
        }
        var sid_buf: [32]u8 = undefined;
        const sid_str = try std.fmt.bufPrint(&sid_buf, " {d}\r\n", .{sid});
        try w.interface.writeAll(sid_str);
        try w.interface.flush();

        const key = try std.fmt.allocPrint(self.allocator, "{d}", .{sid});
        errdefer self.allocator.free(key);
        try self.subscriptions.put(key, .{
            .sid = sid,
            .subject = try self.allocator.dupe(u8, subject),
            .queue_group = if (queue_group) |qg| try self.allocator.dupe(u8, qg) else null,
            .callback = callback,
        });
        return sid;
    }

    /// Unsubscribe from a subscription by its sid.
    pub fn unsubscribe(self: *Self, sid: u64) !void {
        // Send UNSUB command
        self.unsubscribeRaw(sid) catch {};

        // Remove from local subscription map
        const key = try std.fmt.allocPrint(self.allocator, "{d}", .{sid});
        defer self.allocator.free(key);
        if (self.subscriptions.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.subject);
            if (kv.value.queue_group) |qg| self.allocator.free(qg);
        }
    }

    /// Send UNSUB command on the wire without touching the subscription map.
    fn unsubscribeRaw(self: *Self, sid: u64) !void {
        const s = self.stream orelse return error.NotConnected;
        var wbuf: [64]u8 = undefined;
        var w = s.writer(self.io, &wbuf);
        var sid_buf: [32]u8 = undefined;
        const sid_str = try std.fmt.bufPrint(&sid_buf, "UNSUB {d}\r\n", .{sid});
        try w.interface.writeAll(sid_str);
        try w.interface.flush();
    }

    /// Request-reply pattern. Publishes to subject with auto-generated
    /// reply inbox and waits up to timeout_ms for a single response.
    /// Returns the response payload on success (caller owns). Returns error.Timeout.
    pub fn request(self: *Self, subject: []const u8, payload: []const u8, timeout_ms: u64) ![]const u8 {
        const s = self.stream orelse return error.NotConnected;

        // Generate unique inbox subject
        var inbox_buf: [64]u8 = undefined;
        const inbox = try std.fmt.bufPrint(&inbox_buf, "_INBOX.zm{d}", .{Time.monotonicNowMilliseconds()});

        // Send SUB for the inbox
        self.sid_counter += 1;
        const req_sid = self.sid_counter;
        {
            var wbuf: [256]u8 = undefined;
            var w = s.writer(self.io, &wbuf);
            var sub_buf: [64]u8 = undefined;
            const sub_str = try std.fmt.bufPrint(&sub_buf, "SUB {s} {d}\r\n", .{ inbox, req_sid });
            try w.interface.writeAll(sub_str);
            try w.interface.flush();
        }

        // Send PUB with reply-to = inbox
        try self.publishReply(subject, inbox, payload);

        // Poll for response until timeout
        const deadline = Time.monotonicNowMilliseconds() + @as(i64, @intCast(timeout_ms));
        var rbuf: [8192]u8 = undefined;

        while (true) {
            const now = Time.monotonicNowMilliseconds();
            if (now >= deadline) {
                self.unsubscribeRaw(req_sid) catch {};
                return error.Timeout;
            }

            // Non-blocking read
            const n = s.read(self.io, data: { var d: [1][]u8 = .{&rbuf}; break :data &d; }) catch |err| {
                self.unsubscribeRaw(req_sid) catch {};
                return err;
            };
            if (n == 0) {
                var i: usize = 0;
                while (i < 50000) : (i += 1) {
                    _ = Time.monotonicNowMilliseconds();
                }
                continue;
            }

            // Parse for MSG lines matching our inbox subscription
            if (try self.parseRequestResponse(rbuf[0..n], req_sid)) |resp| {
                self.unsubscribeRaw(req_sid) catch {};
                return resp;
            }
        }
    }

    /// Parse a single MSG response for request-reply, returning payload if found.
    fn parseRequestResponse(self: *Self, data: []const u8, target_sid: u64) !?[]const u8 {
        var pos: usize = 0;

        while (pos < data.len) {
            const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse return null;
            var line = data[pos..line_end];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            pos = line_end + 1;

            if (line.len == 0) continue;
            if (std.mem.eql(u8, line, "+OK") or std.mem.eql(u8, line, "PONG")) continue;
            if (std.mem.startsWith(u8, line, "-ERR")) continue;

            if (std.mem.startsWith(u8, line, "MSG ")) {
                // MSG <subject> <sid> [reply-to] <#bytes>\r\n<payload>\r\n
                var parts = std.mem.splitScalar(u8, line[4..], ' ');
                _ = parts.next(); // subject
                const sid_str = parts.next() orelse continue;
                const line_sid = std.fmt.parseInt(u64, sid_str, 10) catch continue;

                if (line_sid != target_sid) continue;

                // Parse payload size (3rd or 4th token)
                const third = parts.next() orelse continue;
                const payload_len = std.fmt.parseInt(usize, third, 10) catch blk: {
                    const fourth = parts.next() orelse continue;
                    const len = std.fmt.parseInt(usize, fourth, 10) catch continue;
                    break :blk len;
                };

                if (pos + payload_len + 2 > data.len) return null;
                const payload = data[pos .. pos + payload_len];
                // pos += payload_len + 2 handled by caller if needed

                const result = try self.allocator.dupe(u8, payload);
                return result;
            }
        }
        return null;
    }

    /// Flush ensures all published messages have been processed by the server.
    /// Sends PING and waits for PONG.
    pub fn flush(self: *Self) !void {
        try self.ping();
    }

    /// Poll for messages (non-blocking). Dispatches matching callbacks.
    /// Returns number of messages processed.
    pub fn poll(self: *Self) !usize {
        const s = self.stream orelse return error.NotConnected;
        var buf: [8192]u8 = undefined;
        const n = s.read(self.io, data: { var d: [1][]u8 = .{&buf}; break :data &d; }) catch |err| return err;
        if (n == 0) return 0;

        return try self.parseMessages(buf[0..n]);
    }

    /// Send PING and expect PONG.
    pub fn ping(self: *Self) !void {
        const s = self.stream orelse return error.NotConnected;
        var wbuf: [64]u8 = undefined;
        var w = s.writer(self.io, &wbuf);
        try w.interface.writeAll("PING\r\n");
        try w.interface.flush();

        var rbuf: [128]u8 = undefined;
        const n = s.read(self.io, data: { var d: [1][]u8 = .{&rbuf}; break :data &d; }) catch return error.ConnectionError;
        if (n < 6 or !std.mem.eql(u8, rbuf[0..6], "PONG\r\n")) return error.ProtocolError;
    }

    // ── Internal: parse incoming NATS messages and dispatch to callbacks ──

    fn parseMessages(self: *Self, data: []const u8) !usize {
        var count: usize = 0;
        var pos: usize = 0;

        while (pos < data.len) {
            const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse break;
            const line = data[pos..line_end];
            const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
            pos = line_end + 1;

            if (trimmed.len == 0) continue;

            if (std.mem.eql(u8, trimmed, "PING")) {
                const s = self.stream orelse return error.NotConnected;
                var wbuf: [64]u8 = undefined;
                var w = s.writer(self.io, &wbuf);
                try w.interface.writeAll("PONG\r\n");
                try w.interface.flush();
                continue;
            }

            if (std.mem.eql(u8, trimmed, "PONG")) {
                continue;
            }

            if (std.mem.eql(u8, trimmed, "+OK")) {
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "-ERR")) {
                std.log.warn("[NATS] Server error: {s}", .{trimmed});
                continue;
            }

            // MSG <subject> <sid> [reply-to] <#bytes>\r\n<payload>\r\n
            if (std.mem.startsWith(u8, trimmed, "MSG ")) {
                var parts = std.mem.splitScalar(u8, trimmed[4..], ' ');
                const subj = parts.next() orelse continue;
                const sid_str = parts.next() orelse continue;
                const sid = std.fmt.parseInt(u64, sid_str, 10) catch continue;

                var reply_to: ?[]const u8 = null;
                var maybe_bytes = parts.next() orelse continue;

                const payload_len = std.fmt.parseInt(usize, maybe_bytes, 10) catch blk: {
                    reply_to = maybe_bytes;
                    maybe_bytes = parts.next() orelse continue;
                    const len = std.fmt.parseInt(usize, maybe_bytes, 10) catch continue;
                    break :blk len;
                };

                if (pos + payload_len + 2 > data.len) break;
                const payload = data[pos .. pos + payload_len];
                pos += payload_len + 2;

                const sid_key = try std.fmt.allocPrint(self.allocator, "{d}", .{sid});
                defer self.allocator.free(sid_key);
                if (self.subscriptions.get(sid_key)) |sub| {
                    sub.callback(.{
                        .subject = subj,
                        .reply_to = reply_to,
                        .payload = payload,
                        .sid = sid,
                    });
                    count += 1;
                }
            }
        }
        return count;
    }

    // ── Minimal JSON value extractors ──

    fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
        // Search for "key":"value"
        var search_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
        const start_idx = std.mem.indexOf(u8, json, needle) orelse return null;
        const val_start = start_idx + needle.len;
        const val_end = std.mem.indexOfScalarPos(u8, json, val_start, '"') orelse return null;
        return json[val_start..val_end];
    }

    fn extractJsonU16(json: []const u8, key: []const u8) ?u16 {
        // Try string value first: "key":"4222"
        if (extractJsonString(json, key)) |s| {
            return std.fmt.parseInt(u16, s, 10) catch null;
        }
        // Try numeric value: "key":4222
        var search_buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
        const start_idx = std.mem.indexOf(u8, json, needle) orelse return null;
        const val_start = start_idx + needle.len;
        const val_end = std.mem.indexOfScalarPos(u8, json, val_start, ',') orelse
            std.mem.indexOfScalarPos(u8, json, val_start, '}') orelse json.len;
        const num_str = std.mem.trim(u8, json[val_start..val_end], " \t");
        return std.fmt.parseInt(u16, num_str, 10) catch null;
    }

    fn extractJsonUsize(json: []const u8, key: []const u8) ?usize {
        var search_buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
        const start_idx = std.mem.indexOf(u8, json, needle) orelse return null;
        const val_start = start_idx + needle.len;
        const val_end = std.mem.indexOfScalarPos(u8, json, val_start, ',') orelse
            std.mem.indexOfScalarPos(u8, json, val_start, '}') orelse json.len;
        const num_str = std.mem.trim(u8, json[val_start..val_end], " \t");
        return std.fmt.parseInt(usize, num_str, 10) catch null;
    }
};

// ── Tests ──

test "NatsClient init and deinit" {
    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, .{});
    defer client.deinit();
}

test "NatsConfig defaults" {
    const cfg = NatsConfig{};
    try std.testing.expectEqualStrings("localhost", cfg.url);
    try std.testing.expectEqual(@as(u16, 4222), cfg.port);
    try std.testing.expectEqual(@as(usize, 10), cfg.max_reconnect_attempts);
}

test "NATS connect and ping" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const nats_url = if (std.c.getenv("NATS_URL")) |ptr| std.mem.span(ptr) else null;
    if (nats_url == null or nats_url.?.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, .{});
    defer client.deinit();

    const info = try client.connect();
    try std.testing.expect(info.server_id.len > 0);
    try std.testing.expect(info.version.len > 0);

    // Ping/PONG heartbeat
    try client.ping();
    try client.ping();
}

test "NATS publish and subscribe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const nats_url = if (std.c.getenv("NATS_URL")) |ptr| std.mem.span(ptr) else null;
    if (nats_url == null or nats_url.?.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, .{});
    defer client.deinit();

    _ = try client.connect();

    // Subscribe to test subject
    const sid = try client.subscribe("zigmodu.test.pubsub", struct {
        fn handler(msg: NatsClient.Message) void {
            _ = msg;
        }
    }.handler);
    defer client.unsubscribe(sid) catch {};

    try client.publish("zigmodu.test.pubsub", "hello-nats");
    try client.flush();

    // Poll to receive the message
    _ = try client.poll();
}

test "NATS request-reply" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const nats_url = if (std.c.getenv("NATS_URL")) |ptr| std.mem.span(ptr) else null;
    if (nats_url == null or nats_url.?.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, .{});
    defer client.deinit();

    _ = try client.connect();

    // Subscribe to respond to requests
    const sid = try client.subscribe("zigmodu.test.request", struct {
        fn handler(msg: NatsClient.Message) void {
            _ = msg;
        }
    }.handler);
    defer client.unsubscribe(sid) catch {};

    // Send a request — will timeout (no responder), but validates protocol
    _ = client.request("zigmodu.test.request", "ping", 1000) catch |err| {
        try std.testing.expectEqual(error.Timeout, err);
        return;
    };
}
