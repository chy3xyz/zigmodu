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
        /// FIN bit (RFC 6455 §5.2). A data frame with `fin == false` is the first
        /// fragment of a message and must not be delivered to `on_message` as-is.
        fin: bool,
        payload: []u8,
        payload_len: usize,
    };

    /// Read one masked client frame. `buf` must be at least 4KB (caller provided).
    ///
    /// The header is validated before the payload is touched, and each illegal
    /// shape gets its own error so callers can close the connection instead of
    /// silently handing truncated data to the application:
    ///   * `error.ReservedBitsSet` — no extension is negotiated, so RSV1-3 must be 0.
    ///   * `error.UnmaskedClientFrame` — RFC 6455 §5.1: a server MUST close the
    ///     connection on a client frame without the MASK bit.
    ///   * `error.UnknownOpcode` — opcodes other than 0x0-0x2 and 0x8-0xA.
    ///   * `error.ControlFrameTooLarge` / `error.FragmentedControlFrame` —
    ///     control frames carry ≤ 125 bytes and are never fragmented (§5.5).
    ///   * `error.PayloadTooLarge` — the single frame does not fit `buf`.
    ///
    /// Fragmented messages are reassembled by `MessageReader`, not here.
    pub fn readFrame(self: *WsFramer, buf: []u8) !Frame {
        var header: [2]u8 = undefined;
        try self.readFull(&header);

        const opcode = header[0] & 0x0F;
        const fin = (header[0] & 0x80) != 0;

        if (header[0] & 0x70 != 0) return error.ReservedBitsSet;
        if (header[1] & 0x80 == 0) return error.UnmaskedClientFrame;

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

        // Masking is mandatory for clients, so the key is always present.
        var mask_key: [4]u8 = undefined;
        try self.readFull(&mask_key);

        switch (opcode) {
            0x0, 0x1, 0x2, 0x8, 0x9, 0xA => {},
            else => return error.UnknownOpcode,
        }
        if (opcode >= 0x8) {
            if (payload_len > 125) return error.ControlFrameTooLarge;
            if (!fin) return error.FragmentedControlFrame;
        }

        if (payload_len > buf.len) return error.PayloadTooLarge;
        try self.readFull(buf[0..payload_len]);

        for (buf[0..payload_len], 0..) |*b, i| {
            b.* ^= mask_key[i % 4];
        }

        return .{ .opcode = opcode, .fin = fin, .payload = buf[0..payload_len], .payload_len = payload_len };
    }

    fn readFull(self: *WsFramer, out: []u8) !void {
        if (self.reader == null) {
            self.reader = sockread.Reader.init(self.stream, &self.read_buf);
        }
        try self.reader.?.readFull(out);
    }

    /// Cap on a reassembled message. 1 MiB matches `NetworkTransport.MAX_MESSAGE_SIZE`.
    pub const max_message_bytes: usize = 1 << 20;

    pub const Event = union(enum) {
        /// `payload` is valid until the next `read` — it points at the caller's `buf`
        /// for a single-frame message, and at the reader's own reassembly buffer for a
        /// reassembled one.
        message: struct { kind: WsFrameKind, payload: []u8 },
        /// The peer sent a close frame (or the connection is at its end).
        close,
    };

    /// Reassembles fragmented messages and services interleaved control frames, so
    /// callers never see a partial message. Carries no inline buffer: `frag` grows
    /// from the heap only for messages that actually arrive fragmented.
    pub const MessageReader = struct {
        framer: *WsFramer,
        allocator: std.mem.Allocator,
        frag: std.ArrayList(u8) = .empty,
        open_kind: ?WsFrameKind = null,

        pub fn init(framer: *WsFramer, allocator: std.mem.Allocator) MessageReader {
            return .{ .framer = framer, .allocator = allocator };
        }

        pub fn deinit(self: *MessageReader) void {
            self.frag.deinit(self.allocator);
        }

        /// Best-effort close before handing a protocol error to the caller: the peer
        /// deserves a reason even if we cannot deliver one. Logged, not swallowed —
        /// `scripts/check-production.sh` bans bare `catch {}` exactly so a failure
        /// cannot hide on this path. This covers the five protocol-error returns
        /// below (`readFrame`'s violations plus this reader's two).
        fn closeForProtocolError(self: *MessageReader) void {
            self.framer.writeClose() catch |err| {
                std.log.debug("[ws] could not send a close frame for a protocol error ({})", .{err});
            };
        }

        pub fn read(self: *MessageReader, buf: []u8) !Event {
            while (true) {
                const frame = self.framer.readFrame(buf) catch |err| switch (err) {
                    // Protocol violations: tell the peer why before the caller
                    // drops the connection, instead of leaving it to a bare RST.
                    error.ReservedBitsSet,
                    error.UnmaskedClientFrame,
                    error.UnknownOpcode,
                    error.ControlFrameTooLarge,
                    error.FragmentedControlFrame,
                    error.PayloadTooLarge,
                    => {
                        self.closeForProtocolError();
                        return err;
                    },
                    else => return err, // I/O — the socket is gone, nothing to send
                };

                if (frame.opcode >= 0x8) {
                    // `readFrame` already rejected the illegal control shapes.
                    switch (frame.opcode) {
                        0x8 => return .close,
                        0x9 => try self.framer.writePong(frame.payload),
                        else => {}, // 0xA pong — nothing to track
                    }
                    continue;
                }

                switch (frame.opcode) {
                    0x1, 0x2 => {
                        const kind = WsFrameKind.fromOpcode(frame.opcode).?;
                        if (self.open_kind != null) {
                            self.closeForProtocolError();
                            return error.UnexpectedDataFrame;
                        }
                        if (frame.fin) {
                            // Common case: one frame, one message — no copy.
                            return .{ .message = .{ .kind = kind, .payload = frame.payload } };
                        }
                        if (frame.payload_len > max_message_bytes) {
                            self.closeForProtocolError();
                            return error.MessageTooLarge;
                        }
                        self.frag.clearRetainingCapacity();
                        try self.frag.appendSlice(self.allocator, frame.payload);
                        self.open_kind = kind;
                    },
                    0x0 => {
                        const kind = self.open_kind orelse {
                            self.closeForProtocolError();
                            return error.UnexpectedContinuation;
                        };
                        if (self.frag.items.len + frame.payload_len > max_message_bytes) {
                            self.closeForProtocolError();
                            return error.MessageTooLarge;
                        }
                        try self.frag.appendSlice(self.allocator, frame.payload);
                        if (frame.fin) {
                            self.open_kind = null;
                            return .{ .message = .{ .kind = kind, .payload = self.frag.items } };
                        }
                    },
                    // `readFrame` only returns the opcodes it whitelisted, and the
                    // control ones were handled above, so this is 0x0/0x1/0x2 in
                    // full. Kept as an explicit error rather than `unreachable`:
                    // `unreachable` is UB in ReleaseFast, so if that whitelist is
                    // ever widened this would silently become a bad path instead of
                    // a compile error or a rejected frame.
                    else => return error.UnknownOpcode,
                }
            }
        }
    };

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

