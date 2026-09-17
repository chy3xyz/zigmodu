const std = @import("std");

// ============================================================
// ZigModu — Production-Grade Zig Framework
// ============================================================
//
// Quick start:
//   const zmodu = @import("zigmodu");
//   var b = zmodu.builder(allocator, io);          // bind first: a temporary is `*const`
//   defer b.deinit();
//   var app = try b.build(.{MyModule});
//
// For faster compilation, import only the domain you need:
//   const http = zmodu.http;       // Server, middleware, client
//   const data = zmodu.data;       // SQLx, Redis, ORM, Cache
//   const sec  = zmodu.security;   // Auth, RBAC, Secrets

// ============================================================
// 1. PRIMARY — Application, Module, Core
// ============================================================
/// The application: owns modules, the DI container, event bus and lifecycle.
pub const Application = @import("Application.zig").Application;
/// Builder handed out by `builder()`: register services, then `build(.{...})`.
pub const ApplicationBuilder = @import("Application.zig").ApplicationBuilder;
/// Entry point: `var b = zmodu.builder(alloc, io); defer b.deinit();`
pub const builder = @import("Application.zig").builder;
/// Live (in-flight) request counter, for backpressure probes and drain checks.
pub const getInFlightCounter = @import("Application.zig").getInFlightCounter;
/// Module contract types: `Module`, `RuntimeOptions`, `Modulith`.
pub const api = @import("api/Module.zig");

/// The framework error set — return these instead of ad-hoc error sets.
pub const ZigModuError = @import("core/Error.zig").ZigModuError;
/// Time helpers (`std.time.*` moved in Zig 0.17; use these instead).
pub const Time = @import("core/Time.zig");
/// An error plus context (code, message, source, timestamp).
pub const ErrorContext = @import("core/Error.zig").ErrorContext;
/// Callback invoked with an `ErrorContext` to log or report a failure.
pub const ErrorHandler = @import("core/Error.zig").ErrorHandler;
/// `Result(T)`: a success value or a `ZigModuError`, for fallible APIs.
pub const Result = @import("core/Error.zig").Result;
/// Maps `ZigModuError` values onto HTTP status codes.
pub const HttpCode = @import("core/Error.zig").HttpCode;
/// Health check surface: register checks, render app and module health.
pub const HealthEndpoint = @import("core/HealthEndpoint.zig").HealthEndpoint;

/// Module descriptor: name, description, dependencies.
pub const ModuleInfo = @import("core/Module.zig").ModuleInfo;
/// The resolved module set (topological order, contexts) after scanning.
pub const ApplicationModules = @import("core/Module.zig").ApplicationModules;
/// Comptime scan: extract module metadata and topologically sort modules.
pub const scanModules = @import("core/ModuleScanner.zig").scanModules;
/// Fails with a dependency error: missing dep, self-dependency, or a cycle.
pub const validateModules = @import("core/ModuleValidator.zig").validateModules;
/// Per-module resources: bulkhead, rate limiter, circuit breaker, worker pool.
pub const ModuleRuntime = @import("core/ModuleRuntime.zig").ModuleRuntime;
/// Runtimes by module name; checks per-module quotas against system capacity.
pub const ModuleRegistry = @import("core/ModuleRegistry.zig").ModuleRegistry;
/// Bounded worker pool: tasks queue up, a fixed set of workers drains it.
pub const WorkerPool = @import("core/WorkerPool.zig").WorkerPool;
/// Per-module limits: concurrency, QPS, circuit breaker, dedicated workers.
pub const RuntimeOptions = @import("api/Module.zig").RuntimeOptions;
/// DEPRECATED: use Application.start() / Application.stop() instead.
pub const startAll = @import("core/Lifecycle.zig").startAll;
/// DEPRECATED: use Application.start() / Application.stop() instead.
pub const stopAll = @import("core/Lifecycle.zig").stopAll;
/// Writes generated module documentation to a file path.
pub const generateDocs = @import("core/Documentation.zig").generateDocs;
/// The module-docs generator module (`generateDocs` lives here).
pub const Documentation = @import("core/Documentation.zig");
/// Declares a module's published/consumed events and provided APIs.
pub const ModuleContract = @import("core/ModuleContract.zig").ModuleContract;
/// Registry of module contracts, used for runtime verification.
pub const ContractRegistry = @import("core/ModuleContract.zig").ContractRegistry;
/// Runs architecture assertions over modules, reported by severity.
pub const ArchitectureTester = @import("core/ArchitectureTester.zig").ArchitectureTester;
/// Checks modules talk only over allowed channels (prevents erosion).
pub const ModuleInteractionVerifier = @import("core/ModuleInteractionVerifier.zig").ModuleInteractionVerifier;
/// How modules may reach each other: direct dep, event, shared data, API.
pub const InteractionType = @import("core/ModuleInteractionVerifier.zig").ModuleInteractionVerifier.InteractionType;

