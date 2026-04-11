const std = @import("std");
const zigmodu = @import("zigmodu");

// Define services
const Database = struct {
    const Self = @This();

    connection_string: []const u8,

    pub fn init(conn_str: []const u8) Self {
        return .{
            .connection_string = conn_str,
        };
    }

    pub fn query(self: *Self, sql: []const u8) void {
        std.log.info("🗄️  DB Query: {s} (via {s})", .{ sql, self.connection_string });
    }
};

const Cache = struct {
    const Self = @This();

    ttl: u32,

    pub fn init(ttl_seconds: u32) Self {
        return .{
            .ttl = ttl_seconds,
        };
    }

    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        std.log.info("💨 Cache get: {s} (ttl={d}s)", .{ key, self.ttl });
        return null; // Simulated miss
    }

    pub fn set(self: *Self, key: []const u8, value: []const u8) void {
        std.log.info("💨 Cache set: {s} = {s}", .{ key, value });
        _ = self;
    }
};

const Logger = struct {
    const Self = @This();

    prefix: []const u8,

    pub fn init(prefix: []const u8) Self {
        return .{
            .prefix = prefix,
        };
    }

    pub fn log(self: *Self, message: []const u8) void {
        std.log.info("[{s}] {s}", .{ self.prefix, message });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Dependency Injection Example ===", .{});

    // Create DI container
    var container = zigmodu.extensions.Container.init(allocator);
    defer container.deinit();

    std.log.info("📦 Creating services...", .{});

    // Create services
    var db = Database.init("postgresql://localhost:5432/myapp");
    var cache = Cache.init(300); // 5 minutes TTL
    var logger = Logger.init("MyApp");

    // Register services
    try container.register("database", &db);
    try container.register("cache", &cache);
    try container.register("logger", &logger);

    std.log.info("✅ Services registered\n", .{});

    // Retrieve and use services
    std.log.info("🔍 Retrieving services...", .{});

    const db_ptr = container.getTyped("database", Database);
    if (db_ptr) |db_service| {
        db_service.query("SELECT * FROM users");
    }

    const cache_ptr = container.getTyped("cache", Cache);
    if (cache_ptr) |cache_service| {
        _ = cache_service.get("user:123");
        cache_service.set("user:123", "{\"id\": 123, \"name\": \"Alice\"}");
    }

    const logger_ptr = container.getTyped("logger", Logger);
    if (logger_ptr) |logger_service| {
        logger_service.log("Application started successfully");
    }

    // Try to retrieve non-existent service
    const missing = container.getTyped("nonexistent", Database);
    if (missing == null) {
        std.log.info("\n⚠️  Service 'nonexistent' not found (expected)", .{});
    }

    std.log.info("\n✅ DI example complete!", .{});
}
