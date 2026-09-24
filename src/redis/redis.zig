//! Redis client for zigzero
//!
//! Provides Redis operations aligned with go-zero's redis functionality.
//!
//! STRUCTURE:
//!   §1  RESP framing —— ReplyReader, readWholeReply, writeCmd
//!   §2  Config & connection —— RedisConfig, Redis lifecycle, pooled stream borrow/release
//!   §3  Command surface —— get/set/del/incr/expire, list and hash ops, pub-sub, lock/unlock
//!   §4  Cluster & locks —— crc16/keySlot, ClusterNode, RedisCluster, Lock
//!   §5  Tests —— unit tests plus RESP framing regression tests
//!
//! Every section carries a matching `// ==== §N ... ====` anchor — `grep "§3"` jumps there.

const std = @import("std");
const builtin = @import("builtin");
const errors = @import("../sqlx/errors.zig");
const sockread = @import("../core/sockread.zig");

// ==== §1  RESP framing ====

/// Write command bytes to Redis stream (Zig 0.17 compat: stream.write removed).
/// Must flush: `Writer.writeAll` only fills the buffer; without flush the
/// RESP command never reaches Redis and the subsequent read hangs forever.
/// Reads one complete RESP reply into a caller-owned buffer.
///
/// The old code did a single `readSome` per command, which is wrong on two
/// counts: a reply larger than the buffer was truncated (and the remainder
/// stayed in the socket, desynchronising every later command), and a reply
/// split across TCP segments was parsed half-formed. This reader frames by
/// RESP instead: `+`/`-`/`:` run to CRLF, `$`/`*` read the declared byte count.
///
/// `timeout_ms` is a real read deadline (poll before each blocking read) —
/// `RedisConfig.read_timeout_ms` used to be declared and never read.
const ReplyReader = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    timeout_ms: u32,

    fn deadlineExpired(self: *ReplyReader) !void {
        if (self.timeout_ms == 0) return;
        var fds = [1]std.posix.pollfd{.{
            .fd = self.stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, @intCast(self.timeout_ms)) catch return error.RedisTimeout;
        if (ready == 0) return error.RedisTimeout;
    }

    fn readByte(self: *ReplyReader) !u8 {
        try self.deadlineExpired();
        var one: [1]u8 = undefined;
        const n = sockread.readSome(self.stream, &one) catch return error.RedisError;
        if (n == 0) return error.RedisError;
        return one[0];
    }

    /// Append one CRLF-terminated line, CRLF included, so `out` holds the exact
    /// wire bytes the pre-framing code used to hand to the parsers.
    fn readLine(self: *ReplyReader, out: *std.ArrayList(u8)) !void {
        while (true) {
            const c = try self.readByte();
            try out.append(self.allocator, c);
            if (c == '\r') {
                const nl = try self.readByte();
                if (nl != '\n') return error.RedisError;
                try out.append(self.allocator, nl);
                return;
            }
        }
    }

    fn readExact(self: *ReplyReader, out: *std.ArrayList(u8), count: usize) !void {
        var i: usize = 0;
        var chunk: [512]u8 = undefined;
        while (i < count) {
            const want = @min(chunk.len, count - i);
            try self.deadlineExpired();
            const n = sockread.readSome(self.stream, chunk[0..want]) catch return error.RedisError;
            if (n == 0) return error.RedisError;
            try out.appendSlice(self.allocator, chunk[0..n]);
            i += n;
        }
    }

    /// Consume the CRLF that terminates a bulk body. It has to come off the
    /// socket, not be synthesised: a phantom CRLF left in the stream shifts the
    /// next reply by two bytes and every later command misparses.
    fn readCrlf(self: *ReplyReader, out: *std.ArrayList(u8)) !void {
        const start = out.items.len;
        try self.readExact(out, 2);
        if (!std.mem.eql(u8, out.items[start..], "\r\n")) return error.RedisError;
    }

    /// Read a `$`/`*` length line: the digits are returned, the whole line
    /// (CRLF included) is appended to `out`.
    fn readCount(self: *ReplyReader, out: *std.ArrayList(u8)) !i64 {
        var line = std.ArrayList(u8).empty;
        defer line.deinit(self.allocator);
        try self.readLine(&line);
        try out.appendSlice(self.allocator, line.items);
        return std.fmt.parseInt(i64, std.mem.trimEnd(u8, line.items, "\r\n"), 10) catch error.RedisError;
    }
};

/// Frame one complete RESP reply into `out`, keeping the wire shape
/// (`+OK\r\n`, `:12\r\n`, `$5\r\nhello\r\n`, `*-1\r\n`) so a command's
/// existing parsing keeps working on a now-complete buffer.
fn readWholeReply(reader: *ReplyReader, out: *std.ArrayList(u8)) !void {
    const type_byte = try reader.readByte();
    try out.append(reader.allocator, type_byte);
    switch (type_byte) {
        // Simple string / error / integer: one line.
        '+', '-', ':' => try reader.readLine(out),
        '$' => {
            const len = try reader.readCount(out);
            if (len >= 0) {
                try reader.readExact(out, @intCast(len));
                try reader.readCrlf(out);
            }
        },
        '*' => {
            const count = try reader.readCount(out);
            var i: i64 = 0;
            while (i < count) : (i += 1) try readWholeReply(reader, out);
        },
        else => return error.RedisError,
    }
}

fn writeCmd(stream: *const std.Io.net.Stream, io: std.Io, cmd: []const u8) errors.Result {
    var wbuf: [8192]u8 = undefined;
    var wstream = stream.writer(io, &wbuf);
    wstream.interface.writeAll(cmd) catch return error.RedisError;
    wstream.interface.flush() catch return error.RedisError;
}

// ==== §2  Config & connection ====

