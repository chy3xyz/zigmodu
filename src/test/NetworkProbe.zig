//! Loopback TCP availability probe for tests that need real sockets.
//!
//! Sandboxed or restricted environments (macOS seatbelt, containers without
//! network permission, CI runners with blocked outbound sockets) return
//! EPERM/EACCES from `connect()`. `std.Io` classifies that errno as a
//! programmer bug and panics, which aborts the whole test binary. This probe
//! uses raw syscalls (which return errors instead of panicking) so tests can
//! `return error.SkipZigTest` in such environments instead of crashing.

const std = @import("std");

/// Returns true when loopback TCP connections are permitted.
pub fn available() bool {
    const rc = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    const fd: std.posix.socket_t = switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => return false,
    };
    defer std.Io.Threaded.closeFd(fd);

    var storage: std.Io.Threaded.PosixAddress = undefined;
    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 1 } };
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &storage);
    const connect_rc = std.posix.system.connect(fd, &storage.any, addr_len);
    return switch (std.posix.errno(connect_rc)) {
        .SUCCESS => true,
        .PERM, .ACCES => false,
        else => true, // e.g. ConnectionRefused → network works, port just closed.
    };
}

test "NetworkProbe returns a stable answer" {
    // The probe must never panic; in restricted environments it reports false,
    // everywhere else true. Either way the call itself must succeed.
    _ = available();
}
