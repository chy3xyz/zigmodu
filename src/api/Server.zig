//! HTTP API server for ZigModu
//!
//! Provides HTTP server with routing, middleware, and handlers.
//! Aligned with go-zero's rest package.

const std = @import("std");

/// HTTP method
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    /// Parse HTTP method from string. Uses first-char dispatch for O(1) fast path.
    pub fn fromString(s: []const u8) Method {
        if (s.len == 0) return .GET;
        return switch (s[0]) {
            'G' => if (s.len == 3 and s[1] == 'E' and s[2] == 'T') .GET else .GET,
            'P' => if (s.len >= 3) switch (s[1]) {
                'O' => if (s.len == 4 and s[2] == 'S' and s[3] == 'T') .POST else .GET,
                'U' => if (s.len == 3 and s[2] == 'T') .PUT else .GET,
                'A' => if (s.len == 5 and s[2] == 'T' and s[3] == 'C' and s[4] == 'H') .PATCH else .GET,
                else => .GET,
            } else .GET,
            'D' => if (s.len == 6 and s[1] == 'E' and s[2] == 'L' and s[3] == 'E' and s[4] == 'T' and s[5] == 'E') .DELETE else .GET,
            'H' => if (s.len == 4 and s[1] == 'E' and s[2] == 'A' and s[3] == 'D') .HEAD else .GET,
            'O' => if (s.len == 7 and s[1] == 'P' and s[2] == 'T' and s[3] == 'I' and s[4] == 'O' and s[5] == 'N' and s[6] == 'S') .OPTIONS else .GET,
            else => .GET,
        };
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
        };
    }
};

/// HTTP handler function type
pub const HandlerFn = *const fn (*Context) anyerror!void;

/// Middleware function type with optional user data
pub const MiddlewareFn = *const fn (*Context, HandlerFn, ?*anyopaque) anyerror!void;

/// Middleware wrapper with optional state
pub const Middleware = struct {
    func: MiddlewareFn,
    user_data: ?*anyopaque = null,
};

/// Route definition
pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: HandlerFn,
    middleware: []const Middleware = &.{},
    user_data: ?*anyopaque = null,
    /// Pre-computed global + route-specific middleware chain.
    /// Set by addRoute() — do not set manually.
    combined_middleware: []const Middleware = &.{},
};

/// Route group helper to prefix paths.
pub const RouteGroup = struct {
    server: *Server,
    prefix: []const u8,

    pub fn init(server: *Server, prefix: []const u8) RouteGroup {
        return .{ .server = server, .prefix = prefix };
    }

    fn joinPath(self: *const RouteGroup, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        // Ensure exactly one '/' between prefix and path.
        const pfx = self.prefix;
        const needs_sep = pfx.len > 0 and pfx[pfx.len - 1] != '/' and (path.len == 0 or path[0] != '/');
        const drop_dup = pfx.len > 0 and pfx[pfx.len - 1] == '/' and path.len > 0 and path[0] == '/';

        if (drop_dup) {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ pfx, path[1..] });
        }
        if (needs_sep) {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ pfx, path });
        }
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ pfx, path });
    }

    fn add(self: *RouteGroup, method: Method, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        const full_path = try self.joinPath(self.server.allocator, path);
        defer self.server.allocator.free(full_path);

        try self.server.addRoute(.{
            .method = method,
            .path = full_path,
            .handler = handler,
            .user_data = user_data,
        });
    }

    pub fn get(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.GET, path, handler, user_data);
    }
    pub fn post(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.POST, path, handler, user_data);
    }
    pub fn put(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.PUT, path, handler, user_data);
    }
    pub fn delete(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.DELETE, path, handler, user_data);
    }
    pub fn patch(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.PATCH, path, handler, user_data);
    }
    pub fn head(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.HEAD, path, handler, user_data);
    }
    pub fn options(self: *RouteGroup, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.OPTIONS, path, handler, user_data);
    }
};

/// Field source for auto parameter binding
pub const FieldSource = enum {
    path,
    query,
    form,
    header,
};

