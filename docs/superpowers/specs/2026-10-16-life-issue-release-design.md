# Life：内置 issue + release 版本管理系统设计 spec

> 日期：2026-10-16 · 状态：已获原则批准（命名 `life` / 方案 C 双适配器 / 公布出口：静态 feed + Dashboard feed）
> 定位：**v1.x 候选**（1.0-alpha 功能冻结期不动代码，本 spec 先行；冻结解除后按 Phase 落地）
> 参考：heysen_saas 生产实践（feedback + release_note 模块）+ zigmodu 现有接口面（`zmodu life` CLI、双通道 MCP、audit/CI JSON、Dashboard）

## 1. 背景与目标

后 AI 时代的协同本质：**agent 是第一等公民，但彼此之间不信任**。代码主要由 AI agent 开发，测试 agent、用户反馈入口、修复 agent 需要在同一事实源上自动化协同与跟踪，且系统进化要能向用户公布。

最小充分集：

1. 机器可读的单一事实源（机器可读优先，人工渲染其次）；
2. 服务端强制的状态机，含「修 ≠ 判」的结构隔离；
3. 确定性发布闭环（issue → 修复 → 向用户公布），AI 只做归类/润色、永不造事实。

## 2. 范围

**做**：issue 全生命周期、release 草稿/发布、CI 证据自动开单、双适配器（file + module）、公布出口（静态 feed + Dashboard feed）、MCP/CLI 双 agent 接口。

**不做（YAGNI，明确拒绝）**：通知系统内置（只发事件，应用自接）；双编号对账；自动相似度去重（只做 fingerprint 精确去重）；业务裁定体系（P0–P3 时限表等）；Web 管理后台 UI（只给最小 HTML 列表）；邮件/RSS 订阅管理；多仓库联邦。

## 3. 总体架构

```
zmodu.life core（纯 Zig，无 IO 依赖）
  ├─ 状态机 + 迁移校验（先校验流转、再校验必填字段、失败不改数据）
  ├─ ID 方案 / reproBlock 构造 / since 窗口圈定 / fingerprint 去重
  │
  ├─ file adapter（Phase 1）
  │    .life/issues/LI-0042.md（frontmatter + body + Repro 段）
  │    zmodu life issue|release 子命令（与既有 tree/fingerprint/evolve 并列）
  │    → 仓库级 agent 无 app 可用；git 即审计链
  │
  └─ module adapter（Phase 2）
       src/modules/life/（model/persistence/service/api/module 五文件，tenant-mgmt 骨架）
       ComptimeRouter routes + 权限码 + MCP skills + Dashboard feeds
       → 运行中应用收用户反馈、Dashboard 公布
```

两个适配器共享同一 core：**同一状态机、同一 ID（`LI-<seq>`）、同一校验器**，不会长成两个系统。

## 4. core 设计（无 IO）

### 4.1 状态机

```
new → triaged → confirmed → fixed → verified → closed ✗终态
       │  └→ needs_info ───────→（回到 triaged）
       ├→ duplicate ✗终态（必填 linked_id）
       └→ rejected  ✗终态（必填 internal_note）

confirmed 的额外出路：confirmed → rejected ✗终态（internal_note, life:triage）、
confirmed → triaged（回滚，internal_note, life:triage）
```

迁移表（必填字段由校验器强制；**先校验流转合法性，再校验必填字段，全部通过才落盘**）：

| 迁移 | 必填字段 | 所需权限码 |
|---|---|---|
| new → triaged | assignee | `life:triage` |
| triaged → confirmed | — | `life:triage` |
| triaged → needs_info | internal_note | `life:triage` |
| needs_info → triaged | — | `life:triage` |
| triaged → duplicate（终态） | linked_id | `life:triage` |
| triaged → rejected（终态） | internal_note | `life:triage` |
| confirmed → rejected（终态） | internal_note | `life:triage` |
| confirmed → triaged（回滚） | internal_note | `life:triage` |
| confirmed → fixed | resolution + fix_ref | `life:fix` |
| fixed → verified | — | `life:verify` |
| fixed → confirmed（回滚） | internal_note | `life:fix` |
| verified → closed（终态） | — | `life:triage` |
| verified → fixed（回滚） | internal_note | `life:verify` |

