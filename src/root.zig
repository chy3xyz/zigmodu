const std = @import("std");

// Core modules
pub const ModuleInfo = @import("core/Module.zig").ModuleInfo;
pub const ApplicationModules = @import("core/Module.zig").ApplicationModules;
pub const scanModules = @import("core/ModuleScanner.zig").scanModules;
pub const validateModules = @import("core/ModuleValidator.zig").validateModules;
pub const startAll = @import("core/Lifecycle.zig").startAll;
pub const stopAll = @import("core/Lifecycle.zig").stopAll;
pub const generateDocs = @import("core/Documentation.zig").generateDocs;
pub const Documentation = @import("core/Documentation.zig");

// Application
pub const Application = @import("Application.zig").Application;
pub const ApplicationBuilder = @import("Application.zig").ApplicationBuilder;
pub const builder = @import("Application.zig").builder;

// API
pub const api = @import("api/Module.zig");
// HTTP Server (adapted from zigzero)
pub const http_server = @import("api/Server.zig");
pub const http_middleware = @import("api/Middleware.zig");


// Simplified API (VTable-based)
pub const App = @import("api/Simplified.zig").App;
pub const Module = @import("api/Simplified.zig").Module;
pub const ModuleImpl = @import("api/Simplified.zig").ModuleImpl;

// Extensions namespace (backward compatibility)
pub const extensions = @import("extensions.zig");

// Extensions
pub const Container = @import("di/Container.zig").Container;
pub const EventBus = @import("core/EventBus.zig").EventBus;
pub const TypedEventBus = @import("core/EventBus.zig").TypedEventBus;
pub const ExternalizedConfig = @import("config/ExternalizedConfig.zig").ExternalizedConfig;
pub const PrometheusMetrics = @import("metrics/PrometheusMetrics.zig").PrometheusMetrics;
pub const DistributedTracer = @import("tracing/DistributedTracer.zig").DistributedTracer;
pub const SecurityModule = @import("security/SecurityModule.zig").SecurityModule;
pub const CacheManager = @import("cache/CacheManager.zig").CacheManager;

// Testing
pub const IntegrationTest = @import("test/IntegrationTest.zig").IntegrationTest;
pub const TestDataGenerator = @import("test/IntegrationTest.zig").TestDataGenerator;
pub const Benchmark = @import("test/Benchmark.zig").Benchmark;
pub const BenchmarkSuite = @import("test/Benchmark.zig").BenchmarkSuite;

// Error handling
pub const ZigModuError = @import("core/Error.zig").ZigModuError;
pub const ErrorContext = @import("core/Error.zig").ErrorContext;
pub const ErrorHandler = @import("core/Error.zig").ErrorHandler;
pub const Result = @import("core/Error.zig").Result;

// Module contracts
pub const ModuleContract = @import("core/ModuleContract.zig").ModuleContract;
pub const ContractRegistry = @import("core/ModuleContract.zig").ContractRegistry;

// Transactions
pub const Transactional = @import("core/Transactional.zig").Transactional;

// Security
pub const SecurityScanner = @import("security/SecurityScanner.zig").SecurityScanner;
pub const DependencyScanner = @import("security/SecurityScanner.zig").DependencyScanner;
pub const SecurityConfigValidator = @import("security/SecurityScanner.zig").SecurityConfigValidator;

// Resilience
pub const CircuitBreaker = @import("resilience/CircuitBreaker.zig").CircuitBreaker;
pub const RateLimiter = @import("resilience/RateLimiter.zig").RateLimiter;

// Validation
pub const Validator = @import("validation/Validator.zig").Validator;

// Scheduler
pub const ScheduledTask = @import("scheduler/ScheduledTask.zig").ScheduledTask;

// HTTP
pub const HttpClient = @import("http/HttpClient.zig").HttpClient;

// Auto instrumentation
pub const AutoInstrumentation = @import("metrics/AutoInstrumentation.zig").AutoInstrumentation;
pub const InstrumentedLifecycleListener = @import("metrics/AutoInstrumentation.zig").InstrumentedLifecycleListener;
pub const InstrumentedEventListener = @import("metrics/AutoInstrumentation.zig").InstrumentedEventListener;

// Logging
pub const StructuredLogger = @import("log/StructuredLogger.zig").StructuredLogger;
pub const LogLevel = @import("log/StructuredLogger.zig").LogLevel;
pub const LogRotator = @import("log/StructuredLogger.zig").LogRotator;

// Re-export core types for convenience
pub const Event = @import("core/Event.zig").Event;

// Distributed Event Bus (NEW)
pub const DistributedEventBus = @import("core/DistributedEventBus.zig").DistributedEventBus;
pub const ClusterConfig = @import("core/DistributedEventBus.zig").ClusterConfig;

// Web Monitor (NEW)
pub const WebMonitor = @import("core/WebMonitor.zig").WebMonitor;

// WebSocket (NEW)
pub const WebSocketServer = @import("core/WebSocket.zig").WebSocketServer;
pub const WebSocketClient = @import("core/WebSocket.zig").WebSocketClient;
pub const WebSocketMonitor = @import("core/WebSocket.zig").WebSocketMonitor;

// Plugin System (NEW)
pub const PluginManager = @import("core/PluginManager.zig").PluginManager;
pub const PluginManifest = @import("core/PluginManager.zig").PluginManifest;

// Hot Reloading (NEW)
pub const HotReloader = @import("core/HotReloader.zig").HotReloader;
pub const ReloadStrategy = @import("core/HotReloader.zig").ReloadStrategy;
pub const ModuleSnapshot = @import("core/HotReloader.zig").ModuleSnapshot;

// Cluster Membership (NEW)
pub const ClusterMembership = @import("core/ClusterMembership.zig").ClusterMembership;

// Distributed Transactions (NEW)
pub const DistributedTransactionManager = @import("core/DistributedTransaction.zig").DistributedTransactionManager;
pub const TwoPhaseCommit = @import("core/DistributedTransaction.zig").TwoPhaseCommit;

// Config Parsers (NEW)
pub const YamlParser = @import("config/YamlToml.zig").YamlParser;
pub const TomlParser = @import("config/YamlToml.zig").TomlParser;

// SQLx (adapted from zigzero)
pub const sqlx = @import("sqlx/sqlx.zig");

// Redis (adapted from zigzero)
pub const redis = @import("redis/redis.zig");

// Pool (adapted from zigzero)
pub const pool = @import("pool/Pool.zig");

// Cache (adapted from zigzero)
pub const cache = @import("cache/Lru.zig");

// Scheduler (adapted from zigzero)
pub const cron = @import("scheduler/Cron.zig");

// Core utilities (adapted from zigzero)
pub const fx = @import("experimental/Fx.zig");

// Resilience (adapted from zigzero)
pub const retry = @import("resilience/Retry.zig");
pub const load_shedder = @import("resilience/LoadShedder.zig");

// Persistence (adapted from zigzero)
pub const orm = @import("experimental/Orm.zig");

// Validation (adapted from zigzero)
pub const gozero_validator = @import("experimental/GoZeroValidator.zig");
// Tests
test {
    // Import all test files
    _ = @import("tests.zig");
}
