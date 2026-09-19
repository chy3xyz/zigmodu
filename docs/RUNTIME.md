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
 5. New Runtime APIs are additive — no existing Runtime call silently changes
    meaning; a replacement is a deletion plus a documented migration (item 10).
 6. Hot-path runtime is opt-in.
 7. Distributed runtime is opt-in.
 8. Actor runtime is opt-in.
 9. Existing applications that never touch `runtime` require no migration.
10. Runtime API may break during 0.x — precedent: §9, v0.28.0 removed
    `Runtime.cancelTimer(id) bool`. Application / Module / DI / EventBus / HTTP
    keep the backward-compatibility promise above.
```

落到实现上：

- **兼容性是分层的，"0.x 不破坏"不成立**（第 5/9/10 条）：`runtime.*` 在 0.x 阶段允许 breaking
  evolution，已发生的先例就是 **v0.28.0 删掉 `Runtime.cancelTimer(id) bool`** —— §9 路线图里那一行
  （"定时器时间轮改为 **ticker-owned**"），迁移步骤在 `docs/UPGRADING.md` 的 v0.28.0 段。删它的理由
  不是"改名字"，而是时间轮改成 ticker-owned 之后它再也回答不了"是否已取消"，留着就是**静默改义**。
  `Application` / `Module` / `DI` / `EventBus` / HTTP 的公开契约不在这条允许范围内：它们只增不改
  （第 1–4 条），所以"不碰 runtime 的应用升级不用动代码"仍然是一句可验证的话。运行时的每一次
  breaking 都必须同时落进 §9 的路线图与 `docs/UPGRADING.md` 的对应版本段 —— 只写在 CHANGELOG 里
  不算数。
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
- `ctx.traceId()`：**当前正在处理的这条消息**带的 trace id（`sendTraced` 附上的），没有则 `null`；
  `init`/`run` 阶段也是 `null`。见 §8.1。
- 定时器**只投消息**，不在 ticker 线程上跑你的代码：`ctx.handle.after(...)` 是唯一的延迟入口，
  这样 worker 的状态依然单线程独占。
- **`after` 到底做了什么**（v0.28 起）：调用方只做三件事 —— 取一个 id（`Sequencer.next()`，无锁）、
  用自己的时钟读算出 `deadline`、把一条 `arm` 命令推进 `Runtime` 的有界命令队列（定容、**入队不分配**）。
  真正碰时间轮的只有**拥有它的那一个线程**：命令行上的 ticker（或自己 `tick()` 的那个线程）每轮
  **先 drain 命令、再 `advance`**，由它做 `wheel.schedule`/`cancel` —— 时间轮因此是单写者状态，
  不需要锁，也不会出现两个线程同时写 `nodes` 的哈希表撕裂（这正是 v0.27 的缺陷）。
  - **有效延迟** = `∈ [delay_ms, delay_ms + 入队延迟 + tick_interval_ms]`：`deadline` 在**调用侧**
    算好，所以 `after(50)` 始终是"从这次调用起 +50"，与 ticker 忙不忙无关；tick 间隔是 **5ms**。
    这个上界成立靠的是时间轮的**推进口径**（v0.28.0 修正，之前不成立）：一次 `advance` 里
    **已经走过的槽整槽过期**（槽终点已在 `now` 之前，槽里每个定时器都已到期），而 `now` 所在的
    **当前槽每轮只发"到期了的"**、没到期的不动、下一个 tick 再看。于是 10ms 的槽粒度既不把延迟
    抬到"下一个槽边界"（那会到 ~15ms），也不提前一个槽触发（那是违反"至少 delay_ms"的另一半）。
    实测偏差看 `timer_lag_ms`（§8）—— 它是 `clock.nowMs() - deadline`，还包含 ticker 的唤醒抖动，
    所以夜里/满载下偶尔略高于 5ms 属于抖动，不是契约失效。
  - 命令队列满 = `error.Full`（**不静默丢**，和邮箱同一条原则）：调用方自己决定丢弃/合并/重试。
- **取消有两个入口，语义写在名字里**（v0.28）：
  - `rt.requestCancelTimer(id) !void` —— 热路径，含义是"**请求已交给 Runtime**"，约一个 tick 后生效；
  - `rt.cancelTimerSync(id) !bool` —— 控制面，等 owner 执行完并返回**最终结果**（`true` = 当时还在 pending）。
  ARM 与 CANCEL 走**同一条 FIFO 队列**，所以"先 arm 后 cancel"与"先 cancel 后 arm"的结果是确定的
  （前者被取消、后者正常触发），不是掷骰子。
- **停机不丢已 arm 的定时器**（v0.28）：`shutdown()` 释放**所有还没触发**的定时器 payload —— 既包括还在
  命令队列里的 arm，也包括**已经进轮**的节点；释放条数汇总在 `stats().timers_discarded`（§8）。
  释放只能在时间轮的 owner 线程上做，所以有 ticker 时由 ticker 在退出前完成（`shutdown()` 只负责 join），
  自己 `tick()` 驱动时由那个调用者线程完成。`shutdown()` 仍然**幂等**：两次调用不会重复释放（也不会 double-free）。
- **停机顺序是有意义的，不是整理**（v0.28 起）：`alive = false` → **停 ticker（broadcast + join）** →
  worker 的 `request_stop` → join → `destroy` → 清命令队列 → drain。定时器的 `post` 投递目标是**arm 它的
  那个 worker handle**，而 `destroy` 释放那个 handle —— ticker 若还在跑，join worker 的这几毫秒里到期
  的定时器就会 `post` 到已释放的内存（这是真故障，不是理论风险）。先 join ticker 把窗口关掉，并且因为
  ticker 退出前自己会 drain，"停机时还 pending 的定时器"的语义被钉死为 **drop，而不是投给将死的 worker**。
  另外 `onTimerFire` 在 `alive = false` 时**只 drop 不 post**（计入 `timers_discarded`）：这是纵深防御，
  覆盖另一个线程的 `tick()` 与 `shutdown()` 并发这种超出 owner 契约的用法。
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

要事后重放这段投递流，用 **EventRecorder**（§11.6）：`bus.attachRecorder(&rec)` 必须在 `freeze()` 之前，
记录点在**扇出之前** —— 它不占订阅者槽位，也不会被计成 `dropped`；日志满则 `error.Full`（不静默丢），
`stats().record_dropped` 与 `publish` 的返回值都会说出来。

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
  反过来就会 use-after-free。runtime 内部第一层同样有顺序：**先停 ticker，再拆 worker**（见 §3
  「停机顺序是有意义的」）—— 理由一模一样的另一面：ticker 会向 worker 的 handle 投递定时器消息。
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
| `Wheel(Payload)` | **单线程驱动（ticker 独占）** | 分层时间轮，O(1) 插入/取消；10ms 粒度、5 层、最长 ~124 天；`advance(now)` 的语义是"到期即发、不到期不发"——走过的槽整槽过期，`now` 所在的槽只发到期的那部分（没到期的留到下一个 tick），所以 10ms 槽粒度不写进延迟上界（§3）。长停摆走 O(pending) 扫描。**零锁**：`schedule`/`cancel`/`advance`/`drainAll` 只有驱动它的那一个线程能调（Debug/ReleaseSafe 下 `claimOwner`+`assertOwner` 会拦）；跨线程只通过 `Runtime` 的有界命令队列交接，见 §3「`after` 到底做了什么」。`drainAll` 是 fire/cancel 之外的第三个出口：停机时把还在轮里的 payload 交给同一个 `drop` 钩子 |
| `ObjectPool(T)` | 多线程 | 定容 + 自旋锁；`acquire` **不分配**，耗尽返回 null（把流量高峰变成"削峰"而不是 OOM） |
| `Clock` | 值类型 | `.monotonic`（生产）/ `.manual`（测试：不睡觉就能推动一小时定时器） |
| `Sequencer` | 多线程 | 无锁单调序列：`next()` / `nextBatch(n)` / `advanceTo()`；**不是时钟**（只在进程生命期内有意义） |
| `HotBus(E, N)` | 1 发布者 / 多订阅者 | freeze 后无锁发布、drop-on-full、计数齐全（见 §3c） |
| `Recorder(E, C)` | N 生产者 / 单线程重放 | 定容追加日志，**满即 `error.Full`（不覆盖、不静默丢弃）**；序号即槽位，`entries()` 无锁给出 seq 升序前缀；`replay` 驱动 `Clock.Manual`、不 sleep（见 §11.6） |
| `Scheduler`（池化执行，§12） | N 生产者 / **1 池线程**（Phase 1） | 就绪环（Vyukov，堆上切片）：容量 = `ceilPowerOfTwo(max_pooled_workers)`，**按声明的上界算出来，不是常数**；D4 ⇒ 每 worker 至多一个 token ⇒ `push` 永不失败（失败 = 调度器失联，不是背压：断言 + `ready_push_failures`）。`claimed`（正被跑）/ `queued`（在环里等）是**两个位**；worker 数超过声明上界时 `spawn` 直接 `error.PoolCapacityExceeded`。见 §12.10 |

**为什么池用自旋锁而不是无锁栈**：Treiber 栈在索引上有一个 ABA 窗口，会把同一个对象发给两个调用者 ——
那是任何测试都不稳定复现的数据竞争。临界区只有一次指针交换，锁的代价远小于"正确性靠运气"。
真出现争用，正确做法是**按线程分片**，不是把锁去掉。

**为什么时间轮没有锁**：它不需要"多线程安全"，它需要"只有一个写者"。时间轮的字段（`now_ms` / `slots` /
`nodes` / id 计数器）全是单写者状态，给它加一把锁只是把一个**顺序**问题伪装成互斥问题：两个线程各自
`arm` 的先后仍然无定义。所以 v0.28 把它改成 **ticker-owned state machine** —— 生产者只推命令，
owner 独占执行，线性化顺序由队列的 FIFO 唯一确定（和 `Worker` 的 state 归 worker 线程、
`Mailbox` 归交接边界是同一套哲学）。`Wheel.claimOwner()` 发布 owner，`assertOwner()` 在
Debug/ReleaseSafe 下把"第二个线程碰它"变成调用点 panic，ReleaseFast 里整段编译掉（基准不掉速）。

**`Clock.Manual.advance` 只在测试 driver / ticker owner 线程上调**：`Manual` 是给"自己驱动"的场景用的
（`tick()` 那条路），谁驱动谁推进；生产里是 `.monotonic`，没人写它。别让一个生产者线程去推时钟 ——
那又是"生产者写、ticker 读"的老问题换了个字段。

## 5. 背压语义（这是运行时的核心承诺）

```
生产者 ──send──▶ 邮箱（有界 N）──recv──▶ worker
   │                  │
   │ 满               │ 空
   ▼                  ▼
