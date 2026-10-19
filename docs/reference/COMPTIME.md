# Compile-time budget（编译期预算）

ZigModu 把大量"结构上不会变"的东西放在编译期：路由表与 `RouteMeta`、模块依赖图
校验、`Repository` 的租户列强制、邮箱容量（`Mailbox(T, capacity)`）。这是框架
的差异化，但它有一个**未显式管理的资源**：`@setEvalBranchQuota`。

## 规则

```
quota = base + per_unit × units        // core/EvalQuota.zig
base = 1_000_000, per_unit = 20_000
```

- `units` 是这次分析要走的"东西"的数量：模块数、字段数、图节点数。
- 这是一个**天花板**：没触发就没有成本，所以数字只需要"足够大"，不需要精确。
- **最内层配额获胜**。调用方写 `@setEvalBranchQuota(10_000_000)` **救不了**
  一个内部写死 `1000` 的库函数——所以库代码必须缩放，不能写死。

已接入：`core/ModuleScanner`（按模块数）、`core/ModuleGraph.findCycle`（按节点数）、
`persistence/Orm.comptimeInsertArgCount`（按字段数）、`runtime/ring`（按容量，
`4 × capacity + 2000`）。`http/Hpack` 的静态表用固定值是有意的。

自己的代码需要更大预算时：

```zig
const EvalQuota = @import("zigmodu").core.EvalQuota; // 或直接 import 路径
comptime {
    @setEvalBranchQuota(EvalQuota.forUnits(fields.len));
    // … 展开/分析 …
}
```

## 预算的证据

- **门禁**：`src/test/ComptimeBudget.zig` 生成 **256 条路由**并完整 mount + catalog。
  任何一处固定配额或 O(n²) 折叠让它编不过，CI 直接红——没有计时抖动。
- **数字**：`scripts/check-comptime-budget.sh` 编译该测试并打印墙钟/峰值 RSS，
  超过 `COMPTIME_BUDGET_SECS`（默认 300s）/ `COMPTIME_BUDGET_RSS_MB`（默认 4096）
  才失败。阈值刻意宽松：这道门抓的是"数量级回归"，不是日常波动。
- **回归时看哪里**：配额类失败报 `evaluation exceeded N branches`，堆栈指向
  `@setEvalBranchQuota` 所在文件；性能类回归看脚本输出的时间/RSS 与上一次记录。

## 消费方视角的成本

路由与模块在编译期展开，意味着**构建时间随应用规模增长**：框架自己的 2.3k 测试、
一个 1800 条路由的消费方，都会把每个 handler/meta 实例化进二进制。当前没有做
"按需裁剪路由"的机制；如果构建时间成为瓶颈，优先检查：

1. 是否有大模块把大量路由注册进同一个 `routes` 表；
2. 是否有 `RouteMeta` 字段引用巨大的 comptime 字符串；
3. 是否触发了多处重复的图分析（每个 builder 一次是预期，重复调用不是）。