/// Redis configuration
pub const RedisConfig = struct {
    /// Literal IPv4 (or IPv6) address: `connect` resolves it with
    /// `IpAddress.parseIp4`, which does no DNS. The default used to be
    /// `"localhost"`, which that parser rejects with `error.InvalidCharacter` —
    /// so the default config could never connect, and the three live tests
    /// (which only checked that `REDIS_URL` was *set*, then connected with these
    /// defaults) failed with `error.RedisError` against a perfectly healthy
    /// server. `fromUrl` is what turns a `REDIS_URL` into this.
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    password: ?[]const u8 = null,
    db: u32 = 0,
    pool_size: u32 = 100,
    read_timeout_ms: u32 = 3000,
    write_timeout_ms: u32 = 3000,

    /// Config from a URL-shaped address (`redis://127.0.0.1:6379`, the shape
    /// `REDIS_URL` carries). Scheme, `user:password@` and any path are dropped;
    /// host and port are taken from what is left.
    pub fn fromUrl(url: []const u8) RedisConfig {
        var rest = url;
        if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
        if (std.mem.lastIndexOfScalar(u8, rest, '@')) |i| rest = rest[i + 1 ..];
        if (std.mem.indexOfAny(u8, rest, "/?#")) |i| rest = rest[0..i];

        var cfg = RedisConfig{};
        if (std.mem.lastIndexOfScalar(u8, rest, ':')) |i| {
            // Inside brackets is an IPv6 literal, not a port.
            if (std.mem.indexOfScalar(u8, rest, '[') == null) {
                cfg.port = std.fmt.parseInt(u16, rest[i + 1 ..], 10) catch cfg.port;
                rest = rest[0..i];
            }
        }
        if (rest.len > 0) cfg.host = rest;
        return cfg;
    }
};

