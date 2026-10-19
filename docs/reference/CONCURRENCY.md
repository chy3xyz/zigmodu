# 并发与确定性契约

框架里有**两套并发模型**，它们服务不同的所有权形状；选错会让代码"能跑但难推理"。
这一页是决策表与确定性边界，配套代码注释见各文件头。

## 1. 选型决策表

| 你的问题 | 用 | 不要用 | 关键约束 |
|---|---|---|---|
| 一份可变状态 + 串行消息（订单簿、会话、计数器） | `Worker` + `Mailbox(T, capacity)` | 共享 `std.Io.Mutex` 保护的业务结构 | 单所有者；`send` 满即 `error.Full`（背压是承诺，不是 bug） |
| 一个请求内扇出多个独立 IO/阻塞任务并汇总 | `std.Io.Group`（fiber） | 每个任务起一个 `Worker` | 每任务独立分配器/上下文；取消是协作式的 |
| 真正会阻塞的调用（大文件、慢系统调用） | 阻塞池（`.mode = .blocking` 的 worker） | 放进 CPU 池 | 阻塞池独立，不占 CPU 池 |
| 延迟/周期任务 | `TimerWheel` / `Cron` | 线程内 `sleep` 循环 | TimerWheel 单写者：arm/cancel 走同一 FIFO |
| 一对多广播（配置、日志、指标） | `HotBus` | 共享可变数组 | `freeze()` 必须在第一条 `publish` 之前 |
| 跨进程事件 | `DistributedEventBus` / Raft | 自己开 TCP | 必须配置 key（`setOwnKey`/`setPeerKey`），否则握手拒绝 |
| Agent 的并行工具调用 | `Tool.parallel_safe` + `Agent.io` | 无声明就并行 | 全有或全无；handler 必须线程安全且用 `ctx.allocator` |

**判断口诀**：状态归谁所有？如果答案是一个线程/Worker，用 Mailbox；如果答案是
"没有共享状态，只是等 IO"，用 `std.Io.Group`。

## 2. 确定性边界

Replay（`runtime/recorder.zig` + `replay_driver.zig`）保证的是**运行时内**的顺序：

| 维度 | 是否确定 | 机制 |
|---|---|---|
| 消息投递顺序 | ✅ | `Sequencer` 分配单调 id；`delivery_log` 记录投递 |
| 定时器 arm/cancel 顺序 | ✅ | 单写者 TimerWheel + 同一 FIFO |
| ready 队列/调度顺序 | ✅ | Scheduler 的 ring 与批处理规则 |
| 时钟 | ✅（手动时钟下） | `runtime/clock.zig`；`Time.monotonic*` 不受影响 |
| 外部 HTTP / DB / 文件系统 | ❌ | 网络与磁盘不在录制范围 |
| 未走 Mailbox 的共享内存并发 | ❌ | 由你的同步策略决定 |

**把外部 IO 纳入回放**：在应用边界录制**规范化事件**（而不是原始请求字节），
例如 "收到支付成功事件(订单=42)"，回放时喂同一事件流。框架的 AI/RAG 与 Quant
示例走的就是这条路；不要把"Replay = 全链路可重放"当成默认承诺。

## 3. 取消语义

- `AgentHandle.requestCancel` / `Budget` 是**协作式**的：在步骤之间检查；
  一次已经发出的 provider 调用或 handler 调用不会被打断（依赖其自身超时）。
- `Tool.timeout_ms` 是"返回后检查 + 记录"，不是抢占；需要硬上界的工具应在
  handler 内轮询 `ctx.checkDeadline()`。
- `std.Io` 的取消只在挂起点生效，见 `docs/reference/RUNTIME.md`。

## 4. 观测

- `Scheduler.Stats`：claim/return、`ready_push_failures`、饥饿次数。
- `PrecisionTimer`：lateness p50/p99 与 spin 占比。
- `agent_writer`/`Worker` 的 `on_result(err)`：失败是数据，不是异常。
