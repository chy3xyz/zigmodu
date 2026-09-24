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

    /// The map key of a *new* entry: `tenant\x1fuser\x1flogical`. Insert path
    /// only — a lookup must not go through it (see `forget`, which cannot
    /// format a key at all: it has no error channel and no bounded buffer).
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
        try self.mutex.lock(self.io);
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
    ///
    /// All-or-nothing: an allocation failure returns the error with the store
    /// **unchanged** — no entry is marked as accessed for a call that did not
    /// hand back a result.
    pub fn recall(
        self: *MemoryStore,
        allocator: std.mem.Allocator,
        key_prefix: []const u8,
        tenant_id: i64,
        user_id: i64,
    ) !std.ArrayList(MemoryEntry) {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const now = Time.monotonicNowSeconds();
        var result = std.ArrayList(MemoryEntry).empty;
        errdefer {
            for (result.items) |e| {
                allocator.free(e.key);
                allocator.free(e.value);
            }
            result.deinit(allocator);
        }

        // Collect first, bump the access counters afterwards: the old loop wrote
        // `access_count`/`last_accessed_at` as it went, so a mid-loop allocation
        // failure returned an error with the entries it had already walked
        // marked as accessed (red: `ai.memory.test.recall leaves the store
        // untouched when an allocation fails`). Nothing mutates between the two
        // walks, so this one resets exactly the entries the first one returned.
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr;
            if (!matchesScope(e, key_prefix, tenant_id, user_id)) continue;

            const owned_key = try allocator.dupe(u8, e.key);
            errdefer allocator.free(owned_key);
            const owned_value = try allocator.dupe(u8, e.value);
            errdefer allocator.free(owned_value);

            try result.append(allocator, .{
                .key = owned_key,
                .value = owned_value,
                .tenant_id = e.tenant_id,
                .user_id = e.user_id,
                .created_at = e.created_at,
                .access_count = e.access_count + 1,
                .last_accessed_at = now,
            });
        }

        var bump = self.entries.iterator();
        while (bump.next()) |entry| {
            const e = entry.value_ptr;
            if (!matchesScope(e, key_prefix, tenant_id, user_id)) continue;
            e.access_count += 1;
            e.last_accessed_at = now;
        }
        return result;
    }

    /// The scope test `recall` applies both when collecting and when bumping —
    /// shared so the two walks cannot drift apart.
    fn matchesScope(e: *const MemoryEntry, key_prefix: []const u8, tenant_id: i64, user_id: i64) bool {
        if (e.tenant_id != tenant_id and tenant_id != 0) return false;
        if (e.user_id != user_id and user_id != 0) return false;
        if (key_prefix.len > 0 and !std.mem.startsWith(u8, e.key, key_prefix)) return false;
        return true;
    }

    /// Remove memory for logical key scoped to tenant+user.
    ///
    /// Allocation-free on purpose. `forget` has no error channel (`void`), and a
    /// skipped call leaves data standing that was asked to be deleted — privacy
    /// deletions included — with nothing reported back. The old shape formatted
    /// the map key first (`storageKey(...) catch return`), so an OOM turned the
    /// delete into a silent no-op; the map is keyed `tenant\x1fuser\x1flogical`,
    /// so the entry a delete means is exactly the one whose three stored fields
    /// match, and comparing those needs no buffer. A stack buffer was the other
    /// candidate and is what this deliberately does not use: the logical key is
    /// caller-supplied and unbounded, so the buffer would need a cap, and a
    /// truncated key collides across scopes — a delete that removes the wrong
    /// tenant's row is worse than one that does not run.
    ///
    /// `matchesScope` is *not* reused here: it reads `0` as "any" (right for
    /// `recall`), so `forget(k, 0, 0)` would delete every scope's copy.
    pub fn forget(self: *MemoryStore, key: []const u8, tenant_id: i64, user_id: i64) void {
        // Uncancelable: `forget` has no error channel (`void`), and a skipped call
        // leaves data standing that was asked to be deleted — privacy deletions
        // included — with nothing reported back. One map walk plus one removal,
        // neither of which allocates (a walk of a map bounded by `max_entries`;
        // the old shape traded that walk for a temporary key whose allocation
        // failure was the silent drop). Red:
        // `ai.memory.test.canceled lock wait does not lose a remember, forget or
        // count`.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // The entry's own key is found first: `fetchRemove` would invalidate the
        // iterator it is looking through.
        var owned_key: ?[]const u8 = null;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr;
            if (e.tenant_id == tenant_id and e.user_id == user_id and std.mem.eql(u8, e.key, key)) {
                owned_key = entry.key_ptr.*;
                break;
            }
        }

        if (self.entries.fetchRemove(owned_key orelse return)) |kv| {
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
        try self.mutex.lock(self.io);
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
    ///
    /// Never invents a fact, and never invents a scope. Two kinds of unusable
    /// input get two answers, because only one of them can change what a stored
    /// memory means:
    ///
    ///   - an item that is not a row — not an object, or without a string
    ///     `key`/`value` — was never readable as a memory, so it is skipped, with
    ///     a `warn` naming its index and the reason. The skip is the answer; being
    ///     silent about it was the defect;
    ///   - an item that carries `key`+`value` but no knowable scope (`tenant_id`/
    ///     `user_id` missing, or not an integer) refuses the whole load with
    ///     `error.InvalidMemoryScope`. Admitting it needs a scope the dump does
    ///     not state, and `0` — what the reader used to substitute — is exactly
    ///     what `recall` reads as "any" (`matchesScope`), so a corrupt dump
    ///     *widened* those rows to every "any"-scope read instead of failing.
    ///     Dropping the row is the other candidate and is worse: it destroys a
    ///     memory whose content is known, behind a log line. Refusing the file
    ///     leaves both the row and the decision with the operator.
    ///
    /// A scope the dump states is kept as stated, `0` included (an explicit
    /// `remember(..., 0, 0)` is a scope this store supports): only a *missing* or
    /// mistyped field is corrupt.
    ///
    /// Rows are read before any of them is applied, so a refused load leaves the
    /// store exactly as it was — a half-merged store *plus* an error is the one
    /// outcome a caller cannot act on. (An allocation failure while applying
    /// still leaves a partial merge; a refused file does not.) `created_at`,
    /// `access_count` and `last_accessed_at` in the dump are not restored: the
    /// row goes through `remember`, which stamps the entry as new.
    pub fn loadJson(self: *MemoryStore, json: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return error.InvalidMemoryDump,
        };

        const Row = struct {
            key: []const u8,
            value: []const u8,
            tenant_id: i64,
            user_id: i64,
        };

        // Pass 1: read. The slices below point into `parsed`, which outlives the
        // apply pass; `remember` copies what it keeps.
        var rows = std.ArrayList(Row).empty;
        defer rows.deinit(self.allocator);
        for (arr.items, 0..) |item, index| {
            const obj = switch (item) {
                .object => |o| o,
                else => {
                    std.log.warn("[ai.memory] dump item {d} skipped: not an object (found {s})", .{ index, @tagName(item) });
                    continue;
                },
            };
            const key = switch (obj.get("key") orelse {
                std.log.warn("[ai.memory] dump item {d} skipped: no `key`", .{index});
                continue;
            }) {
                .string => |s| s,
                else => |other| {
                    std.log.warn("[ai.memory] dump item {d} skipped: `key` is {s}, not a string", .{ index, @tagName(other) });
                    continue;
                },
            };
            const value = switch (obj.get("value") orelse {
                std.log.warn("[ai.memory] dump item {d} skipped: no `value`", .{index});
                continue;
            }) {
                .string => |s| s,
                else => |other| {
                    std.log.warn("[ai.memory] dump item {d} skipped: `value` is {s}, not a string", .{ index, @tagName(other) });
                    continue;
                },
            };
            try rows.append(self.allocator, .{
                .key = key,
                .value = value,
                .tenant_id = try dumpRowScope(obj, index, "tenant_id"),
                .user_id = try dumpRowScope(obj, index, "user_id"),
            });
        }

        // Pass 2: apply.
        for (rows.items) |row| {
            try self.remember(row.key, row.value, row.tenant_id, row.user_id);
        }
    }

    /// The scope a dump row states, or `error.InvalidMemoryScope` with the reason
    /// logged. There is deliberately no fallback: `0` is `recall`'s "any", so
    /// substituting it is not a smaller claim than the dump made — it is a larger
    /// one, and it is the claim that reaches every tenant.
    fn dumpRowScope(obj: std.json.ObjectMap, index: usize, name: []const u8) error{InvalidMemoryScope}!i64 {
        const v = obj.get(name) orelse {
            std.log.warn("[ai.memory] dump item {d} refused: `{s}` is missing, and a memory's scope must not be guessed", .{ index, name });
            return error.InvalidMemoryScope;
        };
        return switch (v) {
            .integer => |n| n,
            else => |other| {
                std.log.warn("[ai.memory] dump item {d} refused: `{s}` is {s}, not an integer", .{ index, name, @tagName(other) });
                return error.InvalidMemoryScope;
            },
        };
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

// `forget` used to format a composite lookup key before it removed anything, and
// answered an allocation failure with `catch return`: `void` has no error
// channel, so a delete — privacy deletions included — became a silent no-op and
// the data stayed. The key is compared field-by-field now, so the removal needs
// no allocation at all, and an OOM cannot drop it.
//
// Red on the old shape: `expected 1, found 2` — the delete below was dropped and
// both entries survived it.
test "MemoryStore forget removes the entry when no allocation is possible" {
    const a = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = std.math.maxInt(usize) });
    var store = MemoryStore.init(failing.allocator(), std.testing.io);
    defer store.deinit();

    try store.remember("user:pref:lang", "zh", 1, 42);
    try store.remember("user:pref:lang", "en", 2, 99); // same logical key, other scope
    try std.testing.expectEqual(@as(usize, 2), store.count());

    // Setup is over: the next allocation fails, and the delete below must not
    // need one.
    failing.fail_index = failing.alloc_index;

    store.forget("user:pref:lang", 1, 42);

    // The scoped entry is gone, the other scope's copy is not: the field-wise
    // match is exact, not a loose "same logical key" sweep.
    try std.testing.expectEqual(@as(usize, 1), store.count());

    failing.fail_index = std.math.maxInt(usize);
    var results = try store.recall(a, "user:pref", 2, 99);
    defer {
        for (results.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        results.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("en", results.items[0].value);
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

// `loadJson` reads what `dumpJson` writes, and `dumpJson` always writes
// `tenant_id`/`user_id` as integers. The reader repaired anything else — a
// missing field, or one of another type — into `0`, and `0` is exactly the value
// `recall` reads as "any" (`matchesScope`:
// `if (e.tenant_id != tenant_id and tenant_id != 0)`). A corrupt or hand-edited
// dump therefore did not fail: a row that belonged to one tenant became readable
// by every "any"-scope reader.
//
// Red on the old shape: `leak: recall(any) returned value="tenant-2-secret"
// scope=(0,2)`, then `expected 0, found 2` — both entries were in scope (0, 0)
// and (0, 2), the scopes the dump never stated, whatever the "any" reader asks
// for. (Which of the two the map walks out first is iteration order, so the value
// printed can be either; the count is the assertion.)
test "a corrupt-scope dump cannot be read back through an any-scope recall" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();

    // Row 1 has no scope at all; row 2 spells `tenant_id` as a string. Both are
    // what a hand-edited file or a dump written by another tool looks like.
    const corrupt =
        \\[{"key":"user:fact:secret","value":"tenant-1-secret"},
        \\ {"key":"user:fact:other","value":"tenant-2-secret","tenant_id":"2","user_id":2}]
    ;
    // Which of the two answers the load gives is asserted by the next test; what
    // matters here is that neither answer may leave a scope-less row reachable
    // through "any", so a refusal is tolerated and any other error is not.
    var load_err: ?anyerror = null;
    store.loadJson(corrupt) catch |err| {
        load_err = err;
    };
    if (load_err) |err| try std.testing.expectEqual(@as(anyerror, error.InvalidMemoryScope), err);

    var any = try store.recall(a, "user:", 0, 0); // 0 = any tenant, any user
    defer {
        for (any.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        any.deinit(a);
    }
    if (any.items.len != 0) {
        // Speaks only when the leak is back. The scope shown is the one the dump
        // never stated: `0`, which is what "any" matches.
        std.debug.print("leak: recall(any) returned value=\"{s}\" scope=({d},{d})\n", .{
            any.items[0].value,
            any.items[0].tenant_id,
            any.items[0].user_id,
        });
    }
    try std.testing.expectEqual(@as(usize, 0), any.items.len);
}

// The refusal, and what it is worth: a row that carries `key`+`value` but no
// knowable scope is not admitted — admitting it needs a scope the dump does not
// state, and the only value the old reader could invent (`0`) is "any" to
// `recall`. It is not silently dropped either: dropping destroys a memory whose
// content *is* known. The file is refused instead, and because the rows are read
// before any of them is applied, the store is left exactly as it was — a
// half-merged store plus an error is the one outcome the caller cannot act on.
//
// Red on the old shape: `expected error.InvalidMemoryScope, found null` for the
// first dump, and the partial-merge dump would leave 2 entries instead of 1.
test "loadJson refuses a dump whose scope is unusable and applies nothing" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();
    try store.remember("user:fact:kept", "kept", 7, 8);
    const before = try store.dumpJson(a);
    defer a.free(before);

    const corrupt = [_][]const u8{
        // no `tenant_id` / `user_id` at all
        \\[{"key":"user:fact:secret","value":"tenant-1-secret"}]
        ,
        // `tenant_id` present with the wrong type
        \\[{"key":"user:fact:secret","value":"tenant-1-secret","tenant_id":"7","user_id":8}]
        ,
        // `user_id` missing, `tenant_id` fine
        \\[{"key":"user:fact:secret","value":"tenant-1-secret","tenant_id":7}]
        ,
        // `user_id` explicitly null
        \\[{"key":"user:fact:secret","value":"tenant-1-secret","tenant_id":7,"user_id":null}]
        ,
        // the unusable row is not the first one: nothing in front of it may be
        // applied before the refusal
        \\[{"key":"user:fact:ok","value":"v","tenant_id":7,"user_id":8},
        \\ {"key":"user:fact:bad","value":"v","tenant_id":7}]
        ,
    };

    for (corrupt) |dump| {
        var seen: ?anyerror = null;
        store.loadJson(dump) catch |err| {
            seen = err;
        };
        try std.testing.expectEqual(@as(?anyerror, error.InvalidMemoryScope), seen);
        try std.testing.expectEqual(@as(usize, 1), store.count());
        const after = try store.dumpJson(a);
        defer a.free(after);
        try std.testing.expectEqualStrings(before, after);
    }

    // The restore path the docs hand applications (`loadFromFile`) is the same
    // judgment, so the refusal reaches the operator there too rather than a
    // half-restored store.
    const path = "zigmodu-test-memory-corrupt-scope.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, corrupt[0]);
    }
    try std.testing.expectError(error.InvalidMemoryScope, store.loadFromFile(path));
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

// An explicit `0` is a scope the store supports (`remember(..., 0, 0)`, and the
// `forget`/eviction tests use it), so the refusal above must not reinterpret it:
// only a *missing* or mistyped field is corrupt, never a stated zero. A dump this
// class wrote therefore needs no migration.
test "loadJson keeps a scope the dump states explicitly, including 0" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();
    try store.remember("user:fact:global", "unscoped", 0, 0);
    try store.remember("user:fact:scoped", "tenant-7", 7, 8);

    const json = try store.dumpJson(a);
    defer a.free(json);

    var store2 = MemoryStore.init(a, std.testing.io);
    defer store2.deinit();
    try store2.loadJson(json);
    try std.testing.expectEqual(@as(usize, 2), store2.count());

    // Scope is what an entry is read back by: the tenant-7 row is reachable by
    // its own scope — a row the reader had repaired into `0` would *not* be
    // (see `matchesScope`: `e.tenant_id != tenant_id and tenant_id != 0`) — and
    // the scoped recall does not hand back the 0/0 row either.
    var scoped = try store2.recall(a, "user:", 7, 8);
    defer {
        for (scoped.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        scoped.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), scoped.items.len);
    try std.testing.expectEqualStrings("tenant-7", scoped.items[0].value);

    // "Any" matches every entry, whatever scope it carries — which is exactly why
    // a scope the dump did not state must never be turned into one that reads as
    // "any" (the test above).
    var any = try store2.recall(a, "user:", 0, 0);
    defer {
        for (any.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        any.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 2), any.items.len);
}

