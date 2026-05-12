//! Data domain: SQLx, Redis, ORM, Cache, Pool, Migrations.
//! Import directly: `const data = @import("zigmodu").data;`

pub const sqlx = @import("sqlx/sqlx.zig");
pub const CachedConn = @import("sqlx/sqlx.zig").CachedConn;
pub const redis = @import("redis/redis.zig");
pub const orm = @import("persistence/Orm.zig");
pub const SqlxBackend = @import("persistence/backends/SqlxBackend.zig").SqlxBackend;
pub const pool = @import("pool/Pool.zig");
pub const CacheManager = @import("cache/CacheManager.zig").CacheManager;
pub const cache = @import("cache/Lru.zig");
pub const CacheAside = @import("cache/CacheAside.zig").CacheAside;

pub const MigrationRunner = @import("migration/Migration.zig").MigrationRunner;
pub const MigrationLoader = @import("migration/Migration.zig").MigrationLoader;
pub const MigrationEntry = @import("migration/Migration.zig").MigrationEntry;
pub const MigrationStatus = @import("migration/Migration.zig").MigrationStatus;
pub const MigrationStatusEntry = @import("migration/Migration.zig").MigrationStatusEntry;
pub const AppliedMigration = @import("migration/Migration.zig").AppliedMigration;
