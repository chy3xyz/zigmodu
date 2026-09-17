# AI 边界 —— 抽包的前置条件（v0.20.1+）

`src/ai/` 是树里最大的可选面（约 12k 行），也是最可能变成独立包的一块。抽包只被**一件事**挡住：
AI 代码直接 import **驱动层**（`sqlx/sqlx.zig`、`persistence/backends/**`），而不是走 `data` 领域缝。

实测（`src/test/AiBoundary.zig` 会持续核对）：

| 方向 | v0.20.1（写这份文档时） | v0.20.2（迁移后） |
|------|------|------|
| **框架 → ai** | **干净**：整个 `src/` 里只有 `root.zig` 的一行 re-export | 同上，未变 |
| **ai → 框架（驱动层）** | 直接 `sqlx/sqlx.zig` **30** 处、直接 `persistence/backends/**` **26** 处，21 个文件 | **0 / 0** ✅ |

迁移是一次机械替换：两处 import 表达式 → `@import("../data.zig")`（`data.sqlx` 与 `data.SqlxBackend`
本来就是同一批模块的 re-export，**类型同一性不变、行为不变**）。顺带一个诚实的观察：56 处里绝大多数是
**测试脚手架**（`:memory:` 客户端与 backend 的构造），所以"生产代码耦合"比这个数字小 —— 但既然一条
替换就能清零，就没有理由留着。

所以边界现在是**机器检查**的，而不是文档里的约定：

- **反向（core → ai）绝对禁止**：`src/{core,api,data,sqlx,http,security,messaging,runtime}` 下任何文件
  import `ai/` 都会让测试失败。只有 `root.zig` 的 re-export 是缝。
- **正向（ai → 框架）ratchet**：只允许 import 领域缝（`data.zig` / `http.zig` / `core/Time` /
  `http/Sse` / `messaging/` / `scheduler/` / `resilience/` / `tracing/` / `redis/` / `security/` /
  `test/`）。直接 import 驱动层被**冻结在两个上限**（30 / 26），**只能减不能增** —— 新增一处就编译失败。
  计数下降时测试会打印一行，提醒把上限调低锁住成果。

为什么要 ratchet 而不是一次性清理：一次性改 56 处跨 21 个文件的 import 是把"边界"和"行为"两件事
混在一次提交里，风险高且难验证；ratchet 保证**债务不再增长**，然后可以按模块逐个搬。
真正的清理路径（每个文件一处）：

```zig
// before — 直接拿驱动
const sqlx = @import("../sqlx/sqlx.zig");
// after — 拿领域缝
const data = @import("../data.zig");   // SQLx / Repository / Cache / Redis 都是它的面
```

`src/test/AiBoundary.zig` 里的 `baseline_direct_sqlx` / `baseline_direct_backends` 已锁到 **0**，
等于对驱动层 import 的绝对禁止。**抽包条件**因此只剩"保持"：两个测试持续为绿即可。

## 与 v0.21（Agent Runtime）的关系

Agent Runtime 要做的是把 Identity / Memory / Skills / Permissions / Budget 变成一等公民 ——
这需要 AI 层能被别的包依赖，而"能被依赖"的前提是它只依赖**稳定接口**（领域缝），
不是"当前那个驱动文件恰好长这样"。所以顺序是：先 ratchet 住边界（本版）→ 再逐文件搬 → 再做 Agent Runtime。
反过来做（先加能力再收边界）会让耦合更多、更难抽。
