# ZigModu × zmodu CLI 工具集成与代码生成指南

`zmodu` 是专为 `ZigModu` 框架定制的高性能 CLI 代码生成器（独立工程位于 `w4_proj/zig_ws/zmodu`）。它支持直接解析 SQL DDL/Schema 或点对点反向工程数据库，一键产出符合 [`docs/MODULE_LAYERS.md`](MODULE_LAYERS.md) 六层架构契约的工程代码骨架。

---

## 核心特性与架构模式

1. **`@initialized` 开发模型**：生成的代码文件头部带有 `//! @initialized by zmodu`，AI Agent 与开发者可直接在线编辑，消除传统 `ext/` 继承模式的过度抽象开销。
2. **完全覆盖 Modulith 六层分层**：
   - `model.zig` — 结构体、数据表名定位、JSON field 名称与默认值。
   - `persistence.zig` — `Repository(T)` 数据存储与自定义 SQL 探针。
   - `service.zig` — 业务逻辑校验与 EventBus 消息事件发布。
   - `api.zig` — ComptimeRouter `pub const routes`（`http.RouteSpec`）+ typed handler；scaffold 经 `mountAll` 接线（见 [`ROUTE_TABLE.md`](ROUTE_TABLE.md)）。
   - `module.zig` — Module 生命期（`init` / `deinit`）与导出链。
3. **内置 MCP Server 交互能力**：内置 Model Context Protocol (MCP) Server，AI 智能体可直接通过 MCP Tool (如 `scaffold`, `module`, `verify`, `sql_diff`) 与代码库联动。

---

## 快速使用

### 1. 使用内置统一构建 Step

在 `zigmodu` 根目录下直接构建与运行 `zmodu` CLI 工具：

```bash
zig build zmodu -- scaffold --sql ./schema.sql --name myapp --tenant-column app_id
```

`--tenant-column`（默认 `tenant_id`）控制生成的 `WHERE` 与 scaffold `main` 里的 `zigmodu.setTenantColumn(...)`。模型字段须与列名一致（如 `app_id: i64`）。

或安装到系统可执行路径：

```bash
zig build zmodu
# 二进制生成于 zig-out/bin/zmodu
```

### 2. 从 SQL DDL 一键生成 Modulith 项目

```bash
zig build zmodu -- scaffold \
  --sql ./schema.sql \
  --name my_shop_app \
  --out ./my_shop_app \
  --with-auth \
  --with-resilience \
  --with-events \
  --with-metrics
```


### 3. 生成模块增量与差异比对

针对已存在的项目进行增量表更新：

```bash
zmodu add --name order_item --sql ./schema.sql
```

---

### 4. AI 技能注册表（`zmodu ai`）

```bash
# 导出内置 AI 技能目录（JSON，与 zigmodu.ai.skill_export.toSkillsJson 同构）
zmodu ai export-skills --out skills.json

# 把技能目录（内置或应用导出的）转换为 OpenAPI 3.0 文档
zmodu ai openapi --in skills.json --out openapi.json
```

每个技能对应一个 `POST /skills/{name}` 操作，参数从注册表推导
（`properties` + `required`）。应用侧可直接用
`zigmodu.ai.skill_export.toSkillsJson / toOpenApi` 在运行时导出（tenant-ai
示例暴露于 `GET /api/ai/skills` 与 `GET /api/ai/skills/openapi`）。

---

### 5. 死代码检查（`zmodu deadcode`）

```bash
# 扫描当前项目（默认跳过 .gitignore / .git / .zig-cache / zig-out）
zmodu deadcode

# 二进制模式：main 是入口，同时报告从未被 import 的模块
zmodu deadcode -b

# CI 友好：JSON 输出 + 退出码（0 干净 / 1 有发现 / 2 扫描失败）
zmodu deadcode -j
```

