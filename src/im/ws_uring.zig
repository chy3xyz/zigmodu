const std = @import("std");
const builtin = @import("builtin");

// io_uring opcode constants — defined locally because std.os.linux
// does not expose them on all architectures (e.g. aarch64).
const IORING_OP_READ: u8 = 22;
const IORING_OP_WRITE: u8 = 23;

const linux = if (builtin.os.tag == .linux) std.os.linux else struct {
    pub const fd_t = i32;
    pub const io_uring_cqe = extern struct { user_data: u64 = 0, res: i32 = 0, flags: u32 = 0 };
    pub const io_uring_sqe = extern struct {
        opcode: u8 = 0,
        flags: u8 = 0,
        ioprio: u16 = 0,
        fd: i32 = 0,
        off: u64 = 0,
        addr: u64 = 0,
        len: u32 = 0,
        user_data: u64 = 0,
    };
    pub fn close(_: i32) void {}
    pub fn write(_: i32, _: [*]const u8, _: usize) usize {
        return 0;
    }
};
const IoUring = if (builtin.os.tag == .linux) std.os.linux.IoUring else struct {
    pub fn init(_: u16, _: u32) !@This() {
        return error.SystemOutdated;
    }
    pub fn deinit(_: *@This()) void {}
    pub fn get_sqe(_: *@This()) !*linux.io_uring_sqe {
        return error.SubmissionQueueFull;
    }
    pub fn submit(_: *@This()) !u32 {
        return 0;
    }
    pub fn copy_cqes(_: *@This(), _: []linux.io_uring_cqe, _: u32) !u32 {
        return 0;
    }
};

/// Callback types matching WsRoute in Server.zig
pub const WsFrameKind = @import("WsFramer.zig").WsFrameKind;
pub const OnMessageFn = *const fn (session: ?*anyopaque, msg: []const u8, kind: WsFrameKind) void;
pub const OnCloseFn = *const fn (session: ?*anyopaque) void;

/// The fiber parser module. `ws_uring` shares its rules — `validateFrameHeader`,
/// `Assembler`, `CloseCode` — rather than restating them; see the notes on each.
const ws_framer = @import("WsFramer.zig");
const WsFramer = ws_framer.WsFramer;

