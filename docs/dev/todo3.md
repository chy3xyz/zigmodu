# Modular Runtime for High-Performance Systems

> **复核（v0.24.0，2026-09-17）**：8 个方向已从 v0.16 推进到 v0.24 共九个版本，**零件齐备、装配线建成**；
> 「升级为 Modular Runtime Platform」的目标走到了"参考实现未完成"这一步 —— 剩余差距集中在
> **参考实现的纵深（alpha-engine P2/P3）**与**集群门面 / 选主状态机收尾**，不在能力有无。
> 逐条见下表；判定口径 = 代码里能跑、且有人用（证据为 文件:行号）。

| # | 方向 | 判定 | 关键证据 / 差距 |
|---|------|------|----------------|
| 1 | Hot Runtime | ⚠ 部分（**采用已接通**） | `src/runtime/` 8 文件 2801 行：SPSC(`ring.zig:45`) + MPSC(`:125`)、`mailbox.zig:42`、`timer_wheel.zig:28`、`hot_bus.zig:54`、`clock.zig:21`。✅ **已被框架采用**：模块 `ctx.runtime()`(`core/ModuleContext.zig:58`) + `app.runtime()`(`Application.zig:274`，首次创建即启动 ticker) + `stop()` 先 join worker 再停模块（e2e 测试锁定 `ctx.runtime() == app.runtime()`；`examples/runtime-workers` 与 `examples/alpha-engine` 都走 app+module 路径）。**仍缺** MPMC/SPMC、scheduler/reactor/arena/metrics；孤儿原语只剩 `object_pool.zig`（头注释写明是刻意公共原语；`Sequencer` 本轮已接 `ai/agent.zig` 的 run-id 消费者） |
| 2 | Actor / Worker | ⚠ 部分 | 契约式 worker + `Runtime.spawn`(`runtime.zig:340`)、监督(`:82,353,565`)、背压(`mailbox.zig:28`)；模块已能在 `initWith` 里 spawn（见第 1 行）。**仍缺** `Worker(State)` 泛型类型、`ActorSystem`、真监督树（`docs/RUNTIME.md` 已标"未承诺"） |
| 3 | Compile-time Architecture | ✅ 机制达成 | 编译期模块图 + 环路径报错(`ModuleGraph.zig:186-216` ← `Application.zig:428`)；`zmodu graph`/`doctor` 已发布。**未做** `module(.{.imports,.exports})` DSL 与 `cannot_import` 声明（原因见 `ModuleGraph.zig:24-30`） |
| 4 | Event 三层 | ✅ 基本达成 | L0 `HotBus`(`hot_bus.zig:54`)、L1 `app.eventBus`(`Application.zig:261`)、L2 Kafka/NATS/Outbox + 自研 TCP Bus。**缺** Redis Stream、L2 统一接口；L0 框架内无消费者属**刻意定位**——`hot_bus.zig:31` 原文「Positioning: `HotBus` is a **user-facing** L0 primitive. The framework itself has no internal consumer — deliberately」，而应用侧示例已真用上（`examples/alpha-engine` 的 audit/metrics 扇出，`main.zig:9-10`；`docs/RUNTIME.md` §6） |
| 5 | Distributed Runtime | ⚠ 部分（**读侧接通 + 真传输落地**） | 零件齐：`ClusterView.zig` + `MembershipView.zig`（membership → view，`ClusterBootstrap.tick()`/`getView()` 驱动，`ClusterBootstrap.zig:207,222`）、`RaftElection.zig`(1387 行)、**`RaftTransport.zig`（真传输：5 测试，其中 3 个真 TCP loopback —— 选主达 quorum、同步 AppendEntries、empty-log follower 经 per-peer `nextIndex` 追平）**、`LoadBalancer.zig`、`PeerDiscovery.zig`、`ShardRouter.zig`；集群组件已从 `root.zig` 正面导出(`:213-229`)。**本轮已修**：选主**计票**（`RaftElection.zig:535-553` `handleVoteResponse` 按 term 去重、达 `quorumSize()` 才 `becomeLeader()`）与落后 follower **追平**（`:365-418` 的 `next_index` 回退提示）；多节点启动 **fail-closed**（`ClusterBootstrap.zig:124-130`：无 transport 且 `raft_cluster_size > 1` 直接拒绝）。**缺** 统一门面（仍无 `Cluster` 类型）、LB 无接入点、2PC 无持久化协调日志(`DistributedTransaction.zig:331`)、跨主机 gossip 发现按 `127.0.0.1` 记账、`ClusterBootstrap` 不自动起入站 server 与 `raft.tick()`、`InstallSnapshot` 只有入站 |
| 6 | AI-native Runtime | ✅ 达成度最高 | `ai.AgentSpec`(`agent.zig:171`)、`ai.Guard`(`guard.zig:101`，**每次工具调用先过闸门再分派**，被拒时把 `{"error":"ToolDenied",…}` 当工具结果喂回模型，计 `tool_denied` 并按原因写 audit)、`skill.Tool.action`（默认 `.execute`，fail-closed）、`ai.ProposalPipeline`(`proposal.zig:78`：`guard(.propose)`→`RiskReview`→（escalate）`ApprovalFlow`→`guard(.execute)`)、`ai.AgentWorker`(`agent_worker.zig:72`，有界邮箱 + 监督 + 生命周期，§八 的 `Agent→Worker→Event` 已通)、`MemoryStore`（agent 路径按 tenant+user 注入，身份缺失=不注入）。**缺** Agent 的 State / Event subscriptions / Lifecycle |
| 7 | DX / CLI | ⚠ 部分（**六件套已落地**） | 28 个子命令(`tools/zmodu/src/main.zig:373-408`：new/module/scaffold/audit/graph/doctor/ci/mcp/…)。✅ **`zmodu module <name> --full`** 追加六件套（model/persistence/service/api/root/module_test，`main.zig:1152`），生成物经 `zig fmt --check` 解析校验；✅ **`zmodu ci` 六步** = compile → fmt → verify → audit → deadcode → **doctor**（`ci.zig:62,98,129,145,173,191`）。**缺** `create app`(app.zig / domain / infrastructure / config / Dockerfile / compose) 一键生成 |
| 8 | Workflow Runtime | ⚠ 部分（**timeout 已生效**） | Saga 补偿逆序回滚(`SagaOrchestrator.zig:302`)、WAL 检查点 + 崩溃续跑(`resumeInstance:279`、`restoreFromWal:422`，测试 `:781`、`:820`、`:865`)；**`SagaStep.timed_out` 已真赋值**——step 超 `timeout_seconds` 就补偿已跑过的步骤、状态置 `.timed_out` 并返回 `error.SagaStepTimeout`(`:243-252`，测试 `620`/`680`)。**缺** 状态机、`.step().compensate()` DSL（`docs/WORKFLOW.md` 明确不做） |
| §十一 | Visualization | ⚠ 部分（**doctor 补三项 + `graph --dot` 已进 CI**） | `zmodu doctor`(`tools/zmodu/src/doctor.zig`) 已补三项 **advisory** 检查：未解析服务 / 消费者计数(`--max-consumers N`) / 事件拓扑，查不到就输出 `n/a (静态分析不可得)` 不编数字(`doctor.zig:16-22,624-660`)；✅ `zmodu graph --dot` 把 `ModuleGraph.renderDot` 接进 CLI(`main.zig:635,667`，测试 `:9054`)；✅ `doctor` 已作 `zmodu ci` 第 6 步，并与 CI 的 examples doctor 循环(`ci.yml:166`)同口径。**仍缺** 原文清单里"违禁 import / 生命周期图"等硬检查（当前只报 advisory） |
| §十六 | alpha-engine 参考实现 | ⚠ **P0+P1 已落地，P2 进行中，P3 未做** | `examples/alpha-engine`（`src/main.zig` 604 行 + README 111 行）：**P0** 骨架 `feed→OrderBook→Alpha→Risk→Execution→PaperExchange` 确定性 offline replay；**P1** 观测容错已开 —— HotBus 扇出(audit/metrics)、`book.after(200, .snapshot)` 定时器、`FaultyFillReporter` 走 `spawnActor` + 错误预算，结束时打印 `bus.stats()`/`rt.stats()`（`main.zig:9-31,549-585`）。**P2** 门禁面已接（进 CI 构建列表 `ci.yml:153` 与 doctor 循环 `:166`），但模块拆分未做（仍只有 `Pipeline` 一个 `api.Module`）；**P3** AI 提议侧未做。规格：`docs/dev/alpha-engine-spec.md` |

