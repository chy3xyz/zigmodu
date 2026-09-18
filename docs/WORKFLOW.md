# Workflow —— 长流程的可恢复执行（v0.20+）

v0.20 没有新写一个编排器。仓库里已经有两个：`core/SagaOrchestrator.zig`（业务事务编排，
WAL 持久化）与 `ai/workflow.zig`（AI 流程，同样有 WAL + resume）。**缺的是"崩溃后真的能续跑"**，
以及恢复时不该复活已经结束的实例。这一版补的就是这两件事。

## 一步之内的语义（写下来，因为这是检查点的全部意义）

`SagaOrchestrator.resumeInstance(id)` 继续一个**上一个进程留下的**实例（它由 `restoreFromWal`
装回来）：

| 情况 | 行为 | 为什么 |
|------|------|--------|
| 该步已记 `completed` | **不重跑** | 这就是检查点 |
| 崩溃时**正在执行**的那一步（`current_step`） | **重跑** | 没有任何记录能说明它是否生效 —— 所以**有副作用的一步必须幂等**（和所有 at-least-once 系统一样） |
| 已 `completed` / `compensated` / `failed` / `timed_out` | 拒绝（`error.NothingToResume`） | 重放已补偿的 saga 会把副作用补偿两次 |
| `compensating` 中途 | 拒绝 | 补偿做了一半，该由人决定，不是框架猜 |

```zig
var orch = zigmodu.SagaOrchestrator.init(allocator);
defer orch.deinit();
orch.setWal(&wal);                      // 真持久：分段文件 + fsync
try orch.registerSaga("order", steps);  // 启动时重新注册（闭包在定义里）
try orch.restoreFromWal();              // 崩溃遗留的实例回到 .running
for (orch.listActiveInstances()) |id| try orch.resumeInstance(id);
```

## 步骤超时：`timeout_seconds` 是事后判定，不是中断

进程内执行器**无法抢占**一个正在运行的 step，所以 `SagaStep.timeout_seconds`
（秒，`0` = 不做预算检查，默认 30）的语义是**诚实的事后判定**：

- step 的 action 正常返回后，若实际耗时 > 预算，实例判为 `.timed_out` —— 终态，
  与 `failed` 同级但可区分；`execute` / `resumeInstance` 返回 `error.SagaStepTimeout`。
- 超时的那一步**已经执行完、副作用已生效**，所以它会和之前已完成的步一起被逆序补偿
  （对照：action 报错的步没有生效，只补偿它之前的步）。
- `.timed_out` 与 `completed` / `compensated` / `failed` 同为终态：
  `restoreFromWal` 不恢复，`resumeInstance` 拒绝（`error.NothingToResume`）。

要"到点立即掐死 step"需要可抢占的执行环境（独立进程 / 远程调用 + 取消令牌），
不在进程内编排器的范围内。

## 本版修掉的三个真问题（都由新测试暴露）

1. **恢复会"复活"已结束的实例**：`restoreFromWal` 原先逐条看记录，只要**任意**一条是
   `running` 就恢复 —— 而一个失败并补偿完的 saga 在 WAL 里正是
   `running → running → compensated` 的链条，于是它会以 `running` 回来，再被续跑就**重复补偿**。
   现在按实例取**最后一条**状态再决定（回归测试直接钉住：已补偿的不再出现，真在飞的仍在）。
2. **每次启动泄漏**：`readFrom` 交出的条目的 topic/payload/source_node 归调用方，而
   `restoreFromWal` 从不释放 —— 一个之前没人调用它所以没人发现的泄漏。现在 `defer` 释放。
3. **`resume` 不能叫 `resume`**：`resume` 是 Zig 关键字（`suspend`/`resume`），`pub fn resume`
   直接被解析器拒绝 → 改名 `resumeInstance`，注释里说明原因。

## 刻意不做

- 不引入新的 workflow DSL / 状态机描述语言：`registerSaga(name, steps)` 已经是声明式定义，
  再加一层语法解决的是"看起来更像 Temporal"，不是这里的任何真实问题。
- 不做调度器 / 定时触发器：`scheduler/Cron.zig` 已有；把 `resumeInstance` 挂上去是使用侧的一行。
- 不做跨节点编排：强一致编排继续用 Postgres（`docs/BEST_PRACTICES.md`「分布式建议」）；
  `DistributedTransaction` 仍是 experimental（缺持久化协调日志）。
- `ai/workflow.zig` 保留（AI 专属：审批门、反思、工具调用），两者都建立在同一套 WAL + resume 语义上。

## 什么时候用

下单/支付/结算这类**多步、有外部副作用、失败要补偿**的流程；以及任何"崩了以后希望继续，
而不是从头再来一次"的长任务。纯 CRUD 不需要它。
