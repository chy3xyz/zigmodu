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

/// Database-specific error types aligned with SQLState codes
pub const DatabaseError = error{
    ConnectionFailed,
    QueryFailed,
    ExecFailed,
    Timeout,
    NotFound,
    ConstraintViolation,
    SerializationFailure,
    ReadOnlyViolation,
    TooManyConnections,
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
    return error.Other;
}

/// Check if a DatabaseError is acceptable (should not trip circuit breaker)
pub fn isAcceptableDbError(err: DatabaseError) bool {
    return switch (err) {
        error.NotFound, error.SerializationFailure, error.ReadOnlyViolation => true,
        else => false,
    };
}