/// HTTP context - holds request/response data
pub const Context = struct {
    allocator: std.mem.Allocator,
    method: Method,
    path: []const u8,
    raw_path: []const u8,
    query: std.StringHashMap([]const u8),
    params: std.StringHashMap([]const u8),
    headers: std.StringHashMap([]const u8),
    form: ?std.StringHashMap([]const u8) = null,
    body: ?[]const u8 = null,
    response_body: std.ArrayList(u8),
    status_code: u16 = 200,
    response_headers: std.StringHashMap([]const u8),
    responded: bool = false,
    user_data: ?*anyopaque = null,
    attributes: std.StringHashMap([]const u8),
    validation_error_message: ?[]const u8 = null,
    stream: ?std.Io.net.Stream = null,
    io: ?std.Io = null,
    streaming: bool = false,
    upgraded: bool = false,

    // Middleware chain fields
    chain_middlewares: []const Middleware = &.{},
    chain_handler: *const fn (*Context) anyerror!void = undefined,
    chain_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, method: Method, path: []const u8) !Context {
        return Context{
            .allocator = allocator,
            .method = method,
            .path = path,
            .raw_path = path,
            .query = std.StringHashMap([]const u8).init(allocator),
            .params = std.StringHashMap([]const u8).init(allocator),
            .headers = std.StringHashMap([]const u8).init(allocator),
            .response_body = std.ArrayList(u8).empty,
            .response_headers = std.StringHashMap([]const u8).init(allocator),
            .attributes = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        var query_iter = self.query.iterator();
        while (query_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.query.deinit();

        var params_iter = self.params.iterator();
        while (params_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();

        var headers_iter = self.headers.iterator();
        while (headers_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        if (self.form) |*f| {
            var form_iter = f.iterator();
            while (form_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            f.deinit();
        }

        self.response_body.deinit(self.allocator);

        var resp_headers_iter = self.response_headers.iterator();
        while (resp_headers_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.response_headers.deinit();

        if (self.validation_error_message) |msg| {
            self.allocator.free(msg);
        }

        var attr_it = self.attributes.iterator();
        while (attr_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.attributes.deinit();
    }

    /// Store an attribute on the context (for middleware data passing).
    pub fn setAttr(self: *Context, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, value);
        try self.attributes.put(k, v);
    }

    /// Retrieve an attribute from the context.
    pub fn getAttr(self: *const Context, key: []const u8) ?[]const u8 {
        return self.attributes.get(key);
    }

    /// Get query parameter
    pub fn queryParam(self: *const Context, key: []const u8) ?[]const u8 {
        return self.query.get(key);
    }

    /// Get path parameter
    pub fn param(self: *const Context, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    /// Path parameter as integer (generic). Returns error.BadRequest if missing/invalid.
    pub fn paramInt(self: *const Context, comptime T: type, key: []const u8) !T {
        const v = self.params.get(key) orelse return error.BadRequest;
        return std.fmt.parseInt(T, v, 10) catch error.BadRequest;
    }

    /// Path parameter as string (required).
    pub fn paramStr(self: *const Context, key: []const u8) ![]const u8 {
        return self.params.get(key) orelse error.BadRequest;
    }

    /// Query parameter as integer with default.
    pub fn queryInt(self: *const Context, comptime T: type, key: []const u8, default: T) T {
        const val = self.query.get(key) orelse return default;
        return std.fmt.parseInt(T, val, 10) catch default;
    }

    /// Query parameter as string with default.
    pub fn queryStr(self: *const Context, key: []const u8, default: []const u8) []const u8 {
        return self.query.get(key) orelse default;
    }

    /// Get header
    pub fn header(self: *const Context, key: []const u8) ?[]const u8 {
        return self.headers.get(key);
    }

    /// Get form value
    pub fn formValue(self: *const Context, key: []const u8) ?[]const u8 {
        return if (self.form) |f| f.get(key) else null;
    }

    /// Set response header
    pub fn setHeader(self: *Context, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        // Free previous entry if key already exists to avoid leak
        if (self.response_headers.getEntry(key_copy)) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        try self.response_headers.put(key_copy, value_copy);
    }

    /// Type-safe accessor for user_data. Replaces @ptrCast(@alignCast(...)).
    pub fn userData(self: *Context, comptime T: type) ?*T {
        return @ptrCast(@alignCast(self.user_data));
    }

    /// Stream a chunk of the response body. Call flushHeaders() first to send
    /// status line + headers, then call writeBody() for each chunk. This avoids
    /// buffering the entire response in memory for large payloads.
    pub fn writeBody(self: *Context, data: []const u8) !void {
        try self.response_body.appendSlice(self.allocator, data);
    }

    /// Mark headers as flushed. After this, writeBody() appends data for
    /// chunked transfer (avoids buffering entire response in memory).
    pub fn flushHeaders(self: *Context) void {
        self.responded = true;
    }

    /// Start chunked transfer encoding for streaming large responses.
    /// Call writeChunk() for each chunk, then endStream() when done.
    /// If a direct stream is available, data goes straight to the socket
    /// without buffering in response_body.
    pub fn startChunked(self: *Context, status: u16, content_type: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Transfer-Encoding", "chunked");
        try self.setHeader("Content-Type", content_type);
        self.responded = true;
        self.streaming = true;
        // Flush status line + headers to socket immediately
        if (self.stream != null and self.io != null) {
            try self.flushHeadersToSocket();
        }
    }

    /// Write status line + headers directly to socket (for streamed responses).
    fn flushHeadersToSocket(self: *Context) !void {
        var write_buf: [4096]u8 = undefined;
        var w = self.stream.?.writer(self.io.?, &write_buf);
        var line_buf: [256]u8 = undefined;
        const status_text = getStatusText(self.status_code);
        const status_line = try std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} {s}\r\n", .{ self.status_code, status_text });
        try w.interface.writeAll(status_line);
        var hiter = self.response_headers.iterator();
        while (hiter.next()) |entry| {
            const header_line = try std.fmt.bufPrint(&line_buf, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            try w.interface.writeAll(header_line);
        }
        try w.interface.writeAll("\r\n");
        try w.interface.flush();
    }

    /// Write a chunk in chunked transfer encoding.
    /// Writes directly to socket when streaming, falls back to response_body buffer.
    pub fn writeChunk(self: *Context, data: []const u8) !void {
        if (self.stream != null and self.io != null) {
            var write_buf: [4096]u8 = undefined;
            var w = self.stream.?.writer(self.io.?, &write_buf);
            var size_buf: [32]u8 = undefined;
            const size_hex = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len});
            try w.interface.writeAll(size_hex);
            try w.interface.writeAll(data);
            try w.interface.writeAll("\r\n");
            try w.interface.flush();
            return;
        }
        const chunk_header = try std.fmt.allocPrint(self.allocator, "{x}\r\n", .{data.len});
        defer self.allocator.free(chunk_header);
        try self.response_body.appendSlice(self.allocator, chunk_header);
        try self.response_body.appendSlice(self.allocator, data);
        try self.response_body.appendSlice(self.allocator, "\r\n");
    }

    /// End chunked transfer encoding.
    /// Writes directly to socket when streaming, falls back to response_body buffer.
    pub fn endStream(self: *Context) !void {
        if (self.stream != null and self.io != null) {
            var write_buf: [4096]u8 = undefined;
            var w = self.stream.?.writer(self.io.?, &write_buf);
            try w.interface.writeAll("0\r\n\r\n");
            try w.interface.flush();
            return;
        }
        try self.response_body.appendSlice(self.allocator, "0\r\n\r\n");
    }

    /// Set JSON response
    pub fn json(self: *Context, status: u16, data: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        try self.response_body.appendSlice(self.allocator, data);
        self.responded = true;
    }

    /// Set plain text response
    pub fn text(self: *Context, status: u16, data: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "text/plain");
        try self.response_body.appendSlice(self.allocator, data);
        self.responded = true;
    }

    /// Send error response
    pub fn sendError(self: *Context, status: u16, message: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        const err_json = try std.fmt.allocPrint(self.allocator, "{{\"code\":{d},\"message\":\"{s}\"}}", .{ status, message });
        defer self.allocator.free(err_json);
        try self.response_body.appendSlice(self.allocator, err_json);
        self.responded = true;
    }

    /// Send structured error response
    pub fn sendErrorResponse(self: *Context, status: u16, code: i32, message: []const u8) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        const err_json = try std.fmt.allocPrint(self.allocator, "{{\"code\":{d},\"message\":\"{s}\"}}", .{ code, message });
        defer self.allocator.free(err_json);
        try self.response_body.appendSlice(self.allocator, err_json);
        self.responded = true;
    }

    /// Send success response with CommonResult wrapper: {"code":0,"msg":"","data":<data>}
    /// DEPRECATED: use ctx.json(200, data) instead.
    pub fn sendSuccess(self: *Context, data_json: []const u8) !void {
        self.status_code = 200;
        try self.setHeader("Content-Type", "application/json");
        const wrapped = try std.fmt.allocPrint(self.allocator, "{{\"code\":0,\"msg\":\"\",\"data\":{s}}}", .{data_json});
        defer self.allocator.free(wrapped);
        try self.response_body.appendSlice(self.allocator, wrapped);
        self.responded = true;
    }

    /// Send fail response with CommonResult wrapper: {"code":<code>,"msg":"<msg>","data":null}
    /// DEPRECATED: use ctx.json(status, body) instead.
    pub fn sendFail(self: *Context, code: u16, msg: []const u8) !void {
        self.status_code = 200;
        try self.setHeader("Content-Type", "application/json");
        const wrapped = try std.fmt.allocPrint(self.allocator, "{{\"code\":{d},\"msg\":\"{s}\",\"data\":null}}", .{ code, msg });
        defer self.allocator.free(wrapped);
        try self.response_body.appendSlice(self.allocator, wrapped);
        self.responded = true;
    }

    /// Send paginated response with CommonResult wrapper:
    /// {"code":0,"msg":"","data":{"list":<items>,"total":<total>}}
    /// DEPRECATED: use ctx.json(200, body) with pagination struct instead.
    pub fn sendPageResult(self: *Context, items_json: []const u8, total: usize) !void {
        self.status_code = 200;
        try self.setHeader("Content-Type", "application/json");
        const wrapped = try std.fmt.allocPrint(self.allocator, "{{\"code\":0,\"msg\":\"\",\"data\":{{\"list\":{s},\"total\":{d}}}}}", .{ items_json, total });
        defer self.allocator.free(wrapped);
        try self.response_body.appendSlice(self.allocator, wrapped);
        self.responded = true;
    }

    /// Convenience: serialize any Zig value as JSON array and wrap in page result.
    /// Usage: try ctx.sendPageItems(vo_slice.items, total);
    pub fn sendPageItems(self: *Context, items: anytype, total: usize) !void {
        const json_str = try std.fmt.allocPrint(self.allocator, "{any}", .{std.json.fmt(items, .{})});
        defer self.allocator.free(json_str);
        try self.sendPageResult(json_str, total);
    }

    /// Convenience: serialize any Zig value as JSON and wrap in success response.
    /// Usage: try ctx.sendJsonItems(vo_slice.items);
    /// DEPRECATED: use ctx.json(200, ...) instead.
    pub fn sendJsonItems(self: *Context, items: anytype) !void {
        const json_str = try std.fmt.allocPrint(self.allocator, "{any}", .{std.json.fmt(items, .{})});
        defer self.allocator.free(json_str);
        try self.sendSuccess(json_str);
    }

    /// Parse JSON body into type T. Deep-copies string fields so the
    /// returned value owns its memory (avoids use-after-free from arena).
    pub fn bindJson(self: *const Context, comptime T: type) !T {
        if (self.body == null) return error.NoBody;
        var parsed = std.json.parseFromSlice(T, self.allocator, self.body.?, .{}) catch return error.InvalidJson;
        defer parsed.deinit();
        // Deep-copy value to escape the parse arena lifetime
        return deepCopy(parsed.value, self.allocator);
    }

    /// Send JSON from struct.
    pub fn jsonStruct(self: *Context, status: u16, value: anytype) !void {
        self.status_code = status;
        try self.setHeader("Content-Type", "application/json");
        const json_str = try std.fmt.allocPrint(self.allocator, "{any}", .{std.json.fmt(value, .{})});
        defer self.allocator.free(json_str);
        try self.response_body.appendSlice(self.allocator, json_str);
        self.responded = true;
    }

    /// Auto-bind request parameters into a struct.
    /// `sources` maps struct field names to their HTTP source locations.
    /// Example: `const req = try ctx.parseReq(MyReq, .{ .id = .path, .page = .query });`
    pub fn parseReq(self: *Context, comptime T: type, sources: anytype) !T {
        const SourcesType = @TypeOf(sources);
        const sources_info = @typeInfo(SourcesType);
        if (sources_info != .@"struct") @compileError("sources must be a struct literal");

        var req: T = undefined;
        const t_info = @typeInfo(T);
        if (t_info != .@"struct") @compileError("T must be a struct");

        inline for (t_info.@"struct".fields) |field| {
            const has_source = @hasField(SourcesType, field.name);
            if (!has_source) continue;

            const source: FieldSource = @field(sources, field.name);
            const value_str: ?[]const u8 = switch (source) {
                .path => self.params.get(field.name),
                .query => self.query.get(field.name),
                .form => if (self.form) |f| f.get(field.name) else null,
                .header => self.headers.get(field.name),
            };

            if (value_str) |v| {
                @field(req, field.name) = try parseValue(field.type, v);
            } else {
                // If field is optional, leave as null
                if (@typeInfo(field.type) == .optional) {
                    @field(req, field.name) = null;
                } else {
                    return error.MissingParameter;
                }
            }
        }

        return req;
    }
};

fn parseValue(comptime T: type, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, value, 10),
        .float => std.fmt.parseFloat(T, value),
        .bool => std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"),
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) value else @compileError("Unsupported slice type in parseValue"),
            else => @compileError("Unsupported pointer type in parseValue"),
        },
        .optional => |opt| if (value.len == 0) null else try parseValue(opt.child, value),
        else => @compileError("Unsupported field type in parseValue"),
    };
}

