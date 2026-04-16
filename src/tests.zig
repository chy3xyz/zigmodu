const std = @import("std");
const zigmodu = @import("zigmodu");

// ========================================
// Compilation Gate: Ensure all source files compile
// ========================================
test "compile all source files" {
    // API
    _ = @import("api/Module.zig");
    _ = @import("api/Middleware.zig");
    _ = @import("api/Simplified.zig");
    _ = @import("api/Server.zig");

    // Application
    _ = @import("Application.zig");

    // Config
    _ = @import("config/ConfigManager.zig");
    _ = @import("config/ExternalizedConfig.zig");
    _ = @import("config/Loader.zig");
    _ = @import("config/TomlLoader.zig");
    _ = @import("config/YamlToml.zig");

    // Core
    _ = @import("core/ApplicationObserver.zig");
    _ = @import("core/ApplicationView.zig");
    _ = @import("core/ArchitectureTester.zig");
    _ = @import("core/AutoEventListener.zig");
    _ = @import("core/C4ModelGenerator.zig");
    _ = @import("core/ClusterMembership.zig");
    _ = @import("core/Documentation.zig");
    _ = @import("core/DistributedEventBus.zig");
    _ = @import("core/DistributedTransaction.zig");
    _ = @import("core/Error.zig");
    _ = @import("core/Event.zig");
    _ = @import("core/EventBus.zig");
    _ = @import("core/EventLogger.zig");
    _ = @import("core/EventPublisher.zig");
    _ = @import("core/EventStore.zig");
    _ = @import("core/HealthEndpoint.zig");
    _ = @import("core/HotReloader.zig");
    _ = @import("core/Lifecycle.zig");
    _ = @import("core/Module.zig");
    _ = @import("core/ModuleBoundary.zig");
    _ = @import("core/ModuleCanvas.zig");
    _ = @import("core/ModuleCapabilities.zig");
    _ = @import("core/ModuleContract.zig");
    _ = @import("core/ModuleListener.zig");
    _ = @import("core/ModuleScanner.zig");
    _ = @import("core/ModuleValidator.zig");
    _ = @import("core/Transactional.zig");
    _ = @import("core/TransactionalEvent.zig");
    _ = @import("core/WebMonitor.zig");
    _ = @import("core/WebSocket.zig");

    // DI
    _ = @import("di/Container.zig");

    // Extensions
    _ = @import("extensions.zig");

    // HTTP
    _ = @import("http/HttpClient.zig");

    // Log
    _ = @import("log/ModuleLogger.zig");
    _ = @import("log/StructuredLogger.zig");

    // Messaging
    _ = @import("messaging/MessageQueue.zig");

    // Metrics
    _ = @import("metrics/AutoInstrumentation.zig");
    _ = @import("metrics/PrometheusMetrics.zig");

    // Persistence
    _ = @import("persistence/Database.zig");
    _ = @import("persistence/Orm.zig");
    _ = @import("persistence/backends/SqlxBackend.zig");
    _ = @import("persistence/Database.zig");

    // Resilience
    _ = @import("resilience/CircuitBreaker.zig");
    _ = @import("resilience/RateLimiter.zig");
    _ = @import("resilience/Retry.zig");
    _ = @import("resilience/LoadShedder.zig");

    // Scheduler
    _ = @import("scheduler/ScheduledTask.zig");
    _ = @import("scheduler/Cron.zig");

    // Security
    _ = @import("security/SecurityModule.zig");
    _ = @import("security/SecurityScanner.zig");

    // Test
    _ = @import("test/Benchmark.zig");
    _ = @import("test/IntegrationTest.zig");
    _ = @import("test/ModulithTest.zig");
    _ = @import("test/ModuleTest.zig");

    // Tracing
    _ = @import("tracing/DistributedTracer.zig");

    // Validation
    _ = @import("validation/Validator.zig");
    _ = @import("experimental/GoZeroValidator.zig");

    // Cache
    _ = @import("cache/CacheManager.zig");
    _ = @import("cache/Lru.zig");

    // SQLx
    _ = @import("sqlx/sqlx.zig");
    _ = @import("sqlx/errors.zig");
    _ = @import("sqlx/breaker.zig");
    _ = @import("sqlx/sqlite3_c.zig");
    _ = @import("sqlx/libpq_c.zig");
    _ = @import("sqlx/libmysql_c.zig");

    // Redis
    _ = @import("redis/redis.zig");

    // Pool
    _ = @import("pool/Pool.zig");

    // Core extensions
    _ = @import("experimental/Fx.zig");
}
