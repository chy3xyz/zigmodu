const std = @import("std");

/// RFC 6455 data-frame kind (opcodes 0x1 / 0x2).
pub const WsFrameKind = enum {
    text,
    binary,

    pub fn fromOpcode(raw: u8) ?WsFrameKind {
        return switch (raw) {
            0x1 => .text,
            0x2 => .binary,
            else => null,
        };
    }

    pub fn opcode(self: WsFrameKind) u8 {
        return switch (self) {
            .text => 0x1,
            .binary => 0x2,
        };
    }
};

/// Minimal WebSocket frame reader/writer.
const sockread = @import("../core/sockread.zig");

pub const WsFramer = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    /// Optional pre-allocated write buffer for frame output.
    /// Retained for API compatibility; writeFrame now emits via one `writev`.
    write_buf: ?[]u8 = null,
    /// Persistent read buffer so frame header/mask/payload come from one
    /// syscall instead of one per field.
    read_buf: [8192]u8 = undefined,
    reader: ?sockread.Reader = null,

    pub fn init(stream: std.Io.net.Stream, io: std.Io) WsFramer {
        return .{ .stream = stream, .io = io };
    }

    pub fn setWriteBuffer(self: *WsFramer, buf: []u8) void {
        self.write_buf = buf;
    }

    /// `Sec-WebSocket-Accept` for `ws_key` (RFC 6455 §4.2.2):
    /// `base64(SHA-1(key ++ the magic GUID))`.
    ///
    /// Pure on purpose: this is the one handshake step whose input is the
    /// attacker-controlled header, so it has to be testable without a socket.
    pub fn acceptKey(ws_key: []const u8) [28]u8 {
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(ws_key);
        sha1.update(magic);
        var digest: [20]u8 = undefined;
        sha1.final(&digest);
        var out: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&out, &digest);
        return out;
    }

    /// RFC 6455 handshake (one-shot).
    pub fn handshake(self: *WsFramer, ws_key: []const u8) !void {
        // **No `hash_input` buffer.** It used to be a `[128]u8` on the stack that
        // `ws_key` was `@memcpy`d into — and `ws_key` is an attacker-controlled
        // request header (bounded only by the 16 KB header limit), while the
        // upgrade is answered *before* `router.match` and before every middleware
        // (docs/RUNTIME.md §12.14). So a 93-byte key wrote past the frame without
        // any credential: panic/abort in a safe build, a stack overwrite in
        // ReleaseFast. SHA-1 is incremental, so the buffer is not needed at all —
        // feeding the two slices removes the class rather than guarding one
        // instance, and no legitimate key's behaviour changes.
        const accept_key = acceptKey(ws_key);

        var buf: [256]u8 = undefined;
        const response = try std.fmt.bufPrint(&buf, "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n", .{accept_key});

        var write_buf: [512]u8 = undefined;
        var w = self.stream.writer(self.io, &write_buf);
        try w.interface.writeAll(response);
        try w.interface.flush();
    }

    pub const Frame = struct {
        opcode: u8,
        payload: []u8,
        payload_len: usize,
    };

    /// Read one WebSocket frame. `buf` must be at least 4KB (caller provided).
    pub fn readFrame(self: *WsFramer, buf: []u8) !Frame {
        var header: [2]u8 = undefined;
        try self.readFull(&header);

        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var payload_len: usize = header[1] & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try self.readFull(&ext);
            payload_len = @intCast(std.mem.readInt(u16, &ext, .big));
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try self.readFull(&ext);
            payload_len = @intCast(std.mem.readInt(u64, &ext, .big));
        }

        var mask_key: [4]u8 = undefined;
        if (masked) {
            try self.readFull(&mask_key);
        }

        if (payload_len > buf.len) return error.PayloadTooLarge;
        try self.readFull(buf[0..payload_len]);

        if (masked) {
            for (buf[0..payload_len], 0..) |*b, i| {
                b.* ^= mask_key[i % 4];
            }
        }

        return .{ .opcode = opcode, .payload = buf[0..payload_len], .payload_len = payload_len };
    }

    fn readFull(self: *WsFramer, out: []u8) !void {
        if (self.reader == null) {
            self.reader = sockread.Reader.init(self.stream, &self.read_buf);
        }
        try self.reader.?.readFull(out);
    }

    /// Write a text frame.
    pub fn writeText(self: *WsFramer, payload: []const u8) !void {
        try self.writeFrame(0x1, payload);
    }

    /// Write a binary frame (e.g. protobuf / OpenIM wire).
    pub fn writeBinary(self: *WsFramer, payload: []const u8) !void {
        try self.writeFrame(0x2, payload);
    }

    /// Write a data frame by kind.
    pub fn writeData(self: *WsFramer, kind: WsFrameKind, payload: []const u8) !void {
        try self.writeFrame(kind.opcode(), payload);
    }

    /// Write an arbitrary frame. Uses pre-allocated write_buf if set.
    pub fn writeFrame(self: *WsFramer, opcode: u8, payload: []const u8) !void {
        var header: [14]u8 = undefined;
        var header_len: usize = 2;
        header[0] = 0x80 | opcode;

        if (payload.len < 126) {
            header[1] = @intCast(payload.len);
        } else if (payload.len < 65536) {
            header[1] = 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header[1] = 127;
            std.mem.writeInt(u64, header[2..10], @intCast(payload.len), .big);
            header_len = 10;
        }

        // Header + payload in one syscall (writev).
        // On a send-timeout we also shut the socket down: a peer that stopped
        // reading will not send anything either, so the read loop would
        // otherwise sit on this connection forever.
        sockread.writevAll(self.stream, &.{ header[0..header_len], payload }) catch |err| {
            if (err == error.WriteTimeout) {
                _ = std.c.shutdown(self.stream.socket.handle, std.c.SHUT.RDWR);
            }
            return err;
        };
    }

    /// Bound blocking writes on this socket (0 = unbounded, the default).
    pub fn setSendTimeout(self: *WsFramer, timeout_ms: u32) void {
        sockread.setSendTimeout(self.stream, timeout_ms);
    }

    /// O(1) probe of the kernel send buffer. `true` does not guarantee a large
    /// payload won't block — it is a cheap "is this peer keeping up?" signal so
    /// fan-out code can drop frames instead of stalling.
    pub fn isWritable(self: *WsFramer) bool {
        var pfds = [1]std.posix.pollfd{.{
            .fd = self.stream.socket.handle,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        return (std.posix.poll(&pfds, 0) catch 0) > 0;
    }

    /// Write a pong frame.
    pub fn writePong(self: *WsFramer, payload: []const u8) !void {
        try self.writeFrame(0xA, payload);
    }

    /// Write a close frame.
    pub fn writeClose(self: *WsFramer) !void {
        try self.writeFrame(0x8, &.{});
    }
};

test "WsFrameKind opcode roundtrip" {
    try std.testing.expectEqual(@as(u8, 0x1), WsFrameKind.text.opcode());
    try std.testing.expectEqual(@as(u8, 0x2), WsFrameKind.binary.opcode());
    try std.testing.expect(WsFrameKind.fromOpcode(0x1).? == .text);
    try std.testing.expect(WsFrameKind.fromOpcode(0x2).? == .binary);
    try std.testing.expect(WsFrameKind.fromOpcode(0x8) == null);
}

test "handshake: the accept key is the RFC's vector, and a long key is not an overflow" {
    // RFC 6455 §1.3's own example vector.
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &WsFramer.acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));

    // `Sec-WebSocket-Key` is an attacker-controlled request header, bounded only by
    // the 16 KB header limit, and the upgrade is answered before `router.match` and
    // before every middleware (docs/RUNTIME.md §12.14) — so this is a pre-auth path.
    // It used to `@memcpy` the key into a `[128]u8`, and any key longer than 92 bytes
    // wrote past that frame. Reaching the assertion is the fix.
    var long: [1024]u8 = @splat('A');
    const accepted = WsFramer.acceptKey(&long);
    try std.testing.expectEqual(@as(usize, 28), accepted.len);
    try std.testing.expectEqual(@as(u8, '='), accepted[27]);
}

test "write with and without buffer" {
    _ = WsFramer.init(undefined, undefined);
}
