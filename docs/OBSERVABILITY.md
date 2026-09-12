# 可观测性与告警（生产接入）

> 目标：把"服务活着吗、它现在好不好"变成**一屏可见 + 可告警**，而不是等用户报障。
> 相关：[`BEST_PRACTICES.md`](BEST_PRACTICES.md)「韧性」· [`PRODUCTION_ROADMAP.md`](PRODUCTION_ROADMAP.md)

## 1. 一行接入

```zig
var server = zigmodu.http.Server.init(io, allocator, 8080);
defer server.deinit();

var profile = zigmodu.http.ProductionProfileState.init(allocator);
defer profile.deinit(allocator);

try zigmodu.http.productionProfile(&server, .{
    .max_connections = 4096,
    .header_timeout_ms = 10_000,
}, &profile);

// ⚠️ 必须在任何 router.mountAll / server.addRoute 之前调用：
//    addRoute 会在注册时快照当时的全局中间件链。
```

挂出的端点：

| 路径 | 内容 |
|------|------|
| `GET /metrics` | Prometheus 文本（`text/plain; version=0.0.4`） |
| `GET /health/live` | 进程存活（K8s liveness） |
| `GET /health/ready` | 依赖就绪（K8s readiness） |
| `GET /`、`/dashboard`、`/api/dashboard/*` | 可选人读面板（`.dashboard = true`） |

路径可用 `metrics_path` / `liveness_path` / `readiness_path` 覆盖；若应用自己已挂
同名路由，记得改路径以免重复注册。

## 2. 黄金信号（框架默认导出）

`productionProfile` 默认创建并维护这些序列（无标签，基数固定）：

| 指标 | 类型 | 含义 |
|------|------|------|
| `http_requests_total` | counter | 流量：累计请求数 |
| `http_responses_2xx_total` | counter | 成功 |
| `http_responses_3xx_total` | counter | 重定向 |
| `http_responses_4xx_total` | counter | 客户端错误（400/401/404…） |
| `http_responses_5xx_total` | counter | **服务端错误 = 错误预算燃烧** |
| `http_request_duration_milliseconds` | histogram | 延迟分布，桶：1/5/10/25/50/100/250/500/1000/2500/5000 ms |

**按路由下钻**：这些黄金信号都带一个 `route` 标签，值取自
`ctx.route_template`（**匹配到的模式**，如 `/orders/{id}`，不是带 id 的原始
path——否则基数会爆）。未匹配/404 归入 `route="__unmatched__"`。基数有硬上限
（`ProductionConfig.max_route_series`，默认 64），超出的值统一落入
`route="__other__"`，所以动态标签永远不会把抓取或内存撑爆。

```promql
# 哪个接口在慢 / 在报错
histogram_quantile(0.95, sum(rate(http_request_duration_milliseconds_bucket[5m])) by (le, route))
topk(5, sum(rate(http_responses_5xx_total[5m])) by (route))
```

**基数纪律（多租户场景必须守）**：`route` 之外的维度**一律不要**直接打标签——
`tenant_id`/`user_id`/`order_id` 这类高基数值会把 Prometheus 打死（每个租户一条序列，
几千租户 = 几十万条）。需要分租户看时：

- 用**已受限基数**的 `createCounterFamily` / `createHistogramFamily`（超出 `max_series`
  统一进 `__other__`，见上文），并且只用于**小集合**（如"大客户"白名单）；
- 或把租户维度留给日志/追踪（trace id 已由 `tracingMiddleware` 注入），指标只留聚合。
- **禁止**：`metrics.createCounter("http_requests_total_v2", ...)` 里塞租户名、
  或在 label 值里拼 `user-123` —— 这类写法在评审里应当直接打回。

真要按租户分流，正确做法是**每租户一个实例/分片**（把基数变成部署维度），
而不是把它压进标签。

### 业务面黄金信号（静默失败的高发区）

HTTP 指标正常 ≠ 系统正常。outbox 停止投递、连接池打满这类故障在 HTTP 层面
完全看不到：

```zig
// 1) outbox：积压 / 投递 / 死信（OutboxConsumer 自带后台轮询）
var consumer = zigmodu.outbox.OutboxConsumer.init(allocator, &backend, .{}, ctx, handler);
try consumer.setMetrics(profile.prometheus.?);   // selected/delivered/failed + pending
try consumer.startPolling(io, 1000);             // 每秒一批，取代手工 cron
defer consumer.stopPolling();
// 告警：outbox_pending 持续增长 = 消费停摆；outbox_failed_total 增长 = 死信

// 2) 连接池 + 其它"抓取时采样"的 gauge：不需要后台线程
const pool_active = try metrics.createGauge("db_pool_active", "Active pooled DB connections");
const pool_waiters = try metrics.createGauge("db_pool_waiters", "Requests waiting for a DB connection");
metrics.setScrapeHook(struct {
    fn sample(ud: ?*anyopaque) void {
        const db: *data.Client = @ptrCast(@alignCast(ud.?));
        if (db.poolMetrics()) |pm| {           // null = 未启用池
            pool_active.set(@floatFromInt(pm.current_active));
            pool_waiters.set(@floatFromInt(pm.current_waiters));
        }
    }
}.sample, &db);
// 告警：db_pool_waiters > 0 持续 1 分钟 = 池已饱和，延迟即将整体抬升
```

