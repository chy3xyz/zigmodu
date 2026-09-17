//! Fixed-capacity object pool — reuse hot-path objects instead of churning the
//! allocator.
//!
//! `init(allocator, capacity)` allocates every slot up front. `acquire` hands out
//! a `*T` from the free list and `release` returns it; a caller that forgets to
//! release does not corrupt anything, it just runs out (and `acquire` says so
//! instead of allocating).
//!
//! Why a pool at all: on a hot path the allocator is the thing that introduces
//! unpredictable latency (locks, size-class walks, page faults on a fresh region).
//! Reusing a fixed region removes that, and it also bounds memory — a pool cannot
//! grow past its capacity, so a traffic spike turns into "acquire failed, shed
//! load" rather than "RSS climbed until the OOM killer".
//!
//! Design note: the free list is guarded by `core/SpinLock` rather than being a
//! lock-free Treiber stack. A Treiber stack on indices is ~15 lines, but a stale
//! head pointer can hand the same object to two callers (ABA), and handing out an
//! object twice is a data race that no test reliably catches. The critical
//! section here is a pointer swap, so the lock costs little and is provably
//! correct; if a profile ever shows it, shard the pool per thread instead.
//!
//! Adoption note (2026-09-17): **no in-tree consumer yet** — `src/im/`
//! ConnectionRegistry keeps its own specialised free list, because it pools
//! connection entries (a lock-free table, different constraints). Treat this as a
//! public primitive: reach for it where a *bounded* pool of ordinary objects is
//! wanted, and expect `acquire` to say "no" instead of growing.

const std = @import("std");
const SpinLock = @import("../core/SpinLock.zig").SpinLock;

