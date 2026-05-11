//! Observability domain: metrics, tracing, logging.
//! Import directly: `const obs = @import("zigmodu").observability;`

pub const MetricsBackend = @import("metrics/MetricsBackend.zig").MetricsBackend;
pub const PrometheusMetrics = @import("metrics/PrometheusMetrics.zig").PrometheusMetrics;
pub const AutoInstrumentation = @import("metrics/AutoInstrumentation.zig").AutoInstrumentation;
pub const InstrumentedLifecycleListener = @import("metrics/AutoInstrumentation.zig").InstrumentedLifecycleListener;
pub const InstrumentedEventListener = @import("metrics/AutoInstrumentation.zig").InstrumentedEventListener;
pub const DistributedTracer = @import("tracing/DistributedTracer.zig").DistributedTracer;
pub const StructuredLogger = @import("log/StructuredLogger.zig").StructuredLogger;
pub const LogLevel = @import("log/StructuredLogger.zig").LogLevel;
pub const LogRotator = @import("log/StructuredLogger.zig").LogRotator;
