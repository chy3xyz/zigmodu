# SkillRegistry → MCP 桥

把 zigmodu 的 AI 技能注册表暴露为 **Model Context Protocol** 工具——Claude /
Codex 等 LLM 平台可直接通过 MCP 调用框架技能（`db.query`、`kpi.query`、
`approval.request`、`entity.create`、`admin.*` 等）。

## 快速接入

```zig
const ai = zigmodu.ai;

// 1. 注册技能（业务/审批/KPI/管理…）
var registry = ai.SkillRegistry.init(allocator, io);
defer registry.deinit();
// 多租户（下面 ctx.tenant_id 有值）必须用 With 入口并声明租户列，否则
// db.query 会 fail-closed 返回 error.TenantScopeUnavailable。
// 单租户应用可以用 registerBusinessSkills(&registry, &.{})。
try ai.business.registerBusinessSkillsWith(&registry, &.{}, .{
    .db_query_tenant_column = "tenant_id",
});
try ai.kpi.registerKpiSkills(&registry);
try ai.actions.registerWriteSkills(&registry);

// 2. 会话身份（租户/用户/权限）——MCP 会话内的每次分发都带这组身份
const perms = [_][]const u8{"entity:write"};
var ctx = ai.SkillContext{
    .allocator = allocator,
    .tenant_id = 1,
    .permissions = &perms,
};

// 3. 起 stdio MCP server（LLM 平台配置为本地 MCP 服务器）
try ai.mcp.serveStdio(io, allocator, &registry, ctx);
```

完整可运行示例见 `examples/mcp-server`（KPI 技能 + SQLite 内存库 + ping），
本地冒烟：

```bash
cd examples/mcp-server && zig build
cd ../.. && python3 scripts/mcp-client-test.py examples/mcp-server/zig-out/bin/mcp-server
```

客户端脚本会跑真实 stdio MCP 会话：`initialize`（协议 2024-11-05）→
`tools/list` → `tools/call kpi.query`（断言 tenant 1 的 SUM=5100）→
`tools/call ping`（"pong"），并校验服务端零泄漏。

## MCP 方法

- `initialize` → 协议版本 + `capabilities.tools`；
- `tools/list` → 技能目录（name / description / inputSchema，参数从注册表推导）；
- `tools/call` → 分发到 `SkillRegistry.dispatch`，结果以文本 content 返回。

## 安全

- 技能保留 `required_permission` 门控：MCP 会话的 `SkillContext.permissions`
  决定可调用的管理/审批技能 —— 拒绝发生在 `tools/call`（`SkillRegistry.dispatch`），**不在** `tools/list`；
- **`tools/list` 不过滤**：`ai.mcp.toMcpTools` 列出注册表里的**全部**技能（含 `admin.*`）。
  按 allowlist / 权限裁剪 `tools/list` 目前**是缺口，不是既有能力** —— 要藏管理类技能，
  只能先别把它们注册进暴露给 MCP 的那个 registry；
- 租户隔离：`ctx_template.tenant_id` 贯穿所有分发。**但隔离由各个技能自己落实** ——
  `entity.*` 看实体声明的 `tenant_column`，`db.query` 看 `BusinessSkillsConfig.db_query_tenant_column`。
  有 `tenant_id` 而没声明列时 `db.query` 是 **`error.TenantScopeUnavailable`（拒绝，不是不过滤）**：
  上面快速接入里的 `registerBusinessSkillsWith` 就是这个原因。

## 编程接口

- `ai.mcp.toMcpTools(registry, allocator)` — MCP `tools/list` payload；
- `ai.mcp.handleToolCall(registry, ctx, params)` — 单次 `tools/call` 分发；
- `ai.mcp.serveStdio(io, allocator, registry, ctx_template)` — stdio server。

> zmodu CLI 的 `zmodu mcp` 是 CLI 自身工具的 MCP server；本桥用于**应用侧**
> 把运行时技能暴露给外部 LLM 平台。