error.Full        阻塞等待（recv(0)）或超时（recv(ms)）
（由调用方决定丢弃/合并/退避）
```

四条规则（第 4 条是 §12 池化之后补的，前面的编号没动，因为文里按"§5 第 4 条"引用它）：

1. **队列永不增长**。容量是 comptime 的，`error.Full` 是唯一出口 —— 内存曲线可预测。
2. **丢弃必须可见，而且"丢"的不同原因要有不同的数**。
   - `stats().dropped_full` / `RuntimeStats.messages_dropped`：**生产者**被满邮箱拒收（`error.Full`，
     消息**从未被接受**，调用方当场就知道该退避还是该合流）。
   - `stats().discarded_on_stop` / `RuntimeStats.messages_discarded_on_stop`：消息**已经**被收下
     （`send` 返回过成功），然后**因为 worker 停机而被放弃** —— 剩下的那条队列不会再有人跑。
   - `RuntimeStats.timer_deliveries_dropped`：**定时器已经触发**（`timer_fires` 已经动过），但那条消息投进
     目标邮箱时**被拒** —— `error.Closed`（那个 worker 已经停了）或 `error.Full`（队列还满着）。
     这是第四个原因、第四个数：没有生产者在挨背压、没有消息被"收下又放弃"、定时器也确实跑了。
     `error.Full` 那一半会和 `messages_dropped` 同时涨（就是同一个 `send` 拒的），**正因为这样才需要它**：
     只有这个读数能把"生产者在挨背压"和"一个已经触发的定时器的消息没到"分成两件事。
     投递用的是非阻塞 `send`（不是 `sendBlocking`）：定时器**不允许**把 ticker 顶住，所以这里的答案
     只能是"丢 + 计数"，不能是"等"。
   - 这几种**故意不合并**：合成一个数会把"调用方正在挨背压"和"这个 actor 停机时把队列扔了"读成同一件事，
     而这两种情况该做的处置完全相反（前者退避，后者查停机原因）。合并只省一个字段，代价是读数失去意义。
   定时器命令队列（`timer_command_capacity` = 512）用同一条规则：满了就 `error.Full`，不静默丢；
   定时器那一侧的对应读数是 `timers_discarded`（§3、§8）——它数的是**没触发就释放**，
   `timer_deliveries_dropped` 数的是**触发了但没投到**，两者互补，别互相替代。
3. **消息是值**。`T` 按值拷贝进队列；要传堆对象就传指针并显式约定所有权，别让 `T` 偷偷拥有内存。
4. **"环满"不是背压**。就绪环（§12）里的 token 不是消息，是**一个 worker 的调度权**：丢一条消息是丢工作，
   丢一个 token 是丢 worker —— 邮箱继续收、`send` 继续成功、而它永远不再运行。所以那个环的容量是按
   **声明的池化上界**算出来的（因此 `push` 不可能失败），`SchedulerConfig.max_pooled_workers` 是硬上限
   （第 N+1 个 `.pooled` spawn 在启动期被拒），真失败时 `std.debug.assert` + `ready_push_failures` 计数。
   把它当背压"丢掉就好"是错的。

## 6. 事件分层（L0 / L1 / L2）

| 层 | 载体 | 语义 | 用于 |
|----|------|------|------|
| **L0** | `MpscRing` / `Mailbox` + worker | 有界、零分配、单线程消费 | 行情、订单簿、Tick、房间广播、内部命令 |
| **L1** | `app.eventBus(T)`（现有，不动） | 进程内、类型化、可订阅 | `UserCreated` / `OrderCreated` / 领域事件 |
| **L2** | Kafka / NATS / Outbox | 跨进程、至少一次 | 跨服务、跨机房 |

L0 与 L1 是**两个通道，不是一个**：不要把热路径塞进 L1（它是为可读性与可靠性设计的），
也不要把业务事件塞进 L0（它没有订阅模型、不落盘）。

**"零分配"是可执行断言，不是形容词**：`src/runtime/alloc_contract_test.zig` 用计数分配器把 L0 的生产者
路径（`Handle.send*` / `HotBus.publish` / `Mailbox.send*` / `RingBuffer` / `MpscRing` / `Sequencer.next`
/ `Runtime.scheduleAction` / `requestCancelTimer`）钉死在 **0 次**分配，并对"本来就要分配"的入口写死
**精确次数**（`Handle.after` 每次 1 个 payload、在调用线程上；`Wheel.schedule` 每个定时器 1 个 node）。
将来谁往热路径塞一次 `allocator.dupe(...)`，`zig build test` 就会红，而不是等某次基准跑出漂移。

## 7. 何时不要用运行时

- CRUD、后台管理、普通 API：模块 + service 已经够了，worker 只是多一层。
- 需要"同一份状态被多个线程读"：那是共享内存问题，先考虑冻结快照（`FrozenMap`）或把状态搬进 worker 再问。
- 需要跨进程顺序：用 Kafka/NATS（L2），别自己写 RPC。

## 8. 可观测性

```zig
const s = rt.stats();
// workers / running / messages_sent / messages_received
// messages_dropped / messages_discarded_on_stop
// handler_errors / timer_fires / timers_discarded / timer_deliveries_dropped / timer_lag_max_ms
```

`timer_lag_max_ms` 是"定时器迟到的最大值"：ticker 被饿死、或某个 `post` 太慢时会变大 ——
它比"定时器数量"更能说明运行时是否健康。每个 worker 的明细在 `handle.stats()`。

`timers_discarded` 是**停机时未触发就被释放**的定时器数：既包括还在命令队列里的 arm，也包括已经进了时间轮
的节点（见 §3「停机不丢已 arm 的定时器」）。它和 `messages_dropped` 是同一条原则 —— 承诺过的活儿没发生，
就必须留下一个数字；否则"少了一次投递"只能靠人去猜。

`timer_deliveries_dropped` 是**定时器已经触发、但那条消息没投到目标邮箱**的数 —— 触发路径上的 `send`
返回了 `error.Closed`（那个 worker 已经停了）或 `error.Full`（队列还满着）。它和 `timers_discarded`
数的是互补的两件事（一个"没触发就走"、一个"触发了但没投到"），和 `messages_dropped` **不是**同一个原因：
后者是某个生产者在调用点被拒（它在自己的线程上，当场就能改主意），前者是运行时替一个已经跑完的定时器
丢一条消息（没有调用方在场）。`error.Full` 那一半会让两个数同时涨 —— 就是同一个 `send` 拒的 ——
这正是它存在的理由：告警里"生产者挨背压"和"定时器的消息没到"要能分开。`after()` 的文档说投递失败
"只打一行 debug 日志"，那是**不够的**（debug 日志在生产里默认关着），现在它有上面的读数 + 那行日志：
日志给"哪个 worker"，读数给"多少次"。

它按**运行时累加**（像 `timers_discarded`、`messages_discarded_on_stop`），不是把活着的 worker 加起来：
`error.Closed` 的那一半写的时刻，那个 worker 已经停了 —— 求和写法会在能读到它之前归零。

`messages_discarded_on_stop` 是**同一原则在消息侧的另一半**，但**不是** `messages_dropped` 的别名
（§5 第 2 条）：`messages_dropped` 是生产者被满邮箱拒收，这条是**收下了又因 worker 停机被放弃**。
只有两处会产生它，两处都实测过：

* **dedicated 的监督停机**：`spawnActor` 一旦判停，`handle` 循环直接 `break` —— 在停机中的 actor
  不该继续干活，但邮箱里剩下的那批**会**被记进 `WorkerStats.discarded_on_stop`（§12.10 有那张实测表）；
* **池先停、worker 手上还有消息**：`.pooled` 在 `Runtime.shutdown` 里先停池（§12.6），
  `join()` 那一步遇到"池已停 + 邮箱非空"就放过 —— 于是收尾时（**全部 join 之后、destroy 之前**）
  把还压在邮箱里的条数记下来。放在这里而不是 `join()` 里，是因为这一句才是
  "没有线程、也没有池能再跑它们"成立的地方（`join()` 可以被早调，那时池还活着）。

计数只取**增量**（`Handle.countAbandoned` 记着上次报到哪一条），所以这件事**重复执行不会重复报**：
收尾那一趟对每个 worker 都跑，dedicated 在循环出口已经报过的那 6 条不会变成 12。它顺带兜住
`close()` 与 `send` 的竞态窗口（生产者刚读到 `closed == false`、停机就发生，消息落进了一个没人再取的邮箱）——
这种消息在循环出口那次读不到，收尾那次读到了。

它按**运行时累加**（像 `timers_discarded`），而不是像 `messages_dropped` 那样把还活着的 worker 加起来：
`shutdown` 是"join 完就 destroy"的同一趟，被放弃的消息**正是**伴随着销毁发生的 —— 求和写法会在
能读到它之前就归零。`RuntimeStats.messages_discarded_on_stop` 因此在 `shutdown()` 之后**仍然可读**
（进程退出前的最后一次抓取、或崩溃前打的一行日志，拿到的不是 0）。每个 worker 的明细在
`handle.stats().discarded_on_stop`，只在那个 worker 还活着时可读。

**接进 `/metrics`**：`RuntimeStats` 有现成的桥，起服务时接一次即可，抓取时采样（无后台线程）：

```zig
var bridge = try zigmodu.Runtime.MetricsBridge(PrometheusMetrics).init(&rt, metrics);
metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge);
```

它注册 17 条 `zigmodu_runtime_*` 指标（`workers` / `running` / `messages_sent` /
`messages_received` / **`messages_dropped`** / **`messages_discarded_on_stop`** / `handler_errors` /
`timer_fires` / **`timers_discarded`** / **`timer_deliveries_dropped`** / **`timer_lag_ms`**，
加上池化执行（§12）的 6 条：
`pool_declared` / `pool_threads` / `pool_ready_len` / `pool_claimed` / `pool_dispatches` /
`pool_ready_push_failures`）。名字里没有 `_total` 后缀是刻意的：这些是**抓取时采样**的快照，
所以走 gauge 而不是 counter（`PrometheusMetrics.Counter` 没有 `set`）。

`messages_dropped` 与 `messages_discarded_on_stop` 是**两条曲线，不是一个**：前者随生产者压力动，
后者只在停机时跳一次。告警要分开写 —— "背压"和"actor 停机扔了队列"是两种事故。

`timer_deliveries_dropped` 是**第三条**，`timer_fires` 的配对读数：`timer_fires` 涨而
`messages_received` 不涨时，缺的那部分就在这条里（还有一个出口是 §3 的停机释放，走
`timers_discarded`；两个出口加起来才等于"承诺过的定时器活儿"的总额）。它的典型形状是**停机窗口**：
worker 先停（邮箱关闭）、定时器随后到点，于是它跳一次 —— 而 `messages_dropped` 不动，因为没有任何
生产者在挨背压。持续增长则是另一回事：目标邮箱长期满着，定时器在往一个跟不上的 worker 上投活儿。

**池的 6 条读什么**（§12.10 那句"`zmodu_runtime_*` 里没有池的指标"已经作废）：

| 指标 | 含义 | 怎么读 |
|------|------|--------|
| `pool_declared` | 声明的 `max_pooled_workers`（上界，不是 worker 数） | `0` = 这个 runtime 没有池（环/线程都不存在） |
| `pool_threads` | 池线程数（Phase 1 只有 0 或 1） | `pool_claimed` 的天花板；Phase 2 起变多 |
| `pool_ready_len` | 就绪环里现有 token 数 = 排队等池线程的 worker 数 | 每个 worker 至多一个 token（D4），所以它 ≤ `pool_declared` |
| `pool_claimed` | **此刻**正被池线程执行的 worker 数 | 池化后 `running` 不再回答"有多少活儿在跑"，这条回答 |
| `pool_dispatches` | 池线程跑过的批次总数 | **有 `.pooled` spawn 却是 0 = 那些 worker 从没到过池线程** |
| `pool_ready_push_failures` | 被环拒收的 token 数 | **必须恒为 0**。见 §5 第 4 条：这不是背压，是调度器失联 |

没有池的 runtime 这 6 条**报 0 而不是缺行**：`pool_declared=0` 本身就是"这里没人声明过池"的答案，
仪表盘不必为它写特例。

**为什么必须有这一步**：`messages_dropped` 与 `timer_lag_ms` 只在这里出现 —— 邮箱打满、定时器被饿死
在 HTTP 侧**完全看不见**，只看请求直方图会得出"一切正常"的结论。池化之后同理：`pool_claimed` /
`pool_ready_len` / `pool_ready_push_failures` 在 `RuntimeStats` 里根本不存在（那是**进程内**读数，
由 `rt.poolStats()` 给），HTTP 侧更是完全无感。

`MetricsBridge` 对 `MetricsT` 是鸭子类型（只要求 `createGauge` + `Gauge.set`），所以 runtime 层
不依赖 observability 层。`bridge` 的生命周期要覆盖进程（别放在会返回的栈帧里）。

**静态的那一半**：上面这些数字都是**运行中**进程的属性，静态 CLI 读不到（也不该假装读到）。
项目**声明了什么**接线 —— worker 类型与邮箱容量、`Mailbox`/`HotBus` 等原语、定时器调用点、
recorder/trace 引用、时钟选择 —— 可以用 `zmodu runtime [dir]` 盘出来（只读源码，每条带
`file:line`；没用 runtime 的项目也退 0）。两者互补：一个答"接线长什么样"，一个答"跑起来怎么样"。
见 [`ZMODU_CLI_INTEGRATION.md`](ZMODU_CLI_INTEGRATION.md) 的 `zmodu runtime` 一节。

### 8.1 Worker trace context —— 消息可归属到发起它的那次请求

`messages_dropped` 告诉你"丢了多少"，说不清"**谁的**被丢了"。`sendTraced` 补上这一半：一条消息可以
带上它来源的 trace id，worker 处理它时能看见，于是 worker 的日志/错误能归到发起请求的那条链上。

```zig
// 生产侧（HTTP handler、别的 worker、任何线程）—— trace 是 16 字节值类型
try worker.sendTraced(.{ .user_id = id }, trace);            // 不阻塞，满则 error.Full
try worker.sendBlockingTraced(msg, trace, 500);              // 等 500ms 腾出槽位

