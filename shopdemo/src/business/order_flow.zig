//! Order state machine — validates transitions.

const enums = @import("enums.zig");
const std = @import("std");

pub fn isValidTransition(from: enums.OrderStatus, to: enums.OrderStatus) bool {
    return switch (from) {
        .pending => to == .paid or to == .cancelled,
        .paid => to == .shipped or to == .refunding,
        .shipped => to == .received or to == .refunding,
        .received => to == .completed or to == .refunding,
        .refunding => to == .cancelled,
        .completed, .cancelled => false,
    };
}
pub fn canRefund(s: enums.OrderStatus) bool { return isValidTransition(s, .refunding); }
pub fn isTerminal(s: enums.OrderStatus) bool { return s == .completed or s == .cancelled; }

test "valid" { try std.testing.expect(isValidTransition(.pending, .paid)); }
test "invalid" { try std.testing.expect(!isValidTransition(.pending, .shipped)); }
