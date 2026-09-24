const std = @import("std");
const Time = @import("../core/Time.zig");

/// Persistent memory entry — facts, preferences, lessons stored across sessions.
/// `key` is the **logical** key (e.g. `user:pref:lang`); tenant/user live in fields.
pub const MemoryEntry = struct {
    key: []const u8,
    value: []const u8,
    tenant_id: i64 = 0,
    user_id: i64 = 0,
    created_at: i64,
    access_count: usize = 0,
    last_accessed_at: i64 = 0,
};

/// Thread-safe in-memory store. Map keys are composite `tenant\x1fuser\x1flogical`
/// so the same logical key can coexist for different tenants/users.
///
/// Usage:
///   var store = MemoryStore.init(allocator, io);
///   try store.remember("user:pref:lang", "zh", 1, 42);
///   const facts = try store.recall(allocator, "user:pref", 1, 42);
pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.StringHashMap(MemoryEntry),
    mutex: std.Io.Mutex,
    max_entries: usize = 10000,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) MemoryStore {
        return initCapacity(allocator, io, 1000);
    }

    pub fn initCapacity(allocator: std.mem.Allocator, io: std.Io, capacity: usize) MemoryStore {
        var entries = std.StringHashMap(MemoryEntry).init(allocator);
        entries.ensureTotalCapacity(@intCast(capacity)) catch |err| {
            std.log.warn("[ai.memory] pre-allocating {d} entries failed ({s}); later puts may fail", .{ capacity, @errorName(err) });
        };
        return .{
            .allocator = allocator,
            .io = io,
            .entries = entries,
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *MemoryStore) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.key);
            self.allocator.free(entry.value_ptr.value);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    fn storageKey(allocator: std.mem.Allocator, tenant_id: i64, user_id: i64, logical: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{d}\x1f{d}\x1f{s}", .{ tenant_id, user_id, logical });
    }

    /// Store a fact. Logical key format: "namespace:category:detail" (e.g. "user:pref:lang").
    pub fn remember(self: *MemoryStore, key: []const u8, value: []const u8, tenant_id: i64, user_id: i64) !void {
        // Propagated, not waited out: `remember` returns `!void`, so the caller
        // can be told that the fact was *not* stored instead of being handed a
        // success it cannot trust (the old `catch return` returned success
        // without storing anything). Red: `ai.memory.test.canceled lock wait does
        // not lose a remember, forget or count`.
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);

        if (self.entries.count() >= self.max_entries) {
            self.evictOldestLocked();
        }

        const now = Time.monotonicNowSeconds();
        const sk = try storageKey(self.allocator, tenant_id, user_id, key);
        errdefer self.allocator.free(sk);

        if (self.entries.getPtr(sk)) |existing| {
            self.allocator.free(sk);
            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(existing.value);
            existing.value = owned_value;
            existing.access_count += 1;
            existing.last_accessed_at = now;
            return;
        }

        const owned_logical = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_logical);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        try self.entries.put(sk, .{
            .key = owned_logical,
            .value = owned_value,
            .tenant_id = tenant_id,
            .user_id = user_id,
            .created_at = now,
            .access_count = 0,
            .last_accessed_at = now,
        });
    }

    /// Recall facts matching a logical key prefix, scoped to tenant+user.
    /// Caller owns returned ArrayList memory.
    pub fn recall(
        self: *MemoryStore,
        allocator: std.mem.Allocator,
        key_prefix: []const u8,
        tenant_id: i64,
        user_id: i64,
    ) !std.ArrayList(MemoryEntry) {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);

        var result = std.ArrayList(MemoryEntry).empty;
        const now = Time.monotonicNowSeconds();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr;
            if (e.tenant_id != tenant_id and tenant_id != 0) continue;
            if (e.user_id != user_id and user_id != 0) continue;
            if (key_prefix.len > 0 and !std.mem.startsWith(u8, e.key, key_prefix)) continue;

            e.access_count += 1;
            e.last_accessed_at = now;

            try result.append(allocator, .{
                .key = try allocator.dupe(u8, e.key),
                .value = try allocator.dupe(u8, e.value),
                .tenant_id = e.tenant_id,
                .user_id = e.user_id,
                .created_at = e.created_at,
                .access_count = e.access_count,
                .last_accessed_at = e.last_accessed_at,
            });
        }
        return result;
    }

    /// Remove memory for logical key scoped to tenant+user.
    pub fn forget(self: *MemoryStore, key: []const u8, tenant_id: i64, user_id: i64) void {
        // Uncancelable: `forget` has no error channel (`void`), and a skipped call
        // leaves data standing that was asked to be deleted — privacy deletions
        // included — with nothing reported back. One map removal. Red:
        // `ai.memory.test.canceled lock wait does not lose a remember, forget or
        // count`.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const sk = storageKey(self.allocator, tenant_id, user_id, key) catch return;
        defer self.allocator.free(sk);

        if (self.entries.fetchRemove(sk)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.key);
            self.allocator.free(kv.value.value);
        }
    }

    /// Format recalled memories as context strings for system prompt injection.
    /// Returns allocated string — caller owns.
    ///
    /// **Pass real ids.** `recall` treats `0` as "any", so `tenant_id = 0` pulls
    /// every tenant's memories into the string. An agent run carries `?i64`
    /// identity and often has none — use `recallBlockAlloc` there, which refuses
    /// to widen instead.
    pub fn formatContext(
        self: *MemoryStore,
        allocator: std.mem.Allocator,
        key_prefix: []const u8,
        tenant_id: i64,
        user_id: i64,
        max_items: usize,
    ) ![]const u8 {
        var recalled = try self.recall(allocator, key_prefix, tenant_id, user_id);
        defer {
            for (recalled.items) |e| {
                allocator.free(e.key);
                allocator.free(e.value);
            }
            recalled.deinit(allocator);
        }

        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(allocator, "Relevant context:\n");
        const limit = @min(recalled.items.len, max_items);
        for (recalled.items[0..limit]) |e| {
            try buf.appendSlice(allocator, "- ");
            try buf.appendSlice(allocator, e.value);
            try buf.appendSlice(allocator, "\n");
        }
        return buf.toOwnedSlice(allocator);
    }

    /// Recall block for an agent run, or `null` when there is nothing safe to
    /// inject.
    ///
    /// The refusal *is* the feature: `recall` treats `0` as "any"
    /// (`if (e.tenant_id != tenant_id and tenant_id != 0)`), so passing `0` for
    /// a missing id returns **every tenant's** memories. A run with no tenant
    /// (or no user) therefore gets no memory block at all, and ids are used
    /// exactly as given — never widened. Returns `null` rather than an empty
    /// header so the prompt is not padded with noise. Caller frees.
    pub fn recallBlockAlloc(
        self: *MemoryStore,
        allocator: std.mem.Allocator,
        tenant_id: ?i64,
        user_id: ?i64,
        key_prefix: []const u8,
        limit: usize,
    ) !?[]u8 {
        const tenant = tenant_id orelse return null;
        const user = user_id orelse return null;
        if (tenant == 0 or user == 0 or limit == 0) return null;

        var recalled = try self.recall(allocator, key_prefix, tenant, user);
        defer {
            for (recalled.items) |e| {
                allocator.free(e.key);
                allocator.free(e.value);
            }
            recalled.deinit(allocator);
        }
        if (recalled.items.len == 0) return null;

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "Facts you remember about this user:\n");
        for (recalled.items[0..@min(limit, recalled.items.len)]) |e| {
            try buf.print(allocator, "- {s} = {s}\n", .{ e.key, e.value });
        }
        return try buf.toOwnedSlice(allocator);
    }

    pub fn count(self: *MemoryStore) usize {
        // Uncancelable: a fabricated `0` reads as "this store is empty" — the
        // reading a size/health report is built from. One map count.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.entries.count();
    }

    /// Snapshot all entries as JSON array (for simple file persistence). Caller frees.
    pub fn dumpJson(self: *MemoryStore, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);

        const Dump = struct {
            key: []const u8,
            value: []const u8,
            tenant_id: i64,
            user_id: i64,
            created_at: i64,
            access_count: usize,
            last_accessed_at: i64,
        };

        var rows = std.ArrayList(Dump).empty;
        defer rows.deinit(allocator);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr.*;
            try rows.append(allocator, .{
                .key = e.key,
                .value = e.value,
                .tenant_id = e.tenant_id,
                .user_id = e.user_id,
                .created_at = e.created_at,
                .access_count = e.access_count,
                .last_accessed_at = e.last_accessed_at,
            });
        }
        return try std.json.Stringify.valueAlloc(allocator, rows.items, .{});
    }

    /// Load entries from `dumpJson` output (merge/overwrite by composite key).
    pub fn loadJson(self: *MemoryStore, json: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return error.InvalidMemoryDump,
        };
        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const key = switch (obj.get("key") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const value = switch (obj.get("value") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const tenant_id: i64 = blk: {
                const v = obj.get("tenant_id") orelse break :blk 0;
                break :blk switch (v) {
                    .integer => |n| n,
                    else => 0,
                };
            };
            const user_id: i64 = blk: {
                const v = obj.get("user_id") orelse break :blk 0;
                break :blk switch (v) {
                    .integer => |n| n,
                    else => 0,
                };
            };
            try self.remember(key, value, tenant_id, user_id);
        }
    }

    /// Persist snapshot to a relative path under cwd (`std.Io.Dir.cwd`).
    pub fn saveToFile(self: *MemoryStore, path: []const u8) !void {
        const json = try self.dumpJson(self.allocator);
        defer self.allocator.free(json);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, json);
    }

    /// Replace-merge from a JSON file written by `saveToFile`.
    pub fn loadFromFile(self: *MemoryStore, path: []const u8) !void {
        const json = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, std.Io.Limit.limited(16 * 1024 * 1024));
        defer self.allocator.free(json);
        try self.loadJson(json);
    }

    fn evictOldestLocked(self: *MemoryStore) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_accessed_at < oldest_time) {
                oldest_time = entry.value_ptr.last_accessed_at;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.key);
                self.allocator.free(kv.value.value);
            }
        }
    }
};

