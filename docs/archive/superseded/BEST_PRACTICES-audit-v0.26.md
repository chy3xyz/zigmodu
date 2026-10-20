# BEST_PRACTICES 现状复核审计快照（v0.26.0，2026-09-18）

> **⛔ 这是 2026-09-18 / v0.26.0 当时的内部审计快照，不是当前状态。**
>
> 它原先住在 `BEST_PRACTICES.md` 正文里（占该文件 14%），但内容是**内部审计台账**
> ——A–F 分档、「待修清单」、源码文档质量抽样、CLI 门禁现状——不是给使用者看的
> 最佳实践。写于 09-18，此后到 v0.35.0 之间又过了九个版本，抽样数字大多已过时。
>
> 留在原地会让人把采样值读成现行结论，所以整段移到这里。
> **要看"现在该怎么写代码"，请读 [`BEST_PRACTICES.md`](../../guide/BEST_PRACTICES.md)。**
>
> 原文位置：`docs/BEST_PRACTICES.md` §「🔄 现状复核（v0.26.0 快照）」。

---

## 🔄 现状复核（**v0.26.0 快照**，2026-09-18）—— 近期演进对示例/文档的影响

> **这一节是 v0.26.0 当时的审计快照，不是当前状态**（写于 09-18；此后到 v0.35.0 之间又过了九个
> 小版本，其中"每条服务端写路径都有上界"、"Runtime Replay 落盘"、"fuzz/soak/bench 三套门禁"、
> "执行平面"等都已落地）。**当前的逐条状态看
> [dev/v1.0-readiness-v0.35.md](../../dev/v1.0-readiness-v0.35.md)**（同一形状：逐条 + 证据 + 谁验证的），
> 那一节里标 `已修` 的条目不要照着做第二遍。留在这里是因为它记的是"当时抽样抽到了什么"，
> 而不是"现在是什么"。

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
  `zmodu.core.*` / "实现 PasRaft 共识" 的说法已删
- ✅ `tools/zmodu/src/main.zig:6011`（`--with-agent` 模板）：生成**无 guard 的裸 `Agent{}`**；`:6082-6086`
  的 handler 同步跑 agent 且不设 tenant/user
  （2026-09-18 修：模板现生成 `guard: zmodu.ai.Guard = …`（`tools/zmodu/src/main.zig:6127`）并交给
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
  （2026-09-18 修：内置技能逐个显式声明类别（`src/ai/ops/business.zig:106/154/202`、`src/ai/ops/kpi.zig:61`、
  `src/ai/ops/notify.zig:126`、`src/ai/ops/schedule.zig:47/71/109/130`、`src/ai/ops/admin.zig:107/134/160/184/209/253/274`、
  `src/ai/ops/actions.zig:66/83/221/304`、`src/ai/ops/approval_api.zig:133`、`src/ai/approval.zig:248`），
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
  `shopdemo-zent` 注释 → zent v0.74.2 的 git tag pin
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
   （`DocSnippets.zig:31,33`），并把 markdown 扫描**递归到 `docs/**`**（跳过 `docs/archive/**` 与 `docs/superpowers/**`）。
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
   `zent-modulith` 三处都改成 `git+https://github.com/chy3xyz/zent?ref=v0.74.2` 的 tag pin（无 sibling 检出也能构建）；
   例外只剩 `examples/_shared`（helper 库，仍按 path 引 sibling `../zent`，CI 的注释已写明此处不可离线构建）。
5. **收敛重复示例** —— ✅ **已完成（2026-09-17）**：删 `deprecated/`（只有一份裸 snippet）与 `examples/example_tests.zig`
   （占位）；testing 并入 basic（`examples/basic/src/tests.zig` + `build.zig` 的 `test` step，5 个测试：原 testing 的 3 个
   全保留 + lifecycle / mock 两例；CI 的 test-step 列表随之由 `testing` 换成 `basic`）；distributed 与 cluster-demo
   合成一份"集群现状 / fail-closed"说明（`examples/distributed/README.md`，含 3 节点拓扑与 docker 拓扑指向
   `examples/production-deploy/`）。验收：`examples/README.md` 的索引表与目录**一一对应**（20 个目录 20 行，
   含 runtime-workers / alpha-engine / mcp-server / shopdemo-zent / metaverse-creative / zmsaas / distributed；
   行数表已删，避免第二份会漂移的清单）。