fn parseFormBody(allocator: std.mem.Allocator, body: []const u8) !std.StringHashMap([]const u8) {
    var form = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var iter = form.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        form.deinit();
    }

    var iter = std.mem.splitScalar(u8, body, '&');
    while (iter.next()) |param| {
        if (param.len == 0) continue;
        if (std.mem.indexOf(u8, param, "=")) |eq_pos| {
            const key = try allocator.dupe(u8, param[0..eq_pos]);
            const value = try allocator.dupe(u8, param[eq_pos + 1 ..]);
            try form.put(key, value);
        }
    }

    return form;
}

/// Simple stream reader wrapper for HTTP parsing
/// Persistent buffered reader over a `std.Io.net.Stream`.
///
/// CRITICAL: the underlying `std.Io.net.Stream.Reader` owns an internal buffer.
/// We must keep a single instance across reads — otherwise its buffer state is
/// repeatedly reset and data from previous reads gets clobbered. The buffer is
/// owned by this struct and must be referenced *after* the struct has reached
/// its final memory location, which is why construction is a two-step process:
/// allocate uninitialized storage, then call `setup`.
const StreamReader = struct {
    reader: std.Io.net.Stream.Reader,
    buffer: [8192]u8 = undefined,

    fn setup(self: *StreamReader, stream: std.Io.net.Stream, io: std.Io) void {
        self.buffer = undefined;
        self.reader = std.Io.net.Stream.Reader.init(stream, io, &self.buffer);
    }

    /// Reads a single line terminated by `delimiter`. Returns a slice into the
    /// reader's internal buffer, valid only until the next read operation. The
    /// caller must copy any data that needs to outlive subsequent reads.
    ///
    /// Returns `null` if the peer closed cleanly with no bytes available
    /// (EOF on a fresh read), and propagates `error.ReadFailed` for actual
    /// I/O errors so the caller can distinguish benign close from failure.
    fn readUntilDelimiterOrEof(self: *StreamReader, _: []u8, delimiter: u8) !?[]u8 {
        return self.reader.interface.takeDelimiter(delimiter) catch |err| switch (err) {
            error.ReadFailed => error.ReadFailed,
            error.StreamTooLong => error.InvalidRequest,
        };
    }

    fn readAll(self: *StreamReader, out: []u8) !usize {
        self.reader.interface.readSliceAll(out) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => return 0,
        };
        return out.len;
    }
};

/// HTTP request parser
const RequestParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RequestParser {
        return .{ .allocator = allocator };
    }

    fn trimCrlf(line: []const u8) []const u8 {
        var out = line;
        while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) {
            out = out[0 .. out.len - 1];
        }
        return out;
    }

    pub fn parse(self: *RequestParser, reader: *StreamReader, max_body_size: usize) !ParsedRequest {
        var buffer: [8192]u8 = undefined;

        // Read request line. `takeDelimiter` returns a slice into the reader's
        // internal buffer, which gets invalidated on the next read (rebase).
        // Dupe it into the parser allocator so subsequent header reads don't
        // clobber the method/path slices we derive from it.
        //
        // A `null` result here means the peer closed before sending anything —
        // this is a benign end-of-connection, not a malformed request, so we
        // surface it as a distinct error the caller can ignore silently.
        const request_line_raw_view = try reader.readUntilDelimiterOrEof(&buffer, '\n') orelse return error.ClientClosed;
        const request_line_owned = try self.allocator.dupe(u8, trimCrlf(request_line_raw_view));
        const request_line = request_line_owned;
        if (request_line.len < 14) return error.InvalidRequest; // Minimum: "GET / HTTP/1.1"

        // Parse method
        const method_end = std.mem.indexOf(u8, request_line, " ") orelse return error.InvalidRequest;
        const method_str = request_line[0..method_end];
        const method = Method.fromString(method_str);

        // Parse path
        const path_start = method_end + 1;
        const path_end = std.mem.indexOfPos(u8, request_line, path_start, " ") orelse return error.InvalidRequest;
        const raw_path = request_line[path_start..path_end];

        // Parse query string
        var path = raw_path;
        var query_map = std.StringHashMap([]const u8).init(self.allocator);

        if (std.mem.indexOf(u8, raw_path, "?")) |query_start| {
            path = raw_path[0..query_start];
            const query_str = raw_path[query_start + 1 ..];

            var qiter = std.mem.splitScalar(u8, query_str, '&');
            while (qiter.next()) |param| {
                if (param.len == 0) continue;
                if (std.mem.indexOf(u8, param, "=")) |eq_pos| {
                    const key = try self.allocator.dupe(u8, param[0..eq_pos]);
                    const value = try self.allocator.dupe(u8, param[eq_pos + 1 ..]);
                    try query_map.put(key, value);
                }
            }
        }

        // Parse headers
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        while (true) {
            const line_raw = try reader.readUntilDelimiterOrEof(&buffer, '\n') orelse return error.InvalidRequest;
            const header_line = trimCrlf(line_raw);
            if (header_line.len == 0) break;

            if (std.mem.indexOf(u8, header_line, ": ")) |colon_pos| {
                const key_raw = try self.allocator.dupe(u8, header_line[0..colon_pos]);
                for (key_raw) |*c| c.* = std.ascii.toLower(c.*);
                const value = try self.allocator.dupe(u8, header_line[colon_pos + 2 ..]);
                try headers.put(key_raw, value);
            }
        }

        // Read body if Content-Length present
        var body: ?[]const u8 = null;
        if (headers.get("Content-Length")) |len_str| {
            const content_len = std.fmt.parseInt(usize, len_str, 10) catch {
                return error.InvalidContentLength;
            };
            if (content_len > max_body_size) return error.BodyTooLarge;
            if (content_len > 0) {
                const body_buf = try self.allocator.alloc(u8, content_len);
                const bytes_read = try reader.readAll(body_buf);
                if (bytes_read == content_len) {
                    body = body_buf;
                } else {
                    // Incomplete body read - connection closed or error
                    self.allocator.free(body_buf);
                    return error.IncompleteBody;
                }
            }
        }

        return ParsedRequest{
            .method = method,
            .path = path,
            .raw_path = raw_path,
            .query = query_map,
            .headers = headers,
            .body = body,
            ._request_line_buf = request_line_owned,
        };
    }
};