// worker 侧
pub fn handle(self: *Self, msg: Msg, ctx: anytype) anyerror!void {
    if (ctx.traceId()) |t| std.log.info("processing user {d} trace={x:016}{x:016}", .{ msg.user_id, t.high, t.low });
    ...
}
```

契约（`src/runtime/runtime.zig` 的测试逐条钉住）：

- **每条消息**，不是每个 worker：trace 跟着邮箱槽位走（信封化），两个生产者并发 `sendTraced` 互不覆盖。
  这也是它**零分配**的原因 —— 16 字节值类型，热路径上一个字段的拷贝。
- 普通 `send` / `sendBlocking` 投递的消息 `ctx.traceId()` 为 `null`；`init` / `run` 阶段也是 `null`
  （那时没有"正在处理的消息"可言）。
- `Handle.after(delay, msg)` 在 **handler 内**（也就是 worker 自己的线程上）调用时，会把**当前这条消息**的
  trace 一并投给定时器投递的消息 —— "延迟处理"仍然属于发起它的那次请求。在别的线程上调 `after` 则投递
  无 trace 的消息（那里没有正在处理的请求，硬编一个反而是假的）。
- `Handle.after` **不在调用线程上碰时间轮**：它只取 id、算 `deadline`、推一条命令（见 §3「`after` 到底做了什么」）。
  所以"任何线程都能安全地 arm 定时器"是结构性的，而不是靠一把锁兜住。
- **错误日志带 `trace=`**：`handler error` 与 `stopped by supervisor` 两行都会带上出错那条消息的 trace id
  （`[runtime] OrderBook trace=<hex> handler error (2 in window): Boom`），可直接 grep 回请求。
- `Handle.send` / `sendBlocking` 签名没变，`HotBus` / `Mailbox` / `Runtime.spawn` 的契约也没变；
  trace 是增量的，老代码一行不用改。

**和 HTTP `ctx.traceId()` 接上**：HTTP 侧是字符串（`"{x:016}-{x:016}"`，见 `http.Tracing`），runtime 侧是
16 字节值 —— 边界上转一次即可：

```zig
// 路由 handler 里：把 HTTP trace 交给 worker
const http_trace = ctx.traceId() orelse "";
try worker.sendTraced(cmd, traceFromHeader(http_trace));

