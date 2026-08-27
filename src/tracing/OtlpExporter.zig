//! OpenTelemetry (OTLP/HTTP JSON) Exporter for DistributedTracer.
//! Serializes spans to OTLP JSON and POSTs to a collector endpoint with retries.

const std = @import("std");
const DistributedTracer = @import("DistributedTracer.zig").DistributedTracer;
const Span = DistributedTracer.Span;
const HttpClient = @import("../http/HttpClient.zig").HttpClient;

pub const ExportOptions = struct {
    /// Extra attempts after the first try (total tries = 1 + max_retries).
    max_retries: u32 = 3,
    retry_base_ms: u64 = 100,
    /// Cap for HttpClient connection pool / socket timeout.
    timeout_ms: u64 = 5_000,
};

pub const OtlpExporter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    service_name: []const u8,
    endpoint_url: []const u8,

    pub fn init(allocator: std.mem.Allocator, service_name: []const u8, endpoint_url: []const u8) !Self {
        return .{
            .allocator = allocator,
            .service_name = try allocator.dupe(u8, service_name),
            .endpoint_url = try allocator.dupe(u8, endpoint_url),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.service_name);
        self.allocator.free(self.endpoint_url);
        self.* = undefined;
    }

    /// Serialize a slice of spans into OTLP JSON payload format.
    pub fn serializeSpansJson(self: *Self, spans: []const Span) ![]const u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(self.allocator);

        try list.appendSlice(self.allocator, "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"");
        try list.appendSlice(self.allocator, self.service_name);
        try list.appendSlice(self.allocator, "\"}}]},\"scopeSpans\":[{\"spans\":[");

        for (spans, 0..) |span, i| {
            if (i > 0) try list.appendSlice(self.allocator, ",");
            const tid = try span.trace_id.toString(self.allocator);
            defer self.allocator.free(tid);
            const sid = try span.span_id.toString(self.allocator);
            defer self.allocator.free(sid);

            const end_time_val = span.end_time orelse span.start_time;
            const st_ns: u64 = @as(u64, @intCast(@max(0, span.start_time))) *% 1_000_000;
            const et_ns: u64 = @as(u64, @intCast(@max(0, end_time_val))) *% 1_000_000;

            const buf = try std.fmt.allocPrint(self.allocator, "{{\"traceId\":\"{s}\",\"spanId\":\"{s}\",\"name\":\"{s}\",\"kind\":1,\"startTimeUnixNano\":{d},\"endTimeUnixNano\":{d}}}", .{
                tid,
                sid,
                span.name,
                st_ns,
                et_ns,
            });

            defer self.allocator.free(buf);
            try list.appendSlice(self.allocator, buf);
        }

        try list.appendSlice(self.allocator, "]}]}]}");
        return list.toOwnedSlice(self.allocator);
    }

    /// OTLP/HTTP: retryable statuses (throttle + server errors).
    pub fn isRetryableStatus(status_code: u16) bool {
        return status_code == 429 or status_code >= 500;
    }

    /// POST serialized spans to `endpoint_url` (OTLP/HTTP JSON).
    /// Retries on transport errors and retryable HTTP statuses.
    pub fn exportSpans(self: *Self, io: std.Io, spans: []const Span, opts: ExportOptions) !void {
        const json = try self.serializeSpansJson(spans);
        defer self.allocator.free(json);
        try self.postJsonWithRetry(io, json, opts);
    }

    pub fn postJsonWithRetry(self: *Self, io: std.Io, json: []const u8, opts: ExportOptions) !void {
        if (!std.mem.startsWith(u8, self.endpoint_url, "http://") and
            !std.mem.startsWith(u8, self.endpoint_url, "https://"))
        {
            return error.InvalidOtlpEndpoint;
        }

        var client = HttpClient.init(self.allocator, io, 2, opts.timeout_ms);
        defer client.deinit();

        var attempt: u32 = 0;
        const max_attempts = opts.max_retries + 1;
        var last_err: anyerror = error.OtlpExportFailed;

        while (attempt < max_attempts) : (attempt += 1) {
            var resp = client.post(self.endpoint_url, json) catch |err| {
                last_err = err;
                if (attempt + 1 >= max_attempts) return err;
                try sleepBackoff(io, opts.retry_base_ms, attempt);
                continue;
            };
            defer resp.deinit();

            if (resp.isSuccess()) return;

            last_err = error.OtlpExportFailed;
            if (!isRetryableStatus(resp.status_code) or attempt + 1 >= max_attempts) {
                std.log.warn("OTLP export failed: HTTP {d} endpoint={s}", .{ resp.status_code, self.endpoint_url });
                return error.OtlpExportFailed;
            }
            std.log.warn("OTLP export retryable HTTP {d}, attempt {d}/{d}", .{ resp.status_code, attempt + 1, max_attempts });
            try sleepBackoff(io, opts.retry_base_ms, attempt);
        }
        return last_err;
    }
};

