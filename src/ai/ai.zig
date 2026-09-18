/// A callable skill (tool) an LLM can invoke by name.
pub const Tool = @import("skill.zig").Tool;
/// One tool parameter: type + description, rendered to JSON Schema.
pub const Param = @import("skill.zig").Param;
/// What a skill handler receives: allocator, caller identity, dispatcher state.
pub const SkillContext = @import("skill.zig").SkillContext;
/// Registry of skills an agent may call — dispatch by name, list as tools.
pub const SkillRegistry = @import("skill.zig").SkillRegistry;
/// Registry-side policy audit: what a policy does to the tools' declared classes.
pub const PolicyHealth = @import("skill.zig").PolicyHealth;
/// Per-dispatch options: timeout, tenant/actor scope, approval hook.
pub const DispatchOpts = @import("skill.zig").DispatchOpts;
/// Frees a `Value` returned by a skill dispatch.
pub const freeValue = @import("skill.zig").freeValue;

/// OpenAI-compatible chat provider with tool_calls and cache metrics.
pub const AiProvider = @import("provider.zig").AiProvider;
/// Key-pool module: concurrency-safe API-key rotation per provider endpoint.
pub const key_pool = @import("key_pool.zig");
/// Guard module: the default-deny gate in front of every agent action.
pub const guard = @import("guard.zig");
/// Decides whether an agent action may run — no policy means no action.
pub const Guard = guard.Guard;
/// Allow/deny lists (+ an execute switch) a `Guard` evaluates per action.
pub const Permissions = guard.Permissions;
/// Guardable actions: read, propose, or execute an effect.
pub const GuardAction = guard.Action;
/// Proposal module: propose → risk → execute, in that order and no other.
pub const proposal = @import("proposal.zig");
/// A proposed action + payload awaiting risk review and execution.
pub const Proposal = proposal.Proposal;
/// Runs proposals through propose → risk → execute, never skipping a stage.
pub const ProposalPipeline = proposal.Pipeline;
/// How a proposal ended: executed / refused / rejected / needs_human.
pub const ProposalVerdict = proposal.Verdict;
/// Full proposal outcome: verdict, risk result, approval status.
pub const ProposalOutcome = proposal.Outcome;
/// Agent-as-worker module: run agents on the runtime mailbox model.
pub const agent_worker = @import("agent_worker.zig");
/// Worker that runs an `Agent` from runtime messages (goal in, done out).
pub const AgentWorker = agent_worker.AgentWorker;
/// Message that starts an agent run on an `AgentWorker`.
pub const AgentGoal = agent_worker.Goal;
/// Message carrying a finished agent run's result.
pub const AgentDone = agent_worker.Done;

/// Concurrency-safe pool of API keys for one provider endpoint.
pub const KeyPool = key_pool.KeyPool;
/// A checked-out key: return it to the pool when the call ends.
pub const KeyLease = key_pool.KeyLease;
/// Why a key was refused (rate limit / auth / quota) → cooldown length.
pub const KeyErrorKind = key_pool.KeyErrorKind;
/// Cooldown module: where key failures are recorded (memory or Redis).
pub const cooldown_store = @import("cooldown_store.zig");
/// Interface for key cooldown state; pick the memory or Redis impl below.
pub const CooldownStore = cooldown_store.CooldownStore;
/// In-process key cooldowns — fine for a single replica.
pub const MemoryCooldownStore = cooldown_store.MemoryCooldownStore;
/// Redis-backed cooldowns so every replica agrees on key health.
pub const RedisCooldownStore = cooldown_store.RedisCooldownStore;
/// Provider registry module: register LLM providers, route, fall back.
pub const provider_registry = @import("provider_registry.zig");
/// Registers LLM providers and routes calls with provider-level fallback.
pub const ProviderRegistry = provider_registry.ProviderRegistry;
/// A checked-out provider (plus key) for the duration of one request.
pub const ProviderLease = provider_registry.ProviderLease;
/// The AI key app module: wires `ProviderRegistry` + `KeyPool` together.
pub const AiKeyManager = @import("module.zig").AiKeyManager;
/// Module definition (`info` / lifecycle) for the AI key module.
pub const ai_key_module = @import("module.zig");
/// ReAct agent loop: `AiProvider` tool_calls ↔ `SkillRegistry.dispatch`.
pub const Agent = @import("agent.zig").Agent;
/// Agent config: provider, skills, guard, prompt, step/token limits.
pub const AgentSpec = @import("agent.zig").Spec;
/// Prompt used when a spec does not set its own system prompt.
pub const default_system_prompt = @import("agent.zig").default_system_prompt;
/// One run's result: messages, tool calls, token usage, stop reason.
pub const AgentResult = @import("agent.zig").AgentResult;
/// Run callbacks: per-step, per-tool-call, and on-error hooks.
pub const AgentHooks = @import("agent.zig").AgentHooks;
/// Per-agent counters: runs, steps, tool calls, errors, denials, budget.
pub const AgentMetrics = @import("agent.zig").AgentMetrics;
/// Hook that decides whether a specific tool call may execute.
pub const ToolApproval = @import("agent.zig").ToolApproval;

