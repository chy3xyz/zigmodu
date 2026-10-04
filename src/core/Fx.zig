//! Functional / stream utilities for zigzero
//!
//! Aligned with go-zero's core/fx package.

const std = @import("std");

/// Parallel executes `func` for each item, spread across up to `max_workers`
/// concurrent tasks on `io` (0 means one task per item). Items are split into
/// contiguous chunks; every item is visited exactly once before this returns.
///
/// The worker bound is honored by chunking rather than by the executor's own
/// concurrency limit, so it holds on any `Io`. A chunk that cannot be spawned
/// (`error.ConcurrencyUnavailable`) cancels the chunks already running and
/// fails the call — a partial run is never reported as success.
pub fn Parallel(
    io: std.Io,
    comptime T: type,
    items: []const T,
    max_workers: usize,
    func: *const fn (T) void,
) (std.Io.ConcurrentError || std.Io.Cancelable)!void {
    if (items.len == 0) return;
    const workers = if (max_workers == 0) items.len else @min(max_workers, items.len);

    const Run = struct {
        fn go(slice: []const T, f: *const fn (T) void) void {
            for (slice) |item| f(item);
        }
    };

    var group: std.Io.Group = .init;
    var start: usize = 0;
    for (0..workers) |w| {
        const n = items.len / workers + @intFromBool(w < items.len % workers);
        const slice = items[start..][0..n];
        start += n;
        group.concurrent(io, Run.go, .{ slice, func }) catch |err| {
            group.cancel(io);
            return err;
        };
    }
    try group.await(io);
}

/// Map applies `func` to each element, writing results in input order, spread
/// across up to `max_workers` concurrent tasks on `io` (0 means one per item).
/// The returned slice is owned by the caller. Same failure contract as
/// `Parallel`: a chunk that cannot be spawned cancels the rest and the buffer
/// is freed, never returned half-written.
pub fn Map(
    io: std.Io,
    comptime In: type,
    comptime Out: type,
    allocator: std.mem.Allocator,
    items: []const In,
    max_workers: usize,
    func: *const fn (In) Out,
) (std.Io.ConcurrentError || std.Io.Cancelable || std.mem.Allocator.Error)![]Out {
    const results = try allocator.alloc(Out, items.len);
    errdefer allocator.free(results);
    if (items.len == 0) return results;
    const workers = if (max_workers == 0) items.len else @min(max_workers, items.len);

    const Run = struct {
        fn go(src: []const In, dst: []Out, f: *const fn (In) Out) void {
            for (src, 0..) |item, i| dst[i] = f(item);
        }
    };

    var group: std.Io.Group = .init;
    var start: usize = 0;
    for (0..workers) |w| {
        const n = items.len / workers + @intFromBool(w < items.len % workers);
        group.concurrent(io, Run.go, .{ items[start..][0..n], results[start..][0..n], func }) catch |err| {
            group.cancel(io);
            return err;
        };
        start += n;
    }
    try group.await(io);
    return results;
}

