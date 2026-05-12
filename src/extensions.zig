//! DEPRECATED — use domain files instead:
//!   zigmodu.http.http_server       (was extensions.HttpServer)
//!   zigmodu.data.sqlx              (was extensions.SqlxClient)
//!   zigmodu.data.orm               (was extensions.Orm)
//!   zigmodu.data.redis             (was extensions.RedisClient)
//!   zigmodu.security.auth           (was extensions.JwtAuthMiddleware)
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
