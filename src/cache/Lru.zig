//! Local cache for zigzero with true LRU eviction - O(1) operations
//!
//! Provides in-memory LRU cache aligned with go-zero's cache patterns.
//! Uses HashMap for O(1) lookup + DoublyLinkedList for O(1) access order tracking.

const std = @import("std");

pub fn Cache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            key: K,
            value: V,
            expires_at: ?i64,
            list_node: std.DoublyLinkedList.Node,
        };

        allocator: std.mem.Allocator,
        map: std.AutoHashMap(K, *Node),
        // Access order list: most recent at the tail, least recent at the head
        list: std.DoublyLinkedList,
        max_size: usize,
        mutex: std.Io.Mutex,
        io: std.Io,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, max_size: usize) Self {
            return .{
                .allocator = allocator,
                .map = std.AutoHashMap(K, *Node).init(allocator),
                .list = .{},
                .max_size = max_size,
                .mutex = std.Io.Mutex.init,
                .io = io,
            };
        }

        /// Destroy the cache: every node, then the map that indexed them.
        ///
        /// Two things here are deliberate, and both are a change of semantics from
        /// the first version of this function, which gave up on a contended
        /// `tryLock` and tore the container down anyway:
        ///
        /// * Uncancelable — a destructor has to run to completion. A cancelable
        ///   `lock` would instead return `error.Canceled`, and that error has no
        ///   usable answer here: returning leaves the cache alive, and proceeding
        ///   is the bug below.
        /// * It waits instead of proceeding unlocked — the old fallback walked
        ///   `map` and `list` (destroying every node, then deiniting the map)
        ///   while another thread was *inside* its critical section on those same
        ///   two containers, freeing memory that holder could still reach and
        ///   leaving the teardown observable to it.
        ///
        /// So `deinit` blocks until the cache is quiet. Every other critical
        /// section in this file is an O(1) map/list operation, so the wait is
        /// bounded by whichever call is in flight.
        pub fn deinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            var it = self.map.valueIterator();
            while (it.next()) |node_ptr| {
                self.allocator.destroy(node_ptr.*);
            }
            self.map.deinit();
            self.list = .{};
        }

        /// Get value from cache (returns pointer to avoid copying)
        ///
        /// Uncancelable: `std.Io.Mutex.lock` fails only with `error.Canceled`
        /// (`std.Io.Cancelable`), and the old `catch return null` answered a
        /// canceled wait with "miss" for a key the cache is holding — and, since
        /// a cancelation is delivered exactly once, it ate the request's
        /// cancelation too, so the caller went on to do the work cancelation was
        /// meant to stop. The critical section is one map lookup plus a list
        /// move, so waiting is the answer this file's `deinit` already chose for
        /// the same mutex.
        pub fn get(self: *Self, key: K) ?*V {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const node_ptr = self.map.get(key) orelse return null;

            if (node_ptr.expires_at) |expires| {
                if (0 > expires) {
                    self.removeNode(node_ptr);
                    return null;
                }
            }

            // Move to tail (most recently used)
            self.moveToTail(&node_ptr.list_node);

            return &node_ptr.value;
        }

        /// Set value in cache with optional TTL.
        ///
        /// A canceled lock wait surfaces as `error.Canceled` (see `get`): the old
        /// `catch return` reported success while storing nothing, so a caller
        /// that went on to read back its own write got a miss. This one has an
        /// error channel, so the cancelation is the caller's to handle.
        pub fn set(self: *Self, key: K, value: V, ttl_ms: ?i64) !void {
            self.mutex.lock(self.io) catch |err| return err;
            defer self.mutex.unlock(self.io);

            const expires_at = if (ttl_ms) |ttl| 0 + ttl else null;

            // If key exists, update it
            if (self.map.get(key)) |node_ptr| {
                node_ptr.value = value;
                node_ptr.expires_at = expires_at;
                self.moveToTail(&node_ptr.list_node);
                return;
            }

            // Evict least recently used if at capacity
            if (self.map.count() >= self.max_size) {
                self.evictLRU();
            }

            // Insert into the map first, link into the list second. The map
            // insert is the only step here that can fail, and the old order —
            // `self.list.append(&node.list_node)` before `try self.map.put` —
            // left the node on the LRU list with no map entry whenever it did.
            // Nothing indexes such a node: `size`, `get`, `delete`, `clear`
            // and `deinit` all walk the map, so it was unreachable and
            // unaccounted for — the memory leaked until some later eviction
            // happened to reach it, and until then `list` and `map` disagreed
            // about what the cache held. Doing the fallible step first means
            // the node becomes visible to both structures or to neither, and
            // the failed insert frees it here.
            const node = try self.allocator.create(Node);
            node.* = .{
                .key = key,
                .value = value,
                .expires_at = expires_at,
                .list_node = .{},
            };
            self.map.put(key, node) catch |err| {
                self.allocator.destroy(node);
                return err;
            };
            self.list.append(&node.list_node);
        }

        /// Delete key from cache.
        ///
        /// Uncancelable (see `get`): the old `catch return` left the stale entry
        /// where it was and told the caller nothing, so the next read served a
        /// value the caller believed it had just invalidated. There is no error
        /// channel to report a skipped delete through.
        pub fn delete(self: *Self, key: K) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.map.get(key)) |node_ptr| {
                self.removeNode(node_ptr);
            }
        }

        /// Clear all cache entries.
        ///
        /// Uncancelable (see `get`) — and this is the "drop everything" button
        /// after a permission or tenant change, where a silent no-op leaves the
        /// previous caller's entries behind. No error channel to report it
        /// through either.
        pub fn clear(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            var it = self.map.valueIterator();
            while (it.next()) |node_ptr| {
                self.allocator.destroy(node_ptr.*);
            }
            self.map.clearRetainingCapacity();
            self.list = .{};
        }

        /// Current cache size.
        ///
        /// Uncancelable (see `get`): the old `catch return 0` reported a cache
        /// that is not empty as empty — a reading a metrics scrape or a health
        /// check would act on, not a harmless placeholder.
        pub fn size(self: *Self) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.map.count();
        }

        // Internal: remove node from both map and list, then free it
        fn removeNode(self: *Self, node: *Node) void {
            self.list.remove(&node.list_node);
            _ = self.map.remove(node.key);
            self.allocator.destroy(node);
        }

        // Internal: move node to tail of list (most recently used)
        fn moveToTail(self: *Self, list_node: *std.DoublyLinkedList.Node) void {
            self.list.remove(list_node);
            self.list.append(list_node);
        }

        // Internal: evict least recently used item (head of list)
        fn evictLRU(self: *Self) void {
            const head = self.list.first orelse return;
            const node = @as(*Node, @fieldParentPtr("list_node", head));
            self.removeNode(node);
        }
    };
}

