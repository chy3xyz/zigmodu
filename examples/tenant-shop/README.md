**Week 1–4 完整脚手架**：交易闭环 + admin 编排 + outbox 重试/DLQ → RobustMQ。  
分层规范见 [`docs/MODULE_LAYERS.md`](../../docs/MODULE_LAYERS.md)。

## Run

```bash
cd examples/tenant-shop
HTTP_PORT=18090 zig build run
# ROBUSTMQ_URL=127.0.0.1:9092  # online
# TENANT_SHOP_SQLITE=./shop.db OUTBOX_POLL_MS=500
```

## Smoke — admin + DLQ

```bash
curl -s -X POST 'http://127.0.0.1:18090/api/v1/tenants?name=Acme&domain=acme.example.com&tier=pro'
curl -s -X POST 'http://127.0.0.1:18090/api/v1/admin/products?tenant_id=1&name=Widget&price_cents=1999'
curl -s -X POST 'http://127.0.0.1:18090/api/v1/admin/inventory?tenant_id=1&product_id=1&qty=100'
curl -s -X POST 'http://127.0.0.1:18090/api/v1/users?tenant_id=1&username=alice&email=a@acme.test&role=customer'
curl -s -X POST 'http://127.0.0.1:18090/api/v1/cart/items?tenant_id=1&user_id=1&product_id=1&qty=1'
curl -s -X POST 'http://127.0.0.1:18090/api/v1/shop/checkout?tenant_id=1&user_id=1'
# force fail → DLQ (max_retries=3)
curl -s -X POST 'http://127.0.0.1:18090/api/v1/admin/outbox/drain?simulate_fail=1'
curl -s -X POST 'http://127.0.0.1:18090/api/v1/admin/outbox/drain?simulate_fail=1'
curl -s -X POST 'http://127.0.0.1:18090/api/v1/admin/outbox/drain?simulate_fail=1'
curl -s 'http://127.0.0.1:18090/api/v1/admin/outbox/dlq'
curl -s -X POST 'http://127.0.0.1:18090/api/v1/admin/outbox/requeue?id=1'
curl -s -X POST 'http://127.0.0.1:18090/api/v1/admin/outbox/drain'
```

## Routes

| Area | Paths |
|------|-------|
| shop_bff | `/shop/checkout` `/shop/pay` |
| admin_bff | `/admin/products` `/admin/inventory` `/admin/orders` `/admin/outbox*` |
| outbox | `/outbox` `/outbox/drain` `/outbox/dlq` `/outbox/requeue` |

Outbox 状态：`pending` →（失败）重试 → `dlq`；`requeue` 重置后可再 `published`。

## Next

1. CI smoke 脚本  
2. Outbox 延迟重试（`next_attempt_at`）  
3. `inventory.stock_low` 事件  
