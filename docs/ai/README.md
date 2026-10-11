# AI 子系统 — 从这里进

`zigmodu.ai` 提供六件**互相独立**的能力。它们不是六个步骤，是六条按需取的线——
先确认你要的是哪一条，再打开对应文档。

## 先定位你要哪一条

| 你要做的事 | 读这份 | 里面有什么 |
|-----------|--------|-----------|
| 生成一个带 LLM 对话的项目 | [`AI.md`](AI.md) | `--with-aichat` 脚手架、Provider 初始化、对话端点、Token 预算。**这是产品功能，不是 agent 指南** |
| 在业务系统里接入 AI | [`AI_DEV_GUIDE.md`](AI_DEV_GUIDE.md) | KeyManager → Provider → Skill → Agent/Workflow → 接入（HTTP / cron / outbox / MCP） |
| 查 Agent 能调用哪些技能 | [`AI_SKILLS.md`](AI_SKILLS.md) | 内置技能目录：`db.query` / `kpi` / `approval` / `admin`…，按 P0–P2 分级，附权限闸门 |
| 编排多步骤流程 | [`AI_ORCHESTRATION.md`](AI_ORCHESTRATION.md) | 线性 / DAG / 审批门 / WAL 恢复 / 触发 / 审计 |
| 给 AI 决策加审批、风控、诊断 | [`LLM_POLICIES.md`](LLM_POLICIES.md) | `zigmodu.ai.llm` 的策略接线、KeyPool 轮换、无模型验证 |
| 让外部 LLM 平台调用框架技能 | [`MCP.md`](MCP.md) | `SkillRegistry` → MCP 桥（Claude / 外部 agent 平台） |

> 写 ZigModu **框架代码**的 coding agent 请读 [`AGENTS.md`](../../AGENTS.md)——
> 那里的 §"文档地图"是权威路由，本页只是给人类读者的导航。
> `AI_METHODOLOGY.md`（讲**为什么**这样设计）已移到 [`docs/dev/`](../dev/AI_METHODOLOGY.md)，
> 不是现行接线指南。

## 它们之间的关系

```
                   ┌─────────────────────────────────────────┐
   对话产品  ────▶ │  AI.md          （--with-aichat 脚手架） │
                   └─────────────────────────────────────────┘

   业务接入  ────▶  AI_DEV_GUIDE.md   ← 入口：KeyManager → Provider → Skill
                        ├─▶ AI_SKILLS.md        Agent 能「做什么」
                        ├─▶ AI_ORCHESTRATION.md  多步骤怎么串
                        └─▶ LLM_POLICIES.md     决策怎么审

   外部平台  ────▶  MCP.md            把上面的技能暴露给 Claude 等平台
```

`MCP.md` 与业务接入那条线**正交**：它暴露的是 `SkillRegistry`，
不关心你在哪个进程里用（`zmodu mcp` 那个 codegen MCP 服务端也和运行时这个是两回事）。

## 一句话判断

- 想要一个**能跑的对话应用** → `AI.md`
- 想在**已有项目里**加 AI → `AI_DEV_GUIDE.md`，然后按需读下面三份
- 想让**外部平台**调你的技能 → `MCP.md`

不确定的话从 [`AI_DEV_GUIDE.md`](AI_DEV_GUIDE.md) 开始——它的 §1 是分层总览，
读完就知道自己需要哪几份。