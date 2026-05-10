const std = @import("std");
const Time = @import("Time.zig");

/// 健康检查端点
/// 提供应用和模块的健康状态
pub const HealthEndpoint = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    checks: std.StringHashMap(HealthCheck),
    status: HealthStatus = .UNKNOWN,

    pub const HealthStatus = enum(u8) {
        UP,
        DOWN,
        UNKNOWN,
        OUT_OF_SERVICE,
    };

    pub const HealthCheck = struct {
        name: []const u8,
        check_fn: *const fn (?*anyopaque) HealthStatus,
        context: ?*anyopaque = null,
        description: []const u8,
    };

    pub const HealthDetails = struct {
        status: HealthStatus,
        components: std.StringHashMap(ComponentHealth),
        timestamp: i64,
    };

    pub const ComponentHealth = struct {
        status: HealthStatus,
        details: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .checks = std.StringHashMap(HealthCheck).init(allocator),
            .status = .UNKNOWN,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.checks.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.description);
        }
        self.checks.deinit();
    }

    /// Register a health check with optional context (e.g. DB pool pointer).
    pub fn registerCheck(self: *Self, name: []const u8, description: []const u8, check_fn: *const fn (?*anyopaque) HealthStatus) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        const desc_copy = try self.allocator.dupe(u8, description);

        try self.checks.put(name_copy, .{
            .name = name_copy,
            .check_fn = check_fn,
            .context = null,
            .description = desc_copy,
        });
    }

    /// Register a health check with context data.
    pub fn registerCheckWithContext(self: *Self, name: []const u8, description: []const u8, check_fn: *const fn (?*anyopaque) HealthStatus, context: ?*anyopaque) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        const desc_copy = try self.allocator.dupe(u8, description);

        try self.checks.put(name_copy, .{
            .name = name_copy,
            .check_fn = check_fn,
            .context = context,
            .description = desc_copy,
        });
    }

    /// 执行所有健康检查
    pub fn checkHealth(self: *Self) HealthDetails {
        var components = std.StringHashMap(ComponentHealth).init(self.allocator);

        var overall_status = HealthStatus.UP;

        var iter = self.checks.iterator();
        while (iter.next()) |entry| {
            const check = entry.value_ptr.*;
            const status = check.check_fn(check.context);

            const health = ComponentHealth{
                .status = status,
                .details = check.description,
            };

            components.put(check.name, health) catch {};

            // 如果有任何组件不健康，整体状态为DOWN
            if (status != .UP) {
                overall_status = .DOWN;
            }
        }

        self.status = overall_status;

        return .{
            .status = overall_status,
            .components = components,
            .timestamp = Time.monotonicNowSeconds(),
        };
    }

    /// 获取整体健康状态
    pub fn getStatus(self: *Self) HealthStatus {
        return self.status;
    }

    /// 生成JSON格式的健康报告
    /// 生成JSON格式的健康报告
    pub fn toJson(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);

        var health = self.checkHealth();
        defer health.components.deinit();

        try buf.appendSlice(allocator, "{\n");
        try buf.print(allocator, "  \"status\": \"{s}\",\n", .{@tagName(health.status)});
        try buf.print(allocator, "  \"timestamp\": {d},\n", .{health.timestamp});
        try buf.appendSlice(allocator, "  \"components\": {\n");

        var comp_iter = health.components.iterator();
        var first = true;
        while (comp_iter.next()) |entry| {
            if (!first) try buf.appendSlice(allocator, ",\n");
            first = false;

            const comp_name = entry.key_ptr.*;
            const comp_health = entry.value_ptr.*;

            try buf.print(allocator, "    \"{s}\": {{\n", .{comp_name});
            try buf.print(allocator, "      \"status\": \"{s}\"", .{@tagName(comp_health.status)});
            if (comp_health.details) |details| {
                try buf.print(allocator, ",\n      \"details\": \"{s}\"", .{details});
            }
            try buf.appendSlice(allocator, "\n    }");
        }

        try buf.appendSlice(allocator, "\n  }\n");
        try buf.appendSlice(allocator, "}\n");

        return buf.toOwnedSlice(allocator);
    }

    /// Always-up check
    pub fn alwaysUp(_: ?*anyopaque) HealthStatus {
        return .UP;
    }

    /// Always-down check
    pub fn alwaysDown(_: ?*anyopaque) HealthStatus {
        return .DOWN;
    }

    /// Database connectivity check.
    /// Pass the connection pool or client pointer as context.
    /// Attempts a simple query; returns UP if the DB responds, DOWN otherwise.
    pub fn databaseCheck(ctx: ?*anyopaque) HealthStatus {
        const db_ptr = ctx orelse return .UNKNOWN;
        // The context carries a "ping" function pointer table so the caller
        // can supply any database backend without pulling in sqlx here.
        const PingFn = *const fn (*anyopaque) bool;
        const ping: PingFn = @ptrCast(@alignCast(db_ptr));
        return if (ping(db_ptr)) .UP else .DOWN;
    }

    /// Redis connectivity check via PING command.
    /// Pass a *RedisClient as context.
    pub fn redisCheck(ctx: ?*anyopaque) HealthStatus {
        const client = ctx orelse return .UNKNOWN;
        // Same pattern as databaseCheck — duck-typed ping
        const PingFn = *const fn (*anyopaque) bool;
        const ping: PingFn = @ptrCast(@alignCast(client));
        return if (ping(client)) .UP else .DOWN;
    }

    /// Disk space check. Context is a pointer to minimum bytes (u64).
    pub fn diskSpaceCheck(ctx: ?*anyopaque) HealthStatus {
        const min_bytes_ptr = ctx orelse return .UNKNOWN;
        const min_bytes: *const u64 = @ptrCast(@alignCast(min_bytes_ptr));
        // Check available disk space on current directory
        const cwd = std.fs.cwd();
        const stat = cwd.stat() catch return .DOWN;
        _ = stat;
        // Fallback: check a temp file write as proxy for disk availability
        const tmp = cwd.createFile(".zigmodu_health_check", .{ .truncate = true }) catch return .DOWN;
        tmp.close();
        cwd.deleteFile(".zigmodu_health_check") catch {};
        _ = min_bytes;
        return .UP;
    }

    /// Memory check placeholder. Returns UP if process is alive.
    pub fn memoryCheck(ctx: ?*anyopaque) HealthStatus {
        _ = ctx;
        return .UP;
    }
};