/// Stream type for chainable data processing
pub fn Stream(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(T),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .items = std.ArrayList(T).empty,
            };
        }

        pub fn fromSlice(allocator: std.mem.Allocator, slice: []const T) !Self {
            var s = init(allocator);
            try s.items.appendSlice(allocator, slice);
            return s;
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn add(self: *Self, item: T) !void {
            try self.items.append(self.allocator, item);
        }

        pub fn map(self: *Self, allocator: std.mem.Allocator, comptime Out: type, func: *const fn (T) Out) ![]Out {
            const out = try allocator.alloc(Out, self.items.items.len);
            for (self.items.items, 0..) |item, i| {
                out[i] = func(item);
            }
            return out;
        }

        pub fn filter(self: *Self, func: *const fn (T) bool) void {
            var i: usize = 0;
            while (i < self.items.items.len) {
                if (!func(self.items.items[i])) {
                    _ = self.items.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        pub fn reduce(self: *Self, initial: T, func: *const fn (T, T) T) T {
            var result = initial;
            for (self.items.items) |item| {
                result = func(result, item);
            }
            return result;
        }

        pub fn toSlice(self: *Self) []T {
            return self.items.items;
        }
    };
}

const Time = @import("Time.zig");

test "fx parallel" {
    const Ctx = struct {
        var count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    };
    Ctx.count.store(0, .monotonic);
    const items = &[_]u32{ 1, 2, 3, 4, 5 };

    const func = struct {
        fn f(i: u32) void {
            _ = i;
            _ = @atomicRmw(usize, &Ctx.count.raw, .Add, 1, .monotonic);
        }
    }.f;

    try Parallel(std.testing.io, u32, items, 2, func);
    try std.testing.expectEqual(@as(usize, 5), Ctx.count.load(.monotonic));
}

test "fx parallel chunking visits every item exactly once" {
    // 7 items over 3 workers → chunks of 3, 2, 2; a missed or doubly-visited
    // item is a chunk-bounds bug, not a scheduling artifact.
    const Ctx = struct {
        var seen: [7]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(0));
        fn mark(i: u32) void {
            _ = seen[i].fetchAdd(1, .acq_rel);
        }
    };
    for (&Ctx.seen) |*s| s.store(0, .monotonic);
    const items = &[_]u32{ 0, 1, 2, 3, 4, 5, 6 };
    try Parallel(std.testing.io, u32, items, 3, Ctx.mark);
    for (&Ctx.seen) |*s| try std.testing.expectEqual(@as(u32, 1), s.load(.monotonic));
}

test "fx parallel with max_workers = 0 means one task per item" {
    const Ctx = struct {
        var count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
        fn bump(i: u32) void {
            _ = i;
            _ = count.fetchAdd(1, .monotonic);
        }
    };
    Ctx.count.store(0, .monotonic);
    const items = &[_]u32{ 1, 2, 3 };
    try Parallel(std.testing.io, u32, items, 0, Ctx.bump);
    try std.testing.expectEqual(@as(usize, 3), Ctx.count.load(.monotonic));
}

test "fx parallel on an empty slice is a no-op" {
    const Ctx = struct {
        var called: bool = false;
        fn f(i: u32) void {
            _ = i;
            called = true;
        }
    };
    Ctx.called = false;
    try Parallel(std.testing.io, u32, &.{}, 4, Ctx.f);
    try std.testing.expect(!Ctx.called);
}

test "fx parallel really runs chunks concurrently" {
    // Both chunks block until both have entered; on a serialized executor this
    // fails after the deadline instead of passing silently.
    const Gate = struct {
        var entered: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
        var timed_out: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        fn wait(i: u32) void {
            _ = i;
            _ = entered.fetchAdd(1, .acq_rel);
            const deadline = Time.monotonicNowMilliseconds() + 5_000;
            while (entered.load(.acquire) < 2) {
                if (Time.monotonicNowMilliseconds() > deadline) {
                    timed_out.store(true, .release);
                    return;
                }
                std.atomic.spinLoopHint();
            }
        }
    };
    Gate.entered.store(0, .monotonic);
    Gate.timed_out.store(false, .monotonic);
    const items = &[_]u32{ 1, 2 };
    try Parallel(std.testing.io, u32, items, 2, Gate.wait);
    try std.testing.expect(!Gate.timed_out.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), Gate.entered.load(.monotonic));
}

test "fx stream" {
    var s = Stream(u32).init(std.testing.allocator);
    defer s.deinit();

    try s.add(1);
    try s.add(2);
    try s.add(3);

    s.filter(struct {
        fn f(x: u32) bool {
            return x > 1;
        }
    }.f);

    try std.testing.expectEqual(@as(usize, 2), s.items.items.len);

    const sum = s.reduce(0, struct {
        fn f(a: u32, b: u32) u32 {
            return a + b;
        }
    }.f);

    try std.testing.expectEqual(@as(u32, 5), sum);
}

test "fx map" {
    const items = &[_]u32{ 1, 2, 3 };
    const out = try Map(std.testing.io, u32, u32, std.testing.allocator, items, 2, struct {
        fn f(x: u32) u32 {
            return x * 2;
        }
    }.f);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(u32, 2), out[0]);
    try std.testing.expectEqual(@as(u32, 4), out[1]);
    try std.testing.expectEqual(@as(u32, 6), out[2]);
}

test "fx map preserves input order across chunk boundaries" {
    const items = &[_]u32{ 0, 1, 2, 3, 4, 5, 6 };
    const out = try Map(std.testing.io, u32, u32, std.testing.allocator, items, 3, struct {
        fn f(x: u32) u32 {
            return x * 10;
        }
    }.f);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(items.len, out.len);
    for (items, 0..) |item, i| try std.testing.expectEqual(item * 10, out[i]);
}

test "fx map on an empty slice returns an empty owned slice" {
    const out = try Map(std.testing.io, u32, u32, std.testing.allocator, &.{}, 0, struct {
        fn f(x: u32) u32 {
            return x;
        }
    }.f);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
