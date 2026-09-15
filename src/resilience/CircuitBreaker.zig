//! Circuit breaker — CLOSED/OPEN/HALF_OPEN state machine with per-service breakers.

const std = @import("std");
const SpinLock = @import("../core/SpinLock.zig").SpinLock;
const Time = @import("../core/Time.zig");

/// Circuit breaker — CLOSED/OPEN/HALF_OPEN failure detector for one dependency.
pub const CircuitBreaker = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    name: []const u8,
    state: State,
    failure_count: u32,
    success_count: u32,
    last_failure_time: i64,
    config: Config,

    pub const State = enum {
        CLOSED, // Normal — allow requests through
        OPEN, // Open circuit — reject requests
        HALF_OPEN, // Half-open — allow limited test requests
    };

    pub const Config = struct {
        failure_threshold: u32, // Failure count to open circuit
        success_threshold: u32, // Success count to close circuit
        timeout_seconds: u64, // Time before half-open after open
        half_open_max_calls: u32, // Max calls allowed in half-open state
    };

    pub const Result = union(enum) {
        success: void,
        failure: anyerror,
        circuit_open: void,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, config: Config) !Self {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .state = .CLOSED,
            .failure_count = 0,
            .success_count = 0,
            .last_failure_time = 0,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.* = undefined;
    }

    /// Returns true if the breaker is currently allowing calls through.
    /// Updates state for OPEN/HALF_OPEN transitions before deciding.
    pub fn canAccept(self: *Self) bool {
        @branchHint(.likely);
        if (self.state != .CLOSED) {
            @branchHint(.cold);
            self.updateState();
        }
        return switch (self.state) {
            .OPEN => false,
            .HALF_OPEN => self.success_count < self.config.half_open_max_calls,
            .CLOSED => true,
        };
    }

    /// Execute a protected call through the circuit breaker.
    ///
    /// Thread safety: this method is NOT thread-safe. For concurrent access,
    /// wrap the CircuitBreaker in a Mutex or use one instance per fiber.
    pub fn call(self: *Self, operation: *const fn () anyerror!void) Result {
        if (!self.canAccept()) {
            switch (self.state) {
                .OPEN => std.log.warn("Circuit breaker '{s}' is OPEN, rejecting call", .{self.name}),
                .HALF_OPEN => std.log.warn("Circuit breaker '{s}' HALF_OPEN limit reached", .{self.name}),
                .CLOSED => unreachable,
            }
            return .circuit_open;
        }

        operation() catch |err| {
            self.onFailure();
            return .{ .failure = err };
        };

        self.onSuccess();
        return .success;
    }

    /// Context-aware variant of `call`: the operation receives `ctx` (e.g. a
    /// `*AiProvider`), enabling circuit-breaking of stateful calls that plain
    /// function pointers cannot capture. Same state machine as `call`.
    pub fn callWithContext(self: *Self, ctx: ?*anyopaque, operation: *const fn (?*anyopaque) anyerror!void) Result {
        if (!self.canAccept()) {
            switch (self.state) {
                .OPEN => std.log.warn("Circuit breaker '{s}' is OPEN, rejecting call", .{self.name}),
                .HALF_OPEN => std.log.warn("Circuit breaker '{s}' HALF_OPEN limit reached", .{self.name}),
                .CLOSED => unreachable,
            }
            return .circuit_open;
        }

        operation(ctx) catch |err| {
            self.onFailure();
            return .{ .failure = err };
        };

        self.onSuccess();
        return .success;
    }

    /// Record a successful call. Public so external callers (e.g. `ModuleRuntime`)
    /// can update breaker state without re-running `canAccept()`.
    pub fn onSuccess(self: *Self) void {
        switch (self.state) {
            .CLOSED => {
                // A success clears the accumulated failure count.
                self.failure_count = 0;
            },
            .HALF_OPEN => {
                self.success_count += 1;
                if (self.success_count >= self.config.success_threshold) {
                    // Enough probe successes — close the circuit again.
                    std.log.info("Circuit breaker '{s}' closing after {d} successes", .{ self.name, self.success_count });
                    self.state = .CLOSED;
                    self.failure_count = 0;
                    self.success_count = 0;
                }
            },
            .OPEN => {},
        }
    }

    /// Record a failed call. Public so external callers (e.g. `ModuleRuntime`)
    /// can update breaker state without re-running `canAccept()`.
    pub fn onFailure(self: *Self) void {
        self.failure_count += 1;
        self.last_failure_time = Time.monotonicNowSeconds();

        switch (self.state) {
            .CLOSED => {
                if (self.failure_count >= self.config.failure_threshold) {
                    // Threshold reached — open the circuit.
                    std.log.warn("Circuit breaker '{s}' opening after {d} failures", .{ self.name, self.failure_count });
                    self.state = .OPEN;
                }
            },
            .HALF_OPEN => {
                // A failure while probing sends the breaker straight back to OPEN.
                std.log.warn("Circuit breaker '{s}' re-opening after failure in HALF_OPEN", .{self.name});
                self.state = .OPEN;
                self.success_count = 0;
            },
            .OPEN => {},
        }
    }

    /// Timeout-driven OPEN → HALF_OPEN transition; a no-op in other states.
    fn updateState(self: *Self) void {
        if (self.state == .OPEN) {
            const now = Time.monotonicNowSeconds();
            const elapsed = @as(u64, @intCast(now - self.last_failure_time));

            if (elapsed >= self.config.timeout_seconds) {
                // Timeout elapsed — let probe calls through via HALF_OPEN.
                std.log.info("Circuit breaker '{s}' entering HALF_OPEN after timeout", .{self.name});
                self.state = .HALF_OPEN;
                self.success_count = 0;
            }
        }
    }

    /// Manually reset circuit breaker
    pub fn reset(self: *Self) void {
        std.log.info("Circuit breaker '{s}' manually reset", .{self.name});
        self.state = .CLOSED;
        self.failure_count = 0;
        self.success_count = 0;
        self.last_failure_time = 0;
    }

    /// Force the breaker OPEN without recording a failure (manual/ops use).
    pub fn forceOpen(self: *Self) void {
        std.log.warn("Circuit breaker '{s}' manually forced OPEN", .{self.name});
        self.state = .OPEN;
        self.last_failure_time = 0;
    }

    /// Current state, first applying any pending timeout transition.
    pub fn getState(self: *Self) State {
        self.updateState();
        return self.state;
    }

    /// Snapshot of state and counters for reporting (no transition applied).
    pub fn getStats(self: *Self) Stats {
        return .{
            .state = self.state,
            .failure_count = self.failure_count,
            .success_count = self.success_count,
            .last_failure_time = self.last_failure_time,
        };
    }

    pub const Stats = struct {
        state: State,
        failure_count: u32,
        success_count: u32,
        last_failure_time: i64,
    };
};

