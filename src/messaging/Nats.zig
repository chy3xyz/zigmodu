//! NATS message queue client (default: localhost:4222).
//!
//! Implements the NATS protocol over TCP:
//!   CONNECT, PUB, SUB, UNSUB, MSG, PING/PONG, +OK/-ERR.
//! Supports publish, subscribe with callback, request-reply, and queue groups.

const std = @import("std");
const builtin = @import("builtin");
const Time = @import("../core/Time.zig");
const netdial = @import("../core/netdial.zig");
const sockread = @import("../core/sockread.zig");

pub const NatsConfig = struct {
    /// Host of the NATS server. A **literal IPv4** (or IPv6) address: `connect`
    /// resolves it with `IpAddress.parseIp4` / `.resolve`, neither of which does
    /// DNS — a host name would have to go through `HostName.connect`. The default
    /// used to be `"localhost"`, which `parseIp4` rejects with
    /// `error.InvalidCharacter`, so the documented default could never connect.
    url: []const u8 = "127.0.0.1",
    port: u16 = 4222,
    token: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    name: []const u8 = "zmodu-nats",
    ping_interval_ms: u64 = 30_000,
    /// How long `ping` / `flush` waits for the server's `PONG` while it keeps
    /// dispatching whatever else arrives.
    ping_timeout_ms: u64 = 5_000,
    /// Bound on the TCP dial itself; `0` keeps the kernel's default (the
    /// pre-existing behaviour) — a black-holed endpoint otherwise costs that
    /// default for every `connect()` attempt.
    connect_timeout_ms: u32 = 0,
    max_reconnect_attempts: usize = 10,
};

