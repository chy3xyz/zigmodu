# ZigModu 生产级路线图（修订版）

**版本口径**: v0.15.41 · Zig 0.17.0  
**最后更新**: 2026-08-27  
**原则**: `sqlx.zig` / `Server.zig` **不物理拆分**；用分区注释 + 冻结边界 + 测试门禁维持可维护性。

---

## 阶段总览

| 阶段 | 状态 | 内容 |
|------|------|------|
| 1 | ✅ 已完成 | 编译恢复、版本/CI 统一、`zig build test` 全绿 |
| 2 | ✅ 已完成 | P0：JWT 生命周期、EventBus、ConnPool、Row arena、mutex deinit |
| 3 | ✅ 已完成 | API 收敛：canonical domain import，deprecated 隔离 |
| **4** | **选做（默认跳过）** | **冻结大文件 + 分区文档 + 维护边界（见下文）** |
| 5 | ✅ 已完成 | 集成/压测/安全测试 + CI 两档（smoke / full） |
| 6 | ✅ 已完成 | README/评估报告/示例与宣传对齐 |
| **7** | **✅ 已完成** | **JWT 统一 + AppSecurity + tenant-mgmt 真 JWT + CI token 生成** |
| **8** | **✅ 已完成** | **评估 v5 (~95/100) + 多租户可选架构文档** |
| **9** | **规划中** | **高阶传输(gRPC streaming/HTTP/2)、分布式容错(Raft 快照/Saga恢复)、Tooling与OTLP观测** |

**验收基线（当前已达成）**

```bash
zig build
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test   # 961/981 passed, 20 skipped（计数以 AGENTS.md 为准）
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build check-api
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build check
bash scripts/ci-integration.sh   # tenant-mgmt + http-stress-test（需 curl）
```

---

## 多租户：可选，非强制

框架核心不假设多租户。`TenantContext` / `ShardRouter` / `DataPermission` 位于可选层；`examples/basic` 为零租户配置，`examples/tenant-mgmt` 为完整 SaaS 演示。详见 `docs/ARCHITECTURE.md` § Multi-Tenancy (Optional)。

---

## 阶段 4（修订）：不拆分，只设边界

### 为何不做物理拆分

- 单文件不影响运行时正确性；近期 P0 与测试覆盖收益更大。
- 拆分 import 面大、短期回归风险高，与「先稳再优」冲突。
- 文件内已有 § 分区；配合边界规则足够支撑 9 分级工程成熟度。

### 何时才重新考虑拆分

仅当 **同时** 出现：

- 同一文件多人每周多次 merge 冲突；
- 单次 PR  routinely >300 行且跨 ≥2 个 § 分区；
- 新 driver / 新传输层**无法**按边界规则落在新文件。

届时按现有 § 注释**一次性**抽出，不做渐进碎裂。

---

## `src/sqlx/sqlx.zig` 维护边界

**定位**: 唯一 SQLx 实现入口；`zmodu.data` / `SqlxBackend` 通过此文件或 `sqlx/` 子目录（非 sqlx.zig 本体）接入。

| § 分区 | 行号约 | 允许修改 | 禁止 / 必须新建文件 |
|--------|--------|----------|---------------------|
| §1 Types | 顶 ~170 | bugfix、Zig 0.17 API 适配 | 新 Value 变体 → 评估是否属 ORM 层 |
| §2 SQLite | ~364 | driver bug、stmt 缓存、绑定 | 新 SQLite 扩展 API → `sqlx/sqlite_ext.zig` |
| §3 Postgres | ~565 | 同上 | 新 PG 特性 → `sqlx/postgres_ext.zig` |
| §4 MySQL | ~989 | 同上 | 新 MySQL 特性 → `sqlx/mysql_ext.zig` |
| §5 PreparedStmt | ~1198 | stmt 生命周期、reset/clear | — |
| §6 ConnPool | ~1477 | 池化语义、健康检查 | 新池策略 → `pool/Pool.zig` 或新文件 |
| §7 Client | ~1623 | query/exec/tx 路径 | **新公开 Client 方法** 先在 `data.zig` 设计再落码 |
| §8 Transaction | Client 内 | savepoint、rollback | — |
| §9 ORM scan | ~171 | scanStruct、类型映射 | **新 ORM 能力** → `sqlx/orm.zig`（已存在则扩该文件） |
| §10 Tests | ~2714 | 回归测试 | 集成级 DB 测试 → `src/tests.zig` 或 examples |

**硬规则**