const ParsedRequest = struct {
    method: Method,
    path: []const u8,
    raw_path: []const u8,
    query: std.StringHashMap([]const u8),
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,
    /// Owned buffer that path and raw_path slice into.
    /// Freed by deinit() — do not free path/raw_path separately.
    _request_line_buf: []const u8,

    pub fn deinit(self: *ParsedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self._request_line_buf);

        var query_iter = self.query.iterator();
        while (query_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.query.deinit();

        var headers_iter = self.headers.iterator();
        while (headers_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        if (self.body) |b| allocator.free(b);
    }
};

/// Trie node for the router
const TrieNode = struct {
    segment: []const u8,
    is_param: bool,
    param_name: ?[]const u8,
    route: ?Route,
    children: std.ArrayList(*TrieNode),
    /// O(1) child lookup map, lazily built when children exceed MAP_THRESHOLD.
    child_map: ?std.StringHashMap(*TrieNode) = null,
    /// Cached pointer to the first param child (at most one per node).
    param_child: ?*TrieNode = null,

    const MAP_THRESHOLD: usize = 8;

    pub fn init(allocator: std.mem.Allocator, segment: []const u8) !*TrieNode {
        const node = try allocator.create(TrieNode);
        node.* = .{
            .segment = try allocator.dupe(u8, segment),
            .is_param = std.mem.startsWith(u8, segment, "{"),
            .param_name = null,
            .route = null,
            .children = std.ArrayList(*TrieNode).empty,
        };
        if (node.is_param) {
            const name = if (std.mem.endsWith(u8, segment, "}"))
                segment[1 .. segment.len - 1]
            else
                segment[1..];
            node.param_name = try allocator.dupe(u8, name);
        }
        return node;
    }

    pub fn deinit(self: *TrieNode, allocator: std.mem.Allocator) void {
        allocator.free(self.segment);
        if (self.param_name) |name| allocator.free(name);
        if (self.route) |route| {
            allocator.free(route.path);
            if (route.combined_middleware.len > 0) allocator.free(route.combined_middleware);
        }
        for (self.children.items) |child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
        if (self.child_map) |*map| {
            map.deinit();
        }
        allocator.destroy(self);
    }

    /// Insert a child and conditionally upgrade to HashMap lookup.
    pub fn addChild(self: *TrieNode, allocator: std.mem.Allocator, child: *TrieNode) !void {
        try self.children.append(allocator, child);

        // Track param child for O(1) access
        if (child.is_param and self.param_child == null) {
            self.param_child = child;
        }

        // Lazy upgrade to HashMap when children cross threshold
        if (self.children.items.len == MAP_THRESHOLD) {
            self.child_map = std.StringHashMap(*TrieNode).init(allocator);
            for (self.children.items) |c| {
                try self.child_map.?.put(c.segment, c);
            }
        } else if (self.child_map) |*map| {
            try map.put(child.segment, child);
        }
    }

    pub fn findChild(self: *const TrieNode, segment: []const u8) ?*TrieNode {
        if (self.child_map) |map| {
            return map.get(segment);
        }
        // Linear scan for small child counts (fast due to cache locality)
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.segment, segment)) return child;
        }
        return null;
    }

    pub fn findParamChild(self: *const TrieNode) ?*TrieNode {
        if (self.param_child) |pc| return pc;
        // Fallback: linear scan (should rarely be reached with addChild tracking)
        for (self.children.items) |child| {
            if (child.is_param) return child;
        }
        return null;
    }
};

/// Router for matching routes using a trie
const Router = struct {
    allocator: std.mem.Allocator,
    roots: std.AutoHashMap(Method, *TrieNode),
    wildcards: std.AutoHashMap(Method, Route),

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .allocator = allocator,
            .roots = std.AutoHashMap(Method, *TrieNode).init(allocator),
            .wildcards = std.AutoHashMap(Method, Route).init(allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        self.wildcards.deinit();
        var iter = self.roots.valueIterator();
        while (iter.next()) |root| {
            root.*.deinit(self.allocator);
        }
        self.roots.deinit();
    }

    pub fn addRoute(self: *Router, route: Route) !void {
        // Wildcard route: catch-all for any path under this method
        if (std.mem.eql(u8, route.path, "*")) {
            const path_copy = try self.allocator.dupe(u8, route.path);
            var r = route;
            r.path = path_copy;
            try self.wildcards.put(route.method, r);
            return;
        }

        const root = try self.getOrCreateRoot(route.method);

        var parts = std.mem.splitScalar(u8, route.path, '/');
        var current = root;

        while (parts.next()) |part| {
            if (part.len == 0) continue;

            if (current.findChild(part)) |child| {
                current = child;
            } else {
                const child = try TrieNode.init(self.allocator, part);
                try current.addChild(self.allocator, child);
                current = child;
            }
        }

        // Store route at the endpoint node
        const path_copy = try self.allocator.dupe(u8, route.path);
        var r = route;
        r.path = path_copy;
        current.route = r;
    }

    fn getOrCreateRoot(self: *Router, method: Method) !*TrieNode {
        if (self.roots.get(method)) |root| return root;
        const root = try TrieNode.init(self.allocator, "");
        try self.roots.put(method, root);
        return root;
    }

    /// 遍历 trie 树，收集所有已注册路由的 (method, path) 信息
    pub fn listRoutes(self: *const Router, alloc: std.mem.Allocator) ![]const RouteInfo {
        var result = std.ArrayList(RouteInfo).empty;

        var method_iter = self.roots.iterator();
        while (method_iter.next()) |entry| {
            const method = entry.key_ptr.*;
            const root = entry.value_ptr.*;
            try collectRoutes(root, method, "", alloc, &result);
        }

        return result.toOwnedSlice(alloc);
    }

    pub fn match(self: *const Router, allocator: std.mem.Allocator, method: Method, path: []const u8) ?MatchedRoute {
        const root = self.roots.get(method) orelse return null;

        const MAX_PARAMS = 8;
        var param_keys: [MAX_PARAMS][]const u8 = undefined;
        var param_vals: [MAX_PARAMS][]const u8 = undefined;
        var param_count: usize = 0;

        var parts = std.mem.splitScalar(u8, path, '/');
        var current = root;

        while (parts.next()) |part| {
            if (part.len == 0) continue;

            if (current.findChild(part)) |child| {
                current = child;
            } else if (current.findParamChild()) |param_child| {
                if (param_count >= MAX_PARAMS) return null;
                param_keys[param_count] = allocator.dupe(u8, param_child.param_name.?) catch return null;
                errdefer allocator.free(param_keys[param_count]);
                param_vals[param_count] = allocator.dupe(u8, part) catch {
                    allocator.free(param_keys[param_count]);
                    return null;
                };
                param_count += 1;
                current = param_child;
            } else {
                for (0..param_count) |i| {
                    allocator.free(param_keys[i]);
                    allocator.free(param_vals[i]);
                }
                return null;
            }
        }

        if (current.route) |route| {
            var params = std.StringHashMap([]const u8).init(allocator);
            for (0..param_count) |i| {
                params.put(param_keys[i], param_vals[i]) catch {
                    allocator.free(param_keys[i]);
                    allocator.free(param_vals[i]);
                };
            }
            return MatchedRoute{
                .route = route,
                .params = params,
            };
        }

        for (0..param_count) |i| {
            allocator.free(param_keys[i]);
            allocator.free(param_vals[i]);
        }
        if (self.wildcards.get(method)) |wc| {
            return MatchedRoute{ .route = wc, .params = std.StringHashMap([]const u8).init(allocator) };
        }
        return null;
    }
};

/// Lightweight route metadata for listing (no handler pointer)
pub const RouteInfo = struct {
    method: []const u8,
    path: []const u8,
};

