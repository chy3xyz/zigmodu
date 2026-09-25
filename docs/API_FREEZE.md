# API 冻结面 / preview 面（1.0 前）

> **一句话**：冻结面上的入口在 1.0 之前**只增不改**；`zigmodu.runtime.*` 的 preview 面**允许 breaking**。
> 门禁在 `src/test/ApiFreeze.zig`（跑在整树套件里 —— 它被 `src/tests.zig` 的聚合根 import，漏接就不会跑）。
> 本文件**只写能从证据里读出来的东西**：每条口径都标出处，每个可检查的断言都对应门禁里的一个检查。

## 口径从哪来（读的，不是发明的）

| 口径 | 出处 |
|---|---|
| 弃用别名**不早于 1.0** 删除 | `docs/UPGRADING.md:8-10`（统一口径），表在 `:12-17`、已移除记录在 `:19-32`（本文件不抄第二份） |
| `Application` / `Module` / `DI` / `EventBus` / HTTP 公开契约**只增不改** | `docs/RUNTIME.md:58`（§2 第 1–4 条见 `:37-40`，第 9 条见 `:46`） |
| `runtime.*` 在 0.x **允许 breaking** | `docs/RUNTIME.md:47-49`（§2 第 10 条）+ `:54-61`（"0.x 不破坏"不成立）；先例 `:537`（v0.28.0 删掉 `Runtime.cancelTimer(id) bool`） |
| 每次 runtime breaking 要**同时**进 §9 路线图与 `UPGRADING.md` 对应版本段 | `docs/RUNTIME.md:59-61` |
| §12 / §13 / §14 的现状口径 | `docs/RUNTIME.md:696`（Phase 2 已落地）、`:1569`（Replay v1 已实现）、`:1751`（v0.31 契约） |

**本清单的第一步"决定"（不是引用）**：把上面只点了五类的"只增不改"扩展到下表**全部**类别 —— 即 1.0 前它们都只增不改。
要缩小冻结面就删表里的行，门禁随之缩小（下面的同步测试会盯着两边）。扩充冻结面同理。

## 冻结的入口类别

冻结的是**类别与锚点**（每类的身份符号），不是逐条枚举的导出名单 —— 完整名单仍在 `root.zig` 与 `docs/API.md`，
本文件刻意不做第三份没人维护的清单。第二列的每个锚点都被 `src/test/ApiFreeze.zig` 逐条断言（`@hasDecl`，数据驱动自本表）。

| 类别 | 门禁锚点（逐条断言） | 冻结依据 |
|---|---|---|
| `zigmodu` 顶层 · 生命周期与模块契约 | `Application`, `ApplicationBuilder`, `builder`, `api`, `ModuleContext`, `ZigModuError`, `Result`, `Time`, `scanModules`, `ModuleInfo` | 引用（`RUNTIME.md:58`） |
| `域别名`（opt-in 域） | `http`, `data`, `security`, `observability`, `runtime`, `ai`, `im`, `web4`, `outbox`, `cron`, `migration`, `datapermission` | 决定（别名本身是导入缝，改名=全员编译错） |
| `http` · 路由与请求 | `http.Server`, `http.Context`, `http.RouteGroup`, `http.RouteSpec`, `http.RouteMeta`, `http.Router`, `http.CatalogSlot` | 引用（HTTP 在 `RUNTIME.md:58` 的"只增不改"名单里） |
| `http` · extractor 与错误渲染 | `http.extractPath`, `http.extractQuery`, `http.extractJson`, `http.extractJsonValidated`, `http.extractMultipart`, `http.respondErr`, `http.setErrorMap`, `http.problemReject`, `http.useRfc7807Errors`, `http.productionProfile`, `http.sse`, `http.Testkit` | 引用（同上） |
| `http` / `security` · 鉴权（Path A） | `http.jwtAuthFromCatalogWithPermissions`, `http.catalogLoaderFromTable`, `http.AuthBackend`, `http.jwtBackend`, `http.envelopeReject`, `http.permissionGateWith`, `http.tenantResolver`, `security.AppSecurity`, `security.PasswordEncoder`, `security.CatalogPermDb`, `security.JwksKeyRing` | 决定（`AGENTS.md` 把 Path A 定为默认接法；门禁只保证名字还在，签名准确性人工看） |
| `data` · 数据层 | `data.Client`, `data.Repository`, `data.SqlxBackend`, `data.CrudService`, `data.CacheManager`, `data.MigrationRunner`, `data.sqlx`, `data.redis`, `data.orm`, `data.pool` | 决定 |
| `observability` · 可观测性 | `observability.PrometheusMetrics`, `observability.DistributedTracer`, `observability.StructuredLogger`, `observability.ModuleLogger`, `observability.OtlpExporter`, `observability.LogScope` | 决定 |
| `zigmodu` 顶层 · 韧性 / 调度 / 分布式 | `CircuitBreaker`, `RateLimiter`, `Bulkhead`, `retry`, `cron`, `DistributedLock`, `Preflight`, `SagaOrchestrator`, `ClusterView`, `MembershipView` | 决定 |
| `zigmodu` 顶层 · DI / 事件 / 配置 / 工具 | `Container`, `ScopedContainer`, `EventBus`, `ThreadSafeEventBus`, `FrozenMap`, `Params`, `ConfigManager`, `TomlLoader`, `Validator`, `panicHook` | 引用（前四个在 `RUNTIME.md:58` 的名单里，其余按同一类别一并冻结） |
| `zigmodu` 顶层 · 测试辅助与扩展 | `IntegrationTest`, `Benchmark`, `ContractTestRunner`, `ModuleTestContext`, `WebSocketServer`, `PluginManager` | 决定 |

