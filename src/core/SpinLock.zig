//! Minimal io-free mutual exclusion for tiny critical sections.
//!
//! `std.Io.Mutex` is the idiomatic choice for a shared mutable structure, but
//! its `lock`/`unlock` take an `Io` — threading that through every accessor
//! (`tryAcquire`, `getOrCreate`, `authRateLimitMiddleware`, …) would change
//! public signatures for callers that only ever touch a map or two counters.
//!
//! Short critical sections (a hash-map lookup, two float operations) do not need
//! a futex: this spins briefly, then yields the time slice, so it degrades to
//! polite waiting instead of burning a core under sustained contention.
//!
//! Use this only for that shape. If a critical section can block (I/O, an
//! allocation that may page, a callback into user code), use `std.Io.Mutex`.

const std = @import("std");

pub const SpinLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins < 32) {
                std.atomic.spinLoopHint();
            } else {
                // A failed yield is benign (we just retry the acquire), but it is
                // still an error — surface it at debug rather than swallowing it.
                std.Thread.yield() catch |err| std.log.debug("[SpinLock] lock wait: yield failed ({s}), retrying", .{@errorName(err)});
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }

    pub fn tryLock(self: *SpinLock) bool {
        return self.state.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }
};

test "SpinLock excludes and releases" {
    var lock_state: SpinLock = .{};
    try std.testing.expect(lock_state.tryLock());
    // Held: a second acquisition must fail rather than corrupt anything.
    try std.testing.expect(!lock_state.tryLock());
    lock_state.unlock();
    try std.testing.expect(lock_state.tryLock());
    lock_state.unlock();
}

test "SpinLock serialises a shared counter" {
    const threads_n: usize = 16;
    const per_thread: usize = 2_000;

    const Shared = struct {
        lock_state: SpinLock = .{},
        counter: u64 = 0,

        fn bump(self: *@This()) void {
            self.lock_state.lock();
            defer self.lock_state.unlock();
            // Read-modify-write: the unsynchronised version loses updates.
            self.counter += 1;
        }
    };
    var shared: Shared = .{};

    const threads = try std.testing.allocator.alloc(std.Thread, threads_n);
    defer std.testing.allocator.free(threads);
    const Worker = struct {
        fn run(s: *Shared) void {
            for (0..per_thread) |_| s.bump();
        }
    };
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&shared});
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, threads_n * per_thread), shared.counter);
}
