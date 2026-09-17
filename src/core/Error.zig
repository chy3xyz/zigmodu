//! Typed error handling — ZigModuError, ErrorContext, Result(T), HttpCode mapping.

const std = @import("std");
const Time = @import("Time.zig");

/// ZigModu unified error type — the framework's shared error vocabulary.
///
/// This is a taxonomy, not a hot-path error set. Only the members whose doc says
/// "Produced by" are actually returned by shipped framework code today; the rest
/// are declared so applications, `ErrorContext`, `Result(T)` and `toHttpCode`
/// can name failures the same way. Every member has a defined HTTP status.
///
/// Caller guidance: match the members you can really receive and keep an `else`
/// arm — this set grows additively, and `toHttpCode` already folds everything
/// unmapped into 500.
pub const ZigModuError = error{
    // Module errors
    /// No module is registered under that name. Produced by `src/core/ModuleValidator.zig`. → 404.
    ModuleNotFound,
    /// A module name was registered twice. Not produced by the framework yet. → 500.
    ModuleAlreadyExists,
    /// A module's `init()` failed during `startAll`, so the container aborts startup.
    /// Produced by `src/core/Lifecycle.zig`. → 500.
    ModuleInitializationFailed,
    /// A module's `deinit()` failed while stopping. Not produced by the framework yet
    /// (shutdown failures are logged, not propagated). → 500.
    ModuleDeinitializationFailed,

    // Dependency errors
    /// A declared dependency name has no matching module. Produced by
    /// `src/core/ModuleValidator.zig`. → 404.
    DependencyNotFound,
    /// A module reached across a declared boundary. Not produced by the framework yet
    /// — `ModuleGraph` reports boundary violations at compile time. → 500.
    DependencyViolation,
    /// The dependency graph contains a cycle. Produced by `src/core/ModuleValidator.zig`
    /// and `src/core/Lifecycle.zig`. → 500.
    CircularDependency,
    /// A module listed itself in `info.dependencies`. Produced by
    /// `src/core/ModuleValidator.zig`. → 500.
    SelfDependency,

    // Lifecycle errors
    /// A lifecycle call arrived out of order (e.g. stop before start). Not produced
    /// by the framework yet. → 500.
    InvalidLifecycleState,
    /// Startup failed as a whole. Not produced by the framework yet — `startAll`
    /// surfaces `ModuleInitializationFailed` instead. → 500.
    StartupFailed,
    /// Shutdown failed. Not produced by the framework yet — `stopAll` logs and goes on. → 500.
    ShutdownFailed,

    // Configuration errors
    /// Generic configuration problem. Not produced by the framework yet. → 400.
    ConfigurationError,
    /// A configuration file was not found. Produced by `toErrorContext` when the
    /// underlying error is `error.FileNotFound`. → 404.
    ConfigFileNotFound,
    /// A configuration file could not be parsed. Not produced by the framework yet. → 400.
    ConfigParseError,
    /// A configuration value failed validation. Not produced by the framework yet —
    /// `Preflight` reports its own check failures. → 400.
    ConfigValidationFailed,

    // DI container errors
    /// A requested service key has no registration. Not produced by the framework yet. → 404.
    ServiceNotFound,
    /// A service key was registered twice. Not produced by the framework yet. → 500.
    ServiceAlreadyExists,
    /// A resolved value had the wrong type for its consumer. Not produced by the
    /// framework yet. → 500.
    TypeMismatch,
    /// The container was used after `close()`. Not produced by the framework yet. → 500.
    ContainerClosed,

    // Event system errors
    /// The event bus plumbing itself failed. Not produced by the framework yet. → 500.
    EventBusError,
    /// No handler is registered for a dispatched event. Not produced by the
    /// framework yet. → 404.
    EventHandlerNotFound,
    /// An event payload could not be serialized. Not produced by the framework yet. → 500.
    EventSerializationFailed,

    // Transaction errors
    /// A transaction failed and was rolled back. Not produced by the framework yet —
    /// `sqlx.Transaction` surfaces the driver-level error instead. → 500.
    TransactionFailed,
    /// Rolling back failed, so the connection state is unknown: drop the connection
    /// instead of returning it to the pool. Not produced by the framework yet. → 500.
    TransactionRollbackFailed,
    /// `beginTx` was called while a transaction is already open. Not produced by the
    /// framework yet. → 500.
    TransactionAlreadyActive,
    /// `commit`/`rollback` was called with no open transaction. Not produced by the
    /// framework yet. → 500.
    NoActiveTransaction,

    // Database
    /// Connecting to the database failed. Produced by `src/sqlx/sqlx.zig` when the
    /// driver reports `error.ConnectionFailed`. → 500.
    DatabaseConnectionFailed,
    /// A query was rejected before execution (malformed SQL). Not produced by the
    /// framework yet. → 500.
    QueryExecutionFailed,
    /// The server rejected the query (SQLSTATE 42xxx). Produced by
    /// `src/sqlx/sqlx.zig` and `sqlStateToError`. → 500.
    QueryFailed,
    /// The connection pool has no free connection. Not produced by the framework yet.
    /// → 503 — surface it as backpressure (retry-after), not a hard failure.
    ConnectionPoolExhausted,
    /// The pool marked a connection unhealthy. Produced by `src/sqlx/sqlx.zig`. → 500.
    PoolUnhealthy,
    /// Database-generic failure: the driver error had no more specific mapping.
    /// Produced by `src/sqlx/sqlx.zig`. → 500.
    DatabaseError,
    /// A constraint (unique / foreign key / check) was violated. Produced by
    /// `src/sqlx/sqlx.zig` and `sqlStateToError` (SQLSTATE 23xxx). → 500 by default —
    /// map it to 409 yourself when the API distinguishes conflicts.
    ConstraintViolation,
    /// A serializable transaction lost a race (SQLSTATE 40001 / 40P01). Produced by
    /// `src/sqlx/sqlx.zig`. → 500 — retry the transaction; `isAcceptableDbError` marks
    /// it as not breaker-tripping.
    SerializationFailure,
    /// The connection is read-only (SQLSTATE 25000/25001/25002). Produced by
    /// `src/sqlx/sqlx.zig`. → 500 — write to a primary, do not retry blindly.
    ReadOnlyViolation,
    /// A Redis command failed. Every parse/connect/read/write failure in
    /// `src/redis/redis.zig` collapses to this one name. → 500.
    RedisError,
    /// SQL driver disabled at compile time (`-Ddb=` / `build_options.enable_*`).
    /// Produced by `toErrorContext`. → 400 — fix the build/dependency config.
    DriverNotEnabled,

    // General business errors
    /// The requested resource does not exist. Produced by `src/sqlx/sqlx.zig` for a
    /// missing row (SQLSTATE 02000). → 404.
    NotFound,
    /// A rate limit was hit. Not produced by the framework yet. → 429 — the caller
    /// should back off rather than retry immediately.
    RateLimitExceeded,
    /// A circuit breaker is open. Produced by `src/sqlx/sqlx.zig` when the pool
    /// breaker refuses a call. → 503 — retry later; hammering keeps it open.
    CircuitBreakerOpen,
    /// A dependency is unavailable. Not produced by the framework yet. → 503, retryable.
    ServiceUnavailable,
    /// The service is shedding load. Not produced by the framework yet. → 503 —
    /// retryable with backoff.
    ServiceOverloaded,

    // Security errors
    /// Credential/token verification failed. Not produced by the framework yet —
    /// `http` middleware renders the 401 body itself; this name is for app code. → 401.
    AuthenticationFailed,
    /// The caller is authenticated but not permitted. Not produced by the framework
    /// yet (gates answer 403 directly). → 403.
    AuthorizationFailed,
    /// The token is past `exp`. Not produced by the framework yet. → 401 — the client
    /// must re-authenticate; do not retry the same token.
    TokenExpired,
    /// The token is malformed, wrongly signed, or for another audience. Not produced
    /// by the framework yet. → 401.
    InvalidToken,
    /// Username/password mismatch. Not produced by the framework yet. → 401.
    InvalidCredentials,

    // Validation errors
    /// A payload failed its validation rules. Not produced by the framework yet. → 400.
    ValidationFailed,
    /// User input is out of contract. Not produced by the framework yet. → 400.
    InvalidInput,
    /// A module name violates the naming rules (must be lowercase, no spaces).
    /// Produced by `src/core/ModuleValidator.zig`. → 400.
    InvalidModuleName,
    /// A required field is absent. Not produced by the framework yet. → 400.
    MissingRequiredField,
    /// A value has the wrong shape (date, uuid, decimal text …). Produced by
    /// `src/sqlx/sqlx.zig` while decoding MySQL temporal/JSON columns. → 400.
    InvalidFormat,

    // Cache errors
    /// Cache subsystem failure. Not produced by the framework yet. → 500.
    CacheError,
    /// The key is not in the cache. Not produced by the framework yet — callers
    /// should fall through to the origin. → 404.
    CacheKeyNotFound,
    /// The cache is full / evicting. Not produced by the framework yet. → 500.
    CacheFull,

    // Network errors
    /// Network transport failure. Not produced by the framework yet. → 500.
    NetworkError,
    /// A connection timed out. Produced by `toErrorContext` when the underlying error
    /// is `error.ConnectionTimedOut`, and by `src/sqlx/sqlx.zig`. → 408, retryable.
    ConnectionTimeout,
    /// A generic deadline was exceeded (query cancel 57014, request budget …).
    /// Produced by `src/sqlx/sqlx.zig` and `sqlStateToError`. → 408, retryable.
    Timeout,
    /// The peer refused the connection. Produced by `toErrorContext` when the
    /// underlying error is `error.ConnectionRefused`. → 500.
    ConnectionRefused,
    /// An outbound HTTP call returned a failure the caller should surface. Not
    /// produced by the framework yet. → 500.
    HttpError,
    /// A server-side failure in a dependency. Not produced by the framework yet. → 500.
    ServerError,

    // Resource errors
    /// Allocation failed. Produced by `toErrorContext` and by `src/sqlx/sqlx.zig`
    /// (arena/dupe failures while scanning rows). → 500.
    OutOfMemory,
    /// A bounded resource (queue, pool, semaphore) is exhausted. Not produced by the
    /// framework yet. → 500 — apply backpressure at the call site.
    ResourceExhausted,
    /// A resource that should have been released was not. Not produced by the
    /// framework yet. → 500.
    ResourceLeak,

    // Unknown errors
    /// Fallback for anything without a name. Produced by `toErrorContext` for every
    /// unmapped `anyerror`. → 500.
    UnknownError,
};

