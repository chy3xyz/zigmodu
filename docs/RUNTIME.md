# ZigModu Runtime —— 第二条高速通道

> 定位：**Modulith（架构单元）+ Runtime（执行单元）**。
> 目标句式：*a compile-time modular, worker-oriented, event-driven runtime for Zig*。
> 版本口径：运行时代码自 **v0.16.0** 起（`zigmodu.runtime`）。参考 `docs/dev/todo3.md`（方向）与
> `docs/dev/todo3.1.md`（兼容策略）。

## 1. 为什么是"第二条通道"而不是重写

`Application` / `Module` / `DI` / `EventBus` / HTTP 已经跑在很多项目上，它们是**架构资产**。
运行时要做的是补上另一件正交的事：**一个线程拥有的状态、一个邮箱拥有交接、一个时间轮拥有延迟**。

```
                     ZigModu
                        │
        ┌───────────────┴───────────────┐
        │                               │
   Application（不变）             Runtime（新增·可选）
   Module / DI / Lifecycle          Worker / Mailbox
   EventBus / Outbox                RingBuffer / TimerWheel
   HTTP / ORM / Redis               ObjectPool / Clock
        │                               │
        └───────────────┬───────────────┘
                        │
              共享 io / config / observability
```

**没有 Actor 就不需要 Actor。** 普通 Web SaaS 继续写 `Application → Module → Service`；
只有在"减少共享状态、减少锁、明确状态所有权"能带来真实收益的负载上（WebSocket 扇出、
行情/订单簿、游戏房间、IoT 汇聚、AI Agent 循环）才引入 worker。

## 2. 兼容原则（写进契约，逐条可验证）

```
ZigModu Compatibility Principles

 1. Existing Module API remains stable.
 2. Existing Application API remains stable.
 3. Existing DI API remains stable.
 4. Existing Application EventBus remains stable.
 5. New Runtime APIs are additive.
 6. Hot-path runtime is opt-in.
 7. Distributed runtime is opt-in.
 8. Actor runtime is opt-in.
 9. Existing applications require no migration.
10. Breaking changes are reserved for 1.0.
```

落到实现上：

- `app.runtime()` 返回 `!*Runtime`，**首次调用才创建**；不调用 = 零线程、零定时器、行为与 v0.15 完全一致。
- `Application.stop()` 先 `runtime.shutdown()`（join 所有 worker）**再**停模块 —— worker 可能在调模块服务，顺序不能反。
- `Application.deinit()` 释放 runtime。
- 运行时**不碰** `Application.events`：`app.eventBus(T)` 仍是业务事件通道。事件分层（L0 hot / L1 app / L2 distributed）
  见 §6，L0 是 `MpscRing`，L1 是现有 EventBus，两者互不替换。

## 3. Worker：一个结构体，三种声明方式

```zig
const OrderBook = struct {
    pub const Message = Delta;            // 声明消息类型 → 运行时拥有接收循环
    bids: std.ArrayList(Level) = .empty,
    asks: std.ArrayList(Level) = .empty,

    pub fn init(self: *@This(), ctx: anytype) !void { ... }     // 可选，先跑一次
    pub fn handle(self: *@This(), msg: Delta, ctx: anytype) !void {
        // 只有这个线程碰 self.bids/self.asks —— 没有锁是因为没有共享
    }
    pub fn deinit(self: *@This()) void { ... }                  // 可选，最后跑一次
};
```

| 声明 | 运行时如何驱动 | 何时用 |
|------|--------------|--------|
| `pub const Message = T` + `pub fn handle(self, msg, ctx)` | **消息驱动**：运行时循环 `recv → handle`，`stop()`/`close()` 结束 | 绝大多数：worker 的输入就是消息 |
| `pub fn run(self, ctx)` | **自带循环**：跑一次，自行 `while (!ctx.stopped())` | 拉取型（轮询外部源）、需要精确控制节拍的循环 |
| `pub fn init` / `pub fn deinit` | 生命周期钩子，前后各一次 | 打开/关闭资源 |
| `pub fn onError(self, err, ctx) Supervision.Strategy` | **Actor 才有**：每条错误现场决定 `.restart` / `.stop`，覆盖配置的策略 | 只有某些错误值得停（如 `error.Fatal`） |

