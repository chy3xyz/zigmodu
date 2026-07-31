# ZigModu 使用中发现的问题（v0.14.17 / Zig 0.17.0-dev.1422）

> 来源：真实项目（devs_monitor）接入时发现并记录；前两条已在框架侧修复，第三条为已知约束。

## 1. sqlx postgres 驱动：`?N` 编号占位符转换 bug —— 已修复

**原现象**：任何使用 `?1`、`?2` 等编号占位符的参数化查询，在 postgres 驱动下都会失败：

```sql
SELECT ... FROM users WHERE username = ?1 LIMIT 1
→ ERROR: could not determine data type of parameter $1（SQLSTATE 42P18）
```

**原根因**：`src/sqlx/sqlx.zig` 的 `convertPlaceholders`（postgres 专用）把每个 `?` 替换为顺序编号的 `$N`，但不会吞掉 sqlite 风格 `?N` 里跟随的数字。`?1` 先变成 `$1`，紧跟的字符 `1` 又被原样拷贝 → 实际发给 PG 的是 `$11`（参数 11）。byte 级复现：`sql=[...username = $11]`。

**修复（2026-07-31）**：`convertPlaceholders` 现在：

- 消费 `?N` 的数字，`?1` → `$1`（不再出现 `$11`）；
- 所有占位符统一按出现顺序编号，`?`、`?2`、`?` → `$1`、`$2`、`$3`；
- 跳过单引号字符串（含 `''` 转义）、双引号标识符、`--` 行注释、`/* */` 块注释，字符串字面量里的 `?` 不再被误转；
- 附带修复了 `?12` 这类「移除字符数 > 新增字符数」导致的尺寸计算下溢。

**语义说明**：`?N` 与 `?` 均按顺序编号，即「参数顺序 = 出现顺序」。SQLite 原生支持显式 `?N` 下标绑定，如需跨驱动一致，请保持占位符与参数数组顺序对应。

## 2. HTTP header 读取大小写敏感 —— 已修复

请求解析器把 header 名统一转小写（`x-agent-token`），但 `ctx.header(key)` 之前是大小写敏感的 HashMap 查找，`ctx.header("X-Agent-Token")` 返回 `null`。

**修复（2026-07-31）**：`ctx.header()` 现在按 RFC 9110 做大小写不敏感查找（先精确匹配小写键，再 `eqlIgnoreCase` 兜底），`"User-Agent"` 与 `"user-agent"` 均可用。修复同时覆盖了框架内部 AccessLog（`User-Agent`）、Validation（`X-Validate`）以及 tenant-mgmt 示例（`X-Tenant-ID`）等混合大小写调用。

## 3. HttpClient 纯 HTTP 路径依赖事件循环（已知约束，未改）

`zigmodu.http.HttpClient` 的 HTTP（非 TLS）路径使用自定义连接池 + `std.Io` 异步连接，在无 server 事件循环的普通 `main` 里调用会**永久挂起**（不报错、不超时）。

**规避**：独立客户端直接用 `std.http.Client.fetch(...)`（zigmodu HTTPS 路径同款 API，阻塞式可用）。