/// Redis client for zigzero
pub const Redis = struct {
    /// Serialises commands when there is no pool (`pool_size <= 1`).
    stream_mu: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,
    config: RedisConfig,
    stream: ?std.Io.net.Stream = null,
    io: std.Io,
    /// Optional connection pool (enabled when pool_size > 1).
    pool: ?ConnPool = null,
    pool_mu: std.Io.Mutex = .init,

    const ConnPool = struct {
        streams: []?std.Io.net.Stream,
        in_use: []bool,

        fn init(allocator: std.mem.Allocator, size: u32) !ConnPool {
            const n = @max(size, 1);
            const streams = try allocator.alloc(?std.Io.net.Stream, n);
            @memset(streams, null);
            const in_use = try allocator.alloc(bool, n);
            @memset(in_use, false);
            return .{ .streams = streams, .in_use = in_use };
        }

        fn deinit(self: *ConnPool, allocator: std.mem.Allocator, io: std.Io) void {
            for (self.streams) |maybe| {
                if (maybe) |s| s.close(io);
            }
            allocator.free(self.streams);
            allocator.free(self.in_use);
        }
    };

    /// Create a new Redis client
    pub fn new(allocator: std.mem.Allocator, io: std.Io, cfg: RedisConfig) !Redis {
        var client = Redis{
            .allocator = allocator,
            .config = cfg,
            .stream = null,
            .io = io,
        };
        if (cfg.pool_size > 1) {
            client.pool = try ConnPool.init(allocator, cfg.pool_size);
        }
        return client;
    }

    /// Deinitialize Redis client
    pub fn deinit(self: *Redis) void {
        if (self.pool) |*p| {
            p.deinit(self.allocator, self.io);
            self.pool = null;
        }
        if (self.stream) |s| {
            s.close(self.io);
            self.stream = null;
        }
        self.* = undefined;
    }

    /// Connect to Redis server (opens primary stream; pool fills on demand).
    pub fn connect(self: *Redis) !void {
        const address = std.Io.net.IpAddress.parseIp4(self.config.host, self.config.port) catch return error.RedisError;
        self.stream = address.connect(self.io, .{ .mode = .stream }) catch return error.RedisError;
        // `write_timeout_ms` used to be declared and never applied: a stalled
        // Redis made writes block forever (and held `stream_mu` while doing it).
        if (self.stream) |s| sockread.setSendTimeout(s, self.config.write_timeout_ms);
    }

    /// Borrowed connection handle. Named on purpose: an inline struct type
    /// would not be assignable between `acquireStream` / `releaseStream` /
    /// `evictStream` even with identical fields.
    pub const Borrowed = struct { stream: std.Io.net.Stream, pool_idx: ?usize };

    /// Borrow a pooled connection (or the primary stream when pool_size <= 1).
    ///
    /// The single-stream case takes `stream_mu` for the whole command: without
    /// it two request fibers interleave their writes and each reads the other's
    /// reply (the desync that produced 500s and then hung endpoints forever
    /// under concurrency with `pool_size = 1`).
    fn acquireStream(self: *Redis) errors.ResultT(Borrowed) {
        if (self.pool) |*p| {
            self.pool_mu.lock(self.io) catch return error.RedisError;
            defer self.pool_mu.unlock(self.io);
            for (p.streams, 0..) |*slot, i| {
                if (p.in_use[i]) continue;
                if (slot.*) |_| {
                    p.in_use[i] = true;
                    return .{ .stream = slot.*.?, .pool_idx = i };
                }
                const address = std.Io.net.IpAddress.parseIp4(self.config.host, self.config.port) catch return error.RedisError;
                const s = address.connect(self.io, .{ .mode = .stream }) catch return error.RedisError;
                slot.* = s;
                p.in_use[i] = true;
                return .{ .stream = s, .pool_idx = i };
            }
            return error.RedisError; // pool exhausted
        }
        self.stream_mu.lock(self.io) catch return error.RedisError;
        const s = self.stream orelse {
            self.stream_mu.unlock(self.io);
            return error.RedisError;
        };
        return .{ .stream = s, .pool_idx = null };
    }

    fn releaseStream(self: *Redis, pool_idx: ?usize) void {
        const idx = pool_idx orelse {
            self.stream_mu.unlock(self.io);
            return;
        };
        if (self.pool) |*p| {
            self.pool_mu.lock(self.io) catch return;
            defer self.pool_mu.unlock(self.io);
            if (idx < p.in_use.len) p.in_use[idx] = false;
        }
    }

    /// Drop the stream we just failed on instead of returning it to the pool:
    /// a desynchronised connection must never be handed to the next borrower.
    fn evictStream(self: *Redis, borrowed: Borrowed) void {
        if (self.pool) |*p| {
            const idx = borrowed.pool_idx orelse {
                borrowed.stream.close(self.io);
                return;
            };
            self.pool_mu.lock(self.io) catch return;
            defer self.pool_mu.unlock(self.io);
            if (idx < p.streams.len) {
                if (p.streams[idx]) |s| s.close(self.io);
                p.streams[idx] = null;
                p.in_use[idx] = false;
            }
            return;
        }
        borrowed.stream.close(self.io);
        if (self.stream) |s| {
            if (s.socket.handle == borrowed.stream.socket.handle) self.stream = null;
        }
    }

    /// Disconnect from Redis server
    pub fn disconnect(self: *Redis) void {
        if (self.stream) |s| {
            s.close(self.io);
            self.stream = null;
        }
    }

    // ==== §3  Command surface ====

    /// Get a value by key
    pub fn get(self: *Redis, key: []const u8) errors.ResultT(?[]const u8) {
        const borrowed = try self.acquireStream();
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nGET\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            try writeCmd(&stream, self.io, cmd);

            var response_list = std.ArrayList(u8).empty;
            defer response_list.deinit(self.allocator);
            var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
            readWholeReply(&reply_reader, &response_list) catch {
                self.evictStream(borrowed);
                return error.RedisError;
            };
            const response = response_list.items;

            // Parse bulk string response
            if (response.len > 1) {
                if (response[0] == '$') {
                    if (response[1] == '-') {
                        return null; // Null bulk string
                    }
                    var end_idx: usize = 1;
                    while (end_idx < response.len and response[end_idx] != '\r') : (end_idx += 1) {}
                    const len = std.fmt.parseInt(i32, response[1..end_idx], 10) catch return error.RedisError;
                    if (len <= 0) return null;

                    const value_start = end_idx + 2;
                    const value = self.allocator.dupe(u8, response[value_start..@min(value_start + @as(usize, @intCast(len)), response.len)]) catch return error.RedisError;
                    return value;
                }
            }
        }
        return error.RedisError;
    }

    /// Set a value with expiration
    pub fn set(self: *Redis, key: []const u8, value: []const u8, ex_seconds: ?u32) errors.Result {
        const borrowed = try self.acquireStream();
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = if (ex_seconds) |ex|
            std.fmt.allocPrint(self.allocator, "*5\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n$2\r\nEX\r\n${d}\r\n{d}\r\n", .{ key.len, key, value.len, value, std.fmt.count("{d}", .{ex}), ex }) catch return error.RedisError
        else
            std.fmt.allocPrint(self.allocator, "*3\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ key.len, key, value.len, value }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            self.evictStream(borrowed);
            return error.RedisError;
        };
    }

    /// Set a value only if key doesn't exist
    pub fn setNX(self: *Redis, key: []const u8, value: []const u8) errors.ResultT(bool) {
        const borrowed = try self.acquireStream();
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$5\r\nSETNX\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ key.len, key, value.len, value }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(i32, std.mem.trimEnd(u8, response[1..], "\r\n"), 10) catch return error.RedisError;
            return val == 1;
        }
        return error.RedisError;
    }

    /// Delete keys
    pub fn del(self: *Redis, keys: []const []const u8) errors.ResultT(u32) {
        // Nothing to delete is a real "0 deleted", not a failure.
        if (keys.len == 0) return 0;
        const borrowed = try self.acquireStream();
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        var cmd_builder: std.ArrayList(u8) = std.ArrayList(u8).empty;
        defer cmd_builder.deinit(self.allocator);

        try cmd_builder.print(self.allocator, "*{d}\r\n$3\r\nDEL\r\n", .{keys.len + 1});
        for (keys) |key| {
            try cmd_builder.print(self.allocator, "${d}\r\n{s}\r\n", .{ key.len, key });
        }

        try writeCmd(&stream, self.io, cmd_builder.items);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(u32, std.mem.trimEnd(u8, response[1..], "\r\n"), 10) catch return error.RedisError;
            return val;
        }
        return error.RedisError;
    }

    /// Check if key exists
    pub fn exists(self: *Redis, key: []const u8) errors.ResultT(bool) {
        const borrowed = try self.acquireStream();
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$6\r\nEXISTS\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(i32, std.mem.trimEnd(u8, response[1..], "\r\n"), 10) catch return error.RedisError;
            return val == 1;
        }
        return error.RedisError;
    }

    /// Increment a value
    pub fn incr(self: *Redis, key: []const u8) errors.ResultT(i64) {
        const borrowed = self.acquireStream() catch return error.RedisError;
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$4\r\nINCR\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(i64, std.mem.trimEnd(u8, response[1..], "\r\n"), 10) catch return error.RedisError;
            return val;
        }
        return error.RedisError;
    }

    /// Decrement a value
    pub fn decr(self: *Redis, key: []const u8) errors.ResultT(i64) {
        const borrowed = self.acquireStream() catch return error.RedisError;
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$4\r\nDECR\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(i64, std.mem.trimEnd(u8, response[1..], "\r\n"), 10) catch return error.RedisError;
            return val;
        }
        return error.RedisError;
    }

    /// Expire a key
    pub fn expire(self: *Redis, key: []const u8, seconds: u32) errors.Result {
        const borrowed = self.acquireStream() catch return error.RedisError;
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$6\r\nEXPIRE\r\n${d}\r\n{s}\r\n${d}\r\n{d}\r\n", .{ key.len, key, std.fmt.count("{d}", .{seconds}), seconds }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            self.evictStream(borrowed);
            return error.RedisError;
        };
        return;
    }

    /// Get remaining TTL
    pub fn ttl(self: *Redis, key: []const u8) errors.ResultT(i64) {
        const borrowed = try self.acquireStream();
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nTTL\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(i64, std.mem.trimEnd(u8, response[1..], "\r\n"), 10) catch return error.RedisError;
            return val;
        }
        return error.RedisError;
    }

    /// Acquire a distributed lock
    pub fn lock(self: *Redis, key: []const u8, value: []const u8, ttl_seconds: u32) errors.ResultT(bool) {
        const borrowed = try self.acquireStream();
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const px = ttl_seconds * 1000;
        const px_len = std.fmt.count("{d}", .{px});
        var cmd_builder: std.ArrayList(u8) = std.ArrayList(u8).empty;
        defer cmd_builder.deinit(self.allocator);
        // RESP array of 6 bulk strings: SET, key, value, NX, PX, <px-ms>.
        try cmd_builder.print(self.allocator, "*6\r\n$3\r\nSET\r\n", .{});
        try cmd_builder.print(self.allocator, "${d}\r\n{s}\r\n", .{ key.len, key });
        try cmd_builder.print(self.allocator, "${d}\r\n{s}\r\n", .{ value.len, value });
        try cmd_builder.print(self.allocator, "$2\r\nNX\r\n$2\r\nPX\r\n", .{});
        try cmd_builder.print(self.allocator, "${d}\r\n{d}\r\n", .{ px_len, px });

        try writeCmd(&stream, self.io, cmd_builder.items);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len >= 3 and std.mem.eql(u8, response[0..3], "+OK")) {
            return true;
        }
        // A losing `SET ... NX` answers with a nil bulk string — the server
        // telling us the key is held elsewhere. That is an answer; any other
        // reply (an `-ERR`, say) is not, and must not read as "not acquired".
        if (response.len >= 4 and std.mem.eql(u8, response[0..4], "$-1\r")) {
            return false;
        }
        return error.RedisError;
    }

    /// Release a distributed lock
    pub fn unlock(self: *Redis, key: []const u8) errors.Result {
        const borrowed = try self.acquireStream();
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nDEL\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        // DEL answers with an integer count; 0 means "the lock had already
        // expired" and still counts as released. Any other reply — an `-ERR`,
        // say — leaves us not knowing, which is not a success.
        if (response.len > 1 and response[0] == ':') {
            return;
        }
        return error.RedisError;
    }

    /// List operations
    pub fn lPush(self: *Redis, key: []const u8, value: []const u8) errors.ResultT(u32) {
        const borrowed = self.acquireStream() catch return error.RedisError;
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$5\r\nLPUSH\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ key.len, key, value.len, value }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(u32, std.mem.trimEnd(u8, response[1..], "\r\n"), 10) catch return error.RedisError;
            return val;
        }
        return error.RedisError;
    }

    pub fn rPop(self: *Redis, key: []const u8) errors.ResultT(?[]const u8) {
        const borrowed = self.acquireStream() catch return error.RedisError;
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$4\r\nRPOP\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len > 1) {
            if (response[0] == '$') {
                if (response[1] == '-') {
                    return null;
                }
                var end_idx: usize = 1;
                while (end_idx < response.len and response[end_idx] != '\r') : (end_idx += 1) {}
                const len = std.fmt.parseInt(i32, response[1..end_idx], 10) catch return error.RedisError;
                if (len <= 0) return null;

                const value_start = end_idx + 2;
                const value = self.allocator.dupe(u8, response[value_start..@min(value_start + @as(usize, @intCast(len)), response.len)]) catch return error.RedisError;
                return value;
            }
        }
        return error.RedisError;
    }

    /// Hash operations
    pub fn hSet(self: *Redis, key: []const u8, field: []const u8, value: []const u8) errors.ResultT(bool) {
        const borrowed = self.acquireStream() catch return error.RedisError;
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*4\r\n$4\r\nHSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
            key.len, key, field.len, field, value.len, value,
        }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(i32, std.mem.trimEnd(u8, response[1..], "\r\n"), 10) catch return error.RedisError;
            return val == 1;
        }
        return error.RedisError;
    }

    pub fn hGet(self: *Redis, key: []const u8, field: []const u8) errors.ResultT(?[]const u8) {
        const borrowed = self.acquireStream() catch return error.RedisError;
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$4\r\nHGET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
            key.len, key, field.len, field,
        }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len > 1) {
            if (response[0] == '$') {
                if (response[1] == '-') {
                    return null;
                }
                var end_idx: usize = 1;
                while (end_idx < response.len and response[end_idx] != '\r') : (end_idx += 1) {}
                const len = std.fmt.parseInt(i32, response[1..end_idx], 10) catch return error.RedisError;
                if (len <= 0) return null;

                const value_start = end_idx + 2;
                const value = self.allocator.dupe(u8, response[value_start..@min(value_start + @as(usize, @intCast(len)), response.len)]) catch return error.RedisError;
                return value;
            }
        }
        return error.RedisError;
    }

    /// Pub/Sub
    pub fn publish(self: *Redis, channel: []const u8, message: []const u8) errors.ResultT(u32) {
        const borrowed = self.acquireStream() catch return error.RedisError;
        defer self.releaseStream(borrowed.pool_idx);
        const stream = borrowed.stream;
        const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$7\r\nPUBLISH\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
            channel.len, channel, message.len, message,
        }) catch return error.RedisError;
        defer self.allocator.free(cmd);

        try writeCmd(&stream, self.io, cmd);

        var response_list = std.ArrayList(u8).empty;
        defer response_list.deinit(self.allocator);
        var reply_reader = ReplyReader{ .stream = stream, .io = self.io, .allocator = self.allocator, .timeout_ms = self.config.read_timeout_ms };
        readWholeReply(&reply_reader, &response_list) catch {
            // Framing failed or the deadline passed: this connection's byte
            // stream can no longer be trusted, so it must not go back to the pool.
            self.evictStream(borrowed);
            return error.RedisError;
        };
        const response = response_list.items;

        if (response.len > 1 and response[0] == ':') {
            const val = std.fmt.parseInt(u32, std.mem.trimEnd(u8, response[1..], "\r\n"), 10) catch return error.RedisError;
            return val;
        }
        return error.RedisError;
    }
};