6. **加元数据门禁** —— ✅ **已完成（2026-09-17）**：`build.zig.zon` 的 `minimum_zig_version` 全部 → `"0.17.0"`
   （`grep -rn '"0.16.0"' examples/ --include='*.zon'` 为空）；`metaverse-creative` 两处 → zmodu **v0.24.0**
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
   （2026-09-18 修：内置技能逐个显式声明类别 —— `src/ai/ops/business.zig:106/154/202`、`src/ai/ops/kpi.zig:61`、
   `src/ai/ops/notify.zig:126`、`src/ai/ops/schedule.zig:47/71/109/130`、`src/ai/ops/admin.zig:107/134/160/184/209/253/274`、
   `src/ai/ops/actions.zig:66/83/221/304`、`src/ai/ops/approval_api.zig:133`、`src/ai/approval.zig:248`；
   类别维度的盲区改由注册表侧补：`SkillRegistry.auditPolicy` + `PolicyHealth.isInert()/hasClassBlindSpot()`
   （`src/ai/skill.zig:99,242`）会列名"被类别闸门拒掉"的工具，测试见 `:545` / `:608`。
   `Guard.isInert()` 本身仍只看 `allow.len`（`src/ai/guard.zig:87`），故这一条的"改"按 `PolicyHealth` 落地）
3. ✅ **`Workflow` 的 `.agent` 步骤无 guard 途径**：`src/ai/workflow.zig:615-619` 现搓裸 `Agent{provider,registry,budget}`，
   且 `Workflow`(`:140-167`) 没有 guard 字段 → workflow 里的 agent 天然无界。改：加字段并透传。
   （2026-09-18 修：`Workflow` 新增 `guard: ?*guard.Guard` 字段（`src/ai/workflow.zig:153`），`.agent` 步骤经
   `agentForStep()` 透传 `.guard = self.guard`（`:606`）；测试 `workflow .agent steps inherit the workflow guard`（`:1297`））
4. ✅ **scaffold `--with-agent` 生成无 guard 的裸 `Agent{}`**：`tools/zmodu/src/main.zig:6011-6019`；`:6085` 的 handler 也不设
   tenant/user（落库恒 0）。改：生成 `AgentSpec{ .guard = … }` + `SkillContext{ .tenant_id = ctx.tenantId(), … }`。
   （2026-09-18 修：模板生成 `guard: zmodu.ai.Guard = zmodu.ai.Guard.init(.{})`（`tools/zmodu/src/main.zig:6127`）
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
   `b.dependency("zmodu")` 而全篇没给 `build.zig.zon` 依赖声明。README 里 `const UserModule`（非 `pub`）+ 传
   `.{user}`（文件结构体无 `info`）同样编不过。
   （2026-09-18 修：`docs/QUICK-START.md:37` 是 `pub const UserModule`（注释点明 `pub` 的原因），`:84` 有
   `var app = try b.build(.{user.UserModule});`，`:77` 的 `generateDocs` 带满 4 个实参，`:25` 的 `zig version`
   期望值改为 `ci.yml` 的 `ZIG_VERSION`，`:97` 起补了 `build.zig.zon` 依赖声明（`:133` 的 `b.dependency("zmodu")`
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
   （文档主推 `data.SqlxBackend`，但 `queryRowPartial` 只在 `*data.Client` 上存在）。`ZENT.md:532` 还写着 zent v0.39.2（实际 pin v0.74.2）。
   （2026-09-18 修：`docs/ZENT.md` 的"摘自示例"块已改成 `defer self.client.product.deinitRows(&found)`（`:479`），
   `:491` 注明"手写 `deinitEntity` 循环是旧写法，本仓库示例已全部改掉"；全文 `v0.39.2` 清零、口径为 zent v0.74.2
   （`:4` / `:530` / `:549`）；`docs/MODULE_LAYERS.md:62-64` 写清 `Backend` 两套方法（`*data.Client` → `queryRowPartial`，
   `data.SqlxBackend` → `queryRowPartialBorrowed`），`:72-74` + `:94` 说明租户键表用 `findById(self, tenant_id, id)`、
   租户主表退化为 `findById(self, id)`。`rg -n 'v0\.39\.2' docs/ZENT.md` 为空）
