# `docs/dev/` — 文件索引

17 份文件、约 5000 行，写于 **2026-04-23 → 2026-09-26** 的四个批次（另有 8 份已归档到
[`archive/2026-05-review/`](archive/README.md)，约 1200 行）。这里是判断
**"哪份还算数"** 与 **"哪份动不得"** 的唯一入口 —— 先看这张表，再打开具体文件。

复现引用关系：

```bash
grep -rn 'docs/dev/' --include='*.zig' --include='*.sh' --include='*.md' . | grep -v '^\./docs/dev/'
```

---

## 0. 硬约束：§1 那 16 份**不能移动**

它们被 `src/**`、`scripts/**`、`docs/*.md`、`CHANGELOG.md` 按**字面路径**引用，
而且多处带 `§N` 章节号（例如 `docs/dev/cluster-auth-design.md` §10）。改名或移动
= 断链，且断在源码注释里 —— 没有编译器会提醒你。

## 1. 被引用（路径不可动）

| 文件 | 首次入库 | 什么 | 引用者 |
|------|----------|------|--------|
| `cluster-identity-design.md` | 09-21 | 总线节点身份绑定 —— **已实现** | `src/core/DistributedEventBus.zig`、`docs/DISTRIBUTED.md` |
| `cluster-auth-design.md` | 09-20 | 集群入站认证 —— **L1/L2 已实现**；Raft 侧身份绑定未实现 | `src/core/cluster/{RaftElection,RaftTransport,ClusterBootstrap,DistributedIntegrationTest}.zig`、`src/core/DistributedEventBus.zig`、`docs/DISTRIBUTED.md`、`docs/UPGRADING.md` |
| `alpha-engine-spec.md` | 09-17 | alpha-engine 规格（todo3 §十六 的参考实现） | `examples/alpha-engine/**`（7 处）、`CHANGELOG.md` |
| `READING_NUMBERS.md` | 09-20 | 读数约定：一个事实一个名字 | `scripts/test-fast.sh`、`scripts/check-bench.sh`、`docs/UPGRADING.md`、`CHANGELOG.md` |
| `todo3.md` | 09-17 | 运行时**方向** | `docs/RUNTIME.md`（:5 与 :531） |
| `todo3.1.md` | 09-17 | 运行时**兼容策略** | `docs/RUNTIME.md`、`CHANGELOG.md` |
| `todo.md` | 04-23 | 第一代产品级评估（当 todo 用） | `src/extensions/HotReloader.zig` |
| `upgrade-roadmap.md` | 05-12 | v0.9 → v1.0 路线 | `docs/BEST_PRACTICES.md`、`CHANGELOG.md` |
| `v1.0-readiness-v0.35.md` | 09-26 | **v0.35 → v1.0 差距评估（现行）** | `CHANGELOG.md` |
| `v1.0-readiness-v0.32.md` | 09-21 | v0.32 → v1.0 差距评估（已被上一份取代） | `src/soak_cluster.zig`、`CHANGELOG.md` |
| `v1.0-gap.md` | 09-20 | v0.31 → v1.0 差距评估（已被取代两代） | `CHANGELOG.md` |
| `security-audit-v0.31.0.md` | 09-20 | v0.31.0 安全审计 | `examples/production-deploy/smuggling-e2e/{run.sh,README.md}` |
| `security-audit-cluster.md` | 09-20 | 审计 ②：集群 / Raft 帧解码 | `src/test/ErrorSetSnapshot.zig`、`CHANGELOG.md` |
| `security-audit-ws.md` | 09-20 | 审计 ②：WebSocket 帧解析 / 握手 | `CHANGELOG.md` |
| `final-assessment.md` | 05-11 | 第一轮的"最终"评估 | `CHANGELOG.md` |
| `h2-pending-slices.md` | 09-26 | H2 响应体 > `max_pending_bytes` —— **已修**（现象/根因两层/修法/验收） | `CHANGELOG.md` |

## 2. 已归档：`archive/2026-05-review/`（**2026-09-26 执行**）

`2026-05-11/12` 那一轮评审里，除 §1 收录的 `final-assessment.md` 与 `upgrade-roadmap.md` 之外的
7 份 + 第二代 todo，**零外部引用**已复核（`src/**`、`scripts/**`、`docs/*.md`、`CHANGELOG.md`
都没有按字面路径或 `§N` 引用它们），已 `git mv` 进归档区：

`architecture-review.md` · `performance-review.md` · `comprehensive-assessment.md` ·
`final-quality-assessment.md` · `gap-to-92.md` · `shopdemo-review.md` · `performance-v094.md` ·
`todo2.md`

归档区是**历史快照**（`archive/README.md` 有对照表：哪份被谁取代、今天该看哪份），
不要在那边补进展，也不要按它的 TODO 开工。

## 3. 取代关系（别读错代）

**评估报告** —— 同一件事问了三次：

1. `04-23` `todo.md` → `todo2.md`（已归档）：早期"产品级评估"，以评估当 todo。
2. `05-11/12` 九份一组：architecture → performance → comprehensive → **final** →
   **final-quality** → gap-to-92 → shopdemo → performance-v094 → upgrade-roadmap。
   文件名里出现两次 "final" 是**同一轮的迭代**，不是三份独立结论。
3. `09-20/21/26` v1.0 差距三代：`v1.0-gap.md` → `v1.0-readiness-v0.32.md` →
   **`v1.0-readiness-v0.35.md`（现行，09-26）**。三份都是"逐条 + 证据"的同一形状，读最新那份即可；
   旧的两份保留在原地是因为源码注释按路径引用它们。
   `gap-to-92.md`（已归档）属第 2 轮的评分口径，不与这三份同轴。

**todo 四代**：`todo.md`(04-23) → `todo2.md`(04-23，已归档) → `todo3.md`(09-17) →
`todo3.1.md`(09-17)。后两份被 `docs/RUNTIME.md` 引用、`todo.md` 被
`HotReloader.zig` 引用 —— 这三份都留在原地。

**安全审计三份并列**（同日 09-20，覆盖面不同，互不取代）：
v0.31.0 通用 / 集群·Raft 帧解码 / WebSocket 帧解析·握手。

**设计文档两份并列**（状态不同，互不取代）：
`cluster-identity-design.md` 已实现 · `cluster-auth-design.md` 未实现。

## 4. 建议动作

- ~~§2 那 8 份移动而非删除~~ —— **已执行**（2026-09-26，见 §2 与
  [`archive/README.md`](archive/README.md)）。
- §1 **一律不动**，尤其是 `cluster-*.md` / `alpha-engine-spec.md` /
  `READING_NUMBERS.md`：源码与脚本按字面路径 + `§N` 引用它们。
- 新增文件时在 §1 或 §2 补一行，并注明取代了谁。
- 再出现"零外部引用且已被后代取代"的评估类文档，**移动前先重跑** §0 那条 grep
  （本索引基于当时 `master`，新增引用会让清单过期），再 `git mv` 到
  `archive/<年份>-<轮次>/` 并补一行。
