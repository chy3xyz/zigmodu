const std = @import("std");
const PrometheusMetrics = @import("PrometheusMetrics.zig").PrometheusMetrics;
const DistributedTracer = @import("../tracing/DistributedTracer.zig").DistributedTracer;
const Time = @import("../core/Time.zig");

/// Seconds elapsed since `start_ns`, read from the same clock the caller used
/// (`Time.monotonicNow()`; `std.time.*` is gone in this Zig version).
///
/// `*_duration_seconds` histograms are fed from here, and their sum may not
/// carry a fabricated number. Both ends come from the monotonic clock — ns-
/// resolution OS clock, or Time.zig's strictly-increasing fallback counter — so
/// the difference is what was really spent. The clamp only covers the
/// otherwise-unreachable case of the clock resetting under a live start
/// timestamp: a reset then reads as 0 elapsed instead of a negative duration.
fn elapsedSecondsSince(start_ns: i64) f64 {
    const elapsed_ns = @max(Time.monotonicNow() - start_ns, 0);
    return @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
}

/// Auto-instrumentation collector
/// Auto-create metrics and traces for module lifecycle, events, API calls
/// High-priority architecture improvement item
pub const AutoInstrumentation = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    metrics: *PrometheusMetrics,
    tracer: *DistributedTracer,

    // Module lifecycle metrics
    module_init_duration: *PrometheusMetrics.Histogram,
    module_init_total: *PrometheusMetrics.Counter,
    module_active_gauge: *PrometheusMetrics.Gauge,

    // Event processing metrics
    event_published_total: *PrometheusMetrics.Counter,
    event_consumed_total: *PrometheusMetrics.Counter,
    event_processing_duration: *PrometheusMetrics.Histogram,

    // API call metrics
    api_request_total: *PrometheusMetrics.Counter,
    api_request_duration: *PrometheusMetrics.Histogram,
    api_error_total: *PrometheusMetrics.Counter,

    pub fn init(allocator: std.mem.Allocator, metrics: *PrometheusMetrics, tracer: *DistributedTracer) !Self {
        // Create module lifecycle metrics
        const module_init_duration = try metrics.createHistogram("zigmodu_module_init_duration_seconds", "Module initialization duration", &.{ 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 });

        const module_init_total = try metrics.createCounter("zigmodu_module_init_total", "Module initialization count (success + failure)");

        const module_active_gauge = try metrics.createGauge("zigmodu_module_active", "Current active module count");

        // Create event processing metrics
        const event_published_total = try metrics.createCounter("zigmodu_event_published_total", "Total published events");

        const event_consumed_total = try metrics.createCounter("zigmodu_event_consumed_total", "Total consumed events");

        const event_processing_duration = try metrics.createHistogram("zigmodu_event_processing_duration_seconds", "Event processing duration", &.{ 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5 });

        // Create API call metrics
        const api_request_total = try metrics.createCounter("zigmodu_api_request_total", "Total API requests");

        const api_request_duration = try metrics.createHistogram("zigmodu_api_request_duration_seconds", "API request duration", &.{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 });

        const api_error_total = try metrics.createCounter("zigmodu_api_error_total", "Total API errors");

        return .{
            .allocator = allocator,
            .metrics = metrics,
            .tracer = tracer,
            .module_init_duration = module_init_duration,
            .module_init_total = module_init_total,
            .module_active_gauge = module_active_gauge,
            .event_published_total = event_published_total,
            .event_consumed_total = event_consumed_total,
            .event_processing_duration = event_processing_duration,
            .api_request_total = api_request_total,
            .api_request_duration = api_request_duration,
            .api_error_total = api_error_total,
        };
    }

    /// Record module initialization
    ///
    /// `duration_seconds` is null when the caller has no start timestamp to
    /// measure from: the init is still counted and the active gauge still moves,
    /// but no duration sample is recorded — a fabricated 0 s sample would land
    /// in the histogram sum as if the init had been free.
    pub fn recordModuleInit(self: *Self, module_name: []const u8, duration_seconds: ?f64, success: bool) void {
        if (duration_seconds) |d| self.module_init_duration.observe(d);
        self.module_init_total.inc();

        if (success) {
            self.module_active_gauge.inc();
        }

        if (duration_seconds) |d| {
            std.log.info("[AutoInstrumentation] Module {s} init done, duration: {d:.3}s, status: {s}", .{
                module_name,
                d,
                if (success) "success" else "failure",
            });
        } else {
            std.log.warn("[AutoInstrumentation] Module {s} init done, duration unmeasured (no start timestamp), status: {s}", .{
                module_name,
                if (success) "success" else "failure",
            });
        }
    }

    /// Record module shutdown
    pub fn recordModuleShutdown(self: *Self, module_name: []const u8) void {
        self.module_active_gauge.dec();

        std.log.info("[AutoInstrumentation] Module {s} shutdown", .{module_name});
    }

    /// Record event published (with trace)
    ///
    /// Span ownership: `startTrace` copies the name into the span and hands the
    /// caller the `*Span`; the name slice passed in stays the caller's, so it is
    /// freed here. The returned span stays in the tracer's active list until it
    /// is ended — a span still listed at `tracer.deinit()` is freed there.
    pub fn recordEventPublished(self: *Self, event_name: []const u8, module_name: []const u8) !?*DistributedTracer.Span {
        self.event_published_total.inc();

        // Create trace span
        const span_name = try std.fmt.allocPrint(self.allocator, "event_publish:{s}", .{event_name});
        defer self.allocator.free(span_name);
        const span = try self.tracer.startTrace(span_name);
        errdefer {
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }

        try span.setAttribute(self.allocator, "event.name", event_name);
        try span.setAttribute(self.allocator, "module.name", module_name);
        try span.setAttribute(self.allocator, "event.type", "published");

        std.log.info("[AutoInstrumentation] Event {s} published from module {s}", .{ event_name, module_name });

        return span;
    }

    /// Record event consumed (with trace)
    ///
    /// Ownership is the same as `recordEventPublished`: the span name is copied
    /// by `startTrace`/`startSpan` and freed here, the returned span is the
    /// caller's only after `endSpan` un-lists it.
    pub fn recordEventConsumed(self: *Self, event_name: []const u8, module_name: []const u8, parent_span: ?*DistributedTracer.Span) !?*DistributedTracer.Span {
        self.event_consumed_total.inc();

        // Create trace span
        const span_name = try std.fmt.allocPrint(self.allocator, "event_consume:{s}", .{event_name});
        defer self.allocator.free(span_name);
        const span = if (parent_span) |parent|
            try self.tracer.startSpan(parent, span_name)
        else
            try self.tracer.startTrace(span_name);

        errdefer {
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }

        try span.setAttribute(self.allocator, "event.name", event_name);
        try span.setAttribute(self.allocator, "module.name", module_name);
        try span.setAttribute(self.allocator, "event.type", "consumed");

        std.log.info("[AutoInstrumentation] Event {s} consumed by module {s}", .{ event_name, module_name });

        return span;
    }

    /// Record event processing complete.
    ///
    /// Ends the span — which only un-lists it from the tracer — so the caller
    /// keeps the storage and must release it (`span.deinit(self.allocator)` +
    /// `self.allocator.destroy(span)`) once nothing else needs the readings.
    /// A span that is never ended stays the tracer's and is freed by
    /// `tracer.deinit()`.
    pub fn recordEventProcessed(self: *Self, span: *DistributedTracer.Span, duration_seconds: f64, success: bool) void {
        self.event_processing_duration.observe(duration_seconds);

        if (!success) {
            span.status = .ERROR;
        } else {
            span.status = .OK;
        }

        self.tracer.endSpan(span);

        std.log.info("[AutoInstrumentation] Event processing done, duration: {d:.3}s, status: {s}", .{
            duration_seconds,
            if (success) "success" else "failure",
        });
    }

    /// Record API call start (with trace).
    ///
    /// Same name/span ownership as `recordEventPublished`.
    pub fn recordApiRequestStart(self: *Self, api_name: []const u8, module_name: []const u8) !*DistributedTracer.Span {
        self.api_request_total.inc();

        const span_name = try std.fmt.allocPrint(self.allocator, "api:{s}", .{api_name});
        defer self.allocator.free(span_name);
        const span = try self.tracer.startTrace(span_name);
        errdefer {
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }

        try span.setAttribute(self.allocator, "api.name", api_name);
        try span.setAttribute(self.allocator, "module.name", module_name);

        return span;
    }

    /// Record API call complete.
    ///
    /// Ends the span; the caller keeps ownership of the storage afterwards (see
    /// `recordEventProcessed`).
    pub fn recordApiRequestEnd(self: *Self, span: *DistributedTracer.Span, duration_seconds: f64, success: bool) void {
        self.api_request_duration.observe(duration_seconds);

        if (!success) {
            self.api_error_total.inc();
            span.status = .ERROR;
        } else {
            span.status = .OK;
        }

        span.addEvent(self.allocator, "api_request_complete") catch |err| std.log.debug("[metrics] span event dropped ({s})", .{@errorName(err)});
        self.tracer.endSpan(span);

        std.log.info("[AutoInstrumentation] API call done, duration: {d:.3}s, status: {s}", .{
            duration_seconds,
            if (success) "success" else "failure",
        });
    }

    /// Wrap function execution, auto-record the trace span and log the duration.
    ///
    /// The elapsed time is log-only: no histogram of its own is observed here
    /// (`module_init_duration` / `event_processing_duration` /
    /// `api_request_duration` are recorded by their respective callers).
    ///
    /// `name` is only read (`startTrace` copies it), so the caller keeps it; the
    /// span itself is ended, deinit'ed and destroyed here, since this function
    /// is the one that allocated it. It is the reference for the ownership rule
    /// the other span helpers document.
    pub fn instrumentFunction(
        self: *Self,
        name: []const u8,
        comptime ResultType: type,
        func: fn () anyerror!ResultType,
    ) !ResultType {
        const start_ns = Time.monotonicNow();

        // Create trace span
        const span = try self.tracer.startTrace(name);
        defer {
            self.tracer.endSpan(span);
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }

        // Execute function
        const result = func() catch |err| {
            const duration = elapsedSecondsSince(start_ns);

            span.status = .ERROR;
            try span.setAttribute(self.allocator, "error.type", @errorName(err));

            std.log.err("[AutoInstrumentation] Function {s} failed: {s}, duration: {d:.3}s", .{
                name,
                @errorName(err),
                duration,
            });

            return err;
        };

        const duration = elapsedSecondsSince(start_ns);
        span.status = .OK;

        std.log.info("[AutoInstrumentation] Function {s} succeeded, duration: {d:.3}s", .{
            name,
            duration,
        });

        return result;
    }

    /// Get Prometheus-format metrics
    pub fn getMetrics(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        return try self.metrics.toPrometheusFormat(allocator);
    }
};

