pub const CreativeDraft = struct {
    owner_did: []const u8,
    title: []const u8,
    slug: []const u8,
    /// METHOD.md: insight|thesis|vision
    problem: []const u8,
    /// METHOD.md: approach|monetization|ecosystem
    solution: []const u8,
    /// METHOD.md: venue|form|lore
    world: []const u8,
    price_cents: i64 = 0,
};

pub const CreativeDto = struct {
    id: i64,
    owner_did: []const u8,
    title: []const u8,
    slug: []const u8,
    status: []const u8,
    price_cents: i64,
    problem: []const u8,
    solution: []const u8,
    world: []const u8,
};