/// One end of a `socketpair`, so a test can push raw client bytes in and read
/// server bytes back. `null` means the platform refused `socketpair` (the caller
/// then `return error.SkipZigTest`, same as `core/sockread.zig`).
const SocketPair = struct {
    fd: std.posix.socket_t,
    stream: std.Io.net.Stream,

    fn open() ?SocketPair {
        var fds: [2]std.posix.socket_t = undefined;
        const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            else => return null,
        }
        return .{
            .fd = fds[1],
            .stream = .{ .socket = .{ .handle = fds[0], .address = undefined } },
        };
    }

    fn deinit(self: *SocketPair) void {
        self.stream.close(std.testing.io);
        _ = std.posix.system.close(self.fd);
    }

    /// Write raw bytes as the client (i.e. into the server's read direction).
    fn send(self: *SocketPair, bytes: []const u8) void {
        _ = std.posix.system.write(self.fd, bytes.ptr, bytes.len);
    }

    /// Read what the server wrote back.
    fn recv(self: *SocketPair, out: []u8) usize {
        return std.posix.read(self.fd, out) catch 0;
    }
};

/// The wire shape of one frame; named so the tests read as protocol, not as bits.
const TestFrame = struct {
    opcode: u8,
    fin: bool = true,
    masked: bool = true,
    /// RSV1-3 as the raw 0x70 bits (0 = RFC-compliant for a client with no extension).
    rsv: u8 = 0,
};

const test_mask_key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };

/// Serialize one frame per RFC 6455 §5.2/§5.3. `out` must be large enough.
fn buildFrame(out: []u8, spec: TestFrame, payload: []const u8) []u8 {
    var n: usize = 0;
    out[0] = spec.rsv | (if (spec.fin) @as(u8, 0x80) else 0) | spec.opcode;
    const mask_bit: u8 = if (spec.masked) 0x80 else 0;
    if (payload.len < 126) {
        out[1] = mask_bit | @as(u8, @intCast(payload.len));
        n = 2;
    } else if (payload.len < 65536) {
        out[1] = mask_bit | 126;
        std.mem.writeInt(u16, out[2..4], @intCast(payload.len), .big);
        n = 4;
    } else {
        out[1] = mask_bit | 127;
        std.mem.writeInt(u64, out[2..10], @intCast(payload.len), .big);
        n = 10;
    }
    if (spec.masked) {
        @memcpy(out[n..][0..4], &test_mask_key);
        n += 4;
    }
    for (payload, 0..) |b, i| out[n + i] = if (spec.masked) b ^ test_mask_key[i % 4] else b;
    return out[0 .. n + payload.len];
}

