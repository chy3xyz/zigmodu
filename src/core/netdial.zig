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
//! `connectTimeout` is the bounded half of the same toolbox: non-blocking
//! `connect(2)` + `poll` + `SO_ERROR` on POSIX, non-blocking `connect` +
//! `WSAPoll` + `SO_ERROR` over ws2_32 on Windows. It exists because std's
//! `IpAddress.ConnectOptions.timeout` field is a trap on this toolchain —
//! neither `std.Io` backend implements it (`std/Io/Threaded.zig:12358` is
//! `@panic("TODO implement netConnectIpPosix with timeout")`, and the Windows
//! one below it is the same; measured on 0.17.0-dev.2151+2ec5523d5, passing a
//! `.timeout` and dialling `127.0.0.1:1` aborts the process with that panic).
//! The implementation was lifted out of `cluster/RaftTransport.zig`, which
//! re-exports it, so the raft's dial notes there apply here unchanged.
//!
//! POSIX-only by construction (the raw-syscall layer is the one
//! `sockread.zig` is built on); on Windows, where WSA's blocking connect has
//! no EINTR/EISCONN asymmetry, `connectBlocking` delegates to std's own
//! `IpAddress.connect`.

const std = @import("std");
const builtin = @import("builtin");
const Time = @import("Time.zig");

const log = std.log.scoped(.netdial);
/// Exactly the error names `std.Io.Threaded.posixConnect` (plus the `socket(2)`
/// table `netConnectIpPosix` applies around it) can produce — a subset of
/// `std.Io.net.IpAddress.ConnectError`, so any function that returned the
/// std dial's result can return this one unchanged. The last two members are
/// not produced by the raw-syscall POSIX path; they exist because the Windows
/// branch delegates to `IpAddress.connect`, whose set includes both — without
/// them that delegation itself does not compile for a Windows target.
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
    Canceled,
    OptionUnsupported,
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
/// `connectTimeout` below (non-blocking connect + poll), which never
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
    // `connectTimeoutPosix` below and for the same reason: this call has to
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
    // `connectTimeoutPosix` below sets it by hand), so CLOEXEC goes on with
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

// ── Bounded dial: non-blocking connect + poll + SO_ERROR ────────────────────

/// `IpAddress.ConnectError` plus the one error std's connect cannot report on
/// this toolchain, because it never reaches the kernel to find out.
pub const ConnectTimeoutError = std.Io.net.IpAddress.ConnectError || error{ConnectTimeout};

/// Connect to `addr`, giving up `timeout_ms` after the call starts. `0` means
/// no bound — `sockread.setRecvTimeout`'s convention, and what lets a pre-fix
/// `rpc_timeout_ms = 0` config keep the unbounded behaviour.
///
/// The returned stream is **blocking**, like every other socket `std.Io` hands
/// out: `sockread.readSome` is a bare `read` and `writeFull` a bare `write`, so
/// a non-blocking socket would come back `EAGAIN` — which the WebSocket write
/// path, for one, treats as a programmer bug and panics on in debug builds.
///
/// Windows dials the same bounded shape over ws2_32 (`connectTimeoutWindows`:
/// non-blocking `connect` + `WSAPoll` + `SO_ERROR`), because std's Windows
/// dial has the same unimplemented-timeout trap as the POSIX one and std
/// exposes no poll there — its own Windows networking talks to the AFD driver
/// directly, so the handful of ws2_32 symbols the dial needs is declared in
/// the `wsa` block below.
///
/// The unbounded `timeout_ms == 0` escape goes through `connectBlocking` on
/// every target: std's blocking connect panics when a signal interrupts it
/// (EINTR retry → EISCONN → `errnoBug`; see the module doc above). On Windows
/// `connectBlocking` delegates back to std, which is fine there — a blocking
/// WSA connect has no EINTR/EISCONN asymmetry.
pub fn connectTimeout(io: std.Io, addr: std.Io.net.IpAddress, timeout_ms: u32) ConnectTimeoutError!std.Io.net.Stream {
    if (timeout_ms == 0) return connectBlocking(io, addr);
    if (builtin.target.os.tag == .windows) return connectTimeoutWindows(addr, timeout_ms);
    return connectTimeoutPosix(addr, timeout_ms);
}