pub const NatsClient = struct {
    const Self = @This();

    /// Upper bound for the read-side reassembly buffer (`pending`). A peer
    /// whose bytes never complete a frame — or one endless garbage stream —
    /// must not grow the buffer without limit. Past the bound the read paths
    /// fail with `error.MessageTooLarge`.
    pub const max_pending_bytes: usize = 1024 * 1024;

    /// Upper bound for the server INFO line read during `connect`. A real INFO
    /// is a few hundred bytes; without a bound a peer that never sends '\n'
    /// keeps `connect` accumulating (and blocked) forever. Past the bound the
    /// read fails with `error.ProtocolError`.
    pub const max_info_line_bytes: usize = 64 * 1024;

    allocator: std.mem.Allocator,
    io: std.Io,
    config: NatsConfig,
    stream: ?std.Io.net.Stream = null,
    sid_counter: u64 = 0,
    subscriptions: std.StringHashMap(Subscription),
    reconnect_attempts: usize = 0,
    /// Bytes read from the socket but not yet consumed as a complete protocol
    /// frame. TCP may split a frame anywhere — mid-header, mid-payload — and a
    /// frame may exceed one 8 KiB read, so the unconsumed tail stays here
    /// across `poll` / `request` / `ping` calls instead of being dropped.
    /// Bounded by `max_pending_bytes`.
    pending: std.ArrayList(u8) = .empty,
    /// Set while `drainPending` is parsing and dispatching: a subscription
    /// callback that re-enters `poll` / `request` / `ping` would append to
    /// (and reallocate) `pending` while the parser still holds slices into
    /// it. Re-entrant calls fail with `error.Reentrant` instead.
    draining: bool = false,
    /// The raw server INFO line, owned by the client. `connect` hands back a
    /// `ServerInfo` whose string fields point into this buffer — the shape
    /// this replaces freed the line before returning, so every string field
    /// of the returned struct was a dangling slice. Valid until the next
    /// `connect()` (which replaces it) or `deinit`.
    info_line: ?[]u8 = null,

    pub const Subscription = struct {
        sid: u64,
        subject: []const u8,
        queue_group: ?[]const u8 = null,
        callback: *const fn (Message) void,
    };

    pub const Message = struct {
        subject: []const u8,
        reply_to: ?[]const u8 = null,
        /// Borrows the client's reassembly buffer: valid only for the duration
        /// of the callback that receives it.
        payload: []const u8,
        sid: u64,
    };

    /// Info returned by NATS server on connect (parsed from INFO JSON).
    ///
    /// The string fields borrow the client's INFO buffer (`info_line`): they
    /// are valid until the next `connect()` on the same client or its
    /// `deinit`. The shape this replaced freed that buffer before returning,
    /// so every field was a dangling slice.
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
                self.unsubscribeRaw(entry.value_ptr.sid) catch |err| std.log.warn("[Nats] unsubscribeRaw failed during deinit: {}", .{err});
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.subject);
                if (entry.value_ptr.queue_group) |qg| self.allocator.free(qg);
            }
        }
        self.subscriptions.deinit();
        self.pending.deinit(self.allocator);

        if (self.info_line) |owned| self.allocator.free(owned);

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
        // netdial, not std: a signal inside std's blocking connect panics on
        // the EINTR retry's EISCONN (`errnoBug`) — core/netdial.zig.
        const stream = try netdial.connectTimeout(self.io, addr, self.config.connect_timeout_ms);
        errdefer stream.close(self.io);

        // ── Read server INFO ──
        // NATS sends an INFO JSON line on each new connection:
        //   INFO {"server_id":"...","version":"...",...}\r\n
        const info_line = try readInfoLine(self.allocator, stream);
        // Ownership moves to the client: the returned `ServerInfo`'s string
        // fields point into this buffer, so it lives until the next `connect`
        // or `deinit`. The `defer free` this replaces handed the caller back
        // dangling slices — every read of the returned info touched freed
        // memory.
        if (self.info_line) |old| self.allocator.free(old);
        self.info_line = info_line;
        errdefer {
            if (self.info_line) |owned| {
                self.allocator.free(owned);
                self.info_line = null;
            }
        }

        // Strip trailing \r if present
        const raw: []const u8 = if (info_line.len > 0 and info_line[info_line.len - 1] == '\r')
            info_line[0 .. info_line.len - 1]
        else
            info_line;

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
        const open = try self.allocator.print("{{\"name\":\"{s}\"", .{self.config.name});
        defer self.allocator.free(open);
        try connect_json.appendSlice(self.allocator, open);

        const fixed = try self.allocator.print(",\"verbose\":false,\"pedantic\":false,\"lang\":\"zig\",\"version\":\"0.9\"", .{});
        defer self.allocator.free(fixed);
        try connect_json.appendSlice(self.allocator, fixed);

        if (self.config.username) |u| {
            const user_part = try self.allocator.print(",\"user\":\"{s}\"", .{u});
            defer self.allocator.free(user_part);
            try connect_json.appendSlice(self.allocator, user_part);
        }
        if (self.config.password) |p| {
            const pass_part = try self.allocator.print(",\"pass\":\"{s}\"", .{p});
            defer self.allocator.free(pass_part);
            try connect_json.appendSlice(self.allocator, pass_part);
        }
        if (self.config.token) |t| {
            const token_part = try self.allocator.print(",\"auth_token\":\"{s}\"", .{t});
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

        const key = try self.allocator.print("{d}", .{sid});
        errdefer self.allocator.free(key);
        // Dupe into locals with an errdefer each (the web4/challenge.zig
        // pattern): built inline in the `put` argument list, the subject copy
        // leaked when the queue-group dupe failed, and both copies leaked when
        // `put` itself failed.
        const subject_copy = try self.allocator.dupe(u8, subject);
        errdefer self.allocator.free(subject_copy);
        const queue_copy: ?[]u8 = if (queue_group) |qg| try self.allocator.dupe(u8, qg) else null;
        errdefer if (queue_copy) |qg| self.allocator.free(qg);
        try self.subscriptions.put(key, .{
            .sid = sid,
            .subject = subject_copy,
            .queue_group = queue_copy,
            .callback = callback,
        });
        return sid;
    }

    /// Unsubscribe from a subscription by its sid.
    pub fn unsubscribe(self: *Self, sid: u64) !void {
        // Send UNSUB command
        self.unsubscribeRaw(sid) catch |err| std.log.warn("[Nats] unsubscribeRaw failed: {}", .{err});

        // Remove from local subscription map
        const key = try self.allocator.print("{d}", .{sid});
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
    /// Returns the response payload on success (caller owns). Returns
    /// error.Timeout when no reply arrives in time, error.ConnectionClosed
    /// when the peer goes away while waiting.
    pub fn request(self: *Self, subject: []const u8, payload: []const u8, timeout_ms: u64) ![]const u8 {
        const s = self.stream orelse return error.NotConnected;
        if (self.draining) return error.Reentrant;

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

        // Best-effort UNSUB on every way out — timeout, connection loss, or a
        // delivered reply.
        defer self.unsubscribeRaw(req_sid) catch |err| std.log.warn("[Nats] unsubscribeRaw failed after request: {}", .{err});

        // Poll for the response until the timeout. Bytes accumulate in
        // `pending` so a reply split across TCP segments — or larger than one
        // 8 KiB read — is still reassembled; other traffic that arrives while
        // waiting is dispatched normally instead of being dropped.
        const deadline = Time.monotonicNowMilliseconds() + @as(i64, @intCast(timeout_ms));
        var rbuf: [8192]u8 = undefined;

        while (true) {
            if (Time.monotonicNowMilliseconds() >= deadline) return error.Timeout;

            const n = try sockread.readSome(s, &rbuf);
            // 0 is the peer's EOF (core/sockread.zig): the old code spun a busy
            // loop here until the deadline and then misreported the closed
            // connection as `error.Timeout`. Same handling as `ping`.
            if (n == 0) return error.ConnectionClosed;

            try self.appendPending(rbuf[0..n]);
            const res = try self.drainPending(req_sid);
            if (res.request_payload) |resp| return resp;
        }
    }

    /// Flush ensures all published messages have been processed by the server.
    /// Sends PING and waits for PONG.
    pub fn flush(self: *Self) !void {
        try self.ping();
    }

    /// Poll for messages. Dispatches matching callbacks for every complete
    /// frame currently readable; bytes of an incomplete frame stay in
    /// `pending` for the next call. Returns number of messages dispatched.
    pub fn poll(self: *Self) !usize {
        const s = self.stream orelse return error.NotConnected;
        if (self.draining) return error.Reentrant;
        var buf: [8192]u8 = undefined;
        const n = sockread.readSome(s, &buf) catch |err| return err;
        if (n == 0) return 0;

        try self.appendPending(buf[0..n]);
        const res = try self.drainPending(null);
        return res.dispatched;
    }

    /// Send PING and wait for PONG.
    ///
    /// Reads until a `PONG` line arrives, dispatching whatever else comes in
    /// through `drainPending`. "The next read is the PONG" only holds on an
    /// idle connection, and PING/PONG are *interleaved with traffic by design* —
    /// the publish-and-subscribe live test failed here with `error.ProtocolError`
    /// on a healthy connection because the server's `MSG` for the message just
    /// published arrived first, and the single-read version read those bytes and
    /// compared them to `"PONG\r\n"`.
    pub fn ping(self: *Self) !void {
        const s = self.stream orelse return error.NotConnected;
        if (self.draining) return error.Reentrant;
        var wbuf: [64]u8 = undefined;
        var w = s.writer(self.io, &wbuf);
        try w.interface.writeAll("PING\r\n");
        try w.interface.flush();

        const deadline = Time.monotonicNowMilliseconds() + @as(i64, @intCast(self.config.ping_timeout_ms));
        var rbuf: [8192]u8 = undefined;
        while (true) {
            const n = sockread.readSome(s, &rbuf) catch return error.ConnectionError;
            if (n == 0) return error.ConnectionClosed;
            try self.appendPending(rbuf[0..n]);
            // Dispatch first: a `MSG` can share the chunk with the `PONG`, and
            // dropping it here would lose a message the caller still expects.
            const res = self.drainPending(null) catch |err| {
                std.log.warn("[Nats] dispatch while waiting for PONG: {s}", .{@errorName(err)});
                if (Time.monotonicNowMilliseconds() >= deadline) return error.Timeout;
                continue;
            };
            // A PONG split across two reads is still recognized: it is consumed
            // out of the reassembly buffer, not matched against one chunk.
            if (res.saw_pong) return;
            if (Time.monotonicNowMilliseconds() >= deadline) return error.Timeout;
        }
    }

    // ── Internal: reassembly buffer + incoming frame parser ──

    /// Append freshly read bytes to the reassembly buffer. Bounded: a peer
    /// whose bytes never complete a frame must not grow this without limit.
    fn appendPending(self: *Self, bytes: []const u8) !void {
        if (self.pending.items.len + bytes.len > max_pending_bytes) return error.MessageTooLarge;
        try self.pending.appendSlice(self.allocator, bytes);
    }

    const DrainResult = struct {
        /// MSG frames dispatched to subscription callbacks.
        dispatched: usize = 0,
        /// A PONG line was consumed (used by `ping`).
        saw_pong: bool = false,
        /// The payload of the MSG addressed to the request sid, if one
        /// arrived. Owned by the caller of `drainPending`.
        request_payload: ?[]u8 = null,
    };

    /// Parse as many complete protocol frames as `pending` currently holds:
    /// dispatch MSGs to their subscriptions (or capture the one addressed to
    /// `request_sid`), answer PINGs, note PONGs. Consumed bytes are removed;
    /// an incomplete trailing frame is kept for the next read — that retained
    /// tail is the point of the buffer, since a read can end in the middle of
    /// a header line or mid-payload.
    fn drainPending(self: *Self, request_sid: ?u64) !DrainResult {
        self.draining = true;
        defer self.draining = false;

        var res: DrainResult = .{};
        errdefer if (res.request_payload) |p| self.allocator.free(p);

        var pos: usize = 0;
        // Whatever the loop consumed stays consumed even when it exits with an
        // error — re-parsing those bytes on the next call would re-dispatch
        // messages their callbacks already saw.
        defer {
            if (pos > 0) {
                const rest = self.pending.items.len - pos;
                std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[pos..]);
                self.pending.shrinkRetainingCapacity(rest);
            }
        }

        const data = self.pending.items;
        while (pos < data.len) {
            const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse break;
            const line = data[pos..line_end];
            const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;

            // MSG <subject> <sid> [reply-to] <#bytes>\r\n<payload>\r\n
            if (std.mem.startsWith(u8, trimmed, "MSG ")) {
                const header = parseMsgHeader(trimmed) orelse {
                    // Malformed header line: skip the line and keep going.
                    pos = line_end + 1;
                    continue;
                };
                const payload_start = line_end + 1;
                // Header complete but the payload (or its trailing CRLF) is
                // still in flight: keep the whole frame for the next read.
                if (payload_start + header.payload_len + 2 > data.len) break;
                const payload = data[payload_start .. payload_start + header.payload_len];
                pos = payload_start + header.payload_len + 2;

                if (request_sid) |rs| {
                    if (header.sid == rs) {
                        if (res.request_payload == null) {
                            res.request_payload = try self.allocator.dupe(u8, payload);
                        }
                        continue;
                    }
                }

                const sid_key = try self.allocator.print("{d}", .{header.sid});
                defer self.allocator.free(sid_key);
                if (self.subscriptions.get(sid_key)) |sub| {
                    sub.callback(.{
                        .subject = header.subject,
                        .reply_to = header.reply_to,
                        .payload = payload,
                        .sid = header.sid,
                    });
                    res.dispatched += 1;
                }
                continue;
            }

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
                res.saw_pong = true;
                continue;
            }

            if (std.mem.eql(u8, trimmed, "+OK")) continue;

            if (std.mem.startsWith(u8, trimmed, "-ERR")) {
                std.log.warn("[NATS] Server error: {s}", .{trimmed});
                continue;
            }
            // Anything else is not a line this client speaks; skipped.
        }
        return res;
    }

    const MsgHeader = struct {
        subject: []const u8,
        sid: u64,
        reply_to: ?[]const u8,
        payload_len: usize,
    };

    /// Parse a MSG header line (the "\r" already stripped). Returns null on a
    /// malformed line.
    fn parseMsgHeader(line: []const u8) ?MsgHeader {
        var parts = std.mem.splitScalar(u8, line[4..], ' ');
        const subject = parts.next() orelse return null;
        const sid_str = parts.next() orelse return null;
        const sid = std.fmt.parseInt(u64, sid_str, 10) catch return null;
        var reply_to: ?[]const u8 = null;
        var token = parts.next() orelse return null;
        const payload_len = std.fmt.parseInt(usize, token, 10) catch blk: {
            // 4-token form: the token just read is the reply-to subject.
            reply_to = token;
            token = parts.next() orelse return null;
            break :blk std.fmt.parseInt(usize, token, 10) catch return null;
        };
        return .{ .subject = subject, .sid = sid, .reply_to = reply_to, .payload_len = payload_len };
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

/// Read one protocol line from a freshly connected socket, up to and excluding
/// the '\n' (a trailing '\r' is kept for the caller to strip). Byte-at-a-time
/// because the line length is unknown and whatever follows it must stay in the
/// socket for the caller. Bounded by `NatsClient.max_info_line_bytes`: past
/// that the peer is not speaking NATS (or is a flood), and the read fails with
/// `error.ProtocolError` instead of accumulating without limit. Caller owns the
/// returned slice.
fn readInfoLine(allocator: std.mem.Allocator, stream: std.Io.net.Stream) ![]u8 {
    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);
    while (true) {
        var byte_buf: [1]u8 = undefined;
        const got = sockread.readSome(stream, &byte_buf) catch return error.ConnectionError;
        if (got == 0) return error.ConnectionClosed;
        if (byte_buf[0] == '\n') break;
        try line.append(allocator, byte_buf[0]);
        if (line.items.len > NatsClient.max_info_line_bytes) return error.ProtocolError;
    }
    return line.toOwnedSlice(allocator);
}

