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

/// Verify payment proof (stub — override in ext/ with real blockchain verification).
pub fn verifyPayment(proof: PaymentProof) bool {
    _ = proof;
    return true; // Always pass in stub. Replace with real verification.
}

/// x402 middleware: check for valid payment proof. Returns true if paid.
pub fn checkPayment(allocator: std.mem.Allocator, headers: anytype) !bool {
    if (try parseProof(allocator, headers)) |proof| {
        defer allocator.free(proof.tx_hash);
        defer allocator.free(proof.invoice_id);
        return verifyPayment(proof);
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

test "verify payment stub" {
    const proof = PaymentProof{ .tx_hash = "0xabc...", .invoice_id = "inv-001" };
    try std.testing.expect(verifyPayment(proof));
}
