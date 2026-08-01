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
    _ = @import("api/ComptimeRouter.zig");

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
    _ = @import("core/ModuleRuntime.zig");
    _ = @import("core/ModuleRegistry.zig");
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
    _ = @import("core/cluster/LoadBalancer.zig");
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
    _ = @import("messaging/FluvioConnector.zig");

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
    _ = @import("resilience/RedisRateLimiter.zig");

    // Scheduler
    _ = @import("scheduler/ScheduledTask.zig");
    _ = @import("scheduler/Cron.zig");

    // Security
    _ = @import("security/SecurityModule.zig");
    _ = @import("security/SecurityScanner.zig");
    _ = @import("security/AuthMiddleware.zig");
    _ = @import("security/AppSecurity.zig");
    _ = @import("security/JwksKeyRing.zig");

    // Test
    _ = @import("test/Benchmark.zig");
    _ = @import("test/IntegrationTest.zig");
    _ = @import("test/ModulithTest.zig");
    _ = @import("test/ModuleTest.zig");
    _ = @import("test/NetworkProbe.zig");

    // Tracing
    _ = @import("tracing/DistributedTracer.zig");
    _ = @import("tracing/OtlpExporter.zig");

    // Web4 (DID + x402; payment verify fail-closed)
    _ = @import("web4/web4.zig");
    _ = @import("web4/x402.zig");

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
    _ = @import("security/CatalogPermDb.zig");
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
    _ = @import("http/Http2.zig");
    _ = @import("http/Http2Server.zig");
    _ = @import("http/Http2Tls.zig");
    _ = @import("http/Hpack.zig");
    _ = @import("extensions/GrpcTransport.zig");

    // Kafka Connector
    _ = @import("core/KafkaConnector.zig");

    // Saga Orchestrator
    _ = @import("core/SagaOrchestrator.zig");

    // Contract Testing
    _ = @import("test/ContractTest.zig");

    // RFC 7807 Problem Details + framework HTTP helpers
    _ = @import("http/ProblemDetails.zig");
    _ = @import("api/Extract.zig");
    _ = @import("http/Testkit.zig");
    _ = @import("http/Profiles.zig");
    _ = @import("http/Lifecycle.zig");
    _ = @import("http/Sse.zig");
    _ = @import("ai/ai.zig");
    _ = @import("ai/provider.zig");
    _ = @import("ai/skill.zig");
    _ = @import("ai/agent.zig");
    _ = @import("ai/schedule.zig");
    _ = @import("ai/business.zig");
    _ = @import("ai/budget.zig");
    _ = @import("ai/workflow.zig");
    _ = @import("ai/trigger.zig");
    _ = @import("ai/hierarchy.zig");
    _ = @import("ai/context.zig");
    _ = @import("ai/handle.zig");
    _ = @import("ai/reporter.zig");
    _ = @import("ai/alerts.zig");
    _ = @import("ai/ticket.zig");
    _ = @import("ai/refund.zig");
    _ = @import("ai/risk.zig");
    _ = @import("ai/recon.zig");
    _ = @import("ai/approval.zig");
    _ = @import("ai/memory.zig");
    _ = @import("ai/audit.zig");
    _ = @import("ai/retriever.zig");
    _ = @import("ai/quota.zig");
    _ = @import("ai/tokenizer.zig");
    _ = @import("messaging/outbox.zig");
    _ = @import("messaging/outbox_sample.zig");

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

    // Kit utilities
    _ = @import("kit/array.zig");
    _ = @import("kit/format.zig");
    _ = @import("kit/io_instance.zig");
    _ = @import("kit/json.zig");
    _ = @import("kit/random.zig");
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
