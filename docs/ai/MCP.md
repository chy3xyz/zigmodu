# SkillRegistry to MCP Bridge (`zmodu.ai.mcp`)

`zmodu.ai.mcp` exposes a `SkillRegistry` as a **Model Context Protocol (MCP)** stdio server so external LLM hosts (such as Claude Desktop, Cursor, or Codex) can discover and invoke zmodu skills (`db.query`, `kpi.query`, `approval.request`, `entity.create`, etc.).

> Note: `zmodu mcp` in the CLI is the code-generation MCP server for project scaffolding. `zmodu.ai.mcp` is the runtime library bridge for your application's `SkillRegistry`.

## 1. Quick Start

```zig
const ai = zmodu.ai;

// 1. Register business, KPI, and action skills
var registry = ai.SkillRegistry.init(allocator, io);
defer registry.deinit();

// Multi-tenant applications MUST declare `db_query_tenant_column` so `db.query`
// scopes queries to `ctx.tenant_id` (otherwise it fails closed with `error.TenantScopeUnavailable`).
try ai.business.registerBusinessSkillsWith(&registry, &.{}, .{
    .db_query_tenant_column = "tenant_id",
});
try ai.kpi.registerKpiSkills(&registry);
try ai.actions.registerWriteSkills(&registry);

// 2. Define the session identity and permissions applied to every MCP tool call
const perms = [_][]const u8{"entity:write"};
const ctx = ai.SkillContext{
    .allocator = allocator,
    .tenant_id = 1,
    .permissions = &perms,
};

// 3. Start the stdio MCP server
try ai.mcp.serveStdio(io, allocator, &registry, ctx);
```

Runnable example: [`examples/mcp-server`](../../examples/mcp-server):

```bash
cd examples/mcp-server && zig build
cd ../.. && python3 scripts/mcp-client-test.py examples/mcp-server/zig-out/bin/mcp-server
```

## 2. Supported MCP Methods

- `initialize`: Negotiates protocol version (`2024-11-05`) and advertises `capabilities.tools`.
- `tools/list`: Exports registered skills (`name`, `description`, and JSON `inputSchema` derived from `Tool.parameters`), filtered by the session's permissions.
- `tools/call`: Dispatches the tool call through `SkillRegistry.dispatch` and returns the JSON result as text content.

## 3. Security & Tenant Isolation

- **Permission filtering on `tools/list` and `tools/call`**: `serveStdio` only advertises skills that `ctx_template.permissions` is authorized to call, and `SkillRegistry.dispatch` enforces `Tool.required_permission` on every `tools/call` (`error.PermissionDenied`). For custom filtering, call `serveStdioFiltered(io, allocator, &registry, ctx_template, .{ .allowlist = ..., .permissions = ... })`.
- **Tenant isolation**: `ctx_template.tenant_id` is passed to every skill invocation. `entity.*` skills filter by the entity's `tenant_column`, and `db.query` wraps the query with `BusinessSkillsConfig.db_query_tenant_column` (failing closed with `error.TenantScopeUnavailable` if `tenant_id` is set without a configured column).

## 4. Programmatic API

- `ai.mcp.toMcpTools(registry, allocator)`: Renders the unfiltered MCP `tools/list` JSON payload.
- `ai.mcp.handleToolCall(registry, ctx, params)`: Executes a single `tools/call` request.
- `ai.mcp.serveStdio(io, allocator, registry, ctx_template)`: Runs the stdio JSON-RPC loop with permission filtering.
- `ai.mcp.serveStdioFiltered(io, allocator, registry, ctx_template, filter)`: Runs the stdio loop with explicit allowlist and permission filters.