/// Registry of named circuit breakers — one per downstream dependency.
/// Per-dependency circuit breakers, keyed by name.
///
/// Breakers are heap-allocated and the map holds pointers, so a pointer from
/// `getOrCreate`/`get` stays valid across later inserts. Storing them by value
/// (the previous shape) moved them on rehash and handed callers dangling
/// pointers — the same use-after-free class the zent connection pool hit.
/// All access is guarded; safe to share across threads.
///
/// Keys are expected to be a fixed set of downstream dependencies, so unlike
/// `RateLimiterRegistry` there is no size cap: if you key breakers by something
/// request-derived, keep that set bounded yourself (`remove` is available).
pub const CircuitBreakerRegistry = struct {
    const Self = @This();

    guard: SpinLock = .{},
    allocator: std.mem.Allocator,
    breakers: std.StringHashMap(*CircuitBreaker),
    default_config: CircuitBreaker.Config,

    pub fn init(allocator: std.mem.Allocator, default_config: CircuitBreaker.Config) Self {
        return .{
            .allocator = allocator,
            .breakers = std.StringHashMap(*CircuitBreaker).init(allocator),
            .default_config = default_config,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.breakers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.breakers.deinit();
        self.* = undefined;
    }

    /// Breaker for `name`, created with `default_config` on first use.
    pub fn getOrCreate(self: *Self, name: []const u8) !*CircuitBreaker {
        self.guard.lock();
        defer self.guard.unlock();

        if (self.breakers.get(name)) |existing| return existing;

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const breaker = try self.allocator.create(CircuitBreaker);
        errdefer self.allocator.destroy(breaker);
        breaker.* = try CircuitBreaker.init(self.allocator, name_copy, self.default_config);
        errdefer breaker.deinit();

        try self.breakers.put(name_copy, breaker);
        return breaker;
    }

    /// Existing breaker, or null. The pointer outlives later inserts.
    pub fn get(self: *Self, name: []const u8) ?*CircuitBreaker {
        self.guard.lock();
        defer self.guard.unlock();
        return self.breakers.get(name);
    }

    /// Drop `name`'s breaker. No-op when absent.
    pub fn remove(self: *Self, name: []const u8) bool {
        self.guard.lock();
        defer self.guard.unlock();

        const entry = self.breakers.fetchRemove(name) orelse return false;
        self.allocator.free(entry.key);
        entry.value.deinit();
        self.allocator.destroy(entry.value);
        return true;
    }

    /// Number of tracked breakers.
    pub fn count(self: *Self) usize {
        self.guard.lock();
        defer self.guard.unlock();
        return self.breakers.count();
    }

    pub fn resetAll(self: *Self) void {
        self.guard.lock();
        defer self.guard.unlock();

        var iter = self.breakers.iterator();
        while (iter.next()) |entry| entry.value_ptr.*.reset();
    }

    /// JSON snapshot of every breaker's state — for an admin/debug endpoint.
    /// Caller frees.
    pub fn generateReport(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        const Entry = struct {
            name: []const u8,
            state: []const u8,
            failure_count: u32,
            success_count: u32,
            failure_threshold: u32,
        };

        self.guard.lock();
        defer self.guard.unlock();

        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(allocator);

        var iter = self.breakers.iterator();
        while (iter.next()) |entry| {
            const breaker = entry.value_ptr.*;
            try entries.append(allocator, .{
                .name = breaker.name,
                .state = @tagName(breaker.state),
                .failure_count = breaker.failure_count,
                .success_count = breaker.success_count,
                .failure_threshold = breaker.config.failure_threshold,
            });
        }
        return std.json.Stringify.valueAlloc(allocator, entries.items, .{});
    }
};

test "CircuitBreakerRegistry keeps pointers valid and reports state" {
    const allocator = std.testing.allocator;
    var registry = CircuitBreakerRegistry.init(allocator, .{
        .failure_threshold = 2,
        .success_threshold = 1,
        .timeout_seconds = 60,
        .half_open_max_calls = 1,
    });
    defer registry.deinit();

    const first = try registry.getOrCreate("payment");
    // Force rehash: a by-value map would have moved `first` by now.
    for (0..128) |i| {
        var buf: [24]u8 = undefined;
        _ = try registry.getOrCreate(try std.fmt.bufPrint(&buf, "dep-{d}", .{i}));
    }
    try std.testing.expect(first == try registry.getOrCreate("payment"));
    try std.testing.expectEqual(@as(usize, 129), registry.count());

    const report = try registry.generateReport(allocator);
    defer allocator.free(report);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, report, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 129), parsed.value.array.items.len);

    // Removal frees the entry and the name can come back.
    try std.testing.expect(registry.remove("payment"));
    try std.testing.expect(!registry.remove("payment"));
    try std.testing.expectEqual(@as(usize, 128), registry.count());
    try std.testing.expect(registry.get("payment") == null);
}

