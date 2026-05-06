//! Promotion data model — marketing sub-module.
//! Group: marketing | AI Context: role=campaign_engine

pub const Promotion = struct {
    id: i64,
    name: []const u8,
    type: i32, // 10=full_reduce, 20=discount, 30=buy_give
    threshold_amount: f64,
    reduce_amount: f64,
    start_time: i64,
    end_time: i64,
    is_active: bool,
};
