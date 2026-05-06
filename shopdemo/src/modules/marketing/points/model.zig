//! Points data model — marketing sub-module.
//! Group: marketing | AI Context: role=loyalty_engine

pub const PointsRule = struct {
    id: i64,
    name: []const u8,
    earn_rate: f64, // points per yuan spent
    spend_rate: f64, // yuan per point redeemed
    min_redeem: i64, // minimum points to redeem
    is_active: bool,
};