test "CircuitBreaker state transitions" {
    const allocator = std.testing.allocator;
    var cb = try CircuitBreaker.init(allocator, "test", .{
        .failure_threshold = 3,
        .success_threshold = 2,
        .timeout_seconds = 1,
        .half_open_max_calls = 5,
    });
    defer cb.deinit();

    const fail_op = struct {
        fn op() !void {
            return error.TestFail;
        }
    }.op;

    const ok_op = struct {
        fn op() !void {}
    }.op;

    // Initially CLOSED
    try std.testing.expectEqual(CircuitBreaker.State.CLOSED, cb.getState());

    // 3 failures -> OPEN
    _ = cb.call(fail_op);
    _ = cb.call(fail_op);
    _ = cb.call(fail_op);
    try std.testing.expectEqual(CircuitBreaker.State.OPEN, cb.getState());

    // Wait for timeout -> HALF_OPEN (simulate time passing)
    cb.last_failure_time = -10;
    try std.testing.expectEqual(CircuitBreaker.State.HALF_OPEN, cb.getState());
    try std.testing.expectEqual(CircuitBreaker.State.HALF_OPEN, cb.getState());

    // 2 successes -> CLOSED
    _ = cb.call(ok_op);
    _ = cb.call(ok_op);
    try std.testing.expectEqual(CircuitBreaker.State.CLOSED, cb.getState());
}