/// The POSIX half of `connectTimeout`: non-blocking `connect(2)` + `poll` +
/// `SO_ERROR` over raw syscalls. Kept behind its own function — not just an
/// early `return` above — so a Windows-targeted compile never analyzes it:
/// Zig skips the not-taken branch of a comptime condition but still analyzes
/// the code that *follows* it, and this half's `std.posix` surface (`pollfd`,
/// `fcntl`, raw `socket`) does not exist on Windows.
fn connectTimeoutPosix(addr: std.Io.net.IpAddress, timeout_ms: u32) ConnectTimeoutError!std.Io.net.Stream {
    var storage: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &storage);

    // Raw syscalls, not the `std.posix.*` wrappers: this call has to be able to
    // *return* an error, and the wrappers map several errno values onto
    // `unreachable` (`std.posix.poll`'s `.FAULT`/`.INVAL`, `setsockopt`'s
    // `.INVAL` — the reason `sockread` exists at all). Same shape as
    // `sockread.applyTimeout`.
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

    // Neither of these can be a `socket()` flag: macOS rejects `SOCK.NONBLOCK`
    // there (measured: `socket()` → `EINVAL`), which is why std sets
    // `FD_CLOEXEC` by hand on darwin too.
    if (fcntlSet(fd, std.posix.F.SETFD, std.posix.FD_CLOEXEC)) |e| return std.posix.unexpectedErrno(e);
    if (setNonblock(fd, true)) |e| return std.posix.unexpectedErrno(e);

    switch (std.posix.errno(std.posix.system.connect(fd, &storage.any, addr_len))) {
        // Immediate: loopback, or a listener on this host. That is the common
        // case between nodes in one rack, and every case in these tests.
        .SUCCESS => {},
        // The SYN is out and the kernel reports the outcome as writability plus
        // `SO_ERROR`. `EINTR` is the same state reached with a signal on the
        // way in: the attempt is still in flight and must not be retried.
        .INPROGRESS, .AGAIN, .INTR => try awaitConnect(fd, timeout_ms),
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .ALREADY => return error.ConnectionPending,
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .HOSTUNREACH => return error.HostUnreachable,
        .NETUNREACH => return error.NetworkUnreachable,
        .TIMEDOUT => return error.Timeout,
        .ACCES => return error.AccessDenied,
        .NETDOWN => return error.NetworkDown,
        else => |e| return std.posix.unexpectedErrno(e),
    }

    // Hand back the same state `netConnectIpPosix` does: a blocking socket
    // whose `address` is the *local* endpoint `getsockname` reports (i.e. the
    // ephemeral port). The name is best-effort there too — a failure leaves a
    // perfectly usable stream.
    if (setNonblock(fd, false)) |e| return std.posix.unexpectedErrno(e);
    var local: std.Io.Threaded.PosixAddress = undefined;
    var local_len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    const local_addr = if (std.posix.errno(std.posix.system.getsockname(fd, &local.any, &local_len)) == .SUCCESS)
        std.Io.Threaded.addressFromPosix(&local)
    else
        addr;
    return .{ .socket = .{ .handle = fd, .address = local_addr } };
}

