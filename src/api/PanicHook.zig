//! PanicHook — request-context-aware panic handler.
//!
//! A Zig panic aborts the process; there is no per-request recovery. What the
//! framework *can* do is make every panic attributable: which request was on
//! this thread when it went down. The server records the current
//! `METHOD /path` into a threadlocal slot before dispatching a request and
//! clears it afterwards. When a panic fires, the hook prints that context to
//! stderr (no allocation, fixed buffer) before delegating to
//! `std.debug.defaultPanic` for the normal message + stack trace.
//!
//! Wire-up is one line in the application's root file (the one with `main`):
//!
//! ```zig
//! const zmodu = @import("zigmodu");
//! pub const panic = zmodu.panicHook;
//! ```
//!
//! Without that line everything still works — the slot is simply never read.
//! Combine with a supervisor (`Restart=always`, k8s `restartPolicy`) for
//! process-level recovery; the hook is the *diagnosis* half, not the cure.

const std = @import("std");

const BUF_SIZE = 512;

threadlocal var request_buf: [BUF_SIZE]u8 = undefined;
threadlocal var request_len: usize = 0;

/// Record the request currently being dispatched on this thread.
/// Called by the server before middleware/handler execution.
pub fn setRequestContext(method: []const u8, path: []const u8) void {
    var len: usize = 0;
    const m = method[0..@min(method.len, 16)];
    @memcpy(request_buf[len..][0..m.len], m);
    len += m.len;
    request_buf[len] = ' ';
    len += 1;
    const room = BUF_SIZE - len;
    const p = path[0..@min(path.len, room)];
    @memcpy(request_buf[len..][0..p.len], p);
    len += p.len;
    request_len = len;
}

/// Clear the slot after the request finishes (panic or not, a reused thread
/// must not attribute a later crash to an earlier request).
pub fn clearRequestContext() void {
    request_len = 0;
}

/// The panic function. Signature matches `std.debug.defaultPanic`.
pub fn panicWithRequestContext(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (request_len > 0) {
        const prefix = "panic while handling request: ";
        var out: [prefix.len + BUF_SIZE + 1]u8 = undefined;
        @memcpy(out[0..prefix.len], prefix);
        @memcpy(out[prefix.len..][0..request_len], request_buf[0..request_len]);
        out[prefix.len + request_len] = '\n';
        writeStderr(out[0 .. prefix.len + request_len + 1]);
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn writeStderr(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.posix.write(std.posix.STDERR_FILENO, rest) catch return;
        if (n == 0) return;
        rest = rest[n..];
    }
}

/// Drop-in panic namespace for the application root:
/// `pub const panic = zmodu.panicHook;`
pub const hook = std.debug.FullPanic(panicWithRequestContext);

test "PanicHook: set/clear request context round-trip" {
    setRequestContext("GET", "/api/orders/42?verbose=true");
    try std.testing.expect(request_len > 0);
    const recorded = request_buf[0..request_len];
    try std.testing.expect(std.mem.startsWith(u8, recorded, "GET /api/orders/42"));
    clearRequestContext();
    try std.testing.expectEqual(@as(usize, 0), request_len);
}

test "PanicHook: oversized path is truncated, never overflows" {
    var long_path: [601]u8 = undefined;
    long_path[0] = '/';
    @memset(long_path[1..], 'x');
    setRequestContext("POST", &long_path);
    try std.testing.expect(request_len <= BUF_SIZE);
    clearRequestContext();
}