pub fn ObjectPool(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        slots: []T,
        /// Intrusive free list: index of the next free slot, or `null`.
        next_free: []?usize,
        free_head: ?usize = null,
        lock: SpinLock = .{},
        in_use: usize = 0,
        acquires: u64 = 0,
        releases: u64 = 0,
        exhaustions: u64 = 0,
        high_water: usize = 0,

        /// Caller-provided reset, applied on `release` so a recycled object never
        /// carries the previous request's state (the classic pool bug is a field
        /// that everyone assumes is zeroed).
        reset: ?*const fn (*T) void = null,

        pub fn init(allocator: std.mem.Allocator, slot_count: usize, reset: ?*const fn (*T) void) !Self {
            const slots = try allocator.alloc(T, slot_count);
            errdefer allocator.free(slots);
            const next_free = try allocator.alloc(?usize, slot_count);
            errdefer allocator.free(next_free);

            for (next_free, 0..) |*link, i| link.* = if (i + 1 < slot_count) i + 1 else null;
            return .{
                .allocator = allocator,
                .slots = slots,
                .next_free = next_free,
                .free_head = if (slot_count == 0) null else 0,
                .reset = reset,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
            self.allocator.free(self.next_free);
            self.* = undefined;
        }

        /// Pop a slot. Null when the pool is exhausted (the caller decides
        /// whether to shed, wait or fall back) — never allocates.
        pub fn acquire(self: *Self) ?*T {
            self.lock.lock();
            defer self.lock.unlock();

            const index = self.free_head orelse {
                self.exhaustions += 1;
                return null;
            };
            self.free_head = self.next_free[index];
            self.next_free[index] = null;
            self.in_use += 1;
            self.acquires += 1;
            if (self.in_use > self.high_water) self.high_water = self.in_use;
            return &self.slots[index];
        }

        /// Return a slot obtained from `acquire`. `reset` (if set) runs before the
        /// object re-enters the free list.
        pub fn release(self: *Self, object: *T) bool {
            const base = @intFromPtr(self.slots.ptr);
            const addr = @intFromPtr(object);
            if (addr < base or addr >= base + self.slots.len * @sizeOf(T)) return false;
            const offset = addr - base;
            if (offset % @sizeOf(T) != 0) return false;
            const index = offset / @sizeOf(T);

            self.lock.lock();
            defer self.lock.unlock();

            if (self.next_free[index] != null or self.free_head == index) return false; // double release
            if (self.reset) |r| r(object);
            self.next_free[index] = self.free_head;
            self.free_head = index;
            self.in_use -= 1;
            self.releases += 1;
            return true;
        }

        pub fn capacity(self: *const Self) usize {
            return self.slots.len;
        }

        pub fn available(self: *Self) usize {
            self.lock.lock();
            defer self.lock.unlock();
            return self.slots.len - self.in_use;
        }

        pub fn stats(self: *Self) Stats {
            self.lock.lock();
            defer self.lock.unlock();
            return .{
                .capacity = self.slots.len,
                .in_use = self.in_use,
                .acquires = self.acquires,
                .releases = self.releases,
                .exhaustions = self.exhaustions,
                .high_water = self.high_water,
            };
        }

        pub const Stats = struct {
            capacity: usize,
            in_use: usize,
            acquires: u64,
            releases: u64,
            /// `acquire` calls that found the pool empty.
            exhaustions: u64,
            high_water: usize,
        };
    };
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

const Probe = struct { value: u32 = 0, touched: bool = false };

test "ObjectPool hands out slots without allocating and reports exhaustion" {
    var pool = try ObjectPool(Probe).init(std.testing.allocator, 2, null);
    defer pool.deinit();

    const a = pool.acquire().?;
    const b = pool.acquire().?;
    try std.testing.expect(a != b);
    try std.testing.expect(pool.acquire() == null); // bounded: refuses instead of growing
    try std.testing.expectEqual(@as(u64, 1), pool.stats().exhaustions);

    try std.testing.expect(pool.release(a));
    const c = pool.acquire().?;
    try std.testing.expectEqual(a, c); // the released slot is the one reused
    try std.testing.expectEqual(@as(usize, 2), pool.stats().in_use);
}

test "ObjectPool runs the reset hook so recycled objects carry no state" {
    const resetFn = struct {
        fn call(p: *Probe) void {
            p.* = .{};
        }
    }.call;
    var pool = try ObjectPool(Probe).init(std.testing.allocator, 1, resetFn);
    defer pool.deinit();

    const obj = pool.acquire().?;
    obj.value = 7;
    obj.touched = true;
    try std.testing.expect(pool.release(obj));

    const again = pool.acquire().?;
    try std.testing.expectEqual(@as(u32, 0), again.value);
    try std.testing.expect(!again.touched);
}

test "ObjectPool refuses foreign pointers and double release" {
    var pool = try ObjectPool(Probe).init(std.testing.allocator, 1, null);
    defer pool.deinit();

    var foreign = Probe{};
    try std.testing.expect(!pool.release(&foreign)); // not ours

    const obj = pool.acquire().?;
    try std.testing.expect(pool.release(obj));
    try std.testing.expect(!pool.release(obj)); // double release
    try std.testing.expectEqual(@as(usize, 0), pool.stats().in_use);
    try std.testing.expectEqual(@as(u64, 1), pool.stats().releases);
}

test "ObjectPool survives concurrent acquire/release" {
    const threads_n = 8;
    const rounds = 20_000;

    var pool = try ObjectPool(Probe).init(std.testing.allocator, 16, null);
    defer pool.deinit();

    const Worker = struct {
        fn run(p: *ObjectPool(Probe)) void {
            for (0..rounds) |_| {
                const obj = p.acquire() orelse {
                    std.atomic.spinLoopHint();
                    continue;
                };
                obj.value +%= 1;
                _ = p.release(obj);
            }
        }
    };
    var threads: [threads_n]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&pool});
    for (threads) |t| t.join();

    const s = pool.stats();
    try std.testing.expectEqual(s.acquires, s.releases); // every acquire came back
    try std.testing.expectEqual(@as(usize, 0), s.in_use);
    try std.testing.expect(s.high_water <= 16);
}