/// Framework event union — lifecycle and domain events as tagged variants.
pub const Event = @import("core/Event.zig").Event;
/// Untyped bus for a single thread; prefer `ThreadSafeEventBus` in apps.
pub const EventBus = @import("core/EventBus.zig").EventBus;
/// Type-safe bus for one event type; not thread-safe by itself.
pub const TypedEventBus = @import("core/EventBus.zig").TypedEventBus;
/// Thread-safe bus owned by the application — reach it via `app.eventBus(T)`.
pub const ThreadSafeEventBus = @import("core/EventBus.zig").ThreadSafeEventBus;
/// Type-erased registry of per-event-type buses.
pub const EventRegistry = @import("core/EventRegistry.zig").EventRegistry;
/// Facilities a module receives at startup (`initWith(ctx)`).
pub const ModuleContext = @import("core/ModuleContext.zig").ModuleContext;
/// Dependency-injection container: register and resolve services by type.
pub const Container = @import("di/Container.zig").Container;
/// Build-then-freeze map: fill at startup, read concurrently afterwards.
pub const FrozenMap = @import("core/FrozenMap.zig").FrozenMap;
/// String-keyed variant of `FrozenMap`.
pub const FrozenStringMap = @import("core/FrozenMap.zig").FrozenStringMap;
/// Panic hook module — expose its `hook` as the app's `pub const panic`.
pub const PanicHook = @import("api/PanicHook.zig");
/// Drop-in panic namespace for app roots: `pub const panic = zmodu.panicHook;`
pub const panicHook = @import("api/PanicHook.zig").hook;

// ============================================================
// 2. DOMAIN RE-EXPORTS (canonical — prefer these)
// ============================================================
/// HTTP domain: server, router, middleware, client, OpenAPI, SSE.
pub const http = @import("http.zig");
/// Data domain: SQLx, Redis, ORM, cache, pool, migrations.
pub const data = @import("data.zig");
/// Security domain: auth, RBAC, API keys, secrets, passwords, JWT.
pub const security = @import("security.zig");
/// Observability domain: metrics, tracing, structured logging.
pub const observability = @import("observability.zig");
/// Runtime domain: workers, mailboxes, timers, ring buffers (opt-in).
pub const runtime = @import("runtime.zig");
/// Migrations: runner, loader, entries and status.
pub const migration = @import("migration/Migration.zig");

// ============================================================
// 3. RESILIENCE
// ============================================================
/// Stops calling a failing dependency: CLOSED / OPEN / HALF_OPEN per service.
pub const CircuitBreaker = @import("resilience/CircuitBreaker.zig").CircuitBreaker;
/// Token-bucket / sliding-window limiter for one key.
pub const RateLimiter = @import("resilience/RateLimiter.zig").RateLimiter;
/// Named limiters, so endpoints do not fight over a single bucket.
pub const RateLimiterRegistry = @import("resilience/RateLimiter.zig").RateLimiterRegistry;
/// Semaphore isolation: cap concurrency per group so one failure starves none.
pub const Bulkhead = @import("resilience/Bulkhead.zig").Bulkhead;
/// Named bulkheads, created on demand and then reused.
pub const BulkheadRegistry = @import("resilience/Bulkhead.zig").BulkheadRegistry;
/// Retry helpers with backoff for transient failures.
pub const retry = @import("resilience/Retry.zig");
/// Adaptive load shedding: refuse work instead of queueing it forever.
pub const load_shedder = @import("resilience/LoadShedder.zig");