// ==== §4  Cluster & locks ====

/// CRC16 for Redis cluster slot calculation
fn crc16(data: []const u8) u16 {
    const table = [_]u16{
        0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50a5, 0x60c6, 0x70e7,
        0x8108, 0x9129, 0xa14a, 0xb16b, 0xc18c, 0xd1ad, 0xe1ce, 0xf1ef,
        0x1231, 0x0210, 0x3273, 0x2252, 0x52b5, 0x4294, 0x72f7, 0x62d6,
        0x9339, 0x8318, 0xb37b, 0xa35a, 0xd3bd, 0xc39c, 0xf3ff, 0xe3de,
        0x2462, 0x3443, 0x0420, 0x1401, 0x64e6, 0x74c7, 0x44a4, 0x5485,
        0xa56a, 0xb54b, 0x8528, 0x9509, 0xe5ee, 0xf5cf, 0xc5ac, 0xd58d,
        0x3653, 0x2672, 0x1611, 0x0630, 0x76d7, 0x66f6, 0x5695, 0x46b4,
        0xb75b, 0xa77a, 0x9719, 0x8738, 0xf7df, 0xe7fe, 0xd79d, 0xc7bc,
        0x48c4, 0x58e5, 0x6886, 0x78a7, 0x0840, 0x1861, 0x2802, 0x3823,
        0xc9cc, 0xd9ed, 0xe98e, 0xf9af, 0x8948, 0x9969, 0xa90a, 0xb92b,
        0x5af5, 0x4ad4, 0x7ab7, 0x6a96, 0x1a71, 0x0a50, 0x3a33, 0x2a12,
        0xdbfd, 0xcbdc, 0xfbbf, 0xeb9e, 0x9b79, 0x8b58, 0xbb3b, 0xab1a,
        0x6ca6, 0x7c87, 0x4ce4, 0x5cc5, 0x2c22, 0x3c03, 0x0c60, 0x1c41,
        0xedae, 0xfd8f, 0xcdec, 0xddcd, 0xad2a, 0xbd0b, 0x8d68, 0x9d49,
        0x7e97, 0x6eb6, 0x5ed5, 0x4ef4, 0x3e13, 0x2e32, 0x1e51, 0x0e70,
        0xff9f, 0xefbe, 0xdfdd, 0xcffc, 0xbf1b, 0xaf3a, 0x9f59, 0x8f78,
        0x9188, 0x81a9, 0xb1ca, 0xa1eb, 0xd10c, 0xc12d, 0xf14e, 0xe16f,
        0x1080, 0x00a1, 0x30c2, 0x20e3, 0x5004, 0x4025, 0x7046, 0x6067,
        0x83b9, 0x9398, 0xa3fb, 0xb3da, 0xc33d, 0xd31c, 0xe37f, 0xf35e,
        0x02b1, 0x1290, 0x22f3, 0x32d2, 0x4235, 0x5214, 0x6277, 0x7256,
        0xb5ea, 0xa5cb, 0x95a8, 0x8589, 0xf56e, 0xe54f, 0xd52c, 0xc50d,
        0x34e2, 0x24c3, 0x14a0, 0x0481, 0x7466, 0x6447, 0x5424, 0x4405,
        0xa7db, 0xb7fa, 0x8799, 0x97b8, 0xe75f, 0xf77e, 0xc71d, 0xd73c,
        0x26d3, 0x36f2, 0x0691, 0x16b0, 0x6657, 0x7676, 0x4615, 0x5634,
        0xd94c, 0xc96d, 0xf90e, 0xe92f, 0x99c8, 0x89e9, 0xb98a, 0xa9ab,
        0x5844, 0x4865, 0x7806, 0x6827, 0x18c0, 0x08e1, 0x3882, 0x28a3,
        0xcb7d, 0xdb5c, 0xeb3f, 0xfb1e, 0x8bf9, 0x9bd8, 0xabbb, 0xbb9a,
        0x4a75, 0x5a54, 0x6a37, 0x7a16, 0x0af1, 0x1ad0, 0x2ab3, 0x3a92,
        0xfd2e, 0xed0f, 0xdd6c, 0xcd4d, 0xbdaa, 0xad8b, 0x9de8, 0x8dc9,
        0x7c26, 0x6c07, 0x5c64, 0x4c45, 0x3ca2, 0x2c83, 0x1ce0, 0x0cc1,
        0xef1f, 0xff3e, 0xcf5d, 0xdf7c, 0xaf9b, 0xbfba, 0x8fd9, 0x9ff8,
        0x6e17, 0x7e36, 0x4e55, 0x5e74, 0x2e93, 0x3eb2, 0x0ed1, 0x1ef0,
    };
    var crc: u16 = 0;
    for (data) |byte| {
        crc = (crc << 8) ^ table[((crc >> 8) ^ byte) & 0xFF];
    }
    return crc;
}