机制参考 [zdeadcode](https://github.com/chy3xyz/zdeadcode)（rustc `dead_code`
lint 风格的可达性分析）：报告未使用的顶层 `fn`/`const`/`var`、容器字段、
枚举变体、方法、嵌套类型与从未 import 的模块；roots 为 `pub` 声明、
`export` 符号、`test` 块、`@export` 目标与（二进制模式）`main`。Zig 编译器
本身不报告这些（例如结构体未用字段、枚举未用变体），本项目仓库扫描即发现
约 9% 潜在死声明，可作为 CI 门禁。完整参数见 `zmodu deadcode --help`。

---

## `zmodu audit` — 业务最佳实践检查

针对业务代码（`src/modules/**`）的规则检查器，两组规则：

- **architecture**：模块自依赖、循环依赖、缺失描述、命名规范
  （小写字母/数字/`-`/`_`）、依赖数量上限（默认 5）、未知依赖（拼写错误）、
  base 模块依赖业务模块（`--base-modules core,http` 时启用）——与框架内
  `zigmodu.ArchitectureTester` 的默认规则对齐（静态源码扫描版）；
- **business**：handler/model 含 SQL、非参数化 SQL（字符串字面量拼接）、
  `@ptrCast(ctx.user_data)`、legacy `sendSuccess`/`sendFail`、banned 导入
  （`zigmodu.http_server` / `orm.Orm` / `PasswordEncoder`）、已移除的 Zig
  0.17 API（`std.Thread.Mutex` 等）、跨模块直接文件导入、handler 手工解析
  Authorization/Bearer、空 `catch {}` 吞错。规则可用
  `.zmodu/rules.json` 按项目开关。

```bash
zmodu audit                      # 全部规则，默认目录 "."
zmodu audit -g business          # 只跑业务 lint
zmodu audit --max-deps 8 -j      # 依赖上限 8 + JSON 输出
zmodu audit --base-modules core,http   # 启用 base 模块规则
zmodu audit --update             # 写入/更新 .zmodu/audit-baseline.json
```

基线语义与 `deadcode` 一致：新增违规使命令失败（exit 1），已入基线条目被
抑制，条目消失视为移除；`--update` 收缩基线。`-j` 输出机器可读 JSON
（pass / 分组计数 / violations / baseline 统计）。仓库示例中
`tenant-mgmt`、`tenant-shop`、`basic`、`ai-ops` 全量通过；`shopdemo` 为
legacy 演示，可用基线逐步治理。

---

## `zmodu ci` — 一站式质量门禁

一条命令跑完全部门禁（面向 CI 或本地提交流程）：

```bash
zmodu ci [dir]      # zig build → fmt --check → verify → audit → deadcode
```

任何一步失败退出码 1，全部通过退出码 0。业务项目可在 GitHub Actions 里
直接 `zmodu ci`，无需再拼多段脚本。

## `zmodu graph` — 模块依赖图（Mermaid）

复用 audit 的模块提取，输出 Mermaid 依赖图：

```bash
zmodu graph [dir]            # stdout
zmodu graph --out docs/modules.md   # 写入文件（可进 CI 自动更新架构图）
```

## `zmodu diff --migration` — schema 演进闭环

`diff` 现在可以直接产出 Flyway 迁移文件：

```bash
zmodu diff old.sql new.sql --migration add-audit-log [--dir src/migrations]
```

自动生成 `V{YYYYMMDDHHMMSS}__add-audit-log.sql`（CREATE/ALTER/DROP 语句），
与 `zmodu migration` 同名规范一致。顺带修复了迁移时间戳恒为
`V19700101000000` 的既有 bug（改用 REALTIME 时钟）。

## audit 规则配置（`.zmodu/rules.json`）

按项目开关规则 / 调阈值：

```json
{ "max_deps": 8, "disabled": ["b3", "b9"] }
```

CLI `--max-deps` 优先于配置文件，配置文件优先于内置默认值。

---

## 最佳实践规范

在整合使用 `zmodu` 生成代码时，必须遵守 ZigModu 生产规范：
1. **模块依赖拓扑**：生成的 `module.zig` 中的 `dependencies` 需精准列出下游模块名，启动时框架通过 `ModuleValidator` 自动检测并防范循环依赖。
2. **规范领域导入**：生成的业务代码统一使用 canonical 导入：
   ```zig
   const zmodu = @import("zigmodu");
   const http = zmodu.http;
   const data = zmodu.data;
   const sec = zmodu.security;
   const obs = zmodu.observability;
   ```
3. **数据库与事务模式**：生成的存储层可通过参数选择 `sqlx` (标准) 或 `zent` (正交 ORM) 作为后端，两套引擎独立运行。
4. **驱动链接**：scaffold / `new` 写入的 `build.zig` 含 `.db = "…"`（默认 `sqlite`；`--from-db` 按 DSN 映射 `postgres` / `mysql` / `sqlite`）。勿再手链三库。详见 [SQLX_DRIVERS.md](SQLX_DRIVERS.md)。

---

## Scaffold 与 `-Ddb=` / `.db=`

| 输入 | 生成 `.db=` |
|------|-------------|
| `zmodu new` / `--sql`（无 `--from-db`） | `sqlite` |
| `--from-db postgresql://…` 或 `postgres://…` | `postgres` |
| `--from-db mysql://…` | `mysql` |
| 其它 / sqlite 路径 | `sqlite` |

```bash
zig build zmodu -- scaffold --from-db postgresql://user@localhost/db --name myapp
# → build.zig 中 b.dependency("zigmodu", .{ .db = "postgres", ... })
```

运行时 DSN 与链接驱动必须一致；未链接的驱动会在 `Client.connect` 返回 `error.DriverNotEnabled`。