/// io_uring-based WebSocket event loop — Linux 5.1+ only.
/// Eliminates per-connection fiber stacks: each connection is a 4KB buffer + 120B state.
pub const WsUring = struct {
    const Self = @This();

    ring: IoUring,
    allocator: std.mem.Allocator,
    /// Only used to back off when the ring has nothing to report: `std.Io.sleep`
    /// is the 0.17 replacement for the removed `std.time.sleep`, and it takes
    /// the same `io` the rest of the framework threads through.
    io: std.Io,
    connections: std.AutoHashMap(i32, *Conn),
    running: std.atomic.Value(bool),
    max_conn: u32,
    thread: ?std.Thread = null,

    pub const Config = struct {
        max_connections: u32 = 8192,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: Config) !Self {
        if (builtin.os.tag != .linux) @compileError("io_uring requires Linux 5.1+");

        const ring_size: u16 = @intCast(std.math.ceilPowerOfTwo(u16, @intCast(@min(cfg.max_connections * 2, 32768))) catch 512);
        const ring = try IoUring.init(ring_size, 0);
        return .{
            .ring = ring,
            .allocator = allocator,
            .io = io,
            .connections = std.AutoHashMap(i32, *Conn).init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .max_conn = cfg.max_connections,
        };
    }

    pub fn deinit(self: *Self) void {
        self.running.store(false, .monotonic);
        if (self.thread) |t| t.join();
        self.drainConnections(true);
        self.ring.deinit();
        self.connections.deinit();
        self.* = undefined;
    }

    /// Start the event loop in a dedicated thread.
    pub fn start(self: *Self) !void {
        self.running.store(true, .monotonic);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Signal shutdown and wait for the event loop to exit.
    pub fn stop(self: *Self) void {
        self.running.store(false, .monotonic);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Transfer a WS connection (after handshake) from fiber to io_uring.
    /// Takes ownership of the fd — caller must NOT close it.
    pub fn adopt(self: *Self, fd: i32, session: *anyopaque, on_message: OnMessageFn, on_close: OnCloseFn) !void {
        if (self.connections.count() >= self.max_conn) return error.MaxConnections;

        const conn = try self.allocator.create(Conn);
        conn.* = .{
            .fd = fd,
            .session = session,
            .on_message = on_message,
            .on_close = on_close,
            .data_offset = 0,
            .data_len = 0,
            .assembler = WsFramer.Assembler.init(self.allocator),
        };
        try self.connections.put(fd, conn);

        // Submit initial read
        try self.submitRead(conn);
    }

    fn runLoop(self: *Self) void {
        var cqes: [64]linux.io_uring_cqe = undefined;

        while (self.running.load(.monotonic)) {
            _ = self.ring.submit() catch |err| {
                std.log.debug("[ws_uring] submit failed: {s}", .{@errorName(err)});
            };

            const count = self.ring.copy_cqes(&cqes, 0) catch |err| {
                std.log.debug("[ws_uring] copy_cqes failed: {s}", .{@errorName(err)});
                self.idleBackoff();
                continue;
            };

            if (count == 0) {
                self.idleBackoff();
                continue;
            }

            for (cqes[0..count]) |*cqe| {
                if (cqe.user_data == 0) continue;
                const fd: i32 = @intCast(cqe.user_data);
                const conn = self.connections.get(fd) orelse continue;

                if (cqe.res <= 0) {
                    self.closeConn(conn, fd);
                    continue;
                }

                self.processData(conn, fd, @intCast(cqe.res));
            }
        }

        self.drainConnections(true);
    }

    /// 1 ms back-off when the ring has nothing to report.
    ///
    /// This used to be `std.time.sleep`, which Zig 0.17 removed — so `start()`
    /// did not compile. Because nothing in-tree referenced `start()`, Zig never
    /// analysed it, and `processData` (only reachable from `runLoop`) was never
    /// analysed either: the parser's defects below stayed latent, not fixed.
    fn idleBackoff(self: *Self) void {
        std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(1), .real) catch |err| {
            std.log.debug("[ws_uring] sleep interrupted: {s}", .{@errorName(err)});
        };
    }

    fn drainConnections(self: *Self, notify_close: bool) void {
        var it = self.connections.iterator();
        while (it.next()) |kv| {
            self.teardownConn(kv.value_ptr.*, kv.key_ptr.*, notify_close);
        }
        self.connections.clearRetainingCapacity();
    }

    fn teardownConn(self: *Self, conn: *Conn, fd: i32, notify_close: bool) void {
        if (notify_close and @intFromPtr(conn.on_close) != 0) conn.on_close(conn.session);
        _ = self.connections.remove(fd);
        _ = linux.close(fd);
        conn.assembler.deinit();
        self.allocator.destroy(conn);
    }

    /// Submit a 4KB read at the current buffer tail.
    fn submitRead(self: *Self, conn: *Conn) !void {
        const sqe = try self.ring.get_sqe();
        const sqe_bytes: [*]u8 = @ptrCast(sqe);
        @memset(sqe_bytes[0..@sizeOf(linux.io_uring_sqe)], 0);
        if (@TypeOf(sqe.opcode) == u8) {
            sqe.opcode = IORING_OP_READ;
        } else {
            sqe.opcode = @fromBackingInt(@intCast(IORING_OP_READ));
        }
        sqe.fd = conn.fd;
        sqe.addr = @intFromPtr(&conn.buf[conn.data_offset + conn.data_len]);
        sqe.len = @intCast(Conn.BufSize - conn.data_offset - conn.data_len);
        sqe.user_data = @as(u64, @intCast(conn.fd));
    }

    /// Process newly read data. Parse all complete frames, submit next read.
    ///
    /// Semantics are the fiber path's (`WsFramer.MessageReader`), on purpose:
    /// the same shared validator decides what is legal, the same `Assembler`
    /// decides what a fragment sequence means, and a message is delivered whole
    /// or not at all.
    fn processData(self: *Self, conn: *Conn, fd: i32, bytes_read: usize) void {
        conn.data_len += bytes_read;
        var consumed: usize = 0;

        while (true) {
            const rest = conn.buf[conn.data_offset..][0..conn.data_len][consumed..];
            const frame = parseFrame(rest) catch |err| switch (err) {
                error.Incomplete => break,
                // Declared length does not fit this connection's 4 KiB buffer —
                // and `parseFrame` converts a hostile 64-bit length into this
                // too, so the value below never reaches an index or a sum.
                error.PayloadTooLarge => return self.failConn(conn, fd, WsFramer.CloseCode.message_too_big),
                else => return self.failConn(conn, fd, WsFramer.CloseCode.protocol_error),
            };
            consumed += frame.total;

            if (frame.opcode >= 0x8) {
                // `parseFrame` already rejected the illegal control shapes
                // (payload > 125, FIN clear), so the write below is in range.
                switch (frame.opcode) {
                    0x8 => {
                        self.closeConn(conn, fd);
                        return;
                    },
                    0x9 => writeControl(fd, 0xA, frame.payload) catch |err| {
                        std.log.debug("[ws_uring] pong send failed: {s}", .{@errorName(err)});
                    },
                    else => {}, // 0xA pong — nothing to track
                }
                continue;
            }

            const message = conn.assembler.push(frame.opcode, frame.fin, frame.payload) catch |err| {
                return self.failConn(conn, fd, closeCodeFor(err));
            } orelse continue;

            if (@intFromPtr(conn.on_message) != 0) conn.on_message(conn.session, message.payload, message.kind);
        }

        // Compact: move the unconsumed tail to the start of the buffer.
        const tail_start = conn.data_offset + consumed;
        const leftover = conn.data_len - consumed;
        if (consumed > 0 and leftover > 0) {
            std.mem.copyForwards(u8, conn.buf[0..leftover], conn.buf[tail_start..][0..leftover]);
        }
        conn.data_offset = 0;
        conn.data_len = leftover;

        // Submit next read
        self.submitRead(conn) catch self.closeConn(conn, fd);
    }

    /// Close a connection that broke the protocol, after telling the peer why
    /// (RFC 6455 §7.4.1). Best effort: the peer may already be gone.
    fn failConn(self: *Self, conn: *Conn, fd: i32, code: u16) void {
        var code_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_bytes, code, .big);
        writeControl(fd, 0x8, &code_bytes) catch |err| {
            std.log.debug("[ws_uring] close frame send failed: {s}", .{@errorName(err)});
        };
        self.closeConn(conn, fd);
    }

    fn closeConn(self: *Self, conn: *Conn, fd: i32) void {
        self.teardownConn(conn, fd, true);
    }
};

