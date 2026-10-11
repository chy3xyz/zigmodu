# docs/archive

已完成但**不再维护**的计划与快照。它们是史料，不是当前指引。

| 目录 | 内容 | 为什么归档 |
|---|---|---|
| [`status/`](status/EVALUATION_2026-10.md) | 项目状态与决策快照（9 份）：评估报告、生产路线图、框架 backlog、外部反馈台账、旧版迁移指南 | 都是**某一时点的裁决**，会过期。框架怎么用不取决于它们 |
| [`2026-07-plans/`](2026-07-plans/plans/2026-07-22-modulith-qps-phase1.md) | 5 份实施计划（modulith QPS 三阶段 · sqlx 进阶优化 · 完整性 phase3） | 工作已完成并落地在正式文档里；计划本身只记录当时的拆解与取舍 |
| [`superseded/`](superseded/COMPLETENESS_REPORT.md) | 已被取代的评估报告 | 内容明确过时 |
| [`superseded/BEST_PRACTICES-audit-v0.26.md`](superseded/BEST_PRACTICES-audit-v0.26.md) | v0.26.0「现状复核」审计台账（原 `BEST_PRACTICES.md` §，462 行） | 内部审计分档与抽样数字，不是给使用者的最佳实践；写在正文里会让人把采样值读成现行结论 |
| [`elegant-code-patterns.md`](elegant-code-patterns.md) | 五文件布局 + handler/input/response 约定 | 五文件布局的样例已并入 [`MODULE_LAYERS.md`](../guide/MODULE_LAYERS.md)，其余与 `BEST_PRACTICES` 重叠 |
| [`best-practices-heysen-lessons.md`](best-practices-heysen-lessons.md) | 一次真实 SaaS 集成的经验 | 与 `SQLX_DRIVERS` / `BEST_PRACTICES` 的内存规则重叠；自身 §8 是 TODO 清单 |

**归档不等于删除。** 这些文件仍被源码注释与其他文档按路径引用，所以保留在原位，
只是不再出现在文档索引的主路径上。

## 判断某份文档是否过期

文档自己在文件头会写明。例如 `superseded/COMPLETENESS_REPORT.md` 首行即
「**这是 2026-05-08 / v0.8.0 的历史快照，不是当前状态**」。

**看到"历史快照"字样就不要照着做** —— 它们的结论描述的是当时的树。