# Deterministic Runtime 设计稿（A-6 残留项 · 单独立项）

> 状态：**设计稿，未实施**。对应 `docs/dev/v1.0-readiness-v0.35.md` A-6 行「deterministic
> runtime（无 `DeterministicMode`，`recorder.zig:88-90` 自述无进程级确定性）」。
> 本文先定级、定界、定契约，再分阶段落地；任何一阶段都可独立验收、独立回滚。

## 0. 一句话定义

> **同一份输入 + 同一个 seed + 同一拓扑，必产生同一条事件序列，进而同一份输出。**

确定性是「配置出来的执行模式」，**不是第二套 runtime**。默认模式（多线程、真实钟、
系统熵）一字不改；det 模式是把三个非确定源（时钟、随机、调度交错）换成受控源后的
同一个 Runtime。

## 1. 价值排序（为什么是它，为什么是现在）

| 场景 | 没有 det runtime | 有了之后 |
|------|-----------------|---------|
| Quant backtest | 回放只能看事件流，不能重跑决策 | 同一份市场日志 → 同一串信号/订单，可断言 |
| 线上事故复现 | `ReplayFromLog` 只重放投递记录 | 按 seq 重放到出事窗口，state 逐步可检 |
| 并发回归测试 | 交错靠运气，flake 靠重跑 | seed 即测试用例：失败 seed 可存档复现 |
| AI Agent 调试 | 工具调用序列不可重放 | proposal/policy 决策链确定性回放 |

分级动机：全进程确定性（含 socket/DB 副作用）是 rr 式工程，**投入产出不成比例**；
而「runtime 交付链路的确定性」资产已经攒了八成（见 §2），缺的只是收口。

## 2. 现状盘点（已验证的代码事实）

**已有（直接构成底座）**

- `Clock` union（`src/runtime/clock.zig:21`）：`.real` / `.manual` 两支，`Manual.advance/set`
  是 replay 驱动的时间推进柄。
- `Sequencer`（`src/runtime/sequencer.zig:18`）：单调 `next/nextBatch/advanceTo`，
  recorder 的每条记录已带全局单调 seq —— **全局序的骨架已经在日志里**。
- `EventRecorder`（`src/runtime/recorder.zig`，4.1K 行）：单调 seq + manual clock +
  track 过滤 + bounded + `error.Full`；`delivery_log.zig` 的 `ZDL1` 段 WAL +
  `ReplayFromLog` 已落地（§13.10，缺 CLI/retention/compaction）。
- `TimerWheel`：单写者状态机，跨线程 arm/cancel 走同一个 FIFO 命令环 —— 定时器
  命令序本身是确定的。
- `Mailbox` 有界 FIFO、scheduler ready ring FIFO + 每 worker 单 ready token ——
  每个 worker 的*输入序列*确定；不确定的只有*跨 worker 的交错*。

**缺口（recorder.zig:88-90 自述 + 实测）**

1. **无进程级确定性**：`spawn`/`init` 副作用、socket、wall clock、drop-on-full
   投递不在回放内。
2. **直读真实时间的代码在回放外**：`core/Time.zig` 直读经审计（第 137 批）
   全部是测试辅助与两个合法本体（`clock.zig` real 分支、`precision_timer.zig`
   真实钟原语），runtime 域 production 已天然走注入 Clock —— 缺口从「收口」
   收窄为「防回退」，已由 `check-production.sh` 的 `dettime` 扫描把守。
   core 域直读仍多（`ClusterMembership` 9、`KafkaConnector` 8 …），一期不管。
3. **随机源未接管**：runtime 域内无随机源（grep 零命中，干净）；core 域
   `RaftElection.zig:1413` 用 time-seeded `DefaultPrng`（集群域，一期不管）、
   `LoadBalancer` 已是注入 seed 形态（`:57`）。**runtime 域是张白纸，现在接管
   成本最低。**
4. **调度交错不确定**：多线程 pool 下跨 worker 的 interleaving 由宿主调度决定 ——
   这是 det 模式要解决的核心，也是唯一能「换掉」的源。