6. ✅ **孤儿文档**（无任何索引收录）：`docs/LOGGING.md`、`docs/MIGRATION_v04_to_v07.md`、`docs/ZMODU_NOTES.md`，
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
3. ✅ 「阶段 4：服务网格」的能力表与「配置示例」—— `zmodu.resilience.*` / `zmodu.tracing.*` / `zmodu.metrics.*` 三个命名空间**都不存在**。真身：`zmodu.CircuitBreaker` / `zmodu.RateLimiter`（`src/root.zig` §3），`zmodu.observability.DistributedTracer` / `zmodu.observability.PrometheusMetrics`（`src/observability.zig`）。已改。
4. ✅ 同两处的 `CircuitBreaker.init(5, 30000)` 与 `data.redis.Redis.init(allocator)` + `connect(host, port, .{})` —— 真签名分别是 `CircuitBreaker.init(allocator, name, cfg)`（`cfg` 字段是 `timeout_seconds` / `half_open_max_calls`）与 `data.redis.Redis.new(allocator, io, cfg)` + `connect()`。已改。
5. ✅ 「部署与 CI/CD」节的三处旧 API —— `std.process.getEnvVarOwned`（0.17 已移除，改走 `init.environ_map`）、`root_module.addDefine(...)`（不存在，改 `b.addOptions()` + `addImport("build_options", …)`）、CI 矩阵 `zig-version: ["0.16.0"]`（本仓走 `ci.yml` 的 `ZIG_VERSION`）。已改。
6. ✅ 测试节与阶段 2 示例里的 `zmodu.extensions.ModuleTestContext`（真身 `zmodu.ModuleTestContext`，`src/root.zig`）与 `zmodu.extensions.AsyncEventBus`（**全仓无此类型** —— 整段已删除，换成 `ThreadSafeEventBus` 示例）。已改。
7. ✅ 本节开头的采样断言（"examples 里没有任何代码用 `ai.Agent`／全仓只有 3 处 `zmodu.builder`"）—— 已标 `（2026-09-17 采样）`、更新数字，并注明"以 `grep` 为准"。

**结构与口径（2026-09-18 部分处理）**
- ✅ 目录已**上移到正文之前**，并补录 `## 🔄 现状复核` 与本次新增的小节。
- ✅ 版本口径三处互斥已统一为**仓库当前 v0.26.0**（`build.zig.zon` 的 `.version`），页脚一并改。
- ✅ 自引用行号（如指向本文件/tools 某行的 `:231`）已换成按章节名/片段引用。
- ⏳ 仍未处理（属重构，本次范围外）：错误处理节 412 行塞了 15 个主题，建议拆；认证内容散在「JWT 密钥轮换」「Auth.optional」「JWT / 多端身份」三处；路线图节尾有第二套"阶段 3/4（模块数）"与上文同名；「演进决策树」「技术债务」「ClusterBootstrap」「Server.initWithConfig」各重复 2–3 次。

### 实践 ↔ 门禁一致性（2026-09-18）

「会炸/会漏」的规则**基本都有门禁**（`audit` b1–b24 + `check-production` + `DocSnippets` + `AiBoundary`）。缺口分三类：

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

