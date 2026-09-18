# ZigModu 最佳实践指南 (Best Practices Guide)

> **Modulith 从第一天怎么写高并发应用**：见专文 [MODULITH.md](MODULITH.md)（边界、fiber、池化、规模阶梯、反模式）。  
> **model / persistence / service / Tx 分层**：见专文 [MODULE_LAYERS.md](MODULE_LAYERS.md)（参考实现 `examples/tenant-shop`）。  
> **ZigModu × zent（schema / Client / privacy / 模块级选型）**：见专文 [ZENT.md](ZENT.md)（参考实现 `examples/zent-modulith`）。  
> **SQLx 选择性驱动链接（`-Ddb=` / `.db=`）**：见专文 [SQLX_DRIVERS.md](SQLX_DRIVERS.md)。  
> **HTTP 路由 + catalog JWT / RBAC**：见专文 [ROUTE_TABLE.md](ROUTE_TABLE.md) §7；可执行清单见下文「JWT / 多端身份」。  
> **AI / Agent 写代码**：先读仓库根目录 [AGENTS.md](../AGENTS.md)（文档地图 + DO/DON'T）；方法论见 [AI_METHODOLOGY.md](AI_METHODOLOGY.md)。

## 🔄 现状复核（2026-09-17，v0.23.0）—— 近期演进对示例/文档的影响

**结论：对 `examples/` 的代码影响很小，问题集中在文档与 CLI 模板。** 三份只读审计（Runtime/builder、
AI 侧、集群侧）的实测结果：builder 绑定、worker 归 app、不手动 `rt.start()` 这三条在 examples 里**零违规**
（全仓只有 3 处 `zmodu.builder`，全部先绑定）；`examples/` 里**没有任何**代码用 `ai.Agent`（只用
SkillRegistry / Workflow / 审批流），也**没有任何**示例接集群栈。真正"照抄即失败"的都在文档里，清单见本节末尾。

### 当前最佳实践速查

1. **App 组装**：builder 必须先绑定 —— `var b = zmodu.builder(allocator, io); defer b.deinit();`
   然后 `var app = try b.withName("x").build(.{Mod});`。链在**临时值**上（`builder(…).withName(…)`）
   编译不过：临时值物化成 `*const`，而 builder 方法收 `*Self`。
2. **worker 属于 app**：模块在 `pub fn initWith(ctx: *ModuleContext)` 里 `const rt = try ctx.runtime();`
   再 spawn；`Application.stop()` 先 join worker 再停模块。不要在模块里 `Runtime.init`（线程没人 join）
   或 `rt.shutdown()`（会打断别的模块）。`Application.runtime()` **首次调用即启动 ticker**，别再多写 `rt.start()`。
3. **Agent 装配**：用 `ai.AgentSpec{ .name, .provider, .skills, .system_prompt, .guard, .memory, .budget }`
   + `spec.build()`；启动期用 `isGuarded()`（有没有闸门）/ `isInert()`（有闸门但什么都没授予）断言。
   裸 `Agent{}` 不设 `.guard` = **无界**（任何注册工具都能跑）。
4. **工具必须声明类别**：`skill.Tool.action = .read / .propose / .execute`（**默认 `.execute`**，最严）。
   注意：内置技能目前全部落在默认值上 —— 照 `AGENT_RUNTIME.md` §二 配
   `allow = 读工具 + allow_execute = false`，会把它们**全部拒掉**且 `isInert()` 不报警（见待修清单 B）。
5. **记忆**：`agent.memory = &store`（按本次运行的 tenant + user 注入；身份缺失或为 0 时**一个字都不注入**）。
   别用 `MemoryStore.formatContext(…, 0, 0, …)` 手工拼 prompt —— `0` 是"任意"，那会跨租户。
6. **Agent 跑成 worker**：webhook / cron 路径用 `ai.AgentWorker` + `ai.agent_worker.post(...)`，
   别在请求线程里同步 `Agent.run`（`ai.trigger.Trigger.fire` 是同步的）。被拒/失败走 `on_result`，不占监督预算。
7. **有副作用的 agent**：`ai.ProposalPipeline`（`guard(.propose)` → `RiskReview` →（escalate）`ApprovalFlow`
   → `guard(.execute)` → executor）；常态结局是 `execute_not_permitted` **带着风险结论**交给人工。
8. **集群读侧**：请求路径用 `MembershipView.acquire()/release()/pick(key)`（或 `ClusterBootstrap.getView()`），
   **不要**读 `ClusterMembership` 的哈希表；循环里调 `ClusterBootstrap.tick()`（一次做 gossip/health + 刷新读侧）。
9. **多节点选主默认 fail-closed**：桩传输下 `raft_cluster_size > 1` 会拒绝启动。出路三条：单机
   `raft_cluster_size = 1`；只跑 membership + 读侧 `.allow_stub_raft_transport = true`；自带
   `.transport = <ElectionTransport>`（契约见 `DISTRIBUTED.md`「真选主要什么」，v0.23.0 的
   `src/core/cluster/RaftTransport.zig` 可作起点 —— 但选主状态机仍有缺口，见该文）。
10. **事件分层**：热路径 L0 `runtime.HotBus`（有界、可丢、发布方不停）；业务事件 L1 `app.eventBus(T)` /
    `ModuleContext.eventBus(T)`；跨进程 L2（Kafka/NATS/Outbox）。用错层的代价是"可靠投递"和"零阻塞"两头不靠。
11. **门禁**：应用侧 `zmodu ci`（compile → fmt → verify → audit → deadcode → **doctor**，6 步）；
    文档里的 Zig 片段会被 `src/test/DocSnippets.zig` 抽查（只扫围栏代码块）——写 `builder` 片段时照第 1 条的形态写。

### ⚠️ 待修清单（审计产出，按严重度；✅ 命中的条目是 2026-09-17 复核后**已修**的，其余仍未修）

**A. 会编译 / 启动失败**
- ✅ `examples/README.md`：`Application.init(allocator,"app",.{M},.{})` 的缺 `io` 片段已删
  （`grep -n "Application.init(allocator" examples/README.md` 为空）
- ✅ `docs/DISTRIBUTED.md`：组装片段已显式写 `raft_cluster_size = 1` + fail-closed 注释，
  与后文不再自相矛盾
- ✅ `docs/CLUSTER-QUICKSTART.md`：整篇重写 —— 开头就是 fail-closed 声明、`raft_cluster_size = 1`、
  无 `std.Thread.sleep`；`/cluster/health` 明确写成"由你的 handler 挂载"，并**如实列出** `node_id`
  仍是固定串 `"node-id"`（见下方 ClusterHealth 一条，仍未修）
- ✅ 本文件「集群」段（现 :376-377）：已写 `ClusterMembership.init(allocator, io, …)`，并注明
  "`start` 的 Config 只有三项（没有 `seed_nodes`，seed 节点走 `connectToSeed`）"；
  `zigmodu.core.*` / "实现 PasRaft 共识" 的说法已删
- `tools/zmodu/src/main.zig:6011`（`--with-agent` 模板）：生成**无 guard 的裸 `Agent{}`**；`:6082-6086`
  的 handler 同步跑 agent 且不设 tenant/user
- `src/ai/workflow.zig:590`：`.agent` 步骤内部现搓裸 `Agent{}`，Workflow 无处传 guard ⇒ 文档推荐的
  `.agent` 步骤就是**无界 agent**
- `src/core/cluster/ClusterHealth.zig:20,37`：丢掉真实 `node_id`，输出固定串 `"node-id"`（多节点无法区分）

**B. 会误导（口径与实现不符）**
- AI 文档四件套（`AI_DEV_GUIDE.md` / `AI.md` / `AI_SKILLS.md` / `AI_ORCHESTRATION.md`）停在 2026-08：
  裸 `Agent{}`、不提 `Tool.action` / `guard` / `AgentSpec` / `AgentWorker` —— **仍未修**：`AI_SKILLS.md` /
  `AI_ORCHESTRATION.md` 至今 0 处提及 `guard` / `AgentSpec`（`AI_DEV_GUIDE.md` / `AI.md` 已开始提到）
- ✅ `MCP.md:53` 的"需显式加入 allowlist"已改成事实：「**`tools/list` 不过滤**…按 allowlist / 权限裁剪
  `tools/list` 目前**是缺口，不是既有能力**」
- **最容易踩的一条**：内置技能全部落在 `.action` 默认值 `.execute` 上（全 `src/` 只有 1 处显式
  `.action =`，还是测试）—— 按 `AGENT_RUNTIME.md` 的推荐配法会拒掉所有内置技能，且启动期不报警
- ✅ `docs/RUNTIME.md`：`"Worker 接线未做"` 已删（路线图 v0.21 行改为 ✅ `ai.AgentSpec` + `ai.Guard`）；
  `:144-145` 的历史实测数字已换成"具体条数随示例版本变化…别照抄历史数字"
- ✅ `examples/distributed/README.md`：已改成事实 —— 选主 "Not used — `RaftElection` is a framework module,
  not wired here"、"no discovery, no heartbeats, no gossip"、`NODE_ID` / `PORT` 不被代码读取（三个容器都打
  `node1` / `9000`）、Docker 三件套标注为 scaffold
- ~~`examples/cluster-demo/`~~（**已删除**，2026-09-17）：compose 构建的是**仓根 Dockerfile**（跑 basic 示例，
  无 cluster 二进制）；README 教人 `curl :8081/cluster/health` 而该路由从未挂载。拓扑与 fail-closed
  说明现并入 `examples/distributed/README.md`（docker 拓扑参考见 `examples/production-deploy/`）
- `docs/UPGRADING.md` 止于 v0.15.46 —— v0.22 / v0.23 的集群破坏性变更（fail-closed + `.transport`）没有条目

**C. 只是过时数字 / 措辞** —— ✅ **已全部收敛（2026-09-17 复核）**
- ✅ `examples/README.md`：行数表已删（末尾「Example Statistics」写明索引表才是唯一权威）；
  `"Zig 0.17.0 or later"`；shopdemo 改成 "Minimal runnable app"；test step 改为**逐行标注**，
  且三处清单与 `ci.yml` 的 `Run the example test steps` 一致
- ✅ `build.zig.zon` 的 `.minimum_zig_version` 已全部是 `"0.17.0"`
  （`grep -rn '"0.16.0"' examples/ --include='*.zon'` 为空）；`tenant-mgmt` README → v0.23.0；
  `metaverse-creative` 两处 → v0.24.0（v0.4.0 实际在 `ARCHITECTURE_DIAGRAM.txt:153`，不在 `DEMO_SUMMARY.md`）；
  `shopdemo-zent` 注释 → zent v0.67.0 的 git tag pin
- ✅ `examples/alpha-engine` 已进 `ci.yml` 两个 examples 构建循环（`:153` / `:319`）与 `zmodu doctor`
  循环（`:166`）。**仍未进 `zmodu audit` 循环**（`:214`，仍是 tenant-mgmt / tenant-shop / basic /
  ai-ops / zmsaas-backend）—— 实测 `audit examples/alpha-engine` pass、0 violations，可随时加入


### 源码文档质量（2026-09-17 抽样）

口径（2026-09-17 抽样）：`src/**.zig` 264 文件 / 1842 pub 声明；模块级 `//!` 覆盖 **171/264（64.8%）**，公开 API `///` 覆盖
**772/1842（41.9%）**，`root.zig` 再导出 **21/147（14.3%）**。当时的关键结论：主要问题不是"缺文档"，而是
**文档没跟代码走** —— 两处死旋钮（`Application.withMaxDependencies`、`Server.Config.connection_stack_size`
零读取）、若干**编不过的片段**（`Application.zig:43` 的 init 例子、`runtime.zig:17` 与 `src/runtime.zig:5`
的 `app.runtime()`）、自相矛盾处（`ClusterView.zig:10` 的 "no refcount" 与 `acquire/release` 的 fetchAdd/Sub）、
未兑现的注释（`Server.zig:2257` 的 keepalive 只设了 `SO_KEEPALIVE`）。**以上 5 条已在 v0.24.0 全部完成**，逐条现状：

1. **守住导出面** —— ✅ **已完成（v0.24.0）**：`root.zig` 与六个 barrel（http / data / security / ai / observability / runtime）
   新增 **463 行 `///`**，导出面覆盖 **100%**（`root.zig` 157 pub / 163 doc；http 176/178、data 24/24、security 21/21、
   observability 13/13、runtime 22/22），每条一句话写"是什么 + 什么时候用"。
