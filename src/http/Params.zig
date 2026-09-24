//! `Params` — the multi-value container behind `ctx.query` and `ctx.form`.
//!
//! Why not a plain `StringHashMap`: HTML's native shapes for "several values
//! for one name" are
//!
//!   1. repeated keys — `<select multiple>` / checkbox groups: `ids=1&ids=2`
//!   2. bracket keys   — PHP/Rails/qs style: `role_id[0]=7`, `tags[]=a`
//!
//! A single-value map silently loses (1) and cannot express (2). `Params` keeps
//! every occurrence in arrival order and offers three read styles:
//!
//! ```zig
//! ctx.query.get("ids")            // last occurrence (historical semantics)
//! ctx.query.getFirst("ids")       // first occurrence
//! ctx.query.getAll("ids")         // all occurrences, arrival order
//! ctx.form.?.getArray(alloc, "role_id")   // ids + role_id[0..n] + role_id[]
//! ctx.query.getPath("filter.tags")        // dotted path → filter[tags]
//! ```
//!
//! Ordering note: `get` returns the **last** value because that is what the old
//! single-value map did (`put` overwrote), so existing callers keep their
//! behavior. Use `getFirst` when you want the first.

const std = @import("std");

pub const Params = struct {
    allocator: std.mem.Allocator,
    map: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,

    pub fn init(allocator: std.mem.Allocator) Params {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Params) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |v| self.allocator.free(v);
            entry.value_ptr.deinit(self.allocator);
        }
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    /// Duplicate `name`/`value` and append. Repeated names accumulate.
    pub fn put(self: *Params, name: []const u8, value: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        const gop = try self.map.getOrPut(self.allocator, name_copy);
        if (!gop.found_existing) {
            gop.key_ptr.* = name_copy;
            gop.value_ptr.* = .empty;
        }
        errdefer if (!gop.found_existing) {
            _ = self.map.swapRemove(name_copy);
        };
        try gop.value_ptr.append(self.allocator, value_copy);
        // The map owns one copy of the name; ours is redundant. Released only
        // after the append succeeded: freeing it earlier would leave the
        // errdefer above releasing the same copy a second time.
        if (gop.found_existing) self.allocator.free(name_copy);
    }

    /// Like `put`, but takes ownership of already-allocated `name`/`value`
    /// (no copy). Used by the request parsers, which decode straight into
    /// owned buffers — `put` there would duplicate every byte twice.
    ///
    /// Ownership contract: **on success both slices belong to `Params`**; on
    /// error the caller still owns them (nothing is freed here). Callers
    /// transfer with `catch |err| { allocator.free(name); allocator.free(value);
    /// return err; }` so a later error in the same scope cannot double-free.
    pub fn putOwned(self: *Params, name: []const u8, value: []const u8) !void {
        const gop = try self.map.getOrPut(self.allocator, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;

        gop.value_ptr.append(self.allocator, value) catch |err| {
            // Nothing is freed here: the caller still owns both slices. The
            // only thing to undo is the entry we just inserted for a new name.
            if (!gop.found_existing) _ = self.map.swapRemove(name);
            return err;
        };

        if (gop.found_existing) {
            // The map already owns a copy of this name; ours is redundant.
            // Freed only now that the append has succeeded — freeing it earlier
            // would hand the caller back a dangling slice, which it frees again.
            self.allocator.free(name);
        }
    }

    /// Last occurrence (see the ordering note above). Null when absent.
    pub fn get(self: *const Params, name: []const u8) ?[]const u8 {
        const list = self.map.get(name) orelse return null;
        if (list.items.len == 0) return null;
        return list.items[list.items.len - 1];
    }

    pub fn getFirst(self: *const Params, name: []const u8) ?[]const u8 {
        const list = self.map.get(name) orelse return null;
        if (list.items.len == 0) return null;
        return list.items[0];
    }

    /// Every occurrence of `name`, arrival order.
    pub fn getAll(self: *const Params, name: []const u8) []const []const u8 {
        const list = self.map.get(name) orelse return &.{};
        return list.items;
    }

    pub fn count(self: *const Params) usize {
        return self.map.count();
    }

    /// Total occurrences across all names (the number a parameter-limit guard
    /// cares about).
    pub fn totalValues(self: *const Params) usize {
        var n: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |e| n += e.value_ptr.items.len;
        return n;
    }

    pub fn contains(self: *const Params, name: []const u8) bool {
        return self.map.contains(name);
    }

    /// Bracket/repeated-key array read, in the order a client would expect:
    /// indexed keys (`name[0]`, `name[1]`, …) sorted numerically, then append
    /// keys (`name[]`) in arrival order. Falls back to repeated plain keys
    /// (`name=a&name=b`) when there are no bracket forms.
    /// Caller owns the slice (not the inner values).
    pub fn getArray(self: *const Params, allocator: std.mem.Allocator, name: []const u8) ![][]const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(allocator);

        // Indexed forms, sorted by index; missing indices keep their relative
        // order rather than being renumbered.
        var indexed: std.ArrayListUnmanaged(struct { idx: u64, value: []const u8 }) = .empty;
        defer indexed.deinit(allocator);
        var appended: std.ArrayListUnmanaged([]const u8) = .empty;
        defer appended.deinit(allocator);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.len <= name.len or !std.mem.startsWith(u8, key, name) or key[name.len] != '[') continue;
            if (key[key.len - 1] != ']') continue;
            const inner = key[name.len + 1 .. key.len - 1];
            if (inner.len == 0) {
                for (entry.value_ptr.items) |v| try appended.append(allocator, v);
                continue;
            }
            const idx = std.fmt.parseInt(u64, inner, 10) catch continue;
            for (entry.value_ptr.items) |v| try indexed.append(allocator, .{ .idx = idx, .value = v });
        }

        if (indexed.items.len == 0 and appended.items.len == 0) {
            // Repeated plain keys.
            for (self.getAll(name)) |v| try out.append(allocator, v);
            return out.toOwnedSlice(allocator);
        }

        std.mem.sort(@TypeOf(indexed.items[0]), indexed.items, {}, struct {
            fn lt(_: void, a: @TypeOf(indexed.items[0]), b: @TypeOf(indexed.items[0])) bool {
                return a.idx < b.idx;
            }
        }.lt);
        for (indexed.items) |e| try out.append(allocator, e.value);
        for (appended.items) |v| try out.append(allocator, v);
        return out.toOwnedSlice(allocator);
    }

    /// Dotted path lookup: `"filter.tags"` → tries the literal key first, then
    /// the PHP-style bracket form `filter[tags]`.
    pub fn getPath(self: *const Params, path: []const u8) ?[]const u8 {
        if (self.get(path)) |v| return v;
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        var first = true;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (first) {
                if (seg.len > buf.len) return null;
                @memcpy(buf[0..seg.len], seg);
                len = seg.len;
                first = false;
            } else {
                const need = 2 + seg.len;
                if (len + need > buf.len) return null;
                buf[len] = '[';
                @memcpy(buf[len + 1 ..][0..seg.len], seg);
                len += 1 + seg.len;
                buf[len] = ']';
                len += 1;
            }
        }
        if (first) return null; // empty path
        return self.get(buf[0..len]);
    }

    /// Force the dotted-index form (`a[0].b` → `a[0][b]`), used by callers that
    /// already hold segments.
    pub fn getSegments(self: *const Params, segments: []const []const u8) ?[]const u8 {
        if (segments.len == 0) return null;
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        for (segments, 0..) |seg, i| {
            if (i == 0) {
                if (seg.len > buf.len) return null;
                @memcpy(buf[0..seg.len], seg);
                len = seg.len;
                continue;
            }
            if (len + 2 + seg.len > buf.len) return null;
            buf[len] = '[';
            @memcpy(buf[len + 1 ..][0..seg.len], seg);
            len += 1 + seg.len;
            buf[len] = ']';
            len += 1;
        }
        return self.get(buf[0..len]);
    }
};

