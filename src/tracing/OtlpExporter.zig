//! OpenTelemetry (OTLP/HTTP JSON) Exporter for DistributedTracer.
//! Converts trace spans into standard OpenTelemetry OTLP JSON payloads.

const std = @import("std");
const DistributedTracer = @import("DistributedTracer.zig").DistributedTracer;
const Span = DistributedTracer.Span;

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
};

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
