const std = @import("std");
const zigmodu = @import("zigmodu");

// ============================================
// Example 3: Dependency Injection
// ============================================
// Demonstrates: Container, service registration, type-safe retrieval

// 定义服务
const DatabaseConfig = struct {
    host: []const u8 = "localhost",
    port: u16 = 5432,
    database: []const u8 = "shop",
};

const Database = struct {
    config: *DatabaseConfig,
    connected: bool = false,

    pub fn connect(self: *Database) !void {
        if (self.connected) return;

        std.log.info("[db] Connecting to {s}:{d}/{s}", .{
            self.config.host,
            self.config.port,
            self.config.database,
        });

        self.connected = true;
        std.log.info("[db] ✓ Connected successfully", .{});
    }

    pub fn query(self: *Database, sql: []const u8) !void {
        if (!self.connected) return error.NotConnected;

        std.log.info("[db] Executing: {s}", .{sql});
    }

    pub fn disconnect(self: *Database) void {
        if (!self.connected) return;

        std.log.info("[db] Disconnecting...", .{});
        self.connected = false;
    }
};

const Cache = struct {
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn get(self: *Cache, key: []const u8) ?[]const u8 {
        _ = key;
        // 模拟缓存逻辑
        if (self.hits % 2 == 0) {
            self.hits += 1;
            return "cached_value";
        } else {
            self.misses += 1;
            return null;
        }
    }

    pub fn put(self: *Cache, key: []const u8, value: []const u8) void {
        _ = self;
        std.log.info("[cache] Storing: {s} = {s}", .{ key, value });
    }
};

const Logger = struct {
    prefix: []const u8,

    pub fn log(self: *Logger, message: []const u8) void {
        std.log.info("[{s}] {s}", .{ self.prefix, message });
    }
};

// 使用 DI 的服务
const UserService = struct {
    db: *Database,
    cache: *Cache,
    logger: *Logger,

    pub fn getUser(self: *UserService, user_id: u64) !?User {
        self.logger.log("Fetching user");

        // 尝试从缓存获取
        const cache_key = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "user:{d}",
            .{user_id},
        );
        defer std.heap.page_allocator.free(cache_key);

        if (self.cache.get(cache_key)) |_| {
            self.logger.log("Cache hit!");
            return User{ .id = user_id, .name = "Cached User" };
        }

        // 从数据库查询
        self.logger.log("Cache miss, querying database");
        try self.db.query("SELECT * FROM users WHERE id = ?");

        const user = User{ .id = user_id, .name = "John Doe" };

        // 存入缓存
        self.cache.put(cache_key, "user_data");

        return user;
    }
};

const User = struct {
    id: u64,
    name: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== ZigModu Dependency Injection Example ===", .{});
    std.log.info("Demonstrates: Container, service registration, type-safe retrieval\n", .{});

    // 创建 DI 容器
    var container = zigmodu.extensions.Container.init(allocator);
    defer container.deinit();

    std.log.info("=== Phase 1: Service Registration ===", .{});

    // 1. 注册配置
    const config = try allocator.create(DatabaseConfig);
    config.* = .{
        .host = "localhost",
        .port = 5432,
        .database = "ecommerce",
    };
    try container.register(DatabaseConfig, "config", config);
    std.log.info("✓ Registered: DatabaseConfig as 'config'", .{});

    // 2. 注册数据库（依赖配置）
    const db = try allocator.create(Database);
    db.* = .{ .config = config };
    try container.register(Database, "database", db);
    std.log.info("✓ Registered: Database as 'database'", .{});

    // 3. 注册缓存
    const cache = try allocator.create(Cache);
    cache.* = .{};
    try container.register(Cache, "cache", cache);
    std.log.info("✓ Registered: Cache as 'cache'", .{});

    // 4. 注册日志器
    const logger = try allocator.create(Logger);
    logger.* = .{ .prefix = "UserService" };
    try container.register(Logger, "logger", logger);
    std.log.info("✓ Registered: Logger as 'logger'", .{});

    // 5. 注册 UserService（依赖其他服务）
    const user_service = try allocator.create(UserService);
    user_service.* = .{
        .db = container.get(Database, "database").?,
        .cache = container.get(Cache, "cache").?,
        .logger = container.get(Logger, "logger").?,
    };
    try container.register(UserService, "user_service", user_service);
    std.log.info("✓ Registered: UserService as 'user_service'", .{});

    std.log.info("", .{});
    std.log.info("=== Phase 2: Service Retrieval ===", .{});

    // 从容器获取服务并使用
    if (container.get(Database, "database")) |database| {
        try database.connect();
    }

    std.log.info("", .{});
    std.log.info("=== Phase 3: Business Logic ===", .{});

    if (container.get(UserService, "user_service")) |service| {
        const user = try service.getUser(123);
        if (user) |u| {
            std.log.info("✓ Retrieved user: {d} - {s}", .{ u.id, u.name });
        }

        // 第二次查询（应该命中缓存）
        const user2 = try service.getUser(123);
        if (user2) |u| {
            std.log.info("✓ Retrieved user (cached): {d} - {s}", .{ u.id, u.name });
        }
    }

    std.log.info("", .{});
    std.log.info("=== Phase 4: Scoped Container ===", .{});

    // 演示作用域容器
    var scoped = zigmodu.extensions.ScopedContainer.init(
        allocator,
        "request-scope",
        &container,
    );
    defer scoped.deinit();

    // 在作用域中注册临时服务
    const request_logger = try allocator.create(Logger);
    request_logger.* = .{ .prefix = "Request" };
    try scoped.register(Logger, "request_logger", request_logger);

    // 可以访问父容器的服务
    if (scoped.get(Database, "database")) |parent_db| {
        std.log.info("✓ Accessed parent service from scoped container", .{});
        try parent_db.query("SELECT * FROM requests");
    }

    std.log.info("", .{});
    std.log.info("=== Benefits of Dependency Injection ===", .{});
    std.log.info("1. Decoupling: Services depend on abstractions", .{});
    std.log.info("2. Testability: Easy to mock dependencies", .{});
    std.log.info("3. Flexibility: Swap implementations easily", .{});
    std.log.info("4. Lifecycle: Container manages object lifetime", .{});
    std.log.info("5. Type Safety: Compile-time type checking", .{});
}
