# ZigModu 生产级路线图（修订版）

**版本口径**: v0.13.15 · Zig 0.17.0  
**最后更新**: 2026-06-20  
**原则**: `sqlx.zig` / `Server.zig` **不物理拆分**；用分区注释 + 冻结边界 + 测试门禁维持可维护性。

---

## 阶段总览

| 阶段 | 状态 | 内容 |
|------|------|------|
| 1 | ✅ 已完成 | 编译恢复、版本/CI 统一、`zig build test` 全绿 |
| 2 | ✅ 已完成 | P0：JWT 生命周期、EventBus、ConnPool、Row arena、mutex deinit |
| 3 | ✅ 已完成 | API 收敛：canonical domain import，deprecated 隔离 |
| **4** | **选做（默认跳过）** | **冻结大文件 + 分区文档 + 维护边界（见下文）** |
| 5 | ✅ 已完成 | 集成/压测/安全测试 + CI 两档（smoke / full） |
| 6 | ✅ 已完成 | README/评估报告/示例与宣传对齐 |
| **7** | **✅ 已完成** | **JWT 统一 + AppSecurity + tenant-mgmt 真 JWT + CI token 生成** |
| **8** | **✅ 已完成** | **评估 v5 (~95/100) + 多租户可选架构文档** |

**验收基线（当前已达成）**

```bash
zig build
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test   # 415+ passed, 5 skipped
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build check-api
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build check
bash scripts/ci-integration.sh   # tenant-mgmt + http-stress-test（需 curl）
```

---

## 多租户：可选，非强制

框架核心不假设多租户。`TenantContext` / `ShardRouter` / `DataPermission` 位于可选层；`examples/basic` 为零租户配置，`examples/tenant-mgmt` 为完整 SaaS 演示。详见 `docs/ARCHITECTURE.md` § Multi-Tenancy (Optional)。

---

## 阶段 4（修订）：不拆分，只设边界

### 为何不做物理拆分

- 单文件不影响运行时正确性；近期 P0 与测试覆盖收益更大。
- 拆分 import 面大、短期回归风险高，与「先稳再优」冲突。
- 文件内已有 § 分区；配合边界规则足够支撑 9 分级工程成熟度。

### 何时才重新考虑拆分

仅当 **同时** 出现：

- 同一文件多人每周多次 merge 冲突；
- 单次 PR  routinely >300 行且跨 ≥2 个 § 分区；
- 新 driver / 新传输层**无法**按边界规则落在新文件。

届时按现有 § 注释**一次性**抽出，不做渐进碎裂。

---

## `src/sqlx/sqlx.zig` 维护边界

**定位**: 唯一 SQLx 实现入口；`zmodu.data` / `SqlxBackend` 通过此文件或 `sqlx/` 子目录（非 sqlx.zig 本体）接入。

| § 分区 | 行号约 | 允许修改 | 禁止 / 必须新建文件 |
|--------|--------|----------|---------------------|
| §1 Types | 顶 ~170 | bugfix、Zig 0.17 API 适配 | 新 Value 变体 → 评估是否属 ORM 层 |
| §2 SQLite | ~364 | driver bug、stmt 缓存、绑定 | 新 SQLite 扩展 API → `sqlx/sqlite_ext.zig` |
| §3 Postgres | ~565 | 同上 | 新 PG 特性 → `sqlx/postgres_ext.zig` |
| §4 MySQL | ~989 | 同上 | 新 MySQL 特性 → `sqlx/mysql_ext.zig` |
| §5 PreparedStmt | ~1198 | stmt 生命周期、reset/clear | — |
| §6 ConnPool | ~1477 | 池化语义、健康检查 | 新池策略 → `pool/Pool.zig` 或新文件 |
| §7 Client | ~1623 | query/exec/tx 路径 | **新公开 Client 方法** 先在 `data.zig` 设计再落码 |
| §8 Transaction | Client 内 | savepoint、rollback | — |
| §9 ORM scan | ~171 | scanStruct、类型映射 | **新 ORM 能力** → `sqlx/orm.zig`（已存在则扩该文件） |
| §10 Tests | ~2714 | 回归测试 | 集成级 DB 测试 → `src/tests.zig` 或 examples |