/// Calculate Redis cluster slot for a key
fn keySlot(key: []const u8) u16 {
    // Handle hash tags: only the part between { and } is hashed
    var start: usize = 0;
    var end: usize = key.len;
    if (std.mem.indexOfScalar(u8, key, '{')) |s| {
        if (std.mem.indexOfScalar(u8, key[s..], '}')) |e| {
            if (e > 1) {
                start = s + 1;
                end = s + e;
            }
        }
    }
    return crc16(key[start..end]) % 16384;
}

/// Redis cluster node configuration
pub const ClusterNode = struct {
    host: []const u8,
    port: u16,
};

/// Redis cluster client
pub const RedisCluster = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Redis),
    node_configs: std.ArrayList(RedisConfig),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(Redis).empty,
            .node_configs = std.ArrayList(RedisConfig).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.deinit(self.allocator);
        for (self.node_configs.items) |*cfg| {
            self.allocator.free(cfg.host);
        }
        self.node_configs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addNode(self: *Self, host: []const u8, port: u16) !void {
        const host_copy = try self.allocator.dupe(u8, host);
        const cfg = RedisConfig{ .host = host_copy, .port = port };
        try self.node_configs.append(self.allocator, cfg);
        const redis = try Redis.new(self.allocator, std.testing.io, cfg);
        try self.nodes.append(self.allocator, redis);
    }

    fn selectNode(self: *Self, key: []const u8) ?*Redis {
        if (self.nodes.items.len == 0) return null;
        if (self.nodes.items.len == 1) return &self.nodes.items[0];
        const slot = keySlot(key);
        const idx = slot % @as(u16, @intCast(self.nodes.items.len));
        return &self.nodes.items[idx];
    }

    pub fn connect(self: *Self) !void {
        for (self.nodes.items) |*node| {
            node.connect() catch |err| std.log.warn("[Redis] node connect failed: {}", .{err});
        }
    }

    pub fn get(self: *Self, key: []const u8) errors.ResultT(?[]const u8) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.get(key);
    }

    pub fn set(self: *Self, key: []const u8, value: []const u8, ex_seconds: ?u32) errors.Result {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.set(key, value, ex_seconds);
    }

    pub fn del(self: *Self, keys: []const []const u8) errors.ResultT(u32) {
        if (keys.len == 0) return 0;
        const node = self.selectNode(keys[0]) orelse return error.RedisError;
        return node.del(keys);
    }

    pub fn exists(self: *Self, key: []const u8) errors.ResultT(bool) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.exists(key);
    }

    pub fn incr(self: *Self, key: []const u8) errors.ResultT(i64) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.incr(key);
    }

    pub fn decr(self: *Self, key: []const u8) errors.ResultT(i64) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.decr(key);
    }

    pub fn expire(self: *Self, key: []const u8, seconds: u32) errors.Result {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.expire(key, seconds);
    }

    pub fn ttl(self: *Self, key: []const u8) errors.ResultT(i64) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.ttl(key);
    }

    pub fn hSet(self: *Self, key: []const u8, field: []const u8, value: []const u8) errors.ResultT(bool) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.hSet(key, field, value);
    }

    pub fn hGet(self: *Self, key: []const u8, field: []const u8) errors.ResultT(?[]const u8) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.hGet(key, field);
    }
};

