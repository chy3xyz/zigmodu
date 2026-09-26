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
    /// Registered connections, keyed by fd. **The ring thread is its only
    /// reader and writer** (registration, dispatch, teardown); a connection
    /// fiber never touches it — see `pending`.
    connections: std.AutoHashMap(i32, *Conn),
    /// Connections `adopt`ed but not yet registered, plus the lock guarding this
    /// list. They exist as a pair because `adopt` runs on the **connection's own
    /// fiber thread** while the loop runs on the ring thread: an io_uring
    /// submission queue has one writer (`get_sqe` reads *and* stores the SQ tail
    /// non-atomically) and so does the map. So the fiber only ever appends here;
    /// the ring thread moves entries into `connections` and submits their first
    /// read. `adopt` used to `put` into the map and `get_sqe` from the fiber
    /// thread — a torn SQ tail and a torn hash map, both silent.
    pending: std.ArrayList(*Conn),
    mutex: std.Io.Mutex = .init,
    /// Connections admitted and not yet torn down — the same number as
    /// `connections.count() + pending.items.len`, but readable from the fiber
    /// thread without touching a container that thread does not own.
    active: std.atomic.Value(u32) = .init(0),
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
            .pending = std.ArrayList(*Conn).empty,
            .running = std.atomic.Value(bool).init(false),
            .max_conn = cfg.max_connections,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        // Post-join, on this thread: `stop` has already drained both containers,
        // so these two are no-ops after a normal run and the only cleanup there
        // is when `start()` was never called.
        self.drainConnections(true);
        self.drainPending(true);
        self.ring.deinit();
        self.pending.deinit(self.allocator);
        self.connections.deinit();
        self.* = undefined;
    }

    /// Start the event loop in a dedicated thread.
    pub fn start(self: *Self) !void {
        self.running.store(true, .monotonic);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Signal shutdown, wait for the event loop to exit, then release whatever
    /// it was still holding.
    ///
    /// The loop drains `connections` on its way out; a connection adopted after
    /// its last pass was never registered and is still in `pending`, so it is
    /// drained here — on a thread the loop has already joined, which is why this
    /// is safe to do without the loop's cooperation. `adopt` decides whether to
    /// accept under this same lock (see below), so there is no window in which a
    /// connection is accepted by nobody: it is either registered by the loop or
    /// torn down here.
    pub fn stop(self: *Self) void {
        self.running.store(false, .monotonic);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.drainPending(true);
    }

    /// Transfer a WS connection (after handshake) from its fiber to io_uring.
    ///
    /// **On success the ring owns `fd`** and closes it exactly once, in
    /// `teardownConn`; the caller must NOT close it — that is the caller's half
    /// of this contract, and it is the fiber's `defer stream.close` that has to
    /// be skipped (`Server.connFiber`). **On error nothing was taken**: the fd is
    /// untouched and still the caller's to close.
    ///
    /// Registration itself is deferred to the ring thread (`registerPending`);
    /// this only enqueues, so `self.allocator` is the one thing that crosses
    /// threads here and must be safe to use from any (it is: every connection
    /// fiber already allocates from it through its own arena).
    pub fn adopt(self: *Self, fd: i32, session: *anyopaque, on_message: OnMessageFn, on_close: OnCloseFn) !void {
        const conn = try self.allocator.create(Conn);
        errdefer {
            conn.assembler.deinit();
            self.allocator.destroy(conn);
        }
        conn.* = .{
            .fd = fd,
            .session = session,
            .on_message = on_message,
            .on_close = on_close,
            .data_offset = 0,
            .data_len = 0,
            .assembler = WsFramer.Assembler.init(self.allocator),
        };

        // `lock` fails only with `error.Canceled`; report that itself rather than
        // a lock-machinery story, and let it mean "take the connection back".
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        // Decided under the lock `stop()` drains under, so a connection accepted
        // here cannot outlive the drain that would have cleaned it.
        if (!self.running.load(.monotonic)) return error.ShuttingDown;
        if (self.active.load(.monotonic) >= self.max_conn) return error.MaxConnections;

        try self.pending.append(self.allocator, conn);
        _ = self.active.fetchAdd(1, .monotonic);
    }

    fn runLoop(self: *Self) void {
        var cqes: [64]linux.io_uring_cqe = undefined;

        while (self.running.load(.monotonic)) {
            self.registerPending();

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

    /// The ring thread's half of `adopt`: move newly adopted connections into
    /// `connections` and submit each one's first read.
    ///
    /// The lock covers the *handover only* — one uncontended lock per pass, and
    /// never a syscall per message. Registration happens outside it on purpose:
    /// `put` can fail, and a failure ends in `teardownConn`, which runs the
    /// application's `on_close`. No application callback runs while a fiber is
    /// waiting on this lock, so nothing the application does can invert the lock
    /// order from under the ring.
    ///
    /// Latency note for the move: `submitRead` only *fills* an SQE — the kernel
    /// picks it up at the loop's next `ring.submit()`, and that is exactly where
    /// the pre-fix code's fiber-written SQE also landed. Filling it here instead
    /// adds nothing the kernel could see.
    fn registerPending(self: *Self) void {
        // `lock` fails only with `error.Canceled`; there is nothing to unwind
        // here, so a canceled wait simply leaves the batch for the next pass.
        var batch: std.ArrayList(*Conn) = .empty;
        {
            self.mutex.lock(self.io) catch return;
            defer self.mutex.unlock(self.io);
            std.mem.swap(std.ArrayList(*Conn), &batch, &self.pending);
        }
        defer batch.deinit(self.allocator);
        if (batch.items.len == 0) return;

        for (batch.items) |conn| {
            self.connections.put(conn.fd, conn) catch |err| {
                // Untrackable (out of memory): close it rather than serve it with
                // no entry the ring can find. Post-handshake, so the peer sees a
                // plain close — the same outcome as a rejected peer.
                std.log.warn("[ws_uring] cannot track fd {d}: {s}", .{ conn.fd, @errorName(err) });
                self.teardownConn(conn, conn.fd, true);
                continue;
            };
            self.submitRead(conn) catch |err| {
                std.log.debug("[ws_uring] initial read submit failed: {s}", .{@errorName(err)});
                self.closeConn(conn, conn.fd);
            };
        }
    }

    /// Tear down connections that were adopted but never registered.
    ///
    /// Called from `stop`/`deinit` once the loop thread is joined, and on the way
    /// out of `registerPending`'s failures, so the list is quiescent whenever it
    /// runs. It is also what keeps `start()`-never-called clean: a connection
    /// adopted with no loop running has nobody else to close it.
    fn drainPending(self: *Self, notify_close: bool) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        for (self.pending.items) |conn| self.teardownConn(conn, conn.fd, notify_close);
        self.pending.clearRetainingCapacity();
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

    /// The one place a connection is actually released: `on_close` once, the fd
    /// closed once, the slot given back to `max_conn`.
    ///
    /// Every path that ends a connection comes through here — dispatch failure,
    /// protocol failure, loop exit, `stop` — which is what makes "closed exactly
    /// once" a property of the ring rather than of its callers. It used to be
    /// otherwise: the handshake fiber closed the fd too, after handing it over.
    fn teardownConn(self: *Self, conn: *Conn, fd: i32, notify_close: bool) void {
        if (notify_close and @intFromPtr(conn.on_close) != 0) conn.on_close(conn.session);
        _ = self.connections.remove(fd);
        _ = linux.close(fd);
        _ = self.active.fetchSub(1, .monotonic);
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

// ---------------------------------------------------------------------------
// The handoff contract (`adopt`) and the teardown that closes what it took.
//
// `init` is Linux-only — that is where `std.os.linux.IoUring` comes from — so
// these tests build the bookkeeping by hand instead. That is possible precisely
// because `adopt`, `registerPending` and `teardownConn` no longer touch the ring:
// the fiber used to `put` into the map and submit its own SQE, and this is the
// test-shaped half of undoing that. `ring` stays `undefined` and no loop runs.
// ---------------------------------------------------------------------------

/// A `WsUring` whose `ring` is never reached. Not usable with `deinit` (it calls
/// `ring.deinit`); every field the admission and teardown paths read is real.
fn testInstance(allocator: std.mem.Allocator) WsUring {
    return .{
        .ring = undefined,
        .allocator = allocator,
        .io = std.testing.io,
        .connections = std.AutoHashMap(i32, *Conn).init(allocator),
        .pending = std.ArrayList(*Conn).empty,
        .running = std.atomic.Value(bool).init(false),
        .max_conn = 8,
    };
}

/// Callback state for `testInstance`'s connections — file-level because the
/// callbacks are plain function pointers, with no context argument to carry it.
var handoff_state: struct {
    closes: usize = 0,
    messages: usize = 0,
} = .{};

fn handoffOnMessage(_: ?*anyopaque, _: []const u8, _: WsFrameKind) void {
    handoff_state.messages += 1;
}

fn handoffOnClose(_: ?*anyopaque) void {
    handoff_state.closes += 1;
}

/// Whether the kernel still has `fd` open. Asked with `F_GETFD`, so the answer is
/// the real one: a second `close` on a number the kernel has since reissued is
/// invisible to the process that does it, but not to this question.
fn fdIsOpen(fd: std.posix.socket_t) bool {
    return std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0))) == .SUCCESS;
}

fn testSocketPair() ![2]std.posix.socket_t {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.posix.errno(rc) != .SUCCESS) return error.SkipZigTest;
    return fds;
}