/// One frame as it sits in `Conn.buf`, already validated and de-masked in place.
const ParsedFrame = struct {
    opcode: u8,
    fin: bool,
    /// Borrowed from `Conn.buf`; valid until the next read into it.
    payload: []u8,
    /// Bytes this frame occupies on the wire, so the caller advances by it.
    total: usize,
};

const ParseError = error{
    /// `buf` does not hold the whole frame yet — read more and retry.
    Incomplete,
    /// The declared length exceeds this connection's buffer.
    PayloadTooLarge,
} || ws_framer.HeaderError;

/// Parse one frame out of `buf`, in place.
///
/// Never reads past `buf`, never allocates, and has no panic path: an illegal
/// header is reported by the **shared** `WsFramer.validateFrameHeader` (the same
/// function the fiber parser calls, so the two cannot drift), an oversized frame
/// as `error.PayloadTooLarge`, a short buffer as `error.Incomplete`.
///
/// This function was unreachable until `start()` was made to compile, and it had
/// kept every defect the fiber parser had already been fixed for: no RSV check,
/// no MASK requirement, no opcode whitelist, no control-frame constraints, no
/// fragment reassembly, no UTF-8 check — plus an unchecked 64-bit length and a
/// `@intCast` panic on a large ping.
fn parseFrame(buf: []u8) ParseError!ParsedFrame {
    if (buf.len < 2) return error.Incomplete;

    const header: [2]u8 = .{ buf[0], buf[1] };
    var payload_len: u64 = header[1] & 0x7F;
    var header_len: usize = 2;

    if (payload_len == 126) {
        if (buf.len < 4) return error.Incomplete;
        payload_len = std.mem.readInt(u16, buf[2..4], .big);
        header_len = 4;
    } else if (payload_len == 127) {
        if (buf.len < 10) return error.Incomplete;
        payload_len = std.mem.readInt(u64, buf[2..10], .big);
        header_len = 10;
    }

    // Bound before the sum. `payload_len` is a 64-bit field straight off the
    // wire: `header_len + 4 + payload_len` overflows for a crafted 127-extended
    // length (10 + 4 + 0xFFFF_FFFF_FFFF_FFFF), and the slice below would then be
    // built with start > end. `header_len` is at most 10, so bounding the payload
    // against the buffer first makes every sum below safe — the same order
    // `WsFramer.readFrame` uses.
    if (payload_len > Conn.BufSize) return error.PayloadTooLarge;

    // Before the header rules, deliberately: this bound is what keeps the
    // arithmetic safe no matter what `validateFrameHeader` grows into, and the
    // only error precedence it costs is 1009-vs-1002 on a frame that declares an
    // absurd length — both close the connection.
    try ws_framer.validateFrameHeader(header, payload_len);

    // The whole frame has to fit, not just the payload. A frame that cannot fit
    // even an empty buffer must be rejected *here*: the alternative is a full
    // buffer, `consumed == 0`, and a zero-length read submitted for the next
    // poll — which reads 0, looks like EOF, and drops a legitimate connection.
    // Masking is mandatory for clients (validated above), so the key is 4 bytes.
    const total = header_len + 4 + @as(usize, @intCast(payload_len));
    if (total > Conn.BufSize) return error.PayloadTooLarge;
    if (buf.len < total) return error.Incomplete;

    const mask_key: [4]u8 = buf[header_len..][0..4].*;
    const payload = buf[header_len + 4 .. total];
    for (payload, 0..) |*b, i| b.* ^= mask_key[i % 4];

    return .{
        .opcode = header[0] & 0x0F,
        .fin = (header[0] & 0x80) != 0,
        .payload = payload,
        .total = total,
    };
}

