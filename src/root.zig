const std = @import("std");

// ============================================================
// ZigModu — Production-Grade Zig Framework
// ============================================================
//
// Usage:
//   const zmodu = @import("zigmodu");
//   var app = try zmodu.builder("my-app").build(allocator);
//
// Sections:
//   1. PRIMARY     — Entry points every user needs
//   2. HTTP        — Server, middleware, client, OpenAPI
//   3. DATA        — SQLx, Redis, ORM, Cache, Migrations
//   4. RESILIENCE  — Circuit breaker, rate limit, retry, bulkhead
//   5. SECURITY    — Auth, RBAC, API keys, secrets, password
//   6. MESSAGING   — Outbox, Kafka, distributed event bus
//   7. DISTRIBUTED — Cluster, saga, transactions, sharding
//   8. OBSERVABILITY — Metrics, tracing, logging
//   9. TESTING     — Integration, benchmark, contract
//  10. CONFIG      — Externalized config, feature flags, parsers
//  11. EXTENSIONS  — Plugins, hot reload, WebSocket, gRPC
//  12. SCHEDULER   — Cron, scheduled tasks
//  13. UTILITIES   — Time, Fx, validation, ID generation
//  14. DEPRECATED  — Legacy APIs (will be removed)

// ============================================================
// 1. PRIMARY — Application & Module
// ============================================================
pub const Application = @import("Application.zig").Application;
pub const ApplicationBuilder = @import("Application.zig").ApplicationBuilder;
pub const builder = @import("Application.zig").builder;
pub const getInFlightCounter = @import("Application.zig").getInFlightCounter;
pub const api = @import("api/Module.zig");

// Error handling
pub const ZigModuError = @import("core/Error.zig").ZigModuError;
pub const ErrorContext = @import("core/Error.zig").ErrorContext;
pub const ErrorHandler = @import("core/Error.zig").ErrorHandler;
pub const Result = @import("core/Error.zig").Result;

// Core module infrastructure
pub const ModuleInfo = @import("core/Module.zig").ModuleInfo;
pub const ApplicationModules = @import("core/Module.zig").ApplicationModules;
pub const scanModules = @import("core/ModuleScanner.zig").scanModules;
pub const validateModules = @import("core/ModuleValidator.zig").validateModules;
pub const startAll = @import("core/Lifecycle.zig").startAll;
pub const stopAll = @import("core/Lifecycle.zig").stopAll;
pub const generateDocs = @import("core/Documentation.zig").generateDocs;
pub const Documentation = @import("core/Documentation.zig");

// Module contracts
pub const ModuleContract = @import("core/ModuleContract.zig").ModuleContract;
pub const ContractRegistry = @import("core/ModuleContract.zig").ContractRegistry;
pub const ModuleInteractionVerifier = @import("core/ModuleInteractionVerifier.zig").ModuleInteractionVerifier;
pub const InteractionType = @import("core/ModuleInteractionVerifier.zig").ModuleInteractionVerifier.InteractionType;

// Event system
pub const Event = @import("core/Event.zig").Event;
pub const EventBus = @import("core/EventBus.zig").EventBus;
pub const TypedEventBus = @import("core/EventBus.zig").TypedEventBus;
pub const ThreadSafeEventBus = @import("core/EventBus.zig").ThreadSafeEventBus;

// Dependency injection
pub const Container = @import("di/Container.zig").Container;

// ============================================================
// 2. HTTP — Server, Middleware, Client, OpenAPI
// ============================================================
pub const http_server = @import("api/Server.zig");
pub const RouteInfo = @import("api/Server.zig").RouteInfo;
pub const http_middleware = @import("api/Middleware.zig");
pub const tracing_middleware = @import("api/middleware/Tracing.zig");
pub const validateRequest = @import("api/middleware/Validation.zig").validateRequest;
pub const validationMiddleware = @import("api/middleware/Validation.zig").validationMiddleware;

pub const HttpClient = @import("http/HttpClient.zig").HttpClient;
pub const OpenApiGenerator = @import("http/OpenApi.zig").OpenApiGenerator;
pub const ApiEndpoint = @import("http/OpenApi.zig").ApiEndpoint;
pub const ApiSchema = @import("http/OpenApi.zig").ApiSchema;
pub const HttpMethod = @import("http/OpenApi.zig").HttpMethod;
pub const ProblemDetails = @import("http/ProblemDetails.zig").ProblemDetails;
pub const ValidationProblem = @import("http/ProblemDetails.zig").ValidationProblem;
pub const IdempotencyStore = @import("http/Idempotency.zig").IdempotencyStore;
pub const idempotencyMiddleware = @import("http/Idempotency.zig").idempotencyMiddleware;
pub const ApiVersion = @import("http/ApiVersioning.zig").ApiVersion;
pub const ApiVersionExtractor = @import("http/ApiVersioning.zig").ApiVersionExtractor;
pub const ApiVersionRouter = @import("http/ApiVersioning.zig").ApiVersionRouter;
pub const apiVersionMiddleware = @import("http/ApiVersioning.zig").apiVersionMiddleware;
pub const Dashboard = @import("http/Dashboard.zig");
pub const AccessLogger = @import("http/AccessLog.zig").AccessLogger;
pub const accessLogMiddleware = @import("http/AccessLog.zig").accessLogMiddleware;
pub const HttpMetricsCollector = @import("http/HttpMetrics.zig").HttpMetricsCollector;
pub const httpMetricsMiddleware = @import("http/HttpMetrics.zig").httpMetricsMiddleware;