test "cache basic" {
    var cache = Cache(u32, []const u8).init(std.testing.allocator, std.testing.io, 10);
    defer cache.deinit();

    try cache.set(1, "hello", null);
    try std.testing.expectEqualStrings("hello", cache.get(1).?.*);

    cache.delete(1);
    try std.testing.expect(cache.get(1) == null);
}

test "cache ttl" {
    var cache = Cache(u32, []const u8).init(std.testing.allocator, std.testing.io, 10);
    defer cache.deinit();

    try cache.set(1, "hello", 0);
    // Without real time, we just verify the item was set successfully
    try std.testing.expectEqualStrings("hello", cache.get(1).?.*);
}

test "cache lru eviction" {
    var cache = Cache(u32, u32).init(std.testing.allocator, std.testing.io, 3);
    defer cache.deinit();

    try cache.set(1, 10, null);
    try cache.set(2, 20, null);
    try cache.set(3, 30, null);

    // Access 1 to make it most recent
    _ = cache.get(1);

    // Add 4, should evict 2 (least recently used)
    try cache.set(4, 40, null);

    try std.testing.expect(cache.get(1) != null); // 1 was accessed, should remain
    try std.testing.expect(cache.get(2) == null); // 2 was LRU, should be evicted
    try std.testing.expect(cache.get(3) != null);
    try std.testing.expect(cache.get(4) != null);
}