/// Distributed lock helper
pub const Lock = struct {
    redis: *Redis,
    key: []const u8,
    value: []const u8,
    acquired: bool = false,

    /// Acquire a lock
    pub fn acquire(redis: *Redis, key: []const u8, value: []const u8, ttl_seconds: u32) errors.ResultT(bool) {
        return redis.lock(key, value, ttl_seconds);
    }

    /// Release a lock
    pub fn release(self: *Lock) errors.Result {
        if (self.acquired) {
            return self.redis.unlock(self.key);
        }
    }
};

// ==== §5  Tests ====

test "RedisConfig.fromUrl reads host and port from REDIS_URL" {
    const a = RedisConfig.fromUrl("redis://127.0.0.1:6379");
    try std.testing.expectEqualStrings("127.0.0.1", a.host);
    try std.testing.expectEqual(@as(u16, 6379), a.port);

    // A container's published port is the case this exists for: the tests are
    // gated on REDIS_URL, and taking only the host would silently ignore it.
    const b = RedisConfig.fromUrl("redis://10.1.2.3:16379");
    try std.testing.expectEqualStrings("10.1.2.3", b.host);
    try std.testing.expectEqual(@as(u16, 16379), b.port);

    // Credentials and a path do not end up in the host.
    const c = RedisConfig.fromUrl("redis://user:pass@192.168.1.9:6380/3");
    try std.testing.expectEqualStrings("192.168.1.9", c.host);
    try std.testing.expectEqual(@as(u16, 6380), c.port);

    // Bare address: the default port survives.
    const d = RedisConfig.fromUrl("192.168.1.9");
    try std.testing.expectEqualStrings("192.168.1.9", d.host);
    try std.testing.expectEqual(@as(u16, 6379), d.port);

    // The default config describes an address the parser accepts — the whole
    // reason it is a literal and not "localhost".
    const e = RedisConfig{};
    _ = try std.Io.net.IpAddress.parseIp4(e.host, e.port);
}

test "redis client" {
    // Requires a running Redis server; set REDIS_URL to enable (e.g. redis://127.0.0.1:6379).
    const redis_url = if (builtin.os.tag == .windows) @as(?[]const u8, null) else if (std.c.getenv("REDIS_URL")) |ptr| std.mem.span(ptr) else null;
    if (redis_url == null or redis_url.?.len == 0) return error.SkipZigTest;

    // Host *and port* come from REDIS_URL: the client resolves a literal
    // address (`RedisConfig.host`), and taking only the host would silently
    // ignore a non-default port.
    const cfg = RedisConfig.fromUrl(redis_url.?);
    var redis = try Redis.new(std.testing.allocator, std.testing.io, cfg);
    defer redis.deinit();

    try redis.connect();

    // Test basic operations
    try redis.set("test_key", "test_value", null);
    const value = try redis.get("test_key");
    try std.testing.expect(value != null);
    if (value) |v| {
        try std.testing.expectEqualStrings("test_value", v);
        std.testing.allocator.free(v);
    }

    // Test lock
    const acquired = try Lock.acquire(&redis, "test_lock", "token123", 10);
    try std.testing.expect(acquired);
}

/// Worker used by the concurrent-incr test: INCR one key, ignoring errors
/// (caller asserts the final count so any lost increment fails the test).
fn concurrentIncrWorker(r: *Redis, k: []const u8) void {
    _ = r.incr(k) catch |err| {
        std.log.debug("[redis] concurrent incr worker failed: {s}", .{@errorName(err)});
    };
}

test "redis concurrent incr" {
    // Requires a running Redis server; set REDIS_URL to enable
    // (e.g. redis://127.0.0.1:6379). Spawns many threads that concurrently
    // INCR the same key through the connection pool and asserts the final
    // value equals the thread count — i.e. no two commands ever interleave
    // on a shared socket, and the pool hands out exclusive connections.
    const redis_url = if (builtin.os.tag == .windows) @as(?[]const u8, null) else if (std.c.getenv("REDIS_URL")) |ptr| std.mem.span(ptr) else null;
    if (redis_url == null or redis_url.?.len == 0) return error.SkipZigTest;

    const raw = redis_url.?;
    const after_scheme = if (std.mem.startsWith(u8, raw, "redis://")) raw["redis://".len..] else raw;
    const host = if (std.mem.indexOfScalar(u8, after_scheme, ':')) |i| after_scheme[0..i] else after_scheme;

    const threads_n: usize = 64;
    // Pool larger than the thread count so acquireStream never exhausts.
    const cfg = RedisConfig{ .host = host, .pool_size = 128 };
    var redis = try Redis.new(std.testing.allocator, std.testing.io, cfg);
    defer redis.deinit();
    try redis.connect();

    const key = "zigmodu_concurrent_incr_test";
    _ = redis.del(&[_][]const u8{key}) catch {};

    var threads: [threads_n]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, concurrentIncrWorker, .{ &redis, key });
    }
    for (&threads) |*t| t.join();

    const final_val = try redis.get(key);
    if (final_val) |v| {
        defer std.testing.allocator.free(v);
        const parsed = std.fmt.parseInt(i64, v, 10) catch return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(i64, threads_n), parsed);
    } else {
        try std.testing.expect(false); // key should exist with value == threads_n
    }
}

test "resp protocol parsing" {
    // Test parsing RESP simple strings
    const simple_string = "+OK\r\n";
    try std.testing.expectEqualStrings("OK", simple_string[1..3]);
}

test "redis cluster slot calculation" {
    try std.testing.expectEqual(@as(u16, 12182), keySlot("foo"));
    try std.testing.expectEqual(@as(u16, 5474), keySlot("{user}:123"));
    try std.testing.expectEqual(@as(u16, 5474), keySlot("{user}:456"));
}

test "redis cluster init" {
    const allocator = std.testing.allocator;
    var cluster = RedisCluster.init(allocator);
    defer cluster.deinit();

    try cluster.addNode("127.0.0.1", 7000);
    try cluster.addNode("127.0.0.1", 7001);
    try cluster.addNode("127.0.0.1", 7002);

    try std.testing.expectEqual(@as(usize, 3), cluster.nodes.items.len);

    // Verify consistent routing for the same key
    const node1 = cluster.selectNode("mykey");
    const node2 = cluster.selectNode("mykey");
    try std.testing.expectEqual(node1, node2);
}

// ── RESP framing & single-stream locking (regression tests for the desync bug) ──

/// socketpair-based fake peer: no network permission needed, fully deterministic.
fn testPair() ?[2]std.posix.socket_t {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => fds,
        else => null,
    };
}

