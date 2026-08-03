//! Arena-backed read result. `items` borrows one arena (string fields are
//! NOT per-field copies), so bulk reads avoid one allocation per string.
//! `deinit` frees the arena exactly once — no per-item freeScanned.
//!
//! ```zig
//! var result = try client.queryRows(User, sql, &.{});
//! const take = result.take();
//! var set = ResultSet(User){ .items = take.items, .arena = take.arena };
//! defer set.deinit(allocator);
//! for (set.items) |u| { … }
//! ```

const std = @import("std");

pub fn ResultSet(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        /// When set, owns all string data and the items slice (arena-backed
        /// query). When null, items must be trivially freeable — deinit only
        /// frees the slice buffer.
        arena: ?std.heap.ArenaAllocator = null,

        pub fn fromOwned(items: []T, arena: ?std.heap.ArenaAllocator) Self {
            return .{ .items = items, .arena = arena };
        }

        /// Free owned memory once: arena path frees the arena; arena-less
        /// path frees only the items slice (caller owns any nested strings).
        pub fn deinit(self: *const Self, allocator: std.mem.Allocator) void {
            const m: *Self = @constCast(self);
            if (m.arena) |*a| {
                a.deinit();
                m.arena = null;
                m.items = &.{};
                return;
            }
            allocator.free(m.items);
            m.items = &.{};
        }
    };
}

test "ResultSet arena deinit clears state" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    const User = struct { id: i64 };
    var set = ResultSet(User){
        .items = arena.allocator().alloc(User, 2) catch return error.OutOfMemory,
        .arena = arena,
    };
    set.deinit(allocator);
    try std.testing.expect(set.items.len == 0);
    try std.testing.expect(set.arena == null);
}
