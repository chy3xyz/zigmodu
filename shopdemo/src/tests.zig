const std = @import("std");
const business = @import("business/root.zig");

test "suite" {
    _ = business;
    try std.testing.expect(true);
}