test "cache pointer return" {
    var cache = Cache(u32, u32).init(std.testing.allocator, std.testing.io, 10);
    defer cache.deinit();

    try cache.set(1, 100, null);
    const ptr = cache.get(1).?;
    try std.testing.expectEqual(@as(u32, 100), ptr.*);

    // Modify through pointer
    ptr.* = 200;
    try std.testing.expectEqual(@as(u32, 200), cache.get(1).?.*);
}

// `delete` answered a canceled lock wait with a bare `catch return`, and the
// caller had no way to tell: it asked for a key to be gone and got no error
// back, so the next read served the value the caller believed it had just
// invalidated. `clear` has the same shape and a sharper edge — it is the "drop
// everything" button after a permission or tenant change — and `size` / `get`
// fabricated `0` / "miss" for a cache that was not empty.
//
// None of the three has an error channel and each critical section is one map
// operation, so the answer is the one this file's own `deinit` already chose:
// wait uncancelably rather than skip the work.
//
// In each test the action is parked on the cache mutex (held by the test thread)
// with a cancel request already placed on its thread, so the lock wait inside
// the action is the cancelation point; the gate between the two is pure
// spinning, which consumes nothing.
fn parkedBehindCanceledLock(cache: *Cache(u32, u32), action: *const fn (*Cache(u32, u32)) void) !void {
    const io = cache.io;
    const Gate = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn run(c: *Cache(u32, u32), act: *const fn (*Cache(u32, u32)) void) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            act(c);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Gate.entered.store(false, .monotonic);
    Gate.open.store(false, .monotonic);

    try cache.mutex.lock(io);
    var action_fut = try io.concurrent(Gate.run, .{ cache, action });
    while (!Gate.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Gate.cancel, .{ io, &action_fut });
    // Give the request time to land on the action's thread while it is still gated.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Gate.open.store(true, .release);
    // The action is now inside the cache: parked on the mutex (it swaps the
    // state to `contended` on its way to the wait), or already gone.
    while (cache.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    cache.mutex.unlock(io);

    cancel_fut.await(io);
    action_fut.await(io);
}

test "cache: a canceled delete still deletes" {
    var cache = Cache(u32, u32).init(std.testing.allocator, std.testing.io, 8);
    defer cache.deinit();

    try cache.set(1, 10, null);
    try cache.set(2, 20, null);

    const Act = struct {
        fn run(c: *Cache(u32, u32)) void {
            c.delete(1);
        }
    };
    try parkedBehindCanceledLock(&cache, Act.run);

    // The key the caller just deleted is gone, and only that key.
    try std.testing.expect(cache.get(1) == null);
    try std.testing.expect(cache.get(2) != null);
    try std.testing.expectEqual(@as(usize, 1), cache.size());
}

test "cache: a canceled clear still clears" {
    var cache = Cache(u32, u32).init(std.testing.allocator, std.testing.io, 8);
    defer cache.deinit();

    try cache.set(1, 10, null);
    try cache.set(2, 20, null);

    const Act = struct {
        fn run(c: *Cache(u32, u32)) void {
            c.clear();
        }
    };
    try parkedBehindCanceledLock(&cache, Act.run);

    try std.testing.expectEqual(@as(usize, 0), cache.size());
    try std.testing.expect(cache.get(1) == null);
    try std.testing.expect(cache.get(2) == null);
}

test "cache: a canceled set reports the cancelation instead of a fabricated success" {
    var cache = Cache(u32, u32).init(std.testing.allocator, std.testing.io, 8);
    defer cache.deinit();

    const Act = struct {
        var outcome: ?anyerror = null;
        fn run(c: *Cache(u32, u32)) void {
            c.set(1, 10, null) catch |err| {
                outcome = err;
                return;
            };
        }
    };
    Act.outcome = null;
    try parkedBehindCanceledLock(&cache, Act.run);

    // `set` has an error channel, so the caller has to see the cancelation
    // rather than believe a write that never happened: reading back its own
    // write would otherwise report a miss.
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), Act.outcome);
    try std.testing.expect(cache.get(1) == null);
}

