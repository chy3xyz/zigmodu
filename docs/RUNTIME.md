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
| `pub fn init` / `pub fn deinit` | 生命周期钩子；**每一代各一次**——进组之后一次重建就是一轮 `deinit` + `init`（§14） | 打开/关闭资源 |
| `pub fn onError(self, err, ctx) Supervision.Strategy` | **Actor 才有**：每条错误现场决定 `.restart` / `.stop`，覆盖配置的策略 | 只有某些错误值得停（如 `error.Fatal`） |
| `Supervision.group = g` | **进监督组**：还没到"停"之前，把决定交给组（重建自己 / 重建同组 / 停整组） | 一组 worker 该一起活、一起死，或一个有难同当 |

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
见 **§14**（组 / 策略 / 强度 / 树）：重启的语义在那里定死了 —— 它是
**`deinit` + `init` 原地重建**，没有"可拷贝的初始副本"、也没有 `reset` 钩子，
所以本节"在语义确定之前宁可不给"这条不再矛盾。

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
| `Wheel(Payload)` | **单线程驱动（ticker 独占）** | 分层时间轮，O(1) 插入/取消；10ms 粒度、5 层、最长 ~124 天；`advance(now)` 的语义是"到期即发、不到期不发"——走过的槽整槽过期，`now` 所在的槽只发到期的那部分（没到期的留到下一个 tick），所以 10ms 槽粒度不写进延迟上界（§3）。长停摆走 O(pending) 扫描。**零锁**：`schedule`/`cancel`/`advance`/`drainAll` 只有驱动它的那一个线程能调（Debug/ReleaseSafe 下 `claimOwner`+`assertOwner` 会拦）；跨线程只通过 `Runtime` 的有界命令队列交接，见 §3「`after` 到底做了什么」。`drainAll` 是 fire/cancel 之外的第三个出口：停机时把还在轮里的 payload 交给同一个 `drop` 钩子。id 索引是**数组哈希表**（不是 `AutoHashMapUnmanaged`），理由见下 |
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

**为什么 id 索引是数组哈希表而不是 `std.AutoHashMapUnmanaged`**：`nodes`（id → node）在运行时里的形状是
**长生命周期 + 永远新鲜的 id** —— 轮活整个进程，每一次 `after()` 都是一个新 id。`HashMapUnmanaged` 用墓碑
删除，而它的增长预算（`available`）把墓碑**也算作可用**，于是表能被墓碑填满：本机实测（200 轮 × 100 个定时器，
每轮全部触发，id 不重复）得到 256 槽里 206 个墓碑、**0 个空槽**，此后每次查找都要走完整个表 ——
同一份测量在新轮上 15.0 ns、在老化轮上 203.9 ns（**13.6×**，ReleaseFast；Debug 173.3 → 2143.9，12.4×）。
这个状态**不会自己恢复**：之后每次插入回收一个墓碑而不是消耗空槽（吸收态），而增长要求
`size == max_load`，100 个活定时器永远到不了。容量大小不是变量 —— 把表预撑到 131072 槽（2MB）照样排干到 0 个空槽，
而 4194304 槽且**有空槽**的表比 256 槽无空槽的表快 15 倍：变的是"探测到第一个真空槽要走多远"。