## 0.x 允许破坏的 preview 面

依据是 `docs/RUNTIME.md:47-49`（§2 第 10 条）。这里只列 §11–§14 文档点到名的符号；
"仍未做 / 明确不做"的口径在 `docs/RUNTIME.md:696-706`（§12）、`:1649`（§13.5）、`:1913`（§14.7）等处，是散文 —— **人工看**。

**可检查的推论**（门禁 `src/test/ApiFreeze.zig` 的第二个 test）：这些符号只经 `zigmodu.runtime.*` 暴露，
**不得**出现在冻结的顶层 —— 一旦 `pub const Supervision = …` 之类被加到 `root.zig`，第 10 条允许的破坏就打到了冻结面。

| preview 出处 | 门禁锚点（逐条断言） |
|---|---|
| `runtime` · §3 Worker / `Runtime` | `runtime.Runtime` |
| `runtime` · §12 WorkerPool / Scheduler | `runtime.SpawnMode`, `runtime.SpawnConfig`, `runtime.SchedulerConfig`, `runtime.ExecutionClass`, `runtime.StopPolicy`, `runtime.PrecisionTimer` |
| `runtime.recorder` · §11 / §13 EventRecorder 与 Runtime Replay | `runtime.Sequencer`, `runtime.recorder.Recorder`, `runtime.recorder.DeliveryLog`, `runtime.recorder.Replayer`, `runtime.recorder.TrackRef`, `runtime.recorder.LogStep` |
| `runtime` · §14 监督树 | `runtime.Supervision`, `runtime.Group`, `runtime.GroupPolicy`, `runtime.Intensity` |

## 弃用别名与删除时点

**不在这里抄第二份。** 表在 `docs/UPGRADING.md:12-17`，本文件只声明门禁怎么管它：

- 每一行由 `src/test/ApiFreeze.zig` 逐行断言：弃用名仍可调用、指向的"现在的名字"仍存在；
- 该行代码里的 `DEPRECATED` 标注与"指向新名"也要在（`docs/UPGRADING.md:34-37` 的规则 1）；
- **表 ↔ 门禁双向同步**：表里加一行而门禁没跟上是红，门禁里留着一行而表删了也是红。

### 已移除的记录（`docs/UPGRADING.md:19-32`）

表只承诺**还活着**的别名。已经删掉的名字进不了表 —— 给它写"不早于 1.0 删除"等于告诉读者它今天还能用；
它们记在表下方的「已移除」小节里，门禁对它们的断言方向**相反**：**不得**重新出现在顶层。

- `zigmodu.App` / `zigmodu.ModuleImpl`：随 `Simplified` 整块在 commit `557190a`（2026-05-12）从 `src/root.zig` 移除，
  替代品 `Application`。门禁断言 `@hasDecl(zmodu, …)` 为**假**（回到顶层即红），
  并断言 `src/api/Simplified.zig` 仍在树里、仍被 `src/tests.zig` 的编译门禁 import —— **只到文件级**，
  不是"整块 API 仍受支持"的承诺。记录里的名字 / commit / 文件路径三者都由门禁对照文档检查（措辞改了也要一起改）。