// ── Tests ──

test "NatsClient init and deinit" {
    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, .{});
    defer client.deinit();
}

test "NatsConfig defaults" {
    const cfg = NatsConfig{};
    // A literal address, not `"localhost"`: `connect` resolves this with
    // `IpAddress.parseIp4`, which rejects a host name with
    // `error.InvalidCharacter` — so the documented default used to be a config
    // that could not connect. `NatsConfig.url`'s doc comment says what a host
    // name would take.
    try std.testing.expectEqualStrings("127.0.0.1", cfg.url);
    try std.testing.expectEqual(@as(u16, 4222), cfg.port);
    try std.testing.expectEqual(@as(usize, 10), cfg.max_reconnect_attempts);
    // The address the default config describes is parsable, which is the whole
    // point of the default being a literal.
    _ = try std.Io.net.IpAddress.parseIp4(cfg.url, cfg.port);
}

test "natsTestConfig reads host and port from NATS_URL" {
    const a = natsTestConfig("nats://127.0.0.1:4222");
    try std.testing.expectEqualStrings("127.0.0.1", a.url);
    try std.testing.expectEqual(@as(u16, 4222), a.port);
    // Non-default port (a container's published port is the case that matters).
    const b = natsTestConfig("nats://10.1.2.3:14222");
    try std.testing.expectEqualStrings("10.1.2.3", b.url);
    try std.testing.expectEqual(@as(u16, 14222), b.port);
    // Bare host, no scheme and no port: the config default port survives.
    const c = natsTestConfig("192.168.1.9");
    try std.testing.expectEqualStrings("192.168.1.9", c.url);
    try std.testing.expectEqual(@as(u16, 4222), c.port);
}