fn testReader(stream: std.Io.net.Stream, allocator: std.mem.Allocator, timeout_ms: u32) ReplyReader {
    return .{ .stream = stream, .io = std.testing.io, .allocator = allocator, .timeout_ms = timeout_ms };
}

/// Write a whole slice to the fake peer. Hand-counting the length for
/// `system.write` is a trap: `"$5\r\nhe"` is 6 bytes, so asking for 7 ships the
/// literal's NUL sentinel down the socket and the reader then sees a reply that
/// never came from Redis.
fn peerWriteAll(fd: std.posix.socket_t, bytes: []const u8) void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[sent..].ptr, bytes[sent..].len);
        if (std.posix.errno(rc) != .SUCCESS) return;
        const n: usize = @intCast(rc);
        if (n == 0) return;
        sent += n;
    }
}

test "readWholeReply frames a bulk value split across writes" {
    const allocator = std.testing.allocator;
    const fds = testPair() orelse return error.SkipZigTest;
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    // "$5\r\nhello\r\n" delivered in three TCP-sized bites, the body straddling
    // two of them — the old single `readSome` parse produced a truncated value
    // and left "llo\r\n" in the socket to poison the next command.
    peerWriteAll(fds[1], "$5\r\nhe");
    peerWriteAll(fds[1], "llo");
    peerWriteAll(fds[1], "\r\n");

    var reader = testReader(stream, allocator, 2000);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try readWholeReply(&reader, &out);
    try std.testing.expectEqualStrings("$5\r\nhello\r\n", out.items);
}

test "readWholeReply frames values larger than one read and nested arrays" {
    const allocator = std.testing.allocator;
    const fds = testPair() orelse return error.SkipZigTest;
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    // The peer writes from its own thread: a socketpair's buffer is far smaller
    // than the 8 KiB payload, so writing inline before anyone reads deadlocks.
    const Peer = struct {
        fn run(fd: std.posix.socket_t) void {
            const big_len = 8192;
            var header_buf: [32]u8 = undefined;
            const header = std.fmt.bufPrint(&header_buf, "${d}\r\n", .{big_len}) catch return;
            peerWriteAll(fd, header);
            var payload: [1024]u8 = @splat('x');
            var sent: usize = 0;
            while (sent < big_len) : (sent += payload.len) {
                peerWriteAll(fd, payload[0..@min(payload.len, big_len - sent)]);
            }
            peerWriteAll(fd, "\r\n");
            // Nested array (`*2` of `$-1` and `:7`) right after: the int-only
            // commands rely on arrays being framed too.
            peerWriteAll(fd, "*2\r\n$-1\r\n:7\r\n");
        }
    };
    const peer = try std.Thread.spawn(.{}, Peer.run, .{fds[1]});
    defer peer.join();

    var reader = testReader(stream, allocator, 5000);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try readWholeReply(&reader, &out);
    const header_len = "$8192\r\n".len;
    try std.testing.expectEqual(@as(usize, header_len + 8192 + 2), out.items.len);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "$8192\r\n"));
    try std.testing.expectEqual(@as(usize, 8192), std.mem.count(u8, out.items, "x"));

    var out2 = std.ArrayList(u8).empty;
    defer out2.deinit(allocator);
    try readWholeReply(&reader, &out2);
    try std.testing.expectEqualStrings("*2\r\n$-1\r\n:7\r\n", out2.items);
}

test "readWholeReply honors the read deadline instead of blocking forever" {
    const allocator = std.testing.allocator;
    const fds = testPair() orelse return error.SkipZigTest;
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    // Server accepts the command but never replies: before this, the read
    // blocked forever and the endpoint could not recover without a restart.
    var reader = testReader(stream, allocator, 120);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try std.testing.expectError(error.RedisTimeout, readWholeReply(&reader, &out));
}

test "redis concurrent incr on a single shared stream (pool_size = 1)" {
    // The production shape that failed: `pool_size = 1` means every request
    // fiber shares one socket. Before the fix that path took no lock (commands
    // interleaved: 11/60 requests got `RedisError`, then endpoints hung once the
    // byte stream desynchronised) and there was no read deadline to recover.
    // Requires a running Redis server; set REDIS_URL to enable.
    const redis_url = if (builtin.os.tag == .windows) @as(?[]const u8, null) else if (std.c.getenv("REDIS_URL")) |ptr| std.mem.span(ptr) else null;
    if (redis_url == null or redis_url.?.len == 0) return error.SkipZigTest;

    const raw = redis_url.?;
    const after_scheme = if (std.mem.startsWith(u8, raw, "redis://")) raw["redis://".len..] else raw;
    const host = if (std.mem.indexOfScalar(u8, after_scheme, ':')) |i| after_scheme[0..i] else after_scheme;

    const threads_n: usize = 32;
    const cfg = RedisConfig{ .host = host, .pool_size = 1, .read_timeout_ms = 2000 };
    var r = try Redis.new(std.testing.allocator, std.testing.io, cfg);
    defer r.deinit();
    try r.connect();

    const key = "zigmodu:test:redis:single-stream";
    _ = r.del(&.{key}) catch {};

    const threads = try std.testing.allocator.alloc(std.Thread, threads_n);
    defer std.testing.allocator.free(threads);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, concurrentIncrWorker, .{ &r, key });
    for (threads) |t| t.join();

    const final = try r.get(key);
    defer if (final) |v| std.testing.allocator.free(v);
    try std.testing.expect(final != null);
    // Every INCR must have landed: a lost update means two commands interleaved
    // on the shared socket (the bug this test exists for).
    try std.testing.expectEqualStrings("32", final.?);
    _ = r.del(&.{key}) catch {};
}

// ── "no answer" vs "the answer is X" (regression tests for fabricated values) ──

/// A client that has never connected. With `pool_size = 1` there is no pool and
/// `stream` stays null until `connect`, so `acquireStream` fails before any
/// socket is touched: the deterministic stand-in for "Redis is unreachable".
fn offlineClient() !Redis {
    return Redis.new(std.testing.allocator, std.testing.io, .{ .pool_size = 1 });
}

/// A client whose socket is the given socketpair end, so a peer can hand it a
/// canned RESP reply: "the server answered X" without a live server.
fn cannedReplyClient(fd: std.posix.socket_t) !Redis {
    var r = try Redis.new(std.testing.allocator, std.testing.io, .{ .pool_size = 1 });
    r.stream = .{ .socket = .{ .handle = fd, .address = undefined } };
    return r;
}

