//! Error handling for sqlx (adapted from zigzero)
//! Now unified with ZigModu core/Error.zig. This file remains as a backward-compat
//! shim that re-exports the framework error types plus SQL-specific helpers.

const std = @import("std");
const core_err = @import("../core/Error.zig");

/// Unified framework error type (alias for backward compatibility)
pub const Error = core_err.ZigModuError;

/// Result type alias
pub const Result = Error!void;

/// Result type with value
pub fn ResultT(comptime T: type) type {
    return Error!T;
}

/// Error code constants (aligned with go-zero)
pub const Code = core_err.HttpCode;

/// Convert Error to Code
pub const toCode = core_err.toHttpCode;

/// Standardized JSON error response aligned with go-zero
pub const ErrorResponse = core_err.ErrorResponse;

/// Build a JSON error response string. Caller owns returned memory.
pub const toJson = core_err.toJson;

/// Convenience: create JSON from Error + message
pub const fromError = core_err.fromError;

// ==================== SQL-specific helpers (retained here) ====================

/// SQLState code type
pub const SqlState = []const u8;

/// Structured SQL error with SQLState code
pub const SqlError = struct {
    kind: DatabaseError,
    sql_state: SqlState,
    message: []const u8,
};

/// Database-specific error types aligned with SQLState codes.
///
/// Produced by `sqlStateToError` (SQLSTATE → kind) and by `diagnose*` in
/// `sqlx/sqlx.zig`. `isAcceptableDbError` decides which of them are "expected"
/// and must not trip the pool circuit breaker.
pub const DatabaseError = error{
    /// The connection is gone or was never established (SQLSTATE 08xxx, incl. 08004
    /// too-many-connections). Reconnect or fail the request; the statement did not run.
    ConnectionFailed,
    /// The server rejected the statement itself (SQLSTATE 42xxx — unknown table,
    /// column, or syntax). A code bug, not a transient failure: do not retry.
    QueryFailed,
    /// The statement failed during execution. Present in the taxonomy but not
    /// returned by `sqlStateToError` today — the drivers map to `Other` instead.
    ExecFailed,
    /// The statement was cancelled by a timeout (SQLSTATE 57014). Retryable; treat
    /// as backpressure rather than an outage.
    Timeout,
    /// No row matched (SQLSTATE 02000) or the row was already deleted. Surfacing it
    /// as 404 is normal; `isAcceptableDbError` marks it as breaker-safe.
    NotFound,
    /// A constraint was violated (SQLSTATE 23xxx — unique, FK, check). Retrying the
    /// same statement will fail again; report a conflict (409) to the client.
    ConstraintViolation,
    /// A serializable transaction lost a race (SQLSTATE 40001 / 40P01). Retry the
    /// whole transaction; `isAcceptableDbError` marks it as breaker-safe.
    SerializationFailure,
    /// The connection is read-only (SQLSTATE 25000/25001/25002). Route the write to a
    /// primary; `isAcceptableDbError` marks it as breaker-safe.
    ReadOnlyViolation,
    /// The server is out of connection slots (SQLSTATE 53300). Back off and retry
    /// later instead of opening another connection.
    TooManyConnections,
    /// No more specific mapping exists for this SQLSTATE. Log the raw state/message
    /// (they stay available in `SqlError`) before deciding to retry.
    Other,
};

/// Map SQLState code to DatabaseError kind
pub fn sqlStateToError(sql_state: SqlState) DatabaseError {
    if (std.mem.eql(u8, sql_state, "08000")) return error.ConnectionFailed;
    if (std.mem.eql(u8, sql_state, "08003")) return error.ConnectionFailed;
    if (std.mem.eql(u8, sql_state, "08006")) return error.ConnectionFailed;
    if (std.mem.eql(u8, sql_state, "40001")) return error.SerializationFailure;
    if (std.mem.eql(u8, sql_state, "40P01")) return error.SerializationFailure;
    if (std.mem.eql(u8, sql_state, "25000")) return error.ReadOnlyViolation;
    if (std.mem.eql(u8, sql_state, "25001")) return error.ReadOnlyViolation;
    if (std.mem.eql(u8, sql_state, "25002")) return error.ReadOnlyViolation;
    if (std.mem.eql(u8, sql_state, "23000")) return error.ConstraintViolation;
    if (std.mem.eql(u8, sql_state, "23505")) return error.ConstraintViolation;
    if (std.mem.eql(u8, sql_state, "23503")) return error.ConstraintViolation;
    if (std.mem.eql(u8, sql_state, "23514")) return error.ConstraintViolation;
    if (std.mem.eql(u8, sql_state, "08004")) return error.ConnectionFailed;
    if (std.mem.eql(u8, sql_state, "08001")) return error.ConnectionFailed;
    if (std.mem.eql(u8, sql_state, "02000")) return error.NotFound;
    if (std.mem.eql(u8, sql_state, "42P01")) return error.QueryFailed;
    if (std.mem.eql(u8, sql_state, "42601")) return error.QueryFailed;
    if (std.mem.eql(u8, sql_state, "42703")) return error.QueryFailed;
    if (std.mem.eql(u8, sql_state, "42S02")) return error.QueryFailed;
    if (std.mem.eql(u8, sql_state, "42S22")) return error.QueryFailed;
    if (std.mem.eql(u8, sql_state, "57014")) return error.Timeout;
    if (std.mem.eql(u8, sql_state, "53300")) return error.TooManyConnections;
    return error.Other;
}

test "sqlStateToError maps known SQLStates and falls back to Other" {
    try std.testing.expectEqual(error.ConnectionFailed, sqlStateToError("08006"));
    try std.testing.expectEqual(error.SerializationFailure, sqlStateToError("40001"));
    try std.testing.expectEqual(error.ReadOnlyViolation, sqlStateToError("25001"));
    try std.testing.expectEqual(error.ConstraintViolation, sqlStateToError("23505"));
    try std.testing.expectEqual(error.NotFound, sqlStateToError("02000"));
    try std.testing.expectEqual(error.QueryFailed, sqlStateToError("42P01"));
    try std.testing.expectEqual(error.Timeout, sqlStateToError("57014"));
    try std.testing.expectEqual(error.TooManyConnections, sqlStateToError("53300"));
    try std.testing.expectEqual(error.Other, sqlStateToError("XX000"));
}

/// Check if a DatabaseError is acceptable (should not trip circuit breaker)
pub fn isAcceptableDbError(err: DatabaseError) bool {
    return switch (err) {
        error.NotFound, error.SerializationFailure, error.ReadOnlyViolation => true,
        else => false,
    };
}
