//! Coupon data model — marketing sub-module.
//! Group: marketing | AI Context: role=discount_engine

pub const Coupon = struct {
    id: i64,
    code: []const u8,
    discount_type: i32, // 10=fixed, 20=percent
    discount_value: f64,
    min_order_amount: f64,
    start_time: i64,
    end_time: i64,
    is_active: bool,

    pub fn isValid(self: Coupon, current_time: i64) bool {
        return self.is_active and current_time >= self.start_time and current_time <= self.end_time;
    }
};