/// Error context
pub const ErrorContext = struct {
    error_code: ZigModuError,
    message: []const u8,
    source: ?[]const u8,
    timestamp: i64,
    stack_trace: ?[]const u8,

    pub fn init(error_code: ZigModuError, message: []const u8) ErrorContext {
        return .{
            .error_code = error_code,
            .message = message,
            .source = null,
            .timestamp = Time.monotonicNowSeconds(),
            .stack_trace = null,
        };
    }
};

/// Error handler
pub const ErrorHandler = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    handlers: std.ArrayList(HandlerEntry),

    const HandlerEntry = struct {
        error_code: ZigModuError,
        handler: *const fn (ErrorContext) void,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .handlers = std.ArrayList(HandlerEntry).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.handlers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Self, error_code: ZigModuError, handler: *const fn (ErrorContext) void) !void {
        try self.handlers.append(self.allocator, .{
            .error_code = error_code,
            .handler = handler,
        });
    }

    pub fn handle(self: *Self, ctx: ErrorContext) void {
        for (self.handlers.items) |entry| {
            if (entry.error_code == ctx.error_code) {
                entry.handler(ctx);
                return;
            }
        }

        // Default handling: log the error
        std.log.err("[{s}] {s}", .{ @errorName(ctx.error_code), ctx.message });
    }
};

