# 内置 AI Skills 规划与现状

> 从「AI 驱动业务框架」角度规划的内置 skill 目录。所有 skill 遵守受控执行
> 姿态：LLM 不写代码、白名单 + 人机门 + 配额 + 审计 + 租户隔离。

## 设计原则（每个内置 skill 都套这层壳）

| 机制 | 组件 | 默认行为 |
|------|------|----------|
| 租户隔离 | `SkillContext.tenant_id` | 实体查询自动追加租户条件（实体声明 `tenant_column` 时） |
| SQL 安全 | `validateSqlFragment` + 参数绑定 | `db.query` 仅 SELECT、禁止字面量/注释/`;`、行数上限 |
| 白名单 | 实体注册表 / allowlist | `entity.*` 只能访问注册实体；管理类 skill 默认不在 allowlist |
| 所有权 | `ai.freeValue` | 结果 JSON 由 ctx.allocator 持有，调用方可深释放 |
| 审计/配额 | AgentAuditLog / TokenQuota | 工具调用自动落审计、计配额 |

## P0 · 只读高价值（✅ 已落地）

`zigmodu.ai.business.registerBusinessSkills(registry, comptime entities)`
（DB 经 `SkillContext.backend_ptr` 指向 `*data.SqlxBackend`）：

| Skill | 说明 |
|-------|------|
| `db.query` | 只读参数化 SELECT；`?` 占位符 + args；行数上限（默认 20 / 上限 100）；拒绝非 SELECT 与自由字面量 |
| `entity.lookup` | 按主键查注册实体；白名单表名；配置 `tenant_column` 后自动按 `tenant_id` 过滤 |
| `entity.list` | 等值过滤 + 行数上限 + 租户隔离 |

调度闭环（`zigmodu.ai.registerScheduleSkills` + `ScheduleCtx`，`userdata` 传
`*ScheduleCtx`）：`list_schedulable_tasks` / `schedule_job` / `list_jobs` /
`cancel_job`。

## P0 · 业务技能（✅ 已落地）

| Skill | 说明 | 注册 |
|-------|------|------|
| `kpi.query` | 查询应用注册的经营指标（`KpiCtx` 按名 + 可租户隔离） | `ai.kpi.registerKpiSkills` |
| `approval.request` | 经应用注册的审批链提交审批（subject + amount），转人工入队 | `ai.approval_api.registerApprovalRequestSkills` |
| `notification.send` | 向具名渠道投递通知（webhook / sink / outbox），渠道白名单 | `ai.notify.registerNotifySkills` |

技能目录可导出：`zigmodu.ai.skill_export.toSkillsJson / toOpenApi`
（运行时，tenant-ai 暴露于 `GET /api/ai/skills`），或 `zmodu ai
export-skills / openapi`（CLI，内置目录）。

## P1 · 业务动作（✅ 已落地，默认人机门 + 幂等）

`zigmodu.ai.actions.registerWriteSkills / registerCommandSkills /
registerReportSkills`（`userdata` 传对应 Ctx；`SkillContext.permissions` 需含
权限码）：

| Skill | 说明 | 权限 |
|-------|------|------|
| `entity.create/update` | 白名单实体写操作；仅可写列白名单（`EntitySpec.writable`）、租户列由上下文强制（模型不可传）、主键禁止 | `entity:write` |
| `command.execute` | 经事务性 outbox 提交应用注册命令；幂等键 = `SkillContext.run_id`（缺失拒绝），返回 event_id | `command:execute` |
| `report.generate` | 应用注册聚合查询 → CSV / JSON（行数上限 100，只读） | — |

## P2 · 管理/运维（规划中，默认关闭）

`admin.user.manage` / `admin.tenant.provision` / `admin.cache.invalidate`（禁通配）/
`admin.config.get/set` / `audit.export`。

## 配套增强（✅ 已落地）

- `Tool.required_permission`：dispatch 层按权限码校验（`error.PermissionDenied`）。

## 边界（不做）

不内置 shell / 任意 URL 抓取 / 裸 SQL 写 / 跨租户访问；管理类 skill 必须显式
加入 allowlist。
