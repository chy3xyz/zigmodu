const std = @import("std");

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

    // 安全错误
    AuthenticationFailed,
    AuthorizationFailed,
    TokenExpired,
    InvalidToken,
    InvalidCredentials,

    // 验证错误
    ValidationFailed,
    InvalidInput,
    MissingRequiredField,
    InvalidFormat,

    // 缓存错误
    CacheError,
    CacheKeyNotFound,
    CacheFull,

    // 网络错误
    NetworkError,
    ConnectionTimeout,
    ConnectionRefused,
    HttpError,

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
            .timestamp = std.time.timestamp(),
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
            .handlers = std.ArrayList(HandlerEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.handlers.deinit(self.allocator);
    }

    pub fn register(self: *Self, error_code: ZigModuError, handler: *const fn (ErrorContext) void) !void {
        try self.handlers.append(.{
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
            return @as(@typeInfo(@This()).Union.tag_type.?, self) == .ok;
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