fn sleepBackoff(io: std.Io, base_ms: u64, attempt: u32) !void {
    const shift: u6 = @intCast(@min(attempt, 6));
    const delay_ms = base_ms * (@as(u64, 1) << shift);
    try std.Io.sleep(io, .{ .nanoseconds = delay_ms * std.time.ns_per_ms }, .real);
}

test "OtlpExporter JSON serialization" {
    const allocator = std.testing.allocator;
    var exporter = try OtlpExporter.init(allocator, "shop-service", "http://localhost:4318/v1/traces");
    defer exporter.deinit();

    var tracer = try DistributedTracer.init(allocator, "test-tracer", "shop-service");
    defer tracer.deinit();

    const span = try tracer.startTrace("GET /api/users");
    defer {
        tracer.endSpan(span);
        span.deinit(allocator);
        allocator.destroy(span);
    }

    const spans = &[_]Span{span.*};
    const json = try exporter.serializeSpansJson(spans);
    defer allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "shop-service"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "GET /api/users"));
}

test "OtlpExporter isRetryableStatus" {
    try std.testing.expect(OtlpExporter.isRetryableStatus(429));
    try std.testing.expect(OtlpExporter.isRetryableStatus(503));
    try std.testing.expect(!OtlpExporter.isRetryableStatus(200));
    try std.testing.expect(!OtlpExporter.isRetryableStatus(400));
}

test "OtlpExporter accepts https endpoint (routes via HttpClient TLS)" {
    const allocator = std.testing.allocator;
    var exporter = try OtlpExporter.init(allocator, "svc", "https://collector.example/v1/traces");
    defer exporter.deinit();
    // No live network in unit tests: an unreachable collector surfaces as a
    // transport error, NOT OtlpTlsNotSupported — https is now a supported
    // scheme routed through std.http.Client.
    if (exporter.postJsonWithRetry(std.testing.io, "{}", .{ .max_retries = 0 })) |_| {
        return error.ExpectedFailure;
    } else |err| {
        try std.testing.expect(err != error.OtlpTlsNotSupported);
        try std.testing.expect(err != error.InvalidOtlpEndpoint);
    }
}

test "OtlpExporter live HTTP export" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const ep_c = std.c.getenv("OTLP_ENDPOINT") orelse return error.SkipZigTest;
    const ep = std.mem.span(ep_c);
    if (ep.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var exporter = try OtlpExporter.init(allocator, "zigmodu-test", ep);
    defer exporter.deinit();

    var tracer = try DistributedTracer.init(allocator, "live", "zigmodu-test");
    defer tracer.deinit();
    const span = try tracer.startTrace("otlp.live");
    defer {
        tracer.endSpan(span);
        span.deinit(allocator);
        allocator.destroy(span);
    }

    try exporter.exportSpans(io, &.{span.*}, .{ .max_retries = 1, .timeout_ms = 2_000 });
}