/// `x-trace-id`（两段 16 进制，或上游任意字符串）→ runtime 的 `TraceId`。
fn traceFromHeader(id: []const u8) zigmodu.runtime.TraceId {
    var parts = std.mem.splitScalar(u8, id, '-');
    const high = std.fmt.parseInt(u64, parts.next() orelse "", 16) catch return zigmodu.runtime.TraceId.generate();
    const low = std.fmt.parseInt(u64, parts.next() orelse "", 16) catch 0;
    return .{ .high = high, .low = low };
}
```

解析失败（上游给的是非 16 进制串）就退回 `TraceId.generate()`：**宁可换一个新 id，也不要让 worker 的日志
挂上一条张冠李戴的 trace**。OTLP 侧同理 —— span 上的 `trace_id` 就是同一种 `TraceId`（`docs/OBSERVABILITY.md`）。

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
| **v0.28.0** | EventRecorder v1：`Recorder(E, C)` + `HotBus.attachRecorder`（运行时投递流录制、按 seq 重放并驱动 `Clock.Manual`） | ✅ 本文档 §11.6（落盘、多事件类型、`Handle.send`/定时器投递不在 v1） |
| **v0.28.0** | 定时器时间轮改为 **ticker-owned**：`Runtime` 命令队列（`arm`/`cancel` 同一条 FIFO）+ 生产者侧 id/deadline；`cancelTimer` 拆成 `requestCancelTimer`（请求）/ `cancelTimerSync`（要结果） | ✅ 本文档 §3/§4（**Breaking**：旧的 `cancelTimer(id) bool` 已删 —— 第 2 节第 10 条那条分层契约的先例） |
| **v0.28.0** | `shutdown()` 释放**已进轮**的待触发 payload（`Wheel.drainAll`，在 owner 线程上 drain）+ `RuntimeStats.timers_discarded` / `zigmodu_runtime_timers_discarded` | ✅ 本文档 §3/§4/§8（**非 Breaking**：补上 ticker-owned 那批的"未附带"项） |
| **v0.28.0** | `shutdown()` 顺序改为**先停 ticker 再拆 worker**（关掉 "ticker 向已 destroy 的 handle 投递" 的 use-after-free 窗口）+ `onTimerFire` 在 `alive = false` 时只 drop 不 post | ✅ 本文档 §3（**非 Breaking**：签名不变，只多一次 `alive` 读） |
| **未发版** | WorkerPool **Phase 1**：`spawn(..., .{ .mode = .pooled })` + `queued`/`claimed` 两位 + 就绪环 + **一条**池线程（`src/runtime/scheduler.zig`）；池在 `Runtime.initWithOptions` / `builder.withMaxPooledWorkers` 声明的上界内 | ✅ 本文档 §12.10（**Breaking：否** —— 第三参同时接受 `256` 与 `.{ .capacity = 256, .mode = .pooled }`；`run` 型 worker 用 `.pooled` 是编译期报错，见 `scripts/check-pool-guard.sh`） |
| **未发版** | 池的**可观测性与示例**：6 条 `zigmodu_runtime_pool_*`（§8）+ `examples/runtime-workers` 的 audit 环真的以 `.pooled` 跑（`[pool] dispatched>0` 才算过）+ `zmodu runtime` 报池声明 | ✅ 本文档 §12.10 末节（**Breaking：否**；顺带修掉 `Application.Config.max_pooled_workers` 没被 `Application.init` 拷贝的接线缺口） |
| **未发版** | **监督停机丢弃可见**：`WorkerStats.discarded_on_stop` / `RuntimeStats.messages_discarded_on_stop` + 第 16 条 gauge `zigmodu_runtime_messages_discarded_on_stop` —— dedicated 的 `break` 与"池先停、邮箱非空"两档都计数 | ✅ 本文档 §5 第 2 条 / §8 / §12.10（**Breaking：否**；`RuntimeStats` 只加字段，停机行为一字未改） |
| 1.0 | API 收敛、命名统一、deprecated 清理 | 计划 |

## 10. 最小示例

见 `examples/runtime-workers/`：一条"行情源 → 订单簿 worker → 风控 worker → 快照定时器"的流水线，
既演示 worker/邮箱/定时器，也演示背压（`error.Full` 时的合并策略）与优雅停机。

## 11. EventRecorder —— 设计草案（v1 已实现：见 §11.6）

> 状态：**本节是决策记录（设计草案），别再当成"未实现"读**。落地形状、与草案的差异、
> 以及明确未做的边界见 **§11.6**；代码在 `src/runtime/recorder.zig`。
> 这一节存在的理由是先把契约定下来 —— 录什么、按什么顺序、存哪里、怎么和 `Clock.manual` 对齐。
> 四问答错任何一个，写出来的东西要么不可重放，要么在热路径上不可接受。

### 11.1 先说已经有什么（别重造）

| 已有 | 是什么 | 为什么不能直接当 EventRecorder |
|------|--------|------------------------------|
| `core/EventStore.zig`（`append` / `readStream` / `replay` / `getVersion`）+ `SnapshotStore` + `EventReplay.replayFromSnapshot` | **领域事件溯源**：按 `stream_id` 记业务事件、版本、快照，可持久 | 它记的是**应用主动 append 的领域事件**，不是运行时的投递流；流/版本/快照那套机制也不适合 1M/s 的 tick |
| `core/eventbus/WAL.zig`（`WALConfig` / `SyncMode{fsync,segment_sync,none}` / 64MB 分段 / `append`·`readFrom`·`markCommitted`·`cleanup`） | 通用 WAL，**尚未接进 runtime** | 可以做落地层，但 `append` 会分配并返回 `!u64`，不能直接放热路径 |
| `examples/alpha-engine`（`market/service.zig` 的 `Replay(BookInbox)` + drain marker） | **重放驱动跑通了**：非 worker 的驱动线程按确定序列喂邮箱 | 它读的是内嵌序列，不是录下来的运行流 |
| `SagaOrchestrator.resumeInstance` / `restoreFromWal` | 记录 + 崩溃续跑在 **Saga 这一层**已成立 | 只覆盖 saga 步骤，不是通用投递流 |
| `runtime.Sequencer` / `runtime.Clock`（`.monotonic` / `.manual`） | 全局序号 + 可注入时间 | 正是本设计要复用的两块地基 |

**所以缺的不是"记录事件"或"重放"本身，而是**：把运行时**实际投递了什么、按什么顺序、在哪个运行时时刻**录成一份可重放的日志。

### 11.2 缺口的确切形状

`HotBus` 是**有意有损**的 —— `publish` 逐个 sink 调 `deliver`，返回 false（满/关闭）就计一次
`dropped` 然后**继续**，事件不保留（`hot_bus.zig:118`）。因此：

- 从 `HotBus` **读不回**一次运行；
- `Handle.send` 的直达投递、`after` 的定时器投递、以及 `MpscRing` 的跨生产者顺序，`HotBus` 都不覆盖。

而 `HotBus` 一旦 `freeze()` 订阅者表就固定，所以"记录"必须在 freeze 前接上。

### 11.3 四个契约问题

**Q1 在哪里取？**

| 取点 | 拿到什么 | 代价 |
|------|---------|------|
| `HotBus.publish` 挂一个 sink | 只有 L0 扇出的那一份 | ❌ **不能选**：sink 是竞争者，`max_subscribers` 是 comptime，满时 `deliver` 返回 false → **记录会被丢掉**。而"丢过的记录"比没有记录更危险：你会以为重放是完整的 |
| `Handle.send` / `sendBlocking` / `sendTraced` + 定时器投递 | **实际进邮箱的每一条**，含直达发送与 `after` | 热路径：每条 send 多一次判断，必须零分配 |
| `Runtime` 内部、扇出之前 | 同上，且能同时看见 bus 与直达两条来路 | 改动落在 `Runtime`，比改 `Handle` 集中 |

→ 倾向**第三个**，退一步是第二个。

**Q2 顺序怎么定义？** 运行时**没有全局顺序**（每邮箱 FIFO；`MpscRing` 明确不保证跨生产者顺序）。
所以顺序必须被**定义**：在取点用 `Sequencer.next()` 打一个单调序号，**日志的顺序就是重放的顺序**。
诚实边界：这是取点处的**某一个**合法交错，不等于某次运行被观察到的那个交错 ——
重放是确定性的，但不是"时间倒流"。

**Q3 时间。** 每条记录带 `Clock.nowMs()`；重放用 `Clock.manual` 按这些时刻推进，于是定时器按相对次序触发、不 sleep。
**限制**：这只对**读注入 `Clock` 的代码**成立。runtime 内部全部走 `Clock`，但应用代码若直接调
`core/Time.zig` 就读到了真实时间 —— 那条路径不参与重放，必须在文档里写明。

**Q4 存哪里？** 三档：

1. **v1：内存有界环**（复用 `RingBuffer`/`MpscRing`）。**溢出是错误而不是静默丢弃** ——
   与 `HotBus` 相反，这是刻意的：记录器丢一条，重放就不再是那次运行。
2. 落盘：接 `core/eventbus/WAL.zig`（分段 + `SyncMode`），后台线程刷。
3. **不**用 `EventStore`：它的流/版本/快照是给领域事件用的，套在 tick 上属于误用。

### 11.4 v1 建议范围

```
src/runtime/Recorder.zig          // 新文件，opt-in
  Runtime.enableRecording(cfg)    // 开着才有开销；关着只是一次 ?*Recorder 判断
  Recorder.record(...)            // 取点调用：零分配，写预分配环
  Recorder.replay(runtime, clk)   // 按 seq 重放，驱动 Clock.manual
