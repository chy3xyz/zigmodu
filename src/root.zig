const std = @import("std");

// ============================================
// PRIMARY API - For most users
// ============================================

// Application (Primary entry point)
pub const Application = @import("Application.zig").Application;
pub const ApplicationBuilder = @import("Application.zig").ApplicationBuilder;
pub const builder = @import("Application.zig").builder;

// Module Definition
pub const api = @import("api/Module.zig");

// HTTP Server
pub const http_server = @import("api/Server.zig");
pub const http_middleware = @import("api/Middleware.zig");

// Error Handling
pub const ZigModuError = @import("core/Error.zig").ZigModuError;
pub const ErrorContext = @import("core/Error.zig").ErrorContext;
pub const ErrorHandler = @import("core/Error.zig").ErrorHandler;
pub const Result = @import("core/Error.zig").Result;

// Event System
pub const Event = @import("core/Event.zig").Event;
pub const EventBus = @import("core/EventBus.zig").EventBus;
pub const TypedEventBus = @import("core/EventBus.zig").TypedEventBus;

// Dependency Injection
pub const Container = @import("di/Container.zig").Container;

// Logging
pub const StructuredLogger = @import("log/StructuredLogger.zig").StructuredLogger;
pub const LogLevel = @import("log/StructuredLogger.zig").LogLevel;

// Configuration
pub const ExternalizedConfig = @import("config/ExternalizedConfig.zig").ExternalizedConfig;

// ============================================
// ADVANCED API - For power users
// ============================================

// Core Utilities (Time)
pub const time = @import("core/Time.zig");

// Core modules - Low-level access
pub const ModuleInfo = @import("core/Module.zig").ModuleInfo;
pub const ApplicationModules = @import("core/Module.zig").ApplicationModules;
pub const scanModules = @import("core/ModuleScanner.zig").scanModules;
pub const validateModules = @import("core/ModuleValidator.zig").validateModules;
pub const startAll = @import("core/Lifecycle.zig").startAll;
pub const stopAll = @import("core/Lifecycle.zig").stopAll;
pub const generateDocs = @import("core/Documentation.zig").generateDocs;
pub const Documentation = @import("core/Documentation.zig");

// Module Contracts
pub const ModuleContract = @import("core/ModuleContract.zig").ModuleContract;
pub const ContractRegistry = @import("core/ModuleContract.zig").ContractRegistry;

// Resilience Patterns
pub const CircuitBreaker = @import("resilience/CircuitBreaker.zig").CircuitBreaker;
pub const RateLimiter = @import("resilience/RateLimiter.zig").RateLimiter;

// Metrics
pub const PrometheusMetrics = @import("metrics/PrometheusMetrics.zig").PrometheusMetrics;

// Testing
pub const IntegrationTest = @import("test/IntegrationTest.zig").IntegrationTest;
pub const Benchmark = @import("test/Benchmark.zig").Benchmark;
pub const TestDataGenerator = @import("test/IntegrationTest.zig").TestDataGenerator;
pub const BenchmarkSuite = @import("test/Benchmark.zig").BenchmarkSuite;

// Security
pub const SecurityModule = @import("security/SecurityModule.zig").SecurityModule;
pub const SecurityScanner = @import("security/SecurityScanner.zig").SecurityScanner;
pub const DependencyScanner = @import("security/SecurityScanner.zig").DependencyScanner;
pub const SecurityConfigValidator = @import("security/SecurityScanner.zig").SecurityConfigValidator;

// Validation
pub const Validator = @import("validation/ObjectValidator.zig").Validator;

// Scheduler
pub const ScheduledTask = @import("scheduler/ScheduledTask.zig").ScheduledTask;

// HTTP Client
pub const HttpClient = @import("http/HttpClient.zig").HttpClient;

// Auto Instrumentation
pub const AutoInstrumentation = @import("metrics/AutoInstrumentation.zig").AutoInstrumentation;
pub const InstrumentedLifecycleListener = @import("metrics/AutoInstrumentation.zig").InstrumentedLifecycleListener;
pub const InstrumentedEventListener = @import("metrics/AutoInstrumentation.zig").InstrumentedEventListener;

// Log Rotation
pub const LogRotator = @import("log/StructuredLogger.zig").LogRotator;

// Distributed Event Bus
pub const DistributedEventBus = @import("core/DistributedEventBus.zig").DistributedEventBus;
pub const ClusterConfig = @import("core/DistributedEventBus.zig").ClusterConfig;

// Web Monitor
pub const WebMonitor = @import("core/WebMonitor.zig").WebMonitor;

// WebSocket
pub const WebSocketServer = @import("core/WebSocket.zig").WebSocketServer;
pub const WebSocketClient = @import("core/WebSocket.zig").WebSocketClient;
pub const WebSocketMonitor = @import("core/WebSocket.zig").WebSocketMonitor;

// Plugin System
pub const PluginManager = @import("core/PluginManager.zig").PluginManager;
pub const PluginManifest = @import("core/PluginManager.zig").PluginManifest;

// Hot Reloading
pub const HotReloader = @import("core/HotReloader.zig").HotReloader;
pub const ReloadStrategy = @import("core/HotReloader.zig").ReloadStrategy;
pub const ModuleSnapshot = @import("core/HotReloader.zig").ModuleSnapshot;

// Cluster Membership
pub const ClusterMembership = @import("core/ClusterMembership.zig").ClusterMembership;

// Distributed Transactions
pub const DistributedTransactionManager = @import("core/DistributedTransaction.zig").DistributedTransactionManager;
pub const TwoPhaseCommit = @import("core/DistributedTransaction.zig").TwoPhaseCommit;

// Transactions
pub const Transactional = @import("core/Transactional.zig").Transactional;

// Config Parsers
pub const YamlParser = @import("config/YamlToml.zig").YamlParser;
pub const TomlParser = @import("config/YamlToml.zig").TomlParser;

// SQLx
pub const sqlx = @import("sqlx/sqlx.zig");

// Redis
pub const redis = @import("redis/redis.zig");

// Pool
pub const pool = @import("pool/Pool.zig");

// Cache
pub const CacheManager = @import("cache/CacheManager.zig").CacheManager;
pub const cache = @import("cache/Lru.zig");

// Scheduler (Cron)
pub const cron = @import("scheduler/Cron.zig");

// Core Utilities
pub const fx = @import("core/Fx.zig");

// Retry / Load Shedder
pub const retry = @import("resilience/Retry.zig");
pub const load_shedder = @import("resilience/LoadShedder.zig");

// ORM
pub const orm = @import("persistence/Orm.zig");
pub const SqlxBackend = @import("persistence/backends/SqlxBackend.zig").SqlxBackend;

// Gozero Validator (legacy)
pub const gozero_validator = @import("validation/Validator.zig");

// Tracing
pub const DistributedTracer = @import("tracing/DistributedTracer.zig").DistributedTracer;

// ============================================
// DEPRECATED API - Will be removed in future
// ============================================

/// DEPRECATED: Use zigmodu.Application instead
/// This API will be removed in a future version.
/// Please use the Application API for better type safety and features.
pub const App = @import("api/Simplified.zig").App;

/// DEPRECATED: Use zigmodu.Application instead
pub const Module = @import("api/Simplified.zig").Module;

/// DEPRECATED: Use zigmodu.Application instead
pub const ModuleImpl = @import("api/Simplified.zig").ModuleImpl;

// Extensions namespace (backward compatibility)
pub const extensions = @import("extensions.zig");

// Tests
test {
    _ = @import("tests.zig");
}
