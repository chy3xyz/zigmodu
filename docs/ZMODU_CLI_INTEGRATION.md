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
zig build zmodu -- --help
```

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
