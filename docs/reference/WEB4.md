# Web4: DID Identity & x402 Payments

`zmodu.web4` provides self-certifying Ed25519 `did:key` decentralized identifiers, Verifiable Credentials, and HTTP 402 (`x402`) payment verification middleware.

Runnable example: [`examples/web4`](../../examples/web4).

## 1. DID Identity (`zmodu.web4.DidKey`)

Generate keys, sign challenges, and verify `did:key` signatures without external blockchain calls:

```zig
const web4 = zmodu.web4;

var key = try web4.DidKey.generate(allocator, io);
defer allocator.free(key.did);

const sig = try key.sign(allocator, "challenge-123");
defer allocator.free(sig);
const ok = try key.verify("challenge-123", sig); // true

// Resolve any public `did:key:z6Mk...` identifier for verification
var resolved = try web4.resolve(allocator, "did:key:z6Mk...");
defer allocator.free(resolved.did);
```

Use `web4.issueCredential` and `web4.verifyCredential` to issue and verify `VerifiableCredential` payloads.

## 2. x402 Payment Protocol (`zmodu.web4.x402`)

The x402 middleware gates endpoints behind HTTP `402 Payment Required`:
1. Requests without payment proof receive `402 Payment Required` with an `Invoice` JSON body.
2. Clients retry with `x402-tx-hash` and `x402-invoice-id` headers.
3. `PaymentVerifier` validates the proof. **Verification is fail-closed by default** (`verifyPaymentReject` rejects all proofs unless a real verifier or development `verifyPaymentAllowAll` is configured).

## 3. HTTP Middleware (`zmodu.web4.middleware`)

```zig
// 1. DID authentication middleware (must run BEFORE x402Middleware so payer attributes are set)
var challenges = web4.challenge.ChallengeStore.init(allocator, io);
defer challenges.deinit();

var did_cfg = web4.middleware.DidAuthConfig{
    .path_prefix = "/api/identity",
    .challenge_store = &challenges, // Verifies signature first, then consumes one-time challenge
};
try server.addMiddleware(web4.middleware.didAuthMiddleware(&did_cfg));

// 2. Persistent invoice store + x402 payment gate
var store = web4.x402_store.X402Store.init(allocator, &backend);
try store.migrate();

var x402_cfg = web4.middleware.X402Config{
    .verifier = my_verifier,
    .store = &store,
    .path_prefix = "/api/paid",
    .on_invoice = my_invoice_builder,
};
try server.addMiddleware(web4.middleware.x402Middleware(&x402_cfg));
```

## 4. Production Security Guarantees

- **`X402Store` is a ledger, not a verifier**: `X402Store` persists issued invoices and ensures each `invoice_id` is redeemed at most once (`already_used` → HTTP `410`, `not_found` / `expired` → HTTP `403`). Cryptographic or on-chain proof validation always runs through `X402Config.verifier`.
- **Payer binding**: When an invoice is created, `x402Middleware` records the authenticated payer from `ctx.attributes` (`did` or `user_id`, never from unverified client headers). On redemption, a mismatched payer returns `payer_mismatch` (`403`) without consuming the invoice. Mount `x402Middleware` **after** your identity middleware (DID or JWT).
- **One-time DID challenges (`ChallengeStore`)**: `ChallengeStore` mints short-lived CSPRNG challenges (`std.Io.randomSecure`). `didAuthMiddleware` verifies the Ed25519 signature **before** consuming the challenge so an attacker cannot burn a user's challenge with an invalid signature.
- **DID-to-JWT bridge**: Setting `DidAuthConfig.jwt_issuer = &app_sec` issues a framework JWT in the `x-did-token` response header upon successful DID authentication.
