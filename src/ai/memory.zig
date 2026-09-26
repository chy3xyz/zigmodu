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
        // No history: a fact being stored now has no past to restore, so the row
        // is stamped from the clock.
        try self.putLocked(key, value, tenant_id, user_id, null);
    }

    /// An entry's past — the three fields `dumpJson` writes that are neither the
    /// entry's identity nor its content. A `null` history means "not stated", and
    /// the entry is stamped as new.
    const EntryHistory = struct {
        created_at: i64,
        access_count: usize,
        last_accessed_at: i64,
    };

    /// Insert-or-replace one entry under the write lock. Both insert paths go
    /// through here so the map key's shape and the ownership rules cannot drift:
    /// `remember` (a live fact) and `loadJson` (a restored snapshot).
    ///
    /// `history` is the one thing the two callers state differently, and each
    /// branch reads it for itself:
    ///   - an entry already stored has its value replaced and keeps its
    ///     `created_at`; with a history the whole row *is* the snapshot that was
    ///     loaded, without one the re-store counts as an access (`remember` on an
    ///     existing key is an update, so the fact's recency is now);
    ///   - a new entry takes the history as given, or is stamped as new.
    ///
    /// `key` and `value` are copied; the caller keeps its own slices.
    fn putLocked(
        self: *MemoryStore,
        key: []const u8,
        value: []const u8,
        tenant_id: i64,
        user_id: i64,
        history: ?EntryHistory,
    ) !void {
        if (self.entries.count() >= self.max_entries) {
            self.evictOldestLocked();
        }

        const now = Time.monotonicNowSeconds();
        const sk = try storageKey(self.allocator, tenant_id, user_id, key);
        errdefer self.allocator.free(sk);

        if (self.entries.getPtr(sk)) |existing| {
            // Allocate *before* releasing `sk`: the `errdefer` above is still
            // armed, so freeing first and then failing here freed the same key
            // twice (double free on OOM in the update path).
            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(sk);
            self.allocator.free(existing.value);
            existing.value = owned_value;
            if (history) |h| {
                existing.created_at = h.created_at;
                existing.access_count = h.access_count;
                existing.last_accessed_at = h.last_accessed_at;
            } else {
                existing.access_count += 1;
                existing.last_accessed_at = now;
            }
            return;
        }

        const owned_logical = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_logical);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const h = history orelse EntryHistory{
            .created_at = now,
            .access_count = 0,
            .last_accessed_at = now,
        };
        try self.entries.put(sk, .{
            .key = owned_logical,
            .value = owned_value,
            .tenant_id = tenant_id,
            .user_id = user_id,
            .created_at = h.created_at,
            .access_count = h.access_count,
            .last_accessed_at = h.last_accessed_at,
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
    ///
    /// Every field of an entry is written. A `[]const u8` value that is not valid
    /// UTF-8 goes out in the array form `std.json` picks for it (one number per
    /// byte); `loadJson` reads that back, so the snapshot is lossless.
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
    ///   - an item that is not a row — not an object, or without a readable
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
    /// `key` and `value` each have two readable shapes, because the writer picks
    /// by content: a JSON string, and — for a `[]const u8` that is not valid UTF-8
    /// — an array of one number per byte (see `byteArrayValue`). Both come back, so
    /// a snapshot survives this pair byte-for-byte instead of dropping the rows
    /// whose key or value is binary.
    ///
    /// `created_at`, `access_count` and `last_accessed_at` are restored as the dump
    /// states them (`EntryHistory`) — a snapshot of state has to bring the state
    /// back, and it is what lets `evictOldestLocked` go on picking the genuinely
    /// oldest row after a restore. A history the dump does *not* state leaves the
    /// row restored with `remember`'s fresh stamp, warned (see `dumpRowHistory`):
    /// the row's content is readable, and a timestamp is not a scope, so the
    /// refusal `dumpRowScope` makes would be the wrong instrument here.
    ///
    /// Rows are read before any of them is applied, so a refused load leaves the
    /// store exactly as it was — a half-merged store *plus* an error is the one
    /// outcome a caller cannot act on. (An allocation failure while applying
    /// still leaves a partial merge; a refused file does not.)
    pub fn loadJson(self: *MemoryStore, json: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return error.InvalidMemoryDump,
        };

        // The bytes a byte-array `key`/`value` decodes to must outlive the read
        // pass — the slices below are handed to `putLocked` in the apply pass, and
        // a row is read before anything is applied. An arena owns them for the
        // length of the load. Slices into `parsed` need no copy: it outlives both
        // passes, and `putLocked` copies whatever it keeps.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const Row = struct {
            key: []const u8,
            value: []const u8,
            tenant_id: i64,
            user_id: i64,
            history: ?EntryHistory,
        };

        // Pass 1: read.
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
            const key = (try dumpRowBytes(obj, index, "key", arena.allocator())) orelse continue;
            const value = (try dumpRowBytes(obj, index, "value", arena.allocator())) orelse continue;
            try rows.append(self.allocator, .{
                .key = key,
                .value = value,
                .tenant_id = try dumpRowScope(obj, index, "tenant_id"),
                .user_id = try dumpRowScope(obj, index, "user_id"),
                .history = dumpRowHistory(obj, index),
            });
        }

        // Pass 2: apply. One critical section for the whole restore — every row in
        // `rows` has already been read and validated, and `putLocked` is exactly
        // what `remember` would have done for each of them.
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        for (rows.items) |row| {
            try self.putLocked(row.key, row.value, row.tenant_id, row.user_id, row.history);
        }
    }

    /// The bytes a dump row states for `name` — `key` or `value`, the two fields
    /// the writer can emit in either shape (a JSON string, or the array form for a
    /// `[]const u8` that is not valid UTF-8). `null` means the field cannot be read
    /// as bytes at all, the reason warned here; the caller then skips the item,
    /// which is the same answer every unreadable item gets, for the same reason:
    /// the row was never readable as a memory, so it is not repaired.
    ///
    /// A scope is the one field read strictly (`dumpRowScope`), and the difference
    /// is what the field decides: a scope decides who *else* can read the row, so
    /// there is nothing to fall back to, while `key`/`value` are the row's own
    /// content.
    fn dumpRowBytes(
        obj: std.json.ObjectMap,
        index: usize,
        name: []const u8,
        allocator: std.mem.Allocator,
    ) !?[]const u8 {
        const v = obj.get(name) orelse {
            std.log.warn("[ai.memory] dump item {d} skipped: no `{s}`", .{ index, name });
            return null;
        };
        return switch (v) {
            .string => |s| s,
            .array => |items| byteArrayValue(allocator, index, name, items.items),
            else => |other| {
                std.log.warn("[ai.memory] dump item {d} skipped: `{s}` is {s}, not a string or a byte array", .{ index, name, @tagName(other) });
                return null;
            },
        };
    }

    /// The bytes behind the array form `std.json` writes for a `[]const u8` that
    /// is not valid UTF-8: one integer per byte, each in `0..255` (the writer takes
    /// its string branch only `if (... and std.unicode.utf8ValidateSlice(slice))`,
    /// and otherwise writes the slice as an array of its elements).
    ///
    /// The dump's own bytes, rebuilt in `allocator`. `null` means the array is not
    /// that form — a member that is not an integer, or one outside byte range — and
    /// the caller skips the item with the warning logged here: a shape this pair
    /// never wrote is not repaired, and no scope is in question, so nothing about
    /// it justifies refusing a whole file the way an unstated `tenant_id` does.
    fn byteArrayValue(
        allocator: std.mem.Allocator,
        index: usize,
        name: []const u8,
        items: []const std.json.Value,
    ) !?[]const u8 {
        const bytes = try allocator.alloc(u8, items.len);
        for (items, 0..) |item, at| {
            const n = switch (item) {
                .integer => |n| n,
                else => |other| {
                    std.log.warn("[ai.memory] dump item {d} skipped: `{s}` member {d} is {s}, not an integer", .{ index, name, at, @tagName(other) });
                    return null;
                },
            };
            bytes[at] = std.math.cast(u8, n) orelse {
                std.log.warn("[ai.memory] dump item {d} skipped: `{s}` member {d} is {d}, outside 0..255", .{ index, name, at, n });
                return null;
            };
        }
        return bytes;
    }

    /// The history a dump row states, or `null` when it is not stated. The three
    /// fields are read as one unit, so a row whose `created_at` is mistyped cannot
    /// keep a stale `last_accessed_at` from the same file driving eviction.
    ///
    /// Unlike `dumpRowScope` this has a fallback, and the difference is not
    /// convenience: a scope the dump does not state cannot be filled in without
    /// widening who may read the row (`0` is `recall`'s "any"), while a history only
    /// decides *when* the row is evicted. So an unusable field is warned and the
    /// row is still restored, stamped as new — which is what every restored row got
    /// before, except that now it is the fallback rather than the rule.
    fn dumpRowHistory(obj: std.json.ObjectMap, index: usize) ?EntryHistory {
        const created_at = dumpRowHistoryField(obj, index, "created_at") orelse return null;
        const stated_count = dumpRowHistoryField(obj, index, "access_count") orelse return null;
        const last_accessed_at = dumpRowHistoryField(obj, index, "last_accessed_at") orelse return null;
        const access_count = std.math.cast(usize, stated_count) orelse {
            std.log.warn("[ai.memory] dump item {d}: `access_count` is {d}, not a count; the row is restored with a fresh stamp", .{ index, stated_count });
            return null;
        };
        return .{
            .created_at = created_at,
            .access_count = access_count,
            .last_accessed_at = last_accessed_at,
        };
    }

    fn dumpRowHistoryField(obj: std.json.ObjectMap, index: usize, name: []const u8) ?i64 {
        const v = obj.get(name) orelse {
            std.log.warn("[ai.memory] dump item {d}: `{s}` is not stated; the row is restored with a fresh stamp", .{ index, name });
            return null;
        };
        return switch (v) {
            .integer => |n| n,
            else => |other| {
                std.log.warn("[ai.memory] dump item {d}: `{s}` is {s}, not an integer; the row is restored with a fresh stamp", .{ index, name, @tagName(other) });
                return null;
            },
        };
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

// An item that is not a row at all — not an object, or without a readable
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

// `dumpJson` writes a `[]const u8` that is not valid UTF-8 as an *array of byte
// values* rather than a JSON string (`std/json/stringify.zig`: the string branch
// is `if (!self.options.emit_strings_as_arrays and std.unicode.utf8ValidateSlice(slice))`),
// and `loadJson` used to read only the string form — so a binary memory was
// written by the pair and dropped on restore (silently before the last batch,
// with a `value is array, not a string` warning after it). A dump is a snapshot:
// what it states has to come back. The array form is rebuilt byte-for-byte and
// owned like every other value the reader hands to the store, and the entry is an
// ordinary entry afterwards — `recall` returns it and `formatContext` takes it.
//
// `key` is the same `[]const u8` and the same asymmetry (`remember` never
// validated it as text), so it is read the same way; the third row below has a
// binary key and exercises that.
//
// The dump below is produced by `dumpJson`, so the shape assertions pin the pair's
// own output rather than a hand-written expectation of it.
//
// Red on the old shape: `expected 3, found 1` — both binary rows never arrived.
test "dumpJson and loadJson round trip bytes that are not valid UTF-8" {
    const a = std.testing.allocator;
    const binary = [_]u8{ 0xFF, 0xFE, 0x00, 0x6F, 0x6B };
    const binary_key = [_]u8{ 0xC3, 0x28 };
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();
    try store.remember("user:fact:bin", &binary, 3, 4);
    try store.remember("user:fact:text", "ok", 3, 4);
    try store.remember(&binary_key, "binary key", 3, 4);

    const json = try store.dumpJson(a);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "[255,254,0,111,107]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[195,40]") != null);

    var store2 = MemoryStore.init(a, std.testing.io);
    defer store2.deinit();
    try store2.loadJson(json);
    try std.testing.expectEqual(@as(usize, 3), store2.count());

    // The whole snapshot survives: the same rows, with the same bytes — the binary
    // key and value back in the array form the writer picks for them, so
    // `dumpJson` → `loadJson` → `dumpJson` is byte-identical.
    const redumped = try store2.dumpJson(a);
    defer a.free(redumped);
    try std.testing.expectEqualStrings(json, redumped);

    var got = try store2.recall(a, "user:fact:bin", 3, 4);
    defer {
        for (got.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        got.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualSlices(u8, &binary, got.items[0].value);

    // The key came back as bytes too, and is addressable as a key: a binary prefix
    // still finds it, and the row's own key is the exact byte sequence.
    var by_key = try store2.recall(a, &binary_key, 3, 4);
    defer {
        for (by_key.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        by_key.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), by_key.items.len);
    try std.testing.expectEqualSlices(u8, &binary_key, by_key.items[0].key);
    try std.testing.expectEqualStrings("binary key", by_key.items[0].value);

    const ctx = try store2.formatContext(a, "user:fact:bin", 3, 4, 4);
    defer a.free(ctx);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "- ") != null);
}

