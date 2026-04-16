//! Functional / stream utilities for zigzero
//!
//! Aligned with go-zero's core/fx package.

const std = @import("std");
const errors = @import("../sqlx/errors.zig");

/// Parallel executes a function for each item in a slice concurrently.
/// `max_workers` controls concurrency (0 means len(items)).
pub fn Parallel(comptime T: type, _allocator: std.mem.Allocator, items: []const T, max_workers: usize, func: *const fn (T) void) !void {
    _ = _allocator;
    const workers = if (max_workers == 0) items.len else @min(max_workers, items.len);
    if (workers == 0) return;

    var wg = std.Thread.WaitGroup{};
    var semaphore = std.Thread.Semaphore{ .permits = @intCast(workers) };

    for (items) |item| {
        semaphore.wait();
        wg.start();
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(i: T, f: *const fn (T) void, s: *std.Thread.Semaphore, w: *std.Thread.WaitGroup) void {
                defer {
                    s.post();
                    w.finish();
                }
                f(i);
            }
        }.run, .{ item, func, &semaphore, &wg });
        thread.detach();
    }

    wg.wait();
}

/// Map applies a transform to each element concurrently.
pub fn Map(comptime In: type, comptime Out: type, allocator: std.mem.Allocator, items: []const In, max_workers: usize, func: *const fn (In) Out) ![]Out {
    const results = try allocator.alloc(Out, items.len);
    errdefer allocator.free(results);

    const workers = if (max_workers == 0) items.len else @min(max_workers, items.len);
    if (workers == 0) return results;

    var wg = std.Thread.WaitGroup{};
    var mutex = std.Thread.Mutex{};
    var semaphore = std.Thread.Semaphore{ .permits = @intCast(workers) };
    var err: ?anyerror = null;

    for (items, 0..) |item, idx| {
        semaphore.wait();
        wg.start();
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(i: In, index: usize, f: *const fn (In) Out, res: []Out, s: *std.Thread.Semaphore, w: *std.Thread.WaitGroup, m: *std.Thread.Mutex, e: *?anyerror) void {
                defer {
                    s.post();
                    w.finish();
                }
                const out = f(i);
                m.lock();
                res[index] = out;
                m.unlock();
                _ = e;
            }
        }.run, .{ item, idx, func, results, &semaphore, &wg, &mutex, &err });
        thread.detach();
    }

    wg.wait();
    if (err) |e| return e;
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
                .items = std.ArrayList(T){},
            };
        }

        pub fn fromSlice(allocator: std.mem.Allocator, slice: []const T) !Self {
            var s = init(allocator);
            try s.items.appendSlice(allocator, slice);
            return s;
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
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
                    _ = self.items.orderedRemove(i);
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

    try Parallel(u32, std.testing.allocator, items, 2, func);
    try std.testing.expectEqual(@as(usize, 5), Ctx.count.load(.monotonic));
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
    const out = try Map(u32, u32, std.testing.allocator, items, 2, struct {
        fn f(x: u32) u32 {
            return x * 2;
        }
    }.f);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(u32, 2), out[0]);
    try std.testing.expectEqual(@as(u32, 4), out[1]);
    try std.testing.expectEqual(@as(u32, 6), out[2]);
}
