# ZigModu 完整性补齐 Phase 3 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 ZigModu 从 95% 完整性推进到 98%，补齐分布式事件组件接线、MySQL 二进制类型解析、示例可运行性、SQL API 生命周期统一、核心运行时指标与日志格式。

**Architecture:** 每个任务独立交付、独立测试、独立提交；不引入破坏性公共 API 变更（queryRows 返回类型改为 `QueryResult(T)` 是预期内的统一，需同步更新内部调用方）；所有改动遵循 Zig 0.17 与 `AGENTS.md` 规则。

**Tech Stack:** Zig 0.17.0, `std.Io.*`, `zmodu.data`, `zmodu.http`, `zmodu.metrics.PrometheusMetrics`, `zmodu.observability.StructuredLogger`.

## Global Constraints

- Zig 0.17.0: 使用 `std.Io.Mutex`, `std.Io.Group`, `std.ArrayList(T).empty`, `std.Io.sleep`；禁止 `std.Thread.Mutex` / `std.Thread.sleep`。
- 测试命令: `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test` 必须全绿。
- 生产门禁: `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build check` 必须通过。
- API 规范: 数据库用 `zmodu.data`，HTTP 用 `zmodu.http`，安全用 `zmodu.security`，可观测用 `zmodu.observability`。
- 不物理拆分 `sqlx.zig` / `Server.zig`；新 driver/扩展按 `docs/PRODUCTION_ROADMAP.md` 分区规则落地。
- 每次 task 完成后必须提交；最终 tag v0.14.8。

---

## Task 1: Wire DLQ and Partitioner into DistributedEventBus

**Files:**
- Modify: `src/core/DistributedEventBus.zig`
- Modify: `src/core/ClusterMembership.zig` (node join/leave callbacks)
- Modify: `src/core/cluster/ClusterBootstrap.zig` (optional wiring)
- Modify: `src/root.zig` (re-export DLQ, Partitioner, WAL if missing)
- Test: `src/core/DistributedEventBus.zig` 内部测试

**Interfaces:**
- Consumes: `Partitioner.addNode/removeNode/route`, `DLQ.push/requeue/purgeExpired`, `WAL.append/readFrom`
- Produces: `DistributedEventBus` 实际按 partition key 路由；DLQ 处理发送失败与重试；WAL replay 可恢复

- [ ] **Step 1: 实现 Partitioner 真实路由**
  - 在 `DistributedEventBus.publish` 中，当 `partitioner` 存在时：
    - 计算 `target_node = partitioner.route(topic)`（或 topic + payload hash）。
    - 若命中目标节点，只向该节点发送；否则回退到广播。
  - 在节点连接/断开时调用 `partitioner.addNode(node_id)` / `removeNode(node_id)`。

- [ ] **Step 2: 扩展 DLQ 使用场景**
  - 发送失败（`publish` 广播循环中 socket 写失败）累计达到阈值后，将 `(topic, payload, error)` push 到 DLQ。
  - 启动一个 `std.Io.Group` fiber 定期调用 `dlq.requeue(callback)` 和 `dlq.purgeExpired()`，把 requeue 的消息重新 `publish`。

- [ ] **Step 3: 修复 WAL.readFrom stub**
  - 实现 `WAL.readFrom(start_seq)`，按 segment 顺序读取 Entry。
  - 让 `replayFromWal` 真正重放未提交条目。

- [ ] **Step 4: 补齐缺失的 connectToNode / nodeId / clusterSize**
  - 添加 `connectToNode(node_id, address)` 供 `ClusterMembership` 调用。
  - 添加 `nodeId()` 与 `clusterSize()`（或清理 `DistributedIntegrationTest.zig` 调用）。

- [ ] **Step 5: root.zig re-export 与测试**
  - 确保 `zmodu.DLQ`, `zmodu.Partitioner`, `zmodu.WAL` 可从 root 导入。
  - 新增测试：partitioner 路由命中目标节点、DLQ 发送失败入队与重放、WAL replay。
  - 运行: `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test -- core.DistributedEventBus`