**修 ≠ 判的结构强制**：`fixed` 只能由持 `life:fix` 者推进，`verified` 只能由持 `life:verify` 者推进——测试 agent 与修复 agent 各持其一，结构上谁也替谁下不了结论。部署指引：两类 token 不并授同一主体；`zmodu audit` 规则 **b27**（Phase 2）拦「同一 role 同时授 `life:fix` + `life:verify`」。

### 4.2 其他 core 件

- **ID**：`LI-<seq>`（每 store 单调递增；file adapter 扫描 `.life/issues/LI-*.md` 文件名派生 max+1——**无计数文件**，无状态可腐化，`sync` 校验连续性；module 用 AUTOINCREMENT + `public_id` UNIQUE）。
- **reproBlock**：`{version, git_sha, route?, platform?, command?, output_excerpt?}`（key:value 行格式，file 形态为 body 末尾 `## Repro` 段；module 形态为 `context` JSON 列）。CI 来源自动填充，用户提交时由调用方附带。
- **fingerprint 去重**：`sha256(source|rule|normalized_message|file)`，仅 `source ∈ {ci, bench, stress}` 使用；命中同 fingerprint 且未关闭的 issue → 追加 comment（带新出现的 sha/输出），不开新单。
- **since 圈定**：release 草稿默认 `since_at = 上一条 published 的 published_at`，圈定窗口内 `status ∈ {fixed, verified, closed}` 的 issue 进入 items。

## 5. 数据模型

### 5.1 file 形态

`.life/issues/LI-0042.md`：

```markdown
---
id: LI-0042
title: runtime-stress ready_push_failures gate tripped
status: new
category: bug
priority: P1
source: stress
reporter: agent:ci
assignee: ""
created_at: 2026-10-16T08:00:00Z
updated_at: 2026-10-16T08:00:00Z
resolution: ""
fix_ref: ""
linked_id: ""
internal_note: ""
fingerprint: "sha256:9f2c…"
---

正文 markdown。

## Repro
version: 0.39.13
git_sha: 13fed68
command: zig build runtime-stress
output_excerpt: "ready_push_failures=3 (gate 0)"
```

frontmatter 用**自写极简行解析器**（`key: value` 单行行，无 YAML 依赖，保零依赖足迹）。`.life/releases/v0.39.14.md` 同构（items 为 JSON 行）。

### 5.2 SQL 形态（module adapter，三方言通用）

```sql
CREATE TABLE life_issue (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  public_id TEXT NOT NULL UNIQUE,        -- LI-42
  title TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  category TEXT NOT NULL DEFAULT 'bug',  -- bug|feat|perf|ux|docs|other
  source TEXT NOT NULL DEFAULT 'user',   -- user|agent|ci|bench|stress
  status TEXT NOT NULL DEFAULT 'new',
  priority TEXT NOT NULL DEFAULT 'P2',   -- P0|P1|P2|P3
  reporter TEXT NOT NULL DEFAULT '',
  assignee TEXT NOT NULL DEFAULT '',
  context TEXT NOT NULL DEFAULT '',      -- JSON reproBlock
  resolution TEXT NOT NULL DEFAULT '',
  fix_ref TEXT NOT NULL DEFAULT '',      -- 可核验部署标识（git sha / 版本）
  linked_id TEXT NOT NULL DEFAULT '',
  internal_note TEXT NOT NULL DEFAULT '',
  fingerprint TEXT NOT NULL DEFAULT '',
  tenant_id TEXT NOT NULL DEFAULT '',    -- 标准租户列（comptime 强制，走 zent/sqlx 均自带过滤）
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
-- fingerprint 去重：SQLite/PG 用部分唯一索引
--   CREATE UNIQUE INDEX life_issue_fp ON life_issue(fingerprint) WHERE fingerprint <> '';
-- MySQL 无部分索引：不建该索引，去重由 service 层先 SELECT 判定（fingerprint 非空才查），
-- 应用层判空保证并发下正确性要求由事务/唯一冲突双保险承担（MySQL 侧冲突时降级为 comment）。

CREATE TABLE life_release (
  version TEXT PRIMARY KEY,              -- v0.39.14
  title TEXT NOT NULL,
  summary TEXT NOT NULL DEFAULT '',
  items TEXT NOT NULL DEFAULT '[]',      -- [{kind,scope,text,issueIds}]
  status TEXT NOT NULL DEFAULT 'draft',  -- draft|published|archived
  audience TEXT NOT NULL DEFAULT 'public', -- public|internal
  source TEXT NOT NULL DEFAULT 'auto',   -- auto|manual
  since_at INTEGER NOT NULL DEFAULT 0,
  published_at INTEGER,
  git_sha TEXT NOT NULL DEFAULT ''
);
```

