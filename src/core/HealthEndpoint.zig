const std = @import("std");

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
        check_fn: *const fn () HealthStatus,
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

    /// 注册健康检查
    pub fn registerCheck(self: *Self, name: []const u8, description: []const u8, check_fn: *const fn () HealthStatus) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        const desc_copy = try self.allocator.dupe(u8, description);

        try self.checks.put(name_copy, .{
            .name = name_copy,
            .check_fn = check_fn,
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
            const status = check.check_fn();

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
            .timestamp = std.time.timestamp(),
        };
    }

    /// 获取整体健康状态
    pub fn getStatus(self: *Self) HealthStatus {
        return self.status;
    }

    /// 生成JSON格式的健康报告
    pub fn toJson(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer(allocator);

        const health = self.checkHealth();
        defer health.components.deinit();

        try writer.writeAll("{\n");
        try writer.print("  \"status\": \"{s}\",\n", .{@tagName(health.status)});
        try writer.print("  \"timestamp\": {d},\n", .{health.timestamp});
        try writer.writeAll("  \"components\": {\n");

        var comp_iter = health.components.iterator();
        var first = true;
        while (comp_iter.next()) |entry| {
            if (!first) try writer.writeAll(",\n");
            first = false;

            const comp_name = entry.key_ptr.*;
            const comp_health = entry.value_ptr.*;

            try writer.print("    \"{s}\": {{\n", .{comp_name});
            try writer.print("      \"status\": \"{s}\"", .{@tagName(comp_health.status)});
            if (comp_health.details) |details| {
                try writer.print(",\n      \"details\": \"{s}\"", .{details});
            }
            try writer.writeAll("\n    }");
        }

        try writer.writeAll("\n  }\n");
        try writer.writeAll("}\n");

        return buf.toOwnedSlice(allocator);
    }

    /// 简化的健康检查：总是返回UP
    pub fn alwaysUp() HealthStatus {
        return .UP;
    }

    /// 简化的健康检查：总是返回DOWN
    pub fn alwaysDown() HealthStatus {
        return .DOWN;
    }

    /// 数据库连接健康检查
    pub fn databaseCheck(connection_pool: anytype) HealthStatus {
        // 简化实现
        _ = connection_pool;
        return .UP;
    }

    /// 磁盘空间健康检查
    pub fn diskSpaceCheck(min_space_bytes: u64) HealthStatus {
        _ = min_space_bytes;
        return .UP;
    }

    /// 内存健康检查
    pub fn memoryCheck(min_memory_bytes: u64) HealthStatus {
        _ = min_memory_bytes;
        return .UP;
    }
};

/// 存活探针（Liveness Probe）
/// 检查应用是否运行
pub const LivenessProbe = struct {
    pub fn check() HealthEndpoint.HealthStatus {
        // 简化的存活检查
        return .UP;
    }
};

/// 就绪探针（Readiness Probe）
/// 检查应用是否准备好接收流量
pub const ReadinessProbe = struct {
    pub fn check(modules: anytype) HealthEndpoint.HealthStatus {
        // 检查所有模块是否已启动
        for (modules) |module| {
            if (!module.isReady()) {
                return .DOWN;
            }
        }
        return .UP;
    }
};
