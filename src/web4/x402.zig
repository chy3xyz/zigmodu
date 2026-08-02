//! HTTP 402 / x402 monetization helpers (production-ready).
//!
//! Payment verification is **fail-closed by default**. Production code must
//! inject an explicit `PaymentVerifier` (on-chain check, allow-list, etc.).
//! Never treat a bare `verifyPayment` / missing verifier as "paid".
//! For persisted, exactly-once redemption use `x402_store.X402Store` with
//! `middleware.x402Middleware` (see docs/WEB4.md).

const std = @import("std");

/// HTTP 402 Payment Required — Web4 monetization protocol.
/// Server returns 402 with invoice; client pays and retries with proof.
pub const Currency = enum { usdc, eth, sol, btc };

pub const Invoice = struct {
    id: []const u8,
    payee_did: []const u8, // DID of payment recipient
    amount: u64,
    currency: Currency,
    chain_id: u64 = 1, // Ethereum mainnet
    deadline: i64, // Unix timestamp
    description: []const u8,
};

/// Write a 402 response with invoice as JSON body.
pub fn writePaymentRequired(ctx: anytype, allocator: std.mem.Allocator, invoice: Invoice) !void {
    const currency_str = switch (invoice.currency) {
        .usdc => "USDC",
        .eth => "ETH",
        .sol => "SOL",
        .btc => "BTC",
    };
    const body = try std.fmt.allocPrint(allocator,
        \\{{"code":402,"msg":"Payment Required","data":{{"invoice_id":"{s}","payee":"{s}","amount":{d},"currency":"{s}","deadline":{d},"description":"{s}"}}}}
    , .{ invoice.id, invoice.payee_did, invoice.amount, currency_str, invoice.deadline, invoice.description });
    defer allocator.free(body);
    try ctx.json(402, body);
}

/// Parse x402 payment proof from request headers.
pub fn parseProof(allocator: std.mem.Allocator, headers: anytype) !?PaymentProof {
    const tx_hash = try headers.getFirst("x402-tx-hash") orelse return null;
    const invoice_id = try headers.getFirst("x402-invoice-id") orelse return null;
    return .{ .tx_hash = try allocator.dupe(u8, tx_hash), .invoice_id = try allocator.dupe(u8, invoice_id) };
}

pub const PaymentProof = struct {
    tx_hash: []const u8,
    invoice_id: []const u8,
};

/// Pluggable verifier — required for any “paid” decision in production.
pub const PaymentVerifier = *const fn (proof: PaymentProof) bool;

/// Fail-closed default: always reject. Safe for accidental use in hot paths.
pub fn verifyPaymentReject(_: PaymentProof) bool {
    return false;
}

/// Dev-only: always accept. Must be passed explicitly — never the default.
pub fn verifyPaymentAllowAll(_: PaymentProof) bool {
    return true;
}

/// Verify with an explicit verifier (preferred API).
pub fn verifyWith(verifier: PaymentVerifier, proof: PaymentProof) bool {
    return verifier(proof);
}

/// Fail-closed convenience (same as `verifyPaymentReject`).
/// Kept for call-site compatibility; does **not** accept payments.
pub fn verifyPayment(proof: PaymentProof) bool {
    return verifyPaymentReject(proof);
}

/// x402 middleware helper: check for valid payment proof.
/// Uses fail-closed default verifier unless `verifier` is provided.
pub fn checkPayment(allocator: std.mem.Allocator, headers: anytype) !bool {
    return checkPaymentWith(allocator, headers, verifyPaymentReject);
}

pub fn checkPaymentWith(allocator: std.mem.Allocator, headers: anytype, verifier: PaymentVerifier) !bool {
    if (try parseProof(allocator, headers)) |proof| {
        defer allocator.free(proof.tx_hash);
        defer allocator.free(proof.invoice_id);
        return verifyWith(verifier, proof);
    }
    return false;
}

test "create invoice" {
    const inv = Invoice{
        .id = "inv-001",
        .payee_did = "did:key:z6Mk...",
        .amount = 1000000, // $1.00 USDC (6 decimals)
        .currency = .usdc,
        .deadline = 0,
        .description = "API access — 1000 requests",
    };
    try std.testing.expectEqualStrings("inv-001", inv.id);
}

test "verify payment fail-closed by default" {
    const proof = PaymentProof{ .tx_hash = "0xabc...", .invoice_id = "inv-001" };
    try std.testing.expect(!verifyPayment(proof));
    try std.testing.expect(!verifyPaymentReject(proof));
}

test "verifyPaymentAllowAll is explicit opt-in" {
    const proof = PaymentProof{ .tx_hash = "0xabc...", .invoice_id = "inv-001" };
    try std.testing.expect(verifyWith(verifyPaymentAllowAll, proof));
}
