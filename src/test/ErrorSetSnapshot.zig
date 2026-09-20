//! Public-API error-set snapshots.
//!
//! Consumers write exhaustive `switch (err)` over these error sets. Widening one
//! (accidentally falling back to `anyerror`, or adding a new error) breaks their
//! build at *their* call site, with no warning from us. So each entry pins two
//! things:
//!
//!   - the errors consumers are known to switch on must still be present
//!     (removing one silently changes behaviour), and
//!   - the total count must not grow past a recorded ceiling (anything new is a
//!     breaking change and has to be acknowledged here, in this file).
//!
//! `anyerror` is a failure, not a pass: it makes exhaustive switches impossible.
//!
//! Deliberate exceptions (not snapshotted): the `DistributedLock.Lock` vtable and
//! the `Preflight` probes are duck-typed `anytype` boundaries, so their error
//! sets are intentionally open.

const std = @import("std");
const SecurityModule = @import("../security/SecurityModule.zig").SecurityModule;
const Multipart = @import("../http/Multipart.zig");
const Server = @import("../api/Server.zig").Server;
const RaftElection = @import("../core/cluster/RaftElection.zig").RaftElection;

test "public API error sets stay narrow and stable" {
    try checkSnapshot(SecurityModule.verifyToken, "SecurityModule.verifyToken", &.{
        "InvalidToken", "TokenExpired", "UnsupportedAlgorithm", "UnknownKeyId",
    }, 22);
    try checkSnapshot(Multipart.parse, "Multipart.parse", &.{
        "NotMultipart", "MissingBoundary", "MalformedPart", "TooManyParts", "PartTooLarge", "PayloadTooLarge",
    }, 7);
    try checkSnapshot(Server.start, "Server.start", &.{}, 19);

    // The Raft inbound handler. `InvalidLogIndex` arrived in v0.32.0 — the
    // `entry.index == 0` guard (`docs/dev/security-audit-cluster.md` §5), a
    // rejection path that had to exist but still widens a public error set, which
    // is why it is acknowledged here and in CHANGELOG.md. Not `anyerror`, so the
    // set stays switchable.
    try checkSnapshot(RaftElection.handleAppendEntries, "RaftElection.handleAppendEntries", &.{
        "InvalidLogIndex",
        "OutOfMemory",
    }, 2);
}

fn checkSnapshot(
    comptime func: anytype,
    comptime label: []const u8,
    comptime required: []const []const u8,
    comptime ceiling: usize,
) !void {
    const ret = @typeInfo(@TypeOf(func)).@"fn".return_type orelse {
        std.debug.print("error-set snapshot: {s} is not a function returning a value\n", .{label});
        return error.NotAFunction;
    };
    if (@typeInfo(ret) != .error_union) {
        std.debug.print("error-set snapshot: {s} no longer returns an error union\n", .{label});
        return error.NotAnErrorUnion;
    }
    const names = @typeInfo(@typeInfo(ret).error_union.error_set).error_set.error_names orelse {
        std.debug.print("error-set snapshot: {s} widened to anyerror — consumers can no longer switch exhaustively\n", .{label});
        return error.ErrorSetWidenedToAnyerror;
    };

    inline for (required) |want| {
        if (!hasError(names, want)) {
            std.debug.print("error-set snapshot: {s} no longer returns error.{s}\n", .{ label, want });
            return error.ErrorRemoved;
        }
    }

    if (names.len > ceiling) {
        std.debug.print("error-set snapshot: {s} grew to {d} errors (ceiling {d}) — widening a public error set is a breaking change; acknowledge it here and in CHANGELOG.md\n", .{ label, names.len, ceiling });
        return error.ErrorSetGrew;
    }
}

fn hasError(names: []const [:0]const u8, comptime want: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, want)) return true;
    }
    return false;
}
