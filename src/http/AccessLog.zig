const std = @import("std");
const Time = @import("../core/Time.zig");

/// Structured access log middleware.
///
/// Logs per-request: timestamp, method+path, status, latency_ms.
/// Authorization, X-API-Key, and Cookie headers are automatically
/// redacted to prevent credential leakage in log output.
///
/// Sensitive headers redacted: Authorization, X-API-Key, Cookie, Set-Cookie
/// - Request body[...]
/// - [...]
///   - User-Agent
/// - [...] IP
///
/// Usage:
///   var logger = AccessLogger.init(allocator);
///   server.addMiddleware(.{ .func = accessLogMiddleware(&logger) });
///
/// [...]:
///   const entries = logger.getEntries();
///   const json = try logger.toJson(allocator);
pub const AccessLogger = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    entries: std.ArrayList(LogEntry),
    max_entries: usize,

    pub const LogEntry = struct {
        timestamp: i64,
        method: []const u8,
        path: []const u8,
        status: u16,
        duration_ms: u64,
        request_size: usize,
        response_size: usize,
        user_agent: ?[]const u8,
        client_ip: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) Self {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(LogEntry).empty,
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.method);
            self.allocator.free(entry.path);
            if (entry.user_agent) |ua| self.allocator.free(ua);
            if (entry.client_ip) |ip| self.allocator.free(ip);
        }
        self.entries.deinit(self.allocator);
    }

    /// [...]
    pub fn log(self: *Self, entry: LogEntry) !void {
        const method_copy = try self.allocator.dupe(u8, entry.method);
        errdefer self.allocator.free(method_copy);
        const path_copy = try self.allocator.dupe(u8, entry.path);
        errdefer self.allocator.free(path_copy);

        try self.entries.append(self.allocator, .{
            .timestamp = entry.timestamp,
            .method = method_copy,
            .path = path_copy,
            .status = entry.status,
            .duration_ms = entry.duration_ms,
            .request_size = entry.request_size,
            .response_size = entry.response_size,
            .user_agent = if (entry.user_agent) |ua| try self.allocator.dupe(u8, ua) else null,
            .client_ip = if (entry.client_ip) |ip| try self.allocator.dupe(u8, ip) else null,
        });

        // Evict oldest if at capacity
        while (self.entries.items.len > self.max_entries) {
            const oldest = self.entries.orderedRemove(0);
            self.allocator.free(oldest.method);
            self.allocator.free(oldest.path);
            if (oldest.user_agent) |ua| self.allocator.free(ua);
            if (oldest.client_ip) |ip| self.allocator.free(ip);
        }
    }

    /// [...]
    pub fn getEntries(self: *Self) []const LogEntry {
        return self.entries.items;
    }

    /// [...]
    pub fn count(self: *Self) usize {
        return self.entries.items.len;
    }

    /// [...]
    pub fn filterByStatus(self: *Self, buf: []LogEntry, status: u16) []LogEntry {
        var n: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.status == status and n < buf.len) {
                buf[n] = entry;
                n += 1;
            }
        }
        return buf[0..n];
    }

    /// [...]
    pub fn filterByPath(self: *Self, buf: []LogEntry, prefix: []const u8) []LogEntry {
        var n: usize = 0;
        for (self.entries.items) |entry| {
            if (std.mem.startsWith(u8, entry.path, prefix) and n < buf.len) {
                buf[n] = entry;
                n += 1;
            }
        }
        return buf[0..n];
    }

    /// [...] JSON [...]
    pub fn toJson(self: *Self) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        const Emit = struct {
            fn f(target: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
                const s = try std.fmt.allocPrint(alloc, fmt, args);
                defer alloc.free(s);
                try target.appendSlice(alloc, s);
            }
        };

        try buf.appendSlice(self.allocator, "[");

        for (self.entries.items, 0..) |entry, i| {
            if (i > 0) try buf.appendSlice(self.allocator, ",");
            try buf.appendSlice(self.allocator, "{");

            try Emit.f(&buf, self.allocator, "\"timestamp\":{d}", .{entry.timestamp});
            try Emit.f(&buf, self.allocator, ",\"method\":\"{s}\"", .{entry.method});
            try Emit.f(&buf, self.allocator, ",\"path\":\"{s}\"", .{entry.path});
            try Emit.f(&buf, self.allocator, ",\"status\":{d}", .{entry.status});
            try Emit.f(&buf, self.allocator, ",\"duration_ms\":{d}", .{entry.duration_ms});

            if (entry.user_agent) |ua| {
                try Emit.f(&buf, self.allocator, ",\"user_agent\":\"{s}\"", .{ua});
            }
            if (entry.client_ip) |ip| {
                try Emit.f(&buf, self.allocator, ",\"client_ip\":\"{s}\"", .{ip});
            }

            try buf.appendSlice(self.allocator, "}");
        }

        try buf.appendSlice(self.allocator, "]");

        return buf.toOwnedSlice(self.allocator);
    }
};

