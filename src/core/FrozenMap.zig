//! FrozenMap / FrozenStringMap — build-time-populated, run-time-read-only maps.
//!
//! The safe pattern for app-level shared registries (adapter tables, route
//! caches, feature flags): fill the map during startup, call `freeze()` when
//! the application starts serving, then hand out read-only access. Reads of a
//! frozen map need no lock — an immutable `std.HashMap` is safe for any
//! number of concurrent readers. Writes after freeze return `error.Frozen`,
//! turning a production data race (concurrent put/resize vs get — torn
//! metadata, misaligned pointers, `panic: incorrect alignment`) into a loud,
//! recoverable failure that surfaces in tests / at startup.
//!
//! ```zig
//! var adapters = zmodu.FrozenStringMap(Adapter).init(allocator);
//! try adapters.put("alipay", .{ ... });   // startup: free to write
//! adapters.freeze();                       // serving: read-only from here
//! const a = adapters.get("alipay");        // lock-free, thread-safe
//! try adapters.put("wechat", .{ ... });    // error.Frozen — no race
//! ```

const std = @import("std");

/// Raised by `put`/`putNoClobber`/`remove` once `freeze()` has been called.
///
/// It is the signal that a write arrived after the registry became read-only —
/// usually a registration happening outside startup. The map is unchanged when
/// this is returned (no partial write), so callers can either drop the write and
/// log it, or move the registration earlier, before `freeze()`.
pub const FrozenError = error{
    /// The map is frozen and immutable; the write did not happen.
    Frozen,
};

pub fn FrozenMap(comptime K: type, comptime V: type) type {
    return FrozenMapImpl(std.AutoHashMap(K, V), K, V);
}

pub fn FrozenStringMap(comptime V: type) type {
    return FrozenMapImpl(std.StringHashMap(V), []const u8, V);
}

fn FrozenMapImpl(comptime Map: type, comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        map: Map,
        frozen: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .map = Map.init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        /// Seal the map: from now on `put`/`remove` fail with error.Frozen and
        /// all reads are lock-free and safe for concurrent readers.
        pub fn freeze(self: *Self) void {
            self.frozen = true;
        }

        pub fn isFrozen(self: *const Self) bool {
            return self.frozen;
        }

        pub fn put(self: *Self, key: K, value: V) (FrozenError || std.mem.Allocator.Error)!void {
            if (self.frozen) return error.Frozen;
            return self.map.put(key, value);
        }

        pub fn remove(self: *Self, key: K) FrozenError!bool {
            if (self.frozen) return error.Frozen;
            return self.map.remove(key);
        }

        /// Read-only lookup. Safe to call from any thread once frozen (and
        /// from a single thread before that).
        pub fn get(self: *const Self, key: K) ?V {
            return self.map.get(key);
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.map.contains(key);
        }

        pub fn count(self: *const Self) u32 {
            return self.map.count();
        }

        /// Read-only iteration. The caller must not mutate the map through
        /// other references while iterating.
        pub fn iterator(self: *const Self) Map.Iterator {
            return self.map.iterator();
        }
    };
}

test "FrozenMap: write before freeze, lock-free reads after" {
    const allocator = std.testing.allocator;
    var m = FrozenMap(u32, u32).init(allocator);
    defer m.deinit();

    try m.put(1, 100);
    try m.put(2, 200);
    try std.testing.expect(!m.isFrozen());

    m.freeze();
    try std.testing.expect(m.isFrozen());
    try std.testing.expectEqual(@as(?u32, 100), m.get(1));
    try std.testing.expectEqual(@as(?u32, 200), m.get(2));
    try std.testing.expect(m.contains(2));
    try std.testing.expectEqual(@as(u32, 2), m.count());

    try std.testing.expectError(error.Frozen, m.put(3, 300));
    try std.testing.expectError(error.Frozen, m.remove(1));
    // Failed writes did not corrupt the frozen contents.
    try std.testing.expectEqual(@as(?u32, 100), m.get(1));
    try std.testing.expectEqual(@as(?u32, null), m.get(3));
}

test "FrozenStringMap: string keys, iterator is read-only view" {
    const allocator = std.testing.allocator;
    var m = FrozenStringMap(i64).init(allocator);
    defer m.deinit();

    try m.put("alipay", 1);
    try m.put("wechat", 2);
    m.freeze();

    try std.testing.expectEqual(@as(?i64, 1), m.get("alipay"));
    try std.testing.expectError(error.Frozen, m.put("stripe", 3));

    var seen: i64 = 0;
    var it = m.iterator();
    while (it.next()) |kv| seen += kv.value_ptr.*;
    try std.testing.expectEqual(@as(i64, 3), seen);
}

test "FrozenMap: remove works before freeze" {
    const allocator = std.testing.allocator;
    var m = FrozenMap(u8, u8).init(allocator);
    defer m.deinit();

    try m.put(1, 1);
    try std.testing.expect(try m.remove(1));
    try std.testing.expectEqual(@as(?u8, null), m.get(1));
}