// ============================================================
// 4. MESSAGING
// ============================================================
/// Thin barrel — `zigmodu.outbox.*` or direct root aliases below.
pub const outbox = @import("messaging/outbox.zig");
/// Writes commands/events into the outbox table inside your transaction.
pub const OutboxPublisher = outbox.OutboxPublisher;
/// Claims and dispatches outbox rows; set metrics, then start polling.
pub const OutboxPoller = outbox.OutboxPoller;
/// One outbox row: topic, payload, status, retry metadata.
pub const OutboxEntry = outbox.OutboxEntry;
/// Outbox poller settings (batch size, interval, claim timeout).
pub const OutboxConfig = outbox.OutboxConfig;
/// Outbox row state: pending / processing / done / failed.
pub const OutboxStatus = outbox.OutboxStatus;
/// Kafka-protocol producer (RobustMQ or any Kafka-compatible broker).
pub const KafkaProducer = @import("core/KafkaConnector.zig").KafkaProducer;
/// Kafka-protocol consumer: poll, process, commit offsets.
pub const KafkaConsumer = @import("core/KafkaConnector.zig").KafkaConsumer;
/// Bridges Kafka topics onto the framework event bus.
pub const KafkaEventBridge = @import("core/KafkaConnector.zig").KafkaEventBridge;
/// One consumed Kafka record: topic, key, value, headers.
pub const KafkaMessage = @import("core/KafkaConnector.zig").KafkaMessage;
/// Transport tuned for RobustMQ's Kafka compatibility layer.
pub const RobustMQTransport = @import("core/KafkaConnector.zig").RobustMQTransport;
/// Consumer-group session: assignor, rebalance, revocation acknowledgement.
pub const ConsumerGroupSession = @import("core/KafkaConnector.zig").ConsumerGroupSession;
/// Encodes and decodes Kafka protocol frames.
pub const KafkaWireFormat = @import("core/KafkaConnector.zig").KafkaWireFormat;
/// NATS client (default localhost:4222) for pub/sub messaging.
pub const NatsClient = @import("messaging/Nats.zig").NatsClient;
/// NATS connection settings (URL, credentials, timeouts).
pub const NatsConfig = @import("messaging/Nats.zig").NatsConfig;
/// Queue abstraction over in-memory, NATS, Redis and Kafka backends.
pub const MessageQueue = @import("messaging/MessageQueue.zig").MessageQueue;
/// Gossip event bus across nodes; also carries cluster membership.
pub const DistributedEventBus = @import("core/DistributedEventBus.zig").DistributedEventBus;
/// Node list and ports for `DistributedEventBus`.
pub const ClusterConfig = @import("core/DistributedEventBus.zig").ClusterConfig;
/// Dead-letter queue for messages that keep failing.
pub const DLQ = @import("core/eventbus/DLQ.zig").DLQ;
/// DLQ capacity and retry policy.
pub const DLQConfig = @import("core/eventbus/DLQ.zig").DLQConfig;
/// Consistent-hash partitioner for topic sharding.
pub const Partitioner = @import("core/eventbus/Partitioner.zig").ConsistentHashPartitioner;
/// Partitioner knobs (virtual nodes, hash seed).
pub const PartitionerConfig = @import("core/eventbus/Partitioner.zig").PartitionerConfig;
/// Write-ahead log so bus messages survive a crash.
pub const WAL = @import("core/eventbus/WAL.zig").WAL;
/// WAL file location, fsync policy and size limits.
pub const WALConfig = @import("core/eventbus/WAL.zig").WALConfig;