`AutoArrayHashMapUnmanaged` 用后移删除，没有墓碑；它的索引重建规则保证占用 ≤ 60%，空槽是结构性保证、
不是 churn 历史的函数。同样 churn 之后比值是 0.65×–0.99×（三种优化模式、两种分配器），即"老化不改变查找代价"。
`TimerWheel x100K`（10 万个定时器铺开、一次 `advance` 全触发）没有回退：门禁测量 7.02 ms 对基线 6.808 ms（1.03×）。
分配契约**没有变化**：首次 `schedule` 仍是 2 次分配（node + 数组；数组哈希表在条目数 ≤ 8 时只有 entries 一个分配，
索引头要到第 9 个条目才出现）、`cancel`/`advance`/`drainAll` 仍是 0 次 —— `src/runtime/alloc_contract_test.zig`
的精确断言原样通过，一个数字都没改。这条性质由两处守着：`timer_wheel.zig` 的
`a long-lived wheel's lookups do not get slower as it ages`（老实现下**红**：13.6×/10.6×/12.4×，分别对应
ReleaseFast/ReleaseSafe/Debug），以及基准的 `TimerWheel churn x1M`（`[med3]`，已进基线；老实现 265.5 ns/schedule+fire，
新实现 27.6 ns，9.6×）。

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
var bridge = try zigmodu.runtime.Runtime.MetricsBridge(PrometheusMetrics).init(&rt, metrics);
metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge);
```

它注册 19 条 `zigmodu_runtime_*` 指标（`workers` / `running` / `messages_sent` /
`messages_received` / **`messages_dropped`** / **`messages_discarded_on_stop`** / `handler_errors` /
`timer_fires` / **`timers_discarded`** / **`timer_deliveries_dropped`** / **`timer_lag_ms`** /
**`supervised_stops`** / **`group_restarts`**（后两条是 §14 的监督读数），
加上池化执行（§12）的 6 条：
`pool_declared` / `pool_threads` / `pool_ready_len` / `pool_claimed` / `pool_dispatches` /
`pool_ready_push_failures`）。名字里没有 `_total` 后缀是刻意的：这些是**抓取时采样**的快照，
所以走 gauge 而不是 counter（`PrometheusMetrics.Counter` 没有 `set`）。

`supervised_stops` 与 `messages_discarded_on_stop` 是**两条曲线**：前者是"一个成员被框架停掉了"
（它自己的预算、同组成员连坐、或强度用尽整组停），后者是那次停机顺手扔掉的队列长度。
一个成员死了但队列是空的，只动第一条。

`group_restarts` 是它**唯一**的配对读数，也是"这个成员没有真的死"的证明：重建一次就涨一次，
所以 `group_restarts` 持续涨而 `supervised_stops` 不涨 = 有一个成员在**反复重启**，
正在往它组的 `max_restarts` 上撞。两个都不涨而 `handler_errors` 在涨 = 错误都在预算内被吃掉了。

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
| `pool_threads` | 池线程数：`0` = 池还没起（或已停），起来后 = **声明的宽度**（`pool_threads`，默认 1） | `pool_claimed` 的天花板；只有 0/1 两个值说明宽度没被声明（§12.12） |
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
| **未发版** | **Runtime Replay v1（投递轨）**：spawn 点 `.record = .{ .id, .capacity }` 声明**每 worker 一条同类型轨**（复用 §11 的环 + log 的一个 `Sequencer` 打**全局** seq），取点在 `Handle` 的投递漏斗（`send*` + `after` 的定时器投递）；`Runtime.deliveryLog()` + `Replayer.step()`（`replayAll()` 附带）按 seq 归并、驱动 `Clock.Manual`、调用方给"标识 → 新 handle"映射回投 | ✅ 本文档 §13.7（**Breaking：否** —— `SpawnConfig` 多一个可选 `.record`，`Handle` 多一个默认 `null` 的 `track`；没声明就是一次空判断 + 零分配不变。**未做**：落盘/codec、跨进程） |
| **v0.31.0** | **监督树**：`rt.spawnGroup(policy)` + 四种策略（`one_for_one` / `one_for_all` / `rest_for_one` / `stop_group`）+ 重启强度（`Intensity`）+ 组嵌套（强度用尽即升级到父组）+ **原地重建**（`deinit` + `init` 在同一线程、同一循环里；不换 handle、不关邮箱）+ `supervised_stops` / `group_restarts` 两个累计量与两条指标 | ✅ 本文档 §14（**Breaking：否** —— `Supervision` 多一个默认 `null` 的 `.group`，`spawn*` 签名一字未改；`Mailbox` 多一个 `wake`/`recvWakeable`，`recv` 行为不变） |
| 之后 | 跨进程 / 跨节点监督 | 未承诺 |
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
  都不覆盖。v1 录的是 `HotBus` 的**发布流**。（**投递流**那一半后来单独做了：**§13** ——
  取点在 `Handle` 的投递漏斗，每 worker 一条同类型轨 + 共享 `Sequencer`，**不需要 codec**。）
- 不做领域事件溯源（那是 `core/EventStore.zig`：按 `stream_id` + 版本 + 快照、可持久，
  是"业务决定了什么"；`Recorder` 是"运行时投递了什么"，内存、有界、opt-in 的调试工具）。
- 不承诺进程级完全确定性：`spawn`/`init` 副作用、网络、墙钟、以及丢弃模式都不重放。
- 只有**读注入 `Clock`** 的代码参与重放；直接调 `core/Time.zig` 的路径读到真实时间。

## 12. WorkerPool / Scheduler —— Phase 2 已落地（N 条池线程，默认 1）

> 状态：**Phase 1 已落地**（一条池线程），**Phase 2 已落地**（N 条，声明入口 `pool_threads`，
> 默认 1 = Phase 1 的形状；环改成多消费者安全）。代码全在 `src/runtime/scheduler.zig`，
> 入口 `spawn(..., .{ .mode = .pooled })`。
> 12.1–12.9 是设计原文，原样保留作为决策记录；**12.10 记 Phase 1 的落地结果**，
> **12.11 记 Phase 1 发出去之后修掉的四处缺陷**，**12.12 记 Phase 2**（多消费者环、线程集合、
> 宽度声明、以及实测数字）。
> **仍未做**：公平性加权（**加权**没做；"会不会饿死"已在 §12.16 实测并钉住：等待 = 一个 batch）、
> `batch` 的实测调优（**已在 §12.16 收口：结论是保持 16**）、affinity 的**声明**（`spawn` 上的字段；
> §12.7 的复核记了为什么它卡在"dedicated 路径没有启动握手"，以及原语 `runtime.pinCurrentThread` 已落地）。

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
   **N 条池线程下原样成立**（§12.12 实测：4 条线程、4 个 worker 的压力跑，overlap 读数 0）；
   但"N 条"把**协议外围**重新摆上台面：就绪环必须是多消费者安全的（Phase 1 的出队是
   单消费者写法，§12.12 有红证据），环容量必须是"每个 worker 一个 token + 每个消费者一个窗口槽位"，
   池的宽度必须显式声明。
2. **每 worker FIFO**：同一 worker 的消息顺序不变（`Mailbox` 不变，仍是有界的）。
   这条与池的宽度无关：顺序来自邮箱，池只决定"什么时候被谁跑"。
3. **池线程绝不阻塞**：调度线程上跑的代码不允许 `recv(0)` 阻塞、不允许 sleep、不允许等锁。
   N 条线程下多一条含义：**空转也要有界** —— 一条拿不到的 token 不能让 N−1 条线程全速自旋
   （§12.12 的退避；Phase 1 靠"只有一条线程"掩盖了它）。
4. **热路径零分配**：就绪队列是定容 `MpscRing`；派发与认领零分配。由 §13 那份分配契约守。
   **线程数组也在 `Scheduler.init` 一次分配**（宽度是声明值，不在调度路径上分配）。
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

**`SchedulerConfig.batch` 不只是性能旋钮 —— 它就是公平上界。** 环是 FIFO、每个 worker 至多
一个 token，所以"一个永远忙的 worker 把另一个已就绪的 worker 挡在后面"的**最坏等待就是一个
batch**：一批跑完必须交回，环里的下一个才被认领。这条以前只是设计论证，现在有断言：
`Pooled (§12.3): an endlessly busy worker cannot starve a ready one`（一个自我续食、积压无界的
worker A + 只发一条的 worker B，断言 B 被服务时 A 还没跑过 256 条）。
**变异验证的形状值得记下来**：把 `batch` 调成 `1_000_000`，红的是**那条边界断言**而不是超时 ——
B 仍然被服务，只是要等 A 那一批跑干。所以小 batch 换吞吐、大 batch 换的是**所有人的延迟上界**，
两边都不能只按吞吐调。

**这一跳的实测价格**（`src/benchmark.zig` 的三条基准，同一条轴、同一个生产循环、同一个 worker、
同样 256 的邮箱，只有"谁在 drain"不同）：

| 指标 | ns / 次交接 | 相对无线程 |
|---|---|---|
| `Mailbox post+drain x1M`（无第二线程） | 17 | — |
| `Worker drain dedicated x1M` | 128 | 7.6× |
| `Pooled dispatch x1M` | 190 | 11.3× |

即**池化的一次交接约为 dedicated 的 1.5–2.9 倍**（8 次独立运行的比值 1.57–2.93）。这条数字把
"多一跳"从形容词变成了量级：关键路径上每一跳都要付大约一倍，链条越长越亏；而长尾 worker
用池化省下的是一条线程，付的是它自己那一跳 —— 它不在任何人的关键路径上，所以这笔账划得来。

**池的扫描（`benchPoolSweep`，5 个点、每点 50 万条、中位 3 次，只报告不门禁）**：

| workers | pool_threads | ns / 条 |
|---|---|---|
| 1 | 1 | ~410 |
| 10 | 4 | ~114 |
| **100** | **1** | **~41** |
| 100 | 2 | ~55 |
| 100 | 4 | ~66 |

- **worker 越多、每条越便宜**（410 → 41）：每个 worker 是一只邮箱，100×64 = 6400 条的缓冲让生产者
  几乎不再撞 `error.Full`；这条曲线的代价主要在**生产者的重试**上，不在派发上。
- **加池线程从来没有变快**（6 次独立运行：`pool_threads=1` 5 次最快、1 次持平；最快的几次
  比 2/4 线程**快 2–3 倍**）。所以默认值 1 是对的，**不要按吞吐去调大它**。
- **但上面那一族量的是"生产者受限"那一半** —— 6400 条的缓冲让池从来不是瓶颈。同一根轴换上**每条消息
  真有活儿**（一个 256 步的依赖乘法链，约 400 ns）就是下一族，而结论**反过来**：

  | workers | pool_threads | ms（4 次运行） |
  |---|---|---|
  | 8 | 1 | 78 / 92 / 83 / 90 |
  | 8 | 2 | 49 / 59 / 56 / 49 |
  | 8 | **4** | **34 / 31 / 31 / 31** |
  | 8 | 8 | 35 / 36 / 38 / 33 |

  **有活儿时线程近线性扩展到 4**（2.4–3.0×），**8 条反而略降**（8 个 worker + 生产者已经把 10 核占满）。

  **两族合起来才是可决策的答案**：`pool_threads` 要**按活儿定**，不能盲调大 ——
  handler 是琐碎的就 1 条（此时生产者才是瓶颈，多线程纯属争抢），每条消息有真活儿就
  `min(忙的 worker 数, 核数 − 1)`。单独看任何一族都会得出错结论。

**两条 hand-off 指标只报告、不门禁**，理由是实测出来的：8 次运行里
`Worker drain dedicated x1M` 散 1.84×、`Pooled dispatch x1M` 散 **3.09×**（同批
`Mailbox post+drain x1M` 只散 1.26×），而窗口是 2.0× —— 在一次运行内就能摆动 3 倍的数字**不能**
当判据，否则又多一台假红机器。它们的绝对值是宿主调度/唤醒路径的性质，所以进了
`check-bench.sh` 的 `REF_METRICS`（"宿主测量，永不门禁"）。要判据就判"比值漂移到 1.3× 以上"，
那是边界在动，而那条目前也是**打印**而非门禁 —— 先攒跨宿主数据。

### 12.13 停机策略与执行类别（两者都与执行模式解耦）

**§12.5 那两条差异曾经是执行模式的副作用**：同一个 worker 因为 `.dedicated` / `.pooled` 不同，
"停机后邮箱里的尾巴怎么处理"就不同。现在它是**显式声明**：

| 声明 | `.dedicated` | `.pooled` |
|------|-------------|-----------|
| 不写（`null`） | `.immediate` ——**历史行为** | `.drain` ——**历史行为** |
| `.stop_policy = .immediate` | 监督停机即断，尾巴计入 `discarded_on_stop` | 批次停止 + `countAbandoned`（＝今天 dedicated 的答案） |
| `.stop_policy = .drain` | 停机后继续抽干（＝今天 pooled 的答案） | 同左 |

**"不写"必须复现两种现状**，这是硬要求（§2 的兼容原则）。实现上解析成默认值时两条路径走的都是
**原语句**，且新增的 `abandoned` 标志只在 pooled + `.immediate` 上被触碰 —— 所以默认组合零影响。

**一条容易搞错的边界**：`.immediate` 说的是**监督停机**那一侧；`Handle.stop()`（外部停机）
在两种策略、两种模式下**都抽干**（`close()` 之后队列仍可被读完）。有测试钉住。

**执行类别**：`.blocking` 的 worker 走**独立的一只池**（`blocking_threads` / `max_blocking_workers`
各自声明），于是"一个阻塞的 handler 占住池线程"不会饿死 CPU 池 —— 这是**结构性事实**（两池不共享
环、线程、计数），不是时序巧合。

- **这是声明式的，不是检测式的**：runtime **不能**（Zig 里也不能一般地）判断一段代码会不会等外部资源。
  所以它解决的是"**被声明为阻塞的 worker 不会占 CPU 池**"，**不**解决"忘了声明"。
  凡是 handler 会等进程外的东西（DB 往返、阻塞 HTTP、文件 IO、第三方锁）就声明 `.blocking`。
- **`blocking_threads` 按下游资源的并发量定，不要按核数** —— 这些线程在等待，不是在算
  （例如按 DB 连接池大小）。
- **两个上界是两次独立 admission**，不是一次声明拆两半：声明了阻塞池之后 `max_pooled_workers`
  不再描述阻塞类，总量上界是**两者之和**；`max_blocking_workers = 0` 表示"与 CPU 池同数"。
- **接线两条路都通**：`Runtime.initWithOptions(.{ .scheduler = … })`，或走 builder ——
  `b.withMaxPooledWorkers(4).withBlockingThreads(2, 7)`（参数是 `blocking_threads` 与
  `max_blocking_workers`，与 `Config` 上的字段同名）。**不声明就没有阻塞池**：`.blocking` 在 `spawn`
  时被拒，与 `.pooled` 缺 `max_pooled_workers` 是同一种拒绝（§12.8 D2）。
- **可观测性**：`MetricsBridge` 为阻塞池发布**同样六条**独立指标
  （`zigmodu_runtime_blocking_pool_*`），与 CPU 池的六条并列。没声明阻塞池时它们是 0 ——
  "这个 app 没有阻塞池"是仪表盘能画出来的答案，不是一条缺失的线。读侧对应 `blockingPoolStats()`。
  注意 `pool_threads` 是**正在跑的**线程数（声明后仍为 0，直到第一条 `.blocking` spawn 把池拉起来），
  **声明的宽度**看 `max_pooled_workers`（= `blocking_threads`/`max_blocking_workers` 里那个上界）。
- **`.blocking` + `.dedicated` 是编译错**：那个声明会被静默忽略，比不声明更糟。

### 12.14 WebSocket 路由的 auth 声明是**被强制的**（而且只能是 `.public`）

**问题**：WS 升级在 `Server` 里是**在 `router.match` 之前、在任何全局中间件之前**被应答的
（`Server.zig` 的升级块 vs 其后的 `router.match`），所以 `ws_routes` 上的 `auth` / `permission` /
`roles` **没有任何执行点** —— 它们会被记进 catalog，然后**没有人查**。`findEntry` 还会主动
`continue` 跳过 `is_ws`，所以"catalog 是唯一的 bypass 真相"这条设计在 WS 上两头都断。

**这条曾经真的咬人**：脚手架的 IM 网关在 WS 上把身份取自**查询串**
（`ctx.queryInt(u64, "userId", 0)`），也就是说**任何客户端传 `?userId=<任意人>` 就能以那个人连接**，
而同一份模板里那条路由写着 `.auth = .jwt`。声明读起来是保证，实际上什么都没有。

**现在**：WS 路由的声明被**拒绝**而不是被记录 ——

| 写法 | 结果 |
|------|------|
| 没声明 `.meta.auth` | **编译错**（消息里给出该写什么） |
| 声明了非 `.public` 的 auth | **编译错**（说明没有执行点） |
| 声明了 `permission` / `roles` | **编译错**（同上） |

**为什么是编译期**：运行期拒绝会把那条**骗人的声明留在源码里**给下一个人抄。编译期拒绝让"这个声明是假的"
变成**无法表达**。这与 §12.8 D2（`.pooled` 没有声明就拒绝 spawn）是同一条原则。

**WS 的身份该谁负责**：应用自己，在 `on_connect` 里 —— `ctx` 就是那条升级请求。脚手架的 IM 网关
示范了 fail-closed 的形状：`ImGateway.verifier` **默认为 null**，而 `accept` 在没接验签器时**拒连**
（不是回落到信任客户端给的 id），并在注释里给出接法。HTTP 侧同理：身份从 JWT 中间件写入的 attr 读
（`ctx.requireUserIdInt(T)`），**不从查询串读**。

**审计也跟着改了**：`Testkit.auditAuthCoverage` 过去对 `is_ws` 直接 `continue`（唯一一个本可以发现
这件事的自动检查，恰好"看别处"）。现在是**断言** `.auth == .public` —— 把不变量钉住，而不是跳过它。

### 12.6 与现有件的关系

- **`Mailbox` 不改语义**（仍是有界、`error.Full`、`sendBlocking`），只多一个"被谁唤醒"的分叉。
- **`Wheel` 不变**：`after` 的投递末端是 `handle.send`，它照 §12.4 决定推不推 ready。
- **`Recorder`**：`Record` 覆盖的是 `HotBus.publish`，与池化正交；若将来扩到 `send`，
  记录点仍在 `Handle.send*`，不受调度模式影响。
- **`RuntimeStats`**：`workers` / `running` 语义不变（"已 spawn" 与 "正在执行"），
  池化后 `running` 的上界从"worker 数"变成"**池线程数**"——这本身是个有用的观测信号。
  宽度可声明之后（§12.12）这句话的读数也变了：`running ≤ pool_threads`，而 `pool_threads`
  是**声明的宽度**（不是 `0/1` 两个值）。
- **`shutdown()`**：§3 的顺序（先停 ticker → 停 worker → join → destroy → drain）要扩展一步：
  先停调度线程（它们可能正握着某个 worker 的 `claimed`），确认所有权都归还后再 destroy。
  **N 条时是"停一整组、join 一整组"**：`Scheduler.shutdown` 先让每条线程看到 `stopping`，
  再取走 `started` 计数并 join 那么多条 —— 计数是**取走**（swap 成 0）而不是读，否则两个
  并发调用方会 join 同一个句柄两次（第二次是 `EINVAL` → 中止，§12.11 第 4 条）。

### 12.7 明确不做（本设计范围内）

- **不做新的队列原语** —— `MpscRing` 够用（多生产者推 ready、多调度线程消费）。
  **Phase 2 的修正**：ready 环本身必须是 MPMC 的（多调度线程消费），而它一直是"按单消费者写的"
  （§12.11 第 1 条只修了**生产者**侧的窗口）。修法不是引入新原语：还是 Vyukov 那套
  `enqueue_pos`/`dequeue_pos` + 槽位序号，只是**出队那一半也要 CAS 下标**（§12.12）。
- **不做 CPU affinity / NUMA / 优先级**（评估 §14 也建议往后放）：它们属于**执行策略层**，
  应在 Dedicated/Pooled 稳定之后再谈，否则会同时改两个变量。
  **调度器稳定后的复核（本条的前提"应在 Dedicated/Pooled 稳定之后再谈"已满足，拆成两层结论）**：
  * **原语已落地**：`src/runtime/affinity.zig` 的 `runtime.pinCurrentThread(cpu)` —— 把**调用线程**
    钉到一个 CPU；平台没有这个能力时返回 `error.Unsupported`，**不静默**（本仓库明写"静默忽略的
    声明比不声明更糟"，`runtime.zig:145-146`）。平台事实是**实测**出来的，不是推测：
    Linux 有 `sched_setaffinity`（`lib/std/os/linux.zig:3082`）；**macOS 根本没有** —— SDK 的
    `sched.h` 46 行里只声明 `sched_yield` / `sched_get_priority_{min,max}`（没有 `cpu_set_t`、
    没有 `sched_setaffinity`），唯一 affinity 形状的 API 是 Mach 的 `THREAD_AFFINITY_POLICY`，
    参数是 **L2 分组 tag 而不是 CPU 序号**（`mach/thread_policy.h:208-212`，其头文件自称
    "experimental"、"a hint to the scheduler for thread placement"），且本机（Darwin 25.6.0 /
    macOS 26.6.2 arm64）内核连这个 hint 都不收：`thread_policy_set` 返回
    **46 = `KERN_NOT_SUPPORTED`**（`mach/kern_return.h:298`）；Windows 侧本 std **没有**
    `SetThreadAffinityMask` 之类的绑定。**三个目标里两个不能兑现，能兑现的那个正是 CI 跑的。**
  * **`.affinity` 声明仍不做**：它只对 `.dedicated` 有意义 —— `.pooled` 的 worker 线程是"谁抢到
    token 谁跑"，"把这个 worker 钉住"在那儿是**未定义**而非"难实现"（没有可归属的线程）；
    而它若要"失败必须响亮"，就需要 dedicated 路径目前**没有**的父子启动握手：`spawn` 在线程跑起来
    之前就返回（`runtime.zig:1719-1723`），线程体的 init 结果"刻意不读"（`runtime.zig:2305-2308`）。
    先加字段只能买到"静默失败的 pin"或"上报成功却没拿到核的 worker"。详见 `affinity.zig` 的模块 doc。
- **不做 μs 级 timer**：那是独立的 `LowLatencyClock/Timer`（评估 §7 的建议），与调度器正交。
- **不做 remote worker**（评估 §15）：本地 Runtime 稳定之前不谈。

### 12.8 已定的四个决策

**D1 API 形状**：`spawn(..., .{ .mode = .pooled })`，**不**另开 `spawnPooled`。
一处入口、模式是显式声明，读者不用在两套命名间对齐语义。代价是 `spawn` 的第三参从
"comptime 容量"变成配置结构（容量也进这个结构），迁移面见 §12.9。

**D2 池的归属与默认**：`Runtime` 持有池；池线程数在 `Runtime.init` 时声明，
**默认不创建任何池线程** —— 不碰 `runtime` 的应用仍然是零线程，与 §2 的 opt-in 契约一致。
未显式配池却调用 `.mode = .pooled` 是**配置错误**（启动时报错），不是"顺手给你起一条"。

**Phase 2 把"池线程数"拆成两个声明**（§12.12）：`max_pooled_workers` 是**上界**（环容量按它算、
第 N+1 个 `.pooled` spawn 被拒），`pool_threads` 是**宽度**（几条线程消费这个环，默认 1）。
两个都是声明值，两个都在启动期定：一条线程都没有的池只能把 token 堆在环里，宽度为 0 是配置错误、
被夹到 1；宽度也要进环容量的公式（每个消费者在出队窗口里占一个槽位）。

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

> **本节是设计期的待办清单，其中第 1 条已在 §12.16 收口**（实测 6 个点 × 3 种形状，
> 结论：**保持 16**）；另外两条（第三参迁移、`shutdown()` 顺序）在 §12.10 的落地记要里结掉。
> 本节其余文字保留原文，作为当时的决策记录。

1. ~~**drain 批量 16 是起点，不是结论**：用 runtime benchmark 复核（突发型 vs 延迟型各一组），
   并把结论写回本节。测之前不要把它当性能承诺。~~ → **§12.16 已测并写回**。
2. **`spawn` 第三参的形状变化**：容量与 `mode` 合进配置结构后，既有 `rt.spawn(W, .{}, 256)`
   的调用点需要迁移（全仓调用点数量在落地时清点）。这是本设计唯一预期的**源码级** Breaking。
3. **`shutdown()` 多一步**：先停调度线程（它们可能正握着 `claimed`），确认所有权归还后再 destroy
   worker —— §12.6 已记，落地时要和 §3 的既有顺序合并成一条。
4. **`RuntimeStats.running` 的上界变化**：池化后从"worker 数"变成"池线程数"。这本身是有用的观测
   信号，但别让它被误读成"worker 变少了"。**Phase 2 落地读数**（§12.12）：`running` 仍逐 worker
   语义（= 被 claim 的 worker 数），上界就是 `pool.threads`（声明的宽度），`pool.claimed`
   读的是同一个量；`pool.threads` 是**真实条数**（`0` = 池还没起或已停），不再是 `0/1`。

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
| `join()` | `Thread.join` | 等 claim 交还（先自旋 1024 轮，之后每 1 ms 轮询同一谓词；它只在停机路径被调用） |
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
**停池线程（join，N 条就是 N 条）** → 断言没有 worker 还握着 claim → request/join/destroy worker →
收尾定时器。池线程在批次之间才退出，所以"停机时它正跑着某个 worker"这个窗口里，worker 的 `handle`
会先跑完（和 dedicated 一样：worker 不返回就拖着停机，这是刻意的）。

**明确没做**（Phase 2 起再谈，别拿 Phase 1 当结论）：

* ~~多池线程~~ —— **Phase 2 已做，见 §12.12**（协议里的 two-bit 与回执出口在任意 N 下都成立，
  §12.10 这两条不用改；改的是协议外围：环的多消费者出队、宽度声明、以及拿不到 token 时的退避）；
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

### 12.11 Phase 1 修过的四处（v0.29.1；都在 `.pooled` 上）

> 四处都是 v0.29.0 已经发出去的缺陷，**只在 `.pooled` 这条可选路径上**（`.dedicated` 默认不受影响）。
> 共用一个形状：池把"某件事一定会发生"当成前提，却没有把它变成断言。每处都是**先写能红的测试**再改，
> 测试名缀在每条末尾。

**1. `push` 把"出队窗口"读成"环满" → 丢 token → 那个 worker 永久停摆**（危害最大）。
`ReadyRing.tryPop` 先推进 `dequeue_pos`、再释放槽位（`slot.sequence = pos + capacity`）；生产者在这两条
指令之间读到的还是**上一轮的序号**，被 Vyukov 的检查判成"满"。普通有界队列里这是保守答案（调用方重试），
在这里却是丢一个 **token**：worker 的 `queued` 还是 true，别的生产者也不会替它推 ⇒ 这个 worker 再不被
调度，而邮箱继续收条。本机实测（cap=4、4 生产者、1 个 CAS 消费者、各 20 万次 `tryPush`）：

| 构建 | 尝试 | 被拒 | 其中读到的 `len < capacity`（环并未满） |
|------|------|------|----------------------------------------|
| ReleaseFast | 800 000 | 324 416 | **187 053** |
| Debug | 800 000 | 133 070 | **60 986** |

修法两处，都做：① 环容量按 `max_pooled_workers + pool_threads` 取 —— 消费者在窗口里也占着一个槽位
（Phase 1 `pool_threads = 1`），只按 worker 数取就正好会少这一格；② `push` 首次被拒后**自旋重试**
（预算 `push_retry_rounds`），只有整个预算都没等到才计数 + Debug/ReleaseSafe 断言 —— 从此"环满"只表示
真的满。`ready_push_failures` 仍然是"必须恒 0"的读数。
测试：`scheduler: a producer waits out the slot its consumer is mid-release on`（把窗口手工撑开，
确定性）· `scheduler: a hammered ring never eats a token`（真打频率）。

**2. `Scheduler.start()` 的懒启动不是原子的 → 起两条池线程、只记住一条 → use-after-free**。
池是**第一次 `.pooled` spawn 才启动**的（D2），所以两个并发 spawn 会一起走到
`if (self.thread != null) return;` 与 `self.thread = try std.Thread.spawn(...)` 之间：两条都过检查、
各起一条线程，只有后写的句柄被记住 —— `shutdown` join 一条，另一条活进 `Scheduler.deinit` 的释放里。
这不是泄漏，是 UAF。修法：`start_claim` 上的 CAS，输的一方**等这次尝试有结论**（句柄发布，或失败后位被
放开），不自己再起一条。改前实测 `expected 4, found 5`（多出来的那条线程**没有任何计数器看得见**，
判据只能是 OS 线程数：macOS `task_threads` / Linux `/proc/self/task`）+ 未释放的环与 scheduler。
测试：`scheduler: two concurrent first starts spawn exactly one pool thread`。

**3. `Delivery.post` 投递后不 `announceReady` → 定时器投递静默滞留**。
`send*` 四条路径都在投递后通知就绪，定时器那条（`after` → `Tick` → `Delivery.post` → `enqueue`）没有：
池化 worker 的就绪是**环里的 token**，不是停在 `recv` 的线程，于是这条消息一直躺到"碰巧有别的 `send`"
为止 —— 只被定时器喂的 worker 就是永远。修法：投递成功后按与 `send*` 相同的规则通知就绪
（投递失败的那条直接返回，不推 token）。测试：`Runtime: a timer's delivery to a pooled worker arms its ready token`
（`Clock.Manual` + `tick()`；改前 `WaitTimeout`，因为没有任何东西会再碰这个 worker）。

