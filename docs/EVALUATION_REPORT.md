# ZigModu 生产级评估报告 v5

**评估日期**: 2026-06-20  
**框架版本**: v0.14.3  
**Zig 版本**: 0.17.0  
**测试结果**: **464 passed, 13 skipped, 0 failed**（`ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`，2026-07-20 复测）  
**生产门禁**: `zig build check`（热路径禁止裸 `catch {}`）  
**旗舰示例**: [`examples/tenant-mgmt/`](../examples/tenant-mgmt/) — SQLite 持久层 + 真 JWT + CI 业务断言  
**参考 codegen**: [`examples/shopdemo/`](../examples/shopdemo/) — 152 表 schema + 生成样例（非完整可运行应用）

> v5 增量（2026-07-20）：gRPC unary / Kafka wire / Vault KV v2 HTTP 已落地；综合仍约 94–95。

---

## 综合评分 (12 维度)

| # | 维度 | 得分 | v4 | Δ | 评价 |
|---|------|:----:|:--:|:--:|------|
| 1 | **核心框架** | 98 | 98 | — | Module 全生命周期闭环 |
| 2 | **API & 传输** | 96 | 95 | +1 | HTTP + gRPC unary（帧/本地/HTTP）+ Kafka wire |
| 3 | **弹性模式** | 95 | 95 | — | CB + RL + Retry + Saga |
| 4 | **数据层** | 96 | 95 | +1 | SQLite 旗舰示例 + PG/MySQL CI job |
| 5 | **安全** | 97 | 95 | +2 | AppSecurity、JWT 单路径、wall clock exp |
| 6 | **可观测性** | 93 | 93 | — | Metrics + Tracer + Health + Dashboard |
| 7 | **开发者体验** | 96 | 95 | +1 | `builder.security()`、gen-jwt-token、check 门禁 |
| 8 | **分布式** | 88 | 88 | — | Cluster + DistEventBus |
| 9 | **测试质量** | 95 | 93 | +2 | 415 tests；integration 含 JWT + CRUD 断言 |
| 10 | **运维/DevOps** | 98 | 98 | — | CI matrix + integration-full + DB jobs |
| 11 | **内存安全** | 93 | 92 | +1 | P0 泄漏修复 + 生产 check 门禁 |
| 12 | **文档** | 93 | 90 | +3 | JWT 迁移指南、多租户可选说明、路线图阶段 7 |

> **综合评分: ~95/100** — 路线图阶段 1–7 完成；多租户为可选模块，不启用即为单租户应用。

---

## 生产就绪清单（增量）

| 检查项 | 状态 |
|--------|:----:|
| JWT 统一验证（Middleware ↔ SecurityModule） | ✅ |
| Wall-clock JWT exp（`initWithIo` / `AppSecurity`） | ✅ |
| CI 真 JWT + tenant CRUD 探针 | ✅ |
| CI `DB=postgres` / `DB=mysql` | ✅ |
| `zig build check` 热路径门禁 | ✅ |
| 多租户能力文档化（可选，非强制） | ✅ |

---

## 剩余差距 (95 → 98)

| # | 项目 | 优先级 | 状态 |
|---|------|--------|------|
| 1 | 环境门控 skip 用例（Redis/NATS/PG/MySQL） | 中 | ✅ CI live-service job 覆盖（Fluvio/HttpClient-live 仍本地跳过） |
| 2 | gRPC streaming / HTTP/2 | 低 | Unary 已生产可用；streaming 返回 UNIMPLEMENTED |
| 2b | Kafka Fetch 全量协议矩阵 | 低 | Produce + RecordBatch 解析已测；live 需 `KAFKA_BOOTSTRAP` |
| 3 | ShopDemo 可 `zig build run` | 低 | 待办 |
| 4 | 持续 Benchmark 基线入库 | 低 | ✅ `zig build benchmark` 输出 `bench-results.json`，CI 基线告警已接通 |

> 12 个 skipped 用例全部为环境门控（需要外部服务）：Redis ×3、NATS ×3、Fluvio ×2、PG/MySQL ×2、HttpClient live ×2。CI 中 `test-postgres` / `test-mysql` / `test-live-services` job 分别启用对应服务后执行。

---

## 结论

ZigModu v0.14.3 在 Zig 0.17 上约 **95/100**。单租户应用直接使用 `Application` + HTTP + SQLx 即可；多租户通过 `TenantContext` / 中间件 / SQL 过滤**按需叠加**，见 [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) § Multi-Tenancy (Optional)。

**推荐路径**：`examples/basic`（无租户）→ `examples/tenant-mgmt`（可选多租户 + JWT）→ `shopdemo` schema（大规模 modulith 生成）。

*评估完成时间: 2026-06-20*