/// Module lifecycle listener (for auto-instrumentation)
pub const InstrumentedLifecycleListener = struct {
    const Self = @This();

    instrumentation: *AutoInstrumentation,
    module_init_times: std.StringHashMap(i64),

    pub fn init(allocator: std.mem.Allocator, instrumentation: *AutoInstrumentation) Self {
        return .{
            .instrumentation = instrumentation,
            .module_init_times = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.module_init_times.deinit();
        self.* = undefined;
    }

    /// Called before module init
    pub fn onModuleInitStart(self: *Self, module_name: []const u8) !void {
        // Nanoseconds from the same clock `onModuleInitEnd` reads.
        try self.module_init_times.put(module_name, Time.monotonicNow());

        std.log.info("[LifecycleListener] Module {s} initializing", .{module_name});
    }

    /// Called after module init
    pub fn onModuleInitEnd(self: *Self, module_name: []const u8, success: bool) void {
        const start_ns = self.module_init_times.get(module_name);
        if (start_ns) |s| {
            self.instrumentation.recordModuleInit(module_name, elapsedSecondsSince(s), success);
        } else {
            // End without a start (or an unknown module name): say so and record
            // the init unmeasured, rather than timing it from a made-up origin.
            std.log.warn("[LifecycleListener] Module {s} init end without a recorded start; no duration sample", .{module_name});
            self.instrumentation.recordModuleInit(module_name, null, success);
        }

        _ = self.module_init_times.remove(module_name);
    }

    /// Called before module shutdown
    pub fn onModuleShutdown(self: *Self, module_name: []const u8) void {
        self.instrumentation.recordModuleShutdown(module_name);
    }
};

/// Event listener (for auto-instrumentation)
pub const InstrumentedEventListener = struct {
    const Self = @This();

    instrumentation: *AutoInstrumentation,
    /// Two entry families share this map, told apart by their key prefix (this
    /// file is the only writer of both):
    ///
    /// - `publish:` — one entry per distinct `event:module` pair, holding a span
    ///   `onEventPublished` has already ended. It is the consume half's parent
    ///   reference; its storage is this listener's, replaced (and freed) by the
    ///   next publish of the same pair, and freed by `deinit`.
    /// - `consume:` — one entry per in-flight consume, holding a span the
    ///   *tracer* still lists. `onEventConsumeEnd` ends it and frees it, or
    ///   `tracer.deinit()` frees one that is never ended.
    ///
    /// That makes the map bounded by `distinct publish pairs + consumes in
    /// flight`; the pairs are fixed by the app's source (its event types × the
    /// modules publishing them), not by traffic. The tests below assert it.
    event_processing_spans: std.StringHashMap(*DistributedTracer.Span),
    event_start_times: std.StringHashMap(i64),

    const publish_key_prefix = "publish:";
    const consume_key_prefix = "consume:";

    pub fn init(allocator: std.mem.Allocator, instrumentation: *AutoInstrumentation) Self {
        return .{
            .instrumentation = instrumentation,
            .event_processing_spans = std.StringHashMap(*DistributedTracer.Span).init(allocator),
            .event_start_times = std.StringHashMap(i64).init(allocator),
        };
    }

    /// Frees one key per entry, plus the span of every `publish:` entry — those
    /// are ended by `onEventPublished`, so this listener owns them. `consume:`
    /// spans are left alone: an in-flight consume is still in the tracer's
    /// active list, which is what frees it at `tracer.deinit()`.
    pub fn deinit(self: *Self) void {
        const allocator = self.event_processing_spans.allocator;
        var span_iter = self.event_processing_spans.iterator();
        while (span_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.startsWith(u8, key, publish_key_prefix)) {
                entry.value_ptr.*.deinit(allocator);
                allocator.destroy(entry.value_ptr.*);
            }
            allocator.free(key);
        }
        self.event_processing_spans.deinit();

        var time_iter = self.event_start_times.iterator();
        while (time_iter.next()) |entry| {
            self.event_start_times.allocator.free(entry.key_ptr.*);
        }
        self.event_start_times.deinit();
        self.* = undefined;
    }

    /// Called on event publish
    ///
    /// The span is ended here: the publish is what it measures, and the publish
    /// is over when this returns. `endSpan` only un-lists it, and an ended span
    /// is still a usable parent for the consume half (`startSpan` copies
    /// `trace_id` / `span_id` out of it). Leaving it un-ended put one span in
    /// the tracer's active list per *published event*, forever — the map entry
    /// was overwritten by the next publish of the pair, the span it replaced
    /// stayed listed.
    pub fn onEventPublished(self: *Self, event_name: []const u8, module_name: []const u8) !void {
        const span = try self.instrumentation.recordEventPublished(event_name, module_name);
        if (span) |s| {
            const allocator = self.event_processing_spans.allocator;
            const key = try std.fmt.allocPrint(allocator, publish_key_prefix ++ "{s}:{s}", .{ event_name, module_name });
            errdefer allocator.free(key);

            self.instrumentation.tracer.endSpan(s);
            // Past `endSpan` the storage is this listener's, so the last
            // fallible step has to release it if it fails — otherwise nobody
            // would (`deinit` only frees the spans it can still find).
            errdefer {
                s.deinit(allocator);
                allocator.destroy(s);
            }

            // `getPtr` first, because the two cases need opposite key handling:
            // the map keeps the key a slot already has and stores the one it is
            // given for a fresh slot, so on the replace path the *fresh* key is
            // the orphan (`fetchPut` hands back the stored key instead — freeing
            // that one frees what the map still points at).
            if (self.event_processing_spans.getPtr(key)) |slot| {
                // Nth publish of this pair: the parent being replaced is ended
                // and this listener's, so its storage goes as the new one takes
                // the slot.
                const old = slot.*;
                allocator.free(key);
                slot.* = s;
                old.deinit(allocator);
                allocator.destroy(old);
            } else {
                try self.event_processing_spans.put(key, s);
            }
        }
    }

    /// Called on event consumption start
    ///
    /// Both maps are keyed by the *same* string, but each holds its own copy:
    /// `deinit` and `onEventConsumeEnd` free one key per entry, so a shared
    /// pointer would be freed twice.
    pub fn onEventConsumeStart(self: *Self, event_name: []const u8, module_name: []const u8) !void {
        const allocator = self.event_processing_spans.allocator;

        // Look up publish-time span as parent. That key is the publish-format
        // one; the consume entry below gets its own prefix, so `deinit` can tell
        // the two families apart by key alone.
        const pub_key = try std.fmt.allocPrint(allocator, publish_key_prefix ++ "{s}:{s}", .{ event_name, module_name });
        defer allocator.free(pub_key);
        const parent_span = self.event_processing_spans.get(pub_key);

        const span = try self.instrumentation.recordEventConsumed(event_name, module_name, parent_span);

        if (span) |s| {
            const key = try std.fmt.allocPrint(allocator, consume_key_prefix ++ "{s}:{s}", .{ event_name, module_name });
            errdefer allocator.free(key);
            const start_key = try allocator.dupe(u8, key);
            errdefer allocator.free(start_key);

            try self.event_processing_spans.put(key, s);
            // Nanoseconds from the same clock `onEventConsumeEnd` reads.
            try self.event_start_times.put(start_key, Time.monotonicNow());
        }
    }

    /// Called on event consumption complete
    ///
    /// Best-effort by design, and reported rather than swallowed: this is the
    /// metrics/tracing side of an event whose handling already happened in the
    /// caller, so it can never be worth failing the work it describes. Giving up
    /// here costs one duration sample and leaves the entry's key to `deinit`
    /// — the span is still un-ended, so the tracer keeps it and frees it at
    /// `tracer.deinit()`. Same trade `recordApiRequestEnd` makes for a dropped
    /// span event, which is why it logs at the same level.
    ///
    /// On the happy path the span is also released here: `recordEventProcessed`
    /// ends it, which un-lists it from the tracer, so from that point the
    /// listener is the only owner.
    pub fn onEventConsumeEnd(self: *Self, event_name: []const u8, module_name: []const u8, success: bool) void {
        const allocator = self.event_start_times.allocator;

        const key = std.fmt.allocPrint(allocator, consume_key_prefix ++ "{s}:{s}", .{ event_name, module_name }) catch |err| {
            std.log.debug("[metrics] event consume end dropped ({s}); the span stays un-ended", .{@errorName(err)});
            return;
        };
        defer allocator.free(key);

        const span_entry = self.event_processing_spans.fetchRemove(key) orelse {
            // `onEventConsumeStart` writes both maps under this key, so this is
            // unreachable through the public API; treat it like the allocation
            // failure above (say so, record nothing) instead of measuring from a
            // zero origin.
            std.log.debug("[metrics] event consume end dropped (no span for {s}); nothing recorded", .{key});
            return;
        };

        const start_entry = self.event_start_times.fetchRemove(key) orelse {
            // Same unreachable case, other half: hand the span back to the
            // tracer (it was never ended, so `tracer.deinit` still owns it)
            // rather than ending and freeing it without a start timestamp.
            allocator.free(span_entry.key);
            std.log.debug("[metrics] event consume end dropped (no start timestamp for {s}); the span stays un-ended", .{key});
            return;
        };

        allocator.free(span_entry.key);
        allocator.free(start_entry.key);

        self.instrumentation.recordEventProcessed(span_entry.value, elapsedSecondsSince(start_entry.value), success);

        span_entry.value.deinit(allocator);
        allocator.destroy(span_entry.value);
    }
};

