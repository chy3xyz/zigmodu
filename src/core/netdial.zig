//! Blocking TCP connect without std's EINTR→EISCONN panic.
//!
//! `std.Io.Threaded.posixConnect` (Threaded.zig:12194-12224 on
//! 0.17.0-dev.2151+2ec5523d5) drives a blocking `connect(2)` like this:
//!
//! ```zig
//! .INTR => { try syscall.checkCancel(); continue; },  // retry on the SAME socket
//! .ISCONN => |err| return syscall.errnoBug(err),       // panic
//! ```
//!
//! POSIX says a blocking connect interrupted by a signal is **not** aborted:
//! the connection is established asynchronously, and a retry on the same socket
//! then reports `EISCONN` — which *is* the success report. std reads that
//! errno as a programmer bug and panics. So any signal without a handler that
//! merely lands inside a blocking dial — SIGTERM during shutdown being the
//! measured case — kills the process, and on loopback (where the handshake
//! completes in microseconds) the retry hits EISCONN almost every time.
//!
//! Measured: `bash scripts/ci-mixed-version.sh`, node mv-c SIGTERMed during a
//! raft heartbeat dial → exit 134 (SIGABRT), stack `posixConnect` ←
//! `netConnectIpPosix` ← `Io.net.IpAddress.connect` ←
//! `HarnessTransport.sendAppendEntries` ← `RaftElection.tick`.
//!
//! `connectBlocking` is the same blocking dial built from raw syscalls, with
//! `classifyConnectErrno` reading EISCONN as connected — the POSIX-correct
//! table. Every other errno keeps std's exact error names, so call sites swap
//! `addr.connect(io, .{ .mode = .stream })` for `connectBlocking(io, addr)`
//! without touching their `try`/`catch` shapes. When std fixes posixConnect
//! upstream this helper stays harmless: it is the same syscall sequence with
//! the right errno table.
//!
//! POSIX-only by construction (the raw-syscall layer is the one
//! `sockread.zig` is built on); on Windows, where WSA's blocking connect has
//! no EINTR/EISCONN asymmetry, `connectBlocking` delegates to std's own
//! `IpAddress.connect`.

const std = @import("std");
const builtin = @import("builtin");

/// Exactly the error names `std.Io.Threaded.posixConnect` (plus the `socket(2)`
/// table `netConnectIpPosix` applies around it) can produce — a subset of
/// `std.Io.net.IpAddress.ConnectError`, so any function that returned the
/// std dial's result can return this one unchanged.
pub const ConnectError = error{
    AddressUnavailable,
    AddressFamilyUnsupported,
    SystemResources,
    ConnectionPending,
    ConnectionRefused,
    ConnectionResetByPeer,
    HostUnreachable,
    NetworkUnreachable,
    Timeout,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    ProtocolUnsupportedBySystem,
    ProtocolUnsupportedByAddressFamily,
    SocketModeUnsupported,
    AccessDenied,
    WouldBlock,
    NetworkDown,
    Unexpected,
};

/// What one `connect(2)` errno means for a blocking dial. Pure data — the
/// whole policy of this file, unit-tested per arm so a regression in the
/// table (e.g. ISCONN read as a bug again) fails a test, not a process.
pub const ConnectVerdict = union(enum) {
    /// The connection is established: SUCCESS, or ISCONN on an EINTR retry.
    connected,
    /// EINTR: the attempt is still in flight asynchronously; call connect again.
    retry,
    /// Terminal failure, mapped to std's name for the errno.
    failed: ConnectError,
    /// Not in the table. std `errnoBug`s (panics) on its "programmer bug" set —
    /// BADF/CONNABORTED/FAULT/NOENT/NOTSOCK/PERM/PROTOTYPE — but a dial must
    /// never take the process down: these surface as `error.Unexpected` via
    /// `std.posix.unexpectedErrno` at the call site. (On an fd created two
    /// syscalls ago they are unreachable anyway; EPERM is how a sandboxed
    /// macOS seatbelt answers connect, which is a *reportable* failure, not a
    /// bug — `test/NetworkProbe.zig` exists because std panics on exactly it.)
    unexpected: std.posix.E,
};

