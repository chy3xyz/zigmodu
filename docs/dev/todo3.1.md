# 低破坏性变化升级

由于已经有好几个项目上线了，为了，不对既有项目产生破坏性影响，参考一下方案

**完全可以把破坏性变化控制在很小范围内**。

我的判断是：如果按照我上面那套升级直接重构现有 `Application / Module / EventBus / DI`，确实可能产生较大的 breaking changes；但如果采用**“内核兼容 + Runtime 增量”的演进方式**，可以做到 **v0.16～v0.21 基本保持现有业务代码兼容**，最后到 1.0 再做一次有计划的 API 收敛。

目前 ZigModu 已经有 Module、DI、Event、Lifecycle、HTTP/gRPC、Resilience、Distributed 等成熟基础，因此没必要推倒重来。

## 我建议采用“双层架构”

```text
                 ZigModu
                    │
        ┌───────────┴───────────┐
        │                       │
  Existing Runtime        New Runtime
        │                       │
 Application               Runtime
 Module                    Worker
 DI                        Actor
 EventBus                  Mailbox
 HTTP                      RingBuffer
 ORM                       TimerWheel
 Redis                     Sequencer
 Kafka                     Scheduler
        │                       │
        └───────────┬───────────┘
                    │
              共享生命周期
              共享 Observability
              共享 Config
              共享 Error
```

**不要把现有 `Application` 改造成 Actor Runtime。**

而是：

```zig
const app = Application.init(...);

app.start();

const rt = try app.runtime();                      // 首次调用才创建（v0.16+）
const worker = try rt.spawn(MyWorker, .{}, 256);   // 256 = comptime 邮箱容量
```

这样老项目完全可以：

```zig
const app = Application.init(...);
app.start();
```

继续运行。

---

# 具体看哪些变化

| 升级                 | Breaking Risk | 建议               |
| ------------------ | ------------: | ---------------- |
| RingBuffer         |         🟢 很低 | 新增               |
| ObjectPool         |         🟢 很低 | 新增               |
| TimerWheel         |         🟢 很低 | 新增               |
| Clock abstraction  |          🟢 低 | 新增接口             |
| Worker             |         🟢 很低 | 新增               |
| Mailbox            |         🟢 很低 | 新增               |
| Actor              |         🟢 很低 | 新增               |
| Hot EventBus       |          🟡 中 | 新增，不替换旧 EventBus |
| Architecture Graph |         🟢 很低 | CLI 新增           |
| `zmodu doctor`     |         🟢 很低 | CLI 新增           |
| Workflow           |         🟢 很低 | 新增               |
| Agent Runtime      |         🟢 很低 | 新增               |
| Cluster            |          🟡 中 | 新增               |
| 重构 Module API      |          🔴 高 | 暂时不要             |
| 重构 DI              |          🔴 高 | 暂时不要             |
| 重构 Application     |          🔴 高 | 暂时不要             |
| 替换 EventBus        |          🔴 高 | 不建议              |

所以真正需要避免的是最后四项。

---

# 最关键：不要替换 EventBus

现在已有：

```zig
app.eventBus(T)
```

这个 API 很有价值。

继续保留：

```text
Application EventBus
        ↓
业务事件
```

然后增加：

```zig
app.runtime().hotBus(...)
```

用于：

```text
Trade
BookUpdate
OrderUpdate
Fill
Timer
```

于是：

```text
                    Event System
                         │
             ┌───────────┴───────────┐
             ↓                       ↓
       Application Bus           Hot Bus
             │                       │
       Business Event          Market Event
             │                       │
        易理解/可靠             高性能/低延迟
```

这就不会破坏已有代码。

---

# Worker 也不要修改 Module

例如原来：

```zig
const PaymentModule = struct {
    pub fn init(...) !void {}
};
```

继续有效。

新功能：

```zig
const PaymentWorker = struct {
    pub fn run(ctx: *WorkerContext) !void {
        ...
    }
};
```

然后：

```zig
const rt = try app.runtime();
const worker = try rt.spawn(PaymentWorker, .{}, 256);
```

这意味着：

> **Module 是架构单元，Worker 是运行单元。**

这是一个非常重要的概念分离。

---

# Actor 甚至可以完全建立在 Worker 之上

不要：