## 覆盖不到的部分（只能人工看）

1. **已移除的块只钉"回不到顶层"，不钉"用不了"。** `Simplified` 整块（`App` / `ModuleImpl` / `Module`）已从顶层移除
   （`docs/UPGRADING.md:19-32`）。门禁钉的是 `zigmodu.App` / `zigmodu.ModuleImpl` **不**在顶层、且 `src/api/Simplified.zig`
   仍在树上并被 `src/tests.zig` 的编译门禁 import —— 这不是"整块 API 仍受支持"的承诺：门禁**不断言**里面的签名，
   也不断言越路径 `@import("zigmodu/src/api/Simplified.zig")` 在下一个版本还能用（越包内路径不受支持）。
   门禁确实跑 `App.init` → `register(ModuleImpl(T).interface(…))` → `start` / `stop` 的 before 流程，但那是**走越路径 import**
   跑的 —— `docs/API-MIGRATION.md` 的 Before 片段（写的是 `zmodu.App`）照抄**编译不过**，文档里已写明它只剩教学价值。
2. **签名准确性**（"这个函数还接受同样的参数吗"）不在门禁范围，与 `src/test/DocsConsistency.zig` 的既有口径一致 —— 人工看。
3. **"1.0 那天一次性删掉"这个动作本身**是人工承诺：门禁只保证删除列写着"不早于 1.0"且非空。
4. **`docs/API.md` 里的逐符号存在性**由 `src/test/DocsConsistency.zig` 覆盖（跨文件 import，与消费者可见性一致），本文件不重复。
5. **每个类别的完整导出名单**不在本文件：同步测试比的是"本文件点到的锚点集合"与门禁的集合，不是 `root.zig` 的全部导出。
6. **`runtime.*` 的 breaking 是否真的进了 §9 与 `UPGRADING.md`**（`RUNTIME.md:59-61` 的流程要求）没有机械检查 —— 人工看。
7. **表外的弃用标记没有反查。** 门禁只检查"表里已有的行"；反过来"代码里标了 `DEPRECATED` 但表里没补行"
   仍然**没有**机械检查，只能人工看 —— 要自动化就得扫全树标记，而标记既出现在声明前、也出现在模块级横幅里，
   误报面太大。**已收口（2026-09-25）**：`src/root.zig:63-66` 的 `startAll` / `stopAll` 与 `src/http.zig:13` 的
   `http_server` 已按该节规则 2 补进表（`docs/UPGRADING.md:15-17`），并各有一条可执行检查。
   **仍在表外（观察，未决定）**：`src/validation/Validator.zig:3`（整个模块弃用）、
   `src/resilience/RateLimiter.zig:70`（`acquire` → `tryAcquire`）、`src/api/Server.zig` 的 `sendSuccess` /
   `sendFail` / `sendPageResult` / `sendJsonItems`（都指向 `ctx.json`）、`src/extensions.zig:1`（域文件级弃用）。
8. **`zigmodu.stopAll` 的标记检查不独立。** 门禁的标记看的是声明前 1500 字节（`marker_window`），
   `src/root.zig:63-66` 两条标记只隔一行，所以只删 `stopAll` 那条注释**不会**让它红（`startAll` 的注释里也有
   `Application.stop()`）。要让两条各自独立，得把窗口收窄成"紧邻的 doc comment"—— 那是门禁自己的比较口径，暂不动，人工看。

## 新增一行要做什么

1. 在 `docs/UPGRADING.md:12-17` 加弃用行（删除列不要留空），**并**在 `src/test/ApiFreeze.zig` 的 `ALIASES` 加对应项 + 一个可调用的检查；
   两张表不一致时同步测试会红。
2. 冻结/preview 面同理：改本文件的表 → 门禁的表必须同改（`FREEZE_CATEGORIES` / `PREVIEW`）。
   只改一边 = 红。**preview 往上加符号时先问一句**：它是不是该留在 `runtime.*` 里（第 10 条只保护 `runtime.*`）。
3. **删一行要在三处一起动**：从表里移出去 → `ALIASES` 同步删（"门禁留着一行而表删了"是红）→ 在
   `docs/UPGRADING.md:19-32` 的「已移除」记录里写清名字 / commit / 替代品 / 今天怎么找到它，并在
   `src/test/ApiFreeze.zig` 的 `REMOVED` 加一项（门禁钉它**不得**回到顶层，也钉记录里的名字与 commit）。