// Tests
test "AutoInstrumentation basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
    defer tracer.deinit();

    var instrumentation = try AutoInstrumentation.init(allocator, &metrics, &tracer);

    // Test module init recording
    instrumentation.recordModuleInit("test_module", 0.5, true);

    try testing.expectEqual(@as(u64, 1), instrumentation.module_init_total.get());
    try testing.expectEqual(@as(f64, 1.0), instrumentation.module_active_gauge.get());
}

test "InstrumentedLifecycleListener" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
    defer tracer.deinit();

    var instrumentation = try AutoInstrumentation.init(allocator, &metrics, &tracer);

    var listener = InstrumentedLifecycleListener.init(allocator, &instrumentation);
    defer listener.deinit();

    try listener.onModuleInitStart("test_module");
    listener.onModuleInitEnd("test_module", true);

    try testing.expectEqual(@as(u64, 1), instrumentation.module_init_total.get());
}

/// Time deliberately spent between a start and an end call, so that the
/// monotonic clock has something to measure. `Time.monotonicNow()` advances by
/// whole nanoseconds (ns-resolution OS clock, or Time.zig's strictly-increasing
/// fallback counter), so any wait above a couple of milliseconds is measurable
/// on every platform this suite runs on.
const measured_wait_ns: i64 = 2 * std.time.ns_per_ms;