**完成度（2026-09-17 复核，v0.24.0）** —— 计分口径：每条 todo3 子诉求 **1.0** = 有实体代码 + 测试 + **被采用**（框架内或参考示例真的走这条路）；**0.5** = 有代码有测试但**没人用**（孤岛）；**0** = 没有。

| # | 方向 | 完成度 | 主要失分点 |
|---|------|:-----:|-----------|
| 1 | Hot Runtime | **~82%** | 孤儿原语只剩 `object_pool`（`Sequencer` 已接 `ai/agent.zig`）；MPMC/SPMC、scheduler / reactor / arena / metrics 文件族不存在 |
| 2 | Actor / Worker | **~72%** | worker 模型已被两个示例真用；仍无 `Worker(State)` 泛型类型、无 `ActorSystem`、无真监督树 |
| 3 | Compile-time Architecture | **~55%** | 机制强（编译期报环，超出原文设想）、**声明面弱**：`module(.{.imports,.exports})` 与 `cannot_import` 仍无法表达 |
| 4 | Event 三层 | **~78%** | L0 `HotBus` 框架内无消费者（**刻意定位**，非孤儿）且已有应用侧示例（alpha-engine 扇出）；无 Redis Stream；L2 无统一接口 |
| 5 | Distributed Runtime | **~65%** | 读侧接线 + `RaftTransport` 真传输 + 计票/追平修复 + 多节点 fail-closed 均已落地；仍无统一门面、LB 无接入点、2PC 无持久化协调日志、跨主机发现受限 |
| 6 | AI-native Runtime | **~92%** | Guard 进 `Agent.run` / `AgentSpec` / `ProposalPipeline` / `AgentWorker` 全落地；Agent 的 State / Event subscriptions / Lifecycle 不存在 |
| 7 | DX / CLI | **~70%** | `module --full` 六件套 + `ci` 六步（含 doctor）已落地；无 `create app`（app.zig / domain / infrastructure / config / Dockerfile / compose） |
| 8 | Workflow Runtime | **~62%** | `timed_out` 已生效（超时即补偿）；无状态机；DSL 主动不做 |
| §十一 | Visualization | **~68%** | doctor 补三项 advisory + `graph --dot` + 已进 `zmodu ci`；原文清单里的硬检查仍有未做项（当前只报 advisory） |
| §十六 | alpha-engine | **~50%** | P0+P1 完整且被 CI / doctor 门禁采纳；P2 模块拆分未做（门禁面已接）、P3 AI 侧未做 |