```text
Module
 ↓
Actor
```

而应该：

```text
Module
 ↓
Runtime
 ↓
Worker
 ↓
Actor
```

例如：

```zig
const OrderBookActor = Actor(OrderBookState);
```

Actor 内部：

```text
Mailbox
   ↓
Message
   ↓
State mutation
   ↓
Event
```

但是对于普通 Web SaaS：

```text
Application
 → Module
 → Service
```

完全不需要 Actor。

这就是**渐进式架构**。

---

# 我甚至建议增加一个 `Runtime` API

例如：

```zig
pub const Runtime = struct {
    pub fn spawn(...) !WorkerHandle;
    pub fn spawnActor(...) !ActorHandle;
    pub fn timer(...) TimerHandle;
    pub fn clock(...) Clock;
};
```

然后：

```zig
const runtime = app.runtime();

const worker = try runtime.spawn(MarketWorker, .{});
```

未来：

```zig
const actor = try runtime.spawnActor(OrderBookActor, .{});
```

但：

```zig
app.service(...)
app.eventBus(...)
app.module(...)
```

这些老 API **不要动**。

---

# 版本策略也很重要

我建议不要现在就宣布：

```text
ZigModu 0.16 = breaking rewrite
```

而是：

### v0.16

```text
新增 Runtime
新增 Worker
新增 RingBuffer
新增 Clock
新增 Timer
```

**0 breaking**

---

### v0.17

```text
Actor
Mailbox
Hot EventBus
Sequencer
```

仍然：

**0 breaking**

---

### v0.18

```text
Architecture Engine
zmodu graph
zmodu doctor
Architecture Rules
```

仍然：

**0 breaking**

---

### v0.19

```text
Cluster
Shard
Distributed Runtime
```

增加新 API。

---

### v0.20

```text
Workflow
Agent Runtime
```

---

### v1.0

这时候才考虑：

```text
API cleanup
命名统一
deprecated API removal
Runtime default
```

也就是说：

> **真正的 breaking change 留给 1.0。**

---

# 还有一个更重要的问题：性能升级本身也可能产生破坏性变化

比如现在：

```zig
app.eventBus(Trade)
```

假设未来为了性能直接改成：

```text
lock-free
zero allocation
bounded
```

可能会改变：

* Event 生命周期
* 内存所有权
* allocator 行为
* callback 生命周期
* thread-safety 语义

所以不要直接修改旧 EventBus。

做：

```text
EventBus
    │
    ├── ApplicationEventBus
    │
    └── HotEventBus
```

然后逐渐把内部通用组件抽出来：

```text
Event
Queue
Subscription
Dispatcher
```

---

# 对 `zigmodu` 来说，最危险的是“为了性能重写整个框架”

我反而**不建议这么做**。

因为你现在的资产已经很多：

```text
Module
DI
Lifecycle
Event
Outbox
HTTP
WebSocket
gRPC
ORM
Redis
Kafka
Resilience
Observability
Security
AI
CLI
```

这些都是已有生态资产。

真正应该做的是：

```text
                 ZigModu 现有资产
                       │
                 ┌─────┴─────┐
                 ↓           ↓
            Application    Runtime
                 │           │
                 │      ┌────┼────┐
                 │      ↓    ↓    ↓
                 │    Worker Actor HotBus
                 │
                 └───────┬────────┘
                         ↓
                  Unified Lifecycle
```

所以我会把这次升级定义成：

# **ZigModu Evolution，而不是 ZigModu Rewrite**

---

## 最终我建议的兼容原则

可以直接写进项目 `ARCHITECTURE.md`：

```text
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

这套策略特别适合你现在的 `zigmodu`。

**一句话：不要动“已经跑起来的骨架”，把新的 Runtime 作为第二条高速通道接进去。**

这样 `zigmodu` 可以同时服务：

```text
普通 SaaS
   ↓
Modulith

高并发服务
   ↓
Worker Runtime

实时系统
   ↓
Actor + Hot Event

量化交易
   ↓
Hot Runtime

分布式系统
   ↓
Cluster Runtime

AI 系统
   ↓
Agent Runtime
```

这会比直接重写成一个“高性能框架”稳得多，也更容易把现在的 `v0.15.x` 用户和未来的 `v1.0` 生态连接起来。
