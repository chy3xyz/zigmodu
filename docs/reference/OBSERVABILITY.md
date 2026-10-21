# Observability & Alerting Guide

This guide covers wiring Prometheus metrics, Kubernetes health probes, runtime worker gauges, structured logs, and OpenTelemetry tracing in production.

## 1. One-Line Production Setup (`http.productionProfile`)

Call `zmodu.http.productionProfile` **before** registering any routes (`router.mountAll` or `server.addRoute`), because `addRoute` snapshots the active global middleware chain at registration time:

```zig
var server = zmodu.http.Server.init(io, allocator, 8080);
defer server.deinit();

var profile = zmodu.http.ProductionProfileState.init(allocator);
defer profile.deinit(allocator);

try zmodu.http.productionProfile(&server, .{
    .max_connections = 4096,
    .header_timeout_ms = 10_000,
}, &profile);
```

Endpoints registered by `productionProfile`:

| Path | Description |
|------|-------------|
| `GET /metrics` | Prometheus exposition format (`text/plain; version=0.0.4`) |
| `GET /health/live` | Liveness probe (`200 UP`) |
| `GET /health/ready` | Readiness probe |
| `GET /`, `/dashboard`, `/api/dashboard/*` | Optional human-readable dashboard (when `.dashboard = true`) |

Override default paths via `metrics_path`, `liveness_path`, and `readiness_path`.

## 2. HTTP Golden Signals

`productionProfile` exports the following series by default:

| Metric | Type | Description |
|--------|------|-------------|
| `http_requests_total` | Counter | Total HTTP requests |
| `http_responses_2xx_total` | Counter | 2xx responses |
| `http_responses_3xx_total` | Counter | 3xx responses |
| `http_responses_4xx_total` | Counter | 4xx client error responses |
| `http_responses_5xx_total` | Counter | 5xx server error responses |
| `http_request_duration_milliseconds` | Histogram | Request latency (buckets: 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 ms) |

### Bounded Route Labels

Golden signals carry a `route` label populated from `ctx.route_template` (the matched pattern such as `/orders/{id}`, never the raw URL path). Unmatched routes map to `route="__unmatched__"`. Label cardinality is capped by `ProductionConfig.max_route_series` (default `64`); additional patterns map to `route="__other__"`.

Never place high-cardinality identifiers (`tenant_id`, `user_id`, `order_id`) into Prometheus labels. Use `createCounterFamily` / `createHistogramFamily` for small bounded dimensions, and register all custom metrics at startup before the first `GET /metrics` scrape freezes the registry.

## 3. Runtime Execution Plane Metrics (37 Gauges via `MetricsBridge`)

HTTP metrics do not observe worker mailboxes, worker pools, or timer lag. When using `app.runtime()`, wire `Runtime.MetricsBridge`:

```zig
var bridge = try Runtime.MetricsBridge(PrometheusMetrics).init(&rt, &metrics);
metrics.setScrapeHook(bridge.publish);
```

### 3.1 CPU Worker Pool & Blocking Pool (9 Gauges Each)

| Metric | Description |
|--------|-------------|
| `zigmodu_runtime_pool_{declared,threads,claimed,dispatches}` | Pool configuration, active claims, and dispatch count |
| `zigmodu_runtime_pool_ready_len_{high,normal,low}` | Ready queue depth per priority class |
| `zigmodu_runtime_pool_ready_push_failures` | Contract invariant gauge (**must remain 0**) |
| `zigmodu_runtime_pool_wait_max_ms_{high,normal,low}` | High-water mark claim wait time |
| `zigmodu_runtime_pool_starvation_events_{high,normal,low}` | Claims waiting longer than `starvation_threshold_ms` (**must remain 0**) |
| `zigmodu_runtime_blocking_pool_*` | Corresponding 9 gauges for the blocking pool |

### 3.2 Mailboxes, Timers & Supervision (13 Gauges)

