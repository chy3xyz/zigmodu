# `docs/dev/` — 文件索引

22 份文件、约 5850 行，写于 **2026-04-23 → 2026-09-21** 的四个批次。这里是判断
**"哪份还算数"** 与 **"哪份动不得"** 的唯一入口 —— 先看这张表，再打开具体文件。

复现引用关系：

```bash
grep -rn 'docs/dev/' --include='*.zig' --include='*.sh' --include='*.md' . | grep -v '^\./docs/dev/'
```

---

## 0. 硬约束：14 份**不能移动**

它们被 `src/**`、`scripts/**`、`docs/*.md`、`CHANGELOG.md` 按**字面路径**引用，
而且多处带 `§N` 章节号（例如 `docs/dev/cluster-auth-design.md` §10）。改名或移动
= 断链，且断在源码注释里 —— 没有编译器会提醒你。

## 1. 被引用（路径不可动）

| 文件 | 首次入库 | 什么 | 引用者 |
|------|----------|------|--------|
| `cluster-identity-design.md` | 09-21 | 总线节点身份绑定 —— **已实现** | `src/core/DistributedEventBus.zig`、`docs/DISTRIBUTED.md` |
| `cluster-auth-design.md` | 09-20 | 集群入站零认证 —— **未实现**（当前代码取舍的理由） | `src/core/cluster/{RaftElection,RaftTransport,ClusterBootstrap,DistributedIntegrationTest}.zig`、`src/core/DistributedEventBus.zig`、`docs/DISTRIBUTED.md`、`docs/UPGRADING.md` |
| `alpha-engine-spec.md` | 09-17 | alpha-engine 规格（todo3 §十六 的参考实现） | `examples/alpha-engine/**`（7 处）、`CHANGELOG.md` |
| `READING_NUMBERS.md` | 09-20 | 读数约定：一个事实一个名字 | `scripts/test-fast.sh`、`scripts/check-bench.sh`、`docs/UPGRADING.md`、`CHANGELOG.md` |
| `todo3.md` | 09-17 | 运行时**方向** | `docs/RUNTIME.md`（:5 与 :531） |
| `todo3.1.md` | 09-17 | 运行时**兼容策略** | `docs/RUNTIME.md`、`CHANGELOG.md` |
| `todo.md` | 04-23 | 第一代产品级评估（当 todo 用） | `src/extensions/HotReloader.zig` |
| `upgrade-roadmap.md` | 05-12 | v0.9 → v1.0 路线 | `docs/BEST_PRACTICES.md`、`CHANGELOG.md` |
| `v1.0-readiness-v0.32.md` | 09-21 | **v0.32 → v1.0 差距评估（现行）** | `src/soak_cluster.zig`、`CHANGELOG.md` |
| `v1.0-gap.md` | 09-20 | v0.31 → v1.0 差距评估（已被上一份取代） | `CHANGELOG.md` |
| `security-audit-v0.31.0.md` | 09-20 | v0.31.0 安全审计 | `examples/production-deploy/smuggling-e2e/{run.sh,README.md}` |
| `security-audit-cluster.md` | 09-20 | 审计 ②：集群 / Raft 帧解码 | `src/test/ErrorSetSnapshot.zig`、`CHANGELOG.md` |
| `security-audit-ws.md` | 09-20 | 审计 ②：WebSocket 帧解析 / 握手 | `CHANGELOG.md` |
| `final-assessment.md` | 05-11 | 第一轮的"最终"评估 | `CHANGELOG.md` |

## 2. 零外部引用（归档候选）

2026-05-11/12 那一轮完整评审里，除了 §1 收录的 `final-assessment.md` 与
`upgrade-roadmap.md`，其余 7 份 + 第二代 todo **没有任何外部引用**：

| 文件 | 首次入库 | 什么 |
|------|----------|------|
| `architecture-review.md` | 05-11 | 架构评审 |
| `performance-review.md` | 05-11 | 性能评审 |
| `comprehensive-assessment.md` | 05-11 | 综合评估 |
| `final-quality-assessment.md` | 05-12 | 质量终评 |
| `gap-to-92.md` | 05-12 | 86 → 92 差距分析 |
| `shopdemo-review.md` | 05-12 | ShopDemo 架构 & ZModu 生成器优化 |
| `performance-v094.md` | 05-12 | v0.9.5 性能评估 |
| `todo2.md` | 04-23 | 第二代（v0.7.0）产品级评估 |

## 3. 取代关系（别读错代）

**评估报告** —— 同一件事问了三次：

1. `04-23` `todo.md` → `todo2.md`：早期"产品级评估"，以评估当 todo。
2. `05-11/12` 九份一组：architecture → performance → comprehensive → **final** →
   **final-quality** → gap-to-92 → shopdemo → performance-v094 → upgrade-roadmap。
   文件名里出现两次 "final" 是**同一轮的迭代**，不是三份独立结论。
3. `09-20/21` v1.0 差距三代：`v1.0-gap.md` → **`v1.0-readiness-v0.32.md`（现行）**。
   `gap-to-92.md` 属第 2 轮的评分口径，不与这两份同轴。

**todo 四代**：`todo.md`(04-23) → `todo2.md`(04-23) → `todo3.md`(09-17) →
`todo3.1.md`(09-17)。后两份被 `docs/RUNTIME.md` 引用、`todo.md` 被
`HotReloader.zig` 引用，**只有 `todo2.md` 可以动**。

**安全审计三份并列**（同日 09-20，覆盖面不同，互不取代）：
v0.31.0 通用 / 集群·Raft 帧解码 / WebSocket 帧解析·握手。

**设计文档两份并列**（状态不同，互不取代）：
`cluster-identity-design.md` 已实现 · `cluster-auth-design.md` 未实现。

## 4. 建议动作（**未执行**，需要你点头）

- §2 那 8 份是唯一可动的，且**建议移动而非删除**：
  `git mv docs/dev/<file> docs/dev/archive/2026-05-review/`
  （移动前请再跑一遍 §0 的 grep —— 本索引基于当前 `master`，新增引用会让清单过期。）
- §1 **一律不动**，尤其是 `cluster-*.md` / `alpha-engine-spec.md` /
  `READING_NUMBERS.md`：源码与脚本按字面路径 + `§N` 引用它们。
- 新增文件时在 §1 或 §2 补一行，并注明取代了谁。