/// Seconds that `measured_wait_ns` guarantees at the very least. The duration
/// assertions below use this as a lower bound: a stubbed clock records exactly
/// `0`, and a subtraction in the wrong order records a negative — both are
/// rejected by it, while `>= 0` would accept either.
const measured_wait_seconds: f64 = @as(f64, @floatFromInt(measured_wait_ns)) / std.time.ns_per_s;

/// Generous upper bound for the same assertion. A correct implementation records
/// ~2 ms; the 60 s ceiling is there to catch a *unit* regression (`_seconds`
/// metric fed nanoseconds or milliseconds reads as ~10^3-10^9 s), not to bound
/// how long a loaded machine may take.
const measured_wait_ceiling_seconds: f64 = 60.0;

/// Busy-wait, since `std.Thread.sleep` is gone in this Zig version.
fn waitForClockAdvance(min_ns: i64) void {
    const start_ns = Time.monotonicNow();
    while (Time.monotonicNow() - start_ns < min_ns) {}
}

test "InstrumentedLifecycleListener records a measured duration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
    defer tracer.deinit();

    var instrumentation = try AutoInstrumentation.init(allocator, &metrics, &tracer);

    var listener = InstrumentedLifecycleListener.init(allocator, &instrumentation);
    defer listener.deinit();

    try listener.onModuleInitStart("timed_module");
    waitForClockAdvance(measured_wait_ns);
    listener.onModuleInitEnd("timed_module", true);

    // Shape: exactly one sample was recorded …
    try testing.expectEqual(@as(u64, 1), instrumentation.module_init_duration.totalCount());

    // … and it carries the time that was really spent, in seconds.
    const recorded = instrumentation.module_init_duration.sum();
    try testing.expect(recorded >= measured_wait_seconds);
    try testing.expect(recorded < measured_wait_ceiling_seconds);
}