/// Classify one `connect(2)` errno for a blocking dial.
///
/// The two arms that differ from std's `posixConnect` and why:
///   - `.ISCONN` → `connected`. POSIX: "If connect() is interrupted by a
///     signal ... the connection request shall not be aborted, and the
///     connection shall be established asynchronously." Once it has been, the
///     retry answers EISCONN. std maps it to `errnoBug` — the panic this file
///     exists to bypass.
///   - std's `errnoBug` set → `unexpected`, never a panic (see above).
///
/// `.ALREADY` keeps std's mapping (`ConnectionPending`): on a blocking socket
/// a retry while the attempt is still in flight reports EALREADY, and std's
/// callers already handle that error name. Widening it into a poll-wait would
/// change the *boundedness* contract of the dial — out of scope here.
pub fn classifyConnectErrno(e: std.posix.E) ConnectVerdict {
    return switch (e) {
        .SUCCESS, .ISCONN => .connected,
        .INTR => .retry,
        .ADDRNOTAVAIL => .{ .failed = error.AddressUnavailable },
        .AFNOSUPPORT => .{ .failed = error.AddressFamilyUnsupported },
        .AGAIN, .INPROGRESS => .{ .failed = error.WouldBlock },
        .ALREADY => .{ .failed = error.ConnectionPending },
        .CONNREFUSED => .{ .failed = error.ConnectionRefused },
        .CONNRESET => .{ .failed = error.ConnectionResetByPeer },
        .HOSTUNREACH => .{ .failed = error.HostUnreachable },
        .NETUNREACH => .{ .failed = error.NetworkUnreachable },
        .TIMEDOUT => .{ .failed = error.Timeout },
        .ACCES => .{ .failed = error.AccessDenied },
        .NETDOWN => .{ .failed = error.NetworkDown },
        else => .{ .unexpected = e },
    };
}

/// Connect to `addr` with a blocking socket, exactly like
/// `addr.connect(io, .{ .mode = .stream })` — minus the EINTR→EISCONN panic.
///
/// Unbounded, like the std call it replaces: a peer whose SYNs are dropped
/// still costs the kernel's default. Callers that need a bound want
/// `RaftTransport.connectTimeout` (non-blocking connect + poll), which never
/// retries a connect and so never had this trap.
pub fn connectBlocking(io: std.Io, addr: std.Io.net.IpAddress) ConnectError!std.Io.net.Stream {
    if (builtin.target.os.tag == .windows) {
        // WSA blocking connect has no EINTR/EISCONN asymmetry, and the raw
        // posix layer below does not exist on the target — std's own path is
        // the right one there.
        return addr.connect(io, .{ .mode = .stream });
    } else {
        // The POSIX path is raw syscalls and takes no io; the parameter still
        // counts as used through the branch above.
        return connectBlockingPosix(addr);
    }
}