2. **死旋钮：接线或删除** —— ✅ **已完成（v0.24.0）**：两个字段都真接线了 —— `Application.Config.max_dependencies`
   在启动期做超限告警（`src/Application.zig:161-162` 调 `warnOverDependencyLimit`），`Server.Config.connection_stack_size`
   真用于 accept 线程栈（`src/api/Server.zig:2034,2326`，低于平台下限才抬升）；两者各有测试（`Server.zig:3794`）。
3. **给超长文件加可跳转目录** —— ✅ **已完成（v0.24.0）**：Server / KafkaConnector / Middleware / GrpcTransport /
   Http2Server / ai-workflow / redis / sqlx 均加了 `//! §N` 目录 + 正文 `// ==== §N ====` 锚点
   （如 `src/core/KafkaConnector.zig` 有 10 处锚点），`grep "§3"` 可跳。
4. **修可执行文档 + 加护栏** —— ✅ **已完成（v0.24.0）**：`Application.init` 真签名示例、`app.runtime()` 的
   `try` / comptime capacity、`ClusterView` 的 refcount 表述、`tuneSocket` 的 keepalive 说明全部改正；
   `src/test/DocSnippets.zig` 增补 `try app.runtime()` 与 `Application.init(allocator…` 两类模式
   （`DocSnippets.zig:31,33`），并把 markdown 扫描**递归到 `docs/**`**（跳过 `docs/superpowers/**`）。
5. **错误与契约文案** —— ✅ **已完成（v0.24.0）**：12/12 pub error set 补齐成员级 `///`（新补 8 个 set / 94 条成员注释）；
   5 处 `@compileError` / `@panic` 文案统一成"期望形态 + 怎么改"。

### 示例品质（2026-09-17 抽样）

统计（2026-09-17 抽样）：当时 24 个目录（`find -name '*.zig'` 求和，排除缓存/构建产物）。**当时"可运行样板与门禁最不匹配的地方"**：
`runtime-workers`（builder+`ctx.runtime()`+HotBus+`spawnActor` 全对）**没有 README、不在索引里**；
`alpha-engine`（v0.23 的 P0）**不在 CI、无 README**；`shopdemo` 有 12 个 test 声明但
`build.zig` **没有 test step**（悬空）；`shopdemo-zent`/`metaverse-creative` 用 `.path = "../../../zent"`
（无 sibling 检出时不可构建）而 `zent-modulith` 用 tag pin；三份 README 有假声明
（`distributed` 的选主/env、`http-stress-test` 的 wrk、`tenant-mgmt` 的 v0.13.15）。重复候选：
shopdemo↔shopdemo-zent、basic↔testing、distributed↔cluster-demo、`deprecated/` 与 `examples/example_tests.zig`
—— 后三组已于 2026-09-17 收敛（见本节第 5 条）；`shopdemo`↔`shopdemo-zent` 保留（sqlx / zent 两种持久化的对照）。
**各条已在 v0.24.0 / 2026-09-17 全部收敛**（`shopdemo` 的 test 根与 `zent-modulith` 的 step 也已补上），逐条现状：

1. **把已存在的 test step 接进 CI** —— ✅ **已完成（2026-09-17）**：ai-ops / basic / llm-policies /
   tenant-ai / web4 / zmsaas-backend 的 test step 已进 CI（`testing` 并入 `basic`）；`shopdemo` 已补 test 根
   （`tests.zig` 聚合 `src/modules/order/` 与 `generated-sample/` 的 4 个生成测试文件 = **13 个 test**，
   `build.zig` 的 `test` step）并进入同一循环（`ci.yml:334`）。`zent-modulith` 的 step 是 `bash smoke.sh`，
   由 `Smoke zent-modulith` 步骤单独跑，因此**刻意**不在这个循环里（`ci.yml:327-331` 已写明原因）。
2. **修三处假 README** —— ✅ **已完成（2026-09-17）**：`examples/distributed/README.md` 改成事实
   （「Leader election | Not used — `RaftElection` 是框架模块，未在此接线」+ fail-closed 三条出路）；
   `http-stress-test` 改为"自带压测（1600 请求 / Errors: 0 即断言）+ 可选 wrk"；`tenant-mgmt` 版本号 → v0.23.0。
   顺带把根 README 的 Distributed 行与 `docs/dev/upgrade-roadmap.md` 的 `cluster-demo` 引用改准。
3. **给 runtime-workers / alpha-engine 补 README + 索引条目** —— ✅ **已完成（2026-09-17）**：两者都补了 README；
   `examples/README.md` 索引与目录一一对应（20 行，含 runtime-workers / alpha-engine）；`alpha-engine` 已进
   CI 构建列表（`ci.yml:153`）与 `zmodu doctor` 循环（`ci.yml:166`）。
4. **统一 zent 依赖为 git tag pin** —— ✅ **已完成（2026-09-17）**：`shopdemo-zent` / `metaverse-creative` /
   `zent-modulith` 三处都改成 `git+https://github.com/chy3xyz/zent?ref=v0.67.0` 的 tag pin（无 sibling 检出也能构建）；
   例外只剩 `examples/_shared`（helper 库，仍按 path 引 sibling `../zent`，CI 的注释已写明此处不可离线构建）。
5. **收敛重复示例** —— ✅ **已完成（2026-09-17）**：删 `deprecated/`（只有一份裸 snippet）与 `examples/example_tests.zig`
   （占位）；testing 并入 basic（`examples/basic/src/tests.zig` + `build.zig` 的 `test` step，5 个测试：原 testing 的 3 个
   全保留 + lifecycle / mock 两例；CI 的 test-step 列表随之由 `testing` 换成 `basic`）；distributed 与 cluster-demo
   合成一份"集群现状 / fail-closed"说明（`examples/distributed/README.md`，含 3 节点拓扑与 docker 拓扑指向
   `examples/production-deploy/`）。验收：`examples/README.md` 的索引表与目录**一一对应**（20 个目录 20 行，
   含 runtime-workers / alpha-engine / mcp-server / shopdemo-zent / metaverse-creative / zmsaas / distributed；
   行数表已删，避免第二份会漂移的清单）。
6. **加元数据门禁** —— ✅ **已完成（2026-09-17）**：`build.zig.zon` 的 `minimum_zig_version` 全部 → `"0.17.0"`
   （`grep -rn '"0.16.0"' examples/ --include='*.zon'` 为空）；`metaverse-creative` 两处 → ZigModu **v0.24.0**
   （`DEMO_SUMMARY.md:202` 原 v0.23.0、`ARCHITECTURE_DIAGRAM.txt:153` 原 **v0.4.0** —— 上一版把 v0.4.0 记到了
   `DEMO_SUMMARY.md`，实际在 `ARCHITECTURE_DIAGRAM.txt`，两处都已改）。

## 📋 目录 (Table of Contents)