**4. 并发 `shutdown()` 崩溃**。`Runtime.shutdown` 的文档写"幂等"，但它不是**线程安全**的：两个调用方都走
函数体、都读到 `Scheduler.thread`、都 `t.join()` —— 第二次 join 同一个句柄是 `INVAL` →
`unreachable` → **ABRT**（调用栈：`std.Thread.join` ← `Scheduler.shutdown` ← `Runtime.shutdown`），
`workers` 列表也会被走两遍。**"幂等"必须覆盖"任意个调用方、任意交错"**，不只是"返回之后再调一次"。
修法：`Runtime.shutdown` 整体进 `shutdown_mu` + `shutdown_done`（后到的调用方等前者做完就返回），
`Scheduler.shutdown` 的 join 也串行化（`joins` 互斥量，join 前先把句柄摘下来）。
**对照实验**：同一份测试源码（只用公开 API）在**未改动的基线**（worktree @ `dd6df20`）连跑 8 次
**8 次全挂**（同一个 `INVAL` 断言），在修后的树上 **8 次全过**。
测试：`Runtime: two threads calling shutdown at once are safe`。

### 12.12 Phase 2 落地记要（N 条池线程）

> **结论先说**：协议本体不用改。`queued`/`claimed` 两个位、单出口回执（§12.10 第 2 条）、
> D4「每 worker 至多一项」、D5「回执前重查邮箱」在任意 N 下都成立 —— Phase 1 侥幸掩盖的是
> **协议外围**的三件事：就绪环的**多消费者出队**、环容量的**消费者窗口**（d2a1cd6 已改成
> `max_pooled_workers + pool_threads`）、以及**一条拿不到的 token 会让 N−1 条线程全速空转**。
> 本节的四处改动都在外围。

**1. `ReadyRing.tryPop` 改成多消费者安全**（本次最硬的一处）。Phase 1 的出队是
"读 `dequeue_pos` → 读槽位 → 写 `dequeue_pos = pos+1` → 释放槽位序号"：

* 两条线程读到同一个 `pos` 就**都会拿走同一个 token** —— §12.3 的状态独占在进门之前就没了
  （两条线程会跑同一个 worker）；
* 两次 `dequeue_pos.store` 与两次序号写会让某个 token **永远 pop 不出来** —— 那个 worker 从此
  不再被调度，而邮箱继续收条。

修法是 Vyukov 出队那一半的标准写法：**下标用 `cmpxchgWeak` 认领**，赢了才拷值、才释放槽位序号；
落后的一方重读下标，读到"还没轮到我"就返回 null。**没有新原语**（§12.7 的"不做新队列"仍然成立）。

**红证据**（把 `tryPop` 换回 Phase 1 的写法，其余代码不动，只跑新测试）：

| 测试 | 旧实现 | 新实现 |
|------|--------|--------|
| `scheduler: two consumers race one token and exactly one of them gets it` | 第 2 轮就红：`expected 2, found 3`（两条消费者各拿到一次同一个 token） | 50 000 轮全绿 |
| `scheduler: a hammered ring hands every token to exactly one consumer` | 红：`ring: token 0 came out 4 times`，环随即卡死（4 个生产者全部超预算放弃） | 4 生产者 × 5 000 token 全绿 |

两条测试的分工是刻意的：第一条是**同步到同一起跑线**的最小形状（确定性最强），第二条是
**频率形状**（暴露"丢失"那一半）。旧实现下环不会"偶尔慢一点"，它会**碎掉**：token 重复到手
之后，某个槽位的序号再也回不到可读状态。真池用例（`N pool threads conserve messages …`）在旧实现下
还会直接 **ABRT**（生产者重试预算耗尽 → `push` 的 Debug 断言）—— 上表的两条读数已在 2026-09-20
**补测复核**（确定性暂停钩子 + 纯回退两种口径），复核记录、第二条形态与新增守卫见 **§12.12.1**。

**2. 线程从"一条"变成"一组"**。`thread: ?std.Thread` → `threads: []std.Thread`（在
`Scheduler.init` 里**一次性分配**，调度路径上零分配）+ `started: usize`（已起的条数）。

* `start()`：整组在**同一个 `start_claim`** 下起完，再发布 `started` —— 懒启动的语义仍是
  "起或不起"，不是"起几条"（否则两个并发 `spawn` 会各起一部分，§12.11 第 2 条那个 UAF 只是
  从"多一条"变成"多几条"）；起失败时把已经起来的几条回滚 join 掉，`start` 保持 all-or-nothing。
* `shutdown()`：先 `stopping` + 唤醒全部，再**取走** `started`（`swap(0)`）并 join 那么多条。
  计数是取走而不是读 —— 否则两个并发调用方会 join 同一句柄两次（§12.11 第 4 条的 `EINVAL`）。
  取走同时让"停机后再问池有几条"读作 0。
* `stats().pool_threads`：**真实条数**（`0` = 池没起或已停，起来后 = 声明的宽度）。
  把"池部署了吗"和"池有多宽"合成一个读数，会让 `pool_claimed ≤ pool_threads` 这条契约读数
  在 N>1 时永远停在 0/1 上 —— 那正是这条读数被写下来的原因（§12.9 第 4 条）。

**3. 宽度要有声明入口**：`SchedulerConfig.pool_threads`（**默认 1**）、
`Application.Config.pool_threads` + `ApplicationBuilder.withPoolThreads(N)`、
`Runtime.InitOptions.scheduler.pool_threads`。三项都是默认值即"Phase 1 行为"：

* 不碰 runtime 的应用仍是零线程（D2 不变）；
* 声明了池但没声明宽度的应用，跑的还是**一条**池线程，既有测试与读数逐位不变；
* 宽度为 0 会被夹到 1：一个没有消费者的池只能把 token 堆在环里；
* 宽度**进环容量公式**：`capacity = ceilPowerOfTwo(max_pooled_workers + pool_threads)`。
  这不只是"多留一格"——消费者在出队窗口里持有的是**槽位**，槽位不够时 `push` 只能靠重试等它
  回来（d2a1cd6 的修法）。容量按消费者数算，等于把"等窗口"从每次推送的常态变成不该发生的例外。

**4. claim-miss 之后要有退避**（性能，不是正确性）。`claimed` 抢不到的 token 会被重推回环里，
但那条 token 在**当前持有者交还之前**谁也跑不了：Phase 1 的循环在"跳过"时把自旋预算清零，
于是 N−1 条线程会对着一个谁都拿不走的 token 全速空转（一条线程时这件事根本不存在，因为跳过的
前提是"有别人在跑它"）。改法两处：

* `turn()` 区分 `ran` / `skipped` / `empty`，**只有 `ran` 清零自旋预算**（"跳过"和"环空"共用一个
  预算），所以跳过也会走到 park；
* park 的判据从"环里没有 token"（`ready.len() == 0`）换成"**环和我上次看到的一模一样**"
  （`pushes` 计数器没变）—— 被 claim 住的 token 会一直在环里，用它当"有活儿"的证据就是
  永远不 park；
* 代价如实说：持有者交还 claim 那一刻**不会**唤醒 parked 的线程（生产者路径上没有 mutex/信号，
  这是刻意的），所以"偷"到那条 token 最多晚一个 `idle_wait_ms`（1 ms）。换来的是空闲时不烧核。

**实测（本机，N 条线程真跑，`batch = 1`；`claim_misses` 是 §12.9 里那个上界读数的落地值）**：

| 形状 | 读数 |
|------|------|
| 4 worker × 4 生产者 × 2 000 条，宽度 4 | `attempts = 8000`，`received = 8000`，`dropped_full = 0`，`dispatches = 8000`，`overlaps = **0**`，`claim_misses = **0**`，`ready_push_failures = 0` |
| 同上，宽度 1（Phase 1 读数） | `claim_misses = 0`（**可证**，见下），`overlaps = 0`，守恒式成立 |
| 宽度 3 + `shutdown` | 用 OS 线程数（macOS `task_threads`）量：起 3 条、再 `start()` 不增、`shutdown()` 回到基线 |
| 容量对照（手撑开两个消费者窗口） | 按 Phase 1 口径（`ceilPowerOfTwo(bound)`）的环 `tryPush` **被拒**；把窗口还回去同一个推送就成功（证明拒的是窗口不是"满了"）；按消费者口径的环从未需要等 |

**`claim_misses` 的监控口径要跟着改**（这是 Phase 2 唯一一条"读数含义变了"的东西）：

* **宽度 1**：恒 0，而且是可证的 —— 能交还 claim 的线程就是唯一能再 pop 的线程，等它再 pop 时
  自己的回执已经把 `claimed` 清了。"非 0 = 协议被破坏"这个读法在宽度 1 上仍然成立。
* **宽度 > 1**：**允许非 0**。能造出它的只有一条窗口：回执先清 `queued`、两条指令后再清
  `claimed`，生产者落在这中间就会推一个"worker 还在被跑"的 token；此时另一条线程 pop 到它、
  抢 claim 失败 —— 这就是一次 skip（token 被重推，不是丢）。这条窗口只有**持有者被抢占**时才会
  宽，所以本机实测 11 次跑全为 0；**不能把 0 当契约**，也要把"非 0"从告警里摘掉
  （要盯的恒 0 读数是 `ready_push_failures`）。
* 结构上界：skip 消耗一个 token，token 只能来自生产者的 `send` 或批次回执的重推，所以
  `claim_misses ≤ attempted + dispatches`（测试断言的就是这条）。

**新增测试**（都在 `src/runtime/scheduler.zig`，除最后两条）：

* `two consumers race one token and exactly one of them gets it` —— 50 000 轮，两条线程同一起跑线
  抢 1-token 环，每轮**恰好一个**赢家；
* `a hammered ring hands every token to exactly one consumer` —— 4 生产者 × 4 消费者、每个 token
  带自己的编号，断言**每个 token 恰好出来一次**（出来两次 = 两条线程拿到同一个 token；一次都没
  出来 = token 被环吞了）；
* `the ring is sized for its consumers' windows (the Phase 1 size would refuse)` —— 两条口径的容量
  对照，窗口用手撑开做成确定性的；
* `four consumers released together still hand one token out once` —— 上上条的**加宽版**（4 条消费者
  抢 1-token 环）：同一份协议，能读同一位置的**线程对**更多，旧实现下 `expected 2, found 4`
  （红证据见 §12.12.1）；
* `the declared occupancy pushes cleanly, round after round` —— `bound + width` 口径连压 500 轮 ×
  7 次推送**零拒绝**，并在同一用例里断言 Phase 1 口径（`ceilPowerOfTwo(bound)`）的环第 5 次就被拒；
  容量公式回退成 `max_pooled_workers` 时它红（§12.12.1）；
* `N pool threads conserve messages and never run one worker twice` —— 真线程跑池：
  `sent == received + dropped_full`、`ready_push_failures == 0`、**overlap 读数 0**；
* `with one pool thread a claim is never missed (the Phase 1 reading)` —— N=1 恒 0，**三种形状**
  （`batch` 1/8/16、worker 2/4/6）都要恒 0：一种形状是读数，几种形状才是契约；
* `the declared width is the number of threads started — and all of them are joined` —— 用 OS
  线程数当见证（多出来的线程没有任何计数器看得见，§12.11 第 2 条同理）；
* `Runtime: N pool threads conserve messages and never overlap on one worker`（`runtime.zig`）——
  真 `Runtime` + 真 `Handle.send`：3 个 pooled worker、宽度 2，守恒式 + overlap 0 +
  `ready_len == 0`、`claimed == 0` 收尾；
* `e2e: the builder's pool *width* reaches the runtime a module spawns .pooled on`（`Application.zig`）
  —— `withPoolThreads(3)` 一路走到 `poolStats().pool_threads == 3`，`app.stop()` 后回到 0。

**12.12.1 红证据与守卫的复现复核（2026-09-20 补测）**

> §12.12 第一版把"旧出队是坏的"写在**改动理由**里，而支撑它的数字来自设计审查那一步，不是这次实现
> 自己的测试 —— 执行那一轮的 agent 撞了步数上限、没交报告。本节把它补上，**生产代码一行未改**：
> 只加验证，加两条守卫，并把"守卫在旧实现下到底红不红"实跑一遍。

**(1) 确定性红证据（一次性暂停钩子，只在 `/tmp` 的副本里跑）**

把 `tryPop` 停在"读到 token 值之后、推进 `dequeue_pos` 之前"（旧形状），主线程在被暂停的消费者
停住时**完整跑一次 `tryPop`** —— 两条消费者于是同一起跑线抢一个 1-token 环。原文：

| 实现 | 观测（测试打印原文） | 判定 |
|------|----------------------|------|
| 旧 `load → 读值 → store` | `PROBE race: T1=1 T2=1 T3=2 (1 = token0, 2 = token1, 0 = null)  len=1 dequeue_pos=1 enqueue_pos=2` | **两条线程拿到同一个 token**（token0 交出两次）；且 `dequeue_pos` 被陈旧 store 从 2 **打回** 1，环当场卡住 |
| 新 CAS 认领 | `PROBE race: T1=1 T2=2 T3=0 … len=0 dequeue_pos=2 enqueue_pos=2` | token0 恰好一个消费者拿到，token1 顺位交出，三个读数互相一致 |

第二种形态（陈旧的 `slot.sequence.store`）在同一个钩子下也是确定性的：

| 实现 | 观测（测试打印原文） | 判定 |
|------|----------------------|------|
| 旧 | `PROBE stale: T1=1 T2=1 pushes={ true, true, true, true } drained={ 2, 3, 4 } stuck_after_drain=1 accepted_more=3 next_pop=0  len=4 dequeue_pos=4 enqueue_pos=8` | 暂停者醒来把**陈旧的 `pos + cap` 写回**，该槽位从此不可读：`tryPop()` 返回 null 而 `len() != 0`；后续推送还**永久毒化一格**（`accepted_more=3`），环整个停摆 |
| 新 | `PROBE stale: T1=1 T2=0 pushes={ true, true, true, false } drained={ 2, 3, 4 } stuck_after_drain=0 accepted_more=4 next_pop=6  len=3 …` | 认领过的位置只有认领者能释放：被暂停的消费者不还槽位时生产者**被拒一次**（可恢复的窗口，不是丢 token），暂停者一还，推送就进、token 一个不少 |

钩子在两条实现里插在**同一个语义点**（"值已拷出、槽位还没还"），而这正是修法的落点：新的 `tryPop`
先把位置**认领**下来再读值，"读到值"与"位置还属于我"于是是同一件事 —— 第二个人读到的不再是
"这个 token 还在"，而是"这个位置已经有人在处理"。

落地件（都在 `/tmp`，仓库里没有钩子，也没有为它留任何分支）：
`/tmp/zm-red/patch_probe.py`（换成旧形状 + 插钩子 + 两个 PROBE 用例）、`/tmp/zm-red/probe-legacy/`、
`/tmp/zm-red/probe-fixed/`。

**(2) 守卫有没有牙齿：只把 `tryPop` 换回 Phase 1 写法（`/tmp/zm-red/legacy/`），其余一行不动**