/// A framer + reader over one end of a socketpair. Frames sent through `pair` are
/// consumed by `reader`. `init` takes a pointer because the reader points at
/// `framer` — a by-value return would leave it pointing into the callee's frame.
const Wire = struct {
    pair: SocketPair,
    framer: WsFramer = undefined,
    reader: WsFramer.MessageReader = undefined,

    fn init(self: *Wire) !void {
        self.pair = SocketPair.open() orelse return error.SkipZigTest;
        self.framer = WsFramer.init(self.pair.stream, std.testing.io);
        self.reader = WsFramer.MessageReader.init(&self.framer, std.testing.allocator);
    }

    fn deinit(self: *Wire) void {
        self.reader.deinit();
        self.pair.deinit();
    }
};

test "MessageReader: one masked text frame is one message, with the frame's payload" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    var wire: [64]u8 = undefined;
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x1 }, "hello"));

    var buf: [4096]u8 = undefined;
    const event = try w.reader.read(&buf);
    try std.testing.expect(event == .message);
    try std.testing.expectEqual(WsFrameKind.text, event.message.kind);
    try std.testing.expectEqualStrings("hello", event.message.payload);
}

test "MessageReader: a fragmented text message arrives as ONE reassembled message" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    // RFC 6455 §5.4: FIN=0 first fragment, then FIN=1 continuation (opcode 0x0).
    // Pre-fix the loop delivered the first fragment as the whole message and
    // dropped the continuation, so a compliant client's data arrived truncated.
    var wire: [64]u8 = undefined;
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x1, .fin = false }, "Hel"));
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x0 }, "lo"));

    var buf: [4096]u8 = undefined;
    const event = try w.reader.read(&buf);
    try std.testing.expect(event == .message);
    try std.testing.expectEqual(WsFrameKind.text, event.message.kind);
    try std.testing.expectEqualStrings("Hello", event.message.payload);
}

test "MessageReader: an interleaved ping is ponged and the message still reassembles" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    var wire: [64]u8 = undefined;
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x1, .fin = false }, "Hel"));
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x9 }, "p"));
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x0 }, "lo"));

    var buf: [4096]u8 = undefined;
    const event = try w.reader.read(&buf);
    try std.testing.expectEqualStrings("Hello", event.message.payload);

    // The pong is read off the peer's socket: unmasked server frame, opcode 0xA,
    // echoing the ping's payload.
    var pong: [16]u8 = undefined;
    const n = w.pair.recv(&pong);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u8, 0x8A), pong[0]);
    try std.testing.expectEqual(@as(u8, 0x01), pong[1]);
    try std.testing.expectEqualStrings("p", pong[2..3]);
}

test "MessageReader: a continuation with no open message is a protocol error" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    var wire: [64]u8 = undefined;
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x0 }, "orphan"));

    var buf: [4096]u8 = undefined;
    try std.testing.expectError(error.UnexpectedContinuation, w.reader.read(&buf));
}

test "MessageReader: a close frame reports .close" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    var wire: [64]u8 = undefined;
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x8 }, ""));

    var buf: [4096]u8 = undefined;
    try std.testing.expect((try w.reader.read(&buf)) == .close);
}

test "readFrame: an unmasked client frame is rejected (RFC 6455 §5.1)" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    var wire: [64]u8 = undefined;
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x1, .masked = false }, "hi"));

    var buf: [4096]u8 = undefined;
    try std.testing.expectError(error.UnmaskedClientFrame, w.reader.read(&buf));
}

test "readFrame: RSV1 without a negotiated extension is rejected" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    var wire: [64]u8 = undefined;
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x1, .rsv = 0x40 }, "hi"));

    var buf: [4096]u8 = undefined;
    try std.testing.expectError(error.ReservedBitsSet, w.reader.read(&buf));
}

test "readFrame: a control frame carries at most 125 bytes (RFC 6455 §5.5)" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    var wire: [256]u8 = undefined;
    var payload: [126]u8 = @splat('x');
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x9 }, &payload));

    var buf: [4096]u8 = undefined;
    try std.testing.expectError(error.ControlFrameTooLarge, w.reader.read(&buf));
}

test "readFrame: an unknown opcode is rejected" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    var wire: [64]u8 = undefined;
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x3 }, "hi"));

    var buf: [4096]u8 = undefined;
    try std.testing.expectError(error.UnknownOpcode, w.reader.read(&buf));
}

test "writeFrame emits one unmasked server frame" {
    var pair = SocketPair.open() orelse return error.SkipZigTest;
    defer pair.deinit();

    var framer = WsFramer.init(pair.stream, std.testing.io);
    var write_buf: [64]u8 = undefined;
    framer.setWriteBuffer(&write_buf);
    try framer.writeText("hi");

    var out: [16]u8 = undefined;
    const n = pair.recv(&out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u8, 0x81), out[0]); // FIN + text
    try std.testing.expectEqual(@as(u8, 0x02), out[1]); // unmasked, len 2
    try std.testing.expectEqualStrings("hi", out[2..4]);
}
