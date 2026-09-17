# alpha-engine 规格（todo3 §十六 的参考实现）

> 状态：**规格，未实现**（2026-09-17 立）。目标是把 todo3「杀手级 Reference Implementation」拆成
> 可独立验证的阶段，避免一次性重写。

## 1. 为什么是这个示例

框架现在有三条已通的装配线（Runtime 采用 / `Agent→Worker→Event` / Cluster 读侧），但**没有一个示例同时
展示它们**。todo3 §十六 点名要做 `examples/alpha-engine/`：一条真实形状的交易流水线，用来证明
「高性能 + Event-driven + Actor + Modulith + 容错 + 可观测 + AI」不是口号。

现有 `examples/runtime-workers` 覆盖了它的前三段（行情 → 订单簿 → 风控）+ HotBus + 监督 + 定时器快照，
**alpha-engine 是它的延伸**，不是重写：保留那段，补齐 Alpha / Execution / Exchange Adapter 与
Replay/Backtest 两种驱动模式。

## 2. 范围（每条都要能指到具体 API，否则不做）

| 能力 | 用哪个 API | 验收方式 |
|------|-----------|---------|
| Actor / 状态所有权 | `rt.spawn` / `rt.spawnActor`（`runtime.zig`），每 worker 自带 mailbox | 全文件 `grep -c "Mutex\|atomic"` 只允许出现在 feed 与 metrics |
| L0 热事件 | `runtime.HotBus`（freeze 后无锁扇出、drop-on-full） | `bus.stats().dropped > 0` 且订单簿从未阻塞 |
| 背压 | `runtime.Handle.send` 的 `error.Full` + 合并策略 | `stats().dropped_full > 0`，进程不涨内存 |
| 生命周期 | `Application` + `ctx.runtime()`（模块 `initWith` 里 spawn） | `app.stop()` 后 `[done] every worker joined` |
| 定时器 | `handle.after(...)`（ticker 由 app 负责启动） | `stats().timer_fires > 0`、`timer_lag_max_ms` 打印 |
| 模块边界 | `api.Module` + `pub const routes`（ComptimeRouter） | `zmodu doctor examples/alpha-engine` PASS |
| 容错 | `spawnActor` + `Supervision`（错误预算） | 故障 worker 被停且 mailbox 关闭，进程继续 |
| 可观测 | `AgentMetrics`/`RuntimeStats` 打印 + OTLP（可选） | 一条 `-Dmetrics` 开关，默认关 |
| AI 侧（可选） | `ai.AgentWorker` + `ai.ProposalPipeline` | 见 P3 |

## 3. 拓扑（worker 图）

```text
  feed(thread) ──▶ OrderBook ──▶ Alpha ──▶ Risk ──▶ Execution ──▶ ExchangeAdapter
       │              │            │         │           │              │
       └──────────────┴────────────┴─────────┴───────────┴──────────────┘
                         HotBus(Delta) 扇出：audit / metrics / 落盘
                         after(200ms) 快照定时器；after(1s) 心跳
```

驱动模式（同一份 worker 代码，换 feed 与 adapter）：

- **Replay**：`feed` 读一个内嵌的 NDJSON/CSV 序列（确定性，可断言），adapter 是 `PaperExchange`（即时成交）。
- **Backtest**：Replay + 结束时打印 PnL/成交笔数/最大回撤（只统计，不优化）。
- **Paper**：Replay 按原始时间戳节流。
- **Live**：**不做**（要接真交易所，属于使用方）。

## 4. 分阶段（每阶段独立可验证、可停）

- **P0 · 骨架**（≈150 行）：`src/main.zig` + 一个 `Pipeline` 模块（`initWith` 里 `ctx.runtime()` spawn
  OrderBook/Alpha/Risk/Execution），ExchangeAdapter 为 `PaperExchange`。Replay 驱动。
  验收：`zig build run` 打印快照 + `[done] every worker joined`；`zig fmt --check` 干净。
- **P1 · 观测与容错**：HotBus 扇出（audit/metrics）、`after` 快照、一个故意失败的 `FaultyFillReporter`
  （`spawnActor` + 3 次错误预算）、结束时打印 `rt.stats()`。验收：`dropped`/`timer_fires`/
  `stopped_by_supervisor` 三个计数非零且断言。
- **P2 · 模块化与门禁**：拆成 `market` / `book` / `alpha` / `risk` / `exec` 模块（`api.Module`），
  `main` 只做组装；`zmodu doctor` 与 `zmodu ci` 必须 PASS；加 CI job 跑示例。
- **P3 · AI 侧（可选）**：`ai.AgentWorker` 订阅"日终快照"消息，产出**提议**（`ai.ProposalPipeline`）
  由 `PaperExchange` 执行 —— 演示"Agent 默认不能直接交易"在示例里的样子（`Guard` 的 `allow_execute = false`）。

## 5. 明确不做

- 不接真交易所/真行情（无凭证、无网络依赖；CI 要能离线跑）。
- 不做真正的回测引擎（撮合、滑点、手续费模型最多到"够打印一行结果"）。
- 不引入新依赖（现成 `runtime` / `http` / `ai` 就够）。
- 不重写 `examples/runtime-workers` —— alpha-engine 是它的延伸；两者共享 worker 写法。

## 6. 风险与前置

- `examples/*` 由 CI 的 `Build Examples` job 构建（`ci.yml`），所以**每个阶段都必须本地 `zig build run` 通过**
  才算完成（不能只编译）。
- 单文件会很长（P0 就 ~150 行），到 P2 必须拆模块 —— 否则违反 `docs/MODULITH.md` 的边界纪律。
- 若只想验证某一能力（例如背压），优先扩 `examples/runtime-workers` 的现有断言，而不是在 alpha-engine
  里造第二套。