/// Wait out an in-flight `connect` (`EINPROGRESS`), up to `timeout_ms` from
/// *now*.
///
/// `poll(POLLOUT)` means "the kernel is done with the attempt", not "it
/// worked": `SO_ERROR` carries the verdict, and a refused connection arrives
/// exactly that way — writable, then `ECONNREFUSED`.
fn awaitConnect(fd: std.posix.socket_t, timeout_ms: u32) ConnectTimeoutError!void {
    const started = Time.monotonicNowMilliseconds();
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
    while (true) {
        const elapsed = Time.monotonicNowMilliseconds() - started;
        if (elapsed >= timeout_ms) return error.ConnectTimeout;
        const prc = std.posix.system.poll(&fds, 1, @intCast(timeout_ms - elapsed));
        switch (std.posix.errno(prc)) {
            .SUCCESS => {},
            // A signal, not an answer: recompute what is left and wait again.
            .INTR => continue,
            else => |e| return std.posix.unexpectedErrno(e),
        }
        if (prc == 0) return error.ConnectTimeout;
        break;
    }

    var so_error: i32 = 0;
    var len: std.posix.socklen_t = @sizeOf(i32);
    switch (std.posix.errno(std.posix.system.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, @ptrCast(&so_error), &len))) {
        .SUCCESS => {},
        else => |e| return std.posix.unexpectedErrno(e),
    }
    // The mapping `std.Io.Threaded.posixConnect` applies to the blocking form,
    // so a caller cannot tell which of the two dialled.
    switch (so_error) {
        0 => {},
        @backingInt(std.posix.E.ADDRNOTAVAIL) => return error.AddressUnavailable,
        @backingInt(std.posix.E.CONNREFUSED) => return error.ConnectionRefused,
        @backingInt(std.posix.E.CONNRESET) => return error.ConnectionResetByPeer,
        @backingInt(std.posix.E.HOSTUNREACH) => return error.HostUnreachable,
        @backingInt(std.posix.E.NETUNREACH) => return error.NetworkUnreachable,
        @backingInt(std.posix.E.TIMEDOUT) => return error.Timeout,
        @backingInt(std.posix.E.ACCES), @backingInt(std.posix.E.PERM) => return error.AccessDenied,
        @backingInt(std.posix.E.NETDOWN) => return error.NetworkDown,
        else => |e| {
            log.debug("connect failed with errno {d}", .{e});
            return error.Unexpected;
        },
    }
}

// ── Windows bounded dial (ws2_32) ───────────────────────────────────────────
//
// The Windows half of `connectTimeout`. std's own Windows dial neither
// implements `ConnectOptions.timeout` (`std/Io/Threaded.zig`'s
// `netConnectIpWindows` is the same `@panic("TODO … with timeout")` as the
// POSIX line quoted above) nor exposes `WSAPoll` (`std.c.pollfd` aliases a
// `ws2_32.pollfd` the std module does not define — referencing `std.c.poll` on
// a Windows target is a compile error), and `std.os.windows.ws2_32` carries
// constants but no function declarations, because std does its Windows
// networking over raw AFD IOCTLs instead of Winsock. So the handful of ws2_32
// symbols the dial needs is declared below; Zig's bundled import libraries
// resolve them on both Windows ABIs (measured: a probe exe referencing all of
// them links for `-target x86_64-windows` and `x86_64-windows-gnu`), so no
// `linkSystemLibrary` is asked of a consumer.

/// The ws2_32 surface `connectTimeoutWindows` needs, as one block so the
/// extern count stays reviewable at a glance.
const wsa = struct {
    const INVALID_SOCKET = ~@as(usize, 0); // (SOCKET)(~0)
    const SOCKET_ERROR = -1;
    const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667E)); // ioctlsocket command

    const POLLWRNORM = 0x0010;
    const POLLNVAL = 0x0004;

    const SOL_SOCKET = std.os.windows.ws2_32.SOL.SOCKET;
    const SO_ERROR = std.os.windows.ws2_32.SO.ERROR;

    // The WSA error codes the tables below read (MSDN numeric values; std
    // carries no names for them).
    const EINTR = 10004;
    const EACCES = 10013;
    const EMFILE = 10024;
    const EWOULDBLOCK = 10035;
    const EALREADY = 10037;
    const EPROTOTYPE = 10041;
    const EPROTONOSUPPORT = 10043;
    const EAFNOSUPPORT = 10047;
    const EADDRNOTAVAIL = 10049;
    const ENETDOWN = 10050;
    const ENETUNREACH = 10051;
    const ECONNRESET = 10054;
    const ENOBUFS = 10055;
    const EISCONN = 10056;
    const ETIMEDOUT = 10060;
    const ECONNREFUSED = 10061;
    const EHOSTUNREACH = 10065;

    /// WSADATA: the field order is fixed by the Win32 ABI, and the alignment
    /// Zig computes for this extern struct matches it on both word sizes.
    const InitData = extern struct {
        wVersion: u16,
        wHighVersion: u16,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?[*]u8,
    };

    /// WSAPOLLFD.
    const PollFd = extern struct { fd: usize, events: i16, revents: i16 };

    extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *InitData) i32;
    extern "ws2_32" fn WSAGetLastError() i32;
    extern "ws2_32" fn socket(af: i32, type_: i32, protocol: i32) usize;
    extern "ws2_32" fn closesocket(s: usize) i32;
    extern "ws2_32" fn ioctlsocket(s: usize, cmd: i32, argp: *u32) i32;
    extern "ws2_32" fn connect(s: usize, name: *const anyopaque, namelen: i32) i32;
    extern "ws2_32" fn WSAPoll(fds: [*]PollFd, nfds: u32, timeout: i32) i32;
    extern "ws2_32" fn getsockopt(s: usize, level: i32, optname: i32, optval: *anyopaque, optlen: *i32) i32;
    extern "ws2_32" fn getsockname(s: usize, name: *anyopaque, namelen: *i32) i32;
};

