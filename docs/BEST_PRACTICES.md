# ZigModu 最佳实践指南 (Best Practices Guide)

> **Modulith 从第一天怎么写高并发应用**：见专文 [MODULITH.md](MODULITH.md)（边界、fiber、池化、规模阶梯、反模式）。  
> **model / persistence / service / Tx 分层**：见专文 [MODULE_LAYERS.md](MODULE_LAYERS.md)（参考实现 `examples/tenant-shop`）。  
> **ZigModu × zent（schema / Client / privacy / 模块级选型）**：见专文 [ZENT.md](ZENT.md)（参考实现 `examples/zent-modulith`）。  
> **SQLx 选择性驱动链接（`-Ddb=` / `.db=`）**：见专文 [SQLX_DRIVERS.md](SQLX_DRIVERS.md)。  
> **HTTP 路由 + catalog JWT / RBAC**：见专文 [ROUTE_TABLE.md](ROUTE_TABLE.md) §7；可执行清单见下文「JWT / 多端身份」。  
> **AI / Agent 写代码**：先读仓库根目录 [AGENTS.md](../AGENTS.md)（文档地图 + DO/DON'T）；方法论见 [AI_METHODOLOGY.md](AI_METHODOLOGY.md)。  
> **代码片段基线**：**ZigModu v0.26.0 · Zig 0.17.0**（CI 钉 `0.17.0-dev.2151+2ec5523d5`，见 `.github/workflows/ci.yml` 的 `ZIG_VERSION`）。跨版本升级看 [UPGRADING.md](UPGRADING.md)。  
> **片段口径**：本文的代码围栏分两类 —— **可照抄的完整示例**，和**示意用的片段/伪码**（含 `...`、`// ...`、
> 或引用了上下文里没给的标识符）。伪码**不保证可直接编译**，只表达结构与契约；可编译的完整示例看
> `examples/**`。逐段标注见各围栏前的说明。

## 📋 目录 (Table of Contents)