- **版本路线图：v0.16 → v0.24 九版按序交付 = 100%**（前六版照 §十五 的路线图，v0.22–v0.24 是"采用/接线"批次）。
- **加权总体 ≈ 70%**：前四个"护城河"方向按 ×2 权重 →
  `(82+72+55+78)×2 + (65+92+70+62+68+50)` = `574 + 407` = `981 / 14` ≈ **70.1%**。
- 同一批事实换三个口径看：**能力存在性 ≈ 88%**（几乎都有代码）／**采用度 ≈ 78%**（Runtime / Agent→Worker / Cluster 读侧三条装配线已通，
  且 `examples/alpha-engine` 把 HotBus 扇出 + 定时器 + 监督 + 快照跑成一条真链路）／**todo3 的产品定位目标 ≈ 70%**（"Modular Runtime Platform + killer reference impl"）。
- 本轮（v0.21 → v0.24）分阶段成果：① **Runtime 采用接通**（模块 `ctx.runtime()` + app 生命周期 + e2e 测试 +
  两个示例走 app+module 路径）② **§八 的 `Agent→Worker→Event` 接通**（`ai.AgentWorker`）且**把 `Guard` 接进 `Agent.run`**
  （每次工具调用先过闸门，被拒当工具结果喂回模型，不扣 guard 预算）③ **Cluster 读侧接通 + 真传输落地**
  （`MembershipView` / `RaftTransport` / 计票与追平修复 / 多节点 fail-closed）④ **alpha-engine P0+P1**（P1 观测容错已开并进 CI + doctor）
  ⑤ **DX 与可视化**（`module --full`、`ci` 六步含 doctor、`graph --dot`）⑥ **文档/示例品质批次**
  （导出面 `///` 覆盖到 100%、`docs/**` 片段门禁、`examples/README.md` 索引 20/20 并收敛重复示例、outbox 占位符真 bug 修复）。