| 检查 | 旧实现下的原文 | 新实现 |
|------|----------------|--------|
| `two consumers race one token and exactly one of them gets it` | `expected 2, found 3` → `FAIL (TestExpectedEqual)`（一轮里两个赢家；复现时撞上的轮次不同，读数会不同 —— 另一跑是 `expected 1, found 2`，同一条断言） | 50 000 轮全绿 |
| `a hammered ring hands every token to exactly one consumer` | `ring: token 0 came out 4 times` → `FAIL (TokenNotDeliveredExactlyOnce)` | 4 生产者 × 5 000 token 全绿 |
| `N pool threads conserve messages and never run one worker twice` | **不是断言失败，是进程 ABRT**：`push` 的重试预算耗尽 → `scheduler.zig:564: std.debug.assert(false)`（调用栈 `push ← runOne ← turn ← poolMain`，生产者路径同样撞上；token 被吞 = worker 永久停摆） | 全绿 |

即：§12.12 新增的那两条多消费者测试**本身就有牙齿**，红证据不是设计审查的转述。本次另补两条：

* `four consumers released together still hand one token out once` —— 同一起跑线的**加宽版**
  （4 条消费者抢 1-token 环）：旧实现下红（`expected 1, found 2` / `expected 2, found 4`，视撞上的轮次）；
* `the declared occupancy pushes cleanly, round after round` —— 按新容量口径连压 500 轮、每轮 7 次推送
  **零拒绝**，并在同一用例里断言 Phase 1 口径（`ceilPowerOfTwo(bound)`）的环第 5 次推送就被拒；
  把容量公式回退成 `max_pooled_workers`（去掉 `+ pool_threads`）时它红：`expected 8, found 4`；
* `with one pool thread a claim is never missed` 从**一种形状**扩成三种（`batch` 1/8/16、worker 2/4/6）——
  "恒 0"才算有形状覆盖。

**(3) 三项读数（本机实跑；数字取自 `runPoolLoad` 的实测打印）**

| 形状 | 读数 |
|------|------|
| N 条线程的消息守恒：4 worker × 宽度 4 × 4 生产者 × 2 000 条，`batch = 1` | `sent=8000 received=8000 dropped_full=0 overlaps=0 claim_misses=0 dispatches=8000 pool_threads=4 ready_capacity=8 push_failures=0` —— 守恒式成立、`overlaps = 0`（没有 worker 被两条线程同时执行） |
| 容量边界：`bound = 4`、`width = 3`（`bound + width = 7`，容量 8），连压 500 轮 × 7 次推送 | **0 次拒绝**（同一用例断言 `ready_push_failures == 0`）；Phase 1 口径的 4 槽环第 5 次即被拒 |
| `claim_misses` 在 `pool_threads == 1`、`batch` 1/8/16 三种形状 | 三次全 **0**（各自 `sent == received`、`dropped_full = 0`、`overlaps = 0`、`push_failures = 0`） |

**默认行为不变**（硬要求，回归口径）：`pool_threads` 不写 = 1，既有池化测试（Phase 1 的全部
`Runtime: ...pooled...` 用例、`Actor:` 的两条停机语义用例、`zigmodu_runtime_pool_*` 的取值断言）
一行未改、读数未变；宽度是新增的声明，不是既有声明的语义变化。

**Phase 2 仍未做（§12.16 之后重述）**：公平性加权、优先级、affinity/NUMA（§12.7 本来就排除）、
以及"池线程数随负载自适应"。**`batch` 的实测调优已不在这一行** —— §12.16 用 6 个点 × 3 种形状实测过，
结论是**保持 16**（per-worker 覆盖仍然没有，那需要 per-worker 声明，属于加权/优先级那一档）。
另外一条已知的**取舍**（不是缺陷）：上面第 4 点的 1 ms 偷取延迟。

### 12.15 `PrecisionTimer` 的界是**宿主的**，不是机制的（v0.33.6；CI 红过一次）

`zigmodu.runtime.PrecisionTimer` 的 `lateness_p50_bound_ns = 10 µs` 此前被直接当作断言，
在 GitHub 的 macOS runner 上红了两条用例。实测原因不是循环写错，而是**那台宿主机的
`nanosleep` 粒度比自旋窗口还粗**：

| 宿主 | `nanosleep(100 µs)` 的实际迟到 | `nanosleep(500 µs)` | 交付的 `default` 配置 p50 @1 ms |
|------|------|------|------|
| 本仓开发机（Apple Silicon macOS） | ~55 µs | ~257 µs | **0 ns** |
| GitHub `macos-latest` runner | **+818 µs** | **+4 031 µs** | **+3 531 000 ns** |

机制本身没变：等待循环睡的是 `remaining - spin_window_ns`，只有这次唤醒**落在窗口内**，
自旋才有 deadline 可收口；一旦内核把唤醒推过 deadline，剩下的就全是宿主的账。所以：

* 绝对界只在**宿主测得可交付**时断言 —— 判据是运行期探针
  （`hostCanHoldTheBound`：用出厂 knobs 打一个 1 ms deadline，读 p50），不是常量、不是平台判断；
* 过粗的宿主上改断言**可移植的那条**："出厂 knobs 不比把整段等待交给内核更差"，
  并把探针读数与 sleep-only 行**打印出来**（红与归因都带证据）；
* 100 µs 那一行是**纯自旋**（deadline 落在窗口内 → 一次都不睡），所以它在任何宿主上都断言绝对界 ——
  机制不会因为宿主粗就完全没有证明；
* 粗宿主上的正解是**调大 `spin_window_ns`**（或 `= 0` 表示不要这个精度），而不是把界放松。

**这条对消费方的含义**：`PrecisionTimer` 出厂的两个 knob 是按本仓开发机的过冲梯子定的。
把它搬进容器/共享 runner/云主机时，先读一次 `src/runtime/precision_timer.zig` 里那份
harness 表格（每个用例都会打印 min/p50/p99/max 与 spun 占比），再决定窗口；
`Runtime` 的 5 ms 时间轮（§3）不受这条影响。

### 12.16 公平性与 `batch`：实测（v0.33.6；D3 的"16 是起点"到此收口）

> 状态：**测量已落地**，两条测试都在 `src/runtime/runtime.zig`
> （`Pooled (§12.16): a continuously busy worker starves nobody …` 与
> `Pooled (§12.16): the batch sweep …`）。这一节里被**断言**钉住的只有"等待用对方跑过多少条
> 消息"（表 1）—— 它与宿主速度无关；时间列（µs / msg/s）是**打印出来的读数，不是门禁**，
> 原因与 §12.15 同一条（绝对延迟界在共享 runner 上不成立）。每条消息的延迟由**生产者打时间戳、
> handler 自己读表**得到，所以测试线程被调度器挂起不会污染它（§12.12 上面那条老测试栽的正是这个）。

**1. 公平性：不是"没有饿死"，而是"等待 = 一个 batch"，而且这个界每次都被兑现**

形状：**一个**池线程、三个 pooled worker。A 由一个生产者线程不停灌（邮箱满就重试，所以
A 的邮箱永远非空、A 永远不跑干）；B、C 各只偶尔来一条，一条一条地来（每通道 3 000 条）。
A 的邮箱 256 槽、B/C 的 8 槽，`batch` 取默认 16，`pool_threads = 1`（不这样 A/B/C 就不争执行权，
"饿不饿死"也就无从谈起）。

**被断言的是表 1 —— 一条探针在等待期间，A 跑过了多少条消息**：

| 10 次独立运行（每次 2 × 3 000 条探针） | B 的等待 p50 / max | C 的等待 p50 / max | A 在同一区间跑过 |
|---|---|---|---|
| 1 | 15 / **16** | 15 / **16** | 96 288 |
| 2 – 9 | 11 – 15 / **16** | 12 – 15 / **16** | 96 405 – 98 032 |
| 10（同机重载，见下） | 13 / **16** | 15 / **16** | 101 983 |

**10 次运行 × 2 条通道 × 3 000 条探针，max 全部恰好 = 16**，而 A 在同一区间跑了约 **9.6 万条**。
`batch = 16`，所以这不是"看起来有界"，而是**设计自己预言的那个界被逐次兑现**：环是 FIFO、
每个 worker 至多一个 token、一批跑完必须交回 —— 一个永远忙的 worker 的最坏耽误就是一个 batch。

同一批运行的入队→处理延迟（µs，p50 / p99 / max）：

| 10 次运行 | A（忙，96k–102k 条） | B（探针，3 000 条） | C（探针，3 000 条） |
|---|---|---|---|
| 9 次正常 | 52 – 70 / 166 – 190 / 1 058 – 1 343 | 3 – 8 / 10 – 11 / 22 – 162 | 3 – 9 / 10 – 12 / 11 – 1 176 |
| 1 次重载 | 140 / 2 172 / 5 562 | 6 / 48 / 5 183 | 8 / 36 / 2 274 |

**重载那次是这一节最有用的一条**：同机另有 agent 在编译，生产者撞满邮箱的重试次数从 ~9 万涨到
**676 040**（7.5×），B 的 max 从 22 µs 变成 **5 183 µs**（时钟上差 236 倍）——**而表 1 的 max
仍然是 16**。宿主把微秒搅成什么样都动不了那句"最多等一个 batch"，这正是把界钉在消息数上的意义。

`RuntimeStats` / `poolStats()` 侧的读数（10 次运行）：`dispatches` 12 039 – 12 631、
**`claim_misses` 0**（宽度 1 下它是缺陷信号，§12.12）、`ready_len` 收尾 0、`ready_high_water` 2、
`idle_waits` 2 – 30、**`ready_push_failures` 0**、`claimed` 收尾 0、`pool_threads` 1；
`messages_sent == messages_received`（102 609 – 108 303），`messages_dropped` = 生产者撞满邮箱的
重试次数（81 299 – 676 040，**是背压不是丢失**：重试后每条都进去了）。

**断言选 `4 × batch = 64`，三条理由**：

1. 机制的**最坏**形状是两个 batch（探针到达时 A 手里正握着一个 claim，探针的 token 又可能排在
   A 的重新入环之后），实测恰好停在 1 个 batch；
2. 参考点取在"`send` 之后、A 的下一条消息上"，所以这个读数是**下限**（被立即服务的探针记 0），
   2 倍余量捕的是"参考窗口藏起来的那一部分"；
3. 它比"无界"小三到四个数量级 —— 同一区间 A 跑了 9.6 万条，所以 64 不是一个套话式的界。

**为什么这个界在共享 CI runner 上也成立**：它量的是**消息数**，不是时钟。宿主变慢只会把表 2 的
微秒数放大，动不了表 1 —— 环、token、batch 都不是宿主属性。这正是 §12.15 的做法在这里的
翻版：能跨宿主的那条拿去断言，宿主相关的那条打印出来。

**它有牙齿（红证据）**：把该测试的池配置临时改成 `.batch = 65536`（其余一行未改），读数爆炸、
断言红（原文）：

```
[§12.16 fairness]   A handled 489785 messages during the probes …（A 的样本缓冲溢出 89 856 条）
[§12.16 fairness]   B (probe)   n=3000    p50=      22.0us p99=   11286.0us max=   15500.0us
[§12.16 fairness]   C (probe)   n=3000    p50=       9.0us p99=     621.0us max=    2718.0us
[§12.16 fairness]   A's messages that ran while a probe waited: B p50=132 max=53118, C p50=55 max=8768
FAIL (TestUnexpectedResult)          ← expect(b_ran_max <= 64)
```

于是 `batch` 的身份也清楚了：它不是"一个顺带影响公平的吞吐旋钮"，**它就是公平本身** ——
16 的时候探针等 16 条（p99 11 µs），65 536 的时候等 53 118 条（p99 11 286 µs）。

**2. `batch` 扫描：6 个点 × 3 种形状 × 每点 27 轮**

每点每轮重新起 `Runtime`、线程与邮箱；msg/s 从生产者等待的**闸门**量到最后一条被处理
（不含线程创建）。**每点 27 轮 = 9 次独立运行 × 3 轮**（跑的时候同机有其他 agent 在编译/测试，
下面每张表的"运行中位数散布"就是为此而列；`min` 一列里带 \* 的是被别的编译撞出来的那一轮）。
三种形状各管一个问题：

* `saturated`：1 worker / 2 producer / **1 池线程** / 24 000 条 —— 池永远追不上邮箱，
  量的是**每条消息的派发成本**（大 batch 该买到的东西）；
* `mixed-busy`：4 / 4 / **1 池线程** / 16 000 条 —— 池线程吃满、几乎不 park，
  量的是**大 batch 花掉的东西**（别的 worker 的等待）；
* `mixed-x2`：4 / 4 / **2 池线程** / 16 000 条 —— 消费者够快，环常常空，
  量的是**尾巴**（下面第 3 点）。

`saturated`（延迟列是 27 轮的中位数）：

| batch | msg/s min / median / max | 运行中位数散布（9 次运行） | p50 | p99 | max | parks |
|---|---|---|---|---|---|---|
| 1 | 1.05M / **1.64M** / 2.59M | 1.46 – 2.56M (1.8×) | 23 µs | 63 µs | 1 154 µs | 27/27 |
| 4 | 1.52M / 2.16M / 3.27M | 1.54 – 3.24M (2.1×) | 33 µs | 54 µs | 1 136 µs | 27/27 |
| 8 | 1.49M / 2.63M / 3.75M | 1.61 – 3.46M (2.2×) | 15 µs | 49 µs | 1 141 µs | 27/27 |
| **16** | 1.51M / 2.30M / 3.72M | 1.63 – 3.44M (2.1×) | 15 µs | 46 µs | 1 142 µs | 27/27 |
| 32 | 0.48M\* / 2.10M / 3.49M | 1.38 – 3.31M (2.4×) | 33 µs | 49 µs | 1 138 µs | 27/27 |
| 64 | 1.66M / 2.33M / 3.63M | 1.72 – 3.37M (2.0×) | 17 µs | 50 µs | 1 136 µs | 27/27 |

`mixed-busy`：

| batch | msg/s min / median / max | 运行中位数散布（9 次运行） | p50 | p99 | max | parks |
|---|---|---|---|---|---|---|
| 1 | 1.14M / **1.48M** / 2.04M | 1.24 – 1.87M (1.5×) | 146 µs | 1 003 µs | 1 096 µs | 27/27 |
| 4 | 1.31M / 1.75M / 2.40M | 1.38 – 2.07M (1.5×) | 120 µs | 983 µs | 1 042 µs | 27/27 |
| 8 | 1.44M / 2.49M / 3.51M | 2.09 – 3.12M (1.5×) | 84 µs | 966 µs | 1 004 µs | 27/27 |
| **16** | 1.18M / 3.22M / 3.70M | 2.33 – 3.53M (1.5×) | 59 µs | 966 µs | 994 µs | 27/27 |
| 32 | 2.52M / 3.71M / 4.52M | 3.00 – 4.05M (1.4×) | 44 µs | 960 µs | 985 µs | 27/27 |
| 64 | 2.29M / 3.50M / 4.23M | 3.09 – 3.76M (1.2×) | 40 µs | 940 µs | 967 µs | 27/27 |

`mixed-x2`：

| batch | msg/s min / median / max | 运行中位数散布（9 次运行） | p50 | p99 | max | parks |
|---|---|---|---|---|---|---|
| 1 | 0.85M\* / **1.60M** / 2.24M | 1.51 – 1.79M (1.2×) | 5 µs | 982 µs | 1 051 µs | 27/27 |
| 4 | 1.82M / 2.63M / 3.47M | 2.00 – 2.83M (1.4×) | 57 µs | 972 µs | 1 010 µs | 27/27 |
| 8 | 1.95M / 3.20M / 4.53M | 2.29 – 4.28M (1.9×) | 6 µs | 956 µs | 976 µs | 27/27 |
| **16** | 2.25M / 3.75M / 4.78M | 2.42 – 4.60M (1.9×) | 10 µs | 947 µs | 964 µs | 27/27 |
| 32 | 2.09M / 3.96M / 4.77M | 2.85 – 4.67M (1.6×) | 7 µs | 950 µs | 969 µs | 27/27 |
| 64 | 1.71M / 3.53M / 4.59M | 2.70 – 4.19M (1.6×) | 19 µs | 952 µs | 974 µs | 27/27 |

\* 被别的编译撞出来的那一轮：`saturated` / `batch=32` 的 min 只有 0.48M；同一点另外 26 轮都在
1.38M–3.49M，`mixed-x2` / `batch=1` 的 0.85M 同理。

**3. 尾巴不是 `batch`，是 park**

