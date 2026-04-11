const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// Config Module - 配置模块
/// 提供应用配置管理、环境配置、热重载等功能
/// ============================================
pub const ConfigModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "config",
        .description = "Application configuration management with hot reload",
        .dependencies = &.{},
    };

    var config: AppConfig = .{};
    var allocator: std.mem.Allocator = undefined;
    var config_file_path: []const u8 = "";
    var last_modified: i128 = 0;
    var config_mutex: std.Thread.Mutex = .{};

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        std.log.info("[config] Configuration module initialized", .{});
    }

    pub fn deinit() void {
        // Only free if strings were allocated (not string literals)
        if (config_file_path.len > 0 and @intFromPtr(config_file_path.ptr) >= 0x100000000) {
            allocator.free(config_file_path);
        }
        std.log.info("[config] Configuration module cleaned up", .{});
    }

    /// 应用配置
    pub const AppConfig = struct {
        // 服务器配置
        server: ServerConfig = .{},
        // 数据库配置
        database: DatabaseConfig = .{},
        // 安全配置
        security: SecurityConfig = .{},
        // 缓存配置
        cache: CacheConfig = .{},
        // 支付配置
        payment: PaymentConfig = .{},
        // 通知配置
        notification: NotificationConfig = .{},
        // 功能开关
        features: FeatureFlags = .{},

        pub fn deinit(self: *AppConfig, alloc: std.mem.Allocator) void {
            self.server.deinit(alloc);
            self.database.deinit(alloc);
            self.security.deinit(alloc);
        }
    };

    /// 服务器配置
    pub const ServerConfig = struct {
        host: []const u8 = "0.0.0.0",
        port: u16 = 8080,
        max_connections: u32 = 1000,
        request_timeout_seconds: u32 = 30,
        read_buffer_size: usize = 8192,
        write_buffer_size: usize = 8192,

        pub fn deinit(self: *ServerConfig, alloc: std.mem.Allocator) void {
            // Note: Only free if the string was allocated, not for string literals
            // In this implementation, default strings are literals and shouldn't be freed
            _ = self;
            _ = alloc;
        }
    };

    /// 数据库配置
    pub const DatabaseConfig = struct {
        driver: []const u8 = "sqlite",
        host: []const u8 = "localhost",
        port: u16 = 5432,
        database: []const u8 = "bookstore",
        username: []const u8 = "bookstore_user",
        password: []const u8 = "password",
        max_connections: u32 = 10,
        connection_timeout_ms: u32 = 5000,
        query_timeout_ms: u32 = 30000,

        pub fn deinit(self: *DatabaseConfig, alloc: std.mem.Allocator) void {
            // Note: Only free if the string was allocated, not for string literals
            _ = self;
            _ = alloc;
        }
    };

    /// 安全配置
    pub const SecurityConfig = struct {
        jwt_secret: []const u8 = "change-this-secret-in-production",
        jwt_expiry_hours: u32 = 24,
        bcrypt_cost: u32 = 12,
        enable_https: bool = false,
        https_cert_path: []const u8 = "",
        https_key_path: []const u8 = "",
        cors_origins: []const []const u8 = &.{"*"},
        rate_limit_requests: u32 = 100,
        rate_limit_window_seconds: u32 = 60,

        pub fn deinit(self: *SecurityConfig, alloc: std.mem.Allocator) void {
            // Note: Only free if the string was allocated, not for string literals
            _ = self;
            _ = alloc;
        }
    };

    /// 缓存配置
    pub const CacheConfig = struct {
        enabled: bool = false,
        driver: []const u8 = "memory",
        host: []const u8 = "localhost",
        port: u16 = 6379,
        password: []const u8 = "",
        database: u32 = 0,
        default_ttl_seconds: u32 = 3600,
    };

    /// 支付配置
    pub const PaymentConfig = struct {
        stripe_enabled: bool = false,
        stripe_secret_key: []const u8 = "",
        stripe_publishable_key: []const u8 = "",
        paypal_enabled: bool = false,
        paypal_client_id: []const u8 = "",
        paypal_secret: []const u8 = "",
        webhook_secret: []const u8 = "",
    };

    /// 通知配置
    pub const NotificationConfig = struct {
        email_enabled: bool = false,
        smtp_host: []const u8 = "smtp.gmail.com",
        smtp_port: u16 = 587,
        smtp_username: []const u8 = "",
        smtp_password: []const u8 = "",
        smtp_from_address: []const u8 = "noreply@bookstore.com",
        sms_enabled: bool = false,
        sms_provider: []const u8 = "twilio",
        push_enabled: bool = false,
    };

    /// 功能开关
    pub const FeatureFlags = struct {
        enable_registration: bool = true,
        enable_checkout: bool = true,
        enable_reviews: bool = false,
        enable_recommendations: bool = false,
        enable_analytics: bool = true,
        maintenance_mode: bool = false,
    };

    /// 加载配置文件
    pub fn loadFromFile(path: []const u8) !void {
        config_file_path = try allocator.dupe(u8, path);

        // 检查文件是否存在
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.log.warn("[config] Config file not found at {s}: {any}", .{ path, err });
            return;
        };
        defer file.close();

        // 获取文件修改时间
        const stat = try file.stat();
        last_modified = stat.mtime;

        // 读取文件内容
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // 解析配置（简化实现，实际应该解析 JSON/TOML）
        try parseConfig(content);

        std.log.info("[config] Loaded configuration from {s}", .{path});
    }

    /// 解析配置（简化实现）
    fn parseConfig(content: []const u8) !void {
        _ = content;
        // 实际实现应该解析 JSON/TOML/YAML
        // 这里使用默认配置
    }

    /// 获取配置（线程安全）
    pub fn getConfig() AppConfig {
        config_mutex.lock();
        defer config_mutex.unlock();
        return config;
    }

    /// 更新配置（线程安全）
    pub fn updateConfig(new_config: AppConfig) !void {
        config_mutex.lock();
        defer config_mutex.unlock();

        // 释放旧配置
        config.deinit(allocator);

        // 设置新配置
        config = new_config;

        std.log.info("[config] Configuration updated", .{});
    }

    /// 检查配置文件是否有更新
    pub fn checkForUpdates() !bool {
        if (config_file_path.len == 0) return false;

        const file = std.fs.cwd().openFile(config_file_path, .{}) catch return false;
        defer file.close();

        const stat = try file.stat();
        if (stat.mtime > last_modified) {
            std.log.info("[config] Config file changed, reloading...", .{});
            try loadFromFile(config_file_path);
            return true;
        }

        return false;
    }

    /// 获取环境类型
    pub fn getEnvironment() Environment {
        // 从环境变量或配置中读取
        return .development;
    }

    /// 环境类型
    pub const Environment = enum {
        development,
        testing,
        staging,
        production,

        pub fn toString(self: Environment) []const u8 {
            return switch (self) {
                .development => "development",
                .testing => "testing",
                .staging => "staging",
                .production => "production",
            };
        }
    };

    /// 验证配置
    pub fn validate() !ValidationResult {
        var result = ValidationResult.init(allocator);
        errdefer result.deinit(allocator);

        // 验证服务器配置
        if (config.server.port == 0 or config.server.port > 65535) {
            result.valid = false;
            try result.errors.append(allocator, "Invalid server port");
        }

        // 验证安全配置
        if (config.security.jwt_secret.len < 32) {
            result.valid = false;
            try result.errors.append(allocator, "JWT secret must be at least 32 characters");
        }

        // 验证数据库配置
        if (config.database.max_connections == 0) {
            result.valid = false;
            try result.errors.append(allocator, "Database max_connections must be greater than 0");
        }

        return result;
    }

    /// 验证结果
    pub const ValidationResult = struct {
        valid: bool,
        errors: std.ArrayList([]const u8),

        pub fn init(_alloc: std.mem.Allocator) ValidationResult {
            _ = _alloc;
            return .{
                .valid = true,
                .errors = std.ArrayList([]const u8){},
            };
        }

        pub fn deinit(self: *ValidationResult, alloc: std.mem.Allocator) void {
            for (self.errors.items) |err| {
                alloc.free(err);
            }
            self.errors.deinit(alloc);
        }
    };

    /// 获取配置摘要（用于日志）
    pub fn getConfigSummary() ![]const u8 {
        return try std.fmt.allocPrint(allocator, "Server: {s}:{d}, Database: {s}, Environment: {s}", .{
            config.server.host,
            config.server.port,
            config.database.driver,
            getEnvironment().toString(),
        });
    }
};

test "Config module" {
    try ConfigModule.init();
    defer ConfigModule.deinit();

    // Get default config
    const cfg = ConfigModule.getConfig();
    try std.testing.expectEqual(@as(u16, 8080), cfg.server.port);

    // Update config
    var new_config = ConfigModule.AppConfig{};
    new_config.server.port = 9090;
    try ConfigModule.updateConfig(new_config);

    const updated = ConfigModule.getConfig();
    try std.testing.expectEqual(@as(u16, 9090), updated.server.port);

    // Validate
    const validation = try ConfigModule.validate();
    try std.testing.expect(validation.valid);
    validation.errors.deinit(std.testing.allocator);
}
