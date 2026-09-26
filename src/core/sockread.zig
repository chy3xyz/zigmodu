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

/// Make a syscall already parked on `fd` return **now**.
///
/// `shutdown()` is what does it, and the same call covers both directions of the
/// same problem: a listener parked in `accept` (see `closeListener`, EINVAL) and
/// a connection parked in `read` — a peer that completes a handshake and then
/// sends nothing, and never hangs up, leaves the reading fiber there for as long
/// as it likes, and whoever drains that fiber (`Io.Group.await`) waits with it.
/// The parked read comes back as EOF, which every read loop in the tree already
/// treats as "the peer went away". `close()` alone wakes neither on Linux: the
/// kernel keeps the socket alive for the in-flight syscall.
///
/// Errors are expected and ignored — ENOTCONN on a socket that is not connected,
/// EINVAL for a listener on macOS — because a caller that gets no error had
/// nothing blocked to begin with.
///
/// Deliberately not an idle / `SO_RCVTIMEO` bound: a long quiet period is a
/// *normal* WebSocket state, so a timeout would cut healthy connections, whereas
/// this only ever fires because someone is shutting the socket down.
pub fn wakeBlockedSyscall(fd: std.posix.socket_t) void {
    _ = std.c.shutdown(fd, std.c.SHUT.RDWR);
}

/// Close a listening socket so a thread already blocked in `accept()` returns.
///
/// `wakeBlockedSyscall` is the shutdown half, and the reason it is not optional:
/// `close()` alone does not wake an in-flight `accept` on Linux, so the accept
/// loop stays blocked and whoever is waiting for it — a `Thread.join`, an
/// `Io.Group.await` — waits with it. The symptom is a `stop()` that never
/// returns, which is a hang, not a shutdown. `shutdown()` on a listening socket
/// makes that `accept` fail immediately (EINVAL). Errors are expected (macOS
/// answers ENOTCONN for a listener) and ignored: the fd is closed either way, and
/// a caller that gets no error had nothing blocked to begin with.
pub fn closeListener(io: std.Io, listener: *std.Io.net.Server) void {
    wakeBlockedSyscall(listener.socket.handle);
    listener.deinit(io);
}

/// Bound how long a blocking write may stall on a full send buffer.
///
/// Without this a slow (or maliciously non-reading) WS peer can block the
/// writing thread indefinitely — and, for `im.ConnectionRegistry`, while it
/// holds a shard lock. After the timeout the syscall returns `EAGAIN`, which
/// the write helpers surface as `error.WriteTimeout` so callers can disconnect
/// the peer. 0 disables the bound (previous behavior).
///
/// The option is **fd-global and not harmless to leave armed**: `std.Io`'s
/// writers answer a timed-out send with `errnoBug` (`unreachable`). So it is for
/// a *section of code that owns the fd's writes*, not for a connection's whole
/// life: arm it, do the bounded writes, and `clearSendTimeout` on the way out
/// (see the note there).
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

/// What a bounded write on this file can fail with, named so the writers that
/// remember their first failure (`BoundedWriter.failed`, `ConnWriter.failed`)
/// can do so **without widening their callers' inferred error sets** — an
/// `anyerror` field read back and returned turns every exhaustive `switch (err)`
/// up the stack into a compile error about a missing `else`.
pub const WriteError = error{ WriteTimeout, ConnectionError, ConnectionClosed };

/// Write all of `bytes` (loops on partial writes so frames are never split).
///
/// `send(MSG_NOSIGNAL)`, not `write`, and that matters: a peer whose socket is
/// already closed — or **reset**, which is what a crashed client leaves behind —
/// makes a plain `write` raise `SIGPIPE`, and its default action terminates the
/// process. Measured on macOS against a `socketpair` whose peer end is closed:
/// `write` → the process is killed (exit 141), `send(MSG_NOSIGNAL)` → `-1`/`EPIPE`,
/// which is the `error.ConnectionError` below. `RaftTransport.sendAll` made this
/// switch for the same reason; every raw write in this file has to.
///
/// `std.Io`'s own writer is not the alternative: it sets `MSG_NOSIGNAL` too
/// (`Threaded.netWritePosix`), but it answers a timed-out send with `errnoBug` —
/// `unreachable` — so a *bounded* write cannot be expressed through it at all.
/// A bound has to be the socket's own (`setSendTimeout`) plus this helper, which
/// is what `writeResponse` does around the response it writes.
pub fn writeFull(stream: std.Io.net.Stream, bytes: []const u8) WriteError!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.c.send(stream.socket.handle, bytes[sent..].ptr, bytes.len - sent, std.posix.MSG.NOSIGNAL);
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

