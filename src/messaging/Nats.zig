//! NATS message queue client (default: localhost:4222).
//!
//! Implements the NATS protocol over TCP: CONNECT, PUB, SUB, MSG, PING/PONG.
//! Supports publish, subscribe with callback, request-reply, and queue groups.

const std = @import("std");
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: NatsConfig) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .subscriptions = std.StringHashMap(Subscription).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.stream) |*s| {
            s.close(self.io);
            self.stream = null;
        }
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.queue_group) |qg| self.allocator.free(qg);
            self.allocator.free(entry.value_ptr.subject);
        }
        self.subscriptions.deinit();
    }

    /// Establish TCP connection and send CONNECT frame.
    pub fn connect(self: *Self) !void {
        const addr = try std.Io.net.IpAddress.parseIp4(self.config.url, self.config.port);
        const stream = try addr.connect(self.io);

        // Build CONNECT JSON
        var connect_json = std.ArrayList(u8).empty;
        defer connect_json.deinit(self.allocator);

        const w = connect_json.writer(self.allocator);
        try w.writeAll("{");
        try w.print("\"name\":\"{s}\"", .{self.config.name});
        try w.print(",\"verbose\":false,\"pedantic\":false,\"lang\":\"zig\",\"version\":\"0.9\"", .{});
        if (self.config.username) |u| try w.print(",\"user\":\"{s}\"", .{u});
        if (self.config.password) |p| try w.print(",\"pass\":\"{s}\"", .{p});
        if (self.config.token) |t| try w.print(",\"auth_token\":\"{s}\"", .{t});
        try w.writeAll("}");

        try self.writeFrame("CONNECT", connect_json.items);
        self.stream = stream;
    }

    /// Publish a message to a subject.
    pub fn publish(self: *Self, subject: []const u8, payload: []const u8) !void {
        try self.publishReply(subject, null, payload);
    }

    /// Publish with optional reply subject (for request-reply).
    pub fn publishReply(self: *Self, subject: []const u8, reply_to: ?[]const u8, payload: []const u8) !void {
        const s = self.stream orelse return error.NotConnected;
        var write_buf: [4096]u8 = undefined;
        var w = s.writer(self.io, &write_buf);

        // PUB <subject> [reply-to] <#bytes>\r\n<payload>\r\n
        if (reply_to) |rt| {
            try w.interface.writeAll("PUB ");
            try w.interface.writeAll(subject);
            try w.interface.writeAll(" ");
            try w.interface.writeAll(rt);
            try w.interface.writeAll(" ");
            var size_buf: [32]u8 = undefined;
            const size_str = try std.fmt.bufPrint(&size_buf, "{d}", .{payload.len});
            try w.interface.writeAll(size_str);
            try w.interface.writeAll("\r\n");
        } else {
            try w.interface.writeAll("PUB ");
            try w.interface.writeAll(subject);
            try w.interface.writeAll(" ");
            var size_buf: [32]u8 = undefined;
            const size_str = try std.fmt.bufPrint(&size_buf, "{d}", .{payload.len});
            try w.interface.writeAll(size_str);
            try w.interface.writeAll("\r\n");
        }
        try w.interface.writeAll(payload);
        try w.interface.writeAll("\r\n");
        try w.interface.flush();
    }

    /// Subscribe to a subject with callback. Returns subscription ID.
    pub fn subscribe(self: *Self, subject: []const u8, callback: *const fn (Message) void) !u64 {
        return try self.subscribeGroup(subject, null, callback);
    }

    /// Subscribe with queue group for load-balanced delivery.
    pub fn subscribeGroup(self: *Self, subject: []const u8, queue_group: ?[]const u8, callback: *const fn (Message) void) !u64 {
        const s = self.stream orelse return error.NotConnected;

        self.sid_counter += 1;
        const sid = self.sid_counter;

        var write_buf: [4096]u8 = undefined;
        var w = s.writer(self.io, &write_buf);

        // SUB <subject> [queue group] <sid>\r\n
        if (queue_group) |qg| {
            try w.interface.writeAll("SUB ");
            try w.interface.writeAll(subject);
            try w.interface.writeAll(" ");
            try w.interface.writeAll(qg);
            var sid_buf: [32]u8 = undefined;
            const sid_str = try std.fmt.bufPrint(&sid_buf, " {d}\r\n", .{sid});
            try w.interface.writeAll(sid_str);
        } else {
            try w.interface.writeAll("SUB ");
            try w.interface.writeAll(subject);
            var sid_buf: [32]u8 = undefined;
            const sid_str = try std.fmt.bufPrint(&sid_buf, " {d}\r\n", .{sid});
            try w.interface.writeAll(sid_str);
        }
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

    /// Poll for messages (non-blocking). Dispatches matching callbacks.
    /// Returns number of messages processed.
    pub fn poll(self: *Self) !usize {
        const s = self.stream orelse return error.NotConnected;
        var buf: [8192]u8 = undefined;
        const n = s.read(self.io, &buf) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
        if (n == 0) return 0;

        return try self.parseMessages(buf[0..n]);
    }

    /// Send PING and expect PONG.
    pub fn ping(self: *Self) !void {
        const s = self.stream orelse return error.NotConnected;
        var write_buf: [64]u8 = undefined;
        var w = s.writer(self.io, &write_buf);
        try w.interface.writeAll("PING\r\n");
        try w.interface.flush();

        var read_buf: [128]u8 = undefined;
        const n = s.read(self.io, &read_buf) catch return error.DatabaseError;
        if (n < 6 or !std.mem.eql(u8, read_buf[0..6], "PONG\r\n")) return error.DatabaseError;
    }

    /// Internal: write a NATS protocol frame.
    fn writeFrame(self: *Self, cmd: []const u8, payload: []const u8) !void {
        const s = self.stream orelse return error.NotConnected;
        var write_buf: [4096]u8 = undefined;
        var w = s.writer(self.io, &write_buf);
        try w.interface.writeAll(cmd);
        try w.interface.writeAll(" ");
        var size_buf: [32]u8 = undefined;
        const size_str = try std.fmt.bufPrint(&size_buf, "{d}", .{payload.len});
        try w.interface.writeAll(size_str);
        try w.interface.writeAll("\r\n");
        try w.interface.writeAll(payload);
        try w.interface.writeAll("\r\n");
        try w.interface.flush();
    }

    /// Internal: parse incoming NATS messages and dispatch to callbacks.
    fn parseMessages(self: *Self, data: []const u8) !usize {
        var count: usize = 0;
        var pos: usize = 0;

        while (pos < data.len) {
            const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse break;
            const line = data[pos..line_end];
            // Trim trailing \r
            const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
            pos = line_end + 1;

            if (trimmed.len == 0) continue;

            if (std.mem.eql(u8, trimmed, "PING")) {
                const s = self.stream orelse return error.NotConnected;
                var write_buf: [64]u8 = undefined;
                var w = s.writer(self.io, &write_buf);
                try w.interface.writeAll("PONG\r\n");
                try w.interface.flush();
                continue;
            }

            if (std.mem.eql(u8, trimmed, "PONG")) {
                // No action needed
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
                _ = std.fmt.parseInt(usize, maybe_bytes, 10) catch {
                    reply_to = maybe_bytes;
                    maybe_bytes = parts.next() orelse continue;
                };
                const payload_len = std.fmt.parseInt(usize, maybe_bytes, 10) catch continue;

                if (pos + payload_len + 2 > data.len) break; // Need more data
                const payload = data[pos .. pos + payload_len];
                pos += payload_len + 2; // Skip payload + \r\n

                // Dispatch to subscription
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