/// What one WSA error code from `connect` means for a bounded dial. Pure data —
/// the error policy of the Windows half in one table, unit-tested per arm
/// (`classifyConnectErrno` is the same idea for POSIX errnos).
const WsaConnectVerdict = union(enum) {
    /// WSAEISCONN: the attempt had already completed (a repeated connect).
    connected,
    /// WSAEWOULDBLOCK / WSAEINTR / WSAEALREADY: the attempt is in flight —
    /// wait it out with WSAPoll, never retry the connect.
    in_progress,
    /// Terminal failure, mapped onto the same error names the POSIX half uses.
    failed: ConnectTimeoutError,
};

fn classifyWsaConnect(code: i32) WsaConnectVerdict {
    return switch (code) {
        wsa.EWOULDBLOCK, wsa.EINTR, wsa.EALREADY => .in_progress,
        wsa.EISCONN => .connected,
        else => .{ .failed = wsaFailure(code) },
    };
}

/// Map a terminal WSA failure code onto the POSIX half's error names, so a
/// caller cannot tell which of the two dialled. Codes with no named
/// counterpart — WSAECONNABORTED among them, the same reading `awaitConnect`
/// gives ECONNABORTED — fold into `error.Unexpected`: a dial reports, it never
/// panics.
fn wsaFailure(code: i32) ConnectTimeoutError {
    return switch (code) {
        wsa.ETIMEDOUT => error.Timeout,
        wsa.ECONNREFUSED => error.ConnectionRefused,
        wsa.ECONNRESET => error.ConnectionResetByPeer,
        wsa.EHOSTUNREACH => error.HostUnreachable,
        wsa.ENETUNREACH => error.NetworkUnreachable,
        wsa.EACCES => error.AccessDenied,
        wsa.ENETDOWN => error.NetworkDown,
        wsa.EADDRNOTAVAIL => error.AddressUnavailable,
        wsa.EAFNOSUPPORT => error.AddressFamilyUnsupported,
        wsa.ENOBUFS => error.SystemResources,
        wsa.EMFILE => error.ProcessFdQuotaExceeded,
        wsa.EPROTONOSUPPORT => error.ProtocolUnsupportedByAddressFamily,
        wsa.EPROTOTYPE => error.SocketModeUnsupported,
        else => error.Unexpected,
    };
}