/// The POSIX half, referenced only from the non-Windows branch above so a
/// Windows-targeted compile never analyzes it (`std.posix.system.connect` and
/// friends do not exist there).
fn connectBlockingPosix(addr: std.Io.net.IpAddress) ConnectError!std.Io.net.Stream {
    var storage: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &storage);

    // Raw syscalls, not the `std.posix.*` wrappers — the same shape as
    // `RaftTransport.connectTimeout` and for the same reason: this call has to
    // be able to *return* an error, and the wrappers map several errno values
    // onto `unreachable`/`errnoBug`.
    const rc = std.posix.system.socket(std.Io.Threaded.posixAddressFamily(&addr), std.posix.SOCK.STREAM, 0);
    const fd: std.posix.socket_t = switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .INVAL => return error.ProtocolUnsupportedBySystem,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
        .PROTOTYPE => return error.SocketModeUnsupported,
        else => |e| return std.posix.unexpectedErrno(e),
    };
    errdefer std.Io.Threaded.closeFd(fd);

    // macOS rejects SOCK.CLOEXEC as a socket() flag (same measured reason
    // `RaftTransport.connectTimeout` sets it by hand), so CLOEXEC goes on with
    // fcntl on every POSIX target.
    if (fcntlSet(fd, std.posix.F.SETFD, std.posix.FD_CLOEXEC)) |e| return std.posix.unexpectedErrno(e);

    while (true) {
        switch (classifyConnectErrno(std.posix.errno(std.posix.system.connect(fd, &storage.any, addr_len)))) {
            .connected => break,
            .retry => continue,
            .failed => |err| return err,
            .unexpected => |e| return std.posix.unexpectedErrno(e),
        }
    }

    // Hand back the same state std's `netConnectIpPosix` does: a blocking
    // socket whose `address` is the *local* endpoint `getsockname` reports
    // (i.e. the ephemeral port). The name is best-effort there too — a failure
    // leaves a perfectly usable stream.
    var local: std.Io.Threaded.PosixAddress = undefined;
    var local_len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    const local_addr = if (std.posix.errno(std.posix.system.getsockname(fd, &local.any, &local_len)) == .SUCCESS)
        std.Io.Threaded.addressFromPosix(&local)
    else
        addr;
    return .{ .socket = .{ .handle = fd, .address = local_addr } };
}

