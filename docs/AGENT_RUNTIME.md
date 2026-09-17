# Agent Runtime —— 默认不能执行（v0.21+）

`todo3.md` §八 给 AI + 金融/业务系统定了唯一一条硬规则：

> **AI Agent 默认不能直接交易。** Agent → Proposal → Risk → Execution

这条规则在框架里分三层，逐层收紧：

| 层 | 类型 | 回答的问题 |
|----|------|-----------|
| **权限闸门** | `ai.Guard`（`src/ai/guard.zig`） | 这个 agent **能不能**做这件事（两条轴，见下） |
| **工具声明** | `skill.Tool.action` | 这个工具属于哪一类 —— **默认 `execute`**（最严），忘了声明就永远拿不到宽策略 |
| **阶段骨架** | `ai.ProposalPipeline`（`src/ai/proposal.zig`） | 提议 → 风险 → 执行，**顺序**不能跳 |

## 一、两条轴，都是 fail-closed

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

## 二、接进 `Agent.run`（默认路径）

`Agent.guard` 一旦设置，**每次工具调用先过闸门再分派**：

```zig
var guard = ai.Guard.init(.{
    .allow = &.{ "market.quote", "order.draft", "order.submit" },  // 列名 ≠ 可执行
    .deny = &.{},                                   // 随时可以收回某一项
    .allow_execute = false,                         // 执行：另外再说一句
});

var spec = ai.AgentSpec{
    .name = "trader",                 // 身份：进日志与 Prometheus 标签
    .provider = &provider,
    .skills = &registry,              // 技能：注册时各自声明 action
    .guard = &guard,                  // 权限：默认空 = 什么都不能做
    .memory = &memory,                // 记忆：按本次运行的 tenant+user 注入
    .system_prompt = "You are …",
};
var agent = spec.build();

try registry.register(.{ .name = "order.draft", .action = .propose, /* … */ });
```

被拒时**不是**报错退出：`{"error":"ToolDenied","reason":"denied_execute_class"}` 会作为工具结果喂回模型，
它就能改走"提议"分支 —— 这正是规则要的形状。同时 `AgentMetrics.tool_denied`、guard 的四类计数、
audit 记录（写的是具体原因）各自留痕。

两个刻意的细节：

- **闸门在 `hooks.on_tool_request` 之前**。结构上不该发生的事不必先问人；钩子仍然管"这一次要不要放行"。
- **`Agent.run` 不扣 guard 的预算**（`estimated_tokens = 0`）。LLM 步数花费由 `Agent.budget` 管，
  同一个 token 在两条账上各记一次，会让两个上限都说谎。

## 三、声明式规格（`AgentSpec`）

手搓 `Agent{}` 最容易漏的正是 `guard` —— 漏了就什么都没拦。`AgentSpec` 把身份 / 技能 / 记忆 / 权限
收成一处字面量，`build()` 按正确顺序接线：

- `isGuarded()` —— 有没有闸门；没有就是**无界**（不是"惰性"，是另一种、通常更糟的问题）
- `isInert()` —— 有闸门但什么也没授予；启动期据此大声失败

一个进程里跑多个 agent 时，`name` 让日志与指标可分辨；评审时 `Spec` 是唯一要看的那一屏。

## 四、Proposal → Risk → Execution（骨架）

`ai.ProposalPipeline` 把三段串成一个函数。`executeStage` 是私有的，**只能**从闸门进：

```
guard.check(.propose, action) ──refuse──▶ propose_refused
        │
   risk.RiskReview.review ──reject────▶ risk_rejected
        │                  ──escalate──▶ approval.ApprovalFlow ──pending──▶ needs_human
        │                                          │approved
   guard.check(.execute, action) ──refuse──▶ execute_not_permitted
        │
   executor(...) ──error──▶ executor_failed
        │
   executed
```

三个刻意的决定：

1. **风险阶段排在"能不能执行"之前。** agent 不被允许执行时（默认状态），提议照样带着风险结论交出去 ——
   人（或另一个系统）接手的是一条有判定的提议，而不是一句"它没权限"。
2. **没有审批链时，escalate 就是硬停**（`needs_human`）。agent 不会因为"没人看着"就自己批准自己。
3. **`executed` 不是 agent 的常态结局**，`execute_not_permitted` 才是 —— 这就是 §八 想要的样子。

`risk.RiskReview`（SQL 规则打分 → approve / reject / escalate）与 `approval.ApprovalFlow`（多级人工审批 +
outbox 留痕）都在 `src/ai/` 里，Pipeline 只负责它们之间**不能跳序**。

