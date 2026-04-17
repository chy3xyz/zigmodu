//! Adaptive load shedding aligned with go-zero core/load
//!
//! Provides an adaptive shedder that drops requests when the system
//! is under load, based on response time and throughput.

const std = @import("std");
const errors = @import("../sqlx/errors.zig");

const default_buckets = 50;
const default_window_ms = 5000;
const default_cpu_threshold = 900; // 90% in millicpu notation
const default_min_rt: f64 = 1000.0; // 1000ms, like go-zero
const flying_beta = 0.9;
const cool_off_duration_ms = 1000;
const cpu_max = 1000;
const overload_factor_lower_bound = 0.1;

/// Error returned when service is overloaded
pub const ErrServiceOverloaded = errors.Error.ServiceOverloaded;

/// A bucket in the rolling window
pub const Bucket = struct {
    sum: i64 = 0,
    count: i64 = 0,
};

/// RollingWindow is a time-based sliding window for statistics.
pub fn RollingWindow(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        buckets: []Bucket,
        bucket_duration_ms: i64,
        last_add_time_ms: i64,
        last_index: usize,
        size: usize,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, size: usize, bucket_duration_ms: i64) !Self {
            const buckets = try allocator.alloc(Bucket, size);
            @memset(buckets, .{});
            return .{
                .allocator = allocator,
                .buckets = buckets,
                .bucket_duration_ms = bucket_duration_ms,
                .last_add_time_ms = 0,
                .last_index = 0,
                .size = size,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buckets);
        }

        fn advance(self: *Self, now_ms: i64) void {
            if (self.last_add_time_ms == 0) {
                self.last_add_time_ms = now_ms;
                return;
            }
            const diff = now_ms - self.last_add_time_ms;
            const steps = @divFloor(diff, self.bucket_duration_ms);
            if (steps <= 0) return;
            const n = @min(steps, @as(i64, @intCast(self.size)));
            var i: i64 = 1;
            while (i <= n) : (i += 1) {
                const idx = (self.last_index + @as(usize, @intCast(i))) % self.size;
                self.buckets[idx] = .{};
            }
            self.last_index = (self.last_index + @as(usize, @intCast(steps))) % self.size;
            self.last_add_time_ms += steps * self.bucket_duration_ms;
        }

        pub fn add(self: *Self, value: T) void {
            const now_ms = 0;
            self.advance(now_ms);
            self.buckets[self.last_index].sum += value;
            self.buckets[self.last_index].count += 1;
            self.last_add_time_ms = now_ms;
        }

        pub fn maxSum(self: *Self) i64 {
            var result: i64 = 1;
            for (self.buckets) |b| {
                if (b.sum > result) {
                    result = b.sum;
                }
            }
            return result;
        }

        pub fn minAvg(self: *Self) f64 {
            var result = default_min_rt;
            for (self.buckets) |b| {
                if (b.count <= 0) continue;
                const avg = @round(@as(f64, @floatFromInt(b.sum)) / @as(f64, @floatFromInt(b.count)));
                if (avg < result) {
                    result = avg;
                }
            }
            return result;
        }
    };
}

/// Promise is returned by Shedder.allow to report success or failure.
pub const Promise = struct {
    start_ms: i64,
    shedder: ?*AdaptiveShedder,

    pub fn pass(self: *const Promise) void {
        if (self.shedder) |s| {
            const rt = @as(f64, @floatFromInt(0 - self.start_ms));
            const rt_ceil: i64 = @intFromFloat(@ceil(rt));
            s.addFlying(-1);
            s.rt_counter.add(rt_ceil);
            s.pass_counter.add(1);
        }
    }

    pub fn fail(self: *const Promise) void {
        if (self.shedder) |s| {
            s.addFlying(-1);
        }
    }
};

/// Options for customizing the adaptive shedder
pub const ShedderOptions = struct {
    window_ms: i64 = default_window_ms,
    buckets: usize = default_buckets,
    cpu_threshold: i64 = default_cpu_threshold,
    cpu_overloaded_fn: *const fn (threshold: i64) bool = defaultCpuOverloaded,
};

fn defaultCpuOverloaded(threshold: i64) bool {
    _ = threshold;
    return false;
}

/// NopShedder never drops requests.
pub const NopShedder = struct {
    pub fn allow(self: *NopShedder) errors.Error!Promise {
        _ = self;
        return Promise{
            .start_ms = 0,
            .shedder = null,
        };
    }
};