## 6. 适配器 A：file + CLI（Phase 1）

`zmodu life` 现有 `tree|fingerprint|evolve` 保留，新增：

```
zmodu life issue new --title T [--category C] [--priority P] [--source S]
                     [--reporter R] [--body-file F] [--fingerprint FP]
zmodu life issue list [--status S] [--source S] [--category C] [--json]
zmodu life issue show LI-42
zmodu life issue transition LI-42 <target> [--assignee A] [--resolution R]
                     [--fix-ref F] [--linked-id ID] [--note N] [--by AGENT]
zmodu life issue comment LI-42 --body B [--by AGENT]
zmodu life release draft <version> [--since <tag>]   # 默认 dry-run，打印到 stdout
zmodu life release publish <version> [--feed-dir <dir>]  # 落 life.json + atom.xml
zmodu life sync   # 重建索引/一致性自检（seq 连续性、frontmatter 可解析、状态合法）
```

所有变更类子命令走同一 core 校验器；`--by` 记操作者（agent:xxx / 人名）进 comment 审计段。

**CI 钩子**：`zmodu ci --life`（或 `ZMODU_LIFE=1`）——任一门禁失败时按 fingerprint 去重自动 `issue new --source ci`（reproBlock 带 sha、命令、输出摘要）。`check-bench` / `runtime-stress trend` 由各自的 record 脚本以同样方式喂入（source=bench / stress）。

## 7. 适配器 B：module（Phase 2）

五文件骨架照 `examples/tenant-mgmt/src/modules/user/`。routes（ComptimeRouter）：

```
POST /api/life/issues                  # public 或 jwt；限流 10min/3；Idempotency 中间件幂等
GET  /api/life/issues                  # list + 过滤
GET  /api/life/issues/{id}
POST /api/life/issues/{id}/transition  # handler 内按目标迁移查权限码（4.1 表）
POST /api/life/issues/{id}/comments
GET  /api/life/releases                # audience 过滤：未授权只见 public
GET  /api/life/releases/{version}
GET  /api/life/feed.json
GET  /api/life/atom.xml
```

- **权限**：`life:triage / life:fix / life:verify / life:manage` 四码；transition 端点按目标迁移所需码 `requirePermission`。用户提交端点零权限 + 限流 + 幂等。
- **MCP skills**（应用侧 SkillRegistry 注册即成 tools）：`life.issue.create`（propose）、`life.issue.list/get`（read）、`life.issue.transition`（propose + required_permission）、`life.issue.comment`（propose）、`life.release.draft`（propose）、`life.release.publish`（execute + `life:manage`）。
- **CLI MCP**（`zmodu mcp`）加 `zmodu_life_issue_new/transition/list/comment`、`zmodu_life_release_draft/publish`，操作 file adapter（仓库级 agent 通道）。
- **Dashboard**：`DataSource` 增可选 `life` 源；feeds `api/dashboard/life/issues`、`api/dashboard/life/releases`；`/dashboard/life` 最小 HTML 列表；**未接线诚实返回空**（沿用 Dashboard.zig 现有纪律）。WebMonitor 的占位 health/metrics 是已知缺口，不做数据源。

## 8. 发布闭环与公布出口