/// `NATS_URL` (`nats://127.0.0.1:4222`) as a config. The three live tests used to
/// only *check* that the variable was set and then connect with the defaults —
/// so a `NATS_URL` pointing somewhere else was silently ignored, and the tests
/// were really asserting "there is a NATS server on localhost:4222". The host and
/// the port are both taken from the URL now; `nats.zig`'s client resolves a
/// literal address, so the scheme is dropped here (the same shape
/// `redis.zig`'s live test uses).
fn natsTestConfig(url: []const u8) NatsConfig {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const host_end = std.mem.indexOfScalar(u8, after_scheme, ':') orelse after_scheme.len;
    const host = after_scheme[0..host_end];
    var cfg = NatsConfig{};
    if (host.len > 0) cfg.url = host;
    if (host_end < after_scheme.len) {
        cfg.port = std.fmt.parseInt(u16, after_scheme[host_end + 1 ..], 10) catch cfg.port;
    }
    return cfg;
}

test "NATS connect and ping" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const nats_url = if (std.c.getenv("NATS_URL")) |ptr| std.mem.span(ptr) else null;
    if (nats_url == null or nats_url.?.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, natsTestConfig(nats_url.?));
    defer client.deinit();

    const info = try client.connect();
    try std.testing.expect(info.server_id.len > 0);
    try std.testing.expect(info.version.len > 0);

    // Ping/PONG heartbeat
    try client.ping();
    try client.ping();
}

