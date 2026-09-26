# `docs/dev/archive/` — 归档区（**历史快照，勿照做**）

这里的文件**不再代表当前状态**。它们记录的是当时（2026-04/05 那一轮完整评审）看到了什么、
打了多少分 —— 其中的评分、测试数、代码规模、行号与结论**全部过期**，照着做会改错东西。
判断"哪份还算数"的入口是 [`../README.md`](../README.md)（现行索引），**不是**本目录。

## 2026-05-review/（2026-04-23 → 2026-05-12 的四次评估）

这一轮在 **v0.7.0 → v0.9.5** 之间写了 9 份评估。移动前夕（2026-09-26）复核过：这 8 份
**零外部引用**（`src/**`、`scripts/**`、`docs/*.md`、`CHANGELOG.md` 都没有按字面路径引用它们，
带 `§N` 的引用也没有），所以移动不会断链。留在这里的只有 `final-assessment.md` 与
`upgrade-roadmap.md` —— 那两份被 `CHANGELOG.md` / `docs/BEST_PRACTICES.md` 按路径引用，
留在 `docs/dev/` 原地不动。

| 文件 | 何时 | 什么 | 今天该看谁 |
|------|------|------|-----------|
| `todo2.md` | 04-23 | 第二代（v0.7.0）产品级评估，以评估当 todo | `../v1.0-readiness-v0.32.md`（现行差距评估） |
| `architecture-review.md` | 05-11 | 架构评审 | `docs/ARCHITECTURE.md`、`docs/MODULITH.md` |
| `performance-review.md` | 05-11 | 性能评审 | `docs/dev/READING_NUMBERS.md` + `bench-results.json` |
| `comprehensive-assessment.md` | 05-11 | 综合评估 | `../v1.0-readiness-v0.32.md` |
| `final-quality-assessment.md` | 05-12 | 质量终评（第一轮） | `../v1.0-readiness-v0.32.md` |
| `gap-to-92.md` | 05-12 | 86 → 92 差距分析 | 属第一轮评分口径，已不与现役评分同轴 |
| `shopdemo-review.md` | 05-12 | ShopDemo 架构 & ZModu 生成器优化 | `docs/ZMODU_CLI_INTEGRATION.md`、`examples/shopdemo` |
| `performance-v094.md` | 05-12 | v0.9.5 性能评估 | `docs/dev/READING_NUMBERS.md` + `bench-results.json` |

同一轮里被两代"最终"结论取代的还有 `docs/COMPLETENESS_REPORT.md`（第 53 批起在文件头带
"历史快照"免责表）—— 留在原地，因为它被 `CHANGELOG.md` 按路径引用。

## 约定

* 归档文件**只读**：不要在里面补"最新进展"，也不要按它的 TODO 开工。
* 需要引用的现行文档一律写**当前路径**（`docs/dev/<file>`、`docs/<file>`），不要指回本目录。
* 以后再有"零外部引用 + 已被后代取代"的评估类文档，`git mv` 到
  `docs/dev/archive/<年份>-<轮次>/`，并在本文件补一行。