/// Result type alias
pub fn Result(T: type) type {
    return union(enum) {
        ok: T,
        err: ErrorContext,

        pub fn isOk(self: @This()) bool {
            return switch (self) {
                .ok => true,
                .err => false,
            };
        }

        pub fn isErr(self: @This()) bool {
            return !self.isOk();
        }

        pub fn unwrap(self: @This()) T {
            std.debug.assert(self.isOk());
            return self.ok;
        }

        pub fn unwrapErr(self: @This()) ErrorContext {
            std.debug.assert(self.isErr());
            return self.err;
        }
    };
}

/// Error conversion helper
pub fn toErrorContext(err: anyerror, message: []const u8) ErrorContext {
    const code = switch (err) {
        error.OutOfMemory => ZigModuError.OutOfMemory,
        error.FileNotFound => ZigModuError.ConfigFileNotFound,
        error.ConnectionRefused => ZigModuError.ConnectionRefused,
        error.ConnectionTimedOut => ZigModuError.ConnectionTimeout,
        error.DriverNotEnabled => ZigModuError.DriverNotEnabled,
        else => ZigModuError.UnknownError,
    };

    return ErrorContext.init(code, message);
}

/// HTTP status code mapping (aligned with go-zero patterns)
pub const HttpCode = enum(i32) {
    OK = 0,
    BadRequest = 400,
    Unauthorized = 401,
    Forbidden = 403,
    NotFound = 404,
    RequestTimeout = 408,
    RateLimit = 429,
    ServerError = 500,
    ServiceUnavailable = 503,
};

