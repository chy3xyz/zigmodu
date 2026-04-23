const std = @import("std");
const Time = @import("Time.zig");

/// ZigModu 统一错误类型
pub const ZigModuError = error{
    // 模块相关错误
    ModuleNotFound,
    ModuleAlreadyExists,
    ModuleInitializationFailed,
    ModuleDeinitializationFailed,

    // 依赖相关错误
    DependencyNotFound,
    DependencyViolation,
    CircularDependency,
    SelfDependency,

    // 生命周期错误
    InvalidLifecycleState,
    StartupFailed,
    ShutdownFailed,

    // 配置错误
    ConfigurationError,
    ConfigFileNotFound,
    ConfigParseError,
    ConfigValidationFailed,

    // DI 容器错误
    ServiceNotFound,
    ServiceAlreadyExists,
    TypeMismatch,
    ContainerClosed,

    // 事件系统错误
    EventBusError,
    EventHandlerNotFound,
    EventSerializationFailed,

    // 事务错误
    TransactionFailed,
    TransactionRollbackFailed,
    TransactionAlreadyActive,
    NoActiveTransaction,

    // 数据库错误
    DatabaseConnectionFailed,
    QueryExecutionFailed,
    ConnectionPoolExhausted,
    PoolUnhealthy,
    DatabaseError,
    RedisError,

    // 通用业务错误
    NotFound,
    RateLimitExceeded,
    CircuitBreakerOpen,
    ServiceUnavailable,
    ServiceOverloaded,

    // 安全错误
    AuthenticationFailed,
    AuthorizationFailed,
    TokenExpired,
    InvalidToken,
    InvalidCredentials,

    // 验证错误
    ValidationFailed,
    InvalidInput,
    InvalidModuleName,
    MissingRequiredField,
    InvalidFormat,

    // 缓存错误
    CacheError,
    CacheKeyNotFound,
    CacheFull,

    // 网络错误
    NetworkError,
    ConnectionTimeout,
    Timeout,
    ConnectionRefused,
    HttpError,
    ServerError,

    // 资源错误
    OutOfMemory,
    ResourceExhausted,
    ResourceLeak,

    // 未知错误
    UnknownError,
};

/// 错误上下文信息
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

/// 错误处理器
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

        // 默认处理：记录日志
        std.log.err("[{s}] {s}", .{ @errorName(ctx.error_code), ctx.message });
    }
};

/// 结果类型别名
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

/// 错误转换辅助函数
pub fn toErrorContext(err: anyerror, message: []const u8) ErrorContext {
    const code = switch (err) {
        error.OutOfMemory => ZigModuError.OutOfMemory,
        error.FileNotFound => ZigModuError.ConfigFileNotFound,
        error.ConnectionRefused => ZigModuError.ConnectionRefused,
        error.ConnectionTimedOut => ZigModuError.ConnectionTimeout,
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
        error.ModuleNotFound,
        error.DependencyNotFound,
        error.CacheKeyNotFound,
        error.NotFound,
        error.ServiceNotFound,
        error.EventHandlerNotFound,
        error.ConfigFileNotFound => .NotFound,

        error.AuthenticationFailed,
        error.InvalidToken,
        error.TokenExpired,
        error.InvalidCredentials => .Unauthorized,

        error.AuthorizationFailed => .Forbidden,

        error.RateLimitExceeded => .RateLimit,

        error.CircuitBreakerOpen,
        error.ServiceUnavailable,
        error.ServiceOverloaded,
        error.ConnectionPoolExhausted => .ServiceUnavailable,

        error.ConnectionTimeout,
        error.Timeout => .RequestTimeout,

        error.InvalidInput,
        error.MissingRequiredField,
        error.InvalidFormat,
        error.ValidationFailed,
        error.ConfigurationError,
        error.ConfigParseError,
        error.ConfigValidationFailed => .BadRequest,

        error.HttpError,
        error.ServerError => .ServerError,

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
        .code = @intFromEnum(toHttpCode(err)),
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