test "MemoryStore remember and recall" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();

    try store.remember("user:pref:lang", "zh", 1, 42);
    try store.remember("user:pref:theme", "dark", 1, 42);
    try store.remember("user:pref:lang", "en", 2, 99); // same logical key, different tenant/user

    var results = try store.recall(a, "user:pref", 1, 42);
    defer {
        for (results.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        results.deinit(a);
    }

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqual(@as(usize, 3), store.count());
}

test "MemoryStore forget" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();

    try store.remember("test:key", "value", 0, 0);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    store.forget("test:key", 0, 0);
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "MemoryStore formatContext" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();

    try store.remember("user:fact:name", "Alice", 1, 1);
    try store.remember("user:fact:role", "admin", 1, 1);

    const ctx = try store.formatContext(a, "user:fact", 1, 1, 10);
    defer a.free(ctx);

    try std.testing.expect(std.mem.indexOf(u8, ctx, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "admin") != null);
}

test "MemoryStore recallBlockAlloc refuses to widen scope" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();

    try store.remember("user:fact:lang", "zh-hans", 1, 42);
    try store.remember("user:fact:theme", "dark", 1, 42);
    try store.remember("user:fact:lang", "en-US", 2, 42); // same user, other tenant
    try store.remember("user:fact:lang", "fr-FR", 1, 7); // same tenant, other user

    const block = (try store.recallBlockAlloc(a, 1, 42, "user:", 8)).?;
    defer a.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "zh-hans") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, block, "\n- "));
    try std.testing.expect(std.mem.indexOf(u8, block, "en-US") == null);
    try std.testing.expect(std.mem.indexOf(u8, block, "fr-FR") == null);

    // Missing or zero identity: no block at all. `recall` reads 0 as "any", so
    // rendering anything here would put other tenants' facts in the prompt.
    try std.testing.expectEqual(@as(?[]u8, null), try store.recallBlockAlloc(a, null, 42, "user:", 8));
    try std.testing.expectEqual(@as(?[]u8, null), try store.recallBlockAlloc(a, 1, null, "user:", 8));
    try std.testing.expectEqual(@as(?[]u8, null), try store.recallBlockAlloc(a, 0, 42, "user:", 8));
    try std.testing.expectEqual(@as(?[]u8, null), try store.recallBlockAlloc(a, 1, 0, "user:", 8));

    // No match, and limit 0, are both "nothing to say".
    try std.testing.expectEqual(@as(?[]u8, null), try store.recallBlockAlloc(a, 1, 42, "order:", 8));
    try std.testing.expectEqual(@as(?[]u8, null), try store.recallBlockAlloc(a, 1, 42, "user:", 0));

    // `limit` bounds the block.
    const one = (try store.recallBlockAlloc(a, 1, 42, "user:", 1)).?;
    defer a.free(one);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, one, "\n- "));
}

