const std = @import("std");

/// Shared buffer pool for WebSocket frame I/O.
/// Replaces per-connection stack-allocated 4KB buffers (~8KB/fiber)
/// with a bounded pool (~300MB for 75000 buffers at 1M connections).
pub const BufferPool = struct {
    const Self = @This();
    const BufSize = 4096;

    allocator: std.mem.Allocator,
    free: std.ArrayList([]u8),
    mutex: std.Io.Mutex,
    io: std.Io,
    max: usize,
    allocated: usize,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, max: usize) Self {
        return .{
            .allocator = allocator,
            .free = std.ArrayList([]u8).empty,
            .mutex = std.Io.Mutex.init,
            .io = io,
            .max = max,
            .allocated = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        // A destructor has to run to completion, so it waits rather than
        // answering a contended `tryLock` by freeing the list underneath its
        // holder — that is memory unsafety: the holder's `free.append` would
        // write into freed storage and a buffer could be freed twice (same rule
        // as `cache/Lru.zig`'s and `pool/Pool.zig`'s `deinit`). There is no error
        // channel here, and `catch return` would leave the pool alive with
        // nothing left to free it. Red evidence for the old shape: the test
        // `deinit waits for a held lock instead of freeing underneath its holder`
        // fails on it.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.free.items) |buf| {
            self.allocator.free(buf);
        }
        self.free.deinit(self.allocator);
    }

    /// Acquire a 4KB buffer from the pool.
    ///
    /// `error.PoolExhausted` when the pool is already holding its cap; a canceled
    /// lock wait surfaces as `error.Canceled` (see the note in the body).
    pub fn acquire(self: *Self) ![]u8 {
        // `std.Io.Mutex.lock` fails only with `error.Canceled` (`std.Io.Cancelable`)
        // — it was reported here as `error.OutOfMemory`, an allocation failure
        // this call cannot have: the only allocations below go through
        // `self.allocator` and are reported as themselves. A cancellation is not
        // resource pressure, and the caller (`api/Server.zig`'s WS read loop)
        // reads any error here as "give up on this connection"; propagating it is
        // also what `Future.cancel` asks for — an unconsumed request stays pending
        // for the next cancellation point, which is not this call's to decide.
        self.mutex.lock(self.io) catch |err| return err;
        defer self.mutex.unlock(self.io);

        if (self.free.pop()) |buf| {
            return buf;
        }

        if (self.max == 0 or self.allocated < self.max) {
            const buf = try self.allocator.alloc(u8, BufSize);
            self.allocated += 1;
            return buf;
        }

        // Still reachable without genuine exhaustion: `allocated` counts buffers
        // that have no path back into the pool — one whose caller handed back a
        // sub-slice (refused and warned, the caller keeping it) or simply never
        // handed one back. The pool cannot tell such a buffer from a live one.
        // What is fixed is the pool's own accounting error: a canceled `release`
        // no longer drops the buffer (see there), so this side cannot lose count.
        return error.PoolExhausted;
    }

    /// Return a buffer to the pool for reuse.
    ///
    /// **Contract: `buf` must be one `acquire()` handed out** (i.e. `BufSize` bytes).
    /// A differently-sized slice is refused with a warning and left to the caller —
    /// this pool cannot free it (its allocator free needs the allocation's own
    /// length) and must not pool it.
    pub fn release(self: *Self, buf: []u8) void {
        // Uncancelable: `release` is the caller handing its buffer back, and a
        // canceled `mutex.lock` has no way to say "never mind" — the old
        // `catch return` left the buffer neither pooled nor freed, so `allocated`
        // stayed up for good and a later `acquire` reported `PoolExhausted` with
        // nothing live. Waiting is the honest answer (the critical section is one
        // list append), and there is nowhere for an error to go anyway: the WS
        // read loop calls this from a `defer` (`api/Server.zig`). Same choice as
        // `Pool.release` and `sqlx.ConnPool.release`.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // A buffer this pool did not hand out is not ours to free: `allocator.free`
        // needs the allocation's own length, so freeing a differently-sized slice is
        // wrong (the DebugAllocator rejects it outright). The old code just `return`ed
        // here — the caller's buffer was then neither pooled nor freed, and
        // `allocated` stayed inflated, so `acquire` would eventually report
        // `PoolExhausted` while nothing was actually live. It is a caller bug either
        // way; the only useful thing this side can do is name it instead of doing
        // nothing.
        // Only the *undersized* case is refused, which is the boundary this function
        // already had — keeping it means no caller's oversized buffer changes
        // behaviour here. What changed is the silence: `return`ing meant the caller's
        // buffer was neither pooled nor freed and `allocated` stayed inflated, so
        // `acquire` would eventually report `PoolExhausted` while nothing was live.
        // This side cannot free it (the allocator needs the allocation's own length)
        // and must not pool it, so naming the caller bug is the useful thing to do.
        if (buf.len < BufSize) {
            std.log.warn("[BufferPool] release() got a {d}-byte buffer; this pool hands out {d}-byte ones, and a slice this size did not come from `acquire` — not taking it (the caller still owns it)", .{ buf.len, BufSize });
            return;
        }

        if (self.max == 0 or self.free.items.len < self.max) {
            self.free.append(self.allocator, buf) catch {
                self.allocator.free(buf);
                self.allocated -= 1;
                return;
            };
        } else {
            self.allocator.free(buf);
            self.allocated -= 1;
        }
    }

    pub fn available(self: *Self) usize {
        // Uncancelable: this is a reading, and answering a canceled lock wait with
        // `0` (the old `catch return 0`) fabricated "the pool holds nothing" — a
        // scrape hook or a health check cannot tell that apart from the truth.
        // The critical section is one length read; waiting for it costs nothing.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.free.items.len;
    }

    pub fn stats(self: *Self) struct { allocated: usize, free: usize } {
        // Uncancelable, for the same reason as `available`: `{ 0, 0 }` is a
        // reading an operator would act on, not a harmless placeholder.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .allocated = self.allocated, .free = self.free.items.len };
    }
};