// An item that is not a row at all — not an object, or without a string
// `key`/`value` — carries nothing that could be admitted, so skipping it stays
// the answer (that part of the contract does not change). What changes is that
// the skip is no longer silent: each one is warned with its index and the reason,
// which is what this test prints above its result. Nothing is repaired into a
// row: the four unusable items below must not appear as entries.
//
// Red on the old shape: the same count, and *no* warn line anywhere in the run —
// the items vanished with nothing said.
test "loadJson names each item it skips" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();

    const mixed =
        \\[{"key":"user:fact:kept","value":"kept","tenant_id":1,"user_id":2},
        \\ 42,
        \\ {"key":"user:fact:novalue","tenant_id":1,"user_id":2},
        \\ {"value":"nokey","tenant_id":1,"user_id":2},
        \\ {"key":"user:fact:numvalue","value":7,"tenant_id":1,"user_id":2}]
    ;
    try store.loadJson(mixed);

    // The load is not an error — every readable row was read, and the unreadable
    // ones were named rather than repaired.
    try std.testing.expectEqual(@as(usize, 1), store.count());
    var got = try store.recall(a, "user:", 1, 2);
    defer {
        for (got.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        got.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualStrings("kept", got.items[0].value);
}

// A listed asymmetry, not a fix (see the report): `dumpJson` writes a `[]const u8`
// that is not valid UTF-8 as an *array of bytes* rather than a JSON string
// (`std/json/stringify.zig`: `if (!self.options.emit_strings_as_arrays and
// std.unicode.utf8ValidateSlice(slice))`), and `loadJson` reads only the string
// form — so a binary memory value is written by the pair and not read back. It is
// skipped rather than repaired, and the skip is warned like any other; decoding
// the array form would be the lossless answer.
//
// The dump below is produced by `dumpJson`, so this is the pair's own output and
// not a hand-written file: the assertion on the dump is what pins the shape, and
// it stops holding the day the array form is decoded.
test "loadJson does not read back a non-UTF-8 value that dumpJson writes" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();
    try store.remember("user:fact:bin", "\xff\xfe\x00ok", 3, 4);
    try store.remember("user:fact:text", "ok", 3, 4);

    const json = try store.dumpJson(a);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "[255,254,0,111,107]") != null);

    var store2 = MemoryStore.init(a, std.testing.io);
    defer store2.deinit();
    try store2.loadJson(json);
    try std.testing.expectEqual(@as(usize, 1), store2.count());

    var got = try store2.recall(a, "user:", 3, 4);
    defer {
        for (got.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        got.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualStrings("ok", got.items[0].value);
}

test "recall leaves the store untouched when an allocation fails" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();

    try store.remember("user:pref:a", "1", 1, 42);
    try store.remember("user:pref:b", "2", 1, 42);
    try store.remember("user:pref:c", "3", 1, 42);

    const before = try store.dumpJson(a);
    defer a.free(before);

    // The 4th allocation fails: one entry has already been appended to the
    // result (and, before the fix, the entries walked so far had already had
    // their access counters bumped).
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 3 });
    try std.testing.expectError(error.OutOfMemory, store.recall(failing.allocator(), "user:pref", 1, 42));

    const after = try store.dumpJson(a);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
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