// ============================================================
// 3. DATA — SQLx, Redis, ORM, Cache, Migrations, Pool
// ============================================================
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
pub const AppliedMigration = @import("migration/Migration.zig").AppliedMigration;

// ============================================================
// 4. RESILIENCE — Circuit Breaker, Rate Limit, Retry, Bulkhead
// ============================================================
pub const CircuitBreaker = @import("resilience/CircuitBreaker.zig").CircuitBreaker;
pub const RateLimiter = @import("resilience/RateLimiter.zig").RateLimiter;
pub const Bulkhead = @import("resilience/Bulkhead.zig").Bulkhead;
pub const BulkheadRegistry = @import("resilience/Bulkhead.zig").BulkheadRegistry;
pub const retry = @import("resilience/Retry.zig");
pub const load_shedder = @import("resilience/LoadShedder.zig");

// ============================================================
// 5. SECURITY — Auth, RBAC, API Keys, Secrets, Password
// ============================================================
pub const auth = @import("security/AuthMiddleware.zig");
pub const Rbac = @import("security/Rbac.zig");
pub const PasswordEncoder = @import("security/PasswordEncoder.zig").PasswordEncoder;
pub const ApiKeyAuth = @import("security/ApiKeyAuth.zig").apiKeyAuth;
pub const ApiKeyAuthWithLoader = @import("security/ApiKeyAuth.zig").apiKeyAuthWithLoader;
pub const ApiKeyGenerator = @import("security/ApiKeyAuth.zig").ApiKeyGenerator;
pub const ApiKeyConfig = @import("security/ApiKeyAuth.zig").ApiKeyConfig;
pub const SecurityScanner = @import("security/SecurityScanner.zig").SecurityScanner;
pub const DependencyScanner = @import("security/SecurityScanner.zig").DependencyScanner;
pub const SecurityConfigValidator = @import("security/SecurityScanner.zig").SecurityConfigValidator;
pub const SecretsManager = @import("secrets/SecretsManager.zig").SecretsManager;
pub const SecretEntry = @import("secrets/SecretsManager.zig").SecretsManager.SecretEntry;
pub const SecretsSourcePriority = @import("secrets/SecretsManager.zig").SecretsSourcePriority;

// ============================================================
// 6. MESSAGING — Outbox, Kafka, Distributed Event Bus
// ============================================================
pub const OutboxPublisher = @import("messaging/OutboxPublisher.zig").OutboxPublisher;
pub const OutboxPoller = @import("messaging/OutboxPublisher.zig").OutboxPoller;
pub const OutboxEntry = @import("messaging/OutboxPublisher.zig").OutboxEntry;
pub const OutboxConfig = @import("messaging/OutboxPublisher.zig").OutboxConfig;
pub const KafkaProducer = @import("core/KafkaConnector.zig").KafkaProducer;
pub const KafkaConsumer = @import("core/KafkaConnector.zig").KafkaConsumer;
pub const KafkaEventBridge = @import("core/KafkaConnector.zig").KafkaEventBridge;
pub const KafkaMessage = @import("core/KafkaConnector.zig").KafkaMessage;
pub const DistributedEventBus = @import("core/DistributedEventBus.zig").DistributedEventBus;
pub const ClusterConfig = @import("core/DistributedEventBus.zig").ClusterConfig;

// ============================================================
// 7. DISTRIBUTED — Cluster, Saga, Transactions, Sharding
// ============================================================
pub const ClusterMembership = @import("core/ClusterMembership.zig").ClusterMembership;
pub const SagaOrchestrator = @import("core/SagaOrchestrator.zig").SagaOrchestrator;
pub const SagaLog = @import("core/SagaOrchestrator.zig").SagaLog;
pub const SagaStatus = @import("core/SagaOrchestrator.zig").SagaStatus;
pub const DistributedTransactionManager = @import("core/DistributedTransaction.zig").DistributedTransactionManager;
pub const TwoPhaseCommit = @import("core/DistributedTransaction.zig").TwoPhaseCommit;
pub const Transactional = @import("core/Transactional.zig").Transactional;
pub const ShardRouter = @import("tenant/ShardRouter.zig").ShardRouter;
pub const ShardPool = @import("tenant/ShardRouter.zig").ShardPool;
pub const ShardConfig = @import("tenant/ShardRouter.zig").ShardConfig;
pub const TenantContext = @import("tenant/TenantContext.zig").TenantContext;
pub const TenantInterceptor = @import("tenant/TenantInterceptor.zig").TenantInterceptor;
pub const DataPermissionContext = @import("datapermission/DataPermission.zig").DataPermissionContext;
pub const DataPermissionFilter = @import("datapermission/DataPermission.zig").DataPermissionFilter;
pub const datapermission = @import("datapermission/DataPermission.zig");

