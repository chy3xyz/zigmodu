//! Data domain: SQLx, Redis, ORM, Cache, Pool, Migrations.
//! Import directly: `const data = @import("zigmodu").data;`

/// Driver-agnostic SQL client (sqlite/postgres/mysql): open, tx, rows.
pub const sqlx = @import("sqlx/sqlx.zig");
/// A pooled connection kept for reuse instead of re-dialing on every checkout.
pub const CachedConn = @import("sqlx/sqlx.zig").CachedConn;
/// Redis client: connect, GET/SET, lists/hashes, pub-sub.
pub const redis = @import("redis/redis.zig");
/// Fixed-window rate limiter shared across replicas through Redis counters.
pub const redis_rate_limit = @import("redis/RateLimiter.zig");
/// ORM factory — `Orm(Backend)` builds the repository layer above a backend.
pub const orm = @import("persistence/Orm.zig");
/// Batch insert/update helpers: one round trip instead of N statements.
pub const bulk = @import("sqlx/Bulk.zig");
/// Default ORM backend — runs repository SQL through `sqlx`.
pub const SqlxBackend = @import("persistence/backends/SqlxBackend.zig").SqlxBackend;
/// Typed repository (`Repository(T)`): list/get/create/update/delete per entity.
pub const Repository = orm.Orm(SqlxBackend).Repository;
/// Generic CRUD service — entity persistence without passthrough boilerplate.
pub const CrudService = @import("data/CrudService.zig").CrudService;
/// Event published by `CrudService` writes — feed a bus or the outbox.
pub const CrudEvent = @import("data/CrudService.zig").CrudEvent;
/// Arena-backed read result: string fields borrow one arena (cheap bulk reads).
pub const ResultSet = @import("data/ResultSet.zig").ResultSet;
/// Ordering descriptor (field + direction) for repository reads.
pub const SortSpec = @import("data/ResultSet.zig").SortSpec;
/// The raw sqlx client type — use it when a repository would be overkill.
pub const Client = @import("sqlx/sqlx.zig").Client;
/// Rows that own their buffers; release them with the `deinitRows` helpers.
pub const ManagedRows = @import("sqlx/sqlx.zig").ManagedRows;
/// Generic connection pool: acquire/release for any resource with a factory.
pub const pool = @import("pool/Pool.zig");

/// Cache front door: several eviction policies, TTL, hit/miss stats.
pub const CacheManager = @import("cache/CacheManager.zig").CacheManager;
/// In-process LRU cache (O(1) get/put) — one process only, never shared.
pub const cache = @import("cache/Lru.zig");
/// Cache-aside wrapper: read-through on miss, write-through on updates.
pub const CacheAside = @import("cache/CacheAside.zig").CacheAside;

/// Applies/rolls back migrations; give it a `DistributedLock` for multi-replica.
pub const MigrationRunner = @import("migration/Migration.zig").MigrationRunner;
/// Loads migration files from disk into entries the runner can apply.
pub const MigrationLoader = @import("migration/Migration.zig").MigrationLoader;
/// One migration as loaded: version, description, up/down SQL.
pub const MigrationEntry = @import("migration/Migration.zig").MigrationEntry;
/// Migration state enum: pending / applied / failed / skipped.
pub const MigrationStatus = @import("migration/Migration.zig").MigrationStatus;
/// Per-migration status row returned by the runner's status query.
pub const MigrationStatusEntry = @import("migration/Migration.zig").MigrationStatusEntry;
/// Row of the applied-migrations table (version, checksum, timing, success).
pub const AppliedMigration = @import("migration/Migration.zig").AppliedMigration;