1. **单 PR 仅触一个 §**（跨 § 需拆 PR 或明确 P0 理由）。
2. **新数据库 driver**：新文件 `sqlx/<name>_conn.zig` + `sqlx.zig` 仅加 VTable 注册与 re-export。
3. **禁止**在 sqlx.zig 增加与 HTTP、租户、缓存无关的业务逻辑。
4. 修改 ConnPool / Row arena / stmt 复用路径时，**必须**跑全量 `zig build test`。
5. **选择性链接**：用 `build_options.enable_*` + `sqlx/*_c_stub.zig` + `examples/_shared/db_link.zig`；**不要**为减体积拆 `sqlx.zig`。默认 `-Ddb=all`；消费者与测试约定见 [SQLX_DRIVERS.md](SQLX_DRIVERS.md)。

---

## `src/api/Server.zig` 维护边界

**定位**: HTTP Server 唯一实现；对外经 `http.zig` → `zmodu.http` 暴露。

| 逻辑块 | 约行 | 允许修改 | 禁止 / 必须新建文件 |
|--------|------|----------|---------------------|
| Method / Route / RouteGroup | 顶 ~147 | 路由注册 API | — |
| Context | ~172 | 请求/响应、arena、bindJson | 新业务 DTO → 各 module 的 `api.zig` |
| StreamReader / ParsedRequest | ~605 | 解析 bug、keep-alive | — |
| TrieNode / Router | ~790 | 匹配、wildcard、params | — |
| writeResponse / Server | ~1121 | 监听、graceful drain | — |
| connFiber / 升级 WS | ~1387 | I/O 生命周期 | **新 WS 协议** → `im/` 或 `extensions/WebSocket.zig` |
| deepCopy / 测试 | 末段 | 回归 | E2E → `examples/` 或 IntegrationTest |

**硬规则**

1. **Middleware 新种类**：实现放在 `Middleware.zig`，Server 只保留链式调度 hook。
2. **禁止**在 Server.zig 写 SQL、租户过滤、JWT 签发（已在 `Middleware.zig` / `security`）。
3. **PathRewriter / compat** 仅做路径重写，不嵌入业务路由表。
4. 修改 `Context.deinit` / `setHeader` / `connFiber` 时，**必须**跑 `api.Server` 与 `api.Middleware` 相关测试。
5. **单 PR 行数**: 建议 <150 行；超过需说明所属逻辑块且不分 cross 块重构。

---

## 阶段 3 / 5 / 6 简要

### 阶段 3 — API 收敛 ✅

- [x] 应用代码统一 `zmodu.http` / `zmodu.data` / `zmodu.security` / `zmodu.observability`（示例已迁移）。
- [x] `src/deprecated.zig` 集中 flat 别名；`root.zig` re-export；**计划 v0.14.0 移除**。
- [x] `ctx.json` 为首选响应；`sendSuccess/sendFail` 保留 compat（`Server.zig` 已标 DEPRECATED）。
- [x] `docs/API-MIGRATION.md` § Domain Import Convergence。

### 阶段 5 — 测试升级 ✅

- [x] CI smoke：`zig build test` + `zig build check-api`（`scripts/ci-smoke.sh`）。
- [x] CI full（main push）：`integration-full` job → `scripts/ci-integration.sh`（tenant-mgmt health/dashboard/401 + http-stress-test）。
- [x] 安全单测：JWT 有效/篡改/过期、CSRF 双提交、SQL 参数化防注入；`jwtAuth` 校验 `exp` + 小写 header 键。

### 阶段 6 — 文档与示例 ✅

- [x] 更新 `docs/EVALUATION_REPORT.md` v4（v0.13.15 / Zig 0.17 / 413 tests）。
- [x] 旗舰示例 `examples/tenant-mgmt/`；README / examples 索引中 shopdemo 标为 codegen 参考。
- [x] `CLAUDE.md` / `AGENTS.md` 同步 Zig 0.17 与 v0.13.15。

### 阶段 9 — 高阶演进与深度改进路线 (演进中)

1. **数据库层高阶优化 (✅ 已落地)**
   - **MySQL 二进制协议类型适配**：补全 `NEWDECIMAL`, `DECIMAL`, `JSON`, `DATETIME`, `TIMESTAMP`, `DATE`, `TIME`, `ENUM`, `SET` 等二进制 prepared statement 精确解析与 `Value` 映射。
   - **内存生命周期安全管理**：引入 `ManagedRows` RAII 自动释放封装与 `withRows` 作用域闭包，消除长连接与高 QPS 查询内存泄露风险。
   - **连接池 ConnPool 可观测度与指标**：增加 `active_count`, `idle_count`, `creation_count`, `eviction_count`, `total_wait_time_ms`, `timeout_count` 指标统计与 `pool.stats()` 接口。
