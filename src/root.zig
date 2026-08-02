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
pub const Time = @import("core/Time.zig");
pub const ErrorContext = @import("core/Error.zig").ErrorContext;
pub const ErrorHandler = @import("core/Error.zig").ErrorHandler;
pub const Result = @import("core/Error.zig").Result;
pub const HttpCode = @import("core/Error.zig").HttpCode;
pub const HealthEndpoint = @import("core/HealthEndpoint.zig").HealthEndpoint;

pub const ModuleInfo = @import("core/Module.zig").ModuleInfo;
pub const ApplicationModules = @import("core/Module.zig").ApplicationModules;
pub const scanModules = @import("core/ModuleScanner.zig").scanModules;
pub const validateModules = @import("core/ModuleValidator.zig").validateModules;
pub const ModuleRuntime = @import("core/ModuleRuntime.zig").ModuleRuntime;
pub const ModuleRegistry = @import("core/ModuleRegistry.zig").ModuleRegistry;
pub const WorkerPool = @import("core/WorkerPool.zig").WorkerPool;
pub const RuntimeOptions = @import("api/Module.zig").RuntimeOptions;
/// DEPRECATED: use Application.start() / Application.stop() instead.
pub const startAll = @import("core/Lifecycle.zig").startAll;
/// DEPRECATED: use Application.start() / Application.stop() instead.
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
// 2. DOMAIN RE-EXPORTS (canonical — prefer these)
// ============================================================
pub const http = @import("http.zig");
pub const data = @import("data.zig");
pub const security = @import("security.zig");
pub const observability = @import("observability.zig");

/// Deprecated flat aliases — remove in v0.14.0. Prefer domain imports above.

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
/// Thin barrel — `zigmodu.outbox.*` or direct root aliases below.
pub const outbox = @import("messaging/outbox.zig");
pub const OutboxPublisher = outbox.OutboxPublisher;
pub const OutboxPoller = outbox.OutboxPoller;
pub const OutboxEntry = outbox.OutboxEntry;
pub const OutboxConfig = outbox.OutboxConfig;
pub const OutboxStatus = outbox.OutboxStatus;
pub const KafkaProducer = @import("core/KafkaConnector.zig").KafkaProducer;
pub const KafkaConsumer = @import("core/KafkaConnector.zig").KafkaConsumer;
pub const KafkaEventBridge = @import("core/KafkaConnector.zig").KafkaEventBridge;
pub const KafkaMessage = @import("core/KafkaConnector.zig").KafkaMessage;
pub const RobustMQTransport = @import("core/KafkaConnector.zig").RobustMQTransport;
pub const ConsumerGroupSession = @import("core/KafkaConnector.zig").ConsumerGroupSession;
pub const KafkaWireFormat = @import("core/KafkaConnector.zig").KafkaWireFormat;
pub const NatsClient = @import("messaging/Nats.zig").NatsClient;
pub const NatsConfig = @import("messaging/Nats.zig").NatsConfig;
pub const MessageQueue = @import("messaging/MessageQueue.zig").MessageQueue;
pub const DistributedEventBus = @import("core/DistributedEventBus.zig").DistributedEventBus;
pub const ClusterConfig = @import("core/DistributedEventBus.zig").ClusterConfig;
pub const DLQ = @import("core/eventbus/DLQ.zig").DLQ;
pub const DLQConfig = @import("core/eventbus/DLQ.zig").DLQConfig;
pub const Partitioner = @import("core/eventbus/Partitioner.zig").ConsistentHashPartitioner;
pub const PartitionerConfig = @import("core/eventbus/Partitioner.zig").PartitionerConfig;
pub const WAL = @import("core/eventbus/WAL.zig").WAL;
pub const WALConfig = @import("core/eventbus/WAL.zig").WALConfig;

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
pub const setTenantColumn = @import("tenant/TenantContext.zig").setTenantColumn;
pub const tenantColumn = @import("tenant/TenantContext.zig").tenantColumn;
pub const TENANT_COLUMN = @import("tenant/TenantContext.zig").TENANT_COLUMN;
pub const TenantInterceptor = @import("tenant/TenantInterceptor.zig").TenantInterceptor;
pub const TenantRepository = @import("tenant/TenantInterceptor.zig").TenantRepository;
pub const TenantRepositoryCol = @import("tenant/TenantInterceptor.zig").TenantRepositoryCol;
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
pub const im = @import("im/im.zig");
pub const ai = @import("ai/ai.zig");
pub const web4 = @import("web4/web4.zig");
pub const GrpcServiceRegistry = @import("extensions/GrpcTransport.zig").GrpcServiceRegistry;
pub const GrpcClient = @import("extensions/GrpcTransport.zig").GrpcClient;
pub const GrpcStatusCode = @import("extensions/GrpcTransport.zig").GrpcStatusCode;
pub const GrpcFrame = @import("extensions/GrpcTransport.zig").GrpcFrame;
pub const GrpcStreamWriter = @import("extensions/GrpcTransport.zig").GrpcStreamWriter;
pub const OwnedGrpcResponse = @import("extensions/GrpcTransport.zig").OwnedGrpcResponse;
pub const ProtoParser = @import("extensions/GrpcTransport.zig").ProtoParser;
pub const Http2 = @import("http/Http2.zig");

// ============================================================
// 7. SCHEDULER
// ============================================================
pub const cron = @import("scheduler/Cron.zig");

// ============================================================
// 8. UTILITIES
// ============================================================
pub const time = @import("core/Time.zig");
pub const fx = @import("core/Fx.zig");
pub const util = @import("util.zig");
pub const csv = @import("util/csv.zig");
pub const pluralize = util.pluralize;
pub const HashKit = util.HashKit;
pub const hexEncode = util.hexEncode;
pub const Validator = @import("validation/ObjectValidator.zig").Validator;

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
pub const ModuleTestContext = @import("test/ModuleTest.zig").ModuleTestContext;
pub const createMockModule = @import("test/ModuleTest.zig").createMockModule;

// ============================================================
// ============================================================
// TESTS
// ============================================================
test {
    _ = @import("tests.zig");
    _ = @import("core/WorkerPool.zig");
}