// The array form is read as bytes only when it *is* one: every member an integer
// in `0..255`. Anything else did not come from this pair's writer, so the item is
// skipped with a warning — the same answer a `key`/`value` of the wrong type gets.
// It is deliberately not a whole-file refusal: nothing here makes a claim about a
// scope (which is what `dumpRowScope` refuses over), it is one row's content that
// cannot be read, and forcing the operator to repair the file to lose one
// unreadable row is a disproportionate answer. The last two items are a malformed
// array in `key` rather than `value`: the same shape rule, read by the same helper.
//
// Red on the old shape: `expected 1, found 0` — even the readable byte-array row
// was skipped.
test "loadJson reads the byte-array form and skips arrays that are not one" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();

    const mixed =
        \\[{"key":"user:fact:bytes","value":[104,105],"tenant_id":1,"user_id":2},
        \\ {"key":"user:fact:text-member","value":[104,"i"],"tenant_id":1,"user_id":2},
        \\ {"key":"user:fact:high","value":[104,300],"tenant_id":1,"user_id":2},
        \\ {"key":"user:fact:negative","value":[104,-1],"tenant_id":1,"user_id":2},
        \\ {"key":"user:fact:float","value":[104,1.5],"tenant_id":1,"user_id":2},
        \\ {"key":[104,"i"],"value":"v","tenant_id":1,"user_id":2},
        \\ {"key":[104,300],"value":"v","tenant_id":1,"user_id":2}]
    ;
    try store.loadJson(mixed);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    var got = try store.recall(a, "user:fact:bytes", 1, 2);
    defer {
        for (got.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        got.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualStrings("hi", got.items[0].value);
}

// A dump is a snapshot of an entry's *state*, and `dumpJson` writes all of it —
// `created_at`, `access_count`, `last_accessed_at` next to the identity and the
// value. The reader used to take only identity and value: every restored row went
// through `remember`, which stamps a row as new. The consequence is not cosmetic
// — `evictOldestLocked` picks the smallest `last_accessed_at`, so after a restore
// every row compared equal and eviction fell back to hash-iteration order: the
// store threw away an arbitrary row while claiming to throw away the oldest one.
//
// Red on the old shape: the re-dump below carries the clock instead of the stated
// `"created_at":100` / `"last_accessed_at":1000`, and the eviction assertion finds
// the wrong row gone.
test "loadJson restores the row's own recency so eviction can pick the oldest" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();
    store.max_entries = 3;

    const dump =
        \\[{"key":"user:fact:old","value":"old","tenant_id":1,"user_id":2,"created_at":100,"access_count":7,"last_accessed_at":1000},
        \\ {"key":"user:fact:mid","value":"mid","tenant_id":1,"user_id":2,"created_at":200,"access_count":3,"last_accessed_at":2000},
        \\ {"key":"user:fact:new","value":"new","tenant_id":1,"user_id":2,"created_at":300,"access_count":1,"last_accessed_at":3000}]
    ;
    try store.loadJson(dump);

    const redumped = try store.dumpJson(a);
    defer a.free(redumped);
    try std.testing.expect(std.mem.indexOf(u8, redumped, "\"created_at\":100,\"access_count\":7,\"last_accessed_at\":1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, redumped, "\"created_at\":300,\"access_count\":1,\"last_accessed_at\":3000") != null);

    // One more fact overflows `max_entries`: the row that goes must be the one the
    // dump says is oldest, not whichever row the hash order happens to visit first.
    try store.remember("user:fact:fourth", "fourth", 1, 2);
    try std.testing.expectEqual(@as(usize, 3), store.count());
    const after = try store.dumpJson(a);
    defer a.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "user:fact:old") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "user:fact:mid") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "user:fact:new") != null);
}