test "NATS publish and subscribe" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const nats_url = if (std.c.getenv("NATS_URL")) |ptr| std.mem.span(ptr) else null;
    if (nats_url == null or nats_url.?.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, natsTestConfig(nats_url.?));
    defer client.deinit();

    _ = try client.connect();

    // Subscribe to test subject
    const sid = try client.subscribe("zmodu.test.pubsub", struct {
        fn handler(msg: NatsClient.Message) void {
            _ = msg;
        }
    }.handler);
    defer client.unsubscribe(sid) catch {};

    try client.publish("zmodu.test.pubsub", "hello-nats");
    try client.flush();

    // Poll to receive the message
    _ = try client.poll();
}

test "NATS request-reply" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const nats_url = if (std.c.getenv("NATS_URL")) |ptr| std.mem.span(ptr) else null;
    if (nats_url == null or nats_url.?.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, natsTestConfig(nats_url.?));
    defer client.deinit();

    _ = try client.connect();

    // Subscribe to respond to requests
    const sid = try client.subscribe("zmodu.test.request", struct {
        fn handler(msg: NatsClient.Message) void {
            _ = msg;
        }
    }.handler);
    defer client.unsubscribe(sid) catch {};

    // Send a request — will timeout (no responder), but validates protocol
    _ = client.request("zmodu.test.request", "ping", 1000) catch |err| {
        try std.testing.expectEqual(error.Timeout, err);
        return;
    };
}

