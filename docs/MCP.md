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
try ai.business.registerBusinessSkills(&registry, &.{});
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

## MCP 方法

- `initialize` → 协议版本 + `capabilities.tools`；
- `tools/list` → 技能目录（name / description / inputSchema，参数从注册表推导）；
- `tools/call` → 分发到 `SkillRegistry.dispatch`，结果以文本 content 返回。

## 安全

- 技能保留 `required_permission` 门控：MCP 会话的 `SkillContext.permissions`
  决定可调用的管理/审批技能；
- `admin.*` 技能默认不在任何 allowlist，需要显式加入才会出现在 `tools/list`；
- 租户隔离：`ctx_template.tenant_id` 贯穿所有分发。

## 编程接口

- `ai.mcp.toMcpTools(registry, allocator)` — MCP `tools/list` payload；
- `ai.mcp.handleToolCall(registry, ctx, params)` — 单次 `tools/call` 分发；
- `ai.mcp.serveStdio(io, allocator, registry, ctx_template)` — stdio server。

> zmodu CLI 的 `zmodu mcp` 是 CLI 自身工具的 MCP server；本桥用于**应用侧**
> 把运行时技能暴露给外部 LLM 平台。