```

复用：`Sequencer`（顺序）、`Clock`（时间）、`RingBuffer`（存储）、`WAL`（可选落地）。

**明确不做**（否则它会长成一个平行框架）：

- 不做领域事件溯源 —— 那是 `EventStore` 的活；
- 不做 `HotBus` 的订阅者 —— 见 Q1，会丢；
- 不承诺"进程级完全确定性"：`spawn`/`init` 的副作用、网络、墙钟、以及**丢弃模式**都不重放。
  丢不丢是时序的函数；重放的是"投递成功的那部分"。

### 11.5 待定（定完再动手）

1. **取点选哪个**（`Runtime` 内部 / `Handle`）—— 决定改动面，以及能否覆盖定时器投递。
2. **v1 要不要落盘**：只做内存环（小，够测试与短事故窗口）还是同时接 WAL。
3. **记录粒度**：存 `(seq, clock_ms, target, kind, len)` + 载荷字节，还是只存载荷哈希
   （省内存，但重放时得重建载荷 —— 对一个"重放"特性来说通常是错的选择）。

### 11.6 v1 已实现（`src/runtime/recorder.zig`）

上面的草案保持原样（它是决策记录）；这里是实际落地的形状，以及和草案的差异。

```zig
const runtime = @import("zigmodu").runtime;

var rec = runtime.Recorder(Trade, 4096).init(clock); // clock 与 Runtime.init 用同一个
try bus.attachRecorder(&rec);                        // 必须在 bus.freeze() 之前
bus.freeze();
// …运行…
if (rec.hasOverflowed()) { /* 这份日志不完整：丢掉，别重放 */ }
try bus.publish(trade);                              // 记录点：扇出之前

