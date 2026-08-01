const std = @import("std");
const Time = @import("../core/Time.zig");
const sockread = @import("../core/sockread.zig");

/// HTTP client with connection pool and retry
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
                // Simplified: check timeout
                const now = Time.monotonicNowSeconds();
                return (now - self.last_used) < 30; // 30-second timeout
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
            self.* = undefined;
        }

        pub fn acquire(self: *ConnectionPool, host: []const u8, port: u16) !Connection {
            self.mutex.lock(self.io) catch return error.ServerError;
            defer self.mutex.unlock(self.io);

            // Find idle connection
            for (self.idle_connections.items, 0..) |conn, i| {
                if (std.mem.eql(u8, conn.host, host) and conn.port == port and conn.isAlive()) {
                    const connection = self.idle_connections.swapRemove(i);
                    try self.active_connections.append(self.allocator, connection);
                    return connection;
                }
            }

            // Create new connection
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
                .created_at = Time.monotonicNowSeconds(),
                .last_used = Time.monotonicNowSeconds(),
                .request_count = 0,
            };

            try self.active_connections.append(self.allocator, conn);
            return conn;
        }

        pub fn release(self: *ConnectionPool, conn: Connection) void {
            self.mutex.lock(self.io) catch return;
            defer self.mutex.unlock(self.io);

            // Remove from active connections
            for (self.active_connections.items, 0..) |active_conn, i| {
                if (active_conn.stream != null and conn.stream != null and active_conn.stream.?.socket.handle == conn.stream.?.socket.handle) {
                    _ = self.active_connections.swapRemove(i);
                    break;
                }
            }

            // Return to idle pool if still alive
            if (conn.isAlive()) {
                var released_conn = conn;
                released_conn.last_used = Time.monotonicNowSeconds();
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
            self.* = undefined;
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
            self.* = undefined;
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
        self.* = undefined;
    }

    const Target = struct {
        host: []const u8,
        port: u16,
        path: []const u8,
        is_tls: bool,
    };

    /// Send HTTP(S) request (with retry). HTTPS uses `std.http.Client` (TLS 1.3).
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

    pub fn parseTarget(url: []const u8, host_buf: *[256]u8, path_buf: *[4096]u8) !Target {
        const parsed_url = try std.Uri.parse(url);
        const is_https = std.ascii.eqlIgnoreCase(parsed_url.scheme, "https");
        const is_http = std.ascii.eqlIgnoreCase(parsed_url.scheme, "http");
        if (!is_https and !is_http) return error.UnsupportedScheme;

        const host_component = parsed_url.host orelse return error.InvalidUrl;
        const host = host_component.toRaw(host_buf) catch return error.InvalidUrl;
        const port: u16 = if (parsed_url.port) |p|
            if (p <= std.math.maxInt(u16)) @intCast(p) else return error.InvalidPort
        else if (is_https)
            443
        else
            80;

        var path_tmp: [2048]u8 = undefined;
        const path_only_raw = parsed_url.path.toRaw(&path_tmp) catch "/";
        const path_base: []const u8 = if (path_only_raw.len == 0) "/" else path_only_raw;

        if (parsed_url.query) |qcomp| {
            var qbuf: [2048]u8 = undefined;
            const qstr = qcomp.toRaw(&qbuf) catch return error.InvalidUrl;
            const full = std.fmt.bufPrint(path_buf, "{s}?{s}", .{ path_base, qstr }) catch return error.InvalidUrl;
            return .{ .host = host, .port = port, .path = full, .is_tls = is_https };
        }
        if (path_base.len > path_buf.len) return error.InvalidUrl;
        @memcpy(path_buf[0..path_base.len], path_base);
        return .{ .host = host, .port = port, .path = path_buf[0..path_base.len], .is_tls = is_https };
    }

    fn parseMethod(method: []const u8) std.http.Method {
        if (std.ascii.eqlIgnoreCase(method, "GET")) return .GET;
        if (std.ascii.eqlIgnoreCase(method, "POST")) return .POST;
        if (std.ascii.eqlIgnoreCase(method, "PUT")) return .PUT;
        if (std.ascii.eqlIgnoreCase(method, "DELETE")) return .DELETE;
        if (std.ascii.eqlIgnoreCase(method, "PATCH")) return .PATCH;
        if (std.ascii.eqlIgnoreCase(method, "HEAD")) return .HEAD;
        return .GET;
    }

    /// HTTPS via std.http.Client (system CA bundle + TLS 1.3). Not pooled.
    fn executeHttps(self: *Self, req: HttpRequest) !HttpResponse {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.connection_pool.io };
        defer client.deinit();

        var header_list = std.ArrayList(std.http.Header).empty;
        defer header_list.deinit(self.allocator);
        var iter = req.headers.iterator();
        while (iter.next()) |entry| {
            try header_list.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = req.url },
            .method = parseMethod(req.method),
            .payload = req.body,
            .extra_headers = header_list.items,
            .response_writer = &aw.writer,
            .keep_alive = false,
        }) catch |err| return mapHttpsError(err);

        var resp = HttpResponse.init(self.allocator);
        errdefer resp.deinit();
        resp.status_code = @intFromEnum(result.status);
        resp.body = try aw.toOwnedSlice();
        return resp;
    }

    /// HTTPS incremental body stream via std.http.Client (read loop → on_chunk).
    fn executeHttpsStream(self: *Self, req: HttpRequest, cb_ctx: *anyopaque, on_chunk: OnBodyChunk) !HttpResponse {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.connection_pool.io };
        defer client.deinit();

        var header_list = std.ArrayList(std.http.Header).empty;
        defer header_list.deinit(self.allocator);
        var iter = req.headers.iterator();
        while (iter.next()) |entry| {
            try header_list.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        const uri = std.Uri.parse(req.url) catch return error.InvalidUrl;
        var https_req = client.request(parseMethod(req.method), uri, .{
            .extra_headers = header_list.items,
            .keep_alive = false,
        }) catch |err| return mapHttpsError(err);
        defer https_req.deinit();

        if (req.body) |body| {
            const body_owned = try self.allocator.dupe(u8, body);
            defer self.allocator.free(body_owned);
            https_req.sendBodyComplete(body_owned) catch |err| return mapHttpsError(err);
        } else {
            https_req.sendBodiless() catch |err| return mapHttpsError(err);
        }

        var response = https_req.receiveHead(&.{}) catch |err| return mapHttpsError(err);

        var resp = HttpResponse.init(self.allocator);
        errdefer resp.deinit();
        resp.status_code = @intFromEnum(response.head.status);
        resp.body = try self.allocator.dupe(u8, "");

        var transfer_buf: [4096]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        var chunk_buf: [8192]u8 = undefined;
        while (true) {
            const n = body_reader.readSliceShort(&chunk_buf) catch |err| switch (err) {
                error.ReadFailed => {
                    if (response.bodyErr()) |be| return mapHttpsError(be);
                    return error.ConnectionError;
                },
                else => |e| return e,
            };
            if (n == 0) break;
            try on_chunk(cb_ctx, chunk_buf[0..n]);
        }
        return resp;
    }

    fn mapHttpsError(err: anyerror) anyerror {
        const name = @errorName(err);
        if (std.mem.indexOf(u8, name, "Certificate") != null or
            std.mem.indexOf(u8, name, "Tls") != null or
            std.mem.eql(u8, name, "CertificateBundleLoadFailure"))
        {
            return error.TlsHandshakeFailed;
        }
        if (std.mem.eql(u8, name, "ConnectionRefused")) return error.ConnectionRefused;
        if (std.mem.eql(u8, name, "NetworkUnreachable")) return error.NetworkUnreachable;
        if (std.mem.indexOf(u8, name, "Host") != null or
            std.mem.indexOf(u8, name, "Name") != null or
            std.mem.eql(u8, name, "UnknownHostName"))
        {
            return error.DnsFailed;
        }
        if (std.mem.eql(u8, name, "ConnectionTimedOut") or std.mem.eql(u8, name, "Timeout")) {
            return error.Timeout;
        }
        return error.ConnectionError;
    }

    fn executeRequest(self: *Self, req: HttpRequest) !HttpResponse {
        var host_buf: [256]u8 = undefined;
        var path_buf: [4096]u8 = undefined;
        const target = try parseTarget(req.url, &host_buf, &path_buf);
        if (target.is_tls) return self.executeHttps(req);

        var conn = try self.connection_pool.acquire(target.host, target.port);
        defer self.connection_pool.release(conn);

        if (conn.stream) |stream| {
            var write_buf: [4096]u8 = undefined;
            var w = stream.writer(self.connection_pool.io, &write_buf);
            try self.writeRequestHeaders(&w, req.method, target.path, target.host, target.port, &req.headers, req.body);
            // Buffered writer: the request must reach the peer before we start
            // reading the response, otherwise both sides deadlock forever.
            try w.interface.flush();
            const response = try self.readResponse(stream);
            conn.request_count += 1;
            return response;
        }

        return error.ConnectionError;
    }

    /// Wait up to `timeout_ms` for the socket to become readable so
    /// `request()` cannot block indefinitely against a peer that never
    /// responds. `timeout_ms == 0` disables the timeout.
    fn waitForReadable(fd: std.posix.socket_t, timeout_ms: u64) !void {
        if (timeout_ms == 0) return;
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const capped: i32 = @intCast(@min(timeout_ms, std.math.maxInt(i32)));
        const n = std.posix.poll(&fds, capped) catch return error.Timeout;
        if (n == 0) return error.Timeout;
    }

    fn writeRequestHeaders(
        self: *Self,
        w: anytype,
        method: []const u8,
        path: []const u8,
        host: []const u8,
        port: u16,
        headers: *const std.StringHashMap([]const u8),
        body: ?[]const u8,
    ) !void {
        const request_line = try std.fmt.allocPrint(self.allocator, "{s} {s} HTTP/1.1\r\n", .{ method, path });
        defer self.allocator.free(request_line);
        _ = w.interface.writeAll(request_line) catch return error.ConnectionError;

        var has_host = false;
        var has_content_length = false;
        var iter = headers.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "host")) has_host = true;
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "content-length")) has_content_length = true;
            const header_line = try std.fmt.allocPrint(self.allocator, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            defer self.allocator.free(header_line);
            _ = w.interface.writeAll(header_line) catch return error.ConnectionError;
        }

        if (!has_host) {
            const host_line = if (port == 80 or port == 443)
                try std.fmt.allocPrint(self.allocator, "Host: {s}\r\n", .{host})
            else
                try std.fmt.allocPrint(self.allocator, "Host: {s}:{d}\r\n", .{ host, port });
            defer self.allocator.free(host_line);
            _ = w.interface.writeAll(host_line) catch return error.ConnectionError;
        }

        if (!has_content_length) {
            const len = if (body) |b| b.len else 0;
            const cl = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n", .{len});
            defer self.allocator.free(cl);
            _ = w.interface.writeAll(cl) catch return error.ConnectionError;
        }

        _ = w.interface.writeAll("\r\n") catch return error.ConnectionError;
        if (body) |b| {
            if (b.len > 0) _ = w.interface.writeAll(b) catch return error.ConnectionError;
        }
    }

    fn readResponse(self: *Self, stream: std.Io.net.Stream) !HttpResponse {
        var resp = HttpResponse.init(self.allocator);
        errdefer resp.deinit();

        var buf: [8192]u8 = undefined;

        try waitForReadable(stream.socket.handle, self.timeout_ms);
        const n = std.posix.read(stream.socket.handle, &buf) catch return error.ConnectionError;
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
            try waitForReadable(stream.socket.handle, self.timeout_ms);
            const more = std.posix.read(stream.socket.handle, &buf) catch return error.ConnectionError;
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

    /// Callback for streamed response body (decoded chunk payload, not raw TCP framing).
    pub const OnBodyChunk = *const fn (ctx: *anyopaque, chunk: []const u8) anyerror!void;

    /// Send HTTP request and stream the response body via `on_chunk` (no retry — streams are not idempotent).
    /// Returned `HttpResponse.body` is empty; status/headers are filled. Caller still owns `deinit`.
    pub fn requestStream(self: *Self, req: HttpRequest, cb_ctx: *anyopaque, on_chunk: OnBodyChunk) !HttpResponse {
        return self.executeRequestStream(req, cb_ctx, on_chunk);
    }

    fn executeRequestStream(self: *Self, req: HttpRequest, cb_ctx: *anyopaque, on_chunk: OnBodyChunk) !HttpResponse {
        var host_buf: [256]u8 = undefined;
        var path_buf: [4096]u8 = undefined;
        const target = try parseTarget(req.url, &host_buf, &path_buf);
        if (target.is_tls) {
            return self.executeHttpsStream(req, cb_ctx, on_chunk);
        }

        var conn = try self.connection_pool.acquire(target.host, target.port);
        defer self.connection_pool.release(conn);

        if (conn.stream) |stream| {
            var write_buf: [4096]u8 = undefined;
            var w = stream.writer(self.connection_pool.io, &write_buf);
            try self.writeRequestHeaders(&w, req.method, target.path, target.host, target.port, &req.headers, req.body);
            const response = try self.readResponseStreaming(stream, cb_ctx, on_chunk);
            conn.request_count += 1;
            return response;
        }
        return error.ConnectionError;
    }

    fn readResponseStreaming(self: *Self, stream: std.Io.net.Stream, cb_ctx: *anyopaque, on_chunk: OnBodyChunk) !HttpResponse {
        var resp = HttpResponse.init(self.allocator);
        errdefer resp.deinit();

        var buf: [8192]u8 = undefined;

        const n = try sockread.readSome(stream, &buf);
        if (n == 0) return error.ConnectionError;
        const raw = buf[0..n];

        const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidResponse;
        const head = raw[0..header_end];
        const body_start = header_end + 4;

        var line_it = std.mem.splitSequence(u8, head, "\r\n");
        const status_line = line_it.next() orelse return error.InvalidResponse;
        var parts = std.mem.splitScalar(u8, status_line, ' ');
        _ = parts.next() orelse return error.InvalidResponse;
        const status_str = parts.next() orelse return error.InvalidResponse;
        resp.status_code = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidResponse;

        var content_length: ?usize = null;
        var chunked = false;
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
                content_length = std.fmt.parseInt(usize, val_trim, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(key_trim, "transfer-encoding")) {
                if (containsIgnoreCaseAscii(val_trim, "chunked")) chunked = true;
            }
        }

        resp.body = try self.allocator.dupe(u8, "");
        const initial = raw[body_start..];

        if (chunked) {
            try streamChunkedBody(stream, &buf, initial, self.allocator, cb_ctx, on_chunk);
        } else if (content_length) |cl| {
            try streamContentLengthBody(stream, &buf, initial, cl, cb_ctx, on_chunk);
        } else {
            try streamUntilEofBody(stream, &buf, initial, cb_ctx, on_chunk);
        }
        return resp;
    }

    /// Decode a complete chunked-transfer buffer into contiguous body (unit-test helper).
    pub fn decodeChunkedBuffer(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < data.len) {
            const line_end = std.mem.indexOfPos(u8, data, i, "\r\n") orelse return error.InvalidChunked;
            const size = std.fmt.parseInt(usize, data[i..line_end], 16) catch return error.InvalidChunked;
            i = line_end + 2;
            if (size == 0) break;
            if (i + size + 2 > data.len) return error.IncompleteChunked;
            try out.appendSlice(allocator, data[i .. i + size]);
            i += size + 2;
        }
        return try out.toOwnedSlice(allocator);
    }

    /// GET [...]
    pub fn get(self: *Self, url: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "GET", url);
        defer req.deinit();
        return self.request(req);
    }

    /// POST [...]
    pub fn post(self: *Self, url: []const u8, body: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "POST", url);
        defer req.deinit();
        try req.setBody(body);
        try req.setHeader("Content-Type", "application/json");
        return self.request(req);
    }

    /// PUT [...]
    pub fn put(self: *Self, url: []const u8, body: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "PUT", url);
        defer req.deinit();
        try req.setBody(body);
        try req.setHeader("Content-Type", "application/json");
        return self.request(req);
    }

    /// DELETE [...]
    pub fn delete(self: *Self, url: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "DELETE", url);
        defer req.deinit();
        return self.request(req);
    }
};