/// RFC 6455 §7.4.1 close code for a message-level violation — same mapping the
/// fiber path uses (`WsFramer.closeCodeFor`).
fn closeCodeFor(err: WsFramer.Assembler.Error) u16 {
    return switch (err) {
        error.InvalidUtf8 => WsFramer.CloseCode.invalid_payload, // 1007
        error.MessageTooLarge => WsFramer.CloseCode.message_too_big, // 1009
        else => WsFramer.CloseCode.protocol_error, // 1002
    };
}

/// One control frame via a direct syscall — control frames are small and rare,
/// so they do not need an SQE round-trip through the ring.
///
/// `payload.len > 125` is rejected rather than truncated: RFC 6455 §5.5 caps
/// control frames at 125 bytes, and the one-byte length field would be an
/// `@intCast` panic above it. The caller parsed this frame through
/// `validateFrameHeader`, which enforces the cap — this check is here so that
/// loosening *that* rule cannot turn into a panic here.
fn writeControl(fd: i32, opcode: u8, payload: []const u8) !void {
    if (payload.len > 125) return error.ControlFrameTooLarge;

    var frame: [127]u8 = undefined;
    frame[0] = 0x80 | opcode;
    frame[1] = @intCast(payload.len);
    @memcpy(frame[2..][0..payload.len], payload);

    const total = 2 + payload.len;
    // `linux.write` is `usize`-returning: errno comes back as a huge value, so
    // "not exactly what we asked for" covers both a short write and a failure.
    if (linux.write(fd, &frame, total) != total) return error.WriteFailed;
}

