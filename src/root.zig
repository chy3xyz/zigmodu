const std = @import("std");

// ============================================================
// ZigModu — Production-Grade Zig Framework
// ============================================================
//
// Quick start:
//   const zmodu = @import("zigmodu");
//   var app = try zmodu.builder(allocator, io).build(.{MyModule});
//
// For faster compilation, import only the domain you need:
//   const http = zmodu.http;       // Server, middleware, client
//   const data = zmodu.data;       // SQLx, Redis, ORM, Cache
//   const sec  = zmodu.security;   // Auth, RBAC, Secrets

// ============================================================
// 1. PRIMARY — Application, Module, Core
// ============================================================
pub const Application = @import("Application.zig").Application;
pub const ApplicationBuilder = @import("Application.zig").ApplicationBuilder;
pub const builder = @import("Application.zig").builder;
pub const getInFlightCounter = @import("Application.zig").getInFlightCounter;
pub const api = @import("api/Module.zig");

pub const ZigModuError = @import("core/Error.zig").ZigModuError;
pub const ErrorContext = @import("core/Error.zig").ErrorContext;
pub const ErrorHandler = @import("core/Error.zig").ErrorHandler;
pub const Result = @import("core/Error.zig").Result;

pub const ModuleInfo = @import("core/Module.zig").ModuleInfo;
pub const ApplicationModules = @import("core/Module.zig").ApplicationModules;
pub const scanModules = @import("core/ModuleScanner.zig").scanModules;
pub const validateModules = @import("core/ModuleValidator.zig").validateModules;
pub const startAll = @import("core/Lifecycle.zig").startAll;
pub const stopAll = @import("core/Lifecycle.zig").stopAll;
pub const generateDocs = @import("core/Documentation.zig").generateDocs;
pub const Documentation = @import("core/Documentation.zig");
pub const ModuleContract = @import("core/ModuleContract.zig").ModuleContract;
pub const ContractRegistry = @import("core/ModuleContract.zig").ContractRegistry;
pub const ModuleInteractionVerifier = @import("core/ModuleInteractionVerifier.zig").ModuleInteractionVerifier;
pub const InteractionType = @import("core/ModuleInteractionVerifier.zig").ModuleInteractionVerifier.InteractionType;

pub const Event = @import("core/Event.zig").Event;
pub const EventBus = @import("core/EventBus.zig").EventBus;
pub const TypedEventBus = @import("core/EventBus.zig").TypedEventBus;
pub const ThreadSafeEventBus = @import("core/EventBus.zig").ThreadSafeEventBus;
pub const Container = @import("di/Container.zig").Container;

// ============================================================
// 2. DOMAIN RE-EXPORTS (import individually for fast compilation)
// ============================================================
pub const http = @import("http.zig");
pub const data = @import("data.zig");
pub const security = @import("security.zig");
pub const observability = @import("observability.zig");

// ============================================================
// 3. RESILIENCE
// ============================================================
pub const CircuitBreaker = @import("resilience/CircuitBreaker.zig").CircuitBreaker;
pub const RateLimiter = @import("resilience/RateLimiter.zig").RateLimiter;
pub const Bulkhead = @import("resilience/Bulkhead.zig").Bulkhead;
pub const BulkheadRegistry = @import("resilience/Bulkhead.zig").BulkheadRegistry;
pub const retry = @import("resilience/Retry.zig");
pub const load_shedder = @import("resilience/LoadShedder.zig");

// ============================================================
// 4. MESSAGING
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
// 5. DISTRIBUTED
// ============================================================
pub const ClusterBootstrap = @import("core/cluster/ClusterBootstrap.zig").ClusterBootstrap;
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
// 6. EXTENSIONS
// ============================================================
pub const PluginManager = @import("extensions/PluginManager.zig").PluginManager;
pub const PluginManifest = @import("extensions/PluginManager.zig").PluginManifest;
pub const HotReloader = @import("extensions/HotReloader.zig").HotReloader;
pub const ReloadStrategy = @import("extensions/HotReloader.zig").ReloadStrategy;
pub const ModuleSnapshot = @import("extensions/HotReloader.zig").ModuleSnapshot;
pub const WebMonitor = @import("extensions/WebMonitor.zig").WebMonitor;
pub const WebSocketServer = @import("extensions/WebSocket.zig").WebSocketServer;
pub const WebSocketClient = @import("extensions/WebSocket.zig").WebSocketClient;
pub const WebSocketMonitor = @import("extensions/WebSocket.zig").WebSocketMonitor;
pub const GrpcServiceRegistry = @import("extensions/GrpcTransport.zig").GrpcServiceRegistry;
pub const GrpcClient = @import("extensions/GrpcTransport.zig").GrpcClient;
pub const GrpcStatusCode = @import("extensions/GrpcTransport.zig").GrpcStatusCode;
pub const ProtoParser = @import("extensions/GrpcTransport.zig").ProtoParser;

// ============================================================
// 7. SCHEDULER
// ============================================================
pub const cron = @import("scheduler/Cron.zig");
pub const ScheduledTask = @import("scheduler/ScheduledTask.zig").ScheduledTask;

// ============================================================
// 8. UTILITIES
// ============================================================
pub const time = @import("core/Time.zig");
pub const fx = @import("core/Fx.zig");
pub const util = @import("util.zig");
pub const Validator = @import("validation/ObjectValidator.zig").Validator;
/// DEPRECATED: use `zigmodu.Validator` instead (ObjectValidator, not GoZero-style)
pub const gozero_validator = @import("validation/Validator.zig");

// ============================================================
// 9. CONFIG
// ============================================================
pub const ExternalizedConfig = @import("config/ExternalizedConfig.zig").ExternalizedConfig;
pub const FeatureFlagManager = @import("core/FeatureFlags.zig").FeatureFlagManager;
pub const FeatureFlag = @import("core/FeatureFlags.zig").FeatureFlag;
pub const YamlParser = @import("config/YamlToml.zig").YamlParser;
pub const TomlParser = @import("config/YamlToml.zig").TomlParser;

// ============================================================
// 10. TESTING
// ============================================================
pub const IntegrationTest = @import("test/IntegrationTest.zig").IntegrationTest;
pub const TestDataGenerator = @import("test/IntegrationTest.zig").TestDataGenerator;
pub const Benchmark = @import("test/Benchmark.zig").Benchmark;
pub const BenchmarkSuite = @import("test/Benchmark.zig").BenchmarkSuite;
pub const ContractTestRunner = @import("test/ContractTest.zig").ContractTestRunner;
pub const Contract = @import("test/ContractTest.zig").Contract;
pub const ContractVerificationResult = @import("test/ContractTest.zig").ContractVerificationResult;

// ============================================================
// 11. DEPRECATED — Legacy APIs (will be removed)
// ============================================================
pub const App = @import("api/Simplified.zig").App;
pub const Module = @import("api/Simplified.zig").Module;
pub const ModuleImpl = @import("api/Simplified.zig").ModuleImpl;
pub const extensions = @import("extensions.zig");

// ============================================================
// TESTS
// ============================================================
test {
    _ = @import("tests.zig");
}