- [渐进式架构演进路线图](#-渐进式架构演进路线图)
- [模块设计原则](#-模块设计原则)
- [代码质量规范](#-代码质量规范)
- [错误处理](#-错误处理)
  - [错误响应形状：一条开关统一全框架](#错误响应形状一条开关统一全框架v01545)
  - [韧性：一个 bug 不拖垮整个后端](#韧性一个-bug-不拖垮整个后端v01536)
  - [共享限流器 / 统计结构的线程安全](#共享限流器--统计结构的线程安全v01545)
  - [连接级背压与慢连接防护](#连接级背压与慢连接防护v01536)
  - [上线前预检](#上线前预检v01536)
  - [JWT 密钥轮换（kid）](#jwt-密钥轮换kidv01536)
  - [迁移失败后怎么恢复](#迁移失败后怎么恢复运维向)
  - [多副本后台任务：跨实例互斥](#多副本后台任务跨实例互斥v01536)
- [数据访问选型（zent / sqlx）](#-数据访问选型zent--sqlx)
- [上传与 multipart](#-上传与-multipartv01546)
- [内存管理](#-内存管理)
- [测试策略](#-测试策略)
- [性能优化](#-性能优化)
- [事务范式（伪事务警示）](#-事务范式伪事务警示)
- [安全实践](#-安全实践)
- [部署与 CI/CD](#-部署与cicd)
- [**生产就绪检查清单**](#-生产就绪检查清单)
- [文档规范](#-文档规范)
- [开发工具](#-开发工具)
- [常见陷阱与避免方法](#-常见陷阱与避免方法)
- [质量指标](#-质量指标)
- [版本升级指南](#-版本升级指南)
- [团队协作](#-团队协作)

## 🚀 渐进式架构演进路线图

ZigModu 核心设计理念：**从单体部署到分布式集群，随着用户规模增长平滑演进**。

**起步请先读** [MODULITH.md](MODULITH.md) 与 [MODULE_LAYERS.md](MODULE_LAYERS.md)：五文件模块边界、Tx 工作单元、Day-1 连接池/Outbox、以及何时才拆独立进程。本节描述用户量增长驱动的架构演进，框架能力随阶段自动解锁。

---

### 领域分层（摘要）

| 层 | 要点 |
|----|------|
| model | 行形状；状态枚举；不写 SQL |
| persistence | `Persistence(Backend)` CRUD；同事务用 `pub const Tx` |
| service | Cmd/Result；`beginTx` 编排 Tx；同事务写 outbox |
| api/BFF | 解析与 JSON；禁止 SQL |

完整规则与 `tenant-shop` 对照表 → **[MODULE_LAYERS.md](MODULE_LAYERS.md)**。

---

### 阶段 1：单机部署（0 - 1,000 用户/日活）

**目标**：最小可行产品，快速上线验证

**用户痛点**：
- 日活 < 1,000
- 单机部署，简单运维
- 快速迭代，小步快跑

**技术架构**：
```
┌─────────────────────────────────┐
│         单机部署                 │
│  ┌─────────────────────────┐    │
│  │   ZigModu Application   │    │
│  │  ┌─────┐ ┌─────┐ ┌────┐ │    │
│  │  │User │ │Order│ │Pay │ │    │
│  │  └─────┘ └─────┘ └────┘ │    │
│  └─────────────────────────┘    │
│           SQLite                  │
└─────────────────────────────────┘
```

**落地步骤**：
```
Week 1: MVP 上线
├── 定义核心模块（User/Order/Product）
├── 依赖关系配置
└── init/deinit 生命周期

Week 2-3: 业务实现
├── 业务模块开发
├── EventBus 事件驱动
└── 单元测试覆盖 > 60%

Week 4: 上线准备
├── 性能基准测试
├── 日志配置
└── 部署脚本
```

**推荐配置**：
```zig
// 单机最小配置
var app = try zigmodu.Application.init(io, allocator, "shop", .{
    UserModule,
    OrderModule,
    ProductModule,
}, .{
    .validate_on_start = true,
    .auto_generate_docs = true,
});
try app.start();
```

**关键指标**：
- 响应时间 < 100ms（P99）
- 吞吐量 100 QPS
- 内存占用 < 200MB

---

### 阶段 2：垂直扩展（1,000 - 10,000 用户）

**目标**：优化单机性能，支撑更大流量

**用户痛点**：
- 日活 1,000 - 10,000
- 请求量增长，单机瓶颈显现
- 需要更好的监控和告警

**演进策略**：
- 连接池优化
- 缓存引入（本地缓存 + Redis）
- 异步处理增强

**技术架构**：
```
┌─────────────────────────────────┐
│       垂直扩展（单机增强）        │
│  ┌─────────────────────────┐    │
│  │   ZigModu Application   │    │
│  │  ┌─────┐ ┌─────┐ ┌────┐ │    │
│  │  │User │ │Order│ │Pay │ │    │
│  │  └─────┘ └─────┘ └────┘ │    │
│  └─────────────────────────┘    │
│  ┌─────────┐  ┌─────────┐     │
│  │  Cache  │  │ DB Pool │     │
│  └─────────┘  └─────────┘     │
└─────────────────────────────────┘
```

**新增能力**：
```zig
// 引入缓存模块
const CacheModule = struct {
    pub const info = api.Module{
        .name = "cache",
        .dependencies = &.{"database"},
    };
    // 本地缓存 + Redis 分布式缓存
};

// 异步事件处理
const async_bus = zigmodu.extensions.AsyncEventBus.init(allocator);
```

**关键指标**：
- 响应时间 < 80ms（P99）
- 吞吐量 500 QPS
- 缓存命中率 > 80%

---

### 阶段 3：多实例部署（10,000 - 100,000 用户）

**目标**：水平扩展，多实例集群

**用户痛点**：
- 日活 10,000 - 100,000
- 单机无法支撑，需要多实例
- 会话共享、负载均衡需求

**技术架构**：
```
                    ┌──────────────────┐
                    │   Load Balancer  │
                    └────────┬─────────┘
           ┌─────────────────┼─────────────────┐
           │                 │                 │
    ┌──────▼──────┐   ┌──────▼──────┐   ┌──────▼──────┐
    │  Instance 1 │   │  Instance 2 │   │  Instance N │
    │ ┌─────────┐ │   │ ┌─────────┐ │   │ ┌─────────┐ │
    │ │ Modules │ │   │ │ Modules │ │   │ │ Modules │ │
    │ └─────────┘ │   │ └─────────┘ │   │ └─────────┘ │
    └──────┬──────┘   └──────┬──────┘   └──────┬──────┘
           │                 │                 │
           └─────────────────┴─────────────────┘
                          │
    ┌─────────────────────┴─────────────────────┐
    │        DistributedEventBus                │
    │     (ClusterMembership + Node Discovery)  │
    └────────────────────────────────────────────┘
                          │
    ┌─────────────────────┴─────────────────────┐
    │              Shared State                 │
    │   ┌────────┐   ┌────────┐   ┌────────┐  │
    │   │ Redis  │   │  DB    │   │ Cache  │  │
    │   └────────┘   └────────┘   └────────┘  │
    └────────────────────────────────────────────┘
```

**新增能力**：

| 能力 | 作用 | 引入方式 |
|------|------|----------|
| DistributedEventBus | 跨实例事件通信 | `zigmodu.DistributedEventBus` |
| ClusterMembership | 节点发现与健康检查 | `zigmodu.ClusterMembership` |
| 集群读侧 | 请求路径选节点（引用计数快照 + rendezvous） | `zigmodu.MembershipView` / `ClusterBootstrap.getView()` |
| Session 共享 | 分布式会话 | Redis Session Store |
| 负载均衡 | 请求分发 | Nginx/Envoy |

**配置示例**：
```zig
// 多实例部署配置（组装 + 读侧首选 ClusterBootstrap；单节点 raft_cluster_size = 1）
var boot = try zigmodu.ClusterBootstrap.init(allocator, io, .{
    .node_id = "node-1",
    .port = 9001,
    .peers = &.{ "127.0.0.1:9002" },
    .raft_cluster_size = 1,   // >1 需要自带 `.transport`，否则 start() 拒绝启动
});
defer boot.deinit();
try boot.start();             // 循环里再调 boot.tick()（外部驱动：gossip/health + 刷新读侧）

// 裸用 membership 也可以，但 `start` 的 Config 只有三项（没有 `seed_nodes`，seed 节点走 `connectToSeed`）：
//   var member = try zigmodu.ClusterMembership.init(allocator, io, "node-1", address, &bus);
//   try member.start(.{ .gossip_interval_ms = 1000, .health_check_interval_ms = 3000, .node_timeout_ms = 10000 });

// 跨实例事件走它内部的 DistributedEventBus：
const bus = boot.getEventBus() orelse return error.ClusterNotStarted;
try bus.publish("order.created", event_data);
```

**关键指标**：
- 响应时间 < 50ms（P99）
- 吞吐量 2,000 QPS
- 实例数 3-5 个
- 可用性 > 99.9%

---

### 阶段 4：服务网格（100,000 - 1,000,000 用户）

**目标**：微服务拆分，服务治理

**用户痛点**：
- 日活 100,000 - 1,000,000
- 业务复杂，需要服务拆分
- 需要熔断、限流、追踪

**技术架构**：
```
┌─────────────────────────────────────────────────────────┐
│                     API Gateway                          │
│              (GraphQL / REST / gRPC)                     │
└─────────────────────────────────────────────────────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
┌────────▼────────┐ ┌─────▼─────┐ ┌──────▼──────┐
│   User Service  │ │  Order    │ │  Payment    │
│  (独立部署)      │ │  Service  │ │  Service    │
│  ┌───────────┐  │ │ ┌───────┐  │ │ ┌────────┐  │
│  │ user mod  │  │ │ │order  │  │ │ │payment │  │
│  └───────────┘  │ │ │ mod   │  │ │ │ mod    │  │
│        │        │ │ └───────┘  │ │ └────────┘  │
└────────┬────────┘ └─────┬─────┘ └──────┬──────┘
         │                │               │
         └────────────────┼───────────────┘
                          │
    ┌─────────────────────┴──────────────────────────┐
    │              Service Mesh Layer                  │
    │  • 断路器 (CircuitBreaker)                      │
    │  • 限流 (RateLimiter)                           │
    │  • 追踪 (DistributedTracing)                   │
    │  • 指标 (PrometheusMetrics)                    │
    └──────────────────────────────────────────────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
    ┌────▼────┐     ┌─────▼─────┐   ┌─────▼─────┐
    │  Redis  │     │    DB     │   │   MQTT    │
    │ Cluster │     │  Cluster  │   │  Broker   │
    └─────────┘     └───────────┘   └───────────┘
```

**新增能力**：

| 能力 | 框架支持 | 配置 |
|------|----------|------|
| 断路器 | `zigmodu.resilience.CircuitBreaker` | 5次失败，30秒半开 |
| 限流 | `zigmodu.resilience.RateLimiter` | 令牌桶 1000/s |
| 分布式限流 | `zigmodu.data.redis_rate_limit.RateLimiter` | Redis INCR+EXPIRE 固定窗口（跨实例，fail-closed）|
| 分布式追踪 | `zigmodu.tracing.DistributedTracer` | Jaeger 导出 |
| 指标收集 | `zigmodu.metrics.PrometheusMetrics` | /metrics 端点 |
| gRPC | `zigmodu.GrpcServiceRegistry` / `zigmodu.GrpcClient` | HTTP/2（unary + stream） |
| 消息队列 | `zigmodu.NatsClient` / `zigmodu.MessageQueue` | 没有 MQTT 实现，别照抄旧名 |

**配置示例**：
```zig
// 服务治理配置
var cb = try CircuitBreaker.init(allocator, "order-service", .{
    .failure_threshold = 5,
    .timeout_ms = 30000,
});

var limiter = try RateLimiter.init(allocator, "api", 1000, 100);

// 分布式限流（跨实例共享固定窗口；Redis 不可用 → error，fail-closed）
var redis = try data.redis.Redis.init(allocator);
defer redis.deinit();
try redis.connect("127.0.0.1", 6379, .{});
var dist_limiter = data.redis_rate_limit.RateLimiter.init(&redis);
const allowed = dist_limiter.allow("login:user-1", 5, 60) catch |err| {
    // fail-closed：限流后端不可用时不放行，按拒绝处理
    std.log.warn("rate limiter backend down: {s}", .{@errorName(err)});
    return error.RateLimited;
};
if (!allowed) return error.RateLimited;

// 跨实例 WebSocket fanout：任意实例 publish → 全集群所有实例本地 broadcast
try bus.subscribeWithContext("ws.fanout", &ws_server, struct {
    fn onEvent(ctx: ?*anyopaque, ev: NetworkEvent) void {
        const s: *WebSocketServer = @ptrCast(@alignCast(ctx.?));
        s.broadcast(ev.payload);
    }
}.onEvent);
try bus.publish("ws.fanout", "{\"type\":\"notice\"}");

// 分布式追踪
var tracer = try DistributedTracer.init(allocator, "order-service", "prod");
var span = try tracer.startTrace("createOrder");
defer tracer.endSpan(span);
```

**关键指标**：
- 响应时间 < 30ms（P99）
- 吞吐量 10,000 QPS
- 实例数 10-50 个
- 可用性 > 99.99%

---

### 阶段 5：大规模分布式（1,000,000+ 用户）

**目标**：全球化部署，多区域协调

**用户痛点**：
- 日活 > 1,000,000
- 多区域部署，低延迟
- 跨区域数据一致性

**技术架构**：
```
┌─────────────────────────────────────────────────────────┐
│                  Global Load Balancer                    │
│                   (Anycast + GeoDNS)                     │
└───────────────────────────┬─────────────────────────────┘
                            │
    ┌───────────────────────┼───────────────────────┐
    │                       │                       │
┌───▼────┐           ┌─────▼─────┐           ┌─────▼─────┐
│ Asia   │           │  Europe   │           │  America  │
│ Region │           │  Region   │           │  Region   │
│ ┌─────┐│           │ ┌─────┐   │           │ ┌─────┐   │
│ │Mesh ││           │ │Mesh │   │           │ │Mesh │   │
│ └─────┘│           │ └─────┘   │           │ └─────┘   │
└───┬────┘           └─────┬─────┘           └─────┬────┘
    │                      │                       │
    └──────────────────────┼───────────────────────┘
                           │
┌──────────────────────────┼──────────────────────────┐
│        Raft 选主 / 复制（框架给缝，不给实现）             │
│   ElectionTransport + RaftTransport（状态机仍有缺口）   │
└─────────────────────────────────────────────────────────┘
```

**新增能力**：

| 能力 | 作用 | 框架支持 |
|------|------|----------|
| 选主 / 日志复制 | 跨区域协调 | `zigmodu.RaftElection` + `zigmodu.RaftTransport`（自带传输；见 `docs/DISTRIBUTED.md`） |
| 多租户 | 租户隔离 | Namespace + 资源配额 |
| 热更新 | 运行时模块替换 | `zigmodu.HotReloader` |
| 插件系统 | 动态扩展 | `zigmodu.PluginManager` |

**配置示例**：
```zig
// 单节点：显式 raft_cluster_size = 1（默认 3 会因内置传输是桩而拒绝启动）
var boot = try zigmodu.ClusterBootstrap.init(allocator, io, .{
    .node_id = "node-asia-1",
    .port = 9001,
    .peers = &.{},
    .raft_cluster_size = 1,
});
defer boot.deinit();
try boot.start();

// 跨区域选主要自带传输（契约见 docs/DISTRIBUTED.md「真选主要什么」）：
//   .transport = <RaftElection.ElectionTransport>
// 或只跑 membership + 读侧：.allow_stub_raft_transport = true
```

**关键指标**：
- 响应时间 < 20ms（P99）
- 吞吐量 50,000+ QPS
- 区域数 3-5 个
- 可用性 > 99.999%

---

### 演进决策树

```
当前日活用户量？
│
├─ < 1,000 → 阶段1：单机部署
│   └─ 简单业务 → 直接开发
│   └─ 有复杂需求 → 预留 EventBus 扩展点
│
├─ 1,000 - 10,000 → 阶段2：垂直扩展
│   └─ 性能瓶颈？→ 引入缓存
│   └─ 并发高？→ 异步处理优化
│
├─ 10,000 - 100,000 → 阶段3：多实例部署
│   └─ 需要分布式？→ DistributedEventBus
│   └─ 需要高可用？→ ClusterMembership
│
├─ 100,000 - 1,000,000 → 阶段4：服务网格
│   └─ 需要服务治理？→ 断路器 + 限流
│   └─ 需要可观测？→ 追踪 + 指标
│
└─ > 1,000,000 → 阶段5：大规模分布式
    └─ 跨区域？→ 集群读侧 + 自带 Raft 传输（框架不提供跨区编排）
    └─ 需要弹性？→ 热更新 + 插件
```

---

### 架构演进检查清单

每个阶段启动前检查：

| 阶段 | 前置条件 | 风险点 | 应对策略 |
|------|----------|--------|----------|
| 1→2 | QPS 增长 50% | 缓存穿透 | 预热 + 限流 |
| 2→3 | 实例 CPU > 70% | 会话丢失 | Redis Session |
| 3→4 | 延迟 > 100ms | 服务雪崩 | 断路器 |
| 4→5 | 跨区域部署 | 一致性 | Raft 共识 |

---

### 技术债务演进

| 阶段 | 常见技术债务 | 优先级 | 解决时机 |
|------|-------------|--------|----------|
| 1 | 缺少监控告警 | P2 | 阶段2 |
| 2 | 缓存策略单一 | P2 | 阶段2 |
| 3 | 无分布式追踪 | P1 | 阶段3 |
| 4 | 缺少熔断 | P0 | 阶段4 |
| 5 | 跨区延迟高 | P0 | 阶段5 |

**建议**：每个阶段预留 15-20% 迭代容量处理技术债务

---

### 阶段 3：分布式系统（30+ 模块）

**目标**：支持多实例部署和服务治理

**适用场景**：
- 大型项目（15+ 人）
- 高可用要求
- 多地域部署

**落地步骤**：

```
Month 1-2: 分布式基础
├── 部署 DistributedEventBus
├── 接入 ClusterBootstrap（单节点起步；多节点需自带 Raft 传输）
└── 读侧用 ClusterView / MembershipView，别读 membership 哈希表

Month 3: 服务治理
├── 集成 ServiceMesh
├── 引入 CircuitBreaker
├── 实现 RateLimiter
└── 部署分布式追踪

Month 4: 可观测性
├── 指标收集（Prometheus）
├── 日志聚合（ELK/ Loki）
└── 链路追踪（Jaeger/Zipkin）
```

**技术要点**：
- 多协议：gRPC 用 `zigmodu.GrpcServiceRegistry` / `zigmodu.GrpcClient`；消息总线用 `zigmodu.NatsClient` / `zigmodu.MessageQueue`（**没有** MQTT 实现）
- 断路器配置建议：
  ```zig
  const cb = CircuitBreaker.init(5, 30000); // 5次失败，30秒半开
  ```
- 速率限制根据业务峰值配置

---

### 阶段 4：平台化（100+ 模块）

**目标**：构建可扩展的模块化平台

**适用场景**：
- 超大型项目
- 需要支持多产品线
- 生态开放需求

**关键能力**：

| 能力 | 说明 | 优先级 |
|------|------|--------|
| 热更新 | 运行时模块热替换 | P0 |
| 插件系统 | 动态加载扩展 | P0 |
| 网关集成 | GraphQL/REST API 网关 | P1 |
| 多租户 | 租户隔离和配额管理 | P1 |

**架构模式**：
```
┌─────────────────────────────────────────────┐
│                 API Gateway                 │
│         (GraphQL / REST / gRPC)              │
└─────────────────────────────────────────────┘
                      │
┌─────────────────────┴───────────────────────┐
│              Service Mesh Layer             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ Module   │  │ Module   │  │ Module   │   │
│  │ Cluster  │  │ Cluster  │  │ Cluster  │   │
│  └──────────┘  └──────────┘  └──────────┘   │
└─────────────────────────────────────────────┘
                      │
┌─────────────────────┴───────────────────────┐
│           Cluster Coordination             │
│  (Raft Consensus / Membership / Discovery)  │
└─────────────────────────────────────────────┘
```

---

### 演进决策树

```
项目当前阶段？
│
├─ < 10 模块 → 阶段1：单体应用
│   └─ 简单需求？→ 直接使用基础功能
│   └─ 复杂需求？→ 引入 DI + EventBus
│
├─ 10-30 模块 → 阶段2：模块化服务
│   └─ 单团队？→ ArchitectureTester 验证
│   └─ 多团队？→ ModuleCapabilities 边界
│
├─ 30-100 模块 → 阶段3：分布式系统
│   └─ 高可用？→ ClusterView 读侧 + 自带 Raft 传输（选主状态机仍有缺口）+ ServiceMesh
│   └─ 性能敏感？→ gRPC + 断路器 + 速率限制
│
└─ > 100 模块 → 阶段4：平台化
    └─ 总是 → 热更新 + 插件系统 + 多租户
```

---

### 技术债务管理

每个阶段应关注的技术债务：

| 阶段 | 技术债务 | 处理策略 |
|------|----------|----------|
| 1 | 缺少测试 | 优先补齐核心模块测试 |
| 2 | 配置分散 | 引入 ConfigManager 统一管理 |
| 3 | 缺乏监控 | 部署 MetricsCollector |
| 4 | 性能瓶颈 | 引入 APM 工具 |

**建议**：每个迭代预留 20% 时间处理技术债务

---

## 🗄 数据访问选型（zent / sqlx）

ZigModu 不绑定 ORM：**同一个应用里按模块选型**，但两者正交——**不要混驱动、不要跨两者共享事务**。

| 场景 | 选 | 理由 |
|------|-----|------|
| 电商 / 社交的实体 CRUD、边关系、行级数据权限 | **zent**（`docs/ZENT.md`） | schema-as-code + 引擎强制租户/数据范围过滤，安全靠结构而非纪律 |
| 复杂报表、多表 join、批量分析 | `data.sqlx` 裸 SQL | zent 不做 join 编排；报表只读连接可独立 |
| 需要与既有 SQL schema 对齐 | zent + `StorageKey`（v0.36+） | 字段名与列名解耦，不必改库表命名 |
| 既有 sqlx 代码迁移 | 逐模块替换 | 分层契约不变（model / persistence / service），改动局限在 persistence |

铁律与细节：[`docs/ZENT.md`](ZENT.md) §1 定位、§2 何时用哪个、§12 反模式、§14 升级注意。
租户来源必须是 JWT 注入的 attr（`.tenant_source = .attr`），从 query 取租户会被
`zmodu audit` b22 拦下。

### sqlx：`Client` 与 `Transaction` 两套签名

同一件事在两个对象上签名不同，**不是笔误**——`Transaction` 不持有 allocator（它借连接），
所以凡是要分配字符串/行的查询都多一个 `allocator` 参数：

| 操作 | `Client` | `Transaction` |
|------|----------|---------------|
| 取一行（全字段） | `queryRow(T, sql, args)` | `queryRow(allocator, T, sql, args)` |
| 取一行（部分字段） | `queryRowPartial(T, sql, args)` | `queryRowPartial(allocator, T, sql, args)` |
| 取多行 | `queryRows(T, sql, args)` | `queryRows(allocator, T, sql, args)` |
| 执行 | `exec(sql, args)` | `tx.exec(sql, args)` |

行集的释放责任也随之不同（**以下签名已与源码核对**）：

| 类型 | 所有权 | 释放 |
|------|--------|------|
| `Rows`（`queryRows`/`query` 返回） | 自带 arena | `rows.deinit()` —— **不传 allocator** |
| `ManagedRows` | 包一层 `Rows` | `.deinit()` —— 同样不传 allocator |
| `BorrowedRow(T)`（`queryRowPartialBorrowed`） | 借用，字符串绑定其 arena | `.deinit()`；`get()` 的浅拷贝在 `deinit` 前有效 |
| `QueryResult(T)`（`queryRowsOwned` / `scanRowsToOwned`） | `arena != null` 时拥有全部字符串与 items 切片 | **二选一**：`deinitArena()`（arena 路径，推荐）**或** 逐行 `freeScanned(allocator, T, row)` + `allocator.free(items)` —— **都做 = double-free** |

`deinit(allocator)` 在 arena 路径上会忽略传入的 allocator（用 arena 自己的 backing allocator），
所以**误传不同 allocator 不会立刻报错、却会让 SafeAllocator 拒收**——arena 路径请用 `deinitArena()`。

`Transaction` 内的读写**必须**走 `tx` 句柄（`tx.exec` / `backend.execTx`），否则自动提交且
`rollback` 无效——伪事务，`zmodu audit` b18 会拦。

---

## 🏗️ 模块设计原则

### 单一职责原则
每个模块应只负责一个功能领域：
```zig
// ✅ 正确示例
const UserModule = struct {
    pub const info = api.Module{
        .name = "user",
        .dependencies = &.{"auth"},
    };
    
    pub fn init() !void { /* 用户初始化 */ }
    pub fn deinit() void { /* 用户清理 */ }
};

// ❌ 错误示例 - 职责混合
const BadModule = struct {
    pub const info = api.Module{
        .name = "mixed",
        .dependencies = &.{}, // 职责不明确
    };
};
```

### 依赖管理
- **声明式依赖**：所有依赖必须在 Module.info.dependencies 中明确声明
- **避免循环依赖**：模块间不应形成循环依赖链
- **最小依赖原则**：只依赖必要的模块

### 模块生命周期
每个模块必须实现完整的生命周期：
```zig
pub fn init() !void {
    // 初始化：连接数据库、启动协程、注册事件等
    std.log.info("Module initialized", .{});
}

pub fn deinit() void {
    // 清理：释放资源、停止协程、取消订阅等
    std.log.info("Module cleaned up", .{});
}
```

### 零样板 CRUD（autoCrud）
标准租户 CRUD（list/get/create/update/delete）不需要手写 handler：

```zig
// api.zig —— 整份文件一行注册
pub const OrdersApi = zigmodu.http.CrudApi(model.Orders, service.OrdersService, .{});
```

- 自动生成 5 条路由，JWT + `<module>:read`/`<module>:write` 权限 meta；
- `tenant_id` 从 attrs 注入（勿在 handler 里再验 Bearer）；
- 分页走 `PageParams.parse`（page_size 钳制，杜绝 0 拉全表）；
- 分页 `total` 是真实 COUNT（生成 list 内建）；排序走
  `CrudOpts.sortable` 白名单（`sort=<列>&order=asc|desc`，防注入）；
- 响应白名单：`CrudOpts{ .dto = OrderDto }` 后 list/get 自动经 `toDto`
  映射（隐藏 `org_id`/`secret` 等内部列）；批量导入开
  `CrudOpts{ .bulk = true }` 获得 `POST {nest}/bulk`（一次 RTT）；
- 事件源：service 组合 `data.CrudService(Entity, Persistence)` 后，写操作自动
  publish `CrudEvent{created,updated,deleted}`，业务订阅即可（发通知/审计/外发），
  无需手写事件发布；
- 零透传：service 声明 `pub const impl = data.CrudService(Entity, P)` 与
  `crud: impl` 字段后，`CrudApi` 自动直通（无需再写 5 个转发方法）；
  生成的 service 只有接线 + `validate` 钩子（`zmodu saas` 已按此产出）；
- 读路径禁止手写 `scan()` 列下标取值——列顺序变化会静默错位；分页列表用
  arena-backed `data.ResultSet`（`queryRows.take()`，字符串零拷贝、`deinit`
  一次释放），单行用 `queryRowsSlice`（按列名映射、索引每查询建一次）；
- 多写一致性：`svc.transact(T, f)` 事务封装（生成物自带），避免手写
  begin/commit/rollback 遗漏。
- 可观测一行开：`server.addMiddleware(zigmodu.http.tracingMiddleware())`
  注入 `x-trace-id` + 请求耗时日志（`rateLimitMiddleware` 同款）；autoCrud
  路由与自定义路由一并生效，业务代码无需埋点。
- 多语言错误：`http.setErrorLocalizations(&.{.{ .err = error.ValidationFailed,
  .zh = "校验失败", .en = "Validation failed" }})` 后，`respondErr` 按
  `Accept-Language` 返回中文/英文 detail（覆盖 autoCrud 与自定义路由）。
- 数据权限 SQL 注入：`DataPermissionInterceptor.andWhere(ctx, dept_col,
  user_col)`（镜像 TenantInterceptor）由 `DataPermissionContext` 产出 scope
  子句（`.all` 返回 null、`.self_` 生成 `user_col = ?`、`.dept_*` 生成 IN）；
  中间件解析角色→作用域，handler 只把注入的子句拼进查询——不手写过滤。
- 零配置交互式 API 文档：`http.openApiRoutes(State, &slot, .{ .title = "App" })`
  一行接入 `/openapi.json`、`/docs` (Swagger UI) 与 `/scalar` (Scalar UI)
  公开路由组；亦可使用 `http.swaggerUiHandler("spec.json")` 或
  `http.scalarUiHandler("spec.json")` 单独挂载。

适用边界：规则简单的 CRUD 模块直接用；需要复杂业务编排（多表事务、状态机、
审批流）时保留 service 内手写 Cmd，autoCrud 只覆盖纯增删改查面。

### 自定义业务逻辑（扩展点）
autoCrud 之上加业务逻辑，按复杂度选档，全部向后兼容：

1. **输入校验** — 生成 service 的 `validate(e)` 钩子（create/update 自动调用）。
2. **CRUD 方法覆盖** — 在 service 里声明同名方法即优先于内嵌 impl：
   ```zig
   // create 需要额外副作用（如写 outbox、扣库存）时：
   pub fn create(self: *@This(), e: model.Orders) !i64 {
       const id = try self.crud.create(e);   // 基础行为 + validate + CrudEvent
       try self.persistence.afterCreateHook(org_id_of(e), id); // 自定义 SQL
       return id;
   }
   ```
   未覆盖的方法仍直通 `self.crud`（零透传不回归）。
3. **自定义端点** — 同 `module_name`/`nest` 挂第二个 Api 结构（路径不重叠即可，
   `assertNoDupes` 只查 method+path 重复）：
   ```zig
   pub const OrdersActionsApi = struct {
       pub const module_name = "orders";
       pub const nest = .{"orders"};
       pub const State = @This();
       service: *service.OrdersService,
       pub const routes = [_]zigmodu.http.RouteSpec(State){
           .{ .method = .POST, .path = "{id}/cancel", .handler = cancel,
             .meta = .{ .auth = .jwt, .permission = "orders:write" } },
       };
       // handler：读 attrs 的 tenant_id → self.service.cancel(...) → respondErr 映射
   };
   ```
   状态机、多表事务、审批流等同步逻辑放 service 方法；`crud.get/crud.update`
   可复用基础读写（事件照发），需要新 SQL 时用保留的 `self.persistence` 指针
   写参数化语句。
4. **解耦副作用** — 订阅 `CrudEvent{created,updated,deleted}`（含自定义方法内
   复用 `crud.create/update/delete` 的路径）：
   ```zig
   var bus = zigmodu.TypedEventBus(zigmodu.data.CrudEvent(model.Orders)).init(allocator);
   defer bus.deinit();
   try bus.subscribe(module.events.onOrderEvent);
   svc.crud.setEventBus(&bus);   // 通知/审计/外发/积分，与主流程解耦
   ```

参考实现：`examples/zmsaas/backend`（`POST /orders/{id}/cancel` 状态机 +
`events.zig` 订阅）。注意：`zmodu saas` 重新生成会覆盖
model/persistence/service/api/module/root 五个文件，自定义逻辑可放在
`events.zig` 等独立文件（生成器不写）或重新生成后重放差异。

## 🧪 代码质量规范

### 命名约定
| 类型 | 命名规范 | 示例 |
|------|---------|------|
| 模块 | 小写 + 描述 | `user`, `order_service` |
| 常量 | 全大写下划线 | `MAX_RETRIES`, `DEFAULT_TIMEOUT` |
| 函数 | 小驼峰 | `getUserData()`, `validateToken()` |
| 类型 | 大驼峰 | `UserData`, `OrderService` |
| 错误 | 全大写下划线 | `ERROR_INVALID_TOKEN` |

### 代码结构
- **文件组织**：按功能组织模块目录
- **函数长度**：单个函数不超过 50 行
- **复杂度控制**：圈复杂度保持在 10 以下
- **注释规范**：关键算法和决策点必须有注释

```zig
// ✅ 良好的代码结构
const OrderService = struct {
    /// 创建订单并验证库存
    pub fn createOrder(allocator: Allocator, req: OrderRequest) !Order {
        // 1. 验证请求参数
        try validateRequest(req);
        
        // 2. 检查库存
        const stock = try checkInventory(req.product_id);
        
        // 3. 创建订单实体
        const order = try createOrderEntity(allocator, req);
        
        // 4. 发布事件
        try publishOrderCreated(order);
        
        return order;
    }
};
```

## ⚠️ 错误处理

### 错误类型设计
- **明确错误类型**：为每个错误场景定义具体的错误类型
- **错误传播**：使用 Zig 的错误传播机制
- **上下文信息**：错误应包含足够的上下文信息

```zig
pub const AppError = error{
    DatabaseConnectionFailed,
    InvalidConfiguration,
    NetworkTimeout,
    AuthenticationFailed,
    InsufficientPermissions,
} || std.io.Error || std.json.Error;

pub fn processRequest(req: Request) AppError!Response {
    const db = try connectToDatabase() catch |err| {
        std.log.err("DB connection failed: {}", .{err});
        return err;
    };
    // ...
}
```

### 错误恢复
- **重试机制**：对临时性错误实现指数退避重试
- **降级策略**：在关键服务不可用时提供降级方案
- **断路器模式**：使用 CircuitBreaker 防止雪崩

### 错误响应形状：一条开关统一全框架（v0.15.45+）

对外契约最常见的写法是"失败体必须是 `ProblemDetails`"。这个承诺**只有在你够得到每一条出口时才成立** ——
框架自产的错误体有三条出口，修复前只有一条能被应用改：

| 形状 | 触发路径 | 谁来写 |
|------|---------|--------|
| `{"status":…,"title":…,"detail":…,"instance":…}` | `http.respondErr` / `respondProblem` / 显式 `.reject` | **handler / 应用**（你能控制） |
| `{"code":status,"msg":…,"data":null}` | `ctx.sendError`/`sendErrorResponse`：moduleGate 403/404、CSRF 403、413、请求超时 408、**未捕获 handler 500**、静态文件错误 | 框架内部 |
| `{"error":"…"}` | 路由**之前**写裸 socket：400/408/413 `BodyTooLarge`/431 `TooManyHeaders`、accept 线程超额 503 | 框架传输层（中间件链之外） |

后两条是"客户端把路径写错 / UI 未迁移"这种最常见场景的出口。装上渲染器即可全部收口：

```zig
// 启动期一次：链内 + 路由前全部 RFC 7807（application/problem+json）
zigmodu.http.useRfc7807Errors();
```

| 需求 | 调用 |
|------|------|
| 只收口链内 | `http.setDefaultReject(http.problemReject)` |
| 只收口路由前 | `http.setTransportErrorRenderer(http.problemTransportBody)` |
| 完全复位（测试用） | `http.clearDefaultReject()` |
| 单个 gate 例外 | `.reject = http.envelopeReject(.thinkphp)`（`ModuleGateConfig` 也接受 `reject`） |
| 单条响应例外 | `ctx.sendErrorEnvelope(status, code, msg)` |

三条守则：

- **不要用链尾中间件去改 404 体。** 那需要把 `moduleGate` 降级成 `.unknown = .allow`，等于放弃 gate 的拒绝语义；`.reject` 钩子（v0.15.45）既保留 `.deny` 又能改body。
- **未捕获的 500 抓不到就别去抓。** 它发生在中间件链之外，只能由进程级渲染器统一 —— 这也是钩子设计成进程级而非路由级的原因。
- **渲染器签名不含业务 code。** `sendErrorResponse(status, code, msg)` 在装了渲染器后 `code` 会被丢弃（RFC 7807 没有业务码位）；需要两者兼得就用 `ctx.sendErrorEnvelope`。

> 自查：`grep -rn 'application/json' src/api/middleware/` 不该出现自造信封；
> `scripts/check-production.sh` 会拦"信封泄漏"（`sendSuccess`/`sendFail`/裸 `{"code":`）。

### 韧性：一个 bug 不拖垮整个后端（v0.15.36+）

Zig 的 panic 不可捕获——请求路径上任何一次 panic 都会终止**整个进程**，
拖垮全部在途请求。框架提供四层防线（预防 → 收口 → 诊断 → 恢复）。

**生产一行接入**（细节与顺序约束见
[`ROUTE_TABLE.md`](ROUTE_TABLE.md) §7.4）：

```zig
var profile = zigmodu.http.ProductionProfileState.init(allocator);
defer profile.deinit(allocator);
try zigmodu.http.productionProfile(&server, .{
    .max_connections = 4096,      // 连接洪泛背压
    .header_timeout_ms = 10_000,  // slowloris（请求行+header 阶段）
}, &profile);                     // ⚠️ 必须在 addRoute / mountAll 之前
```

它同时挂出 `/metrics`（黄金信号）、`/health/live`、`/health/ready` 与
tracing/access-log/security-headers；告警与看板见
[`OBSERVABILITY.md`](OBSERVABILITY.md)。

**1. 预防 · 共享注册表用 FrozenMap（消除最高发的崩溃源）**

app 级共享 HashMap（适配器表、路由缓存、开关表）在 worker 池上并发
`put`/resize 会撕裂元数据，读者随后 `panic: incorrect alignment`——这类
崩溃无 stack 可用、极难定位。正确姿势：启动期填充 → `freeze()` → 运行期
只读（无锁、任意并发读安全）；冻结后写返回 `error.Frozen`（可测试、可在
启动期暴露）：

```zig
var adapters = zmodu.FrozenStringMap(Adapter).init(allocator);
try adapters.put("alipay", .{ .endpoint = "..." });  // 启动期：可写
adapters.freeze();                                   // 服务期：只读
const a = adapters.get("alipay");                    // 无锁、线程安全
```

**参数层（表单 / 上传）**

| 输入 | 用它 | 说明 |
|------|------|------|
| `application/x-www-form-urlencoded` | `ctx.bindForm(T)` | 与 query 同口径解码；loose 字段名；缺必填 → `error.MissingField` |
| query string | `ctx.bindQuery(T)` | 同上契约 |
| **重复键 / 数组**（`ids=1&ids=2`、`role_id[0]`、`tags[]`） | `ctx.queryValues` / `ctx.formValues` / `ctx.formArray` / `ctx.queryArray` | `get()` 仍是"最后出现者"（兼容旧语义）；`getFirst`/`getAll` 取全部；`getArray` 把 `name[0..n]` 与 `name[]` 合并为按索引排序的数组 |
| **深层键** | `ctx.paramPath("filter.tags")` | 点路径 → `filter[tags]`；form 优先、回退 query |
| 参数数量防护 | `Server.Config.max_params`（默认 1000） | query/form 按出现次数计数，超限 `error.TooManyParams`，不静默截断（对标 PHP `max_input_vars`） |
| `multipart/form-data` | `ctx.bindMultipart(T, cfg)` + `Form.file(name)` | 文本与文件分开取；限额 `max_parts` / `max_part_bytes` / `max_total_bytes` |
| JSON | `ctx.bindJsonLoose(T)` | camelCase 兼容、null 视为缺省、所有权统一 |
| 路径参数 | `ctx.pathParam(name)`（旧名 `param`） | 它**不是**"任意参数" |
| 静态资源 | `http.staticFiles(io, &server, allocator, "/assets", "public", .{})` | 中间件实现；只 GET/HEAD；无目录索引；ETag/Range |

手写 `getPara`、自建解码器、自建 JSON 发射器、自写静态服务都不再必要——
整批绑定用上面的 `bind*`，单值才用 `formValue` / `queryParam`。

**2. 收口 · 请求路径禁止裸 panic**

handler/service/persistence 里用错误返回，不用 `catch unreachable` /
`@panic`。`zmodu audit` 规则默认开启并拦截这三类：

| 规则 | 拦截 | 豁免 |
|------|------|------|
| b19 | 请求路径 `@panic(...)` / 语句级 `unreachable;` | switch 分支穷举 `=> unreachable,` 不报；确实不可能的分支用 `// audit: ignore b19` |
| b20 | 文件作用域共享可变 HashMap | `zmodu.FrozenMap/FrozenStringMap` 不报 |
| b21 | 请求路径裸 `@alignCast`（指针来源必须稳定） | `ctx.user_data` 与 `@alignCast(self)`（单例注册）不报 |

**3. 诊断 · panic 钩子（一行接入）**

进程还是要死，但要死得可查：panic 时先把**当前请求的 `METHOD /path`**
打到 stderr（无分配、固定缓冲），再走标准 panic 输出 stack trace。应用
root（含 `main` 的文件）加一行：

```zig
const zmodu = @import("zigmodu");
pub const panic = zmodu.panicHook;
```

Server 在 dispatch 前写入 threadlocal 请求上下文、结束后清除，无需业务
侧任何配合；不接这一行则一切照旧。

**4. 恢复 · 进程级兜底**

panic 钩子管诊断，不管存活。进程存活靠 supervisor：`systemd`
`Restart=always`、k8s `restartPolicy: Always` 或容器编排的重启策略。
多进程隔离（prefork）的边界与前置条件见
[`PRODUCTION_ROADMAP.md`](PRODUCTION_ROADMAP.md)「单进程单点与原位隔离」。

### 共享限流器 / 统计结构的线程安全（v0.15.45+）

`RateLimiter`、`RateLimiterRegistry`、`SlidingWindowRateLimiter` 三者**现在都是线程安全的**
（内部短自旋守卫）。在此之前的后果不是抽象的：`current_tokens` 的读-改-写竞争会让
**同一枚令牌被两个线程花掉**——把守卫临时去掉，100 枚令牌的并发用例被放行 117 次。

自己写"跨请求共享的可变结构"时，按同一个标准问三个问题：

| 问题 | 危险信号 | 处置 |
|------|---------|------|
| 热路径上有共享可变哈希表吗？ | `put`/`resize` 撕裂元数据，读者 `@alignCast` → `incorrect alignment` panic（进程级） | 启动期填充 + `FrozenMap`（只读），或加锁 |
| 返回过容器内部元素的指针吗？ | 下一次插入触发 rehash → 调用方拿到**悬垂指针**（zent 连接池 UAF 同族） | 容器存**指针**，不存值 |
| 计数器是"读-改-写"吗？ | 丢更新（限流值只是"大致"）、令牌重复消费 | 原子 CAS，或加锁 |

`zmodu audit` 的 b20/b21 规则正是扫前两类（文件作用域共享可变 HashMap / 请求路径裸 `@alignCast`）——
两者都属于"一次就打死整个进程"，见 [`MODULITH.md`](MODULITH.md) 与「韧性」一节。

### 连接级背压与慢连接防护（v0.15.36+）

`request_timeout_ms` 只管 **handler 阶段**：连接洪泛与 header 慢速滴入
（slowloris）在它生效之前就把 fd/内存耗尽——这类故障**不需要任何 bug 就能
打挂进程**，所以是独立的两个开关：

```zig
var server = zigmodu.http.Server.initWithConfig(io, allocator, .{
    .port = 8080,
    .max_connections = 4096,          // 0 = 不限（默认）；超限立即处理
    .over_limit_response = .close,    // .close（最省）或 .unavailable（先回 503）
    .header_timeout_ms = 10_000,      // 请求行 + header 阶段的总 deadline
});
```

| 场景 | 行为 |
|------|------|
| 正常请求 | 不受影响；header 读完后 deadline 立即解除，慢速上传（body）不会被误杀 |
| 慢速滴 header | 到点回 `408 Request Timeout` 并关连接 |
| 连接数超限 `.close` | 直接关（不发响应，最省） |
| 连接数超限 `.unavailable` | 先用裸 socket 回 `503` 再关（写在 accept 线程上，不走 io，避免阻塞 accept 循环） |

也可用环境变量：`HTTP_MAX_CONNECTIONS`、`HTTP_HEADER_TIMEOUT_MS`
（`Server.fromEnv`）。上线前按"预期并发 × 2"设 `max_connections`，
`header_timeout_ms` 取 p99 建连时间的两倍左右（默认 10s 已相当宽松）。

**WebSocket 出站**（同属"慢客户端"问题，但发生在写方向）：

```zig
var server = zigmodu.http.Server.initWithConfig(io, allocator, .{
    .port = 8080,
    .ws_write_timeout_ms = 10_000,   // 0 = 旧行为（可无限阻塞）
});
```

不读数据的客户端会让发送缓冲填满，写线程（以及 `im.ConnectionRegistry` 的
shard 锁）被无限期占住。设了超时后写返回 `error.WriteTimeout` 并 shutdown
连接；广播/Fan-out 还可先用 `framer.isWritable()` 做 O(1) 水位探测，主动丢帧
而不是排队堆积。

**并发验收**：`zig build soak`（`-Dsoak-clients=N -Dsoak-iterations=M`）跑真实
socket 的 N 并发 × M 租户压测，断言跨租户读取为 **0**、冻结注册表在并发读 +
拒写下不撕裂、连接计数回落为 0。它刻意不挂在 `zig build test` 里，以便日常
快跑、发布前慢跑。

**沙箱/受限 CI**：`zig build test -Dnet-tests=false` 让所有依赖 loopback 的用例
走 `NetworkProbe.available()` 跳过（默认开启网络用例）。

### 上线前预检（v0.15.36+）

生产事故大多在启动前就已注定：少了一个环境变量、JWT secret 还是示例里的占位值、
数据库连不上、时钟差了几年（签出的 token 直接过期）。这些**在启动时检查几乎零成本**，
上线后排查却极贵：

```zig
var env_ctx = zigmodu.Preflight.EnvCheck.fromMap(init.environ_map, &.{ "JWT_SECRET", "DATABASE_URL" });
var secret_ctx = zigmodu.Preflight.SecretCheck{ .secret = jwt_secret };  // 拒绝占位/过短
var clock_ctx = zigmodu.Preflight.ClockCheck{ .io = io };
var report = zigmodu.Preflight.run(allocator, &.{
    zigmodu.Preflight.envCheck(&env_ctx),
    zigmodu.Preflight.secretCheck(&secret_ctx),
    zigmodu.Preflight.dbCheck(&db_client),      // SELECT 1
    zigmodu.Preflight.migrationCheck(&mig_ctx), // 有待应用迁移就拒绝启动
    zigmodu.Preflight.clockCheck(&clock_ctx),
});
defer report.deinit();
report.log();
if (!report.ok()) return error.PreflightFailed;   // 不启动，胜过带病运行
```

- `Severity.warn` 只告警不阻塞（如"迁移未应用"在自动迁移的应用里只提示）。
- 检查之间互不影响：单个探针失败不会掩盖其它结果。
- 参考接线：`examples/zmsaas/backend/src/main.zig`（env + secret + DB + clock）。

### 文档 ↔ 代码一致性（v0.15.42+）

`src/test/DocsConsistency.zig` 把"API 参考里写的符号必须真实存在"变成 CI 门禁：
扫描 `docs/API.md` 的 `pub fn` / `pub const` 声明，逐个在 `src/` 里核对（大写名字按
"类型构造器"的文档写法放宽，只出现在注释里的词不算）。首次运行就抓到 4 个**从未存在过**
的 API 被写在参考文档里——消费方照着写只会得到"找不到符号"。

写文档时的三条规矩：① 示例签名从源码复制，别凭记忆；② 字段就是字段，别写成
`pub fn`；③ 计划中/未提供的能力明确标注（`Not provided` / `experimental`），不要以
可用 API 的形式出现。应用侧示例代码放在 BEST_PRACTICES（有意不参与该检查）。

### `anytype` 形参的契约写法（v0.15.41+）

`anytype` 是灵活性来源，也是**隐式契约**——消费方传错形态时，报错往往落在被调方深处，
要翻两层才知道是自己传错了（zent 的 `deinitRows(rows: anytype)` 传 `&rows` 就是这样）。
本仓库的规则：

1. **doc comment 第一句就写"接受什么形态"**，用"必须是**指针**"这类明确措辞：

   ```zig
   /// Accepted form: **a pointer** to anything with
   /// `queryRows(T, sql, params)` — in practice `*zigmodu.data.Client`.
   /// Pass `&client`, not `client`.
   pub fn dbCheck(client: anytype) Check { ... }
   ```
2. **能表达成编译期约束的，绝不留给我们推导**——把报错提到调用点并写清怎么改：

   ```zig
   const T = @TypeOf(client);
   if (@typeInfo(T) != .pointer) {
       @compileError("dbCheck expects a *pointer* to a client (e.g. `&db_client`); got "
           ++ @typeName(T) ++ ". Pass the address, not the value.");
   }
   const Client = @typeInfo(T).pointer.child;
   if (!@hasDecl(Client, "queryRows")) @compileError("...expects `queryRows`...");
   ```
3. **用回归测试固定形态**：至少一条正向用例走"真实类型"，另一条走"鸭子类型替身"
   （见 `src/core/Preflight.zig` 的 `dbCheck accepts any type with queryRows`）。
   这样契约变化会在 CI 里失败，而不是在消费方那里失败。
4. 泛型事件/`comptime` 元组这类**真正"任意"**的形参（`stageEvent(event: anytype)`、
   `scanModules(modules: anytype)`）不需要约束，但要在注释里写清"任意值/类型元组"。

已加固的公开 API：`Preflight.dbCheck` / `Preflight.EnvCheck.fromMap` /
`PrometheusMetrics.registerMetricsRoute[Path]` / `Dashboard.registerRoutes`。

### 跨函数边界返回：必须具名类型（v0.15.45+）

Zig 里**同名但各自内联的 struct 是不同类型**。persistence 返回 `!struct { list: []T, total: i64 }`，
service 再声明一个字面相同的内联返回类型，编译器报的是 `expected A, found B` —— 名字一样，
类型不同，人会反复踩（反馈方在日志查询、结算列表、统计趋势、任务统计上各踩一次）。

```zig
// ✗ 两层各自内联：类型不相等，报错在 service 层，光看名字找不到原因
pub fn listLogs(...) !struct { list: []Log, total: i64 } { ... }
pub fn logs(...) !struct { list: []Log, total: i64 } { ... }

// ✓ 具名一次，全链路复用（框架已有泛型容器 data.PageResult(T)）
pub const LogPage = struct { list: []Log, total: i64 };
```

规则：**跨函数/跨层边界返回的结构一律具名**；分页场景直接用 `data.PageResult(T)`。
局部变量里的内联 struct 无所谓。

### 公开但可个性化：`Auth.optional`（v0.15.41+）

`Auth` 的三个值语义要分清，选错会得到"游客拿不到身份"或"游客被 401"：

| 值 | 验签 | 身份注入 | 适用 |
|----|------|----------|------|
| `.public` | 跳过 | **无**（`ctx.userId()` 恒空） | 纯公开数据（健康检查、公开列表） |
| `.optional` | 有 token 就验，失败忽略 | 有效 token → 注入 `user_id`/`tenant_id`/`roles` | **公开但可个性化**：C 端用户中心、按用户灰度的公开接口、公开详情的"是否已收藏" |
| `.jwt` | 必须 | 必须 | 私有接口；无 token 401 |

```zig
.{ .method = .GET, .path = "products/{id}", .handler = detail, .meta = .{ .auth = .optional } }
// handler 里照常 ctx.userId()：有 token 有值，没 token 就是 null，绝不会 401
```

不要再用"handler 里手写 token 解析"或"给公开接口再挂一条 jwt 路由"来绕过。
`.optional` 仍可带 `permission` / `roles` 元数据（`permissionGate` 不会把它当 public 短路）。

### `unreachable` / `assert` 的分类原则（v0.15.41+）

这两个构造的选择标准是**"这个失败是不是来自外部输入或环境"**：

| 情形 | 用什么 | 例子 |
|------|--------|------|
| 内部状态机的不变式（构造上不可能） | `=> unreachable`（switch 穷举） | 熔断器 `CLOSED => unreachable`（`canAccept` 已保证） |
| **环境失败**（OOM、socket 选项、syscall） | 显式 error，或 `@panic("可读原因")` | 中间件构造期的 `page_allocator.create` → `catch @panic("…: out of memory")` |
| 请求路径上的任何"不可能" | 返回错误（`respondErr`），不许 `unreachable` | `zmodu audit` **b19** 会拦 |
| 测试里的前提 | `try` / `error.TestUnexpectedResult` | 解析刚写入的值 |

`ReleaseFast` 下 `unreachable` 是 UB、`ReleaseSafe` 是 abort 且没有上下文——所以
"能说出原因"的 panic 也比裸 `unreachable` 好。CI 门禁 `scripts/check-production.sh`
按前缀分层强制这一规则（`src/api|core|http|metrics|messaging|scheduler|security`），
其余目录先告警、逐步收紧。

### JWT 密钥轮换（kid，v0.15.36+）

不带 keyring 时签发的 token 头部 `kid` 为空，换密钥只能"全部重启 + 所有人重登"。
接上 `JwksKeyRing` 后，token 头部带 `kid`，验签按 `kid` 取密钥：

```zig
var ring = zigmodu.security.JwksKeyRing.init(allocator);
defer ring.deinit();
try ring.addKey("v1", old_secret, true);      // 上线时的主密钥
app_sec.module.setKeyring(&ring);

// 轮换：新密钥设为主密钥，旧密钥留在环里继续可验
try ring.addKey("v2", new_secret, true);      // 新签发的 token 用 v2
// → 旧 token 在有效期内仍可用；等它们自然过期后再 ring 里移除 v1
```

`kid` 指向环中不存在的密钥时直接拒绝（`error.UnknownKeyId`），不会退化成"用主密钥
试一下"——否则伪造一个未知 kid 就等于绕过。

### 迁移失败后怎么恢复（运维向）

`MigrationRunner.run()` 的失败语义是**明确的**，恢复动作因此也是确定的：

| 事实 | 含义 |
|------|------|
| 失败时写入 `success = false` 的历史行，随后返回 `error.MigrationFailed` | 下一条迁移不会执行（顺序保证） |
| 只有 `success = true` 的行会被跳过 | 修复后**重启即自动重试**那条迁移，无需手工改状态 |
| 部分语句可能已生效（断在第 N 条） | 迁移脚本必须**可重复执行**：`CREATE TABLE IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS` / 先判断再建索引 |
| `validateChecksums()` 校验已应用迁移的 checksum | 已上线的迁移文件**不许改**；要改就加新版本 |
| `ALTER TABLE` 语句失败会被 log + 跳过并记 success | 这是为了兼容"列已存在"，代价是**真的写错也会被吞**——ALTER 请用 `IF NOT EXISTS` 形式，测试环境先跑一遍 |

恢复步骤：修脚本（保持同一版本号与幂等）→ 重启（或再跑一次 `run()`）→ 用
`getMigrationStatus()` / 查询 `_zigmodu_migrations` 确认 `success = true`。

```sql
-- 事故现场查询：哪条迁移没成功
SELECT version, description, success, execution_time_ms, applied_at
FROM _zigmodu_migrations ORDER BY version;
```

生成迁移文件：`zmodu migration "add orders.notes" --dir src/migrations`（只生成，
不代跑）；应用由应用启动时调 `runner.run(client)`，多副本务必配
`runner.setLock(...)`（见上一节）。

### 多副本后台任务：跨实例互斥（v0.15.36+）

单机跑得对，不代表多副本跑得对：**cron 和迁移在 N 个副本上会各跑一遍**——发券、
对账、outbox 投递会重复执行，迁移则可能并发执行 DDL。

```zig
// 一张表即可，三个驱动通用（表名会做标识符校验）
var lock = try zigmodu.DistributedLock.SqlLock(@TypeOf(db)).init(
    allocator, io, &db, "zigmodu_lock", .sqlite,   // .sqlite | .postgres | .mysql
);
defer lock.deinit();

// 每个 job 每分钟只在一个副本上执行
cron.setLock(lock.lock(), 60_000);

// 滚动发布时只有一个实例应用迁移；抢不到返回 error.MigrationLocked
runner.setLock(lock.lock(), 300_000);
```

要点：

- **TTL 必须大于最慢任务**：持有者崩溃未释放时，锁在 `ttl_ms` 之后被回收；
  若任务运行时间超过 TTL，下个窗口可能被另一副本并行执行。
- **争用不是错误**：抢占是一条原子语句（`INSERT … ON CONFLICT DO NOTHING` /
  `INSERT IGNORE`），`rows_affected == 0` 即"别人持有"，返回 false；连接失败
  等真实错误会向上抛，不会被静默当成"跳过"。
- **默认无锁**（`NoopLock`）：不配置就保持单进程行为，不会有隐藏契约变化。
- Postgres 想用原生 `pg_try_advisory_lock`：实现同一个 `Lock` vtable 即可
  （`tryAcquire(name, ttl_ms)` / `release(name)`），调用点无需改动。

## 🧠 内存管理

### 分配器使用
- **明确生命周期**：每个分配明确的生命周期
- **避免内存泄漏**：确保每处分配都有对应的释放
- **使用 defer**：关键资源使用 `defer` 确保释放

```zig
// ✅ 正确的内存管理
pub fn processData(allocator: Allocator, input: []const u8) ![]u8 {
    const buffer = try allocator.alloc(u8, input.len);
    defer allocator.free(buffer); // 确保释放
    
    // 处理数据...
    
    return buffer;
}

// ❌ 错误的内存管理
pub fn badPractice() ![]u8 {
    const buffer = try allocator.alloc(u8, 1024);
    // 忘记 defer 释放
    return buffer; // 内存泄漏
}
```

### 集合使用
- **预分配容量**：已知大小时预分配容量
- **及时释放**：不再使用的集合及时释放
- **避免共享所有权**：谨慎使用共享引用

## 🧪 测试策略

### 测试金字塔
- **单元测试**：覆盖核心逻辑（70%）
- **集成测试**：验证模块交互（20%）
- **端到端测试**：完整流程验证（10%）

### 测试编写规范
```zig
// ✅ 良好的测试实践
const ModuleTestContext = @import("zigmodu").extensions.ModuleTestContext;

test "用户模块 - 创建用户" {
    const allocator = std.testing.allocator;
    var ctx = try ModuleTestContext.init(allocator, "user");
    defer ctx.deinit();
    
    try ctx.start();
    defer ctx.stop();
    
    // 执行操作
    const result = try createUser(ctx, "test_user");
    
    // 验证结果
    try std.testing.expectEqualStrings("test_user", result.name);
    try std.testing.expect(ctx.hasEvent("user.created"));
}

test "订单模块 - 异常处理" {
    const allocator = std.testing.allocator;
    var ctx = try ModuleTestContext.init(allocator, "order");
    defer ctx.deinit();
    
    // 测试错误场景
    const result = createOrder(ctx, .{
        .product_id = "invalid",
        .quantity = 0, // 无效数量
    });
    
    try std.testing.expectError(error.InvalidQuantity, result);
}
```

### 覆盖率要求
- **核心模块**：覆盖率 ≥ 80%
- **关键路径**：覆盖率 ≥ 90%
- **错误路径**：必须覆盖所有错误处理分支

## ⚡ 性能优化

### 算法选择
- **数据结构**：根据访问模式选择合适的数据结构
  - 频繁查找：HashMap
  - 顺序访问：ArrayList
  - 先进先出：Queue
  
- **算法复杂度**：避免 O(n²) 复杂度的算法

### 异步处理
- **非阻塞IO**：使用异步IO避免阻塞
- **协程管理**：合理使用协程避免资源耗尽
- **批处理**：合并小请求减少开销

```zig
// ✅ 异步批处理
pub fn processBatch(allocator: Allocator, items: []Item) !void {
    const batch_size = 100;
    var i: usize = 0;
    
    while (i < items.len) {
        const batch = items[i..@min(i + batch_size, items.len)];
        try processBatchAsync(batch); // 异步批处理
        i += batch_size;
    }
}
```

### 内存池
- **对象池**：频繁创建销毁的对象使用对象池
- **缓冲区复用**：复用大缓冲区避免频繁分配
- **避免装箱**：优先使用值类型而非引用类型


## 💱 事务范式（伪事务警示）

**伪事务（最常见的事务缺陷）**：`beginTx()` 之后事务内的写仍用
`backend.exec()` / `client.exec()` —— 那走的是池连接**自动提交**，`rollback`
无效，资金/积分/状态类链路会出现部分写入残留。

正确两种范式：

1. **回调式（推荐，防呆）**：`Client.transact` / `Repository.transact` ——
   回调返回即 commit，出错自动 rollback（errdefer），结构上不可能漏：

   ```zig
   try repo.transact(void, struct {
       fn f(tx: *data.orm.Tx(data.SqlxBackend)) anyerror!void {
           try tx.exec("UPDATE orders SET status = ? WHERE id = ?", &.{.{ .int = 1 }, .{ .int = 42 }});
           try tx.exec("INSERT INTO event_outbox ...", &.{});
       }
   }.f);
   ```

2. **三件套（需要显式控制时）**：

   ```zig
   var tx = try client.beginTx();
   defer tx.rollback() catch {};   // 出错兜底回滚
   try tx.exec("UPDATE ...", &.{});
   try tx.commit();                // 全部成功才提交
   ```

**铁律**：`beginTx()` 之后一切读写**走 tx 句柄**（`tx.exec` / `tx.queryRow` /
`tx.queryRowPartial`），不要混用 `backend.exec`（池连接、非事务）。事务内查询优先
`tx.queryRowPartial`（缺失列置零，与 `Client.queryRowPartial` 同契约）。多写方法
的遗漏由 `zmodu audit` 的 b16 规则兜底（默认开启）。


## 📤 上传与 multipart（v0.15.46+）

### 三件事一起做，缺一个就有洞

上传端点要同时回答三个问题：**能不能收**（大小）、**收进来是什么**（内容）、**收下来安全吗**（存放）。

```zig
// 1) 能收多大：先抬服务端上限，再让 multipart 的限额在它之内
var server = zigmodu.http.Server.initWithConfig(io, allocator, .{
    .max_body_size = 64 << 20,
});
const mp = zigmodu.http.Multipart.Config.forBodyLimit(64 << 20);

// 2) 收进来是什么：解析失败按 ProblemDetails 出 415/413/400
var form = try zigmodu.http.extractMultipart(ctx, mp);
defer form.deinit();

// 3) 安全吗：按字节判定格式，并要求与扩展名一致
try zigmodu.http.UploadGuard.checkForm(&form, .{
    .extensions = &.{ "jpg", "jpeg", "png", "webp" },
    .formats = &.{ .jpeg, .png, .webp },
    .max_bytes = 5 << 20,
});
const avatar = form.file("avatar").?;   // 到这里才可信
```

### 限额的先后顺序（最容易搞错的一处）

| 配置 | 默认 | 在哪一层生效 |
|------|------|------------|
| `Server.Config.max_body_size` | 8 MB | **最先**：请求体还在读的时候就 413，`Multipart.parse` 根本不会被调用 |
| `Multipart.Config.max_total_bytes` | 32 MB | 解析期，仅在服务端已放行该体积之后才有意义 |
| `Multipart.Config.max_part_bytes` | 8 MB | 同上，单个 part |

所以默认配置下 `max_total_bytes = 32 MB` **永远不可能触发**——服务端 8 MB 先拒了。
要收 64 MB 的附件，必须同时抬 `max_body_size` 与 multipart 限额；`Config.forBodyLimit(n)`
用同一个数字帮你把两者对齐（单 part ≤ 总量 ≤ body）。

### 内容校验：三种"看起来对"的写法都是错的

```zig
// ✗ 只看扩展名：shell.php 改名 avatar.jpg 就过了
if (!std.mem.endsWith(u8, filename, ".jpg")) return error.Rejected;

// ✗ 只看 Content-Type：这个头是客户端自己填的，只是建议
if (!std.mem.eql(u8, part.content_type, "image/jpeg")) return error.Rejected;

// ✗ 放行 SVG：SVG 是脚本容器，从你自己的源站发出去就是 stored-XSS
```

**可用的规则：嗅探字节，再要求"嗅探结果"与"扩展名"一致。** `UploadGuard.check` 的判定顺序是
刻意的（大小 → 主动内容 → 扩展名白名单 → 格式白名单 → 两者一致），因此错误信息可以直接告诉调用方
问题在哪：

| 错误 | 含义 |
|------|------|
| `FileTooLarge` | 超过 `max_bytes`（单文件上限，独立于请求总量） |
| `ActiveContentNotAllowed` | 嗅探到 SVG/HTML。**默认拒绝**，即使白名单里写了 `svg`——`allow_active_content = true` 才是显式选择 |
| `ExtensionNotAllowed` | 扩展名不在 `extensions`（没扩展名也算） |
| `ContentNotAllowed` | 嗅探出的格式不在 `formats` |
| `ExtensionContentMismatch` | 两边各自都合法，但互相对不上（PNG 字节挂了 `.jpg` 名） |

支持嗅探：JPEG/PNG/GIF/WebP/BMP/TIFF/PDF/ZIP/GZIP/**MP4(ISO-BMFF，校验 box size + `ftyp`)**/WebM/OGG/MP3/WAV，
以及"文本容器"——`<svg`/`<!doctype html`/`<script` 归为主动内容，其它文本归为 `plain`。

**这不是病毒扫描器**，也不解析图像：它只保证"文件是它声称的那类"，把上传端点从"任人投递"变成"只收这几类"。
要求更高的场景（图片重编码、病毒扫描）应放在存储侧的后处理里。

### 其它两条上传相关的约定

- `http.extractMultipart(ctx, config)` 是 `ctx.multipart` 的抽取器版本：失败直接产出
  ProblemDetails（415/413/400），不需要每个 handler 自己映射 `Multipart.Error`。
- 目录/文件名只在**扩展名比对**时使用，且只看最后一段路径（`a.b/c.jpg` → `jpg`）；真正的落盘路径
  仍要自己生成（不要用客户端文件名拼路径）。

## 🔒 安全实践

### JWT / 多端身份（与路由栈）

权威细则：[`ROUTE_TABLE.md`](ROUTE_TABLE.md) §7 + §7.1。此处为可执行摘要。

#### 默认栈（路径 A · 新应用必选）

```zig
var app_sec = zigmodu.security.AppSecurity.init(allocator, io, .{
    .jwt_secret = jwt_secret,
    .token_expiry_seconds = 3600,
});
var catalog_slot: http.CatalogSlot = .{};
defer catalog_slot.deinit();

// 1) JWT + 权限展开（写入 attrs；不碰 user_data）
try server.addMiddleware(http.jwtAuthFromCatalogWithPermissions(
    &app_sec.module,
    &catalog_slot,
    // 简单应用：http.catalogLoaderFromTable(&table)
    // 或：zigmodu.security.CatalogPermDb.loaderFromClient(&db)
    // 多主体：自定义 CatalogPermissionLoader（见下）
    http.catalogLoaderFromTable(&role_perm_table),
    .{ .skip_prefixes = &.{ "api/health", "health", "dashboard", "openapi.json" } },
));
// 2) 可选：写入 module attr
try server.addMiddleware(http.moduleGate(&catalog_slot, .{ .unknown = .allow }));
// 3) 门禁：RouteMeta.permission ⊆ permissions CSV
try server.addMiddleware(http.permissionGateWith(&catalog_slot, .{ .mode = .rbac }));

// … Router.mountAll …
catalog_slot.set(try router.finish());
```

签发（唯一源）：

```zig
// aud = 租户；roles = 门户粗身份（勿塞全量菜单树）
const token = try app_sec.module.generateTokenWithTenant(user_id_str, &.{ "shop" }, app_id_str);
```

路由元数据：

```zig
.{ .method = .GET, .path = "product/list", .handler = list,
   .meta = .{ .auth = .jwt, .permission = "portal:shop" } }, // 或细码 tenant:suspend
.{ .method = .POST, .path = "passport/login", .handler = login,
   .meta = .{ .auth = .public } },
```

#### 上下文槽位（正交 · 勿混用）

| 槽位 | 用途 | 禁止 |
|------|------|------|
| `ctx.user_data` | ComptimeRouter `*State` | 写入 AuthInfo / JWT 对象 |
| `ctx.auth_info` | 可选 `Rbac.AuthInfo`（legacy `rbacJwtMiddleware`） | `@ptrCast(user_data)` 当 AuthInfo |
| `ctx.attributes` | `user_id`/`tenant_id`/`roles`/`permissions` | 再验一遍 Bearer（gate 已做过） |

Handler 只读 attrs / 应用侧薄 helper（如 `portal_auth.currentTenant`），**不要**在每个 handler 里 `extractAuth` 重复验签。

#### 多门户 / 多套业务 RBAC

框架 **不** 增加 JWT `type` 枚举。约定：

| 概念 | Claim / 落点 |
|------|----------------|
| 谁 | `sub` → attr `user_id` |
| 哪租户 | `aud` → attr `tenant_id`（SQL 列名可用 `app_id`） |
| 哪门户 | `roles`：`user` / `shop` / `admin` / `supplier` |
| 门户门禁 | `RouteMeta.permission = "portal:shop"` 等 |
| 职务/菜单 | 应用表 → **自定义** `CatalogPermissionLoader` → `permissions` CSV |

自定义 loader 签名（已含身份）：

```zig
fn load(allocator: Allocator, input: http.CatalogPermLoadInput) ![]u8 {
    // input.sub / input.aud / input.roles
    // 按 roles 选 shop_* / supplier_* / admin 表族展开 access.path
    // 始终可附带 portal:* 码，便于粗门禁
}
```

- 简单演示：`RolePermissionTable` / `CatalogPermDb`（**忽略** sub/aud）。  
- 多商户后台：**不要**把三套业务表并进 `CatalogPermDb`。  
- 参考：`examples/tenant-mgmt`（单套库表）；多主体应用见 ZigShop `docs/AUTH_FRAMEWORK_ALIGNMENT.md`（路径 A 已落地）。

#### 刻意不做

- 核心 `JwtPayload` 加必填 `type`  
- 长期「应用自签 + 框架再验」双轨  
- 把业务 `*_role` / `*_access` 内置进框架  

#### Legacy 中间件

`AppSecurity.rbacJwtMiddleware*` / `security.auth.jwtAuth*` 现只写 **`auth_info`**，可与 ComptimeRouter 共存；新代码仍优先 catalog + `permissionGateWith(.rbac)`。

### 输入验证
- **边界检查**：所有外部输入必须验证
- **类型安全**：避免使用 anytype 和强制转型
- **错误处理**：绝不忽略错误

```zig
// ✅ 安全的输入验证
pub fn validateInput(input: []const u8) !void {
    if (input.len == 0 or input.len > 1024) {
        return error.InvalidInput;
    }
    
    if (!std.ascii.isPrint(input)) {
        return error.NonPrintableChar;
    }
    
    // 进一步验证...
}
```

### 并发安全
- **互斥锁**：共享数据使用互斥锁保护
- **原子操作**：简单计数器使用原子操作
- **线程隔离**：避免跨线程共享可变状态

```zig
const std = @import("std");

pub const ThreadSafeCounter = struct {
    mutex: std.Thread.Mutex = .{},
    value: u64 = 0,
    
    pub fn increment(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value += 1;
    }
    
    pub fn get(self: *Self) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.value;
    }
};
```

### 安全扫描
- **静态分析**：使用安全扫描工具定期检查
- **依赖审计**：定期审计第三方依赖
- **代码审查**：安全相关代码必须经过审查

## 🚀 部署与CI/CD

### 构建优化
```zig
// build.zig - 优化构建配置
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe, // 生产环境使用 ReleaseSafe
    });
    
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    // 生产环境特定配置
    if (optimize == .ReleaseSafe or optimize == .ReleaseFast) {
        exe.root_module.addDefine("NDEBUG");
        exe.root_module.addDefine("LOG_LEVEL=2"); // 减少日志
    }
}
```

### 环境配置
- **环境分离**：开发、测试、生产环境分离
- **配置管理**：使用环境变量配置
- **密钥管理**：敏感信息使用密钥管理服务

```zig
// config/Loader.zig - 环境感知配置
pub fn loadConfig(allocator: Allocator) !Config {
    const env = std.process.getEnvVarOwned(allocator, "APP_ENV") catch "development";
    
    return switch (env) {
        "production" => .{
            .db_url = std.process.getEnvVarOwned(allocator, "DB_URL").?,
            .log_level = .error,
            .enable_cache = true,
        },
        "staging" => .{
            .db_url = std.process.getEnvVarOwned(allocator, "DB_URL").?,
            .log_level = .info,
            .enable_cache = true,
        },
        else => .{
            .db_url = "sqlite:///dev.db",
            .log_level = .debug,
            .enable_cache = false,
        },
    };
}
```

### CI/CD 流水线
```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [master, develop]
  pull_request:
    branches: [master]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        zig-version: ["0.16.0"]
    
    steps:
      - uses: actions/checkout@v4
      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: ${{ matrix.zig-version }}
      - name: Run tests
        run: zig build test
      - name: Build examples
        run: |
          cd examples/basic && zig build
          cd ../event-driven && zig build
```

## ✅ 生产就绪检查清单

上线前逐条过一遍；每条都对应一个真实故障模式，括号内是承接它的能力。

**进程与启动**
- [ ] 应用 root 接上 `pub const panic = zmodu.panicHook;`（panic 时输出正在处理的请求）
- [ ] 启动跑 `zigmodu.Preflight.run(...)`：必填 env、JWT secret 非占位、DB 连通、无待应用迁移、时钟正常（`!report.ok()` 直接拒绝启动）
- [ ] supervisor 就位：systemd `Restart=always` 或 k8s `restartPolicy: Always`（panic 不可捕获，重启是最后一道可用性防线）

**HTTP 层**
- [ ] `http.productionProfile(&server, cfg, &state)` 在**所有 `addRoute` / `mountAll` 之前**调用
- [ ] `max_connections` 已设（≈ 预期并发 × 2）；`header_timeout_ms` 打开；`.unavailable` 或 `.close` 按需
- [ ] WS 服务设了 `ws_write_timeout_ms`；广播前用 `framer.isWritable()` 丢帧
- [ ] CORS 不再是 `"*"`（profile 会告警）

**数据与并发**
- [ ] 请求路径无裸 `panic`/`catch unreachable`（`zmodu audit` b19 拦截）
- [ ] 共享注册表用 `FrozenMap`/`FrozenStringMap`，启动期填充后 `freeze()`（b20 拦截）
- [ ] 多副本的 cron / 迁移配 `DistributedLock`（`cron.setLock` / `runner.setLock`）
- [ ] 换密钥走 `JwksKeyRing` + `setKeyring`（带 `kid`，新旧双验）
- [ ] zent 数据访问：`.tenant_source = .attr`（b22 拦截）

**可观测**
- [ ] `/metrics` 已挂且**不对公网暴露**；`/health/live` 与 `/health/ready` 语义分离（存活查进程、就绪查依赖）
- [ ] 至少 5 条告警在跑：`up`、5xx 率、P95 延迟、`outbox_pending`、`db_pool_waiters`（`docs/OBSERVABILITY.md`）
- [ ] outbox 有后台轮询 + 指标；池饱和度用 `setScrapeHook` 采样

**验证与发布**
- [ ] `zig build test` 全绿；`bash scripts/ci-integration.sh` 通过
- [ ] 发布前跑 `zig build soak`（跨租户泄漏断言）；CI 夜间已挂 64×200
- [ ] TLS 在边车终结（`examples/production-deploy/`），证书轮换有流程
- [ ] 迁移幂等（`IF NOT EXISTS`），且有失败恢复步骤（本文「迁移失败后怎么恢复」）

---

## 📚 文档规范

### API 文档
- **所有导出项**：必须包含文档注释
- **参数说明**：明确参数含义和约束
- **返回值**：说明可能的返回值和错误

```zig
/// 用户模块 - 提供用户管理服务
/// 
/// ## 示例
/// ```zig
/// const user_mod = try UserModule.init(allocator);
/// defer user_mod.deinit();
/// ```
pub const UserModule = struct {
    /// 用户信息结构
    pub const User = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
    };
    
    /// 创建新用户
    /// - `allocator`：内存分配器
    /// - `name`：用户名（必须非空）
    /// - `email`：邮箱地址（必须有效格式）
    /// - 返回：创建的用户对象
    pub fn createUser(
        allocator: Allocator,
        name: []const u8,
        email: []const u8,
    ) !User {
        // 实现...
    }
};
```

### 模块文档
每个模块应包含：
- 模块功能说明
- 依赖关系
- 使用示例
- 已知限制

### README 维护
- **及时更新**：功能变更后更新文档
- **示例丰富**：提供完整可运行的示例
- **结构清晰**：逻辑清晰、易于导航

## 🛠 开发工具

### 推荐工具链
- **格式化**：`zig fmt` 保持代码风格一致
- **类型检查**：`zig build check` 定期运行
- **静态分析**：使用 `scan-build` 等工具
- **性能分析**：使用 `zig build benchmark`

### 常用命令
```bash
# 格式化代码
zig fmt --check .

# 类型检查
zig build check

# 运行测试
zig build test

# 性能基准测试
zig build benchmark

# 生成文档
zig build docs
```

## 🚨 常见陷阱与避免方法

### 内存泄漏
- **问题**：忘记释放分配的内存
- **避免**：使用 `defer` 确保资源释放
- **检测**：使用内存分析工具

### 错误处理不完整
- **问题**：忽略错误或错误传播不完整
- **避免**：每个错误分支都有处理逻辑
- **检测**：代码审查时特别关注错误处理

### 竞态条件
- **问题**：多线程环境下数据竞争
- **避免**：使用适当的同步机制
- **检测**：使用数据竞争检测器

### 性能瓶颈
- **问题**：热点代码路径性能差
- **避免**：基准测试识别瓶颈
- **优化**：算法优化、缓存、批处理

### Threaded Io 下的同步阻塞（handler 内禁 `posix.poll/read`）
- **背景**：服务端 handler 跑在 **Threaded Io 的 fiber（io 线程）**上。同步阻塞调用
  （`std.posix.poll` / `std.posix.read` / 忙等）会**阻塞整个 io 线程**——所有
  并发请求共享该线程，一次阻塞 = 全局停顿（表现为超时 / ProviderError / 假死）。
- **对比**：`std.testing.io` 与独立调用线程没有 io 线程概念，同样的同步代码
  "看起来正常"——这是"live 测试通过、服务端挂"类问题的典型根源。
- **正确姿势**：
  - 出站 HTTP：一律走 `http.HttpClient`（内部已封装 io 异步路径；真实
    DeepSeek/OpenAI 流式在 Threaded Io 下实测通过）。
  - 其他网络/等待：使用 `io` 的异步 API（`io.timeout` / fiber 语义），不要
    自己 `posix.poll`。
  - 纯计算（无阻塞）不受影响。
- **诊断**：若服务端出现"单请求挂起拖垮全部"且 live 测试正常 → 查 handler 链路
  里是否有同步阻塞 I/O；`@TypeOf(io)` 打印确认是否为 Threaded。
- **契约**：框架层不强制禁止（工具链兼容），但**应用层默认禁止**在 handler /
  中间件 / Agent 工具回调里做同步阻塞 I/O。

## 📊 质量指标

### 代码质量
- [ ] 零 `@panic` 调用（生产代码）
- [ ] 错误覆盖率 ≥ 95%
- [ ] 代码重复率 < 5%
- [ ] 圈复杂度平均值 < 5

### 测试质量
- [ ] 单元测试覆盖率 ≥ 80%
- [ ] 集成测试覆盖率 ≥ 60%
- [ ] 关键路径覆盖率 ≥ 95%
- [ ] 性能测试定期运行

### 文档质量
- [ ] 所有公共 API 有文档
- [ ] 示例代码可运行
- [ ] 更新及时同步功能变更

## 🛠️ 版本升级指南

### 向后兼容性
- **API 变更**：提供迁移指南
- **行为变更**：明确说明影响
- **废弃功能**：提前版本标记为废弃

### 迁移策略
1. **并行支持**：新旧版本同时支持
2. **自动迁移**：提供迁移工具
3. **文档引导**：详细的迁移说明

## 🤝 团队协作

### 代码审查
- **必查项**：内存管理、错误处理、并发安全
- **选查项**：性能优化、代码简洁性
- **反馈机制**：及时反馈、改进闭环

### 知识共享
- **技术分享**：定期组织技术分享
- **最佳实践**：总结沉淀最佳实践
- **新人培训**：完善 onboarding 流程

--

**最后更新**：2025年4月  
**版本**：1.0  
**维护者**：ZigModu 团队