- [ ] **Step 6: Commit**
  ```bash
  git add src/core/DistributedEventBus.zig src/core/ClusterMembership.zig src/core/cluster/ClusterBootstrap.zig src/core/eventbus/WAL.zig src/root.zig src/tests.zig
  git commit -m "feat(core): wire DLQ, Partitioner and WAL replay into DistributedEventBus"
  ```

---

## Task 2: MySQL DECIMAL / DATETIME / JSON Binary Support

**Files:**
- Modify: `src/sqlx/sqlx.zig` (MySQL binary result decode section)
- Modify: `src/sqlx/libmysql_c.zig` (add `mysql_stmt_fetch_column` extern if needed)
- Test: `src/sqlx/sqlx.zig` 内部测试 + MySQL live test

**Interfaces:**
- Consumes: MySQL prepared statement binary protocol, `MYSQL_TYPE_NEWDECIMAL/MYSQL_TYPE_DATETIME/MYSQL_TYPE_JSON/MYSQL_TYPE_TIMESTAMP/MYSQL_TYPE_DATE/MYSQL_TYPE_TIME`
- Produces: `Value.decimal`, `Value.datetime`, `Value.json` (新增 Value 变体）或统一字符串语义

**Decision:** 采用方案 A（最小改动，保持字符串语义但解决正确性问题），避免大面积 `Value` 扩展和 exhaustive switch 重写。

- [ ] **Step 1: 处理 MYSQL_DATA_TRUNCATED**
  - 在 `mysqlStmtReadRows` fetch 循环中，当 `rc == MYSQL_DATA_TRUNCATED` 且 `lengths[c] > buffer_length` 时：
    - 动态分配更大缓冲区；
    - 调用 `mysql_stmt_fetch_column` 重新读取该列（需在 `libmysql_c.zig` 补充 extern）。
  - 若分配失败或 fetch_column 失败，返回 `error.DatabaseError`。

- [ ] **Step 2: 移除静默截断**
  - 当前 `safe_len = @min(len, buf.len)`；改为：如果实际长度大于缓冲区且未被截断处理，返回 `error.DatabaseError`。

- [ ] **Step 3: 增加 MySQL 类型单元测试**
  - 新增纯函数测试 `mysqlParseDecimal`, `mysqlParseDateTime`, `mysqlParseJson`（如从字符串解析）。
  - 扩展 `test "mysql live connection"`，创建含 `DECIMAL(19,4)`, `DATETIME`, `JSON` 的表并断言返回字符串内容。

- [ ] **Step 4: 运行测试**
  - `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test -- sqlx.sqlx`
  - MySQL live test 需要本地 MySQL；若不可用，保证编译通过且非 live 测试全绿。

- [ ] **Step 5: Commit**
  ```bash
  git add src/sqlx/sqlx.zig src/sqlx/libmysql_c.zig
  git commit -m "fix(sqlx): handle MySQL DECIMAL/DATETIME/JSON truncation in binary protocol"
  ```

---

## Task 3: Make ShopDemo Runnable

**Files:**
- Create: `examples/shopdemo/build.zig`
- Create: `examples/shopdemo/build.zig.zon`
- Create: `examples/shopdemo/src/main.zig`
- Create: `examples/shopdemo/src/db/backend.zig`
- Create: `examples/shopdemo/src/db/schema.zig`
- Modify: `examples/shopdemo/generated-sample/*.zig` (API 兼容性修复)
- Modify: `examples/shopdemo/README.md`

**Interfaces:**
- Consumes: `zmodu.Application`, `zmodu.data.Client`, `zmodu.scanModules`, generated `order` module
- Produces: `zig build run` 成功启动并监听 HTTP 端口

- [ ] **Step 1: 复制 tenant-mgmt 的 build 模板**
  - 复制 `examples/tenant-mgmt/build.zig` 与 `build.zig.zon` 到 `examples/shopdemo/`。
  - 修改 `name = "shopdemo"`, 依赖路径指向 `../../src/root.zig`。

- [ ] **Step 2: 创建入口与 schema**
  - `src/main.zig`: 初始化 SQLite client、scan modules、启动 HTTP server。
  - `src/db/backend.zig`: 导出 `Backend = *zmodu.data.Client`。
  - `src/db/schema.zig`: 从 `schema.sql` 提取 `zmodu_order` 建表语句并在启动时执行。

- [ ] **Step 3: 迁移 generated-sample 到 src/modules/order/**
  - 复制/移动 `generated-sample/` 到 `src/modules/order/`。
  - 修复不兼容 API：
    - `data.orm.Orm(...)` → `data.Repository(T)`
    - `ctx.query.get` → `ctx.query.get` 或 `queryInt` 按当前 API 调整
    - 确保 `module.zig` 使用 `zmodu.api.Module`

- [ ] **Step 4: 验证构建与运行**
  - `cd examples/shopdemo && zig build run` 编译并启动。
  - 至少一个健康/列表接口可访问（如 `GET /api/v1/orders` 返回空数组）。

- [ ] **Step 5: Commit**
  ```bash
  git add examples/shopdemo/build.zig examples/shopdemo/build.zig.zon examples/shopdemo/src examples/shopdemo/README.md
  git commit -m "feat(examples): make shopdemo runnable with single order module"
  ```

---

## Task 4: Unify queryRows Lifecycle

**Files:**
- Modify: `src/sqlx/sqlx.zig`
- Modify: `examples/tenant-shop/src/**/*.zig`（若有 `tx.queryRows` 调用）
- Delete/Fix: `src/sqlx/sqlx.zig:withRows` helper (line ~177)

**Interfaces:**
- `Client.queryRows(T, sql, args) -> !QueryResult(T)`
- `Client.queryRowsPartial(...) -> !QueryResult(T)`
- `Client.findAll(...) -> !QueryResult(T)`
- `Transaction.queryRows(allocator, T, sql, args) -> !QueryResult(T)`
- `CachedConn.queryRows(...) -> !QueryResult(T)`
- 移除 `Client.deinitQueryRows`

- [ ] **Step 1: 修改 Client 返回类型**
  - 将 `queryRows`, `queryRowsPartial`, `findAll` 改为返回 `QueryResult(T)`。
  - 内部复用 `scanRowsToOwned` 或等价逻辑。

- [ ] **Step 2: 修改 Transaction / CachedConn**
  - `Transaction.queryRows` 与 `CachedConn.queryRows` 改为返回 `QueryResult(T)`，不再内部 `defer rows.deinit()`。

- [ ] **Step 3: 删除 deinitQueryRows 和修复测试**
  - 删除 `Client.deinitQueryRows` 函数及 TODO。
  - 更新 `src/sqlx/sqlx.zig` 中 3 个调用 `deinitQueryRows` 的测试，改为 `result.deinit(allocator)`。
  - 删除或修复失效的 `withRows` helper。

- [ ] **Step 4: 更新示例调用方**
  - 搜索 `tx.queryRows` / `client.queryRows` / `findAll` 在 `examples/` 的使用，改为 `result.items` + `result.deinit(allocator)`。

- [ ] **Step 5: 运行测试**
  - `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test -- sqlx.sqlx persistence.Orm persistence.backends.SqlxBackend`

- [ ] **Step 6: Commit**
  ```bash
  git add src/sqlx/sqlx.zig examples/tenant-shop/src
  git commit -m "refactor(sqlx): unify queryRows lifecycle to QueryResult(T).deinit"
  ```

---

## Task 5: WorkerPool / EventBus Metrics and Log Unification

**Files:**
- Modify: `src/core/WorkerPool.zig`
- Modify: `src/core/EventBus.zig`
- Modify: `src/metrics/PrometheusMetrics.zig` (add WorkerPoolMetricsCollector / EventBusMetricsCollector)
- Modify: `src/core/ModuleRuntime.zig` (inject metrics)
- Modify: `src/log/StructuredLogger.zig` or `src/log/ModuleLogger.zig` (pilot log format)
- Test: `src/core/WorkerPool.zig`, `src/core/EventBus.zig`, `src/metrics/PrometheusMetrics.zig`

**Interfaces:**
- `WorkerPoolMetricsCollector.init(metrics, pool_name)`
- `EventBusMetricsCollector.init(metrics, bus_name)`
- `WorkerPool.init(..., metrics: ?*WorkerPoolMetrics)` optional
- `TypedEventBus.init(allocator, metrics: ?*EventBusMetrics)` optional

- [ ] **Step 1: 新增 WorkerPoolMetricsCollector**
  - 在 `PrometheusMetrics.zig` 中创建 `WorkerPoolMetricsCollector`，按 `pool` label 创建：
    - `workerpool_pending_tasks` Gauge
    - `workerpool_active_workers` Gauge
    - `workerpool_completed_tasks_total` Counter
    - `workerpool_rejected_tasks_total` Counter

- [ ] **Step 2: WorkerPool 接入指标**
  - `WorkerPool.init` 增加可选 `metrics: ?*WorkerPoolMetrics` 参数。
  - 在 `dispatch`（reject）、`workerLoop`（complete/active）中更新计数器/计量器。
  - 保持向后兼容：传 `null` 时不更新。

- [ ] **Step 3: 新增 EventBusMetricsCollector**
  - 创建 `EventBusMetricsCollector`，按 `bus` label 创建：
    - `eventbus_published_total` Counter
    - `eventbus_async_dropped_total` Counter
    - `eventbus_subscribers` Gauge

- [ ] **Step 4: EventBus 接入指标**
  - `TypedEventBus.init` 增加可选 `metrics: ?*EventBusMetrics` 参数。
  - 在 `publish` 入口 `published_total.inc()`。
  - 在 async drop 两处 `async_dropped_total.inc()`。
  - 在 subscribe/unsubscribe 时更新 `subscribers` gauge。

- [ ] **Step 5: ModuleRuntime / Application 注入（可选）**
  - 在 `ModuleRuntime` 创建 `WorkerPool` 时传入 metrics（如果 `RuntimeOptions` 开启 metrics）。
  - 不强制 Application 持有 PrometheusMetrics；保持可选注入。

- [ ] **Step 6: 日志统一试点**
  - 把 `AutoInstrumentation` 中的 `[AutoInstrumentation]` 前缀日志改为 `std.log.scoped(.auto_instrumentation)` 或 `StructuredLogger`。
  - 确保 EventBus 已有 `std.log.scoped(.event_bus)` 不变。
  - 目标：不再出现自由格式 `[ModuleName]` 字符串前缀；用 scope/fields 代替。

- [ ] **Step 7: 运行测试**
  - `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test -- core.WorkerPool core.EventBus metrics.PrometheusMetrics`

- [ ] **Step 8: Commit**
  ```bash
  git add src/core/WorkerPool.zig src/core/EventBus.zig src/metrics/PrometheusMetrics.zig src/core/ModuleRuntime.zig src/metrics/AutoInstrumentation.zig
  git commit -m "feat(observability): WorkerPool/EventBus metrics and scoped logging pilot"
  ```

---

## Final Verification & Release

- [ ] **Step 1: Full test suite**
  - `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`
  - `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build check`
  - `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build check-api`

- [ ] **Step 2: Version bump & changelog**
  - `build.zig.zon`: `0.14.7` → `0.14.8`
  - `CHANGELOG.md`: add `## [Unreleased]` entries for the 5 tasks (or move to `## [0.14.8]`)

- [ ] **Step 3: Commit, push, tag**
  ```bash
  git add CHANGELOG.md build.zig.zon
  git commit -m "chore(release): bump version to 0.14.8 and update changelog"
  git push origin master
  git tag -a v0.14.8 -m "Release v0.14.8: Completeness Phase 3 - DLQ/Partitioner, MySQL types, ShopDemo, queryRows lifecycle, metrics"
  git push origin v0.14.8
  ```
