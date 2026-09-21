//! Raw socket reads that bypass `std.Io`'s `net_read` path.
//!
//! With the Threaded Io shared across threads (accept thread + worker fibers +
//! client threads), io-based socket reads can block forever even when data is
//! already in the kernel buffer (reproduced on macOS: `poll` readable and
//! `MSG_PEEK` show the bytes, `readv` still hangs). Writes and connects are
//! unaffected. Long-blocking reads that wait for peer data — WebSocket frames,
//! Redis/NATS/Kafka responses, event-bus messages, HTTP bodies — must use
//! these helpers instead of `io.operate(net_read)`.

const std = @import("std");

/// Read once into `buf` (blocking; sockets from std.Io are blocking so a bare
/// `read` already waits for data — no poll needed, and it halves syscalls).
/// Returns bytes read (possibly fewer than `buf.len`); 0 means the peer closed.
pub fn readSome(stream: std.Io.net.Stream, buf: []u8) !usize {
    const n = std.posix.read(stream.socket.handle, buf) catch return error.ConnectionError;
    return n;
}

/// Read exactly `buf.len` bytes (blocks until complete, an error, or EOF).
pub fn readFull(stream: std.Io.net.Stream, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = try readSome(stream, buf[filled..]);
        if (n == 0) return error.ConnectionClosed;
        filled += n;
    }
}

/// Apply a socket timeout option **without** going through
/// `std.posix.setsockopt`.
///
/// That wrapper maps `EINVAL` to `unreachable` (std/posix.zig:1081), so on a
/// socket where the kernel rejects the option the caller does not get an error
/// to `catch` — it **panics**. Measured on macOS: `setsockopt(SO_RCVTIMEO)` on an
/// `AF_UNIX` socket whose peer end has already closed returns `EINVAL`
/// (peer open → `SUCCESS`, peer closed → `INVAL`), so the `catch` below was dead
/// code and the process aborted instead. Over **TCP** the same call stays
/// `SUCCESS` after the peer closes, so the cluster/HTTP paths were never the
/// exposed ones — this is an AF_UNIX hazard, and the `socketpair`-based tests are
/// AF_UNIX.
///
/// Raw syscall + explicit errno, so every rejection is reportable. A failure is
/// only a warning: the bound is a hardening measure, and the caller's next read
/// or write still returns an error of its own.
fn applyTimeout(fd: std.posix.socket_t, optname: u32, tv: *const std.posix.timeval, what: []const u8, consequence: []const u8) void {
    const rc = std.posix.system.setsockopt(fd, std.posix.SOL.SOCKET, optname, @ptrCast(tv), @sizeOf(std.posix.timeval));
    const e = std.posix.errno(rc);
    if (e == .SUCCESS) return;
    std.log.warn("[sockread] {s} not applied ({s}): {s}", .{ what, @tagName(e), consequence });
}

/// Bound how long a blocking write may stall on a full send buffer.
///
/// Without this a slow (or maliciously non-reading) WS peer can block the
/// writing thread indefinitely — and, for `im.ConnectionRegistry`, while it
/// holds a shard lock. After the timeout the syscall returns `EAGAIN`, which
/// the write helpers surface as `error.WriteTimeout` so callers can disconnect
/// the peer. 0 disables the bound (previous behavior).
pub fn setSendTimeout(stream: std.Io.net.Stream, timeout_ms: u32) void {
    if (timeout_ms == 0) return;
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    applyTimeout(stream.socket.handle, std.posix.SO.SNDTIMEO, &tv, "SO_SNDTIMEO", "a slow peer can block the writer indefinitely");
}

/// Bound how long a blocking read may wait for peer data.
///
/// The mirror of `setSendTimeout` on the reading side, and the one that matters
/// for a *synchronous* RPC: a peer that accepts the connection and then never
/// answers blocks the caller forever, where a peer that refuses to connect only
/// costs the connect timeout. `SO_RCVTIMEO` bounds **each** blocking `read`, so
/// a peer trickling one byte per timeout still holds the caller — the same
/// per-call bound (and the same caveat) `setSendTimeout` documents.
///
/// A timed-out read comes back `EAGAIN`, which `readSome` folds into
/// `error.ConnectionError`: callers already treat "the peer went away" and "the
/// peer went quiet" as the same lost message, so this deliberately does not
/// invent a third error for them to switch on. 0 disables the bound.
pub fn setRecvTimeout(stream: std.Io.net.Stream, timeout_ms: u32) void {
    if (timeout_ms == 0) return;
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    applyTimeout(stream.socket.handle, std.posix.SO.RCVTIMEO, &tv, "SO_RCVTIMEO", "a peer that accepts and never replies can block the reader indefinitely");
}

/// Write all of `bytes` (loops on partial writes so frames are never split).
pub fn writeFull(stream: std.Io.net.Stream, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.posix.system.write(stream.socket.handle, bytes[sent..].ptr, bytes[sent..].len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return error.WriteTimeout,
            else => return error.ConnectionError,
        }
        const n: usize = @intCast(rc);
        if (n == 0) return error.ConnectionClosed;
        sent += n;
    }
}