test "redis: an unreachable server is an error, not a data answer" {
    var r = try offlineClient();
    defer r.deinit();

    // Every one of these used to return *success* carrying the value a caller
    // reads as data — `-1` = "key exists, no expiry", `false` = "already set" /
    // "key absent" / "lock held elsewhere", `0` = "nothing deleted" — a made-up
    // answer to a question that never reached Redis.
    try std.testing.expectError(error.RedisError, r.ttl("k"));
    try std.testing.expectError(error.RedisError, r.setNX("k", "v"));
    try std.testing.expectError(error.RedisError, r.del(&.{"k"}));
    try std.testing.expectError(error.RedisError, r.exists("k"));
    try std.testing.expectError(error.RedisError, r.lock("k", "v", 5));
    try std.testing.expectError(error.RedisError, r.unlock("k"));

    // Control group: commands that already propagated the very same failure.
    try std.testing.expectError(error.RedisError, r.get("k"));
    try std.testing.expectError(error.RedisError, r.set("k", "v", null));
    try std.testing.expectError(error.RedisError, r.incr("k"));
    try std.testing.expectError(error.RedisError, r.hSet("k", "f", "v"));
    try std.testing.expectError(error.RedisError, r.publish("c", "m"));

    // ...while a request that asks for nothing still answers 0 deleted: the
    // empty list is a decision, not an unreachable server.
    try std.testing.expectEqual(@as(u32, 0), try r.del(&.{}));
}

test "redis: a server reply is data, a server error reply is not" {
    const fds = testPair() orelse return error.SkipZigTest;
    var r = try cannedReplyClient(fds[0]);
    defer r.deinit(); // closes fds[0] unless a command already evicted it
    defer _ = std.posix.system.close(fds[1]);

    // In-protocol answers stay values: TTL -1 is "exists, no expiry", -2 is
    // "no such key" — the server talking, not us guessing.
    peerWriteAll(fds[1], ":-1\r\n");
    try std.testing.expectEqual(@as(i64, -1), try r.ttl("k"));
    peerWriteAll(fds[1], ":-2\r\n");
    try std.testing.expectEqual(@as(i64, -2), try r.ttl("k"));

    // SETNX: 1 = we took it, 0 = someone else holds it.
    peerWriteAll(fds[1], ":1\r\n");
    try std.testing.expect(try r.setNX("k", "v"));
    peerWriteAll(fds[1], ":0\r\n");
    try std.testing.expect(!try r.setNX("k", "v"));

    // EXISTS / DEL / HSET return counts.
    peerWriteAll(fds[1], ":1\r\n");
    try std.testing.expect(try r.exists("k"));
    peerWriteAll(fds[1], ":0\r\n");
    try std.testing.expect(!try r.exists("k"));
    peerWriteAll(fds[1], ":2\r\n");
    try std.testing.expectEqual(@as(u32, 2), try r.del(&.{"a"}));
    peerWriteAll(fds[1], ":1\r\n");
    try std.testing.expect(try r.hSet("k", "f", "v"));

    // SET NX PX answers +OK when the lock is ours and a nil bulk when it is not.
    peerWriteAll(fds[1], "+OK\r\n");
    try std.testing.expect(try r.lock("k", "v", 5));
    peerWriteAll(fds[1], "$-1\r\n");
    try std.testing.expect(!try r.lock("k", "v", 5));

    // A `-ERR` reply is the server refusing the command, not an answer to it.
    // These were the sharpest lies: each one came back as plausible data.
    peerWriteAll(fds[1], "-ERR wrong number of arguments for 'ttl' command\r\n");
    try std.testing.expectError(error.RedisError, r.ttl("k"));
    peerWriteAll(fds[1], "-ERR wrong number of arguments for 'setnx' command\r\n");
    try std.testing.expectError(error.RedisError, r.setNX("k", "v"));
    peerWriteAll(fds[1], "-ERR wrong number of arguments for 'del' command\r\n");
    try std.testing.expectError(error.RedisError, r.del(&.{"k"}));
    peerWriteAll(fds[1], "-ERR wrong number of arguments for 'exists' command\r\n");
    try std.testing.expectError(error.RedisError, r.exists("k"));
    peerWriteAll(fds[1], "-ERR wrong number of arguments for 'hset' command\r\n");
    try std.testing.expectError(error.RedisError, r.hSet("k", "f", "v"));
    peerWriteAll(fds[1], "-ERR wrong number of arguments for 'set' command\r\n");
    try std.testing.expectError(error.RedisError, r.lock("k", "v", 5));
    peerWriteAll(fds[1], "-ERR wrong number of arguments for 'del' command\r\n");
    try std.testing.expectError(error.RedisError, r.unlock("k"));
}

test "redis: real server answers arrive as data (TTL -1, SETNX false)" {
    // The other half of the distinction, against a live server: a genuine -1
    // from TTL must still be -1, and a genuine false from SETNX/SET NX must
    // still be false.
    const redis_url = if (builtin.os.tag == .windows) @as(?[]const u8, null) else if (std.c.getenv("REDIS_URL")) |ptr| std.mem.span(ptr) else null;
    if (redis_url == null or redis_url.?.len == 0) return error.SkipZigTest;

    var r = try Redis.new(std.testing.allocator, std.testing.io, RedisConfig.fromUrl(redis_url.?));
    defer r.deinit();
    try r.connect();

    const key = "zigmodu:test:redis:answers-are-data";
    const lock_key = "zigmodu:test:redis:answers-are-data:lock";
    const absent = "zigmodu:test:redis:definitely-absent";
    _ = r.del(&.{ key, lock_key }) catch {};

    try r.set(key, "v", null);
    // No expiry set: the server says -1, and that is an answer.
    try std.testing.expectEqual(@as(i64, -1), try r.ttl(key));
    try std.testing.expectEqual(@as(i64, -2), try r.ttl(absent));

    try std.testing.expect(!try r.setNX(key, "other"));
    _ = r.del(&.{key}) catch {};
    try std.testing.expect(try r.setNX(key, "first"));

    try std.testing.expectEqual(@as(u32, 0), try r.del(&.{absent}));

    // The second acquire losing is a value, not a failure.
    try std.testing.expect(try r.lock(lock_key, "t1", 5));
    try std.testing.expect(!try r.lock(lock_key, "t2", 5));
    try r.unlock(lock_key);

    _ = r.del(&.{ key, lock_key }) catch {};
}
