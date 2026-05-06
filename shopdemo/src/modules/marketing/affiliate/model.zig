//! Affiliate data model — marketing sub-module.
//! Group: marketing | AI Context: role=referral_engine

pub const AffiliateLink = struct {
    id: i64,
    user_id: i64,
    code: []const u8,
    click_count: i64,
    register_count: i64,
    commission_rate: f64,
};