```zig
const rt = try app.runtime();
const book = try rt.spawn(OrderBook, .{}, 256);   // 256 = 邮箱容量（comptime）
try book.send(.{ .bid = 101, .qty = 2 });          // 满 → error.Full（背压可见）
try book.after(50, .{ .tick = true });             // 50ms 后投一条消息给同一个 worker
book.stop();                                       // 请求结束（join 由 shutdown/join 负责）
```

**契约要点**

- `ctx` 是 `WorkerContext(W, capacity)`，用 `anytype` 接 —— worker 作者不必写出容量参数。
- `ctx.stopped()`：`stop()` 或运行时关闭。**"没启动 ticker" 不算停止**（自己驱动 `tick()` 是受支持用法）。
- 定时器**只投消息**，不在 ticker 线程上跑你的代码：`ctx.handle.after(...)` 是唯一的延迟入口，
  这样 worker 的状态依然单线程独占。
- `handle`/`run` 返回的错误被记录并计数（`stats().handler_errors`），**不会**停掉 worker；
  panic 不可捕获，会带走进程 —— 热路径上的 panic 见 `docs/BEST_PRACTICES.md`「韧性」。

## 3b. Actor —— Worker + 监督（v0.17）

**Actor 不是新的运行单元，是加了失败策略的 Worker。** 这样"Module → Runtime → Worker → Actor"是一条直路，
不存在两套生命周期。

```zig
const h = try rt.spawnActor(Reporter, .{}, 32, .{ .max_errors = 3, .window_ms = 60_000 });
```

| 配置 | 含义 |
|------|------|
| `strategy = .restart`（默认） | 出错只记录，继续服务 —— 与 v0.16 的 worker 契约一致 |
| `strategy = .stop` | 首个错误即停（fail-fast，邮箱关闭、线程退出） |
| `max_errors` / `window_ms` | **错误预算**：窗口内超过 N 次即停。`0` = 不限 |
| `onError(self, err, ctx)`（可选声明） | 现场决策，**覆盖** `strategy` |

**为什么需要预算**：一个"每条消息都出错"的 actor，在"只记录不停止"的语义下会永远烧掉一个核，
从外部看却是健康的（线程在跑、邮箱在收）。预算把这种情况变成"停止 + 一条 warn + 计数"，
而不是一个安静的 CPU 黑洞。停止后 `stats().stopped_by_supervisor` 为真、邮箱关闭（生产者拿到
`error.Closed`），**不会**悄悄改成静默丢弃。

**停不下来的那些**：本版不实现"用干净状态重启 actor"（Erlang 的 process restart）——状态是 spawn 时
移进去的，重启意味着要么保留一份初始副本（要求 State 可拷贝），要么声明 `reset` 钩子并接受
"上一次失败留下的痕迹"。在语义确定之前宁可不给。**父子关系**目前只体现在**停止顺序**：`shutdown`
按 spawn 逆序 join，因此"先 spawn 父、再 spawn 子"就得到"子先停"。真正的监督树（父决定子的重启策略）
留给后续版本。

## 3c. HotBus —— L0 的扇出（v0.17）

一个事件、多个消费者（订单簿 + 风控 + 审计 + 指标），而发布方**不能等**。

```zig
var bus = runtime.HotBus(Trade, 4).init();   // 最多 4 个订阅者
try bus.subscribe(book);                     // 真 worker（任意 *Handle(W, cap)）
try bus.subscribeSink(metrics.sink());       // 普通 sink（不是 worker 也行）
bus.freeze();                                // 启动期接线结束
if (!try bus.publish(trade)) { /* 所有订阅者都满了 */ }
```

两条规则让它成为 L0 而不是"另一个 EventBus"：

1. **先 freeze 再跑流量**：订阅者在启动期接好、`freeze()` 之后 `publish` 就是一次**无锁、无分配**的切片遍历。
   未 freeze 就 publish 返回 `error.NotFrozen` —— 这是接线 bug，应该大声失败而不是竞争。
2. **丢，但不长**：每个订阅者是**有界邮箱**，满即丢该条并计数（`stats().dropped`）。慢消费者既不能拖慢发布方，
   也不能把内存吃光。