test "WsUring.start is analysed (the removed std.time.sleep used to hide this file)" {
    // `zig build test` never saw this file's real bodies: Zig analyses lazily,
    // nothing in-tree referenced `start()`, so `start()` → `runLoop` →
    // `processData` were outside every analysis graph and the `std.time.sleep`
    // Zig 0.17 removed was a latent compile error rather than a broken build —
    // with a parser underneath it that had missed every hardening `WsFramer` got.
    // Referencing the entry point forces the whole loop (and thus every function
    // it reaches) to be analysed on every platform, so the next removal cannot
    // go unnoticed again.
    _ = &WsUring.start;
    _ = &WsUring.stop;
    _ = &WsUring.adopt;
    _ = &WsUring.processData;
    // Signature only: `init`'s body stops at its `@compileError` off-Linux.
    _ = @TypeOf(WsUring.init);
    _ = @TypeOf(parseFrame);
    _ = @TypeOf(writeControl);
}

const test_mask_key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };

/// Serialize one masked client frame into `out` (RFC 6455 §5.2/§5.3), the same
/// shape the live client sends. Mirrors the builder in `WsFramer.zig`'s tests.
fn buildFrame(out: []u8, opcode: u8, fin: bool, payload: []const u8) []u8 {
    out[0] = (if (fin) @as(u8, 0x80) else 0) | opcode;
    var n: usize = 0;
    if (payload.len < 126) {
        out[1] = 0x80 | @as(u8, @intCast(payload.len));
        n = 2;
    } else if (payload.len < 65536) {
        out[1] = 0x80 | 126;
        std.mem.writeInt(u16, out[2..4], @intCast(payload.len), .big);
        n = 4;
    } else {
        out[1] = 0x80 | 127;
        std.mem.writeInt(u64, out[2..10], @intCast(payload.len), .big);
        n = 10;
    }
    @memcpy(out[n..][0..4], &test_mask_key);
    n += 4;
    for (payload, 0..) |b, i| out[n + i] = b ^ test_mask_key[i % 4];
    return out[0 .. n + payload.len];
}

test "parseFrame: a masked text frame parses and de-masks in place" {
    var wire: [64]u8 = undefined;
    const frame = try parseFrame(buildFrame(&wire, 0x1, true, "hi"));

    try std.testing.expectEqual(@as(u8, 0x1), frame.opcode);
    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(@as(usize, 8), frame.total);
    try std.testing.expectEqualStrings("hi", frame.payload);
}

test "parseFrame: the shared header rules apply (the second parser used to accept all of these)" {
    var wire: [64]u8 = undefined;

    // Unmasked: RFC 6455 §5.1 requires the server to close.
    wire[0] = 0x81;
    wire[1] = 0x02;
    wire[2] = 'h';
    wire[3] = 'i';
    try std.testing.expectError(error.UnmaskedClientFrame, parseFrame(wire[0..4]));

    // RSV1 with no negotiated extension.
    _ = buildFrame(&wire, 0x1, true, "hi");
    wire[0] |= 0x40;
    try std.testing.expectError(error.ReservedBitsSet, parseFrame(&wire));

    // Unknown opcode.
    _ = buildFrame(&wire, 0x3, true, "hi");
    try std.testing.expectError(error.UnknownOpcode, parseFrame(&wire));

    // A fragmented control frame.
    _ = buildFrame(&wire, 0x9, false, "p");
    try std.testing.expectError(error.FragmentedControlFrame, parseFrame(&wire));

    // A ping above the 125-byte ceiling (126 bytes → this used to be read as a
    // whole frame and echoed back as an illegal >125-byte control frame).
    var big: [256]u8 = undefined;
    const payload126: [126]u8 = @splat('x');
    try std.testing.expectError(error.ControlFrameTooLarge, parseFrame(buildFrame(&big, 0x9, true, &payload126)));
}

