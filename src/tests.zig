const std = @import("std");

// ========================================
// Compilation Gate: Ensure all source files compile
// ========================================
test "compile all source files" {
    // API
    _ = @import("api/Module.zig");
    _ = @import("api/Middleware.zig");
    _ = @import("api/Compression.zig");
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
    _ = @import("core/FrozenMap.zig");
    _ = @import("api/PanicHook.zig");
    _ = @import("core/EventRegistry.zig");
    _ = @import("core/ModuleContext.zig");
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
    _ = @import("extensions/PluginManager.zig");
    _ = @import("extensions/WebMonitor.zig");
    _ = @import("extensions/WebSocket.zig");

    // Cluster & Distributed (integration tests - these compile successfully)
    _ = @import("core/ClusterMembership.zig");
    _ = @import("cluster/ClusterView.zig");
    _ = @import("core/cluster/FailureDetector.zig");
    _ = @import("core/cluster/NetworkTransport.zig");
    _ = @import("core/cluster/RaftTransport.zig");
    _ = @import("core/cluster/PeerDiscovery.zig");
    _ = @import("core/cluster/ClusterMessage.zig");
    _ = @import("core/cluster/TlsTransport.zig");
    _ = @import("core/cluster/ClusterMetrics.zig");
    _ = @import("core/cluster/ClusterBootstrap.zig");
    _ = @import("core/cluster/ClusterHealth.zig");
    _ = @import("core/cluster/LoadBalancer.zig");
    _ = @import("core/cluster/DistributedIntegrationTest.zig");
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
    _ = @import("messaging/FluvioNative.zig");

    // Metrics
    _ = @import("metrics/AutoInstrumentation.zig");
    _ = @import("metrics/PrometheusMetrics.zig");

    // Persistence
    _ = @import("persistence/Orm.zig");
    _ = @import("persistence/backends/SqlxBackend.zig");

    // Resilience
    _ = @import("resilience/CircuitBreaker.zig");
    _ = @import("resilience/RateLimiter.zig");
    _ = @import("resilience/Retry.zig");
    _ = @import("resilience/LoadShedder.zig");
    _ = @import("resilience/RedisRateLimiter.zig");

    // Scheduler
    _ = @import("scheduler/Cron.zig");
    _ = @import("core/DistributedLock.zig");
    _ = @import("core/Preflight.zig");

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
    _ = @import("test/FaultInjection.zig");
    _ = @import("http/StaticFiles.zig");
    _ = @import("http/Multipart.zig");
    _ = @import("http/UploadGuard.zig");
    _ = @import("test/ContractGate.zig");
    _ = @import("test/DocsConsistency.zig");
    _ = @import("test/DocSnippets.zig");
    // Deprecation / API-freeze gate: the names docs/UPGRADING.md and
    // docs/API_FREEZE.md promise must still exist and still work.
    _ = @import("test/ApiFreeze.zig");
    _ = @import("test/ErrorSetSnapshot.zig");
    _ = @import("test/CombinationMatrix.zig");
    _ = @import("test/ErrorShape.zig");
    _ = @import("test/PermissionMatch.zig");
    _ = @import("test/RouteTemplate.zig");

    // Runtime (v0.16): ring/mailbox/timer/pool/worker primitives
    _ = @import("runtime.zig");
    // Scheduler: the pooled execution mode of `Runtime.spawn` (docs/RUNTIME.md §12)
    _ = @import("runtime/scheduler.zig");
    // Delivery-log segments: the storage layer §13.3 Q4 tier 2 builds on. Not
    // re-exported from `runtime.zig` (nothing consumes it yet), so this import is
    // the only thing that makes its tests run at all — the same wiring
    // `im/ConnectionRegistry.zig` above needed.
    _ = @import("runtime/delivery_log.zig");
    // Allocation contract for the L0 hot paths (docs/RUNTIME.md §4–§6)
    _ = @import("runtime/alloc_contract_test.zig");
    // Precision deadline timer: the sleep-then-spin alternative to the wheel for
    // sub-millisecond deadlines. Its tests are the *measurement* — the lateness
    // and spin-cost tables are printed, and the bound is asserted — so reaching
    // this file from here is what makes the numbers below run at all.
    _ = @import("runtime/precision_timer.zig");
    // CPU affinity: the primitive alone (`pinCurrentThread`). The test here is
    // the platform contract — a real pin on Linux, `error.Unsupported`
    // everywhere the OS has no API — so reaching this file from here is what
    // keeps the Linux half of it exercised in CI (see the module doc for the
    // evidence behind the truth table).
    _ = @import("runtime/affinity.zig");

    // IM domain. `im/ConnectionRegistry.zig`'s own tests were never wired here:
    // the file is reached only through `im/im.zig`, which `root.zig` exports and
    // this aggregating test does not import. So its 8 tests never ran — which is
    // how the id-0 / failure-sentinel collision in `register` shipped (see the
    // tests at the bottom of that file). `WsFramer`/`BufferPool` are reachable
    // via `api/Server.zig`; only this one was orphaned.
    _ = @import("im/ConnectionRegistry.zig");

    // AI boundary: ratcheted coupling + one-way seam (docs/AI_BOUNDARY.md)
    _ = @import("test/AiBoundary.zig");
    _ = @import("ai/guard.zig");
    _ = @import("ai/proposal.zig");
    _ = @import("ai/agent_worker.zig");
    _ = @import("cluster/MembershipView.zig");

    // Tracing
    _ = @import("tracing/DistributedTracer.zig");
    _ = @import("tracing/OtlpExporter.zig");

    // Web4 (DID + x402; payment verify fail-closed)
    _ = @import("web4/web4.zig");
    _ = @import("web4/x402.zig");
    _ = @import("web4/x402_store.zig");
    _ = @import("web4/challenge.zig");
    _ = @import("web4/middleware.zig");

    // Validation
    _ = @import("validation/ObjectValidator.zig");
    _ = @import("validation/FieldRules.zig");

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
    _ = @import("ai/key_pool.zig");
    _ = @import("ai/cooldown_store.zig");
    _ = @import("ai/provider_registry.zig");
    _ = @import("ai/module.zig");
    _ = @import("ai/skill.zig");
    _ = @import("ai/agent.zig");
    _ = @import("ai/schedule.zig");
    _ = @import("ai/business.zig");
    _ = @import("ai/actions.zig");
    _ = @import("ai/admin.zig");
    _ = @import("ai/mcp.zig");
    _ = @import("ai/budget.zig");
    _ = @import("ai/workflow.zig");
    _ = @import("ai/observability.zig");
    _ = @import("ai/run_audit.zig");
    _ = @import("ai/skill_export.zig");
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
    _ = @import("ai/approval_api.zig");
    _ = @import("ai/approval_store.zig");
    _ = @import("ai/llm.zig");
    _ = @import("ai/notify.zig");
    _ = @import("ai/kpi.zig");
    _ = @import("ai/sla.zig");
    _ = @import("ai/diagnose.zig");
    _ = @import("ai/bridge.zig");
    _ = @import("ai/memory.zig");
    _ = @import("ai/audit.zig");
    _ = @import("ai/retriever.zig");
    _ = @import("ai/quota.zig");
    _ = @import("ai/tokenizer.zig");
    _ = @import("messaging/outbox.zig");
    _ = @import("messaging/OutboxConsumer.zig");
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
    _ = @import("util.zig");
    _ = @import("kit/json.zig");
    _ = @import("kit/random.zig");
}