实测（`examples/runtime-workers`）：审计 worker 故意慢，指标 sink 是 O(1) —— 指标一条不漏、审计丢掉慢的那些、
**订单簿从未阻塞**。具体条数随示例版本变化（投递/丢弃由 feed 速率与邮箱容量决定），跑一次看当次输出即可，
别照抄历史数字。

与 `app.eventBus(T)` 的分工见 §6：L1 要"最终大家都看到"（可以分配、可以慢），L0 要"发布方绝不停"（有界、可丢）。

定位：HotBus 是**用户面向**的 L0 原语，框架内部没有消费者是**刻意的** —— 现有内部热路径要么单消费者
（`AgentWorker.on_result`）、要么点对点路由（`im.ConnectionRegistry`）、要么统计走拉取（`Runtime.stats()`），
接进去只会硬造订阅者并改动那条路径的语义。参考用法见 `examples/runtime-workers`。

## 3d. 模块里怎么用（Application 拥有 Runtime）

`Runtime` 不必自己 new：**`Application` 就是它的所有者** —— 首次用到时创建、ticker 自动跑、
`stop()` 时请求停止并 join。模块通过 `ModuleContext.runtime()` 拿到**同一个** runtime：

```zig
const zmodu = @import("zigmodu");
const rt = zmodu.runtime;

/// 拥有一个 worker 的模块：从 `initWith` 里 spawn，生命周期交给 app。
pub const BookModule = struct {
    pub const info = zmodu.api.Module{
        .name = "book",
        .description = "order book worker",
        .dependencies = &.{},
    };

    pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        const runtime = try ctx.runtime();               // 不是新建，是 app 的那个
        _ = try runtime.spawn(OrderBook, .{ .symbol = "BTC/USDT" }, 256);
    }
    pub fn deinit() void {}
};

// main：
var b = zmodu.builder(allocator, io);   // 先绑定：builder 方法收 `*Self`，临时值是 `*const`
defer b.deinit();
var app = try b.withName("trader").build(.{BookModule});
defer app.deinit();
try app.start();    // initWith 里 spawn 的 worker 已经在跑
defer app.stop();   // 先请求停止 + join worker，再停模块
```

规则：

- **模块只借不还**：不要在模块里 `Runtime.init` —— 那样线程没人 join；`ctx.runtime()` 拿到的那个由 app 收尾。
- **停止顺序是刻意的**：`app.stop()` **先** join 所有 worker，**再** `Lifecycle.stopAll`。worker 可能正在调模块服务，
  反过来就会 use-after-free。
- **不要在模块里 `rt.shutdown()` / `rt.deinit()`**：虽然幂等，但会提前打断别的模块的 worker。
- **测试想用 `Manual` 时钟自己 `tick()`？** 那就别走 app：`Runtime.init(alloc, io, .{ .manual = &clk })`
  并自己 `defer rt.deinit()`（`src/runtime/runtime.zig` 的单测就是这么做的）。
- 没有 provider 的裸 harness（直接调 `Lifecycle.startAllWith`）里 `ctx.runtime()` 返回 `error.RuntimeUnavailable` ——
  明确失败，而不是偷偷给你一个没人管的 runtime。

接线在 `Application.start()`（注入 `ModuleContext.runtime_provider`）与 `Application.runtime()`；
`ctx.runtime() == app.runtime()` 这条不变量有 e2e 测试兜底（`src/Application.zig` 「a module spawns workers through ctx.runtime()」）。

## 4. 原语与取舍