fn containsIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn streamContentLengthBody(
    stream: std.Io.net.Stream,
    buf: []u8,
    initial: []const u8,
    content_length: usize,
    cb_ctx: *anyopaque,
    on_chunk: HttpClient.OnBodyChunk,
) !void {
    var copied: usize = 0;
    if (initial.len > 0 and content_length > 0) {
        const n = @min(initial.len, content_length);
        if (n > 0) try on_chunk(cb_ctx, initial[0..n]);
        copied = n;
    }
    while (copied < content_length) {
        const more = try sockread.readSome(stream, buf);
        if (more == 0) return error.IncompleteBody;
        const to_copy = @min(@as(usize, more), content_length - copied);
        try on_chunk(cb_ctx, buf[0..to_copy]);
        copied += to_copy;
    }
}

fn streamUntilEofBody(
    stream: std.Io.net.Stream,
    buf: []u8,
    initial: []const u8,
    cb_ctx: *anyopaque,
    on_chunk: HttpClient.OnBodyChunk,
) !void {
    if (initial.len > 0) try on_chunk(cb_ctx, initial);
    while (true) {
        const more = try sockread.readSome(stream, buf);
        if (more == 0) break;
        try on_chunk(cb_ctx, buf[0..more]);
    }
}

fn streamChunkedBody(
    stream: std.Io.net.Stream,
    buf: []u8,
    initial: []const u8,
    allocator: std.mem.Allocator,
    cb_ctx: *anyopaque,
    on_chunk: HttpClient.OnBodyChunk,
) !void {
    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);
    try carry.appendSlice(allocator, initial);

    while (true) {
        while (std.mem.indexOf(u8, carry.items, "\r\n") == null) {
            const more = try sockread.readSome(stream, buf);
            if (more == 0) return error.IncompleteChunked;
            try carry.appendSlice(allocator, buf[0..more]);
        }
        const line_end = std.mem.indexOf(u8, carry.items, "\r\n").?;
        const size = std.fmt.parseInt(usize, carry.items[0..line_end], 16) catch return error.InvalidChunked;
        const after_line = line_end + 2;
        // Drop size line
        const rest_len = carry.items.len - after_line;
        std.mem.copyForwards(u8, carry.items[0..rest_len], carry.items[after_line..]);
        try carry.resize(allocator, rest_len);

        if (size == 0) return;

        while (carry.items.len < size + 2) {
            const more = try sockread.readSome(stream, buf);
            if (more == 0) return error.IncompleteChunked;
            try carry.appendSlice(allocator, buf[0..more]);
        }
        try on_chunk(cb_ctx, carry.items[0..size]);
        const after_data = size + 2;
        const rem = carry.items.len - after_data;
        std.mem.copyForwards(u8, carry.items[0..rem], carry.items[after_data..]);
        try carry.resize(allocator, rem);
    }
}