// ============================================================
// 5. DISTRIBUTED
// ============================================================
/// One-shot cluster bring-up for multi-node deployments.
pub const ClusterBootstrap = @import("core/cluster/ClusterBootstrap.zig").ClusterBootstrap;
/// Read side of a cluster: refcounted membership snapshots + rendezvous routing.
pub const ClusterView = @import("cluster/ClusterView.zig").ClusterView;
/// One node inside a `ClusterSnapshot`.
pub const ClusterMember = @import("cluster/ClusterView.zig").Member;
/// Immutable, refcounted membership snapshot handed out by `ClusterView`.
pub const ClusterSnapshot = @import("cluster/ClusterView.zig").Snapshot;
/// The bridge that feeds `ClusterView` from `ClusterMembership` — use this, not
/// the membership map, on request paths (`docs/DISTRIBUTED.md`).
pub const MembershipView = @import("cluster/MembershipView.zig").MembershipView;
/// One member as the read-side bridge sees it (id, address, healthy).
pub const ClusterNodeView = @import("cluster/MembershipView.zig").Node;
/// The membership *write* side — the gossip maintenance loop's own state.
pub const ClusterMembership = @import("core/ClusterMembership.zig").ClusterMembership;
/// Cluster building blocks. Exported so an app can assemble its own topology
/// instead of taking the whole `ClusterBootstrap`; each is independently tested
/// and **not** wired into a request path by the framework (see the readiness
/// notes in `docs/DISTRIBUTED.md`).
pub const RaftElection = @import("core/cluster/RaftElection.zig").RaftElection;
/// The real transport behind `RaftElection` (`docs/DISTRIBUTED.md`「真选主要什么」):
/// outbound vote/replication RPCs over TCP, inbound dispatch, address book.
pub const RaftTransport = @import("core/cluster/RaftTransport.zig");
/// Peer discovery for multi-node deployments (seeds / registry).
pub const PeerDiscovery = @import("core/cluster/PeerDiscovery.zig").PeerDiscovery;
/// Client-side load balancing across peers.
pub const LoadBalancer = @import("core/cluster/LoadBalancer.zig").LoadBalancer;
/// Cluster health is a **pair of functions**, not a type:
/// `healthJson(allocator, cluster)` and `clusterHealthHandler(cluster)`.
pub const cluster_health = @import("core/cluster/ClusterHealth.zig");
/// Renders cluster health as JSON: `healthJson(alloc, cluster)`.
pub const clusterHealthJson = @import("core/cluster/ClusterHealth.zig").healthJson;
/// Handler that serves the cluster health JSON.
pub const clusterHealthHandler = @import("core/cluster/ClusterHealth.zig").clusterHealthHandler;
/// φ-accrual failure detector: a suspicion level, not a binary ping.
pub const AccrualFailureDetector = @import("core/cluster/FailureDetector.zig").AccrualFailureDetector;
/// Long-running saga with compensating rollback steps (`resumeInstance`).
pub const SagaOrchestrator = @import("core/SagaOrchestrator.zig").SagaOrchestrator;
/// Persisted saga log — the recovery point for crash resume.
pub const SagaLog = @import("core/SagaOrchestrator.zig").SagaLog;
/// Saga state: running / completed / compensating / failed.
pub const SagaStatus = @import("core/SagaOrchestrator.zig").SagaStatus;
/// Saga-pattern transactions: forward steps, reverse-order compensation.
pub const DistributedTransactionManager = @import("core/DistributedTransaction.zig").DistributedTransactionManager;
/// 2PC coordinator: tracks each transaction's prepare/commit decision.
pub const TwoPhaseCommit = @import("core/DistributedTransaction.zig").TwoPhaseCommit;
/// Declarative transaction wrapper (Spring `@Transactional` style).
pub const Transactional = @import("core/Transactional.zig").Transactional;
/// Routes a tenant id to the correct database connection pool.
pub const ShardRouter = @import("tenant/ShardRouter.zig").ShardRouter;
/// One shard's name and connection config.
pub const ShardPool = @import("tenant/ShardRouter.zig").ShardPool;
/// Shard topology and routing rules.
pub const ShardConfig = @import("tenant/ShardRouter.zig").ShardConfig;
/// Request-scoped tenant id: set by middleware, read by SQL interceptors.
pub const TenantContext = @import("tenant/TenantContext.zig").TenantContext;
/// Sets the tenant column name (e.g. `app_id` for ZigShop-style schemas).
pub const setTenantColumn = @import("tenant/TenantContext.zig").setTenantColumn;
/// Reads the configured tenant column name.
pub const tenantColumn = @import("tenant/TenantContext.zig").tenantColumn;
/// Default tenant column name (`tenant_id`).
pub const TENANT_COLUMN = @import("tenant/TenantContext.zig").TENANT_COLUMN;
/// Injects the tenant column into ORM queries automatically.
pub const TenantInterceptor = @import("tenant/TenantInterceptor.zig").TenantInterceptor;
/// Repository wrapper that applies tenant filtering.
pub const TenantRepository = @import("tenant/TenantInterceptor.zig").TenantRepository;
/// Same, for a custom tenant column.
pub const TenantRepositoryCol = @import("tenant/TenantInterceptor.zig").TenantRepositoryCol;
/// Request-scoped data scope (self / dept / all) for row-level filtering.
pub const DataPermissionContext = @import("datapermission/DataPermission.zig").DataPermissionContext;
/// Turns a data scope into a SQL predicate.
pub const DataPermissionFilter = @import("datapermission/DataPermission.zig").DataPermissionFilter;
/// Data-permission module: scopes, filters, request context.
pub const datapermission = @import("datapermission/DataPermission.zig");

