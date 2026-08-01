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

/// Wait until `stream` is readable, then read once into `buf`.
/// Returns bytes read (possibly fewer than `buf.len`); 0 means the peer
/// closed the connection.
pub fn readSome(stream: std.Io.net.Stream, buf: []u8) !usize {
    var fds = [_]std.posix.pollfd{.{
        .fd = stream.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, -1) catch return error.ConnectionError;
    if (ready == 0) return error.ConnectionError;
    if ((fds[0].revents & std.posix.POLL.IN) == 0) {
        if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) return 0;
        return error.ConnectionError;
    }
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
