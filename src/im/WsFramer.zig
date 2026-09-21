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

/// RFC 6455 §5.1/§5.2/§5.5 violations a frame *header* can carry — one error
/// per rule, so a caller names the reason instead of closing silently.
pub const HeaderError = error{
    /// RSV1-3 set with no extension negotiated (§5.2).
    ReservedBitsSet,
    /// MASK clear on a client frame — a server MUST close the connection (§5.1).
    UnmaskedClientFrame,
    /// Opcode outside `{0x0, 0x1, 0x2, 0x8, 0x9, 0xA}` (§5.2).
    UnknownOpcode,
    /// A control frame carrying more than 125 bytes (§5.5).
    ControlFrameTooLarge,
    /// A control frame with FIN clear — control frames are never fragmented (§5.5).
    FragmentedControlFrame,
};

/// The frame-header negative paths, in **one** place.
///
/// Two parsers read WebSocket frames in this repo: `WsFramer.readFrame` (the
/// fiber path in `api/Server.zig`) and `ws_uring`'s `parseFrame` (the io_uring
/// path, Linux only). They used to be two hand-written copies of the same byte
/// arithmetic, so hardening one left the other accepting unmasked, RSV-set,
/// unknown-opcode and fragmented-control frames — the two drift by
/// construction. This is the shared rule set; both call it, neither restates it.
///
/// `header` is the frame's first two bytes and `payload_len` the length already
/// decoded from the 126/127 extended forms — all these rules need. Pure,
/// allocation-free, no I/O: testable without a socket.
pub fn validateFrameHeader(header: [2]u8, payload_len: u64) HeaderError!void {
    // §5.2: no extension is ever negotiated, so RSV1-3 must be zero.
    if (header[0] & 0x70 != 0) return error.ReservedBitsSet;
    // §5.1: a client frame without the MASK bit is a protocol error.
    if (header[1] & 0x80 == 0) return error.UnmaskedClientFrame;

    const opcode = header[0] & 0x0F;
    switch (opcode) {
        0x0, 0x1, 0x2, 0x8, 0x9, 0xA => {},
        else => return error.UnknownOpcode,
    }

    if (opcode >= 0x8) {
        if (payload_len > 125) return error.ControlFrameTooLarge;
        if (header[0] & 0x80 == 0) return error.FragmentedControlFrame;
    }
}

/// RFC 6455 §8.1: a text message that is not valid UTF-8 MUST fail the
/// connection (close 1007) — it must never reach `on_message`.
fn validateUtf8(payload: []const u8) error{InvalidUtf8}!void {
    if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidUtf8;
}