## 3. 确定性分级（定界就是定级）

| 级 | 名称 | 内容 | 状态 |
|----|------|------|------|
| D 级 | Delivery 确定性 | 已进邮箱的每条消息按 seq 重放（日志里有什么放什么） | **已有**（`ReplayFromLog`） |
| S 级 | 单线程全序执行 | det 执行器：单调度线程 + Manual Clock + seeded RNG，全事件序可复现 | **本设计的目标** |
| P 级 | 进程级确定性 | socket/DB/文件/spawn 副作用全部录制回放 | **明确不做**（rr 式工程，见 §8） |

S 级成立的关键观察：**把多线程交错换成「单线程 + 全序事件源」，交错不确定性
就消失了** —— 不需要让多线程变确定，只需要 det 模式不用多线程。性能无关紧要：
det 模式的客户是 backtest / 事故复现 / 测试，不是生产路径。

## 4. S 级设计

### 4.1 配置面（不是新 runtime）

```zig
const rt = try Runtime.init(allocator, io, .{
    .deterministic = .{ .seed = 42 },          // 打开即受控
    .clock = .manual,                           // Manual Clock 注入
    .scheduler = .{ .pool_threads = 1 },        // 强制单调度线程（见下）
});
```

`RuntimeOptions.deterministic: ?struct{ seed: u64 }`（null = 默认生产模式）。
打开时框架**强制并校验**以下不变式，违反即 `error.DeterministicViolation`：

- **D1 时钟**：runtime 域内时间读只能走注入 `Clock`。`Manual` 由 replay driver /
  测试推进；`nowMs` 永远单调（Manual.set 回退 = 违规）。
- **D2 随机**：唯一入口 `Runtime.rng()`（`DefaultPrng.init(seed)`）。runtime 域
  `grep DefaultPrng.init(` 白名单化（现状零命中，门禁从第一天就是绿的）。
- **D3 调度**：`pool_threads` 必须 = 1；`.dedicated` 拒收（它没有 pool 交错但也
  没有全序保证，det 模式里就是第二个调度域）；`.blocking` 池拒收（同理）。
  单线程 pool 下，ready ring FIFO + 每 worker 单 token ⇒ **调度序 = 入环序**，
  而入环序由事件 seq 决定 —— 全序闭环。
- **D4 定时器**：命令环 FIFO 已确定；**同 deadline 触发序**定为契约「按 arm 命令
  到达序」—— 第 138 批审计发现槽内是 prepend（**LIFO**，与直觉相反且测试名实
  不符），已改为 append + 尾指针的 FIFO（`timer_wheel.zig`，`pushNode`/`unlink`/
  `expireSlot`/`sweepDue`/`drainAll`/`alignNow` 六处尾簿记），同 deadline 三连
  arm 与 sweepDue 部分到期两条顺序测试锁定。
- **D5 邮箱**：det 模式下 mailbox 满 = **违规而非 drop**（`error.Full` 冒泡给
  调用方；drop-on-full 的不确定本就在 D 级回放外，S 级直接禁止）。容量规划是
  调用方契约，文档给公式（生产者速率 × 最坏调度延迟）。
- **D6 副作用**：socket/DB/文件由应用层接口注入；框架不录制（P 级不做）。
  文档写明：det 模式下副作用代码必须由调用方 mock，框架只保证交付链路确定。

### 4.2 回放驱动（Replay driver）

```zig
var driver = try replay.Driver.init(allocator, &rt, log_reader);
try driver.runUntilSeq(120_000);   // 或 runUntilClock(t) / runToEnd()
```

驱动循环：从 `ZDL1` 段读出下一条记录 → Manual Clock 推进到记录时间 → 按记录的
track/payload 向目标 worker 邮箱投递 → 单线程 pool 自然 drain（含其引发的级联
send/timer arm，全部走同一受控链路）→ 下一条。**级联事件不进日志也能复现**：
它们是输入的确定性函数（同输入 + 同 seed + 同钟 ⇒ 同级联）。