test "acquire release" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator, std.testing.io, 100);
    defer pool.deinit();

    const buf = try pool.acquire();
    try std.testing.expect(buf.len == 4096);
    try std.testing.expectEqual(@as(usize, 0), pool.available());
    const ptr = buf.ptr;
    pool.release(buf);
    try std.testing.expectEqual(@as(usize, 1), pool.available());

    const buf2 = try pool.acquire();
    try std.testing.expectEqual(ptr, buf2.ptr);
    pool.release(buf2);
}

// Pins the contract at the top of `release`: a buffer this pool did not hand out is
// refused, and — the part that used to be a silent leak — is **not** silently
// swallowed either: the pool's counters are untouched, so `allocated` keeps
// reflecting reality and the caller keeps ownership.
//
// No mutation red: the pre-fix code also left the counters untouched (it just
// `return`ed). What changed is that the misuse is now named in the log instead of
// vanishing. This test is a pin, not a reproduction.
test "release names an undersized buffer instead of silently dropping it" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator, std.testing.io, 4);
    defer pool.deinit();

    // No `defer allocator.free(buf)`: the last statement hands it back to the pool,
    // which owns it from then on and frees it in `deinit` — freeing it here too would
    // be a double free.
    const buf = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().allocated);

    // Half a buffer, and a bigger one — neither came from `acquire()`.
    pool.release(buf[0 .. buf.len / 2]);
    try std.testing.expectEqual(@as(usize, 0), pool.available());
    try std.testing.expectEqual(@as(usize, 1), pool.stats().allocated);

    // An *oversized* buffer keeps the old behaviour on purpose (it falls through to
    // the normal pooling path) — only the undersized case was the leak, and changing
    // the oversized boundary would also change what the >4 KiB frame path may hand
    // back. So this asserts nothing about `bigger`; the point of the test is the
    // undersized half above.

    // The real one still round-trips.
    pool.release(buf);
    try std.testing.expectEqual(@as(usize, 1), pool.available());
    try std.testing.expectEqual(@as(usize, 1), pool.stats().allocated);
}