var manual = runtime.Clock.Manual{ .now_ms = 0 };
rec.replay(&manual, &harness, Harness.sink);         // 按 seq 推进 clock，不 sleep
```

**取点（对 §11.3 Q1 的更正）**：草案写"倾向 `Runtime` 内部、扇出之前"，但 `Handle.send`
**直接写邮箱、不经过 `Runtime`**，所以 `Runtime` 里没有那个取点。真正的位置是
**`HotBus.publish` 的 sink 循环之前**（`hot_bus.zig` 的 `publish`）：它正是"扇出"本身，
在它之前记录既不占订阅者槽位（`max_subscribers` 是 comptime），也不会走 `dropped` 分支
（`publish` 里 `deliver` 返回 false 的那一支）—— 那正是 §11 要避免的"丢记录"。代价很小：
没 attach recorder 的 bus，`publish` 只多一次 `?*anyopaque` 空判断，行为逐位不变（有测试守着）。

**溢出怎么处理**（§11.3 Q4 第 1 档）：`Recorder.record` 满环返回 `error.Full`，
**绝不覆盖、绝不静默丢弃**；`entries()` 因此永远是 `seq` 升序的一段完整前缀。
`HotBus.publish` 拿到拒绝后做两件可见的事：

1. `stats().record_dropped += 1`（`Stats` 新增字段）；
2. `publish` 返回 `false` —— 签名仍是 `Error!bool`（examples 在用，不动），但"日志已经不完整"
   不应该读成成功。`Recorder.hasOverflowed()` 此后恒为真。
   无 recorder 时 `publish` 的返回值与改动前一致。

**存储与顺序**：`Sequencer` 给出的序号**就是槽位下标**（0,1,2,…），一次 `fetchAdd` 同时拿到
顺序与空间 —— 多生产者不会撞车（有 4×500 条的并发测试）。槽位有 per-slot `ready` 标志，
`published` 是"已完整写入的前缀长度"，因此跨线程读 `entries()` 不需要锁、也不需要等待
（领先的生产者写自己的槽位就返回，由滞后的那条来延伸前缀）。没有 `RingBuffer` 的绕圈覆盖：
一次溢出之后就不再接受，语义上就是"有界追加日志"。

**与草案的其它差异**

| 草案 | 落地 | 为什么 |
|------|------|--------|
| `src/runtime/Recorder.zig`（大写文件名） | `src/runtime/recorder.zig` | 与目录内其它文件（`hot_bus.zig`/`timer_wheel.zig`…）一致 |
| `Runtime.enableRecording(cfg)` | `HotBus.attachRecorder(rec)` | 取点落在 bus 上，`Runtime` 手上没有那个取点；opt-in 更局部 |
| 三档存储中的第 2 档（WAL 落地） | **未做** | v1 只要内存环：够测试与短事故窗口，落盘留给后续 |
| `replay(runtime, clk)` | `replay(&Clock.Manual, ctx, sink)` | 重放不需要 `Runtime`；驱动 `Clock.Manual` + 一个 sink，测试与事故复现都不必起线程 |
| `(seq, clock_ms, target, kind, len)` + 载荷字节 | `Entry{ seq, clock_ms, event }` | v1 只录单一事件类型 `E`（值拷贝，零分配），`target/kind` 属于多流记录，不在范围内 |

**明确未做（同 §11.4，这里写死边界）**

- **单一事件类型 `E`**：`Recorder(E, capacity)` 只录一种 `E`。同步录多个 worker 的**异构**
  消息不在 v1 —— `Handle.send` 直达投递、`after` 定时器投递、`MpscRing` 的跨生产者交错
  都不覆盖。v1 录的是 `HotBus` 的**发布流**。
- 不做领域事件溯源（那是 `core/EventStore.zig`：按 `stream_id` + 版本 + 快照、可持久，
  是"业务决定了什么"；`Recorder` 是"运行时投递了什么"，内存、有界、opt-in 的调试工具）。
- 不承诺进程级完全确定性：`spawn`/`init` 副作用、网络、墙钟、以及丢弃模式都不重放。
- 只有**读注入 `Clock`** 的代码参与重放；直接调 `core/Time.zig` 的路径读到真实时间。

## 12. WorkerPool / Scheduler —— Phase 1 已落地（一条池线程）

> 状态：**Phase 1 已落地**（`src/runtime/scheduler.zig`，`spawn(..., .{ .mode = .pooled })`）。
> 12.1–12.9 是设计原文，原样保留作为决策记录；**12.10 记落地结果** —— 实际做到哪、没做哪，
> 以及实测后对 D4/D5 的两处收紧（老写法会丢 worker，不是丢消息）。
> **多池线程、drain 批量调优、公平性加权、affinity 仍未做**（也正是 12.7 明确不做的那些）。

### 12.1 问题：一 worker = 一线程

`spawn` 现在是 `allocator.create(Handle)` + `std.Thread.spawn(workerMain(W, capacity), handle)`
（`runtime.zig`）。所以：

```
100 个 symbol → 100 个 orderbook worker → 100 个 OS 线程
```

线程不是免费的：每个约 8MB 栈的虚拟地址空间、调度器里的实体、上下文切换成本。**"worker 数"
一旦从"模块数"变成"数据维数"，这个模型就到顶了。** 量化、游戏房间、WebSocket 连接、
IoT 设备、AI 会话都是这种形态。

但**不能简单换成 ThreadPool**：`state: W` 现在住在 `*Handle` 里、由它自己的线程独占；
随便丢给任意池线程执行，`handle` 里的裸字段访问立刻变成数据竞争（这正是 §1 那条
"一个线程拥有的状态"要挡的东西）。

### 12.2 两种执行模式，而不是替换

```
Runtime
 ├── Dedicated   Worker → 自己的 OS 线程        （现状，默认，低延迟链用它）
 └── Scheduled   Worker → 池线程执行 + 就绪队列   （新增，长尾用它）
```

`spawn` 保持现状语义（= Dedicated），新增 `spawnPooled`（或 `spawn(..., .mode = .pooled)`，
API 形状见 §12.8）。**默认不变**，所以既有应用零影响。

### 12.3 必须守住的不变量

池化**不能**松掉任何一条，否则这个改动就白做：

1. **状态独占**：任一时刻只有一个线程在执行某个 worker 的 `handle`/状态。**从"按线程身份独占"
   变成"按排他声明独占"**（见 §12.4 的 `claimed`）——这是本设计的核心，也是唯一一处
   需要重新论证的语义。
2. **每 worker FIFO**：同一 worker 的消息顺序不变（`Mailbox` 不变，仍是有界的）。
3. **池线程绝不阻塞**：调度线程上跑的代码不允许 `recv(0)` 阻塞、不允许 sleep、不允许等锁。
4. **热路径零分配**：就绪队列是定容 `MpscRing`；派发与认领零分配。由 §13 那份分配契约守。
5. **Wheel 仍是 ticker-only**：§4 的 owner 契约不受影响；定时器投递照旧走 `handle.send`。

### 12.4 机制

```
发消息方                     调度线程（N 条）
  send(msg)                    loop:
    ├─ mailbox.send(msg)          ├─ ready.pop()  → handle
    └─ ready.push(handle)          ├─ claimed.testAndSet(handle) → 抢不到就跳过
        （同一 worker 只推一次）     ├─ drain 该 mailbox（tryRecv，一轮若干条）
                                    │    └─ W.handle(state, msg, ctx)
                                    └─ 清 claimed；mailbox 还非空就再 push