test "HttpClient decodeChunkedBuffer" {
    const a = std.testing.allocator;
    const raw = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
    const body = try HttpClient.decodeChunkedBuffer(a, raw);
    defer a.free(body);
    try std.testing.expectEqualStrings("hello world", body);
}

test "HttpClient parseTarget https defaults to 443" {
    var host_buf: [256]u8 = undefined;
    var path_buf: [4096]u8 = undefined;
    const t = try HttpClient.parseTarget("https://api.example.com/v1/chat", &host_buf, &path_buf);
    try std.testing.expect(t.is_tls);
    try std.testing.expectEqual(@as(u16, 443), t.port);
    try std.testing.expectEqualStrings("api.example.com", t.host);
    try std.testing.expectEqualStrings("/v1/chat", t.path);
}

test "HttpClient parseTarget http path and query" {
    var host_buf: [256]u8 = undefined;
    var path_buf: [4096]u8 = undefined;
    const t = try HttpClient.parseTarget("http://api.local:8080/v1/chat?x=1", &host_buf, &path_buf);
    try std.testing.expectEqualStrings("api.local", t.host);
    try std.testing.expectEqual(@as(u16, 8080), t.port);
    try std.testing.expectEqualStrings("/v1/chat?x=1", t.path);
}

test "HttpClient RetryPolicy calculateDelay" {
    const policy = HttpClient.RetryPolicy.default();
    try std.testing.expectEqual(@as(u64, 100), policy.calculateDelay(0));
    try std.testing.expectEqual(@as(u64, 200), policy.calculateDelay(1));
    try std.testing.expectEqual(@as(u64, 400), policy.calculateDelay(2));
}