| Metric | Description |
|--------|-------------|
| `zigmodu_runtime_{workers,running}` | Total spawned workers vs currently running workers |
| `zigmodu_runtime_messages_{received,sent}` | Mailbox message throughput |
| `zigmodu_runtime_messages_dropped` | Messages rejected due to full mailboxes (`error.Full`) |
| `zigmodu_runtime_messages_discarded_on_stop` | Pending messages discarded during shutdown |
| `zigmodu_runtime_handler_errors` | Unhandled errors returned by worker handlers |
| `zigmodu_runtime_group_restarts` | Supervision group restarts |
| `zigmodu_runtime_supervised_stops` | Workers stopped after exhausting their error budget |
| `zigmodu_runtime_timer_fires` | Fired timers |
| `zigmodu_runtime_timer_lag_ms` | Maximum timer firing lag in milliseconds |
| `zigmodu_runtime_timer_deliveries_dropped` | Timer deliveries dropped due to full target mailbox |
| `zigmodu_runtime_timers_discarded` | Armed timers discarded during shutdown |

## 4. Outbox & Database Pool Metrics

```zig
// 1. Transactional Outbox consumer metrics and background polling
var consumer = zmodu.outbox.OutboxConsumer.init(allocator, &backend, .{}, ctx, handler);
try consumer.setMetrics(profile.prometheus.?);
try consumer.startPolling(io, 1000);
defer consumer.stopPolling();

// 2. Database connection pool gauges sampled on scrape
const pool_active = try metrics.createGauge("db_pool_active", "Active pooled DB connections");
const pool_waiters = try metrics.createGauge("db_pool_waiters", "Requests waiting for a DB connection");
metrics.setScrapeHook(struct {
    fn sample(ud: ?*anyopaque) void {
        const db: *data.Client = @ptrCast(@alignCast(ud.?));
        if (db.poolMetrics()) |pm| {
            pool_active.set(@floatFromInt(pm.current_active));
            pool_waiters.set(@floatFromInt(pm.current_waiters));
        }
    }
}.sample, &db);
```

## 5. PromQL Queries & Alert Thresholds

```text
# Request rate (QPS, 5m window)
sum(rate(http_requests_total[5m]))

# 5xx error ratio
sum(rate(http_responses_5xx_total[5m])) / clamp_min(sum(rate(http_requests_total[5m])), 0.001)

# P95 / P99 latency
histogram_quantile(0.95, sum(rate(http_request_duration_milliseconds_bucket[5m])) by (le))
histogram_quantile(0.99, sum(rate(http_request_duration_milliseconds_bucket[5m])) by (le))
```

| Alert | Condition | Action |
|-------|-----------|--------|
| Instance Down | `up{job="zmodu"} == 0` for 1m | Check supervisor logs and `zmodu.panicHook` stderr output |
| High 5xx Rate | 5xx ratio > 1% for 5m (or > 5% for 1m) | Inspect error logs and trace IDs; roll back if caused by deploy |
| High Latency | P95 > 500 ms for 10m | Check `db_pool_waiters` and downstream dependencies |
| Outbox Backlog | `outbox_pending` growing for 5m or `outbox_failed_total` > 0 | Check downstream broker connectivity and dead-letter rows |
| Pool Saturation | `db_pool_waiters > 0` for 1m | Increase pool capacity or optimize slow queries |

## 6. Logs, Tracing & Panic Attribution

- **Request trace correlation**: `tracingMiddleware` (enabled by `productionProfile`) reads or generates `X-Trace-Id` (ignoring untrusted headers longer than 128 bytes or containing non-printable characters) and calls `ctx.setTraceId()`. Inside handlers, call `const log = ctx.logScope("orders");` so every log line includes `trace_id=...`.
- **OTLP Export**: Use `zmodu.observability.OtlpExporter` (`exportSpans`) to push spans over `http://` or `https://`.
- **Panic attribution**: Export `pub const panic = zmodu.panicHook;` in your root `main.zig` to print the active `METHOD /path` to stderr when a panic occurs.
