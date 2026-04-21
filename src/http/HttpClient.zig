const std = @import("std");

/// HTTP 客户端 - 带连接池和重试机制
pub const HttpClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    connection_pool: ConnectionPool,
    retry_policy: RetryPolicy,
    timeout_ms: u64,

    pub const ConnectionPool = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        max_connections: usize,
        idle_connections: std.ArrayList(Connection),
        active_connections: std.ArrayList(Connection),
        mutex: std.Io.Mutex,

        pub const Connection = struct {
            host: []const u8,
            port: u16,
            stream: ?std.Io.net.Stream,
            created_at: i64,
            last_used: i64,
            request_count: u64,

            pub fn isAlive(self: Connection) bool {
                if (self.stream == null) return false;
                // 简化实现：检查是否超时
                const now = 0;
                return (now - self.last_used) < 30; // 30秒超时
            }
        };

        pub fn init(allocator: std.mem.Allocator, io: std.Io, max_connections: usize) ConnectionPool {
            return .{
                .allocator = allocator,
                .io = io,
                .max_connections = max_connections,
                .idle_connections = std.ArrayList(Connection).empty,
                .active_connections = std.ArrayList(Connection).empty,
                .mutex = std.Io.Mutex.init,
            };
        }

        pub fn deinit(self: *ConnectionPool) void {
            for (self.idle_connections.items) |conn| {
                if (conn.stream) |stream| {
                    stream.close(self.io);
                }
                self.allocator.free(conn.host);
            }
            self.idle_connections.deinit(self.allocator);

            for (self.active_connections.items) |conn| {
                if (conn.stream) |stream| {
                    stream.close(self.io);
                }
                self.allocator.free(conn.host);
            }
            self.active_connections.deinit(self.allocator);
        }

        pub fn acquire(self: *ConnectionPool, host: []const u8, port: u16) !Connection {
            self.mutex.lock(self.io) catch return error.ServerError;
            defer self.mutex.unlock(self.io);

            // 查找空闲连接
            for (self.idle_connections.items, 0..) |conn, i| {
                if (std.mem.eql(u8, conn.host, host) and conn.port == port and conn.isAlive()) {
                    const connection = self.idle_connections.orderedRemove(i);
                    try self.active_connections.append(self.allocator, connection);
                    return connection;
                }
            }

            // 创建新连接
            if (self.active_connections.items.len >= self.max_connections) {
                return error.PoolExhausted;
            }

            const addr = try std.Io.net.IpAddress.resolve(self.io, host, port);
            const stream = try addr.connect(self.io, .{ .mode = .stream });
            const host_copy = try self.allocator.dupe(u8, host);

            const conn = Connection{
                .host = host_copy,
                .port = port,
                .stream = stream,
                .created_at = 0,
                .last_used = 0,
                .request_count = 0,
            };

            try self.active_connections.append(self.allocator, conn);
            return conn;
        }

        pub fn release(self: *ConnectionPool, conn: Connection) void {
            self.mutex.lock(self.io) catch return;
            defer self.mutex.unlock(self.io);

            // 从活跃连接中移除
            for (self.active_connections.items, 0..) |active_conn, i| {
                if (active_conn.stream != null and conn.stream != null and active_conn.stream.?.socket.handle == conn.stream.?.socket.handle) {
                    _ = self.active_connections.orderedRemove(i);
                    break;
                }
            }

            // 如果连接还存活，放回空闲池
            if (conn.isAlive()) {
                var released_conn = conn;
                released_conn.last_used = 0;
                self.idle_connections.append(self.allocator, released_conn) catch {};
            } else {
                if (conn.stream) |stream| {
                    stream.close(self.io);
                }
                self.allocator.free(conn.host);
            }
        }
    };

    pub const RetryPolicy = struct {
        max_retries: u32,
        initial_delay_ms: u64,
        max_delay_ms: u64,
        backoff_multiplier: f64,

        pub fn default() RetryPolicy {
            return .{
                .max_retries = 3,
                .initial_delay_ms = 100,
                .max_delay_ms = 10000,
                .backoff_multiplier = 2.0,
            };
        }

        pub fn calculateDelay(self: RetryPolicy, attempt: u32) u64 {
            const delay = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.initial_delay_ms)) *
                std.math.pow(f64, self.backoff_multiplier, @as(f64, @floatFromInt(attempt)))));
            return @min(delay, self.max_delay_ms);
        }
    };

    pub const HttpRequest = struct {
        method: []const u8,
        url: []const u8,
        headers: std.StringHashMap([]const u8),
        body: ?[]const u8,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, method: []const u8, url: []const u8) HttpRequest {
            return .{
                .method = method,
                .url = url,
                .headers = std.StringHashMap([]const u8).init(allocator),
                .body = null,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *HttpRequest) void {
            var iter = self.headers.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.headers.deinit();
            if (self.body) |body| {
                self.allocator.free(body);
            }
        }

        pub fn setHeader(self: *HttpRequest, key: []const u8, value: []const u8) !void {
            const key_copy = try self.allocator.dupe(u8, key);
            const value_copy = try self.allocator.dupe(u8, value);
            try self.headers.put(key_copy, value_copy);
        }

        pub fn setBody(self: *HttpRequest, body: []const u8) !void {
            self.body = try self.allocator.dupe(u8, body);
        }
    };

    pub const HttpResponse = struct {
        status_code: u16,
        headers: std.StringHashMap([]const u8),
        body: []const u8,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) HttpResponse {
            return .{
                .status_code = 0,
                .headers = std.StringHashMap([]const u8).init(allocator),
                .body = "",
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *HttpResponse) void {
            var iter = self.headers.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.headers.deinit();
            self.allocator.free(self.body);
        }

        pub fn isSuccess(self: HttpResponse) bool {
            return self.status_code >= 200 and self.status_code < 300;
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, max_connections: usize, timeout_ms: u64) Self {
        return .{
            .allocator = allocator,
            .connection_pool = ConnectionPool.init(allocator, io, max_connections),
            .retry_policy = RetryPolicy.default(),
            .timeout_ms = timeout_ms,
        };
    }

    pub fn deinit(self: *Self) void {
        self.connection_pool.deinit();
    }

    /// 发送 HTTP 请求（带重试）
    pub fn request(self: *Self, req: HttpRequest) !HttpResponse {
        var last_error: anyerror = error.Unknown;

        var attempt: u32 = 0;
        while (attempt <= self.retry_policy.max_retries) : (attempt += 1) {
            return self.executeRequest(req) catch |err| {
                last_error = err;

                if (attempt < self.retry_policy.max_retries) {
                    const delay = self.retry_policy.calculateDelay(attempt);
                    std.log.warn("Request failed, retrying in {d}ms (attempt {d}/{d})", .{ delay, attempt + 1, self.retry_policy.max_retries });
                    std.Io.sleep(self.connection_pool.io, .{ .nanoseconds = delay * std.time.ns_per_ms }, .real) catch {};
                }
                continue;
            };
        }

        return last_error;
    }

    fn executeRequest(self: *Self, req: HttpRequest) !HttpResponse {
        // 解析 URL
        const parsed_url = try std.Uri.parse(req.url);
        const host = parsed_url.host orelse return error.InvalidUrl;
        const port: u16 = if (parsed_url.port) |p|
            if (p <= std.math.maxInt(u16)) @intCast(p) else return error.InvalidPort
        else
            80;

        // 获取连接
        var conn = try self.connection_pool.acquire(host, port);
        defer self.connection_pool.release(conn);

        // 构建 HTTP 请求
        const request_line = try std.fmt.allocPrint(self.allocator, "{s} {s} HTTP/1.1\r\n", .{ req.method, parsed_url.path });
        defer self.allocator.free(request_line);

        // 发送请求
        if (conn.stream) |stream| {
            var write_buf: [4096]u8 = undefined;
            var w = stream.writer(self.connection_pool.io, &write_buf);
            _ = w.writeAll(request_line) catch return error.ConnectionError;

            // 发送 headers
            var iter = req.headers.iterator();
            while (iter.next()) |entry| {
                const header_line = try std.fmt.allocPrint(self.allocator, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                defer self.allocator.free(header_line);
                _ = w.writeAll(header_line) catch return error.ConnectionError;
            }

            _ = w.writeAll("\r\n") catch return error.ConnectionError;

            // 发送 body
            if (req.body) |body| {
                _ = w.writeAll(body) catch return error.ConnectionError;
            }

            // 读取响应（最小实现：解析 status line + headers + body）
            const response = try self.readResponse(stream);

            conn.request_count += 1;
            return response;
        }

        return error.ConnectionError;
    }

    fn readResponse(self: *Self, stream: std.Io.net.Stream) !HttpResponse {
        var resp = HttpResponse.init(self.allocator);
        errdefer resp.deinit();

        var buf: [8192]u8 = undefined;
        var read_buf: [8192]u8 = undefined;
        var r = stream.reader(self.connection_pool.io, &read_buf);

        const n = try r.interface.readSliceShort(&buf);
        if (n == 0) return error.ConnectionError;
        const raw = buf[0..n];

        const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidResponse;
        const head = raw[0..header_end];
        const body_start = header_end + 4;

        var line_it = std.mem.splitSequence(u8, head, "\r\n");
        const status_line = line_it.next() orelse return error.InvalidResponse;
        // Example: HTTP/1.1 200 OK
        var parts = std.mem.splitScalar(u8, status_line, ' ');
        _ = parts.next() orelse return error.InvalidResponse; // http version
        const status_str = parts.next() orelse return error.InvalidResponse;
        resp.status_code = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidResponse;

        var content_length: usize = 0;
        while (line_it.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key_trim = std.mem.trim(u8, line[0..colon], " \t");
            const val_trim = std.mem.trim(u8, line[colon + 1 ..], " \t");

            const key = try self.allocator.dupe(u8, key_trim);
            errdefer self.allocator.free(key);
            const val = try self.allocator.dupe(u8, val_trim);
            errdefer self.allocator.free(val);
            try resp.headers.put(key, val);

            if (std.ascii.eqlIgnoreCase(key_trim, "content-length")) {
                content_length = std.fmt.parseInt(usize, val_trim, 10) catch 0;
            }
        }

        const initial_body = raw[body_start..];
        if (content_length == 0) {
            resp.body = try self.allocator.dupe(u8, initial_body);
            return resp;
        }

        var body_buf = try self.allocator.alloc(u8, content_length);
        var copied: usize = @min(initial_body.len, content_length);
        @memcpy(body_buf[0..copied], initial_body[0..copied]);

        while (copied < content_length) {
            const more = try r.interface.readSliceShort(&buf);
            if (more == 0) break;
            const to_copy = @min(@as(usize, more), content_length - copied);
            @memcpy(body_buf[copied..][0..to_copy], buf[0..to_copy]);
            copied += to_copy;
        }

        if (copied != content_length) {
            self.allocator.free(body_buf);
            return error.IncompleteBody;
        }

        resp.body = body_buf;
        return resp;
    }

    /// GET 请求
    pub fn get(self: *Self, url: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "GET", url);
        defer req.deinit();
        return self.request(req);
    }

    /// POST 请求
    pub fn post(self: *Self, url: []const u8, body: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "POST", url);
        defer req.deinit();
        try req.setBody(body);
        try req.setHeader("Content-Type", "application/json");
        return self.request(req);
    }

    /// PUT 请求
    pub fn put(self: *Self, url: []const u8, body: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "PUT", url);
        defer req.deinit();
        try req.setBody(body);
        try req.setHeader("Content-Type", "application/json");
        return self.request(req);
    }

    /// DELETE 请求
    pub fn delete(self: *Self, url: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "DELETE", url);
        defer req.deinit();
        return self.request(req);
    }
};