// ── Offline protocol tests (AF_UNIX socketpair stands in for the server) ──

/// Callback target for the socketpair tests: subscription callbacks are bare
/// fn pointers, so the recorded message lives in statics. Tests in a binary
/// run sequentially, and each test calls `reset` first.
const TestSink = struct {
    var count: usize = 0;
    var payload_buf: [64 * 1024]u8 = undefined;
    var payload_len: usize = 0;
    var subject_buf: [256]u8 = undefined;
    var subject_len: usize = 0;

    fn reset() void {
        count = 0;
        payload_len = 0;
        subject_len = 0;
    }

    fn callback(msg: NatsClient.Message) void {
        count += 1;
        // The message borrows the client's reassembly buffer — copy out what
        // the assertions need.
        @memcpy(payload_buf[0..msg.payload.len], msg.payload);
        payload_len = msg.payload.len;
        @memcpy(subject_buf[0..msg.subject.len], msg.subject);
        subject_len = msg.subject.len;
    }

    fn payload() []const u8 {
        return payload_buf[0..payload_len];
    }

    fn subject() []const u8 {
        return subject_buf[0..subject_len];
    }
};

fn testSocketpair() ?[2]std.posix.socket_t {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return null,
    }
    return fds;
}

fn testStream(fd: std.posix.socket_t) std.Io.net.Stream {
    return .{ .socket = .{ .handle = fd, .address = undefined } };
}