```
issue fixed（带 fix_ref）→ verified → closed
        │
        ▼ since = 上一条 published_at
zmodu life release draft <version>     # 确定性：CHANGELOG 段解析 + 窗口内 closed issue 圈定
        │                              # 可选 LLM 润色：白名单校验、失败退回确定性草稿
        ▼
draft → publish                        # published 不可变；要改 = archive 重发
        │
        ├─→ ① 静态 feed：life.json + atom.xml（--feed-dir，zdoc 站点消费）
        ├─→ ② Dashboard feeds（应用内）
        └─→ ③ EventBus 事件 life.release.published（站内通知/webhook 应用自接，框架不内置）
```

**AI 纪律**（与 `docs/ai/LLM_POLICIES.md` 一致）：事实一律确定性生成（文件解析 / SQL）；AI 只归类与润色；结构化输出白名单校验、不合规即降级；失败/超时永不阻塞、永不返回 5xx、**输入没有的内容一个字都不写**。

## 9. 与现有机制的关系

- `scripts/release.sh` 仍是**唯一发版权威**，本系统不碰版本切割；`life release` 只做消费与公布（数据源 = git tag + CHANGELOG 段 + issue 表）。
- `zmodu life` 既有 `tree/fingerprint/evolve`（`.life/tree/<version>.md`）保留并列；本系统的 `.life/issues/`、`.life/releases/` 与之间无冲突。
- `zmodu audit` 增规则 **b27**（Phase 2）：同一 role 并授 `life:fix` + `life:verify` 报 violation。
- 租户：module 形态走标准 `tenant_id` 列，comptime 强制 + Repository 过滤免费获得；file 形态单租户（仓库自身即单租户）。

## 10. 分期落地与验收

| Phase | 内容 | 验收 |
|---|---|---|
| **P1** ✅ 2026-10-16 | core（状态机/校验/ID/reproBlock/since/fingerprint）+ file adapter + CLI 子命令 + CI 钩子 | 已落地（批 182）：core 单测 4 项（迁移矩阵/必填字段/修≠判权限拆分/fingerprint）、CLI 11 项 tmpDir 集成测试（生命周期/转换校验/CI 去重/release 窗口与不可变/feed/sync）+ 临时目录端到端冒烟；seq 按扫描派生实现（§4.2 已回填此偏差） |
| **P2** | module adapter（SQL/routes/权限/MCP/Dashboard）+ audit b27 | tenant-mgmt 示例接线最小演示路由；Testkit 断言：持 `life:fix` 的 token 推不动 verified（结构强制实测）；audience 过滤越权 404；published 不可变 |
| **P3** | 公布出口完善：atom/JSON feed + webhook 示例（examples/ 一个 life-feed 演示） | feed 通过 zdoc 渲染验证；webhook 示例 e2e 收到 `life.release.published` |

## 11. 测试策略

- core：纯 Zig 无 IO，单测全覆盖（含上面验收矩阵）；错误集窄化。
- file adapter：tmpDir 集成测试（new/transition/comment/draft/publish/sync 全链路 + 并发写拒绝）。
- module：Testkit dispatch（权限矩阵 + 越权 + 幂等 + 限流）+ `openMemorySqlite` 持久化测试。
- CI 钩子：脚本级测试喂伪造门禁失败输出，断言 issue 落库 + 重复指纹只加 comment。

## 12. 风险与决策记录

| 决策 | 选择 | 理由 |
|---|---|---|
| 单编号 vs heysen 双编号 | 单编号 `LI-*` + `linked_id` | 双轨对账是外部测试团队约束，框架内置是账本负担 |
| 修≠判强制级别 | 权限码结构强制 + b27 审计 | 纯流程纪律（heysen SOP）在 agent 规模下不可靠 |
| 通知系统 | 只发 EventBus 事件 | YAGNI；heysen 的站内通知是应用级设施 |
| 存储 | SQLite 默认（module）/ markdown 文件（file） | 零新依赖；与框架"零依赖足迹"纪律一致 |
| 落地时机 | v1.x（冻结期 spec 先行） | 1.0-alpha 功能冻结纪律 |