/// Undo `setSendTimeout`: back to the blocking default.
///
/// Needed because `SO_SNDTIMEO` is **fd-global**, and the option is not harmless
/// to leave on: `std.Io`'s writers answer a timed-out send with `errnoBug`
/// (`Threaded.netWritePosix` — `unreachable`), so an armed socket that a
/// `stream.writer(io, …)` writes to turns the timeout into a panic. A caller that
/// arms the bound for one bounded write (`writeFullBounded` does) has to clear it
/// on the way out, including the error paths — that is what makes "the bound is
/// armed only while this fiber owns the fd for writes" true rather than hopeful.
///
/// A kernel that will not clear it is warned about, like every other option here.
pub fn clearSendTimeout(stream: std.Io.net.Stream) void {
    const tv = std.posix.timeval{ .sec = 0, .usec = 0 };
    applyTimeout(stream.socket.handle, std.posix.SO.SNDTIMEO, &tv, "SO_SNDTIMEO (clear)", "an armed timeout would outlive the write it was meant to bound");
}

/// Write all of `bytes` with the send bound armed for exactly this call
/// (`timeout_ms` 0 = `writeFull`'s unbounded behavior).
///
/// Armed and cleared **per call**, not once per connection, and that is the
/// point: `SO_SNDTIMEO` is fd-global and `std.Io`'s writers answer a timed-out
/// send with `errnoBug` (`unreachable`), so a socket left armed turns a peer's
/// silence into a panic for anything else that writes to it. Two `setsockopt`s
/// per bounded write is what makes the bound *provable* rather than a convention
/// about who else may write to this fd.
pub fn writeFullBounded(stream: std.Io.net.Stream, bytes: []const u8, timeout_ms: u32) WriteError!void {
    if (timeout_ms == 0) return writeFull(stream, bytes);
    setSendTimeout(stream, timeout_ms);
    defer clearSendTimeout(stream);
    return writeFull(stream, bytes);
}

