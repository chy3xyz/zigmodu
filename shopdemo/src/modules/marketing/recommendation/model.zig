//! Recommendation data model — marketing sub-module.
//! Group: marketing | AI Context: role=personalization_engine

pub const RecommendationConfig = struct {
    id: i64,
    user_id: i64,
    product_id: i64,
    score: f64,
    reason: []const u8,
    created_at: i64,
};
