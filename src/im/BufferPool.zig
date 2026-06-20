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
    pub fn acquire(self: *Self) ![]u8 {
        self.mutex.lock(self.io) catch return error.OutOfMemory;
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
    pub fn release(self: *Self, buf: []u8) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        if (buf.len < BufSize) return;

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
