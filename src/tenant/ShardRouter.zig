//! Shard Router — routes tenant_id to the correct database connection pool.
//!
//! Implements logical sharding at the application level:
//!   request → TenantContext(tenant_id=5) → ShardRouter → DB pool #2
//!
//! Physical partitioning (e.g., tenant_1.table, tenant_2.table) is handled
//! by the database layer (MySQL partition, Citus, Vitess). This module provides
//! the application-level routing primitives.

const std = @import("std");
const tc = @import("TenantContext.zig");

/// Configuration for the shard router.
pub const ShardConfig = struct {
    /// Number of shard pools. Each tenant maps to exactly one pool.
    shard_count: u16 = 1,

    /// Default pool name when no routing is configured.
    default_pool: []const u8 = "default",
};

/// A single shard pool entry.
pub const ShardPool = struct {
    name: []const u8,
    /// DB connection config for this pool.
    host: []const u8,
    port: u16,
    database: []const u8,
    username: []const u8,
    password: []const u8,
    max_conns: u16,
};

/// ShardRouter — maps tenant_id → shard pool index.
pub const ShardRouter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: ShardConfig,
    pools: []ShardPool,
    /// Tenant-to-pool mapping. If a tenant_id is not found, uses hash-based routing.
    tenant_map: std.AutoHashMap(i64, u16),

    pub fn init(allocator: std.mem.Allocator, config: ShardConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .pools = &.{},
            .tenant_map = std.AutoHashMap(i64, u16).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.pools) |*pool| {
            self.allocator.free(pool.name);
            self.allocator.free(pool.host);
            self.allocator.free(pool.database);
            self.allocator.free(pool.username);
            self.allocator.free(pool.password);
        }
        self.allocator.free(self.pools);
        self.tenant_map.deinit();
        self.* = undefined;
    }

    /// Configure the available shard pools.
    pub fn setPools(self: *Self, pools: []ShardPool) !void {
        self.pools = try self.allocator.dupe(ShardPool, pools);
        for (self.pools) |*pool| {
            pool.name = try self.allocator.dupe(u8, pool.name);
            pool.host = try self.allocator.dupe(u8, pool.host);
            pool.database = try self.allocator.dupe(u8, pool.database);
            pool.username = try self.allocator.dupe(u8, pool.username);
            pool.password = try self.allocator.dupe(u8, pool.password);
        }
    }

    /// Assign a specific tenant to a shard pool by index.
    pub fn assignTenant(self: *Self, tenant_id: i64, pool_index: u16) !void {
        try self.tenant_map.put(tenant_id, pool_index);
    }

    /// Build a SQL query that routes to the correct shard for the current tenant.
    /// Returns the pool index for the tenant, or null if no routing is configured.
    pub fn route(self: *Self, ctx: *const tc.TenantContext) ?u16 {
        if (!ctx.isActive()) return null;
        if (self.pools.len == 0) return null;

        // Check explicit mapping first
        if (self.tenant_map.get(ctx.tenant_id)) |pool_idx| {
            return pool_idx;
        }

        // Fall back to hash-based routing
        const hash: u64 = @intCast(ctx.tenant_id);
        const idx: u16 = @intCast(hash % self.pools.len);
        return idx;
    }

    /// Get the pool configuration for a pool index.
    pub fn getPool(self: *Self, pool_index: u16) ?ShardPool {
        if (pool_index >= self.pools.len) return null;
        return self.pools[pool_index];
    }

    /// Get the pool for the active tenant (from context).
    pub fn getPoolForTenant(self: *Self, ctx: *const tc.TenantContext) ?ShardPool {
        const idx = self.route(ctx) orelse return null;
        return self.getPool(idx);
    }

    /// Build a connection string for a pool index.
    pub fn buildConnectionString(self: *Self, pool_index: u16) ![]const u8 {
        const pool = self.getPool(pool_index) orelse return error.InvalidShardIndex;
        return std.fmt.allocPrint(
            self.allocator,
            "{s}://{s}:{s}@{s}:{d}/{s}",
            .{ "mysql", pool.username, pool.password, pool.host, pool.port, pool.database },
        );
    }

    /// Build a sqlx Config from a pool definition, for use with sqlx.Client.
    pub fn buildSqlxConfig(self: *Self, pool_index: u16) !SqlxConfig {
        const pool = self.getPool(pool_index) orelse return error.InvalidShardIndex;
        return SqlxConfig{
            .host = pool.host,
            .port = pool.port,
            .database = pool.database,
            .username = pool.username,
            .password = pool.password,
            .max_open_conns = pool.max_conns,
            .max_idle_conns = @divFloor(pool.max_conns, 2),
        };
    }

    /// Get the number of configured shard pools.
    pub fn poolCount(self: *Self) usize {
        return self.pools.len;
    }

    /// Get the number of explicitly assigned tenants.
    pub fn assignedCount(self: *Self) usize {
        return self.tenant_map.count();
    }
};

