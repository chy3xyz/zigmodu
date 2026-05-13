const std = @import("std");

// ========================================
// Compilation Gate: Ensure all source files compile
// ========================================
test "compile all source files" {
    // API
    _ = @import("api/Module.zig");
    _ = @import("api/Middleware.zig");
    _ = @import("api/middleware/Tracing.zig");
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

    _ = @import("core/eventbus/WAL.zig");
    _ = @import("core/eventbus/DLQ.zig");
    _ = @import("core/eventbus/Partitioner.zig");

    _ = @import("core/Documentation.zig");
    _ = @import("core/DistributedTransaction.zig");
    _ = @import("core/Error.zig");
    _ = @import("core/Event.zig");
    _ = @import("core/EventBus.zig");
    _ = @import("core/EventLogger.zig");
    _ = @import("core/EventPublisher.zig");
    _ = @import("core/EventStore.zig");
    _ = @import("core/HealthEndpoint.zig");
    _ = @import("extensions/HotReloader.zig");
    _ = @import("core/Lifecycle.zig");
    _ = @import("core/Module.zig");
    _ = @import("core/ModuleBoundary.zig");
    _ = @import("core/ModuleCapabilities.zig");
    _ = @import("core/ModuleContract.zig");
    _ = @import("core/ModuleListener.zig");
    _ = @import("core/ModuleScanner.zig");
    _ = @import("core/ModuleValidator.zig");
    _ = @import("core/Transactional.zig");
    _ = @import("core/TransactionalEvent.zig");
    _ = @import("extensions/WebMonitor.zig");
    _ = @import("extensions/WebSocket.zig");

    // Cluster & Distributed (integration tests - these compile successfully)
    _ = @import("core/ClusterMembership.zig");
    _ = @import("core/cluster/FailureDetector.zig");
    _ = @import("core/cluster/NetworkTransport.zig");
    _ = @import("core/cluster/PeerDiscovery.zig");
    _ = @import("core/cluster/ClusterMessage.zig");
    _ = @import("core/cluster/TlsTransport.zig");
    _ = @import("core/cluster/ClusterMetrics.zig");
    _ = @import("core/cluster/ClusterBootstrap.zig");
    _ = @import("core/cluster/ClusterHealth.zig");
    _ = @import("messaging/OutboxPublisher.zig");
    _ = @import("tenant/ShardRouter.zig");

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
    _ = @import("messaging/Nats.zig");
    _ = @import("messaging/MessageQueue.zig");

    // Metrics
    _ = @import("metrics/AutoInstrumentation.zig");
    _ = @import("metrics/PrometheusMetrics.zig");

    // Persistence
    _ = @import("persistence/Database.zig");
    _ = @import("persistence/Orm.zig");
    _ = @import("persistence/backends/SqlxBackend.zig");

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
    _ = @import("validation/ObjectValidator.zig");

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
    _ = @import("security/Rbac.zig");
    _ = @import("security/PasswordEncoder.zig");
    _ = @import("tenant/TenantContext.zig");
    _ = @import("tenant/TenantInterceptor.zig");
    _ = @import("datapermission/DataPermission.zig");

    // Core extensions
    _ = @import("core/Fx.zig");

    // Migration
    _ = @import("migration/Migration.zig");

    // Secrets
    _ = @import("secrets/SecretsManager.zig");

    // Module Interaction Verifier
    _ = @import("core/ModuleInteractionVerifier.zig");

    // HTTP Idempotency
    _ = @import("http/Idempotency.zig");

    // OpenAPI Generator
    _ = @import("http/OpenApi.zig");

    // gRPC Transport
    _ = @import("extensions/GrpcTransport.zig");

    // Kafka Connector
    _ = @import("core/KafkaConnector.zig");

    // Saga Orchestrator
    _ = @import("core/SagaOrchestrator.zig");

    // Contract Testing
    _ = @import("test/ContractTest.zig");

    // RFC 7807 Problem Details
    _ = @import("http/ProblemDetails.zig");

    // Feature Flags
    _ = @import("core/FeatureFlags.zig");

    // HTTP Metrics
    _ = @import("http/HttpMetrics.zig");

    // API Versioning
    _ = @import("http/ApiVersioning.zig");

    // Cache Aside
    _ = @import("cache/CacheAside.zig");

    // Bulkhead
    _ = @import("resilience/Bulkhead.zig");

    // API Key Auth
    _ = @import("security/ApiKeyAuth.zig");

    // Validation Middleware
    _ = @import("api/middleware/Validation.zig");

    // Access Log
    _ = @import("http/AccessLog.zig");

    // Dashboard
    _ = @import("http/Dashboard.zig");
}

// ========================================
// Domain Import Validation
// ========================================
test "domain imports: http" {
    _ = @import("http.zig");
}

test "domain imports: data" {
    _ = @import("data.zig");
}

test "domain imports: security" {
    _ = @import("security.zig");
}

test "domain imports: observability" {
    _ = @import("observability.zig");
}
