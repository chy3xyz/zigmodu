# Modular Runtime for High-Performance Systems

> **复核（v0.21.0，2026-09-17）**：8 个方向已按 v0.16→v0.21 推进六个版本，**零件基本齐备**，但
> 「升级为 Modular Runtime Platform」这个目标**未完全达成** —— 差距在**采用/接线**与**参考实现**，
> 不在能力有无。逐条见下表；判定口径 = 代码里能跑、且有人用（证据为 文件:行号）。

| # | 方向 | 判定 | 关键证据 / 差距 |
|---|------|------|----------------|
| 1 | Hot Runtime | ⚠ 部分（**采用已接通**） | `src/runtime/` 8 文件 2783 行：SPSC(`ring.zig:45`) + MPSC(`:125`)、`mailbox.zig:42`、`timer_wheel.zig:28`、`hot_bus.zig:44`、`clock.zig:21`。✅ **已被框架采用**：模块 `ctx.runtime()`(`core/ModuleContext.zig`) + `app.runtime()` 首次创建即启动 ticker + `stop()` 先 join worker 再停模块（e2e 测试锁定 `ctx.runtime() == app.runtime()`；`examples/runtime-workers` 走 app+module 路径）。**仍缺** MPMC/SPMC、scheduler/reactor/arena/metrics；`sequencer.zig`/`object_pool.zig` 零使用者 |
| 2 | Actor / Worker | ⚠ 部分 | 契约式 worker + `Runtime.spawn`(`runtime.zig:340`)、监督(`:82,353,565`)、背压(`mailbox.zig:28`)；模块已能在 `initWith` 里 spawn（见第 1 行）。**仍缺** `Worker(State)` 泛型类型、`ActorSystem`、真监督树（`docs/RUNTIME.md` 已标"未承诺"） |
| 3 | Compile-time Architecture | ✅ 机制达成 | 编译期模块图 + 环路径报错(`ModuleGraph.zig:186-216` ← `Application.zig:428`)；`zmodu graph`/`doctor` 已发布。**未做** `module(.{.imports,.exports})` DSL 与 `cannot_import` 声明（原因见 `ModuleGraph.zig:24-30`） |
| 4 | Event 三层 | ✅ 基本达成 | L0 `HotBus`(`hot_bus.zig:44`)、L1 `app.eventBus`(`Application.zig:261`)、L2 Kafka/NATS/Outbox + 自研 TCP Bus。**缺** Redis Stream、L2 统一接口；L0 框架内部仍无消费者（只有 `examples/runtime-workers`） |
| 5 | Distributed Runtime | ⚠ 部分（**读侧已接通**） | 零件齐：`ClusterView.zig` + **`MembershipView.zig`（本轮接线：membership → view，`ClusterBootstrap.tick()` 驱动）**、`RaftElection.zig`(1311 行)、`LoadBalancer.zig`、`PeerDiscovery.zig`、`ShardRouter.zig`。**缺** 统一门面（仍无 `Cluster` 类型）、选主传输仍是桩（**已 fail-closed**：多节点启动直接拒绝，不再假装选主）、LB 无接入点；2PC 无持久化日志(`DistributedTransaction.zig:331`)；跨主机 gossip 发现按 `127.0.0.1` 记账（要解析器，或用 seed） |
| 6 | AI-native Runtime | ✅ 达成度最高 | `ai.AgentSpec`(`agent.zig:168`)、`ai.Guard`(`guard.zig:63`，已接进 `Agent.run`)、`ai.ProposalPipeline`(`proposal.zig`)、`ai.AgentWorker`(`agent_worker.zig`，§八 的 `Agent→Worker→Event` 已通)、`MemoryStore`(`memory.zig:23`，agent 路径 fail-closed)。**缺** Agent 的 State / Event subscriptions / Lifecycle |
| 7 | DX / CLI | ⚠ 部分 | 28 个子命令(`tools/zmodu/src/main.zig:373-408`：new/module/scaffold/audit/graph/doctor/ci/mcp/…)。**缺** `create app`(app.zig / domain / infrastructure / config / Dockerfile / compose) 与 `create module` 六件套一键生成（`module` 只写 module.zig，`main.zig:1096`） |
| 8 | Workflow Runtime | ⚠ 部分 | Saga 补偿逆序回滚(`SagaOrchestrator.zig:262`)、WAL 检查点 + 崩溃续跑(`:247`、`:390`，测试 `:719`、`:783`)。**缺** 状态机、生效的 timeout（`timed_out` 从不赋值）、`.step().compensate()` DSL（`docs/WORKFLOW.md` 明确不做） |
| §十一 | Visualization | ⚠ 部分 | `zmodu doctor`(`tools/zmodu/src/doctor.zig:49`) 清单 8 项中 3 ✅ / 2 ⚠ / 3 ❌（缺"未解析服务/事件拓扑/消费者计数"）；`graph` 仅 Mermaid(`main.zig:624`)，`ModuleGraph.renderDot` 未接 CLI；**`doctor` 已进 `zmodu ci`**（第 6 步，与 CI 对 examples 的门禁同口径） |
| §十六 | alpha-engine 参考实现 | ❌ 未做 | `examples/alpha-engine` 不存在；最接近是 `examples/runtime-workers`（行情→订单簿→风控，`examples/runtime-workers/src/main.zig:1-31`），缺 Execution / Exchange Adapter / Replay / Backtest / Paper / Live |

