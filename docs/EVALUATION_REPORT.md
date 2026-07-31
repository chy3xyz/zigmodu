# ZigModu 生产级评估报告 v5

**评估日期**: 2026-07-31  
**框架版本**: v0.14.16  

**Zig 版本**: 0.17.0  
**测试结果**: **745+ passed, 20 skipped, 0 failed**（`ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`，2026-07-31 复测）  

**生产门禁**: `zig build check`（热路径禁止裸 `catch {}`）  
**旗舰示例**: [`examples/tenant-mgmt/`](../examples/tenant-mgmt/) — SQLite 持久层 + 真 JWT + CI 业务断言  
**内置 CodeGen CLI**: [`tools/zmodu/`](../tools/zmodu/) — 支持 SQL DDL 解析、`@initialized` 开发模型与内置 MCP Server（`zig build zmodu`）

> v5.6 增量（2026-07-31）：x402 支付校验 **fail-closed**；`OtlpExporter.exportSpans` OTLP/HTTP JSON 上报 + 重试；AGENTS/CLAUDE 版本与测试基线对齐；综合维持 **~98/100**。

---

## 综合评分 (12 维度)

| # | 维度 | 得分 | v4 | Δ | 评价 |
|---|------|:----:|:--:|:--:|------|
| 1 | **核心框架** | 98 | 98 | — | Module 全生命周期闭环 + 级联背压 |
| 2 | **API & 传输** | 97 | 95 | +2 | HTTP/1.1 + h2c + gRPC streams + Kafka wire |
| 3 | **弹性模式** | 96 | 95 | +1 | CB + RL + Retry + Redis 容灾降级 |
| 4 | **数据层** | 97 | 95 | +2 | SQLite 旗舰示例 + PG/MySQL 二进制解析 + ManagedRows |
| 5 | **安全** | 98 | 95 | +3 | AppSecurity、JWT 单路径、JwksKeyRing 动态轮换 |
| 6 | **可观测性** | 98 | 93 | +5 | Prometheus + OTLP/HTTP JSON 上报(重试) + Health Probe |
| 7 | **开发者体验** | 98 | 95 | +3 | 内置 `zmodu` CLI、`builder` API |
| 8 | **分布式** | 93 | 88 | +5 | Cluster + DistEventBus + Raft Log Compaction |
| 9 | **测试质量** | 97 | 93 | +4 | ~745 passed；integration 含 JWT + CRUD + shopdemo smoke |
| 10 | **运维/DevOps** | 98 | 98 | — | CI matrix + integration-full + DB jobs |
| 11 | **内存安全** | 96 | 92 | +4 | P0 泄漏修复 + 生产 check 门禁 |
| 12 | **文档** | 97 | 90 | +7 | ZMODU / ZENT / MODULITH / 多租户可选说明 |

> **综合评分: ~98/100** — 路线图阶段 1–9 主体落地；多租户为可选模块。v5.6 补齐 OTLP 上报与 x402 安全默认。

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
| h2c prior-knowledge + Router 复用 | ✅ |
| PRIORITY 加权出站调度 | ✅ |
| H2 ConnWriter + GOAWAY/RST + pending 上限 | ✅ |
| x402 支付校验 fail-closed | ✅ |
| OTLP/HTTP JSON `exportSpans` + 重试 | ✅ |
| AGENTS/CLAUDE 版本与测试基线对齐 | ✅ |

---

## 剩余差距

| # | 项目 | 优先级 | 状态 |
|---|------|--------|------|
| 1 | 环境门控 skip（Redis/NATS/PG/MySQL） | 中 | ✅ CI live-service job；Fluvio/HttpClient-live / `OTLP_ENDPOINT` 仍本地跳过 |
| 2 | gRPC streaming / HTTP/2 | 部分 | PRIORITY + 合并写 + GOAWAY/RST 隔离 + h2c；**H2 吞吐仍低于 H1**；进程内 TLS 仍待 |
| 2b | Kafka Consumer Group | 部分 | CooperativeSticky + 两阶段 revoke/ack；broker 完整往返仍可加深 |
| 3 | ShopDemo `zig build run` | 低 | ✅ + CI smoke |
| 4 | Benchmark 基线 | 低 | ✅ `zig build benchmark`；H1/h2c 脚本 `scripts/bench_h1_h2.py` |
| 5 | OTLP/Vault HTTPS | 中 | `http://` 已通；`https://` 仍 `*TlsNotSupported`（sidecar / 待 stdlib） |

---

## 结论

ZigModu **v0.14.16** 在 Zig 0.17 上约 **98/100**。短请求本机场景优先 HTTP/1.1；h2c/gRPC 适合多路复用与流式。TLS 生产路径用 sidecar ALPN。

**推荐路径**：`examples/basic` → `examples/tenant-mgmt` → `shopdemo` / `zent-modulith`。

*评估完成时间: 2026-07-31*
