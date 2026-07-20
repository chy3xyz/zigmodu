//! Creator identity — DID is the business key (same as legacy IdentityModule).
pub const CreatorDto = struct {
    id: i64,
    did: []const u8,
    display_name: []const u8,
    wallet: []const u8,
    reputation: i64,
    verified: bool,

    pub fn reputationLevel(self: CreatorDto) ReputationLevel {
        return if (self.reputation >= 8000) .legend else if (self.reputation >= 6000) .expert else if (self.reputation >= 4000) .established else if (self.reputation >= 2000) .rising else .novice;
    }
};

pub const ReputationLevel = enum {
    novice,
    rising,
    established,
    expert,
    legend,

    pub fn multiplier(self: ReputationLevel) f64 {
        return switch (self) {
            .novice => 1.0,
            .rising => 1.2,
            .established => 1.5,
            .expert => 2.0,
            .legend => 3.0,
        };
    }
};
