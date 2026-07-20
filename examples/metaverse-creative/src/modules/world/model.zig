pub const WorldDto = struct {
    id: i64,
    owner_did: []const u8,
    name: []const u8,
    token_symbol: []const u8,
    entry_fee_cents: i64,
    visitor_count: i64,
    revenue_cents: i64,
    featured_creative_id: i64,
};