/// Recursively traverse trie nodes to collect all route paths
fn collectRoutes(
    node: *const TrieNode,
    method: Method,
    prefix: []const u8,
    alloc: std.mem.Allocator,
    result: *std.ArrayList(RouteInfo),
) !void {
    if (node.route) |_| {
        const path = try std.fmt.allocPrint(alloc, "/{s}", .{prefix});
        defer alloc.free(path);
        try result.append(alloc, .{
            .method = try alloc.dupe(u8, method.toString()),
            .path = try alloc.dupe(u8, path),
        });
    }
    for (node.children.items) |child| {
        const sep = if (prefix.len > 0 and prefix[prefix.len - 1] != '/') "/" else "";
        const full = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ prefix, sep, child.segment });
        defer alloc.free(full);
        try collectRoutes(child, method, full, alloc, result);
    }
}

const MatchedRoute = struct {
    route: Route,
    params: std.StringHashMap([]const u8),
};

fn getStatusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

/// Write HTTP response directly to a `std.Io.net.Stream`.
/// Avoids intermediate ArrayList allocation — formats status line and headers
/// into small stack buffers and writes body directly from caller's buffer.
fn writeResponse(io: std.Io, stream: std.Io.net.Stream, status: u16, headers: std.StringHashMap([]const u8), body: []const u8) !void {
    var write_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &write_buf);

    var line_buf: [256]u8 = undefined;
    const status_text = getStatusText(status);

    // Status line
    const status_line = try std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} {s}\r\n", .{ status, status_text });
    try w.interface.writeAll(status_line);

    // Headers
    var hiter = headers.iterator();
    while (hiter.next()) |entry| {
        const header_line = try std.fmt.bufPrint(&line_buf, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        try w.interface.writeAll(header_line);
    }

    // Content-Length (skip for chunked transfer to avoid HTTP spec violation)
    if (headers.get("Transfer-Encoding") == null) {
        const cl_line = try std.fmt.bufPrint(&line_buf, "Content-Length: {d}\r\n", .{body.len});
        try w.interface.writeAll(cl_line);
    }
    try w.interface.writeAll("\r\n");

    // Body (already chunk-encoded if Transfer-Encoding: chunked)
    try w.interface.writeAll(body);
    try w.interface.flush();
}

/// HTTP server — async fiber-based
pub const Server = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    port: u16,
    router: Router,
    global_middleware: std.ArrayList(Middleware),
    name: []const u8,
    running: std.atomic.Value(bool),
    listener: ?std.Io.net.Server,
    listener_closing: std.atomic.Value(bool),
    conn_group: std.Io.Group,
    max_body_size: usize,
    request_timeout_ms: u32,
    max_requests_per_conn: usize,
    in_flight: ?*std.atomic.Value(u64) = null,

    pub const Config = struct {
        port: u16 = 8080,
        name: []const u8 = "zigmodu-api",
        max_body_size: usize = 8 * 1024 * 1024,
        request_timeout_ms: u32 = 30000,
        max_requests_per_conn: usize = 100,
    };

    pub fn init(io: std.Io, allocator: std.mem.Allocator, port: u16) Server {
        return Server.initWithConfig(io, allocator, .{ .port = port });
    }

    pub fn initWithConfig(io: std.Io, allocator: std.mem.Allocator, config: Config) Server {
        return .{
            .io = io,
            .allocator = allocator,
            .port = config.port,
            .router = Router.init(allocator),
            .global_middleware = std.ArrayList(Middleware).empty,
            .name = config.name,
            .running = std.atomic.Value(bool).init(false),
            .listener = null,
            .listener_closing = std.atomic.Value(bool).init(false),
            .conn_group = .init,
            .max_body_size = config.max_body_size,
            .request_timeout_ms = config.request_timeout_ms,
            .max_requests_per_conn = config.max_requests_per_conn,
        };
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
        self.global_middleware.deinit(self.allocator);
    }

    pub fn addRoute(self: *Server, route: Route) !void {
        var r = route;
        // Pre-compose global + route middleware so executeWithMiddleware
        // avoids alloc+memcpy+free per request.
        if (self.global_middleware.items.len > 0 or route.middleware.len > 0) {
            const total = self.global_middleware.items.len + route.middleware.len;
            const combined = try self.allocator.alloc(Middleware, total);
            @memcpy(combined[0..self.global_middleware.items.len], self.global_middleware.items);
            @memcpy(combined[self.global_middleware.items.len..], route.middleware);
            r.combined_middleware = combined;
        }
        try self.router.addRoute(r);
    }

    pub fn group(self: *Server, prefix: []const u8) RouteGroup {
        return RouteGroup.init(self, prefix);
    }

    /// List all registered routes (method + path pairs)
    pub fn listRoutes(self: *const Server, alloc: std.mem.Allocator) ![]const RouteInfo {
        return self.router.listRoutes(alloc);
    }

    pub fn addMiddleware(self: *Server, mw: Middleware) !void {
        try self.global_middleware.append(self.allocator, mw);
    }

    /// Wire the server into the Application's graceful-shutdown drain counter.
    /// When set, every request increments the counter on entry and decrements
    /// on completion so Application.run() can drain before stopping.
    pub fn withGracefulDrain(self: *Server, counter: *std.atomic.Value(u64)) void {
        self.in_flight = counter;
    }

    fn executeWithMiddleware(self: *Server, ctx: *Context, final_handler: HandlerFn, combined_middleware: []const Middleware) !void {
        _ = self;
        ctx.chain_middlewares = combined_middleware;
        ctx.chain_handler = final_handler;
        ctx.chain_index = 0;

        try runMiddlewareChain(ctx);
    }

    /// Start the async HTTP server.
    /// Blocks until stop() is called (runs within self.io scheduler).
    pub fn start(self: *Server) !void {
        const addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", self.port);
        self.listener = try addr.listen(self.io, .{
            .reuse_address = true,
        });
        // Only the path that first flips `listener_closing` to true is allowed
        // to call `deinit`. This prevents a double-close race between `stop()`
        // (called by user code) and this defer (triggered when the accept loop
        // exits because the fd was closed underneath it).
        defer self.closeListener();
        // Reap any still-running connection fibers on exit so their futures
        // are released. Await (not cancel) so in-flight requests complete.
        defer self.conn_group.await(self.io) catch {};

        self.running.store(true, .monotonic);
        std.log.info("Server listening on port {d}", .{self.port});

        while (self.running.load(.monotonic)) {
            const stream = (self.listener orelse break).accept(self.io) catch |err| {
                if (!self.running.load(.monotonic)) break;
                std.log.err("Accept error: {any}", .{err});
                continue;
            };

            self.conn_group.async(self.io, connFiber, .{ self, stream, self.allocator });
        }
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .monotonic);
        self.closeListener();
        self.listener_closing.store(false, .monotonic); // allow restart
    }

    /// Start the server in a background thread. Returns immediately.
    /// Call stop() to shut down. Use this when you need to start multiple
    /// services (HTTP + gRPC + cluster) in the same process.
    pub fn runInBackground(self: *Server) !std.Thread {
        self.running.store(true, .monotonic);
        const handle = try std.Thread.spawn(.{}, runLoop, .{self});
        return handle;
    }

    fn runLoop(self: *Server) void {
        self.start() catch |err| {
            std.log.err("[Server] Background accept loop failed: {}", .{err});
        };
    }

    /// Factory: create a Server from environment variables.
    /// Pass std.process.Environ from main's init: Server.fromEnv(io, alloc, init.environ).
    pub fn fromEnv(io: std.Io, allocator: std.mem.Allocator, env: std.process.Environ) !Server {
        var port: u16 = 8080;
        var max_body: usize = 8 * 1024 * 1024;
        var iter = env.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "HTTP_PORT")) {
                port = std.fmt.parseInt(u16, entry.value_ptr.*, 10) catch 8080;
            } else if (std.mem.eql(u8, entry.key_ptr.*, "HTTP_MAX_BODY")) {
                max_body = std.fmt.parseInt(usize, entry.value_ptr.*, 10) catch (8 * 1024 * 1024);
            }
        }
        return initWithConfig(io, allocator, .{ .port = port, .max_body_size = max_body });
    }

    /// Close the listener exactly once, whichever caller wins the race.
    fn closeListener(self: *Server) void {
        if (self.listener_closing.swap(true, .acq_rel)) return;
        if (self.listener) |*l| {
            l.deinit(self.io);
            self.listener = null;
        }
    }
};