- [现状复核（2026-09-18 复核，v0.26.0）—— 近期演进对示例/文档的影响](#-现状复核2026-09-18-复核v0260-近期演进对示例文档的影响)
  - [当前最佳实践速查](#当前最佳实践速查)
  - [待修清单（审计产出，按严重度）](#-待修清单审计产出按严重度-命中的条目是-2026-09-17--2026-09-18-两批复核后已修的其余仍未修)
  - [源码文档质量（2026-09-17 抽样）](#源码文档质量2026-09-17-抽样)
  - [示例品质（2026-09-17 抽样）](#示例品质2026-09-17-抽样)
  - [仍待完善（2026-09-18 复核，v0.26.0）](#仍待完善2026-09-18-复核v0260)
  - [CLI 与门禁现状（2026-09-18 复检）](#cli-与门禁现状2026-09-18-复检)
  - [新用户路径卡点（2026-09-18，按严重度）](#新用户路径卡点2026-09-18按严重度)
  - [BEST_PRACTICES 自审（2026-09-18）](#best_practices-自审2026-09-18)
  - [实践 ↔ 门禁一致性（2026-09-18）](#实践--门禁一致性2026-09-18)
- [渐进式架构演进路线图](#-渐进式架构演进路线图)
- [模块设计原则](#-模块设计原则)
- [代码质量规范](#-代码质量规范)
- [错误处理](#-错误处理)
  - [错误响应形状：一条开关统一全框架（v0.15.45+）](#错误响应形状一条开关统一全框架v01545)
  - [韧性：一个 bug 不拖垮整个后端（v0.15.36+）](#韧性一个-bug-不拖垮整个后端v01536)
  - [共享限流器 / 统计结构的线程安全（v0.15.45+）](#共享限流器--统计结构的线程安全v01545)
  - [连接级背压与慢连接防护（v0.15.36+）](#连接级背压与慢连接防护v01536)
  - [上线前预检（v0.15.36+）](#上线前预检v01536)
  - [JWT 密钥轮换（kid，v0.15.36+）](#jwt-密钥轮换kidv01536)
  - [迁移失败后怎么恢复（运维向）](#迁移失败后怎么恢复运维向)
  - [多副本后台任务：跨实例互斥（v0.15.36+）](#多副本后台任务跨实例互斥v01536)
- [数据访问选型（zent / sqlx）](#-数据访问选型zent--sqlx)
- [上传与 multipart（v0.15.46+）](#-上传与-multipartv01546)
- [内存管理](#-内存管理)
- [测试策略](#-测试策略)
- [性能优化](#-性能优化)
- [事务范式（伪事务警示）](#-事务范式伪事务警示)
  - [跨进程事务日志：TransactionJournal + recover()（必须接）](#跨进程事务日志transactionjournal--recover必须接)
  - [Saga 步骤超时：SagaStep.timeout_seconds（必须设）](#saga-步骤超时sagasteptimeout_seconds必须设)
- [安全实践](#-安全实践)
- [部署与 CI/CD](#-部署与cicd)
- [生产就绪检查清单](#-生产就绪检查清单)
- [文档规范](#-文档规范)
- [开发工具](#-开发工具)
- [常见陷阱与避免方法](#-常见陷阱与避免方法)
- [质量指标](#-质量指标)
- [版本升级指南](#-版本升级指南)
- [团队协作](#-团队协作)

## 🔄 现状复核（2026-09-18 复核，v0.26.0）—— 近期演进对示例/文档的影响

**结论：对 `examples/` 的代码影响很小，问题集中在文档与 CLI 模板。** 三份只读审计（Runtime/builder、
AI 侧、集群侧）的实测结果：builder 绑定、worker 归 app、不手动 `rt.start()` 这三条在 examples 里**零违规**
（2026-09-17 采样：全仓 2 处真实 `zmodu.builder` 调用 —— `examples/runtime-workers/src/main.zig`、
`examples/alpha-engine/src/main.zig` —— 全部先绑定）。**"examples 里没有任何代码用 `ai.Agent`"这条断言
（2026-09-17 采样）已被推翻**：`examples/alpha-engine/src/modules/propose/module.zig` 用了**裸 `Agent{}`**
—— 恰好违反下文规则 3；截至 2026-09-18 仍是唯一一处。也**没有任何**示例接集群栈。真正"照抄即失败"的
都在文档里，清单见本节末尾。**本节所有"全仓有几处 / 没有任何"式数字都是采样值，会过时——以 `grep` 为准。**

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

### ⚠️ 待修清单（审计产出，按严重度；✅ 命中的条目是 **2026-09-17 / 2026-09-18 两批复核后已修**的，其余仍未修）

**A. 会编译 / 启动失败**
- ✅ `examples/README.md`：`Application.init(allocator,"app",.{M},.{})` 的缺 `io` 片段已删
  （`grep -n "Application.init(allocator" examples/README.md` 为空）
- ✅ `docs/DISTRIBUTED.md`：组装片段已显式写 `raft_cluster_size = 1` + fail-closed 注释，
  与后文不再自相矛盾
- ✅ `docs/CLUSTER-QUICKSTART.md`：整篇重写 —— 开头就是 fail-closed 声明、`raft_cluster_size = 1`、
  无 `std.Thread.sleep`；`/cluster/health` 明确写成"由你的 handler 挂载"，并**如实列出** `node_id`
  仍是固定串 `"node-id"`（见下方 ClusterHealth 一条 —— 2026-09-18 已修）
- ✅ 本文件「集群」段（即「阶段 3：多实例部署」的组装示例）：已写 `ClusterMembership.init(allocator, io, …)`，并注明
  "`start` 的 Config 只有三项（没有 `seed_nodes`，seed 节点走 `connectToSeed`）"；
  `zigmodu.core.*` / "实现 PasRaft 共识" 的说法已删
- ✅ `tools/zmodu/src/main.zig:6011`（`--with-agent` 模板）：生成**无 guard 的裸 `Agent{}`**；`:6082-6086`
  的 handler 同步跑 agent 且不设 tenant/user
  （2026-09-18 修：模板现生成 `guard: zigmodu.ai.Guard = …`（`tools/zmodu/src/main.zig:6127`）并交给
  `Agent{ .guard = &self.guard }`（`:6150`），handler 用 `tenantId(ctx)` / `ctx.userIdInt(i64)` 填
  `SkillContext{ .tenant_id = …, .user_id = … }`（`:6214` / `:6232-6233`））
- ✅ `src/ai/workflow.zig:590`：`.agent` 步骤内部现搓裸 `Agent{}`，Workflow 无处传 guard ⇒ 文档推荐的
  `.agent` 步骤就是**无界 agent**
  （2026-09-18 修：`Workflow` 增 `guard` 字段（`src/ai/workflow.zig:153`），`agentForStep()` 透传
  `.guard = self.guard`（`:606`）；测试 `workflow .agent steps inherit the workflow guard`（`:1297`））
- ✅ `src/core/cluster/ClusterHealth.zig:20,37`：丢掉真实 `node_id`，输出固定串 `"node-id"`（多节点无法区分）
  （2026-09-18 修：`healthJson` 改读 `cluster.getConfig().node_id`（`src/core/cluster/ClusterHealth.zig:37`，
  `getConfig` 见 `src/core/cluster/ClusterBootstrap.zig:300`）；测试断言 health JSON 的 `node_id` == 配置值（`:87`））

**B. 会误导（口径与实现不符）**
- ✅ AI 文档四件套（`AI_DEV_GUIDE.md` / `AI.md` / `AI_SKILLS.md` / `AI_ORCHESTRATION.md`）停在 2026-08：
  裸 `Agent{}`、不提 `Tool.action` / `guard` / `AgentSpec` / `AgentWorker`（`AI_DEV_GUIDE.md` / `AI.md` 先开始提到）
  （2026-09-18 修：`AI_SKILLS.md:6-7` / `AI_ORCHESTRATION.md:8-9` 补了指向 `AGENT_RUNTIME.md` 的
  「运行时姿态」指针并点名 `ai.Guard` / `ai.AgentSpec` / `Tool.action` / `ai.AgentWorker`；四件套现均提及
  `guard`/`AgentSpec`（`rg -c 'guard|AgentSpec' docs/AI_*.md` → `AI_SKILLS.md:3`、`AI_ORCHESTRATION.md:2`、
  `AI_DEV_GUIDE.md:7`、`AI.md:8`）；`AI_DEV_GUIDE.md:97` / `AI.md:32` 明写"不要手搓裸 `Agent{}`"）
- ✅ `MCP.md:53` 的"需显式加入 allowlist"已改成事实：「**`tools/list` 不过滤**…按 allowlist / 权限裁剪
  `tools/list` 目前**是缺口，不是既有能力**」
- ✅ **最容易踩的一条**：内置技能全部落在 `.action` 默认值 `.execute` 上（全 `src/` 只有 1 处显式
  `.action =`，还是测试）—— 按 `AGENT_RUNTIME.md` 的推荐配法会拒掉所有内置技能，且启动期不报警
  （2026-09-18 修：内置技能逐个显式声明类别（`src/ai/business.zig:106/154/202`、`src/ai/kpi.zig:61`、
  `src/ai/notify.zig:126`、`src/ai/schedule.zig:47/71/109/130`、`src/ai/admin.zig:107/134/160/184/209/253/274`、
  `src/ai/actions.zig:66/83/221/304`、`src/ai/approval_api.zig:133`、`src/ai/approval.zig:248`），
  并有测试 `builtin skills declare their action class`（`src/ai/skill.zig:545`）；盲区本身由
  `SkillRegistry.auditPolicy` + `PolicyHealth.isInert()/hasClassBlindSpot()` 补齐（`src/ai/skill.zig:99,242`，
  测试 `:567/:608`）——`Guard.isInert()` 仍只看 `allow.len`（`src/ai/guard.zig:87`），但注册表侧现在能报出
  "列了名单却被类别闸门全拒"）
- ✅ `docs/RUNTIME.md`：`"Worker 接线未做"` 已删（路线图 v0.21 行改为 ✅ `ai.AgentSpec` + `ai.Guard`）；
  `:144-145` 的历史实测数字已换成"具体条数随示例版本变化…别照抄历史数字"
- ✅ `examples/distributed/README.md`：已改成事实 —— 选主 "Not used — `RaftElection` is a framework module,
  not wired here"、"no discovery, no heartbeats, no gossip"、`NODE_ID` / `PORT` 不被代码读取（三个容器都打
  `node1` / `9000`）、Docker 三件套标注为 scaffold
- ~~`examples/cluster-demo/`~~（**已删除**，2026-09-17）：compose 构建的是**仓根 Dockerfile**（跑 basic 示例，
  无 cluster 二进制）；README 教人 `curl :8081/cluster/health` 而该路由从未挂载。拓扑与 fail-closed
  说明现并入 `examples/distributed/README.md`（docker 拓扑参考见 `examples/production-deploy/`）
- ✅ `docs/UPGRADING.md` 止于 v0.15.46 —— v0.22 / v0.23 的集群破坏性变更（fail-closed + `.transport`）没有条目
  （2026-09-18 修：补上 v0.22.0（`docs/UPGRADING.md:132`）/ v0.23.0（`:100`）/ v0.24.0（`:70`）/
  v0.25.0（`:18`）四节，含 `ClusterBootstrap` 多节点 fail-closed 与 `.transport` 那条）

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
   新增 **463 行 `///`**，导出面覆盖 **100%**（`root.zig` 158 pub / 164 doc〔2026-09-18 实测〕；http 176/178、data 24/24、security 21/21、
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
—— 后三组已于 2026-09-17 收敛（见本节第 5 条）；`shopdemo`↔`shopdemo-zent` 一组当时判为"保留"，
**2026-09-18 改判并删除**（见下方「示例目录收敛」）。
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

### 示例目录收敛（2026-09-18）

上面第 5 条收敛到 20 个目录后仍偏重，这轮按"**每个目录必须唯一承载一项框架能力**"再筛一遍，删掉 2 个：

- **`shopdemo-zent`** —— 结构性重复：它就是 `shopdemo/generated-sample` 的**同一个 `order` 模块**
  （model / persistence / service / api / module / root 一一对应），只把持久化换成 zent；而 zent
  已由 `zent-modulith` 演示（还带 `smoke.sh` 的真实请求遍历）。此前判"保留作两种持久化的对照"，
  实测这个"对照"没有任何断言在守，属纯维护面。
- **`tenant-ai`** —— 与 `ai-ops`（AI 流水线 + HTTP 审批队列）和 `tenant-mgmt`（租户隔离）双向重叠。
  删前核实过它"独有"的两项**并不独有**：`workflow.toMermaid` 在 `src/ai/workflow.zig` 有单测、
  `skill_export.toOpenApi/toSkillsJson` 在 `src/ai/skill_export.zig` 有单测且被 `zmodu ai
  export-skills / openapi` 的 CLI smoke 端到端覆盖，`SkillRegistry` 也有自己的单测 —— 所以删掉
  不会留下"无人调用因而无人编译"的公开 API（`LogRotator` 那类问题）。

保留判定：`metaverse-creative`（结算链路 PaymentIntent 幂等 → 双分录 Ledger → OwnershipTransfer →
Outbox 无替代）与 `zmsaas` 后端（`Preflight` + 池/积压指标的接线参考）**保留**；
`zmsaas/frontend`（SolidStart，CI 从不构建）本轮不动。

影响面同步（**注意：`examples/README.md` 那句"每个目录在索引表里恰好出现一次"没有任何门禁在查**，
漏改不会红）：`.github/workflows/ci.yml` 的构建列表（两处，`build-and-test` 与 `examples` job）、
`doctor` 循环、`test` 循环；`examples/README.md` 索引表 + 段落；`docs/AI_DEV_GUIDE.md` /
`AI_SKILLS.md` / `AI_ORCHESTRATION.md` / `ZMODU_CLI_INTEGRATION.md` / `PRODUCTION_ROADMAP.md` 的
指向示例的句子（改成描述能力或改指 `ai-ops`，不留悬空路径）。收敛后：**18 个目录（17 个示例 + `_shared`）**，
CI 构建 15 项 + `zmsaas/backend`。

### 仍待完善（2026-09-18 复核，v0.26.0）

> 口径：本节标题与页脚的版本号都指**仓库当前版本**（`build.zig.zon` 的 `.version` = **v0.26.0**）。
> 正文里出现的「（v0.25.0 本轮）」「v0.24.0」是**该修复落地时**的版本，属历史事实，不改。
> 同理，凡提到 `examples/shopdemo-zent` 或 `examples/tenant-ai` 的句子，都是**2026-09-18 删除之前**
> 的审计记录（删除理由见上方「示例目录收敛」）—— 那是当时的真实状态，不改写；当前目录清单以
> `examples/README.md` 的索引表为准。

**按 ROI 排序（每条都带证据；前三条是"功能级"而非文案级）**

1. ✅ **`zmodu scaffold` 生成的项目拉不到框架**：`tools/zmodu/src/main.zig:219-220` 仍钉 `v0.13.9` 且 hash 是占位符
   `0.13.7-AAAA…A`；生成文本 `:1095/:1416/:5417/:7421` 停在 v0.13.9/v0.14.4，`saveManifest`(`:5512`) 写 `0.14.9`。
   `scripts/check-version.sh` 只校验 5 个顶层文档，**`tools/` 不在护栏内** —— 这是版本漂移的根，先补护栏再改值。
   （2026-09-18 修：`scripts/check-version.sh:31-104` 新增 4 项 `tools/` 护栏（框架形状 pin 必须 == 当前版本、
   非白名单 `0.x.y` 字面量报错、`tools/zmodu/build.zig.zon` 版本必须相等、scaffold 依赖 hash 不得是占位符）；
   `tools/zmodu/src/main.zig:231` 的 tarball URL 改为 `ZMODU_VERSION` 拼接、`:238` 换真 hash；
   `rg -n '0\.13\.9|0\.14\.9|0\.13\.7-AAAA' tools/zmodu/src/` 为空）
2. ✅ **内置技能全落默认 `.action = .execute` + `isInert()` 盲区**：`grep -rn "\.action = " src/` 非测试仅 `skill.zig:150`
   的转发；`business/admin/schedule/notify/mcp` 的技能全落 `.execute`（`skill.zig:30`）。按 `AGENT_RUNTIME.md` §二 推荐配
   `allow = 读工具 + allow_execute = false` 会**全拒**，而 `guard.zig:87` 的 `isInert()` 只看 `allow.len` → 不报警。
   改：读类工具补 `.action = .read|.propose`；`isInert()` 纳入类别维度。
   （2026-09-18 修：内置技能逐个显式声明类别 —— `src/ai/business.zig:106/154/202`、`src/ai/kpi.zig:61`、
   `src/ai/notify.zig:126`、`src/ai/schedule.zig:47/71/109/130`、`src/ai/admin.zig:107/134/160/184/209/253/274`、
   `src/ai/actions.zig:66/83/221/304`、`src/ai/approval_api.zig:133`、`src/ai/approval.zig:248`；
   类别维度的盲区改由注册表侧补：`SkillRegistry.auditPolicy` + `PolicyHealth.isInert()/hasClassBlindSpot()`
   （`src/ai/skill.zig:99,242`）会列名"被类别闸门拒掉"的工具，测试见 `:545` / `:608`。
   `Guard.isInert()` 本身仍只看 `allow.len`（`src/ai/guard.zig:87`），故这一条的"改"按 `PolicyHealth` 落地）
3. ✅ **`Workflow` 的 `.agent` 步骤无 guard 途径**：`src/ai/workflow.zig:615-619` 现搓裸 `Agent{provider,registry,budget}`，
   且 `Workflow`(`:140-167`) 没有 guard 字段 → workflow 里的 agent 天然无界。改：加字段并透传。
   （2026-09-18 修：`Workflow` 新增 `guard: ?*guard.Guard` 字段（`src/ai/workflow.zig:153`），`.agent` 步骤经
   `agentForStep()` 透传 `.guard = self.guard`（`:606`）；测试 `workflow .agent steps inherit the workflow guard`（`:1297`））
4. ✅ **scaffold `--with-agent` 生成无 guard 的裸 `Agent{}`**：`tools/zmodu/src/main.zig:6011-6019`；`:6085` 的 handler 也不设
   tenant/user（落库恒 0）。改：生成 `AgentSpec{ .guard = … }` + `SkillContext{ .tenant_id = ctx.tenantId(), … }`。
   （2026-09-18 修：模板生成 `guard: zigmodu.ai.Guard = zigmodu.ai.Guard.init(.{})`（`tools/zmodu/src/main.zig:6127`）
   + `setGuard()`（`:6140`），装配 `Agent{ .guard = &self.guard }`（`:6150`）；handler 侧 `fn tenantId(ctx)`（`:6214`）
   与 `ctx.userIdInt(i64)`（`:6233`）填 `SkillContext`。实测 `scaffold --with-agent` 的生成项目 `zig build` exit 0，
   `rg '\.guard|tenantId\(ctx\)' src/modules/ai/agent/` 命中模板产物）
5. **`/cluster/health` 的 `node_id` 是硬编码 `"node-id"`** —— ✅ **已完成（v0.25.0 本轮）**：`ClusterHealth.healthJson` 改读
   `ClusterBootstrap.getConfig().node_id`（新增最小只读 getter），并加测试断言 health JSON 的 `node_id` == 配置值。
6. ✅ **`tools/zmodu/src/mcp_server.zig:557` 断言版本 `"0.14.9"`**，实际来自 `build.zig.zon`（0.25.0）→ 该断言与当前版本不可能
   同时成立（若是活路径，需要改成读 `ZMODU_VERSION`；若是死路径，顺手删）。
   （2026-09-18 修：断言改为读单一真源 `main_mod.ZMODU_VERSION`（`tools/zmodu/src/mcp_server.zig:559`，
   `tools/call` 的 `version` 响应也用它，`:95,:179`）；`rg -n '0\.14\.9' tools/zmodu/src/` 为空）
7. ✅ **死测试文件**：`src/core/cluster/DistributedIntegrationTest.zig` 的 **11 个 test 从 `src/tests.zig` 不可达**，自 2026-07-06
   起零编译（与 doctor 那次同类）。改：接进测试根或删除（它已登记在 deadcode baseline）。
   （2026-09-18 修：已接进测试根 —— `src/tests.zig:77` `_ = @import("core/cluster/DistributedIntegrationTest.zig");`）
8. ✅ **CI 的 doctor 循环漏两个 module-layout 示例**：`ci.yml:246` 只跑 tenant-mgmt/tenant-shop/shopdemo/zent-modulith/alpha-engine，
   而 `metaverse-creative`（4 个 `module.zig`）与 `shopdemo-zent`（1 个）从不 doctored；`examples/tenant-mgmt` 至今**零测试**。
   （2026-09-18 修：doctor 循环补上 `shopdemo-zent` 与 `metaverse-creative`（`.github/workflows/ci.yml:167`）；
   `examples/tenant-mgmt` 补 `src/tests.zig`（2 个 test：模块图 + 路由表）与 `build.zig:54` 的 `test` step，
   并进 CI test-step 循环（`ci.yml:337`））
9. **`docs/UPGRADING.md` 止于 v0.15.46** —— ✅ **已完成（v0.25.0 本轮）**：补上 v0.22–v0.25 的破坏性/行为变更（`ModuleContext.runtime()`、
   `Tool.action` 默认、`Agent.memory` 注入规则、`DocSnippets` 门禁、示例目录删除、`minimum_zig_version`、多节点 fail-closed + `.transport`、
   `RaftTransport`、门面 `tick()`/入站监听、Raft 计票口径、Saga timeout 生效、`TransactionJournal`）。
10. **文档数字/版本漂移** —— ✅ **已完成（v0.25.0 本轮）**：`docs/PRODUCTION_ROADMAP.md:245`（42 文件/12,216 行 → 实测 45/13,919
    行，≈14.0%，并把复算命令写进文档）、
    `docs/BEST_PRACTICES.md:108`（root.zig 157/163 → 158/164）、`README.md:65`（改为已有 `TransactionJournal` 持久化协调日志）、
    `docs/API.md:581`（"per-connection stack" → 只 sizing accept-loop 线程栈）、`docs/CLUSTER-QUICKSTART.md:35`（补 `tick()` 也驱动
    `raft.tick()` + `.transport` 时 `start()` 起入站监听）、`examples/{tenant-mgmt,metaverse-creative}` 版本号 → v0.25.0；
    `docs/AI_SKILLS.md` 与 `AI_ORCHESTRATION.md` 各加指针指向 `AGENT_RUNTIME.md`。

**导出孤儿**（`root.zig` 导出、src + examples 零引用；建议逐个"找消费者或删"）：
`ClusterNodeView` · `ClusterSnapshot` · `cluster_health`/`clusterHealthJson` · `MessageQueue` · `LoadBalancer` ·
`ModuleInteractionVerifier` · `PluginManager` · `HotReloader` · `IntegrationTest` · `load_shedder` · **`FrozenMap`**
（`AGENTS.md` 明确推荐它，但框架内零消费者 —— 属于"文档承诺的入口没人用"）。

**测试跳过面**：`SkipZigTest` 共 82 处，主因是 loopback 权限（29×）、Windows（10×）、`REDIS_URL`(5×)、`NATS_URL`(3×)
与各中间件 URL —— 都属环境门控，不是缺口；真缺口只有上面第 7 条。

### CLI 与门禁现状（2026-09-18 复检）

- ✅ **`zmodu scaffold` 生成的项目仍不能 `zig build`**（实测 9 错，exit 1）。模板缺陷 4 处：
  `tools/zmodu/src/main.zig:3665/3671/3673/3681/3683` 把字面量 `1` 传给 `shared.errors.BizCode`（枚举）；
  `:3526`+`:3368` 对 `?i64` 做 `<` 比较；`:8677` 生成的 `tests.zig` 不可编译（硬编码 `.name = "test"` 不补必填字段）；
  `:3563` 生成的 `.nest` 非 fmt-clean。**实测：只补前两处 `zig build` 即通过（产出二进制）；补全 4 处才是完整可用产物。**
  （2026-09-18 修：四处都改了 —— `BizCode` 一律用枚举成员（`main.zig:1752-1754` 等 `R.wrapErr(ctx, .not_found, …)`，
  `rg 'wrapErr\(ctx, [0-9]' tools/zmodu/src/main.zig` 为空）；租户列可空时改按 `entity.?.tenant_id != null`
  判断（`main.zig:3522-3536`）；生成器输出统一过 `appendFooter()` 消掉多余空行（`:194-201`）。
  复现：`zig build -p <tmp>` 出新 CLI → `zmodu scaffold --sql <2 表 schema> --name myapp` → 生成项目
  `zig build` exit 0、`zig build test` exit 0、`zig fmt --check src` exit 0。
  残留：生成的顶层 `build.zig` 模板仍带 3 处行尾空格（`zig fmt --check build.zig` exit 1，但 `zmodu ci` 的 fmt
  步只扫 `src/tools/examples`，故不影响门禁）；`zmodu ci` 在新生成项目上仍 FAIL verify + deadcode。）
- ✅ **`zmodu ci` 在 18 个有 build.zig 的示例里 9 个 FAIL**（compile 全 PASS）：deadcode 8 个（未用 `std`/字段/函数）、
  verify 1 个（`tenant-shop` 的 `shop_bff/{model,persistence,service}.zig`）、audit 4 个（`shopdemo` 99 条 b4/b13、
  `metaverse-creative` 12 条、`shopdemo-zent` 4 条、`tenant-mgmt` 2 条）。
  （2026-09-18 复测：`for d in $(find examples -maxdepth 2 -name build.zig | xargs -n1 dirname | sort); do zmodu ci "$d"; done`
  → **只剩 1 个 FAIL**：`examples/tenant-shop` 的 `[verify]`（现在报 `shop_bff/*` 与 `admin_bff/{model,persistence,service}.zig`
  共 6 个文件）；**deadcode 与 audit 已全部 PASS** —— 上面点名的 `shopdemo`（99 条 b4/b13）、`metaverse-creative`（12 条）、
  `shopdemo-zent`（4 条）、`tenant-mgmt`（2 条）现在都是 `[audit] PASS`，`tenant-shop` 的 verify 一条仍成立）
- ✅ **口径不一致**：`zmodu ci` 的 audit 步骤**忽略 `.zmodu/audit-baseline.json`**（`tools/zmodu/src/audit.zig:1626`
  的 `auditJsonFor` 硬编码 `added = violations.len`）→ 有 baseline 的 `tenant-mgmt` 单独跑 `zmodu audit` 是
  `pass:true`，在 `zmodu ci` 里却 FAIL；而 CI 的 audit job 只跑 `zmodu audit` → **CI 绿、`zmodu ci` 红**。
  （2026-09-18 修：`auditJsonFor` 现在读 `<dir>/.zmodu/audit-baseline.json` 并走 `compareBaseline`
  （`tools/zmodu/src/audit.zig:1650-1657`），`cmdAudit` 同样以 `baseline.added == 0` 判 pass（`:159-180`）；
  `zmodu ci` 的 audit 步因此与 `zmodu audit` 口径一致）
- ✅ 遗留项：本轮已修 1/2/3/5/6/7；~~**4 仍成立**~~（`main.zig:6040-6047` 的 `--with-agent` 仍生成无 `.guard` 的裸 `Agent{}`，
  `:6104` 的 `SkillContext` 仍无 tenant/user）；~~**8 只剩 README 侧**~~（`examples/README.md:165/288-289/404` 未补 `tenant-mgmt`）。
  （2026-09-18 修：第 4 条已修 —— `--with-agent` 模板生成 `.guard`（`tools/zmodu/src/main.zig:6127/6150`）
  并用 `tenantId(ctx)` / `ctx.userIdInt(i64)` 填 `SkillContext`（`:6214,:6233`）；第 8 条已修 ——
  `examples/README.md:165`（索引行）、`:288-289`、`:404` 都已列入 `tenant-mgmt`）

### 新用户路径卡点（2026-09-18，按严重度）

1. ✅ **第一步就 404**：`README.md:183` 把工具链钉在 `zigup 0.17.0-dev.1567+f0354179a`，而该 dev 版本已被 ziglang 镜像
   回收（`AGENTS.md:345` 自己都写了"dev.1567 已 404"；`ci.yml:33` 用的是 `1970+67f39b551`）；`:184` 又只给
   `brew install zig`（stable），与本仓的 `std.process.Init` 等 dev API 不兼容。
   （2026-09-18 修：`README.md:218` 与 `docs/QUICK-START.md:13` 都改成 CI 同款 `zigup 0.17.0-dev.1970+67f39b551`；
   `README.md:224` / `QUICK-START.md:8` 明确写"`brew install zig` 装的是 *stable*，编译不了本仓"，并注明
   `.github/workflows/ci.yml` → `ZIG_VERSION`（`:33`）才是真源。`rg -n 'dev\.1567' README.md docs/QUICK-START.md` 为空）
2. ✅ **"5 分钟教程"本身编不过**：`docs/QUICK-START.md:68` 的 `app` 通篇未定义、`:65` 的 `generateDocs` 少 `io` 参
   （真签名 4 参）；`:16` 说 `zig version` 显示 `0.17.0` 与 README 的 dev 钉版、AGENTS 互相矛盾；`:86` 调
   `b.dependency("zigmodu")` 而全篇没给 `build.zig.zon` 依赖声明。README 里 `const UserModule`（非 `pub`）+ 传
   `.{user}`（文件结构体无 `info`）同样编不过。
   （2026-09-18 修：`docs/QUICK-START.md:37` 是 `pub const UserModule`（注释点明 `pub` 的原因），`:84` 有
   `var app = try b.build(.{user.UserModule});`，`:77` 的 `generateDocs` 带满 4 个实参，`:25` 的 `zig version`
   期望值改为 `ci.yml` 的 `ZIG_VERSION`，`:97` 起补了 `build.zig.zon` 依赖声明（`:133` 的 `b.dependency("zigmodu")`
   因此有出处）；`README.md:236` 的 `UserModule` 也是 `pub`，`main` 走 `scanModules` / `startAll`）
3. ✅ **`AGENTS.md` 的核心代码模式是错的**：`:266/:286` 的 `ctx.paramInt("id")` 少类型参（真签名 `paramInt(T, key)`）；
   `:270/:272/:273/:287` 的 `ctx.json(200, .{ .ok = true })`——`ctx.json` 第二参是 `[]const u8`，值形态要用
   `jsonStruct`/`jsonValue`。**加重误导**：`:85` 声称 `DocSnippets.zig` 会抽查文档代码块，但该门禁只认
   builder/runtime/init 三种形态（`src/test/DocSnippets.zig:51-73`），这两类永远漏检。
   （2026-09-18 修：`AGENTS.md:266/286` 改成 `ctx.paramInt(i64, "id")`、`:270/272/273/287` 改成
   `ctx.jsonStruct(200, .{ … })`（`:287` 还带 `// NOT sendSuccess/sendFail`）；门禁同步扩容 —— `AGENTS.md:85`
   改口为"5 种形状"并点名这两类，检测器是 `jsonGetsStructLiteral`（`src/test/DocSnippets.zig:220`）与
   `paramIntMissingType`（`:237`）。`rg -n 'paramInt\("|ctx\.json\([0-9]' AGENTS.md` 为空）
4. ✅ **有文档背书的死代码**：`examples/production-deploy/README.md:49` 教 `Server.fromEnv(io, allocator, init.environ_map)`
   —— `fromEnv` 形参是 `std.process.Environ`（`Server.zig:2348`）而传的是 `*Environ.Map`，且函数体 `env.iterator()`
   只存在于 `Environ.Map`（toolchain `std/process/Environ.zig:337`）→ **一旦被实例化就编不过**，却全仓无人调用、
   无测试。"部署时唯一的 env 接线入口"是死的。另 `:19` 的 `Server.enable_http2` 真名是 `setHttp2Enabled()`。
   （2026-09-18 修：`Server.fromEnv` 形参改为 `*const std.process.Environ.Map`（`src/api/Server.zig:2355`）并补两个测试
   （`src/api/Server.zig:4458` / `:4478`）；`examples/production-deploy/README.md:19` 改用真名 `Server.setHttp2Enabled(true)`，
   `:49` 的调用与真签名一致）
5. ✅ **数据层文档自相矛盾**：`docs/ZENT.md:450-483` 标着"摘自示例"的推荐形态用的是手写 `zent.codegen.deinitEntity` 循环，
   而示例真码是 `deinitRows(&found)`（`examples/zent-modulith/.../catalog/persistence.zig:84`），同一文档 `:519/:618/:665`
   又要求用 `deinitRows`；`docs/MODULE_LAYERS.md:67` 的 `findById(self, tenant_id, id)` 与其"参考实现"
   `examples/tenant-shop/.../tenant/persistence.zig:26` 的 `findById(self, id)` 不符；`Backend` 口径不清
   （文档主推 `data.SqlxBackend`，但 `queryRowPartial` 只在 `*data.Client` 上存在）。`ZENT.md:532` 还写着 zent v0.39.2（实际 pin v0.67.0）。
   （2026-09-18 修：`docs/ZENT.md` 的"摘自示例"块已改成 `defer self.client.product.deinitRows(&found)`（`:479`），
   `:491` 注明"手写 `deinitEntity` 循环是旧写法，本仓库示例已全部改掉"；全文 `v0.39.2` 清零、口径为 zent v0.67.0
   （`:4` / `:530` / `:549`）；`docs/MODULE_LAYERS.md:62-64` 写清 `Backend` 两套方法（`*data.Client` → `queryRowPartial`，
   `data.SqlxBackend` → `queryRowPartialBorrowed`），`:72-74` + `:94` 说明租户键表用 `findById(self, tenant_id, id)`、
   租户主表退化为 `findById(self, id)`。`rg -n 'v0\.39\.2' docs/ZENT.md` 为空）
6. ✅ **孤儿文档**（无任何索引收录）：`docs/LOGGING.md`、`docs/MIGRATION_v04_to_v07.md`、`docs/ZIGMODU_NOTES.md`，
   以及 `docs/dev/**` 全部 14 个文件。
   （2026-09-18 修：`docs/README.md:48-50` 新增「Other documents」表逐条收录前三份，`:51` 收录 `docs/dev/` 目录；
   `ls docs/dev/ | wc -l` = 14）

### BEST_PRACTICES 自审（2026-09-18）

规模：2197 行 / 21 个 `##` / 79 个 `###` / 48 个围栏。链接与锚点**无断链** ✓；问题集中在"过时片段"与"结构"。

> ⚠️ 本节原始审计里写的 `:1547` 式**行号是 2026-09-18 快照**，其后文档有增删，行号必然漂移。
> **定位一律用 `grep` 按内容找**；下文已把行号引用换成内容描述，不再给出可漂移的数字。

**会误导读者（按严重度）—— ✅ 2026-09-18 已逐条修掉**
1. ✅ 「正确 vs 错误的内存管理」对照（现「内存管理 → 分配器使用」节）—— 标着「✅ 正确的内存管理」，却在 `defer allocator.free(buffer)` 之后 `return buffer`：**照抄即悬垂指针（静默 UAF）**。现改为两个真正确形态：「返回拷贝，所有权交给调用方」与「写入调用方提供的缓冲，不移交所有权」。
2. ✅ 「并发安全」节的 `ThreadSafeCounter`（现「安全实践 → 并发安全」节）—— 用了 **Zig 0.17 已删除的 `std.Thread.Mutex`**（现为 `std.Io.Mutex`，`lock`/`unlock` 需 `io` 参数），且 `Self` 未定义；而这是"并发安全"的正面示例。现按 `src/core/EventBus.zig` 的 `ThreadSafeEventBus` 真实写法重写。
3. ✅ 「阶段 4：服务网格」的能力表与「配置示例」—— `zigmodu.resilience.*` / `zigmodu.tracing.*` / `zigmodu.metrics.*` 三个命名空间**都不存在**。真身：`zigmodu.CircuitBreaker` / `zigmodu.RateLimiter`（`src/root.zig` §3），`zigmodu.observability.DistributedTracer` / `zigmodu.observability.PrometheusMetrics`（`src/observability.zig`）。已改。
4. ✅ 同两处的 `CircuitBreaker.init(5, 30000)` 与 `data.redis.Redis.init(allocator)` + `connect(host, port, .{})` —— 真签名分别是 `CircuitBreaker.init(allocator, name, cfg)`（`cfg` 字段是 `timeout_seconds` / `half_open_max_calls`）与 `data.redis.Redis.new(allocator, io, cfg)` + `connect()`。已改。
5. ✅ 「部署与 CI/CD」节的三处旧 API —— `std.process.getEnvVarOwned`（0.17 已移除，改走 `init.environ_map`）、`root_module.addDefine(...)`（不存在，改 `b.addOptions()` + `addImport("build_options", …)`）、CI 矩阵 `zig-version: ["0.16.0"]`（本仓走 `ci.yml` 的 `ZIG_VERSION`）。已改。
6. ✅ 测试节与阶段 2 示例里的 `zigmodu.extensions.ModuleTestContext`（真身 `zigmodu.ModuleTestContext`，`src/root.zig`）与 `zigmodu.extensions.AsyncEventBus`（**全仓无此类型** —— 整段已删除，换成 `ThreadSafeEventBus` 示例）。已改。
7. ✅ 本节开头的采样断言（"examples 里没有任何代码用 `ai.Agent`／全仓只有 3 处 `zmodu.builder`"）—— 已标 `（2026-09-17 采样）`、更新数字，并注明"以 `grep` 为准"。

**结构与口径（2026-09-18 部分处理）**
- ✅ 目录已**上移到正文之前**，并补录 `## 🔄 现状复核` 与本次新增的小节。
- ✅ 版本口径三处互斥已统一为**仓库当前 v0.26.0**（`build.zig.zon` 的 `.version`），页脚一并改。
- ✅ 自引用行号（如指向本文件/tools 某行的 `:231`）已换成按章节名/片段引用。
- ⏳ 仍未处理（属重构，本次范围外）：错误处理节 412 行塞了 15 个主题，建议拆；认证内容散在「JWT 密钥轮换」「Auth.optional」「JWT / 多端身份」三处；路线图节尾有第二套"阶段 3/4（模块数）"与上文同名；「演进决策树」「技术债务」「ClusterBootstrap」「Server.initWithConfig」各重复 2–3 次。

### 实践 ↔ 门禁一致性（2026-09-18）

「会炸/会漏」的规则**基本都有门禁**（`audit` b1–b22 + `check-production` + `DocSnippets` + `AiBoundary`）。缺口分三类：

**A. 只有约定、没有机制**（文档说得硬，机器不查）
`worker 归 app`（禁模块内 `Runtime.init`/`rt.shutdown`）· **裸 `Agent{}` 必带 guard**（只有 opt-in 的 `isGuarded()`）· `请求路径勿读 ClusterMembership 哈希表`（b20 只管文件作用域 `var …HashMap`）· 多副本 cron/迁移 `setLock` · `TransactionJournal.recover()` · `SagaStep.timeout_seconds`。

**B. 门禁比文档松**（原六处 → 复检出第七处 —— **2026-09-18 全部收窄**）
1. ✅ `scripts/check-production.sh` 原先**扫到第一个 `test "` 即止** —— `src/api/Server.zig` 首个 test 在 1445 行、全文 4487 行，约 3000 行生产代码完全不检。
   **新行为**：改为**扫全文件**，只在遇到 `test` **块**时跳过该块（内嵌 awk 扫描器按大括号配平，且先剥掉字符串/字符字面量与 `//` 注释再计数，所以 test 内的 `"{}"` 不会带偏配平）。副作用：在原本已强制的路径里新暴露 4 处（`src/redis/redis.zig` 1 处、`src/core/cluster/RaftTransport.zig` 3 处）并已修。
   **更正**：此前记的 `RaftElection.zig:991` 经核实落在 `test "log replication commit"` 块**之内**，是测试代码，被正确跳过 —— 不是 B1 的战果。
2. ✅ 强制前缀 **7 → 10**：新增 `src/ai/`、`src/extensions/`、`src/im/`。这三处 23 条裸 `catch {}` 已**逐条真实修复**（统一改成 `catch |err| std.log.debug/warn("[tag] … ({s})", .{@errorName(err)})`，行为不变、只多一条日志），**未使用豁免清单**。仍未修 3 条 WARN 区：`src/log/StructuredLogger.zig`(×2)、`src/runtime/timer_wheel.zig`(×1)。
3. ✅ 跨行 `catch {` + 换行 `}`：`check-production.sh`（awk 状态机，识别 `catch` / `catch |e|` / `catch {` 三种尾巴）与 `audit.zig`（`pending_catch_kw_line` / `pending_catch_brace_line`）两边都已支持。
4. ✅ `audit` b3 关键词补 `WITH`（CTE）/`PRAGMA`/`TRUNCATE`，并改为**大小写不敏感 + 标识符词边界**（`withContext` / `createTable` 不再被当 SQL）；同时新增"纯常量比较"抑制 —— `WHERE status = 'active'` 这类不再误报，含 `{s}`/`++` 的拼接仍报。
5. ✅ `audit` b17 改为**逐分配点判定**：命名分配只有在 `freeScanned(...)` 实参里以标识符边界出现该变量名时才算释放，匿名分配消耗一条未被认领的 `freeScanned` —— "一处 free 洗白全函数"已消除。
6. ✅ `check-deadcode.sh --update` 加了**单调性断言**：新增条数超过基线时**拒绝写入并 exit 非 0**（需显式 `--force`），写入时打印 `old -> new (+n / -m)` 摘要。`examples/**` **同日也从 WARN 提升为强制**（`EXAMPLES_MODE` 已删除）：`src`+`tools` 与 `examples/**` 现在**各自独立**扫描后比对基线 —— 不合并扫描是因为合并会改变 import 图、让 `src/api/Server.zig` 的某条判定凭空出现/消失。
7. ✅ `body_kind` 的**尾随标点盲区**已封：`x() catch {},`（switch 分支 / 初始化列表里的逗号）此前既不是 `{}` 也不是 `{};`，被判为 `other` 而**完全逃检** —— shell 扫描器与 `audit.zig` 的 `catchBodyKind` 两边都有这个洞，现已同时修掉并各加反证用例。

**C. 新能力未入册 / 推荐了但没人示范**
前三项 **2026-09-18 已入册**：`TransactionJournal` / `recover()`（「事务日志与 Saga 超时」节 + `AGENTS.md` DO/DON'T「长流程」行）、`SagaStep.timeout_seconds`（同节）、`jsonStruct` / `paramInt(T, key)`（「韧性」节参数层表与「错误响应形状」表的成功体一行）；`ai.AgentWorker` 已补进 `AGENTS.md` DO/DON'T；`AGENTS.md` 的 `zmodu ci` 已改成 **6 步**（含 doctor）。
**测试实践（2026-09-18 已修）**：`http.Testkit` 此前在 `examples/**` 只有 1 处真实用例（`examples/tenant-mgmt/src/tests.zig` 的 `openMemorySqlite`），`dispatch`/`signBearerToken` 零示例。更关键的是 `tools/zmodu/src/templates/orm/sqlx/test.zig.tpl` **从未被 `@embedFile`**（`orm_tpl.zig` 的 embed 列表里没有它），内容还是三个 `expect(true)` 空桩 —— 即"文档推荐、示例不示范、脚手架不产出"。现状：

- `examples/tenant-mgmt` 已用 `dispatch` + `signBearerToken` 写出 3 条真用例，含**跨租户隔离**（token 的 `aud` 决定可见行；猜别租户的 id 得 404）与"换一个 secret 签的同形 token 必须 401"。
- `test.zig.tpl` 已重写为可跑测试并**真正接线**：`orm_tpl.sqlx_test` + `writeModuleFiles` 对**单表模块**写出 `modules/<name>/test.zig`，`generateScaffoldTestsZig` 同步产出 `test { _ = @import("modules/<name>/test.zig"); }` 把它拉进 `zig build test`。多表模块不产出（模板按 `model.<<PASCAL_MODULE>>` 取类型，多表时类型名不对）。
- `Testkit.dispatch` 补了 `DispatchOptions.query`（percent-encoded 原样串，与 `path` 自带的 `?…` 可共存，同名 key 后者胜）——此前**任何 query 驱动路由都无法用 dispatch 测试**，包括脚手架自己生成的 `list*`（读 `ctx.queryInt(usize,"pageNo",1)`）。

**D. 顺带修掉的真缺陷：脚手架生成的 handler 从客户端分配器泄漏**

给脚手架补测试时发现 `generateModuleApi` 产出的 `list*` / `get*` handler **不释放 owned 返回值**：

- `list*`：`service.list*()` → `repo.findPage()`，其 `PageResult.arena` 由 **`Client.allocator`（长生命周期）** 分配，而 `ctx.allocator` 是**每请求 arena** ——请求结束的 arena 重置**回收不到**它，属**永久泄漏**（每请求一页）。
- `get*`：`service.get*()` → `repo.findById()` → `Client.queryRow()`，其字符串字段按 `sqlx.zig` 自己的注释就是"owned copies from the client's allocator and must be freed by the caller"。

**实测证据**（在生成的探针项目里，用 `std.testing.allocator` 调 `db.queryRow` / `db.queryRowsOwned` 且故意不释放）：
```
+- run test 9 pass (9 total); 3 leaks
  … queryRow … sqlx.zig:4834: return try scanStruct(self.allocator, T, rows.rows[0], …)
```
栈顶落在 `scanStruct(self.allocator, …)`，确认分配根在客户端分配器。

**关键陷阱：`ctx.allocator` 释放不了这些内存。** 生产里 `ctx.allocator` 是**每连接的 arena**（`Server.connFiber` 的 `arena_alloc`，每请求 `arena.reset()`）。`ArenaAllocator.free()` 是 **no-op**，所以"用 `ctx.allocator` 释放客户端分配器的内存"既不会报错、也不会释放——**看起来修好了，实际照漏**。这是本轮最容易写错的一点（我们的第一版修复就是这么写的，靠下面的反证才发现）。

**修法**（用分配它的那个分配器）：
- `list*` → `var result = try …; defer result.deinit(self.service.persistence.backend.allocator);` —— `SqlxBackend.allocator` 就是 arena 的 backing allocator，是唯一正确的实参（`PageResult.deinit` 新增的 doc 已写明：给别的分配器是 misuse，arena 路径上会被静默忽略）。
- `get*` → `defer sqlx.freeScanned(self.service.persistence.backend.allocator, model.X, entity);`
- `create*` / `update*` → `defer sqlx.freeScanned(ctx.allocator, …)` —— 这里**必须**是 `ctx.allocator`，因为 `bindJson` 是从它深拷贝出来的（`bindJson` 的文档契约就是"深拷贝、调用方可统一 free"）。两个方向的分配器不能互换。

**注意**：`repo.insert` 返回的是入参 `entity` 的**副本**，其字符串字段与 `entity` **别名同一片内存** —— 因此 `create*` 只 free `entity` 一次，**再 free `created` 就是双重释放**。这一点写进了生成器的注释。

**反证（生产形状）**：探针用 `std.testing.allocator` 作**客户端**分配器（可检测泄漏），`Server` 拿到的是**另一个 arena**（复刻 `connFiber` 的层次），然后真的 `dispatch` `list` 与 `get?id=1`：

| 生成代码里的释放 | 结果 |
|---|---|
| `defer result.deinit(self.service.persistence.backend.allocator)` + `get` 用 backend 分配器 free | **0 leak**（9/9 pass） |
| `defer result.deinit(ctx.allocator)` + `get` 不释放 | **2 leaks** —— `allocator.dupe(u8, str)` 分配的行字符串 |

**顺带**：`PageResult` 原来只有 `deinit(allocator)`，没有 `QueryResult` 那样的无参 `deinitArena()`（而 `QueryResult.deinitArena` 全仓**零使用**）。本轮补上了 `PageResult.deinitArena()` 及其测试，但**生成器暂时不用它** —— scaffold 出的项目 pin 的是已发布版本，用了会编译不过；等版本推进后再把生成器和文档切到 `deinitArena`（`repo.insert` 那类单行没有 arena，仍需 `freeScanned` + 客户端分配器）。

**E. "公开 API + 零调用者 = 从未被编译"：`LogRotator` 的教训**

`zigmodu.observability.LogRotator` 是正式导出的公开组件，但**全仓零调用**（`grep -rn LogRotator src/ tools/ examples/` 只有那一行导出）。Zig 惰性分析函数体，所以 `rotate()` 里的

```zig
std.Io.Dir.cwd().rename(self.io, old_name, new_name)   // 0.17 之前的签名
```

一直没报错 —— 0.17 里 `rename` 是 5 参自由函数 `rename(old_dir, old_sub_path, new_dir, new_sub_path, io)`。**任何用户一调用 `LogRotator.write` 就编译失败。** 光靠 `zig build test` 抓不到这类问题，因为"引用所有源文件"的编译测试只做文件级 import，不进函数体。

**修法与防复发**：

- 补 `initIn(allocator, io, dir, …)`（`init` 仍写 CWD，`initIn` 指向 `tmpDir`），修 2 处 `rename`；
- **加一条真正实例化它的测试**（`tmpDir` + 按大小轮转 + 断言 `.0`/`.1` 内容 + 超代数的文件不存在）。写这个测试时顺带纠正了我对语义的错误猜测：`max_size=10` + 4 字节写并不是"每次写都轮转"，而是两笔一滚 —— 断言得按真实语义写。
- **推广**：任何 `pub` 导出但无人调用的组件，都应当有一条把它**真正用起来**的测试。`deinitArena`（`QueryResult`/`PageResult`）同样属于这一类。

**同批收尾**：`check-production.sh` 的强制前缀补 `src/log/`、`src/runtime/`（此前只剩 3 条 WARN）；`zig build zmodu` 现在**同时安装**二进制（此前只 build+run，`zig-out/bin/zmodu` 会静默留着旧的，调用方驱动到陈旧 CLI）；`http.Testkit` 删掉查询解析的手工孪生实现，改为直接调 `Server.zig` 的 `parseQueryInto`（现在两边**不可能**再漂移）。

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
// 引入缓存模块（伪码：示意结构，非可直接编译）
const CacheModule = struct {
    pub const info = api.Module{
        .name = "cache",
        .dependencies = &.{"database"},
    };
    // 本地缓存 + Redis 分布式缓存
};

// 异步事件处理：业务事件走线程安全的 ThreadSafeEventBus（L1 层）
// —— 没有 `zigmodu.extensions.AsyncEventBus` 这个类型。
var bus = try zigmodu.ThreadSafeEventBus(OrderCreated).init(allocator, io);
defer bus.deinit();
try bus.subscribe(onOrderCreated);   // 回调在 publish 的线程上同步跑，保持短小
bus.publish(.{ .order_id = 42 });
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

| 能力 | 框架支持（真实导入路径） | 配置 |
|------|--------------------------|------|
| 断路器 | `zigmodu.CircuitBreaker` | 5 次失败，30 秒半开 |
| 限流 | `zigmodu.RateLimiter` | 令牌桶 1000/s |
| 隔离舱 | `zigmodu.Bulkhead` | 每组并发上限，一个失败不拖垮全部 |
| 自适应卸压 | `zigmodu.load_shedder` | 超载时拒绝，而不是无限排队 |
| 分布式限流 | `zigmodu.data.redis_rate_limit.RateLimiter` | Redis INCR+EXPIRE 固定窗口（跨实例，fail-closed）|
| 分布式追踪 | `zigmodu.observability.DistributedTracer` | 采样 + `OtlpExporter` 导出 |
| 指标收集 | `zigmodu.observability.PrometheusMetrics` | /metrics 端点 |
| gRPC | `zigmodu.GrpcServiceRegistry` / `zigmodu.GrpcClient` | HTTP/2（unary + stream） |
| 消息队列 | `zigmodu.NatsClient` / `zigmodu.MessageQueue` | 没有 MQTT 实现，别照抄旧名 |

> 韧性/观测**没有** `zigmodu.resilience.*` / `zigmodu.tracing.*` / `zigmodu.metrics.*` 这三层命名空间：
> 韧性原语直接挂在 `zigmodu.*`（`src/root.zig` §3 RESILIENCE），追踪与指标在 `zigmodu.observability.*`
> （`src/observability.zig`）。见到旧写法请一并改。

**配置示例**：

```zig
const CircuitBreaker = zigmodu.CircuitBreaker;
const RateLimiter = zigmodu.RateLimiter;

// 断路器：init(allocator, name, Config) —— Config 四个字段都要给全
var cb = try CircuitBreaker.init(allocator, "order-service", .{
    .failure_threshold = 5,   // 连续 5 次失败 → OPEN
    .success_threshold = 2,   // HALF_OPEN 期间 2 次成功 → CLOSED
    .timeout_seconds = 30,    // OPEN 保持 30 秒后转 HALF_OPEN
    .half_open_max_calls = 3, // HALF_OPEN 最多放 3 个探测请求
});
defer cb.deinit();

var limiter = try RateLimiter.init(allocator, "api", 1000, 100);
defer limiter.deinit();

// 分布式限流（跨实例共享固定窗口；Redis 不可用 → error，fail-closed）
var redis = try data.redis.Redis.new(allocator, io, .{
    .host = "127.0.0.1",
    .port = 6379,
});
defer redis.deinit();
try redis.connect();
var dist_limiter = data.redis_rate_limit.RateLimiter.init(&redis);
const allowed = dist_limiter.allow("login:user-1", 5, 60) catch |err| {
    // fail-closed：限流后端不可用时不放行，按拒绝处理
    std.log.warn("rate limiter backend down: {s}", .{@errorName(err)});
    return error.RateLimited;
};
if (!allowed) return error.RateLimited;

// 分布式追踪：init(allocator, tracer_name, service_name)
var tracer = try zigmodu.observability.DistributedTracer.init(allocator, "order-tracer", "order-service");
var span = try tracer.startTrace("createOrder");
defer tracer.endSpan(span);
```

跨实例 WebSocket fanout（任意实例 publish → 全集群所有实例本地 broadcast）走
`zigmodu.DistributedEventBus`（`init(allocator, io, node_id)` + `publish` / `subscribeWithContext`，
见 `src/core/DistributedEventBus.zig`）。下面这段**省略了 `bus` 的创建与 `ws_server` 的定义**：

```zig
// （伪码：假设已有 var bus = try zigmodu.DistributedEventBus.init(allocator, io, node_id);）
try bus.subscribeWithContext("ws.fanout", &ws_server, struct {
    fn onEvent(ctx: ?*anyopaque, ev: zigmodu.DistributedEventBus.NetworkEvent) void {
        const s: *WebSocketServer = @ptrCast(@alignCast(ctx.?));
        s.broadcast(ev.payload);
    }
}.onEvent);
try bus.publish("ws.fanout", "{\"type\":\"notice\"}");
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
- 断路器配置：`CircuitBreaker.init(allocator, name, Config)`（完整字段见上文阶段 4「配置示例」）
  ```zig
  var cb = try zigmodu.CircuitBreaker.init(allocator, "order-service", .{
      .failure_threshold = 5,   // 5 次失败 → OPEN
      .success_threshold = 2,
      .timeout_seconds = 30,    // 30 秒后转 HALF_OPEN
      .half_open_max_calls = 3,
  });
  defer cb.deinit();
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

### `*Ctx` 后缀 vs `ctx` 字段：看起来不一致，其实各自都对

给查询带上"截止时间（请求预算）"有两副面孔，读代码时容易当成历史遗留：

| 对象 | 形式 | 例子 |
|------|------|------|
| `sqlx.Client`（跨请求共享 / 池化） | 方法名 **`*Ctx` 后缀** | `client.queryRowsCtx(sql_ctx, T, sql, args)`（`Client` 的 58 个方法里 19 个是 `*Ctx` 变体） |
| `data.SqlxBackend`（`Orm.withContext()` 里的**按请求副本**） | 一个 **`ctx` 字段** | `backend.ctx`；backend 的查询/执行都把它转交给对应的 `*Ctx` |

规则一句话：**共享句柄只能用传参，请求局部副本才能用字段。**

- `*Client` 是被池 / `ConnectionRegistry` 跨请求复用的对象。把 per-request 的
  `SqlContext` 存成它的字段就是**数据竞争**（A 请求的 deadline 会看见 B 请求的），
  所以它只能"改调用形式"——多一个参数，或方法名带 `Ctx`。
- `SqlxBackend` 不同：`Orm.withContext(ctx)` 返回的是**按请求拷贝**的一份值，
  字段天然请求局部，一次赋值就覆盖它全部的查询/执行方法——这里是字段更省事，也正确。
  （事务路径是例外：`beginTx` / `execTx` / `queryRowTx` 不带预算，要预算得用
  `Client.transactCtx`。）

用法对应：

- 裸 sqlx：预算**每次**传 —— `client.queryRowsCtx(ctx.sqlContext(), T, sql, args)`；
- 仓储层：一行覆盖该请求**所有**查询 —— `var scoped = self.persistence.orm.withContext(ctx.sqlContext())`，
  此后由它建的 `data.Repository(T)` 都继承预算（展开见下面「请求预算要传给存储」一节）。

**不要**把这条读成"将来要统一成字段"：对共享的 `Client` 那样做是错的。

---

## 🏗️ 模块设计原则

### 单一职责原则
每个模块应只负责一个功能领域（**片段**：`api.Module` 与两个回调是示意结构，非完整可编译模块）：
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
每个模块必须实现完整的生命周期（**片段**：只示 `init` / `deinit` 的形状与注释约定）：
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
// ✅ 良好的代码结构（片段：`validateRequest` / `checkInventory` / `createOrderEntity` /
//    `publishOrderCreated` 是示意调用，未在上下文给出定义）
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
// （片段：`Request` / `connectToDatabase` 是假设的上下文，`// ...` 处省略）
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
| **成功体（值形态）** | `ctx.jsonStruct(200, .{ .ok = true })` —— `ctx.json` 的第二参是 `[]const u8`（预序列化 body），**不能**直接传结构体；别名 `ctx.jsonValue` |
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
// （片段：`Adapter` 是示意类型；`"..."` 是占位值）
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
| **路径参数转整数** | `ctx.paramInt(T, key)` —— **两参，第一个是类型** | 例：`ctx.paramInt(i64, "id")`；解析失败返回 `error.BadRequest`。写成 `ctx.paramInt("id")` 编译不过（门禁 `DocSnippets.paramIntMissingType` 会拦） |
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

### 请求预算要传给存储，否则超时只是"事后 408"

`request_timeout_ms` 原先**只做一件事**：handler 返回后比一下耗时，超了就改发 408
（`Server.zig` 的 `elapsed_ms > server.request_timeout_ms`）。**它不打断任何东西** ——
慢查询照样跑完、照样占着连接池，而客户端已经走人。

现在 `Context` 带着这个预算，一行即可把它送进存储（`Context.setDeadline` 在请求进入时自动
armed，`0` 表示不限）：

```zig
fn listOrders(ctx: *http.Context, self: *State) !void {
    // 这一行之后，本请求**所有**仓储查询都继承预算（不是每查询一行）
    var scoped = self.persistence.orm.withContext(ctx.sqlContext());
    const repo = data.Repository(model.Order){ .orm = &scoped };
    ...
    // 裸 sqlx 同理：client.queryRowsCtx(ctx.sqlContext(), T, sql, args)
}
```

语义边界（**必须知道**，否则会误判为"取消"）：

- `SqlContext.isDone()` 只拒绝**尚未开始**的语句 —— sqlx 没有飞行中取消。
  所以这个预算是**防止请求在预算耗尽后继续堆查询**，不是"到点砍掉正在跑的那条"。
- 不调 `withContext` / `sqlContext()` 时行为与改动前**完全一致**（默认 `.{}` = 无截止），
  所以这是**按 handler opt-in**，不是全局行为变更。
- `Orm.withContext` 返回的是**副本**：`repo.orm` 指向它，副本要活到仓储用完（同一作用域即可）。
- 第三方 backend 若没有 `ctx` 字段，编译期会直接报错并告诉你该加什么。

### 多租户：把隔离从"记得调"变成"编译不过"

`Repository(T)` 同时提供 `findById` 和 `findByIdForTenant`，而编译期守卫只保证"调用 `*ForTenant`
时模型必须有租户列" —— **它不阻止你对租户模型调用无作用域变体**。模型带 `tenant_id` 时
`repo.findById(id)` 照样跨租户返回，防线是"人记得"。

**模型 opt-in 一行，就变成编译期强制**：

```zig
pub const Order = struct {
    pub const sql_table_name: []const u8 = "orders";
    /// 开启后，下列无作用域方法在本模型上**编译错误**。
    pub const sql_tenant_column: ?[]const u8 = "tenant_id";
    id: i64,
    tenant_id: i64,
    ...
};
```

- 17 个无作用域方法（`findById` / `findAll` / `count` / `findPage*` / `insert*` / `update*` /
  `delete*` / `findByIds` / `upsertMany` …）全部被守卫；错误信息点名对应的
  `*ForTenant` 或逃生舱名字，并指出调用点。
- **逃生舱**：跨租户是合法需求的场景（平台管理员 / 对账 / 导出）写更长的
  `findByIdUnscoped` / `findPageUnscoped` / …。命名原则是**"安全的名字最短"** ——
  危险的那条必须多打几个字，且代码里一眼可见。
- **未声明 `sql_tenant_column` 的模型完全不受影响**（守卫第一句就是
  `tenant_column orelse return`），所以既有项目升级不需要改任何东西。
- `zmodu scaffold` 生成的 `model.zig` **默认就带这一行**（表里真有租户列时才写），
  新项目默认安全。

口径与验证：`scripts/check-tenant-scope.sh` 用三个 fixture 锁死"守卫开火 / 逃生舱可用 /
未 opt-in 的模型不受影响"，进 CI。

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
// （伪码：`...` 处省略了参数与函数体，只示"内联 struct 是不同类型"这一点）
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
const std = @import("std");
const Allocator = std.mem.Allocator;

// ✅ 正确（一）：把所有权交给调用方 —— 就不要再 defer free
//    契约：返回的切片归调用方所有，调用方负责 free。
pub fn processData(allocator: Allocator, input: []const u8) ![]u8 {
    const buffer = try allocator.alloc(u8, input.len);
    errdefer allocator.free(buffer); // 只兜住"本函数失败"这一条路径

    @memcpy(buffer, input);
    // 处理数据...

    return buffer; // 所有权随返回值移交；此处绝不 free
}

// ✅ 正确（二）：本函数保留所有权 —— 返回拷贝给调用方
pub fn processDataCopy(allocator: Allocator, input: []const u8) ![]u8 {
    const buffer = try allocator.alloc(u8, input.len);
    defer allocator.free(buffer); // 本函数拥有 buffer，退出时归还

    @memcpy(buffer, input);
    // 处理数据...

    return allocator.dupe(u8, buffer); // 交出的是拷贝，与 buffer 无关
}

// ❌ 错误：标着"确保释放"，释放后却把同一块内存返回 —— 悬垂指针（静默 UAF）
pub fn danglingAlloc(allocator: Allocator, input: []const u8) ![]u8 {
    const buffer = try allocator.alloc(u8, input.len);
    defer allocator.free(buffer); // 返回前就把内存还了
    @memcpy(buffer, input);
    return buffer; // ✗ 调用方拿到的是已释放内存
}

// ❌ 错误：分配到堆、没人释放，调用方也不知道要 free
pub fn badPractice() ![]u8 {
    const buffer = try std.heap.page_allocator.alloc(u8, 1024);
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
const std = @import("std");
const zigmodu = @import("zigmodu");

// 被测模块
const UserModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "user",
        .description = "User module",
        .dependencies = &.{},
    };
    pub fn init() !void {}
    pub fn deinit() void {}
};

// ✅ 良好实践（一）：模块级测试用 ModuleTestContext
//    真身是 `zigmodu.ModuleTestContext`（src/root.zig）——
//    **没有** `zigmodu.extensions.ModuleTestContext` 这一层。
test "用户模块 - 装 mock 并查表" {
    var ctx = try zigmodu.ModuleTestContext.init(std.testing.allocator, "user");
    defer ctx.deinit();

    try ctx.registerMockModule(zigmodu.createMockModule("user", "User module", &.{}));

    const module = ctx.modules.get("user");
    try std.testing.expect(module != null);
    try std.testing.expectEqualStrings("user", module.?.name);
}

// ✅ 良好实践（二）：走真实 Application 生命周期 + 依赖校验（validate_on_start）
fn createOrder(quantity: usize) !void {
    if (quantity == 0) return error.InvalidQuantity;
}

test "订单模块 - 异常路径" {
    var app = try zigmodu.Application.init(
        std.testing.io,                 // 第一个参数是 io，不是 allocator
        std.testing.allocator,
        "order-failure",
        .{UserModule},
        .{ .validate_on_start = true },
    );
    defer app.deinit();
    try app.start();
    defer app.stop();

    try std.testing.expectError(error.InvalidQuantity, createOrder(0));
}
```

> 参考实现：`examples/basic/src/tests.zig`（ModuleTestContext + mock + 生命周期 + 依赖校验）
> 与 `examples/tenant-mgmt/src/tests.zig`。请求级断言用 `http.Testkit`（`dispatch` /
> `signBearerToken` / `openMemorySqlite` / `SseRecorder`）。

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

### 跨进程事务日志：`TransactionJournal` + `recover()`（必须接）

单机 `beginTx` 管不了"协调者进程崩在 prepare 与 commit 之间"：参与者锁着资源，
协调者自己什么都记不住 —— 重启后没人知道这笔事务该提交还是回滚。这就是 **in-doubt**。

`zigmodu.TransactionJournal`（`src/core/TransactionJournal.zig`）是**追加写**的协调者日志：
每次状态迁移插一条记录，崩溃最多丢最后一条，不会损坏已写的。接进 `TwoPhaseCommit` 后，
`prepared` 记录在任何参与者收到 commit 指令**之前**落盘。带 journal 的协调者一旦
写不进日志就拒绝推进（fail-closed）。

```zig
const zigmodu = @import("zigmodu");
const data = zigmodu.data;

// 启动期一次：建表 + 挂到协调者上
var journal = zigmodu.TransactionJournal.initWithBackend(
    allocator,
    data.SqlxBackend{ .allocator = allocator, .client = &db },
);
defer journal.deinit();
try journal.migrate();               // CREATE TABLE IF NOT EXISTS（三驱动通用，表名可配）

var tpc = zigmodu.TwoPhaseCommit.init(allocator);
defer tpc.deinit();
tpc.setJournal(&journal);            // ← 不接这一步，协调者就是纯内存的

// 进程重启后（或在 supervisor 的启动序列里）：把悬挂事务捞出来交人工/补偿
const in_doubt = try tpc.recover(allocator);
defer zigmodu.TransactionJournal.freeInDoubt(allocator, in_doubt);
for (in_doubt) |tx| {
    // tx.tx_id / tx.participants / tx.updated_at —— 只报告
    std.log.warn("in-doubt tx {s} prepared at {d}, participants={any}", .{ tx.tx_id, tx.updated_at, tx.participants });
}
```

三条规则（**必须遵守**，不是建议）：

1. **`recover()` 必须接。** 不接就没有任何机制会发现 in-doubt 事务 —— 参与者可能永久锁着。
2. **`recover()` 只报告，不自动处置。** 没有重试、没有回滚、没有超时策略，也不知道参与者
   实际做没做。它给的是"该人工看一眼"的清单；决定权在你（`preparePhase` / `commitPhase` /
   `abortPhase`）。
3. **`freeInDoubt` 必须配对**（`defer`），每项里还有独立分配的 id 与参与者列表。

一个进程内的 saga 另有一套崩溃续跑机制（`SagaOrchestrator.resumeInstance` + WAL，
见 [WORKFLOW.md](WORKFLOW.md)）；本节管的是**跨进程 2PC** 那一条。

### Saga 步骤超时：`SagaStep.timeout_seconds`（必须设）

`SagaStep.timeout_seconds`（默认 `30`，`0` = **关掉**这个检查）是**每个步骤的预算**。
它防的是最难受的一种挂起：某一步的 `action` 卡死（等一个永远不回的 RPC、死循环），
saga 就永远停在 `running` —— 补偿不跑、实例不释放、没人知道它死了。

```zig
// `SagaStep` 是 `core/SagaOrchestrator.zig` 的顶层声明（`zigmodu` 目前只再导出
// `SagaOrchestrator` / `SagaLog` / `SagaStatus`）。所以别写 `zigmodu.SagaStep`——
// 直接把字面量交给 `registerSaga`，元素类型由此推断：
var orch = zigmodu.SagaOrchestrator.init(allocator);
defer orch.deinit();

try orch.registerSaga("order", &.{
    .{
        .name = "charge",
        .action = charge,
        .compensation = refund,
        .timeout_seconds = 15, // 必须给一个正数；`0` 等于关掉预算
    },
    .{
        .name = "ship",
        .action = ship,
        .compensation = unship,
        .timeout_seconds = 30, // 默认值就是 30，写出来是为了显式
    },
});
```

语义要说清（**判在事后，不是打断**）：

- 判断发生在 `action` **返回之后** —— 进程内执行器无法抢占正在跑的步骤。
- 超预算时实例落到 `.timed_out`，**已经产生效果的所有步骤（含这一步，因为它确实返回了）
  按逆序补偿**；`execute` / `resumeInstance` 随后返回 `error.SagaStepTimeout`。
- `.timed_out` 是终态：`resumeInstance` 拒绝续跑（`error.NothingToResume`），
  `restoreFromWal` 也跳过它。
- 所以 `timeout_seconds = 0` 不是"更快"，是"关掉唯一的悬挂检测"——**别设 0**。


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

### 一步到位：解析 + 校验绑在一起

两步写法里最容易被漏掉的是 `checkForm` 那一行——策略写了，handler 只调了 `extractMultipart`，
中间那道门就没装上（而且这种漏掉不会报错，只会静默放行）。`extractMultipartGuarded` 把两者绑成一次调用：

- 解析失败沿用 `extractMultipart` 的状态码（415 / 413 / 400）；
- 策略拒绝默认出 **415** ProblemDetails，`reject_status = 422` 可以换成"类型能收、内容不收"的语义；
- guard 的错误**原样返回**，所以想区分"扩展名不对"和"内容不对"的 handler 照样能
  `catch |err| switch (err)`——只是**不要再写第二个响应**（服务器保留第一个，见 `Server.handleForTest` 的 `ctx.responded` 判断）；
- 被拒时 form 由内部释放，调用方不用管。

```zig
var form = try zigmodu.http.extractMultipartGuarded(ctx, .{
    .multipart = zigmodu.http.Multipart.Config.forBodyLimit(64 << 20),
    .policy = .{
        .extensions = &.{ "jpg", "jpeg", "png", "webp" },
        .formats = &.{ .jpeg, .png, .webp },
        .max_bytes = 5 << 20,
    },
});
defer form.deinit();
const avatar = form.file("avatar").?;   // 到这里才可信
```

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
// ✅ 安全的输入验证（片段：`// 进一步验证...` 处省略，未给出完整校验）
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

Zig 0.17 删掉了 `std.Thread.Mutex`：现在是 **`std.Io.Mutex`**，且 `lock` / `unlock`
都要**带 `io` 参数**（`lock(io)` / `unlock(io)`，都返回 error union）。锁本身仍是非阻塞自旋语义，
也要自己声明 `io` 字段。写法对齐 `src/core/EventBus.zig` 的 `ThreadSafeEventBus`：

```zig
const std = @import("std");

pub const ThreadSafeCounter = struct {
    const Self = @This();          // 少了这行，`*Self` 编译不过

    mutex: std.Io.Mutex = .init,   // 不是 `.{}`
    io: std.Io,                    // lock/unlock 都要它
    value: u64 = 0,

    pub fn init(io: std.Io) Self {
        return .{ .io = io };
    }

    pub fn increment(self: *Self) void {
        self.mutex.lock(self.io) catch return;   // 拿不到锁就当本次没加
        defer self.mutex.unlock(self.io);
        self.value += 1;
    }

    pub fn get(self: *Self) u64 {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.value;
    }
};
```

> 反例（Zig 0.17 编译不过、也别照抄）：`mutex: std.Thread.Mutex = .{}` +
> `self.mutex.lock()` / `self.mutex.unlock()`。旧文档里出现过，已删。
>
> 只是计数的话，优先考虑 `std.atomic.Value(u64)` 的 `fetchAdd`（无锁），
> 锁留给"一次要改多处状态"的场景。

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
        .preferred_optimize_mode = .ReleaseSafe, // 带 `-Drelease` 时用 ReleaseSafe
    });

    // 编译期开关走 build options —— Zig 0.17 **没有** `root_module.addDefine`。
    // 与仓库根 build.zig 的 `log_level` 同款写法。
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "log_level", b.option(
        []const u8,
        "log-level",
        "Compile-time log level (debug/info/warn/err)",
    ) orelse "debug");
    const build_options_mod = build_options.createModule();

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("build_options", build_options_mod); // ← 开关这样进代码

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
}
```

```zig
// src/main.zig —— 读编译期开关
const build_options = @import("build_options");
const log_level = build_options.log_level; // "debug" | "info" | "warn" | "err"
```

> 生产环境别靠 `addDefine` 关日志：日志级别用 `-Dlog-level=warn`（上面的 option），
> 或者运行时用 `StructuredLogger` 的级别字段。

### 环境配置
- **环境分离**：开发、测试、生产环境分离
- **配置管理**：使用环境变量配置
- **密钥管理**：敏感信息使用密钥管理服务

Zig 0.17 移除了 `std.process.getEnvVarOwned`：环境变量从 `main` 的
**`init.environ_map`**（`*std.process.Environ.Map`）拿，`get` 返回 `?[]const u8`，
不分配、不需要释放。仓库示例统一这么写（`examples/*/src/main.zig`）。

```zig
// src/config/Loader.zig - 环境感知配置
const std = @import("std");

pub const Config = struct {
    db_url: []const u8,
    log_level: LogLevel,
    enable_cache: bool,
};

/// 环境表由调用方（main）传进来；本函数不分配、不持有环境内存。
pub fn loadConfig(env: *const std.process.Environ.Map) !Config {
    const app_env = env.get("APP_ENV") orelse "development"; // 缺省即默认值
    const db_url = env.get("DB_URL");

    return switch (app_env) {
        "production" => .{
            .db_url = db_url orelse return error.MissingDbUrl,
            .log_level = .error,
            .enable_cache = true,
        },
        "staging" => .{
            .db_url = db_url orelse return error.MissingDbUrl,
            .log_level = .info,
            .enable_cache = true,
        },
        else => .{
            .db_url = db_url orelse "sqlite:///dev.db",
            .log_level = .debug,
            .enable_cache = false,
        },
    };
}
```

```zig
// src/main.zig —— main 拿到的 `init` 里就有环境表
pub fn main(init: std.process.Init) !void {
    const cfg = try loadConfig(init.environ_map);
    _ = cfg;
}
```

> 生产接线还有一条更省事的路径：`Server.fromEnv(io, allocator, init.environ_map)`
> （`src/api/Server.zig`）读 `HTTP_PORT` / `HTTP_MAX_BODY` / `HTTP_MAX_CONNECTIONS` /
> `HTTP_HEADER_TIMEOUT_MS`；启动期必填项检查交给 `zigmodu.Preflight.run(...)`。

### CI/CD 流水线
```yaml
# .github/workflows/ci.yml（节选）
name: CI

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

env:
  # 真源就是这里。dev 构建会被 ziglang 镜像回收（dev.1567 已 404），
  # 升级时先本地验证，再改这个值。
  ZIG_VERSION: "0.17.0-dev.2151+2ec5523d5"

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup Zig
        # 别用版本矩阵：`goto-bus-stop/setup-zig` 之类的 action 按旧 URL 形状
        # (zig-<os>-<arch>) 拼链接，对当前 dev 构建一律 404。直接下 tarball。
        shell: bash
        run: |
          case "$RUNNER_OS" in
            Linux) ART="zig-x86_64-linux" ;;
            macOS) ART="zig-aarch64-macos" ;;
            *) echo "unsupported runner OS: $RUNNER_OS"; exit 1 ;;
          esac
          curl -fsSL "https://ziglang.org/builds/$ART-$ZIG_VERSION.tar.xz" -o "$RUNNER_TEMP/zig.tar.xz"
          mkdir -p "$RUNNER_TEMP/zig"
          tar -xJf "$RUNNER_TEMP/zig.tar.xz" -C "$RUNNER_TEMP/zig"
          echo "$RUNNER_TEMP/zig/$ART-$ZIG_VERSION" >> "$GITHUB_PATH"
      - name: Run tests
        run: zig build test
      - name: Build examples
        shell: bash
        run: |
          for d in examples/basic examples/event-driven; do
            (cd "$d" && zig build)
          done
```

> 业务项目的发布门禁是 `zmodu ci`（build → fmt → verify → audit → deadcode → doctor，6 步）；
> 框架自身是 `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`。

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
        // 片段：`// 实现...` 处省略；`UserModule.init(allocator)` 只是文档注释里的示意调用
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

# 性能门禁（对比基线，见 scripts/check-bench.sh 头部；CI 用 bench-baseline.ci.json）
bash scripts/check-bench.sh

# 生成文档
zig build docs
```

### 性能门禁的两种判据（2026-09-19 起）

`scripts/check-bench.sh` 对**大多数**指标用绝对毫秒（2.0× 阈值，越低越好）；对**每轮关键路径是一个
内存序原语**的六条改用**比值**：`指标 ÷ 'atomic RMW x10M'`（同一轮的两个中位数相除）。这六条是
`Mailbox post+drain`、`Mailbox full-path`、`HotBus 8sub`、`Sequencer`、`1L x10M events`
（每轮卡在一次原子 RMW 上）以及 `RingBuffer SPSC x1M`（每轮卡在 `tail`/`head` 各一条 store→load 链上，
量的是宿主的 release/acquire 实现 + store-to-load forwarding 延迟 —— 同一份 `ring.zig` 只把
`.release`/`.acquire` 换成 `.monotonic`，本机就从 11.70 ms 掉到 0.954 ms）。原因是 Azure runner 按区域滚动
换代，内存序路径整体变慢的那代机器会把绝对判据打红，而这份二进制的计时循环逐条指令相同（见
`src/benchmark.zig` 的 `benchAtomicRmw` 与 `scripts/check-bench.sh` 头部记录的证据；2026-09-19 那条
`RingBuffer SPSC x1M` 的误红就是唯一一次落在 Xeon 档的 run）。比值判据**不削弱**
对真回归的敏感度：热路径多一次分配 / 多一把锁 / 多一个原子都会把比值推上去（反证见 CHANGELOG 对应条目）。
`atomic RMW x10M` 本身只做“这台机器有多快”的报告，**不参与判定**；两种基线各留一份，比值也**不跨机器档
比较**（本机 ~0.50、runner ~0.052）。

### 延迟分位数（p50 / p95 / p99 / p99.9，只报告、不判定）

中位数回答“普通一轮多少钱”，回答不了“尾部长什么样” —— 而尾部长什么样正是“高性能运行时”这句话要兑现的
东西（调度唤醒、冷邮箱槽、要到分配器的线程创建）。所以 `zig build benchmark` 在原有 `[med3]` 之外，多打一张
**延迟分布表**：runtime 组 8 条 + 两条链（`App lifecycle`、`1L x10M events`），共 10 行，每行
`p50 / p95 / p99 / p99.9`（ns/op），前缀是 `[pct]`，与 `[med3]` 同为“原样打给日志看”的输出。
`TimerWheel x100K` 是 runtime 组里**被排除**的一条（它的 `[med3]` 照旧测量、照旧判定），理由与代价见
本节末尾那条；同样被排除的还有 `TimerWheel churn x1M`，但理由不同 —— 它量的是轮**老化之后**的代价，
而一个会重建 fixture 的 batch 只有几轮大（跟 `findById x20K` 的 fixture 占据样本是同一条规则）。
表头也会打印这两行排除说明，所以在日志里 grep 不到它们时先看那几行。每节末尾另外打印自己的
实测耗时（`[pct] section cost`），因为这张表本身要花 CI 时间，预算得看得见。

- **一次 1000 个 batch 的样本，不是 3 个中位数。** 每条指标按 `总量 ÷ 1000` 切成 1000 个 batch，harness
  被调用 1000 次（而不是 `median3` 的 3 次）；每个 batch 前后各读一次时钟，**样本是该 harness 自计时的单
  batch 耗时** —— 每个 harness 都在建好 fixture *之后* 才起表，所以 fixture 不进样本。分位数用 nearest-rank
  （`ceil(p·n)`，1-based），1000 个样本的 p99.9 是第 999 个。逐操作计时在这里不可用：`Sequencer` 一轮 ~2 ns，
  一次读钟 ~25 ns，那样量的是钟。**一个 batch 就是采样单位**，比 batch 更短的抖动看不见 —— 每行打印的
  `ops` 就是这个分辨率。
- **收集路径零分配。** 样本缓冲是一次性预分配的 `f64` 切片，背后那个 allocator 在采样循环开始前被
  `fail_index` 上膛：循环体只读钟、只往切片里写一个数。采样器将来长出一次分配（会增长的列表、格式化一行
  日志），**这一轮就直接失败**，而不是把自己的簿记悄悄算进被测量的路径。被测量路径本身的零分配要求归各
  harness 自己（两条要求“stop 路径不分配”的 harness 本来就带 `WorkerAllocProbe`）。
- **不进 `bench-results.json`、不进任何基线、不参与判定。** `check-bench.sh` 只读 `bench-results.json`
  与两份基线文件；分位数只出现在它 `grep -v '^info: '` 之后的日志里。理由：这些数**跨宿主档的离散度还不知道**
  —— 这个仓库已经为“拿一台机器的单点基线去卡新数字”付过三次账（`RingBuffer SPSC x1M` 一个指标就随宿主
  内存序实现差 2.15×，见 `scripts/check-bench.sh` 头部）。先攒几轮观测，等手里有离散度再决定要不要立判据。
- **自证采样是真的**：`ZIGMODU_BENCH_INJECT_NS=<ns>`（配合 `ZIGMODU_BENCH_INJECT_EVERY`，默认每 40 个
  batch 一次，即 1000 个样本里的 25 个 = 2.5%）让这些 batch 各多付一段**忙等**，宽度用同一只钟量出来并加进
  该 batch 的样本。2.5% 的样本恰好落在排序后分布的最顶部（在 p95 的 5% 边界之上），所以 p50 必须不动、
  p99/p99.9 必须按注入量抬起来。`every` 取 21–99 保持这个性质（被挪动的质量占 1%–5%）。本机实测
  （M1 Pro，负载均值 8–9，`ZIGMODU_BENCH_INJECT_NS=2000000`，同一台机器上的相邻两次运行，左=关、右=开，
  逐项对应）：

  ```
  [pct] RingBuffer SPSC x1M: p50 10.00 → 11.00   p95 11.00 → 11.00   p99 12.00 → 2010.00   p99.9 30.00 → 2013.00 ns/op
  [pct] ObjectPool x1M:      p50 15.00 → 15.00   p95 18.00 → 17.00   p99 31.00 → 2015.00   p99.9 56.00 → 2017.00 ns/op
  [pct] Sequencer x10M:      p50  2.20 →  2.10   p95  3.30 →  2.30   p99  5.90 →  202.10   p99.9 11.30 →  202.20 ns/op
  [pct] 1L x10M events:      p50  2.10 →  2.10   p95  2.20 →  2.30   p99  3.50 →  202.20   p99.9  4.20 →  202.30 ns/op
  ```
  抬起来的尾部正好落在**注入宽度 + 那条 batch 自己的正常耗时**（RingBuffer 2010.00 = 2000 + 10、Sequencer
  202.10 = 200 + 2.10、ObjectPool 2015.00 = 2000 + 15）：落点可预测，抬升量是注入宽度的量级而不是几个
  百分点 —— 这既不是“把中位数印三遍”能造出来的形状，也不是采样噪声能撞上的巧合。p50 那 1 ns 级的出入是 batch
  自身耗时在两次运行间的抖动（RingBuffer 那条 batch 平时 10–11 ns），而尾部是 2000 ns。p95 是 5% 边界、
  离被挪动的质量只差 2.5 个百分点，所以它的边界样本会挪一格（厚尾指标更明显，见 `App lifecycle x3K`）；
  p50 离得最远，不动。这个开关默认关，开着的时候表头会打印一行 `!! latency injection ON`：那种表是反证
  输出，不是框架测量。
- **`sum = N x med3` 这一列要读。** 每行末尾把该指标 1000 个 batch 的**自计时之和**与它的 `[med3]` 值并列
  （同一轮、同一总工作量）。两者一致（本机正常负载下 0.95–1.10×；本身会抖的 `App lifecycle` /
  `Worker spawn+join` 落在 0.84–1.23×）说明 batch 化没有改动这条指标；差出 0.8–1.25 的区间时，行下会多一段
  说明 —— 现在已知的成因只有一个：**宿主负载在 `[med3]` 阶段与分位数阶段之间变了**（本机在一次编译同时进行时，
  `HotBus 8sub x1M`、`Mailbox full-path x10M` 实测 1.37–1.57×，而它们各自的 `[med3]` 也一起被拉高了）。
  分位数只描述采样时看到的那份形状。曾经还有第二类成因（batch 化真的改了工作负载），它对应的那条指标已经被
  移出这张表 —— 下面是它的实测记录，留着是因为“哪些 harness 不能 batch”是个会再犯的问题。
- **`TimerWheel x100K` 为什么不在表里。** 因为它的**每轮代价是活结构的规模**，不是每轮代码：一轮的活是遍历
  10 万个已排定定时器（分布在 32 个 slot 链表上），`[med3]` 那一轮走 ~5.6 MB 的节点（缓存冷），而 100 ops
  的 batch 只持有 100 个节点（~5.6 KB，全在 L1）。本机用同一份循环（一个轮子、每个半边各一对钟，不逐操作
  计时）量的两个半边：

  ```
  10 万节点的一轮：schedule 49.8 ns/定时器   advance 20.8 ns/定时器   合计 70.6 ns（= [med3] 6.72 ms / 10 万）
  100 ops 的 batch：schedule 23.5 ns/定时器  advance  4.9 ns/定时器   合计 28.4 ns（= 1000 batch 之和 2.84 ms）
  ```

  `schedule` 那一半的差在 `nodes` 索引（数组哈希表：10 万条 → entries 1.8 MB + index 2.1 MB，262144 个 8 字节槽，
  每次 put/remove 都是缓存缺失）与节点内存的首次触碰，`advance` 那一半的差在它要走的那 5.6 MB 节点。于是 sum 常年落在
  `[med3]` 的 0.34–0.51×
  （本轮复测 0.42×），**而且加大 batch 解决不了**——同一个 10 万总量切成不同的 batch：

  ```
  ops/batch   100    250    500   1000   2000
  sum/med3   0.42   0.47   0.45   0.47   0.64
  ```

  要动的量是“一个样本走了多少活结构”，不是“一个样本跑了多少 op”。要让 batch 与判据同形，就得让每个样本
  都是一次判据规模的运行，而一次判据样本 ~6.7 ms ⇒ 1000 个样本 ~6.8 s，是整节预算（~0.2 s）的 30 倍，
  为一行指标不值得。更便宜的两种形状都不诚实：100 个判据规模 batch（实测 677 ms，sum/med3 = 1.007）确实
  能把 sum 拉回 1.0×，但 100 个样本的 p99.9 就是最大值 —— 与其余各行打印的不是同一个统计量；20 个判据规模
  batch（134 ms）同理更糟。所以这一行是**移出**，而不是换个形状继续采样（指标本身仍在：`[med3]
  TimerWheel x100K` 照旧测量、照旧参与判定）。这是“batch 采样对『代价随状态规模增长』的 harness 不适用”
  的实例，不是分位数机制的问题。
- **`TimerWheel x100K` 上「数组索引 vs 旧哈希表」到底贵多少（2026-09-19 复测，结论：不回退，代价在扩容、不在稳态）。**
  上一轮把 `nodes` 换成 `AutoArrayHashMapUnmanaged` 时留下一条“这条指标的余量不大”的观察，本轮同机把它钉到机制上。
  测法：写一份 A/B harness（两份 `timer_wheel.zig` 源码副本，一为当前、一为改动前），每轮**两臂各测两次、两种先后顺序各一次**
  （抵消“后测的那一臂占便宜”），并且**在同一轮里同时跑 A/A 对照**（两臂是同一份代码）作为这台机器的分辨率下限；
  本机负载均值 10–15（10 核，同时在跑别的构建），所以每条数字都带自己的对照。10 万个键的形状：

  | 形状 | array / hash（配对中位数） | 同轮 A/A 对照 |
  |---|---|---|
  | 新建 map、**不含扩容**（先 `ensureTotalCapacity`，计时区内零分配） | **0.94×（数组快 6%）**，最好样本 12.65 / 14.04 ns | 0.995× |
  | 新建 map、**含扩容**（= `Wheel.schedule` 的真实路径） | **1.25×** | 1.003× |
  | 删除（`fetchSwapRemove` vs `fetchRemove`） | **1.73×** | 1.06× |

  机制是**扩容**，不是探测距离或局部性：同一份 10 万定时器整轮（计数 allocator，`zig build benchmark` 的 `[alloc]`
  那一趟量的也是它）——

  ```
               扩容分配次数   总分配字节   峰值常驻
  数组表            34         14.75 MB    9.53 MB    entries ×1.5 增长 18 步（合计 5.6 MB）
                                                        + index 重建 10 次（合计 3.7 MB，最后一步自己
                                                        就是 262144 个 8 字节槽 = 2.1 MB，每次重建都要
                                                        `@memset` 后把全部条目重插）
  哈希表            15         10.06 MB    7.83 MB    桶数组倍增，没有第二份结构
  ```

  顺带一个容易看错的数：数组表**活着**的索引是 262144 × 8 B = **2.1 MB**（`Index(u32)` 是 `entry_index` +
  `entry_distance` 两个 u32，不是 4 字节），比旧哈希表整张桶数组（131072 × 16 B = 2.1 MB）还大 ——
  数组表要维护**两份结构**：entries 要被复制，index 每次重建都要新分配 header、`@memset` 后把全部条目重新插一遍；
  而它“占用 ≤60%”的规则正是插入快的原因（先把容量给足，数组表反而比哈希表快 6%）。所以“贵 7–18%”只在**把扩容算进去的
  map 级**形状里成立，且本轮量到的是 25%；到了轮子这一层被稀释（整轮 = schedule 半边里的 map 部分 + advance 半边，
  后者的大头是 slot 链表遍历与回调）。判据面（同机、150 轮交错、A/A 对照同轮）：

  ```
  A/B 配对中位数 1.12–1.17     A/A 对照中位数 1.08     同轮内 (A/B − A/A) 的中位数 +0.05 … +0.17
  固定缓冲（预触页、无 free、去掉分配器噪声）最好样本：50.85 / 48.75 ns/op = 1.043×
  ```

  即这条指标的差值落在**低个位数百分比**（最好的仪器里 4%，最悲观的估计 ~15%），而 A/A 对照自己就有 6–8% 的偏置 ——
  在这台（被共用的）机器上这就是分辨率下限，不是可判定的回退。run 级波动比被测差值本身还大：同一天、同一份二进制、
  同一台机器，三次 `[med3]` 实测 `TimerWheel x100K` 中位数分别为 6.21 ms（负载均值 ~25）、7.47 ms（~15）、
  7.63 ms（~12，`check-bench.sh` 自己那次，exit 0）—— **6.21 ↔ 7.63 = 1.23×**，基线 6.808 ms 落在中间，
  其中一次还低于基线（0.91×）。所以这条指标的 run 级噪声不该记到代码账上。结论：**不动 `timer_wheel.zig`** —— 任何“修法”都等于放弃数组表（= 退回
  `TimerWheel churn x1M` 的 265 ms）或重写 std 的哈希表，而代价只是“轮子长到 10 万个活定时器时多付约 5 MB
  扩容流量”；判据也维持原样（6.808 ms 绝对 + 2.0×，余量仍接近 1.8×），要动它得先有跨宿主离散度，本轮没有这个证据。
- **`alloc/op` 是另一趟 instrumented 分测，不在 `[pct]` 里。** 统计分配要在被计时路径上插一个计数 allocator，
  那会改动被测路径本身（每次分配多一层 vtable 与一次计数写入），所以它从来不该挂在延迟采样上，也确实没有：
  runtime 组的 9 条指标各有一份**独立**的 `[alloc]` 行，前缀是 `[alloc]`，跟在 `[pct]` 表之后，只打**分配次数**
  （`alloc/op` 与总次数），**不打耗时** —— 一趟被插桩的运行没有可比的时长，这正是“与延迟采样分开”的全部含义。
  计数 allocator 插在**被测代码自己持有 allocator 的地方**：wheel（`schedule` 分配节点）、object pool、worker
  runtime（`spawn` 每个 worker 分配一个堆上的 handle，邮箱是 comptime 内联存储）；`RingBuffer`、`Mailbox`、
  `HotBus.publish`、`Sequencer` 和那条原子基准的每轮操作**根本不接 allocator**，它们的 `0.00` 是结构性的
  （没有可分配的路径），不是量出来的。
  插桩只计被计时段（fixture 在快照之前建好），计时的 `[med3]`/`[pct]` 路径一行都没动 —— 每个 `[alloc]` 都是
  那条指标 op 循环的一份副本。读数与 `src/runtime/alloc_contract_test.zig` 的**精确断言**一致：
  `Mailbox.send*` / `Handle.send*` / `RingBuffer` / `MpscRing` / `Sequencer` / `HotBus.publish` /
  `Wheel.cancel`·`advance` 都是 0，`Wheel.schedule` 是**每个定时器一次节点分配**（数组哈希表下实测 100,034 次 /
  10 万个定时器 = 1.00 alloc/op，多出的 34 次是 `nodes` 的摊还扩容：entries 增长 + index 重建，见上一条的对照表；
  换成数组哈希表之前是 15 次 —— 两次都远小于 1 次/定时器，所以 `alloc/op` 到小数后两位没变）；`Worker spawn+join` 实测 1.01 alloc/op（1000 次 spawn 共 1011 次分配，其中**stop/join 那半边
  0 次**，与那份测试的 `BenchStopPathAllocated` 断言一致）。这两条非零是**设计允许**的，不是缺陷。
  `[alloc]` 同样**不进 `bench-results.json`、不进基线、不被 `check-bench.sh` 判**：判定留在那份测试里（它把
  allocator 上膛成失败，热路径多一次分配是**报错**而不是一个变大的数字），这里只负责把同一组数字摆到性能
  读者能看到的地方。`Handle.send*` 与 `MpscRing` 有那份测试但没有本套件的指标，所以没有对应的 `[alloc]` 行。

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

**最后更新**：2026-09-18 · ZigModu v0.26.0（Zig 0.17.0）  
**维护者**：ZigModu 团队