// ========================================
// Domain Import Validation
// ========================================
test "domain imports: http" {
    _ = @import("http.zig");
    _ = @import("api/Crud.zig");
}

test "domain imports: data" {
    _ = @import("data.zig");
    _ = @import("data/CrudService.zig");
}

test "domain imports: security" {
    _ = @import("security.zig");
}

test "domain imports: observability" {
    _ = @import("observability.zig");
}

test "ai barrel exposes the public AI API surface" {
    const ai = @import("ai/ai.zig");
    // Orchestration
    _ = ai.workflow.Workflow;
    _ = ai.WorkflowMetrics;
    _ = ai.trigger.Trigger;
    _ = ai.hierarchy;
    _ = ai.context;
    _ = ai.AgentHandle;
    _ = ai.bridge.OutboxWorkflowBridge;
    // LLM-backed policies + RAG
    _ = ai.llm.LlmPolicyCtx;
    _ = ai.llm.llmApprove;
    _ = ai.llm.llmDiagnose;
    _ = ai.llm.llmRiskDecide;
    _ = ai.llm.llmVerify;
    // Business tools
    _ = ai.reporter.BusinessReporter;
    _ = ai.alerts.BusinessAlert;
    _ = ai.ticket.TicketFlow;
    _ = ai.refund.RefundFlow;
    _ = ai.risk.RiskReview;
    _ = ai.recon.ReconCheck;
    _ = ai.approval.ApprovalFlow;
    _ = ai.approval_api.ApprovalQueue;
    _ = ai.approval_store.PersistentApprovalQueue;
    _ = ai.notify.NotificationHub;
    _ = ai.kpi.KpiMetric;
    _ = ai.sla.SlaTracker;
    _ = ai.diagnose.DiagnosisFlow;
    // Skills, export, observability, audit
    _ = ai.SkillRegistry;
    _ = ai.business;
    _ = ai.schedule;
    _ = ai.skill_export.toOpenApi;
    _ = ai.skill_export.toSkillsJson;
    _ = ai.observability.AiMetrics;
    _ = ai.run_audit.RunAuditStore;
    _ = ai.freeValue;
    _ = ai.TokenQuota;
}

test "domain modules stay independent of the optional src/ai domain" {
    const allocator = std.testing.allocator;
    // src/ai is an optional domain (~12k lines, used by the ai-ops /
    // llm-policies / mcp-server examples). Because Zig analyses
    // lazily, a consumer that never touches `zmodu.ai` never compiles it —
    // but only as long as the canonical domain files keep their distance.
    const domains = [_][]const u8{
        "src/http.zig",
        "src/data.zig",
        "src/security.zig",
        "src/observability.zig",
    };
    for (domains) |path| {
        const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, std.Io.Limit.limited(4 * 1024 * 1024));
        defer allocator.free(content);
        if (std.mem.indexOf(u8, content, "ai/") != null) {
            std.debug.print("domain file {s} must not import src/ai/*\n", .{path});
            return error.AiDomainLeakedIntoCore;
        }
    }
}