**结论：零件齐，装配线建成三条（Runtime 采用、Agent→Worker→Event、Cluster 读侧），这一批把"存在但没人用"与"文档承诺未兑现"两类债基本清完；剩下的宽缺口在参考实现的纵深与集群的收尾。** 接下来的 ROI 顺序：① **alpha-engine P2/P3**（P2 拆 `market`/`book`/`alpha`/`risk`/`exec` 模块；P3 用 `ai.AgentWorker` + `ai.ProposalPipeline` 演示"Agent 默认不能直接交易" —— 让"killer reference impl"真的成立）② **集群门面与 2PC 持久化**（给 `LoadBalancer` 一个接入点、或明确降级为"单机 modulith + 外部 LB"；`DistributedTransaction` 的协调日志落盘）③ **真选主的状态机剩余项**（`ClusterBootstrap` 自动起入站 server 与 `raft.tick()`、`InstallSnapshot` 出站、端到端追平）。


**现在的 ZigModu 已经不是“功能不够”的问题，而是产品定位还可以再往上提一层。**

目前它已经覆盖了 Modulith、DI、Event、HTTP、WebSocket、gRPC、ORM、Redis、Kafka、Resilience、Observability、Security、AI、CLI 等相当完整的能力；仓库目前是 `v0.15.47`，并且明确定位为 Zig 0.17 的 Modulith Framework。([GitHub][1])

但如果目标是让它在未来 2～3 年形成**真正有竞争力的 Zig 基础框架**，我不会继续单纯增加 CRUD / Web API 功能，而会把它升级成：

# ZigModu = Modular Runtime for High-Performance Systems

也就是：

> **从 Modulith Framework → Modular Runtime Platform**

这样才能和 Spring Boot / Spring Modulith、Go Kit、Actix/Axum、Tokio 生态形成不同维度的竞争。

---

# 一、我认为最应该升级的 8 个方向

按照重要程度，我会排成：

| 优先级   | 升级方向                       | 战略价值 |
| ----- | -------------------------- | ---: |
| ⭐⭐⭐⭐⭐ | Hot Runtime                |   极高 |
| ⭐⭐⭐⭐⭐ | Actor / Worker Runtime     |   极高 |
| ⭐⭐⭐⭐⭐ | Compile-time Architecture  |   极高 |
| ⭐⭐⭐⭐⭐ | Event-driven Runtime       |   极高 |
| ⭐⭐⭐⭐  | Distributed Runtime        |    高 |
| ⭐⭐⭐⭐  | AI-native Runtime          |    高 |
| ⭐⭐⭐⭐  | Developer Experience / CLI |    高 |
| ⭐⭐⭐   | Data / Workflow Runtime    |   中高 |

其中前四个，才是 ZigModu 真正的护城河。

---

# 二、第一优先级：Hot Runtime

这是我最建议你现在做的。

现在 ZigModu 已经有一些性能设计，比如 ArenaAllocator、Object Pool、`ensureTotalCapacity`、branch hints 等。([GitHub][1])

但这些还是：

> **Application Framework 的性能优化**

还不是：

> **High-performance Runtime**

这两个定位完全不同。

## 建议增加

```text
zigmodu/runtime/
├── runtime.zig
├── scheduler.zig
├── worker.zig
├── reactor.zig
├── ring_buffer.zig
├── queue.zig
├── mailbox.zig
├── timer_wheel.zig
├── clock.zig
├── sequencer.zig
├── object_pool.zig
├── arena.zig
└── metrics.zig
```

核心组件：

### RingBuffer

```zig
pub fn RingBuffer(comptime T: type, comptime N: usize) type
```

支持：

```text
SPSC
MPSC
SPMC
MPMC
```

但不要一上来全部做。

第一版：

```text
SPSC
MPSC
```

就够。

---

# 三、第二优先级：Actor / Worker Model

这是我认为 ZigModu 很值得做的东西。

不要把 ZigModu 做成：

```text
Module
 ↓
Service
 ↓
Function
```

而应该支持：

```text
Module
 ↓
Worker
 ↓
Mailbox
 ↓
Event
 ↓
State
```

例如：

```zig
const OrderBookWorker = Worker(OrderBook);
```

它拥有自己的：

```text
State
Mailbox
EventQueue
Timer
Lifecycle
Metrics
```

形成：