2. **Modulith QPS 横向扩展与高并发控流 (✅ 已落地)**
   - **WorkerPool & Runtime 实时度量**：支持 `pending_count`, `active_workers`, `completed_tasks`, `rejected_tasks`, `utilization_pct` 等指标捕获与 `wp.stats()`。
   - **Redis 分布式限流降级保护**：`RedisRateLimiter` 实现 `allowWithFallback` 容灾逻辑，断连或异常时无缝降级至本地 `RateLimiter` 兜底。
   - **级联背压 (Cascade Backpressure)**：在 `ModuleRuntime.tryEnter` 中整合 WorkerPool 载重检测（>90% 满载时实现快速拒绝，保护系统不雪崩）。
3. **全链路可观测性 (Observability) 升级 (✅ 已落地)**
   - **OpenTelemetry (OTLP) Exporter**：`src/tracing/OtlpExporter.zig` — JSON 序列化 + **`exportSpans` OTLP/HTTP POST**（重试 429/5xx；`https://` 明确 `OtlpTlsNotSupported`）。
   - **在 `observability.zig` 导出**：`OtlpExporter`；live 用例需 `OTLP_ENDPOINT`。
4. **工具链与生成器集成 (zmodu CLI) (✅ 已落地)**
   - **`zmodu` 独立 CLI 集成**：编写 [`docs/ZMODU_CLI_INTEGRATION.md`](ZMODU_CLI_INTEGRATION.md)，打通 SQL DDL Schema 一键构建 `@initialized` 模版工程，全量支持 MCP Server 与 Modulith 六层分层生成。
5. **协议传输层高阶演进 (gRPC Streaming & HTTP/2)** — **本轮加深（出站合并写 + GOAWAY/RST 隔离）**
   - HTTP/2：WINDOW_UPDATE + SETTINGS + **PRIORITY 依赖树** + **加权 fair 出站**（deficit WRR；有更多入站缓冲时 slice drain，阻塞读前 drainAll）+ **ConnWriter 32KiB 合并写** + **完整 GOAWAY/RST** + **pending 出站上限**（流级错误 RST，不杀连接）+ h2c Upgrade（共享 StreamReader）
   - Kafka：`cooperative_sticky` + **`applyCooperativeAssignment` / `acknowledgeRevocation` 两阶段**（revoking → stable）
   - TLS：sidecar ALPN（`Http2Tls`）；进程内 TLS server 仍待 Zig stdlib
   - CI：tenant-mgmt + stress + shopdemo smoke；H1/h2c 对比脚本 `scripts/bench_h1_h2.py`
   - 仍后续：H2 吞吐进一步对齐 H1（HPACK/alloc 池）、进程内 TLS、cooperative 与 broker 完整 revoke 往返

### 决策记录：gRPC「一等公民」≠ modulith 近期投入

**结论（2026-08）：维持「能力预留 + 文档定位」，不做 TLS 主路径/网关/生态一等公民化。**

gRPC 的价值与**通信距离**成正比，modulith 的核心通信都在**进程内**：

| 场景 | modulith 现实 | gRPC 价值 |
|------|--------------|:--------:|
| 模块间调用 | 直接调用 / EventBus / outbox，不走网络 | ❌ 纯序列化开销 |
| 单体多副本扩展 | 共享 DB / Redis / 队列，无服务间 API | ❌ 不需要 |
| 对外 REST | 已有一等 HTTP/1.1 + h2c | 低（生态/代理友好性 REST 更优） |
| **演进拆分出口** | 拆分后才出现服务间契约 | ✅ **唯一高价值点，但发生在后期** |

**现状**：h2c + unary/stream 四态 + HTTP/2 priority 已在（阶段 5 ✅）——缺的是"一等公民"包装。拆分时真正的瓶颈是**数据归属/事务边界**（saga 等，阶段 6 已铺垫），协议反而是最简单的部分。

**三档投入策略**：
- **保持（推荐，≈0 成本）**：现有能力不退化；`TLS：sidecar ALPN` 维持现状（进程内 TLS 待 Zig stdlib）
- **验证（中成本）**：出现实际拆分计划时，补一个"拆分为两个 gRPC 服务"示例证明出口可行
- **一等公民（高成本）**：**暂缓**——TLS 主路径 + 网关 + 生态对齐，等拆分需求出现再启动

### 下一阶段 backlog（2026-08-11 评估）

**P0（阻塞）**
- CI 系统性 0s failure（8-03 起 260+ run）——分支 bug 已修（master），仍需
  GitHub Actions 服务端排查（禁用/配额）；测试基建依赖 CI/独立 runner。

