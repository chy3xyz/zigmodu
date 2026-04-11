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
        max_connections: usize,
        idle_connections: std.ArrayList(Connection),
        active_connections: std.ArrayList(Connection),
        mutex: std.Thread.Mutex,

        pub const Connection = struct {
            host: []const u8,
            port: u16,
            stream: ?std.net.Stream,
            created_at: i64,
            last_used: i64,
            request_count: u64,

            pub fn isAlive(self: Connection) bool {
                if (self.stream == null) return false;
                // 简化实现：检查是否超时
                const now = std.time.timestamp();
                return (now - self.last_used) < 30; // 30秒超时
            }
        };

        pub fn init(allocator: std.mem.Allocator, max_connections: usize) ConnectionPool {
            return .{
                .allocator = allocator,
                .max_connections = max_connections,
                .idle_connections = std.ArrayList(Connection).init(allocator),
                .active_connections = std.ArrayList(Connection).init(allocator),
                .mutex = std.Thread.Mutex{},
            };
        }

        pub fn deinit(self: *ConnectionPool) void {
            for (self.idle_connections.items) |conn| {
                if (conn.stream) |stream| {
                    stream.close();
                }
                self.allocator.free(conn.host);
            }
            self.idle_connections.deinit(self.allocator);

            for (self.active_connections.items) |conn| {
                if (conn.stream) |stream| {
                    stream.close();
                }
                self.allocator.free(conn.host);
            }
            self.active_connections.deinit(self.allocator);
        }

        pub fn acquire(self: *ConnectionPool, host: []const u8, port: u16) !Connection {
            self.mutex.lock();
            defer self.mutex.unlock();

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

            const stream = try std.net.tcpConnectToHost(self.allocator, host, port);
            const host_copy = try self.allocator.dupe(u8, host);

            const conn = Connection{
                .host = host_copy,
                .port = port,
                .stream = stream,
                .created_at = std.time.timestamp(),
                .last_used = std.time.timestamp(),
                .request_count = 0,
            };

            try self.active_connections.append(self.allocator, conn);
            return conn;
        }

        pub fn release(self: *ConnectionPool, conn: Connection) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // 从活跃连接中移除
            for (self.active_connections.items, 0..) |active_conn, i| {
                if (active_conn.stream == conn.stream) {
                    _ = self.active_connections.orderedRemove(i);
                    break;
                }
            }

            // 如果连接还存活，放回空闲池
            if (conn.isAlive()) {
                var released_conn = conn;
                released_conn.last_used = std.time.timestamp();
                self.idle_connections.append(self.allocator, released_conn) catch {};
            } else {
                if (conn.stream) |stream| {
                    stream.close();
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

    pub fn init(allocator: std.mem.Allocator, max_connections: usize, timeout_ms: u64) Self {
        return .{
            .allocator = allocator,
            .connection_pool = ConnectionPool.init(allocator, max_connections),
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
                    std.time.sleep(delay * std.time.ns_per_ms);
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
            try stream.writeAll(request_line);

            // 发送 headers
            var iter = req.headers.iterator();
            while (iter.next()) |entry| {
                const header_line = try std.fmt.allocPrint(self.allocator, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                defer self.allocator.free(header_line);
                try stream.writeAll(header_line);
            }

            try stream.writeAll("\r\n");

            // 发送 body
            if (req.body) |body| {
                try stream.writeAll(body);
            }

            // 读取响应（简化实现）
            var response = HttpResponse.init(self.allocator);
            response.status_code = 200; // 简化
            response.body = try self.allocator.dupe(u8, "OK");

            conn.request_count += 1;
            return response;
        }

        return error.ConnectionError;
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