test "NatsClient poll reassembles a MSG frame split across reads" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const fds = testSocketpair() orelse return error.SkipZigTest;
    defer _ = std.posix.system.close(fds[1]);

    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, .{});
    defer client.deinit();
    client.stream = testStream(fds[0]);

    TestSink.reset();
    _ = try client.subscribe("zmodu.test.split", TestSink.callback);

    // The first read ends inside the header line. The per-read parser used to
    // drop everything after the last complete line, stranding the partial
    // frame; now the tail stays in `pending` for the next read.
    const frame = "MSG zmodu.test.split 1 10\r\nhello-nats\r\n";
    try sockread.writeFull(testStream(fds[1]), frame[0..9]);
    try std.testing.expectEqual(@as(usize, 0), try client.poll());
    try std.testing.expectEqual(@as(usize, 0), TestSink.count);

    try sockread.writeFull(testStream(fds[1]), frame[9..]);
    try std.testing.expectEqual(@as(usize, 1), try client.poll());
    try std.testing.expectEqual(@as(usize, 1), TestSink.count);
    try std.testing.expectEqualStrings("zmodu.test.split", TestSink.subject());
    try std.testing.expectEqualStrings("hello-nats", TestSink.payload());
    // Nothing left half-consumed.
    try std.testing.expectEqual(@as(usize, 0), client.pending.items.len);
}

test "NatsClient poll reassembles a MSG larger than one read buffer" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const fds = testSocketpair() orelse return error.SkipZigTest;
    defer _ = std.posix.system.close(fds[1]);

    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, .{});
    defer client.deinit();
    client.stream = testStream(fds[0]);

    TestSink.reset();
    _ = try client.subscribe("zmodu.test.big", TestSink.callback);

    // A 20 KiB payload cannot fit the 8 KiB per-read buffer: it necessarily
    // arrives over several reads. Written in 4 KiB pieces with a poll after
    // each so the socketpair stays drained and no write can block on a full
    // buffer.
    var payload: [20 * 1024]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    const header = try allocator.print("MSG zmodu.test.big 1 {d}\r\n", .{payload.len});
    defer allocator.free(header);

    try sockread.writeFull(testStream(fds[1]), header);
    try std.testing.expectEqual(@as(usize, 0), try client.poll());

    var off: usize = 0;
    while (off < payload.len) : (off += 4096) {
        try sockread.writeFull(testStream(fds[1]), payload[off..@min(off + 4096, payload.len)]);
        // Not complete until the trailing CRLF has arrived too.
        try std.testing.expectEqual(@as(usize, 0), try client.poll());
    }
    try sockread.writeFull(testStream(fds[1]), "\r\n");
    try std.testing.expectEqual(@as(usize, 1), try client.poll());

    try std.testing.expectEqual(@as(usize, 1), TestSink.count);
    try std.testing.expectEqualSlices(u8, &payload, TestSink.payload());
}

test "NatsClient request reports a peer shutdown as ConnectionClosed, not Timeout" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const fds = testSocketpair() orelse return error.SkipZigTest;
    defer _ = std.posix.system.close(fds[1]);

    const allocator = std.testing.allocator;
    var client = NatsClient.init(allocator, std.testing.io, .{});
    defer client.deinit();
    client.stream = testStream(fds[0]);

    // The peer closes its write side: the client's reads see EOF while its own
    // writes (the SUB/PUB of the request itself) still succeed into the
    // socketpair buffer, so the read loop is what gets exercised.
    _ = std.c.shutdown(fds[1], std.c.SHUT.WR);

    // 0 from readSome used to spin a busy loop until the deadline and then
    // misreport the closed connection as error.Timeout — the generous 60 s
    // timeout makes that old behavior hang this test, the new one returns at
    // once.
    if (client.request("zmodu.test.closed", "x", 60_000)) |resp| {
        allocator.free(resp);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.ConnectionClosed, err);
    }
}

// `subscribeGroup` built the entry's copies inline in the `put` argument list:
// when the queue-group dupe or the map insert failed, the copies already made
// had no owner left to free them (the challenge.zig batch had the same shape).
// The loop walks every allocation of the call — the sid key, both dupes and
// the map's own storage — and asserts the call gave every byte back.
test "NatsClient subscribeGroup frees the partial copies when an allocation fails" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const fds = testSocketpair() orelse return error.SkipZigTest;
    defer _ = std.posix.system.close(fds[1]);
    defer _ = std.posix.system.close(fds[0]);

    for (0..12) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var client = NatsClient.init(failing.allocator(), std.testing.io, .{});
        client.stream = testStream(fds[0]);

        if (client.subscribeGroup("zmodu.test.oom", "workers", TestSink.callback)) |sid| {
            _ = sid;
        } else |err| {
            try std.testing.expectEqual(@as(anyerror, error.OutOfMemory), err);
            // A failed subscribe left nothing in the map.
            try std.testing.expectEqual(@as(usize, 0), client.subscriptions.count());
        }
        // The socketpair fd is shared across iterations; the client does not
        // own it.
        client.stream = null;
        client.deinit();
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