**完成度（2026-09-17 复核）** —— 计分口径：每条 todo3 子诉求 **1.0** = 有实体代码 + 测试 + **被采用**（框架内或参考示例真的走这条路）；**0.5** = 有代码有测试但**没人用**（孤岛）；**0** = 没有。

| # | 方向 | 完成度 | 主要失分点 |
|---|------|:-----:|-----------|
| 1 | Hot Runtime | **~78%** | `sequencer` / `object_pool` / `HotBus` 在 `src/runtime/` 之外零引用（看得到但没人用）；scheduler / reactor / arena / metrics 文件族不存在 |
| 2 | Actor / Worker | **~68%** | 无 `Worker(State)` 泛型类型（comptime 契约等价）、无 `ActorSystem`、无真监督树 |
| 3 | Compile-time Architecture | **~55%** | 机制强（编译期报环，超出原文设想）、**声明面弱**：`module(.{.imports,.exports})` 与 `cannot_import` 无法表达 |
| 4 | Event 三层 | **~75%** | L0 `HotBus` 框架内无消费者；无 Redis Stream；L2 无统一接口 |
| 5 | Distributed Runtime | **~50%** | 读侧接线完成（`MembershipView` 有发布者、`tick()` 驱动、组件已导出）；仍无统一门面、选主传输是桩、LB 无接入点；2PC 无持久化协调日志；跨主机发现受限 |
| 6 | AI-native Runtime | **~90%** | Agent 的 State / Event subscriptions / Lifecycle 不存在 |
| 7 | DX / CLI | **~60%** | 无 `create app`（app.zig / domain / infrastructure / config / Dockerfile / compose）；六件套非一键 |
| 8 | Workflow Runtime | **~55%** | 无状态机；`SagaStep.timed_out` 从不赋值（timeout 是假承诺）；DSL 主动不做 |
| §十一 | Visualization | **~50%** | doctor 缺 3 项检查；graph 仅 Mermaid；未进 `zmodu ci` |
| §十六 | alpha-engine | **~10%** | 未做；`runtime-workers` 只覆盖链路前三段 |

- **版本路线图：v0.16 → v0.21 六版按序交付 = 100%**（这是最硬的一项成绩）。
- **加权总体 ≈ 62%**：前四个"护城河"方向按 ×2 权重 →
  `(78+68+55+75)×2 + (50+90+60+55+50+10)` = `867 / 14` ≈ **61.9%**。
- 同一批事实换三个口径看：**能力存在性 ≈ 85%**（几乎都有代码）／**采用度 ≈ 70%**（Runtime / Agent / Cluster 读侧三条线已通）／
  **todo3 的产品定位目标 ≈ 62%**（"Modular Runtime Platform + killer reference impl"）。
- 本轮（2026-09-17）变化：① Runtime **采用已接通**（模块 `ctx.runtime()` + app 生命周期 + e2e 测试 +
  示例改走 app+module 路径）② §八 的 `Agent→Worker→Event` 接通（`ai.AgentWorker`：有界邮箱/背压/监督/生命周期，
  失败不占监督器错误预算）③ **Cluster 读侧接通**（`cluster/MembershipView.zig` + `ClusterBootstrap.tick()/getView()`；
  顺带修掉 gossip 负载里 `{any}` 打印结构体 dump 的地址格式问题，并把跨主机发现限制写进注释与文档）
  ④ `zmodu.builder(..).withName(..)` 链式误用 12 处已修（此前 README / docs / 注释里的片段**全部编译不过**）。

**结论：零件齐了，装配线建成三条（Runtime 采用、Agent→Worker、Cluster 读侧），集群的门面/选主/LB 仍空着。** 接下来的 ROI 顺序：① 集群门面（选主接真传输、LB 给接入点，或明确降级为"单机 modulith + 外部 LB"）② 给 `HotBus`/`sequencer`/`object_pool` 找真实消费者或删除（孤儿原语是最贵的债）③ CLI 六件套 / alpha-engine ④ 给文档片段加编译抽查。


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