/// RFC 6455 §7.4.1 close code for a message-level violation.
fn closeCodeFor(err: WsFramer.Assembler.Error) u16 {
    return switch (err) {
        error.InvalidUtf8 => WsFramer.CloseCode.invalid_payload, // 1007
        error.MessageTooLarge => WsFramer.CloseCode.message_too_big, // 1009
        else => WsFramer.CloseCode.protocol_error, // 1002
    };
}

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

    /// Read one masked client frame.
    ///
    /// `buf` is the caller's fast-path buffer — in `api/Server.zig` that is a
    /// 4 KiB pooled allocation, and a frame that fits is read straight into it
    /// with no allocation at all. A frame *larger* than `buf` up to
    /// `max_message_bytes` is read into `overflow` (caller-owned, grown on
    /// first use) instead of failing: a single legal 10 KiB frame used to come
    /// back as `error.PayloadTooLarge` and silently drop the connection even
    /// though the cap is 1 MiB. `null` keeps the strict old behaviour.
    ///
    /// The caller's slice is never resized, so `BufferPool.release` still gets
    /// back exactly what it handed out.
    ///
    /// The header is validated — by the shared `validateFrameHeader` — before
    /// the payload is touched, and each illegal shape gets its own error so
    /// callers can close the connection instead of silently handing truncated
    /// data to the application:
    ///   * `error.ReservedBitsSet` — no extension is negotiated, so RSV1-3 must be 0.
    ///   * `error.UnmaskedClientFrame` — RFC 6455 §5.1: a server MUST close the
    ///     connection on a client frame without the MASK bit.
    ///   * `error.UnknownOpcode` — opcodes other than 0x0-0x2 and 0x8-0xA.
    ///   * `error.ControlFrameTooLarge` / `error.FragmentedControlFrame` —
    ///     control frames carry ≤ 125 bytes and are never fragmented (§5.5).
    ///   * `error.PayloadTooLarge` — the frame is above `max_message_bytes` (or
    ///     above `buf.len` with no `overflow`).
    ///
    /// Fragmented messages are reassembled by `MessageReader`, not here.
    pub fn readFrame(self: *WsFramer, buf: []u8, overflow: ?*OversizeBuf) !Frame {
        var header: [2]u8 = undefined;
        try self.readFull(&header);

        const opcode = header[0] & 0x0F;
        const fin = (header[0] & 0x80) != 0;

        var payload_len: usize = header[1] & 0x7F;
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try self.readFull(&ext);
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try self.readFull(&ext);
            // The length field is 64 bits and `usize` is not, on 32-bit
            // targets. `@intCast` here would be a panic in a safe build and a
            // truncation in ReleaseFast; the cap has to be applied to the wire
            // value, before it becomes an index or an allocation size.
            const wire_len = std.mem.readInt(u64, &ext, .big);
            payload_len = std.math.cast(usize, wire_len) orelse return error.PayloadTooLarge;
        }

        try validateFrameHeader(header, payload_len);

        // Masking is mandatory for clients (validated above), so the key is
        // always present.
        var mask_key: [4]u8 = undefined;
        try self.readFull(&mask_key);

        var dest = buf;
        if (payload_len > dest.len) {
            // The bound first: `payload_len` is a field straight off the wire
            // and must never size an allocation before it is checked.
            if (payload_len > max_message_bytes) return error.PayloadTooLarge;
            const growable = overflow orelse return error.PayloadTooLarge;
            dest = try growable.reserve(payload_len);
        }

        try self.readFull(dest[0..payload_len]);

        for (dest[0..payload_len], 0..) |*b, i| {
            b.* ^= mask_key[i % 4];
        }

        return .{ .opcode = opcode, .fin = fin, .payload = dest[0..payload_len], .payload_len = payload_len };
    }

    fn readFull(self: *WsFramer, out: []u8) !void {
        if (self.reader == null) {
            self.reader = sockread.Reader.init(self.stream, &self.read_buf);
        }
        try self.reader.?.readFull(out);
    }

    /// Cap on a reassembled message. 1 MiB matches `NetworkTransport.MAX_MESSAGE_SIZE`.
    pub const max_message_bytes: usize = 1 << 20;

    /// Read destination for a frame larger than the caller's fast-path buffer.
    ///
    /// `readFrame`'s `buf` argument is the connection's 4 KiB pooled buffer
    /// (`api/Server.zig`), so every frame above 4 KiB used to come back as
    /// `error.PayloadTooLarge` and drop the connection — even though
    /// `max_message_bytes` is 1 MiB. The buffer grows here instead: the common
    /// path allocates nothing, and a connection that never sees a big frame owns
    /// nothing. Capacity is retained after use (the same choice `Assembler.frag`
    /// makes) and bounded by `max_message_bytes`, so the per-connection ceiling
    /// does not move.
    pub const OversizeBuf = struct {
        allocator: std.mem.Allocator,
        data: ?[]u8 = null,

        pub fn deinit(self: *OversizeBuf) void {
            if (self.data) |d| self.allocator.free(d);
            self.data = null;
        }

        /// A slice of at least `n` bytes. Capacity is rounded up to a power of
        /// two so a peer cannot force one allocation per frame by ratcheting
        /// the declared length up a byte at a time.
        fn reserve(self: *OversizeBuf, n: usize) ![]u8 {
            if (self.data) |d| {
                if (d.len >= n) return d[0..n];
            }
            const capacity = std.math.ceilPowerOfTwo(usize, n) catch n;
            const fresh = try self.allocator.alloc(u8, capacity);
            if (self.data) |d| self.allocator.free(d);
            self.data = fresh;
            return fresh[0..n];
        }
    };

    /// Close codes this server originates (RFC 6455 §7.4.1).
    pub const CloseCode = struct {
        /// 1002 — a malformed frame.
        pub const protocol_error: u16 = 1002;
        /// 1007 — a text message that is not valid UTF-8.
        pub const invalid_payload: u16 = 1007;
        /// 1009 — a message above `max_message_bytes`.
        pub const message_too_big: u16 = 1009;
    };

    pub const Event = union(enum) {
        /// `payload` is valid until the next `read` — it points at the caller's `buf`
        /// for a single-frame message, and at the reader's own reassembly buffer for a
        /// reassembled one.
        message: struct { kind: WsFrameKind, payload: []u8 },
        /// The peer sent a close frame (or the connection is at its end).
        close,
    };

    /// Fragment/FIN state machine, shared by **both** parsers.
    ///
    /// "Deliver the first fragment as the whole message, drop the continuation"
    /// is a silent truncation: a compliant client's protobuf/JSON arrives cut in
    /// half with no error anywhere. `WsFramer` had that defect and the io_uring
    /// parser reproduced it, so the rule lives here once and both drive it:
    /// `MessageReader` for the fiber path, `ws_uring.WsUring.processData` for
    /// the io_uring path.
    ///
    /// It also owns the two rules that cannot be decided on a single fragment:
    ///   * `max_message_bytes` over all fragments of one message;
    ///   * RFC 6455 §8.1 UTF-8 validity for text — checked on the **complete**
    ///     message, because a multi-byte character may straddle a fragment
    ///     boundary and a per-fragment check would reject a valid message.
    ///
    /// Allocation-free until a message actually arrives fragmented.
    pub const Assembler = struct {
        allocator: std.mem.Allocator,
        frag: std.ArrayList(u8) = .empty,
        open_kind: ?WsFrameKind = null,

        /// A complete message. `payload` is valid until the next `push` — it is
        /// either the caller's own frame payload (single-frame message, no
        /// copy) or this assembler's reassembly buffer.
        pub const Message = struct { kind: WsFrameKind, payload: []u8 };

        pub const Error = error{
            InvalidUtf8,
            MessageTooLarge,
            UnexpectedContinuation,
            UnexpectedDataFrame,
            OutOfMemory,
        };

        pub fn init(allocator: std.mem.Allocator) Assembler {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Assembler) void {
            self.frag.deinit(self.allocator);
        }

        /// Feed one data (0x1/0x2) or continuation (0x0) frame whose header has
        /// already passed `validateFrameHeader` and whose payload is de-masked.
        /// `null` means the message is not complete yet.
        pub fn push(self: *Assembler, opcode: u8, fin: bool, payload: []u8) Error!?Message {
            if (opcode == 0x0) {
                const kind = self.open_kind orelse return error.UnexpectedContinuation;
                if (self.frag.items.len + payload.len > max_message_bytes) return error.MessageTooLarge;
                try self.frag.appendSlice(self.allocator, payload);
                if (!fin) return null;
                // Cleared before validating so a caller that ignores the error
                // still starts the next message from a clean state.
                self.open_kind = null;
                if (kind == .text) try validateUtf8(self.frag.items);
                return .{ .kind = kind, .payload = self.frag.items };
            }

            // Not 0x0, so 0x1/0x2 — anything else is a peer-reachable value the
            // caller's whitelist did not expect. An explicit error rather than
            // `unreachable`, which is UB in ReleaseFast if that whitelist is
            // ever widened.
            const kind = WsFrameKind.fromOpcode(opcode) orelse return error.UnexpectedDataFrame;
            if (self.open_kind != null) return error.UnexpectedDataFrame;
            if (fin) {
                // Common case: one frame, one message — nothing to copy.
                if (kind == .text) try validateUtf8(payload);
                return .{ .kind = kind, .payload = payload };
            }
            if (payload.len > max_message_bytes) return error.MessageTooLarge;
            self.frag.clearRetainingCapacity();
            try self.frag.appendSlice(self.allocator, payload);
            self.open_kind = kind;
            return null;
        }
    };

    /// Reassembles fragmented messages and services interleaved control frames, so
    /// callers never see a partial message. Carries no inline buffer: the
    /// reassembly buffer grows from the heap only for messages that actually
    /// arrive fragmented, and `overflow` only for frames above `buf`.
    pub const MessageReader = struct {
        framer: *WsFramer,
        allocator: std.mem.Allocator,
        assembler: Assembler,
        /// See `OversizeBuf` / `readFrame`.
        overflow: OversizeBuf,

        pub fn init(framer: *WsFramer, allocator: std.mem.Allocator) MessageReader {
            return .{
                .framer = framer,
                .allocator = allocator,
                .assembler = Assembler.init(allocator),
                .overflow = .{ .allocator = allocator },
            };
        }

        pub fn deinit(self: *MessageReader) void {
            self.assembler.deinit();
            self.overflow.deinit();
        }

        /// Best-effort close before handing a protocol error to the caller: the
        /// peer deserves a reason even if we cannot deliver one, and RFC 6455
        /// §7.4.1 gives it one. Logged, not swallowed — `scripts/check-production.sh`
        /// bans bare `catch {}` exactly so a failure cannot hide on this path.
        fn closeForProtocolError(self: *MessageReader, code: u16) void {
            self.framer.writeCloseWithCode(code) catch |err| {
                std.log.debug("[ws] could not send a close frame for a protocol error ({})", .{err});
            };
        }

        pub fn read(self: *MessageReader, buf: []u8) !Event {
            while (true) {
                const frame = self.framer.readFrame(buf, &self.overflow) catch |err| switch (err) {
                    // Protocol violations: tell the peer why before the caller
                    // drops the connection, instead of leaving it to a bare RST.
                    error.PayloadTooLarge => {
                        self.closeForProtocolError(CloseCode.message_too_big);
                        return err;
                    },
                    error.ReservedBitsSet,
                    error.UnmaskedClientFrame,
                    error.UnknownOpcode,
                    error.ControlFrameTooLarge,
                    error.FragmentedControlFrame,
                    => {
                        self.closeForProtocolError(CloseCode.protocol_error);
                        return err;
                    },
                    else => return err, // I/O or OOM — the socket is gone, nothing to send
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

                const message = self.assembler.push(frame.opcode, frame.fin, frame.payload) catch |err| {
                    self.closeForProtocolError(closeCodeFor(err));
                    return err;
                } orelse continue;

                return .{ .message = .{ .kind = message.kind, .payload = message.payload } };
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

    /// Write a close frame with no status code.
    pub fn writeClose(self: *WsFramer) !void {
        try self.writeFrame(0x8, &.{});
    }

    /// Close with a status code (RFC 6455 §5.5.1 / §7.4.1). `writeClose` stays
    /// for callers that only need to terminate the connection.
    pub fn writeCloseWithCode(self: *WsFramer, code: u16) !void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, code, .big);
        try self.writeFrame(0x8, &payload);
    }
};

test "WsFrameKind opcode roundtrip" {
    try std.testing.expectEqual(@as(u8, 0x1), WsFrameKind.text.opcode());
    try std.testing.expectEqual(@as(u8, 0x2), WsFrameKind.binary.opcode());
    try std.testing.expect(WsFrameKind.fromOpcode(0x1).? == .text);
    try std.testing.expect(WsFrameKind.fromOpcode(0x2).? == .binary);
    try std.testing.expect(WsFrameKind.fromOpcode(0x8) == null);
}

// The shared header rules, one case per rule. Both parsers (`readFrame` and
// `ws_uring.parseFrame`) call exactly this function, so a case here is a case
// for both — that is the point of extracting it.
test "validateFrameHeader: the RFC 6455 negative paths, one case each" {
    // Legal: FIN + text, MASK set, 2-byte payload.
    try validateFrameHeader(.{ 0x81, 0x82 }, 2);
    // Legal: continuation, and pong.
    try validateFrameHeader(.{ 0x80, 0x82 }, 0);
    try validateFrameHeader(.{ 0x8A, 0x80 }, 0);

    try std.testing.expectError(error.ReservedBitsSet, validateFrameHeader(.{ 0xC1, 0x82 }, 2));
    try std.testing.expectError(error.UnmaskedClientFrame, validateFrameHeader(.{ 0x81, 0x02 }, 2));
    try std.testing.expectError(error.UnknownOpcode, validateFrameHeader(.{ 0x83, 0x82 }, 2));
    try std.testing.expectError(error.ControlFrameTooLarge, validateFrameHeader(.{ 0x89, 0xFE }, 126));
    try std.testing.expectError(error.FragmentedControlFrame, validateFrameHeader(.{ 0x09, 0x82 }, 2));

    // A masked control frame at the 125-byte ceiling is still legal.
    try validateFrameHeader(.{ 0x89, 0xFD }, 125);
}

test "Assembler: an invalid UTF-8 text message is rejected (RFC 6455 §8.1)" {
    var assembler = WsFramer.Assembler.init(std.testing.allocator);
    defer assembler.deinit();

    var invalid = [_]u8{ 'h', 0xFF, 0xFE };
    try std.testing.expectError(error.InvalidUtf8, assembler.push(0x1, true, &invalid));

    // A truncated multi-byte sequence is equally invalid — the check is on the
    // whole message, not on "is there a lead byte".
    var truncated = [_]u8{ 0xE4, 0xB8 };
    try std.testing.expectError(error.InvalidUtf8, assembler.push(0x1, true, &truncated));

    // Binary is opaque bytes and must NOT be UTF-8 checked.
    const binary = try assembler.push(0x2, true, &invalid);
    try std.testing.expectEqual(WsFrameKind.binary, binary.?.kind);

    // The failure left no half-open message behind.
    var text = [_]u8{ 'o', 'k' };
    const after = (try assembler.push(0x1, true, &text)).?;
    try std.testing.expectEqualStrings("ok", after.payload);
}

test "Assembler: a multi-byte character split across two fragments is one valid message" {
    var assembler = WsFramer.Assembler.init(std.testing.allocator);
    defer assembler.deinit();

    // "中" is E4 B8 AD. The first fragment ends *inside* the character, which is
    // exactly the shape a per-fragment UTF-8 check rejects: each fragment is
    // invalid on its own, and the reassembled message is valid. §8.1 says the
    // check belongs on the complete message.
    var first = [_]u8{0xE4};
    var rest = [_]u8{ 0xB8, 0xAD };
    try std.testing.expect((try assembler.push(0x1, false, &first)) == null);
    const message = (try assembler.push(0x0, true, &rest)).?;

    try std.testing.expectEqual(WsFrameKind.text, message.kind);
    try std.testing.expectEqualStrings("中", message.payload);
}

test "Assembler: a fragment sequence without an opening frame is a protocol error" {
    var assembler = WsFramer.Assembler.init(std.testing.allocator);
    defer assembler.deinit();

    var payload = [_]u8{ 'x', 'y' };
    try std.testing.expectError(error.UnexpectedContinuation, assembler.push(0x0, true, &payload));
    try std.testing.expectError(error.UnexpectedDataFrame, assembler.push(0x3, true, &payload));
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

test "MessageReader: invalid UTF-8 fails the connection with close 1007" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    var wire: [64]u8 = undefined;
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x1 }, "h\xFF"));

    var buf: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidUtf8, w.reader.read(&buf));

    // RFC 6455 §7.4.1: the peer gets a reason, not a bare RST. 1007 = 0x03EF.
    var close: [8]u8 = undefined;
    const n = w.pair.recv(&close);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u8, 0x88), close[0]); // FIN + close
    try std.testing.expectEqual(@as(u8, 0x02), close[1]); // 2-byte status
    try std.testing.expectEqual(@as(u16, 1007), std.mem.readInt(u16, close[2..4], .big));
}

