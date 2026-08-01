# Web4：DID 身份 + x402 支付

> zigmodu 的 Web4 原语：`zigmodu.web4`（DID `did:key` 身份 + HTTP 402/x402
> 支付协议）与 HTTP 中间件（`zigmodu.web4.middleware`）。配套示例：
> [`examples/web4`](../examples/web4)。

## 1. DID 身份（`zigmodu.web4.DidKey`）

Ed25519 `did:key` 自证明身份（无需区块链）：

```zig
const web4 = zigmodu.web4;

var key = try web4.DidKey.generate(allocator, io);
defer allocator.free(key.did);
const sig = try key.sign(allocator, "challenge-123");
defer allocator.free(sig);
const ok = try key.verify("challenge-123", sig); // true

// 解析任意 did:key（仅公钥，可验证签名）
var resolved = try web4.resolve(allocator, "did:key:z6Mk...");
defer allocator.free(resolved.did);
```

`VerifiableCredential`：`issueCredential` / `verifyCredential` 签发与验证可验证凭证。

## 2. x402 支付（`zigmodu.web4.x402`）

HTTP 402 变现协议：服务端返回 402 + invoice，客户端支付后带 proof 重试。

- `Invoice` + `writePaymentRequired(ctx, allocator, invoice)`：生成 402 JSON；
- `parseProof` / `PaymentProof`：读取 `x402-tx-hash` / `x402-invoice-id` 头；
- `PaymentVerifier` 可插拔验证器；**默认 fail-closed**（`verifyPaymentReject` 永拒；
  dev 才显式注入 `verifyPaymentAllowAll`；生产注入链上/白名单验证器）。

## 3. HTTP 中间件（`zigmodu.web4.middleware`）

```zig
// x402 支付门：保护 /api/paid —— 无 proof → 402 + invoice；无效 → 403；通过 → 放行
var x402_cfg = web4.middleware.X402Config{
    .verifier = my_verifier,        // 生产：链上/白名单；fail-closed 默认
    .path_prefix = "/api/paid",     // 全局挂载时按路径生效
    .on_invoice = my_invoice_builder, // 可选：按路由定价
};
try server.addMiddleware(web4.middleware.x402Middleware(&x402_cfg));

// DID 认证：保护 /api/identity —— 缺签名 → 401；签名有效 → 写 did / user_id attrs
var did_cfg = web4.middleware.DidAuthConfig{ .path_prefix = "/api/identity" };
try server.addMiddleware(web4.middleware.didAuthMiddleware(&did_cfg));
```

`path_prefix` 使全局中间件可以按路由生效；不设置则保护全部路径。

### 生产加固

**invoice 持久化 + 幂等核销（防重放）**：`zigmodu.web4.x402_store.X402Store`
（SQL 表）创建 invoice 落库；proof 到达时 `redeem(invoice_id, tx_hash)`
**每个 invoice 恰好核销一次**——重复 proof 返回 `already_used`（410），
未知/过期分别返回 `not_found` / `expired`。挂到中间件：

```zig
var store = web4.x402_store.X402Store.init(allocator, &backend);
try store.migrate();
var x402_cfg = web4.middleware.X402Config{
    .store = &store,             // 替代裸 verifier：落库 + 核销
    .path_prefix = "/api/paid",
};
```

**DID 一次性 challenge（防重放）**：`zigmodu.web4.challenge.ChallengeStore`
签发短时随机 challenge，`verifyAndConsume` 每个 challenge 只接受一次：

```zig
var challenges = web4.challenge.ChallengeStore.init(allocator, io);
defer challenges.deinit();
var did_cfg = web4.middleware.DidAuthConfig{
    .path_prefix = "/api/identity",
    .challenge_store = &challenges,   // 签名前必须先通过一次性 challenge
};
```

**DID → JWT 串联**：`DidAuthConfig.jwt_issuer` 挂 `AppSecurity` 后，认证成功
自动签发 JWT 于 `x-did-token` 响应头——客户端可继续走框架 JWT 中间件链
（`jwtAuthFromCatalogWithPermissions` / RBAC）。

## 4. 示例

```bash
cd examples/web4 && zig build run
# x402:
curl -i http://127.0.0.1:18089/api/paywall                        # 402 + invoice
curl -i -H 'x402-tx-hash: 0x1' -H 'x402-invoice-id: inv' \
       http://127.0.0.1:18089/api/paywall                         # 200（dev verifier）
# DID:
curl -i http://127.0.0.1:18089/api/identity                       # 401
# 用 DidKey 生成签名后带 x-did / x-did-message / x-did-signature → 200
zig build test                                                    # 2 个端到端断言
```

## 5. 安全默认

- 支付验证 **fail-closed**：未注入验证器 = 全部拒绝；`verifyPaymentAllowAll` 仅限 dev。
- DID 认证：消息由客户端提供，生产应绑定一次性 challenge（防重放）。
- invoice 持久化 / 幂等（invoice_id 核销）由应用层接入。