test "WsUring.adopt: a refusal takes nothing, and the fd stays the caller's" {
    const allocator = std.testing.allocator;
    var uring = testInstance(allocator);
    defer {
        // Not `deinit`: it would call `ring.deinit` on the `undefined` above.
        uring.connections.deinit();
        uring.pending.deinit(allocator);
    }
    handoff_state = .{};

    const fds = try testSocketPair();
    // `fds[0]` is handed over below, so on Linux the teardown closes it; off Linux
    // `linux.close` is a stub, so the test has to.
    defer {
        if (builtin.os.tag != .linux) _ = std.posix.system.close(fds[0]);
    }
    defer _ = std.posix.system.close(fds[1]);
    var session: u32 = 0;

    // Not started: an upgrade that gets here has no loop to serve it, so it is
    // refused — and a refused handoff must hand nothing over. The caller's half
    // of that is `connFiber`'s `fd_owned_by_fiber` staying true, so the fd is
    // closed exactly once, by the fiber.
    try std.testing.expectError(error.ShuttingDown, uring.adopt(@intCast(fds[0]), &session, handoffOnMessage, handoffOnClose));
    try std.testing.expectEqual(@as(usize, 0), uring.pending.items.len);
    try std.testing.expectEqual(@as(u32, 0), uring.active.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), handoff_state.closes);
    try std.testing.expect(fdIsOpen(fds[0]));

    // Started, but full: refused the same way, and the refusal does not consume a
    // slot — `active` is what `max_conn` is measured against, and it counts what
    // was taken, not what was offered.
    uring.running.store(true, .monotonic);
    uring.max_conn = 1;
    try uring.adopt(@intCast(fds[0]), &session, handoffOnMessage, handoffOnClose);
    try std.testing.expectEqual(@as(u32, 1), uring.active.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), uring.pending.items.len);

    const more = try testSocketPair();
    defer {
        _ = std.posix.system.close(more[0]);
        _ = std.posix.system.close(more[1]);
    }
    try std.testing.expectError(error.MaxConnections, uring.adopt(@intCast(more[0]), &session, handoffOnMessage, handoffOnClose));
    try std.testing.expectEqual(@as(u32, 1), uring.active.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), uring.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), handoff_state.closes);
    try std.testing.expect(fdIsOpen(more[0]));

    // And the one connection that was taken goes through the drain `stop()` ends
    // with: `on_close` once, the slot back, the `Conn` freed (the testing
    // allocator would report it otherwise).
    uring.drainPending(true);
    try std.testing.expectEqual(@as(u32, 0), uring.active.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), handoff_state.closes);
}