```text
                    ┌──────────────┐
                    │ Application  │
                    └──────┬───────┘
                           │
             ┌─────────────┼─────────────┐
             ↓             ↓             ↓
        Worker A       Worker B       Worker C
        BTC/USDT       ETH/USDT       SOL/USDT
             │             │             │
          mailbox       mailbox       mailbox
```

最大的价值是：

> **减少共享状态 + 减少锁 + 明确状态所有权。**

这对于：

* 量化
* WebSocket
* 游戏服务器
* IoT
* 实时交易
* AI Agent
* 区块链节点
* 消息系统

都非常适合。

---

# 四、第三个核心：Compile-time Architecture

这个其实是 ZigModu 最应该强化的护城河。

现在已经有：

> Declarative module definition + compile-time dependency validation

这是非常好的方向。([GitHub][1])

但可以继续往前走。

---

## 做成 Compile-time Architecture Engine

例如：

```zig
const TradingModule = module(.{
    .name = "trading",

    .imports = .{
        MarketModule,
        RiskModule,
        ExecutionModule,
    },

    .exports = .{
        TradingService,
    },
});
```

然后编译期自动验证：

```text
Module Graph

Market
  ↓
Alpha
  ↓
Risk
  ↓
Execution
  ↓
Exchange
```

如果出现：

```text
Execution → Alpha
Alpha → Execution
```

直接：

```text
COMPILE ERROR

Circular dependency detected:

Alpha
  → Execution
  → Risk
  → Alpha
```

---

# 五、进一步做 Architecture Rules

这是非常有价值的。

例如：

```zig
.architecture(.{
    .no_cycle = true,

    .rules = .{
        .{
            .from = .alpha,
            .cannot_import = .http,
        },

        .{
            .from = .domain,
            .cannot_import = .database,
        },

        .{
            .from = .hot_path,
            .cannot_import = .orm,
        },
    },
});
```

于是 ZigModu 不只是：

> 帮你运行程序

而是：

> **帮你保证架构不会腐化。**

这就是 Modulith 真正应该做的事情。

---

# 六、第四个核心：Event Runtime 重新设计

目前 ZigModu 已经有：

```text
EventRegistry
TypedEventBus
TransactionalEvent
Outbox
DistributedEventBus
Kafka
```

这已经很丰富。([GitHub][1])

但我建议把 Event 分成三层。

## L0：Memory Event

极低延迟。

```text
RingBuffer
   ↓
Event
```

用于：

```text
Trade
BookUpdate
OrderUpdate
Fill
Timer
MarketState
```

要求：

```text
zero allocation
bounded
lock-minimized
```

---

## L1：Application Event

现在的：

```zig
app.eventBus(T)
```

继续保留。

用于：

```text
UserCreated
OrderCreated
PaymentCompleted
StrategyStarted
PositionChanged
```

---

## L2：Distributed Event

```text
Kafka
NATS
Redis Stream
QUIC
```

用于：

```text
跨进程
跨机器
跨地域
```

于是形成：

```text
                ZigModu Event Runtime

                     Event
                       │
          ┌────────────┼────────────┐
          ↓            ↓            ↓
        L0             L1           L2
      Hot Event     App Event    Distributed
          │            │            │
      RingBuffer     EventBus     Kafka/NATS
```

这会比单纯继续增加 EventBus 功能强很多。

---

# 七、第五个：Distributed Runtime

现在 ZigModu 已经有：

* DistributedEventBus
* ClusterMembership
* DistributedTransaction
* Kafka
* Sharding

但其中部分目前仍属于 experimental。([GitHub][1])

所以这里不要继续疯狂增加协议。

应该做：

# `ZigModu Cluster`

让多个 ZigModu 实例天然形成：

```text
                 Cluster
                    │
       ┌────────────┼────────────┐
       ↓            ↓            ↓
     Node A       Node B       Node C
       │            │            │
    Module        Module        Module
       │            │            │
    Worker        Worker        Worker
```

核心能力：

```text
Membership
Leader Election
Partition
Shard
Service Discovery
Distributed Event
Health
Load Balancing
```

但我建议：

**不要自己发明一套复杂 RPC 协议。**

优先：

```text
QUIC
gRPC
NATS
Kafka
```

做适配层。

---

# 八、第六个：AI-native Runtime