/// Map ZigModuError to HttpCode
pub fn toHttpCode(err: ZigModuError) HttpCode {
    return switch (err) {
        error.ModuleNotFound, error.DependencyNotFound, error.CacheKeyNotFound, error.NotFound, error.ServiceNotFound, error.EventHandlerNotFound, error.ConfigFileNotFound => .NotFound,

        error.AuthenticationFailed, error.InvalidToken, error.TokenExpired, error.InvalidCredentials => .Unauthorized,

        error.AuthorizationFailed => .Forbidden,

        error.RateLimitExceeded => .RateLimit,

        error.CircuitBreakerOpen, error.ServiceUnavailable, error.ServiceOverloaded, error.ConnectionPoolExhausted => .ServiceUnavailable,

        error.ConnectionTimeout, error.Timeout => .RequestTimeout,

        error.InvalidInput, error.MissingRequiredField, error.InvalidFormat, error.ValidationFailed, error.ConfigurationError, error.ConfigParseError, error.ConfigValidationFailed, error.DriverNotEnabled => .BadRequest,

        error.HttpError, error.ServerError => .ServerError,

        else => .ServerError,
    };
}

/// Standardized JSON error response
pub const ErrorResponse = struct {
    code: i32,
    message: []const u8,
    details: ?[]const u8 = null,
};

/// Build a JSON error response string. Caller owns returned memory.
pub fn toJson(allocator: std.mem.Allocator, err: ErrorResponse) ![]u8 {
    if (err.details) |details| {
        return std.fmt.allocPrint(allocator, "{{\"code\":{d},\"message\":\"{s}\",\"details\":\"{s}\"}}", .{ err.code, err.message, details });
    } else {
        return std.fmt.allocPrint(allocator, "{{\"code\":{d},\"message\":\"{s}\"}}", .{ err.code, err.message });
    }
}

/// Convenience: create JSON from ZigModuError + message
pub fn fromError(allocator: std.mem.Allocator, err: ZigModuError, message: []const u8) ![]u8 {
    const resp = ErrorResponse{
        .code = @backingInt(toHttpCode(err)),
        .message = message,
    };
    return toJson(allocator, resp);
}

test "ErrorContext has real timestamp" {
    const ctx = ErrorContext.init(error.ModuleNotFound, "test");
    try std.testing.expect(ctx.timestamp > 0);
    try std.testing.expectEqual(ZigModuError.ModuleNotFound, ctx.error_code);
    try std.testing.expectEqualStrings("test", ctx.message);
}

test "ErrorHandler register and dispatch" {
    const allocator = std.testing.allocator;
    var handler = ErrorHandler.init(allocator);
    defer handler.deinit();

    const Ctx = struct {
        var handled: bool = false;
        fn onModuleNotFound(_: ErrorContext) void {
            handled = true;
        }
    };

    try handler.register(error.ModuleNotFound, Ctx.onModuleNotFound);
    Ctx.handled = false;
    handler.handle(ErrorContext.init(error.ModuleNotFound, "missing module"));
    try std.testing.expect(Ctx.handled);
}

test "Result type ok and err" {
    const R = Result(i32);

    const ok_result = R{ .ok = 42 };
    try std.testing.expect(ok_result.isOk());
    try std.testing.expect(!ok_result.isErr());
    try std.testing.expectEqual(@as(i32, 42), ok_result.unwrap());

    const err_result = R{ .err = ErrorContext.init(error.ValidationFailed, "bad input") };
    try std.testing.expect(err_result.isErr());
    try std.testing.expect(!err_result.isOk());
    try std.testing.expectEqual(ZigModuError.ValidationFailed, err_result.unwrapErr().error_code);
}

test "toHttpCode mapping" {
    try std.testing.expectEqual(HttpCode.NotFound, toHttpCode(error.ModuleNotFound));
    try std.testing.expectEqual(HttpCode.Unauthorized, toHttpCode(error.AuthenticationFailed));
    try std.testing.expectEqual(HttpCode.Forbidden, toHttpCode(error.AuthorizationFailed));
    try std.testing.expectEqual(HttpCode.RateLimit, toHttpCode(error.RateLimitExceeded));
    try std.testing.expectEqual(HttpCode.ServiceUnavailable, toHttpCode(error.CircuitBreakerOpen));
    try std.testing.expectEqual(HttpCode.BadRequest, toHttpCode(error.InvalidInput));
    try std.testing.expectEqual(HttpCode.RequestTimeout, toHttpCode(error.ConnectionTimeout));
}

test "toJson serialization" {
    const allocator = std.testing.allocator;

    const json = try toJson(allocator, .{ .code = 404, .message = "not found" });
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "404") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "not found") != null);
}

test "fromError convenience" {
    const allocator = std.testing.allocator;

    const json = try fromError(allocator, error.RateLimitExceeded, "too many requests");
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "429") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "too many requests") != null);
}

test "toErrorContext maps known errors" {
    const ctx = toErrorContext(error.OutOfMemory, "allocation failed");
    try std.testing.expectEqual(ZigModuError.OutOfMemory, ctx.error_code);
    try std.testing.expectEqualStrings("allocation failed", ctx.message);
}
