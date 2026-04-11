const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// Audit Module - 审计日志模块
/// 提供操作审计、性能监控、安全日志等功能
/// ============================================
pub const AuditModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "audit",
        .description = "Audit logging and performance monitoring",
        .dependencies = &.{"database"},
    };

    var audit_logs: std.ArrayList(AuditLog) = undefined;
    var performance_metrics: std.ArrayList(PerformanceMetric) = undefined;
    var error_logs: std.ArrayList(ErrorLog) = undefined;
    var log_id_counter: u64 = 1;
    var allocator: std.mem.Allocator = undefined;

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        audit_logs = std.ArrayList(AuditLog){};
        performance_metrics = std.ArrayList(PerformanceMetric){};
        error_logs = std.ArrayList(ErrorLog){};
        std.log.info("[audit] Audit module initialized", .{});
    }

    pub fn deinit() void {
        for (audit_logs.items) |*log| {
            allocator.free(log.action);
            allocator.free(log.resource_type);
            if (log.details) |details| {
                allocator.free(details);
            }
        }
        audit_logs.deinit(allocator);

        for (performance_metrics.items) |*metric| {
            allocator.free(metric.operation);
        }
        performance_metrics.deinit(allocator);

        for (error_logs.items) |*err| {
            allocator.free(err.error_type);
            allocator.free(err.message);
            if (err.stack_trace) |st| {
                allocator.free(st);
            }
            if (err.context) |ctx| {
                allocator.free(ctx);
            }
        }
        error_logs.deinit(allocator);

        std.log.info("[audit] Audit module cleaned up", .{});
    }

    /// 审计日志
    pub const AuditLog = struct {
        id: u64,
        user_id: ?u64,
        action: []const u8,
        resource_type: []const u8,
        resource_id: ?u64,
        details: ?[]const u8,
        success: bool,
        timestamp: i64,
    };

    /// 审计日志参数
    pub const AuditLogParams = struct {
        user_id: ?u64 = null,
        action: []const u8,
        resource_type: []const u8,
        resource_id: ?u64 = null,
        details: ?[]const u8 = null,
        success: bool,
    };

    /// 记录审计日志
    pub fn logAudit(params: AuditLogParams) !void {
        const log = AuditLog{
            .id = log_id_counter,
            .user_id = params.user_id,
            .action = try allocator.dupe(u8, params.action),
            .resource_type = try allocator.dupe(u8, params.resource_type),
            .resource_id = params.resource_id,
            .details = if (params.details) |d| try allocator.dupe(u8, d) else null,
            .success = params.success,
            .timestamp = std.time.timestamp(),
        };

        log_id_counter += 1;
        try audit_logs.append(allocator, log);

        std.log.info("[audit] {s} {s} by user {?d} - {s}", .{ params.action, params.resource_type, params.user_id, if (params.success) "SUCCESS" else "FAILED" });
    }

    /// 性能指标
    pub const PerformanceMetric = struct {
        id: u64,
        operation: []const u8,
        duration_ms: u64,
        timestamp: i64,
    };

    /// 记录性能指标
    pub fn recordPerformance(operation: []const u8, duration_ms: u64) !void {
        const metric = PerformanceMetric{
            .id = log_id_counter,
            .operation = try allocator.dupe(u8, operation),
            .duration_ms = duration_ms,
            .timestamp = std.time.timestamp(),
        };

        log_id_counter += 1;
        try performance_metrics.append(allocator, metric);
    }

    /// 错误日志级别
    pub const LogLevel = enum {
        debug,
        info,
        warning,
        error_,
        critical,
    };

    /// 错误日志
    pub const ErrorLog = struct {
        id: u64,
        error_type: []const u8,
        message: []const u8,
        level: LogLevel,
        stack_trace: ?[]const u8,
        user_id: ?u64,
        context: ?[]const u8,
        timestamp: i64,
    };

    /// 错误日志参数
    pub const ErrorLogParams = struct {
        error_type: []const u8,
        message: []const u8,
        level: LogLevel = .error_,
        stack_trace: ?[]const u8 = null,
        user_id: ?u64 = null,
        context: ?[]const u8 = null,
    };

    /// 记录错误日志
    pub fn logError(params: ErrorLogParams) !void {
        const err = ErrorLog{
            .id = log_id_counter,
            .error_type = try allocator.dupe(u8, params.error_type),
            .message = try allocator.dupe(u8, params.message),
            .level = params.level,
            .stack_trace = if (params.stack_trace) |st| try allocator.dupe(u8, st) else null,
            .user_id = params.user_id,
            .context = if (params.context) |ctx| try allocator.dupe(u8, ctx) else null,
            .timestamp = std.time.timestamp(),
        };

        log_id_counter += 1;
        try error_logs.append(allocator, err);

        std.log.err("[audit] Error: {s} - {s}", .{ params.error_type, params.message });
    }

    /// 获取审计日志
    pub fn getAuditLogs(user_id: ?u64, action: ?[]const u8) ![]AuditLog {
        var result = std.ArrayList(AuditLog){};
        for (audit_logs.items) |log| {
            if (user_id) |uid| {
                if (log.user_id != uid) continue;
            }
            if (action) |act| {
                if (!std.mem.eql(u8, log.action, act)) continue;
            }
            try result.append(allocator, log);
        }
        return result.toOwnedSlice(allocator);
    }

    /// 获取性能统计
    pub fn getPerformanceStats() PerformanceStats {
        var stats = PerformanceStats{};

        for (performance_metrics.items) |metric| {
            stats.total_operations += 1;
            stats.total_duration_ms += metric.duration_ms;

            if (metric.duration_ms > stats.max_duration_ms) {
                stats.max_duration_ms = metric.duration_ms;
            }
            if (stats.min_duration_ms == 0 or metric.duration_ms < stats.min_duration_ms) {
                stats.min_duration_ms = metric.duration_ms;
            }
        }

        if (stats.total_operations > 0) {
            stats.avg_duration_ms = stats.total_duration_ms / stats.total_operations;
        }

        return stats;
    }

    /// 性能统计
    pub const PerformanceStats = struct {
        total_operations: u64 = 0,
        total_duration_ms: u64 = 0,
        avg_duration_ms: u64 = 0,
        min_duration_ms: u64 = 0,
        max_duration_ms: u64 = 0,
    };

    /// 获取错误统计
    pub fn getErrorStats() ErrorStats {
        var stats = ErrorStats{};

        for (error_logs.items) |err| {
            stats.total_errors += 1;

            switch (err.level) {
                .debug => stats.debug_count += 1,
                .info => stats.info_count += 1,
                .warning => stats.warning_count += 1,
                .error_ => stats.error_count += 1,
                .critical => stats.critical_count += 1,
            }
        }

        return stats;
    }

    /// 错误统计
    pub const ErrorStats = struct {
        total_errors: u64 = 0,
        debug_count: u64 = 0,
        info_count: u64 = 0,
        warning_count: u64 = 0,
        error_count: u64 = 0,
        critical_count: u64 = 0,
    };
};

test "Audit module" {
    try AuditModule.init();
    defer AuditModule.deinit();

    // Log audit
    try AuditModule.logAudit(.{
        .user_id = 1,
        .action = "CREATE_BOOK",
        .resource_type = "book",
        .success = true,
    });

    // Log error
    try AuditModule.logError(.{
        .error_type = "DatabaseError",
        .message = "Connection failed",
        .level = .error_,
    });

    // Get logs
    const logs = try AuditModule.getAuditLogs(1, null);
    try std.testing.expect(logs.len > 0);
}