// Not every file is one this class wrote, and a row whose history is unreadable is
// still a memory whose key, value and scope *are* readable — dropping it would
// destroy content over a timestamp. So an unreadable history is taken as unstated
// and the row is stamped the way `remember` stamps it, which is what every
// restored row did before. What the reader must not do is half-trust a snapshot:
// the three fields are read as a unit, so one mistyped field leaves no stale
// `last_accessed_at` behind to drive eviction.
test "loadJson keeps a row whose history is not stated, stamped as new" {
    const a = std.testing.allocator;

    const dumps = [_][]const u8{
        // nothing stated at all
        \\[{"key":"user:fact:v","value":"v","tenant_id":1,"user_id":2}]
        ,
        // one of the three mistyped
        \\[{"key":"user:fact:v","value":"v","tenant_id":1,"user_id":2,"created_at":"100","access_count":7,"last_accessed_at":1000}]
        ,
        // a count that cannot be a count
        \\[{"key":"user:fact:v","value":"v","tenant_id":1,"user_id":2,"created_at":100,"access_count":-1,"last_accessed_at":1000}]
        ,
    };

    for (dumps) |dump| {
        var store = MemoryStore.init(a, std.testing.io);
        defer store.deinit();
        try store.loadJson(dump);
        try std.testing.expectEqual(@as(usize, 1), store.count());

        const redumped = try store.dumpJson(a);
        defer a.free(redumped);
        // Fresh stamp: the numbers the file states are not what the row states now,
        // and the unusable one is not half-kept either.
        try std.testing.expect(std.mem.indexOf(u8, redumped, "\"created_at\":100,") == null);
        try std.testing.expect(std.mem.indexOf(u8, redumped, "\"last_accessed_at\":1000") == null);
    }
}

// Loading over a row the store already holds replaces the whole row: the dump is
// the snapshot, so its value *and* its history win. This is the branch `putLocked`
// takes when the composite key is already present, and it is where `loadJson`
// parts company with `remember` — re-remembering a fact counts as an access
// (`access_count + 1`, recency now, `created_at` kept), while a restored one
// becomes what the file says. The recalls below are what makes "the dump won"
// visible in the numbers rather than looking like a fresh stamp.
test "loadJson overwrites an existing row with the dump's value and history" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();
    try store.remember("user:fact:k", "live", 1, 2);

    for (0..2) |_| {
        var seen = try store.recall(a, "user:fact:k", 1, 2);
        for (seen.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        seen.deinit(a);
    }

    const dump =
        \\[{"key":"user:fact:k","value":"from-dump","tenant_id":1,"user_id":2,"created_at":500,"access_count":9,"last_accessed_at":900}]
    ;
    try store.loadJson(dump);

    // Overwritten, not duplicated — and the row a re-dump states is the file's row.
    try std.testing.expectEqual(@as(usize, 1), store.count());
    const after = try store.dumpJson(a);
    defer a.free(after);
    try std.testing.expectEqualStrings(dump, after);
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
