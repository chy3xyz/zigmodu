# zsaas — SaaS 业务框架（zigmodu 后端 + saas-solidjs 前端）

快速开发多租户业务系统：**一份业务模型 JSON，同时生成两端**——

- **后端**：`zmodu saas <model.json>` 生成 zigmodu 业务模块（Zig），严格按
  zigmodu 最佳实践（分层 model/persistence/service/api、参数化 SQL、org 租户
  隔离、ComptimeRouter + `.auth = .jwt` + permission 门控、`ctx.json`）；
- **前端**：`node zsaas/scripts/gen-business.mjs <model.json> <dir>` 生成
  SolidStart 管理端页面（列表/表单 + API client），走 **zigmodu REST API**
  （`/api/v1/<entity>`），不重复造 Drizzle 后端层。

## 技术栈

| 端 | 选型 |
|---|------|
| 后端 | **zigmodu**（Zig）：多租户、JWT/RBAC、sqlx 参数化查询、outbox、审计、AI 技能 |
| 前端 | [zsaas-start](https://github.com/chy3xyz/saas-solidjs)：SolidStart SSR + SolidJS + Kobalte/Tailwind v4 + cookie 会话 + org RBAC + Stripe/Resend + en/zh i18n |

## 一份模型 → 两端

```json
{ "entities": [ {
    "name": "orders", "label": "Orders", "description": "Customer orders",
    "writeRole": "admin",
    "fields": [
      { "name": "customer", "type": "string", "required": true },
      { "name": "amount", "type": "number" },
      { "name": "status", "type": "string", "default": "pending" }
    ]
} ] }
```

字段类型：`string` / `text` / `number` / `boolean` / `date`。`writeRole`
控制写操作权限（member 或 admin，映射到 `<entity>:write` permission）。

## 快速开始

```bash
# 方式 A — 一键新建前后端工程（推荐）
node zsaas/scripts/create-project.mjs orders.model.json \
  --name mysaas --backend ./mysaas-backend --frontend ./mysaas-frontend
#   → zigmodu 后端工程（zmodu new + zmodu saas 业务模块，可直接 zig build）
#   → saas-solidjs 前端工程（模板复制 + 业务页面，npm install && npm run dev）

# 方式 B — 已有工程，只生成业务模块
# 1. 后端：生成 org 隔离的 zigmodu 模块（含 saas-schema.sql 迁移）
zmodu saas orders.model.json --out src/modules
#    在 main.zig 按 ROUTE_TABLE §7 挂载：jwtAuthFromCatalogWithPermissions +
#    permissionGateWith(.rbac) + Router.scope.mountAll，并用 saas-schema.sql 建表

# 2. 前端：生成 SolidStart 管理页面 + REST client
node zsaas/scripts/gen-business.mjs orders.model.json <saas-solidjs-dir>
cd <saas-solidjs-dir> && npm run dev   # /dashboard/orders
```

前端经 `src/libs/zmoduApi.ts` 的 `zmoduFetch` 调 zigmodu：请求带
`Authorization: Bearer <token>`（dev 用 `ZMODU_API_TOKEN` 环境变量；生产由
SolidStart 会话换发 zigmodu JWT），后端从 JWT 取 `tenant_id` 做行级隔离。

## 后端生成模块（zigmodu 最佳实践）

```
src/modules/<entity>/
├── model.zig          # 行类型（org_id + 审计列）
├── persistence.zig    # 参数化 SQL，全部 WHERE org_id = ?（租户强制）
├── service.zig        # 校验 + CRUD（读传租户，写强制 org_id）
├── api.zig            # ComptimeRouter：GET/POST /{id} PUT/DELETE，
│                      #   .meta = .{ .auth = .jwt, .permission = "<e>:read|write" }
├── module.zig         # pub const info + 生命周期
└── root.zig           # barrel
```

REST 契约：`GET /api/v1/<entity>?page&size` → `{code,items,total}`；
`GET/PUT/DELETE /api/v1/<entity>/{id}`；`POST /api/v1/<entity>`。

## 安全默认

- 后端：每张表 `org_id`，读写都按 JWT `tenant_id` 过滤；路由 `.auth = .jwt`
  + permission 门控；参数化 SQL（无注入面）；
- 前端：写操作 `guardForm`（CSRF）+ `requireOrgMember(writeRole)`；
  会话/密码/Stripe/邮件全部复用基座实现。

## 验证

- `node zsaas/scripts/check-gen.mjs` — 前端生成器自检（产物结构 + zmoduFetch 接线）；
- 生成的前端在真实 saas-solidjs 工程 `tsc --noEmit` 通过；
- 生成的后端模块在真实 zigmodu 工程 `zig build test` 编译通过。

## 扩展

- 更多字段类型/关联 → 扩展 `zmodu saas` 的 `emit*` 模板与前端 `actionsTpl`；
- 业务校验 → 后端 `service.validate`、前端动作里加 zod；
- 报表/搜索 → 后端 persistence 加查询函数 + 前端列表页接入。
