//! Shared zent schema — DID-keyed identity + 三域创意 + P0 变现实体.
const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

comptime {
    @setEvalBranchQuota(200_000);
}

pub const Creator = Schema("Creator", .{
    .fields = &.{
        field.String("did"),
        field.String("display_name"),
        field.String("wallet"),
        field.Int("reputation"),
        field.Bool("verified"),
    },
});

pub const Creative = Schema("Creative", .{
    .fields = &.{
        field.String("owner_did"),
        field.String("title"),
        field.String("slug"),
        field.String("problem"),
        field.String("solution"),
        field.String("world"),
        field.String("status"),
        field.Int("price_cents"),
        field.Int("royalty_bps"),
    },
});

pub const Sale = Schema("Sale", .{
    .fields = &.{
        field.Int("creative_id"),
        field.String("seller_did"),
        field.String("buyer_did"),
        field.Int("price_cents"),
        field.Int("royalty_cents"),
        field.Int("payment_id"),
    },
});

pub const World = Schema("World", .{
    .fields = &.{
        field.String("owner_did"),
        field.String("name"),
        field.String("token_symbol"),
        field.Int("entry_fee_cents"),
        field.Int("visitor_count"),
        field.Int("revenue_cents"),
        field.Int("featured_creative_id"),
    },
});

/// P0: idempotent payment intent (gateway stub confirms in-process).
pub const PaymentIntent = Schema("PaymentIntent", .{
    .fields = &.{
        field.String("idempotency_key"),
        field.Int("creative_id"),
        field.String("buyer_did"),
        field.Int("amount_cents"),
        field.Int("platform_fee_cents"),
        field.Int("seller_net_cents"),
        field.String("status"), // created | succeeded | failed
        field.String("currency"),
    },
});

/// P0: double-entry line; journal_id == payment_id; amounts sum to 0.
pub const LedgerEntry = Schema("LedgerEntry", .{
    .fields = &.{
        field.Int("journal_id"),
        field.String("account"),
        field.Int("amount_cents"),
        field.String("memo"),
    },
});

/// P0: append-only ownership event; Creative.owner_did is projection.
pub const OwnershipTransfer = Schema("OwnershipTransfer", .{
    .fields = &.{
        field.Int("creative_id"),
        field.String("from_did"),
        field.String("to_did"),
        field.Int("payment_id"),
        field.String("license"), // personal | commercial
    },
});

/// P0: outbox stub (pending → published via CLI drain).
pub const OutboxEvent = Schema("OutboxEvent", .{
    .fields = &.{
        field.String("topic"),
        field.String("payload"),
        field.String("status"), // pending | published
        field.Int("retry_count"),
    },
});

const graph = zent.codegen.graph.buildGraph(&.{
    Creator,
    Creative,
    Sale,
    World,
    PaymentIntent,
    LedgerEntry,
    OwnershipTransfer,
    OutboxEvent,
});
pub const infos = graph.types;
pub const Client = zent.codegen.client.Client(infos);

pub const CreatorInfo = infos[0];
pub const CreativeInfo = infos[1];
pub const SaleInfo = infos[2];
pub const WorldInfo = infos[3];
pub const PaymentIntentInfo = infos[4];
pub const LedgerEntryInfo = infos[5];
pub const OwnershipTransferInfo = infos[6];
pub const OutboxEventInfo = infos[7];

pub const platform_fee_bps: i64 = 500; // 5%