### 4.3 验收（可证明，不是口号）

1. **同种子 N 跑一致**：同一输入日志 + seed=42 跑 10 次，recorder 摘要
   （seq 序列 + 逐条 payload xxhash）**字节级相同**。进 `runtime-stress` 不变式家族。
2. **异种子分叉合法**：seed=43 允许不同，但同 seed=43 的两次必须相同（防
   「把随机源钉死成常量」的假确定性）。
3. **变异测试**：① 把某处 Clock 换成 `Time.monotonicNowMilliseconds()` 直读 →
   验收 1 必须红；② 把 `Runtime.rng()` 换成 time-seeded → 红；③ 同 deadline
   定时器乱序 → 红。三条变异先行，验收后行。
4. **性能无回退**：默认模式（det = null）热路径零新增分支 —— det 检查全部
   沉在 `init`/`spawn` 边界，alloc contract 既有读数不动。

## 5. 分阶段落地（每阶段独立可发）

| 期 | 内容 | 验收 |
|----|------|------|
| **A** ✅（第 137 批） | ~~D1/D2 收敛~~ → **审计 + 门禁**。审计结论：runtime 域 production 直读只有两处合法本体（`clock.zig` real 分支、`precision_timer.zig` 真实钟原语）；其余直读全是测试辅助（`waitUntil`/`awaitTrackLen`/`PoolSettled`/`runShape`/`LatencyLog`，真实预算防挂，本就在回放外）。D2 的 RNG 门禁**树级已在**（entropy 扫描禁 `DefaultPrng.init` 全家，`src/runtime` 零命中）；`Runtime.rng()` API **推迟到 B 期**（零消费者，且 seed 来源要等 det 配置面）。落地物：`zig-scan.awk` 新 `dettime` mode + `check-production.sh` 扫描块（12 条逐行豁免锚，覆盖全部合法直读；两条变异实测被抓：production 直读、豁免行改一字） | 门禁绿 + 变异双红 ✅ |
| **B** ✅（第 138 批） | det 配置面：`RuntimeOptions.deterministic` ✅、`Runtime.rng()` ✅（det seed / 非 det 系统熵 + 多源回落）、单线程强制 ✅（`pool_threads != 1` 拒）、dedicated/blocking 拒收 ✅（池查找**之前**拒，错误点名模式）、batch 强制 1 ✅、同 deadline 定时器序 ✅（**审计发现是 LIFO**（prepend）—— 改为 FIFO（arm 序）+ 尾指针，旧 pin 测试名实不符（名「insertion order」断言 LIFO）一并纠正；全模式生效，不只 det） | §4.3-1/2/4 中 D2/D3/D4 部分 ✅（三条聚焦测试 + sweepDue 部分到期 FIFO 测试）；mailbox 满违规化 = 既有 `error.Full` 语义，无新分叉 |
| **C** ✅（第 139 批） | replay driver（`runtime/replay_driver.zig` 的 `replay.Driver`）+ `ZDL1` 的 seek/limit/filter CLI（§13.10 自列缺口顺带收）。落地物：① `ReplayFromLog` 新增 reproduce 模式（`reproduceTimers()`：`.timer` 记录不投递只拨钟/锚链/计数，洞纪律一字不变；`isFullyBound` 跳过 `.timer`——纯定时器轨无需绑定）；② `replay.Driver`：`init` 三拒（非 det → `NotDeterministic`、无池 → `NoPool`、ticker 在跑 → `TickerRunning`），迭代循环 = `loader.step()`（拨钟+投 `.message`）→ `rt.tick()`（drain 命令环 + wheel 触发到期定时器 = 复现 `.timer`）→ `settle()`（等 `poolStats().idle_waits` 首次增量——driver 是唯一外部生产者、park 只发生在 `turn()` 空转后、幻影 token 下个 turn 被排干，故首次 park ⟹ 级联淬火；30 万迭代 × 200 µs 计数防 wedge，**不读钟**满足 D1 门禁）；三种 run 界（`runToEnd` / `runUntilSeq`（含）/ `runUntilClock`（含)），拒绝后 cursor 不动可续跑；③ `replay-inspect --limit N` / `--track NAME`（可重复、并集；滤掉的计 `skipped_unselected`/`skipped_after` 永不隐身；log 里不存在的 track 名拒 `UnknownTrack`——typo 不是空窗；§13.10 D7 的 CLI 项 seek（from/to 既有）+ limit + filter 三半收齐）。**录制纪律落定**：S 级录制只录**输入边界 worker**（级联消息与定时器一样由回放端确定性复现，重复投递即双投递；`.timer` 记录是证据不是输入） | §4.3-1/2/3 全量 ✅：同 seed=42 十跑 digest 字节级相同、A 录制端与 B 回放端输入轨逐条一致、级联流与本地同 seed Prng 独立预算的期望流一致（不信录制端）、12 个 `.timer` 全由 wheel 复现（`delivered=12, timer_steps=12`）、seed=43 双跑一致且 ≠ 42；**三变异实测红**：manual 分支改直读真实钟 → `expected 24, found 12`；`seedPrng` 无视 det seed → digest idx 573 处分叉；TimerWheel `pushNode` 改回 LIFO → D4 测试 `expected 100, found 200`；CLI 8/8 绿（6 旧 + track/limit 2 新） |
| **D** | 真实验证：`examples/quant-runtime`（或 zalpha 场景）同日志双跑 —— Live 录制 → det 回放 → 信号序列逐字节比对 | 事故级演示入 CHANGELOG |