// ============================================================
// 6. EXTENSIONS
// ============================================================
/// Loads shared libraries as plugins (.so / .dll / .dylib).
pub const PluginManager = @import("extensions/PluginManager.zig").PluginManager;
/// Plugin metadata: name, version, author, exports, dependencies.
pub const PluginManifest = @import("extensions/PluginManager.zig").PluginManifest;
/// Watches module files and reloads them without a full restart.
pub const HotReloader = @import("extensions/HotReloader.zig").HotReloader;
/// How a reload treats state: restart, preserve state, gradual migration.
pub const ReloadStrategy = @import("extensions/HotReloader.zig").ReloadStrategy;
/// Versioned value snapshot used to carry state across a reload.
pub const ModuleSnapshot = @import("extensions/HotReloader.zig").ModuleSnapshot;
/// Web UI for module and health monitoring.
pub const WebMonitor = @import("extensions/WebMonitor.zig").WebMonitor;
/// RFC 6455 WebSocket server for live monitoring pushes.
pub const WebSocketServer = @import("extensions/WebSocket.zig").WebSocketServer;
/// WebSocket client, for connecting to a monitor or a peer.
pub const WebSocketClient = @import("extensions/WebSocket.zig").WebSocketClient;
/// Broadcasts monitor updates over WebSocket connections.
pub const WebSocketMonitor = @import("extensions/WebSocket.zig").WebSocketMonitor;
/// IM domain: WebSocket messaging, connection registry, buffer pool.
pub const im = @import("im/im.zig");
/// AI domain: skills, agents, guard, proposals, workflows, MCP.
pub const ai = @import("ai/ai.zig");
/// Web4 domain: DID keys, verifiable credentials, x402 payments.
pub const web4 = @import("web4/web4.zig");
/// In-process gRPC service registry and dispatch.
pub const GrpcServiceRegistry = @import("extensions/GrpcTransport.zig").GrpcServiceRegistry;
/// gRPC client over the HTTP/1.1 `application/grpc` unary path.
pub const GrpcClient = @import("extensions/GrpcTransport.zig").GrpcClient;
/// gRPC status codes, mapped to and from HTTP.
pub const GrpcStatusCode = @import("extensions/GrpcTransport.zig").GrpcStatusCode;
/// gRPC length-prefixed message framing.
pub const GrpcFrame = @import("extensions/GrpcTransport.zig").GrpcFrame;
/// Server-streaming writer: several messages, then trailers.
pub const GrpcStreamWriter = @import("extensions/GrpcTransport.zig").GrpcStreamWriter;
/// A gRPC response that owns its buffers.
pub const OwnedGrpcResponse = @import("extensions/GrpcTransport.zig").OwnedGrpcResponse;
/// Minimal `.proto` parser for service and message descriptors.
pub const ProtoParser = @import("extensions/GrpcTransport.zig").ProtoParser;
/// HTTP/2 frame codec (RFC 7540) plus HPACK.
pub const Http2 = @import("http/Http2.zig");