test "InstrumentedEventListener records a measured duration" {
    const testing = std.testing;

    // No arena: this listener's spans and map keys are checked by
    // `testing.allocator` here, so a leak in publish → consume-start →
    // consume-end fails the test as well as the timing assertions below do.
    const allocator = testing.allocator;

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
    defer tracer.deinit();

    var instrumentation = try AutoInstrumentation.init(allocator, &metrics, &tracer);

    var listener = InstrumentedEventListener.init(allocator, &instrumentation);
    defer listener.deinit();

    try listener.onEventPublished("order.created", "orders");
    try listener.onEventConsumeStart("order.created", "orders");
    waitForClockAdvance(measured_wait_ns);
    listener.onEventConsumeEnd("order.created", "orders", true);

    try testing.expectEqual(@as(u64, 1), instrumentation.event_processing_duration.totalCount());

    const recorded = instrumentation.event_processing_duration.sum();
    try testing.expect(recorded >= measured_wait_seconds);
    try testing.expect(recorded < measured_wait_ceiling_seconds);
}

test "InstrumentedEventListener deinit releases an unended consume" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
    defer tracer.deinit();

    var instrumentation = try AutoInstrumentation.init(allocator, &metrics, &tracer);

    var listener = InstrumentedEventListener.init(allocator, &instrumentation);
    defer listener.deinit();

    // Published and never consumed: the publish span is ended by
    // `onEventPublished` (the publish is over by then) and kept in the map as
    // the consume half's parent reference, so `deinit` releases that entry's
    // key *and* the span — nothing else owns it.
    try listener.onEventPublished("order.created", "orders");

    // Consumed and never ended: both maps hold a `consume:…` key, one
    // allocation each, so `deinit` frees two keys and never the same one twice.
    // The consume span is still un-ended, so the tracer owns it — which is the
    // observable half of the split `deinit` makes (ended publish span → this
    // listener, un-ended consume span → the tracer).
    try listener.onEventConsumeStart("order.created", "orders");
    try testing.expectEqual(@as(usize, 1), tracer.active_spans.items.len);
    try testing.expectEqual(@as(usize, 2), listener.event_processing_spans.count());
}

