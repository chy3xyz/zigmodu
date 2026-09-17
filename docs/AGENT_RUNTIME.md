# Agent Runtime —— 默认不能执行（v0.21+）

`todo3.md` §八 给 AI + 金融/业务系统定了唯一一条硬规则：

> **AI Agent 默认不能直接交易。** Agent → Proposal → Risk → Execution

身份 / 记忆 / 技能 / 工具 / 预算 / 钩子 / 指标这些，`src/ai/` 里本来就有（`Agent`、`SkillRegistry`、
`Budget`、`AgentHooks`、`AgentMetrics`）。**缺的是闸门**：一个明确决定"这个 agent 到底被允许做什么、
谁批准的"的地方，而且 handler 直接调工具时绕不过去。`src/ai/guard.zig` 就是它。

## 两条轴，都是 fail-closed

| 轴 | 默认 | 为什么 |
|----|------|--------|
| **类别**：`read` / `propose` / `execute` | `execute` **再上一道开关**：`allow_execute` | 把 "order.submit" 写进 allow 不等于"这个 agent 可以下单"；执行需要有人**另外**说一句 —— 配置写错了不会静默把交易接口交给 agent |
| **名字**：`allow` / `deny` | `allow` **默认为空 = 什么都不能做**；`deny` 永远压过 `allow` | 空策略的 agent 是惰性的（`isInert()` 让调用方在启动期就能大声失败，而不是事后发现"agent 什么都不做"）；`deny` 压过 `allow` 让宽列表能被局部收回，不必重写整份 |

预算在**同一个函数**里检查，因为"agent 因为 token 用完而停下"不该依赖调用方记得去问。
两处细节是刻意的：**被拒绝的动作不消耗预算**（否则配置错的 agent 会靠"试"把自己饿死），
而拒绝原因**分门别类计数**（`denied_not_listed` / `denied_explicitly` / `denied_execute_class` /
`denied_budget`）—— 一个"看起来健康"的被拒 agent，正是这道闸门要防的东西。

报出的原因是**真正卡住它的那一个**，判定次序固定为 `deny` → 是否列名 → 执行开关：未列名的
`execute` 报 `denied_not_listed`，哪怕 `allow_execute` 也关着 —— 打开那个开关不会有任何变化，
报"执行类被拒"只会把运维指到错的旋钮上。

```zig
var guard = ai.Guard.init(.{
    .allow = &.{ "market.quote", "order.draft", "order.submit" },  // 列名 ≠ 可执行
    .deny = &.{},                                   // 随时可以收回某一项
    .allow_execute = false,                         // 执行：另外再说一句
});
guard.budget = ai.budget.Budget.init(200_000);

switch (guard.check(.execute, "order.submit", 0)) {
    .allowed => try executor.submit(...),
    .denied_execute_class => try propose(ctx, ...),   // 列了名但没开执行开关 → 走"提议"分支：这就是规则要的形状
    else => |d| std.log.warn("agent refused: {s}", .{@tagName(d)}),
}
```

## 这不是什么

它不是**终端用户**的鉴权系统 —— 那是 `security/`（JWT / RBAC / catalog 权限）。这道闸门管的是
**agent 自身的权限**：在任何"它代表哪个用户"的问题之前，这个自动化角色到底能不能做某件事。

## 还没做（说清楚，免得被当成已具备）

- 身份/记忆/技能还没有"一等公民"的类型包装：它们由 `Agent` 与 `SkillRegistry` 承载，
  可组合但不是一个声明式的 `Agent(.{...})` 规格。`guard.zig` 先把**最危险的一半**（能不能动手）定下来。
- 没有把 `Guard` 接到 `Agent.run` 的调用链上（那需要读 `Agent` 的 hook 点，见 `docs/AI.md`）；
  现在的接法是调用方在工具分发处分派 `check`。
- Proposal → Risk → Execution 三段里，**只有 Proposal 侧的入口**（`propose` 类别 + 拒绝后落到提议分支）；
  Risk 与 Execution 的具体实现属于业务系统。
