# metaverse-creative 开发备忘

## 7.18 升级目标 → 落地状态

1. **资产即创意**（问题域 / 解决域 / 世界域）  
   → [`METHOD.md`](METHOD.md) 方法论模板；Schema 字段 `problem` / `solution` / `world`（`|` 分隔子项）

2. **modules 深度展开 + zent 最佳实践，默认 Postgres**  
   → `src/modules/{identity,creative,world}/` 五文件分层；`src/db.zig` 默认 `ZENT_DRIVER=postgres`，sqlite 兜底

3. **早期：发布创意并赚钱**  
   → `draft → publish → settlement.purchase → world.feature → visit`（`cli demo`；含幂等/对账/outbox）

4. **面向 AI Agent 的 CLI**  
   → `metaverse-creative cli …`（见 README）

## 本地命令

```bash
zig build demo          # sqlite 冒烟
zig build serve         # HTTP :18200
ZENT_DRIVER=postgres zig-out/bin/metaverse-creative cli demo
```
