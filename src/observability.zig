//! Observability domain: metrics, tracing, logging.
//! Import directly: `const obs = @import("zigmodu").observability;`

/// Metrics vtable — implement it to plug your own metrics system.
pub const MetricsBackend = @import("metrics/MetricsBackend.zig").MetricsBackend;
/// Prometheus backend: counters/gauges/histograms + text exposition.
pub const PrometheusMetrics = @import("metrics/PrometheusMetrics.zig").PrometheusMetrics;
/// Auto-registers lifecycle/event metrics so modules instrument themselves.
pub const AutoInstrumentation = @import("metrics/AutoInstrumentation.zig").AutoInstrumentation;
/// Lifecycle listener wrapper that records module start/stop timing.
pub const InstrumentedLifecycleListener = @import("metrics/AutoInstrumentation.zig").InstrumentedLifecycleListener;
/// Event listener wrapper that records event counts and latency.
pub const InstrumentedEventListener = @import("metrics/AutoInstrumentation.zig").InstrumentedEventListener;
/// Trace/span collection with sampling; pair it with `OtlpExporter`.
pub const DistributedTracer = @import("tracing/DistributedTracer.zig").DistributedTracer;
/// Structured (JSON / key-value) logger with levels and file rotation.
pub const StructuredLogger = @import("log/StructuredLogger.zig").StructuredLogger;
/// Log severity enum shared by the structured loggers.
pub const LogLevel = @import("log/StructuredLogger.zig").LogLevel;
/// Size-based log rotation with retention limits.
pub const LogRotator = @import("log/StructuredLogger.zig").LogRotator;
/// Per-module logger — the module name is attached to every line.
pub const ModuleLogger = @import("log/ModuleLogger.zig").ModuleLogger;
/// Key-values attached to every line logged inside the scope block.
pub const LogScope = @import("log/ModuleLogger.zig").ModuleLogger.LogScope;
/// Trace sampling policy (always / never / ratio) for `DistributedTracer`.
pub const Sampler = @import("tracing/DistributedTracer.zig").Sampler;
/// Exports spans to an OTLP endpoint over http(s), with retries.
pub const OtlpExporter = @import("tracing/OtlpExporter.zig").OtlpExporter;