test "MessageReader: a frame larger than the caller's buffer is read, not dropped" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    // 10 KiB: above the 4 KiB pooled buffer `api/Server.zig` hands in, and above
    // the 126-form length, so this also exercises the 127 extended path. It used
    // to return error.PayloadTooLarge and kill the connection even though
    // max_message_bytes is 1 MiB.
    const big_len = 10 * 1024;
    const wire = try std.testing.allocator.alloc(u8, big_len + 14);
    defer std.testing.allocator.free(wire);

    const payload = try std.testing.allocator.alloc(u8, big_len);
    defer std.testing.allocator.free(payload);
    var i: usize = 0;
    while (i < big_len) : (i += 1) payload[i] = @truncate(i *% 31);

    // A socketpair buffers far less than 10 KiB (macOS: 8 KiB), so the write and
    // the read have to overlap — sending from this thread would fill the pair and
    // block before `read` ever runs.
    const wire_frame = buildFrame(wire, .{ .opcode = 0x2 }, payload);
    const th = try std.Thread.spawn(.{}, struct {
        fn sendAll(fd: std.posix.socket_t, bytes: []const u8) void {
            var off: usize = 0;
            while (off < bytes.len) {
                const rc = std.posix.system.write(fd, bytes[off..].ptr, bytes[off..].len);
                switch (std.posix.errno(rc)) {
                    .SUCCESS => {},
                    else => return,
                }
                const n: usize = @intCast(rc);
                if (n == 0) return;
                off += n;
            }
        }
    }.sendAll, .{ w.pair.fd, wire_frame });

    var buf: [4096]u8 = undefined;
    try std.testing.expect(w.reader.overflow.data == null); // fast path so far
    const event = w.reader.read(&buf) catch |err| {
        th.join();
        return err;
    };
    th.join();

    try std.testing.expectEqual(WsFrameKind.binary, event.message.kind);
    try std.testing.expectEqualSlices(u8, payload, event.message.payload);
    try std.testing.expect(w.reader.overflow.data != null); // grew, once
}

