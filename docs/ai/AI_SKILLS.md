# Built-in AI Skills

The skill catalog an agent can call, and the guard rail each skill runs under: the model never writes code, and every skill sits behind an allowlist, permission codes, quotas, audit and tenant isolation.

For how a tool is allowed to run, read [`AGENT_RUNTIME.md`](../reference/AGENT_RUNTIME.md): `ai.Guard` is already wired into `Agent.run`, `skill.Tool.action` defaults to `.execute`, and `ai.AgentWorker` / `ai.ProposalPipeline` cover background execution and staged approval.

## Design rules

| Mechanism | Component | Default behaviour |
|-----------|-----------|-------------------|
| Tenant isolation | `SkillContext.tenant_id` | Entity queries filter on the declared `tenant_column`; `db.query` is wrapped by the framework with `WHERE <col> = ?`, which requires `BusinessSkillsConfig.db_query_tenant_column` (otherwise `error.TenantScopeUnavailable`) |
| SQL safety | `validateSqlFragment` + bound parameters | `db.query` accepts SELECT only, rejects literals, comments and `;`, and caps rows |
| Allowlist | Entity registry / allowlist | `entity.*` reaches registered entities only; admin skills are excluded by default |
| Ownership | `ai.freeValue` | Result JSON is owned by `ctx.allocator`; the caller deep-frees |
| Audit and quota | `AgentAuditLog` / `TokenQuota` | Tool calls are audited and metered automatically |

## Action classes and the guard

Every skill declares `action` (`guard.Action`), the class axis of `ai.Guard`. A skill that declares nothing is `.execute`, the strictest class, and can never pass a policy with `allow_execute = false`.

| Class | Built-in skills | Why |
|-------|-----------------|-----|
| `read` | `db.query`, `entity.lookup`, `entity.list`, `kpi.query`, `report.generate`, `admin.config.get`, `admin.audit.export`, `list_schedulable_tasks`, `list_jobs` | Reads data, changes nothing |
| `propose` | `notification.send`, `approval.submit`, `approval.request` | Hands work to someone else (a channel or an approval chain) |
| `execute` | `entity.create`, `entity.update`, `command.execute`, `schedule_job`, `cancel_job`, `admin.cache.invalidate`, `admin.cache.clear`, `admin.config.set`, `admin.user.manage`, `admin.tenant.provision` | Changes state: needs `allow_execute = true` and the tool name |

So `allow = &.{ "db.query", "kpi.query" }` with `allow_execute = false` lets an agent read data and change nothing; read tools are unaffected by that switch. The two delegated admin skills have unknown effects and stay in `execute` by design. Custom skills follow the same rule: no declaration means `execute`.

`Guard` sees names, not classes. A policy whose `allow` list contains only `execute` tools still reports `isInert() == false` while permitting nothing. Check at startup with `registry.auditPolicy(allocator, guard.permissions)` or `AgentSpec.auditPolicy`; `class_denied_tools` lists tools rejected by class rather than by name. See [`AGENT_RUNTIME.md`](../reference/AGENT_RUNTIME.md) §1.

```zig
var guard = ai.Guard.init(.{
    .allow = &.{ "db.query", "kpi.query" }, // names the policy may call
    .allow_execute = false,                 // and no execute-class tool at all
});
var spec = ai.AgentSpec{
    .name = "analyst",
    .provider = &provider,
    .skills = &registry,
    .guard = &guard,
};

const health = try spec.auditPolicy(allocator); // null when no guard is set
defer if (health) |*h| h.deinit(allocator);
// health.class_denied_tools: listed names the class gate still refuses
```

## Read-only data skills

`zmodu.ai.business.registerBusinessSkills(registry, comptime entities)` registers the data skills; `SkillContext.backend_ptr` carries a `*data.SqlxBackend`.

Multi-tenant apps must use the explicit entry point. The default leaves `db_query_tenant_column` as `null`, so any `db.query` with a `tenant_id` fails closed with `error.TenantScopeUnavailable`.

```zig
try ai.business.registerBusinessSkillsWith(&registry, &.{}, .{
    .db_query_tenant_column = "tenant_id", // the column name in your schema
});
```