// ============================================================
// 8. OBSERVABILITY — Metrics, Tracing, Logging
// ============================================================
pub const PrometheusMetrics = @import("metrics/PrometheusMetrics.zig").PrometheusMetrics;
pub const AutoInstrumentation = @import("metrics/AutoInstrumentation.zig").AutoInstrumentation;
pub const InstrumentedLifecycleListener = @import("metrics/AutoInstrumentation.zig").InstrumentedLifecycleListener;
pub const InstrumentedEventListener = @import("metrics/AutoInstrumentation.zig").InstrumentedEventListener;
pub const DistributedTracer = @import("tracing/DistributedTracer.zig").DistributedTracer;
pub const StructuredLogger = @import("log/StructuredLogger.zig").StructuredLogger;
pub const LogLevel = @import("log/StructuredLogger.zig").LogLevel;
pub const LogRotator = @import("log/StructuredLogger.zig").LogRotator;

// ============================================================
// 9. TESTING — Integration, Benchmark, Contract
// ============================================================
pub const IntegrationTest = @import("test/IntegrationTest.zig").IntegrationTest;
pub const TestDataGenerator = @import("test/IntegrationTest.zig").TestDataGenerator;
pub const Benchmark = @import("test/Benchmark.zig").Benchmark;
pub const BenchmarkSuite = @import("test/Benchmark.zig").BenchmarkSuite;
pub const ContractTestRunner = @import("test/ContractTest.zig").ContractTestRunner;
pub const Contract = @import("test/ContractTest.zig").Contract;
pub const ContractVerificationResult = @import("test/ContractTest.zig").ContractVerificationResult;

// ============================================================
// 10. CONFIG — Externalized Config, Feature Flags, Parsers
// ============================================================
pub const ExternalizedConfig = @import("config/ExternalizedConfig.zig").ExternalizedConfig;
pub const FeatureFlagManager = @import("core/FeatureFlags.zig").FeatureFlagManager;
pub const FeatureFlag = @import("core/FeatureFlags.zig").FeatureFlag;
pub const YamlParser = @import("config/YamlToml.zig").YamlParser;
pub const TomlParser = @import("config/YamlToml.zig").TomlParser;

// ============================================================
// 11. EXTENSIONS — Plugins, Hot Reload, Web, WebSocket, gRPC
// ============================================================
pub const PluginManager = @import("core/PluginManager.zig").PluginManager;
pub const PluginManifest = @import("core/PluginManager.zig").PluginManifest;
pub const HotReloader = @import("core/HotReloader.zig").HotReloader;
pub const ReloadStrategy = @import("core/HotReloader.zig").ReloadStrategy;
pub const ModuleSnapshot = @import("core/HotReloader.zig").ModuleSnapshot;
pub const WebMonitor = @import("core/WebMonitor.zig").WebMonitor;
pub const WebSocketServer = @import("core/WebSocket.zig").WebSocketServer;
pub const WebSocketClient = @import("core/WebSocket.zig").WebSocketClient;
pub const WebSocketMonitor = @import("core/WebSocket.zig").WebSocketMonitor;
pub const GrpcServiceRegistry = @import("core/GrpcTransport.zig").GrpcServiceRegistry;
pub const GrpcClient = @import("core/GrpcTransport.zig").GrpcClient;
pub const GrpcStatusCode = @import("core/GrpcTransport.zig").GrpcStatusCode;
pub const ProtoParser = @import("core/GrpcTransport.zig").ProtoParser;

// ============================================================
// 12. SCHEDULER — Cron, Scheduled Tasks
// ============================================================
pub const cron = @import("scheduler/Cron.zig");
pub const ScheduledTask = @import("scheduler/ScheduledTask.zig").ScheduledTask;

// ============================================================
// 13. UTILITIES — Time, Validation, Fx, ID
// ============================================================
pub const time = @import("core/Time.zig");
pub const fx = @import("core/Fx.zig");
pub const util = @import("util.zig");
pub const Validator = @import("validation/ObjectValidator.zig").Validator;
pub const gozero_validator = @import("validation/Validator.zig");

// ============================================================
// 14. DEPRECATED — Legacy APIs (will be removed)
// ============================================================

/// DEPRECATED: Use zigmodu.Application instead.
pub const App = @import("api/Simplified.zig").App;

/// DEPRECATED: Use zigmodu.Application instead.
pub const Module = @import("api/Simplified.zig").Module;

/// DEPRECATED: Use zigmodu.Application instead.
pub const ModuleImpl = @import("api/Simplified.zig").ModuleImpl;

/// DEPRECATED: Backward-compatibility namespace.
pub const extensions = @import("extensions.zig");

// ============================================================
// TESTS
// ============================================================
test {
    _ = @import("tests.zig");
}