// What the publish side of `event_processing_spans` costs on a long-lived
// listener.
//
// The map is keyed by the `event:module` pair, so *it* is bounded by how many
// distinct pairs an app publishes — a number fixed by the app's source (its
// event types × the modules publishing them), not by traffic, and asserted
// below. The span behind the entry was unbounded in the other direction:
// every `onEventPublished` built a fresh span with `startTrace` and left the
// previous one listed in `tracer.active_spans` (`put` replaced the map value,
// nothing ended the old span), so a process publishing for months collected
// one span per published event — one map entry, but a tracer list that grew
// with the event volume. Both halves are asserted here.
test "InstrumentedEventListener publish side is bounded by distinct pairs, not by volume" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
    defer tracer.deinit();

    var instrumentation = try AutoInstrumentation.init(allocator, &metrics, &tracer);

    var listener = InstrumentedEventListener.init(allocator, &instrumentation);
    defer listener.deinit();

    const publishes = 128;
    for (0..publishes) |_| try listener.onEventPublished("order.created", "orders");

    try testing.expectEqual(@as(usize, 1), listener.event_processing_spans.count());
    try testing.expectEqual(@as(usize, 0), tracer.active_spans.items.len);

    // A second module on the same event name, and a second event name, cost
    // one entry each — that is the bound the map does have — and still no span.
    try listener.onEventPublished("order.created", "billing");
    try listener.onEventPublished("order.shipped", "orders");
    try testing.expectEqual(@as(usize, 3), listener.event_processing_spans.count());
    try testing.expectEqual(@as(usize, 0), tracer.active_spans.items.len);

    // The ended parent is still usable as one: `startSpan` copies `trace_id` /
    // `span_id` by value, so ending the publish span (rather than parking it in
    // the tracer's list) does not orphan the consume half of the trace.
    try listener.onEventConsumeStart("order.created", "orders");
    try testing.expectEqual(@as(usize, 1), tracer.active_spans.items.len);
    try testing.expect(tracer.active_spans.items[0].parent_span_id != null);
}

