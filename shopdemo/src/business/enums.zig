//! Business enums — exact values matching PHP/DB integer constants.

pub const OrderStatus = enum(i32) {
    pending = 10, paid = 20, shipped = 30, received = 40,
    completed = 50, cancelled = 60, refunding = 70,
};
pub const RefundStatus = enum(i32) { pending = 10, approved = 20, rejected = 30, refunded = 40 };
pub const AgentLevel = enum(i32) { none = 0, first = 1, second = 2, third = 3 };
pub const PayType = enum(i32) { wechat = 10, alipay = 20, bank = 30, balance = 40 };