/// A socket writer with a caller-owned buffer, raw syscalls and a bounded send.
///
/// Why not `stream.writer(io, …)`: that one cannot express the bound at all (see
/// `writeFullBounded`). Why buffered at all: it is what keeps a small response —
/// a field section plus a small body — **one** syscall.
///
/// `write` takes bytes of any size (a body bigger than the buffer goes straight
/// out without a copy); `print` formats one piece into the buffer. A single
/// `print` that cannot fit an **empty** buffer is `error.LineTooLong` rather than
/// a split line: the callers where that can only be a protocol violation (an HTTP
/// field section) answer it with a 500, and the ones where a long piece is legal
/// (streaming bodies, SSE events) use `write`.
pub const BoundedWriter = struct {
    stream: std.Io.net.Stream,
    buf: []u8,
    len: usize = 0,
    timeout_ms: u32 = 0,
    /// The first write failure, kept for the life of the writer — see
    /// `ConnWriter.failed` in `http/Http2Server.zig` for what going without it
    /// costs (a timed-out flush clears the buffer, so the next flush is a
    /// no-op that reports success on a socket that is already done).
    failed: ?WriteError = null,

    pub fn init(stream: std.Io.net.Stream, buf: []u8, timeout_ms: u32) BoundedWriter {
        return .{ .stream = stream, .buf = buf, .timeout_ms = timeout_ms };
    }

    pub fn print(self: *BoundedWriter, comptime fmt: []const u8, args: anytype) !void {
        while (true) {
            if (std.fmt.bufPrint(self.buf[self.len..], fmt, args)) |written| {
                self.len += written.len;
                return;
            } else |err| switch (err) {
                error.NoSpaceLeft => {
                    if (self.len == 0) return error.LineTooLong;
                    try self.flush();
                },
            }
        }
    }

    pub fn write(self: *BoundedWriter, bytes: []const u8) !void {
        if (self.failed) |err| return err;
        if (bytes.len <= self.buf.len - self.len) {
            @memcpy(self.buf[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
            return;
        }
        try self.flush();
        if (bytes.len <= self.buf.len) {
            @memcpy(self.buf[0..bytes.len], bytes);
            self.len = bytes.len;
            return;
        }
        return self.writeDirect(bytes);
    }

    fn writeDirect(self: *BoundedWriter, bytes: []const u8) !void {
        return writeFullBounded(self.stream, bytes, self.timeout_ms) catch |err| {
            self.failed = err;
            return err;
        };
    }

    pub fn flush(self: *BoundedWriter) !void {
        if (self.failed) |err| return err;
        if (self.len == 0) return;
        const pending = self.buf[0..self.len];
        self.len = 0;
        try self.writeDirect(pending);
    }
};

/// Write all segments with a single `sendmsg` syscall (header + body in one
/// call). Falls back to per-segment writes only on a rare partial write.
///
/// `sendmsg(MSG_NOSIGNAL)`, not `writev`: same reason `writeFull` gives — a peer
/// that already reset its socket turns a plain `writev` into `SIGPIPE` and the
/// process dies. This is the WebSocket frame path, where a client that crashes
/// mid-fan-out is exactly the peer that does it.
pub fn writevAll(stream: std.Io.net.Stream, parts: []const []const u8) !void {
    var iovecs: [16]std.posix.iovec_const = undefined;
    var total: usize = 0;
    var count: usize = 0;
    while (count < parts.len and count < iovecs.len) : (count += 1) {
        iovecs[count] = .{ .base = parts[count].ptr, .len = parts[count].len };
        total += parts[count].len;
    }
    if (count == 0) return;

    const msg: std.posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = @intCast(count),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    var sent: usize = 0;
    while (sent < total) {
        const rc = std.c.sendmsg(stream.socket.handle, &msg, std.posix.MSG.NOSIGNAL);
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

test "BoundedWriter keeps failing after a failed write" {
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
    var w = BoundedWriter.init(stream, &buf, 200);
    try w.write("hello");
    try std.testing.expectError(error.ConnectionError, w.flush());
    // Same invariant as `ConnWriter` (see `failed`): the buffer is empty now, so
    // a flush that only looked at `len` would answer with success on a socket
    // that is already done.
    try std.testing.expectError(error.ConnectionError, w.flush());
    try std.testing.expectError(error.ConnectionError, w.write("more"));
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

test "writeFull and writevAll report a peer that is gone instead of dying of SIGPIPE" {
    // What this pins: both helpers turn "the peer is gone" into
    // `error.ConnectionError` rather than a process dead from SIGPIPE.
    //
    // **It cannot go red here.** Zig's test runner ignores SIGPIPE for the test
    // process (measured: inside `zig test`, the same raw `write` below returns
    // `EPIPE`), so a `write`-based implementation also passes this. The red was
    // measured *outside* a test process, with a two-line standalone binary doing
    // exactly this `socketpair` + close + `write`: **exit 141** (killed by
    // SIGPIPE) with `write`, and `-1`/`EPIPE` — the error below — with
    // `send(MSG_NOSIGNAL)`. That is the defect: in a real application the default
    // SIGPIPE action terminates the process (`Application.zig` installs handlers
    // for INT/TERM, not PIPE).
    //
    // The peer is closed *before* the write on purpose: over TCP a graceful FIN
    // lets the next write succeed (the bytes sit in the send buffer), so TCP
    // cannot make this deterministic. The peer that matters in production is the
    // one that has **reset** — a crashed WebSocket client — and a closed AF_UNIX
    // peer gives the same `EPIPE` on the spot.
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    _ = std.posix.system.close(fds[1]);

    try std.testing.expectError(error.ConnectionError, writeFull(stream, "x"));
    try std.testing.expectError(error.ConnectionError, writevAll(stream, &.{ "x", "y" }));
}

test "the send bound clears: the socket reports the option it was given, and 0 after" {
    // What makes arm-then-write-then-clear a *section* rather than a permanent
    // change to the fd: the kernel is asked, not trusted. A socket left armed
    // would take any `std.Io` writer on it down with `errnoBug` the first time a
    // send timed out.
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    defer _ = std.posix.system.close(fds[1]);

    // Unset to begin with.
    try expectSendTimeoutMs(stream, 0);

    setSendTimeout(stream, 250);
    try expectSendTimeoutMs(stream, 250);

    clearSendTimeout(stream);
    try expectSendTimeoutMs(stream, 0);

    // And `setSendTimeout(0)` is the no-op the other test relies on.
    setSendTimeout(stream, 0);
    try expectSendTimeoutMs(stream, 0);
}

fn expectSendTimeoutMs(stream: std.Io.net.Stream, ms: u64) !void {
    var tv: std.posix.timeval = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    const rc = std.posix.system.getsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, @ptrCast(&tv), &len);
    // macOS rejects the option on an AF_UNIX socket whose peer is gone; here the
    // peer is alive, so a rejection is a real failure.
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(rc));
    try std.testing.expectEqual(@as(i64, @intCast(ms / 1000)), @as(i64, tv.sec));
    try std.testing.expectEqual(@as(i64, @intCast((ms % 1000) * 1000)), @as(i64, tv.usec));
}
