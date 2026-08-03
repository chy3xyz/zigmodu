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

### 3b. 零样板 CRUD（`zmodu saas` 生成 + `http.CrudApi`）

`zmodu saas` 生成的业务模块，API 层已收敛成一行声明——list/get/create/
update/delete 五个 handler 由框架 `zigmodu.http.CrudApi(Entity, Service, opts)`
自动生成：

```zig
// api.zig（生成物）—— 整份文件即一行注册
const zigmodu = @import("zigmodu");
const model = @import("model.zig");
const service = @import("service.zig");

pub const OrdersApi = zigmodu.http.CrudApi(model.Orders, service.OrdersService, .{});
```

生成的路由与元数据（`nest`/`module_name` 取自 Service）：

| 方法 | 路径 | 权限 | 说明 |
|------|------|------|------|
| GET | `{nest}` | `<module>:read` | 分页列表（`PageParams` 钳制 page/page_size） |
| POST | `{nest}` | `<module>:write` | 创建（`bindJson` + `tenant_id` 注入） |
| GET | `{nest}/{id}` | `<module>:read` | 详情（404 信封） |
| PUT | `{nest}/{id}` | `<module>:write` | 更新 |
| DELETE | `{nest}/{id}` | `<module>:write` | 删除 |

- 默认 `.auth = .jwt`；`CrudOpts{ .public = true }` 切公开（同时去掉权限 meta）。
- `CrudOpts{ .permission = "crm.order" }` 覆盖权限前缀。
- 分页信封默认 `{code, items, total}`；`CrudOpts.envelope` 可选
  `.plain` / `.ruoyi`（RuoYi 兼容 `{code,msg,data}`）。

Service 只需 duck-typed `list/get/create/update/delete` + `module_name`/`nest`：

- 生成器输出带 `validate` 钩子的薄 service（保留业务扩展点，如写 outbox、加事件）；
- 想要「透传归零 + CRUD 即事件源」的项目可直接组合
  `zigmodu.data.CrudService(Entity, Persistence)`：写操作自动 publish
  `CrudEvent{created,updated,deleted}`，无需手写事件发布代码。

```zig
// service.zig（生成物）—— CrudService 零透传组合
pub const OrdersService = struct {
    pub const module_name = "orders";
    pub const nest = .{"orders"};
    pub const impl = zigmodu.data.CrudService(model.Orders, persistence.OrdersPersistence);
    crud: impl,

    pub fn init(p: *persistence.OrdersPersistence) @This() {
        var self: @This() = .{ .crud = impl.init(p) };
        self.crud.validate = &validate; // 可选校验钩子
        return self;
    }
    // 无 list/get/create/update/delete 透传：CrudApi 探测到 `impl` 类型后
    // 直接路由到 self.crud，写操作自动 publish CrudEvent{created,updated,deleted}
};
```

响应收敛配套：`http.PageParams.parse(ctx, .{ .max_page_size = 100 })` 统一分页解析，
`Extract.toDto/respondDto` 按同名字段约定映射 DTO（白名单天然隐藏
`secret`/`org_id` 等列），`Extract.toDtoList` 做列表收集。

前端同源产出：同一个 `orders.model.json` 可再跑
`node zsaas/scripts/gen-business.mjs orders.model.json <frontend>`，生成
`src/models/Orders.ts`（类型 + 字段 schema）与
`src/routes/dashboard/orders/index.tsx`（DataTable + EntityForm 数据驱动 CRUD
页，直接对接后端 autoCrud）。共享脚手架（`libs/apiClient.ts`、
`components/data/DataTable.tsx`、`EntityForm.tsx`）已随 `examples/zmsaas` 提供。

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
  Authorization/Bearer、空 `catch {}` 吞错、未使用 catch 捕获
  （`catch |err| { _ = err; }` → 应写 `catch {`）、service 层纯透传 CRUD
  方法（list/get/create/update/delete 只转发 `self.persistence.*` → 建议
  `data.CrudService(Entity, Persistence)`，写操作自动发事件）、api 层裸实体
  响应（`ctx.jsonStruct(200, e)` 直接序列化 model → 建议
  `Extract.toDto/respondDto` 白名单隐藏内部列）。规则可用
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

## `zmodu market` — 模块市场（Phase 1 策展目录 + Phase 2 远程发现/安装）

模块市场分阶段：**Phase 1** 是本地策展目录
（`tools/zmodu/src/marketplace/catalog.json`，`schema_version: 1`），登记值得
引用的 example / plugin，先解决可发现性；**Phase 2** 增加远程发现与安装——
`update` 拉取远程索引合并进本地浏览，`install` 把条目源码复制进项目。签名、
build.zig.zon 自动写入与 CI 回归钩子仍延后（ADR-016）——先有质量门
（ADR-014 / `zmodu ci`）再谈扩张，避免在版本纪律稳定前引入"下载并执行第三方
代码"的信任面。

```bash
zmodu market list                      # 列出全部策展条目（本地 + 已缓存远程索引）
zmodu market search saas               # id/name/summary/tags 大小写不敏感匹配
zmodu market info example/zmsaas       # 单个条目详情
zmodu market update                    # 拉取远程索引 -> .zmodu/market-index.json
zmodu market update --index <url>      # 自定义索引源
zmodu market install example/basic --dir ./vendor [--dry-run] [--verify]
zmodu market list --json               # 机器可读 JSON
zmodu market list --catalog <path>     # 用外部目录文件替代内嵌目录
```

条目字段：`id`（`example/<name>` 或 `plugin/<name>`）、`kind`、`path`、
`summary`、`tags`、`min_version`、`doc`、`status`（plugin stub 为 `"stub"`）。

| 阶段 | 发现模块 | 安装 | 信任 | 门槛 |
|------|----------|------|------|------|
| Phase 1（已完成） | `zmodu market search … --json` | 读 `path` 参考接线（或 `zmodu saas`/`scaffold` 生成） | 本地策展 | — |
| Phase 2（本轮） | `market update` 远程索引（合并浏览） | `market install <id> --dir … [--dry-run] [--verify]` 复制源码树（跳过 node_modules/.git 等） | 本地策展 + URL 来源 | `--verify` 就地 `zig build` |
| Phase 2c（ADR-016，未做） | 远程索引升级 | `install` 自动写 `build.zig.zon` | 签名包 | 要求 `zmodu ci` 绿 + catalog schema 版本化 |

新增官方示例的流程：先合入 `examples/`（保证示例构建绿），再往 catalog 加一行。

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