**硬规则**

1. **单 PR 仅触一个 §**（跨 § 需拆 PR 或明确 P0 理由）。
2. **新数据库 driver**：新文件 `sqlx/<name>_conn.zig` + `sqlx.zig` 仅加 VTable 注册与 re-export。
3. **禁止**在 sqlx.zig 增加与 HTTP、租户、缓存无关的业务逻辑。
4. 修改 ConnPool / Row arena / stmt 复用路径时，**必须**跑全量 `zig build test`。

---

## `src/api/Server.zig` 维护边界

**定位**: HTTP Server 唯一实现；对外经 `http.zig` → `zmodu.http` 暴露。

| 逻辑块 | 约行 | 允许修改 | 禁止 / 必须新建文件 |
|--------|------|----------|---------------------|
| Method / Route / RouteGroup | 顶 ~147 | 路由注册 API | — |
| Context | ~172 | 请求/响应、arena、bindJson | 新业务 DTO → 各 module 的 `api.zig` |
| StreamReader / ParsedRequest | ~605 | 解析 bug、keep-alive | — |
| TrieNode / Router | ~790 | 匹配、wildcard、params | — |
| writeResponse / Server | ~1121 | 监听、graceful drain | — |
| connFiber / 升级 WS | ~1387 | I/O 生命周期 | **新 WS 协议** → `im/` 或 `extensions/WebSocket.zig` |
| deepCopy / 测试 | 末段 | 回归 | E2E → `examples/` 或 IntegrationTest |

**硬规则**

1. **Middleware 新种类**：实现放在 `Middleware.zig`，Server 只保留链式调度 hook。
2. **禁止**在 Server.zig 写 SQL、租户过滤、JWT 签发（已在 `Middleware.zig` / `security`）。
3. **PathRewriter / compat** 仅做路径重写，不嵌入业务路由表。
4. 修改 `Context.deinit` / `setHeader` / `connFiber` 时，**必须**跑 `api.Server` 与 `api.Middleware` 相关测试。
5. **单 PR 行数**: 建议 <150 行；超过需说明所属逻辑块且不分 cross 块重构。

---

## 阶段 3 / 5 / 6 简要

### 阶段 3 — API 收敛 ✅

- [x] 应用代码统一 `zmodu.http` / `zmodu.data` / `zmodu.security` / `zmodu.observability`（示例已迁移）。
- [x] `src/deprecated.zig` 集中 flat 别名；`root.zig` re-export；**计划 v0.14.0 移除**。
- [x] `ctx.json` 为首选响应；`sendSuccess/sendFail` 保留 compat（`Server.zig` 已标 DEPRECATED）。
- [x] `docs/API-MIGRATION.md` § Domain Import Convergence。

### 阶段 5 — 测试升级 ✅

- [x] CI smoke：`zig build test` + `zig build check-api`（`scripts/ci-smoke.sh`）。
- [x] CI full（main push）：`integration-full` job → `scripts/ci-integration.sh`（tenant-mgmt health/dashboard/401 + http-stress-test）。
- [x] 安全单测：JWT 有效/篡改/过期、CSRF 双提交、SQL 参数化防注入；`jwtAuth` 校验 `exp` + 小写 header 键。

### 阶段 6 — 文档与示例 ✅

- [x] 更新 `docs/EVALUATION_REPORT.md` v4（v0.13.15 / Zig 0.17 / 413 tests）。
- [x] 旗舰示例 `examples/tenant-mgmt/`；README / examples 索引中 shopdemo 标为 codegen 参考。
- [x] `CLAUDE.md` / `AGENTS.md` 同步 Zig 0.17 与 v0.13.15。

---

## 评分口径（修订）

| 维度 | 不拆分时的目标 | 说明 |
|------|----------------|------|
| 可维护性 | 8/10 | 靠 § 分区 + 边界规则，不靠文件数 |
| 正确性 | 9+/10 | 测试全绿 + P0 清零 |
| 文档可信 | 9/10 | 版本/测试数/示例一致 |
| **综合** | **≥95/100** | 阶段 1–8 已完成；多租户可选 |