test "parseFrame: a 64-bit length cannot overflow the frame total" {
    // A 127-extended length of 2^64-1 with no payload behind it: 10 + 4 + len
    // wraps, and the old code then sliced `buf[10..9]`. It must be a rejected
    // frame, never a wrap — and never a panic.
    var buf: [14]u8 = undefined;
    buf[0] = 0x82; // FIN + binary
    buf[1] = 0x80 | 127; // masked, 64-bit length
    std.mem.writeInt(u64, buf[2..10], std.math.maxInt(u64), .big);
    @memcpy(buf[10..14], &test_mask_key);
    try std.testing.expectError(error.PayloadTooLarge, parseFrame(&buf));

    // The same for a length that fits the wire field but not this buffer.
    std.mem.writeInt(u64, buf[2..10], @as(u64, Conn.BufSize) + 1, .big);
    try std.testing.expectError(error.PayloadTooLarge, parseFrame(&buf));

    // A payload that fits but a *frame* that does not: 4096 - 14 + 1 bytes of
    // payload, plus the 10-byte 127-form header and the 4-byte mask. Rejected
    // here (1009), not left to fill the buffer and then submit a zero-length
    // read — which reads 0, looks like EOF, and drops a live connection.
    std.mem.writeInt(u64, buf[2..10], Conn.BufSize - 14 + 1, .big);
    try std.testing.expectError(error.PayloadTooLarge, parseFrame(&buf));

    // One byte smaller fits, and is only short of data — not rejected.
    std.mem.writeInt(u64, buf[2..10], Conn.BufSize - 14, .big);
    try std.testing.expectError(error.Incomplete, parseFrame(&buf));
}

test "parseFrame: a partial frame is Incomplete, not an error" {
    var wire: [64]u8 = undefined;

    // Header only.
    const whole = buildFrame(&wire, 0x1, true, "hello");
    try std.testing.expectError(error.Incomplete, parseFrame(whole[0..1]));
    // Header + mask, payload still on the wire.
    try std.testing.expectError(error.Incomplete, parseFrame(whole[0..6]));
    // 127-form length whose 8 extended bytes have not arrived.
    var ext: [256]u8 = undefined;
    var payload200: [200]u8 = @splat('x');
    _ = buildFrame(&ext, 0x2, true, &payload200);
    try std.testing.expectError(error.Incomplete, parseFrame(ext[0..5]));
}

test "writeControl: a control frame above 125 bytes is rejected, not truncated" {
    // RFC 6455 §5.5 — the 1-byte length field would be an `@intCast` panic here,
    // so the bound has to be a rejection. The fd is never reached.
    var payload: [126]u8 = @splat('x');
    try std.testing.expectError(error.ControlFrameTooLarge, writeControl(-1, 0xA, &payload));
}

const Conn = struct {
    const BufSize = 4096;

    fd: i32,
    session: *anyopaque,
    on_message: OnMessageFn,
    on_close: OnCloseFn,
    buf: [BufSize]u8 = undefined,
    data_offset: usize = 0, // Start of valid data in buf
    data_len: usize = 0, // Amount of valid data starting at data_offset
    /// Fragment/FIN reassembly — the *same* state machine the fiber parser
    /// drives (`WsFramer.Assembler`), so both paths deliver whole messages and
    /// both apply the 1 MiB cap and the UTF-8 rule in one place.
    assembler: WsFramer.Assembler,
};