```zig
var pipeline = ai.ProposalPipeline.init(&guard, executorFn);
pipeline.risk = &review;            // 可选：没有它就只剩"能不能执行"这一道
pipeline.approval = &chain;         // 可选：risk escalate 才用到，缺省 = 硬停
pipeline.approval_steps = &steps;

const out = try pipeline.submit(allocator, &ctx, .{
    .action = "order.submit",
    .payload = "order-1",
    .amount = 150_000,              // 金额不是风险分，两者不互相顶替
});
switch (out.verdict) {
    .executed => {},                            // 风险放行 + 策略允许执行
    .execute_not_permitted => queueForHuman(out), // 常态：带着 out.risk 交给人工/别的系统
    else => |v| std.log.warn("proposal refused: {s}", .{@tagName(v)}),
}
```

## 五、记忆：`0` 是"任意"，所以拒绝注入

`MemoryStore.recall` 把 `0` 当通配（`if (e.tenant_id != tenant_id and tenant_id != 0)`），
所以一次没有租户标识的运行若直接 recall，会把**别的租户**的记忆拼进 prompt。
`Agent.memory` 走的是 `memory.recallBlockAlloc`：tenant 与 user 必须**存在且非 0**，否则一个字都不注入；
有值就按该 tenant + user 精确取（`memory_prefix` 过滤、`memory_limit` 截断）。
`MemoryStore.formatContext` 仍然是原样（传 `0` = 跨租户），agent 路径不要用它。

## 六、Agent 作为 Worker（`Agent → Worker → Event`）

`Agent.run` 会**阻塞调用它的线程**整轮 LLM 往返。从 webhook handler 或 cron tick 里直接调
（`ai.trigger.Trigger.fire` 就是这么做的），一个慢模型就占住一个请求线程。把 agent 跑成 **worker**，
运行时已有的承诺就白拿到了：**有界邮箱**（满 → 生产方 `error.Full`，而不是无限堆积）、
**生命周期**（`app.stop()` / `rt.shutdown()` 负责 join）、**监督**（`spawnActor` + `Supervision` 错误预算）、
**指标**（`handle.stats()` 的队列深度与丢弃数）。

```zig
const ai = zmodu.ai;

// 结果回到这里 —— 在 worker 线程上，所以只入队、不处理
fn onDone(ud: ?*anyopaque, d: ai.AgentDone) void {
    const me: *MyApp = @ptrCast(@alignCast(ud.?));
    if (d.err) |e| return me.alerts.push("agent failed: {s}", .{@errorName(e)});
    me.answers.push(d.result.?.answer);   // 借用：要留就 copy
}

// 模块 initWith：worker 挂在 app 的 runtime 上
const rt = try ctx.runtime();
const worker = try rt.spawn(ai.AgentWorker, .{
    .allocator = ctx.allocator,
    .agent = &my_agent,          // 闸门 / 记忆 / 预算 / 审计都在它身上
    .on_result = onDone,
    .ud = self,
}, 32);

// 请求线程：投递即返回（`post` 会 dupe 文本，worker 负责释放）
try ai.agent_worker.post(ctx.allocator, 32, worker, goal_text, tenant_id, user_id);
```

三条刻意的约定：

- **所有权**：`post()` dupe 目标文本、worker 跑完释放；交给 `on_result` 的 `AgentResult` 是**借用** ——
  出了回调就释放，要留就自己 copy。邮箱有界（`capacity`），满时 `error.Full` 且不泄漏。
- **失败不算 worker 错误**：provider 挂掉走 `on_result(err)` 并由 app 决定重试/DLQ/告警；
  监督器的错误预算留给**真 bug**（所以 `stats().handler_errors` 保持 0）。
- **执行器可换**：`executor` 默认 `Agent.run`，测试注入罐头的即可（本文件的单测不碰网络）。

`Worker → Event` 那条边就是 `on_result`：在那里发 L1 事件（`app.eventBus(T)`）、写 L2 outbox、
或推 SSE —— 框架不替业务决定发什么事件。

## 这不是什么

它不是**终端用户**的鉴权系统 —— 那是 `security/`（JWT / RBAC / catalog 权限）。这道闸门管的是
**agent 自身的权限**：在任何"它代表哪个用户"的问题之前，这个自动化角色到底能不能做某件事。

## 仍然属于业务侧

- **Risk 的规则**（`RiskRule.sql` + 分值）与 **Execution 的实现**（`ExecutorFn`）：框架给顺序和骨架，
  内容由业务填。
- **身份 ≠ 鉴权**：`SkillContext` 的 tenant / user 是"代表谁运行"，权限依旧由 `security/` 决定。
- **多智能体编排**（谁指挥谁、跨 agent 的预算分配）不在这一层。
- **Agent 的 State / Event subscriptions / Lifecycle** 仍未做：状态在 app 侧（worker 的 `handle` 无状态），
  订阅是主动拉（`ai.trigger`），没有 agent 级的 start/stop。
