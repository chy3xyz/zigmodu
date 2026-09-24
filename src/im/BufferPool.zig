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
        if (!self.mutex.tryLock()) {
            for (self.free.items) |buf| {
                self.allocator.free(buf);
            }
            self.free.deinit(self.allocator);
            return;
        }
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

        return error.PoolExhausted;
    }

    /// Return a buffer to the pool for reuse.
    ///
    /// **Contract: `buf` must be one `acquire()` handed out** (i.e. `BufSize` bytes).
    /// A differently-sized slice is refused with a warning and left to the caller —
    /// this pool cannot free it (its allocator free needs the allocation's own
    /// length) and must not pool it.
    pub fn release(self: *Self, buf: []u8) void {
        self.mutex.lock(self.io) catch return;
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
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.free.items.len;
    }

    pub fn stats(self: *Self) struct { allocated: usize, free: usize } {
        self.mutex.lock(self.io) catch return .{ .allocated = 0, .free = 0 };
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
