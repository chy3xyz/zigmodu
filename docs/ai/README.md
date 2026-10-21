# AI Subsystem Overview (`zmodu.ai`)

`zmodu.ai` provides six modular capabilities for building controlled, auditable AI features in Zig applications. All capabilities enforce strict execution boundaries: allowlists, permission codes, token budgets, audit logs, and tenant isolation.

## 1. Document Map

| Task | Document | Contents |
|------|----------|----------|
| Scaffold an AI chat module | [`AI.md`](./AI.md) | `zmodu scaffold --with-aichat`, `AiProvider`, SSE streaming, multi-turn history, and `MemoryStore` |
| Integrate AI into a business service | [`AI_DEV_GUIDE.md`](./AI_DEV_GUIDE.md) | `AiKeyManager` → `AiProvider` → `SkillRegistry` → `Agent` / `Workflow` → HTTP / Cron / Outbox / MCP |
| Configure agent authority gates | [`AGENT_RUNTIME.md`](../reference/AGENT_RUNTIME.md) | Fail-closed `ai.Guard`, `AgentSpec`, `ProposalPipeline`, and `AgentWorker` |
| Browse built-in skills | [`AI_SKILLS.md`](./AI_SKILLS.md) | Read (`db.query`, `kpi.query`), propose (`approval.request`, `notification.send`), execute (`entity.*`, `command.execute`), and admin skills |
| Orchestrate multi-step workflows | [`AI_ORCHESTRATION.md`](./AI_ORCHESTRATION.md) | Linear and DAG `Workflow`, human approval gates, `Budget`, WAL crash recovery, and outbox bridges |
| Wire LLM-backed business policies | [`LLM_POLICIES.md`](./LLM_POLICIES.md) | `llmApprove`, `llmRiskDecide`, `llmDiagnose`, `llmVerify`, and `AiKeyManager` key rotation |
| Expose skills over MCP | [`MCP.md`](./MCP.md) | `ai.mcp.serveStdio` bridging `SkillRegistry` to Claude / Codex / external MCP clients |

## 2. Architecture Overview

```text
Chat Product    ---> AI.md (`--with-aichat` scaffold)

Business App    ---> AI_DEV_GUIDE.md (AiKeyManager -> AiProvider -> SkillRegistry)
                       ├──> AI_SKILLS.md         (What tools the Agent can call)
                       ├──> AGENT_RUNTIME.md     (Guard & Proposal -> Risk -> Execute)
                       ├──> AI_ORCHESTRATION.md  (Multi-step linear/DAG workflows)
                       └──> LLM_POLICIES.md      (Approval, risk, and diagnosis policies)

External Client ---> MCP.md (Exposes SkillRegistry over stdio MCP)
```

> If you are using an AI coding assistant to write zmodu application code, start with [`AGENTS.md`](../../AGENTS.md).