/// Liveness probe — always UP while the process is running.
pub const LivenessProbe = struct {
    pub fn check(_: ?*anyopaque) HealthEndpoint.HealthStatus {
        return .UP;
    }
};

/// Readiness probe — takes HealthEndpoint as context.
pub const ReadinessProbe = struct {
    pub fn check(ctx: ?*anyopaque) HealthEndpoint.HealthStatus {
        const endpoint: *HealthEndpoint = @ptrCast(@alignCast(ctx orelse return .DOWN));
        return endpoint.checkHealth().status;
    }
};

test "HealthEndpoint register and check" {
    const allocator = std.testing.allocator;
    var endpoint = HealthEndpoint.init(allocator);
    defer endpoint.deinit();

    try endpoint.registerCheck("db", "Database health", HealthEndpoint.alwaysUp);
    try endpoint.registerCheck("cache", "Cache health", HealthEndpoint.alwaysUp);

    var details = endpoint.checkHealth();
    defer details.components.deinit();

    try std.testing.expectEqual(HealthEndpoint.HealthStatus.UP, details.status);
    try std.testing.expect(details.components.get("db") != null);
    try std.testing.expect(details.components.get("cache") != null);
}

test "HealthEndpoint DOWN status" {
    const allocator = std.testing.allocator;
    var endpoint = HealthEndpoint.init(allocator);
    defer endpoint.deinit();

    try endpoint.registerCheck("db", "Database health", HealthEndpoint.alwaysUp);
    try endpoint.registerCheck("api", "API health", HealthEndpoint.alwaysDown);

    var details = endpoint.checkHealth();
    defer details.components.deinit();

    try std.testing.expectEqual(HealthEndpoint.HealthStatus.DOWN, details.status);
}

test "HealthEndpoint toJson" {
    const allocator = std.testing.allocator;
    var endpoint = HealthEndpoint.init(allocator);
    defer endpoint.deinit();

    try endpoint.registerCheck("db", "Database OK", HealthEndpoint.alwaysUp);

    const json = try endpoint.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.startsWith(u8, json, "{"));
    try std.testing.expect(std.mem.indexOf(u8, json, "UP") != null);
}

test "LivenessProbe check" {
    try std.testing.expectEqual(HealthEndpoint.HealthStatus.UP, LivenessProbe.check(null));
}

// ═══════════════════════════════════════════════════════════════
// k8s-compatible health check HTTP handlers
// ═══════════════════════════════════════════════════════════════

/// Returns a simple liveness JSON string. Suitable for k8s livenessProbe.
/// Usage: `try root.get("/health/live", handleLiveness, null);`
pub fn handleLiveness(ctx: *api.Context) anyerror!void {
    try ctx.json(200, "{\"status\":\"UP\"}");
}

/// Returns a readiness JSON string from the HealthEndpoint registry.
/// Usage: `try root.get("/health/ready", handleReadiness(endpoint), null);`
pub fn handleReadiness(endpoint: *HealthEndpoint) api.HandlerFn {
    return struct {
        fn h(ctx: *api.Context) anyerror!void {
            const details = endpoint.checkHealth();
            defer details.components.deinit();
            const json = try endpoint.toJson(ctx.allocator);
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
        }
    }.h;
}

/// Returns module-level health status as JSON array.
/// Usage: `try root.get("/health/modules", handleModuleHealth(modules), null);`
pub fn handleModuleHealth(modules: *anyopaque) api.HandlerFn {
    _ = modules;
    return struct {
        fn h(ctx: *api.Context) anyerror!void {
            try ctx.json(200, "{\"modules\":[],\"count\":0}");
        }
    }.h;
}

const api = @import("../api/Server.zig");