/// `fcntl` with the error reported as a value — this toolchain's `std.posix`
/// has no `fcntl` wrapper, and the raw call is what `sockread.applyTimeout`
/// does for `setsockopt` for the same reason (the wrapper maps rejections to
/// `unreachable`).
fn fcntlSet(fd: std.posix.socket_t, cmd: i32, arg: u32) ?std.posix.E {
    const e = std.posix.errno(std.posix.system.fcntl(fd, cmd, @as(usize, arg)));
    return if (e == .SUCCESS) null else e;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectFailed(expected: ConnectError, verdict: ConnectVerdict) !void {
    switch (verdict) {
        .failed => |err| try testing.expectEqual(expected, err),
        else => return error.TestExpectedFailedVerdict,
    }
}

test "classifyConnectErrno: SUCCESS and ISCONN both mean connected" {
    try testing.expectEqual(ConnectVerdict.connected, classifyConnectErrno(.SUCCESS));
    // The arm this file exists for: EISCONN is the success report of a
    // connection an interrupted blocking connect established asynchronously —
    // std's posixConnect reads it as a programmer bug and panics.
    try testing.expectEqual(ConnectVerdict.connected, classifyConnectErrno(.ISCONN));
}

test "classifyConnectErrno: INTR retries on the same socket" {
    try testing.expectEqual(ConnectVerdict.retry, classifyConnectErrno(.INTR));
}

test "classifyConnectErrno: named failures keep std's error names" {
    try expectFailed(error.AddressUnavailable, classifyConnectErrno(.ADDRNOTAVAIL));
    try expectFailed(error.AddressFamilyUnsupported, classifyConnectErrno(.AFNOSUPPORT));
    try expectFailed(error.WouldBlock, classifyConnectErrno(.AGAIN));
    try expectFailed(error.WouldBlock, classifyConnectErrno(.INPROGRESS));
    try expectFailed(error.ConnectionPending, classifyConnectErrno(.ALREADY));
    try expectFailed(error.ConnectionRefused, classifyConnectErrno(.CONNREFUSED));
    try expectFailed(error.ConnectionResetByPeer, classifyConnectErrno(.CONNRESET));
    try expectFailed(error.HostUnreachable, classifyConnectErrno(.HOSTUNREACH));
    try expectFailed(error.NetworkUnreachable, classifyConnectErrno(.NETUNREACH));
    try expectFailed(error.Timeout, classifyConnectErrno(.TIMEDOUT));
    try expectFailed(error.AccessDenied, classifyConnectErrno(.ACCES));
    try expectFailed(error.NetworkDown, classifyConnectErrno(.NETDOWN));
}

test "classifyConnectErrno: std's panic set is unexpected, never a bug" {
    // std's posixConnect feeds these to `errnoBug` (panic). Here they are a
    // reportable `error.Unexpected` instead — a dial must not kill the
    // process no matter what the kernel answers.
    const panic_set = [_]std.posix.E{ .BADF, .CONNABORTED, .FAULT, .NOENT, .NOTSOCK, .PERM, .PROTOTYPE };
    for (panic_set) |e| {
        switch (classifyConnectErrno(e)) {
            .unexpected => |got| try testing.expectEqual(e, got),
            else => return error.TestExpectedUnexpectedVerdict,
        }
    }
}

test "connectBlocking dials a loopback listener and the stream reads and writes" {
    const io = testing.io;
    if (!netTestsAvailable()) return error.SkipZigTest;

    const bind = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try bind.listen(io, .{});
    defer server.deinit(io);

    var client = try connectBlocking(io, try std.Io.net.IpAddress.parse("127.0.0.1", server.socket.address.getPort()));
    defer client.close(io);
    var accepted = try server.accept(io);
    defer accepted.close(io);

    // The stream is blocking, like every socket std.Io hands out: a socket
    // left non-blocking would come back EAGAIN from these raw calls (and the
    // WebSocket write path treats EAGAIN as a programmer bug), so a clean
    // round trip is the proof. Raw syscalls rather than the repo's sockread
    // helpers: netdial is the layer dial paths fall back to when std
    // misbehaves, so its tests stay self-contained (std-only) on purpose.
    try rawWriteAll(client.socket.handle, "ping");
    var buf: [4]u8 = undefined;
    try rawReadFull(accepted.socket.handle, &buf);
    try testing.expectEqualStrings("ping", &buf);
}

test "connectBlocking to a closed port reports ConnectionRefused" {
    const io = testing.io;
    if (!netTestsAvailable()) return error.SkipZigTest;

    // Bind, take the port, close: the kernel then answers the dial with
    // ECONNREFUSED on loopback (the same trick RaftTransport's tests use).
    const bind = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var gone = try bind.listen(io, .{});
    const gone_port = gone.socket.address.getPort();
    gone.deinit(io);

    try testing.expectError(error.ConnectionRefused, connectBlocking(io, try std.Io.net.IpAddress.parse("127.0.0.1", gone_port)));
}

/// `test/NetworkProbe.zig`'s probe, inlined: same loopback check, same
/// seatbelt reading (EPERM/EACCES → skip), but netdial keeps its tests
/// std-only on purpose — it is the layer dial paths fall back to when std
/// itself misbehaves, so its self-checks do not lean on repo helpers built
/// over the same std layers.
fn netTestsAvailable() bool {
    if (!@import("build_options").net_tests) return false;
    const rc = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    const fd: std.posix.socket_t = switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => return false,
    };
    defer std.Io.Threaded.closeFd(fd);
    var storage: std.Io.Threaded.PosixAddress = undefined;
    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 1 } };
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &storage);
    return switch (std.posix.errno(std.posix.system.connect(fd, &storage.any, addr_len))) {
        .SUCCESS => true,
        .PERM, .ACCES => false, // sandboxed (macOS seatbelt): report, never panic
        else => true, // e.g. ECONNREFUSED → network works, port just closed
    };
}

fn rawWriteAll(fd: std.posix.socket_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.c.send(fd, bytes[sent..].ptr, bytes.len - sent, std.posix.MSG.NOSIGNAL);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.WriteFailed,
        }
        sent += @intCast(rc);
    }
}

fn rawReadFull(fd: std.posix.socket_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.posix.system.read(fd, buf[got..].ptr, buf.len - got);
        switch (std.posix.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        const nn: usize = @intCast(n);
        if (nn == 0) return error.Eof;
        got += nn;
    }
}