三张表里 **p99/max 在每一个点、每一个形状上都是 ~1 ms**，而 `parks` 每轮都 ≥ 1 —— 两件事是
同一件事：`poolMain` 的 park 是**轮询**（`idle_wait_ms = 1`，为了不给生产者路径加 mutex/信号），
所以池空闲期间到达的消息最多要等一个轮询周期。一次 park 的代价不是"一条消息晚 1 ms"：这段时间里
每个 pooled worker 的邮箱都能攒满（4 × 64 = 256 条），所以一次 park 就让整轮约 1% 的消息落在
p99 ≈ 1 ms 上（`mixed-x2` 正好是 `p99 = 947 µs` 而 `p50 = 10 µs` 的形状）。

**这条对调优的含义**：想让池化 worker 的 p99 好看，要看的是 `idle_wait_ms` 这条取舍，不是 `batch`
——把 `batch` 从 1 调到 64，p99 一点没动。反过来，`p50` 随 `batch` 上升而下降完全不是"batch 变便宜了"，
而是**吞吐上去以后队列变短**（同一张表里 msg/s 与 p50 反向）。

**结论（一句话）：默认保持 `batch = 16`。** 依据是这组读数：

* **1 是唯一被数据否掉的默认值**：`mixed-busy` 的 `p50` 在所有点里最高（146 µs，且随 `batch`
  单调降到 40 µs），吞吐只有 16 的 46%；`saturated` 里它同样是吞吐最低、`p50` 最高
  （23 µs，而 8/16/64 是 15–17 µs）；`mixed-x2` 里它也是吞吐最低的一点；
* **8 以上是同一片平台**：三形状中位数的平均 16 → 3.09M、32 → 3.26M、64 → 3.12M，
  即 32 只比 16 高 **5%**；而**每次运行自己的中位数散布是 1.2×–2.4×**（±25%–40%），
  同一片平台上的点与点差别全在噪声带之内；
* **唯一反例要说清楚**：`mixed-busy`（池被吃满的那种形状）32 比 16 高 **15%**（3.22M → 3.71M），
  但两者的**运行中位数区间仍然重叠**（16: 2.33–3.53M，32: 3.00–4.05M），这个样本量切不开它；
* 平台既然平，就取平台上**最小**的一点：`batch` 是公平上界（第 1 点实测：探针恰好等一个 batch，
  每次运行的 6 000 次探针一次不差），加倍它买到的是**确定的**代价（对端最坏等待 16 → 32 条）与
  **测不出**的收益。

延迟敏感的池化 worker 仍按 §12.12 的办法单独设小：`batch = 1` 在 `mixed-busy` 里 p50 146 µs、
吞吐 1.48M/s，两个数字都说明它只适合"这一条真的不能等"的 worker。

**这说明了什么**

* 一条永远忙的 worker 饿不死别人，而且"不饿死"有**可复现的上界**：刚好一个 batch ——
  10 次运行、20 次通道运行、共 60 000 次探针一次不差（第 1 点）；`batch` 一改，上界跟着改（红证据）；
* D3 的"16 是先验起点，不是定论"现在有读数了，结论是**这个先验站得住**：平台从 8 起就平，
  16 在平台上，且是平台上最小的一点（第 2 点）；
* `batch` 的兜底代价不在吞吐上而在别人身上，所以默认值应当取平台的**下端**；
* 池化 worker 的延迟尾巴归 `idle_wait_ms` 的 park 所有，与 `batch` 无关（第 3 点）。

**没说明什么**

* 时间列（msg/s、µs）是**本机在这段时间的读数**：跑的时候同机有其他 agent 的编译/测试，
  所以运行间散布最大 2.4×（`batch=32`/`saturated` 甚至撞出过 0.48M 的一轮）。
  跨宿主引用前先重跑，别把这里的 µs 当承诺；`parks`、`claim_misses`、`ready_len` 这类**计数**
  不受影响。
* 因此这一节的结论只到"**不改变默认值**"这一步：数据量不足以在 8 / 16 / 32 之间挑一个更优的默认
  （5%–15% 的差距坐落在 25%–40% 的噪声里）。要真挑，就得换一台安静的机器或加长每点轮数。
* 没有测"消息真需要 CPU"的形状（这里 handler 极短），所以**不能**说"16 也适合重 handler" ——
  那种形状量的是 `pool_threads`（§12.12 已经量过），不是 `batch`。
* 只测了 `.cpu` 池：阻塞池（§6）共用同一套协议与默认值，但没在这里单独量过。
* 生产者是**自旋重试**满邮箱的（背压只重试、不丢），所以生产者本身吃一个核；换成 `sendBlocking`
  的形状（生产者睡着）会同时改变吞吐与 park 频率，那是另一组读数。
* 没有动公平性机制：`queued`/`claimed`、FIFO 环、一个 worker 一个 token 一条未改，也没有加
  加权或优先级（§12.7 本来就排除）。这一节只回答"会不会饿死"和"`batch` 该取多少"。

## 13. Runtime Replay —— v1 已实现（见 §13.7）

> 状态：**13.1–13.5 是设计草案（决策记录，原样保留）；13.6 的三个待定项已定；13.7 记 v1 落地形状**。
> 代码在 `src/runtime/recorder.zig`（`Track` / `DeliveryLog` / `Replayer`）+ `src/runtime/runtime.zig`
> （`.record` 声明、`Handle` 投递漏斗、`Runtime.deliveryLog()`）。
>
> §11 的 EventRecorder 记的是 **L0 扇出**（`HotBus.publish` 之前）；本节做的是**投递流**——
> "每个 worker 实际收到了什么"。**这是两个不同的问题，不是同一个 log 的两个视图。**

### 13.1 先说清和 §11 的分工（不搞清必然做错）

同一个 `send` 会被两种视角看见，**不要记两遍**：

| log | 取点 | 回答的问题 |
|-----|------|-----------|
| §11 `Recorder(E)` | `HotBus.publish`，**扇出之前** | "**生产者发布了什么**" —— L0 流的完整序列 |
| 本节 · 投递轨 | `Handle.send*` | "**每个 worker 收到了什么**" —— L0 扇出的落点、直达 send、定时器投递 |

为什么投递必须记在 `Handle.send*` 而不是 `publish`：**定时器投递根本不经过 `publish`**
（`after` → `TimerCommand` → ticker → `Delivery.post` → `handle.send`），而它在流水线里往往是
关键节拍（快照、结算、超时）。只记 `publish` 的 log **重放不出定时器驱动的那一半**。
反过来 `publish` 在扇出**之前**，记它会漏掉"某订阅者满了被丢"——而那恰好是投递轨能看见的。

### 13.2 真正的障碍，以及为什么它其实不是障碍

"记录任意 worker 的消息"看着要先解决 **异构 `Message` 类型**（每个 worker 的 `Message` 不同），
于是自然想到"定义一套序列化/编码协议"。**那条路很大，而且 §11 已经用过一个更好的招**：

`Recorder(E)` 之所以零分配、无需序列化，是因为它是 **`E` 的单类型有界环、值放进去**。
把它推广到异构的办法不是加编码，而是**每 worker 一条同类型轨**：

```
Runtime
 ├── worker A → Recorder(A.Message, capA)   ← 各轨内部同类型，值语义
 ├── worker B → Recorder(B.Message, capB)
 └── worker C → Recorder(C.Message, capC)
                     │
         共享一个 Sequencer 给所有轨的 entry 打全局序号
                     │
         重放时按全局 seq 归并多条轨
```

**每条轨内部同类型 ⇒ 仍然零分配、仍然值语义、仍然不需要任何 codec。**
代价是内存变成 `Σ(capacity × sizeof(Message))` —— 这是**有界的、可声明的、且必须显式开启**的，
与 §12 的池"默认不创建"同一条纪律。

### 13.3 四个契约问题

**Q1 记哪些 worker？** 显式声明（spawn 点选 `record = .{ .capacity = N }`），**不做"默认全记"**——
它会把内存从"声明多少"变成"有多少 worker"。未声明的 worker 不产生轨，它收到的消息在重放里
**不存在**；这一点必须写进文档，否则重放结果会被误当成"完整"。

**Q2 顺序怎么定义？** 与 §11 同解：取点处 `Sequencer.next()` 打全局序号，**归并后的 seq 顺序
就是重放顺序**。边界照旧诚实——这是取点处的**某一个**合法交错，不是"时间倒流"。

**Q3 重放时怎么投回原 worker？** 需要一个 **worker 稳定标识**，而 `*Handle` 是运行时概念
（每次 spawn 都不同）。所以 entry 记的是**声明时的稳定标识**（调用方给出，如模块名 + 序号），
重放时由调用方提供"标识 → 新 handle"的映射。**运行时不该猜**——猜就会做出一个只在
"spawn 顺序完全一致"时才成立的重放。

**Q4 存哪里？** 两档，**v1 只做第一档**：
1. **内存有界轨**（本节）—— 够单测、短事故窗口、以及 §13.4 的目标。
2. **落盘 / 跨进程** —— 必须先有一个 **`Message` codec 契约**（encode/decode + 版本号）。
   不做在 v1 里；但 entry 的形状要**预留"这条轨的 codec 是谁"的位置**，否则将来接 codec 时接口会翻。
   > **进展（v0.33.6）**：这一档的**存储层已落地** —— `src/runtime/delivery_log.zig`（magic +
   > 显式版本 + 每帧 CRC32 + 撕裂尾部可判可修 + 分段轮转 + append 零分配，12 条测试；**尚未**
   > 从 `runtime.zig`/`root.zig` 导出，因为还没有消费者）。它**只存字节**：把一条投递记录变成字节
   > 的那个 codec 契约，以及 recorder 侧的接线（`TrackRef.payload_codec` 那个预留位）**仍未做**。
   > 所以现在既不能说"可以落盘重放了"，也不能说这一档没动 —— 准确说法是：**盘上那一半有了，进盘那一半没有**。

### 13.4 v1 的目标（可验收）

不是"完整重放整个进程"，而是：

> **给定一套相同的 worker 图与一个录下来的投递轨，重放出与录制时相同的 handler 调用序列
> （同样的顺序、同样的载荷），且不 sleep。**

"同样的顺序 + 同样的载荷"是**可以断言**的（把 handler 的入参压成一个可比对的指纹即可，
连载荷都不必真的可重放）。这比"重放整个系统"小得多，但它正是调试一次线上事故要的东西。

### 13.5 明确不做

- 不做 `Message` 的通用 codec / 序列化协议（Q4 第 2 档，需要独立契约）
- 不做跨进程 / 跨节点重放（§12.7 已排除）
- 不承诺进程级确定性：`spawn`/`init` 副作用、网络、墙钟、以及**丢弃模式**都不重放
  （丢不丢是时序的函数；重放的是**投递成功的那部分**）
- 不替代 §11 的 L0 log —— 两者并存，回答不同的问题

### 13.6 待定 → **已定（v1 按此实现）**

1. **轨的内存上界怎么声明**：**per-worker `.record = .{ .capacity = N }`，在 spawn 点显式声明**。
   与 §12 的池"默认不创建"同一条纪律：**不做"默认全记"** —— 那会把内存从"声明了多少"变成
   "有多少 worker"，而生产里 worker 数是数据维数。未声明的 worker 没有轨（它的投递在重放里不存在，
   见 §13.7 的边界）。
2. **worker 稳定标识由谁给**：**调用方显式传**（`.record = .{ .id = "book:BTC", … }`），
   **不从 `ModuleContext` 的模块名派生** —— 派生会做出一个"模块名唯一"的隐含假设，而标识的作用正是
   把"spawn 顺序/模块命名"排除在重放语义之外（§13.3 Q3）。同一个 log 里 id 重复 = 声明错误（拒绝），
   不合并：两份轨共用一个人份身份会把一个 worker 的投递拆成两条流。
3. **重放的驱动方式**：**`step()` 为主 + `replayAll()` 附带**。§13.4 的验收必须能逐步断言
   （每步给出 `seq` / `clock_ms` / `id`，并把载荷投给绑定好的 handle），`replayAll()` 只是同一个循环。

### 13.7 v1 已实现（`src/runtime/recorder.zig` + `.record` 声明）

```zig
// 声明（spawn 点）：每个 worker 一条轨，容量是显式的内存上界
const book = try rt.spawn(Book, .{}, .{
    .capacity = 256,
    .record = .{ .id = "book:BTC", .capacity = 4096 },
});

// …运行…（`send*`、`HotBus` 扇出的落点、`after(...)` 的定时器投递都进这条轨）

// 重放：按全局 seq 归并多条轨、驱动 Clock.Manual、由调用方给"标识 → 新 handle"的映射
const log = rt.deliveryLog() orelse return;          // 没有任何 worker 声明过轨
var manual = runtime.Clock.Manual{ .now_ms = 0 };    // 必须非负（轮用时间算槽位）
var rp = log.replayer(&manual);
try rp.bind("book:BTC", fresh_book);                 // 目标不能就在这条 log 里（见下）
while (try rp.step()) |step| {                       // step.id / step.seq / step.clock_ms
    // step 已经把载荷投给 fresh_book 了；这里只做断言/记录
}
// rp.replayAll() 是同一个循环，只返回投出去的条数
```

**取点：`Handle` 的投递漏斗**（`src/runtime/runtime.zig` 的 `enqueue` / `enqueueBlocking`）。
`send*` 与 `Handle.after` 的定时器投递**都**走它 —— 只挂 `send*` 会漏掉定时器那一半
（`Delivery.post` 直接写邮箱），而 §13.1 说的正是那一半。记录发生在**邮箱接受之后**：
轨记的是"投递成功的那部分"（§13.5），`error.Full` / `error.Closed` 不产生条目。

**零分配按契约保持**：`Handle.track` 是个 `?*TrackRef`，没声明就一次空判断；
有声明时是"一次间接调用 + 把值拷进预分配环"。`src/runtime/alloc_contract_test.zig` 对
`Handle.send*` 的**精确**分配次数断言一个数字都没改（仍是 0）。

**顺序**：全局 `seq` 由 log 的**一个** `Sequencer` 发放，entry 的 `seq` 是全局的，
而槽位由**每条轨自己的**计数器声明（`slot` 本地、`seq` 全局）。轨道之间没有别的排序依据。

**溢出 / 不完整**：`Track.record` 满环返回 `error.Full` —— **不覆盖、不静默丢弃**。
但 `send*` **不因此失败**（消息确实进了邮箱）：`DeliveryLog.refused` 计数 + 一条 warn 日志；
`Replayer` 看到 log 有洞时 `step()` / `replayAll()` 直接返回 `error.LogIncomplete`，
**连部分也不放**（"有洞的 log 看起来完整"是 §11.6 起就写死的禁忌）。

**与草案的差异**

| 草案 | 落地 | 为什么 |
|------|------|--------|
| "复用 `Recorder(W.Message, capacity)` 那套机制" | `Recorder` 的存储半边抽成 `Slots`（`capacity` 槽 + per-slot ready + 连续 published 前缀），`Recorder` 与 `Track` 共用；`Recorder` 的 slot == seq 语义一字未动 | 两条轨的差别只在"槽位从哪来"，把它留在环外，环就只剩一份 |
| 取点写 `Handle.send*` | `Handle` 的漏斗 `enqueue`/`enqueueBlocking`（`send*` + 定时器投递） | 见上：定时器投递不经过 `send*`，只挂 `send*` 就漏掉 §13.1 要的那半 |
| `Runtime.enableRecording(cfg)` 式全局开关 | spawn 点 `.record = …` + `Runtime.deliveryLog()`（**懒创建**：首个 `.record` spawn 才分配） | §13.6 · 1：按声明计的内存；没声明就没有 log、没有环 |
| `(seq, clock_ms, target, kind, len)` + 载荷字节 | `Entry{ seq, clock_ms, event }`（值拷贝，零分配）+ 轨自己的 `id`/`message_type` | v1 不引入 codec：轨内部同类型，payload 就是那个值 |
| 落盘（Q4 第 2 档） | **未做**。`TrackRef.payload_codec` 是预留位，v1 恒为 `null`；`bind` 会拒绝声明了 codec 的轨 | 接口不翻：接 codec 时"载荷是指针"这件事本来就要变，让它在同一个判据上暴露 |