| 类型 | 并发形态 | 关键性质 |
|------|---------|---------|
| `RingBuffer(T, N)` | 1 生产者 / 1 消费者 | 无 CAS（各自只读对方指针）；N 必须 2 的幂 |
| `MpscRing(T, N)` | N 生产者 / 1 消费者 | Vyukov 有界队列；**N ≥ 2**（N=1 时序号无法区分"空"与"未消费"，编译期拒绝） |
| `Mailbox(T, N)` | N 生产者 / 1 消费者 | 有界 + 阻塞；`send` 满即 `error.Full`，`sendBlocking` 换延迟；`close()` 唤醒等待者 |
| `Wheel(Payload)` | 单线程驱动 | 分层时间轮，O(1) 插入/取消；10ms 粒度、5 层、最长 ~124 天；长停摆走 O(pending) 扫描 |
| `ObjectPool(T)` | 多线程 | 定容 + 自旋锁；`acquire` **不分配**，耗尽返回 null（把流量高峰变成"削峰"而不是 OOM） |
| `Clock` | 值类型 | `.monotonic`（生产）/ `.manual`（测试：不睡觉就能推动一小时定时器） |
| `Sequencer` | 多线程 | 无锁单调序列：`next()` / `nextBatch(n)` / `advanceTo()`；**不是时钟**（只在进程生命期内有意义） |
| `HotBus(E, N)` | 1 发布者 / 多订阅者 | freeze 后无锁发布、drop-on-full、计数齐全（见 §3c） |

**为什么池用自旋锁而不是无锁栈**：Treiber 栈在索引上有一个 ABA 窗口，会把同一个对象发给两个调用者 ——
那是任何测试都不稳定复现的数据竞争。临界区只有一次指针交换，锁的代价远小于"正确性靠运气"。
真出现争用，正确做法是**按线程分片**，不是把锁去掉。

## 5. 背压语义（这是运行时的核心承诺）

```
生产者 ──send──▶ 邮箱（有界 N）──recv──▶ worker
   │                  │
   │ 满               │ 空
   ▼                  ▼
error.Full        阻塞等待（recv(0)）或超时（recv(ms)）
（由调用方决定丢弃/合并/退避）
```

三条规则：

1. **队列永不增长**。容量是 comptime 的，`error.Full` 是唯一出口 —— 内存曲线可预测。
2. **丢弃必须可见**。`stats().dropped_full` 计数，`RuntimeStats` 汇总，接 Prometheus 只是时间问题。
3. **消息是值**。`T` 按值拷贝进队列；要传堆对象就传指针并显式约定所有权，别让 `T` 偷偷拥有内存。

## 6. 事件分层（L0 / L1 / L2）

| 层 | 载体 | 语义 | 用于 |
|----|------|------|------|
| **L0** | `MpscRing` / `Mailbox` + worker | 有界、零分配、单线程消费 | 行情、订单簿、Tick、房间广播、内部命令 |
| **L1** | `app.eventBus(T)`（现有，不动） | 进程内、类型化、可订阅 | `UserCreated` / `OrderCreated` / 领域事件 |
| **L2** | Kafka / NATS / Outbox | 跨进程、至少一次 | 跨服务、跨机房 |

L0 与 L1 是**两个通道，不是一个**：不要把热路径塞进 L1（它是为可读性与可靠性设计的），
也不要把业务事件塞进 L0（它没有订阅模型、不落盘）。

## 7. 何时不要用运行时

- CRUD、后台管理、普通 API：模块 + service 已经够了，worker 只是多一层。
- 需要"同一份状态被多个线程读"：那是共享内存问题，先考虑冻结快照（`FrozenMap`）或把状态搬进 worker 再问。
- 需要跨进程顺序：用 Kafka/NATS（L2），别自己写 RPC。

## 8. 可观测性

```zig
const s = rt.stats();
// workers / running / messages_sent / messages_received
// messages_dropped / handler_errors / timer_fires / timer_lag_max_ms
```

`timer_lag_max_ms` 是"定时器迟到的最大值"：ticker 被饿死、或某个 `post` 太慢时会变大 ——
它比"定时器数量"更能说明运行时是否健康。每个 worker 的明细在 `handle.stats()`。

**接进 `/metrics`**：`RuntimeStats` 有现成的桥，起服务时接一次即可，抓取时采样（无后台线程）：

```zig
var bridge = try zigmodu.Runtime.MetricsBridge(PrometheusMetrics).init(&rt, metrics);
metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge);
```

它注册 8 条 `zigmodu_runtime_*` 指标（`workers` / `running` / `messages_sent` /
`messages_received` / **`messages_dropped`** / `handler_errors` / `timer_fires` /
**`timer_lag_ms`**）。名字里没有 `_total` 后缀是刻意的：这些是**抓取时采样**的快照，所以走 gauge
而不是 counter（`PrometheusMetrics.Counter` 没有 `set`）。