/// Write all segments with a single `writev` syscall (header + body in one
/// call). Falls back to per-segment writes only on a rare partial write.
pub fn writevAll(stream: std.Io.net.Stream, parts: []const []const u8) !void {
    var iovecs: [16]std.posix.iovec_const = undefined;
    var total: usize = 0;
    var count: usize = 0;
    while (count < parts.len and count < iovecs.len) : (count += 1) {
        iovecs[count] = .{ .base = parts[count].ptr, .len = parts[count].len };
        total += parts[count].len;
    }
    if (count == 0) return;

    var sent: usize = 0;
    while (sent < total) {
        const rc = std.posix.system.writev(stream.socket.handle, &iovecs, @intCast(count));
        const got = switch (std.posix.errno(rc)) {
            .SUCCESS => @as(usize, @intCast(rc)),
            .AGAIN => return error.WriteTimeout,
            else => return error.ConnectionError,
        };
        if (got == 0) return error.ConnectionClosed;
        sent += got;
        if (sent < total) {
            // Rare partial write: finish the remaining bytes per segment.
            var seg_end: usize = 0;
            for (parts[0..count]) |p| {
                if (sent >= seg_end + p.len) {
                    seg_end += p.len;
                    continue;
                }
                const off = if (sent > seg_end) sent - seg_end else 0;
                if (off < p.len) try writeFull(stream, p[off..]);
                seg_end += p.len;
            }
            return;
        }
    }
}

/// Buffered socket reader: collapses many small reads into one larger syscall.
/// `buf` is caller-owned (e.g. 4-8KB) and reused across calls.
pub const Reader = struct {
    stream: std.Io.net.Stream,
    buf: []u8,
    start: usize = 0,
    end: usize = 0,

    pub fn init(stream: std.Io.net.Stream, buf: []u8) Reader {
        return .{ .stream = stream, .buf = buf };
    }

    /// Read exactly `out.len` bytes, serving from the cache first and
    /// refilling with a single larger read.
    pub fn readFull(self: *Reader, out: []u8) !void {
        var filled: usize = 0;
        while (filled < out.len) {
            if (self.start < self.end) {
                const n = @min(self.end - self.start, out.len - filled);
                @memcpy(out[filled..][0..n], self.buf[self.start..][0..n]);
                self.start += n;
                filled += n;
            } else {
                const n = try readSome(self.stream, self.buf);
                if (n == 0) return error.ConnectionClosed;
                self.start = 0;
                self.end = n;
            }
        }
    }
};

// Verified red: the previous `std.posix.setsockopt` call made this **panic**
// (`reached unreachable code`, std/posix.zig:1081) rather than return, because
// macOS answers `EINVAL` for `SO_RCVTIMEO` on an `AF_UNIX` socket whose peer end
// has closed (measured: peer open → SUCCESS, peer closed → INVAL). That is an
// abort, not an assertion failure — there is nothing to assert before it.
//
// Over TCP the same call stays SUCCESS after the peer closes, which is why the
// cluster/HTTP paths never hit this; the exposure is AF_UNIX, and every
// `socketpair`-based test in this repo is AF_UNIX.
test "applying a timeout on a closed-peer socket warns instead of panicking" {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer _ = std.posix.system.close(fds[0]);

    // Peer alive: both apply cleanly.
    setRecvTimeout(stream, 100);
    setSendTimeout(stream, 100);

    // Peer gone: the kernel rejects the read-side option (that one is the measured
    // case). Either way the requirement is the same — return, do not panic.
    _ = std.posix.system.close(fds[1]);
    setRecvTimeout(stream, 100);
    setSendTimeout(stream, 100);
}

test "readSome returns EOF on closed socketpair" {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    _ = std.posix.system.close(fds[1]);
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    var buf: [16]u8 = undefined;
    const n = try readSome(stream, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "Reader serves many small reads from one refill" {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const peer = std.Io.net.Stream{ .socket = .{ .handle = fds[1], .address = undefined } };
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer peer.close(std.testing.io);
    defer stream.close(std.testing.io);
    _ = std.posix.system.write(fds[1], "hello", 5);

    var rbuf: [64]u8 = undefined;
    var reader = Reader.init(stream, &rbuf);
    var out: [5]u8 = undefined;
    try reader.readFull(out[0..2]);
    try reader.readFull(out[2..4]);
    try reader.readFull(out[4..5]);
    try std.testing.expectEqualStrings("hello", &out);
}

test "writevAll sends multiple segments as one stream" {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    const parts = [_][]const u8{ "AB", "CDEF" };
    try writevAll(stream, &parts);
    var out: [6]u8 = undefined;
    const n = try std.posix.read(fds[1], &out);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualStrings("ABCDEF", &out);
    _ = std.posix.system.close(fds[1]);
}

test "writeFull reports WriteTimeout on a non-reading peer" {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    // Nobody reads fds[1]: with a send timeout the write must give up instead
    // of blocking forever.
    setSendTimeout(stream, 50);
    var chunk: [16 * 1024]u8 = @splat('x');
    var i: usize = 0;
    var timed_out = false;
    while (i < 512) : (i += 1) {
        writeFull(stream, &chunk) catch |err| switch (err) {
            error.WriteTimeout => {
                timed_out = true;
                break;
            },
            else => return err,
        };
    }
    try std.testing.expect(timed_out);
}

test "setSendTimeout(0) keeps the blocking default" {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    setSendTimeout(stream, 0); // no-op
    try writeFull(stream, "hello");
    var buf: [5]u8 = undefined;
    const n = try std.posix.read(fds[1], &buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}