test "MessageReader: a small frame never touches the overflow buffer" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();

    var wire: [64]u8 = undefined;
    w.pair.send(buildFrame(&wire, .{ .opcode = 0x1 }, "hello"));

    var buf: [4096]u8 = undefined;
    const event = try w.reader.read(&buf);
    try std.testing.expectEqualStrings("hello", event.message.payload);
    // The 4 KiB fast path is allocation-free: the payload points into the
    // caller's own buffer and no heap buffer was ever reserved.
    try std.testing.expect(w.reader.overflow.data == null);
    try std.testing.expectEqual(buf[0..5].ptr, event.message.payload.ptr);
}

test "OversizeBuf: growth is geometric and bounded by the frame cap" {
    var over = WsFramer.OversizeBuf{ .allocator = std.testing.allocator };
    defer over.deinit();

    // The first request sizes the allocation to the next power of two above it.
    try std.testing.expectEqual(@as(usize, 4096), (try over.reserve(4096)).len);
    try std.testing.expectEqual(@as(usize, 4096), over.data.?.len);

    // Past that it steps up once, and the rounded capacity then absorbs the
    // repeat — which is the point: a peer ratcheting the declared length one
    // byte at a time cannot force one allocation per frame.
    try std.testing.expectEqual(@as(usize, 5000), (try over.reserve(5000)).len);
    try std.testing.expectEqual(@as(usize, 8192), over.data.?.len);
    const grown = over.data.?.ptr;
    try std.testing.expectEqual(@as(usize, 6000), (try over.reserve(6000)).len);
    try std.testing.expectEqual(grown, over.data.?.ptr);

    // 10 KiB — the frame size the fiber path could not deliver before.
    try std.testing.expectEqual(@as(usize, 10 * 1024), (try over.reserve(10 * 1024)).len);
    try std.testing.expectEqual(@as(usize, 16 * 1024), over.data.?.len);
}