**新增的一条拒绝（草案没有，实现时发现的）**：`bind` 拒绝**目标就在被重放的那条 log 里**
（`error.TargetIsInSourceLog`）。把轨重放回**它自己那个 worker** 会把每条重放投递再记一遍，
而新条目落在游标**之后** → 下一步 `step()` 又取到它们 → 自我喂养、`replayAll()` 永不结束
（这是实现时被测试撞出来的，不是理论）。要重放就绑一份**没有在记这条 log** 的新图；
把它重放到**另一个 runtime 上记过的 worker** 也可以 —— 那是两份 log，互不干扰。

**明确未做（v1 边界，写死）**

- **未声明的 worker 没有轨**：它收到的消息在重放里不存在。所以"重放是完整的"只对**声明过的那一刻
  的 worker 图**成立；这条必须由调用方记住（轨自己不知道有谁没被声明）。
- **取点处的一个合法交错**：`seq` 是记录点的原子序号，不等于"某次被观察到的真实顺序"。
  同一个 worker 上**并发生产者**之间的相对顺序，重放按 log 的 `seq` 走 —— 重放是确定性的，
  但不是"时间倒流"（§13.3 Q2）。
- **不重放调度**：`after(...)` 的消息在轨里（handler 会收到），但**定时器本身不重放** ——
  重放里没有 ticker，也不 sleep；重放推动的是 `Clock.Manual`，handler 若自己再 `after(...)`
  就是新的一次排程（那是应用的事）。
- **只有读注入 clock 的代码参与重放**：`ctx.clock()` 看到的是被驱动的那个 Manual 时钟；
  直接调 `core/Time.zig` 的路径读到真实时间，在重放里就是不参与（§11.6 的同一条边界）。
- **不承诺进程级确定性**：`spawn`/`init` 副作用、网络、墙钟、丢弃模式都不重放。
- **不做跨进程**（§12.7）、**不做 `Message` codec**（§13.5）。
- **不新增指标**：拒绝计数在 `DeliveryLog.refusedCount()`（+ 一条 warn 日志）和
  `Replayer` 的 `error.LogIncomplete` 上，**没有**进 `RuntimeStats` / `MetricsBridge` ——
  记录的 opt-in 边界是"声明了多少条轨"，而指标面的每一次新增都要连带
  `docs/OBSERVABILITY.md` 的清单，不在本次范围。要看这个数就读 log。

**验收（§13.4 的那条断言，已测）**：`src/runtime/runtime.zig` 的
`Runtime Replay (§13.4): a delivery track replays into the same handler sequence, without sleeping` ——
两个不同 `Message` 类型（两轨、一个共享 seq），中间夹一条 `after(...)` 的定时器投递；
录制与重放两次的 handler 调用序列（顺序 + 载荷指纹 + handler 读到的时钟）逐条一致，
且 20_000_000 ms（≈5.5 小时）的录制跨度在 **< 1 s 墙钟**内重放完（不 sleep）。
轨/日志/溢出/并发的单测在 `src/runtime/recorder.zig`，绑定与错误路径在 `runtime.zig`。

## 14. 监督树 —— 组、策略、强度（v0.31 契约）

### 14.1 §3b 的监督是自我监督，缺两件东西

`Supervision{ strategy, max_errors, window_ms }` 是**一个 actor 数自己的错、自己决定停不停**。
它补上了"安静烧核"这个洞，但它有两个结构性问题：

1. **停掉是终态，没有下文。** actor 不会再回来，`one_for_one` 那种"这个成员重来一次、
   其余照常"根本表达不了。
2. **"这个 actor 死了"在指标面上不存在。** `WorkerStats.stopped_by_supervisor` 只有
   **轮询者**看得见：没有 `RuntimeStats` 聚合，没有 Prometheus 指标。§3b 说预算是为了
   把"烧核"变成"停止 + 一条 warn + **计数**"——计数在 per-worker 上就到头了，出不了进程。

本节补这两件：**停掉之后有人接手**，以及**停掉这件事可见**。

### 14.2 被否掉的形状：用户 actor 当父

OTP 的 supervisor 是"父进程决定子进程"。照搬会撞上一个具体障碍：

> **父的邮箱由父自己的 `Message` 类型决定，而 runtime 无法合成任意用户 enum 的一个变体。**

三条绕法都不好：强制用户为每种 `Message` 加一个"监督通知"变体（污染业务类型、不组合）；
让失败的孩子**阻塞**等父裁决（错误路径上一次往返，且孩子此时正持有自己的状态）；
让 runtime 自己持一条通知通道（父只在自己的线程上跑，那就得轮询）。

**采用的形状**：组的协调者是 **runtime 自己**，不是用户 actor。这不是简化 ——
OTP 的 supervisor 本身也不跑用户代码。去掉的只是"为一个不跑用户代码的东西
再写一个用户类型"这份样板。

### 14.3 契约：组、策略、强度

```zig
// 建组：策略是 comptime，强度是运行期值
const book_group = try rt.spawnGroup(.one_for_all);
book_group.setIntensity(.{ .max_restarts = 3, .window_ms = 60_000 });

// 入组：spawn 的签名一字未改，组进 `Supervision`
const feed = try rt.spawnActor(Feed, .{}, 64, .{ .group = book_group });
const book = try rt.spawnActor(Book, .{}, 64, .{ .group = book_group });
```

**策略**（用 OTP 的词，刻意不叫 `restart` —— 那个词在 `Supervision.Strategy` 里已经被
"记日志、接着服务"占了，同一份配置里两个 `restart` 会读出两种意思）：

| 策略 | 成员的失败（自己那层已经决定要停）之后 |
|------|--------------------------------------|
| `.one_for_one` | 只重启**它自己**；同组其余不动 |
| `.one_for_all` | 重启**组内每一个**成员 |
| `.rest_for_one` | 重启它**以及 spawn 在它之后**的成员（前面的不动） |
| `.stop_group` | 不重启：**停掉组内每一个** |

**强度**（`Intensity{ max_restarts, window_ms }`，默认 `{ 3, 60_000 }`）：
一个组在 `window_ms` 内最多**触发** `max_restarts` 次重启/连坐动作，超了就地降级为
`.stop_group` —— 组内全体停止、不再重启，并记一条 warn 与计数。理由和 §3b 的
错误预算完全一样：一个"起来就死"的成员若无限重启，只是把一个 CPU 黑洞换成了
一个**带日志的** CPU 黑洞，而且这回还多烧了反复 `init` 的代价。

> `max_restarts` 与 `max_errors` 是**两个**预算，因为它们是两件事：
> 前者数"这个成员被重建了几次"，后者数"这个成员在自己的一生里错了几次"。
> 合成一个数会让"错很多但每次都恢复到好状态"和"错三次就重建三次"读起来一样。

### 14.4 机制：谁执行 —— 仍然是"一个线程拥有状态"

没有新线程、没有跨线程改状态。执行者是**那个成员自己的线程**：

```
成员线程：W.handle 返回 error
      ↓
supervise()：错误记账（§3b 原样）
      ↓
自己那层要不要停？（strategy == .stop 或超出 max_errors）
      ├─ 不要 → 记日志、接着服务                （§3b 原样，一字未改）
      └─ 要  → 组动作（新增）
                 ├─ 无组            → 停自己                    （§3b 原样）
                 ├─ 有组、强度够    → 按策略（14.3 表）
                 └─ 有组、强度用尽  → 停组内全体 + warn + 计数
      ↓
"重启我"   = deinit(state) → startWorker() → 错误窗口清零 → 接着跑循环
"重启别人" = 对方 handle 的 restart_requested 置位；它**自己的线程**做拆+建
"停别人"   = 对方 handle 的 stop()（就是 §3b 已有的那个：置位 + 关邮箱）
```

三个要点：

- **重启是原地重建**：`deinit` → `init` 在**同一个线程、同一个循环**里发生。
  线程不退出、handle 不销毁、邮箱不关。因此 `spawn` 之后拿到 `*Handle(W, cap)` 的人
  在重启前后拿着的是**同一个** handle，`send` 的语义不变。
- **重启不动邮箱**：重建的是 `state`，不是队列。重启期间排队的消息由**新一代**处理。
  这是刻意的：邮箱是对外接口，关掉它会让生产者看到 `error.Closed` —— §5 说
  "丢弃必须可见"，但这里没有丢弃，只是换了一代。
- **重启只对"能自己重建"的成员成立**：声明 `run`（`W.run` 自持循环）的 worker
  **无法**被外部重启 —— 它的循环在 `W.run` 里面，runtime 插不进去，也读不到置位。
  往**会重启的组**里放这种成员是 `error.NotRestartable`（spawn 时报，不是静默降级）。
  `.stop_group` 的组不重启，因此接受 `run` 型成员。

**池化成员的差别**：`.pooled` 的成员没有自己的线程，`restart_requested` 在**下一次被
认领时**（`pooledDispatch` 开头，`started`/`startWorker` 本来就在那里）检查，
效果相同：那一代状态被拆掉、重新 `init`，然后继续接活。如果它当时邮箱是空的，
`Ready.pending` 会把这个置位**报成"有活儿"**（返回 1）—— 否则池会把它交回去且再也不认领，
请求就永远没人读（`pooledPending` 的注释里写着这条）。

**"读置位"这件事本身需要一个唤醒。** `stop_requested` 靠**关邮箱**把停在一个 `recv` 里的
成员叫醒；重启请求不能这么做（关邮箱正是它不想要的那个结果），而它又不是一条消息
（邮箱是**有类型**的，别的线程造不出这个类型的值）。所以 `Mailbox` 多了第三个
"接收者可以回来"的理由：`wake()` 把 `wake_epoch` 加一、广播 `not_empty`，接收者下一次
有机会就返回 null，由自己的循环去重读置位。

两条边界的顺序是**要紧的**：成员必须在**读置位之前**取 epoch，否则落在这两步之间的
`wake()` 会被一个过期的快照比掉、请求就丢了。普通 `recv` 在入口取当前 epoch，
因此它**永远不会**因为一次 `wake` 提前返回 —— 没有组的成员走的还是原来那条路。

**`restart_requested` 与 `stop_requested` 的关系**：两者都是"生产者视角的请求"，
都在**循环顶端 / 认领点**被看到 —— 也就是说，一个正在处理长消息的成员不会被打断
（和 `stop()` 今天的行为一致）。请求是**幂等**的；同时置位时 `stop` 赢
（正在死的东西不该再被建起来）。被真的停掉之前，一次"重启"必须把置位**清掉** ——
池化路径上漏掉这一步的后果不是"没重建"，是**每次失败重建两次**（下一次认领又读到它）；
这条是测试抓出来的。

### 14.5 树：组可以是组的成员

```zig
const cluster = try rt.spawnGroup(.one_for_one);
const backend = try rt.spawnGroup(.one_for_all);
try rt.nestGroup(cluster, backend);        // backend 整棵子树是 cluster 的一个成员
```

组的动作在**成员**上递归：worker 成员 → 置位；组成员 → 递归到它自己的成员。
升级（escalate）就是这条：**子组的强度用尽时，它不自己决定，而是把决定交给父组** ——
父组按**自己的**策略对这个子组施加动作（父 `one_for_one` = 只重建这棵子树，
父 `one_for_all` = 重建父组全体，父 `stop_group` = 停父组整棵子树）。
这就是 OTP 的形状：子 supervisor 放弃，父 supervisor 按自己的策略处理它。

**但 `.stop_group` 不升级。** 这是一条刻意的分界：强度用尽是**计划外**的失败
（"我们以为能恢复，结果不能"），那正是该问父组的情形；而 `.stop_group` 是**声明**
（"这些成员要么一起活着，要么一起死"）—— 调用方已经做了决定，把它再递上去
等于让父组的策略悄悄推翻这个声明。所以：

| 情形 | 子组的动作 | 是否升级 |
|------|-----------|---------|
| 强度用尽 | 停自己子树 | **是** —— 父组按自己的策略处理这棵子树；父组重建它时，子组的预算**一并清零**（"父把子树重建了"就是那棵子树 supervisor 的一次新生） |
| 策略是 `.stop_group` | 停自己子树 | 否 —— 声明即答案 |

没有父组时两者一样：停掉整棵子树，跑完。

**边的方向**：只有 `parent → child` 一条边（子组知道自己属于谁），动作沿成员表向下走。

**锁的次序**：每个组一把自旋锁，只护预算字段与成员表。升级是**先放开子组的锁再进父组**，
所以嵌套只可能按 `parent → child` 取得，不成环。

### 14.6 可见性：停掉与重启都进指标

`RuntimeStats` 新增两个累计量，`MetricsBridge` 各有一条 gauge：

| 字段 / 指标 | 含义 |
|-------------|------|
| `supervised_stops` / `zigmodu_runtime_supervised_stops` | 被监督停掉的成员数（成员自己决定停、连坐停、强度用尽整组停，都算） |
| `group_restarts` / `zigmodu_runtime_group_restarts` | 实际执行的**重建**次数，**按成员计**：一次 `one_for_all` 动作重建两个成员就是 2 |

两者都是**累计量**而不是"当前存活成员的求和"，理由和 `messages_discarded_on_stop`
一样（§8）：`shutdown` 会在同一趟里 join 并销毁成员，求和会回到 0 —— 而这两个数
恰恰是在**停机之后**最需要看的那两个。

### 14.7 明确不做（本节范围外）

- **不做跨进程 / 跨节点监督**：§12.7 的同一条边界；子进程的存活由 `systemd` / k8s 管
  （`docs/BEST_PRACTICES.md` §"进程可恢复"）。
- **不做"重启保留上一次的痕迹"以外的状态策略**：重建就是 `deinit` + `init`，
  没有"从快照恢复状态"这一档。要快照请在自己的 `init`/`deinit` 里做。
- **不做重启退避（backoff）**：强度用尽即整组停，不做指数退避的无限重试。
  要退避在 `init` 里睡（并接受它占着那个线程）。
- **不做成员级策略覆盖**：策略是**组**的属性，不按成员配。需要不同待遇就用不同的组。
- **不监督 panic**：`handle`/`run` 里的 panic 仍然 abort 进程（§3b 的既有边界）。
  进程级存活靠 supervisor（`docs/BEST_PRACTICES.md`）。

### 14.8 验收（已测）

策略算术、预算、升级、锁次序在 `src/runtime/supervisor.zig`（10 条，成员是探针，没有线程）——
那一层能证明"算得对"，证明不了"接得上"。接得上由 `src/runtime/runtime.zig` 的 7 条端到端钉住：

| 用例 | 它唯二能说的话 |
|------|--------------|
| `one_for_one rebuilds a dying actor in place and it keeps serving` | 重建真的发生了（`inits` 从 1 变 3）、handle 没换、`stopped_by_supervisor` 仍为 false |
| `without a group an actor stops where it stands, unchanged` | v0.16/v0.17 的行为一字未改（回归护栏） |
| `one_for_all reaches a healthy group-mate through its handle` | 一个**从未出错**的成员被重建了 —— 没有真 handle 就测不出来 |
| `spending the restart budget takes the group down, and it is counted` | 一组成员同时进 `supervised_stops`，而"被组带下去"与"自己决定停"是两个不同的置位 |
| `a run-owned worker is refused in a rebuilding group, accepted in stop_group` | 编译期接不住的那个接线错误在 spawn 时说出来，且失败不留残骸 |
| `a pooled member is rebuilt by its next claim` | `.pooled` 走的是同一套计数（拆+建在持认领的线程上） |
| `a nested group escalates to its parent, and the parent's policy decides`（§14.5） | 树真的接上了：子组预算用尽 → 父组的 `one_for_all` 落到**不在失败子树里**的成员上 |

**两条守卫都验过红**（不是"看着红"）：池化路径的重复重建、`nestGroup` 缺边，
各由对应用例在变异后变红；`Mailbox.wake` 的"落点丢弃"由 `mailbox.zig` 的
`wake unparks a receiver that had already blocked` 钉住（读置位之前取 epoch 的那条次序）。

### 13.8 v1 的定位与筛选（`Replayer.open` / `onlyTracks`）

§13.7 的 v1 只能整份重放。缺口矩阵 §7 要的 `--from-seq/--to-seq` 现在在 API 上（没有 CLI 包装）：