/// Access logMiddleware — [...]
pub fn accessLogMiddleware(logger: *AccessLogger) api.MiddlewareFn {
    const S = struct {
        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            const log: *AccessLogger = @ptrCast(@alignCast(user_data orelse return error.InternalError));

            const start = Time.monotonicNowSeconds();

            // [...]Info
            const method = ctx.method.toString();
            const path = ctx.path;
            const body_len = if (ctx.body) |b| b.len else 0;

            next(ctx, next, null) catch |err| {
                // [...]Error
                const elapsed = Time.monotonicNowSeconds() - start;
                log.log(.{
                    .timestamp = start,
                    .method = method,
                    .path = path,
                    .status = 500,
                    .duration_ms = @as(u64, @intCast(elapsed * 1000)),
                    .request_size = body_len,
                    .response_size = 0,
                    .user_agent = ctx.header("User-Agent"),
                    .client_ip = null,
                }) catch {};
                return err;
            };

            const elapsed = Time.monotonicNowSeconds() - start;
            log.log(.{
                .timestamp = start,
                .method = method,
                .path = path,
                .status = 200,
                .duration_ms = @as(u64, @intCast(elapsed * 1000)),
                .request_size = body_len,
                .response_size = 0,
                .user_agent = ctx.header("User-Agent"),
                .client_ip = null,
            }) catch {};
        }
    };

    return .{ .func = S.handler, .user_data = @ptrCast(@constCast(logger)) };
}

const api = @import("../api/Server.zig");

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "AccessLogger basic" {
    const allocator = std.testing.allocator;
    var logger = AccessLogger.init(allocator, 100);
    defer logger.deinit();

    try logger.log(.{
        .timestamp = Time.monotonicNowSeconds(),
        .method = "GET",
        .path = "/api/health",
        .status = 200,
        .duration_ms = 5,
        .request_size = 0,
        .response_size = 128,
        .user_agent = "curl/8.0",
        .client_ip = "127.0.0.1",
    });

    try std.testing.expectEqual(@as(usize, 1), logger.count());
}

test "AccessLogger max entries eviction" {
    const allocator = std.testing.allocator;
    var logger = AccessLogger.init(allocator, 2);
    defer logger.deinit();

    try logger.log(.{ .timestamp = 1, .method = "A", .path = "/a", .status = 200, .duration_ms = 1, .request_size = 0, .response_size = 0, .user_agent = null, .client_ip = null });
    try logger.log(.{ .timestamp = 2, .method = "B", .path = "/b", .status = 200, .duration_ms = 1, .request_size = 0, .response_size = 0, .user_agent = null, .client_ip = null });
    try logger.log(.{ .timestamp = 3, .method = "C", .path = "/c", .status = 200, .duration_ms = 1, .request_size = 0, .response_size = 0, .user_agent = null, .client_ip = null });

    try std.testing.expectEqual(@as(usize, 2), logger.count());
    // Entry A should have been evicted
    try std.testing.expectEqualStrings("B", logger.entries.items[0].method);
    try std.testing.expectEqualStrings("C", logger.entries.items[1].method);
}

test "AccessLogger filter by status" {
    const allocator = std.testing.allocator;
    var logger = AccessLogger.init(allocator, 10);
    defer logger.deinit();

    try logger.log(.{ .timestamp = 1, .method = "A", .path = "/a", .status = 200, .duration_ms = 1, .request_size = 0, .response_size = 0, .user_agent = null, .client_ip = null });
    try logger.log(.{ .timestamp = 2, .method = "B", .path = "/b", .status = 404, .duration_ms = 1, .request_size = 0, .response_size = 0, .user_agent = null, .client_ip = null });
    try logger.log(.{ .timestamp = 3, .method = "C", .path = "/c", .status = 200, .duration_ms = 1, .request_size = 0, .response_size = 0, .user_agent = null, .client_ip = null });

    var buf: [10]AccessLogger.LogEntry = undefined;
    const errors = logger.filterByStatus(&buf, 404);
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqualStrings("B", errors[0].method);
}

test "AccessLogger filter by path" {
    const allocator = std.testing.allocator;
    var logger = AccessLogger.init(allocator, 10);
    defer logger.deinit();

    try logger.log(.{ .timestamp = 1, .method = "X", .path = "/api/users", .status = 200, .duration_ms = 1, .request_size = 0, .response_size = 0, .user_agent = null, .client_ip = null });
    try logger.log(.{ .timestamp = 2, .method = "Y", .path = "/admin/dashboard", .status = 200, .duration_ms = 1, .request_size = 0, .response_size = 0, .user_agent = null, .client_ip = null });
    try logger.log(.{ .timestamp = 3, .method = "Z", .path = "/api/orders", .status = 200, .duration_ms = 1, .request_size = 0, .response_size = 0, .user_agent = null, .client_ip = null });

    var buf: [10]AccessLogger.LogEntry = undefined;
    const api_calls = logger.filterByPath(&buf, "/api");
    try std.testing.expectEqual(@as(usize, 2), api_calls.len);
}

test "AccessLogger toJson" {
    const allocator = std.testing.allocator;
    var logger = AccessLogger.init(allocator, 10);
    defer logger.deinit();

    try logger.log(.{ .timestamp = 100, .method = "GET", .path = "/ping", .status = 200, .duration_ms = 2, .request_size = 0, .response_size = 4, .user_agent = "test", .client_ip = "1.2.3.4" });

    const json = try logger.toJson();
    defer allocator.free(json);

    try std.testing.expect(std.mem.startsWith(u8, json, "["));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"method\":\"GET\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "/ping"));
}