/// The Windows half of `connectTimeout`, reached only when `timeout_ms != 0`:
/// non-blocking `connect` + `WSAPoll` + `SO_ERROR`, the POSIX half's exact
/// shape over Winsock.
///
/// WSAStartup runs on every call: it is refcounted and cheap, nothing else in
/// the process is guaranteed to have started Winsock (std's own Windows
/// networking never touches ws2_32), and the matching WSACleanup is
/// deliberately never called — the reference stays held until process exit,
/// which is the documented way to keep the catalog valid.
fn connectTimeoutWindows(addr: std.Io.net.IpAddress, timeout_ms: u32) ConnectTimeoutError!std.Io.net.Stream {
    var init_data: wsa.InitData = undefined;
    if (wsa.WSAStartup(0x0202, &init_data) != 0) return error.NetworkDown;
    // The grant comes back in `wVersion`: less than the 2.2 requested means no
    // WSAPoll (2.2 / Vista+), which is what `awaitConnectWindows` waits on.
    if (init_data.wVersion < 0x0202) return error.NetworkDown;

    var storage: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &storage);

    const w32 = std.os.windows.ws2_32;
    const sock = wsa.socket(@intCast(std.Io.Threaded.posixAddressFamily(&addr)), w32.SOCK.STREAM, w32.IPPROTO.TCP);
    if (sock == wsa.INVALID_SOCKET) return wsaFailure(wsa.WSAGetLastError());
    errdefer _ = wsa.closesocket(sock);

    // Non-blocking for the duration of the dial; the socket is put back to
    // blocking before it is handed out, for the same reason the POSIX half
    // restores O_NONBLOCK (its comment names the sockread contract).
    var nonblocking: u32 = 1;
    if (wsa.ioctlsocket(sock, wsa.FIONBIO, &nonblocking) != 0) return wsaFailure(wsa.WSAGetLastError());

    if (wsa.connect(sock, &storage.any, @intCast(addr_len)) != 0) {
        switch (classifyWsaConnect(wsa.WSAGetLastError())) {
            .connected => {},
            .in_progress => try awaitConnectWindows(sock, timeout_ms),
            .failed => |err| return err,
        }
    }

    var blocking: u32 = 0;
    if (wsa.ioctlsocket(sock, wsa.FIONBIO, &blocking) != 0) return wsaFailure(wsa.WSAGetLastError());

    // Hand back the same state the POSIX half does: a blocking socket whose
    // `address` is the local endpoint `getsockname` reports. The name is
    // best-effort there and here — a failure leaves a perfectly usable stream.
    var local: std.Io.Threaded.PosixAddress = undefined;
    var local_len: i32 = @sizeOf(std.Io.Threaded.PosixAddress);
    const local_addr = if (wsa.getsockname(sock, &local, &local_len) == 0)
        std.Io.Threaded.addressFromPosix(&local)
    else
        addr;
    return .{ .socket = .{ .handle = @ptrFromInt(sock), .address = local_addr } };
}

/// Wait out an in-flight WSA `connect` (`WSAEWOULDBLOCK`), up to `timeout_ms`
/// from *now* — `awaitConnect`'s counterpart. `WSAPoll(POLLWRNORM)` means "the
/// attempt settled", not "it worked": `SO_ERROR` carries the verdict, and a
/// refused connection arrives exactly that way.
fn awaitConnectWindows(sock: usize, timeout_ms: u32) ConnectTimeoutError!void {
    const started = Time.monotonicNowMilliseconds();
    var pfd = wsa.PollFd{ .fd = sock, .events = wsa.POLLWRNORM, .revents = 0 };
    while (true) {
        const elapsed = Time.monotonicNowMilliseconds() - started;
        if (elapsed >= timeout_ms) return error.ConnectTimeout;
        // elapsed < timeout_ms above, so the subtraction cannot underflow.
        // WSAPoll's timeout is a signed int of milliseconds; clamp rather than
        // `@intCast` an absurdly large `timeout_ms` into a panic.
        const left_ms = timeout_ms - @as(u32, @intCast(elapsed));
        const remaining: i32 = @intCast(@min(left_ms, @as(u32, std.math.maxInt(i32))));
        const rc = wsa.WSAPoll(@ptrCast(&pfd), 1, remaining);
        if (rc == 0) return error.ConnectTimeout;
        if (rc == wsa.SOCKET_ERROR) {
            switch (wsa.WSAGetLastError()) {
                // Interrupted, not answered: recompute what is left and wait again.
                wsa.EINTR => continue,
                else => |e| return wsaFailure(e),
            }
        }
        if (pfd.revents & wsa.POLLNVAL != 0) return error.Unexpected;
        break;
    }

    var so_error: i32 = 0;
    var len: i32 = @sizeOf(i32);
    if (wsa.getsockopt(sock, wsa.SOL_SOCKET, wsa.SO_ERROR, &so_error, &len) != 0)
        return wsaFailure(wsa.WSAGetLastError());
    if (so_error != 0) return wsaFailure(so_error);
}

comptime {
    if (builtin.target.os.tag == .windows) {
        // Force analysis of the Windows dial in every Windows-targeted compile
        // of this file: nothing in the default install set has to call a
        // bounded dial, so Zig's lazy analysis would otherwise let a broken
        // ws2_32 declaration through the `windows-cross` CI job until the
        // first consumer actually dialled.
        _ = connectTimeoutWindows;
        _ = awaitConnectWindows;
    }
}