test "CircuitBreakerRegistry" {
    const allocator = std.testing.allocator;
    var registry = CircuitBreakerRegistry.init(allocator, .{
        .failure_threshold = 1,
        .success_threshold = 1,
        .timeout_seconds = 1,
        .half_open_max_calls = 3,
    });
    defer registry.deinit();

    const cb = try registry.getOrCreate("api");
    try std.testing.expectEqualStrings("api", cb.name);
    try std.testing.expect(registry.get("api") != null);

    try std.testing.expect(registry.remove("api"));
    try std.testing.expect(registry.get("api") == null);
}

test "CircuitBreaker OPEN to HALF_OPEN via timeout" {
    const allocator = std.testing.allocator;

    var cb = try CircuitBreaker.init(allocator, "test-hc", .{
        .failure_threshold = 1,
        .success_threshold = 2,
        .timeout_seconds = 0,
        .half_open_max_calls = 10,
    });
    defer cb.deinit();

    // Force OPEN with 0 timestamp
    cb.forceOpen();
    try std.testing.expectEqual(CircuitBreaker.State.OPEN, cb.state);

    // getState() calls updateState(), which triggers OPEN->HALF_OPEN with timeout=0
    const state = cb.getState();
    try std.testing.expectEqual(CircuitBreaker.State.HALF_OPEN, state);

    // Reset to CLOSED
    cb.reset();
    try std.testing.expectEqual(CircuitBreaker.State.CLOSED, cb.state);
}

test "CircuitBreaker callWithContext passes context and tracks failures" {
    const allocator = std.testing.allocator;
    var cb = try CircuitBreaker.init(allocator, "ctx-test", .{
        .failure_threshold = 1,
        .success_threshold = 1,
        .timeout_seconds = 60,
        .half_open_max_calls = 5,
    });
    defer cb.deinit();

    const Ctx = struct {
        var calls: usize = 0;
        var provider_id: i64 = 0;
    };

    // Context arrives at the operation (e.g. *AiProvider) — success path.
    const ok_op = struct {
        fn op(c: ?*anyopaque) anyerror!void {
            const p: *i64 = @ptrCast(@alignCast(c.?));
            Ctx.calls += 1;
            Ctx.provider_id = p.*;
        }
    }.op;
    var pid: i64 = 42;
    try std.testing.expectEqual(CircuitBreaker.Result.success, cb.callWithContext(&pid, ok_op));
    try std.testing.expectEqual(@as(i64, 42), Ctx.provider_id);

    // Failure path records and trips the breaker.
    const fail_op = struct {
        fn op(_: ?*anyopaque) anyerror!void {
            return error.UpstreamDown;
        }
    }.op;
    const fr = cb.callWithContext(&pid, fail_op);
    switch (fr) {
        .failure => {},
        else => return error.TestFail,
    }
    // Breaker tripped after the failure.
    try std.testing.expectEqual(CircuitBreaker.Result.circuit_open, cb.callWithContext(&pid, ok_op));
}