这个方向你已经开始做了，而且现在 ZigModu 已经存在 AI Provider、SkillRegistry、MemoryStore、SSE、ReAct Loop。([GitHub][1])

但是现在这些更像：

> “框架里面加了 AI 功能”

我建议升级为：

# Agent Runtime

即：

```text
Application
      │
      ↓
Agent
      │
 ┌────┼─────┐
 ↓    ↓     ↓
Skill Memory Tool
 │
 ↓
Worker
 │
 ↓
Event
```

---

## Agent 应该拥有

```text
Identity
Memory
State
Tools
Skills
Event subscriptions
Permissions
Lifecycle
Scheduler
Budget
Observability
```

例如：

```zig
const AlphaResearchAgent = Agent(.{
    .name = "alpha-research",

    .skills = .{
        MarketQuery,
        Backtest,
        FeatureAnalysis,
        StrategyDiscovery,
    },

    .permissions = .{
        .market_read = true,
        .order_submit = false,
    },
});
```

注意：

**AI Agent 默认不能直接交易。**

必须经过：

```text
Agent
 ↓
Proposal
 ↓
Risk
 ↓
Execution
```

这会让 AI + 金融系统非常漂亮。

---

# 九、第七个：Workflow Runtime

这个我认为未来会非常重要。

现在 ZigModu 有 Saga，但还可以进一步抽象。

例如：

```zig
workflow("OrderSettlement")
    .step(validate)
    .step(lock)
    .step(execute)
    .step(settle)
    .compensate(unlock);
```

最终形成：

```text
Workflow Runtime
```

支持：

```text
State Machine
Saga
Retry
Timeout
Compensation
Checkpoint
Resume
Schedule
Event trigger
```

这样 ZigModu 可以覆盖：

```text
金融
支付
订单
DAO
AI Agent
RWA
Web3
```

---

# 十、第八个：把 CLI 做成真正的开发平台

现在已经有：

```text
zmodu CLI
zig build zmodu
```

并且支持代码生成、SQL DDL、模型和 MCP Server 等。([GitHub][1])

下一步我会直接把它做成：

# `zmodu create`

例如：

```bash
zmodu create app myapp
```

生成：

```text
myapp/
├── src/
│   ├── app.zig
│   ├── modules/
│   ├── domain/
│   ├── infrastructure/
│   └── main.zig
├── tests/
├── migrations/
├── config/
├── Dockerfile
├── compose.yaml
└── build.zig
```

---

然后：

```bash
zmodu create module payment
```

自动：

```text
PaymentModule
PaymentService
PaymentEvents
PaymentRepository
PaymentRoutes
PaymentTests
```

---

# 十一、最重要的一点：做 Architecture Visualization

这是我特别建议你增加的。

例如：

```bash
zmodu graph
```

自动生成：

```text
                    Application
                         │
       ┌─────────────────┼─────────────────┐
       ↓                 ↓                 ↓
    Account            Trading           AI
       │                 │                 │
       ↓                 ↓                 ↓
   Identity            Risk             Agent
                         │
                         ↓
                     Execution
                         │
                  ┌──────┼──────┐
                  ↓      ↓      ↓
                Binance OKX  Hyperliquid
```

进一步：

```bash
zmodu doctor
```

输出：

```text
Architecture Health

✓ No circular dependencies
✓ No forbidden imports
✓ 0 orphan modules
✓ 0 unresolved services
✓ Event topology valid
✓ Lifecycle graph valid
⚠ 2 modules exceed dependency threshold
⚠ 1 service has 9 consumers
```

这个非常有产品价值。

---

# 十二、我反而不建议继续做什么

这是关键。

现在 ZigModu 已经有很多功能。

**不要继续走“大而全 Java Spring 替代品”的路线。**

比如暂时不要重点投入：

```text
更多 ORM
更多 HTTP Middleware
更多 CRUD
更多 JWT 功能
更多 Web API
更多数据库 Driver
```

因为这些很容易陷入：

> “Zig 版 Spring Boot”

竞争优势不明显。

---

# 十三、真正应该形成的产品结构

我会重新定义 ZigModu：

```text
                         ZigModu
                            │
             ┌──────────────┼──────────────┐
             │              │              │
        Core Runtime    Application     Distributed
             │              │              │
             ↓              ↓              ↓
          Module          HTTP/API       Cluster
          Worker          DI             Sharding
          Actor           Event          Discovery
          Event           Security       Messaging
          Scheduler       Data
             │
             ↓
       High Performance
          Runtime
             │
      ┌──────┼───────┐
      ↓      ↓       ↓
    Queue  Timer   Reactor
    Pool   Wheel   Network
```