test "MemoryStore capacity eviction" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    store.max_entries = 3;
    defer store.deinit();

    try store.remember("k1", "v1", 0, 0);
    try store.remember("k2", "v2", 0, 0);
    try store.remember("k3", "v3", 0, 0);
    try store.remember("k4", "v4", 0, 0);

    try std.testing.expect(store.count() <= 3);
}

test "MemoryStore dumpJson loadJson roundtrip" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();
    try store.remember("user:pref:lang", "zh", 1, 42);

    const json = try store.dumpJson(a);
    defer a.free(json);

    var store2 = MemoryStore.init(a, std.testing.io);
    defer store2.deinit();
    try store2.loadJson(json);
    try std.testing.expectEqual(@as(usize, 1), store2.count());

    var results = try store2.recall(a, "user:pref", 1, 42);
    defer {
        for (results.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        results.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("zh", results.items[0].value);
}

test "MemoryStore saveToFile loadFromFile" {
    const a = std.testing.allocator;
    const path = "zigmodu-test-memory-store.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();
    try store.remember("user:pref:lang", "zh", 1, 42);
    try store.saveToFile(path);

    var store2 = MemoryStore.init(a, std.testing.io);
    defer store2.deinit();
    try store2.loadFromFile(path);
    try std.testing.expectEqual(@as(usize, 1), store2.count());
}

/// Park `read` on `mutex` with a cancel request already placed on its thread, then
/// let it through: the lock wait becomes the cancelation point. `std.Io.Mutex.lock`'s
/// uncontended fast path does not check for cancellation, so it is the contended
/// wait that can come back canceled.
fn readUnderCanceledLockWait(
    comptime T: type,
    target: *T,
    mutex: *std.Io.Mutex,
    io: std.Io,
    comptime read: fn (*T) void,
) !void {
    const Gate = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn run(t: *T) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            read(t);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Gate.entered.store(false, .monotonic);
    Gate.open.store(false, .monotonic);

    try mutex.lock(io);

    var read_fut = try io.concurrent(Gate.run, .{target});
    while (!Gate.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Gate.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Gate.open.store(true, .release);
    while (mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);
}

// The three lock-wait sites the inventory flagged, and why each is answered
// differently:
//   - `remember` returns `!void`, so the canceled wait is *propagated*
//     (`error.LockFailed`) — the caller learns the fact was not stored instead of
//     being told a success it cannot trust;
//   - `forget` returns `void` and has no error channel, so it *waits*
//     (`lockUncancelable`): the skipped call would leave data that was asked to be
//     deleted (privacy deletions included) in the store, invisibly;
//   - `count` returns `usize`, and a fabricated `0` reads as "this store is
//     empty", so it waits too. Each critical section is a map operation.
//
// Red evidence: with the old shapes the first assertion below fails —
// `expected error.LockFailed, found null`, because the canceled `remember`
// returned success without storing. The `forget` and `count` assertions after it
// are the same lock shape; a `try` ends the test at the first failure, so those
// two are only exercised green.
test "canceled lock wait does not lose a remember, forget or count" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var store = MemoryStore.init(a, io);
    defer store.deinit();

    const RememberRead = struct {
        var seen: ?anyerror = null;
        fn read(s: *MemoryStore) void {
            seen = null;
            s.remember("k", "v", 0, 0) catch |err| {
                seen = err;
            };
        }
    };
    RememberRead.seen = null;
    try readUnderCanceledLockWait(MemoryStore, &store, &store.mutex, io, RememberRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.LockFailed), RememberRead.seen);
    try std.testing.expectEqual(@as(usize, 0), store.count());

    try store.remember("gone", "x", 0, 0);
    const ForgetRead = struct {
        fn read(s: *MemoryStore) void {
            s.forget("gone", 0, 0);
        }
    };
    try readUnderCanceledLockWait(MemoryStore, &store, &store.mutex, io, ForgetRead.read);
    try std.testing.expectEqual(@as(usize, 0), store.count());

    // Seeded again: the count read below must return 1, so "0" is unambiguous
    // evidence that the canceled wait was answered with a fabricated value.
    try store.remember("kept", "x", 0, 0);
    const CountRead = struct {
        var seen: usize = 0;
        fn read(s: *MemoryStore) void {
            seen = s.count();
        }
    };
    CountRead.seen = 0;
    try readUnderCanceledLockWait(MemoryStore, &store, &store.mutex, io, CountRead.read);
    try std.testing.expectEqual(@as(usize, 1), CountRead.seen);
}