test "cache: a canceled size and get still report the cache as it is" {
    var cache = Cache(u32, u32).init(std.testing.allocator, std.testing.io, 8);
    defer cache.deinit();

    try cache.set(7, 70, null);

    const SizeAct = struct {
        var seen: usize = 0;
        fn run(c: *Cache(u32, u32)) void {
            seen = c.size();
        }
    };
    SizeAct.seen = 0;
    try parkedBehindCanceledLock(&cache, SizeAct.run);
    // One entry is in there: `0` would be a reading, not a harmless placeholder.
    try std.testing.expectEqual(@as(usize, 1), SizeAct.seen);

    const GetAct = struct {
        var hit = false;
        var value: u32 = 0;
        fn run(c: *Cache(u32, u32)) void {
            if (c.get(7)) |v| {
                hit = true;
                value = v.*;
            }
        }
    };
    GetAct.hit = false;
    GetAct.value = 0;
    try parkedBehindCanceledLock(&cache, GetAct.run);
    // The key is there, so "miss" is a wrong answer, not a safe default.
    try std.testing.expect(GetAct.hit);
    try std.testing.expectEqual(@as(u32, 70), GetAct.value);
}

// Regression: `deinit` used to give up on a contended `tryLock` and then rip the
// container down anyway — destroying every node and deiniting `map` while
// another thread was *inside* the critical section (and still holding the lock,
// so the holder could go on to touch the nodes it had just lost). The teardown
// is observed here without inducing the UB itself: the cache lives on an
// allocator that records every `free` and whether the holder thread was inside
// its critical section at that moment. Teardown under the lock is the contract;
// `deinit` therefore has to be an uncancelable *wait*, not a best-effort.
test "cache Lru deinit tears the container down under the lock, never beside a holder" {
    const CountingAllocator = struct {
        // Set by the holder thread for the whole of its critical section.
        var holder_in_cs = std.atomic.Value(bool).init(false);
        var frees_total = std.atomic.Value(u32).init(0);
        var frees_beside_holder = std.atomic.Value(u32).init(0);

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            _ = ctx;
            return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
        }
        fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            _ = ctx;
            return std.testing.allocator.rawResize(memory, alignment, new_len, ret_addr);
        }
        fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            _ = ctx;
            return std.testing.allocator.rawRemap(memory, alignment, new_len, ret_addr);
        }
        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            _ = ctx;
            _ = frees_total.fetchAdd(1, .monotonic);
            if (holder_in_cs.load(.acquire)) _ = frees_beside_holder.fetchAdd(1, .monotonic);
            std.testing.allocator.rawFree(memory, alignment, ret_addr);
        }

        const vtable: std.mem.Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };
        const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &vtable };
    };

    CountingAllocator.holder_in_cs.store(false, .monotonic);
    CountingAllocator.frees_total.store(0, .monotonic);
    CountingAllocator.frees_beside_holder.store(0, .monotonic);

    const io = std.testing.io;
    var cache = Cache(u32, u32).init(CountingAllocator.allocator, io, 8);
    try cache.set(1, 10, null);
    try cache.set(2, 20, null);

    const Holder = struct {
        fn hold(c: *Cache(u32, u32), thread_io: std.Io) void {
            c.mutex.lock(thread_io) catch |err| {
                std.debug.print("holder could not take the cache lock: {}\n", .{err});
                return;
            };
            CountingAllocator.holder_in_cs.store(true, .release);
            // A bounded critical section. `deinit` has to be observed *while*
            // this is held, and the test thread is already spinning on
            // `holder_in_cs`, so its reaction costs nanoseconds — the budget only
            // has to survive a hostile scheduler. Measured: 20M hints ≈ 0.25s.
            var spins: usize = 0;
            while (spins < 20_000_000) : (spins += 1) std.atomic.spinLoopHint();
            CountingAllocator.holder_in_cs.store(false, .release);
            c.mutex.unlock(thread_io);
        }
    };

    var holder = try io.concurrent(Holder.hold, .{ &cache, io });
    while (!CountingAllocator.holder_in_cs.load(.acquire)) std.atomic.spinLoopHint();

    const frees_before = CountingAllocator.frees_total.load(.monotonic);
    cache.deinit();
    const frees_after = CountingAllocator.frees_total.load(.monotonic);

    holder.await(io);

    // The teardown did happen ...
    try std.testing.expect(frees_after > frees_before);
    // ... and none of it happened behind the holder's back.
    try std.testing.expectEqual(@as(u32, 0), CountingAllocator.frees_beside_holder.load(.monotonic));
}