test "HttpClient ConnectionPool acquire and release" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // Real loopback listener so acquire() gets an actual connection.
    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    var pool = HttpClient.ConnectionPool.init(allocator, std.testing.io, 2);
    defer pool.deinit();

    // Acquire new connection.
    const conn = try pool.acquire("127.0.0.1", port);
    try std.testing.expectEqualStrings("127.0.0.1", conn.host);
    try std.testing.expectEqual(port, conn.port);

    // Release back to pool.
    pool.release(conn);

    // Reacquire should reuse the idle connection.
    const conn2 = try pool.acquire("127.0.0.1", port);
    try std.testing.expectEqualStrings("127.0.0.1", conn2.host);
    try std.testing.expectEqual(port, conn2.port);
    try std.testing.expect(conn2.stream.?.socket.handle == conn.stream.?.socket.handle);

    pool.release(conn2);
}

test "HttpClient ConnectionPool exhaustion" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    var pool = HttpClient.ConnectionPool.init(allocator, std.testing.io, 1);
    defer pool.deinit();

    const conn = try pool.acquire("127.0.0.1", port);
    const result = pool.acquire("127.0.0.1", port);
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

test "HttpClient live request against loopback listener" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    // Serve one request: read until end of headers, then reply and close.
    // The socket read timeout keeps the test bounded if the request never
    // arrives (regression guard for the missing flush bug).
    const ServerCtx = struct {
        server: *std.Io.net.Server,
        fn run(ctx: *@This()) void {
            const accepted = ctx.server.accept(std.testing.io) catch return;
            defer accepted.close(std.testing.io);

            var total: usize = 0;
            var seen: [4096]u8 = undefined;
            while (total < seen.len) {
                // Raw reads keep this thread independent of the io scheduler
                // (spawned-thread io reads can stall on some Io backends).
                HttpClient.waitForReadable(accepted.socket.handle, 3000) catch break;
                const n = std.posix.read(accepted.socket.handle, seen[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, seen[0..total], "\r\n\r\n") != null) break;
            }

            const resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
            _ = std.posix.system.write(accepted.socket.handle, resp.ptr, resp.len);
        }
    };

    var server_ctx = ServerCtx{ .server = &server };
    const th = try std.Thread.spawn(.{}, ServerCtx.run, .{&server_ctx});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/echo", .{port});

    var client = HttpClient.init(allocator, std.testing.io, 2, 3000);
    defer client.deinit();
    var req = HttpClient.HttpRequest.init(allocator, "GET", url);
    defer req.deinit();

    var resp = try client.request(req);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("OK", resp.body);
}