test "pool respects max" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator, std.testing.io, 2);
    defer pool.deinit();

    const b1 = try pool.acquire();
    const b2 = try pool.acquire();
    try std.testing.expectError(error.PoolExhausted, pool.acquire());
    pool.release(b1);
    pool.release(b2);
}

test "stats track allocation" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator, std.testing.io, 100);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.stats().allocated);

    const buf = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().allocated);

    pool.release(buf);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().free);
}

// `acquire` used to answer a canceled `mutex.lock(io)` with `error.OutOfMemory`.
// `std.Io.Mutex.lock` cannot fail that way — `std.Io.Cancelable` is
// `error{Canceled}` — and `error.OutOfMemory` already means the allocation two
// branches down. The two are not interchangeable for a caller: the WS read loop
// turns any failure here into "drop this connection", so a canceled wait was
// reported as memory pressure.
//
// The task below is parked on the pool mutex (held by the test thread) with a
// cancel request already placed on its thread, so the cancelation point is the
// lock wait itself: the gate between the two is pure spinning, which is not one.
// `release` used to answer a canceled `mutex.lock(io)` with an early `return`:
// the buffer was neither pooled nor freed, so `allocated` stayed up for good and
// a later `acquire` reported `error.PoolExhausted` with nothing actually live —
// which the WS read loop reads as "drop this connection".
//
// The lock wait is the cancelation point here: the release task is parked on the
// pool mutex (held by the test thread) with a cancel request already placed on
// its thread, and the gate between the two is pure spinning, which consumes
// nothing.
test "release keeps the buffer when its lock wait is canceled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var pool = BufferPool.init(allocator, io, 1);
    defer pool.deinit();

    const buf = try pool.acquire();
    const ptr = buf.ptr;

    const Task = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn release(p: *BufferPool, b: []u8) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            p.release(b);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);

    // The test thread holds the pool mutex, so the task cannot get past the lock
    // wait until told to.
    try pool.mutex.lock(io);

    var release_fut = try io.concurrent(Task.release, .{ &pool, buf });
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &release_fut });
    // Give the request time to land on the task's thread while it is still gated.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    // The task is now inside `release`: parked on the mutex (it swaps the state
    // to `contended` on its way to the wait), or already gone.
    while (pool.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    pool.mutex.unlock(io);

    cancel_fut.await(io);
    release_fut.await(io);

    // The buffer is back in the pool's books — handed out again, so not leaked
    // either. Before the fix this `acquire` was `error.PoolExhausted`: nothing
    // was live, but the dropped buffer left `allocated` at its cap for good.
    const again = try pool.acquire();
    try std.testing.expectEqual(ptr, again.ptr);
    pool.release(again);
    try std.testing.expectEqual(@as(usize, 1), pool.available());
    try std.testing.expectEqual(@as(usize, 1), pool.stats().allocated);
}

// The same defect class in the read-only accessors: a canceled lock wait was
// answered with a fabricated `0` / `{ allocated = 0, free = 0 }` — "this pool
// holds nothing and has allocated nothing" — which is what a metrics scrape or a
// health check would believe. The pool is not empty here, so the reading has to
// say so.
test "available and stats report the true state when a lock wait is canceled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var pool = BufferPool.init(allocator, io, 4);
    defer pool.deinit();

    // One buffer pooled and one allocation on the books, so a fabricated reading
    // (0 / {0, 0}) is visibly different from the true one (1 / {1, 1}).
    const buf = try pool.acquire();
    pool.release(buf);

    const Task = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);
        var seen_available: usize = 0;
        var seen_allocated: usize = 0;
        var seen_free: usize = 0;

        fn read(p: *BufferPool) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            seen_available = p.available();
            const st = p.stats();
            seen_allocated = st.allocated;
            seen_free = st.free;
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);
    Task.seen_available = 0;
    Task.seen_allocated = 0;
    Task.seen_free = 0;

    try pool.mutex.lock(io);

    var read_fut = try io.concurrent(Task.read, .{&pool});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (pool.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    pool.mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);

    try std.testing.expectEqual(@as(usize, 1), Task.seen_available);
    try std.testing.expectEqual(@as(usize, 1), Task.seen_allocated);
    try std.testing.expectEqual(@as(usize, 1), Task.seen_free);
}

