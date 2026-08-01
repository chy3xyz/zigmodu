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

/// Write all of `bytes` (loops on partial writes so frames are never split).
pub fn writeFull(stream: std.Io.net.Stream, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.posix.system.write(stream.socket.handle, bytes[sent..].ptr, bytes[sent..].len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
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
