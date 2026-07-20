# 资产即创意 — 三域方法论模板（AI-ready）

**定位**：创意资产 = 可发布、可售卖、可挂到世界的结构化想法。  
**三个域**必须同时填，才能 `publish`（见 CLI / HTTP）。

---

## 模板（复制即用）

```yaml
title: "<一句话产品名>"
slug: "<url-safe-id>"

# ── 问题域 Problem（WHY）── AI 可完善商机与愿景
problem:
  insight: "<商机洞察：谁在痛、多大、为何现在>"   # 1–2 句
  thesis:  "<核心理念：你相信什么>"                 # 1 句
  vision:  "<愿景：成功后世界怎样>"                 # 1 句

# ── 解决域 Solution（HOW）── AI 可完善方案与变现
solution:
  approach:      "<解决方案：核心做法>"
  monetization:  "<商业手段：谁付钱、怎么付>"
  ecosystem:     "<生态方案：伙伴 / API / 分成>"

# ── 世界域 World（WHERE）── AI 可完善呈现与世界观
world:
  venue: "<落地载体：metaverse scene / app / API / doc>"
  form:  "<呈现形式：3D asset / 场景包 / 剧本 / NFT>"
  lore:  "<世界观渲染：氛围、规则、符号，3 句内>"
```

---

## 填写准则（给 AI Agent）

| 域 | 禁止 | 必须 |
|----|------|------|
| Problem | 空话、无受众 | 可验证的痛点 + 时机 |
| Solution | 只谈技术不谈钱 | 变现路径可执行 |
| World | 纯概念无载体 | 说得清「用户看到什么」 |

长度：每字段 **≤ 280 字符**（本 demo 硬限制），便于向量检索与 prompt。

---

## 状态机（赚钱路径）

```
draft ──publish──► published ──settlement.purchase(idempotency_key)──► sold
                      │                    │
                      │                    ├── PaymentIntent (succeeded)
                      │                    ├── Ledger ×3 (sum=0)
                      │                    ├── OwnershipTransfer
                      │                    └── Outbox payment.succeeded
                      └── attach World.featured_creative_id
```

早期产品闭环：**发布创意 → 定价上架 → 幂等购买确权（P0）→ 挂到世界获客**。  
CLI：`settlement purchase --key=...`；`reconcile` 校验 ledger 合计为 0。

---

## Zig 字段映射

| 模板键 | Schema 字段（`|` 分隔子项） |
|--------|-------------------------------|
| `problem.insight\|thesis\|vision` | `problem` |
| `solution.approach\|monetization\|ecosystem` | `solution` |
| `world.venue\|form\|lore` | `world` |

字段合并为三条字符串，避免 schema 过宽；语义仍按 METHOD 三域解析（AI Agent 读写时拆 `|`）。
