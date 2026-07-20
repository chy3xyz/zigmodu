# Metaverse Creative — ZigModu × zent

**结构升级**：创意资产 = 三域（problem / solution / world），见 [`METHOD.md`](METHOD.md)。  
**业务不变**：身份仍以 **DID** 为键（注册 / 声誉 / 验证 / 归属 / 访客），不拆成数字 ID 业务主键。  
**P0 变现**：购买走 `PaymentIntent` 幂等 → 双分录 Ledger → OwnershipTransfer → Outbox（见 `settlement` 模块）。

权威约定：[`docs/ZENT.md`](../../docs/ZENT.md)

## 跑通

```bash
cd examples/metaverse-creative
zig build demo    # sqlite :memory:，DID + 三域 + P0 购买/对账/outbox
```

```bash
# Postgres（默认驱动）
ZENT_DRIVER=postgres PGHOST=127.0.0.1 PGDATABASE=metaverse \
  PGUSER=postgres PGPASSWORD=postgres zig-out/bin/metaverse-creative cli demo
```

## DID 业务面（与旧 demo 对齐）

| API | 说明 |
|-----|------|
| `registerCreator(did, name, wallet)` | DID 入驻 |
| `updateReputation(did, delta)` | 声誉 |
| `verifyCreator(did)` | 验证 |
| `creative.draft(owner_did=...)` | 三域草稿 |
| `settlement.purchase(key, id, buyer_did)` | 幂等购买（ledger + transfer） |
| `settlement.reconcile` / `outbox drain` | 对账 / 投递 stub |
| `world.visitWorld(id, visitor_did)` | 按访客 DID 查声誉算入场费 |

## 仅此一处结构变了

旧：自由 description。  
新：`problem` / `solution` / `world`（`insight|thesis|vision` 等，见 METHOD.md）。