```zig
var rp = log.replayer(&manual);
try rp.open(100_000, 120_000);      // [from, to)：from 含、to 不含
try rp.onlyTracks(&.{"book"});      // 只投递这些轨；不再需要时 clearTrackFilter()
try rp.bind("book", book_handle);
_ = try rp.replayAll();
_ = rp.skipped();                   // 被跳过的总数（下面三项之和）
```

**五条语义，都是决策而非实现细节**：

| 决策 | 选择 | 理由 |
|------|------|------|
| 区间端点 | `[from, to)`；`from >= to` = 空窗（不是错误） | 半开是唯一能让"从 100 开始、到 120 结束"不重不漏的说法 |
| `from` 之前 | **跳过并计入** `skippedBefore` | 它进了游标又被丢弃，必须留痕（§13.5 那条"不得静默丢"） |
| `to` 及之后 | **根本不走进度、不计任何数** | 那不是"被筛掉"，是调用方压根没要；算成跳过会污染那个计数 |
| 被筛掉的轨 | **前进游标 + 计入** `skippedUnselected`（不是不计数、也不是报错） | 单线程归并驱动无法"不前进却越过"，而"读了但没投递"必须看得见 |
| 空 `onlyTracks(&.{})` | **什么都不选**，全部计入 `skippedUnselected`（可见） | "筛得一个不剩"和"筛坏了"必须区分得开；回到全部用 `clearTrackFilter()` |

**未被选中的轨不需要 `bind`**，`isFullyBound()` 相应只看选中轨；但**被选中的**未绑定轨仍然报
`error.UnboundTrack`（筛选只缩小检查范围，不取消检查）。**轨 id 拼错 = `error.UnknownTrack`**，
不是"筛掉一切却看着像故意的"。

**计数恒等式**（有测试钉住）：一轮走完后
`log.len() == delivered + skipped() + (seq >= to 的条数)`；`to == null` 时即 `delivered + skipped()`。
也就是**被筛掉的洞看得见** —— 这是这一节唯一真正的合同。

**零分配**：`Replayer` 不持有 allocator，`open`/`seekTo`/`position` 只是扫描，`onlyTracks` 借调用方的
slice。`step` / `replayAll` / `remaining` / `isFullyBound` 的**签名一个都没变**，无 window/filter 时
`remaining()` 与 `isFullyBound()` 的**值**与旧行为逐位一致（代价：`remaining()` 现在是 O(总条目数) 的扫描）。

**未做**（矩阵 §7 的其余部分）：落盘 / WAL / codec、CLI 包装、seq 集合或多区间、按类型或时间戳筛选。
另有一条**既有**边界不在本次范围：`Track` 内部条目不保证 `seq` 升序（并发 sender 时 slot 领取序与
全局 seq 序可不同），而归并本来就假设轨内升序 —— 没动。

**验收**：`src/runtime/recorder.zig` 的 4 条新用例（`Replayer.open: only [from, to) is replayed, and what
that passed over is counted` / `Replayer.onlyTracks: one track is delivered, the others are skipped and
counted` / `Replayer: a window inside a filtered log leaves no entry unaccounted for` /
`Replayer: narrowing and stepping take no allocator, so they cannot allocate`）加 §13.7 既有的 4 条。
**变异验过红**：把 `to` 边界从 `>=` 改成 `>`，3 条断言以 `TestExpectedEqual` 变红（`expected 4, found 5`），
不是编译错。


### 13.9 Replay v2（第一刀）：codec 契约与 `drainTo` —— 设计已定，实现见本节末尾状态行

§13.8 把"落盘 / WAL / codec"留在未做里。第 31 批先落了**存储层**（`src/runtime/delivery_log.zig`：
分段、magic + 版本 + 每帧 CRC、撕裂尾部可判可修、`append` 零分配）。这一节定的是**接线**那一半：
投递轨怎么把"活值"变成"盘上的字节"。四个决策，实现按此做，不要再重新设计。

**D1 —— codec 跑在 `drainTo` 里，不在 `record` 里。** `Track.record` 是 `Handle.send*` 的热路径，
它的契约是**零分配 + 值语义**，一条测试盯着（`append allocates nothing` 那个家族的同类断言）。
所以：环里仍然放值，把值变成字节发生在**显式 drain**（由调用方的维护循环/线程驱动），那里分配是允许的。
代价必须写在明面上：环是有界的，**两次 drain 之间的溢出会变成盘上的洞** —— 见 D3。

**D2 —— 契约是调用方提供的类型，不是一个格式。** §13.2 拒绝"定义一套通用序列化协议"这条大路，
这一点不变：框架只要求一个**接口**，payload 里是什么它一个字都不读。

```zig
/// 一条轨声明它怎么把自己变成字节。`E` 就是这条轨的 `Message`。
pub fn Codec(comptime E: type) type {
    return struct {
        /// 稳定标识：写进 `TrackRef.payload_codec`，也是重放侧认负载的键。
        pub const name: []const u8;
        /// 调用方自己的负载版本（与段文件头的 `format_version` 无关）。
        pub const version: u16 = 1;
        /// 编码结果归调用方（`drainTo` 写完就 free）。
        pub fn encode(allocator: std.mem.Allocator, value: E) ![]u8;
        pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !E;
    };
}
```

**运行时不做猜测**（与 §13.6 Q3 同一条纪律）：没有声明 codec 的轨**不能**被 drain ——
`drainTo` 返回一个**指名到 track id** 的独立错误（`error.CodecRequired` 一族），
**不是**静默跳过。家规照旧：静默忽略的声明比没有声明更坏。

**D3 —— 有洞的 log 必须看得见。** 洞有两个来源，两个都要报：
1. **环溢出**：`Track.hasOverflowed()`（已有）说明这条轨在两次 drain 之间丢过条目；
2. **drain 游标落后**：环绕了一圈、游标指向的槽已被覆盖。

`drainTo` 返回的读数里必须有 `holes`（条数）与 `first_hole_seq`（第一个没进盘的全局 seq，
没有则 `null`）。**不要求**它拒绝写 —— 把已有的写下去是正确行为，把它**说成完整**才是错的。
读侧靠记录的全局 `seq` 自己就能看出缺口（记录里就有 seq），但自动判定"这是洞还是没记"需要
`first_hole_seq` 这一条，所以它必须在读数里。

**D4 —— 游标是每轨一个、单调的。** 一次 drain 之后，下一次只写**上次之后**的条目。
第一次 drain 从头开始。`DeliveryLog` 因此多一个每轨 `drained_upto: u64`（最后写出去的全局 seq）。

**D5 —— 这一刀不做**：从盘上重放（`Replayer` 侧读 `delivery_log` 段 + `decode` 投回 handle：
**下一刀**）、CLI、保留策略/压实、压缩与加密、跨进程传输。段文件本身的格式也不动。

**D6 —— 分配契约。** `drainTo` 允许分配，但必须**全部还回去**：测试用数分配的分配器（本文件
`Replayer: narrowing and stepping take no allocator` 用的同款手法），drain 前后 `allocations ==
deallocations`，并且**热路径那一侧**（`record`）仍然一条分配都不许有。

**状态**：D1–D6 是本节定下的契约；**实现与测试的状态见本节末尾追加的状态行**（写代码的人负责追加，
不要改上面这些决策）。段文件的格式在 `src/runtime/delivery_log.zig` 的文件头，逐字节。

**实现状态（`src/runtime/recorder.zig`，6 条测试全绿）**。**已做**：`pub fn Codec(E)`（D2 的形状，
`setCodec` 拿它做编译期检查，缺哪个声明就报哪个名）、`DeliveryLog.setCodec(track, C)`（擦除 thunk ——
`TrackRef.payload_codec` / `encode` / `decode` 由 comptime 单态化生成，`addTrack(spec, E, capacity)`
签名一字未动）、`DrainReport{ records, holes, first_hole_seq }`、`drainTo(writer)`（每轨单调游标
`TrackRef.drained_slots` + `drained_upto`，按全局 `seq` 归并后逐条 `append`，编码缓冲读完即 free）、
`drainRefusal()` / `firstHoleSeq()` / `drainedUpto(id)`；无 codec 的轨报 `error.CodecRequired` 并**指名**
（`drainRefusal()`），且那次调用**什么都不写**。环溢出仍由 `Track.record` 走 refusal 分支，新增的只有
"第一个没进盘的 seq"（`noteHoleSeq`，原子 min）。**没做**（D5 照旧）：盘上重放、CLI、压实/保留、压缩
加密、跨进程。两条**刻意留的边界**：① 盘上每条都写 `Kind.message` —— 内存轨不记投递种类（`send*` 与
`after` 的定时投递落进同一条环），带上它要往 `Handle.enqueue` 的漏斗加参数，D1 明说不动热路径，所以
"定时器投递在盘上冒充 message"是写在代码注释里的已知缺口 —— **这一条已补（§13.11）**：种类随条目进环
（`Track.recordKind`），`drainTo` 写的是它，D1 的零分配没有被违反（种类是漏斗上的一个值参数，
`recordKind` 与 `record` 一样零分配）；② `holes` / `first_hole_seq` 是**累积**读数
（描述文件、不因 drain 归零，`records` 才是本次的），且 `holes` 把"文件已经越过的那条"也算了进去
（`Writer.append` 的 `error.SeqNotIncreasing` → 记一个洞 + 光标跨过去，而不是让整次 drain 失败：不写
乱序，也不装作完整）。
**③ 第三条边界 —— 已拆**：`Replayer.bind` 曾对 `payload_codec != null` 的轨返回 `error.CodecRequired`
（§13.7 的原决策），读起来就是"给一条轨挂了 codec 就等于放弃了它的内存重放"，
`setCodec` 与 `log.replayer()` 像是**二选一**。那是**过时的**，与 D1 的事实相反：codec 只在 `drainTo` 里跑，
`installCodec` 只写 `payload_codec` / `encode` / `decode` 三个字段，`Track.recordKind` 照旧把**值**拷进环 ——
带 codec 的轨，环里是活值，`bind` 从来不需要解码。所以那条判断已删：`BindError` 不再有 `CodecRequired`
（唯一的返回点就是这一行，删掉即死成员；它只有这一个调用点，没有别的路径用它）。
**`BindError` 现在是 `UnknownTrack` / `MessageTypeMismatch` / `TargetIsInSourceLog` 三个**；
**读盘那一侧照旧要 codec** —— `ReplayFromLog` 读的是字节，`LoadError.CodecRequired` 原样保留。
这条边界现在是**被断言钉住的**，不再是"只写在文档与注释里"：
`Replayer: a track with a codec replays in memory and still drains to a segment file`（同一条挂 codec 的轨：
`bind` 成功、载荷逐条按内容相等 → `drainTo` 后 `scan` 的 `seq` / `kind` / 解码载荷与内存轨一致，
且 drain 过之后内存重放仍是全量 → 同一份记录交给 `ReplayFromLog`、不声明 codec 仍报 `error.CodecRequired`）。
**改动之前那条测试的红**：`507/1942 runtime.recorder.test.Replayer: a track with a codec replays in memory
and still drains to a segment file...FAIL (CodecRequired)`，栈顶
`src/runtime/recorder.zig:1141: if (track.payload_codec != null) return error.CodecRequired;`；
改后聚焦读数 `zm-test-count: aggregate 1/2057 selected passed=1 skipped=0 failed=0 leaked=0 binaries=6
db=all filter=a track with a codec`。
**测试名**：`drainTo: two tracks reach a segment file, encoded, in one global seq order` ·
`drainTo: the second call writes only what the first one left` · `drainTo: a track with no codec is refused
by name, and the other track is untouched` · `drainTo: an overflow is a hole, with a seq the file really
does not have` · `drainTo: an entry the file has already moved past is counted, not written back` ·
`drainTo: the codec's buffers all come back, and record never takes one`。**读数**：聚焦跑
`zm-test-count: aggregate 6/2045 selected passed=6 skipped=0 failed=0 leaked=0 binaries=6 db=all
filter=drainTo`；全量 `--force-run --db all`：`Build Summary: 15/15 steps succeeded; 1987/2045 tests
passed (58 skipped)`（无其它用例被带红）。**变异验红 5 处**（改弱实现后的真实输出，不是"看着红"）：
静默跳过无 codec 的轨 → `expected error.CodecRequired, found .{ .records = 1, .holes = 0,
.first_hole_seq = null }`；`holes` 的溢出那一半恒 0 → `expected 4, found 0`；游标不前进 → 第三次 drain
`expected 0, found 3`（重写）；encode 缓冲不还 → `expected 6, found 0`；refusal 不记 `seq` →
`expected 12, found 0`（`first_hole_seq` 用 `maxInt` 而非 0 表示"没有洞"，正是因为 seq 0 可以是洞）；
去掉"文件已越过"那一支 → `FAIL (SeqNotIncreasing)`。

### 13.10 Replay v2（第二刀）：从盘上重放 —— 设计已定，实现按此做

§13.9 让投递轨能进盘（`Codec` + `drainTo`）。当时记的代价是"挂了 codec 的轨不能再做内存重放"
（`bind` 返回 `error.CodecRequired`）—— 那条边界是**过时的**，已拆（§13.9 状态行 ③：codec 只在 `drainTo`
里跑，环里一直是活值）。但**读盘重放**依然是独立要做的一刀，与它无关：文件里是字节，要变回值就必须有
codec。七个决定。

**D1 —— 新类型，不动 `Replayer`。** `Replayer` 的窗口（`open`）、筛选（`onlyTracks`）、计数
（`log.len() == delivered + skipped + …`）与 `bind` 语义都是为**内存轨**定的，§13.7/§13.8 的 8 条用例
钉在上面。读盘重放的数据源不同（段文件 + 解码），把它塞进同一个类型会让那份合同变成两个值域，而它的
恒等式照搬不过来。所以：**新类型**（名字由实现者定，`ReplayFromLog` 一类），**共享的是契约不是实现** ——
同一个"轨标识 → handle"的绑定思路、同一个 `post` thunk 手法（按值进 mailbox）、同一条"洞必须看得见"的
纪律。**`Replayer` 的既有签名与行为一个字都不许改**（它那 8 条用例必须原样绿）。

**D2 —— 对账键只有 `track_id`，这是刻意的一条。** `delivery_log.Record` 里没有 codec 名/版本字段
（只有 `track_id` / `kind` / `seq` / `recorded_ns` / `payload`）。三个选项：(a) 把 codec 名塞进
`track_id`（零格式改动，语义藏在字符串里）；(b) 改段格式加字段（**动上一刀刚落地的逐字节格式**，
它有 12 条测试钉着）；(c) 框架只认 `track_id`，把"负载是哪种字节"交给调用方。**取 (c)** ——
段格式刚落地、且是"逐字节可依赖"的资产，为一个还没有任何消费者的对账需求去动它，是用错误的方向解决
正确的问题。要更强对账的调用方把版本放进 `track_id`（文档给出这个建议）。**这条是决定，不是遗漏。**

**D3 —— 洞默认拒绝，允许显式跨过。** 内存侧 `Replayer` 在轨溢出时拒绝重放；盘上同理：默认在发现
`seq` 不连续时返回一个**指名的**错误（`error.LogHasHoles` 一类），调用方显式声明"我知道有洞"之后
才继续，并且**跨过多少必须计数可见**（与 §13.8 `skipped` 同一纪律）。**静默跳过是禁止的。**

**D4 —— 顺序按全局 `seq`，不按段。** `scan` 返回的段是追加序，正常情况下跨段 `seq` 连续，但**不假设**：
按 `seq` 升序投递。这是 **load-then-replay**（段文件先读进内存再重放），**不是流式** —— 要写进文档，
否则会被当成能跟一个正在写的 log。

**D5 —— 解码值的生命周期：`post` 按值进 mailbox。** `recorder.zig` 的 `post` thunk 解引用后
`h.send(msg.*)`，而 `Handle.send(message: Message)` 是**按值**收，所以栈上的解码临时量是安全的。
**这一条要有证据**：一条测试在投递之后立刻覆盖那块栈，收端拿到的必须仍是原值。