`zmodu.observability.LogRotator` 是正式导出的公开组件，但**全仓零调用**（`grep -rn LogRotator src/ tools/ examples/` 只有那一行导出）。Zig 惰性分析函数体，所以 `rotate()` 里的

```zig
std.Io.Dir.cwd().rename(self.io, old_name, new_name)   // 0.17 之前的签名
```

一直没报错 —— 0.17 里 `rename` 是 5 参自由函数 `rename(old_dir, old_sub_path, new_dir, new_sub_path, io)`。**任何用户一调用 `LogRotator.write` 就编译失败。** 光靠 `zig build test` 抓不到这类问题，因为"引用所有源文件"的编译测试只做文件级 import，不进函数体。

**修法与防复发**：

- 补 `initIn(allocator, io, dir, …)`（`init` 仍写 CWD，`initIn` 指向 `tmpDir`），修 2 处 `rename`；
- **加一条真正实例化它的测试**（`tmpDir` + 按大小轮转 + 断言 `.0`/`.1` 内容 + 超代数的文件不存在）。写这个测试时顺带纠正了我对语义的错误猜测：`max_size=10` + 4 字节写并不是"每次写都轮转"，而是两笔一滚 —— 断言得按真实语义写。
- **推广**：任何 `pub` 导出但无人调用的组件，都应当有一条把它**真正用起来**的测试。`deinitArena`（`QueryResult`/`PageResult`）同样属于这一类。

**同批收尾**：`check-production.sh` 的强制前缀补 `src/log/`、`src/runtime/`（此前只剩 3 条 WARN）；`zig build zmodu` 现在**同时安装**二进制（此前只 build+run，`zig-out/bin/zmodu` 会静默留着旧的，调用方驱动到陈旧 CLI）；`http.Testkit` 删掉查询解析的手工孪生实现，改为直接调 `Server.zig` 的 `parseQueryInto`（现在两边**不可能**再漂移）。

**F. 同一形状、两条门禁，宽严不同：inline alloc 只有**仓库侧**那条是强制的**

`zmodu audit` 的 **b25** 与 `zig build check` 的 inline-allocation 扫描（`scripts/lib/zig-scan.awk` 的 `inline_alloc` / `inline_alloc_owned`，由 `scripts/check-production.sh` 驱动）查的是同一类缺陷 —— 把新鲜分配直接写进 fallible `append`/`put` 的实参，外层调用一失败，内层刚分配的值就无人持有。**两者不互为镜像：仓库侧那条更严**，差在三处：

- **谓词多一半**：`inline_alloc` 与 b25 同形（`.append(` / `.put(` + 首参是分配器拼写 + 次参 `try <分配器>.<分配调用>(`）；`inline_alloc_owned` 另认以 `*Owned(` 收尾的交接 helper —— `putOwned(&o, a, "k", .{ .string = try a.dupe(u8, v) })`。
- **b25 故意不带那半条**：它的扫描对象是**消费方应用代码**（`src/modules/**`），而 `putOwned` 是框架内部名，应用侧没有对应物。
- **落点与效力不同**：`check-production.sh` 扫框架自身源码，并在 `INLINE_ALLOC_ENFORCED`（`src/ai/` `src/core/` `src/http/` `src/messaging/` `src/migration/` `src/security/` `tools/zmodu/src/`）下**强制**（exit 非 0），其余前缀只警告；b25 的结论走 `.zmodu/audit-baseline.json`。

**共同的盲区（别读成「仓库侧全包」）**：两条都是行形状，都只看单行调用；`inline_alloc` 与 b25 还都要求**首参**是分配器拼写，`inline_alloc_owned` 则要求被调名以 `*Owned(` 收尾 —— 于是 `put(try a.dupe(k), try a.dupe(v))` 这类**首参本身就内联**的写法，两边都看不见。`zig-scan.awk` 的契约注释把这一点写成"偏向沉默"的已知盲区；b25 的针同样把该形状排除在外（`inlineAllocIntoFallibleCall` 先要求首参是 `allocator` / `alloc` / `self.allocator`）。