**已完成（2026-09 加固批次）**
- ✅ 连接级背压 `max_connections` / `over_limit_response` + header 阶段 deadline
  `header_timeout_ms`（slowloris）；环境变量 `HTTP_MAX_CONNECTIONS` /
  `HTTP_HEADER_TIMEOUT_MS`。
- ✅ 生产一键配置 `http.productionProfile`（背压 + 中间件 + `/metrics` 黄金信号
  + `/health/*`），顺序约束见 `ROUTE_TABLE.md` §7.4。
- ✅ WS 出站背压 `ws_write_timeout_ms`（`SO_SNDTIMEO`）+ `WsFramer.isWritable()`。
- ✅ 并发浸泡测试 `zig build soak`；沙箱隔离 `-Dnet-tests=false`。
- ✅ 观测闭环：`docs/OBSERVABILITY.md` + `docs/grafana/zigmodu-overview.json`。
- ✅ 部署参考拓扑 `examples/production-deploy/`（nginx/Envoy/k8s/systemd）。
- ✅ 韧性三件套：`FrozenMap` / `panicHook` / audit b19–b22。
- ✅ 启动预检 `Preflight`（env / 占位 secret / DB / 待应用迁移 / 时钟）；
  JWT `kid` 轮换（`JwksKeyRing` + `setKeyring`，未知 kid 拒绝）；CORS 通配符告警。
- ✅ 业务面可观测：outbox 积压/投递指标 + 内置轮询、DB 池指标、抓取时采样钩子、
  指标按 `ctx.route_template` 受限基数打标签。
- ✅ 故障注入测试（熔断/限流走完整 HTTP 链路）与契约门禁模板
  （`src/test/FaultInjection.zig` · `src/test/ContractGate.zig`）。
- ✅ `DistributedLock` 的 `.postgres` 方言在真实 PG 上验证（`ZIGMODU_TEST_PG=1`，
  CI `test-postgres` 已接入）；`.mysql` 仍待真实库验证。
- ✅ 旗舰示例 `tenant-mgmt` 改为 `productionProfile`；CI 增加夜间 soak job。

**P1（质量/正确性）**
- ConnPool 等待完整 async 化（现为 50ms 分段缓解，M:N worker 耗尽未根治）。
- libpq 非阻塞化（`PQsetnonblocking`+轮询；现 SO_RCVTIMEO 有界超时仍占 worker）。
- b17 剩余误报收敛（命名标量/多行 struct body 边界，22 处，真实泄漏已清零）。
- Migration barrel 导出（F2）→ 弃用业务侧自研 migrate.sh（已补 `pub const migration`）。

**P2（增强/按需）**
- AI 流式 tool_calls 增量组装；refresh token；Windows CI 矩阵；
  zmodu marketplace/CLI 深化。
- 待办：`src/ai` 抽独立包（前置条件见下文「`src/ai` 边界」）· 第三方独立安全审计
  （无法由框架自身完成）。

### 单进程单点与原位隔离（prefork）— 记录在案的已知边界

**现状（v0.15.36）**：整个后端是一个进程；请求由 io fiber 承载在共享 worker
池上。因此**任何请求路径上的 panic 都会终止全部在途请求**——这不是可以靠
框架代码消除的属性（Zig 的 panic 不可捕获），只能通过三层缓解：

1. **少 panic**：`zmodu audit` b19/b20/b21（请求路径裸 panic / 共享可变
   HashMap / 裸 `@alignCast`）+ `FrozenMap`（启动期填充、运行期只读）。
2. **panic 可查**：`zmodu.panicHook` 在 panic 时先输出当前请求的
   `METHOD /path`，把"进程为什么死"变成可定位事件。
3. **进程可恢复**：supervisor 重启（systemd `Restart=always`、k8s
   `restartPolicy: Always`、容器编排策略）。

**未做（本路线图的正式条目）**：**prefork 多进程**——父进程监听并 accept，
N 个 worker 子进程各自持有独立地址空间与 io 实例。届时单请求崩溃只损失一个
worker（在途连接断开并重试），其余 worker 继续服务，panic 钩子的 stderr 归属
到具体 worker pid。这是"一个 bug 只影响一个请求"的唯一结构性解法。

**前置条件（未满足，故不排期实现）**
- 子进程崩溃后的连接语义（keep-alive 断连、idempotency-key 重放的边界）需要
  与应用层约定，框架不能单方面决定。
- 共享状态需重新定义：进程内 EventBus / 内存缓存 / 连接池在 prefork 下变成
  per-worker（或必须外置 Redis/NATS），这会改变 modulith 的默认假设。