不做 B 之前 A 也有独立价值（收口直读 = 回放覆盖面扩大）；不做 C 之前 B 已能
服务内存 replay（recorder 现有能力）。

## 6. 风险与对策

- **级联序依赖 batch 语义**：`SchedulerConfig.batch` 是公平性上界（RUNTIME.md
  §12.x），单线程下 batch 影响「一次 drain 多少」→ 影响级联事件在日志里的相对
  位置。对策：det 模式**固定 batch = 1**（最保守全序），文档写明。
- **supervision 重启序**：重启由 error budget 触发，本身是消息流的确定性函数，
  但 restart 的 *backing-off 计时* 若走真实钟即漏。归 D1 审计范围。
- **HotBus fan-out 顺序**：订阅者槽位序 = comptime 声明序（确定），但 drop 策略
  与订阅者消费速度耦合 —— det 模式 HotBus 订阅者必须同线程 drain（单线程天然
  满足），文档约束。
- **「det 模式性能差」误用**：文档第一行写明 det 是 backtest/复现/测试模式，
  生产禁止；`init` 时对 det + `pool_threads > 1` 直接编译期外的运行时拒收。

## 7. 与既有路线的咬合

- A-6 行（readiness 文档）：本设计落地后该行从「仍开」移「已关」，残留只剩
  公平性加权与 Distributed Worker 统一。
- §13.10（recorder/delivery_log）：C 期顺带收它的 CLI/seek/filter 自列缺口；
  retention/compaction 仍不归本文。
- Quant 路线（`docs/dev/alpha-engine-spec.md`）：D 期是它的 Research→Backtest→
  Live 统一 Runtime 愿景的底座实验。

## 8. 明确不做（防范围蔓延）

1. **P 级进程确定性**：socket/DB/文件/spawn 副作用的录制回放 —— rr 式工程，
   投入产出不成比例；应用层接口注入 + mock 是契约答案。
2. **多线程确定性调度**（如确定性 work-stealing）：学术玩具，S 级用单线程
   绕开了问题本身。
3. **跨版本字节级一致**：det 保证同版本同构建的复现；版本升级后日志可回放
   性归 `ZDL1` 的 codec 版本管理（delivery_log 自己的领土）。
4. **core 域（Cluster/Kafka/EventBus）的 Time/RNG 收口**：一期只做 runtime 域；
   core 域待 S 级验证有真实用户后再议。
