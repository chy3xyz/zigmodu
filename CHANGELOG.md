# Changelog

## [Unreleased]

### Scheduler Phase 2：N 条池线程（**破坏性：否**；默认宽度 1 = Phase 1 行为）

Phase 1 的池只有**一条**线程，`docs/RUNTIME.md` §12.10 把"多池线程"列在"明确没做"里。这一批把它做掉，
而且**协议本体一行未改** —— `queued`/`claimed` 两个位、单出口回执、D4「每 worker 至多一项」、
D5「回执前重查邮箱」在任意 N 下都成立。改的全是协议**外围**，四处：

1. **`ReadyRing.tryPop` 改成多消费者安全**（本次最硬的一处）。Phase 1 的出队是"读 `dequeue_pos` → 读槽位 →
   写 `dequeue_pos = pos+1` → 释放槽位序号"：两条线程读到同一个 `pos` 就**都会拿走同一个 token**
   （§12.3 的状态独占在进门之前就没了），而两次序号写会让某个 token **永远 pop 不出来**（那个 worker 从此
   不再被调度，邮箱却继续收条）。修法是 Vyukov 出队那一半的标准写法：**下标用 `cmpxchgWeak` 认领**，
   赢了才拷值、才释放槽位序号，**没有引入任何新原语**（§12.7 的"不做新队列"仍成立）。
   **红证据**（只把 `tryPop` 换回 Phase 1 的写法，其余不动）：`scheduler: two consumers race one token and
   exactly one of them gets it` 第 2 轮就红 —— `expected 2, found 3`；`scheduler: a hammered ring hands every
   token to exactly one consumer` 红 —— `ring: token 0 came out 4 times`，环随即卡死（4 个生产者全部超预算
   放弃）。换 CAS 后：50 000 轮 + 4×5 000 token 全绿（连跑 5 次）。
2. **线程从"一条"变成"一组"**：`thread: ?std.Thread` → `threads: []std.Thread`（在 `Scheduler.init` 一次性
   分配，调度路径仍零分配）+ `started` 计数。`start()` 在**同一个 `start_claim`** 下起完整组再发布计数
   （懒启动的语义仍是"起或不起"），起失败则回滚 join，保持 all-or-nothing；`shutdown()` 先 `stopping` +
   唤醒，再**取走**计数（`swap(0)`）并 join 那么多条 —— 取走而不是读，否则两个并发调用方会 join 同一句柄
   两次（就是 §12.11 第 4 条的 `INVAL` → 中止）。
   `stats().pool_threads` 从此报**真实条数**（`0` = 池没起或已停，起来后 = 声明的宽度）。Phase 1 用
   `@intFromBool` 报 0/1，N>1 时会让 `pool_claimed ≤ pool_threads` 这条契约读数永远停在 0/1 上。
3. **宽度有声明入口**：`SchedulerConfig.pool_threads`、`Application.Config.pool_threads`、
   `ApplicationBuilder.withPoolThreads(N)`、`Runtime.InitOptions.scheduler.pool_threads`，**默认 1**。
   不碰 runtime 的应用仍是零线程（D2 不变）；声明了池却没声明宽度的应用跑的还是**一条**线程，既有测试与
   读数逐位不变。宽度为 0 夹到 1（没有消费者的池只能把 token 堆在环里），并且**进环容量公式**：
   `capacity = ceilPowerOfTwo(max_pooled_workers + pool_threads)` —— 消费者在出队窗口里持有的是槽位。
4. **claim-miss 之后退避**（性能，不是正确性）：`turn()` 区分 `ran`/`skipped`/`empty`，**只有 `ran` 清零
   自旋预算**（"跳过"与"环空"共用预算），park 判据从"环里没有 token"换成"**环与我上次看到的一样**"
   （`pushes` 计数未变）。否则一条被 claim 住的 token 会让 N−1 条线程全速空转（Phase 1 时这个形状根本
   不存在）。代价如实说：持有者交还 claim 时**不**唤醒 parked 线程（生产者路径上没有 mutex/信号，这是刻意
   的），所以"偷"到那条 token 最多晚一个 `idle_wait_ms`（1 ms）。

- 实测（本机，真线程，`batch = 1`）：4 worker × 4 生产者 × 2 000 条、宽度 4 →
  `attempts = 8000`、`received = 8000`、`dropped_full = 0`、`dispatches = 8000`、**`overlaps = 0`**、
  `claim_misses = 0`、`ready_push_failures = 0`；宽度 1 同上且 `claim_misses = 0`（**可证**：能交还 claim 的
  线程就是唯一能再 pop 的线程）；宽度 3 用 OS 线程数量到"起 3 条 → 再 `start()` 不增 → `shutdown()` 回基线"。
- **`claim_misses` 的监控口径变了**（唯一一条读数含义变化）：宽度 1 恒 0（非 0 = 协议被破坏，读法不变）；
  宽度 > 1 **允许非 0** —— 回执先清 `queued`、两条指令后再清 `claimed`，生产者落在这中间就会推一个
  "worker 还在被跑"的 token，此时另一条线程 pop 到它、抢 claim 失败即一次 skip（token 被重推，不是丢）。
  这条窗口只有持有者被抢占时才会宽，本机 11 次跑全为 0：**不要把 0 当契约，也不要把非 0 当告警**；
  要盯的恒 0 读数是 `ready_push_failures`。结构上界 `claim_misses ≤ attempted + dispatches`。
- 新增测试（`src/runtime/scheduler.zig`）：`two consumers race one token and exactly one of them gets it` ·
  `a hammered ring hands every token to exactly one consumer` ·
  `the ring is sized for its consumers' windows (the Phase 1 size would refuse)` ·
  `N pool threads conserve messages and never run one worker twice` ·
  `with one pool thread a claim is never missed (the Phase 1 reading)` ·
  `the declared width is the number of threads started — and all of them are joined`；
  `src/runtime/runtime.zig`：`Runtime: N pool threads conserve messages and never overlap on one worker`；
  `src/Application.zig`：`e2e: the builder's pool *width* reaches the runtime a module spawns .pooled on`。
- **零分配契约未放宽**：`src/runtime/alloc_contract_test.zig` 未改（线程数组在 `Scheduler.init` 一次分配，
  环仍在同一处一次分配）。
- 文档：`docs/RUNTIME.md` 新增 **§12.12**（机制、红/绿证据、实测数字、`claim_misses` 口径改法与测试名），
  并按 N 更新 §12.3 / §12.6 / §12.7 / §12.8 D2 / §12.9 第 4 条、§8 的 `pool_threads` 读法。

## [0.29.1] - 2026-09-20

### 修复：`.pooled` 路径上的四个缺陷（**破坏性：否**）

四处都是 v0.29.0 里已经发出去的缺陷，**都在 `.pooled` 这条可选路径上**（`.dedicated` 默认不受影响），
而且共用一个形状：池把"某件事一定会发生"当成前提，却没有把它变成断言。每处都是**先写能红的测试**再改。

1. **`push` 把"出队窗口"读成"环满" → 丢 token → 那个 worker 永久停摆**（危害最大）。
   `ReadyRing.tryPop` 先推进 `dequeue_pos`、再释放槽位（`slot.sequence = pos + capacity`）；生产者在这两条
   指令之间读到的是**上一轮的序号**，被 Vyukov 的检查判成"满"。普通有界队列里这是保守答案（调用方重试），
   在这里却是丢一个 **token**：worker 的 `queued` 还是 true，别的生产者也不会替它推 ⇒ 这个 worker 再不被
   调度，而邮箱继续收条。本机实测（cap=4、4 生产者、1 个 CAS 消费者、各 20 万次 `tryPush`）：
   ReleaseFast `800 000` 次尝试中 `324 416` 次被拒、其中 **`187 053`** 次读到的 `len < capacity`（环并没有满）；
   Debug 为 `133 070` / **`60 986`**。修法两处都做：① 环容量按 `max_pooled_workers + pool_threads` 取
   （消费者在窗口里也占一个槽位）；② `push` 被拒后**自旋重试**（预算 `push_retry_rounds`），只有整个预算都
   没等到才计数 + Debug/ReleaseSafe 断言 —— 从此"环满"只表示真的满。守卫不变：`ready_push_failures` 仍必须为 0。
2. **`Scheduler.start()` 的懒启动不是原子的 → 起两条池线程、只记住一条 → use-after-free**。
   池是第一次 `.pooled` spawn 才启动的，于是两个并发 spawn 会一起走到 `if (self.thread != null) return;`
   与 `self.thread = try std.Thread.spawn(...)` 之间：两条线程都起，只有后写的句柄被记住，`shutdown` 只 join
   一条，另一条活进 `Scheduler.deinit` 的释放里。修法：`start_claim` 上的 CAS，输的一方等这次尝试有结论。
   改前实测 `expected 4, found 5`（多出来的那条线程**没有任何计数器看得见**，判据只能是 OS 线程数）+
   未释放的环/scheduler；改后 30 次连跑全过。
3. **`Delivery.post` 投递后不 `announceReady` → 定时器投递静默滞留**。`send*` 四条路径都通知就绪，定时器
   那条（`after` → `Tick` → `Delivery.post` → `enqueue`）没有：池化 worker 的就绪是**环里的 token**，不是停在
   `recv` 的线程，于是这条消息一直躺到"碰巧有别的 `send`"为止 —— 只被定时器喂的 worker 就是永远。
   修法：投递成功后按与 `send*` 相同的规则通知就绪（投递失败的那条直接返回，不推 token）。
4. **并发 `shutdown()` 崩溃**。`Runtime.shutdown` 的文档写"幂等"，但它不是**线程安全**的：两个调用方都进
   函数体、都读到 `Scheduler.thread`、都 `t.join()` —— 第二次 join 同一个句柄是 `INVAL` → `unreachable` →
   **ABRT**（调用栈：`std.Thread.join` ← `Scheduler.shutdown` ← `Runtime.shutdown`），`workers` 列表也会被走
   两遍。修法：`Runtime.shutdown` 整体进 `shutdown_mu` + `shutdown_done`（后到者等做完就返回），
   `Scheduler.shutdown` 的 join 也串行化。**对照实验**：同一份测试源码（只用公开 API）在未改动的基线
   （worktree @ `dd6df20`）连跑 8 次 **8 次全挂**（同一个 `INVAL` 断言），在修后的树上 **8 次全过**。

- 新增测试：`scheduler: a producer waits out the slot its consumer is mid-release on` ·
  `scheduler: a hammered ring never eats a token` · `scheduler: two concurrent first starts spawn exactly one
  pool thread` · `Runtime: a timer's delivery to a pooled worker arms its ready token` ·
  `Runtime: two threads calling shutdown at once are safe`。
- **零分配契约未动**：`src/runtime/alloc_contract_test.zig` 的精确分配计数一个数字没改（环仍在
  `Scheduler.init` 处一次分配，`push` 的重试路径不分配）。`poolStats().ready_capacity` 的口径随容量一起变
  （声明上界非 2 的幂时比旧口径大一倍），既有判据 `ready_capacity >= max_pooled_workers` 仍成立。
- 文档：`docs/RUNTIME.md` 新增 **§12.11**（四处的机制、实测数字、修法与测试名）。

### Runtime Replay v1：每个 worker 的**投递轨** + 按全局 seq 重放（**破坏性：否**）

§11 的 `Recorder` 记的是 **L0 扇出**（`HotBus.publish` 之前）；它回答"生产者发布了什么"，
不回答"每个 worker **收到**了什么"—— `Handle.send` 的直达投递、`after(...)` 的定时器投递、
以及 `MpscRing` 的跨生产者交错，它一条都不覆盖。要重放一次运行，缺的正是后者。

- **取点在 `Handle` 的投递漏斗**（`enqueue` / `enqueueBlocking`）：`send*` 与
  `Handle.after` 的定时器投递**都**走它。只挂 `send*` 会漏掉定时器那一半 ——
  `Delivery.post` 直接写邮箱，`after` → `Tick` → `Delivery.post` 这条链**根本不经过 `publish`**，
  而它在流水线里往往是关键节拍（快照、结算、超时）。记录发生在**邮箱接受之后**：
  轨记的是"投递成功的那部分"，`error.Full`/`error.Closed` 不产生条目。
- **不引入任何 codec**：异构 `Message` 的解法不是序列化，而是**每 worker 一条同类型轨**——
  轨内部仍是 `E` 的有界环、值放进去，所以仍然零分配、仍然值语义。多轨靠 log 的
  **一个 `Sequencer`** 打**全局** `seq` 归并（轨内的槽位是本地计数器：`slot` 本地、`seq` 全局）。
  `Recorder` 的存储半边抽成 `Slots`（槽数组 + per-slot ready + 连续 published 前缀），两条轨共用它；
  `Recorder` 的 slot == seq 语义与 §11 的全部契约（`error.Full` 不覆盖不静默丢、
  `HotBus.attachRecorder` 行为逐位不变）一字未改。
- **声明即上界**：`.record = .{ .id = "book:BTC", .capacity = 4096 }` 在 **spawn 点**给，
  与 §12 的池"默认不创建"同一条纪律：**没有"默认全记"**，内存是 `Σ(capacity × sizeof(Message))`，
  由调用方声明。**worker 标识也是调用方给的**（不从模块名派生 —— 派生会做出一个"模块名唯一"的
  隐含假设）。`Runtime.deliveryLog()` 懒创建：没有任何 `.record` 就没有 log、没有环。
- **重放**：`DeliveryLog.replayer(&Clock.Manual)` → `bind("book:BTC", fresh_handle)` →
  `step()` 按 `seq` 归并、把时钟推到该条记录的 `clock_ms`、把载荷投给绑定的 handle。
  **`step()` 不等待任何人**（不 sleep、不自旋、不 join）；`replayAll()` 是同一个循环。
  目标 worker 的 `ctx.clock()` 就是被驱动的那个时钟，所以重放出来的 handler 读到的是**录制时的时间**。
- **有洞就不放**：轨满 `record` 返回 `error.Full`（不覆盖、不静默丢），但 `send*` **不因此失败**
  ——消息确实进了邮箱。`DeliveryLog.refusedCount()` 计数 + 一条 warn，`Replayer` 见
  `hasOverflowed` 直接 `error.LogIncomplete`，**连部分也不放**（§11.6 起写死的禁忌：
  有洞的 log 看起来完整）。
- **新增一条拒绝（实现时发现）**：`bind` 拒绝目标**就在被重放的 log 里**
  （`error.TargetIsInSourceLog`）。把轨重放回它自己的 worker 会把每条重放投递再记一遍，
  新条目落在游标之后 → `step()` 再取到 → 自我喂养、`replayAll()` 永不结束（被测试撞出来的）。
- **验收（§13.4）**：两个不同 `Message` 类型的两条轨 + 中间一条 `after(...)` 定时器投递，
  录制与重放两次的 **handler 调用序列（顺序 + 载荷指纹 + handler 读到的时钟）逐条一致**，
  且 20_000_000 ms（≈5.5 小时）的录制跨度在 **< 1 s 墙钟**内重放完（不 sleep）。
- **零分配契约不放宽**：`src/runtime/alloc_contract_test.zig` 对 `Handle.send*` 的**精确**分配次数
  断言一个数字都没改（没声明 `.record` 时是一次空判断；声明了也只是"一次间接调用 + 值拷进预分配环"）。
- **Breaking：否**。`SpawnConfig` 多一个可选 `.record`，`Handle` 多一个默认 `null` 的 `track`；
  `spawnConfig` 顺带**拒绝未知字段**（`.recrod = …` 这种拼错过去会被静默忽略 ——
  对一条"重放完整性"依赖的声明，静默忽略是最坏的失败）。
- 文档：`docs/RUNTIME.md` §13.6 三个待定项定稿（per-worker 容量 / 调用方给标识 / `step()` 为主）、
  **§13.7 落地形状**（与草案的差异、边界、新增的 `TargetIsInSourceLog`）。**未做**：落盘（Q4 第 2 档，
  `TrackRef.payload_codec` 是预留位）、跨进程、指标面（拒绝数只在 log 上，见 §13.7）。
### `TimerWheel x100K` 的数组索引代价：量到机制，不改代码（**破坏性：否**）

上一轮把 `nodes` 换成 `AutoArrayHashMapUnmanaged` 时留下一条自注的观察 —— "`x100K` 在 map 级测量里数组表贵
7–18%，门禁内 1.03×，余量不算大"。本轮把它当**待验证的假设**重测，而不是引用旧数字：同一台机器、交错 A/B、
每轮两种先后顺序各测一次（抵消"后测的那一臂占便宜"），并在**同一轮里**跑 A/A 对照（两臂是同一份代码）
当这台机器（10 核、负载均值 10–15、同时有别的构建在跑）的分辨率下限。10 万个键：

| 形状 | array / hash（配对中位数） | 同轮 A/A 对照 |
|---|---|---|
| 新建 map、**不含扩容**（预扩容，计时区内零分配） | **0.94×（快 6%）**，最好样本 12.65 / 14.04 ns | 0.995× |
| 新建 map、**含扩容**（= `Wheel.schedule` 的真实路径） | **1.25×** | 1.003× |
| 删除（`fetchSwapRemove` vs `fetchRemove`） | **1.73×** | 1.06× |

- **机制是扩容，不是探测距离或局部性**：数组表要维护**两份结构** —— entries 被复制（18 步 ×1.5 增长，合计 5.6 MB），
  index 每次重建都要新分配 header、`@memset` 之后把全部条目重插一遍（10 次，合计 3.7 MB）。同一份 10 万定时器整轮
  （计数 allocator）：数组表 34 次扩容分配 / 14.75 MB / 峰值 9.53 MB，旧哈希表 15 次 / 10.06 MB / 7.83 MB。
  数组表**活着**的索引本身就是 262144 × 8 B = **2.1 MB**（`Index(u32)` = `entry_index` + `entry_distance`），
  比旧哈希表整张桶数组（131072 × 16 B = 2.1 MB）还大。先把容量给足，数组表插入反而**快 6%** ——
  "占用 ≤60%" 正是它插入快的原因，扩容就是它的价。
- **判据面（`TimerWheel x100K`）的差值远小于 map 级**：整轮 = schedule 半边 + advance 半边，map 只是其中一部分。
  150 轮交错下 A/B 配对中位数 1.12–1.17，而**同轮 A/A 对照中位数 1.08**；换成固定缓冲（预触页、无 free、
  去掉分配器噪声）后最好样本 50.85 / 48.75 ns/op = **1.043×**。即差值在**低个位数百分比**，而对照本身就有
  6–8% 偏置 —— 在这台被共用的机器上这是分辨率下限，不是可判定的回退。
- **所以不动 `timer_wheel.zig`**：门禁余量仍接近 1.8×（基线 6.808 ms、阈值 2.0×），而任何
  "修法"都等于放弃数组表（= 退回 `TimerWheel churn x1M` 的 265 ms）或重写 std 的哈希表；代价只是"轮子长到
  10 万个活定时器时多付约 5 MB 扩容流量"。**没有跨宿主离散度就不动判据**：不调 `BENCH_THRESHOLD`、不改基线、
  不重录 —— 本轮三次实测（6.21 / 7.47 / 7.63 ms，同一份二进制、负载均值 25 / 15 / 12）对 6.808 ms 是
  0.91–1.12×，`check-bench.sh` 自己那次 27 条全绿（exit 0），仍然在 2.0× 窗口内。
- 守卫未动、仍然好：`Wheel: a long-lived wheel's lookups do not get slower as it ages` 单文件三种优化模式
  **19/19 全过**（Debug / ReleaseSafe / ReleaseFast 逐一跑）；同一份 A/B harness 上 `TimerWheel churn x1M` 形状
  29.81 ms 对改动前实现 277.23 ms（**9.3×**，方向与 9.6× 一致），门禁那次 28.76 ms 对基线 28.193 ms（1.02×）。
- 记录落在 `docs/BEST_PRACTICES.md`（`[pct]` 那节最后两条，含完整对照表与机制）与 `scripts/check-bench.sh`
  头部；顺带修掉两处因上一轮换表而**过期**的文档句子（`[pct]` 一节把 `nodes` 写成"哈希表…桶数组 ~3.5 MB"，
  `[alloc]` 一条把扩容次数写成 15）。

## [0.29.0] - 2026-09-19

### 定时轮：长生命周期轮的 id 查找不再随年龄退化（**破坏性：否**）

一轮 `[alloc]` 插桩分测顺手量到的东西，最后是一个**与生产形态直接相关**的缺陷：
基准里的轮是**每批新建**的，而运行时的轮**活整个进程**（`src/runtime/runtime.zig` 的 ticker 持有它）——
"复用"不是基准的特殊形态，它就是生产形态。同一份 1000 轮 × 100 定时器、两边交错测量的循环，本机实测
（`schedule` 半边，p50 / 最小）：

| 形状 | BEFORE（`AutoHashMapUnmanaged`） | AFTER（`AutoArrayHashMapUnmanaged`） |
|---|---|---|
| 每轮新建一个轮 | 28.3 / 24.2 ns/op | 27.1 / 20.4 ns/op |
| **同一个轮复用 1000 轮**（生产形态） | **233.8 / 59.2 ns/op** | **13.3 / 10.0 ns/op** |

即"复用/新建"从 **8.3×** 变成 **0.49×**，复用轮自身 233.8 → 13.3（**17.6×**）。

- **根因（`nodes` map，不是轮本身的代码）**：`std.AutoHashMapUnmanaged` 用墓碑删除，而它的增长预算
  （`available`）**把墓碑也算作可用**。于是"长生命周期 + 每次都是新 id"的 churn 会把表**排干成墓碑**：
  本机逐轮普查得到空槽 28 → 6 → 1 → 0，第 5 轮起就是 **128 个墓碑、0 个空槽**（表共 128 槽），
  此后每次 `put` 都要走完整个表（`avg miss probe` 从 10.8 步变成"走满容量"）。这个状态是**吸收态**：
  之后每次插入回收一个墓碑而不是消耗空槽；而增长要求 `size == max_load`，100 个活定时器永远到不了，
  所以**永不恢复**。
  对照实验排除掉的候选：**容量不回缩/缓存缺失**——把表预撑到 131072 槽（2MB）照样排干到 0 空槽，
  而 4194304 槽且有空槽的表比 256 槽无空槽的表**快 15 倍**；变的是"探测到第一个真空槽要走多远"。
- **修法**：`nodes` 换成 `std.AutoArrayHashMapUnmanaged`（后移删除，没有墓碑；索引重建保证占用 ≤60%，
  空槽是结构性保证而不是 churn 历史的函数）。生产形态 233.8 → **13.3 ns/op（p50，17.6×）**；
  `cancel` 侧 12.9 → 14.6 ns（+13%）；`advance` 不变（16.7 → 17.5 ns）。
- **契约没有放宽**：轮仍是 ticker-only（`claimOwner`/`assertOwner` 没动）；`src/runtime/alloc_contract_test.zig`
  的**精确**分配次数断言**一个数字都没改**（首次 `schedule` 仍是 2 次、`cancel`/`advance`/`drainAll` 仍是 0 次——
  数组哈希表在 ≤8 个条目时只分配 entries、索引头到第 9 个条目才出现，所以这些窗口内计数不变）。
  文件里原有 18 条用例一个没改、全部通过。
- **守住它**（这是本次的核心交付物）：新增 `timer_wheel.zig` 用例
  `a long-lived wheel's lookups do not get slower as it ages` —— 老实现下**红**
  （ReleaseFast 15.0 → 203.9 ns，**13.6×**；ReleaseSafe 10.6×；Debug 173.3 → 2143.9，**12.4×**），
  新实现下 0.65×–0.99×；以及基准新增 `[med3]` 指标 `TimerWheel churn x1M`（已进基线，
  老实现 265.46 ms → 新实现 27.57 ms，**9.6×**，判定阈值仍是 2.0×）。
- **`TimerWheel x100K` 不回退**：门禁测量 7.02 ms 对基线 6.808 ms（1.03×，判定 2.0×）。
- `docs/RUNTIME.md` §4 增加"为什么 id 索引是数组哈希表"；`scripts/check-bench.sh` 头部记录新条目的来源
  与"CI 基线暂未收录、别把本机值抄过去"的原因。

### 定时器"触发了但没投到"现在有计数（**破坏性：否**）

`Handle.after` 的投递回调（`Delivery.post`）在 `mailbox.send` 失败时**只打一行 debug 日志**：
定时器已经触发（`timer_fires` 动过），那条消息却没进目标邮箱，而**没有任何计数**记下它 ——
上一轮"丢弃必须可见"清单里剩下的最后一个洞。debug 日志在生产里默认关着，所以实际读数只有 0。

`send` 在这里有且只有两个失败出口，两个都覆盖并各有测试：`error.Closed`（那个 worker 已经停了）
与 `error.Full`（它的队列还满着）。

- **第四个原因，第四个数**：新增 `RuntimeStats.timer_deliveries_dropped`（运行时累加，
  `Handle` 侧没有对应字段）。它与既有三个数各不重叠：
  - `messages_dropped`（= `dropped_full`）：**生产者**在自己的调用点被满邮箱拒收 —— 调用方当场在场，
    消息从未被接受；`timer_deliveries_dropped` 是运行时替一个**已经跑完的定时器**丢消息，没有调用方在场。
    （`error.Full` 那一半会让两个数同时涨 —— 就是同一个 `send` 拒的 —— 这正是它存在的理由：
    只有这个读数能把"生产者在挨背压"和"定时器的消息没到"分成两件事。）
  - `messages_discarded_on_stop`：消息**被收下过**（`send` 返回过成功）然后被停机放弃；
    这里 `send` 从来没成功过，什么都不在队列里。
  - `timers_discarded`：定时器**没触发**就被释放（停机/取消）；这里 `timer_fires` 已经涨了。
- **停机窗口的典型形状**：worker 先停（邮箱关闭）、定时器随后到点 —— 于是它跳一次而
  `messages_dropped` 不动。持续增长则是另一回事：定时器在往一个长期跟不上的 worker 上投活儿。
- **第 17 条 gauge**：`zigmodu_runtime_timer_deliveries_dropped`（`Runtime.MetricsBridge`，
  16 → 17 条）。桥仍是鸭子类型（`createGauge` + `Gauge.set`），runtime 层不依赖 observability 层。
- **那行日志保留**（改的是 `catch |err| <计数 + 日志>`，不是退化成裸 `catch {}`）：日志回答"哪个 worker"，
  计数回答"多少次"。`scripts/check-production.sh` 照旧通过。
- **测试（先红后绿）**：两条生产路径各一条测试 —— 关闭邮箱（`error.Closed`）与满邮箱（`error.Full`，
  用一个不 `recv` 的 `run` 型 worker 制造，避免竞态）、外加一条 bridge gauge 注册 + 随运行变化的测试。
  未改生产代码时红（两种形式都贴过）：① 运行期守恒式
  `s.timer_fires == s.messages_received + s.timers_discarded` → `expected 1, found 0`；
  ② 补字段前 → `src/runtime/runtime.zig:1884:48: error: no field named 'timer_deliveries_dropped'
  in struct 'runtime.runtime.RuntimeStats'`。
- **零分配契约不变**：热路径（`Handle.send*` / `Runtime.scheduleAction`）与 `Handle.after` 的分配次数
  一行未动（计数是一次 `fetchAdd`），`src/runtime/alloc_contract_test.zig` 的断言一个字没放宽。
- **语义写进 `docs/RUNTIME.md`**：§5 第 2 条（四种原因各自的定义与"故意不合并"的理由）、§8（读数含义 +
  `timer_fires` 的配对读法）。

### 监督停机丢掉的剩余消息，现在有计数（**破坏性：否**）

`spawnActor` 判停时 dedicated worker 直接跳出接收循环，邮箱里剩下的消息**被丢弃且没有任何计数** ——
唯一一处不可见的静默丢弃（`HotBus.dropped` / `Mailbox.dropped_full` / `timers_discarded` 都计数）。
实测（同一 failing actor、8 条投递、`Clock.Manual`）：dedicated `handled=2/8`、停机时 `mailbox_len=6`、
`dropped_full=0`；pooled `handled=8/8`、`mailbox_len=0`。**停机行为不改**（正在停的 actor 不该继续干活），
补的是那个数字。

- **两个原因，两个数**：新增 `WorkerStats.discarded_on_stop` / `RuntimeStats.messages_discarded_on_stop`
  —— "收下了、然后被停机放弃"，与 `messages_dropped`（生产者被满邮箱拒收即 `error.Full`，消息从未被接受）
  **故意分开**。合并计数会把"调用方在挨背压"读成"某个 actor 停机扔了队列"，两者的处置相反。
  语义写进 `docs/RUNTIME.md` §5 第 2 条与 §8。
- **计数点两处，都是实测可复现的**：① dedicated 的循环出口（`Handle.countAbandoned`，
  监督停机时 `break` 走人那一条）；② `Runtime.shutdown` 的收尾 —— 先停池（§12.6），全部 join 完、
  destroy 之前把还压在邮箱里的条数记下（`Entry.abandon`；不放在 `join()` 里，因为 `join()` 可以被早调，
  那时池还活着，那个时刻还不是"没人能跑它们了"）。计数**只取增量**，所以收尾那趟对每个 worker 都跑、
  而 dedicated 已报过的 6 条不会变成 12；顺带兜住 `close()` 与 `send` 的竞态窗口（晚到的那一条在
  循环出口读不到，在收尾那次读得到）。两处都只 `+=` 计数，**不抽干**：那批消息是值，
  环随 handle 一起销毁，留着它们反而让 `mailbox_len` 诚实；抽干会顺带把它们记成 `received`，而
  `received` 的含义是"worker 取走准备处理的"。
- **计数按运行时累加，不按存活 worker 求和**（`messages_dropped` 是后者）：被放弃的消息**正是**
  在 `shutdown` join + destroy 的同一趟里发生的，求和写法会在能读到它之前归零。
  `RuntimeStats.messages_discarded_on_stop` 因此在 `shutdown()` 之后仍可读；`timers_discarded` 同形。
- **第 16 条 gauge**：`zigmodu_runtime_messages_discarded_on_stop`（`Runtime.MetricsBridge`），
  只在停机时跳一次，和随生产者压力动的 `messages_dropped` 是两条曲线。
- **测试（先红后绿）**：两条断言表本身的测试（dedicated 6 / pooled 0，含守恒式
  `sent == received + dropped_full + discarded_on_stop`，dedicated 那条再断言 `shutdown()` 不会把 6 报成 12）、
  一条"池先停、worker 手上还有 3 条"的测试（断言计数不随 worker 销毁消失）、
  一条 bridge gauge 注册 + 随运行变化的测试。
  未改生产代码时红：`expected 8, found 2`（守恒式右边少了那个计数）；补字段前红：
  `no field named 'discarded_on_stop' in struct 'WorkerStats'`。
- **零分配契约与停机路径不变**：热路径（`Handle.send*` / `scheduleAction`）一行未动，
  `src/runtime/alloc_contract_test.zig` 的断言一个字没放宽；停机顺序、`stop()` 语义、`join()` 契约照旧。

### WorkerPool Phase 1 —— `spawn(..., .{ .mode = .pooled })`：长尾 worker 共用一条池线程（**破坏性：否**）

`spawn` 一直是「一 worker 一线程」：`allocator.create(Handle)` + `std.Thread.spawn`。对
`行情 → 订单簿 → 风控 → 执行` 这种链是对的，对长尾（symbol / 房间 / 会话 / 指标扇入）到了顶 ——
"worker 数"变成"数据维数"，每个都吃一个栈、一个调度实体、一次上下文切换。Phase 1 落地
`docs/RUNTIME.md` §12 的设计：worker 还是那个 `W`（同一份 `handle`、同一个有界邮箱、同一套契约），
只是可以由**池线程**运行，状态独占从"按线程身份"换成"按排他声明"（`claimed`）。

```zig
var rt = try Runtime.initWithOptions(allocator, io, .{ .scheduler = .{ .max_pooled_workers = 64 } });
const audit = try rt.spawn(AuditWorker, .{}, .{ .capacity = 64, .mode = .pooled });
// 既有调用点一行不用改：第三参同时接受 `256` 与 `.{ .capacity = 256, .mode = .pooled }`
const book = try rt.spawn(OrderBook, .{}, 256);   // 仍是 .dedicated
```

- **API/兼容**：`spawn` / `spawnActor` / `spawnSupervised` 的最后一个参数改为 comptime 归一化
  （`spawnConfig`）：**位置容量（`256`）原样可用**，新增配置结构形态。`.dedicated` 是默认，
  行为逐位不变（`Handle.thread`、`join()`、`running` 语义在 dedicated 下与 v0.28 相同）。因此
  **不是源码级 Breaking** —— §12.9 第 2 条预期的迁移没有发生。
- **不能池化的形态是编译期错误**：`run` 型 worker 自带循环，池化等于让一条池线程被它独占；
  `spawn(..., .pooled)` 对它 `@compileError`（报错文本点名 `.dedicated` 与 `handle`）。
  这条守卫在测试套件里断言不了（触发它就是本文件编译失败），所以和 `check-tenant-scope.sh` 同形
  加了 `scripts/check-pool-guard.sh`：一个必须失败的 fixture + 两个必须通过的。
- **配置错误不留后门**：没在 `initWithOptions` / `Application.Config.max_pooled_workers` 里声明池就
  用 `.pooled` → `error.PoolNotConfigured`（不"顺手起一条线程"）；声明的上界是硬上限，
  第 `max+1` 个 `.pooled` spawn → `error.PoolCapacityExceeded`。
- **那条派生不变量**（§12 原文没点透，落地时必须成立）：**就绪环的容量 ≥ 可池化 worker 数**。
  D4（每 worker 在环上至多一项）⇒ 占用上界 = worker 数 ⇒ 容量取 `ceilPowerOfTwo(max_pooled_workers)`：
  **按声明的上界算出来，不是常数**。因为环里的 token 是"一个 worker 的调度权"，不是消息：
  丢 token = 那个 worker 永远不再运行（邮箱继续收、`send` 继续成功）。所以环满**不是背压**：
  `push` 失败要 `std.debug.assert` + `ready_push_failures` 计数（`Runtime.poolStats()`），
  绝不当普通满队列丢掉。
- **两处对设计草案的收紧（实测出来的，不改会丢 worker）**：① 认领失败要**重推** token（§12.4 写的
  "抢不到就跳过"）；② 批量结束只留**一条回执出口**，顺序固定 `清 queued → 清 claimed → 重查邮箱 →
  赢位才 push`（§12.4 的"保持 claimed 并重新入环"有一个 token 在环里而 claim 仍被持有的窗口，
  跳过的 token 会永久停掉一个 worker）。②里"赢位才 push"是被并发压力测试抓出来的：无条件 push
  会留下两个 token，而容量正是按"每 worker 一个"算的。
- **零分配契约不松**：`Handle.send*` 在池化下仍 **0 次分配**（新的 `alloc contract: a pooled Handle.send…`
  用例，`src/runtime/alloc_contract_test.zig`）；就绪环在构造时定容，推 token 是往槽里写一个值。
- **停机顺序多一步**（§12.6/§12.9-3）：`alive=false` → 停 ticker → **停池线程（join）** →
  断言没有 worker 还握着 `claimed` → request/join/destroy worker。池线程只在批次之间退出，
  所以"停机时它正在跑某个 worker"的窗口里 `handle` 会先跑完（worker 不返回就拖着停机，与 dedicated 一致）。
- **生命周期差异（写清以免误读）**：`.pooled` 的 `init` 钩子在**第一条消息的批次里**跑（池线程、
  claim 内），`deinit` 在 `shutdown()` destroy 前跑；从未收到消息的 pooled worker 两个钩子都不跑。
  `RuntimeStats.running` 对 pooled 表示"正被 claim"（上界 = 池线程数）。
- **测试**：协议在 `src/runtime/scheduler.zig` **不用线程**直接驱动（`step`/`runOne`），所以
  "同一 worker 不会被两条执行路径同时跑"和"handler 执行期间到达的消息不被丢"是单元级断言而不是
  "只有一条线程所以侥幸过"；端到端覆盖在同文件与 `src/runtime/runtime.zig`（含 3 生产者 × 200 条、
  `batch = 1` 把回执窗口打满、断言一条不丢；以及"停机时池线程正在跑"的 UAF 窗口）。
  `zig build test` 全绿。
- **没做（Phase 2 起）**：多池线程、`batch` 实测调优（16 是 D3 的设计起点，不是结论）、公平性加权、
  affinity/NUMA、per-worker batch 覆盖。见 `docs/RUNTIME.md` §12.10。
  （池的 Prometheus 指标原文也在这个清单里 —— 已被下面那条补上。）

### 补上 Phase 1 的三处 `TODO`：示例真跑池 · 池的 Prometheus 指标 · CLI 认识池（**破坏性：否**）

Phase 1（上一条）留下了三处"设计/单测都对，但没真跑过 / 没接出去"的缺口。这轮逐个补掉，
原则是**从运行中读出来的数**而不是常量：

- **示例真的跑池了**（`examples/runtime-workers`）：`audit` worker 改为
  `.{ .capacity = 64, .mode = .pooled }`，池的上界在 app builder 上声明
  （`b.withMaxPooledWorkers(1)`）。选它的理由对着 §12.5 的边界：消息驱动、故意慢、
  且不在 `feed → book → risk` 的延迟链上 —— 那条链每一跳都进关键路径，继续 `.dedicated`。
  运行时打印 `[pool] declared=1 threads=1 spawned=1 dispatched=N claimed=0 ready_len=0 push_failures=0`
  并**在 `dispatched == 0` 或 `push_failures != 0` 时以非零退出码结束**：编译过不算数，
  每次 `zig build run` 都验证"token 真的到了池线程"（`spawned` + `dispatches` 只能由池化路径抬高，
  dedicated worker 从不往就绪环里放 token）。示例的业务逻辑一行未改，只改执行模式与接线。
- **池进了 Prometheus**：`Runtime.MetricsBridge` 新增 6 条 gauge —— `zigmodu_runtime_pool_declared` /
  `pool_threads` / `pool_ready_len` / `pool_claimed` / `pool_dispatches` / `pool_ready_push_failures`
  （共 15 条）。`pool_dispatches` 是"池真的被用了"的远程可读证据，`pool_ready_push_failures`
  照旧是**必须恒 0** 的契约读数（§5 第 4 条：那不是背压，是调度器失联）。没声明池的 runtime
  这 6 条**报 0 而不是缺行**。鸭子类型契约没变（仍只要求 `createGauge` + `Gauge.set`）。
  读数来自 `Scheduler.Stats` 新增的 `pool_threads` / `claimed`（后者由 `step`/`runOne` 的
  claim 生命周期计数：批次的 claim 真的交还之后才减）。
- **`zmodu runtime` 认识池的两种写法**：`.max_pooled_workers = N` 与 `withMaxPooledWorkers(N)` 各报一条
  带 `file:line` 的事实，另加"有几条 spawn 写了 `.mode = .pooled`"（`spawn Audit mailbox 64 mode=pooled`）；
  `--json` 每个 worker 多一个 `mode` 字段（`null` = 该调用没写 mode —— API 默认是 `.dedicated`，
  但**默认值不是文本说的事**，所以不填）与顶层 `pool` 对象。仍然只报看得见的事实：不判断声明的池与
  `.pooled` 的 spawn 是否同一个 build，也不判断可达性。
- **顺手修掉一处真接线缺口**：`Application.Config.max_pooled_workers` 文档里承诺"`app.runtime()`
  创建的 runtime 按它 sizing"，但 `Application.init` 的结构体字面量**没有拷贝这个字段**、
  `ApplicationBuilder` 也没有对应方法 —— 即通过 builder/`Application` 路径**根本声明不了池**
  （恒为 0，`.pooled` 必然 `error.PoolNotConfigured`）。现在 `init` 会拷贝，
  builder 多了 `withMaxPooledWorkers(n)`，并补了端到端用例（模块在 `ctx.runtime()` 上 `.pooled` spawn、
  断言 `poolStats().max_pooled_workers` 与 `dispatches ≥ 1`）。这也是示例能声明池的前提。
- **顺带实测到一处两种模式不一致（只记进文档，未改行为）**：`spawnActor` 监督停机后，dedicated 的
  worker 直接 `break`（邮箱里剩下的消息被丢弃、且不计数），pooled 的 worker 会把邮箱**抽干**
  （每条剩余消息都再跑一次 `handle`）。同一个 8 条的探针：dedicated `handled=2/8`、pooled `handled=8/8`。
  §12.10 的生命周期表原本只写了"池把邮箱抽干后不再排 token"，没有点出**它与 dedicated 的差别**，
  现补一行实测记录与"Phase 1 不改"的理由（要统一得先决定丢弃的剩余消息是否该有计数）。

### `check-version.sh` 跳过 `test { … }` 块内的版本形字面量 —— 消除的是一类误报（**破坏性：否**）

tag `v0.27.0`（`1c705e5`）的 `bash scripts/check-version.sh` 红了**两条**，都在同一个文件里：

```
check-version: tools/ hard-codes version 0.26.0 -> tools/zmodu/src/incremental.zig:190:    try saveManifest(allocator, io, dir, &entries, "0.26.0");
check-version: tools/ hard-codes version 0.26.0 -> tools/zmodu/src/incremental.zig:232:    ...（同上）
```

两处都是 `test` 块里的 **fixture 值**（`saveManifest` 的 `version` 形参），不是版本**引用**。门禁的意图
是抓"包清单 / 文档 / 面向用户的字符串里写死的框架版本"—— 而 `test` 块里一个任意字符串既不发布也不生成
任何东西：值改成什么都能过，所以它是**误报**。修法落在门禁一侧：**tag 未移动、未新增 tag、未改发布内容**，
消除的是这一**类**误报（不是把那两个字面量改成别的字符串 —— 那只是修实例）。

- **只放宽这一处**：`scripts/check-version.sh` 第 2 节（"其它 0.x.y 字面量必须有意为之"）跳过 `test { … }`
  块内的命中 —— 只有这一个豁免。其余规则一字未动：第 1 节的 pin、第 3 节的 CLI 包版本、第 4 节的 WARN
  照旧。请求只发往 `.zig`（test 块只存在于 Zig 源码），其它文件照旧走 `grep`；且**只有确切回答
  "在 test 块里"才抑制命中**（文件被删/变短等异常一律保留命中），过滤器不会吃掉真引用。
- **不继承 `check-production.sh` 的宽豁免**：那个门禁的 `zig_skip()` 还跳"注释行"和 `\\…` 模板行（注释里的
  `// catch {}` 不是违规）。版本字面量没有这个理由 —— 模板行正是要写进生成项目的版本。所以共用的状态机
  `zig_in_test()`（花括号配对，顶层或缩进均可）只回答"这行在不在 test 块里"，`zig_skip()` 在它之上加那两个
  豁免：`check-production.sh` 用 `mode=catch`（= `zig_skip`），`check-version.sh` 用 `mode=at-test`
  （= `zig_in_test`），两处不可能漂移。实测本仓 `tools/` 的 33 处命中：**只有 2 处被丢**，都在 test 块里
  （`market.zig:516-517` 那段 `remote_json` fixture 的 `min_version`）；另有 7 处**注释/模板行在 test 块外**
  的命中**照旧被检查**（若继续用宽豁免，它们会被静默放过 —— 那才是削弱）。
- **`test {` 与 `test "name" {` 同一条规则**：`strip_code` 先把测试名（字符串字面量）抹掉，两种写法都变成
  `test  {`；先剥离字面量也让 test 里的 `"{}"` 不会打乱花括号配对。重构后对 `src/` + `tools/zmodu/src/`
  的 **284 个 .zig 文件逐一比对**新旧扫描器输出：**0 处差异**；`check-production.sh` 输出与改动前基线
  **逐字节相同**（`check-production: OK`，exit 0）。
- **反证（实跑，同一棵树，三种"非 test"形状都要照旧报红）**：在 `tools/zmodu/src/main.zig` 非 test 处插入
  一个注释行 `// probe-comment: legacy 0.31.7`、一个多行字符串行 `\\probe-prose 0.31.7`、一个普通代码行
  `pub const legacy_probe_pin = "0.31.7";` → `exit 1`，三行全部点名（`main.zig:27` / `:29` / `:31`）；
  把**同一个字面量**挪进 `test "cli submodule coverage gates …"` 内 → `exit 0` 且不再点名该文件。
  还原后 `shasum tools/zmodu/src/main.zig` = `87e3430a2f27b57eff76071677ff1c5e2f9b07cd`（与改动前一致）。
- **`v0.27.0` 现在绿**：重新 checkout `v0.27.0`（`1c705e5`）的 worktree，把改好的 `check-version.sh` 与
  `scripts/lib/zig-scan.awk` 复制进去（两边 `shasum` 一致：`27f525e9…` / `2da3b4a0…`），
  `bash scripts/check-version.sh` → `exit 0`（`check-version: OK (0.27.0 consistent across docs and tools/)`）；
  scaffold 依赖哈希那条 WARN 仍在 —— 它按设计如此（哈希只能在 tag 推出去之后重算）。**tag 未移动、未新增
  tag。**
- **不改发布记录**：另一条路是移动 `v0.27.0` 的 tag，但修复提交在该 tag 之后 12 个提交，移过去等于声称
  v0.27.0 包含整批后续加固；补一个 `v0.27.1` 也修不了 `v0.27.0`（那个 tag 仍旧红）。两条都歪曲发布内容。

### Benchmark 门禁：`RingBuffer SPSC x1M` 改用比值判据 —— 它是宿主的内存序实现，不是代码（**破坏性：否**）

`624b423` 的 CI Benchmark 闸门只红一条：

```
FAIL: 1 metric(s) slower than the baseline by more than 2.0x (lower is better):
  [absolute] RingBuffer SPSC x1M: baseline 1.090 ms → actual 2.336 ms (+114.3%)
```

该提交只动 `src/runtime/timer_wheel.zig`（`benchRingBuffer` 直接用 `rt.RingBuffer(u64, 1024)`，与时间轮
**不可达**）。逐条排除后，结论是：**这条指标的绝对毫秒判据不成立**，而 `1.090` **不是**被优化掉的伪值 ——
它是一条真实循环在另一种宿主上的真实数字。

- **代码被排除在指令级**：交叉编译 `facef4c` / `624b423` 两份 `x86_64-linux` benchmark 二进制
  （`zig build benchmark-build -Dtarget=x86_64-linux -Doptimize=ReleaseFast -Ddb=none`）逐指令比对：
  `benchRingBuffer` 内联进 `benchmark.main` 的三条展开副本（`0x106fd8a` 起）**编码与地址逐字节相同**，
  唯一差别是 call 重定位位移（链接布局挪了 `0x400`）；整份二进制的差异（374816 → 375046 条，
  改动 271/501 条）全部落在时间轮被内联的那段路径上。
- **不是被 LLVM 折掉的循环**（三条独立证据）：① 汇编里 slot 的 store 与 load 都在（`movq %rax,
  0x100(%rbx,%rsi,8)` / `movq 0x100(%rbx,%rdx,8), %rdx`），计数循环 `cmpq $0xf4240` 也在；
  ② 该循环**对 count 线性** —— 100K/1M/4M/16M = 1.035 / 10.840 / 42.775 / 173.171 ms（10.35-10.82 ns/iter）；
  ③ 把 sink 换成**不可能被折叠**的形式也不变：带内存 clobber 的指针形式 10.43 ms、把 pop 值累加进
  循环携带依赖的 `acc +%= v` 形式 10.98 ms（对生产形式 10.84 ms 在 ±3% 内）。
- **宿主档才是变量**：16 次 CI run 的记录里，同一份代码在**同一宿主上稳定到 3 位有效数字**
  （1.24 / 1.24 / 1.24 ms），跨宿主**台阶式**跳变：1.09（EPYC 9V74）、1.24（EPYC 7763）、1.26-1.57、
  **2.34（WestUS3 Intel Xeon Platinum 8370C）**—— 而红的那次 run 恰好就是唯一落在 Xeon 上的那次，
  同 run 的机器标尺 `atomic RMW x10M` 是 **60.58 ms**（EPYC 上 20.67 / 23.68 / 23.69）。折掉的循环不会
  随宿主变，所以这既是"没折"的反证，也是红的成因。
- **10× 倒挂的机制**：把 `src/runtime/ring.zig` **逐字复制**后只把 `.release`/`.acquire` 换成 `.monotonic`
  （其余一字不改），同一个 `benchRingBuffer` 循环在本机（M1 Pro）从 **11.70 ms → 0.954 ms**（12.3×），
  而 0.954 ms 正是 runner 上的那个数 —— x86 上 release store / acquire load 就是普通 `mov`，
  arm64 上是 `stlr`/`ldar`。所以这条指标量的是**宿主的 release/acquire 实现 + store-to-load forwarding
  延迟**（每轮的关键路径是 `tail`/`head` 各一条 store→load 链），不是框架代码。
- **修法（两条基线各一处）**：`RingBuffer SPSC x1M` 加入 `NORMALIZED_METRICS`，与那五条原子路径指标一样
  按 `指标 ÷ 'atomic RMW x10M'` 判比值（成员的准入规则从"每轮全是原子 RMW"改写为"每轮的关键路径是
  单个内存序原语"）。`scripts/bench-baseline.json` 只改这一条（`10.471 ms` → 比值
  `0.4976` = 10.706 ÷ 21.503，本机一次录制），其余 25 条按文件头部约定手工还原（`--update` 会全量重写）；
  `scripts/bench-baseline.ci.json` 同样只改这一条，比值 `0.0524` 取三次 **runner 实测对**的中位数
  （1.24/23.68、1.24/23.56、1.09/20.67），不是从本机推算的。**未改 `BENCH_THRESHOLD`（仍 2.0×），
  未整份重录基线**。
- **旧值为何不能留**：`1.090 ms` 是"某一档宿主的毫秒数"，被当成"代码的毫秒数"用；同一份二进制在 Xeon
  档上就是 `2.34 ms`。比值判据把宿主约掉（EPYC 0.0523-0.0527，Xeon 0.0386 —— 这条的比值只**近似**
  跟踪参考，26% 的离散度 vs 绝对值 2.15× 的离散度，仍远在 2.0× 窗口内），且**不削弱**对真回归的敏感度：
  循环里多一次分配/多一个原子都会把 `ms` 推上去，而分母同一轮不变，比值随之上升，闸门照旧报红。
- **更正 v0.28.0 段的一条记录**：那里写的"`RingBuffer SPSC x1M` 是唯一**不随机器缩放**的指标
  （runner 1.09 ms vs 本机 10.6 ms，慢机器上反而更快）"读法要改 —— 它**随宿主缩放**，只是缩放的是
  release/acquire 的实现成本，两个机器档在这条上相差约 10×，所以跨档比较依旧无意义（本机对 CI 基线
  仍然只红这一条，9.37×）。`scripts/check-bench.sh` 头部那段注释按实测机制重写。

### 时间轮的推进口径修正：非对齐 deadline 不再晚 640ms、也不再提前一格（**破坏性：否**）

`Wheel.advance` 的 level-0 槽 walk 有 off-by-one：它先 `index[0] += 1` 再走槽，却拿 `now_ms + slot_ms`
（该槽的**起点**）当触发阈值 —— 走在**下一个**槽上、阈值只到它的起点，于是槽内 deadline 大于该阈值的节点被
`expireSlot` 重新 `insert` 回**刚走过的那个槽**，要再等 64 个槽（64 × 10ms = **640ms**）才被看见。同一处偏差的
另一半是**提前触发**（阈值取的是上一轮的 `now_ms`）：`after(14)` 在第 4ms 就发出。两者都与
`docs/RUNTIME.md` §3（以及 `docs/UPGRADING.md` 的 v0.28.0 段）承诺的
`[delay_ms, delay_ms + 入队延迟 + tick_interval_ms]` 冲突 —— 而既有测试的 deadline 全是槽对齐的
（`after(50)`@1000→1050、`schedule(1050)`、5000/5030…），唯一的 ticker 用例自旋预算 4 亿次，所以一直没红。

- **新的推进口径**（`src/runtime/timer_wheel.zig`）：一次 `advance(now)` 先钉住 `now_ms = now`，然后
  ①**已经走过的槽**（`index[0] < target0`）**整槽过期**，阈值取**槽终点**（≤ `now`，槽里每个节点都已到期，
  因此不存在"被塞回刚走过的槽"这回事）；②**`now` 所在的槽**交给新的 `sweepDue`：**只发到期的那部分**，
  没到期的**留在槽里**（`next`/`prev`/`level`/`slot` 原样不动，`cancel`/`drainAll` 照样找得到），下一个 tick 再看。
  于是 `advance(now)` 严格等于"到期即发、不到期不发"，10ms 的槽粒度不再写进延迟上界（5ms tick 下偏差 ≤ 5ms）。
- **顺带修的同类偏差**：粗层（level ≥ 1）的 cascade 原本在"下层索引预增之后"执行，等于提前一格去清**下一个**
  粗槽，落在窗口头 10ms 的节点会被塞进刚走过的细槽、同样等一个旋转。现在级联发生**在走进新旋转之前**，
  要清的粗槽由「细索引 ÷ 64^l」直接推出，并只在"本层索引是 64 的倍数"时继续往上（层与层的窗口对齐是构造性的，
  不是靠增量维护）。
- **测试**：`src/runtime/timer_wheel.zig` 新增 8 条（裸轮复现 `schedule(24)`+`advance(40)`；5ms tick 网格下的
  unaligned 表；槽边界/槽终点/槽内各种偏移；level 提升（4096/4103/41000/41003）；多天延迟逐级级联
  （含 200,000,000ms ≈ 2.3 天）；200 条混合 batch 的逐条窗口断言；长停摆 + unaligned；部分走过的槽上的
  `cancel`/`drainAll`），`src/runtime/runtime.zig` 新增 1 条经**公开 API** 的用例（`Clock.Manual` + `rt.tick()`，
  不 sleep）验证 `after(delay)` 不早于 deadline、且落在下一个 tick 内。
- **兼容面：无 API 变化、无契约变化**（契约本来就是"**至少** `delay_ms`"），但**触发时刻会变**：
  非对齐 deadline 从"可能早最多 ~9ms、或晚最多 640ms"变成"恰好在 deadline 与下一个 tick 之间"。
  依赖旧的"提前几毫秒"做错峰的消费方会观察到差异；这正是它单独成条的理由。
- **未回归**：owner 单写者契约（`claimOwner`/`assertOwner`）、零分配契约
  （`src/runtime/alloc_contract_test.zig` 里 `Wheel.schedule/cancel/advance/drainAll` 的精确分配次数断言一字未改）、
  长停摆 `advanceCoarse` 路径、`TimerWheel x100K` benchmark（比值判据 < 2.0×）。

## [0.28.0] - 2026-09-19

> **本版说明**：给 v0.28 定的硬规定是「所有已有 public API 必须保持 source-compatible」，
> **本版有意偏离一次**，且只此一次 —— `Runtime.cancelTimer(id) bool` 被删除，拆成
> `requestCancelTimer` / `cancelTimerSync`。理由是它一旦异步化（时间轮改为 ticker-owned 后
> 必然如此）就无法再回答"是否已取消"，留着它就是**静默改义**，比删掉更危险；删除前已清点
> 全仓调用方（`examples/`、`tools/`、`docs/` 零引用，只有 `runtime.zig` 内部 1 处 + 1 个单测）。
> 迁移方式见 `docs/UPGRADING.md`。除这一处外，本版完全向后兼容。

### Benchmark 门禁：给"原子路径"指标加同轮机器参考（**破坏性：否**）

CI 的 Benchmark 闸门（`bash scripts/check-bench.sh`）在 `2462e70` 上稳定报红（两次 attempt 比值只差
1.3%），但红的是**宿主**不是代码。证据：受影响的是"每轮路径全是原子 RMW"的五条（`Mailbox post+drain`、
`Mailbox full-path`、`HotBus 8sub`、`Sequencer x10M`、`1L x10M events`），而同一次 run 里对照指标是
有记录以来最快的（前一次红则是反过来的形态：整机慢 1.09-1.45×，这五条只动 1.00-1.18×）；
`x86_64-linux` 上 base / head 两份二进制的计时循环**逐条指令相同**（`benchEventBus` 2683 条全等，
`benchmark.main` 只差 2 条且都在冷路径），两种 CPU 模型下都成立；本机 A/B（8 轮）与 Linux 交叉编译 A/B（5 轮）
全平（±1.5%）；12 套历史带里这五条从未超过自身最小值的 1.3×。

- **新指标 `atomic RMW x10M`**（`src/benchmark.zig` 的 `benchAtomicRmw`，runtime 分组第一条）：
  一次 `std.atomic.Value(u64).fetchAdd(1, .monotonic)` 的紧循环，10M 次，本机 ~22 ms。
  它**不是**框架指标，是"这台机器的原子路径有多快"的同轮标尺。
- **两种判据**：`Mailbox post+drain`、`Mailbox full-path`、`HotBus 8sub`、`Sequencer x10M`、
  `1L x10M events` 改成 `指标 ÷ 'atomic RMW x10M'`（同一轮的两个中位数相除）对**比值**用 2.0× 阈值；
  其余 21 条仍是绝对毫秒。比值把宿主换代约掉，绝对判据留下的部分会把它当成代码回归。
- **`atomic RMW x10M` 本身只报告、不判定**：给它绝对阈值等于"宿主换代就红"，正是这次要修的病因；
  它偏离记录值超过阈值时打印 host note（并说明这一条就是机器，不进入 verdict）。
- **基线格式向后兼容**：条目要么照旧 `{name, unit:"ms", value}`，要么
  `{name, unit:"ratio", value, normalized_by:"atomic RMW x10M"}`（`value` = 指标 ÷ 参考，均为同一轮中位数）。
  `value: null` 表示"这个机器档还没录比值"——闸门 WARN 并跳过（与"基线不认识的指标"同语义，不失败）；
  基线条目与判据清单不一致时**报 mismatch 而不是照比**（拿 0.77 去比 16.9 ms 会全过）。
- **闸门输出**：开头与 verdict 都打印 `region=… cpu=… cores=…`（region 取 `BENCH_REGION` → Azure IMDS →
  取不到打 `?`，**不因此失败**），并分开打印 `[absolute]` / `[ratio]` 两类判据（绿的时候也把 5 条比值和
  基线比值列出来）。
- **反证（真回归仍抓得到）**：给 `benchSequencer` 的每次取号插一对
  `harness_allocator.create/destroy`（热路径多一次分配）→ 闸门 **exit 1**，点名
  `[ratio] Sequencer x10M: baseline ratio 1.0310 → actual 6.7544（= 147.407 ms ÷ atomic RMW x10M
  21.824 ms）(+555.1%)`；还原后 `src/benchmark.zig` 的 sha256 逐字节一致。顺带测到：在
  `benchMailbox` 里插同样的分配只让比值 0.7902 → 1.09（+38%），**不触发** —— 2.0× 本来就是给量级滑落留的，
  这次改动没有降低它的灵敏度（比值阈值≈绝对阈值）。
- **基线**：`scripts/bench-baseline.json` 用 `--update`（未 `--force`）只动了 6 条（新增参考 + 5 条转比值），
  其余 20 条保持原值（`--update` 会全量重写，故按其头部约定手工还原了与本次无关的漂移）。
  `scripts/bench-baseline.ci.json` 无法在本地录：那 6 条写成 `value: null` 占位，CI 首次运行 **WARN 并跳过**，
  待 runner 上 `--update` 补录（**不要**整份重录）。本次实测该路径：本机对 CI 基线 exit 1 只报
  `RingBuffer SPSC x1M`（文件头部早有记载的跨平台差异），那 6 条按预期只 WARN。
- 文档：`scripts/check-bench.sh` 头部记下这轮证据与两种判据的取舍，`docs/BEST_PRACTICES.md`
  新增"性能门禁的两种判据"一节。生产代码公开签名未动。

### `shutdown()` 先停 ticker 再拆 worker —— 收掉停机窗口的 use-after-free（**破坏性：否**）

`shutdown()` 原来是"先 `request_stop`/join/`destroy` 所有 worker，再停 ticker"。夹在中间的那段窗口里
ticker **还在跑**：它每 5ms 醒一次，若这期间有一条定时器到期，`onTimerFire` → `post` 就会写到
**已经被 `destroy` 的 worker handle** 上 —— 定时器 payload 的投递目标恰恰是那个 handle 的邮箱
（`Handle.after` 的 `Delivery.post`）。窗口长度 = join 掉 N 个 worker 的耗时（毫秒级），不是理论值。

- **顺序**：`alive = false` → **停 ticker（broadcast + join）** → `request_stop` → join → `destroy` →
  `abandonTimerCommands()` → `drainWheel()`。ticker 退出前的最后一步本来就是 `drainWheel`（上一项），
  所以"先停 ticker"顺带把语义钉死：停机时还在轮里的定时器是**被 drop 掉**，而不是投给一个即将被
  释放的 handle（`alive = false` 之后那条消息本来也没有活着的收件人）。worker 之间的 "Ask first,
  join after" 与 `shutdown()` 的幂等性都没动。
- **纵深防御**：`onTimerFire` 在 `!alive` 时**只 drop 不 post**，并计入 `timers_discarded`（而非
  `timer_fires`）。这条覆盖"顺序管不到"的组合 —— 例如另一个线程的 `tick()` 与 `shutdown()` 并发
  （`docs/RUNTIME.md` §4 的 owner 契约本就禁止这种用法，但"写进已释放内存"对一次误用来说代价太大）。
- 公开签名不变；热路径只多一次 `alive` 的 acquire load。

**回归测试 2 条**（`src/runtime/runtime.zig`，都是确定性的，不靠"撞窗口"）：一条直接测 guard
（`alive = false` 后 `post` 不再被调用、`drop` 被调用、计数落在 `timers_discarded`）；一条测顺序不变量
—— worker 的 `deinit` 在退出时记录"轮是否已经空了"，两个 worker 都必须看到空轮（旧顺序下必红：
`expected 2, found 0`）。**红证据**：把生产代码临时还原成旧顺序 / 去掉 guard，两条测试分别稳定报红
（`expected 2, found 0` 与 `expected 1, found 2`）。

**UAF 红证据（一次性探针，不进套件）**：用 `std.heap.page_allocator` 启动 runtime，每次 `destroy`
直接 `munmap`，于是"post 打到已释放 handle"变成硬故障而不是静默写。250 轮 × 2 worker × 24 条
待触发定时器、`-OReleaseSafe`：未改生产代码时 **4/4 次** SIGSEGV（栈 `tickerMain → onTimerFire →
action.post → Mailbox.send → std/atomic.zig`）；修完在 Debug / ReleaseSafe 下均 0 崩溃。

### 定时器时间轮改为 ticker-owned：跨线程 arm 不再共享写（**破坏性：是**）

`docs/RUNTIME.md` §4 早就把 `Wheel(Payload)` 标成"单线程驱动"，但实现不是：时间轮零锁零原子，
而 `Handle.after`（任意线程）会一路走到 `wheel.schedule` 写 `nodes` 哈希表与 id 计数器，ticker 线程
同时 `advance`。两个线程同时进 `schedule` 时 `std.hash_map` 的 pointer-stability 断言
（`assert(l.state == .unlocked)`）直接 ABRT —— 这不是理论风险，见下面的复现规模。

修法不是"给它加一把锁"，而是把文档那句话变成真的：**时间轮变成 ticker-owned state machine**，
生产者与 owner 之间只通过一条定容命令队列交接。

**命令队列**：`Runtime` 内一条 `MpscRing(TimerCommand, 512)`。`arm` 与 `cancel` 走**同一条 FIFO**
—— 这样二者的线性化顺序由队列唯一确定（先 arm 后 cancel = 被取消；先 cancel 后 arm = 正常触发），
而不是两条队列下的掷骰子。`after`/`scheduleAction` 在调用线程上只做三件事：取 id（`Sequencer.next()`）、
按自己的时钟读算 `deadline`、入队。**入队不分配**（定容环），满则 `error.Full` —— 不静默丢。

- **`deadline` 在生产者侧算**：`after(50)` 仍是"从调用时刻起 +50"，与 ticker 忙不忙无关。
- **id 在生产者侧取**：`after` 立刻能返回一个 id（`!Id` 签名不变），不必等 ticker。
- ticker 与 `Runtime.tick()` 每轮**先 drain 命令、再 advance**；`tick()` 即声明自己是 owner。
- **`cancelTimer(id) bool` 已删除**（清点结果：只有框架内部 + 一个单测在用，无对外用户），替换为
  - `requestCancelTimer(id) !void` —— 热路径，语义是"**请求已交给 Runtime**"（约一个 tick 后生效）；
  - `cancelTimerSync(id) !bool` —— 控制面，等 owner 执行完并返回最终结果。
  旧名字的坏处正是它读起来像"已取消"，而它从来只是"请取消"。
- **`Wheel` 加 owner 断言**：`claimOwner()` 发布（第二次被别人抢 = panic），`assertOwner()` 在
  `schedule`/`scheduleWithId`/`cancel`/`cancelWith`/`advance` 上拦"第二个线程"，**只在 Debug/ReleaseSafe
  生效**（ReleaseFast 编译掉，基准不掉速）。未声明 owner 的裸时间轮（测试 / 基准 / 自持循环）不受影响。
- `now_ms` 只由 owner 写：`start()` 里那次赋值挪进 ticker 自己（`Wheel.alignNow`）。
- `shutdown()` 会把命令队列里没来得及执行的东西交出去（arm 调 `drop` 释放 payload、cancel 回报 false），
  停机不再漏掉"还在路上"的定时器 payload。

**回归测试 3 条**（`src/runtime/runtime.zig`，都是 §3 契约级、不是一次性脚本）：

- `T1`：32 线程 × 10_000 次 `after()`，**启动栅栏**同时开始，320k 个 id 必须互不相同。
  修复前：`std.hash_map` pointer-stability 断言失败 → **ABRT**（原始栈见 PR/文档记录）。
- `T2`：4 生产者并发 arm/cancel、同时驱动 `tick()`，末尾断言 `S = F + C + P`、同一 id 只 fire 一次、
  不许既 fire 又 cancel。修复前：ABRT（同上，栈落在 `timer_wheel.zig:98` 的 `nodes.put`）。
- `T3`：worker 在自己的 handler 里 `ctx.handle.after(...)`、ticker 在跑，断言那条消息最终到达
  （文档 §3 推荐的用法；修复前就是绿的，保留为回归网）。

**未附带**（现已补上，见下一项）：`Runtime.shutdown()` 当时仍不释放**已经进轮**的待触发 payload
（只释放命令队列里的）。

### `shutdown()` 释放已进时间轮的待触发 payload（**破坏性：否**）

上一项修完之后留下的缺口：`shutdown()` 只交出了**还在命令队列里**的请求，已经进轮的那些定时器
（`Wheel.nodes` 里的节点）只被 `wheel.deinit` 销毁节点本身，**payload 不释放** —— 停机时 armed 未触发的
定时器一律泄漏。修法遵守同一条单写者不变量：**drain 必须发生在 owner 线程上**，而不是让 `shutdown()`
（应用线程）去碰时间轮、把刚立起来的契约再破坏一次。

- **`Wheel.drainAll(ctx, on_drop) usize`**（`timer_wheel.zig`，owner-only + `assertOwner()`）：遍历全部
  slot，对每个 node 调 `on_drop(ctx, id, payload)`，销毁 node，清空 `nodes` map，返回释放条数。
  它是 fire/cancel 之外的**第三个出口**，用的是同一个 `drop` 钩子 —— 这正是"payload 恰好释放一次"
  在三条路径上都成立的原因。重复调用返回 0（幂等）。
- **有 ticker**：ticker 是 owner，所以由它在退出前 drain（`defer`，任何退出路径都覆盖），
  `shutdown()` 只负责 join —— drain 天然落在 owner 线程上。
- **没有 ticker**（调用方自己 `tick()` 自驱）：那条路径上调用方就是 owner，`shutdown()` 直接 drain。
  轮被**另一个**线程持有时不越界写它，而是 `std.log.warn` 出条数与 owner（不是静默丢）。
- **`shutdown()` 仍然幂等**：第二次调用发现轮里没有待触发项就直接返回，不 double-free。
- **丢弃可见**：`RuntimeStats` 新增 `timers_discarded`（按 `stats()` 既有的聚合写法加，`stats()` 里直接 load），命令队列里被丢弃的 arm
  与轮里被 drain 的定时器**同计**（对调用方而言都是"我 arm 的那次没跑"）；`Runtime.MetricsBridge` 出
  第 9 条 gauge `zigmodu_runtime_timers_discarded`。理由和 `messages_dropped` 一样：承诺过的活儿没发生，
  不能没有数字（`docs/RUNTIME.md` §3 / §8）。

**回归测试 4 条**（`src/runtime/runtime.zig`，`std.testing.allocator` 当泄漏 oracle，无需显式断言泄漏）+
1 条轮级单测（`timer_wheel.zig`）：ticker 路径 / 自驱路径各一条，断言 `timers_discarded == N` 且
`pendingCount() == 0`；幂等一条（连调两次 `shutdown()`，同一 `N`、不崩）；"已 fire 的不重复 drop" 一条
（正常触发一轮后 `timers_discarded == 0`）。**红证据**：未改生产代码时先跑这组测试，3 条失败
（`expected 0, found 64 / 16 / 8`）并报 88 leaks；实现后全绿。

### 新增：EventRecorder v1 —— 运行时投递流可录、可重放（**破坏性：否**）

`HotBus` 是**有意有损**的（满则丢并计数），运行时也没有全局顺序（每邮箱 FIFO），所以"这次运行
到底投递了什么、按什么顺序、在什么时刻"事后问不出来。v1 补上这一块：`src/runtime/recorder.zig`
的 `Recorder(E, capacity)`，opt-in、零分配、可重放。设计依据是 `docs/RUNTIME.md` §11（草案保留，
新增 §11.6 记录实际落地的形状与差异）。

```zig
var rec = runtime.Recorder(Trade, 4096).init(clock); // 与 Runtime.init 同一个 clock
try bus.attachRecorder(&rec);                        // 必须在 freeze() 之前
bus.freeze();
// …运行…
var manual = runtime.Clock.Manual{ .now_ms = 0 };
rec.replay(&manual, &harness, Harness.sink);         // 按 seq 推进 clock，不 sleep
```

**取点（对 §11.3 Q1 的更正）**：草案倾向"`Runtime` 内部、扇出之前"，但 `Handle.send` 直接写邮箱、
不经过 `Runtime`，那里没有取点。实际取点是 **`HotBus.publish` 的 sink 循环之前** —— 它正是扇出
本身，在它之前记录既不占 comptime 的订阅者槽位，也不会走 `dropped` 分支（`:128`）：那正是 §11
要避免的"丢记录"。**没 attach recorder 的 bus，`publish` 行为逐位不变**（只多一次 `?*anyopaque`
空判断，有测试守着 `attach` 前后的同一份断言）。

**溢出不是静默丢弃**：`record` 满环返回 `error.Full`，绝不覆盖；`entries()` 因此永远是 seq 升序
的完整前缀。`publish` 拿到拒绝后 `stats().record_dropped += 1` **并且返回 `false`**（签名仍是
`Error!bool`，examples 用的那个不动）—— 日志不完整不该读成成功；`Recorder.hasOverflowed()`
此后恒为真。

**实现要点**：`Sequencer` 的序号**就是槽位下标**（0,1,2,…），一次 `fetchAdd` 同时拿到顺序与空间，
多生产者不撞车；per-slot `ready` 标志 + `published` 前缀长度让 `entries()` 无锁、无等待地给出一段
完整前缀（领先的生产者写完自己那条就返回）。复用 `Clock`/`Clock.Manual` 做时间与重放驱动。

**测试 8 条**（`src/runtime/recorder.zig`）：record/replay 往返逐条相等；满环 = `error.Full` 且
`len` 未超（**反证**：把满环分支改成静默丢弃，这条立刻红）；seq 严格单调（含被拒的记录仍消耗
序号）；重放把 `Clock.Manual` 推到每条记录的 `clock_ms`（501 ms 的记录时间在墙钟上半秒内跑完，
即不 sleep）；attach 前后 `publish` 返回值一致；`freeze()` 之后 attach 返回 `error.Frozen`；
被拒的记录在 bus 上可见（`record_dropped` + 返回值 + `hasOverflowed`）；4 生产者 × 500 条并发
record 序号不丢不重。

**明确不做**：不做领域事件溯源（那是 `core/EventStore.zig`）；不做 `HotBus` 订阅者（会丢）；v1 只录
**单一事件类型 `E`** 的 `HotBus` 发布流，`Handle.send` 直达投递、`after` 定时器投递、多 worker
**异构**消息都不覆盖；不承诺进程级完全确定性（`spawn`/`init` 副作用、网络、墙钟、丢弃模式不重放）；
只有读注入 `Clock` 的代码参与重放。

**文档**：`docs/RUNTIME.md` §11.6（形状、与草案的差异表、未做边界）、README
「High-Performance Runtime」清单（英文）。

### 新增：Runtime worker trace context —— 消息可归属到发起它的请求（**破坏性：否**）

外部 review 的 v0.28 提案里，「Tracing — Worker trace context」是核对后仅剩的 3 个真实缺口之一。
在此之前运行时代码里没有任何追踪概念 —— 对 `HEAD` 逐文件核对，每个文件都是 0：

```text
$ for f in src/runtime/*.zig; do git show HEAD:$f | grep -cE "TraceId|trace_id|traceId|tracing"; done
0
0
0
0
0
0
0
0
```

（`timer_wheel.zig` 里出现过 `span`，那是时间轮的几何宽度，不是 trace span。）

HTTP 层有 `trace_id`（`http.Tracing`）、有 OTLP 导出，但请求触发的 worker 消息在追踪里是**孤儿**：
worker 报错只说得出"谁出错了"，说不出"哪一次请求造成的"。

**改动（集中在 `src/runtime/runtime.zig`）**

- 邮箱元素从裸 `Message` 换成文件内私有信封 `struct { trace: ?TraceId = null, message: Message }`。
  `TraceId` 从 `tracing/DistributedTracer.zig` **原样** re-export（`zigmodu.runtime.TraceId`，16 字节
  值类型），不另造平行结构。**零分配**：trace 跟着邮箱槽位走，不给 `Mailbox` / `RingBuffer` /
  `HotBus` / `send` 加 allocator 形参 —— 热路径上只是一个字段的拷贝。
- `Handle.send` / `sendBlocking` **签名不变**（内部发 `trace = null`）；新增
  `sendTraced(msg, trace)` 与 `sendBlockingTraced(msg, trace, timeout_ms)`。
- `WorkerContext.traceId()` 返回**当前正在处理的那条消息**的 trace —— 每条消息一份，不是每个 worker
  一份，生产者线程设的值不会串到别的消息上；`init` / `run` 阶段为 `null`。
- `Handle.after(...)` 在 handler 内（worker 自己的线程）调用时带上当前消息的 trace，定时器投递的消息
  保留归属；在别的线程上调则投无 trace 的消息（那里没有正在处理的请求，硬编一个反而是假的）。
- `supervise` 的两行错误日志与 `init` 失败那行带上 `trace=<hex>`，可直接 grep 回请求。
- `HotBus` / `Mailbox` / `Runtime.spawn` 的公开契约未动（`HotBus` 只做 `@hasField(H, "mailbox")`
  探测 + `h.send`，`send` 签名不变即无需改动）。

**测试 5 条**（`runtime.zig`）：`sendTraced` 与 `send` 的区别、traced/untraced 交替时各自的归属与顺序、
跨线程双生产者 2000 条零错配、`after` 保留调度时的 trace、`init`/`run` 阶段为 `null`。
跨线程那条是**反证**：把 trace 临时改存到 handle 上（而不是信封里）再跑同一份测试，
2000 条里 **802 条**归属错乱 —— 信封化不是形式主义，它买的就是这个。

**文档**：`docs/RUNTIME.md` §8.1（用法、逐条契约、错误日志、与 HTTP `ctx.traceId()` 的接法）、
§3 契约要点、README「High-Performance Runtime」清单（英文）。

### 修复：v0.27.0 的提交过不了自己的 `check-version.sh`

**背景**：`tools/zmodu/src/incremental.zig` 的两个测试把 `saveManifest(…, zmodu_version)`
的 fixture 值写成了当时的版本字面量 `"0.26.0"`。`scripts/check-version.sh` 会扫 `tools/`
下的 `0.x.y` 字面量并判为硬编码版本 —— 版本一 bump 到 0.27.0，这个闸门就红了。
它**只在 CI 里跑**（`ci.yml` 的 "Version consistency"），不在 `release.sh` 的闸门清单里，
于是本地发布全绿、推上去才红。

**修法**

- 两处 fixture 改成无版本含义的 `"test"`（测试只做 manifest 往返，不断言该字段的值）。
  生产侧本来就是对的：`main.zig:6301` 传的是 `ZMODU_VERSION`（源自 `build.zig.zon`）。
- `release.sh` 的闸门清单补齐为 **CI 阻断项的并集**：新增 `check-version.sh`、
  `check-tenant-scope.sh`、`zig build check-api`、`zig build check`（后者内部跑
  `check-production.sh`）。"本地绿、CI 红"的发布事故因此不会复发。
- scaffold 的 `zigmodu_zon_hash` 刷新到 **v0.27.0**
  （`zigmodu-0.27.0-U40vs9t8UgBlmRaJ7WNawmUCr_LZFk9H1XrKU44bvHk1`）。该 hash 必须在 tag
  存在之后才能算出，所以每次发布后都要补这一手；滞后期间 `check-version.sh` 只报 WARN
  （设计如此）。验证不看 hash 像不像，而是**真编译**一个钉住该 URL+hash 的生成工程，
  `zig build` exit 0 才算数。

### 修复：`check-tenant-scope.sh` 在 Linux 上必红（本次把它接进 CI 时暴露）

`ci.yml` 新增的 "Tenant-scope compile gate" 在 ubuntu-latest 上失败，`plain` fixture 报：

```
error: dependency on libc must be explicitly specified in the build command
    extern "c" fn clock_gettime(...)
referenced by: clock_gettime -> monotonicNow: src/core/Time.zig:46
```

`plain` fixture 可达的代码在 Linux 上经 **`src/core/Time.zig` 的 `monotonicNow`** 走到
`std.c.clock_gettime`，Zig 要求显式声明 libc 依赖；macOS 不走这条路径，所以本地一直是绿的。
`compile()` 加 `-lc` —— `-fno-emit-bin` 不产生二进制，该标志只满足这次分析。

**验证方式**：不靠"推上去看 CI"，而是本地用 `-target x86_64-linux-gnu` 跑同一份分析：
去掉 `-lc` 精确复现了 CI 的报错与调用链，加上 `-lc` 后 3/3 通过。

### 修复：Benchmark 闸门拿本机基线卡 CI —— 拆成两份基线

`ci.yml` 的 "Performance gate" 在 `88f082b` 上失败，报 CircuitBreaker 两个指标慢
2.14× / 2.18× —— 而该提交只改了一个 shell 脚本和 CHANGELOG。真因是**基线录制机器与
闸门运行机器不是同一台**：`scripts/bench-baseline.json` 录在维护者的 M1 Pro 上，
闸门却跑在 ubuntu-latest 上。

同一份代码，三次测量：

| 指标 | 本机基线 | 上一轮 CI（绿） | 本轮 CI（红） |
|---|---|---|---|
| CircuitBreaker x10M | 6.571 ms | 10.91 ms（1.66×） | 14.055 ms（2.14×） |
| CircuitBreaker x100M | 64.488 ms | 109.08 ms（1.69×） | 140.551 ms（2.18×） |

绿的那轮已经只剩约 18% 余量；而本轮 **23 个指标在同一次 CI 内部一致地慢约 1.3×** ——
这是整台机器档位的速度差，不是任何单个指标的回归。

**修法**：绝对时间基线不可能同时服务两个硬件档位，所以一档一份：

- `scripts/bench-baseline.json` —— 本机（默认）
- `scripts/bench-baseline.ci.json` —— **从一次绿的 CI run 的数字录成**，`ci.yml` 用
  `BENCH_BASELINE` 指过去

`check-bench.sh` 的 `BASELINE` 改为 `${BENCH_BASELINE:-scripts/bench-baseline.json}`，
`--update` 写哪一份由它决定。**阈值不动**（仍是 2.0×），两档各自保持满灵敏度。

**验证**：拿失败那轮的 23 个指标去比 CI 基线，比值全部落在 **1.21–1.36×**（最大 1.36×），
即修好后那一轮会通过；本机默认路径仍 exit 0。

**残留**：CI 基线录自某一个 runner 实例，换到明显更慢的实例仍可能逼近 2.0×；
这比修前（仅 18% 余量）稳健得多，真出现时按脚本提示重录，不要调阈值。

### 补齐 Runtime 验收表仅剩的两行：worker 启停 + 背压路径

外部 review 给了一份 "v0.28 Runtime Foundation" 提案，要求新建 `src/runtime/` 下的
Worker / Mailbox / RingBuffer / HotEventBus / Clock / Supervisor 等。**核对后确认这些在
v0.16/v0.17 就已交付**：`docs/RUNTIME.md` §9 的 roadmap 逐条对得上，`src/runtime/` 下已有
`runtime.zig` / `ring.zig` / `mailbox.zig` / `hot_bus.zig` / `timer_wheel.zig` / `clock.zig` /
`object_pool.zig` / `sequencer.zig`，`app.runtime()` 在 `Application.zig:274`。按提案字面
实施等于造第二套平行 runtime（正是该提案自己原则 2 所禁止），所以只做真正缺的部分。

**两条 benchmark** —— 提案 §19 验收表里仅剩未覆盖的行：

| 指标 | 实测（本机） | 覆盖的验收行 |
|---|---|---|
| `Worker spawn+join x1K` | 29.51 ms | worker startup / shutdown / 无泄漏 worker |
| `Mailbox full-path x10M` | 21.80 ms | Queue full → bounded（背压拒绝路径的成本）|

`Worker spawn+join x1K` 把运行时的分配器换成 `FailingAllocator` 并武装在 stop/join 半段，
比对 `alloc_index + resize_index`（`fail_index` 盖不住 `resize`/`remap` 增长），任何被加进停机
路径的分配都会直接失败，而不是变成一个稍慢的样本；循环结束后再断言
`stats().workers == 0 and running == 0`。`spawn` 本身必然分配，这一点没有假装。

提案 §19 其余各行本已满足：RingBuffer / Mailbox / HotBus 的收发路径**不接受 allocator 形参**
（固定容量，结构上不可能分配）；队列满、运行时停机、多线程竞态都有现成单测
（`RingBuffer moves values between two threads without loss`、
`Mailbox: many producers, one consumer, nothing lost`、`MpscRing accepts many producers`、
`Runtime: shutdown joins every worker and reports stats`）。

**文档**：README 的 Features 此前**完全没有 runtime 这一层**（`grep -i runtime` 只命中
"Agent Runtime" 与 "runtime error"）。补了「两种执行模型」的定位句、`### High-Performance
Runtime` 能力清单（Worker / Mailbox / RingBuffer / MpscRing / HotBus / TimerWheel / Clock /
Supervision / 指标桥），以及 Project Structure 里的 `src/runtime/`。英文 README 仍无中文。

**基线**：本机基线重录（23 → 25；无改名，21 条收紧、2 条 +0.9% / +0.5% 噪声漂移）。
CI 基线随后从真实 runner 补录了这 2 条（`Mailbox full-path x10M` 49.44 ms、
`Worker spawn+join x1K` 44.88 ms），**其余 23 条原样未动** —— 该轮 runner 比上一轮慢约 1.19×
（23 条的中位比值 1.19×，范围 0.97–1.50×），整份重录会把当天 runner 的速度烙进棘轮。
另记一条实测观察：`RingBuffer SPSC x1M` 是唯一**不随机器缩放**的指标（runner 1.09 ms vs
本机 10.6 ms，慢机器上反而更快），所以跨这两份基线比较它没有意义。

### 新增：`zmodu runtime` —— 运行时接线的静态盘点（**破坏性：否**）

v0.28 review 的 §二 提过"runtime diagnose/bench"。能做且诚实的只有一半：**读活的运行时状态**
静态 CLI 做不到（队列深度 / `dropped_full` / `timer_lag_ms` 是运行中进程的属性，已由
`Runtime.MetricsBridge` 导出成 8 条 Prometheus 指标，抓取配方在 `docs/RUNTIME.md` §8）；
能做的是把某个项目**已经声明**的 runtime 接线盘出来 —— 新增
`tools/zmodu/src/runtime.zig`，`zmodu runtime [dir] [--json]`。

报告六块（每条带 `file:line`）：是否用了 runtime、worker（`spawn`/`spawnActor`/`spawnSupervised`
的**类型名 + 邮箱容量**）、邮箱/队列原语（`Mailbox(`/`RingBuffer(`/`MpscRing(`/`ObjectPool(`/`HotBus(`）、
定时器调用点、录制/追踪引用、时钟选择，末尾一行汇总（如
`9 worker(s), 1 bus(es), 1 timer call site(s), recording: no, tracing: no`）。

容量**只在读得出来时**给数字：字面量直接用；`api.order_capacity` 这种顺着该文件自己的
`@import("api.zig")` 找到 `pub const` 再用；读不出来报 `?` 并附原表达式 —— 不猜。
遍历是**递归**的（`src/**/*.zig` + 根目录 `*.zig`），不像 `audit` 那样固定两层。
刻意**不做任何判据**：只报看得见的事实（`attachRecorder(` 在 `src/x.zig:42`），
不做静态不可靠的推断（"recorder 是否在 `freeze()` 之前挂上"），所以 `--json` 可以进 CI 而不产生假警报。
退出码 `0`/`1`（目录读不了）/`2`（用法错误）；**项目没用 runtime 也是 0**（报告说 `uses runtime: no`）。
文档：`docs/ZMODU_CLI_INTEGRATION.md` 新增一节（含"它不做什么"），README Commands 加一行。

## [0.27.0] - 2026-09-18

### 修复：`zmodu scaffold` 生成的工程过不了自己的 `zmodu ci`

追一条"grep 干净度"的尾巴时撞出来的真缺陷：**生成器产出的代码违反框架自己的审计规则**。

复现（修复前，v0.26.0 的 CLI）：

```
$ zmodu scaffold --sql schema.sql --name app --out ./app --with-agent --with-websocket
$ zmodu audit ./app
architecture: 0 violation(s), business: 3 violation(s)
  [b10] src/modules/im/service.zig:29  empty catch block swallows errors
  [b4]  src/modules/im/gateway.zig:90  @ptrCast on ctx.user_data
  [b4]  src/modules/im/api.zig:39      @ptrCast on ctx.user_data
summary: FAIL — 3 new violation(s)          # exit 1 → `zmodu ci` 开箱即红
```

三个根因，各自独立：

**1. 模板把 `catch {}` 写进生成物（b10）** — `generateAgentModule` 2 处、`generateImModule` 1 处。
改为带日志的 best-effort 忽略（`std.log.warn` + `@errorName`），审计与真实错误处理都正确。

**2. b4 对"取路由 State"误报** — 被点名的那两处是 WS `on_connect` 回调里的
`@ptrCast(@alignCast(ctx.user_data orelse return null))`，目标是 `*ImApi` / `*ImGateway`，
**正是 `user_data` 该有的用法**。误报的根源是 b4 写于 `auth_info` 与 `user_data` 分离之前
（`Server.zig` 现在注释明说二者已拆开），于是把合法的 State 取值也当成了 AuthInfo 反模式。

**新增 `Context.state(T)`**（`src/api/Server.zig`）作为 State 的正规入口：

```zig
// 之前：每个调用点手写 cast，且 `orelse unreachable` 在 ReleaseFast 是 UB
const self: *ImApi = @ptrCast(@alignCast(ctx.user_data orelse return null));
// 之后：cast 收在一处，缺 state 是具名错误
const self: *ImApi = ctx.state(ImApi) catch return null;
```

b4 的报错文案同步改为指向它（`use ctx.state(T) for the route state`）——规则命中后有了明确去处，
而不是只留一句"读 attrs"。**活代码里 3 个模板站点**全部改用 `ctx.state(T)`：im `api.zig` 的
WS `wsConnect`、im `gateway.zig` 的 `onConnect`、以及 agent/im `service.zig` 的 3 处
`catch {}` 改成带日志的 best-effort 忽略（见下条）。`main.zig` 里另有一处
legacy `RouteGroup` 扩展模板的 `resolve2` 也一并改成了 `ctx.state(T)`，
但那整块在 `if (false) { … } // ext/ removed`（`main.zig:5708-5824`，117 行）**死代码**里，
不参与生成——改它是为了一致性，不是修缺陷。

**3. `zmodu audit` 根本不看嵌套模块** — `collectBusiness` 的遍历是**固定两层、不递归**
（`src/modules/<模块名>/<文件名>.zig`），而生成器把 `--with-agent` 产出在
`src/modules/ai/agent/`——第 3 层。整个模块**从未被审计**，它的 `catch {}` 因此静默留在生成物里
（这就是同一次跑只报 im、不报 agent 的原因）。

改为一棵子树递归遍历（`lintModuleTree` / `collectModelStructsTree`），模块级标志
（b14 的"有无测试"）按子树聚合。**验证**：往 `src/modules/ai/agent/service.zig` 注入一条
`catch {}` → 现在被精确报出 `[b10] src/modules/ai/agent/service.zig:79`（修复前静默）。

**影响面**：本仓库的 `examples/` 无嵌套模块、框架自身无 `src/modules/`，所以该遍历收窄在本仓
零冲击；对**消费方**是行为变更——`zmodu audit` / `zmodu ci` 会开始报出此前看不见的嵌套模块违规。
修复后重新生成的工程：`business: 0 violation(s)` / `summary: PASS` / exit 0。

### 工具链自洁：`tools/zmodu/src/` 的 `catch {}` 字面量归零

`tools/zmodu/src/` 纳入 `check-production.sh` 的强制前缀（`SCAN_ROOTS`）后，该目录仍有 14 处
字面量命中。逐条核对后分两类：

- **3 处是真的** —— 生成器模板会把它发射进用户代码，即上面那节修的缺陷。
- **11 处是扫描器有意跳过的形态** —— `//` 注释 2、b10 规则自己的检测常量 1、喂给 linter 的
  测试 fixture 8。这些**不改语义**，只把拼写改成从两片拼起来
  （`const empty_catch_needle = "catch " ++ "{}";`，fixture 用
  `"… " ++ empty_catch_needle ++ ";\n"`），并重写了两条提到该模式的注释。
  改完 `grep -rn "catch {}" tools/zmodu/src` 与扫描器的判断**一致**，
  不再把 linter 自己的样例源码读成违规。

`src/` 下的同名命中（`std.testing` 清理、`defer … catch {}`，以及 `Middleware.zig` 中解释该规则
本身的注释）**保持原样**：扫描器按花括号配对跳过 `test` 块，测试清理里的空 catch 是惯用法。
判据始终是 `scripts/check-production.sh` 的退出码，不是 grep 计数。

### 工具链升级

- `0.17.0-dev.1970+67f39b551` → **`0.17.0-dev.2151+2ec5523d5`**（latest master dev build）。
  同步更新：`.github/workflows/ci.yml` 的 `ZIG_VERSION`、`README.md` / `README.zh.md` / `docs/QUICK-START.md`
  的安装示例。
- 升级前后**零代码改动**：`zig fmt --check src tools examples` 无漂移；`zig build test`
  **1167 passed / 21 skipped / 0 failed**（同一套数），无需为新工具链改任何源码或测试。

### 最佳实践文档修正与门禁收窄

一次针对 `docs/BEST_PRACTICES.md` 的自审发现"文档写的"与"机器查的"之间有落差，本轮把两边都收了。

**文档：7 处照抄即错的片段（`docs/BEST_PRACTICES.md`）**

- 「正确的内存管理」那段 `defer allocator.free(buffer)` 后 `return buffer` 是**静默 UAF**，
  改成两个真正确的形态（所有权随返回值移交 / `dupe` 出拷贝），原写法降级为显式反例。
- 并发范例用了 **Zig 0.17 已删除的 `std.Thread.Mutex`** 且 `Self` 未定义 → 改成 `std.Io.Mutex = .init`
  + 显式 `io` 字段 + `lock(io) catch return` / `unlock(io)`。
- `zigmodu.resilience.*` / `tracing.*` / `metrics.*` 三个**命名空间不存在** → 改为
  `zigmodu.CircuitBreaker` / `zigmodu.observability.DistributedTracer` 等真实路径。
- `CircuitBreaker.init(5, 30000)`、`.timeout_ms`（字段不存在）、`data.redis.Redis.init(allocator)`
  + `connect(host, port, .{})` 均为旧签名 → 按 `src/resilience/CircuitBreaker.zig`、
  `src/redis/redis.zig` 的真实签名重写。
- 部署节：`root_module.addDefine`（不存在）、`std.process.getEnvVarOwned`（已移除）、
  GitHub Action 的 `0.16.0` 版本矩阵 → 改成 `b.addOptions()` + `init.environ_map` + `ci.yml` 的 `ZIG_VERSION`。
- `zigmodu.extensions.ModuleTestContext` → `zigmodu.ModuleTestContext`；
  `zigmodu.extensions.AsyncEventBus`（**全仓无此类型**）整段删除，换成 `ThreadSafeEventBus` 真实示例。
- "examples 里没有任何代码用 `ai.Agent`" 等采样断言已失效 → 加时间标注并更新。

**文档：入册与口径**

- 补录 `TransactionJournal` / `recover()`、`SagaStep.timeout_seconds`（两条都写成"必须遵守"而非建议）、
  `jsonStruct`、`paramInt(T, key)`（**两参**）；`AGENTS.md` 补 `ai.AgentWorker`；
  `zmodu ci` 由 **5 步**更正为 **6 步**（含 `doctor`）。
- 版本口径三处互斥（v0.23 / v0.25 / 页脚"1.0"）统一到 **v0.26.0**；目录上移并补录 `## 🔄 现状复核`；
  纯伪码围栏加标注；自引用行号改成按内容定位。

**门禁：六处"写着但扫不到"全部收窄**

- `scripts/check-production.sh` 原先**扫到第一个 `test "` 即止** —— `Server.zig` 首个 test 在 1445 行、
  全文 4487 行，约 3000 行生产代码不检。改为**扫全文件 + 按大括号配平跳过 `test` 块**
  （先剥字符串/注释再计数，test 内的 `"{}"` 不会带偏）。副作用：在原本已强制的路径里新暴露 4 处并已修。
- 强制前缀 **7 → 10**（补 `src/ai/`、`src/extensions/`、`src/im/`），这 23 条裸 `catch {}`
  **逐条真实修复**（统一 `catch |err| std.log.debug/warn(...)`，行为不变），未使用豁免清单。
- 跨行 `catch {` + 换行 `}` 在 shell 与 `audit.zig` 两边都**可识别**了（此前只认单行）。
- `audit` b3 关键词补 `WITH`/`PRAGMA`/`TRUNCATE` 并加**词边界**（`withContext` 不再误判），
  同时抑制"纯常量比较"（`WHERE status = 'active'` 不再误报）。
- `audit` b17 改为**逐分配点判定**，消除"一处 `freeScanned` 洗白整个函数"。
- `check-deadcode.sh --update` 加**单调性断言**：超过基线时拒绝写入并 exit 非 0（需 `--force`）；
  `examples/**` 纳入扫描（当前 WARN 阶段）。

**HTTP / Testkit**

- `Testkit.dispatch` 新增 `DispatchOptions.query`。此前**任何 query 驱动路由都无法用 dispatch 测试** ——
  包括脚手架自己生成的 `list*`（读 `ctx.queryInt(usize,"pageNo",1)`）。收 percent-encoded 原样串，
  与 `path` 自带 `?…` 可共存（同名 key 后者胜）。

**修复：脚手架生成的 handler 从客户端分配器泄漏**

`generateModuleApi` 产出的 `list*` / `get*` 不释放 owned 返回值：

- `list*` → `repo.findPage()` 的 `PageResult.arena` 由 **`Client.allocator`（长生命周期）** 分配，
  而 `ctx.allocator` 是**每连接 arena**（`connFiber` 每请求 `reset()`）—— 回收不到它，属**永久泄漏**（每请求一页）。
- `get*` → `repo.findById()` → `Client.queryRow()`，其字符串字段按 `sqlx.zig` 自身注释
  "owned copies from the client's allocator and must be freed by the caller"。

实测（`std.testing.allocator` 下调 `queryRow` / `queryRowsOwned` 故意不释放）：`3 leaks`，
栈顶落在 `scanStruct(self.allocator, …)`，确认分配根在客户端分配器。

**关键陷阱**：`ArenaAllocator.free()` 是 no-op，所以用 `ctx.allocator` 去释放这些内存**不会报错、
也不会释放** —— 看起来修好了，实际照漏（我们的第一版修复正是这么写的）。正确做法是用**分配它的那个**
分配器：`list*` → `defer result.deinit(self.service.persistence.backend.allocator)`；
`get*` → `freeScanned(self.service.persistence.backend.allocator, …)`；
而 `create*`/`update*` 必须继续用 `ctx.allocator`（`bindJson` 从它深拷贝）。

**注意** `repo.insert` 返回入参的副本、字符串与入参**别名**，所以 `create*` 只 free 一次 ——
再 free `created` 就是双重释放。

**反证（生产形状）**：探针用 `std.testing.allocator` 作客户端分配器（可检测泄漏）、`Server` 拿到另一个
arena（复刻 `connFiber` 层次），真的 `dispatch` `list` 与 `get?id=1`：正确的释放 → **0 leak**；
`deinit(ctx.allocator)` + `get` 不释放 → **2 leaks**（`allocator.dupe(u8, str)` 的行字符串）。

**新增 API**：`PageResult.deinitArena()`（补 `QueryResult.deinitArena` 的对称缺口，后者此前全仓零使用）——
生成器**暂不使用**，因为 scaffold 出的项目 pin 已发布版本，用了会编译不过；等版本推进后再切。

**同类修复**：`examples/tenant-mgmt/src/modules/user/api.zig` 的 `getUser` / `listUsers` 有同样的
"拿 `ctx.allocator` 释放客户端内存"问题，一并改成 `backend.allocator` / `deinitArena()`。

**修复：脚手架模板 `test.zig.tpl` 是死模板**

`tools/zmodu/src/templates/orm/sqlx/test.zig.tpl` **从未被 `@embedFile`**（`orm_tpl.zig` 的 embed
列表里没有它），内容还是三个 `expect(true)` 空桩 —— 即"文档推荐、示例不示范、脚手架不产出"。
现在：`orm_tpl.sqlx_test` 嵌入该文件并在 `writeModuleFiles` 里为**单表模块**写出
`modules/<name>/test.zig`（`openMemorySqlite` 上的 repository 往返 + 一次打生成 POST 路由的
`dispatch` 断言），`generateScaffoldTestsZig` 同步写入 `test { _ = @import("modules/<name>/test.zig"); }`。
多表模块不产出（模板按 `model.<PascalModule>` 取类型，多表时类型名不成立）。
端到端验证：`zmodu scaffold` 单表 schema → 生成项目的 `zig build test` **7/7 pass**。

**示例**

- `examples/tenant-mgmt/src/tests.zig` 新增 3 条 `http.Testkit` 真用例：JWT 门（无 token 401 /
  正确 token 200 且 body 逐字节相等 / **换 secret 的同形 token 必须 401**）、权限门
  （`tenant:read` 403 → `tenant:suspend` 200 且状态真的落库）、**跨租户隔离**
  （token 的 `aud` 决定可见行；猜别租户的行 id 得 404；`X-Tenant-ID` 与 aud 冲突 403）。
- 顺带修 `examples/tenant-mgmt/src/modules/user/api.zig`：`getUser` 不释放 `queryRowPartial`
  返回的 owned 字符串（`std.testing.allocator` 抓到 3 处泄漏）。

**修复：`LogRotator` —— 公开导出但从未被编译**

`zigmodu.observability.LogRotator` 是正式导出的组件，但**全仓零调用**；Zig 惰性分析函数体，
所以 `rotate()` 里 0.17 之前的 `std.Io.Dir.cwd().rename(self.io, old, new)`（正确签名是 5 参
自由函数 `Dir.rename(old_dir, old_sub, new_dir, new_sub, io)`）一直没报错 —— **任何用户一调用
`write` 就编译失败**。`zig build test` 抓不到，因为"编译所有源文件"的测试只做文件级 import，
不进函数体。修法：改正 2 处 `rename`；新增 `initIn(allocator, io, dir, …)`（`init` 仍写 CWD，
`initIn` 指向 `tmpDir`），并**补一条真正实例化它的测试**（按大小轮转 + 断言各代内容 + 超代数文件
不存在），否则它会继续腐烂。

**门禁：补齐最后三处 + 两个盲区**

- `check-production.sh` 强制前缀补 `src/log/` 与 `src/runtime/`，并修掉这两处最后 3 条 WARN
  （`StructuredLogger` 轮转 rename 的静默 `catch {}` 改为"`FileNotFound` 静默、其余上报一行
  stderr 且不递归走自身 log"；`timer_wheel` 测试辅助里的 `catch unreachable` 改为 `@panic(…)`，
  消除 ReleaseFast 下的 UB）。**现在 0 warning。**
- **`catch {},` 盲区**：switch 分支 / 初始化列表里的尾随逗号既不是 `{}` 也不是 `{};`，被
  `body_kind` 判成 `other` 而**完全逃检**。shell 扫描器与 `audit.zig` 的 `catchBodyKind`
  两边都修，并各加反证用例（CLI 侧 b10 期望由 3 条升到 5 条）。
- `check-deadcode.sh`：`examples/**` 从 WARN **提升为强制**（`EXAMPLES_MODE` 删除），两个 scope
  各自独立扫描后比对基线；7 条既有死代码全部处置（6 条未使用的 `const std` 导入 + 1 个零读取的
  私有字段），基线保持 32 不变。JSON 解析失败改为 fail-closed。

**开发者体验**

- `zig build zmodu` 现在**同时安装**二进制。此前只 build+run，`zig-out/bin/zmodu` 会静默保留
  上一次 `zig build` 的旧版本，调用方驱动到陈旧 CLI（本轮就被这个坑过一次）。
- `http.Testkit` 删除查询解析的手工孪生实现，改为直接调 `Server.zig` 的 `parseQueryInto`
  （为此把 `parseQueryInto`/`percentDecode` 开放为 `pub`）—— 测试与线上**不可能**再对同一串
  查询参数有不同解读。

**示例目录收敛：删除 2 个重复样板**

`examples/` 由 20 个目录收到 **18 个（17 个示例 + `_shared`）**。判定标准是"每个目录必须唯一承载
一项框架能力"：

- 删 **`shopdemo-zent`** —— 结构性重复：与 `shopdemo/generated-sample` 是**同一个 `order` 模块**，
  只换 zent 持久化，而 zent 已由 `zent-modulith` 演示。
- 删 **`tenant-ai`** —— 与 `ai-ops`（AI 流水线 + HTTP 审批队列）和 `tenant-mgmt`（租户隔离）双向重叠。
  删前核实其"独有"的两项并不独有：`workflow.toMermaid`（`src/ai/workflow.zig` 单测）、
  `skill_export.toOpenApi/toSkillsJson`（`src/ai/skill_export.zig` 单测 + `zmodu ai` CLI smoke）、
  `SkillRegistry`（自有单测）—— **不留无人调用的公开 API**。
- **保留** `metaverse-creative`（结算链路无替代）与 `zmsaas`（含前端，`Preflight` + 池/积压接线参考）。

同步改动：`ci.yml` 的构建列表（两处）、`doctor` 循环、`test` 循环；`examples/README.md` 索引与段落；
`docs/AI_DEV_GUIDE.md` / `AI_SKILLS.md` / `AI_ORCHESTRATION.md` / `ZMODU_CLI_INTEGRATION.md` /
`PRODUCTION_ROADMAP.md` 中指向这两个示例的句子（改为描述能力或改指 `ai-ops`）；
`src/tests.zig` 里列举 `src/ai` 消费者的注释。历史审计记录里的提及**不改写**，只加口径说明。

**定位缺口：性能门禁与运行时观测**

- **性能第一次有了真门禁**。此前 CI 的 benchmark job 自己写着 "the gate (it must compile and complete)" ——
  threshold 比较因 repo 无 `gh-pages` 分支而 `continue-on-error`，**从不生效**；而且基准全是旧定位的微基准
  （`scanModules` / `App lifecycle` / `CircuitBreaker` / `RateLimiter` / health / `findById`），
  **四个护城河方向一条都没测**。现在：`src/benchmark.zig` 补 6 条运行时基准
  （`RingBuffer SPSC` / `Mailbox post+drain` / `TimerWheel` / `HotBus 8sub` / `ObjectPool` / `Sequencer`，
  整套 ReleaseFast 约 1.3 s，确定性、无 socket/线程/sleep），新增 **`scripts/check-bench.sh`**
  用 `scripts/bench-baseline.json` 做基线对比（默认 2.0× 放量，`BENCH_THRESHOLD` 可覆盖；
  基线有而本次没跑的只 WARN 不失败；`--update` 带单调性保护，超阈值须 `--force`）。
  基线对比在**临时目录**跑二进制，不会往工作树丢 `bench-results.json`（为此 `build.zig` 加了只编译不运行的
  `benchmark-build` step）。该门禁接进 CI 的 benchmark job 作为**硬失败**一步，放在历史 hook 之后 ——
  **随后被它自己抓到一次假阳性，并因此做了两处加固**（都写进了 `check-bench.sh` 的头部注释）：
  ① **每个指标取 median-of-3**（`src/benchmark.zig` 的 `median3`；`validateModules x100K` 同机同码三次实测
  446 / 292 / 295 ms，1.5× 的跨运行带宽落在 2.0× 判决窗口里，而被报的代码一行没改）；
  ② **把套件的日志流从测量关键路径上摘掉** —— `validateModules` 每次调用写一行 `info:`，
  每个样本约 7 MB，落到**文件**时 ~280 ms、走**管道**（有消费者）只要 ~63 ms：
  这几个指标此前测的是宿主机的 writeback，不是代码。改成管道过滤后它们降到 **0.23–0.25×**
  （`validateModules x100K` 276→68 ms），其余指标变动 ≤1.10×，基线随之重录。
  阈值仍是 2.0（**没有**为了让门禁变绿而放宽），且反证过：把基线除以 10 立刻 exit 1 并打印三个样本。
  剩余风险已写明：baseline 是绝对时间、录自本机（CI 的 `ubuntu-latest` 首次跑可能需在 runner 上重录）。
  失败步会跳过后续步骤，而回退时正是最需要那条历史数据的时候。
- **`RuntimeStats` 有了出口**。数据早就在（`messages_dropped` / `timer_lag_max_ms` / `handler_errors` …），
  但全仓只有 `rt.stats()` 结构体、实际消费是示例里 `print` —— 生产里**无法对邮箱积压、消息丢弃、
  定时器滞后告警**。新增 `Runtime.MetricsBridge(MetricsT)`：起服务时 `init(&rt, metrics)` +
  `metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge)`，抓取时采样 8 条 `zigmodu_runtime_*`。
  对 `MetricsT` 鸭子类型化，runtime 层不依赖 observability 层。
- **修掉一个 use-after-free（写这条桥的测试时撞出来的）**：`PrometheusMetrics` 的
  `counters`/`gauges`/`histograms`/`summaries` 四个 map 原先把实体**按值**存，
  而 `create*` 返回 `getPtr` 的地址 —— **后续任何一次 `create*` 触发扩容，此前发出的所有指针立刻悬垂**。
  现有示例只建 4 个 gauge，靠初始容量侥幸没触发。改成 map 存 `*T` + `allocator.create/destroy`，
  对外 API 不变（调用方无需改）。回归测试 `issued metric handles survive registry growth`
  一次建 64 个句柄、创建完再回头写入 —— **在修复前它会崩**（`write after free` / `0x5555…` 段错误）。

**数据层：补齐 sqlx 的能力缺口 + 清掉一套死抽象**

- **`sqlx.Transaction` 补齐相对 `Client` 的缺口**（`src/sqlx/sqlx.zig`）。此前 `Client` 有 58 个方法、
  `Transaction` 只有 16 个，同一操作两种签名，缺的方法直接让调用方撞编译错误。
  本次**只做加法、零签名改动**（真实消费者 `zigshop` 在用 Transaction：`page/persistence.zig`、
  `bargain/{service,persistence}.zig`、`trade/service.zig`）：
  补 `queryRowsPartial(Ctx)`、`queryScalar(Ctx)`、`queryRowBorrowed(Ctx)`、`queryRowPartialBorrowed(Ctx)`、
  `findOne(Partial)(Ctx)`、`findAll(Partial)(Ctx)`、`batchExec(Ctx)`、`ping(Ctx)`，以及 `queryRow/queryRowPartial/queryRows` 的 `*Ctx` 形式。
  `findOne*`/`findAll*` 的 SQL 拼接逐字照抄 Client 侧，`validateIdentifier` + `validateSqlFragment` 两道闸一行不少。
  另把"**为什么 Transaction 要多一个 `allocator`**"写进了方法文档：事务里扫出的行必须活过事务自己的扫描作用域，
  所以由调用方给分配器；`Client` 用池/客户端分配器代劳 —— 这个差异是**设计**不是遗漏，此前没人写下来过。
  新增对照测试：同一查询在 Client 与 Transaction 各写一遍断言逐字段一致（`:memory:` 下必须
  `max_open_conns = 1`，否则两侧拿到不同连接 = 两个空库，对照会退化成"拿空气对比"）。
- **删除 `src/persistence/Database.zig`** —— 一套遗留的 vtable 抽象（自带 `VTable`/`QueryParams`/`ParamValue`），
  与真正在用的 `Orm(Backend)` + `SqlxBackend` 并存却**没有从 `root.zig`/`data.zig` 导出**，
  全仓唯一引用是"编译所有源文件"那个测试。死抽象比缺抽象更贵：读者会把它当数据层入口。
- **文档纠正**：`docs/ZENT.md` 新增「与框架自带那条的关系」—— 框架自带的默认是 sqlx
  （`build.zig.zon` 的 `.dependencies = .{}`，**zent 不是框架依赖**），ZENT.md 的"默认选 zent"
  是**新项目选型建议**，不是框架默认值的变更；`src/data.zig` 的 `SqlxBackend`/`Repository`
  doc 加了指认；`AGENTS.md` 补一行"zent 是平行栈、不共享事务"。
  `docs/BEST_PRACTICES.md` 新增「`*Ctx` 后缀 vs `ctx` 字段」：**共享句柄（`Client`）只能传参/后缀**
  （把 per-request 的 `SqlContext` 塞成它的字段就是数据竞争），**按请求拷贝的副本（`SqlxBackend`）用字段**
  —— 看起来不一致，其实各自都对。

**脚手架：生成物端到端租户安全 + 单表 test.zig 的模型名错配**

- **`zmodu scaffold` 生成的代码现在端到端租户安全**。上一轮给了 `Repository` 编译期租户守卫，但生成的
  `api.zig` 仍在调 `*Unscoped`（显式绕过守卫），租户过滤还是靠人。现在：
  - `service.zig` 为租户表补 `create<X>ByTenant` / `update<X>ByTenant` / `delete<X>ByTenant`。
    其中 **create 的关键性质是"先按请求身份把租户列盖章、再插入"** —— 客户端在 body 里声称什么租户都不算数
    （否则任何客户端都能往别的租户插数据）；update/delete 走 `updateForTenant` / `deleteForTenant`。
  - `api.zig` 的租户表 handler 通过 `ctx.tenantId()`（JWT catalog 中间件写的 attr）取租户，
    **取不到就 401 拒绝，绝不回退无作用域方法** —— 缺身份 ≠ 放行。生成物里 `*Unscoped` 调用数为 **0**。
  - 新增 `test_tenant.zig.tpl`：给租户表单表模块加一条**跨租户隔离**测试（四断言：body 声称别的租户仍落在自己名下 /
    list 只有自己那行 / 猜别人的行 id 得 404 / 无租户 attr 得 401）。
  - **非租户表的生成物逐字节未变**（同一份非租户 schema，改动前后各生成一次 `diff -r` 无差异；
    唯一差异是 `build.zig.zon` 的 `.fingerprint`，那是该字段本身非确定 —— 同一个二进制连跑两次也不同）。
    **该非确定性已修**（见下方「脚手架：行数语义与可复现输出」）。
- **修掉一个真缺陷：单表模块的 `test.zig` 模型名错配**。模板在 6 处（`model.X` 与
  `svc.create/get/delete<X>`）用了模块名 `<<PASCAL_MODULE>>`，但那些名字是**表派生**的
  （`strip_prefix_len = commonTablePrefix(tables)` 是**全局**前缀，所以只要 schema 有共同前缀
  ——`shop_*`/`tbl_*` 这类**主流情况**——模型名就会剥掉前缀而模块名不会）。
  实测：模块 `shop/product` 的模型是 `model.Product`，而生成的却是 `model.ShopProduct` →
  `error: … has no member named 'ShopProduct'`。修法：加第三个占位符 `<<MODEL_NAME>>`
  （`orm_tpl.expandOrmTest`），只把**表派生**的 6 处换过去；模块派生的 `…Persistence`/`…Service`/`…Api`
  保持 `<<PASCAL_MODULE>>`。红绿：修复后生成的工程 `zig build test` 14/14 通过；把模板改回旧行为重新生成
  则 `RED_EXIT=1` 并报出上面那条 `no member named 'ShopProduct'`。

**脚手架：行数语义与可复现输出**

- **跨租户改/删不再谎报成功**。生成的 `update/delete<X>ByTenant` 原先把 `updateForTenant`/`deleteForTenant`
  的受影响行数 `_ =` 丢掉，handler 随后**无条件** `wrapSuccess` —— 而框架的契约明确写着
  "0 means the row belongs to another tenant (guarded no-op)"。现在这两个方法返回 `!u64`，handler 把 `0`
  映射成 **404**（并发事件只在 `rows > 0` 时才发）。无作用域路径保持原样。
  新断言：用租户 A 的身份改/删租户 B 的行必须得 404，且**读回逐列证明 B 的行没被改动**；
  反证（还原成无条件 200）→ `expected 404, found 0`，2 条测试变红。
- **脚手架输出可复现**。`.fingerprint` 原先是随机的，同一二进制、同一 schema 连跑两次 `diff -r` 就 exit 1。
  现在从包名**确定性派生**（`checksum = Crc32(清洗后的包名)`、`id = Wyhash(0, 包名)`，遵循工具链
  `Maker/Package.zig` 的 `validate` 要求）。实测两次生成 `diff -r` **exit 0**，且 `zig build` 既不报错
  也不改写它（md5 前后一致）。附带：zon 里已有 fingerprint 时不再为了取随机值跑一次 `zig build`
  （scaffold 更快、不需要网络）。
- **修掉生成的响应体是非法 JSON**：`shared/response.zig` 的 `wrapSuccess` 用了**普通字符串字面量**
  而不是 format string，`{{\"code\":0…` 原样落进响应体 → **每个生成项目的成功信封都是
  `{{"code":0,…}}`**，任何 JSON 解析器都拒。而生成的测试只做**子串**断言（`"code":0`），
  两种写法都能匹配 —— 所以这个 bug 一直没被自己的测试抓到。已改成单花括号。

**验证**：`zig fmt --check src tools examples` · `check-production` · `check-deadcode` ·
`check-version` · `check-tenant-scope` · `check-bench` 全部 exit 0；
`zig build test` **1293 / 1314 passed（21 skipped，0 failed）**（`Database.zig` 自带的那条用例随文件删除 −1，
新增对照测试 +2、租户生成器单测 +4）；新测试连跑 5 次稳定通过（同一位置 178/1206），确认不是
`:memory:` + 连接池 的 flaky。租户链路另有一次独立复现（带共同前缀的两表租户 schema → 生成 →
`zig build test` **16/16**，并用"让 handler 忽略请求租户"做了**行为级反证**：隔离测试红在
`expected 401, found 0`）。
`examples/tenant-mgmt` 6/6、`examples/shopdemo` 13/13；`bash scripts/check-bench.sh` exit 0。

**定位级接线：三处"两边都齐、中间没接"**

都是"机制早已在树里，缺的只是连线"，不是新功能。

- **请求预算送进存储**。`request_timeout_ms` 原先**只在 handler 返回后**比一下耗时、超了改发 408
  （`Server.zig` 的 `elapsed_ms > …`）—— **不打断任何东西**，慢查询照样跑完、照样占着连接池；
  而 `SqlContext`（唯一的截止机制）在 sqlx 里有 6+ 处检查点，却**从没有 HTTP 侧调用者**。
  现在：`Context` 在请求进入时 `setDeadline(request_timeout_ms)`，`ctx.sqlContext()` 一行接进数据层，
  新增 `Orm.withContext()` —— **一次覆盖该请求的所有查询**（而不是 19 个方法各加变体）；
  `SqlxBackend` 持一个 `ctx` 字段并改走 `*Ctx` 变体（补齐了缺失的 `queryScalarCtx` /
  `queryRowBorrowedCtx` / `queryRowPartialBorrowedCtx`）。默认 `.{}` = 无截止，**不接线时行为与改动前完全一致**。
  语义边界写进了文档：`isDone()` 只拒绝**尚未开始**的语句（sqlx 无飞行中取消），所以这是
  "防止预算耗尽后继续堆查询"，不是"到点砍掉正在跑的那条"。
- **多租户隔离变成编译期强制**。`Repository(T)` 的 17 个无作用域方法此前**零租户感知**，
  防线是"人记得调 `*ForTenant`"。现在模型声明 `sql_tenant_column` 即开启守卫：无作用域方法
  `@compileError`，错误信息点名对应的 `*ForTenant` 与逃生舱 `*Unscoped`（安全的名字最短）；
  **未声明的模型零影响**（`tenant_column orelse return`），既有项目升级不用改代码。
  `zmodu scaffold` 生成的 `model.zig` 默认带上该声明。新增 `scripts/check-tenant-scope.sh`
  用三个 fixture（守卫开火 / 逃生舱可用 / 未 opt-in 不受影响）锁死行为并进 CI。
- **trace id 与日志闭环**。框架的 `tracingMiddleware` 手里有 trace id，却**只写响应头不写 `ctx`**，
  所以 handler 读不到、日志也无法关联。现在它复用一个合规的入站 `X-Trace-Id`（长度与可打印性
  有界 —— 该头客户端可控），否则生成，并 `ctx.setTraceId()`；配套新增 `Context.logScope("module")`
  （一行拿到已带 id 的日志作用域）与 `LogScope.withField()`。**走 `ctx.logScope` 而不是
  `LogScope.scope` 是有意的**：后者不报错、只是静默少一个字段。
  `examples/tenant-mgmt` 删掉了自己那份替身中间件，改用框架的 —— 实测同一请求的两行日志带同一个 id。

**验证**：以上三件完成后 `zig fmt --check src tools examples` · `check-production` ·
`check-deadcode` · `check-version` · `check-tenant-scope` · `check-bench` 全部 exit 0；
`zig build test` **1280 / 1301 passed（21 skipped，0 failed）**，主库 1184、`zmodu` CLI 79；
`examples/tenant-mgmt` 6/6。关键改动均带反证：把 `SqlxBackend.queryRow` 退回非 ctx 变体后，
新测试立刻报 `expected error.Timeout, found .{ .id = 1, .name = "Alice", .age = 30 }`。
另有一次端到端验证：`zmodu scaffold` 生成单表项目 → 其 `zig build test` 跑真实 Testkit 用例
（repository 往返 + POST 路由 dispatch）**9/9 pass**，且在"客户端分配器可检测泄漏 + ctx 为独立 arena"
的生产形状下 **0 leak**；把释放改回 `ctx.allocator` 后同一探针立刻报 **2 leaks**。
`zig build zmodu` 的安装行为也做了红绿验证（删掉 `zig-out/bin/zmodu` 后重新生成成功）。

## [0.26.0] - 2026-09-18

> **⚠️ 行为变更**：`Tool.action` 默认值收紧的后果（内置技能已声明类别）、`Server.fromEnv` 签名变更、
> `MessageQueue` 的部分后端 `publish` 由"静默丢弃"改为返回错误、`zmodu verify` 对无表模块放宽、
> `zmodu ci` 改为读 `.zmodu/audit-baseline.json`（与 `zmodu audit` 口径一致）。

### 新用户第一公里（本次最大的一块）

- **`README.md` / `README.zh.md` / `docs/QUICK-START.md`**：工具链钉版从**已被 ziglang 镜像回收**的
  `dev.1567` 改成 CI 同款 `0.17.0-dev.1970+67f39b551`（并注明"dev 版会被回收，以 `ci.yml` 的 `ZIG_VERSION` 为准"）；
  `brew install zig`（stable）从主安装方式降为反例说明；模块写法改 `pub const UserModule` + 正确传递；
  **补上缺失的 `build.zig.zon` 依赖声明**（本地 `.path` 与 tag 两种 + `-Ddb=` 收窄说明）；补 `app` 的构造、
  `generateDocs` 的第 4 个参数、`build.zig` 缺失的 `-Ddb=` option 与 `run`/`test` step。
  **验证方式**：把修完的围栏**抽出落盘**在临时工程里真编译 —— QUICK-START 四段与 README 两段全部
  `zig build`/`run`/`test` 通过；无法脱离业务代码的片段显式标注为 fragment。
- **`AGENTS.md`**：`ctx.paramInt("id")` → `ctx.paramInt(i64, "id")`、`ctx.json(200, .{…})` → `ctx.jsonStruct(200, .{…})`
  （共 6 处 + `docs/elegant-code-patterns.md` 4 处）；并把那句夸大的"门禁会抽查文档"改成**准确列举**覆盖形态。
- **`DocSnippets` 门禁扩容**：新增两类检测（值形态 `ctx.json(<数字>, .{`、缺类型参数 `paramInt("`），
  配"检测器自身单测"（合法写法不误报）；围栏内整行 `//` 注释不再判定（注释是"关于代码"的说明，避免误报）。

### 框架内缺陷修复

- **`zmodu scaffold` 生成的项目现在真能编译**（此前 9 个编译错）：修模板 4 处 —— `shared.errors.BizCode`
  的枚举字面量、`?i64` 的比较、生成的 `tests.zig` 不可编译、`.nest` 非 fmt-clean。
  **实测：生成项目 `zig build` / `zig build test` / `zig fmt --check src` 全 exit=0。**
- **`zmodu verify`**：① 支持**无表模块**（读 `module.zig` 的 `pub const info` 即接受缺 `persistence.zig`，
  并在输出里声明宽松规则）→ `examples/tenant-shop` 的 `zmodu ci` 首次 PASS；② 修 **SIGABRT**
  （`checkCompileWith` 把字符串字面量塞进 `details` 后被 `free`）；③ `verify` 单跑现在打印逐条错误、支持 `-j/--json`。
- **`PluginManager`**：修 test 块 API 漂移（`realPathFileAlloc`、`close(io)`）并**接进测试根**（此前是死测试）。
  复活后暴露生产 bug：`unloadPlugin` 在 `remove` 前 `free` 了 map 的 key → **条目永久残留**（已记录，未改生产）；
  另发现 `loadAllPlugins` 引用不存在的 `self.io` 字段（该函数无法编译）。
- **`MessageQueue`**：`redis`/`kafka` 后端的 `Producer.publish` 原是**空臂 → 静默丢消息**，现返回
  `error.BackendUnimplemented`，文件头新增逐后端能力清单；新增测试锁定该错误。
- **ORM 模板不再生成未用 import**：service 模板改为条件 import（`<<STD_IMPORT>>`，只在真用 `std.mem.*` 时生成），
  persistence/api/types/tests 生成物去掉未用 import。**验证**：重新生成项目的 `zmodu deadcode` 从 `dead: 7` → **0**，
  且生成项目的 `zmodu ci` 从 FAIL 变 **PASS**（六种生成变体全验）。
- **`zmodu ci` 口径 bug**：`auditJsonFor` 不再硬编码"全部违规计入 added"，改为读 `.zmodu/audit-baseline.json`
  （复用既有 `compareBaseline`）→ `zmodu ci` 与 `zmodu audit` 口径一致。
- **`Server.fromEnv` 从死代码救活**：签名改为 `*const std.process.Environ.Map`（= `init.environ_map`），
  加 `envInt` 容错 + **2 个测试**；`examples/production-deploy/README.md` 同步（含 `enable_http2` → `setHttp2Enabled(true)`）。
- **AI 闸门**：22 处内置技能补 `.action`（读/提议/执行；不确定的留 `.execute` fail-closed）；新增
  `SkillRegistry.auditPolicy` + `ai.PolicyHealth`（按类别体检，`Guard.isInert()` 的盲区有兜底）；
  `Workflow` 加 `guard` 字段并透传到 `.agent` 步骤；`--with-agent` 模板改为带 `guard`（默认空 = 惰性）并注入
  `tenant_id`/`user_id`。
- **版本护栏覆盖 `tools/`**：`scripts/check-version.sh` 新增 4 项检查（含 scaffold 的钉版与依赖 hash 非占位），
  scaffold 的所有版本引用改为单一来源 `ZMODU_VERSION` + comptime hash 前缀断言。

### 示例与文档

- **示例 `zmodu ci` 从 9 FAIL → 17/18 PASS**：清掉 8 个示例的未用 import/字段/函数；`shopdemo`(99)、
  `shopdemo-zent`(4)、`metaverse-creative`(12) 的 b4/b13 经 CLI `-u` 收进各自 `.zmodu/audit-baseline.json`
  （b4 命中的全是 router State 回取 `@ptrCast(ctx.user_data)`，`AGENTS.md` 明确允许）。
- **导出孤儿定性**：12 个"root 导出但零消费者"的项逐个判定为 **(b) 用户面向公开 API**（`FrozenMap`/`LoadBalancer`/
  `MessageQueue`/`PluginManager`/`HotReloader`/`IntegrationTest`… 各有文档背书或"按设计不接"的理由），
  改动**纯注释**（`git diff -U0` 校验零代码改动），无一删除。
- **文档**：`docs/UPGRADING.md` 补 v0.22–v0.25；`docs/BEST_PRACTICES.md` 的审计清单回填 23 条 ✅（逐条带证据）；
  `docs/ZENT.md` §8 与示例对齐（`deinitRows`）+ 版本 → v0.67.0；`MODULE_LAYERS.md` 写清 `Backend` 与 tenant_id；
  `docs/README.md` 收录 3 篇孤儿文档；`examples/README.md` 补齐 test-step 清单。

### 其它

- 两点**已知未修**（记录在案）：`PluginManager.unloadPlugin` 的 free-before-remove（UAF）；
  多表 `scaffold` 不写 `root.zig` 且 `--with-events` 变体的 publish 写死 `.id`（PK 名推导缺失）。

## [0.25.0] - 2026-09-18

### 集群：门面 + 选主状态机补完

- **`ClusterBootstrap` 补成完整门面**：`tick()` 现在一次做完 `membership.runOnce()` → `view.sync()` →
  **`raft.tick()`**（此前从没人驱动选举）；配了 `.transport` 时 `start()` **启动入站监听**并把连接交给
  `RaftTransport.handleConnection` 分发（端口起不来就 `error.RaftInboundListenFailed`，不静默降级），`stop()` 对应停掉；
  新增 `pick(key)`（rendezvous 选点）与 `healthJson(allocator)`，请求路径不必再自己拼 view/health。
- **修一个真 bug**：`start()` 把 `ElectionTransport` 存在**栈局部**再取地址给 `RaftElection` → `start()` 一返回即悬垂，
  第一次选举会跳到死函数指针（新测试实测 `Bus error`）；改为存字段。
- **选主状态机**：单节点（`cluster_size == 1`）**首次 election 即当选**（此前永远选不出）；`max_append_entries` 真接上
  （落后量大时分批，`@max(1, config)` 防 0 卡死）；`appendEntry` 末尾补 `advanceCommitIndex()`（单节点写入不再等心跳）。
  口径保持"只数 peer 票"，写进了 `startElection`/`handleVoteResponse`/`hasQuorum` 注释。
- **修一个真 bug**：`randomElectionTimeout` 在 `min == max` 时 `% 0` → **panic: division by zero**（退化为 `max(1, min)`）。
- **LB 有意不接**：`LoadBalancer` 的数据源是 PeerDiscovery 的「服务名→Peer」+ canary/计数，与读侧的「成员 id→地址+健康」
  是两份事实；每 tick 镜像会破坏 `sync()` 稳态零分配。已在 `docs/DISTRIBUTED.md` 写明接入点与分工。

### 2PC 持久化协调日志（in-doubt 有解）

- 新增 `src/core/TransactionJournal.zig`（`zigmodu.TransactionJournal`）：append-only、**只 INSERT 不 UPDATE**、
  DDL 方言中立、走 `data.SqlxBackend` 领域缝；不配 backend 时退回内存。
- 写点：`begun`（带参与者名单）→ **`prepared` 先落盘再返回**（崩溃窗口）→ `committed`；`abortPhase` 先写 `aborted` 再回滚。
  配了日志即 **fail-closed**（写不进去就报错、不前进）。
- `recover()` **只报告不决策**：返回"prepared 且无终态"的事务 + 参与者，供调用方自行重试/回滚。
  8 个新测试，含"preparePhase 后丢掉协调者 → 新实例 recover 读出 in-doubt"的崩溃恢复用例。

### Workflow / Saga

- `SagaStep.timeout_seconds` **真正生效**：事后判定（步骤耗时超预算 → 持久化 → 逆序补偿**含该步** → 终态 `.timed_out`
  → 返回 `error.SagaStepTimeout`）；`0` 表示不做预算。字段注释、`SagaStatus` 注释与 `docs/WORKFLOW.md` 同步。

### alpha-engine 参考实现推进到 P1–P3

- **P1 观测与容错**：HotBus 扇出（慢 audit worker 被丢弃计数、O(1) metrics sink 一条不漏）+ 被监督停掉的
  `FaultyFillReporter` + 可见背压；**四条断言**（`bus.dropped > 0`、`dropped_full > 0`、`stopped_by_supervisor`、`timer_fires > 0`）。
- **P2 模块化**：拆成 `market → book → alpha → risk → exec` + `audit`（跨模块零 import，消息统一放 `contracts.zig`）；
  `zmodu doctor`（7 modules / architecture OK）与 `zmodu ci` 六步全 PASS。
- **P3 AI 提议侧**：日终快照 → `ai.AgentWorker`（**注入 executor**，离线确定性）→ `ai.ProposalPipeline`
  （`guard(.propose)` 允许 → `ai.RiskReview` → `guard(.execute)` 被拒 → `execute_not_permitted`）→ **非 agent 路径**的
  desk 授权后由 `PaperExchange` 成交。两条 P3 断言（`denied_execute_class > 0` 且 **`effect_reached = 0`**、提议→授权→成交闭环）。

### 示例与文档

- **`shopdemo` 的 12 个测试真正跑起来**（此前不在导入图里，Zig 从不编译）：新增测试根 + test step，
  顺带暴露并修掉一处腐坏（`generated-sample/service.zig` 引用不存在的 `OrderEvent`）；`zent-modulith` 加 test step（`smoke.sh` 43 checks）。
- CI 的 test-step 循环补 `shopdemo`；`doctor`/`audit`/`test` 三个子集循环各加一行"Subset by construction"说明。
- 元数据/文档一致性清扫：`metaverse-creative`、`tenant-mgmt` 的旧版本号；`docs/BEST_PRACTICES.md` 两份审计清单标 ✅ 并加图例；
  `docs/DISTRIBUTED.md` 的门面/2PC/选主播述全部改成事实。

## [0.24.0] - 2026-09-17

> **⚠️ 破坏性变更**：删除 7 个示例文件/目录（`examples/testing/`、`examples/deprecated/`、`examples/cluster-demo/`、
> `examples/example_tests.zig`）—— 内容已分别并入 `examples/basic/src/tests.zig`、`examples/distributed/README.md`，
> 或属零引用占位。其余为纯新增/修复。

### 文档与示例品质（2026-09 复核批次）

- **导出面文档**：`src/root.zig` + 六个领域 barrel（http/data/security/ai/observability/runtime）新增
  **463 行 `///`**，覆盖率从 root 14% / barrel 4% 提到 **100%**（每条一句话：是什么 + 什么时候用）。
- **两个"死旋钮"接线**（文档承诺行为、代码零读取）：`Application.Config.max_dependencies` 现在真的在启动期
  做超限告警（`warnOverDependencyLimit`）；`Server.Config.connection_stack_size` 真的用于 accept 线程
  （低于平台下限才抬升）。两者各有测试。
- **可执行文档修正**：`Application.init(io, allocator, name, modules, Config)` 的真签名示例、`app.runtime()` 的
  `try` / comptime capacity、`ClusterView` 的 refcount 表述、`tuneSocket` 的 keepalive 说明。
- **`DocSnippets` 门禁扩容**：新增两类模式（`try app.runtime().spawn(...)` 整链、`Application.init(allocator` 首参错），
  并把 markdown 扫描**递归到 `docs/**`**（跳过插件目录）；两处旧片段顺带修正。
- **大文件可导航**：Server(4392) / KafkaConnector / Middleware / GrpcTransport / Http2Server / ai-workflow /
  redis / sqlx 加 `//! §N` 目录 + 正文 `// ==== §N ====` 锚点（`grep "§3"` 可跳）。
- **公开 error set 全成员文档**：12/12（新补 8 个 set / 94 条成员注释）；5 处 `@compileError` / `@panic` 文案
  统一成"期望形态 + 怎么改"。

### 修复

- **outbox 占位符错配**（真 bug）：`8977184` 给 INSERT 加了 `tenant_id` 列与第 6 个 `?`，而全仓 13 处调用方
  一律按 5 参绑定 → 参数错位、`updated_at` 无人绑定 → `NOT NULL constraint failed: event_outbox.updated_at`。
  非租户 SQL 改为 `VALUES (?, ?, NULL, 0, 0, ?, ?, ?)`（占位符回到 5 个，与调用方逐一对齐），租户变体保留 6 个；
  两条复现测试（含"临时改回旧 SQL 必失败"的反证）。`examples/ai-ops` 的 test 因此恢复并接回 CI。
- **英文 README 中文污染清零** + 门禁：`README.md` 出现汉字即失败，反向断言 `README.zh.md` 必须是中文（防对调）。
- `examples/distributed` 的"多节点部署"改成事实（跨节点事件总线，**无选主**）；`http-stress-test` / `tenant-mgmt`
  README 与代码对齐；根 README 的 Distributed 行同样改准；`docs/dev/upgrade-roadmap.md` 的 `cluster-demo` 引用
  加现状说明（历史原文保留）。

### 示例与 CI

- **CI 两份示例构建清单统一**（此前漂移：`zent-modulith` 只在一侧，`shopdemo-zent` / `metaverse-creative` 两侧都没有）：
  现在两份**逐字一致（17 项 + `zmsaas/backend`）**，19 个示例逐个实测离线 `zig build` exit=0；不可构建的目录
  （docker / node / sibling 依赖）在两处都写明原因。
- 已有 test step 的示例接进 CI（ai-ops / basic / llm-policies / tenant-ai / web4 / zmsaas-backend）。
- **收敛重复示例**：`testing` 并入 `basic`（3 个 test 逐条保留 + 2 条从未跑过的 demo 改为真测试，
  顺带发现其中一条原断言为假）；`cluster-demo` 并进 `distributed`；删 `deprecated/` 与 `example_tests.zig`。
  `examples/README.md` 索引与目录一一对应（20/20，脚本校验）。
- `alpha-engine`（v0.23 的 P0 示例）进 CI 构建列表 + doctor 循环，并补 README；`runtime-workers` 补 README。
- `shopdemo-zent` / `metaverse-creative` 的 zent 依赖由 `.path` 改 **git tag pin（v0.67.0）**；9 个 `build.zig.zon`
  的 `minimum_zig_version` → `0.17.0`。

## [0.23.0] - 2026-09-17

- **`ClusterBootstrap` 可选自带 Raft 传输**：`BootstrapConfig.transport` 接受应用提供的
  `RaftElection.ElectionTransport`；给了它就**不再**要求 `.allow_stub_raft_transport`（默认 `raft_cluster_size = 3`
  也能启动）。框架仍然不内置真传输，但 seam 可用、契约写清了：出站用 `NetworkTransport.connect/send`、
  入站用 `ClusterServer.start(handler)` 分发到 `handleVoteRequest`/`handleAppendEntries`/`handleVoteResponse`/
  `handleInstallSnapshot` 并在同一连接回包；`sendVoteRequest` 是 fire-and-forget（应答走入站），
  `sendAppendEntries` 是同步的；丢包按"消息丢了"处理，别把节点判死。详见 `docs/DISTRIBUTED.md`
  「真选主要什么」。测试用一个自带 transport 的 3 节点配置锁定"给了传输就能启动"。
- **真选主传输落地**（`src/core/cluster/RaftTransport.zig`）：wire 格式（4 字节长度前缀 + 1 字节 tag）、
  peer→地址簿、出站投票（fire-and-forget）与日志复制（同步读回）、入站分发（`handleConnection` 把
  `handleVoteRequest`/`handleAppendEntries`/`handleVoteResponse`/`handleInstallSnapshot` 的返回值在同一连接回包）。
  4 个测试，其中两个是**真 TCP loopback**：3 个 listener → `tick()` → 真投票 → 2/3 quorum → `isLeader()`。
  **诚实边界（未做，属 `RaftElection` 内部状态机）**：`handleVoteResponse` 收到第一张票就 `becomeLeader()`（不数票，
  quorum 由调用方 `hasQuorum` 判）；`tick()` 发的是空条目心跳且 `prev_log_index = last_idx`，空日志 follower 会拒 →
  落后 follower 追不上；`ClusterBootstrap` 不自动起入站 server 与 `raft.tick()`；`InstallSnapshot` 只有入站。
  另：`NetworkTransport.connect` 是死代码且引用即编译不过（`ConnectOptions` 需 `.mode`），本次在 `RaftTransport`
  内自建拨号，未改该文件。
- **`examples/alpha-engine/`（P0）**：`feed → OrderBook → Alpha → Risk → Execution → PaperExchange` 的确定性离线
  流水线（内嵌 200 点价格序列，无随机数），`Pipeline` 模块在 `initWith` 里 `ctx.runtime()` spawn 全部 worker，
  快照定时器 + drain barrier + `rt.stats()`。`zig build run` 退出码 0，连跑数字一致。P1–P3 见
  `docs/dev/alpha-engine-spec.md`。
- **doctor 补三项检查 + `graph --dot`**：doctor 新增「未解析服务 / 消费者计数 / 事件拓扑」三项 **advisory** 检查
  （查不到就输出 `n/a (静态分析不可得)`，不编数字；阈值 `--max-consumers N`）；`zmodu graph --dot` 把
  `ModuleGraph.renderDot` 接进 CLI（DOT 与 Mermaid 共用 `--out`）。顺带修：**doctor 的测试此前从未被编译**
  （`main.zig` 未在测试上下文引用它）→ 已并入 CLI 覆盖率门禁；`moduleOfImport` 把 `std`/`zigmodu` 误判成模块名 →
  改为只认相对 import。

## [0.22.0] - 2026-09-17

> **0 breaking**（Agent 闸门接线 + 三段骨架）。既有字段与函数签名全部保留，新增字段都有默认值。

### Added
- **`Guard` 接进 `Agent.run`**：设了 `Agent.guard` 之后，**每次工具调用先过闸门再分派** —— 被拒时把
  `{"error":"ToolDenied","reason":…}` 当工具结果喂回模型（它可以改走"提议"分支），同时计
  `AgentMetrics.tool_denied` 并按具体原因写 audit。闸门排在 `hooks.on_tool_request` 之前：结构上不该
  发生的事不必先问人。走闸门时不扣 guard 预算（LLM 花费归 `Agent.budget`，同一个 token 不记两次账）。
- **`skill.Tool.action`（默认 `execute`）**：工具自己声明类别（`read` / `propose` / `execute`）。
  忘了声明的工具永远拿不到宽策略 —— fail-closed 的默认值。
- **`ai.AgentSpec`**（`agent.Spec` + `build()`）：身份 / 技能 / 记忆 / 权限收在一处声明；
  `isGuarded()` 与 `isInert()` 把"没有闸门（无界）"和"有闸门但什么都没授予（惰性）"分开，便于启动期断言。
- **`Agent.memory` / `memory_prefix` / `memory_limit`** + **`memory.recallBlockAlloc`**：记忆按本次运行的
  tenant + user 注入 system message。`recall` 把 `0` 当"任意"，所以身份缺失或为 0 时**一个字都不注入**
  （跨租户注入是沉默的、最坏的那种失败）。
- **`ai.ProposalPipeline`**（`src/ai/proposal.zig`）：把 `todo3.md` §八 的三段做成不能跳序的骨架 ——
  `guard(.propose)` → `risk.RiskReview` →（escalate 时）`approval.ApprovalFlow` → `guard(.execute)` → executor。
  `executeStage` 私有；没有审批链时 escalate 是硬停（agent 不自我批准）；风险结论在"能不能执行"之前产生，
  于是常态结局是 `execute_not_permitted` **带着风险结果**交给人工，而不是一句无权限的沉默失败。
- 测试 +8（**1096 passed / 21 skipped / 0 failed**）：记忆作用域拒绝、Pipeline 三条拒绝路径（含 sqlite
  风险规则）、审批链放行、`Agent.run` 走闸门的两个相位、`AgentSpec` 接线。

### Changed
- `Agent` 新增 `name` 字段（默认 `"agent"`），日志改为 `[Agent:<name>] …`，同进程多 agent 可分辨。
- `docs/AGENT_RUNTIME.md` 增补：闸门接线、`AgentSpec`、Pipeline 图与三个刻意决定、记忆的 `0` 语义。
- **Runtime 被框架真正采用**（v0.21 之后第一件"装配线"工作）：
  - `ModuleContext.runtime()`（`src/core/ModuleContext.zig`）—— 模块在 `initWith` 里 spawn worker/timer；
    `Application.stop()` **先**请求停止并 join 它们、**再** `Lifecycle.stopAll`（worker 可能正在调模块服务）。
    裸 harness（直接 `Lifecycle.startAllWith`）里返回 `error.RuntimeUnavailable`，明确失败而不是偷偷新建一个。
  - `Application.runtime()` 现在**首次调用即启动 ticker**：此前返回未启动的 runtime，`handle.after(...)` 会静默不触发；
    启动失败时清理已分配的内存（`errdefer rt.deinit()`）。
  - e2e 测试锁定两条不变量：`ctx.runtime() == app.runtime()`（同一个对象）、worker 随 `app.stop()` 被 join
    （`src/Application.zig`「a module spawns workers through ctx.runtime()」）。
  - **`examples/runtime-workers` 改走 app + module 路径**：管线在 `Pipeline.initWith` 里通过 `ctx.runtime()` 建好，
    `main` 只驱动与观察 —— 参考示例教的形态与文档一致，且 CI 每次都会跑这条路径。
  - `docs/RUNTIME.md` 新增 §3d「模块里怎么用」：四条规则（只借不还 / 停止顺序 / 别自己 shutdown / 测试用 Manual 时钟就别走 app）。
- **`ai.AgentWorker`（`src/ai/agent_worker.zig`）—— `Agent → Worker → Event` 接通**（`todo3.md` §八）：
  `Agent.run` 会阻塞调用线程整轮 LLM 往返（`ai.trigger.Trigger.fire` 就是这么调的，一个慢模型占住一个请求线程），
  现在可以把 agent 跑成运行时 worker —— 有界邮箱（满 → 生产方 `error.Full`）、生命周期（`stop()` join）、
  监督（`spawnActor` + 错误预算）、指标（`handle.stats()`）全部白拿。
  - 所有权明确：`agent_worker.post()` dupe 目标文本、worker 跑完释放；`on_result` 拿到的 `AgentResult` 是借用。
  - 失败不算 worker 错误：provider 挂掉走 `on_result(err)` 由 app 决定重试/DLQ/告警，监督器错误预算留给真 bug
    （`stats().handler_errors` 保持 0，有测试断言）。
  - `executor` 可注入：默认 `Agent.run`，测试用罐头执行器（两个新测试不碰网络）。
  - 边界：`runtime.zig` 作为领域缝加入 `src/test/AiBoundary.zig` 白名单，理由写进 `docs/AI_BOUNDARY.md`
    （单向：ai → runtime 允许，runtime → ai 由反向检查绝对禁止）。
- **Cluster 读侧接通**（`todo3.md` §七 的第一条装配线）：`src/cluster/MembershipView.zig` 把 membership（写侧
  hash map）喂给 `ClusterView`（读侧引用计数快照 + rendezvous），请求路径不再读写侧；`ClusterBootstrap` 自带
  一个 view 并新增 `tick()`（一次做 gossip/health + 刷新读侧；`error.ReadersBusy` 不是失败）与 `getView()`；
  `root.zig` 导出此前只能按文件路径拿的 `RaftElection` / `PeerDiscovery` / `LoadBalancer` / `ClusterHealth` /
  `AccrualFailureDetector`；`ClusterMembership` 新增只读的 `nodesSnapshot()`（读侧的取数缝）。
  - 顺带修掉 gossip 负载里的地址格式：`{any}` 打印的是结构体 dump（`.{ .ip4 = .{ .bytes = … } }`）→ 改 `{f}`
    （`host:port`），并把"被发现的节点按 `127.0.0.1` 记账"这条**跨主机限制**写进代码注释与 `docs/DISTRIBUTED.md`。
- **`zmodu module <name> --full`**：默认只写 `module.zig`（一个声明），`--full` 追加六件套
  （`model` / `persistence` / `service` / `api` / `root` / `module_test`），一次得到 `docs/MODULE_LAYERS.md`
  说的模块形状。生成物经 `zig fmt --check` 解析校验、无残留占位符；`api.zig` 的 `ping` 路由默认 `.jwt`
  （改 `.public` 应当是刻意的一行）。实测：`zmodu module order --full` → 7 个文件、全部解析通过。
- **`zmodu ci` 纳入 `doctor`**：`zmodu ci` 现在跑 6 步（compile → fmt → verify → audit → deadcode → **doctor**），
  架构健康检查（环依赖 + 源码级纠缠）与应用发布门禁合成一条命令，与 CI 里针对每个 example 跑的那条
  （`ci.yml` "Architecture health on the example apps"）口径一致。已按 CI 的调用方式在 `examples/basic` 上
  端到端验证：`[doctor] PASS` + `summary: PASS`（exit 0）。
- **孤儿原语收编**（复核里"存在但没人用"那一条）：
  - `runtime.Sequencer` 接上真实消费者：`ai/agent.zig` 的 run-id 序列原本是私有 `std.atomic.Value(u32)`，
    现在用 `Sequencer`（同一语义、有文档、还带 `nextBatch`；经 `runtime.zig` 领域桶导入，落在 AI 边界白名单内）。
  - `runtime.ObjectPool` 如实标注「暂无仓内消费者」：`src/im/ConnectionRegistry.zig` 有连接表专用的 free list
    （约束不同），所以这条是**文档而非接线** —— 它的头注释解释了为何用 SpinLock 而非 Treiber 栈（ABA），
    属于刻意写的公共原语，面向"有界池、满了就拒绝"的场景。
- **文档片段抽查 `src/test/DocSnippets.zig`**：扫 `AGENTS.md` / `README.md` / `README.zh.md` / `docs/**.md` 里的
  **围栏代码块**（`zig` 或无标签；散文与表格按速记处理），禁止把 builder 方法直接链在 `zmodu.builder(…)`
  临时值后面 —— 那个形状编译不过（`error: expected type '*T', found '*const T'`，此前 12 处都这么写）。
  带"检测器自身的单测"：坏形状必须被抓、`var b = …` 正确形状必须放行。
- **集群：多节点启动 fail-closed + 修掉一个段错误**：
  - `ClusterBootstrap` 的 Raft 传输是桩（投票发不出去、append 恒 false），`raft_cluster_size > 1` 时 `start()`
    现在返回 `error.RaftTransportUnavailable`（并说明怎么承认：`.allow_stub_raft_transport = true`，或单节点
    `raft_cluster_size = 1`）—— 不再静默选出一个没有 quorum 的 leader。
  - **修段错误**：`start()` 里 `disco.deinit()` 与 `deinitResolved(peers)` 的 defer 顺序反了（前者把结构体置
    `undefined`，后者仍要读 `self.allocator`）→ 只要带**一个 peer** 启动就崩在 `0xaaaa…`。空 peer 列表时循环体
    不执行，所以这条多节点路径此前从未被跑过；新测试现在覆盖它（`PeerDiscovery.deinitResolved` 的文档也写明了这个调用顺序要求）。

## [0.21.0] - 2026-09-17

> **0 breaking**（v0.21 = Agent 的运行时闸门）。纯新增，`Agent` / `SkillRegistry` / `Budget` 一字未动。

### Added
- **`src/ai/guard.zig`（`ai.Guard` / `ai.Permissions`）** —— 把 `todo3.md` §八 的硬规则
  （**AI Agent 默认不能直接交易**）变成可测试的代码，两条轴都是 fail-closed：
  - **类别轴**（`read` / `propose` / `execute`）：`execute` 需要 `allow_execute` **另外**再开一次开关 ——
    把 `order.submit` 写进 allow 不等于"这个 agent 可以下单"，配置写错不会静默交出交易接口。
  - **名字轴**：`allow` 默认**为空**（无策略的 agent 什么都不能做，`isInert()` 让调用方启动期就能大声失败）；
    `deny` 永远压过 `allow`，宽列表可被局部收回而不必重写。
  - 预算在**同一个 `check()`** 里扣：被拒绝的动作**不消耗预算**（否则配置错的 agent 会靠"试"把自己饿死），
    拒绝原因**分门别类计数**（not_listed / explicitly / execute_class / budget）——
    "看起来健康"的被拒 agent 正是这道闸门要防的东西。
  - 3 项测试：空策略三类别全拒且计数正确、列名之后 `execute` 仍需第二开关（且 `deny` 压过它）、
    拒绝免费 / 允许计费 / 超预算单独计数。
- **`docs/AGENT_RUNTIME.md`** —— 两条轴的表、接线示例（拒绝 `execute` 后落到 `propose` 分支，正是规则要的形状）、
  与 `security/` 的分工（这道闸门管 **agent 自身**的权限，不是终端用户鉴权），
  以及**还没做**的三件事（身份/记忆/技能尚无声明式包装、`Guard` 未接进 `Agent.run` 调用链、
  Proposal→Risk→Execution 只有 Proposal 侧入口）。

## [0.20.2] - 2026-09-17

> **0 breaking**（v0.20.2 = AI 与驱动层解耦完成）。纯 import 替换，无行为变化。

### Changed
- **`src/ai/**` 不再直接 import 驱动层**：56 处（`sqlx/sqlx.zig` 30 + `persistence/backends/**` 26，
  分布在 21 个文件）全部改为 `@import("../data.zig")`。`data.sqlx` 与 `data.SqlxBackend` 本来就是同一批
  模块的 re-export，所以这是**类型同一性不变、行为不变**的机械替换 —— 整个迁移用一个替换规则完成，
  全量测试 1085 全绿（含 AI 的持久化/审批/预算等用例）。
- 诚实记录：这 56 处里绝大多数是**测试脚手架**（`:memory:` 客户端与 backend 的构造），
  真实生产耦合小于这个数字；但一条替换就能清零，没有理由留着。
- `src/test/AiBoundary.zig` 的两个冻结上限从 30 / 26 调到 **0 / 0**，等于对驱动层 import 的绝对禁止：
  再新增一处就编译失败。`docs/AI_BOUNDARY.md` 的表格同步为迁移前/后对照，抽包条件由
  "两个计数到 0" 变成"保持为 0"。

## [0.20.1] - 2026-09-17

> **0 breaking**（v0.20.1 = 把 AI 抽包的边界变成机器检查）。纯新增测试 + 文档。

### Added
- **`src/test/AiBoundary.zig`** —— AI 边界的机器检查，两半：
  - **反向绝对禁止**：`src/{core,api,data,sqlx,http,security,messaging,runtime}` 下任何文件 import
    `ai/` 即失败（现在 `src/` 里只有 `root.zig` 一行 re-export，是唯一的缝）。
  - **正向 ratchet**：`src/ai/**` 只许 import 领域缝；直接 import 驱动层
    （`sqlx/sqlx.zig`、`persistence/backends/**`）被冻结在实测上限 **30 / 26**，**只能减不能增**；
    计数下降时会打印一行提醒把上限调低。
- **`docs/AI_BOUNDARY.md`** —— 实测数据（21 个文件里 56 处绕过 `data.zig` 的驱动层 import）、
  允许/禁止清单、每个文件的清理路径（`@import("../sqlx/sqlx.zig")` → `@import("../data.zig")`）、
  抽包条件（两个计数到 0 且测试持续为绿），以及**为什么要 ratchet 而不是一次性清理**
  （把 56 处 import 的迁移和边界定义混在一次提交里难以验证）。

### Why
v0.21 的 Agent Runtime 要求 AI 层能被别的包依赖 —— 而"能被依赖"的前提是它只依赖**稳定接口**
（领域缝），不是"当前那个驱动文件恰好长这样"。顺序必须是先收边界再加能力，否则耦合只会更多。

## [0.20.0] - 2026-09-17

> **0 breaking**（v0.20 = 长流程可恢复执行）。新增 `resumeInstance`，既有 `execute` / WAL 格式不变。

### Added
- **`SagaOrchestrator.resumeInstance(id)`** —— 继续一个被上一个进程留在半途的 saga（由
  `restoreFromWal` 装回来）。语义写进 `docs/WORKFLOW.md`：已 `completed` 的步**不重跑**、
  崩溃时**在飞**的那一步**重跑**（所以有副作用的步骤必须幂等）、终态实例（completed/compensated/
  failed/timed_out）与补偿中途（compensating）一律拒绝（`error.NothingToResume` / `UnknownInstance`）。
- 步进循环抽成 `runFrom(instance_id, start_index)`：`execute` 与 `resumeInstance` 共用一条路径，
  续跑的语义不可能与首次执行漂移。
- 2 项测试：崩溃续跑（手写一条"step index 1 在飞"的 `saga-state` WAL 记录当崩溃现场 → 恢复 →
  续跑只重跑在飞那步 + 之后各步，且不触发补偿）、恢复取**最新**状态（回归测试直接钉住下面第 1 条）。

### Fixed
- **恢复会复活已结束的实例**：`restoreFromWal` 原先逐条看记录，只要任意一条是 `running` 就恢复 ——
  而"失败并补偿完"的 saga 在 WAL 里正是 `running → running → compensated` 的链条，于是它会以
  `running` 回来，续跑即**重复补偿**。现在按实例取最后一条状态再决定。
- **`restoreFromWal` 每次启动泄漏**：`readFrom` 交出的条目（topic/payload/source_node）归调用方释放，
  它从不释放。之前没有测试调用过这条路径，所以没人发现。
- `pub fn resume` 无法编译：`resume` 是 Zig 关键字（`suspend`/`resume`）→ 改名 `resumeInstance`。

### Docs
- `docs/WORKFLOW.md`（新）：一步之内的语义表（什么重跑、什么拒绝、为什么）、WAL 接线样例、
  本版修掉的三个真问题、**刻意不做**的四件事（不加 DSL / 不做调度器 / 不做跨节点编排 /
  `ai/workflow.zig` 保留并说明分工）。
- `AGENTS.md`：文件地图加一行（长流程用 `resumeInstance`，副作用步骤必须幂等）。

## [0.19.0] - 2026-09-17

> **0 breaking**（v0.19 = 集群读侧）。纯新增：`ClusterView` 与既有 DistributedEventBus /
> ClusterMembership 并存，后者一行未动。

### Added
- **`zigmodu.ClusterView(N, G)`（`src/cluster/ClusterView.zig`）** —— 集群状态在**请求路径**上的安全读法：
  - **引用计数的成员快照**：写者（维护循环，单写者）`publish()` 整份替换；读者 `acquire()` → 用 →
    `release()`，全程无锁、无分配、无 GC。写者在复用槽位前等该槽读者清零，等不到返回
    `error.ReadersBusy` 而不是覆盖活数据（发布是秒级活动、读是微秒级活动，等是便宜的方向）。
  - **`pick(key)` / `pickRanked(key, rank)`**：rendezvous（最高随机权重）哈希选节点，主 + 至多 3 个备份。
    选它而不是 `core/eventbus/Partitioner.zig` 的一致性哈希环：环要重建、读要加锁，而 rendezvous
    无状态无锁，"成员变化只迁移它拥有的 key"这条性质同样成立；环仍留在批量写的事件总线路径。
  - `error.TooManyMembers`（超容量拒绝，计数）、`stats()`（publishes / generation / members /
    healthy / over_capacity / readers_busy）、`peek()`（诊断用，明确标注"可能被回收"）。
  - 6 项测试：发布即拥有字符串（调用方之后改原 buffer 不影响快照）、rendezvous 稳定性（同集合换序不换主、
    新增节点只迁移一部分 key）、不健康节点永不入选（全不健康 → null，而不是错的答案）、
    **并发**（20k 次发布 × 3 读者 → 0 次不一致读；写者按设计报 Busy 且 publishes+busy 计数守恒）、
    分代环复用后当前视图不丢、超容量拒绝且旧视图完好。

### Docs
- `docs/DISTRIBUTED.md`：新增「集群读侧：`ClusterView`」——为什么请求路径不该读写入侧的哈希表、
  回收没有 GC 靠引用计数、为什么用 rendezvous 而不是环、以及**本版刻意不做**的四件事
  （不发明协议 / 不做跨节点一致性 / Raft 与分布式事务仍 experimental / `weight` 留位未使用）。
- `AGENTS.md`：文件地图 + 两行 DO/DON'T（读侧 acquire/release；`ReadersBusy` 当作"下个 tick 再发"）。

## [0.18.0] - 2026-09-17

> **0 breaking**（v0.18 = 架构引擎）。唯一可能让工程"突然编译不过"的是新增的编译期图检查 ——
> 而它拦的正是**以前会在启动期 abort** 的那些图（环 / 缺失 / 自依赖 / 重名），
> 需要动态装配模块的场景可以 `.withCompileTimeGraphCheck(false)` 关掉。

### Added
- **编译期架构检查（`src/core/ModuleGraph.zig` + `ApplicationBuilder.build`）** —— 模块依赖图从
  "启动期校验"前移成"编译期数据"：
  - 检查：缺失依赖 / 自依赖 / 重名 / **环（DFS，报错信息里带完整路径 `a -> b -> a`）**。
  - 阻断性问题直接 `@compileError`，不再等到二进制跑起来第一件事就是 exit。
  - 关闭：`.withCompileTimeGraphCheck(false)`（仅用于动态装配的模块集，启动期 `validateModules` 仍在）。
  - 同一份分析在运行时也可用：`analyzeRuntime(allocator, nodes, limits)`（动态注册表可自检），
    与编译期版本共享 `Report`/`Finding`/渲染器。
  - 诚实边界：**"domain 不许 import 数据库"这类规则编译期无法检查** —— 模块声明里没有"某文件
    import 了什么"这个信息。声明无法执行的规则比不声明更糟，所以源码级纠缠交给 `zmodu doctor`。
- **`zmodu doctor`（CLI）** —— 不编译工程就能拿到架构健康报告：
  - 复用 `audit.collectModules` 的源码扫描，跑同一套图检查（环/缺失/自依赖/重名/依赖数阈值/孤儿）。
  - **新增跨模块直接 import 检测**：`src/modules/alpha/**` 里出现 `@import("../beta/service.zig")`
    即报纠缠并给出 `文件:行`（"declare the dependency, import the module barrel, or `--allow`"）。
  - `--json`（CI/看板）、`--max-deps N`、`--allow from->to`（承认一处纠缠，可重复）、`--skip-imports`。
  - 退出码：阻断性问题 → 1（可直接进 CI），纠缠 → warn 不影响退出码（设计味道，不是坏图）。
- 7 项 `ModuleGraph` 测试：健康图（含深度度量）、环（路径闭合）、自依赖+未知依赖、重名、
  阈值与孤儿是**告警不阻断**、两个渲染器（Mermaid/DOT/文本，含错误文本里点到点的通配）、
  以及运行时孪生（与编译期同结论）。CLI 侧另有 `moduleOfImport` 与 JSON 渲染的单元测试。

### Fixed
- **`mapOfImport` 的路径深度算术**（本版新写的第一版）：按"importing 文件的目录深度"扣 `..` 个数
  会**拒掉模块根文件写的 `../../other/x.zig`** —— 而这正是最常见写法。改成"剥掉前导 `..` 后取首段，
  再与已知模块名比对"，更简单也更难写错。
- **`analyzeRuntime` 返回的是 DFS 栈而不是环**（首版）：环体被建好后没交给调用者，返回值少一个元素
  且泄漏一份分配。现在通过出参回传，并有"环路径首尾同名"的断言兜住。
- **`@compileError` 的无条件分析**：`if (!report.ok()) @compileError(...)` 在条件未被 comptime 折叠时，
  分支体会被分析 —— 于是**所有**调用点（含健康图）都编译失败。用 `comptime {}` 块 + `inline ok()` 修正，
  并留注释说明原因（这类 bug 的症状是"检查器把好代码也判死"，很容易被误当成"太严"而关掉）。

### Changed
- `tools/zmodu` 与根 `build.zig` 都把框架的 `ModuleGraph` 暴露为命名模块 `module_graph`：
  CLI 与框架**共用一份**环/结论算法，而不是在工具里复制一份会漂移的实现。
  为此 `ModuleGraph.zig` 保持**零框架依赖**（只用 std），其测试夹具用本地 `Info` 结构而非 `api.Module`。

### Docs
- `docs/ARCHITECTURE.md`：新增「Architecture engine」——两半的输入/时机/检查项、三层强度
  （编译期挡住 / 启动期告警 / CLI 报告）、优先级约定（阻断 vs 告警），以及"为什么 import 级规则
  只能在 CLI 层"。
- `AGENTS.md`：文件地图加一行；DO/DON'T 加两行（依赖靠编译期检查拦住；交付前跑 `zmodu doctor`，
  别声明无法执行的架构规则）。

## [0.17.0] - 2026-09-17

> **0 breaking**（v0.17 = 运行时的监督与扇出，仍是纯新增）。v0.16 的 worker 语义一字未改：
> `rt.spawn(...)` 依旧"记录错误并继续"，新语义只在 `spawnActor` 上生效。

### Added
- **Actor 监督（`rt.spawnActor(W, init, cap, Supervision)`）** —— Actor 是"加了失败策略的 Worker"，
  不引入第二套生命周期：
  - `Supervision.strategy = .restart | .stop`：`.restart`（worker 语义，默认）只记录继续；
    `.stop` 首个错误即停（fail-fast，邮箱关闭、线程退出）。
  - `max_errors` / `window_ms`：**窗口错误预算**。窗口内超过 N 次即停，`0` = 不限。
    一个"每条消息都出错"的 actor 在"只记录"语义下会永远烧掉一个核而外部看起来健康 —— 预算把
    它变成"停止 + 一条 warn + 计数"。
  - `pub fn onError(self, err, ctx) Supervision.Strategy`（可选声明）：**现场决策并覆盖配置策略**
    （例如只有 `error.Fatal` 才停）。
  - 停止后 `stats().stopped_by_supervisor == true`、邮箱关闭（生产者拿到 `error.Closed`），**不会**
    退化成静默丢弃；`WorkerStats` 新增 `errors_in_window` / `stopped_by_supervisor`。
  - 诚实边界（写在 `docs/RUNTIME.md` §3b）：本版**不**实现"用干净状态重启 actor"（需要初始状态副本或
    `reset` 钩子，语义未定就不给）；父子关系目前只体现为**停止顺序**——`shutdown` 按 spawn 逆序 join，
    所以"先父后子"即"子先停"，真正的监督树留给后续版本。
- **`runtime.HotBus(E, N)`（L0 扇出）** —— 一个事件、多个消费者，而发布方不能等：
  - `subscribe(*Handle(W, cap))` 接 worker（消息类型不符是**编译期**错误）、`subscribeSink(Sink)`
    接非 worker 消费者（指标、广播器、测试记录器）。
  - `freeze()` 之后 `publish` 是一次**无锁、无分配**的切片遍历；未 freeze 就发布返回
    `error.NotFrozen`（接线 bug 应大声失败而不是竞争）。
  - 满的订阅者**丢该条并计数**（`stats().dropped`），慢消费者既不能拖慢发布方也不能吃光内存。
- **`runtime.Sequencer`** —— 无锁单调序列：`next()` / `nextBatch(n)`（原子预留一段连续值）/
  `peek()` / `advanceTo()`（只前进，不回退，供快照回放）。**不是时钟**：只在进程生命期内可比较。
- 12 项新测试：Actor 四条（worker 语义保持 / fail-fast / 预算耗尽 / `onError` 覆盖两个方向）、
  HotBus 五条（扇出顺序、慢订阅者丢弃并计数、未 freeze 与 freeze 后订阅、容量、真 worker 邮箱打满）、
  Sequencer 三条（唯一性、并发下区间不相交、`advanceTo` 不回退）。
- `examples/runtime-workers` 扩成 v0.17 形态：订单簿把每条 delta 发到 `HotBus`，扇出给
  **故意慢的审计 worker** + **O(1) 的指标 sink**，并跑一个必然失败、被预算停掉的 actor。实测
  `subscribers=2 published=261 delivered=330 dropped=192`（审计丢、指标一条不漏、订单簿从未阻塞）、
  `attempts=4 stopped_by_supervisor=true mailbox_closed=true`。CI 仍会构建并运行它。

### Docs
- `docs/RUNTIME.md`：新增 §3b（Actor 与监督，含"为什么不实现带状态重启"）、§3c（HotBus 两条规则
  与实测数据）、worker 契约表加 `onError`、原语表加 `Sequencer`/`HotBus`、路线图把 v0.17 标为已落地
  并把"真监督树/跨节点监督"明确列为**未承诺**。
- `AGENTS.md`：DO/DON'T 再加两行（持续失败用预算而不是永远记录；L0 扇出用 `HotBus` 而不是 L1 EventBus）。

## [0.16.0] - 2026-09-17

> **0 breaking**：本版只新增（v0.16 = 运行时底座，见 `docs/dev/todo3.1.md` 的兼容策略）。
> 不调用 `app.runtime()` 的应用，线程数、生命周期、行为与 v0.15.x 完全一致。

### Added
- **ZigModu Runtime（`zigmodu.runtime` + `app.runtime()`）** —— `Application`（架构单元：Module/DI/
  Lifecycle/EventBus/HTTP）旁边新增一条**可选**执行通道（执行单元：Worker/Mailbox/RingBuffer/
  TimerWheel），共享同一个 io / config / 可观测性。定位与契约见 `docs/RUNTIME.md`。
  - `RingBuffer(T, N)`：单生产者/单消费者**无锁**环（各自只读对方指针，无 CAS），N 必须 2 的幂。
  - `MpscRing(T, N)`：Vyukov 有界多生产者队列；**N ≥ 2 由编译期强制**（N=1 时序列号无法区分
    "空"与"未消费"，会覆盖未消费消息 —— 实测 `len` 涨到 2）。
  - `Mailbox(T, N)`：有界 + spin-then-block 交接。`send` 满即 `error.Full`（背压对生产者可见），
    `sendBlocking(msg, timeout)` 用延迟换不丢，`close()` 唤醒所有等待者并允许排空。
    无丢唤醒的保证写在实现里：消费者在**持锁**下复查空、生产者在**持锁**下 signal。
  - `Wheel(Payload)`：分层时间轮（5 层 × 64 槽 × 10ms，最长 ~124 天），O(1) 插入/取消；
    长停摆（ticker 被饿死）走 **O(pending) 扫描**而不是逐槽空转；`cancelWith` 带 drop 钩子，
    取消与触发都必须能释放 payload（否则取消即泄漏）。
  - `ObjectPool(T)`：定容对象池，`acquire` **不分配**、耗尽返回 null；`release` 校验归属并拒绝重复归还。
    自旋锁而非无锁栈：索引上的 Treiber 栈有 ABA 窗口会把同一对象发两次，而"发两次"没有测试能稳定复现。
  - `Clock`：`.monotonic`（生产）/ `.manual`（测试：推进一小时定时器不需要睡觉）。
  - `Runtime` + Worker 契约（comptime 探测，热路径无 vtable）：`pub const Message = T` + `handle(self, msg, ctx)`
    走消息驱动；`run(self, ctx)` 自带循环；`init`/`deinit` 为可选生命周期钩子。
    `rt.spawn(W, init, cap)` → `Handle`：`send` / `sendBlocking` / `stop` / `join` / `after(ms, msg)` / `stats`。
    `rt.start()` 起 ticker（或 `rt.tick()` 自驱）、`rt.shutdown()` 请求停止 → 唤醒 → join。
  - `RuntimeStats`：`workers / running / messages_sent / messages_received / messages_dropped /
    handler_errors / timer_fires / timer_lag_max_ms`；每 worker 明细在 `handle.stats()`。
- `Application.runtime()`：**首次调用才创建**（不调用 = 零线程、零定时器）；`stop()` 先
  `runtime.shutdown()`（join 所有 worker）**再**停模块 —— worker 可能正在调模块服务；
  `deinit()` 释放。`Application` 的既有 API 一字未动。
- `examples/runtime-workers/`：行情源 → 订单簿 worker → 风控 worker + 快照定时器的流水线。演示
  ①状态单线程独占（**全文件无锁**）②有界背压（5000 条里 4645 条在生产者侧被削掉、队列零增长）
  ③定时器只投消息（在 worker 线程上处理，不在 ticker 上跑业务）④优雅停机（屏障消息排水 + join）。
  CI 会构建**并运行**它。
- 31 项运行时测试，含真并发：4 生产者 × 5000 条零丢失、20 万条 SPSC 序贯、对象池 8 线程
  acquire/release 收支平衡、以及唯一一条真正启动 ticker 线程的端到端定时器用例。

### Fixed
写这套原语时被测试抓出的四个真 bug（都记在代码注释里，防止回退）：
- `Wheel.cancel` 不更新**槽头指针** → 取消槽内首个定时器后，下一次 `advance` 会遍历已释放节点
  （SafeAllocator 报 `write after free`）。现在 `unlink` 会修头指针，另有"取消中间节点"的回归用例。
- `MpscRing` 在 **capacity = 1** 时**静默覆盖未消费消息**（生产者写 `pos+1`、消费者写 `pos+capacity`，
  同一个数值无法区分状态）→ 编译期拒绝，并在文档写明替代方案。
- `Runtime.running` 把"ticker 已启动"与"运行时存活"混为一谈 → 不调用 `start()`（文档承认的受支持用法）
  时，`ctx.stopped()` 立刻为真，run-owned worker 一行没跑就退出（实测 `ticks = 0`）。
  拆成 `alive` 与 `ticker_running`。
- `timer_fires` 在**投递之后**才自增（计数器落后于自身效果 = 竞态）→ 先计数再投递；
  `timer_lag_max_ms` 此前从未被写入（假字段）→ 由每个 timer 的 deadline 真实计算。
- 另：`Mailbox.dropped_full` 不再被 `sendBlocking` 的内部重试污染（只统计非阻塞 `send` 的拒绝）。

### Docs
- **`docs/RUNTIME.md`**（新）：定位（Modulith + Runtime）、兼容 10 条、worker 三种声明方式、
  原语取舍表（含"为什么池用锁而不是 Treiber"）、背压三规则、事件分层 L0/L1/L2（**不替换现有
  EventBus**）、何时不要用运行时、可观测性、v0.16 → 1.0 路线图。
- `AGENTS.md`：文件地图加 `docs/RUNTIME.md`；DO/DON'T 加四行（worker 与邮箱、`error.Full` 必须显式处理、
  定时器只投消息、运行时是 opt-in 别给 CRUD 加 worker）。

## [0.15.47] - 2026-09-15

### Changed
- **zent 适配 v0.41.1 → v0.67.0**（26 个 minor，`examples/zent-modulith` 的 pin 升到
  `?ref=v0.67.0#e60d81e`）。编译级破坏只有一处：**`CrudService.create(entity, tenant_id)`
  双参**（zent v0.54.0）——旧签名从实体读租户列，而写循环会复制每个字段、拦截器又只填"缺失"的，
  于是调用方新建实体的租户字段为 0 时会写 `0`。本仓库 `zent_crud.CrudApi.create` 已改为
  `create(buildEntity(tenant, body), tenant)`。
- 语义级变更（编译通过但行为不同）已在 §14 记录并验证：**空 `dept_ids` 由"放行全表"改为拒绝**
  （zent v0.66.0 的安全修复，本仓库 smoke 已把"空 `dept_ids` → 空结果"钉成断言）、无谓词
  `BulkDelete` 报 `error.NoPredicate`、无 `last_insert_id` 报 `error.MissingLastInsertId`、
  MySQL 批量改逐行、MySQL 的 `String`/`Enum` 落 `VARCHAR(255)`、`driver.Error` 新增
  `ParamCountMismatch`/`PoolWaitTimeout`。

### Fixed
- **示例崩溃：`deinitRow` 与 `CrudService.get` 的分配器不匹配**（`GET /api/v1/products/{id}`
  命中一行即 `panic: free of invalid memory` 打死整个服务器）。根因不在 zent：
  `CrudService.get(allocator, …)` 返回的是 **`ownedCopy(allocator, …)`**（字符串归调用方传入的
  allocator，即请求 arena），而 `client.<entity>.deinitRow(&e)` 用 **client 的 allocator** 释放 →
  不匹配释放。这是上一轮（commit `23bd2e1`）把 `deinitEntity(…, ctx.allocator)` 机械替换成
  `deinitRow` 时引入的：旧写法传的是拥有者 arena，而 Zig 0.17 里 `ArenaAllocator.free` 是 no-op，
  所以无害；换成 client allocator 后同一个调用变成非法释放。修法：arena 拥有的 owned copy
  **不交给 `deinitRow`**（代码里留了 7 行注释说明契约，防止被"修回去"）。已核对全仓 30 处
  `deinitRow(s)`：其余都作用于驱动扫描出的行（builder `Save()` / `Query().All()`），契约正确。
- **升级验证被增量缓存欺骗**：pin 已改成 v0.67.0 后 `zig build` 仍"编译通过"，但崩溃栈里的源码
  路径是 `zent-0.41.1`——Zig 0.17-dev 的缓存沿用了旧 fetch 依赖。现在 §14/AGENTS.md 明确
  "改 pin 后先 `rm -rf .zig-cache`（并删 `zig-pkg/<旧版本>`）"，本轮即按此复现出真实的编译错误。

### Added
- **`examples/zent-modulith/smoke.sh`**：43 项运行时断言（真实服务器 + 真 sqlite 文件库），覆盖
  泛型 CRUD、原子扣减、事务下单、嵌套预加载、keyset 游标、批量软删、outbox、SSE、data-scope
  四种 scope 与"缺上下文 401"，并在结束时断言**服务器仍存活且日志无 panic**。
  **接入 CI**（Build Examples job）：编译示例证明不了集成正确——上一轮就是"编译通过"而一个请求
  就能打死进程。

### Docs
- `docs/ZENT.md`：版本口径 → v0.67.0；§14 新增 0.42–0.67 六条（含两条升级陷阱：`deinitRow` 与
  owned copy 的分配器匹配、增量缓存沿用旧依赖）；pin 片段改 `v0.67.0.tar.gz`；能力矩阵范围
  改 v0.30–v0.67。
- `AGENTS.md`：zent workspace 事实重写（v0.67.0 + 两条陷阱 + 0.54/0.57/0.58/0.66/0.67 的要点）。
- `examples/zent-modulith/README.md`：版本口径 + smoke 段指向脚本。
- `examples/shopdemo-zent`、`examples/metaverse-creative`（本地 path 依赖）对 **v0.67.0**
  编译通过；`examples/_shared` 同步确认。

## [0.15.46] - 2026-09-15

### Added
- **`http.UploadGuard` — 上传内容策略**（唯一被外部反馈认定为"真缺口"的一处）：框架此前只解析
  multipart 并限制体积，**没有任何内容校验**，于是每个收上传的应用各写一遍，而三种常见写法都有洞
  （只查扩展名 → 改名即绕过；只查 `Content-Type` → 客户端自填；放行 SVG → 脚本容器，从自己源站
  发出去就是 stored-XSS）。新增：
  - `sniff(bytes)`：JPEG/PNG/GIF/WebP/BMP/TIFF/PDF/ZIP/GZIP/**MP4（ISO-BMFF，校验 box size + `ftyp`）**
    /WebM/OGG/MP3/WAV，以及文本容器分类（`<svg`/`<!doctype html`/`<script` → 主动内容）。
  - `check(filename, data, policy)` / `checkForm(form, policy)`：判定顺序固定为
    **大小 → 主动内容 → 扩展名白名单 → 格式白名单 → 扩展名与内容一致**，因此错误可诊断：
    "`avatar.jpg` 里是 PHP" → `ContentNotAllowed`，"PNG 字节挂 `.jpg` 名" → `ExtensionContentMismatch`。
  - **SVG/HTML 默认拒绝**（`allow_active_content = true` 才放行），fail-closed。
- **`http.extractMultipart(ctx, config)`**：与 `extractJson*` 对齐的抽取器，失败直接产出 ProblemDetails
  —— 415（不是 multipart）/ 413（太大）/ 400（缺 boundary、畸形、part 过多）；`OutOfMemory` 不渲染。
- **`Multipart.Config.forBodyLimit(body_limit)`**：用同一个数字对齐"单 part ≤ 总量 ≤ 请求体上限"。
- `RateLimiterRegistry`：`max_keys`（`initWithCapacity`）+ LRU 淘汰、`remove(name)`、
  `retain(max_idle_seconds)`、`generateReport()`。
- `CircuitBreakerRegistry`：`count()`、`generateReport()`（真实 JSON）。
- `Context.requestParam(name)`：**form 优先、回退 query** 的取值器（Rails/Laravel/ThinkPHP `input()` 语义）。
- `Context.nestedParam(path)`：点号路径查找（原 `paramPath`，新名不再读起来像"路径参数"）。
- `CircuitBreaker`：`lastUsedAt()`；`PluginManager.dynamicLoadingSupported()`。
- `src/core/SpinLock.zig`：共享的短自适应自旋锁（自旋后 `yield`），供 io-free 热路径临界区复用。
- 测试：`http/UploadGuard.zig`（8 条：嗅探、ISO-BMFF 尺寸校验、主动内容、改名绕过、跨族改名、
  限额/扩展名、表单级）、`test/RouteTemplate.zig`（4 条：三条注册路径 + 未匹配）、
  `RateLimiterRegistry` 淘汰/LRU/retain 4 条、`CircuitBreakerRegistry` 指针稳定性 + 报告、
  `CapabilityRegistry.generateApiBoundaryReport`、`SpinLock` 2 条、`Multipart.Config.forBodyLimit`。

### Fixed
- **`ctx.route_template` 形状随注册方式而变**：`group.get("/health")` 得 `/health`、
  `group.get("health")` 得 `health`、ComptimeRouter `mountAll` 得 `orders/{id}`、
  `addRoute` 得 `/metrics` —— 同一套指标里两种拼法，写死的 dashboard 查询会漏一半流量。
  现在 `Router.addRoute` 里统一为"恰好一个前导斜杠"（该处本来就在 dupe 路径，零额外开销）；
  匹配逻辑不受影响（trie 按 `/` 切分，不用这个字符串）。
- **`CircuitBreakerRegistry` 与 `RateLimiterRegistry` 同族的两处缺陷**：按值存 breaker →
  `getOrCreate` 返回的内部指针**下一次插入 rehash 后失效**（悬垂指针，与 zent 连接池 UAF 同族）；
  且全程零同步。现改为堆分配指针 + 内部锁，指针在 registry 生命周期内稳定。
- **两个热路径锁是"纯自旋不让出"**：`http/AccessLog.zig`、`http/HttpMetrics.zig` 的
  `while (!mutex.tryLock()) spinLoopHint();` 在争用下烧 CPU。改用共享 `SpinLock`（自旋 32 次后
  `std.Thread.yield()`），并把 14 处 `self.mutex.state.store(...)` 的裸解锁换成 `mutex.unlock()`。
- **`Multipart.Config.max_total_bytes` 默认值永不生效**：`Server.Config.max_body_size`（默认 8 MB）
  在读体阶段先 413，`Multipart.parse` 不会被调用，所以默认 32 MB 的总量上限不可达。
  模块头/字段/`Context.multipart` 三处写明判定顺序，并新增 `forBodyLimit` 对齐工具。
  **默认值未改**（降成 8 MB 会静默改变"已抬 body 上限"的调用方行为）。
- **`generateReport` 占位串**（`RateLimiterRegistry`、`CircuitBreakerRegistry`、
  `CapabilityRegistry.generateApiBoundaryReport`）返回 `"pending … migration"`：改为真实 JSON 快照。
- **`PluginManager.loadPlugin` 是静默 no-op**（登记名字但不加载代码）：现在每次 warn 一行，
  并提供 `dynamicLoadingSupported() == false` 供调用方分支。
- `Transactional` 的日志串 `"Rollback transactionfailure: {}"` 缺空格；`core/Error.zig` /
  `ObjectValidator` / `SecurityScanner` / `ModuleBoundary` / `ApiVersioning` 中同一批"半翻译"注释
  （`ValidationRequired field`、`ValidationModule boundary`、`API versionRoute group` …）一并写清。
- `SecurityModule` 里错位的 `/// Validation JWT Token`（挂在 `setKeyring` 上方，与下一行冲突）删除。

### Changed
- **`RateLimiter` / `RateLimiterRegistry` / `SlidingWindowRateLimiter` / `CircuitBreakerRegistry` /
  `AccessLog` / `HttpMetrics` 的锁统一为 `core/SpinLock.zig`**（同一份实现，避免多份自旋逻辑漂移）。
- `CircuitBreakerRegistry.breakers` 类型 `std.StringHashMap(CircuitBreaker)` →
  `std.StringHashMap(*CircuitBreaker)`（破坏性，仅影响直读该字段的代码）。
- `Context.paramPath` → **DEPRECATED**，改用 `nestedParam`（行为不变）。
- `ShardRouter.ShardedQuery` **移除**：只能 `return error.NotImplemented`，且全仓无调用点
  （物理分表由 DB 层负责，模块头已写明）。
- `Partitioner.zig` 文件头"tests are disabled pending integration"是过期描述——测试实际在跑且通过，
  注释改为实情（仍未接入 `DistributedEventBus`，这点保留）。

### Docs
- `BEST_PRACTICES.md`：新增「上传与 multipart」整节（三个问题、限额优先级表、三种错误写法、
  `UploadGuard` 判定顺序与错误表、支持嗅探的格式清单、落盘路径提醒）。
- `UPGRADING.md`：补 v0.15.46 段（含 `route_template` 标签值变化的升级动作、
  `CircuitBreakerRegistry` 字段类型变化、`paramPath` 弃用）。
- `ISSUES_FROM_ZIGSHOP.md`：追加第二轮 4 条核实矩阵（含 #3 的机制更正与真问题定位）与顺带发现清单。
- `API.md`：Multipart 限额顺序、Uploads（`extractMultipart` + `UploadGuard`）、
  `nestedParam`/`requestParam`、`route_template` 规整、registry 淘汰与报告。
- `AGENTS.md`：DO/DON'T 加"上传内容校验""上传限额对齐""取参数用对名字"三行；文件地图加上传一节。
- **全仓 628 行被 `[...]` 污染的注释修复**（35 个文件；这批注释是 `6316708`「翻译所有中文注释」
  那次自动化替换留下的残骸——中文被吞、英文技术名词残留，出现 `/// Module contract[...]`、
  `/// [...]publish/consume[...]Event[...]API[...]` 这类半句）。按 `6316708^` 的原文核对语义后用
  英文重写（与各文件现存语言一致）；`Page.zig` 里 JSON 示例的 `[...]` 是合法省略号，保留。
  校验：逐文件比对"非注释行"与 HEAD，**34/35 文件零代码改动**（另一个是我本批的改动），全量测试通过。

## [0.15.45] - 2026-09-15

### Added
- **进程级错误渲染器**：框架自产错误体有三条出口（链内 `ctx.sendError`、路由前裸 socket、
  handler 自写），此前只有第三条能被应用改。新增
  `http.useRfc7807Errors()`（一次把前两条统一成 RFC 7807，media type
  `application/problem+json`）、`http.setDefaultReject(?AuthRejectFn)`、
  `http.clearDefaultReject()`、`http.problemReject`、
  `http.setTransportErrorRenderer(?TransportErrorFn)` / `http.problemTransportBody`
  （路由前 408/413/431/503 的体）、`Context.sendErrorEnvelope()`（绕过渲染器）。
  `ModuleGateConfig` 补 `reject: AuthRejectFn`，**可保留 `.unknown = .deny` 同时改 404 体**。
  装渲染器后"链尾中间件改 404 体 + 放弃 `.deny`"的 workaround 可删。
- **handler 侧权限匹配**：`Context.permissionsCsv()`（与 `rolesCsv()` 同形）、
  `Context.permissionMatches(expr)`、`http.permissionMatchesContext(ctx, expr)`、
  `http.permissionMatchesWith(ctx, expr, config)`（与某个 gate 完全同语义）。
  与 gate 的 OR 语义（`portal:user|portal:shop`）共用同一实现 —— 匹配原语下沉到
  `ZigModu.security.Rbac.exprMatchesCsv` / `exprMatchesAuthInfo`，
  `permissionGateWith` 改为委托，杜绝 handler 与 gate 两套语义漂移。
- 测试：`src/test/ErrorShape.zig`（链内/路由前/未捕获 500 的形状矩阵，含"装 `defaultReject`
  为默认渲染器不得自递归"）、`src/test/PermissionMatch.zig`（OR 表达式、AuthInfo 权威性、
  `.roles`/`.rbac` 同语义）、`resilience/RateLimiter.zig` 两个并发用例
  （去守卫会放行 117/100 —— 有牙）、`redis.zig` 三个 RESP 分帧用例。
- 文档：`docs/UPGRADING.md`（逐版本 breaking / 影响面 / 一行改法）、
  `docs/ISSUES_FROM_ZIGSHOP.md`（第 1–13 条核实矩阵：属实/部分/已存在/不属实 + 依据）。

### Fixed
- **Redis 客户端四件套**：① `pool_size <= 1` 的共享单流分支**不加锁** → 命令交叠、
  流错位后端点永久挂起；② 每条命令只 `readSome` 一次 → 大回包截断且余字节留在流里污染
  后续命令；③ `read_timeout_ms` / `write_timeout_ms` 声明了但全仓无读取点 → 读可以永久阻塞；
  ④ 解析失败后连接原样放回池。现在：按 RESP 分帧读（`$`/`*` 先读长度再读体，**尾部 CRLF
  从流里消费并校验**）、无池分支由 `stream_mu` 串行化、读路径每次阻塞前 poll 到 deadline
  （超时 `RedisTimeout`）、写路径 `SO_SNDTIMEO`、任一失败即 `evictStream()` 摘除该连接。
- **`ProblemDetails.toJson` 不做 JSON 转义**：`detail`/`instance`/`type` 含引号即产出非法
  JSON（校验消息会带用户输入）。现全部经 `std.json.Stringify` 转义，
  `ValidationProblem` 同步；`statusTitle` 补全 402/411/413/414/415/416/418/428/431/451/501/505/507。
- **`RateLimiter` / `RateLimiterRegistry` / `SlidingWindowRateLimiter` 无任何同步**：
  `current_tokens` 的读-改-写竞争会**同一枚令牌被两个线程花掉**（实测去掉守卫后 100 枚令牌
  放行 117 次）；registry 的 `StringHashMap.put` 会撕裂元数据。三类各加内部短守卫
  （先 `spinLoopHint`，32 次后 `std.Thread.yield()`；临界区只有一次 map 查找或两次浮点运算，
  故不自旋到死也不引入 `io` 参数）。
- **`RateLimiterRegistry` 按值存 `RateLimiter`**：`getOrCreate` 返回的 `*RateLimiter` 指向
  map 内部存储，**下一次插入触发 rehash 即悬垂**（与 zent 连接池 UAF 同族）。改为存
  `*RateLimiter`（堆分配），指针在 registry 生命周期内稳定 —— 有"插入 257 个 key 后旧指针
  仍可用"的测试。

### Changed
- `RateLimiterRegistry.limiters` 字段类型 `std.StringHashMap(RateLimiter)` →
  `std.StringHashMap(*RateLimiter)`（**破坏性**，仅影响直读该字段的代码；用
  `get`/`getOrCreate`/`count` 的调用方不受影响）。详见 `docs/UPGRADING.md`。
- `ctx.sendError` / `ctx.sendErrorResponse` 现在优先交给进程级渲染器；未装渲染器时行为
  与之前一致，仅 `msg` 改为 JSON 转义（含引号的消息此前会产出非法 JSON）。
  装渲染器后 `sendErrorResponse` 的业务 `code` 不被表达（RFC 7807 无业务码位）。
- `ModuleGateConfig.reject` 默认仍为 `defaultReject`（信封），但 `defaultReject` 经
  `ctx.sendError` 转发，故跟随进程级渲染器；`setDefaultReject(defaultReject)` 解析为
  "不装渲染器"，避免自递归。
- `RateLimiter.acquire` 标注 DEPRECATED（与 `tryAcquire` 同义）。
- `AGENTS.md` 测试计数不再抄写具体数字，改为"以 `zig build test` 输出为准"
  （`-Ddb` 收窄、平台、门控用例都会改变计数，抄下来必然漂移）。

### Docs
- `BEST_PRACTICES.md`：新增「错误响应形状：一条开关统一全框架」（三种形状 × 触发路径 ×
  三条守则）、「共享限流器 / 统计结构的线程安全」（三个自查问题）、
  「跨函数边界返回：必须具名类型」；「数据访问选型」补 sqlx `Client`/`Transaction`
  两套签名与 `Rows`/`ManagedRows`/`BorrowedRow`/`QueryResult` 所有权表（签名已与源码核对）。
- `API.md`：新增「Error response rendering」「Permission matching」两节，校正
  `RateLimiter`（`acquire` 返回 `bool`、补 `release`）、`RateLimiterRegistry`（补 `get`/`count`
  与指针稳定性）、补 `SlidingWindowRateLimiter`。
- `AGENTS.md`：文件地图加 `UPGRADING.md` / `ISSUES_FROM_*`；DO/DON'T 加错误体统一、
  单 gate 换形状、handler 问门户三行。

## [0.15.44] - 2026-09-12

### Changed
- **zent 适配 v0.39.2 → v0.41.1**（pin 升到发布 tag `?ref=v0.41.1#2611ade`）：
  - **采用 v0.40 的一行式释放**：示例里 23 处手写 `zent.codegen.deinitEntity(infos, info, &e, alloc)`
    （含 5 处 `for (...) deinitEntity; list.deinit()` 手写循环）全部改为生成客户端的
    `client.<entity>.deinitRow(&e)` / `deinitRows(&rows)`；整页释放需要把 `const rows` 改为
    `var rows`（helper 会重置调用方的列表并使其可复用）。
  - v0.41.0：`crud_helpers.queryRows` 被明确为**裸路径**（与 `driver.query` 同类，不带你配的
    软删/隐私/拦截器），必须用 `zent.scope` 组合 —— 已补进 `docs/ZENT.md` §15。
  - v0.41.1：修复 0.40.0 把 `deinitRows(rows: anytype)` 收窄成只认值、导致传 `&rows` 编译失败的
    回归；这条与本仓库「anytype 形参的契约写法」的规矩同源，已写进 §14。
- 文档：`docs/ZENT.md` 版本口径 / §14 兼容表（新增 0.40/0.41 三条）/ §15 使用边界、
  `AGENTS.md`、示例 README 同步；四个 zent 示例全部重建通过，zent-modulith 运行时
  实测（嵌套预加载 / 列表释放 / 裸 SQL 搜索 / 事务）零错误。

## [0.15.43] - 2026-09-12

### Added
- **公开 API 错误集快照**（建议第 3 条）：`src/test/ErrorSetSnapshot.zig` 用
  `@typeInfo` 反射钉住 `verifyToken` / `Multipart.parse` / `Server.start` 的错误集——
  ①消费方 `switch` 依赖的错误必须仍在，②总数不得超过记录的上限（**放宽即破坏性变更**，
  必须在本文件里显式确认），③退化成 `anyerror` 直接失败。基线：三者当前都是窄集
  （22 / 7 / 19），**没有 anyerror**。
- **组合矩阵测试**（建议第 7 条）：`src/test/CombinationMatrix.zig` 覆盖
  `moduleGate(.unknown = .deny) × skip_prefixes`（目录内放行 / 目录外拒绝 /
  `health/*` 等跳过前缀放行）与 `tenantResolver × JWT aud × override_existing`
  （默认 aud 优先、显式覆盖时 header 优先、`require` 时无租户即拒绝、query 回退）。
- **基数纪律写成明文禁令**（建议第 8 条）：`OBSERVABILITY.md` 明确禁止把
  `tenant_id`/`user_id`/`order_id` 直接做标签（几千租户 = 几十万序列），给出两条正解
  （受限基数 family 仅用于小集合 / 租户维度留给日志与 trace），并指出"按租户分流 =
  把基数变成部署维度"。
- **升级自查从"读文档"变成"跑命令"**（建议第 4 条的一部分）：`docs/ZENT.md` §14 顶部
  给出三条命令（`zmodu audit` / `zig build check-production` / `zig build test`，
  含形态与错误集快照、文档一致性）与"升级后先删 `.zig-cache`"的硬提醒。

## [0.15.42] - 2026-09-12

### Added
- **文档 ↔ 代码一致性门禁**（建议第 6 条）：新增 `src/test/DocsConsistency.zig`，
  扫描 `docs/API.md` 里所有 `pub fn` / `pub const` 声明，逐个核对 `src/` 中是否存在
  该声明（大写名字按"类型构造器"写法放宽、忽略仅注释里出现的词），缺失即 CI 失败。
  首次运行抓出 **4 个纯虚构 API**：`TransportProtocol`、`MqttTransport`、
  `TaskScheduler`、`PasRaftAdapter`——它们从未存在于本仓库，却被当作可用能力写在
  API 参考里。已修正文档（Transport 段改为真实情况：HTTP/1.1 + h2c + gRPC，
  MQTT 明确"未提供"；Scheduler 改为真实的 `zigmodu.cron.Scheduler` 签名；
  Raft 指向 `core/cluster/RaftElection.zig` 并标注 experimental），另修掉把
  `Context.body` 字段写成方法的条目。
  范围只含 API.md：BEST_PRACTICES 有意展示**应用侧**示例代码（`OrdersApi` 等），
  扫它全是误报。

### Changed
- **`anytype` 形参的契约显式化**（建议第 1 条）：`Preflight.dbCheck` /
  `Preflight.EnvCheck.fromMap` / `PrometheusMetrics.registerMetricsRoute[Path]` /
  `Dashboard.registerRoutes` 现在
  ①doc comment 首句写明"必须是**指针**、需要哪些方法"，
  ②加 `@compileError`（含 `@typeName` 与实际修法）把错误提到**调用点**，
  ③配一条"鸭子类型替身"回归测试固定契约。
  最佳实践写法（含分类：对象指针 / 鸭子 client / 任意事件值 / comptime 元组）落在
  `docs/BEST_PRACTICES.md`「`anytype` 形参的契约写法」。

## [0.15.41] - 2026-09-12

### Added
- **`Auth.optional`：公开但可个性化的路由（一等能力）**。`Auth` 此前只有
  `inherit | public | jwt`：`public` 完全跳过验签、`ctx.userId()` 恒为空，而需要身份就等于
  `.jwt`（游客直接 401）。C 端用户中心这类"公开但想看是谁"的接口只能靠 handler 里手写
  token 检查。现在：

  ```zig
  pub const routes = [_]cr.RouteSpec(State){
      .{ .method = .GET, .path = "me", .handler = me, .meta = .{ .auth = .optional } },
  };
  ```
  语义：**有 token 就验并注入身份，token 缺失/非法/过期一律不影响请求**，永不 401。
  与 `.public` 的差别被显式化并可测试（矩阵用例覆盖 optional×{无/有效/坏 token}、
  public×有效 token、jwt×{无/有效 token}）。同时把此前只在 `authFromCatalog(AuthBackend)`
  一支存在的"尽力而为验签"抽成 `attachIdentityBestEffort`，三处中间件行为一致；
  `permissionGate` 的 public 短路不覆盖 `.optional`（这类路由仍可带 permission/roles 元数据）。

### Added

### Changed
- **CI 门禁 `check-production.sh` 覆盖全仓**：原来只扫 9 个硬编码热文件 + `src/security/*`，
  其余文件（含 auth/tracing 中间件）长期是盲区。现在按前缀分层：
  `src/api|core|http|metrics|messaging|scheduler|security` **强制**，其余
  （`ai/`、`extensions/`、`im/`、`log/`）先**告警**（28 处，作为待收紧清单）。
  扫描同时忽略注释行（文档里提到该模式不再误报）。

### Fixed
- **`catch unreachable` 的可达性收敛**（第 2 类"把环境失败当成不可能"）：8 处
  `page_allocator.create(...) catch unreachable`（中间件构造：CORS / jwtAuth /
  jwtAuthFromCatalog / …WithPermissions / authFromCatalog / tenantResolver / moduleGate /
  tracing）在 `ReleaseFast` 下是 UB，现改为 `catch @panic("<可读原因>: out of memory")`；
  2 处测试内的 `catch unreachable` 改为 `try` / `error.TestUnexpectedResult`；
  `SO_SNDTIMEO` 设置失败从静默改为 **warn**（那意味着慢客户端能无限阻塞写线程）。
- **`PrometheusMetrics` 直方图可能半初始化**：`createHistogramFamily` 里
  `counts.append(0) catch {}` 失败时会留下"有桶无计数"的直方图（`le` 行永久错误），
  现改为清理并降级到 overflow 序列，保证桶与计数始终同步。
- 重点路径上 15 处 `catch {}` 改为带上下文的 debug/warn（分布式锁回收与释放、
  HTTP/2 窗口与 RST、连接池回收与退避、outbox/cron 睡眠、access-log、
  auto-instrumentation），符合仓库既有的"不吞错误"规则。

## [0.15.40] - 2026-09-12

### Changed
- **zent 适配 v0.37.0 → v0.39.2**：`examples/zent-modulith` 的 pin 升到发布 tag
  （`?ref=v0.39.2#1fbf86c`）。两个 minor 带来：
  - **BREAKING（0.38）**：`queryTargets` / `queryTargetsByValue` 改为 **fail-closed**
    （软删 → 隐私 → 拦截器，与 `WithEdge` 同契约）；旧的"仅软删"语义改名为
    `queryTargetsUnscoped` / `queryTargetsByValueUnscoped`。目标表带策略而无
    `privacy_ctx` 时返回 `error.PrivacyDenied` 而不是静默跳过过滤。
  - **安全（0.39）**：新增 `zent.scope`，让**手写 SQL** 也能拼上同一份读契约；
    此前裸 SQL 会静默绕过租户/隐私过滤。`<col>Like`（`Contains` 的诚实名字）、
    NULL 容忍扫描器（`scanRow*Lenient` / `queryAllLenient`）、`zent.version`。
- **文档同步**：`docs/ZENT.md` §4.7 补"裸 SQL 的安全前提（必须接 `zent.scope`）"，
  §14 兼容表新增 0.38/0.39 两条升级注意，§15 增加三条使用边界（scope、fail-closed
  邻居读取、宽松扫描器的适用面），版本口径与依赖示例更新到 v0.39.2。

## [0.15.39] - 2026-09-12

### Changed
- **`ctx.query` / `ctx.form` 升级为多值容器 `Params`**（zapi 反馈 P1-4）：重复键
  （`ids=1&ids=2`，即 `<select multiple>` / 复选框组的原生形态）不再被覆盖，括号键
  （`role_id[0]`、`tags[]`）按原样保留供上层解释。**兼容性**：`get()` 仍返回**最后**一次
  出现的值（与旧的单值 map 语义一致），消费侧 `ctx.query.get("page")` 无需改动。

  ```zig
  ctx.query.get("ids")            // 最后一次（历史语义）
  ctx.query.getFirst("ids")       // 第一次
  ctx.query.getAll("ids")         // 全部（到达顺序）
  ctx.queryArray(alloc, "ids")    // 重复键或 ids[0]/ids[]（索引排序）
  ctx.formArray(alloc, "role_id") // 表单同上
  ctx.paramPath("filter.tags")    // 点路径 → filter[tags]（form 优先、回退 query）
  ctx.bindForm(T) / bindQuery(T)  // 绑定契约不变；现也吃重复键与 role_id[0] 首元素
  ```
- **参数数量上限**：`Server.Config.max_params`（默认 1000，对标 PHP `max_input_vars`）。
  query 与 form 都按"出现次数"计数，超限返回 `error.TooManyParams`，**不静默截断**。

### Added
- `zigmodu.http.Params` 导出（`put`/`putOwned`/`get`/`getFirst`/`getAll`/`getArray`/
  `getPath`/`getSegments`/`count`/`totalValues`），6 个新测试覆盖重复键、括号数组
  （索引排序 + `[]` 追加 + 无括号回退）、点路径、参数上限与所有权转移。

## [0.15.38] - 2026-09-12

### Added
- **`multipart/form-data` 一等支持**（zapi 反馈 P1-5）：`src/http/Multipart.zig` +
  `ctx.multipart(cfg)` / `ctx.bindMultipart(T, cfg)`。

  ```zig
  var form = try ctx.multipart(.{});         // defer form.deinit();
  const title = form.value("title");         // 文本字段
  if (form.file("avatar")) |f| { ... }       // 文件：f.data / f.filename / f.content_type
  // 文本字段也可整批绑定：
  const Meta = struct { full_name: []const u8, age: i64 };
  const meta = try ctx.bindMultipart(Meta, .{});   // 与 bindForm 同一套 loose 绑定契约
  ```

  要点：文本查找**永不返回文件块**（`value()` 跳过带 filename 的 part）；「首次命中优先」
  与 `bindForm` 一致；整个 body 在内存中解析（框架本身已缓冲请求），因此防护是 `Config`
  限额 —— `max_parts` / `max_part_bytes` / `max_total_bytes`，超限分别返回
  `TooManyParts` / `PartTooLarge` / `PayloadTooLarge`，而非盲目分配。
  **不做流式落盘**（请求体已被缓冲，流式 API 只会假装省内存），落盘是应用决策。
  新增 5 个测试（boundary/Disposition 解析矩阵、混合表单含文件、四类拒绝路径、
  文本字段桥接、Context 端到端）。

### Added
- **静态文件服务**（`zigmodu.http.staticFiles` / `StaticFiles.staticMiddleware`，zapi 反馈 P1-6）：

  ```zig
  try zigmodu.http.staticFiles(io, &server, allocator, "/assets", "public", .{
      .cache_control = "public, max-age=3600",
  });
  ```

  实现为**中间件**而非路由：路由器现阶段的 `/prefix/*` 只匹配前缀本身，路由式挂载无法服务其下文件。
  行为约定：只服务 `GET`/`HEAD`（其余 405）；**不做目录索引/列表**（`/assets/` → 404）；
  路径先归一化再碰文件系统（`..`、绝对路径、反斜杠、`:`、NUL 一律拒绝）；
  `ETag`（size+mtime）支持 `If-None-Match` → 304；`Range` 支持 206 / 416（多段范围回落为整实体）；
  超过 `max_bytes`（默认 16 MiB）返回 413 而不是整文件读进内存；
  正文按 `chunk_bytes` 分块读取。挂载对象按进程生命周期分配（所有权契约写在文件头注释里）。

### Fixed
- **表单体的解码口径与 query 不一致**（`parseFormBody`，zapi 反馈 P0-1）：query 的
  key/value 都会 percent-decode，而 form body 原样 `dupe`。后果有两层：`formValue("name")`
  拿到的是 `%E5%BC%A0%E4%B8%89` 而不是 `张三`；更隐蔽的是 **key 也未解码**，浏览器把嵌套键
  编成 `role_id%5B0%5D`，于是 `formValue("role_id[0]")` 永远查不到。现在两条路径同一口径
  （`%XX` 与 `+`→空格 都在解析期处理）。
  ⚠️ **迁移提示**：消费侧若自己补了解码器（zapi 的 `contract/params.zig` 即此类），
  需要删掉，否则会对已经解过的值再解一次；这类解码器同时可删的还有"逐字符比较原始 key"
  的查找函数。
- **CORS 空 allowlist 的失败模式不可诊断**（`Middleware.cors`）：显式传空
  `allow_origins` 时所有跨域请求（含预检）一律 403 且无任何提示；现在启动时会 warn 一行。
  （默认值仍是 `&.{"*"}`，只有主动传空数组才会触发。）

### Added
- **`ctx.bindForm(T)` / `ctx.bindQuery(T)`**（zapi 反馈 P0-2）：表单与查询的声明式绑定，
  语义与所有权对齐 `bindJsonLoose` —— 字段名 loose 匹配（`role_id` ↔ `roleId`）、
  缺省值保留、字符串字段深拷贝（调用方统一 free）、缺必填字段返回 `error.MissingField`
  而不是静默零值。支持 `[]const u8` / 整数 / 浮点 / `bool`（`1/0/true/false/on/off`）
  及其 `?T`；其它类型是编译期错误（不静默跳过字段）。
  同时支持嵌套键的**首元素**绑定：字段 `role_id` 可直接吃下 `role_id[0]`。
- **`ctx.pathParam(name)`**：`param` 的显式别名，消除"路径参数 vs 任意参数"的误读。
- **`ctx.jsonValue(status, value)`**：`jsonStruct` 的别名。**注**：zapi 反馈称"框架只有
  `ctx.json(bytes)`"，实际 `jsonStruct(status, anytype)` 早已存在且正是"任意 Zig 值 →
  JSON"（P0-3 的真实缺口是命名可发现性，不是能力）。

### Added
- **Best-effort identity on `.public` routes.** `authFromCatalog` now verifies a
  presented token even when the catalog marks the route `.public` and attaches
  the resulting identity, instead of skipping verification outright. A missing,
  malformed, or expired token changes nothing — the route stays public and
  `verifyFn` never writes a response — but a *valid* one lets a public handler
  optionally personalize (`ctx.userId()` / `optionalPortalUser`). This closes
  the gap where a public-but-personalized endpoint (e.g. a C-end user center)
  always saw an anonymous caller, since the framework had no "optional auth"
  mode (`Auth` is `inherit | public | jwt`). Cost on public routes: one header
  lookup without a token, one JWT verification with one.

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.15.37] - 2026-09-12

### Fixed
- **CI `Test (DB=postgres)` 失败**：新增的真实 PG 锁用例连不上 CI 的 service 容器。
  根因是 sqlx 的 PG 驱动默认 `sslmode=require`（安全默认，保持不改），而测试用
  service 不支持 TLS —— 仅在该 job 里设 `PGSSLMODE: disable`（一次性测试库）。
  已用同一条件在本地复现并验证。
- **CI `Benchmark` job 首次真正执行即失败**：`benchmark-action` 需要 `gh-pages`
  分支，仓库还没有 → 加 `skip-fetch-gh-pages: true` 让其自举（该 job 此前因
  分支条件写错从未运行，v0.15.36 修好条件后才暴露）。

## [0.15.36] - 2026-09-12

### Changed
- **zent 适配 v0.33.0 → v0.37.0**：`examples/zent-modulith` 的 pin 升到发布 tag
  （`git+…?ref=v0.37.0#d36edb7`）。新版本带来：池 `max_wait_ms` 真正阻塞等待
  （默认 0 = 旧语义）、嵌套预加载每层一次查询（消除 N+1）、outbox 认领式派发
  （可并发 dispatcher）、迁移默认加锁 + checksum 校验、`StorageKey` 字段↔列名映射、
  `queryTargetsByValue`（UUID 主键也可遍历边）、`BulkInsert` 按参数上限分片、
  参数化原生谓词 `sql.RawArgs`、聚合助手、upsert 自定义表达式、边写入
  （`AddEdgeIDs`/`RemoveEdgeIDs`/`SetEdgeIDs`/`ClearEdge`）。
- **补齐 v0.36 的崩溃恢复语义**：`examples/zent-modulith` 的 dispatcher 每次派发前
  调 `Outbox.requeueStale(..., 300)`，把"认领后派发进程死掉"遗留的 `processing`
  行放回 `pending`（否则这些行永久卡住）。
- 文档同步：`docs/ZENT.md` 版本口径与 §14 兼容表（新增 0.34–0.37 四条升级注意）、
  `AGENTS.md` 已知事实、`examples/zent-modulith/README.md`、
  `examples/{shopdemo-zent,metaverse-creative}/build.zig.zon` 注释。

### Docs
- **最佳实践补全**：`docs/BEST_PRACTICES.md` 新增「生产就绪检查清单」（进程/HTTP/数据并发/
  可观测/验证发布五组，每条都标注承接它的能力）与「数据访问选型（zent / sqlx）」；
  修复目录与正文脱节（补上韧性/背压/预检/kid/迁移恢复/多副本/工具/陷阱/升级/协作等条目）并
  删除一处重复的「模块设计原则」标题残片。
- **`docs/ZENT.md` 新增 §15「v0.34–v0.37 实战用法与边界」**：逐能力给出"什么时候用 /
  什么时候不要用"，含 12 条易踩点（金额聚合用 `AggregateText`、边写入要包 `beginTx`、
  `requeueStale` 阈值须大于最长发布时间、池 `deinit` 静默期、预加载目标不带租户作用域、
  SQLite 表达式 upsert 换实现等）；§14 标题与目录对齐到 0.37。

### Added
- **故障注入测试**（`src/test/FaultInjection.zig`）：走完整 HTTP 链路验证韧性行为，
  而不只是状态机单测 —— 下游挂 → 两次失败后熔断 → **后续请求不再打下游**（断言
  调用计数不增长）→ 恢复窗口后半开探测 → 成功即闭合恢复；限流器 2 令牌后回 429。
- **契约门禁**（`src/test/ContractGate.zig`）：注册接口承诺（状态/响应体片段/头），
  经真实路由 dispatch 后逐条校验，漂移即构建失败；负例验证漂移会被报告而不是
  静默通过。`ContractVerificationResult` 新增 `deinit`（此前所有权无处释放）。
- **真实 PostgreSQL 的锁验证**：`DistributedLock` 的 `.postgres` 方言在 PG 17 上
  实测通过（双 owner 互斥、释放移交、过期回收）；经 `ZIGMODU_TEST_PG=1` 门控，
  CI 的 `test-postgres` job 已带上该变量与 PG 环境变量。
- **迁移失败恢复指引**：`docs/BEST_PRACTICES.md` 新增运维小节，写清 `success=false`
  重试语义、部分生效要求幂等、`ALTER TABLE` 失败被跳过的代价，及现场查询 SQL。
- **CI 夜间 soak job**：`schedule`（每天 03:17 UTC）+ 手动触发，
  `zig build soak -Dsoak-clients=64 -Dsoak-iterations=200`，带 30 分钟超时。
  跨租户泄漏与冻结注册表并发断言终于有了持续运行的场地（默认 push/PR 不跑，
  保持反馈速度）。
- **旗舰示例改用生产配置**：`examples/tenant-mgmt` 从手工拼中间件切到
  `http.productionProfile`（连接背压 + 安全/观测中间件 + `/metrics` +
  `/health/live` + `/health/ready`，删掉自带 health 路由避免重复）。
- **路由标签归一化**：ComptimeRouter 的模式不带前导 `/`，而 server 级路由带 ——
  指标标签统一补 `/`，避免同一接口裂成两条序列。
- **`zigmodu.Preflight`**（`src/core/Preflight.zig`）：启动预检，把"凌晨三点炸"变成
  "拒绝启动"。内置 `envCheck`（缺必填变量）/ `secretCheck`（占位或过短的 JWT
  secret）/ `dbCheck`（SELECT 1）/ `migrationCheck`（有待应用迁移）/
  `clockCheck`（时钟偏移）；`Severity.warn` 只告警，检查之间互不影响，不 panic。
  参考接线见 `examples/zmsaas/backend/src/main.zig`。
- **JWT 密钥轮换（kid）**：`SecurityModule.setKeyring(&JwksKeyRing)` —— 新 token 头部
  带 `kid`，验签按 `kid` 取密钥，旧密钥留在环里即可无缝轮换；未知 `kid` 返回
  `error.UnknownKeyId`（不退化成"用主密钥试一下"）。不设 keyring 时行为不变（无 kid）。
- **CORS 通配符告警**：`productionProfile` 在 `cors_origin = "*"` 时打 warn。
- **受限基数的指标标签**：`PrometheusMetrics.createCounterFamily` /
  `createHistogramFamily`（单标签 + 硬上限，超额统一进 `route="__other__"`）。
  `productionProfile` 的黄金信号全部按 **`ctx.route_template`**（匹配到的模式，
  不是带 id 的原始 path）打标签 —— 终于能回答"哪个接口在慢"。
  新增 `Context.route_template`，在两处分发点（`handleForTest` / connFiber）设置。
- **业务面黄金信号**：
  - `OutboxConsumer.setMetrics(metrics)` → `outbox_selected_total` /
    `outbox_delivered_total` / `outbox_failed_total` / `outbox_pending`；
    `pendingCount()` 查积压，`startPolling(io, interval_ms)` 内置后台轮询
    （取代手工 cron），失败计数 `consecutive_failures`。
  - `PrometheusMetrics.setScrapeHook(hook, userdata)`：**抓取时采样**，无需后台
    线程即可刷新连接池/积压等 gauge。
  - `Client.poolMetrics()`：暴露已有的 `ConnPool.PoolMetrics`
    （active / idle / waiters / 各项计数）。
- **`zigmodu.DistributedLock`**（`src/core/DistributedLock.zig`）：后台任务的跨实例互斥。
  接口 `Lock.tryAcquire(name, ttl_ms)` / `release(name)` + `NoopLock`（默认，保持
  单进程行为）+ `SqlLock(Client)`（表锁，`.sqlite` / `.postgres` 用
  `ON CONFLICT DO NOTHING`、`.mysql` 用 `INSERT IGNORE`，靠 `rows_affected`
  判定抢占，争用不是错误）。持有者崩溃后由 `ttl_ms` 过期回收。表名做标识符校验。
- **cron 跨实例互斥**：`Scheduler.setLock(lock, ttl_ms)` —— N 副本部署时每个 job
  每分钟只在一个副本上执行（`cron:<job>` 为锁名）；未设锁时行为与之前完全一致。
- **迁移跨实例锁**：`MigrationRunner.setLock(lock, ttl_ms)` —— 滚动发布时并发实例
  不会再抢着建历史表/执行 DDL；抢不到锁返回 `error.MigrationLocked`。
- **`http.productionProfile()`**（`src/http/Profiles.zig`，导出
  `zmodu.http.productionProfile` / `ProductionConfig` / `ProductionProfileState`）：
  一行接齐生产配置 —— 连接背压（`max_connections` / `over_limit_response` /
  `header_timeout_ms` / `request_timeout_ms`）、安全与观测中间件
  （CORS + request-id + recover + security headers + tracing + access log）、
  `GET /metrics`、`GET /health/live` + `/health/ready`、可选 dashboard。
  路径可配。**必须在 `router.mountAll` / `addRoute` 之前调用**（`addRoute` 会在
  注册时快照全局中间件链）。
- **黄金信号指标**：`productionProfile` 默认维护 `http_requests_total`、
  `http_responses_{2xx,3xx,4xx,5xx}_total` 与
  `http_request_duration_milliseconds` 直方图（1ms–5s 固定桶）。
- **`docs/OBSERVABILITY.md`** + **`docs/grafana/zigmodu-overview.json`**
  （7 面板）：PromQL 速查、告警阈值起点、Prometheus/K8s 抓取配置、上线自检。
- **生产部署参考** `examples/production-deploy/`：nginx / Envoy TLS 终结 +
  h2c 反代、docker-compose、K8s（探针/HPA/Prometheus 注解）、systemd
  （`Restart=always`）、多阶段 Dockerfile。
- **WebSocket 出站背压**：`Server.Config.ws_write_timeout_ms`（`SO_SNDTIMEO`，
  0 = 旧行为）+ `WsFramer.isWritable()` 水位探测。超时写返回
  `error.WriteTimeout` 并 shutdown 连接，慢客户端不再无限阻塞写线程。
- **`PrometheusMetrics.registerMetricsRoutePath`**：可自定义 metrics 路径。
- **`-Dnet-tests=false`**：沙箱环境跳过全部依赖 loopback 的测试（统一经
  `NetworkProbe.available()` 收口）。
- **`zmodu.NetworkProbe`** 导出。
- **连接级背压与慢连接防护**（`src/api/Server.zig`）：`Config.max_connections`
  （0 = 不限）+ `over_limit_response`（`.close` / `.unavailable` 回 503，走裸
  socket 写以免阻塞 accept 线程）、`Config.header_timeout_ms`（请求行 + header
  阶段总 deadline，超时回 408；header 读完后立即解除，不误杀慢速上传）。支持
  `HTTP_MAX_CONNECTIONS` / `HTTP_HEADER_TIMEOUT_MS` 环境变量。连接计数
  `active_connections` 在 accept 时预留、fiber 退出时释放。
- **并发浸泡测试**：`zig build soak`（`-Dsoak-clients` / `-Dsoak-iterations`）。
  真实 socket 的 N 并发 × M 租户压测，断言跨租户读取为 0、FrozenMap 在并发读 +
  拒写下不撕裂、连接计数回落 0。刻意不挂在 `zig build test` 上。
- **audit b22**：拦截 `.tenant_source = .query`（客户端可篡改的租户来源）。
- **`zmodu.NetworkProbe`** 导出（受限沙箱里 socket 测试的跳过探针）。
- **`FrozenMap` / `FrozenStringMap`**（`src/core/FrozenMap.zig`，导出
  `zmodu.FrozenMap/FrozenStringMap`）：启动期填充、`freeze()` 后只读的
  共享注册表容器。冻结后读无锁、任意并发安全；写返回 `error.Frozen`。
  针对 worker 池上并发 put/resize 撕裂 HashMap 元数据导致读者
  `panic: incorrect alignment` 的崩溃类别。
- **panic 钩子**（`src/api/PanicHook.zig`，导出 `zmodu.panicHook`）：
  Server 在 dispatch 前将当前请求 `METHOD /path` 写入 threadlocal，
  panic 时先输出该上下文（无分配、固定缓冲）再走
  `std.debug.defaultPanic`。应用 root 一行接入：
  `pub const panic = zmodu.panicHook;`。
- **`zmodu audit` 新规则**（`tools/zmodu/src/audit.zig`）：
  b19 请求路径裸 panic（`@panic` / 语句级 `unreachable;`）、
  b20 文件作用域共享可变 HashMap（建议 FrozenMap）、
  b21 请求路径裸 `@alignCast`（豁免 `ctx.user_data` 与
  `@alignCast(self)` 单例注册）。

### Security
- **zent-modulith 示例不再信任客户端租户**：`zent_crud.CrudApi` 的
  `.tenant_source` 由 `.query` 改为 `.attr`，products 五条路由接入
  `jwtAuthFromCatalog`（租户取自 JWT `aud` claim）。此前改一个 URL 参数
  `?tenant_id=` 即可跨租户读取。配套新增 dev-only 取 token 路由
  （`ZENT_DEV_TOKEN=1` 才挂载，明确标注为后门）与 README 更新。

### Fixed
- **CI benchmark job 从未执行**（`.github/workflows/ci.yml`）：`if` 只匹配
  `refs/heads/main`，而默认分支是 `master` → 性能回归门禁（`alert-threshold`
  150%）形同虚设。与其它 job 一致改为 `main || master`。
- **`HealthEndpoint.handleReadiness` 编译错误**（`const details` 却调用
  `components.deinit(*Self)`）——任何调用方都会编译失败，readiness 端点不可用。
- **`Dashboard.registerRoutes` 两处编译错误**：`handleModules` 的 `allocPrint`
  缺参数元组、`get` 需要 `*RouteGroup`。`productionProfile(.dashboard = true)`
  暴露了它们。
- **`config` 模块的 `readToEndAlloc` 失效 API**（`YamlToml` ×2 /
  `ConfigManager` / `TomlLoader`）：Zig 0.17 已移除该方法，`parseFile` /
  `loadJson` / `loadFile` 属于"导出但一用就编译失败"的公开 API，现改用
  `Dir.readFileAlloc`，并补 `YamlParser.parseFile` 端到端测试。
- **Server `stop()` 在 Linux 上唤醒阻塞的 `accept()`**（`src/api/Server.zig`
  `closeListener`）：先 `shutdown(SHUT_RDWR)` 再 close。Linux 下 close 不会
  中断阻塞中的 accept（内核为进行中的调用保持 socket 存活），accept 循环
  永不退出、`join` 死锁——ubuntu CI `Run tests` 曾因此挂起 50 分钟。
- **WS fiber 测试自定义栈 128KB → 2MB**（`src/api/Server.zig`）：glibc
  aarch64 `PTHREAD_STACK_MIN=131072` 恰为 128KB，TLS 无空间导致
  `pthread_create` EINVAL（std 内 unreachable panic）。
- **示例内存泄漏（audit b17）**：tenant-mgmt `getById` 结果在
  updateTier/suspendTenant/getTenant 三处从未释放；updateTier 混用静态
  字符串破坏 owned 语义（统一改为 dupe + defer freeTenant）。
  tenant-shop `Tx.priceCents` 改用 `freeScanned`。

### CI
- **CI 全链路修复并首次全绿**：job 级 `if` 误用 `env` 上下文导致工作流
  历史上从未调度（0s 失败）；mlugg/setup-zig 旧式 URL 404（改为直接从
  ziglang.org 下载 arch-first tarball，Zig pin 升至 0.17.0-dev.1970）；
  ubuntu 缺 `libmariadb-dev-compat`（`libmysqlclient.so` 由该包提供）；
  示例路径 `zfsaas`→`zmsaas` 改名未同步；integration / mysql /
  live-service 三个 job 失败时上传日志 artifact 便于诊断。

## [0.15.35] - 2026-09-03

### Security
- **`validateSqlFragment` 黑名单加固**（`src/sqlx/sqlx.zig`）：新增拒绝反引号
  （MySQL 标识符引用）、`#` 注释、`*/` 闭合注释，以及整词匹配（大小写不敏感）
  的语句关键字 `UNION` / `SELECT` / `INSERT` / `UPDATE` / `DELETE` / `DROP` /
  `ALTER` / `CREATE` / `ATTACH` / `DETACH` / `PRAGMA` / `EXEC` / `EXECUTE` /
  `TRUNCATE` / `GRANT` / `REVOKE` / `REPLACE`。标识符内子串（如
  `updated_at`、`selection`）不误伤；`IN (?, ?)` 等括号谓词不受影响。
  值仍必须走 `?` 占位符——此为纵深防御而非主防线。
- **JWT 空 `aud` 不再写入 `tenant_id` attr**（`src/api/Middleware.zig`）：
  原先空串 attr 会遮蔽 `X-Tenant-ID` 回退路径并让下游 int 解析失败；
  现在 `aud` 为空时 attr 缺省（`ctx.tenantId()` 返回 null）。

### Changed
- **EventBus 线程安全语义澄清**（`src/core/EventBus.zig`）：文件头原注释自称
  "Thread-safe" 与事实相反，已修正；`EventBus` / `TypedEventBus` /
  `UnifiedEventBus` 均显式标注 NOT thread-safe，并发场景指向
  `ThreadSafeEventBus`。`ThreadSafeEventBus` 新增 `publishedCount()`。
- **`CrudService.setEventBus` 改收 `*ThreadSafeEventBus`**（`src/data/CrudService.zig`）：
  CRUD 事件在 HTTP handler 线程发布，原 `*TypedEventBus` 无同步保护。
  zmodu 代码模板（`service_header.zig.tpl`、smoke 脚手架、`saas` 生成器）
  同步默认生成 `ThreadSafeEventBus`。
- **`tenant-mgmt` 示例落地真实租户隔离**：租户中间件从空壳改为
  JWT `aud` 优先、`X-Tenant-ID` 头回退（dev 路径）、两者冲突 403；
  user/subscription handler 改经 `requireTenantId(ctx)` 读 attr，
  不再信任 `?tenant_id=` query；`GET /subscriptions/{tenant_id}` 校验路径
  租户与上下文一致，跨租户 403。中间件顺序修正为 JWT → tenant。
  `ci-integration.sh` 新增三条租户隔离探针（401/200/403）。
- **`check-production.sh` 门禁覆盖全文**：`Server.zig` / `sqlx.zig` 的硬编码
  行号截断（1700/2739）改为与其它热路径一致的动态截断（首个 `test "` 行），
  消除后半文件不受约束的盲区；扩扫后当前零违规。
- **README**：`DistributedEventBus` / `SagaOrchestrator`（及 zh 版
  ClusterMembership & Raft）补 ⚠️ experimental 标注；`examples/README.md`
  移除四个不存在的幽灵示例章节（dependency-injection / architecture /
  v2-showcase / ecommerce）并同步学习路径与统计表。
- `gen-jwt-token` 支持 `JWT_AUD`（生成带 `aud` 的 token，供租户探针使用）。
- **EventBus / DI 接入 Application**（闭环"主推抽象未接线"）：新增
  `core/EventRegistry.zig`（按 `@typeName(T)` 类型擦除的 get-or-create
  注册表，只发放 `ThreadSafeEventBus`）与 `core/ModuleContext.zig`
  （`allocator`/`io`/`events`/`services`）。模块可选声明
  `pub fn initWith(ctx: *ModuleContext) !void`——`ModuleScanner` 编译期
  探测（`@hasDecl`）、`Lifecycle.startAllWith` 优先调用（与 `init` 并存时
  只调 `initWith`；仅 `initWith` 而无 ctx 时启动失败并回滚）。
  `Application` 持有 `events` + `services`，`start()` 完成后
  `services.freeze()`（之后 `get` 为无锁只读、注册报 `ContainerFrozen`）；
  新增 `app.eventBus(T)` / `app.service(T, name)` 与
  `Builder.withService(T, name, ptr)`（借用注册，容器不销毁实例）。
  `di.Container` 新增 `registerBorrowed`（修复栈指针注册被 deinit 销毁的
  所有权陷阱）。shopdemo 成为首个真实使用者：order 服务经
  `app.eventBus(OrderEvent)` 接线并在 create 时发布事件。最佳实践文档：
  `docs/EVENTS_DI.md`（MODULITH.md §2.3/§4 与 AGENTS.md 文档地图已交叉引用）。

### Changed
- **zent 适配 v0.32.3**（sqlite 连接访问串行化修复，公共 API 无签名变化）：
  `examples/zent-modulith` pin 升至 `v0.32.3` tag；`docs/ZENT.md`
  版本口径与远程 zon 样例同步，§14 新增升级条目（`Rows` 持锁至
  `deinit()`、遍历完立即释放）；`AGENTS.md` / 示例 zon 注释同步。
  `examples/metaverse-creative` 修复 libpq 链接：`src/db.zig` 引用
  `zent.sql_postgres`，而 zent 在检测到 libpq 头文件时接入 `pg_c` 却
  不链库本体——`_shared/db_link.zig` 新增 `linkDetected()`（检测到才
  链接），示例 build.zig 经它为 `zent_mod` 链接 pq。
  `examples/zent-modulith/README.md` 的 products 载荷补必填的
  `price`（Decimal 列）字段。
- **zent 适配 v0.33.0**（`UseInterceptor` 覆盖 Create/BulkInsert——create
  上 `whereEq` 语义为"缺省才填"，显式值保留）：`examples/zent-modulith`
  pin 升至 `v0.33.0` tag，并落地真实拦截器演示路由
  `GET/POST /api/v1/tenant-injection`（`features_demo.InterceptorApi`）：
  独立 client + 哨兵租户 777，create 缺省填充、查询透明限定，验证
  v0.33.0 写路径拦截在消费端生效（此前头注释宣称该演示但实际未实现）。
  `docs/ZENT.md` §14 新增升级条目（**存量拦截器升级后会开始影响写入，
  需先审计**）；README 补对应章节。⚠️ 排障记录：Zig 0.17-dev 增量缓存
  对 path/fetch 依赖的模块变更可能不失效——升级依赖后行为未变时先删
  示例的 `.zig-cache` 再重建（本次实测：symbol 探针证明二进制里是旧版
  zent，清缓存后一次性通过）。

### Removed
- **`persistence/Database.zig` 的 stub `Repository(T)`**：纯空壳
  （所有方法 no-op）且无任何租户变体，与 `Orm.zig` 的 `Repository(T)`
  同名并存易误用。零调用点，直接删除。规范入口仍是 `data.Repository(T)`。
- **`TenantContext.getDefault()`**：返回非原子可变全局指针、标注
  "non-concurrent use" 且零调用点，属待触发隐患。新增
  `TenantContext.fromAttr(?[]const u8) ?TenantContext` 桥接 HTTP attr
  通路与 TenantContext 类型（attr 缺失/非法/非正数 → null）。

## [0.15.34] - 2026-08-31

### Changed
- **zent 升级 v0.32.1 → v0.32.2**（纯修复，零 breaking）：v0.32.2 修复连接池
  use-after-free（`swapRemove` 移动尾元素导致借出指针被污染，空闲驱逐后
  health-check 段错误）、MySQL 非整数主键 upsert（字符串/UUID PK 回退
  `VALUES(pk)` 而非 `LAST_INSERT_ID`）、多线程池测试改用线程安全 allocator。
  `examples/zent-modulith` zon 锁定 `git+https#v0.32.2`（hash
  `zent-0.32.2-oiur-xP7DwCyv9mm_lt74G6jR5qmlJYBW6hGBJ3bkXUv`），文档版本口径同步。

## [0.15.33] - 2026-08-31

### Fixed
- **accept 循环被 keep-alive 连接卡死（服务器整体停止 accept 的挂死）**：
  `Server.start` 原先用 `conn_group.async` 派发 connFiber。`std.Io.Threaded`
  的 `groupAsync` 在 `busy_count >= async_limit`（默认 cpu_count-1）时回退为
  `groupAsyncEager`——在 accept 线程上同步执行 connFiber。connFiber 是
  keep-alive 读循环，客户端挂机不发下一请求时永久阻塞在 `readv`，accept
  循环从此被占死、对所有新连接静默。修复：改用 `conn_group.concurrent`
  （默认 `concurrent_limit = .unlimited`，**不会 eager 回退**，超限时返回
  错误而非劫持调用线程）；超限时拒绝该连接并继续 accept。同类隐患一并修复：
  `WebSocket.zig` / `DistributedEventBus.zig` 的 accept 循环派发
  handleConnection 同样由 `async` 改为 `concurrent`。

### Changed
- **zent 升级 v0.32.0 → v0.32.1**（纯新增 + CI 修复，零 breaking）：v0.32.1
  新增 interceptor 多租户查询改写示例与 eager/upsert 基准，并修复四个既有
  CI 失败；已 pin zigmodu v0.15.32 并移除其 libc 补丁。`examples/zent-modulith`
  zon 锁定 `git+https#v0.32.1`（hash `zent-0.32.1-oiur-3jiDwAri-…`），
  文档版本口径同步 v0.32.1。

## [0.15.32] - 2026-08-27

### Added
- **sqlx 读写分离（read/write splitting）**：`Client.withReplica(&replica)`
  注册只读副本——`query`/`queryCursor` 及其派生（queryRow/queryRows/
  findOne 等）路由到副本，`exec`/`beginTx`/batch 写入恒走主库；副本读失败
  自动回退主库（降级为单主模式而非报错），副本自身的熔断器打开时直接用
  主库。附路由正确性与故障回退两组回归测试。
- **HTTP header 数量/总字节上限（header 炸弹 DoS 防护）**：
  `Server.Config.header_limits`（默认 100 个 header / 16KB 总量），超限返回
  `error.TooManyHeaders` → HTTP 431。此前 body 有 `max_body_size` 但 header
  无上限，攻击者可发大量合法小 header 耗尽请求 arena。

### Fixed
- **`zmodu` CLI 缺 `link_libc`**：`build.zig` 里 zmodu 模块未设
  `link_libc = true`，Zig 0.17-dev.813 起 `@cImport` 不再隐式链接 libc，
  依赖方（如 zent CI）需打补丁兜底。现已与框架主模块一致显式链接。
- **Cron scheduler `deinit` 潜在 UB**：mutex lock 失败被吞后继续 unlock
  （futex 后端下 unlock 未锁住的 mutex 是未定义行为）——现在 lock 失败时
  记录错误并跳过配对 unlock 与任务清理。
- WebSocket：pong 发送失败静默吞噬 → debug 日志（对端会由下次心跳暴露）；
  升级拒绝路径补 best-effort 注释。HttpClient 连接池回收路径同注释化。
- **`ComptimeRouter.wrapHandler` 双重缺陷**：`handler` 改为 comptime 参数并移除
  共享的容器级 `var Store`——旧实现里同一 `State` 的所有 wrapper 共享一个
  `Store.fn_ptr`（后写覆盖），`openApiRoutes` 的 `openapi.json`/`docs`/`scalar`
  三条路由会串台到最后注册的 handler；且在 `pub const routes` 等 comptime
  上下文中触发 `unable to evaluate comptime expression`。
  `openApiFromCatalog` 的运行时状态同步提升为容器级 `OpenApiRouteStore`
  （单 catalog 契约已注释声明），公共 API 签名不变。新增独立派发回归测试。
- **`zmodu orm --backend zent` 外键解析两处 bug**：表级
  `FOREIGN KEY (col) REFERENCES …` 的列名被截成 `col)`（右括号未剥）并再次被
  内联扫描重复抓取；内联 `col TYPE NOT NULL REFERENCES …` 回溯只吃一个类型词、
  把修饰词误当列名。修复：第二遍跳过 `)` 结尾的表级引用，回溯改为抓到行首/
  逗号后按「修饰词剥离 + 类型词丢弃」取列名。**同时新增外键 → edge 声明生成**
  （`edge.From("<name>", Ref).Field("col")`），两种 FK 书写形式均验证通过。

### Changed
- **OTLP / Vault 支持 HTTPS**（此前文档口径「待 stdlib」实际是滞后）：
  `OtlpExporter.exportSpans` 与 `SecretsManager.loadFromVault` 复用
  HttpClient 的 `std.http.Client` TLS 1.3 通道（系统 CA 信任库），
  移除 `OtlpTlsNotSupported` / `VaultTlsNotSupported` 短路；https 端点
  现在直达，证书链需入系统信任库。AGENTS 文档口径同步。
- **WebSocket 显式 `max_frame_size`**：`WebSocketServer.max_frame_size`
  （默认 4096）+ `setMaxFrameSize`，帧读取 buffer 按该值动态分配，替换原先
  隐含在 4KB 栈缓冲里的硬上限。
- **zent 升级 v0.29.8 → v0.32.0**（纯新增版本，零 breaking 验证）：
  `examples/zent-modulith` zon 锁定 `git+https#v0.32.0`
  （hash `zent-0.32.0-oiur-4vYDwDyEvLh_lnPwxRmJdXAc5920URMil2NQatJ`），
  `examples/shopdemo-zent` 按本地 sibling v0.32.0 构建通过；新增能力可用：
  `SaveOrUpdateOn`/`SaveIgnore` upsert、`Row.tryGet*`、`field.Decimal`（精确
  金额列）、`WithEdgeOptions` inner-join eager loading、`beginTxFromDriver`、
  `managedEntity`/`dupeEntityTo` allocator 安全 teardown、v0.32 Interceptor
  运行时查询拦截、PreparedCache 字节级 key 比对（hash 碰撞修复）。
- **`zmodu orm --backend zent` 模板修复**（生成代码此前无法编译）：
  `client.zig` 返回类型改为泛型实例化 `zent.codegen.client.Client(infos)` 并
  导出 `pub const infos/Client`；schema 体改 `pub const` 并由 client 经
  `schemas.*` 引用；移除 zent 已不存在的 `.Required()` 链式调用（字段默认
  NOT NULL，nullable 列才 `.Optional()`）；`.Default` 按列类型发零值字面量
  （Int→`0`，旧 `""` 在 PG 上是非法 DDL）；zent 版 `module.zig` barrel 改为
  导出实际生成的 `schema`/`client`。生成结果已对 zent v0.32.0 实测编译通过。

### Documentation
- **`docs/ZENT.md` 升级为电商/社交主推组合指南**（版本口径 v0.32.0）：顶部新增
  主推定位；§2 决策表电商/社交默认 zent；新增 §4.8「电商 / 社交主推能力矩阵
  （v0.30–v0.32）」（`field.Decimal` 精确金额、`SaveOrUpdateOn`/`SaveIgnore`
  业务键幂等、`WithEdgeOptions(.inner)` 防 limit skew、`beginTxFromDriver`
  池上事务、`ManagedEntity`/`dupeEntityTo` 请求级 arena、`SelectExpr` 聚合
  DTO、`Row.tryGet*` NULL 安全）；§14 升级表补 v0.28–v0.31（含 ⚠️ v0.29
  `field.Time` 全方言改 BIGINT epoch 的 PG 存量表迁移提醒）。README /
  README.zh / docs/README / AGENTS 文档地图同步主推标注。
- `examples/zent-modulith` 新增 v0.30–v0.32 能力演示端点：`PUT /api/v1/sku-stock`
  （业务键 upsert + Decimal）、`GET /api/v1/feed2/authors-with-posts`
  （inner-join eager load + arena 深拷贝），并已在文档中注明 Interceptor
  接入位置。
- **文档基线校准**：`AGENTS.md` 测试计数 820→990/1009（19 skipped）、
  `docs/EVALUATION_REPORT.md` 与 `docs/PRODUCTION_ROADMAP.md` 版本口径/结论
  统一到 v0.15.32；`scripts/release.sh` 版本校验与 bump 范围扩到这两个
  长期被漏掉的文件。

## [0.15.31] - 2026-08-26

### Added
- **可插拔 AuthBackend + catalog 唯一 bypass 真相**（ISSUES_FROM_ZAPI M1/M3）：
  `http.authFromCatalog(&slot, backend, .{})` 包住任意 `AuthBackend`
  （`verifyFn(ctx) → ?Identity`），仅 `RouteMeta.auth == .public` 跳过验签；
  内置 `http.jwtBackend(&sec)` / `http.jwtBackendWithPermissions(&sec, loader)`
  （≡ `jwtAuthFromCatalogWithPermissions`）。消费端可删除并行 `public_paths` 清单。
- **认证拒绝信封钩子**（M4）：`JwtFromCatalogConfig.reject` /
  `PermissionGateConfig.reject` / `AuthFromCatalogConfig.reject` 接受
  `AuthRejectFn`；`http.envelopeReject(.thinkphp)` 让 401 产出
  `{code:-1,msg,data:null}`，无需 fork 中间件。
- **类型化身份与属性读取**（M5/M11）：`ctx.setIdentity` / `ctx.identity()` /
  `ctx.userId()` / `ctx.userIdInt(T)` / `ctx.requireUserId()` /
  `ctx.requireUserIdInt(T)` / `ctx.tenantId()` / `ctx.rolesCsv()`，及
  `ctx.getAttrInt(T, key)` / `ctx.getAttrEnum(E, key)`。
- **响应信封方言**（M6）：`http.EnvelopeDialect`（`.default` / `.thinkphp` /
  `.ruoyi`）+ `ctx.setEnvelope` + `ctx.ok` / `ctx.okValue` / `ctx.fail` /
  `ctx.failCode` / `ctx.unauth` / `ctx.paginated`（RuoYi 分页为
  `{code,msg,rows,total}`；msg 一律 JSON 转义）。
- **租户解析中间件**（M7）：`http.tenantResolver(.{ .require = … })` 按
  `AppID`/`appid`/`X-Tenant-Id` 头或 `app_id` query 写 `tenant_id` attr；
  JWT `aud` 已存在时默认优先（可 `override_existing`）。
- **路由级门户 roles**（M8）：`RouteMeta.roles = "admin|ops"`（`|` = OR），
  `permissionGateWith` 在细粒度 permission 之前按身份 roles 拦截；catalog
  新增 `rolesFor`。
- **Token 提取器**（M12）：`http.TokenSource` + `extractBearer` /
  `extractHeaderToken` / `extractQueryToken` / `extractFormToken` /
  `extractTokenAny`（Bearer / X-Token / query / form）。
- **meta ↔ runtime 认证审计**（M2）：`http.Testkit.auditAuthCoverage(alloc,
  &server, &slot)` 无凭证分发全部 catalog 路由，返回漂移清单（`{param}` 段
  以 `1` 分发；WS/SSE 跳过）；空切片 = 通过，可接入 CI。
- **OpenAPI securitySchemes**（M14）：`OpenApiGenerator.bearer_auth` +
  `ApiEndpoint.requires_auth`；catalog 导出自动标注非 public 路由
  `security: [{bearerAuth: []}]`，并生成
  `components.securitySchemes.bearerAuth`（http/bearer/JWT）。
  `OpenApiFromCatalogConfig.bearer_auth` 默认开启。

### Documentation
- `docs/ROUTE_TABLE.md` 新增 §7.2（AuthBackend / 身份 / 信封）与
  §7.3（Resilience profiles 接线，M9）。
- `docs/ISSUES_FROM_ZAPI.md` 状态更新：M1–M9、M11、M12、M14 landed；
  M10 deferred（dispatch 层改动大，M6 已覆盖主要诉求）、M13 declined（审美性）。

### Fixed
- **HttpMetricsCollector.generateReport 自死锁**：持锁（非递归自旋锁）期间调用
  会再次加锁的公开方法 `avgDuration()`，`tryLock` 失败导致 100% CPU 永久自旋
  （也是 `zig build test` 卡 853/929 的根因——该死锁长期掩盖了后续测试的真实
  结果）。改为持锁内联计算均值。
- **bindJsonLoose / extractJsonLoose 丢字段默认值**：原实现用
  `std.mem.zeroes(T)` 初始化，`"id": null` 或缺字段时声明的默认值（如
  `id: ?i64 = 7`）被抹成零值。改为两段式：先填匹配字段，再给未匹配字段
  回填**声明默认值**（切片默认值同样 deep-copy，返回值所有字段统一自有，
  可一致释放）。同步修复相关测试的字符串泄漏。

## [0.15.30] - 2026-08-17

### Fixed
- **SQLx pgDecodeNumeric base-10000 boundary**: PG stores numeric values in a compressed form that strips trailing zero base-10000 groups. For numbers like `100000` (= 10 * 10000^1), PG may send `ndigits=1, weight=1, digits=[10]` instead of `ndigits=2, weight=1, digits=[10, 0]`. The previous code only handled the non-stripped form correctly, mis-decoding stripped values (e.g. `100000 → '10'`). The integer-part writer now pads with the missing high-order zeros when `int_out < int_chars`, so both stripped and non-stripped encodings produce the same decimal string. No migration needed: DB data is unchanged.

## [0.15.29] - 2026-08-17

### Fixed
- **SQLx arena ownership clarity**: `QueryResult` (sqlx.zig) now documents the arena contract explicitly and exposes a new `deinitArena()` method that takes no allocator. The arena path of `deinit(allocator)` ignores the `allocator` argument and uses the arena's own backing allocator (captured at scan time). When callers mix allocator identities and pass a different allocator than the one backing the arena, `ReleaseSafe`'s `SafeAllocator` rejects the free; `deinitArena()` makes the intent explicit and removes the ambiguity that produced the heysen `len: 7` panic in nested-allocator chains.

## [0.15.28] - 2026-08-15

### Added
- **分布式限流**：`data.redis_rate_limit.RateLimiter` —— Redis INCR + 首次
  EXPIRE 固定窗口（跨实例共享），fail-closed（Redis 不可用 → error，不静默
  放行）。`max=0` 立即拒绝。
- **跨实例 WS fanout 接线文档**：`DistributedEventBus` 订阅 → 本地
  `WebSocketServer.broadcast`（任意实例 publish → 全集群广播），无需新组件。

## [0.15.27] - 2026-08-14

### Added
- **Repository INSERT 回填自增 id**：`insert` / `insertOmitNulls` 现在把
  DB 生成的 `last_insert_id`（SQLite/MySQL）或 Postgres `SELECT lastval()`
  写回 `entity.id`（上游 PR：heysen_saas `orm-insert-id` 补丁合并，含
  `@hasDecl(B, "dialect")` 守卫与更完整的 `insert` 覆盖）。
- **对称 rows_affected 守卫**：`deleteByIdReturning(id) !u64` 与
  `updateReturning(entity) !u64`——0 表示记录不存在（乐观锁/NotFound 守卫），
  对齐既有 `deleteForTenant`/`updateForTenant`。

## [0.15.26] - 2026-08-14

### Added
- **宽松 JSON 绑定**（camelCase 拒收 + id:null 两个 bug 的框架侧根治）：
  - `Context.bindJsonLoose(T)` — 字段名 snake_case↔camelCase 双向匹配
    （`user_name` ↔ `userName`），`null` 视为缺失（零值默认），缺字段不报
    MissingField。
  - `http.extractJsonLoose(ctx, T)` — 同语义的 canonical extractor。
  - 默认 `bindJson`/`extractJson` 保持严格语义不变；存量 handler 只需把
    方法名换成 Loose 变体（sed 即可）。

## [0.15.25] - 2026-08-13

### Added
- **Repository opt-in 部分写入**（方案 C）：
  - `insertOmitNulls(allocator, entity)` — nullable 且为 null 的列省略，
    让 DB `DEFAULT` 接管（默认 `insert` 仍写显式 NULL 全量覆盖）。
  - `updatePartial(allocator, entity)` — 只 SET 非 null 字段（null 保持
    原值），pk 恒用于 WHERE。
  - 文档：`docs/ZENT.md` §5.1 对照 zent（builder 模式天然规避此问题）。

## [0.15.24] - 2026-08-13

### Added
- **migration barrel 导出（F2）**: `zigmodu.migration` 全量导出
  MigrationRunner/Entry/Applied/Status/Loader——业务侧可弃用自研 migrate.sh。

### Fixed
- **zmodu CLI Windows 交叉编译 3 处修复**: `wallClockSeconds` 用
  `RtlGetSystemTimePrecise`（原 `GetSystemTimeAsFileTime` 已从 std 移除）；
  `std.c.getenv` → `init.environ_map`（避免 libc 依赖）；args 迭代
  `iterate()` → `iterateAllocator`（Windows UTF-16 需 allocator）+ deinit。

### Changed
- **CI**: 新增 `windows-cross` job（`-Ddb=none -Dtarget=x86_64-windows`
  守护 Windows 分支）；push/pull_request branches 补 `master`（默认分支）。
- **examples/zent-modulith**: 依赖升级 **zent v0.29.8**（benchmark canary
  + outbox/shard/mysql-driver 测试补强 + docs 治理）。

## [0.15.23] - 2026-08-11

### Added
- **Swagger UI / Scalar UI 路由**：`swaggerUiHandler` / `scalarUiHandler` /
  `openApiRoutes` / `wrapHandler`（ComptimeRouter + `http.zig` 导出）——OpenAPI
  文档可直接在浏览器渲染。
- **`Context.html(status, data)`**：HTML 响应助手（自动 `text/html; charset=utf-8`）。

### Changed
- **HTTP/2 增强**：Hpack / Http2Server / HttpClient 迭代（含客户端路径调整）。
- **examples/zent-modulith**: 依赖升级 **zent v0.29.5**（`git+https#v0.29.5`，
  hash `zent-0.29.5-oiur-70vDgA9kXdpRrJUN1MRmz721OldWiTrrOJKSNF6`，ORM 迭代与
  适配更新）。

## [0.15.22] - 2026-08-10

### Changed
- **examples/zent-modulith**: 依赖升级 **zent v0.29.4**（pool UAF 修复——
  Rows 持有连接至 deinit；Sum f64；From edge FK 去重；codegen quota 1M）。

### Fixed
- **AccessLogger 线程安全**：全局中间件被所有连接线程共享，并发 `log()`
  append 同一 ArrayList 触发数据竞争 → SafeAllocator panic → 服务崩溃
  （并发 ≥10 即现）——已加锁。
- **HttpMetrics 线程安全**：`HttpMetricsCollector` 加自旋锁
  （beginRequest/endRequest/recordRequest/snapshot）；`metricsMiddleware`
  改用守卫的 begin/endRequest（原先裸改 `in_flight`）。
- **libpq 同步查询永久挂死**（Threaded Io）：`SO_RCVTIMEO` socket 读超时
  （`Config.query_timeout_ms`，默认 30s）+ `connect_timeout=10`——同步
  `PQexec*` 挂起不再永久卡死 fiber；超时后连接由池 ping / 重连回收。
- **ConnPool 等待不可中断**：acquire 池满等待改 50ms 分段 futex——响应
  fiber 取消与池关闭；slice 超时继续等待至 `max_wait_ms`（语义不变）。

## [0.15.21] - 2026-08-07

### Changed
- **examples/zent-modulith**: 依赖升级 **zent v0.29.3**（bool scan / WhereIn
  Zig 0.17 / defaultValueStr quota 修复）；改用 `git+https#v0.29.3` tag 依赖
  （tarball archive hash 不稳定，git tag 内容哈希稳定且锚定更规范）。

## [0.15.20] - 2026-08-07

### Added
- **Outbox 拆分出口治理**（对齐 Spring Modulith 决策记录）：
  - `OutboxPublisher.buildResubmit(policy)` 显式重发 API——failed/DLQ 条目按
    `max_attempts` / `older_than_seconds` / `tenant_id` 策略回 pending 重投
    （对齐 `FailedEventPublications.resubmit()` + Staleness Monitor）。
  - `OutboxPublisher.externalize(...)` 事件契约映射层——内部 topic →
    对外稳定契约 + `{"event","data"}` 信封（对齐 `@Externalized`）。
- **audit b17**：`collectModelStructs` 收集缩进局部 `const X = struct` 与
  单行 struct——函数内局部标量行类型误报消除（22 处边界收口）。

### Changed
- **docs**：EVALUATION_REPORT v5.8（Agent 流式化/tools_json/Metrics 原子化等
  实分重估）；BEST_PRACTICES 新增「Threaded Io 下同步阻塞」契约；
  PRODUCTION_ROADMAP 新增 gRPC「一等公民≠近期投入」与「拆分出口=事件契约+
  outbox」两条决策记录。

## [0.15.19] - 2026-08-07

### Changed
- **examples/zent-modulith**: 依赖从本地 sibling path 改为固定 git
  tarball **zent v0.29.2**（含 migrate 生成 quota 运行时化修复）。
  `.gitignore` 忽略 zig 0.17 的 `zig-pkg/` 包缓存目录。

## [0.15.18] - 2026-08-07

### Fixed
- **tools_json 非法 JSON**: `SkillRegistry.toOpenAiFunctionsAlloc` 每个工具
  多输出一个 `}`（`appendSlice` 字面 `]}}}}` vs `print` 的 `{{` 转义混用），
  导致 DeepSeek/OpenAI 对工具定义报 400 → ProviderError。已改为 `]}}}`，
  并给生成器测试补 `std.json.parse` 合法性断言防回归。

## [0.15.17] - 2026-08-07

### Added
- **Metrics 快照读取**: `AiProvider.Metrics.toStats()` 与
  `AgentMetrics.toStats()` 返回普通字段快照——外部读取/日志不再逐字段
  `.load(.monotonic)`，也避免 `{d}` 直接传 `atomic.Value` 的编译错误。

## [0.15.16] - 2026-08-06

### Fixed
- **HttpClient.requestStream 本地 HTTP 挂起（根治）**: `executeRequestStream`
  写请求后漏 `flush`（请求停在缓冲、与 server 死锁）；流式读取改
  `waitForReadable + posix.read`（同步调用链兼容）。此前本地 HTTP mock
  全挂（真实 HTTPS 因走 std.http.Client 正常）——现本地 SSE mock 可用。

### Added
- **Agent 流式正式落地（TODO #4）**: `Agent.run` 主循环切换到
  `chatStream + DeltaBridge`——`AgentHooks.on_delta` 真实触发（旁路推送
  content/reasoning delta，内部仍聚合完整响应供 ReAct 决策）。Agent mock
  测试全部改为 SSE 响应并恢复通过。

## [0.15.15] - 2026-08-06

### Added
- **CircuitBreaker 上下文感知调用**: `callWithContext(ctx, operation)` —
  熔断有状态调用（如 `*AiProvider`），补上"函数指针无法捕获调用方状态"
  的缺口；`call` 保持兼容。含上下文透传/失败/trip 测试。

## [0.15.14] - 2026-08-06

### Added
- **JWT 凭据版本（服务端会话吊销）**: `JwtPayload.ver` claim +
  `generateTokenWithTenantAndVersion`（`generateTokenWithTenant` 委派
  ver=0 兼容）。应用侧可 `payload.ver != users.token_version` 判定吊销
  （踢人）。修复 `verifyToken` 重建 payload 时漏拷 `ver` 的隐藏 bug；
  含 ver 往返测试。

## [0.15.13] - 2026-08-06

### Changed
- **Agent 流式切换验证记录**: `Agent.run` 的 chatStream 切换已用真实 DeepSeek
  API 验证（content delta 旁路推送 + done + 聚合一致）；因框架 mock 基建
  无法驱动 requestStream（本地 HTTP 挂起，Content-Length/chunked 均复现，
  真实 HTTPS 正常——已记录为 requestStream 本地路径 bug 候选），切换保留
  TODO 待 SSE mock harness 或修复后落地。

## [0.15.12] - 2026-08-06

### Added
- **Metrics 原子化**: `AiProvider.Metrics` 与 `AgentMetrics` 全字段改
  `std.atomic.Value(usize)`（threaded io 多 fiber 并发计数不再丢更新）。
- **audit b18 伪事务拦截**: `beginTx()` 后同函数仍用池连接 `client/backend
  exec` 静态报错——事务内读写必须走 tx 句柄（`tx.exec`/`execTx`），否则
  rollback 无效（自动提交）。
- **`RateLimiterRegistry` barrel 导出**（此前漏导出）。

### Changed
- **Lifecycle 文档统一**: QUICK-START/API.md 主 API 改为
  `Application.start/stop`，`startAll/stopAll` 标注为底层 Lifecycle。

## [0.15.11] - 2026-08-06

### Fixed
- **Time.zig**: Windows 时钟改用 `ntdll.RtlQueryPerformanceCounter`（本版 std 已移除 `std.os.windows.QueryPerformanceCounter`）。
- **README 版本漂移**: release.sh 的 perl bump 静默失配导致 README 停在 v0.15.4；补版本引用一致性校验（release.sh + check-release-tag.sh）。
- **静默吞错补日志**: provider JSON 降级 / Agent 工具参数 / Workflow WAL 坏条目。
- **Migration**: `run()` 重复 version 现 fail-fast（`error.DuplicateVersion`）；`loadHistory` 改为 DB 权威快照（修 markApplied+run 双算）。

### Added
- **中间件多实例隔离**: cors/jwtAuth/jwtAuthFromCatalog*/moduleGate/rateLimitPerClient 配置改存 `user_data`（page_allocator 一次性分配），同进程多 Server 不再互相覆盖。
- **`Transaction.queryRowPartial`**（事务内缺失列置零）；**`RouteCatalog.allPermissions()`**（菜单↔路由权限比对）。
- **Migration `markApplied(version)`**（bootstrap 旧库，不执行 SQL）。
- **audit 行级豁免**（`// audit: ignore` / `// audit: ignore b13`）与 **b3 精确化**（空字符串字面量不误报注入）。
- **`AgentHooks.on_delta`** + `chatStream` model 透出 + run_audit `model` 列（AgentResult.model 联动）。
- **事务范式文档**（BEST_PRACTICES.md：伪事务警示 + transact/三件套两种范式）。

### Changed
- **examples/zent-modulith**: 适配 zent v0.29.1（实体序列化改 `toMaskedJson`，跳过 json_arena/Allocator 注入字段）。

## [0.15.10] - 2026-08-05

### Fixed
- **StructuredLogger**: struct-field keys（comptime 字面量）入 map 前 dupe，消除
  释放只读内存导致的 ABRT。
- **ForTenant × camelCase**: 租户字段检查按模型 camel_case 推导（新增
  `snakeToCamel`），`findPageForTenant` 等在 camelCase 模型上可用。
- **Migration 切分**: 替换裸 `;` 切分为状态机（引号/注释/美元引号感知），
  支持含 PL/pgSQL 函数、触发器、DO 块的迁移脚本。

### Added
- **Repository ForTenant 全方法集**: `findByIdForTenant` / `findAllForTenant` /
  `updateForTenant` / `deleteForTenant`（rows-affected 守卫：跨租户操作返回
  0 行，`== 0 → NotFound` 模式可用）；`Tx(B)` 提供事务内
  `deleteForTenant` / `updateForTenant`。
- **软删读过滤**: 模型含 `deleted` 字段时所有读方法（含 ForTenant 变体）自动
  追加 `AND deleted = 0`；无该字段的模型零影响。
- **自动时间戳（opt-in）**: 模型声明 `sql_auto_timestamps = true` 时 insert
  自动填 `create_time`/`update_time`、update 刷新 `update_time`。
- **SqlxBackend borrowed 透传 + queryScalar**: `queryRowBorrowed` /
  `queryRowPartialBorrowed` / `queryScalar`（字符串类型编译期拒绝、自动释放）；
  `typeHasStrings(T)` / `QueryResult(T).has_strings` 编译期元数据。
- **Outbox 方言化**: `migrationSqlWithDialect`（mysql/postgres/sqlite）。
- **PermissionGate `deny_by_default`**: 未标注 permission 的路由可配置 403。
- **audit b10**: 豁免 best-effort `sendError`（SSE 断连等）。

## [0.15.9] - 2026-08-05

### Added
- **AiProvider reasoning_content 支持**: `ChatResponse` 新增
  `reasoning_content` 字段（推理模型如 DeepSeek-R1 的思维链），非流式
  `message.reasoning_content` 与流式 `delta.reasoning_content` 均解析；
  `StreamDelta` 新增 `reasoning_delta`，`chatStream`/buffered fallback
  透出；`freeResponse` 同步释放。已用真实 deepseek-reasoner 集成验证。

## [0.15.8] - 2026-08-05

### Changed
- **AI 开发文档完善**: 新增 `docs/AI_DEV_GUIDE.md`（业务接入全链路：KeyManager →
  Provider → 自定义 Skill → Agent/Workflow → HTTP/cron/outbox/MCP 接线、
  技能所有权/权限/超时规范、安全清单、观测调试）；`docs/README.md` 索引补全
  AI 编排/技能/LLM 策略/MCP 文档；AGENTS.md 文档地图加「AI 业务接入」入口；
  AI.md 顶部指向新指南；AI_SKILLS.md 补「开发自定义技能」指引。
- **queryRow 系字符串所有权契约落地**: `queryRow` / `queryRowPartial` 文档
  明确返回 **owned** 字符串（dupe 进 client allocator，row arena 返回前已释放；
  调用方须 `freeScanned`，否则泄漏）；新增显式命名别名 `queryRowOwned` /
  `queryRowPartialOwned`；新增 arena-借用 RAII 变体 `queryRowBorrowed` /
  `queryRowPartialBorrowed`（`BorrowedRow.deinit()` 一次释放、无需逐字段
  free；CachedConn 提供无缓存直通）。
- **audit 规则修正**: b10 豁免 `errdefer` / `rollback` 上下文里的 best-effort
  空 `catch {}`（事务回滚不再误报为吞错）；新增 b17 检查 owned `queryRow*`
  结果在函数内既未 `freeScanned` 也未 `return` 委托的泄漏点。
- **CrudApi 多租户 attr 可配置**: `CrudOpts` 新增 `tenant_attr`（默认
  `"tenant_id"`，即 catalog JWT 中间件 aud→attr 标准桥）；多门户场景可配置
  其他 attr 名。
- **Outbox 多租户支持**: `event_outbox` 迁移 SQL 内置可空 `tenant_id` 列
  （向后兼容）；新增 `buildInsertForTenant(topic, payload, tenant_id)`；
  `OutboxEntry` 与 `buildSelectPending` 带 `tenant_id`。
- **Repository 租户感知查询**: 新增 `findPageForTenant` / `findByIdsForTenant`
  / `findPageFilteredForTenant` / `countForTenant`（comptime 列名；模型缺租户
  字段时编译期报错，fail-closed）；原有方法签名不变。
- **API.md 旧别名清理**: `zigmodu.http_server.*` 示例统一为 `zigmodu.http.*`。

## [0.15.7] - 2026-08-04

### Changed
- **Bulk writes（`Repository` + `data.bulk`）**: `Repository.insertMany` /
  `upsertMany` 一条多行 SQL（SQLite/PG `ON CONFLICT ("id") DO UPDATE SET`、
  MySQL `ON DUPLICATE KEY UPDATE`，冲突 SET 默认除 id 外全列）；
  `Repository.findByIds` 单次 round-trip `WHERE pk IN (…)` 取代循环单行；
  `data.bulk` 方言感知批量 INSERT builder + 参数扁平化，exec 目标兼容
  Client/Transaction/SqlxBackend（新增 `SqlxBackend.dialect()`）。空行 /
  空列 / all-conflict upsert 均有守卫 + 回归测试（套件 858 pass），
  docs/API.md 补 Repository + bulk 参考。
- **zent-modulith 示例按 zent v0.27 能力沉淀**: 原子表达式防超卖、两级预加载
  + 边过滤/每父排序限量、复合 keyset 游标（平局不丢）、嵌套事务（savepoint）
  + `afterCommit` 事务事件、uuidv7 主键 + 敏感字段掩码、审计/校验/投影/
  批量插入/批量软删全链路 HTTP 演示；`tx_demo.zig` 下单编排（库存不足 409
  且整单回滚、事件提交后恰好一次投递）。文档同步：docs/ZENT.md 版本口径升至
  zent **v0.27.0+**（远程依赖示例 v0.27.0，升级注意补 v0.21–v0.27 要点）；
  AGENTS.md 工作区事实更新；两个 zent 示例依赖注释指向 `#v0.27.0`。
- **`zmodu market` Phase 2：远程发现 + 安装闭环**: `market update`（std.http 拉取
  远程索引 → `.zmodu/market-index.json`，坏缓存自动忽略、tmp+rename 原子写入）、
  `list/search/info` 改为本地 + 远程合并浏览（按 id 去重）、`market install
  <id> --dir … [--dry-run] [--verify]`（递归复制源码树，跳过 node_modules/.git/
  .output/.zig-cache 等；verify 就地跑 `zig build`）。签名、build.zig.zon 自动
  写入、CI 回归钩子留在 ADR-016（Phase 2c）。4 个新单测（合并去重 + copyTree
  跳过 junk 目录），CLI 套件 50 pass。docs/ZMODU_CLI_INTEGRATION 更新阶段表。
- **`zmodu market` 模块市场（Phase 1 本地策展目录）**: `tools/zmodu/src/
  marketplace/catalog.json`（schema_version 1）登记 12 个策展条目（zmsaas /
  tenant-mgmt / ai-ops / llm-policies / mcp-server / web4 / tenant-shop /
  shopdemo / basic + wechat-pay / aliyun-oss / apns stub）；`zmodu market
  list|search <q>|info <id>` 支持 `--json` 与 `--catalog PATH` 外部目录。设计
  取舍（ADR-015 式）：Phase 1 只做可发现性，远程 registry/自动安装/签名包
  延后（质量门优先）。2 个单测并入 CLI 套件；docs/ZMODU_CLI_INTEGRATION 补
  章节。
- **zsaas — SaaS 业务框架（zigmodu 后端 + saas-solidjs 前端）**: 新增 `zsaas/`
  目录。同一份业务模型 JSON 生成两端：后端 `zmodu saas <model.json>` 产出
  org 隔离的 zigmodu 模块（model/persistence/service/api/module/root 六文件、
  参数化 SQL 强制 `org_id` 租户过滤、ComptimeRouter `.auth=.jwt` + permission
  门控、ctx.json、saas-schema.sql 迁移产物），生成模块已在真实 zigmodu 工程
  编译通过；前端 `scripts/gen-business.mjs` 生成 SolidStart 管理页（列表/新建/
  编辑/删除 + i18n + 导航）+ `zmoduFetch` REST client（`/api/v1/<entity>`，
  Bearer 鉴权），tsc 全绿；`scripts/check-gen.mjs` 自检。
  **一键新建前后端**：`scripts/create-project.mjs <model.json> --name <app>` 同时
  创建 zigmodu 后端工程（自动把 zigmodu 依赖指向本地仓库，规避 `zmodu new`
  的旧 tag 占位 hash）与 saas-solidjs 前端工程（模板复制 + 业务页面），端到端
  验证：后端 `zig build` 编译通过 + `zmodu verify` 全过、前端页面生成、零泄漏。
  顺带修复 `zmodu new` 的既有 bug：生成 main.zig 引用未定义 `project_name`、
  未使用 allocator/init，以及 `generateLifeDir` 两处 ArrayList 泄漏。
- **AI key 轮换 bug 修复（审查发现）**: (1) `AiProvider` 自动换 key 重试后，调用方
  旧 lease 指向已失败的 key——`mgr.onSuccess(lease)` 会把刚 429 的 key 重置回
  健康、撤销冷却；新增 `provider.reportSuccess()` / `reportError(kind)` 用当前
  key 反馈，providerFor 文档同步；(2) `RedisCooldownStore` 冷却标记（SET）与
  失败计数（INCR）共用同一 key，cool 会覆盖计数——拆分为 `:fail` 子键，失败数
  跨进程准确；(3) `chatWith` 传输层错误补上报 `.network` 给池（chatStream 已有）。
  新增外部共享 store 路由单测（套件 838 pass）。
- **跨进程 KeyPool cooldown（CooldownStore）**: 新增 `ai/cooldown_store.zig`——
  `CooldownStore` 接口（isCooling/cool/bumpFailures/reset）+ `MemoryCooldownStore`
  （默认，单进程零依赖）+ `RedisCooldownStore`（跨进程：SET EX / INCR+EXPIRE /
  DEL，fail-open 本地镜像回退，对齐 RedisRateLimiter 先例）。`KeyPool` 的冷却/
  失败/禁用状态改为经 store 读写（多实例共享 key 时协调一致），计数器仍留本地
  观测；`AiKeyManager.setSharedStore` 一键接入。3 个新单测（套件 837 pass），
  docs/LLM_POLICIES.md §8 补跨进程接线。

## [0.15.4] - 2026-08-02

### Changed
- **AI AiKeyManager（provider + key 轮换，四层结构）**: `ai/key_pool.zig`
  （key 池：round-robin、429/配额指数冷却、连续 401 禁用、恢复与观测）、
  `ai/provider_registry.zig`（provider 注册表：endpoint + key 池 + 模型路由 +
  fallback provider 链）、`ai/provider.zig` 挂池（`bindKeyPool` 后
  chat/chatWith 对 401/403/402/429 自动换 key 重试一次）、`ai/module.zig`
  （`AiKeyManager`：`ProviderConfig` api_keys 配置 + 生命周期 +
  `providerFor`）。簿记 `std.Io.Mutex` 保护、HTTP 调用不持锁，适合高并发；
  10 个单测并入框架套件（834 pass）。docs/LLM_POLICIES.md §8 更新为四层接线。
- **git 依赖打包修复 + catch 反模式规则**: (1) `build.zig.zon` 的 `.paths` 增加
  `examples/_shared`——git+https 依赖按 `.paths` 打包，此前 `_shared`（及整个
  examples/）不会出现在拉取包里，业务方换版本必须重打 zig-pkg workaround，现
  已根治（`zig fetch` 后包内自带 `db_link.zig` / `zent_helpers.zig`）；(2) audit
  新增 `b11` 规则：未使用 catch 捕获（`catch |err| { _ = err; }` / `catch |_|` →
  应写 `catch {`），并修复 `src/ai/provider.zig` 存量；(3) `scripts/release.sh`
  移除 fingerprint 重算步骤——按 Zig 文档 fingerprint 是包永久身份、同包永不改
  （改了有信任/安全影响）；docs/SQLX_DRIVERS.md 补充 git 消费者说明。

## [0.15.3] - 2026-08-02

### Changed
- **`zmodu audit` 业务最佳实践检查器**: 新 CLI 命令，两组规则——architecture
  （模块自依赖/循环依赖/缺失描述/命名规范/依赖上限/未知依赖/base 模块依赖，
  与 `zigmodu.ArchitectureTester` 默认规则对齐）与 business（handler/model 含
  SQL、非参数化 SQL、`@ptrCast(ctx.user_data)`、legacy sendSuccess/sendFail、
  banned 导入、已移除 Zig 0.17 API、跨模块直接文件导入）。支持 `-j` JSON、
  `--group`/`--max-deps`/`--base-modules`、`.zmodu/audit-baseline.json` 基线
  （与 deadcode 同语义，`--update` 收缩）；CLI 单测 4 个并入 `zig build test`。
  同时把 `zigmodu.ArchitectureTester` 导出到 root（修复与
  docs/AI_METHODOLOGY.md 的断点），docs/ZMODU_CLI_INTEGRATION.md 补章节。
- **zmodu 工具链增强（P0/P1 落地）**: (1) `zmodu ci` 一站式门禁——`zig build`
  → `fmt --check` → `verify` → `audit` → `deadcode`，单命令面向 CI；(2)
  `zmodu graph [dir] [--out]` 输出模块依赖 Mermaid 图；(3) `zmodu diff old.sql
  new.sql --migration <name>` 自动生成 Flyway 迁移 SQL（CREATE/ALTER/DROP），
  并修复迁移时间戳恒为 `V19700101000000` 的既有 bug（改用 REALTIME 时钟）；(4)
  audit 规则配置 `.zmodu/rules.json`（`max_deps` / `disabled`）与两条新规则
  `b9`（handler 手工解析 Authorization/Bearer）、`b10`（空 catch 吞错）；(5)
  MCP server 新增 `zmodu_audit` / `zmodu_graph` 工具；(6) 修复既有 bug：
  `verify` 字面量 details 被 free 导致的无效释放崩溃、`module_integrity` warn
  details 泄漏、`parseSqlSchema` 对 `CREATE TABLE IF NOT EXISTS` 的表名泄漏、
  sql_diff 测试 const 数组协变编译错误（此前 zmodu CLI 测试产物为缓存旧态）。

## [0.15.2] - 2026-08-02

### Changed
- **freeValue 内存安全审计**: 全代码审计 `std.json.Value` 树所有权（handler 返回树必须由
  `ctx.allocator` dup 全部 key/字符串，调用方统一 `freeValue`）。修复
  `ai.business.db.query` / `entity.list` 返回树使用字面量 key `"rows"`/`"count"`
  （`ObjectMap.put` 按引用存 key，`freeValue` 会释放字符串字面量 → 无效释放；新增
  `std.testing.allocator` 回归测试，修复前实测 crash），以及 `Agent.run` 工具结果在
  `Stringify.valueAlloc` 失败时未释放的 OOM 路径泄漏。
- **Agent composition tests + AI benchmark + optional real-provider CI**: (1) `Agent.run` integration tests for the composed paths — context auto-compaction (`ContextManager` summarize invoked mid-run), budget exhaustion (early stop + `budget_exhausted`), and cooperative cancel (requested from `on_step`, stops next iteration); (2) `zig build benchmark` gains an AI section (workflow 20-step × 100 ≈ 5 ms); (3) CI adds an optional `ai-real-provider` job that runs `examples/llm-policies` against a real LLM when `LLM_API_KEY` is configured (GitHub secret). AGENTS/AI_METHODOLOGY docs synced.
- **SkillRegistry → MCP bridge**: `zigmodu.ai.mcp` exposes registered AI skills as Model Context Protocol tools — `toMcpTools` (MCP `tools/list` payload with inputSchema derived from tool parameters), `handleToolCall` (dispatch to the registry, text content result) and `serveStdio` (JSON-RPC 2.0 MCP server over stdin/stdout). Applications serve a session `SkillContext` (tenant/user/permissions), so `required_permission` gates and admin.* allowlists still apply. docs/MCP.md documents wiring + security.
- **MCP 真实链路示例 + 客户端冒烟 + 泄漏修复**: new `examples/mcp-server` exposes `kpi.query` (in-memory SQLite) + `ping` over real MCP stdio; `scripts/mcp-client-test.py` drives a real session (initialize / tools/list / tools/call) asserting protocol 2024-11-05 and KPI sum — verified locally with zero leaks. Fixes a `handleToolCall` leak (response tree was never freed after stringify). Added to CI example builds.
- **Admin/ops AI skills (P2 落地)**: `zigmodu.ai.admin` — `admin.cache.invalidate` / `admin.cache.clear` (whitelisted caches, wildcard keys rejected, `all=true` opt-in for clears), `admin.config.get` / `admin.config.set` (ConfigStore with mutable-keys whitelist), `admin.audit.export` (RunAuditStore query with kind/tenant/limit filters) and `admin.user.manage` / `admin.tenant.provision` (app-callback delegation). Each requires its own permission code and **must be explicitly allowlisted** — off by default, per the controlled-execution posture.
- **Dead-code baseline gate**: `scripts/check-deadcode.sh` fails CI when the repo gains new dead declarations (identity `file:kind:name:parent`, so line moves don't false-positive); removals are allowed and `--update` shrinks the baseline (`scripts/deadcode-baseline.json`, 37 items). Wired into CI after the deadcode smoke.
- **Agent end-to-end test**: `Agent.run` driven against a loopback mock OpenAI endpoint — tool_calls → skill dispatch → final answer, asserting `answer`, `metrics.tool_calls`, tool hook invocation.
- **Workflow DAG approval-gate test**: a `.approval` step in a DAG stops the run with `pending_human` after dependencies complete; downstream steps never run.

## [0.15.1] - 2026-08-02

### Changed

- **Remaining zero-test coverage**: added tests for `src/util.zig` (`randomHex`/`randomUuid` length + hex charset, `pluralize` english rules incl. vowel-y, `hexEncode` + `HashKit` MD5/SHA-256 known vectors) and `sqlx.errors.sqlStateToError` (SQLState → kind mapping, unknown → Other) — which surfaced two missing mappings (`57014` Timeout, `53300` TooManyConnections) now added. The remaining zero-test files are barrels (http/observability/security/data/root/docs/outbox/im/extensions/ai/web4), C bindings (sqlite3_c/libpq_c/libmysql_c + stubs), platform-specific io_uring stubs and the usage `main.zig`/benchmark entry — none require unit tests.
- **Fluvio native transport + thin-component tests**: `messaging.FluvioNative.NativeTransport` replaces the `fluvio` CLI subprocess with a pluggable TCP transport (line protocol over a socket; loopback server for tests/dev — end-to-end createTopic/produce/consume/list verified). `FluvioConnector` gains a `transport` field so apps inject the native transport or a faithful Fluvio SC/SPU protocol implementation. Added tests for the remaining zero-test thin components: `core.Event` (tagged-union payloads), `log.ModuleLogger` (+ `LogScope`), `metrics.MetricsBackend` (vtable routing).
- **Zero-test component hardening**: added tests for `sqlx.CircuitBreaker` (open/half-open/closed state machine incl. timeout re-open and half-open failure), `core.EventPublisher` (TypedEventBus publish + event validation + metadata) and `core.ApplicationModuleListener` (subscribe + receive). Fixing them surfaced three more lazily-compiled broken implementations: `EventPublisherMixin` validated against the wrong bus type (`EventBus` vs `TypedEventBus`), `ModuleListener.subscribe` called a 2-arg `EventBus.subscribe` with one argument and wrapped the handler with the wrong signature — both now compile and pass tests. `FluvioConnector` CLI-fallback stub semantics confirmed covered by existing tests.
- **Productization pass (per component audit)**: (1) **Security consolidation** — `http_middleware.securityHeaders()` (default HSTS/X-Frame-Options/CSP/etc.) is the canonical security-header middleware; deleted the broken `security/SecurityHeaders.zig` middleware (wrong return type + wrong `next` call, never compiled) and the duplicate broken `security/Csrf.zig` (`CsrfProtection` — invalid API calls, never compiled); `Middleware.csrf()` is now the single CSRF implementation. Added tests for csrf allow/reject and security-header injection. (2) **EventStore productionized** — JSON event serialization, replay invoking the application handler, snapshot-based replay (state + events after snapshot), thread safety via `std.Io.Mutex`, owned metadata; tests cover append/serialize/replay and snapshot replay. (3) **Removed deprecated `ScheduledTask.zig`** (placeholder `start()`/`calculateNextCronRun`; AI bridge uses `Cron.zig`) — `zigmodu.TaskScheduler` export dropped. (4) **gRPC audit** — server/client/bidi/bidi-pump streaming are fully implemented and tested (corrects an earlier "streaming UNIMPLEMENTED" note). (5) PluginManager comment dedupe + HealthEndpoint test.
- **Web4 production hardening**: `web4.x402_store.X402Store` — persisted invoices (SQL) with exactly-once redemption (`redeem(invoice_id, tx_hash)` → redeemed / not_found / already_used / expired), wired into `x402Middleware` via `X402Config.store` (invoices created on 402, proofs redeemed once, replay → 410). `web4.challenge.ChallengeStore` — one-time DID challenges (issue + verifyAndConsume, TTL, anti-replay), wired into `didAuthMiddleware` via `DidAuthConfig.challenge_store`. `DidAuthConfig.jwt_issuer` issues a JWT (`x-did-token` header) after DID auth so clients continue on the framework's JWT/RBAC chain. Fixed pre-existing did.zig leaks (credential issue/verify buffers). `examples/web4` upgraded to the production path (402→200→410 replay rejection; DID challenge + JWT issuance); docs/WEB4.md documents the hardening.
- **Web4 middleware + example**: `zigmodu.web4.middleware` — `x402Middleware` (no proof → 402 + invoice, invalid → 403, valid → pass; fail-closed default verifier, optional per-route `path_prefix` + `on_invoice` pricing hook) and `didAuthMiddleware` (did:key signature verification → writes `did` / `user_id` attrs; per-route `path_prefix`). New `examples/web4` demonstrates both flows end-to-end (402→200 with proof, 401→200 with a generated did:key signature), `docs/WEB4.md` documents protocol + wiring + security defaults. Added to CI example builds.
- **LLM policy real-chain fixes**: `llmJson` now deep-copies the parsed response out of the parser arena before returning (callers `freeValue` it safely — previously the arena-resident tree caused invalid frees; only fake `json_fn` tests exercised that path until now). Added an end-to-end test that drives `llmApprove` through a real loopback mock OpenAI endpoint (provider.chat → llmJson → decision), plus fixed a dangling-pointer in `examples/llm-policies` (provider/http moved to function scope). Verified live against DeepSeek: llmApprove/llmRiskDecide/llmDiagnose/llmVerify all return real model decisions.
- **Write-operation AI skills (P1 落地)**: `zigmodu.ai.actions` — `entity.create/update` (whitelisted writable columns via `EntitySpec.writable`, tenant column forced from `SkillContext.tenant_id` and rejected from the model, PK forbidden, permission `entity:write`), `command.execute` (app-registered commands via the transactional outbox, idempotency key = `SkillContext.run_id`, permission `command:execute`) and `report.generate` (app-registered aggregations → CSV/JSON, row-capped). Closes the "AI 只读 → AI 可执行" gap; `EntitySpec` gains a `writable` field (backward compatible).
- **Dead-code analyzer fixes (`zmodu deadcode`)**: fixed two false-positive roots in the zdeadcode reference resolver — (1) a `test "name"` whose name equals a function name shadowed the function in `name_map`, so references resolved to the (already-live) test and the function was reported dead; (2) container members (enum variants/fields/methods) shadowed same-named top-level declarations (e.g. `const deadcode = @import(...)` + `enum { deadcode }`). Members no longer overwrite top-level names; both cases have regression tests. Also fixed an arena leak in the CLI adapter and wired the analyzer's own unit tests (analyze + scanner) into `zig build test` (was previously only compiled, not run). Repo scan dropped from 45 to 39 findings (0.4%), with the remaining items genuine unused imports/functions plus layout field `WALEntryHeader._pad` (kept).
- **Dead-code checker (`zmodu deadcode`)**: integrated the zdeadcode analyzer (rustc `dead_code`-style reachability: unused top-level fns/consts/vars, container fields, enum variants, methods, never-imported modules; `.gitignore`-aware scanning; human + JSON output; exit code 0/1/2 for CI). Its unit tests ship with the zmodu CLI test suite (framework suite now 825/843). CI adds a deadcode smoke asserting detection + valid JSON.

## [0.15.0] - 2026-08-01

### Changed
- **AI 编排栈完整化（本轮大版本主题）**：workflow 线性↔DAG 混合 + 人工审批门
  （`.approval` step、`pending_human`、resume 恢复不重提）+ WAL 恢复 + LLM
  反射验证（`ai.llm.llmVerify`）+ `WorkflowMetrics` 观测 + `toMermaid` 图导出；
  触发三源统一（cron / fire / outbox，`ai.bridge.OutboxWorkflowBridge`）；
  业务工具 11 件（reporter/alerts/ticket/refund/risk/recon/approval/notify/kpi/
  sla/diagnose）；审批技能桥 `approval.request`（`required_permission` 门控）；
  LLM 策略 + RAG 上下文（`ai.llm`，失败安全回退 escalate）；持久化审批队列
  （`PersistentApprovalQueue`，tenant_id 隔离）+ HTTP API；outbox 消费端
  （`OutboxConsumer`）；运行审计（`RunAuditStore`，workflow + agent）；
  AI 观测聚合（`AiMetrics`）；技能注册表 OpenAPI/CLI 导出
  （`ai.skill_export` + `zmodu ai`）；多租户 AI 示例（tenant-ai）、LLM 接线
  教程（docs/LLM_POLICIES.md）、AI 全链路示例（ai-ops）。

### Changed
- **AI hardening pass**: (1) `Agent.audit_store` — standalone agent runs now persist to `RunAuditStore` (kind=agent, status/steps/duration), closing the durable-audit gap next to workflow runs; (2) `Tool.required_permission` + `SkillContext.permissions` — dispatch refuses with `error.PermissionDenied` when the tool's required permission is not granted; `approval.request` now requires `approval:decide`; (3) `skill_export.toOpenApi` gains optional bearer security (`OpenApiOpts.security_scheme` → components.securitySchemes + per-operation security); (4) barrel integrity test asserts the public `ai.*` API surface and caught a missing `ai.schedule` export (fixed); (5) docs synced — `docs/AI_SKILLS.md` now lists implemented business skills (kpi.query / approval.request / notification.send) vs planned ones, `docs/AI.md` reflects the removed `TaskScheduler`; (6) CI adds a `zmodu ai export-skills + openapi` smoke test asserting valid JSON.
- **AI skill registry → OpenAPI + CLI**: `zigmodu.ai.skill_export` renders a `SkillRegistry` as a JSON catalog (`toSkillsJson`) or an OpenAPI 3.0 document (`toOpenApi`, one `POST /skills/{name}` per skill with schema derived from parameters). `zmodu ai export-skills --out` writes the built-in catalog and `zmodu ai openapi --in/--out` converts any catalog (built-in or app-exported) to OpenAPI. tenant-ai serves both at `GET /api/ai/skills` / `GET /api/ai/skills/openapi` (verified live).
- **LLM policy wiring guide + example**: new `docs/LLM_POLICIES.md` walks through wiring a real `AiProvider` into `llmApprove` / `llmRiskDecide` / `llmDiagnose` / `llmVerify` (LlmPolicyCtx, RAG, json_fn testing, behavior contract), with a companion runnable `examples/llm-policies` (real-model mode via env vars, fake-json fallback so tests stay network-free). Fixed `llmDiagnose` summary parsing (missing `.string`) surfaced by the example, with a regression test. Added to CI example builds.
- **Durable AI run audit**: `zigmodu.ai.run_audit.RunAuditStore` persists one row per workflow/agent/approval run (run_id, kind, status, tenant, steps, duration); attached via `Workflow.audit`, run/resume record automatically. `list(kind, tenant, limit)` filters history; tenant-ai serves it at `GET /api/ai/runs` (tenant-isolated, verified live). `zigmodu.Time` exported from the barrel.
- **AI observability aggregation**: `zigmodu.ai.observability.AiMetrics` merges `WorkflowMetrics` + `AgentMetrics` + `TokenQuota` into one Prometheus document (attach pointers + labels) for a single `/metrics` endpoint; tenant-ai serves it at `GET /api/ai/metrics` (verified live alongside workflow runs).
- **tenant-ai example extended**: workflow endpoints now carry `WorkflowMetrics` and a `GET /api/ai/workflow/graph` Mermaid export of the step pipeline (incl. the approval gate); `ai.WorkflowMetrics` re-exported from the barrel. Verified live.
- **Approval skill bridge**: `registerApprovalRequestSkills` exposes `approval.request` (subject + amount; chain + policy app-registered) so an Agent inside a workflow `.agent` step can submit approvals directly; the escalated run lands in the queue and `resumeRun` continues after the human decides.
- **Workflow graph export**: `Workflow.toMermaid` renders the step graph as a Mermaid `flowchart` — implicit order edges for linear runs, dependency edges for DAG runs, nodes annotated with their kind (llm/skill/agent/approval). Tests cover both layouts.
- **LLM-backed workflow verification**: `zigmodu.ai.llm.llmVerify` implements `VerifyFn` for `Workflow.reflection` — the model judges whether the final output meets the goal (`{"pass":...}`); failures and malformed responses conservatively return `false` (re-run / escalate). Tests cover pass, fail and provider-error paths.
- **Workflow approval gate resume lifecycle**: end-to-end test proving run → `.pending_human` (gate persisted to WAL) → human approves → `resumeRun` continues from the persisted gate and finishes the remaining steps — the human decision is not re-submitted on resume.
- **Workflow approval gate (human-in-the-loop)**: new `.approval` step kind (`{ subject, amount }`) driven by `Workflow.approval_flow` — approved continues, rejected fails the step, escalated stops the run with a new `.pending_human` status so the app can hand the queue to a human and `resumeRun` afterwards (the gate re-runs under the same policy). Test covers both approved → completed and escalated → pending_human.
- **Workflow observability**: `zigmodu.ai.WorkflowMetrics` attaches to `Workflow.metrics` and accumulates `runs` / `completed_steps` / `failed_steps` / `escalations` / `reviews` (reflection re-runs) on every run/resume — including DAG waves; `toPrometheusFormat` exports `zigmodu_ai_workflow_*` counters alongside `AgentMetrics` and `TokenQuota`.
- **Multi-tenant AI example**: `examples/tenant-ai` — two tenants share one app with tenant-scoped AI operations: per-tenant KPI (`kpi.query`), business reports, alert rules, an approval chain with a `PersistentApprovalQueue` that carries `tenant_id` (tenants cannot see or resolve each other's pending items), and a workflow running the registered skills. `ApprovalApi` + `PersistentApprovalQueue` gained optional tenant scoping (`listPending`/`resolve`/`count` take `?i64`); `ai.freeValue` is now exported from the barrel. Added to CI example builds.
- **AI orchestration P2 (RAG context for LLM policies)**: `LlmPolicyCtx` accepts an optional `retriever` + `retrieval_query`; `buildContext` injects top-k retrieved chunks (policies / history / playbooks) into the `llmDiagnose` / `llmApprove` / `llmRiskDecide` prompts so decisions are grounded in business context. Test: keyword retriever chunk appears in the approval prompt and drives the outcome.
- **AI orchestration P2 (persistent approval queue)**: `zigmodu.ai.approval_store.PersistentApprovalQueue` — SQL-backed human approval queue with the same interface as the in-memory one (`push` / `listPending` / `resolve` / `count`, `migrate()` DDL) and a `queuedEscalationPersistent` hook. `ApprovalApi` is now generic over the queue type, so both in-memory and persistent queues mount into the ComptimeRouter unchanged.
- **AI orchestration P2 (outbox→workflow bridge)**: `zigmodu.ai.bridge.OutboxWorkflowBridge` routes outbox entries (exact or prefix topic) into `ai.trigger.fire(input)` — cron / in-process fire / outbox events are now three unified trigger sources; run outcomes flow back through the trigger's outbox writeback.
- **AI orchestration P2 (human approval queue + HTTP API)**: `zigmodu.ai.approval_api` — `ApprovalQueue` (thread-safe in-memory queue), `queuedEscalation` hook for `ApprovalFlow.on_escalated`, and an `ApprovalApi` ComptimeRouter module exposing `GET /approvals/pending`, `POST /approvals/{id}/approve`, `POST /approvals/{id}/reject` (`approval:decide` permission).
- **AI orchestration P2 (LLM default policies)**: `zigmodu.ai.llm` provides `llmDiagnose` / `llmApprove` / `llmRiskDecide` — LLM-backed callbacks for DiagnosisFlow / ApprovalFlow / RiskReview via `LlmPolicyCtx` (`provider` + injectable `json_fn` + `system_hint`); model failures or malformed JSON fall back to escalate (never silently approve). `ApprovalFlow` gains an `on_escalated` hook (+ `escalated_userdata`).
- **End-to-end AI ops example**: `examples/ai-ops` chains the built-in business tools into one runnable pipeline — `BusinessAlert` detect → `DiagnosisFlow` diagnose → `ApprovalFlow` approve (auto-approve small / escalate large) → `NotificationHub` notify → `OutboxConsumer` audit; `zig build run` prints the trace and `zig build test` asserts every stage. Added to CI example builds and the examples README.
- **Built-in business tool (P1, anomaly diagnosis)**: `zigmodu.ai.diagnose.DiagnosisFlow` takes a detected anomaly (from alerts/recon/sla/app code), gathers evidence via configured SQL queries and hands symptom + evidence to a `diagnose` callback (LLM or rule engine) producing likely causes + recommended actions; the result is written to the outbox (`ai.diagnose`) for audit/automation.
- **Built-in business tool (P1, SLA tracker)**: `zigmodu.ai.sla.SlaTracker` tracks monotonic deadlines on business items (tickets/approvals/refunds); `check()` (cron-driven) fires a `warn` when an item enters the deadline window and a `breach` once past it — events go to an `on_sla` callback (e.g. route into `ai.notify`) and the outbox (`ai.sla`) for audit/automation.
- **Built-in business tool (P1, KPI metric queries)**: `zigmodu.ai.kpi` registers app-owned named metrics (name → SQL → value column); the `kpi.query` skill lets an Agent answer business questions like "本周营收多少" by name only, and a programmatic `Kpi.query` returns the metric value for dashboards/automation.
- **Outbox read side (consumer)**: `zigmodu.outbox.OutboxConsumer` polls pending entries (optional topic filter), dispatches to a registered handler (`userdata` + `call`; topic/payload handed over as call-scoped copies) and advances the lifecycle pending → processing → delivered, with `retry_count++` + `error_message` on failure and failed/DLQ after retries are exhausted. Closes the loop for the AI business-tool outbox writebacks (`ai.approval` / `ai.recon` / `ai.notify` / `ai.risk` / `ai.alert`).
- **Built-in business tool (P1, notification hub)**: `zigmodu.ai.notify.NotificationHub` delivers a message to named channels — webhook (via `HttpClient`, HTTP 2xx counts as delivered), custom sink (email/IM/in-app callback with `userdata`+`call`) or durable outbox fallback (`ai.notify`) when no channel matches; delivery failures propagate, nothing is silently dropped. `registerNotifySkills` exposes the `notification.send` skill bridge (LLM supplies channel/title/body; channel targets stay app-registered with an optional allowlist).
- **Built-in business tool (P1, approval chain)**: `zigmodu.ai.approval.ApprovalFlow` runs a request through a configured multi-level chain — each step is decided by a `policy` callback (LLM/RBAC/rule engine) as approved / escalated / rejected, stopping on first rejection or human escalation; every step + a final event is written to the transactional outbox (`ai.approval`). `registerApprovalSkills` exposes the `approval.submit` skill bridge (LLM supplies subject/amount/request only; chain + policy stay app-registered; safe default policy escalates to a human).
- **Built-in business tools (P1, risk + recon)**: `zigmodu.ai.risk.RiskReview` scores a subject via configurable SQL rules → level (low/medium/high) → decision (approve/escalate/reject, `DecideFn` hook for LLM/policy) → outbox writeback (`ai.risk`); `zigmodu.ai.recon.ReconCheck` compares source/target SQL snapshots by key (missing / extra / mismatch), fires per-diff `on_diff`, writes a CLEAN/DRIFT summary to the outbox (`ai.recon`) and renders a Markdown diff report (`renderReport`).
- **Built-in business tool (P1, refund with compensation)**: `zigmodu.ai.refund.RefundFlow` validates → approves → executes a refund as a transactional outbox command → notifies; notify failure auto-emits the compensation command (`refund.reverse`), plus app-initiated `compensate()`.
- **Built-in business tool (P1, ticket triage)**: `zigmodu.ai.ticket.TicketFlow` loads customer/order context, classifies, drafts a reply, runs an approval/send gate (`on_send`) and writes the outcome to the outbox.
- **Built-in business tools (P0)**: `zigmodu.ai.reporter.BusinessReporter` renders configured SQL queries as a Markdown report (cron + outbox = scheduled delivery); `zigmodu.ai.alerts.BusinessAlert` runs SQL rules and alerts (callback + outbox writeback) on any violation row.
- **Workflow linear ↔ DAG hybrid**: steps can declare `depends_on`; when any step has dependencies the runner switches to dependency-aware parallel waves (`max_parallel` via `std.Io.Group`) with cycle detection (`error.CyclicDependency`). Budget, WAL persistence, retry and escalation apply in DAG mode too; reflection stays on the linear final step.
- **AI orchestration P2 (runtime control)**: `zigmodu.ai.AgentHandle` cooperative cancel / pause / step progress (checked at step boundaries; `canceled` flag + metric); `Agent.tracer` + `parent_span` create a run-level span via `DistributedTracer`.
- **AI orchestration P2 (context management)**: `zigmodu.ai.context` auto-compacts long conversations by token threshold — older messages are summarized (via `SummarizeFn`) or dropped, prepended as a system message, keeping a recent window; wired into `Agent` (`Agent.context`, checked each loop iteration).
- **AI orchestration P1 (hierarchical)**: `zigmodu.ai.hierarchy` planner → concurrent executor (`std.Io.Group`, `max_parallel` waves) → aggregation; partial failures surface as `.partial_failed`. Planner/executor are callbacks wireable to `Agent`/`Workflow`.
- **AI orchestration P1 (AgentTrigger)**: `zigmodu.ai.trigger` unifies cron / event / webhook sources into `fire(input)` + `registerCron`; optional transactional-outbox writeback of `{run_id, ok, message}` when an `OutboxPublisher` + SQL backend are configured.
- **AI orchestration P1 (WAL persistence + resume)**: `Workflow.wal` + `run_id` persist each step record to the WAL; `resumeRun(run_id)` replays completed steps and continues from the first unpersisted one (crash recovery / idempotent replay).
- **AI orchestration P1 (reflection + escalation)**: `Workflow` gains a reflection quality gate (`VerifyFn` + `max_reviews` — re-runs the final step until verified) and a human-escalation hook (`on_escalate` on step failure after retries / budget exhaustion / persistent verification failure).
- **AI orchestration (P0)**: `zigmodu.ai.workflow` linear multi-step runner (`.llm` / `.skill` / `.agent` steps, per-step records, retry, stop-on-failure, shared budget) and `zigmodu.ai.Budget` (hard token reservation per step; `.stop`/`.warn` modes; wired into `Agent` — `budget_exhausted` flag + metric). Plan + roadmap in `docs/AI_ORCHESTRATION.md`.
- **sockread performance pass**: `readSome`/`readFull` drop the redundant `poll` (std.Io sockets are blocking, so a bare `read` already waits — syscall count halves); new `sockread.Reader` buffered reader collapses many small reads into one larger syscall, adopted by `WsFramer` frame parsing and the Kafka transport; new `sockread.writevAll` sends header+body in a single `writev` (adopted by `WsFramer.writeFrame`, `ClusterConnection.send`, Kafka `writeFrame`). HttpClient keeps its timeout `waitForReadable`.
- **Built-in business AI skills (P0)**: `zigmodu.ai.business` registers `db.query` (read-only parameterized SELECT, row-capped, rejects literals/comments), `entity.lookup` / `entity.list` (app-registered entity whitelist, tenant-scoped when configured) via `SkillContext.backend_ptr`. Scheduler bridge completed with `list_jobs` / `cancel_job` (`ScheduleCtx` via `SkillContext.userdata`). New `ai.freeValue` defines result ownership (handlers dupe keys/strings; callers deep-free). Plan + roadmap in `docs/AI_SKILLS.md`.
- **Raw socket reads for all long-blocking io read paths**: new `core/sockread` helper (`readSome`/`readFull`/`writeFull`, `posix.poll` + `posix.read`/`write`) now backs the reads that wait for peer data — Redis responses (16 call sites), NATS reads (4), Kafka `readExact`, `DistributedEventBus` connection loop, `ClusterConnection.recv` (fixes partial-header reads) and `send` (loops on partial writes so frames are never split), and `HttpClient` `readResponse`/streaming body reads. Same class of fix as the fiber-mode WebSocket read: with the Threaded Io shared across threads, io-based socket reads can block forever even with data in the kernel buffer.
- **Fiber-mode WebSocket read fixed**: `WsFramer.readFrame` / `WebSocketClient` reads now use raw `posix.poll + posix.read` instead of `io.operate(net_read)`. With the Threaded Io shared across the accept thread, worker fibers and clients, io-based socket reads block forever even when data is in the kernel buffer (reproduced: `poll` readable + `MSG_PEEK` shows bytes, `readv` hangs) — so WS client→server frames, ping/close handling and `on_close` never fired. Writes were unaffected. Added an end-to-end regression test (handshake → masked frame → `on_message` → client close → `on_close`).
- **AI ⇄ cron 薄桥**: `Cron.Scheduler` fixed — the background loop now ticks periodically (`std.Io.sleep`), `addJob` is thread-safe (mutex + name copy) with public `tick()` for deterministic scheduling; `every` is a blocking one-shot helper. New `zigmodu.ai.registerScheduleSkills` exposes `list_schedulable_tasks` / `schedule_job` tools so an Agent can attach pre-registered named tasks to cron expressions (LLM never supplies code). `ScheduledTask.TaskScheduler` marked deprecated (never looped; placeholder next-run math) for removal in v1.0.
- **`HttpClient` pure-HTTP path fixed**: the buffered request writer was never flushed, so the request never reached the peer and `request()` deadlocked in a plain `main` (misdiagnosed earlier as an event-loop dependency). `executeRequest` now flushes after writing headers/body. `timeout_ms` (previously stored but unused) is now honored via `posix.poll` in `readResponse` (`error.Timeout` on a stalled peer). Added loopback end-to-end tests: live request round-trip and stalled-peer timeout.
- **`ctx.header()` is now case-insensitive** (RFC 9110): mixed-case lookups like `"User-Agent"` or `"X-Tenant-ID"` resolve to the lowercased parse-time keys. Fixes latent null-header bugs in `AccessLog`, `middleware/Validation`, and the tenant-mgmt example.
- **Postgres `?N` placeholder bug fixed**: `convertPlaceholders` now consumes sqlite-style `?N` digits so `?1` maps to `$1` (previously `$11`, SQLSTATE 42P18), numbers placeholders sequentially, and skips `?` inside quoted strings/identifiers and `--`/`/* */` comments. Added unit tests covering `?`, `?N`, mixed forms, `?12`, literals and comments.
- **Engineering-quality pass**: repo-wide `zig fmt` (src/tools/examples); fixed `examples/zent-modulith` struct-field syntax error; `Server` global-middleware errors on unmatched routes are now logged; silent I/O/DB error swallows converted to logged catches in redis / ClusterMembership / RaftElection / Orm / WAL / Nats / EventBus / HealthEndpoint / ApplicationView / WorkerPool.
- **`check-production` gate extended** to hot-path modules (redis, Nats, ClusterMembership, DistributedEventBus, RaftElection, WAL, Orm) — previously only Server/sqlx/security were scanned.
- **`DistributedEventBus` connection read loop fixed** for the real `std.Io` (threaded) reader: `readSliceShort` returns a byte count, not a slice; the loop previously failed to compile when a real connection path was instantiated (surfaced by `examples/distributed`).
- **`HttpClient.ConnectionPool` tests now use a real loopback listener** instead of always skipping on `ConnectionRefused` to port 9999.
- **Network-dependent tests skip gracefully** in sandboxed/restricted environments via `src/test/NetworkProbe.zig` (raw-syscall probe) instead of crashing the whole test binary with `errnoBug` on `EPERM`.
- **CI hardening**: `ZIG_VERSION` pinned to `0.17.0-dev.1422+e863bf3be`; `zig fmt --check` now covers `src tools examples`; new `examples` job builds all nine examples (incl. `zent-modulith` with a sibling `zent` checkout); `test-live-services` adds a real Kafka broker (`apache/kafka:3.7.2` KRaft) via `KAFKA_BOOTSTRAP`.
- **Module test helpers are public API**: `zigmodu.ModuleTestContext` and `zigmodu.createMockModule` exported from `root.zig` (consistent with `IntegrationTest`/`Benchmark`/`ContractTest`); `examples/testing` updated off the deprecated `zigmodu.extensions` namespace.
- **Repo hygiene**: tracked `wal_test`/`wal_test2` artifacts removed; `.gitignore` covers `wal_test*` and `.codegraph/`.

### Added
- **WebSocket binary frames**: `on_message` receives text (0x1) **and** binary (0x2) with `WsFrameKind`; fiber + io_uring paths; `WsFramer.writeBinary` / `writeData`. Unblocks OpenIM-style protobuf over WS. **Breaking**: `WsMessageFn` gains `kind` parameter.
- **Selective SQL driver linking**: `-Ddb=all|sqlite|postgres|mysql` (comma-list) via `examples/_shared/db_link.zig`; `build_options.enable_*`; disabled drivers use C stubs (no link) and `Client.connect` returns `error.DriverNotEnabled` (also in `ZigModuError`, HTTP 400). Package consumers: `b.dependency("zigmodu", .{ .db = "sqlite" })`. Scaffold/`--from-db` maps DSN → `.db=`. Framework `zig build test` keeps default `all`; CI integration builds use `-Ddb=sqlite`. Guide: [`docs/SQLX_DRIVERS.md`](docs/SQLX_DRIVERS.md).

### Added
- **zent support — shared helper for examples**: `examples/_shared/zent_helpers.zig` provides `StoreEnv(Driver, Infos).open / inMemory / openWith` (RAII wrapper that replaces the open-driver + migrate + make-client dance) and `TestEnv(schemas).init / reset / deinit` (per-test in-memory SQLite with fresh migrations). Both `examples/zent-modulith/` and `examples/shopdemo-zent/` now use it; `examples/_shared/build.zig` runs the helper's own tests.
- **zent docs extended**: `docs/ZENT.md` adds `§6.1 Testing` (TestEnv pattern), `§6.2 Production: ConnPool` (production driver wrapping), `§6.3 Observability` (zent `sql_logger` → ZigModu logger adapter), and `§6.4 Transactions` (beginTx + savepoint). Shared helper callout at the top.
- **`examples/shopdemo-zent` runnable**: parallel of `examples/shopdemo/` using `zent` (ent-style schema-as-code ORM) instead of `zigmodu.data.sqlx`. Single `order` module with `Order` + `OrderItem` zent Schemas, `OrderStore` persistence, `OrderService` validation, and `OrderApi` exposing `POST/GET /api/v1/orders` plus `POST /api/v1/orders/{order_no}/items`. Demonstrates `docs/ZENT.md`'s orthogonal data-stack rule: each module picks one driver and does not mix or share transactions.
- **Completeness Phase 3 — distributed event bus wiring**: `DistributedEventBus` now actually routes through `Partitioner.route(topic)`, captures send failures in `DLQ` after `max_send_failures` threshold, drains DLQ via a retry fiber, and exposes `connectToNode` / `nodeId` / `clusterSize` for membership integration. `WAL.readFrom` is implemented so `replayFromWal` and `restoreFromWal` actually recover uncommitted entries. `ClusterMembership` keeps the partitioner ring in sync on join / leave / failure.
- **SQLx MySQL binary protocol hardening**: `mysqlFetchStringColumn` re-reads oversized values via `mysql_stmt_fetch_column` instead of silently truncating; `mysqlParseDecimal` / `mysqlParseDateTime` / `mysqlParseJson` validate input strictly (negative TIME allowed, fractional seconds `.[0-9]{1,6}`, JSON via `std.json.parseFromSlice`).
- **`examples/shopdemo` runnable**: `build.zig` / `build.zig.zon` / `src/main.zig` / `src/db/*` added; the single `order` module from `generated-sample/` is migrated with API compatibility fixes; `zig build run` starts the app and `GET /api/v1/orders` returns 200.
- **WorkerPool / EventBus observability**: `WorkerPool.WorkerPoolStats.toPrometheusFormat` renders pool stats as Prometheus text; `TypedEventBus` tracks `published_total` and `dropped_async_total` atomically with `publishedCount` / `droppedAsyncCount` getters.
- **Modulith QPS Phase 2 — async EventBus + WorkerPools**: `core.WorkerPool` (bounded queue, graceful stop, error isolation), `TypedEventBus.subscribeAsync` / `ThreadSafeEventBus.subscribeAsync`, `api.Module.RuntimeOptions.worker_count`, and per-module `WorkerPool` integration in `core.ModuleRuntime`. Includes cross-module pilot test and `max_worker_count = 128` guard (`error.ConfigurationError` for 0 or overflow).
- **Modulith QPS Phase 1 — per-module resource isolation**: `api.Module.RuntimeOptions`, `core.ModuleRuntime` (bulkhead + rate limiter + circuit breaker), `core.ModuleRegistry`, and `Application.getModuleRuntime()`. Thread-safe admission via `std.Io.Mutex`, overflow-safe quota validation, and full backward compatibility for modules without runtime options.
- **SQLx connection pool lifecycle**: per-connection `created_at`/`idle_since` timestamps, max-lifetime / max-idle-time eviction, FIFO waiter fairness, and `PoolMetrics` (acquired/released/created/closed/stale-evicted totals, wait time, max active/idle).
- **SQLx streaming cursor**: `Client.queryCursorEx(sql, args, .{ .mode = .streaming })` with driver-native streaming for MySQL (`mysql_use_result`) and PostgreSQL (`PQsendQueryParams` + `PQsetSingleRowMode`). SQLite falls back to buffered mode.
- **SQLx batch protocols**: `Client.batchInsertEx(table, columns, rows, .{ .mode = .protocol })` uses MySQL prepared-statement multi-execute and PostgreSQL `COPY ... FROM STDIN` (CSV). Falls back to multi-row `INSERT` SQL on failure or SQLite.

### Changed
- **SecretsManager / Vault**: Implemented HashiCorp KV v2 HTTP (`loadFromVault` + `applyVaultKvJson`). Plain HTTP + `X-Vault-Token`; `https://` → `VaultTlsNotSupported`. Live smoke: `VAULT_ADDR` + `VAULT_TOKEN`.
- **gRPC**: Removed EXPERIMENTAL. Unary production path — `GrpcFrame`, `GrpcServiceRegistry.invoke` / `handleHttpUnary`, `GrpcClient.bindLocal` + `initWithIo` HTTP/1.1 `application/grpc`. Streaming still returns `UNIMPLEMENTED`.
- **Kafka**: Hardened wire layer — Produce response error-code check, RecordBatch value parse, Fetch value scan; added roundtrip unit tests. Live smoke still via `KAFKA_BOOTSTRAP` / `ROBUSTMQ_URL`.
- **SQLx**: Removed broken `withRows` helper from `data.zig` re-export (no in-tree callers; called `client.queryRows` without the `T` type parameter).

### Fixed
- **SSE Server lifecycle**: `http.sse` / `markSseResponse` sets `ctx.streaming` so Server does not double-`writeResponse` after the handler; `lastEventId(ctx)`; multiline `data:` splitting; `sendRetry` write-buffer alias fix.

### Added
- **zigmodu.ai Agent P0/P1**: `AiProvider.chatWith` + `tool_calls` parse; `SkillRegistry.toOpenAiFunctionsAlloc` / `dispatchAllowed` / `validateArgs`; first-class `ai.Agent` ReAct loop + `AgentHooks`/`AgentMetrics`; `chatStream` buffered shim; `MemoryStore` composite tenant/user keys + `dumpJson`/`loadJson`.
- **zigmodu.ai skill timeout skeleton**: `Tool.timeout_ms`, `SkillContext.deadline_ms` / `expired` / `checkDeadline`, `dispatchWith` → `error.ToolTimeout` (cooperative; not preemptive).
- **HttpClient.requestStream + AiProvider SSE chatStream**: chunked/content-length/EOF body streaming; OpenAI `data:` delta parse with buffered fallback.
- **MemoryStore file persistence + Agent tool timeout**: `saveToFile`/`loadFromFile`; `Agent.tool_timeout_ms` via `dispatchWith`.
- **HttpClient request wire**: auto `Host` + `Content-Length`; path+query; `https://` → `TlsNotSupported` (plain HTTP only, same posture as Vault/OTLP).
- **AI observability / RAG hooks**: `AgentAuditLog`; `Retriever` + `KeywordRetriever`; `Metrics.toPrometheusFormat` for provider and agent.
- **HttpClient HTTPS**: `https://` via `std.http.Client` (system CA, TLS 1.3); HTTPS `requestStream` incremental body read loop; finer transport errors (`TlsHandshakeFailed` / `DnsFailed` / `Timeout`).
- **Agent HITL + RAG wire-up**: `hooks.on_tool_request` / `ToolApproval`; optional `retriever` merges context into system prompt; scaffold `--with-agent` uses core `zigmodu.ai.Agent` + `AiProvider`.
- **AI stream tool_calls + quota**: `chatStream` accumulates streamed `delta.tool_calls`; `TokenQuota` per-tenant skeleton; scaffold `--with-aichat` uses `*AiProvider` + `chatStream` + shared quota; Agent scaffold persists `ai_agent_run`.
- **AiProvider HTTP status mapping**: `AuthError` / `RateLimited` / `UpstreamError` / transport errors.
## [0.14.17] - 2026-07-31

### Added
- **ComptimeRouter + catalog JWT/RBAC**: modules declare `pub const routes` + `mountAll`; `jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.rbac)`; `CatalogPermLoadInput{ sub, aud, roles }` for custom permission loaders.
- **HTTP ergonomics stack**: typed extractors, ProblemDetails/`respondErr`, scope middleware, Testkit, HTTP/resilience profiles, SSE (`http.sse` / `sse_routes`), OpenAPI param merge, outbox/idempotency barrels.
- **HTTP/2 / gRPC / Kafka depth**: H2 stream states + pump, PRIORITY scheduling, h2c Upgrade, WINDOW_UPDATE/SETTINGS, `Http2Tls` ALPN sidecar; ConnWriter write coalesce and GOAWAY/RST isolation; Kafka consumer-group assignors (incl. cooperative_sticky) + `acknowledgeRevocation`.
- **OTLP/HTTP exporter**: `OtlpExporter.exportSpans` POSTs JSON over plain `http://` with retries (`https://` → `OtlpTlsNotSupported`).

### Changed
- **Legacy JWT middleware**: `rbacJwtMiddleware*` / `jwtAuth*` write **`auth_info` only** (safe with ComptimeRouter `user_data` State); new apps prefer catalog Path A.
- **x402 payment verify**: fail-closed by default; inject `PaymentVerifier` / `verifyPaymentAllowAll` only for explicit dev paths.
- **Docs / AI guides**: `AGENTS.md` canonical agent entry (doc map + DO/DON'T); `CLAUDE.md` / `AI_METHODOLOGY` / `BEST_PRACTICES` / `ROUTE_TABLE` §7 aligned to Path A + ComptimeRouter.

### Fixed
- **OpenAPI JSON strings**: escape quotes/backslashes/control chars in title/version/description/summary via `emitJsonStr`.

## [0.14.16] - 2026-07-24

### Changed
- **SQLx circuit breaker Io handle**: `sqlx/breaker.CircuitBreaker` no longer stores `io`. `allow` / `recordSuccess` / `recordFailure` take `io: std.Io` from the caller (`Client` passes `self.io`), so futex waits always use the live Io handle instead of a copy captured at `Client.init`.

## [0.14.15] - 2026-07-24

### Fixed
- **SQLx `Client.open` pool self-pointer dangling after by-value return**: `ensurePool` stored `ConnPool.client = &local` then `return client` moved the struct, leaving `pool.client` pointing at the dead temporary (SIGSEGV at low addresses like `0x70` on next pool use). `open` no longer creates the pool; call `warmPool()` on the final `*Client` for idle warmup. `ensurePool` always rebinds `pool.client = self`.

## [0.14.14] - 2026-07-24

### Fixed
- **SQLx `Client.ensureBreaker` race / segfault**: `cb` was a lazily initialized `?CircuitBreaker`. Concurrent first-touch from worker fibers could tear the optional write (null/`Io.vtable` → segfault on next `allow`/`record*`, often at low addresses like `0x1a0`). `cb` is now a non-optional `CircuitBreaker` eagerly created in `Client.init`; `ensureBreaker` removed.

## [0.14.13] - 2026-07-24

### Fixed
- **SQLx PostgreSQL SafeAllocator panic (alloc=N+1 / free=N)**: `PostgresConn.stmt_cache` stored `allocZ` (`[:0]u8`) names as `[]const u8`, so LRU eviction / close freed without the sentinel. Cache values are now `CachedStmt([:0]u8)`. Same coerce bug fixed in `queryCursorFn` (`if (args.len==0) slice else [:0]`). `bufPrintZ` reserves the last byte for `\0`. `pgDecodeNumeric` no longer writes through a fixed `[256]u8` stack buffer (heap `ArrayList` + safe `dscale`/`lead_zeros` math).

## [0.8.2] - 2026-05-10

### Fixed
- **SecretsManager**: Inverted priority comparator (`<=` → `>=`) so env > file > vault > default works correctly.
- **SecretsManager**: Double-free in `setWithPriority` when replacing entries — old key freed before `HashMap.remove`.
- **ContractTest**: Double-free in `verifyContract` status check — `allocPrint` strings freed by both local `defer` and `deinit`.
- **LoadShedder**: `now_ms = 0` replaced with `Time.monotonicNowMilliseconds()` — rolling window now advances correctly.
- **Migration parse test**: Isolated with `ArenaAllocator` to prevent allocator-state corruption from prior tests.
- **Version sync**: All version strings unified to v0.8.x across `build.zig.zon`, `main.zig`, and `CHANGELOG.md`.

### Added
- **Graceful shutdown**: `Server.in_flight` request counter + `withGracefulDrain()` wired into `Application.run()` (30s drain timeout, SIGINT/SIGTERM handlers).
- **Prometheus /metrics**: `PrometheusMetrics.registerMetricsRoute()` — one-line `/metrics` in Prometheus text format.
- **Health check context**: `HealthCheck.check_fn` now takes `?*anyopaque` context; `databaseCheck`, `redisCheck`, `diskSpaceCheck` work with real connections.
- **Config validation**: `ExternalizedConfig.validateRequired()` returns missing keys for clear startup errors.
- **ThreadSafeEventBus**: `ThreadSafeEventBus(T)` wraps `TypedEventBus` with `std.Thread.Mutex`.
- **E2E tests**: Server middleware chain + error path, Application lifecycle smoke test, in-flight counter tracking.
- **API Migration Guide**: `docs/API-MIGRATION.md` — Simplified.zig → Application migration path.

### Changed
- **root.zig**: Reorganized from flat 297-line list into 14 named sections with clear category headers.
- **Emoji logs**: Removed all emoji prefixes from production log messages in Application, Lifecycle, ModuleValidator, docs.
- **README**: Updated test count (338 passed, 0 failed), honest production readiness score (84/100), experimental markers on gRPC/Cluster/DistTx/Plugin/WebMonitor/HotReload.
- **CI**: Removed broken `--test-filter` flags from lint job (unsupported by build.zig).

## [0.8.0] - 2026-05-08

### Added

#### Production Hardening (Phase 7)
- **Database Migrations** (`src/migration/Migration.zig`) — Flyway/Liquibase-style versioned migrations with SHA256 checksums, rollback support, status tracking (pending/applied/failed), DDL generation, and filename parsing (`V{timestamp}__{description}.sql`). 10 tests.
- **Secrets Manager** (`src/secrets/SecretsManager.zig`) — Multi-source secrets with priority resolution (env > file > vault > default). Supports K8s/Docker secrets, Vault placeholder, JSON/env content loading, getInt/getBool/getOrDefault/listKeys/exportAsEnv. 10 tests.
- **Docker Support** (`Dockerfile` + `docker-compose.yml`) — Multi-stage build (zig:0.16.0 → alpine:3.21), non-root user, health check. Compose stack includes PostgreSQL 17, Redis 7, Vault 1.18 (profile), Jaeger 1.65 (profile).
- **Timestamp Audit** — Verified all 16 production sites use `Time.monotonicNowSeconds()`. 9 remaining `timestamp=0` in test-only code.

#### Network Verification & Integration (Phase 8)
- **Idempotency Middleware** (`src/http/Idempotency.zig`) — `IdempotencyKey` header-based request deduplication with TTL store, automatic eviction, purge-expired. 5 tests.
- **Module Interaction Verifier** (`src/core/ModuleInteractionVerifier.zig`) — Spring Modulith `verify()`-style architecture validation. Checks circular dependencies, self-dependency, max dependencies, generates ASCII violation reports. 6 tests.
- **OpenAPI Generator** (`src/http/OpenApi.zig`) — Generates OpenAPI 3.0/3.1 JSON from route metadata. Supports endpoints, tags, path/query/header params, response schemas. 4 tests.

#### Modulith Deep Features (Phase 9)
- **gRPC Transport** (`src/core/GrpcTransport.zig`) — Full gRPC service registry with method registration, 16 standard status codes with HTTP mapping, proto file parser (service/method extraction), client stub with endpoint management. 6 tests.
- **Kafka Connector** (`src/core/KafkaConnector.zig`) — Producer with send/sendBatch/flush/close + per-topic statistics, Consumer with subscribe/unsubscribe/getSubscriptions, EventBridge for Kafka ↔ DistributedEventBus integration. Configurable acks, compression, auto_offset_reset. 7 tests.
- **Saga Orchestrator** (`src/core/SagaOrchestrator.zig`) — Automatic compensation with reverse-order rollback on step failure. Saga registration, step logging (started/completed/failed/compensated), instance tracking, active instance listing. 5 tests.
- **Contract Testing** (`src/test/ContractTest.zig`) — Consumer-Driven Contract (Pact-style) verification. Validates HTTP status, response body contains, and response headers against defined contracts. Generates ASCII pass/fail reports. 6 tests.
- **CI/CD Pipeline** (`.github/workflows/ci.yml`) — GitHub Actions workflow with matrix build (ubuntu + macOS), caching, fmt check, full test suite, architecture validation, security scan, benchmarks (ReleaseFast), multi-platform Docker build (amd64/arm64), GitHub Release with artifacts.

### Changed
- **`root.zig`** — Added 30+ new exports for Phases 7-9 modules in ADVANCED API section
- **`tests.zig`** — Added compilation gates for all new modules
- **`AGENTS.md`** — Updated with all new module conventions, middleware patterns, migration/secrets/saga/Kafka/gRPC usage examples
- **`README.md`** — Comprehensive update with new features, project structure, Docker quick start
- **`docs/API.md`** — Added API references for Migration, Secrets, Idempotency, OpenAPI, gRPC, Kafka, Saga, ContractTest
- **`docs/COMPLETENESS_REPORT.md`** — Updated scores: 93/100 production readiness
- **`docs/EVALUATION_REPORT.md`** — Final evaluation with Phase 7-9 coverage

### Test Results
- **282 passed**, 5 skipped, 2 failed (pre-existing)
- +53 new tests across Phases 7-9
- All timestamp-related bugs resolved; no `timestamp=0` in production code

## [0.7.0] - 2026-04-23

### ⚠️ Breaking Changes

- **`ModuleInfo.init()`** now takes 3 arguments `(name, desc, deps)` instead of 4. The `ptr` field is now `?*anyopaque` (nullable, default `null`). Update all call sites.
- **`ModuleInfo.init_fn` / `deinit_fn`** signatures changed from `fn(*anyopaque)` to `fn(?*anyopaque)`.

### Added

- **`core/Time.zig`** — Centralized monotonic time utility using `clock_gettime(CLOCK_MONOTONIC)`. Replaces all hardcoded `const now = 0` throughout the codebase (16 occurrences across 10 files).
- **`root.zig`** — Exports `time` module as `zigmodu.time`.
- **3 new tests** for Time.zig (monotonicity, positive values).

### Fixed

- 🔴 **Timestamp system**: All time-dependent subsystems now use real monotonic time:
  - `CircuitBreaker` — OPEN→HALF_OPEN timeout transition now works
  - `RateLimiter` — Token bucket refill now works with real elapsed time
  - `SlidingWindowRateLimiter` — Window cleanup now works
  - `CacheManager` — TTL expiration now works
  - `DistributedTracer` — Span durations now have real values
  - `TaskScheduler` / `Cron` — Scheduling now uses real time
  - `HttpClient.Connection.isAlive()` — Idle timeout detection now works
  - `ClusterMembership` — Health check timeout detection now works
  - `sqlx/breaker.zig` — Circuit breaker now works

- 🔴 **`ModuleInfo.ptr` UB**: Eliminated `undefined` initialization. Ptr is now nullable `?*anyopaque` with default `null`. Tests no longer trigger undefined behavior.

- 🔴 **Version inconsistency**: Unified version to `0.7.0` across `build.zig.zon`, `main.zig`, `CHANGELOG.md`, and `AGENTS.md`.

- 🔴 **build.zig test paths**: Replaced hardcoded macOS Homebrew paths with dynamic detection via `detectPqPaths()`/`detectMysqlPaths()`. Tests now work on Linux/CI.

- **`ApplicationModules.register()`**: Now invalidates cached `sorted_order` to prevent stale topological sort after module set changes.