test "HttpClient request times out against a stalled peer" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    // Accept, read the request, then never send a response (stalled peer).
    // The thread only exits when the client gives up and closes the socket.
    const StallCtx = struct {
        server: *std.Io.net.Server,
        fn run(ctx: *@This()) void {
            const accepted = ctx.server.accept(std.testing.io) catch return;
            defer accepted.close(std.testing.io);
            var total: usize = 0;
            var seen: [4096]u8 = undefined;
            while (total < seen.len) {
                HttpClient.waitForReadable(accepted.socket.handle, 3000) catch break;
                const n = std.posix.read(accepted.socket.handle, seen[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, seen[0..total], "\r\n\r\n") != null) break;
            }
            var tail: [512]u8 = undefined;
            while (true) {
                const n = std.posix.read(accepted.socket.handle, &tail) catch break;
                if (n == 0) break;
            }
        }
    };

    var stall_ctx = StallCtx{ .server = &server };
    const th = try std.Thread.spawn(.{}, StallCtx.run, .{&stall_ctx});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/never", .{port});

    var client = HttpClient.init(allocator, std.testing.io, 2, 400);
    defer client.deinit();
    var req = HttpClient.HttpRequest.init(allocator, "GET", url);
    defer req.deinit();

    const err = client.request(req) catch |e| e;
    try std.testing.expectEqual(error.Timeout, err);
}