test "WsUring.teardown: on_close runs once per connection, and the slot comes back" {
    const allocator = std.testing.allocator;
    var uring = testInstance(allocator);
    defer {
        uring.connections.deinit();
        uring.pending.deinit(allocator);
    }
    handoff_state = .{};

    const fds = try testSocketPair();
    defer _ = std.posix.system.close(fds[1]);
    var session: u32 = 0;

    uring.running.store(true, .monotonic);
    try uring.adopt(@intCast(fds[0]), &session, handoffOnMessage, handoffOnClose);

    // Success *is* the ownership transfer, so from here the fd belongs to the
    // ring and must still be open: the regression under guard is the handshake
    // fiber closing it anyway, which is what left the ring reading a descriptor
    // that the kernel was free to reissue.
    try std.testing.expect(fdIsOpen(fds[0]));
    try std.testing.expectEqual(@as(usize, 0), handoff_state.closes);
    try std.testing.expectEqual(@as(usize, 1), uring.pending.items.len);

    uring.drainPending(true);
    try std.testing.expectEqual(@as(usize, 1), handoff_state.closes);
    try std.testing.expectEqual(@as(usize, 0), uring.pending.items.len);
    try std.testing.expectEqual(@as(u32, 0), uring.active.load(.monotonic));

    // A second drain is a no-op: `on_close` does not run twice, and the `Conn` is
    // not freed twice (the testing allocator turns that into a failure on its
    // own).
    uring.drainPending(true);
    try std.testing.expectEqual(@as(usize, 1), handoff_state.closes);
    try std.testing.expectEqual(@as(u32, 0), uring.active.load(.monotonic));

    if (builtin.os.tag == .linux) {
        // The teardown closed the fd it took — exactly once. This is the only
        // host where that can be asserted: off Linux `linux.close` is this
        // module's stub and does nothing, so an "open" answer below would say
        // nothing about the code under test.
        try std.testing.expect(!fdIsOpen(fds[0]));
    } else {
        _ = std.posix.system.close(fds[0]);
    }
}