- 需要 sofile/std.Io 在 fork 后重置的验证（`std.Io.Threaded` 的线程池不可继承）。

**因此当前的官方建议**：单进程 + 无状态实例水平扩展 + 状态外置
（Postgres/Redis）+ 跨域副作用走 Outbox；把 prefork 当作"单机密度与故障
隔离"的增强项，而非可用性的必要前提。

### `src/ai` 边界：11% 行数的可剔离域

**事实（2026-09）**：`src/ai/` = 42 个文件 / 12,216 行（约占框架 11%），提供
Agent / Workflow / Skill / MCP / LLM 策略等**业务产品能力**，不是后端框架内核。

**当前边界状态（已核实并由测试守护）**：
- 四个规范域文件（`http.zig` / `data.zig` / `security.zig` / `observability.zig`）
  **零** `ai/` 引用；只有 `root.zig` 有一个惰性 `pub const ai = @import("ai/ai.zig")`。
- 由于 Zig 惰性分析，**不 import `zmodu.ai` 的消费者不会编译这 12k 行**——
  边界是结构性的，不靠纪律。回归守卫见 `src/tests.zig`
  「domain modules stay independent of the optional src/ai domain」。
- 使用者：`examples/ai-ops`、`llm-policies`、`mcp-server`、`tenant-ai` 四个示例。

**为什么仍建议最终抽成独立包**：
- 版本节奏不同：LLM/Agent 侧 API 变动快，框架侧求稳，同仓同版本号会互相拖累。
- 依赖方向不干净：AI 域天然想依赖 HTTP/Data，而后端使用者不想为不用的大块买单
  （编译时间、审计面、`docs/AI*.md` 的认知负担）。

**抽取前置条件**（未满足，故不排期）：
1. 明确 `zmodu.ai` 对核心域的依赖清单，并把它降为"仅公开 API"（不碰内部类型）。
2. 给 `ai` 定义自己的 `build.zig.zon` 与版本线，示例改为独立依赖。
3. 确认没有消费者从 `zigmodu.ai` 反向依赖框架内部（当前示例均只用公开面）。

**当下结论**：保持同仓但**守住边界**；不要往核心域加 `ai` 引用。

### 决策记录：拆分出口 = 事件契约 + outbox（对齐 Spring Modulith）

**2026-08 对照核实**：Spring Modulith 无真正分布式（无 RPC/服务发现），其演进出口是
**进程内事件 → 事务性 outbox 外部化**（`event_publication` 表 + 异步转发 Kafka/RabbitMQ/JMS，
严格 outbox 到 2.1 才引入且靠第三方 Namastack/JobRunr）。zigmodu 已原生对齐且更强：
`OutboxPublisher`（业务事务内写 `event_outbox` + 同事务提交 → 轮询投递 → retry/DLQ/多租户/三方言）+ `DistributedEventBus`（WAL + 一致哈希，Spring 没有）。

**因此拆分出口的下一步是补 outbox 治理差距（中成本，拆分前做）**：
- **显式重发 API**：按失败时间/次数策略 `resubmit()`（Spring 有
  `FailedEventPublications.resubmit()` + Staleness Monitor；zigmodu 目前只有
  retry + DLQ + `stale_threshold_seconds` 自动机制，缺手动治理入口）
- 事件契约显式边界：`@Externalized` 式 payload/routing 映射（当前 outbox 事件直接投递，
  无"内部事件 → 对外稳定契约"的映射层）
- 这两项落地后，modulith → 分布式拆分的出口即与 Spring 最佳实践完全对齐，且无需 gRPC。


6. **分布式状态机与容错增强 (✅ 已落地)**
   - **Raft Log Compaction & InstallSnapshot**：在 [`src/core/cluster/RaftElection.zig`](../src/core/cluster/RaftElection.zig) 中实现 `InstallSnapshotRequest`/`Response` 协议，提供 `compactLog` 内存裁切与 Follower 快照覆盖能力，防止 Raft 日志无限增长。
   - **Saga 事务协调器**：持续支持服务节点崩溃重启后的 WAL Recovery。



---

## 评分口径（修订）

| 维度 | 不拆分时的目标 | 说明 |
|------|----------------|------|
| 可维护性 | 8/10 | 靠 § 分区 + 边界规则，不靠文件数 |
| 正确性 | 9+/10 | 测试全绿 + P0 清零 |
| 文档可信 | 9/10 | 版本/测试数/示例一致 |
| **综合** | **≥95/100** | 阶段 1–8 已完成；多租户可选 |
