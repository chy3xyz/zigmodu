//! Agent commission calculation — pure math, no DB access.

const enums = @import("enums.zig");
const std = @import("std");

pub const CommissionResult = struct {
    first_money: f64, second_money: f64, third_money: f64, total: f64,
};

pub fn calculate(order_amount: f64, first_rate: f64, second_rate: f64, third_rate: f64) CommissionResult {
    const f = @round(order_amount * (first_rate / 100.0) * 100.0) / 100.0;
    const s = @round(order_amount * (second_rate / 100.0) * 100.0) / 100.0;
    const t = @round(order_amount * (third_rate / 100.0) * 100.0) / 100.0;
    return .{ .first_money = f, .second_money = s, .third_money = t, .total = @round((f + s + t) * 100.0) / 100.0 };
}

test "basic" { const r = calculate(100, 10, 5, 3); try std.testing.expectEqual(@as(f64, 10.0), r.first_money); try std.testing.expectEqual(@as(f64, 18.0), r.total); }