test "HttpClient RetryPolicy calculateDelay" {
    const policy = HttpClient.RetryPolicy.default();
    try std.testing.expectEqual(@as(u64, 100), policy.calculateDelay(0));
    try std.testing.expectEqual(@as(u64, 200), policy.calculateDelay(1));
    try std.testing.expectEqual(@as(u64, 400), policy.calculateDelay(2));
}

test "HttpClient ConnectionPool acquire and release" {
    const allocator = std.testing.allocator;
    var pool = HttpClient.ConnectionPool.init(allocator, std.testing.io, 2);
    defer pool.deinit();

    // Acquire new connection
    const conn = pool.acquire("127.0.0.1", 9999) catch |err| switch (err) {
        error.ConnectionRefused => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqualStrings("127.0.0.1", conn.host);
    try std.testing.expectEqual(@as(u16, 9999), conn.port);

    // Release back to pool
    pool.release(conn);

    // Reacquire should reuse if alive
    const conn2 = pool.acquire("127.0.0.1", 9999) catch |err| switch (err) {
        error.ConnectionRefused => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqualStrings("127.0.0.1", conn2.host);
    try std.testing.expectEqual(@as(u16, 9999), conn2.port);

    pool.release(conn2);
}

test "HttpClient ConnectionPool exhaustion" {
    const allocator = std.testing.allocator;
    var pool = HttpClient.ConnectionPool.init(allocator, std.testing.io, 1);
    defer pool.deinit();

    const conn = pool.acquire("127.0.0.1", 9999) catch |err| switch (err) {
        error.ConnectionRefused => return error.SkipZigTest,
        else => return err,
    };
    const result = pool.acquire("127.0.0.1", 9999);
    try std.testing.expectError(error.PoolExhausted, result);

    pool.release(conn);
}

test "HttpClient HttpRequest and HttpResponse" {
    const allocator = std.testing.allocator;

    var req = HttpClient.HttpRequest.init(allocator, "POST", "http://example.com/api");
    defer req.deinit();
    try req.setHeader("Content-Type", "application/json");
    try req.setBody("{\"id\":1}");

    try std.testing.expectEqualStrings("application/json", req.headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("{\"id\":1}", req.body.?);

    var res = HttpClient.HttpResponse.init(allocator);
    defer res.deinit();
    res.status_code = 201;
    try std.testing.expect(res.isSuccess());
}