/// Set or clear `O_NONBLOCK`; returns the errno when the kernel refuses.
///
/// Not a `socket()` flag: macOS rejects `SOCK.NONBLOCK` there (measured:
/// `socket()` → `EINVAL`). `F_SETFL` cannot touch the access-mode bits, so `0`
/// clears exactly `O_NONBLOCK` — the standard way to make a socket blocking
/// again.
fn setNonblock(fd: std.posix.socket_t, on: bool) ?std.posix.E {
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    return fcntlSet(fd, std.posix.F.SETFL, if (on) nonblock else 0);
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

// ── Bounded dial ────────────────────────────────────────────────────────────

// Test-only: the round-trip test below exists precisely to prove the stream
// `connectTimeout` hands back satisfies the contract `sockread` is built on,
// so that one test uses the real helpers rather than the raw syscalls above.
const sockread = @import("sockread.zig");

const test_dial_timeout_ms: u32 = 2000;

/// `O_NONBLOCK` as the *kernel* sees it on `fd`, read back with `fcntl` — the
/// assertion is about the socket's real state rather than about what we meant
/// to ask for.
fn nonblockSet(fd: std.posix.socket_t) bool {
    const rc = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
    if (std.posix.errno(rc) != .SUCCESS) return false;
    const bits: u32 = @truncate(@as(u64, @bitCast(@as(i64, @intCast(rc)))));
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    return bits & nonblock != 0;
}

// Verified red: with the bound removed (a plain `IpAddress.connect`, as the
// pre-fix RaftTransport `dialTo` did) this dial does not return — the SYN to a
// link-local address that has no responder is never answered and macOS keeps
// the socket in SYN_SENT (measured: still pending after 25 s). Green: it
// returns on the configured bound, and the elapsed time proves the bound was
// *reached* rather than the dial failing early for some other reason.
//
// The bound is the assertion; the address is not. `169.254.255.254` is RFC 3927
// link-local with nothing on the link, which is what this machine black-holes
// today (and what the 25 s measurement above used). Another environment may
// answer it, or refuse it outright — hence the probe: without a black hole to
// dial there is nothing to assert, and skipping says so.
test "a black-holed dial returns on the bound, not on the kernel's default" {
    const io = testing.io;
    if (!netTestsAvailable()) return error.SkipZigTest;

    const black_hole = try std.Io.net.IpAddress.parse("169.254.255.254", 80);

    if (connectTimeout(io, black_hole, 150)) |stream| {
        stream.close(io); // something on this link answers: no black hole here
        return error.SkipZigTest;
    } else |err| switch (err) {
        error.ConnectTimeout => {},
        else => {
            std.log.info("[netdial] {s}:80 does not black-hole here ({s}) — skipping the connect-bound test", .{ "169.254.255.254", @errorName(err) });
            return error.SkipZigTest;
        },
    }

    const bound_ms: u32 = 700;
    const started = Time.monotonicNowMilliseconds();
    const result = connectTimeout(io, black_hole, bound_ms);
    const elapsed = Time.monotonicNowMilliseconds() - started;
    if (result) |stream| {
        stream.close(io);
        return error.SkipZigTest; // answered inside the bound after all
    } else |err| switch (err) {
        error.ConnectTimeout => {},
        else => {
            // Black-holing a link-local address relies on its ARP going
            // unanswered; back-to-back dials race the kernel's neighbour
            // cache, and a negative entry turns this second dial into an
            // immediate EHOSTUNREACH even though the probe above timed out.
            // The premise (the address hangs) proved unstable — skip, as the
            // probe does, rather than assert on an environment artifact.
            std.log.info("[netdial] {s}:80 stopped black-holing between probe and measurement ({s}) — skipping the connect-bound test", .{ "169.254.255.254", @errorName(err) });
            return error.SkipZigTest;
        },
    }

    // The bound, and not something shorter: `ConnectionRefused` and friends
    // would mean the dial was never hanging, which is the case this test is not
    // about. The upper end is the real assertion — the kernel's own default for
    // this address is the >25 s measured above.
    try testing.expect(elapsed >= @as(i64, bound_ms) - 150);
    try testing.expect(elapsed < 5_000);
}

test "connectTimeout hands back a blocking stream the sockread helpers can use" {
    const io = testing.io;
    if (!netTestsAvailable()) return error.SkipZigTest;

    const bind = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try bind.listen(io, .{});
    defer server.deinit(io);
    var client = try connectTimeout(io, try std.Io.net.IpAddress.parse("127.0.0.1", server.socket.address.getPort()), test_dial_timeout_ms);
    defer client.close(io);
    var accepted = try server.accept(io);
    defer accepted.close(io);

    // The invariant `sockread` is built on: a socket left non-blocking would
    // come back `EAGAIN` from these, and the WebSocket write path treats `EAGAIN`
    // as a programmer bug and panics on it in debug builds. Then the helpers
    // themselves, which is what the cluster transport actually calls.
    try testing.expect(!nonblockSet(client.socket.handle));
    try sockread.writeFull(client, "ping");
    var buf: [4]u8 = undefined;
    try sockread.readFull(accepted, &buf);
    try testing.expectEqualStrings("ping", &buf);

    // A dial that really fails is still reported as itself: `SO_ERROR` is read
    // even though `poll` said "ready", so a refused port is not folded into the
    // timeout.
    var gone = try bind.listen(io, .{});
    const gone_port = gone.socket.address.getPort();
    gone.deinit(io);
    try testing.expectError(error.ConnectionRefused, connectTimeout(io, try std.Io.net.IpAddress.parse("127.0.0.1", gone_port), test_dial_timeout_ms));
}

// The Windows half's error policy is pure data, so it is verified here on
// every host — the dial itself can only run on Windows, where the CI
// cross-compile (`zig build -Ddb=none -Dtarget=x86_64-windows`) plus the
// comptime reference next to `connectTimeoutWindows` are the gate.

test "WSA connect classification: in-progress vs connected vs failed" {
    try testing.expectEqual(WsaConnectVerdict.in_progress, classifyWsaConnect(wsa.EWOULDBLOCK));
    try testing.expectEqual(WsaConnectVerdict.in_progress, classifyWsaConnect(wsa.EINTR));
    try testing.expectEqual(WsaConnectVerdict.in_progress, classifyWsaConnect(wsa.EALREADY));
    try testing.expectEqual(WsaConnectVerdict.connected, classifyWsaConnect(wsa.EISCONN));
    switch (classifyWsaConnect(wsa.ECONNREFUSED)) {
        .failed => |err| try testing.expectEqual(error.ConnectionRefused, err),
        else => return error.TestUnexpectedResult,
    }
}

test "WSA failure codes keep the POSIX dial's error names" {
    try testing.expectEqual(error.Timeout, wsaFailure(wsa.ETIMEDOUT));
    try testing.expectEqual(error.ConnectionRefused, wsaFailure(wsa.ECONNREFUSED));
    try testing.expectEqual(error.ConnectionResetByPeer, wsaFailure(wsa.ECONNRESET));
    try testing.expectEqual(error.HostUnreachable, wsaFailure(wsa.EHOSTUNREACH));
    try testing.expectEqual(error.NetworkUnreachable, wsaFailure(wsa.ENETUNREACH));
    try testing.expectEqual(error.AccessDenied, wsaFailure(wsa.EACCES));
    try testing.expectEqual(error.NetworkDown, wsaFailure(wsa.ENETDOWN));
    try testing.expectEqual(error.AddressUnavailable, wsaFailure(wsa.EADDRNOTAVAIL));
    try testing.expectEqual(error.AddressFamilyUnsupported, wsaFailure(wsa.EAFNOSUPPORT));
    try testing.expectEqual(error.SystemResources, wsaFailure(wsa.ENOBUFS));
    try testing.expectEqual(error.ProcessFdQuotaExceeded, wsaFailure(wsa.EMFILE));
    try testing.expectEqual(error.ProtocolUnsupportedByAddressFamily, wsaFailure(wsa.EPROTONOSUPPORT));
    try testing.expectEqual(error.SocketModeUnsupported, wsaFailure(wsa.EPROTOTYPE));
    // No named counterpart: report, never panic. WSAECONNABORTED (10053) is
    // folded the same way the POSIX half folds ECONNABORTED into `Unexpected`.
    try testing.expectEqual(error.Unexpected, wsaFailure(10053));
    try testing.expectEqual(error.Unexpected, wsaFailure(-1));
}