test "acquire reports a canceled lock wait as error.Canceled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var pool = BufferPool.init(allocator, io, 1);
    defer pool.deinit();

    const Task = struct {
        var err: ?anyerror = null;
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn acquire(p: *BufferPool) void {
            entered.store(true, .release);
            // Pure spinning: no cancelation point, so a request placed while the
            // task is gated here is still pending when it reaches the lock wait.
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            const buf = p.acquire() catch |e| {
                err = e;
                return;
            };
            p.release(buf);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Task.err = null;
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);

    // The test thread holds the pool mutex, so the task cannot get past the lock
    // wait until told to.
    try pool.mutex.lock(io);

    var task_fut = try io.concurrent(Task.acquire, .{&pool});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    // Give the request time to land on the task's thread while it is still gated.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    // The task is now inside `acquire`: parked on the mutex (it swaps the state
    // to `contended` on its way to the wait), or already gone.
    while (pool.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    pool.mutex.unlock(io);

    cancel_fut.await(io);
    task_fut.await(io);

    try std.testing.expectEqual(@as(?anyerror, error.Canceled), Task.err);
    // Nothing was handed out: the canceled wait must not have taken a buffer.
    try std.testing.expectEqual(@as(usize, 0), pool.stats().free);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().allocated);
}

// `deinit` used to answer a contended `tryLock` by freeing the free list anyway,
// while the thread that held the lock was still either inside `release` (which now
// waits on that same mutex uncancelably) or about to enter it. The teardown then
// frees the backing array and every buffer out from under a live critical section:
// `free.append` writes into freed storage, and `deinit`'s own loop may free a
// buffer twice (once here, once when the holder's append lands). Memory unsafety,
// not a missed teardown.
//
// A destructor has to run to completion (same rule as `cache/Lru.zig`'s `deinit`),
// and there is no error channel: `catch return` would leave the pool alive with
// nothing to free it later. So it waits — the critical section it is waiting on is
// the one in `release`, one list append long.
test "deinit waits for a held lock instead of freeing underneath its holder" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var pool = BufferPool.init(allocator, io, 4);
    // Two buffers on the books and back in the pool, so a skipped teardown is
    // visible: `std.testing.allocator` fails the test on the leaked allocations.
    const a = try pool.acquire();
    const b = try pool.acquire();
    pool.release(a);
    pool.release(b);

    const Task = struct {
        var held = std.atomic.Value(bool).init(false);
        var go = std.atomic.Value(bool).init(false);
        var deinited = std.atomic.Value(bool).init(false);

        fn hold(p: *BufferPool) void {
            p.mutex.lock(std.testing.io) catch return;
            held.store(true, .release);
            while (!go.load(.acquire)) std.atomic.spinLoopHint();
            p.mutex.unlock(std.testing.io);
        }

        fn teardown(p: *BufferPool) void {
            p.deinit();
            deinited.store(true, .release);
        }
    };
    Task.held.store(false, .monotonic);
    Task.go.store(false, .monotonic);
    Task.deinited.store(false, .monotonic);

    var hold_fut = try io.concurrent(Task.hold, .{&pool});
    while (!Task.held.load(.acquire)) std.atomic.spinLoopHint();

    // The other thread holds the pool lock, so `deinit` cannot run yet — and it
    // must not pretend to have run: before the fix its `tryLock` failed and it
    // freed the list anyway, which `deinited` catches.
    var teardown_fut = try io.concurrent(Task.teardown, .{&pool});
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    const ran_while_locked = Task.deinited.load(.acquire);

    // Let the holder out, then join both before touching the pool again.
    Task.go.store(true, .release);
    hold_fut.await(io);
    teardown_fut.await(io);

    try std.testing.expect(!ran_while_locked);
    try std.testing.expect(Task.deinited.load(.acquire));
}
