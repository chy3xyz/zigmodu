const std = @import("std");

/// 分布式链路追踪器
pub const DistributedTracer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    tracer_name: []const u8,
    service_name: []const u8,
    active_spans: std.ArrayList(*Span),

    pub const TraceId = struct {
        high: u64,
        low: u64,

        pub fn generate() TraceId {
            return .{
                .high = std.crypto.random.int(u64),
                .low = std.crypto.random.int(u64),
            };
        }

        pub fn toString(self: TraceId, allocator: std.mem.Allocator) ![]const u8 {
            return std.fmt.allocPrint(allocator, "{x:016}{x:016}", .{ self.high, self.low });
        }
    };

    pub const SpanId = struct {
        id: u64,

        pub fn generate() SpanId {
            return .{ .id = std.crypto.random.int(u64) };
        }

        pub fn toString(self: SpanId, allocator: std.mem.Allocator) ![]const u8 {
            return std.fmt.allocPrint(allocator, "{x:016}", .{self.id});
        }
    };

    pub const Span = struct {
        trace_id: TraceId,
        span_id: SpanId,
        parent_span_id: ?SpanId,
        name: []const u8,
        start_time: i64,
        end_time: ?i64,
        attributes: std.StringHashMap([]const u8),
        events: std.ArrayList(SpanEvent),
        status: SpanStatus,

        pub const SpanEvent = struct {
            name: []const u8,
            timestamp: i64,
            attributes: std.StringHashMap([]const u8),
        };

        pub const SpanStatus = enum {
            UNSET,
            OK,
            ERROR,
        };

        pub fn init(allocator: std.mem.Allocator, trace_id: TraceId, span_id: SpanId, parent_span_id: ?SpanId, name: []const u8) !Span {
            return .{
                .trace_id = trace_id,
                .span_id = span_id,
                .parent_span_id = parent_span_id,
                .name = try allocator.dupe(u8, name),
                .start_time = std.time.nanoTimestamp(),
                .end_time = null,
                .attributes = std.StringHashMap([]const u8).init(allocator),
                .events = std.ArrayList(SpanEvent).init(allocator),
                .status = .UNSET,
            };
        }

        pub fn deinit(self: *Span, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            var iter = self.attributes.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            self.attributes.deinit();

            for (self.events.items) |event| {
                var attr_iter = event.attributes.iterator();
                while (attr_iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                event.attributes.deinit();
            }
            self.events.deinit(allocator);
        }

        pub fn setAttribute(self: *Span, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
            const key_copy = try allocator.dupe(u8, key);
            const value_copy = try allocator.dupe(u8, value);
            try self.attributes.put(key_copy, value_copy);
        }

        pub fn addEvent(self: *Span, allocator: std.mem.Allocator, name: []const u8) !void {
            try self.events.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .timestamp = std.time.nanoTimestamp(),
                .attributes = std.StringHashMap([]const u8).init(allocator),
            });
        }

        pub fn end(self: *Span) void {
            self.end_time = std.time.nanoTimestamp();
        }
    };

    pub fn init(allocator: std.mem.Allocator, tracer_name: []const u8, service_name: []const u8) !Self {
        return .{
            .allocator = allocator,
            .tracer_name = try allocator.dupe(u8, tracer_name),
            .service_name = try allocator.dupe(u8, service_name),
            .active_spans = std.ArrayList(*Span).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.tracer_name);
        self.allocator.free(self.service_name);

        for (self.active_spans.items) |span| {
            span.deinit(self.allocator);
            self.allocator.destroy(span);
        }
        self.active_spans.deinit(self.allocator);
    }

    /// 创建新的 Trace
    pub fn startTrace(self: *Self, span_name: []const u8) !*Span {
        const trace_id = TraceId.generate();
        const span_id = SpanId.generate();

        const span = try self.allocator.create(Span);
        span.* = try Span.init(self.allocator, trace_id, span_id, null, span_name);

        try self.active_spans.append(self.allocator, span);
        return span;
    }

    /// 创建子 Span
    pub fn startSpan(self: *Self, parent: *Span, span_name: []const u8) !*Span {
        const span_id = SpanId.generate();

        const span = try self.allocator.create(Span);
        span.* = try Span.init(self.allocator, parent.trace_id, span_id, parent.span_id, span_name);

        try self.active_spans.append(self.allocator, span);
        return span;
    }

    /// 结束 Span
    pub fn endSpan(self: *Self, span: *Span) void {
        span.end();

        // 从活跃列表中移除
        for (self.active_spans.items, 0..) |s, i| {
            if (s == span) {
                _ = self.active_spans.orderedRemove(i);
                break;
            }
        }
    }

    /// 导出为 Jaeger 格式
    pub fn exportJaeger(_self: *Self, span: *Span, allocator: std.mem.Allocator) ![]const u8 {
        _ = _self;
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll("{");
        try writer.print("\"traceID\":\"{s}\",", .{try span.trace_id.toString(allocator)});
        try writer.print("\"spanID\":\"{s}\",", .{try span.span_id.toString(allocator)});
        if (span.parent_span_id) |parent| {
            try writer.print("\"parentSpanID\":\"{s}\",", .{try parent.toString(allocator)});
        }
        try writer.print("\"operationName\":\"{s}\",", .{span.name});
        try writer.print("\"startTime\":{d},", .{span.start_time});
        try writer.print("\"duration\":{d},", .{if (span.end_time) |et| et - span.start_time else 0});
        try writer.writeAll("\"tags\":[");

        var first = true;
        var iter = span.attributes.iterator();
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.print("{{\"key\":\"{s}\",\"value\":\"{s}\"}}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try writer.writeAll("]}");
        return buf.toOwnedSlice(allocator);
    }

    /// 导出为 Zipkin 格式
    pub fn exportZipkin(self: *Self, span: *Span, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll("[");
        try writer.writeAll("{");
        try writer.print("\"traceId\":\"{s}\",", .{try span.trace_id.toString(allocator)});
        try writer.print("\"id\":\"{s}\",", .{try span.span_id.toString(allocator)});
        try writer.print("\"name\":\"{s}\",", .{span.name});
        try writer.print("\"timestamp\":{d},", .{@divFloor(span.start_time, 1000)});
        if (span.end_time) |et| {
            try writer.print("\"duration\":{d},", .{@divFloor(et - span.start_time, 1000)});
        }
        try writer.print("\"localEndpoint\":{{\"serviceName\":\"{s}\"}}", .{self.service_name});
        try writer.writeAll("}");
        try writer.writeAll("]");

        return buf.toOwnedSlice(allocator);
    }

    /// 传播上下文（用于跨服务调用）
    pub fn injectContext(self: *Self, span: *Span, headers: *std.StringHashMap([]const u8)) !void {
        const trace_id_str = try span.trace_id.toString(self.allocator);
        defer self.allocator.free(trace_id_str);

        const span_id_str = try span.span_id.toString(self.allocator);
        defer self.allocator.free(span_id_str);

        try headers.put("x-trace-id", trace_id_str);
        try headers.put("x-span-id", span_id_str);
    }

    /// 提取上下文（从入站请求）
    pub fn extractContext(self: *Self, headers: std.StringHashMap([]const u8)) ?TraceId {
        _ = self;
        if (headers.get("x-trace-id")) |_| {
            // 简化实现：生成新的 trace id
            return TraceId.generate();
        }
        return null;
    }
};

/// 采样器
pub const Sampler = struct {
    pub const AlwaysOnSampler = struct {
        pub fn shouldSample() bool {
            return true;
        }
    };

    pub const ProbabilitySampler = struct {
        probability: f64,

        pub fn shouldSample(self: ProbabilitySampler) bool {
            const random = std.crypto.random.float(f64);
            return random < self.probability;
        }
    };
};