// ============================================================
// 7. SCHEDULER
// ============================================================
/// Cron scheduler; add a `DistributedLock` before running several replicas.
pub const cron = @import("scheduler/Cron.zig");
/// Cross-instance mutual exclusion for background work (cron, migrations).
pub const DistributedLock = @import("core/DistributedLock.zig");
/// Startup preflight checks (env / secret / DB / migrations / clock).
pub const Preflight = @import("core/Preflight.zig");

// ============================================================
// 8. UTILITIES
// ============================================================
/// Time helpers (`monotonicNowMilliseconds`, monotonic seconds, …).
pub const time = @import("core/Time.zig");
/// Functional / stream utilities (go-zero `fx` style).
pub const fx = @import("core/Fx.zig");
/// Misc helpers: random hex, hashing, pluralize.
pub const util = @import("util.zig");
/// Streaming RFC 4180 CSV parsing.
pub const csv = @import("util/csv.zig");
/// Singular → plural, for generated route and table names.
pub const pluralize = util.pluralize;
/// Hex digest helpers (md5 / sha1 / sha256) for ids and checksums.
pub const HashKit = util.HashKit;
/// Encodes bytes as a lowercase hex string.
pub const hexEncode = util.hexEncode;
/// DTO field validation, accumulating one error per failed rule.
pub const Validator = @import("validation/ObjectValidator.zig").Validator;

// ============================================================
// 9. CONFIG
// ============================================================
/// Config from env / files / custom loaders, with optional hot reload.
pub const ExternalizedConfig = @import("config/ExternalizedConfig.zig").ExternalizedConfig;
/// Feature flags: percentage rollout, allowlists, per-tenant targeting.
pub const FeatureFlagManager = @import("core/FeatureFlags.zig").FeatureFlagManager;
/// One flag's definition (key, default, rollout).
pub const FeatureFlag = @import("core/FeatureFlags.zig").FeatureFlag;
/// Lightweight YAML for basic config (2-level nesting, string arrays).
pub const YamlParser = @import("config/YamlToml.zig").YamlParser;
/// Lightweight TOML parser for config files.
pub const TomlParser = @import("config/YamlToml.zig").TomlParser;

// ============================================================
// 10. TESTING
// ============================================================
/// End-to-end test harness: run an app in-process for one case.
pub const IntegrationTest = @import("test/IntegrationTest.zig").IntegrationTest;
/// Seeded generator for deterministic test fixtures.
pub const TestDataGenerator = @import("test/IntegrationTest.zig").TestDataGenerator;
/// Micro-benchmark helper: warmup, iterations, statistics.
pub const Benchmark = @import("test/Benchmark.zig").Benchmark;
/// Groups benchmarks so their results stay comparable.
pub const BenchmarkSuite = @import("test/Benchmark.zig").BenchmarkSuite;
/// Runs consumer↔provider contract checks for modules.
pub const ContractTestRunner = @import("test/ContractTest.zig").ContractTestRunner;
/// A contract to verify (name, consumer, provider, version).
pub const Contract = @import("test/ContractTest.zig").Contract;
/// Outcome of a contract check: passed, failures, duration.
pub const ContractVerificationResult = @import("test/ContractTest.zig").ContractVerificationResult;
/// Isolated context for testing one module (fresh container/bus/state).
pub const ModuleTestContext = @import("test/ModuleTest.zig").ModuleTestContext;
/// Builds a throwaway `ModuleInfo` for tests.
pub const createMockModule = @import("test/ModuleTest.zig").createMockModule;
/// Loopback TCP probe for socket tests in restricted sandboxes.
pub const NetworkProbe = @import("test/NetworkProbe.zig");

// ============================================================
// ============================================================
// TESTS
// ============================================================
test {
    _ = @import("tests.zig");
    _ = @import("core/WorkerPool.zig");
}