/// Connection fiber — handles one HTTP connection
fn connFiber(server: *Server, stream: std.Io.net.Stream, allocator: std.mem.Allocator) void {
    defer stream.close(server.io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var reader: StreamReader = undefined;
    reader.setup(stream, server.io);
    var parser = RequestParser.init(arena_alloc);

    var req_count: usize = 0;
    while (req_count < server.max_requests_per_conn and server.running.load(.monotonic)) : (req_count += 1) {
        _ = arena.reset(.retain_capacity);

        const start_time = std.Io.Timestamp.now(server.io, .real);

        var request = parser.parse(&reader, server.max_body_size) catch |err| {
            switch (err) {
                // Peer closed before sending anything — keep-alive drain or
                // readiness probe. Nothing to respond with; just exit the loop.
                error.ClientClosed => return,
                error.ReadFailed => return,
                else => {},
            }
            std.log.err("Parse error: {any}", .{err});
            const msg = if (err == error.BodyTooLarge) "Payload Too Large" else "Bad Request";
            const status: u16 = if (err == error.BodyTooLarge) 413 else 400;
            writeErrorResponse(server.io, stream, arena_alloc, status, msg);
            return;
        };
        defer request.deinit(arena_alloc);

        // Track in-flight requests for graceful shutdown drain
        if (server.in_flight) |counter| {
            _ = counter.fetchAdd(1, .monotonic);
            defer _ = counter.fetchSub(1, .monotonic);
        }

        std.log.debug("[HC] {s} {s}", .{ request.method.toString(), request.path });

        var ctx = Context.init(arena_alloc, request.method, request.path) catch |err| {
            std.log.err("Context init error: {any}", .{err});
            return;
        };
        defer ctx.deinit();

        ctx.io = server.io;
        ctx.stream = stream;

        // Transfer ownership: steal query/headers HashMaps from request
        // to avoid re-duplicating every key-value pair (saves ~10 allocs/req).
        // Both use arena_alloc so lifetimes are consistent.
        ctx.query.deinit();
        ctx.query = request.query;
        request.query = std.StringHashMap([]const u8).init(arena_alloc);

        ctx.headers.deinit();
        ctx.headers = request.headers;
        request.headers = std.StringHashMap([]const u8).init(arena_alloc);

        ctx.body = request.body;
        ctx.raw_path = request.raw_path;

        // Parse form body
        if (request.body) |body| {
            const ctype = ctx.headers.get("Content-Type") orelse "";
            if (std.mem.startsWith(u8, ctype, "application/x-www-form-urlencoded")) {
                ctx.form = parseFormBody(arena_alloc, body) catch null;
            }
        }

        var matched = server.router.match(arena_alloc, request.method, request.path);
        if (matched) |*m| {
            defer {
                var it = m.params.iterator();
                while (it.next()) |entry| {
                    arena_alloc.free(entry.key_ptr.*);
                    arena_alloc.free(entry.value_ptr.*);
                }
                m.params.deinit();
            }

            // Transfer params ownership (same pattern as query/headers above).
            // Avoids duping every param key/value — saves 2 allocs per param.
            ctx.params.deinit();
            ctx.params = m.params;
            m.params = std.StringHashMap([]const u8).init(arena_alloc);

            ctx.user_data = m.route.user_data;

            server.executeWithMiddleware(&ctx, m.route.handler, m.route.combined_middleware) catch |err| {
                std.log.err("[HC] Handler error: {any}", .{err});
                if (!ctx.responded) {
                    ctx.sendError(500, @errorName(err)) catch |e| std.log.err("[Server] Failed to send 500: {}", .{e});
                }
            };
        } else {
            // Run global middleware before 404 so CORS/recover/logging
            // process every request (including OPTIONS preflight).
            if (server.global_middleware.items.len > 0) {
                server.executeWithMiddleware(&ctx, struct {
                    fn h(_: *Context) anyerror!void {}
                }.h, server.global_middleware.items) catch {};
            }
            if (!ctx.responded) {
                ctx.sendError(404, "Not Found") catch {};
            }
        }

        const current_time = std.Io.Timestamp.now(server.io, .real);
        const elapsed_ms = @divTrunc(current_time.nanoseconds - start_time.nanoseconds, std.time.ns_per_ms);
        if (elapsed_ms > server.request_timeout_ms and !ctx.responded) {
            ctx.sendError(408, "Request Timeout") catch {};
        }

        if (ctx.responded and !ctx.streaming) {
            writeResponse(server.io, stream, ctx.status_code, ctx.response_headers, ctx.response_body.items) catch |err| {
                std.log.err("[HC] write error: {any}", .{err});
                return;
            };
        }

        // Keep-alive decision: default keep-alive unless Connection: close
        if (request.headers.get("Connection")) |conn_val| {
            if (std.ascii.eqlIgnoreCase(conn_val, "close")) return;
        }
    }
}

/// Write an error response directly to the connection stream
fn writeErrorResponse(io: std.Io, stream: std.Io.net.Stream, allocator: std.mem.Allocator, status: u16, message: []const u8) void {
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = headers.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        headers.deinit();
    }

    const key = allocator.dupe(u8, "Content-Type") catch return;
    const val = allocator.dupe(u8, "application/json") catch {
        allocator.free(key);
        return;
    };
    headers.put(key, val) catch {
        allocator.free(key);
        allocator.free(val);
        return;
    };

    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message}) catch return;
    defer allocator.free(body);

    writeResponse(io, stream, status, headers, body) catch {};
}

fn runMiddlewareChain(ctx: *Context) anyerror!void {
    if (ctx.chain_index < ctx.chain_middlewares.len) {
        const mw = ctx.chain_middlewares[ctx.chain_index];
        ctx.chain_index += 1;
        try mw.func(ctx, runMiddlewareChain, mw.user_data);
    } else {
        try ctx.chain_handler(ctx);
    }
}

// Request/Response type wrapper
pub fn Request(comptime T: type) type {
    return struct {
        body: T,
    };
}

pub fn Response(comptime T: type) type {
    return struct {
        status: u16 = 200,
        body: T,
    };
}

/// JSON request/response wrapper
pub fn Json(comptime T: type) type {
    return struct {
        json: T,
    };
}

/// Deep-copy a parsed JSON value, duping all []const u8 fields
/// to escape the parse arena lifetime. Supports nested structs.
fn deepCopy(value: anytype, allocator: std.mem.Allocator) @TypeOf(value) {
    const T = @TypeOf(value);
    if (comptime T == []const u8 or T == []u8) {
        return allocator.dupe(u8, value) catch @panic("OOM");
    }
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            var copy: T = undefined;
            inline for (s.fields) |f| {
                @field(copy, f.name) = deepCopy(@field(value, f.name), allocator);
            }
            return copy;
        },
        .optional => {
            if (value) |v| return deepCopy(v, allocator);
            return null;
        },
        .array => {
            var copy: T = undefined;
            for (value, 0..) |elem, i| {
                copy[i] = deepCopy(elem, allocator);
            }
            return copy;
        },
        .pointer => |p| {
            if (p.child == u8) {
                return allocator.dupe(u8, value) catch @panic("OOM");
            }
            return value;
        },
        else => return value,
    }
}

test "api server" {
    const allocator = std.testing.allocator;
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    const route = Route{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                try ctx.json(200, "{\"status\":\"ok\"}");
            }
        }.handle,
    };

    try server.addRoute(route);
    try std.testing.expect(server.port == 0);
}