完整可抄版本见 [`../examples/zmsaas/backend/src/main.zig`](../examples/zmsaas/backend/src/main.zig)。

业务指标自己加（同一个 registry）：`profile.prometheus.?.createCounter(...)`；
需要按维度拆分时用 `createCounterFamily` / `createHistogramFamily`
（同样受基数上限保护）。

## 3. PromQL 速查

```promql
# 流量（QPS，5m）
sum(rate(http_requests_total[5m]))

# 5xx 错误率（服务端视角）
sum(rate(http_responses_5xx_total[5m]))
  / clamp_min(sum(rate(http_requests_total[5m])), 0.001)

# 4xx 比率（客户端错，通常不报警，但异常升高说明客户端/鉴权在变）
sum(rate(http_responses_4xx_total[5m]))
  / clamp_min(sum(rate(http_requests_total[5m])), 0.001)

# 延迟 P95 / P99（直方图）
histogram_quantile(0.95, sum(rate(http_request_duration_milliseconds_bucket[5m])) by (le))
histogram_quantile(0.99, sum(rate(http_request_duration_milliseconds_bucket[5m])) by (le))

# 平均延迟
sum(rate(http_request_duration_milliseconds_sum[5m]))
  / clamp_min(sum(rate(http_request_duration_milliseconds_count[5m])), 0.001)
```

## 4. 告警阈值（起点，按真实 SLO 校准）

| 告警 | 表达式（示例阈值） | 处置 |
|------|--------------------|------|
| 服务不可用 | `up{job="zigmodu"} == 0` for 1m | 看 supervisor 重启原因；接 `zmodu.panicHook` 的 stderr |
| 5xx 燃烧 | 5xx 率 > 1% for 5m（或 > 5% for 1m 立即） | 查 trace/日志；必要时回滚 |
| 高延迟 | P95 > 500ms for 10m | 查 DB/下游；确认不是连接池耗尽 |
| 4xx 突增 | 4xx 率 > 基线 3 倍 for 10m | 常见于鉴权批量失效、客户端版本问题 |
| 无流量 | `sum(rate(http_requests_total[5m])) == 0`（营业时段） | 上游/LB/健康检查配置问题 |
| 存活但未就绪 | `up == 1` 且 readiness 非 200 | 依赖（DB/Redis）故障 |

> 三条最该先上的：`up`、5xx 率、P95 延迟。其余按业务补。

## 5. Prometheus 抓取配置

```yaml
scrape_configs:
  - job_name: zigmodu
    metrics_path: /metrics
    scrape_interval: 15s
    static_configs:
      - targets: ["orders-api-1:8080", "orders-api-2:8080"]
```

K8s 用注解式发现：

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/path: "/metrics"
  prometheus.io/port: "8080"
```

## 6. Grafana

导入 [`grafana/zigmodu-overview.json`](grafana/zigmodu-overview.json)
（Grafana → Dashboards → Import → 上传 JSON，数据源选 Prometheus）。
面板：QPS、5xx 错误率、4xx 比率、P50/P95/P99 延迟、状态码分类堆叠、总请求数。

## 7. 日志与追踪

- 访问日志与 trace id 由 `productionProfile` 默认接好（`tracingMiddleware` 注入
  `x-trace-id` 并记录耗时），响应头带 trace id 以便与日志关联。
- OTLP 导出（可选）：`zmodu.observability.OtlpExporter`，`http(s)://` 均支持
  （HTTPS 走系统信任库）。接 collector 后 trace 与指标可在同一后端关联。
- **panic 归因**：应用 root 加 `pub const panic = zmodu.panicHook;`，panic 时
  stderr 会先打印"正在处理哪个请求"，再输出标准堆栈。详见
  [`BEST_PRACTICES.md`](BEST_PRACTICES.md)「韧性」。

## 8. 上线前自检

1. `curl -s localhost:8080/metrics | head` 有 `http_requests_total` 等序列。
2. `curl -s localhost:8080/health/live` → 200 `UP`；`/health/ready` → 200。
3. Prometheus `up == 1`；Grafana 面板有曲线。
4. 至少有 `up`、5xx 率、P95、`outbox_pending`、`db_pool_waiters` 五条告警在跑。
5. 压测一次：`zig build soak`（跨租户泄漏断言）+ 自己的业务压测脚本。
   CI 里已挂 **夜间 soak**（`schedule` 每天 03:17 UTC + 手动触发，
   `-Dsoak-clients=64 -Dsoak-iterations=200`），本地用默认规模即可。