// `connect` read the INFO line a byte at a time with no bound: a peer that
// never sends '\n' kept it accumulating (and blocked) forever. The cap makes
// it `error.ProtocolError` past 64 KiB. The reader runs on an io thread
// because the writer must keep the socketpair drained; once the reader bails
// it closes its end, which fails any write still in flight — expected, and
// not what is asserted.
test "NatsClient connect rejects an INFO line longer than 64 KiB" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const fds = testSocketpair() orelse return error.SkipZigTest;
    defer _ = std.posix.system.close(fds[1]);

    const io = std.testing.io;
    const stream = testStream(fds[0]);

    const Task = struct {
        var s: std.Io.net.Stream = undefined;
        var result: ?anyerror = null;
        fn body() void {
            defer s.close(std.testing.io);
            const line = readInfoLine(std.heap.page_allocator, s) catch |err| {
                result = err;
                return;
            };
            std.heap.page_allocator.free(line);
            result = null;
        }
    };
    Task.s = stream;
    Task.result = null;

    var fut = io.concurrent(Task.body, .{}) catch |err| {
        stream.close(io);
        return err;
    };

    var chunk: [4096]u8 = @splat('x');
    var sent: usize = 0;
    while (sent < NatsClient.max_info_line_bytes + chunk.len) : (sent += chunk.len) {
        sockread.writeFull(testStream(fds[1]), &chunk) catch break;
    }
    fut.await(io);

    try std.testing.expectEqual(@as(?anyerror, error.ProtocolError), Task.result);
}

// `connect` used to free the INFO line before returning the `ServerInfo`
// parsed out of it, so every string field of the returned struct was a
// dangling slice — under the testing allocator the freed bytes read back as
// `0xAA` fill, which is what the assertions below would catch. The line is
// now owned by the client (`info_line`) and freed on the next `connect` or
// `deinit`; the leak check at test end is what proves the new owner exists.
test "NatsClient connect returns a ServerInfo backed by the client's buffer" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    const ServerCtx = struct {
        server: *std.Io.net.Server,
        fn run(ctx: *@This()) void {
            const accepted = ctx.server.accept(io) catch return;
            defer accepted.close(io);
            const info = "INFO {\"server_id\":\"SID-test\",\"server_name\":\"srv-a\",\"version\":\"2.10.3\",\"host\":\"0.0.0.0\",\"port\":4222,\"max_payload\":1048576}\r\n";
            sockread.writeFull(accepted, info) catch return;
            // Drain the CONNECT frame until the client goes away; without
            // this the client's small write could still sit in the socket
            // buffer, but reading keeps the server side simple and bounded.
            var buf: [256]u8 = undefined;
            while (true) {
                var fds = [_]std.posix.pollfd{.{ .fd = accepted.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                const n = std.posix.poll(&fds, 3000) catch break;
                if (n == 0) break;
                const got = std.posix.read(accepted.socket.handle, &buf) catch break;
                if (got == 0) break;
            }
        }
    };

    var server_ctx = ServerCtx{ .server = &listener };
    const th = try std.Thread.spawn(.{}, ServerCtx.run, .{&server_ctx});
    defer th.join();

    var client = NatsClient.init(allocator, io, .{ .url = "127.0.0.1", .port = port });
    defer client.deinit();

    const info = try client.connect();

    // These read the client-owned buffer now; the shape this replaces had
    // freed it before `connect` returned.
    try std.testing.expectEqualStrings("SID-test", info.server_id);
    try std.testing.expectEqualStrings("srv-a", info.server_name);
    try std.testing.expectEqualStrings("2.10.3", info.version);
    try std.testing.expectEqual(@as(u16, 4222), info.port);
    try std.testing.expectEqual(@as(usize, 1048576), info.max_payload);
    try std.testing.expect(info.raw_json.len > 0);
}