test "path matching" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    const route = Route{
        .method = .GET,
        .path = "/users/{id}",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                _ = ctx;
            }
        }.handle,
    };

    try router.addRoute(route);

    var matched = router.match(std.testing.allocator, .GET, "/users/123");
    if (matched) |*m| {
        defer {
            var iter = m.params.iterator();
            while (iter.next()) |entry| {
                std.testing.allocator.free(entry.key_ptr.*);
                std.testing.allocator.free(entry.value_ptr.*);
            }
            m.params.deinit();
        }
        try std.testing.expectEqualStrings("123", m.params.get("id").?);
    } else {
        try std.testing.expect(false);
    }

    const no_match = router.match(std.testing.allocator, .GET, "/posts/123");
    try std.testing.expect(no_match == null);
}

test "http methods" {
    try std.testing.expectEqual(Method.GET, Method.fromString("GET"));
    try std.testing.expectEqualStrings("POST", Method.POST.toString());
}

test "parse req binding" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/users/42");
    defer ctx.deinit();

    try ctx.params.put(try allocator.dupe(u8, "id"), try allocator.dupe(u8, "42"));
    try ctx.query.put(try allocator.dupe(u8, "page"), try allocator.dupe(u8, "3"));

    const Req = struct {
        id: u32,
        page: u32,
    };

    const req = try ctx.parseReq(Req, .{ .id = .path, .page = .query });
    try std.testing.expectEqual(@as(u32, 42), req.id);
    try std.testing.expectEqual(@as(u32, 3), req.page);
}

test "route group" {
    const allocator = std.testing.allocator;
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    var api_group = server.group("/api/v1");
    try api_group.get("/users", struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.json(200, "{\"users\":[]}");
        }
    }.handle, null);

    // Route should exist at /api/v1/users
    const matched = server.router.match(allocator,.GET, "/api/v1/users");
    try std.testing.expect(matched != null);
}

test "context response helpers" {
    const allocator = std.testing.allocator;

    // JSON response
    {
        var ctx = try Context.init(allocator, .GET, "/test");
        defer ctx.deinit();
        try ctx.json(200, "{\"ok\":true}");
        try std.testing.expectEqual(@as(u16, 200), ctx.status_code);
        try std.testing.expect(ctx.responded);
        try std.testing.expectEqualStrings("application/json", ctx.response_headers.get("Content-Type").?);
        try std.testing.expectEqualStrings("{\"ok\":true}", ctx.response_body.items);
    }

    // Text response
    {
        var ctx = try Context.init(allocator, .GET, "/test");
        defer ctx.deinit();
        try ctx.text(201, "created");
        try std.testing.expectEqual(@as(u16, 201), ctx.status_code);
        try std.testing.expectEqualStrings("text/plain", ctx.response_headers.get("Content-Type").?);
        try std.testing.expectEqualStrings("created", ctx.response_body.items);
    }

    // Error response
    {
        var ctx = try Context.init(allocator, .GET, "/test");
        defer ctx.deinit();
        try ctx.sendError(400, "bad request");
        try std.testing.expectEqual(@as(u16, 400), ctx.status_code);
        try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "bad request") != null);
    }
}
test "middleware chain execution" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const TestState = struct {
        call_order: [5]u8 = undefined,
        idx: usize = 0,
    };
    var state = TestState{};

    const S = struct {
        fn mw1(c: *Context, next: HandlerFn, user_data: ?*anyopaque) anyerror!void {
            const st: *TestState = @ptrCast(@alignCast(user_data.?));
            st.call_order[st.idx] = 1;
            st.idx += 1;
            try next(c);
            st.call_order[st.idx] = 5;
            st.idx += 1;
        }
        fn mw2(c: *Context, next: HandlerFn, user_data: ?*anyopaque) anyerror!void {
            const st: *TestState = @ptrCast(@alignCast(user_data.?));
            st.call_order[st.idx] = 2;
            st.idx += 1;
            try next(c);
            st.call_order[st.idx] = 4;
            st.idx += 1;
        }
        fn handler(c: *Context) anyerror!void {
            const st: *TestState = @ptrCast(@alignCast(c.user_data.?));
            st.call_order[st.idx] = 3;
            st.idx += 1;
        }
    };

    const mws = try allocator.alloc(Middleware, 2);
    defer allocator.free(mws);
    mws[0] = Middleware{ .func = S.mw1, .user_data = &state };
    mws[1] = Middleware{ .func = S.mw2, .user_data = &state };

    ctx.chain_middlewares = mws;
    ctx.chain_handler = S.handler;
    ctx.chain_index = 0;
    ctx.user_data = &state;

    try runMiddlewareChain(&ctx);

    try std.testing.expectEqual(@as(u8, 1), state.call_order[0]);
    try std.testing.expectEqual(@as(u8, 2), state.call_order[1]);
    try std.testing.expectEqual(@as(u8, 3), state.call_order[2]);
    try std.testing.expectEqual(@as(u8, 4), state.call_order[3]);
    try std.testing.expectEqual(@as(u8, 5), state.call_order[4]);
}

test "integration: router + handler + response" {
    const allocator = std.testing.allocator;

    // 1. Set up server with a route
    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    const HandlerCtx = struct {
        var last_id: u32 = 0;
        var last_page: u32 = 0;
    };

    try server.addRoute(.{
        .method = .GET,
        .path = "/users/{id}",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                const id_str = ctx.param("id") orelse "0";
                const id = try std.fmt.parseInt(u32, id_str, 10);
                HandlerCtx.last_id = id;

                const page_str = ctx.queryParam("page") orelse "1";
                HandlerCtx.last_page = try std.fmt.parseInt(u32, page_str, 10);

                try ctx.json(200, "{\"found\":true}");
            }
        }.handle,
    });

    // 2. Simulate a matched request
    var matched = server.router.match(allocator,.GET, "/users/99");
    try std.testing.expect(matched != null);

    if (matched) |*m| {
        defer {
            var it = m.params.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            m.params.deinit();
        }

        var ctx = try Context.init(allocator, .GET, "/users/99");
        defer ctx.deinit();

        // Copy params from matched route
        var piter = m.params.iterator();
        while (piter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const val = try allocator.dupe(u8, entry.value_ptr.*);
            try ctx.params.put(key, val);
        }

        // Set a query param
        const qk = try allocator.dupe(u8, "page");
        const qv = try allocator.dupe(u8, "5");
        try ctx.query.put(qk, qv);

        // Execute handler
        try m.route.handler(&ctx);

        // Verify response
        try std.testing.expectEqual(@as(u32, 99), HandlerCtx.last_id);
        try std.testing.expectEqual(@as(u32, 5), HandlerCtx.last_page);
        try std.testing.expectEqual(@as(u16, 200), ctx.status_code);
        try std.testing.expect(ctx.responded);
        try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "found") != null);
    }
}

test "router listRoutes" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    try router.addRoute(.{ .method = .GET, .path = "/health", .handler = struct { fn handle(_: *Context) !void {} }.handle });
    try router.addRoute(.{ .method = .POST, .path = "/users", .handler = struct { fn handle(_: *Context) !void {} }.handle });
    try router.addRoute(.{ .method = .GET, .path = "/users/{id}", .handler = struct { fn handle(_: *Context) !void {} }.handle });
    try router.addRoute(.{ .method = .DELETE, .path = "/api/v1/admin/settings", .handler = struct { fn handle(_: *Context) !void {} }.handle });

    const routes = try router.listRoutes(allocator);
    defer {
        for (routes) |r| {
            allocator.free(r.method);
            allocator.free(r.path);
        }
        allocator.free(routes);
    }

    try std.testing.expectEqual(@as(usize, 4), routes.len);

    // Verify method/path pairs exist (order not guaranteed)
    var found_health = false;
    var found_post_users = false;
    var found_get_users_id = false;
    var found_admin = false;
    for (routes) |r| {
        if (std.mem.eql(u8, r.method, "GET") and std.mem.eql(u8, r.path, "/health")) found_health = true;
        if (std.mem.eql(u8, r.method, "POST") and std.mem.eql(u8, r.path, "/users")) found_post_users = true;
        if (std.mem.eql(u8, r.method, "GET") and std.mem.eql(u8, r.path, "/users/{id}")) found_get_users_id = true;
        if (std.mem.eql(u8, r.method, "DELETE") and std.mem.eql(u8, r.path, "/api/v1/admin/settings")) found_admin = true;
    }
    try std.testing.expect(found_health);
    try std.testing.expect(found_post_users);
    try std.testing.expect(found_get_users_id);
    try std.testing.expect(found_admin);
}