```

三点关键：

- **就绪信号从"有没有线程停在 `recv`"改成"`ready` 环里有没有它"**。这是 `Mailbox` 的语义
  分叉点：Dedicated 模式下 `send` 靠条件变量唤醒自己那个线程；Scheduled 模式下 `send`
  只负责把 handle 推上 ready 环。**`Handle.send*` 的签名与背压语义（满 = `error.Full`）不变。**
- **`claimed` 是排他声明**（`std.atomic.Value(bool)`）：保证同一 worker 不会被两条池线程
  同时执行。它替代了"只有我的线程能碰我"，是 §12.3 第 1 条的落地形式。
- **一轮 drain 多条**（而不是一条一派发）是为了摊掉 ready 环的往返；具体批量是待调参数（§12.8）。

### 12.5 边界：有的 worker **不能**池化

这是本设计最需要写清的一条，否则会有隐蔽的错用：

| worker 形态 | 能否池化 | 原因 |
|---|---|---|
| `pub const Message` + `handle`（消息驱动） | ✅ | 循环是运行时的，改为"被派发时 drain 一轮"即可 |
| `run(self, ctx)`（自带循环） | ❌ **只能 Dedicated** | 它自己 `while (!ctx.stopped())` 占着线程；池化等于让一条池线程被它独占，池就废了 |

所以池化不是"给所有 worker 换个执行器"，而是**先声明哪些 worker 是消息驱动的**。
`spawnPooled` 对 `run` 型 worker **应当编译期报错**（`@compileError`），而不是运行期悄悄退化成独占。

**延迟代价要如实说**：Dedicated 是"发送方直接写进对方邮箱、对方线程立刻醒"；Scheduled 多一跳
（发送方 → ready 环 → 调度线程 → `handle`）。对 `行情 → 订单簿 → 风控 → 执行` 这种链，
**每一跳都会进关键路径**，所以那条链该继续用 Dedicated；池化是给长尾（metrics / audit /
通知 / AI 会话）省线程。这也是 §12.2 保留两种模式、而不是只留池化的原因。

### 12.6 与现有件的关系

- **`Mailbox` 不改语义**（仍是有界、`error.Full`、`sendBlocking`），只多一个"被谁唤醒"的分叉。
- **`Wheel` 不变**：`after` 的投递末端是 `handle.send`，它照 §12.4 决定推不推 ready。
- **`Recorder`**：`Record` 覆盖的是 `HotBus.publish`，与池化正交；若将来扩到 `send`，
  记录点仍在 `Handle.send*`，不受调度模式影响。
- **`RuntimeStats`**：`workers` / `running` 语义不变（"已 spawn" 与 "正在执行"），
  池化后 `running` 的上界从"worker 数"变成"池线程数"——这本身是个有用的观测信号。
- **`shutdown()`**：§3 的顺序（先停 ticker → 停 worker → join → destroy → drain）要扩展一步：
  先停调度线程（它们可能正握着某个 worker 的 `claimed`），确认所有权都归还后再 destroy。

### 12.7 明确不做（本设计范围内）

- **不做 MPMC / 新的队列原语** —— `MpscRing` 够用（多生产者推 ready、多调度线程消费）。
- **不做 CPU affinity / NUMA / 优先级**（评估 §14 也建议往后放）：它们属于**执行策略层**，
  应在 Dedicated/Pooled 稳定之后再谈，否则会同时改两个变量。
- **不做 μs 级 timer**：那是独立的 `LowLatencyClock/Timer`（评估 §7 的建议），与调度器正交。
- **不做 remote worker**（评估 §15）：本地 Runtime 稳定之前不谈。

### 12.8 已定的四个决策

**D1 API 形状**：`spawn(..., .{ .mode = .pooled })`，**不**另开 `spawnPooled`。
一处入口、模式是显式声明，读者不用在两套命名间对齐语义。代价是 `spawn` 的第三参从
"comptime 容量"变成配置结构（容量也进这个结构），迁移面见 §12.9。

**D2 池的归属与默认**：`Runtime` 持有池；池线程数在 `Runtime.init` 时声明，
**默认不创建任何池线程** —— 不碰 `runtime` 的应用仍然是零线程，与 §2 的 opt-in 契约一致。
未显式配池却调用 `.mode = .pooled` 是**配置错误**（启动时报错），不是"顺手给你起一条"。

**D3 一轮 drain 有界小批，默认 16，且 per-worker 可配。**
理由是把两个极端都排除掉：
- **1 条**：每条消息都要付一次"ready 环 pop + `claimed` CAS + 视情况再 push"。池化的目标场景
  恰恰是突发型投递（metrics / audit / 日志扇入），这笔派发成本会被乘上消息数。
- **整箱**（邮箱上界 256）：`claimed` 被长时间持有，其他 ready worker 被饿死；而且一次持有的
  时长由**最慢的 handler** 决定，不是一个可控的量。
- **有界小批**两头都占：派发成本被摊掉，持有时间有上界。默认 **16** 是先验起点，不是定论 ——
  必须用 runtime benchmark 复核（见 D5 的落地要求）。延迟敏感的池化 worker 可以设 1，
  吞吐型的设 64。

**D4 公平性靠不变量，不加计数器。**
不变量：**每个 worker 在 ready 环上最多存在一项**（一个 `queued` 位，**与 `claimed` 分开** ——
前者是"在环里等着"，后者是"正在被跑"，两者可以同时为真，语义不同）。
因为环是 FIFO 且每个 worker 最多一项，pop 出来天然就是轮转；**公平性是这条不变量的推论，
不是额外机制**。加 per-worker 计数或加权只会多一套需要和 `queued`/`claimed` 保持一致的簿记。
顺带：这条不变量也是防"同一 worker 被重复派发"的第一道闸，`claimed` 是第二道。

**D5 `claimed` 在批量结束时归还，但归还前必须重查邮箱。**
与 D3 配套：按消息归还等于把 D3 摊掉的派发成本又加回来。但**归还前不重查邮箱 = 丢唤醒**
（lost wakeup）——handler 执行期间到达的消息，若此时既不在环里也不会被重推，就永远不会被处理。
所以落地时必须写成显式不变量并配测试：

```
（仍持 claimed）drain ≤ batch 条
    ├─ 邮箱仍非空 → 保持 claimed 并（若 !queued）重新入环
    └─ 邮箱已空   → 清 queued、再清 claimed，最后 **重查一次邮箱**
                     └─ 若在清 claimed 之后才到 → 生产者看到 !queued 会自己入环