然后再向上：

```text
                ZigModu Platform
                       │
        ┌──────────────┼──────────────┐
        ↓              ↓              ↓
   Web Backend      AI Agent       Financial
        │              │              │
        ↓              ↓              ↓
      SaaS          AgentOS        Alpha Engine
```

---

# 十四、我最看好的差异化：ZigModu + Modulith + Actor

如果让我给 ZigModu 找一个非常明确的技术标签，我不会叫：

> Zig Spring Modulith

而会叫：

> **Compile-time Modular Runtime for Zig**

进一步：

> **A compile-time modular, actor-oriented, event-driven runtime for Zig.**

这就完全不同了。

---

# 十五、最终技术路线

我建议未来 6 个版本这样走：

### v0.16 — Runtime

```text
RingBuffer
Queue
Worker
Mailbox
Clock
Timer
ObjectPool
Arena
```

### v0.17 — Actor / Event

```text
Actor
ActorSystem
Event Runtime
Event Routing
Backpressure
Supervision
```

### v0.18 — Architecture

```text
Compile-time dependency graph
Architecture rules
Cycle detection
Architecture CLI
Graph visualization
zmodu doctor
```

### v0.19 — Distributed

```text
Cluster
Shard
Service Discovery
Distributed Event
QUIC/gRPC
Leader
```

### v0.20 — Workflow

```text
Workflow
Saga
State Machine
Scheduler
Checkpoint
Resume
```

### v0.21 — Agent Runtime

```text
Agent
Memory
Skill
Tool
Permission
Agent Workflow
Agent Event
Agent Observability
```

---

# 十六、而你的量化系统正好可以成为“杀手级 Reference Implementation”

这是我觉得最有意思的地方。

不要为了证明 ZigModu 能做什么而做 demo。

直接做：

```text
ZigModu
   │
   └── examples/
          └── alpha-engine/
```

里面实现：

```text
MarketData
     ↓
OrderBook Worker
     ↓
Alpha Worker
     ↓
Risk Worker
     ↓
Execution Worker
     ↓
Exchange Adapter
```

再加：

```text
Replay
Backtest
Paper Trading
Live Trading
```

这样一个项目就同时证明：

```text
ZigModu
├── 高性能
├── Event-driven
├── Actor
├── Modulith
├── Distributed
├── Fault tolerance
├── Observability
└── AI Agent
```

而且金融交易这种 workload 对框架要求极高，比普通 Todo / Blog / CRUD 示例有说服力得多。

---

## 我会给 ZigModu 定一个非常明确的演进公式

你现在：

> **Modulith**

下一阶段：

> **Modulith + Runtime**

再下一阶段：

> **Runtime + Actor + Event**

最后：

> **Modular Runtime + Agent Runtime**

即：

```text
Module
   ↓
Worker
   ↓
Actor
   ↓
Event
   ↓
Workflow
   ↓
Agent
```

这条路线比继续堆 HTTP/ORM 功能更有竞争力。

而且这个方向与 Zig 本身的发展非常契合——Zig 0.17 周边正在强化 build server、增量编译等开发体验和底层能力；同时像 TigerBeetle 这类 Zig 生产项目也证明了“低延迟、可预测性能、数据密集型系统”是 Zig 很有辨识度的应用方向。([ziglang.org][2])

**如果是我来推进 `chy3xyz/zigmodu`，下一步不会再做功能堆积，而会直接做 `ZigModu Runtime 1.0`：`Worker + Mailbox + RingBuffer + TimerWheel + Sequencer + Actor + Hot EventBus`。** 这是最可能把它从“一个功能比较完整的 Zig Modulith 框架”变成“一个有自己技术范式的 Zig 基础设施”的升级点。 [ZigModu GitHub](https://github.com/chy3xyz/zigmodu?utm_source=chatgpt.com)

[1]: https://github.com/chy3xyz/zigmodu "GitHub - chy3xyz/zigmodu: A Modulith framework · GitHub"
[2]: https://ziglang.org/devlog/2026/?utm_source=chatgpt.com "Devlog ⚡ Zig Programming Language"