test "integration: router + global middleware + handler" {
    const allocator = std.testing.allocator;

    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    const MwCtx = struct {
        var called: bool = false;
        var handled: bool = false;
    };

    // Add global middleware
    try server.addMiddleware(.{
        .func = struct {
            fn mw(ctx: *Context, next: HandlerFn, _: ?*anyopaque) anyerror!void {
                MwCtx.called = true;
                try next(ctx);
            }
        }.mw,
    });

    // Add route
    try server.addRoute(.{
        .method = .GET,
        .path = "/health",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                MwCtx.handled = true;
                try ctx.json(200, "{\"status\":\"ok\"}");
            }
        }.handle,
    });

    // Simulate match
    var matched = server.router.match(allocator,.GET, "/health");
    try std.testing.expect(matched != null);

    if (matched) |*m| {
        defer {
            var it = m.params.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            m.params.deinit();
        }

        var ctx = try Context.init(allocator, .GET, "/health");
        defer ctx.deinit();

        // Execute with middleware chain
        try server.executeWithMiddleware(&ctx, m.route.handler, m.route.combined_middleware);

        try std.testing.expect(MwCtx.called);
        try std.testing.expect(MwCtx.handled);
        try std.testing.expectEqual(@as(u16, 200), ctx.status_code);
        try std.testing.expect(ctx.responded);
    }
}

test "e2e: full middleware chain with error path" {
    const allocator = std.testing.allocator;

    var server = Server.init(std.testing.io, allocator, 0);
    defer server.deinit();

    const Ctx = struct {
        var hit_count: u32 = 0;
        var last_status: u16 = 0;
    };

    // Global logging middleware
    try server.addMiddleware(.{
        .func = struct {
            fn h(ctx: *Context, next: HandlerFn, _: ?*anyopaque) anyerror!void {
                Ctx.hit_count += 1;
                try next(ctx);
            }
        }.h,
    });

    // Register a route that returns 201
    try server.addRoute(.{
        .method = .POST,
        .path = "/items",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                Ctx.last_status = 201;
                try ctx.json(201, "{\"created\":true}");
            }
        }.handle,
    });

    // Register a route that triggers an error
    try server.addRoute(.{
        .method = .GET,
        .path = "/boom",
        .handler = struct {
            fn handle(_: *Context) anyerror!void {
                return error.SomePanic;
            }
        }.handle,
    });

    // Test 1: happy path
    {
        Ctx.hit_count = 0;
        var matched = server.router.match(allocator,.POST, "/items");
        try std.testing.expect(matched != null);
        if (matched) |*m| {
            defer {
                var it = m.params.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                m.params.deinit();
            }
            var ctx = try Context.init(allocator, .POST, "/items");
            defer ctx.deinit();
            try server.executeWithMiddleware(&ctx, m.route.handler, m.route.combined_middleware);
            try std.testing.expectEqual(@as(u32, 1), Ctx.hit_count);
            try std.testing.expectEqual(@as(u16, 201), ctx.status_code);
            try std.testing.expect(ctx.responded);
        }
    }

    // Test 2: route not found (404)
    {
        const matched = server.router.match(allocator,.GET, "/nonexistent");
        try std.testing.expect(matched == null);
    }

    // Test 3: panic handler returns 500
    {
        Ctx.hit_count = 0;
        var matched = server.router.match(allocator,.GET, "/boom");
        try std.testing.expect(matched != null);
        if (matched) |*m| {
            defer {
                var it = m.params.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                m.params.deinit();
            }
            var ctx = try Context.init(allocator, .GET, "/boom");
            defer ctx.deinit();
            server.executeWithMiddleware(&ctx, m.route.handler, m.route.combined_middleware) catch {
                _ = ctx.sendError(500, "Internal Server Error") catch {};
            };
            try std.testing.expectEqual(@as(u32, 1), Ctx.hit_count);
        }
    }
}

test "router scalability: 200 routes with O(1) child lookup" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    // Register 200 routes across different methods and path depths
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const path = try std.fmt.allocPrint(allocator, "/api/v1/users/{d}", .{i});
        defer allocator.free(path);
        try router.addRoute(.{
            .method = .GET,
            .path = path,
            .handler = struct {
                fn handle(_: *Context) !void {}
            }.handle,
        });
    }
    // Add 50 more with different prefixes
    var j: usize = 0;
    while (j < 50) : (j += 1) {
        const path = try std.fmt.allocPrint(allocator, "/api/v2/items/{d}/details", .{j});
        defer allocator.free(path);
        try router.addRoute(.{
            .method = .GET,
            .path = path,
            .handler = struct {
                fn handle(_: *Context) !void {}
            }.handle,
        });
    }
    // 50 POST routes sharing prefixes
    var k: usize = 0;
    while (k < 50) : (k += 1) {
        const path = try std.fmt.allocPrint(allocator, "/api/v1/users/{d}/posts", .{k});
        defer allocator.free(path);
        try router.addRoute(.{
            .method = .POST,
            .path = path,
            .handler = struct {
                fn handle(_: *Context) !void {}
            }.handle,
        });
    }

    // Verify all 200 routes match correctly
    try std.testing.expect(router.match(allocator, .GET, "/api/v1/users/42") != null);
    try std.testing.expect(router.match(allocator, .POST, "/api/v1/users/7/posts") != null);
    try std.testing.expect(router.match(allocator, .GET, "/api/v2/items/3/details") != null);
    try std.testing.expect(router.match(allocator, .GET, "/nonexistent") == null);

    // Verify listRoutes returns all 200
    const routes = try router.listRoutes(allocator);
    defer {
        for (routes) |r| {
            allocator.free(r.method);
            allocator.free(r.path);
        }
        allocator.free(routes);
    }
    try std.testing.expectEqual(@as(usize, 200), routes.len);
}

test "deepCopy strings escape arena lifetime" {
    const allocator = std.testing.allocator;

    const S = struct { name: []const u8, age: i32 };
    const original = S{ .name = "alice", .age = 30 };
    const copy = deepCopy(original, allocator);
    defer allocator.free(copy.name);

    // Verify deep copy produced independent memory
    try std.testing.expectEqualStrings("alice", copy.name);
    try std.testing.expectEqual(@as(i32, 30), copy.age);
    try std.testing.expect(copy.name.ptr != original.name.ptr); // different pointers

    // Verify nested struct copy
    const Outer = struct { inner: S, label: []const u8 };
    const outer = Outer{ .inner = S{ .name = "bob", .age = 25 }, .label = "test" };
    const outer_copy = deepCopy(outer, allocator);
    defer allocator.free(outer_copy.inner.name);
    defer allocator.free(outer_copy.label);

    try std.testing.expectEqualStrings("bob", outer_copy.inner.name);
    try std.testing.expectEqual(@as(i32, 25), outer_copy.inner.age);
    try std.testing.expectEqualStrings("test", outer_copy.label);
}

test "queryInt returns default on missing param" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    try std.testing.expectEqual(@as(i64, 0), ctx.queryInt(i64, "page", 0));
    try std.testing.expectEqual(@as(i64, 10), ctx.queryInt(i64, "size", 10));
}

test "queryInt parses valid integer" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/test?page=5&size=20");
    defer ctx.deinit();

    const qk = try allocator.dupe(u8, "page");
    const qv = try allocator.dupe(u8, "5");
    try ctx.query.put(qk, qv);
    const sk = try allocator.dupe(u8, "size");
    const sv = try allocator.dupe(u8, "20");
    try ctx.query.put(sk, sv);

    try std.testing.expectEqual(@as(i64, 5), ctx.queryInt(i64, "page", 0));
    try std.testing.expectEqual(@as(i64, 20), ctx.queryInt(i64, "size", 10));
    try std.testing.expectEqual(@as(i64, 42), ctx.queryInt(i64, "missing", 42));
}