```

**这一段是本设计最容易写错的地方**，测试要专门覆盖"handler 执行期间到达的消息不被丢"。

### 12.9 落地时仍需实测/处理的

1. **drain 批量 16 是起点，不是结论**：用 runtime benchmark 复核（突发型 vs 延迟型各一组），
   并把结论写回本节。测之前不要把它当性能承诺。
2. **`spawn` 第三参的形状变化**：容量与 `mode` 合进配置结构后，既有 `rt.spawn(W, .{}, 256)`
   的调用点需要迁移（全仓调用点数量在落地时清点）。这是本设计唯一预期的**源码级** Breaking。
3. **`shutdown()` 多一步**：先停调度线程（它们可能正握着 `claimed`），确认所有权归还后再 destroy
   worker —— §12.6 已记，落地时要和 §3 的既有顺序合并成一条。
4. **`RuntimeStats.running` 的上界变化**：池化后从"worker 数"变成"池线程数"。这本身是有用的观测
   信号，但别让它被误读成"worker 变少了"。

### 12.10 Phase 1 落地记要（做到哪，没做哪）

**落地范围**：`queued` / `claimed` 两个位 + ready 环 + **一条**池线程 + `spawn` 的 `mode`
（`.dedicated` 默认 / `.pooled`）。既有调用点一行未改：`spawn` 的第三参**同时**接受位置容量与配置结构。

```zig
var rt = try Runtime.initWithOptions(allocator, io, .{      // 池在构造时声明（D2）
    .scheduler = .{ .max_pooled_workers = 64 },             // 不写 = 没有池，零线程
});
const audit = try rt.spawn(AuditWorker, .{}, .{ .capacity = 64, .mode = .pooled });
```

应用里走 builder 的同一条声明（`app.runtime()` / `ctx.runtime()` 创建的就是它）：

```zig
var b = zmodu.builder(allocator, io);
defer b.deinit();
var app = try b.withName("app").withMaxPooledWorkers(64).build(.{MyModule});
```

**那条派生不变量的落地形式**（安全支点，见本文件 §5 第 4 条）：

* 环容量 = `ceilPowerOfTwo(max_pooled_workers)`（最小 2），在 `Scheduler.init` 里**按声明的上界**算，
  不是常数 —— 它必须 ≥ 池化 worker 数，否则"环满丢 token"会等于**永久停掉一个 worker**；
* 上界也是硬上限：第 `max+1` 个 `.pooled` spawn 被 `error.PoolCapacityExceeded` 拒（启动期），
  而不是先收下再让某个 token 无处可放；
* `push` 失败 = 不变量被破坏：Debug/ReleaseSafe 断言 + `ready_push_failures` 计数，
  **绝不当背压丢**。`Runtime.poolStats()` 读得到。

**实测后收紧的两处（不改就会丢 worker）**：

1. **认领失败要重推 token，不能丢**（§12.4 写的是"抢不到就跳过"）。丢掉的 token 不会自己回来，
   而 `queued` 还是 true —— 生产者再也不会为它推第二个 token。重推把它变成"稍后重试"。
2. **批量结束只有一条回执出口，顺序固定**：清 `queued` → 清 `claimed` → 重查邮箱 → **赢了 `queued` 位才 push**。
   §12.4/D5 的"保持 claimed 并重新入环"分支有一个"token 在环里、claim 还握着"的窗口：
   那个 token 被别的池线程 pop 到只会被跳过，而持有者又已交还 —— worker 从此不再被调度。
   单出口版本同时把 D3 的公平性（每批之后重新排队，排在别人后面）白拿到手。
   重查之后**赢位才 push** 也很关键：无条件 push 会在"生产者刚赢得位并推了 token"时留下两个 token，
   而环的容量正是按"每 worker 一个"算的（这条是被并发压力测试抓出来的）。

**`.pooled` 的生命周期与状态语义**（与 `.dedicated` 有意不同，写清以免误读）：

| 事项 | `.dedicated` | `.pooled` |
|------|--------------|-----------|
| 谁跑 `handle` | 自己的线程 | 池线程（一条，Phase 1） |
| `init` 钩子 | `spawn` 后立刻，在 worker 线程上 | **第一条消息的批次里**（池线程、claim 内）；从未收到消息就从未 `init` |
| `deinit` 钩子 | 循环结束后，在 worker 线程上 | `shutdown()` destroy 之前（`init` 失败过也会跑；没 `init` 过就不跑） |
| `ctx.owner` | 固定 = worker 自己的线程 | 批次期间 = 当前池线程，批次之外 0（trace 继承的答案来源） |
| `Thread.getCurrentId()` 用于自查 | 稳定 | 只在一次 `handle` 内稳定，别跨消息保存 |
| `stats().running` | 线程活着 | 正被 claim（所以总量上界 = 池线程数，§12.9 第 4 条） |
| `join()` | `Thread.join` | 等 claim 交还（自旋；它只在停机路径被调用） |
| `stop()` | 关邮箱 + 唤醒 `recv` | 同上；池把邮箱抽干后不再为它排 token |
| **`spawnActor` 监督停机**（实测探针，非推理） | 循环 `break`：邮箱里剩下的消息**不再 `handle`**，但**都被计数** —— `stats().discarded_on_stop` | **继续把邮箱抽干**：`handle` 对每条剩余消息再跑一次，抽干后才不再排 token |

两种模式在监督停机下的实测数字（同一个 failing actor、8 条投递、`Clock.Manual`；`handled` 数的是
**`handle` 被调用次数**，失败的那条也在内）：

| 模式 | `handled` | 停机时 `mailbox_len` | `discarded_on_stop` | `dropped_full` | 断言位置 |
|------|-----------|----------------------|---------------------|----------------|----------|
| dedicated | 2/8 | 6 | **6** | 0 | `src/runtime/runtime.zig` 的 `Actor: a supervised stop abandons the mailbox's tail (dedicated)` |
| pooled | 8/8 | 0 | **0** | 0 | 同文件的 `Actor: the pooled stop path drains the mailbox, so nothing is abandoned (pooled)` |

两条测试把这张表钉成断言，含一条**守恒式**：`sent == received + dropped_full + discarded_on_stop` ——
将来谁改了停机语义（无论是让 dedicated 也抽干，还是让 pooled 也 `break`），红的是这条式子而不是某人的记忆。

**监督停机那一行是本表里"两种模式下语义真的不同"的地方**，写下来是因为它容易被读成 bug：
`.pooled` 的 `stop()` 语义是"把邮箱抽干后不再调度"（本节上一段就写了这一句），而 dedicated 的
`handle` 循环是 `break` 走人 —— 于是同一个 `spawnActor(..., .max_errors = N)` 在两种模式下
"停机之后还跑不跑 handler"答案不同。**语义仍然不统一**（改它要么让 pooled 也丢弃队列、要么给
dedicated 加"抽干后再停"，两者都是会动到 D5 那条回执出口的语义决定）；但"被放弃的剩余消息要不要有个计数"
这个问题**已经定了：要**——不统一的只能是"还跑不跑 handler"，不能是"丢了多少要不要说"。dedicated 侧
计数落在循环出口（`Handle.countAbandoned`），pooled 侧落在 `Runtime.shutdown` 的收尾
（全部 join 之后、destroy 之前；`join()` 可以被早调，那时池还活着，所以不是它）——
同一个计数函数只取增量，所以收尾对 dedicated 再跑一次也不会翻倍（§8 有那条测试）。
两边都进 `RuntimeStats.messages_discarded_on_stop` + `zigmodu_runtime_messages_discarded_on_stop`（§8）。

**停机顺序**（在 §3 的老顺序上多一步，§12.6/§12.9 第 3 条）：`alive=false` → 停 ticker →
**停池线程（join）** → 断言没有 worker 还握着 claim → request/join/destroy worker → 收尾定时器。
池线程在批次之间才退出，所以"停机时它正跑着某个 worker"这个窗口里，worker 的 `handle` 会先跑完
（和 dedicated 一样：worker 不返回就拖着停机，这是刻意的）。

**明确没做**（Phase 2 起再谈，别拿 Phase 1 当结论）：

* 多池线程（Phase 1 只有一条；协议里的 two-bit 与环都是按"读者只在 pop 时认领"写的，加线程前要
  把 §12.3/§12.10 的推理重新做一遍）；
* `batch` 的实测调优（默认 16，D3 的起点；per-worker 覆盖也没做）；
* 公平性加权、优先级、CPU affinity/NUMA（§12.7 本来就排除）。

**Phase 1 落地后补的三件（原"没做"清单里已划掉）**：

1. **示例真的跑池了**：`examples/runtime-workers` 的 audit worker（长尾那一环：消息驱动、
   故意慢、且不在 `feed → book → risk` 的延迟链上，见 §12.5）现在以
   `.{ .capacity = 64, .mode = .pooled }` spawn，池的上界由
   `builder.withMaxPooledWorkers(1)` 声明。运行时打印一行
   `[pool] declared=1 threads=1 spawned=1 dispatched=N claimed=0 ready_len=0 push_failures=0`，
   并在 `dispatched == 0` / `push_failures != 0` 时**以非零退出码失败** —— 也就是说这一环不再是
   "编译过就算数"，而是每次 `zig build run` 都验证一遍：单测过 ≠ 真跑过。
   （`audit.state.kept` 在池化后仍是**运行中**的瞬时读数，不要当全量。）
2. **池进了 Prometheus**：§8 的那 6 条 `zigmodu_runtime_pool_*`。`pool_dispatches` 是"池真的被用了"
   的远程可读证据，`pool_ready_push_failures` 是"必须恒 0"的契约读数。
3. **`zmodu runtime` 认识了池的两种写法**：`.max_pooled_workers = N` 与 `withMaxPooledWorkers(N)`
   各报一条带 `file:line` 的事实，外加"有几条 spawn 写了 `.mode = .pooled`"。仍然只报看得见的事实：
   它**不**去判断"声明的池和 `.pooled` 的 spawn 是不是同一个 build"、也不去判断 pooled worker 是否
   可达 —— 那是文本判不了的。
