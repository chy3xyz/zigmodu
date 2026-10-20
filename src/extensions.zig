//! DEPRECATED — use domain files instead:
//!   zmodu.http.http_server       (was extensions.HttpServer)
//!   zmodu.data.sqlx              (was extensions.SqlxClient)
//!   zmodu.data.orm               (was extensions.Orm)
//!   zmodu.data.redis             (was extensions.RedisClient)
//!   zmodu.security.auth           (was extensions.JwtAuthMiddleware)
//!
//! This file will be removed in v1.0.

// Re-export only the most-used types for transitional compatibility:
pub const HttpServer = @import("api/Server.zig").Server;
pub const HttpContext = @import("api/Server.zig").Context;
pub const SqlxClient = @import("sqlx/sqlx.zig").Client;
pub const Orm = @import("persistence/Orm.zig").Orm;
pub const RedisClient = @import("redis/redis.zig").Redis;
pub const RetryPolicy = @import("resilience/Retry.zig").Policy;
pub const ConnectionPool = @import("pool/Pool.zig").Pool;
pub const CronScheduler = @import("scheduler/Cron.zig").Scheduler;