/// Cross-session memory (facts/preferences), scoped by tenant + user.
pub const MemoryStore = @import("memory.zig").MemoryStore;
/// One memory fact: logical key, value, tenant, user, timestamps.
pub const MemoryEntry = @import("memory.zig").MemoryEntry;

/// Ring-buffer audit trail of agent runs and tool calls.
pub const AgentAuditLog = @import("audit.zig").AgentAuditLog;
/// One audit record: kind, tool, detail, tenant/user, timestamp.
pub const AuditEvent = @import("audit.zig").AuditEvent;
/// Audit kinds: run start/finish, tool ok/err/denied, max steps.
pub const AuditKind = @import("audit.zig").AuditKind;

/// A named task the schedule skills may schedule (name + callback).
pub const ScheduledTask = @import("schedule.zig").ScheduledTask;
/// Registers the cron-backed `schedule.*` skills on a registry.
pub const registerScheduleSkills = @import("schedule.zig").registerScheduleSkills;
/// AI ⇄ cron bridge: schedule agent/workflow runs through the cron scheduler.
pub const schedule = @import("schedule.zig");

/// Built-in business skills to register on an agent (order/user/…).
pub const business = @import("business.zig");
/// Write-operation skills — app-registered, whitelisted mutations.
pub const actions = @import("actions.zig");
/// Admin/ops skills — off by default; add them to an agent explicitly.
pub const admin = @import("admin.zig");
/// Exposes registered skills as MCP tools for Claude/Codex-style clients.
pub const mcp = @import("mcp.zig");
/// Token budget shared across an agent run or the steps of a workflow.
pub const Budget = @import("budget.zig").Budget;
/// Linear multi-step agent workflow (orchestration).
pub const workflow = @import("workflow.zig");
/// Counters for workflow runs, steps, failures and durations.
pub const WorkflowMetrics = @import("workflow.zig").WorkflowMetrics;
/// Merges workflow/agent/quota metrics into one Prometheus text response.
pub const observability = @import("observability.zig");
/// Persists one row per workflow/agent/approval run (status, duration…).
pub const run_audit = @import("run_audit.zig");
/// Renders a skill registry as skills-catalog JSON or OpenAPI 3.0.
pub const skill_export = @import("skill_export.zig");
/// Unifies cron/event/webhook sources into one "run this agent" entry point.
pub const trigger = @import("trigger.zig");
/// Planner splits a goal into subtasks, runs them concurrently, aggregates.
pub const hierarchy = @import("hierarchy.zig");
/// Conversation context: estimate tokens, compact long histories.
pub const context = @import("context.zig");
/// Cooperative control handle for a running agent (cancel / inspect).
pub const AgentHandle = @import("handle.zig").AgentHandle;
/// Runs configured SQL and renders a Markdown business report.
pub const reporter = @import("reporter.zig");
/// Periodic SQL alert rules — any rule returning rows raises an alert.
pub const alerts = @import("alerts.zig");
/// Ticket triage: classify, draft a reply, gate it, write the outcome.
pub const ticket = @import("ticket.zig");
/// Refund flow with Saga-style compensation (execute → notify → compensate).
pub const refund = @import("refund.zig");
/// Risk review: SQL rules score a subject → approve / reject / escalate.
pub const risk = @import("risk.zig");
/// Reconciliation checks: diff a source SQL snapshot against a target one.
pub const recon = @import("recon.zig");
/// Multi-level approval chains decided by per-step policies.
pub const approval = @import("approval.zig");
/// Human approval queue plus its HTTP API for escalated runs.
pub const approval_api = @import("approval_api.zig");
/// SQL-backed approval queue, so escalations survive restarts.
pub const approval_store = @import("approval_store.zig");
/// LLM-backed default policies for the diagnosis/approval/risk flows.
pub const llm = @import("llm.zig");
/// Notification hub: webhooks, custom sinks, delivery fan-out.
pub const notify = @import("notify.zig");
/// Named KPI metrics (SQL → value) exposed to the `kpi.query` skill.
pub const kpi = @import("kpi.zig");
/// SLA deadlines on business items with escalating reminders.
pub const sla = @import("sla.zig");
/// Anomaly diagnosis: gather SQL evidence for a detected anomaly.
pub const diagnose = @import("diagnose.zig");
/// Outbox → workflow bridge: routes outbox events into `trigger` runs.
pub const bridge = @import("bridge.zig");

/// Retrieval interface for RAG context (bring your own embedding store).
pub const Retriever = @import("retriever.zig").Retriever;
/// One retrieved chunk: text, relevance score, and source metadata.
pub const RetrievedChunk = @import("retriever.zig").RetrievedChunk;
/// Keyword-matching retriever — works without embeddings.
pub const KeywordRetriever = @import("retriever.zig").KeywordRetriever;

/// Per-tenant token quota for multi-tenant AI chat and agents.
pub const TokenQuota = @import("quota.zig").TokenQuota;

/// Fast token estimate (~4 chars/token Latin, ~1.5 CJK); no allocation.
pub const estimateTokens = @import("tokenizer.zig").estimateTokens;
/// Token estimate for a whole chat history (message list).
pub const estimateMessages = @import("tokenizer.zig").estimateMessages;