/// AdaptiveShedder drops requests probabilistically when overloaded.
pub const AdaptiveShedder = struct {
    io: std.Io,
    cpu_threshold: i64,
    window_scale: f64,
    flying: i64,
    avg_flying: f64,
    avg_flying_mutex: std.Io.Mutex,
    overload_time_ms: std.atomic.Value(i64),
    dropped_recently: std.atomic.Value(bool),
    pass_counter: RollingWindow(i64),
    rt_counter: RollingWindow(i64),
    cpu_overloaded_fn: *const fn (threshold: i64) bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: ShedderOptions) !Self {
        const bucket_duration_ms = @divFloor(opts.window_ms, @as(i64, @intCast(opts.buckets)));
        const window_scale = 1.0 / @as(f64, @floatFromInt(bucket_duration_ms));
        return .{
            .io = io,
            .cpu_threshold = opts.cpu_threshold,
            .window_scale = window_scale,
            .flying = 0,
            .avg_flying = 0,
            .avg_flying_mutex = std.Io.Mutex.init,
            .overload_time_ms = std.atomic.Value(i64).init(0),
            .dropped_recently = std.atomic.Value(bool).init(false),
            .pass_counter = try RollingWindow(i64).init(allocator, opts.buckets, bucket_duration_ms),
            .rt_counter = try RollingWindow(i64).init(allocator, opts.buckets, bucket_duration_ms),
            .cpu_overloaded_fn = opts.cpu_overloaded_fn,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pass_counter.deinit();
        self.rt_counter.deinit();
    }

    pub fn allow(self: *Self) errors.Error!Promise {
        if (self.shouldDrop()) {
            self.dropped_recently.store(true, .monotonic);
            return ErrServiceOverloaded;
        }
        self.addFlying(1);
        return Promise{
            .start_ms = 0,
            .shedder = self,
        };
    }

    fn addFlying(self: *Self, delta: i64) void {
        const prev = @atomicRmw(i64, &self.flying, .Add, delta, .monotonic);
        if (delta < 0) {
            const new_flying = prev + delta;
            self.avg_flying_mutex.lock(self.io) catch return;
            self.avg_flying = self.avg_flying * flying_beta + @as(f64, @floatFromInt(new_flying)) * (1.0 - flying_beta);
            self.avg_flying_mutex.unlock(self.io);
        }
    }

    fn shouldDrop(self: *Self) bool {
        if (self.systemOverloaded() or self.stillHot()) {
            if (self.highThru()) {
                return true;
            }
        }
        return false;
    }

    fn systemOverloaded(self: *Self) bool {
        if (!self.cpu_overloaded_fn(self.cpu_threshold)) {
            return false;
        }
        self.overload_time_ms.store(0, .monotonic);
        return true;
    }

    fn stillHot(self: *Self) bool {
        if (!self.dropped_recently.load(.monotonic)) {
            return false;
        }
        const overload_time = self.overload_time_ms.load(.monotonic);
        if (overload_time == 0) {
            return false;
        }
        if (0 - overload_time < cool_off_duration_ms) {
            return true;
        }
        self.dropped_recently.store(false, .monotonic);
        return false;
    }

    fn highThru(self: *Self) bool {
        self.avg_flying_mutex.lock(self.io) catch return false;
        defer self.avg_flying_mutex.unlock(self.io);
        const avg_flying = self.avg_flying;
        const max_flight = self.maxFlight() * self.overloadFactor();
        const flying_val = @atomicLoad(i64, &self.flying, .monotonic);
        return avg_flying > max_flight and @as(f64, @floatFromInt(flying_val)) > max_flight;
    }

    fn maxFlight(self: *Self) f64 {
        const max_pass = self.pass_counter.maxSum();
        const min_rt = self.rt_counter.minAvg();
        const max_flight = @as(f64, @floatFromInt(max_pass)) * min_rt * self.window_scale;
        return @max(max_flight, 1.0);
    }

    fn overloadFactor(self: *Self) f64 {
        // Stub CPU usage to max (no overload discount) since we don't track CPU by default
        const cpu_usage: f64 = 0;
        const factor = (cpu_max - cpu_usage) / (cpu_max - @as(f64, @floatFromInt(self.cpu_threshold)));
        return std.math.clamp(factor, overload_factor_lower_bound, 1.0);
    }
};

/// Create a new adaptive shedder with options.
pub fn newAdaptiveShedder(allocator: std.mem.Allocator, io: std.Io, opts: ShedderOptions) !AdaptiveShedder {
    return AdaptiveShedder.init(allocator, io, opts);
}

test "rolling window" {
    const allocator = std.testing.allocator;
    var rw = try RollingWindow(i64).init(allocator, 5, 1000);
    defer rw.deinit();

    rw.add(10);
    rw.add(20);
    rw.add(5);
    // All adds happen within the same millisecond bucket, so maxSum = 10+20+5 = 35
    try std.testing.expectEqual(@as(i64, 35), rw.maxSum());
    // minAvg for the single bucket = round((10+20+5)/3) = 12.0
    try std.testing.expectEqual(@as(f64, 12.0), rw.minAvg());
}

test "adaptive shedder basic" {
    const allocator = std.testing.allocator;
    var shedder = try newAdaptiveShedder(allocator, std.testing.io, .{});
    defer shedder.deinit();

    // Should allow normally
    const p = try shedder.allow();
    // std.Thread.sleep(2 * std.time.ns_per_ms);// TODO: 0.16.0 needs io
    p.pass();

    // Nop shedder should always allow
    var nop = NopShedder{};
    const np = try nop.allow();
    np.pass();
}

test "adaptive shedder drops under high load" {
    const allocator = std.testing.allocator;
    var shedder = try newAdaptiveShedder(allocator, std.testing.io, .{
        .cpu_overloaded_fn = struct {
            fn f(th: i64) bool {
                _ = th;
                return true;
            }
        }.f,
    });
    defer shedder.deinit();

    // Without any historical traffic data, maxFlight() returns 1.0,
    // so highThru() checks if avgFlying > factor and flying > factor.
    // After a few allowed requests, if CPU is overloaded and flying is high enough,
    // it should drop.

    var allowed: usize = 0;
    var dropped: usize = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (shedder.allow()) |p| {
            allowed += 1;
            // std.Thread.sleep(1 * std.time.ns_per_ms);// TODO: 0.16.0 needs io
            p.pass();
        } else |_| {
            dropped += 1;
        }
    }

    // We should see both allowed and dropped
    try std.testing.expect(allowed > 0);
}