const FunctionProbe = struct {
    fn ok() anyerror!u32 {
        return 7;
    }
};

test "instrumentFunction frees its span and leaves the name to the caller" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
    defer tracer.deinit();

    var instrumentation = try AutoInstrumentation.init(allocator, &metrics, &tracer);

    // Static name: `startTrace` copies it, so nothing is allocated for it here.
    const name = "probe.work";
    try testing.expectEqual(@as(u32, 7), try instrumentation.instrumentFunction(name, u32, FunctionProbe.ok));

    // The span was ended, so it is not left for `tracer.deinit` to free:
    // `instrumentFunction` destroyed it, and the `testing.allocator` run reports
    // the leak if it had not.
    try testing.expectEqual(@as(usize, 0), tracer.active_spans.items.len);
    // Elapsed time here is log-only, per the doc comment.
    try testing.expectEqual(@as(u64, 0), instrumentation.api_request_duration.totalCount());

    // The failing path (same `defer`, plus an `error.type` attribute) is not
    // driven here: it logs with `std.log.err`, and `scripts/test-runner.zig`
    // fails a run in which anything logged at that level.
}

test "recordApiRequestEnd leaves the span to the caller" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    var tracer = try DistributedTracer.init(allocator, "test_tracer", "test_service");
    defer tracer.deinit();

    var instrumentation = try AutoInstrumentation.init(allocator, &metrics, &tracer);

    const span = try instrumentation.recordApiRequestStart("GET /orders", "orders");
    instrumentation.recordApiRequestEnd(span, 0.01, false);

    // `endSpan` only un-lists the span, so from here the caller owns the storage.
    try testing.expectEqual(@as(usize, 0), tracer.active_spans.items.len);
    span.deinit(allocator);
    allocator.destroy(span);

    try testing.expectEqual(@as(u64, 1), instrumentation.api_request_duration.totalCount());
    try testing.expectEqual(@as(u64, 1), instrumentation.api_error_total.get());
}