| Skill | Behaviour |
|-------|-----------|
| `db.query` | Read-only parameterized SELECT with `?` placeholders and args; row cap (default 20, maximum 100); rejects non-SELECT statements and free literals. With a tenant, the framework wraps the statement as `SELECT * FROM (<your SQL>) AS _zt_tenant_scope WHERE _zt_tenant_scope.<col> = ?` and binds the tenant as a parameter only. Your SELECT must therefore select the tenant column, or the wrapper fails with "no such column" |
| `entity.lookup` | Look up a registered entity by primary key; table names are allowlisted; `tenant_column` adds the tenant filter automatically |
| `entity.list` | Equality filters, row cap and tenant isolation |

Scheduling skills (`zmodu.ai.registerScheduleSkills` with `*ScheduleCtx` in `userdata`): `list_schedulable_tasks`, `schedule_job`, `list_jobs`, `cancel_job`.

## Business skills

| Skill | Behaviour | Registration |
|-------|-----------|--------------|
| `kpi.query` | Query an application-registered metric by name (`KpiCtx`). A dispatch carrying `tenant_id` runs only `KpiMetric.tenant_sql` (single `?` tenant bind); without a declared tenant query it refuses rather than returning an unfiltered value | `ai.kpi.registerKpiSkills` |
| `approval.request` | Submit an approval through the application-registered chain (`subject` + `amount`); escalations enter the human queue. Requires `approval:decide` | `ai.approval_api.registerApprovalRequestSkills` |
| `notification.send` | Deliver to a named channel (webhook, sink or outbox), channel allowlist enforced | `ai.notify.registerNotifySkills` |

Export the catalog with `zmodu.ai.skill_export.toSkillsJson` / `toOpenApi` (an application can expose them as HTTP endpoints), or from the CLI with `zmodu ai export-skills` / `zmodu ai openapi`.

## Write actions

`zmodu.ai.actions.registerWriteSkills`, `registerCommandSkills` and `registerReportSkills` pass the matching context through `userdata`; `SkillContext.permissions` must carry the permission code.

| Skill | Behaviour | Permission |
|-------|-----------|------------|
| `entity.create` / `entity.update` | Writes to an allowlisted entity and allowlisted columns (`EntitySpec.writable`); the tenant column is forced from context and the model cannot supply it; primary keys are rejected | `entity:write` |
| `command.execute` | Submits an application-registered command through the transactional outbox; the idempotency key is `SkillContext.run_id` (missing run id is rejected); returns the event id | `command:execute` |
| `report.generate` | Runs an application-registered aggregation report as CSV or JSON, capped at 100 rows, read-only | none |

## Admin and ops skills

`zmodu.ai.admin.registerAdminSkills` takes `*AdminCtx` through `userdata`. Permission codes are `admin:cache`, `admin:config`, `admin:audit`, `admin:user` and `admin:tenant`, and every admin skill must be added to the agent allowlist explicitly.

| Skill | Behaviour |
|-------|-----------|
| `admin.cache.invalidate` / `admin.cache.clear` | Allowlisted caches; keys reject wildcards (`*`, `?`), and a full clear requires `all=true` |
| `admin.config.get` / `admin.config.set` | Allowlisted config; `set` is limited to mutable keys (`ConfigStore`) |
| `admin.audit.export` | Query `RunAuditStore` with optional kind, tenant and limit filters |
| `admin.user.manage` / `admin.tenant.provision` | Delegate to application callbacks; the framework does not implement user or tenant logic |

## Custom skills

Business skills use the same `Tool` contract as built-ins: parameters map to JSON Schema, results are owned by `ctx.allocator` (callers use `ai.freeValue`), `required_permission` plus an allowlist narrow access, and `checkDeadline` provides the cooperative timeout.

Templates and selection guidance (Agent, Workflow, LLM policy, MCP bridge): [`AI_DEV_GUIDE.md`](./AI_DEV_GUIDE.md) §3–§5.

## Boundaries

No shell, arbitrary URL fetching, raw SQL writes or cross-tenant access. Admin skills are reachable only after an explicit allowlist entry.