// Three of the store's lock-wait sites, and why each is answered differently:
//   - `remember` returns `!void`, so the canceled wait is *propagated*
//     (`error.Canceled` — the only error `std.Io.Mutex.lock` has, where the old
//     `error.LockFailed` named lock-machinery failure for a cancelation) — the
//     caller learns the fact was not stored instead of being told a success it
//     cannot trust;
//   - `forget` returns `void` and has no error channel, so it *waits*
//     (`lockUncancelable`): the skipped call would leave data that was asked to be
//     deleted (privacy deletions included) in the store, invisibly;
//   - `count` returns `usize`, and a fabricated `0` reads as "this store is
//     empty", so it waits too. Each critical section is a map operation.
//
// Red evidence: with the old shapes the first assertion below fails —
// `expected error.Canceled, found null`, because the canceled `remember` returned
// success without storing. The `forget` and `count` assertions after it are the
// same lock shape; a `try` ends the test at the first failure, so those two are
// only exercised green.
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
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), RememberRead.seen);
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

// The other two allocation-returning readers: `recall` and `dumpJson` both return
// errors, so the cancelation is propagated as `error.Canceled` rather than named
// lock-machinery failure. Nothing is stored, dropped or marked as accessed by a
// wait that never entered the critical section.
//
// Red evidence: with `catch return error.LockFailed` the first assertion below
// reads `expected error.Canceled, found error.LockFailed`. The `dumpJson`
// assertion after it is the same lock shape; a `try` ends the test at the first
// failure, so it is only exercised green.
test "recall and dumpJson report a canceled lock wait as error.Canceled" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var store = MemoryStore.init(a, io);
    defer store.deinit();
    try store.remember("user:pref:lang", "zh", 1, 42);

    const RecallRead = struct {
        var seen: ?anyerror = null;
        fn read(s: *MemoryStore) void {
            seen = null;
            var res = s.recall(std.testing.allocator, "user:pref", 1, 42) catch |err| {
                seen = err;
                return;
            };
            for (res.items) |e| {
                std.testing.allocator.free(e.key);
                std.testing.allocator.free(e.value);
            }
            res.deinit(std.testing.allocator);
        }
    };
    RecallRead.seen = null;
    try readUnderCanceledLockWait(MemoryStore, &store, &store.mutex, io, RecallRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), RecallRead.seen);

    const DumpRead = struct {
        var seen: ?anyerror = null;
        fn read(s: *MemoryStore) void {
            seen = null;
            const json = s.dumpJson(std.testing.allocator) catch |err| {
                seen = err;
                return;
            };
            std.testing.allocator.free(json);
        }
    };
    DumpRead.seen = null;
    try readUnderCanceledLockWait(MemoryStore, &store, &store.mutex, io, DumpRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), DumpRead.seen);
}