/// Simplified sqlx-compatible config struct.
pub const SqlxConfig = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    username: []const u8,
    password: []const u8,
    max_open_conns: u16,
    max_idle_conns: u16,
};

/// Shard-aware SQL helper — prepends shard prefix to table names.
pub const ShardedQuery = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ShardedQuery {
        return .{ .allocator = allocator };
    }

    /// Build a table name with shard prefix for a tenant.
    /// e.g. tableForTenant(5, "orders") → "tenant_05.orders" or "orders" depending on strategy.
    pub fn tableForTenant(_: *ShardedQuery, tenant_id: i64, table_name: []const u8) ![]const u8 {
        // Logical isolation: use row-level tenant_id column (handled by TenantInterceptor).
        // Physical isolation: would return "tenant_{d}.{s}" for dedicated tables.
        _ = tenant_id;
        _ = table_name;
        return error.NotImplemented; // Physical sharding requires DB-level setup
    }
};

// ==================== Tests ====================

test "ShardRouter basic routing" {
    const allocator = std.testing.allocator;
    var router = ShardRouter.init(allocator, .{ .shard_count = 3 });
    defer router.deinit();

    var pools = [_]ShardPool{
        .{ .name = "shard-0", .host = "db0.host", .port = 3306, .database = "db0", .username = "root", .password = "", .max_conns = 10 },
        .{ .name = "shard-1", .host = "db1.host", .port = 3306, .database = "db1", .username = "root", .password = "", .max_conns = 10 },
        .{ .name = "shard-2", .host = "db2.host", .port = 3306, .database = "db2", .username = "root", .password = "", .max_conns = 10 },
    };
    try router.setPools(&pools);

    try std.testing.expectEqual(@as(usize, 3), router.poolCount());

    // Hash-based routing: same tenant → same pool
    var ctx1 = tc.TenantContext{ .tenant_id = 42 };
    const route1 = router.route(&ctx1);
    const route2 = router.route(&ctx1);
    try std.testing.expect(route1 != null);
    try std.testing.expectEqual(route1.?, route2.?);

    // Different tenant → may route to different pool
    var ctx2 = tc.TenantContext{ .tenant_id = 99 };
    const route3 = router.route(&ctx2);
    try std.testing.expect(route3 != null);
}

test "ShardRouter explicit assignment" {
    const allocator = std.testing.allocator;
    var router = ShardRouter.init(allocator, .{ .shard_count = 3 });
    defer router.deinit();

    var pools = [_]ShardPool{
        .{ .name = "shard-0", .host = "db0.host", .port = 3306, .database = "db0", .username = "root", .password = "", .max_conns = 10 },
        .{ .name = "shard-1", .host = "db1.host", .port = 3306, .database = "db1", .username = "root", .password = "", .max_conns = 10 },
        .{ .name = "shard-2", .host = "db2.host", .port = 3306, .database = "db2", .username = "root", .password = "", .max_conns = 10 },
    };
    try router.setPools(&pools);

    // Explicitly assign tenant 999 to shard 1
    try router.assignTenant(999, 1);
    try std.testing.expectEqual(@as(usize, 1), router.assignedCount());

    var ctx = tc.TenantContext{ .tenant_id = 999 };
    const route = router.route(&ctx);
    try std.testing.expectEqual(@as(u16, 1), route.?);
}

test "ShardRouter inactive tenant returns null" {
    const allocator = std.testing.allocator;
    var router = ShardRouter.init(allocator, .{ .shard_count = 2 });
    defer router.deinit();

    var pools = [_]ShardPool{
        .{ .name = "db0", .host = "localhost", .port = 3306, .database = "db0", .username = "r", .password = "", .max_conns = 5 },
        .{ .name = "db1", .host = "localhost", .port = 3306, .database = "db1", .username = "r", .password = "", .max_conns = 5 },
    };
    try router.setPools(&pools);

    // Inactive tenant → no routing
    var ctx = tc.TenantContext{ .tenant_id = 0 };
    const route = router.route(&ctx);
    try std.testing.expectEqual(@as(?u16, null), route);

    // Ignored tenant → no routing
    var ctx2 = tc.TenantContext{ .tenant_id = 5, .ignore = true };
    const route2 = router.route(&ctx2);
    try std.testing.expectEqual(@as(?u16, null), route2);
}

test "ShardRouter buildSqlxConfig" {
    const allocator = std.testing.allocator;
    var router = ShardRouter.init(allocator, .{});
    defer router.deinit();

    var pools = [_]ShardPool{
        .{ .name = "main", .host = "prod.db", .port = 3307, .database = "app_main", .username = "app", .password = "secret", .max_conns = 20 },
    };
    try router.setPools(&pools);

    const cfg = try router.buildSqlxConfig(0);
    try std.testing.expectEqualStrings("prod.db", cfg.host);
    try std.testing.expectEqual(@as(u16, 3307), cfg.port);
    try std.testing.expectEqualStrings("app_main", cfg.database);
    try std.testing.expectEqual(@as(u16, 20), cfg.max_open_conns);
}