**D6 —— `ReplayFromLog` 持有 allocator（与 `Replayer` 的零分配有意不同）。** `Codec.decode` 的签名
就是 allocator 版，解码必然分配。这是**刻意的差别**，必须写在文档与类型注释里，否则会被读成退化。
每步的解码缓冲用完即 free（测试数分配守恒）。

**D7 —— 这一刀不做**：边写边读（跟随活跃 log）、压实/保留、CLI、跨进程/跨机、加密压缩。
`Kind.message` 那个既有缺口（内存轨不记投递种类）**允许**顺手补 —— 它与本刀同属"记录里到底有什么"，
但要补就得动 `Handle.enqueue` 的漏斗参数，与 §13.9 D1"热路径零分配"冲突时以 D1 为准。

**验收（实现者交付）**：端到端（Runtime A 投递 → `drainTo` → 新 Runtime B 同图 `bindDecoded` →
重放 → 收端序列与载荷的指纹与 A 逐条一致，含**溢出/洞**那一档的两种模式）· 洞默认拒绝 +
显式跨过时计数精确 · 未绑定的轨与 log 里不存在的 `track_id` 各自**指名**报错 · D5 的栈覆盖测试 ·
D6 的分配守恒 · `Replayer` 的既有 8 条用例一字未改仍绿。

**实现状态**（`src/runtime/recorder.zig` §13.10；6 条聚焦用例 + 1 条端到端，全绿）。**已做**：`ReplayFromLog`
（新类型，D1 —— `Replayer` 的签名与行为**一字未动**，它的 4 条用例与 `runtime.zig` 的 4 条一样原样绿）、
`init(allocator, manual, records)`（D4 —— 段文件的记录**借**进来、按全局 `seq` 排一次索引再走，**load-then-replay**，
不跟随活跃 log；D6 —— **它持有 allocator 是有意的**，`Codec.decode` 就是 allocator 版）、
`setCodec(id, C, E)`（D2 —— 对账键**只有** `track_id`，段格式一字未改；`E` 由调用方指名，编译期同时钉住
"`C.decode` 确实产出 `E`"）、`bindDecoded(id, handle)`、`step()`/`replayAll()`、`allowHoles()`/`refuseHoles()`、
`holesSeen()`/`crossedHoles()`/`firstHoleSeq()`/`duplicateSeqs()`/`remaining()`/`isFullyBound()`、
`refusal()`/`refusalSeq()`/`typeMismatch()`（错误本身不带 payload，"哪个 id"靠这几个访问器，与 `drainRefusal` 同一纪律）、
`LogStep{ seq, clock_ms, id, kind }`（`kind` 读自帧，所以盘上"定时器投递冒充 message"这件事在重放侧**看得见**）。
**D3 落点**：`seq` 链上的缺口默认 `error.LogHasHoles`，而且**不消费**那条记录——`allowHoles()` 之后同一条照常投递；
跨过多少在 `crossedHoles()` 里**精确**（每次交付把"游标前那段缺口"结转到 `crossed_holes`，靠重算而非累加，重试不重复计）。
**指名错误**：`UnknownTrack`（文件里没有这个 id）· `CodecRequired`（绑了 handle 却没声明 codec）· `UnboundTrack`
（什么都没绑）· `MessageTypeMismatch`（handle 的 `Message` ≠ 声明的 `E`，两个类型名在 `typeMismatch()`）·
`CodecNameMismatch`（同一个 id 又声明了一个不同名的 codec）—— 五种都经 `refusal()` 指出 id。
**这一刀顺手补的一处 §13.9 缺口**：`DeliveryLog.setCodec` 要 **typed** `*Track(E, capacity)`，而 `Runtime.spawn`
只留 `Handle.track: ?*TrackRef`（erased）—— 运行时声明的 `.record` 轨**根本挂不上 codec**，`drainTo` 于是无从谈起。
新增 `DeliveryLog.setCodecRef(track, C, E)`（thunk 抽成共用的 `installCodec`；`E` 指名并与 `track.message_type`
比对，不符报 `error.MessageTypeMismatch`），`setCodec` 的签名/行为不变。端到端那一档是它唯一的验证点（e2e 里两条断言）。
**D7 照旧没做**：边写边读、压实/保留、CLI、跨进程/跨机、压缩加密；`Kind.message` 那个既有缺口**没补**
（补它要改 `Handle.enqueue` 的漏斗参数，与 §13.9 D1 冲突）。
**测试名**：`ReplayFromLog: a drained file replays in global seq order, and a hole is refused before it is crossed` ·
`ReplayFromLog: an unknown id, a missing codec and a missing handle are three different refusals` ·
`ReplayFromLog: codec name and message type are checked against the id they were declared for` ·
`ReplayFromLog: a seq the file holds twice is counted, not replayed` ·
`ReplayFromLog: the decoded value is posted by value, so the frame it was decoded in can be reused`（D5）·
`ReplayFromLog: the reader's allocator is real, and nothing a step takes survives it`（D6）·
`ReplayFromLog e2e (§13.10): a drained delivery log replays into a fresh runtime's handlers`（Runtime A 两条轨 cap 2/8、
8 次投递 → alpha 拒 seq 4/6 → `drainTo` 6 条 + 2 洞（`first_hole_seq = 4`）→ 新 Runtime B 同图、**不声明轨**
（`deliveryLog() == null`，不可能反喂）→ 默认拒洞 → `allowHoles()` → 6 条重放的 worker/fingerprint/clock_ms
与 A 逐条一致，`crossedHoles() == 2`，段文件 `scan().expectClean()`，时钟停在 7000 ms 而没睡）。
**读数**：聚焦 `zm-test-count: aggregate 7/2052 selected passed=7 skipped=0 failed=0 leaked=0 binaries=6
db=all filter=ReplayFromLog`；`Replay` 家族（4 条 `Replayer` + 4 条 `Runtime Replay` + 7 条本刀）
`aggregate 15/2052 selected passed=15 skipped=0 failed=0 leaked=0 binaries=6 db=all filter=Replay`；
全量 `--force-run --db all`：`test-fast: OK — 1994/2052 tests passed (58 skipped) in 164s (-Ddb=all)`
（本次改动落地后的读数；同一棵树的前一遍是 `1993/2052 tests passed (59 skipped)`，两遍都**零失败**，
差的那一条在 skip 计数里，是门控用例）；
`zig build check` → `check-production: OK`；`zig build check-api` → exit 0；
`scripts/check-deadcode.sh` → `OK: src+tools dead-code count within baseline (28)` / `OK: examples/** dead-code
count within baseline (0)`。**变异验红 8 处**（改弱实现后的真实输出）：静默跨过洞 → `expected error.LogHasHoles,
found .{ .seq = 13, .clock_ms = 13, .id = { 114, 105, 115, 107 }, .kind = .message }`；跨过计数恒 0 →
`expected 4, found 0`；`refuse` 不记 id → `thread … panic: attempt to use null value`；`inFile` 恒真 →
`expected error.UnknownTrack, found void`；`bindDecoded` 的类型检查去掉 → `expected error.MessageTypeMismatch,
found void`；`setCodecRef` 的类型检查去掉 → `expected error.MessageTypeMismatch, found void`；重复 `seq` 照投 →
`expected 1, found 0`；`deinit` 不还 `order` → `expected 5, found 4`（`1 leaked`）；把 `deliver` 的投递推迟到帧
被复用之后（D5 的反面）→ `expected 295990755014133383820138010460325856212, found 113705285682452570882479431272`。
**没有单独验红的两处**：`CodecRequired` 与 `UnboundTrack` 的**区分**（两条都只由 `refuse` 记 id 那条变异覆盖到"指名"
这一半）、`CodecNameMismatch` 同理 —— 这三种错误各自的**独立**红线没有取到，不编。

### 13.11 投递种类（kind）从漏斗到盘：已补

§13.9 状态行的边界 ① 是本文件里唯一一处"盘上写的是假的"：内存轨不记投递种类，`drainTo` 只能把每条都
写成 `Kind.message`。§13.10 已经把帧里的 kind 读出来给读者看（`LogStep.kind`），于是缺的只剩"盘上那个值
本身要是真的"这一半。§13.10 的 D7 当时把它记成"**允许**顺手补，但要动 `Handle.enqueue` 的漏斗参数，与 D1
冲突时以 D1 为准"——本节是那条判断的结果：**动漏斗不等于违反 D1**，因为带下去的是一个值参数
（`dlog.Kind`，`enum(u16)`，2 字节），不是一次分配，也不是一个格式。

**改了什么**（`src/runtime/recorder.zig` · `src/runtime/runtime.zig`）：

- `Track.recordKind(self, event, kind)`：真正的实现，种类随条目进环 —— 它出现在 `Track.Entry.kind`、
  `TrackEntry.kind` 和 `TrackRef.record` thunk 的第三个参数上。**`Track.record(self, event)` 签名一字未动**，
  等价于 `recordKind(..., .message)`；`Recorder(E).record`（HotBus 发布流那本账）同样一字未动 —— 它记的是
  *发布*，不是*投递*，给它加种类是另一个问题。
- `drainTo` 写 `entry.kind`，不再硬编码 `.message`。
- 三个来源各自归位：`Handle.send*` → `.message`；定时器投递 → **`.timer`**（`Handle.enqueue` /
  `enqueueBlocking` / `noteDelivery` 多带一个种类参数，`Handle.after` 的 `Delivery.post` 传 `.timer`）；
  重放投递 → `.message`。**重放为什么不用文件里的 kind**：录下来的 kind 说的是**被录那次运行**里发生的事
  （那里真的有一个定时器到期），而重放做的是**这次**运行里的一条普通 `send`；照抄等于让目标运行时声称自己
  arm 过一个它没 arm 的定时器。信息没丢 —— 它就在 `LogStep.kind` 里，读者看得见（理由写在
  `ReplayFromLog.bindDecoded` 的 `post` thunk 上）。重放也**不往目标 runtime 的轨里写东西**：目标图照旧按
  "不声明 `.record`"建，e2e 里断言 `deliveryLog() == null`。
- 契约不变：`recordKind` 与 `record` 一样**零分配、值语义**；`Handle.after`"一次调用一个 `Delivery` 分配"
  也没变（`src/runtime/alloc_contract_test.zig` 的断言全绿）。

**环的每槽增量（真实数字，`@sizeOf`）**：`Entry` 现在是 `{ seq: u64, clock_ms: i64, kind: dlog.Kind, event: E }`。
增量由 `E` 的对齐决定，实测两档：`E = u32` 时 **24 → 24** 字节（**+0**，种类落进原本就有的尾部 padding）；
`E = u64` 时 **24 → 32** 字节（**+8**）。`{ x: i32, y: i32 }` 这类 4 字节对齐、8 字节大小的 `Message` 与
`u64` 同档。**怎么量的**：不是估算 —— `Track.recordKind: the ring carries the kind, and record() means
.message` 里对 `@sizeOf(Track(u32, 4).Entry)` / `@sizeOf(Track(u64, 4).Entry)` 以及它们各自与
`{ seq, clock_ms, event }` 的差值做了四条 `expectEqual` 断言，下面这些数字就是那四条断言钉住的值；
差值 +0 / +8 来自"种类落在尾部 padding 里 / 把 8 字节对齐的载荷推到下一个 8 字节边界"这两件事。
（§13.2 记的 `Σ(capacity × sizeof(Message))` 是同一件事的粗略写法：条目的 `seq`/`clock_ms`/`kind` 一直是外加的。）

**测试名**（4 条：`runtime.zig` 3 条 + `recorder.zig` 1 条）：
`Delivery kind (§13.9): a timer delivery is written as .timer`（先写红的那条：定时投递 → 环里
`entry.kind == .timer`，且 `drainTo` 出来的帧 `records[0].kind == .timer`）·
`Delivery kind (§13.9): send and sendBlocking are written as .message`（反向守卫，防"全写 timer"）·
`Delivery kind (§13.9) e2e: a mixed track keeps every kind, entry for entry, on disk`（定时 + 直投混一条轨，
4 条投递 → `drainTo` → `scan`，**逐条**比对 kind（不是只看一条）→ `ReplayFromLog` 的 `LogStep.kind` 同为
`.message/.timer/.message/.timer`，且目标 runtime 不声明轨）·
`Track.recordKind: the ring carries the kind, and record() means .message`（值语义 + 擦除视图 + 上面两条尺寸差值）。

**读数**：聚焦（全部 `--force-run --db all`，`source=zm-test-runner`）：
`zm-test-count: aggregate 3/2056 selected passed=3 skipped=0 failed=0 leaked=0 binaries=6 db=all filter=Delivery kind`；
`aggregate 1/2056 selected passed=1 ... filter=recordKind`；
`aggregate 8/2056 selected passed=8 ... filter=alloc contract`（零分配契约那一批，含 `Handle.send*` 家族；
`recordKind` 是 `record` 的多一个值参数，本条是它"没有偷偷开始分配"的读数）；
`aggregate 6/2056 selected passed=6 ... filter=drainTo`（§13.9 的 6 条原样绿）；
`aggregate 7/2056 selected passed=7 ... filter=ReplayFromLog`（§13.10 的 6 条 + e2e 原样绿）；
`aggregate 15/2056 selected passed=15 ... filter=Replay`（整个重放家族）；`filter=Recorder` 3/3。
全量 `--force-run --db all` 在同一棵树上跑了三遍，**失败数三遍都是 0**：
`1998/2056 tests passed (58 skipped) in 182s`（改动落地后）、`1997/2056 tests passed (59 skipped) in 160s`
（文档定稿后）、`1998/2056 tests passed (58 skipped) in 200s`（最终树，`source=build-summary`）。
三遍之间的差异**只在 skip 计数里**（58 ↔ 59 抖动，门控用例，§13.10 记过同一种抖动），
比 §13.10 记的 `1994/2052` 多 4 条，正是本节新增的 4 条。`ZIG_GLOBAL_CACHE_DIR=.zig-global-cache
zig build check` → `check-production: OK`（exit 0）；`zig build check-api` → exit 0；`scripts/check-deadcode.sh` →
`OK: src+tools dead-code count within baseline (28).` / `OK: examples/** dead-code count within baseline (0).`；
`zig fmt --check src tools examples` → exit 0。

**红证据**（先写红的那条，加上之后改弱实现拿到的真实输出 —— 不是"看着红"）：
① 改实现之前，`Delivery kind (§13.9): a timer delivery is written as .timer` 在旧实现（`drainTo` 硬编码
`.message`）上：`599/1938 runtime.runtime.test.Delivery kind (§13.9): a timer delivery is written as .timer...
expected .timer, found .message`，栈顶是那条 `expectEqual(delivery_log_mod.Kind.timer, scanned.records[0].kind)`。
② `drainTo` 回到硬编码 → 定时用例仍 `expected .timer, found .message`，e2e 也 `expected .timer, found .message`
（栈顶 `expectEqual(kind, scanned.records[i].kind)`，逐条比对那条）。
③ `LogStep.kind` 硬编码成 `.message`（文件里是真的）→ 定时用例与 `.message` 用例**绿**，只有 e2e 红：
`expected .timer, found .message`（栈顶 `expectEqual(kind, step.kind)`）—— 说明"读者看得见 kind"有自己的一条线，
不是被别的断言顺带盖住的。
④ `Handle.send` 改传 `.timer` → `expected .message, found .timer`（栈顶环里 `track.entry(track, 0).kind` 那条；
e2e 同报 `expected .message, found .timer`）。
⑤ 擦除 thunk 丢掉种类（`recordErased` 传 `.message`）→ 定时用例 `expected .timer, found .message`
（栈顶环里 `entry.kind` 那条）。顺带测到一处**编译期**红线：把 `kind` 参数写成不用，构建直接
`src/runtime/recorder.zig:543:66: error: unused function parameter` —— 种类在这条路上是必须传下去的，
不是可以悄悄丢掉的参数。

**没做什么**：CLI / 保留 / 压实 / 加密压缩 / 跨进程（§13.9 D5、§13.10 D7 照旧）；`Recorder(E)`（HotBus
发布流）不加种类；重放不把文件里的 kind 回写成目标运行时的投递种类（见上，这是决定不是遗漏）；
`drainTo` 不对 kind 做额外校验 —— 它是 `enum(u16)`，能进 `Writer.append` 就一定是格式认识的值。