**为什么必须有这一步**：`messages_dropped` 与 `timer_lag_ms` 只在这里出现 —— 邮箱打满、定时器被饿死
在 HTTP 侧**完全看不见**，只看请求直方图会得出"一切正常"的结论。

`MetricsBridge` 对 `MetricsT` 是鸭子类型（只要求 `createGauge` + `Gauge.set`），所以 runtime 层
不依赖 observability 层。`bridge` 的生命周期要覆盖进程（别放在会返回的栈帧里）。

## 9. 路线图（本文件随之更新）

| 版本 | 内容 | 状态 |
|------|------|------|
| **v0.16.0** | `RingBuffer` / `MpscRing` / `Mailbox` / `ObjectPool` / `Clock` / `Wheel` / `Runtime` + `Worker` + `app.runtime()` | ✅ 本文档 |
| **v0.17.0** | Actor 监督（`spawnActor` + 错误预算 + `onError` 现场决策）、`HotBus`（L0 扇出，freeze 后无锁、drop-on-full）、`Sequencer` | ✅ 本文档 §3b/§3c |
| **v0.18** | 编译期架构引擎：依赖图（`ModuleGraph` 编译期报环）、`zmodu graph`（Mermaid）、`zmodu doctor` | ✅ 已发布（doctor 清单仍未覆盖"未解析服务/事件拓扑/消费者计数"，见 `docs/dev/todo3.md` 评估） |
| 之后 | 真监督树（父决定子的重启策略）、带干净状态的重启、跨进程/跨节点监督 | 未承诺 |
| **v0.19** | Cluster / Shard / Service Discovery | ⚠ 部分：`ClusterView`（读侧快照/rendezvous）、`ShardRouter` 落地；**v0.25.0 起 `ClusterBootstrap` 已是门面** —— `tick()` 一次做完 `membership.runOnce()` → `view.sync()` → `raft.tick()`（此前从没人驱动选举）、配 `.transport` 时 `start()` 自动起入站监听、`pick(key)` 与 `healthJson()` 都在它上面；集群组件从 `root.zig` 正面导出。集群传输仍是自造 TCP（未按本节原意"适配 QUIC"）；`LoadBalancer` 是**有意不接**（数据源与读侧是两份事实，见 `docs/DISTRIBUTED.md`）。剩余缺口见 `docs/DISTRIBUTED.md` |
| **v0.20** | Workflow（状态机 + Saga + 补偿 + 检查点 + 恢复） | ⚠ 部分：Saga 补偿 + WAL 检查点 + 崩溃续跑 ✅（`SagaOrchestrator.resumeInstance` / `restoreFromWal`）；**`SagaStep.timeout_seconds` 已于 v0.25.0 真正生效**（超预算即补偿含该步、终态 `.timed_out`、返回 `error.SagaStepTimeout`）；**状态机仍未做**，`.step().compensate()` DSL 明确不做（`docs/WORKFLOW.md`） |
| **v0.21** | Agent Runtime（Identity / Memory / Skills / Permissions / Budget 一等化） | ✅ 已发布：`ai.AgentSpec` + `ai.Guard`（已接进 `Agent.run`）+ `ai.ProposalPipeline` —— 见 `docs/AGENT_RUNTIME.md`；**Agent 的 State / Event subscriptions / Lifecycle 仍未做** |
| **v0.22.0** | Agent 跑成 worker（`Agent → Worker → Event`） | ✅ `ai.AgentWorker`：`rt.spawn(ai.AgentWorker, …)` + `ai.agent_worker.post(...)`，有界邮箱 / 生命周期 / 监督 / 指标跟着来 —— 见 `docs/AGENT_RUNTIME.md` §六 |
| 1.0 | API 收敛、命名统一、deprecated 清理 | 计划 |

## 10. 最小示例

见 `examples/runtime-workers/`：一条"行情源 → 订单簿 worker → 风控 worker → 快照定时器"的流水线，
既演示 worker/邮箱/定时器，也演示背压（`error.Full` 时的合并策略）与优雅停机。
