pub const PurchaseCmd = struct {
    idempotency_key: []const u8,
    creative_id: i64,
    buyer_did: []const u8,
    license: []const u8 = "personal",
};

pub const PurchaseResult = struct {
    payment_id: i64,
    transfer_id: i64,
    sale_id: i64,
    amount_cents: i64,
    platform_fee_cents: i64,
    seller_net_cents: i64,
    idempotent_replay: bool,
};

pub const ReconcileReport = struct {
    ledger_sum_cents: i64,
    succeeded_payments: usize,
    transfers: usize,
    pending_outbox: usize,
    balanced: bool,
};

pub const PaymentDto = struct {
    id: i64,
    idempotency_key: []const u8,
    status: []const u8,
    amount_cents: i64,
    creative_id: i64,
    buyer_did: []const u8,
};