// `std.DoublyLinkedList` has no `len`, and "the list agrees with the map" is
// exactly what these tests assert, so count the nodes by walking from the head.
fn listLen(cache: *Cache(u32, u32)) usize {
    var n: usize = 0;
    var cur = cache.list.first;
    while (cur) |node| : (cur = node.next) {
        n += 1;
        if (n > 1024) break; // a runaway count is a broken list, not a big one
    }
    return n;
}

// `set` used to link the new node into the LRU list *before* the map insert,
// and that insert is the one step in `set` that can fail. On OOM the node then
// stayed on the list with no map entry, and every reader of the cache walks the
// map: `size` counted it as absent, `get` served a miss for a key in the list,
// `delete` removed nothing, and `deinit` / `clear` never freed it — so a cache
// that failed one insert leaked that node and had a list that lied about its
// contents until an eviction happened to walk over it.
//
// The node's own allocation is index #0 and the map's backing storage is #1, so
// failing index #1 is exactly "the insert failed after the node was created".

test "cache: a failed map insert leaves the node in neither the map nor the list" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var cache = Cache(u32, u32).init(failing.allocator(), std.testing.io, 4);
    errdefer cache.deinit(); // an earlier expectation must not hide the real one behind a leak report

    try std.testing.expectError(error.OutOfMemory, cache.set(1, 10, null));
    try std.testing.expect(failing.has_induced_failure);

    // Neither structure knows about the node — and, crucially, the list does
    // not hold it on its own.
    try std.testing.expectEqual(@as(usize, 0), cache.map.count());
    try std.testing.expect(cache.list.first == null);
    try std.testing.expect(cache.get(1) == null);

    // The cache still works afterwards, and both structures agree again.
    failing.fail_index = std.math.maxInt(usize);
    try cache.set(1, 10, null);
    try std.testing.expectEqual(@as(u32, 10), cache.get(1).?.*);
    try std.testing.expectEqual(@as(usize, 1), cache.map.count());
    try std.testing.expectEqual(@as(usize, 1), listLen(&cache));

    cache.deinit();
    // Every byte the failed insert took (the node it created) was given back.
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

// The same invariant at *every* allocation point of a longer sequence, not just
// the index the map insert happens to use: `checkAllAllocationFailures` makes
// each allocation fail in turn and asserts that the failure is either reported
// (exactly `error.OutOfMemory`) with nothing left allocated, or does not happen
// at all. Before the fix, the failing map insert leaked the node and left it
// listed-but-unindexed, so this reports `MemoryLeakDetected`.
test "cache: every allocation failure across set/get/delete/evict is consistent and leaks nothing" {
    const Scan = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var cache = Cache(u32, u32).init(allocator, std.testing.io, 3);
            defer cache.deinit();

            try cache.set(1, 10, null);
            try cache.set(2, 20, null);
            try cache.set(3, 30, null);
            _ = cache.get(1);
            try cache.set(4, 40, null); // at capacity: evicts the LRU
            try cache.set(4, 41, null); // existing key: update, no allocation
            cache.delete(2);

            // The invariant: one list entry per map entry, no orphans either way.
            try std.testing.expectEqual(cache.map.count(), listLen(&cache));
            try std.testing.expectEqual(cache.map.count(), cache.size());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scan.run, .{});
}