const testing = std.testing;

test "Params: repeated keys keep every value; get returns the last" {
    const allocator = testing.allocator;
    var p = Params.init(allocator);
    defer p.deinit();

    try p.put("ids", "1");
    try p.put("ids", "2");
    try p.put("ids", "3");
    try p.put("page", "1");

    try testing.expectEqual(@as(usize, 2), p.count());
    try testing.expectEqual(@as(usize, 4), p.totalValues());
    try testing.expectEqualStrings("3", p.get("ids").?); // historical (last-wins)
    try testing.expectEqualStrings("1", p.getFirst("ids").?);
    try testing.expectEqual(@as(usize, 3), p.getAll("ids").len);
    try testing.expectEqualStrings("1", p.getAll("ids")[0]);
    try testing.expectEqualStrings("3", p.getAll("ids")[2]);
    try testing.expect(p.getAll("missing").len == 0);
}

test "Params: bracket arrays (indexed + append + fallback)" {
    const allocator = testing.allocator;
    var p = Params.init(allocator);
    defer p.deinit();

    // Deliberately out of order: the read must be sorted by index.
    try p.put("role_id[1]", "20");
    try p.put("role_id[0]", "10");
    try p.put("role_id[]", "30");
    try p.put("role_id[]", "40");

    const arr = try p.getArray(allocator, "role_id");
    defer allocator.free(arr);
    try testing.expectEqual(@as(usize, 4), arr.len);
    try testing.expectEqualStrings("10", arr[0]);
    try testing.expectEqualStrings("20", arr[1]);
    try testing.expectEqualStrings("30", arr[2]); // append entries follow, in arrival order
    try testing.expectEqualStrings("40", arr[3]);

    // No bracket forms → repeated plain keys are the array.
    try p.put("ids", "a");
    try p.put("ids", "b");
    const plain = try p.getArray(allocator, "ids");
    defer allocator.free(plain);
    try testing.expectEqual(@as(usize, 2), plain.len);
    try testing.expectEqualStrings("a", plain[0]);
    try testing.expectEqualStrings("b", plain[1]);

    // A name used both ways merges: `tags` plain values stay as-is (no brackets).
    const none = try p.getArray(allocator, "absent");
    defer allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "Params: dotted path lookup and segment lookup" {
    const allocator = testing.allocator;
    var p = Params.init(allocator);
    defer p.deinit();

    try p.put("filter[tags]", "new");
    try p.put("literal.key", "direct");
    try p.put("params[balance][money]", "9.99");

    try testing.expectEqualStrings("new", p.getPath("filter.tags").?);
    try testing.expectEqualStrings("direct", p.getPath("literal.key").?); // literal wins
    try testing.expectEqualStrings("9.99", p.getPath("params.balance.money").?);
    try testing.expect(p.getPath("params.missing.money") == null);
    try testing.expectEqualStrings("9.99", p.getSegments(&.{ "params", "balance", "money" }).?);
}

// `putOwned`'s ownership contract when an insert fails: the caller keeps both
// slices. Both request parsers free them on error (`src/api/Server.zig:1281`,
// `:1306`), so a slice freed here is freed a second time by the caller.
test "Params: putOwned keeps the caller's slices when the value append fails" {
    const testing_alloc = testing.allocator;

    // New name: the map insert is allocation #0, the value append is #1.
    {
        var fa = std.testing.FailingAllocator.init(testing_alloc, .{});
        var p = Params.init(fa.allocator());
        defer p.deinit();

        const name = try testing_alloc.dupe(u8, "k");
        const value = try testing_alloc.dupe(u8, "v");
        fa.fail_index = fa.alloc_index + 1;
        try testing.expectError(error.OutOfMemory, p.putOwned(name, value));
        try testing.expect(fa.has_induced_failure);

        // The contract: free them once, here.
        testing_alloc.free(name);
        testing_alloc.free(value);
        try testing.expect(!p.contains("k"));
        try testing.expectEqual(@as(usize, 0), p.count());
    }

    // Existing name: the value list is at capacity, so the append is the only
    // allocation the call needs to make.
    {
        var fa = std.testing.FailingAllocator.init(testing_alloc, .{});
        var p = Params.init(fa.allocator());
        defer p.deinit();
        while (true) {
            const list = p.map.get("k") orelse {
                try p.put("k", "seed");
                continue;
            };
            if (list.items.len >= list.capacity) break;
            try p.put("k", "seed");
        }
        const before = p.getAll("k").len;

        const name = try testing_alloc.dupe(u8, "k");
        const value = try testing_alloc.dupe(u8, "v");
        fa.fail_index = fa.alloc_index;
        try testing.expectError(error.OutOfMemory, p.putOwned(name, value));
        try testing.expect(fa.has_induced_failure);

        testing_alloc.free(name);
        testing_alloc.free(value);
        try testing.expectEqual(before, p.getAll("k").len);
        try testing.expectEqual(@as(usize, 1), p.count());
    }
}

// Same shape in `put`, from the other side: `put` owns its *copies*, and the
// name copy must be released exactly once — not early, while the value append
// can still fail with it already released.
test "Params: put releases its name copy exactly once when the append fails" {
    const testing_alloc = testing.allocator;
    var fa = std.testing.FailingAllocator.init(testing_alloc, .{});
    var p = Params.init(fa.allocator());
    defer p.deinit();

    while (true) {
        const list = p.map.get("k") orelse {
            try p.put("k", "seed");
            continue;
        };
        if (list.items.len >= list.capacity) break;
        try p.put("k", "seed");
    }
    const before = p.getAll("k").len;

    // dupe(name) #0, dupe(value) #1, the append is #2.
    fa.fail_index = fa.alloc_index + 2;
    try testing.expectError(error.OutOfMemory, p.put("k", "seed"));
    try testing.expect(fa.has_induced_failure);
    try testing.expectEqual(before, p.getAll("k").len);
    try testing.expectEqual(@as(usize, 1), p.count());
}

test "Params: many values for one name stay bounded by the caller's guard" {
    const allocator = testing.allocator;
    var p = Params.init(allocator);
    defer p.deinit();
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        var buf: [16]u8 = undefined;
        try p.put("k", try std.fmt.bufPrint(&buf, "{d}", .{i}));
    }
    try testing.expectEqual(@as(usize, 1), p.count());
    try testing.expectEqual(@as(usize, 500), p.totalValues());
    try testing.expectEqualStrings("499", p.get("k").?);
}
