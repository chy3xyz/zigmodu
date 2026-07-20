//! gRPC unary transport for ZigModu.
//!
//! Production surface (unary only):
//! - Length-prefixed message framing (`GrpcFrame`)
//! - In-process dispatch via `GrpcServiceRegistry.invoke`
//! - HTTP/1.1 + `application/grpc` unary (gRPC status in headers)
//! - Optional local registry binding for modulith same-process calls
//!
//! Streaming (server/client/bidi) returns `UNIMPLEMENTED` until HTTP/2 lands.
//! Protobuf encode/decode stays in application code; this layer carries bytes.

const std = @import("std");
const HttpClient = @import("../http/HttpClient.zig").HttpClient;

/// gRPC method descriptor.
pub const GrpcMethod = struct {
    path: []const u8,
    service: []const u8,
    method: []const u8,
    method_type: MethodType,

    pub const MethodType = enum {
        unary,
        server_streaming,
        client_streaming,
        bidi_streaming,
    };
};

pub const GrpcRequest = struct {
    method: GrpcMethod,
    payload: []const u8,
    metadata: std.StringHashMap([]const u8),
    timeout_ms: u64,
};

pub const GrpcResponse = struct {
    payload: []const u8,
    status: GrpcStatusCode,
    message: []const u8,
};

/// Heap-owned response from network / local invoke.
pub const OwnedGrpcResponse = struct {
    payload: []u8,
    status: GrpcStatusCode,
    message: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OwnedGrpcResponse) void {
        self.allocator.free(self.payload);
        self.allocator.free(self.message);
        self.* = undefined;
    }

    pub fn asView(self: OwnedGrpcResponse) GrpcResponse {
        return .{ .payload = self.payload, .status = self.status, .message = self.message };
    }
};

pub const GrpcStatusCode = enum(u8) {
    OK = 0,
    CANCELLED = 1,
    UNKNOWN = 2,
    INVALID_ARGUMENT = 3,
    DEADLINE_EXCEEDED = 4,
    NOT_FOUND = 5,
    ALREADY_EXISTS = 6,
    PERMISSION_DENIED = 7,
    RESOURCE_EXHAUSTED = 8,
    FAILED_PRECONDITION = 9,
    ABORTED = 10,
    OUT_OF_RANGE = 11,
    UNIMPLEMENTED = 12,
    INTERNAL = 13,
    UNAVAILABLE = 14,
    DATA_LOSS = 15,
    UNAUTHENTICATED = 16,

    pub fn toString(self: GrpcStatusCode) []const u8 {
        return switch (self) {
            .OK => "OK",
            .CANCELLED => "CANCELLED",
            .UNKNOWN => "UNKNOWN",
            .INVALID_ARGUMENT => "INVALID_ARGUMENT",
            .DEADLINE_EXCEEDED => "DEADLINE_EXCEEDED",
            .NOT_FOUND => "NOT_FOUND",
            .ALREADY_EXISTS => "ALREADY_EXISTS",
            .PERMISSION_DENIED => "PERMISSION_DENIED",
            .RESOURCE_EXHAUSTED => "RESOURCE_EXHAUSTED",
            .FAILED_PRECONDITION => "FAILED_PRECONDITION",
            .ABORTED => "ABORTED",
            .OUT_OF_RANGE => "OUT_OF_RANGE",
            .UNIMPLEMENTED => "UNIMPLEMENTED",
            .INTERNAL => "INTERNAL",
            .UNAVAILABLE => "UNAVAILABLE",
            .DATA_LOSS => "DATA_LOSS",
            .UNAUTHENTICATED => "UNAUTHENTICATED",
        };
    }

    pub fn fromCode(code: u8) GrpcStatusCode {
        return switch (code) {
            0 => .OK,
            1 => .CANCELLED,
            2 => .UNKNOWN,
            3 => .INVALID_ARGUMENT,
            4 => .DEADLINE_EXCEEDED,
            5 => .NOT_FOUND,
            6 => .ALREADY_EXISTS,
            7 => .PERMISSION_DENIED,
            8 => .RESOURCE_EXHAUSTED,
            9 => .FAILED_PRECONDITION,
            10 => .ABORTED,
            11 => .OUT_OF_RANGE,
            12 => .UNIMPLEMENTED,
            13 => .INTERNAL,
            14 => .UNAVAILABLE,
            15 => .DATA_LOSS,
            16 => .UNAUTHENTICATED,
            else => .UNKNOWN,
        };
    }

    pub fn toHttpCode(self: GrpcStatusCode) u16 {
        return switch (self) {
            .OK => 200,
            .INVALID_ARGUMENT => 400,
            .NOT_FOUND => 404,
            .ALREADY_EXISTS => 409,
            .PERMISSION_DENIED => 403,
            .UNAUTHENTICATED => 401,
            .RESOURCE_EXHAUSTED => 429,
            .UNIMPLEMENTED => 501,
            .UNAVAILABLE => 503,
            .DEADLINE_EXCEEDED => 504,
            .INTERNAL => 500,
            else => 500,
        };
    }
};

/// Length-prefixed gRPC message: 1 byte compressed-flag + 4 byte BE length + payload.
pub const GrpcFrame = struct {
    pub fn encode(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
        if (payload.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
        var out = try allocator.alloc(u8, 5 + payload.len);
        out[0] = 0; // uncompressed
        const len: u32 = @intCast(payload.len);
        out[1] = @truncate(len >> 24);
        out[2] = @truncate(len >> 16);
        out[3] = @truncate(len >> 8);
        out[4] = @truncate(len);
        @memcpy(out[5..], payload);
        return out;
    }

    pub fn decode(frame: []const u8) ![]const u8 {
        if (frame.len < 5) return error.InvalidGrpcFrame;
        if (frame[0] != 0) return error.CompressedNotSupported;
        const len: u32 = (@as(u32, frame[1]) << 24) | (@as(u32, frame[2]) << 16) | (@as(u32, frame[3]) << 8) | frame[4];
        if (5 + len > frame.len) return error.IncompleteGrpcFrame;
        return frame[5 .. 5 + len];
    }
};

pub const UnaryHandler = *const fn (request: GrpcRequest) anyerror!GrpcResponse;

pub const GrpcServiceRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    services: std.StringHashMap(ServiceEntry),

    pub const ServiceEntry = struct {
        name: []const u8,
        methods: std.StringHashMap(RegisteredMethod),
    };

    pub const RegisteredMethod = struct {
        method: GrpcMethod,
        handler: UnaryHandler,
    };

    /// Result of HTTP unary handling (caller frees `body` and `grpc_message`).
    pub const HttpUnaryResult = struct {
        http_status: u16,
        body: []u8,
        grpc_status: GrpcStatusCode,
        grpc_message: []u8,
        content_type: []const u8 = "application/grpc",

        pub fn deinit(self: *HttpUnaryResult, allocator: std.mem.Allocator) void {
            allocator.free(self.body);
            allocator.free(self.grpc_message);
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .services = std.StringHashMap(ServiceEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var svc_iter = self.services.iterator();
        while (svc_iter.next()) |svc_entry| {
            var meth_iter = svc_entry.value_ptr.methods.iterator();
            while (meth_iter.next()) |meth| {
                self.allocator.free(meth.value_ptr.method.path);
                self.allocator.free(meth.value_ptr.method.service);
                self.allocator.free(meth.value_ptr.method.method);
            }
            svc_entry.value_ptr.methods.deinit();
            self.allocator.free(svc_entry.value_ptr.name);
        }
        self.services.deinit();
        self.* = undefined;
    }

    pub fn registerService(self: *Self, service_name: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, service_name);
        errdefer self.allocator.free(name_copy);
        try self.services.put(name_copy, .{
            .name = name_copy,
            .methods = std.StringHashMap(RegisteredMethod).init(self.allocator),
        });
    }

    pub fn registerMethod(
        self: *Self,
        service_name: []const u8,
        method_name: []const u8,
        method_type: GrpcMethod.MethodType,
        handler: UnaryHandler,
    ) !void {
        const svc = self.services.getPtr(service_name) orelse return error.ServiceNotFound;
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ service_name, method_name });
        errdefer self.allocator.free(path);
        const svc_copy = try self.allocator.dupe(u8, service_name);
        errdefer self.allocator.free(svc_copy);
        const meth_copy = try self.allocator.dupe(u8, method_name);
        errdefer self.allocator.free(meth_copy);

        try svc.methods.put(path, .{
            .method = .{
                .path = path,
                .service = svc_copy,
                .method = meth_copy,
                .method_type = method_type,
            },
            .handler = handler,
        });
    }

    pub fn findHandler(self: *Self, path: []const u8) ?struct { method: GrpcMethod, handler: UnaryHandler } {
        var svc_iter = self.services.iterator();
        while (svc_iter.next()) |svc_entry| {
            if (svc_entry.value_ptr.methods.get(path)) |reg| {
                return .{ .method = reg.method, .handler = reg.handler };
            }
        }
        return null;
    }

    pub fn listMethods(self: *Self) ![]const GrpcMethod {
        var result = std.ArrayList(GrpcMethod).empty;
        var svc_iter = self.services.iterator();
        while (svc_iter.next()) |svc_entry| {
            var meth_iter = svc_entry.value_ptr.methods.iterator();
            while (meth_iter.next()) |meth| {
                try result.append(self.allocator, meth.value_ptr.method);
            }
        }
        return result.toOwnedSlice(self.allocator);
    }

    /// In-process unary invoke (no framing). Streaming methods → UNIMPLEMENTED.
    pub fn invoke(self: *Self, path: []const u8, payload: []const u8) !OwnedGrpcResponse {
        const found = self.findHandler(path) orelse {
            return OwnedGrpcResponse{
                .payload = try self.allocator.dupe(u8, ""),
                .status = .NOT_FOUND,
                .message = try self.allocator.dupe(u8, "method not found"),
                .allocator = self.allocator,
            };
        };
        if (found.method.method_type != .unary) {
            return OwnedGrpcResponse{
                .payload = try self.allocator.dupe(u8, ""),
                .status = .UNIMPLEMENTED,
                .message = try self.allocator.dupe(u8, "only unary methods are supported"),
                .allocator = self.allocator,
            };
        }

        var metadata = std.StringHashMap([]const u8).init(self.allocator);
        defer metadata.deinit();
        const req = GrpcRequest{
            .method = found.method,
            .payload = payload,
            .metadata = metadata,
            .timeout_ms = 30_000,
        };
        const resp = found.handler(req) catch |err| {
            return OwnedGrpcResponse{
                .payload = try self.allocator.dupe(u8, ""),
                .status = .INTERNAL,
                .message = try self.allocator.dupe(u8, @errorName(err)),
                .allocator = self.allocator,
            };
        };
        return OwnedGrpcResponse{
            .payload = try self.allocator.dupe(u8, resp.payload),
            .status = resp.status,
            .message = try self.allocator.dupe(u8, resp.message),
            .allocator = self.allocator,
        };
    }

    /// Handle an HTTP/1.1 unary gRPC request body (framed) for `path`.
    /// Caller must `result.deinit(allocator)`.
    pub fn handleHttpUnary(self: *Self, path: []const u8, body: []const u8) !HttpUnaryResult {
        const payload = GrpcFrame.decode(body) catch {
            return .{
                .http_status = 400,
                .body = try GrpcFrame.encode(self.allocator, ""),
                .grpc_status = .INVALID_ARGUMENT,
                .grpc_message = try self.allocator.dupe(u8, "invalid grpc frame"),
            };
        };
        const owned = try self.invoke(path, payload);
        const grpc_status = owned.status;
        const http_status: u16 = if (grpc_status == .OK) 200 else grpc_status.toHttpCode();
        const framed = try GrpcFrame.encode(self.allocator, owned.payload);
        self.allocator.free(owned.payload);
        return .{
            .http_status = http_status,
            .body = framed,
            .grpc_status = grpc_status,
            .grpc_message = owned.message,
        };
    }
};

pub const ProtoParser = struct {
    pub const ProtoService = struct {
        name: []const u8,
        methods: []const ProtoMethod,
    };

    pub const ProtoMethod = struct {
        name: []const u8,
        input_type: []const u8,
        output_type: []const u8,
        is_streaming: bool = false,
    };

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) ![]const ProtoService {
        var services = std.ArrayList(ProtoService).empty;
        var lines = std.mem.splitScalar(u8, content, '\n');
        var current_service: ?[]const u8 = null;
        var current_methods = std.ArrayList(ProtoMethod).empty;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r;");
            if (std.mem.startsWith(u8, trimmed, "service ")) {
                if (current_service) |svc| {
                    const methods = try current_methods.toOwnedSlice(allocator);
                    try services.append(allocator, .{ .name = svc, .methods = methods });
                    current_methods = std.ArrayList(ProtoMethod).empty;
                    current_service = null;
                }
                const svc_name = std.mem.trim(u8, trimmed["service ".len..], " \t{");
                current_service = try allocator.dupe(u8, svc_name);
            } else if (std.mem.startsWith(u8, trimmed, "rpc ")) {
                const after_rpc = std.mem.trim(u8, trimmed["rpc ".len..], " \t");
                const paren = std.mem.indexOfScalar(u8, after_rpc, '(') orelse continue;
                const method_name = after_rpc[0..paren];
                const input_start = paren + 1;
                const input_end = std.mem.indexOfScalar(u8, after_rpc[input_start..], ')') orelse continue;
                const input_type = after_rpc[input_start .. input_start + input_end];
                const returns_pos = std.mem.indexOf(u8, after_rpc, "returns") orelse continue;
                const output_paren = std.mem.indexOfScalar(u8, after_rpc[returns_pos..], '(') orelse continue;
                const output_start = returns_pos + output_paren + 1;
                const output_end = std.mem.indexOfScalar(u8, after_rpc[output_start..], ')') orelse continue;
                const output_type = after_rpc[output_start .. output_start + output_end];
                try current_methods.append(allocator, .{
                    .name = try allocator.dupe(u8, method_name),
                    .input_type = try allocator.dupe(u8, input_type),
                    .output_type = try allocator.dupe(u8, output_type),
                });
            }
        }
        if (current_service) |svc| {
            const methods = try current_methods.toOwnedSlice(allocator);
            try services.append(allocator, .{ .name = svc, .methods = methods });
        }
        return services.toOwnedSlice(allocator);
    }
};

/// Unary gRPC client: local registry and/or HTTP/1.1 `application/grpc`.
pub const GrpcClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    endpoints: std.StringHashMap(Endpoint),
    local: ?*GrpcServiceRegistry = null,
    io: ?std.Io = null,
    http: ?HttpClient = null,

    pub const Endpoint = struct {
        address: []const u8,
        port: u16,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .endpoints = std.StringHashMap(Endpoint).init(allocator),
        };
    }

    /// Network-capable client (HTTP/1.1 unary).
    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .endpoints = std.StringHashMap(Endpoint).init(allocator),
            .io = io,
            .http = HttpClient.init(allocator, io, 4, 10_000),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.endpoints.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.address);
        }
        self.endpoints.deinit();
        if (self.http) |*h| h.deinit();
        self.* = undefined;
    }

    /// Prefer in-process dispatch when set (modulith).
    pub fn bindLocal(self: *Self, registry: *GrpcServiceRegistry) void {
        self.local = registry;
    }

    pub fn registerEndpoint(self: *Self, service_name: []const u8, address: []const u8, port: u16) !void {
        const addr_copy = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(addr_copy);
        try self.endpoints.put(service_name, .{ .address = addr_copy, .port = port });
    }

    pub fn call(self: *Self, service: []const u8, method: []const u8, payload: []const u8) !OwnedGrpcResponse {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ service, method });
        defer self.allocator.free(path);

        if (self.local) |reg| {
            return try reg.invoke(path, payload);
        }

        const ep = self.endpoints.get(service) orelse return error.EndpointNotFound;
        const http = &(self.http orelse return error.IoRequired);

        const framed = try GrpcFrame.encode(self.allocator, payload);
        defer self.allocator.free(framed);

        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}{s}", .{ ep.address, ep.port, path });
        defer self.allocator.free(url);

        var req = HttpClient.HttpRequest.init(self.allocator, "POST", url);
        defer req.deinit();
        try req.setBody(framed);
        try req.setHeader("Content-Type", "application/grpc");
        try req.setHeader("TE", "trailers");
        try req.setHeader("User-Agent", "zigmodu-grpc/0.14");
        var cl_buf: [32]u8 = undefined;
        const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{framed.len});
        try req.setHeader("Content-Length", cl);
        try req.setHeader("Host", ep.address);

        var http_resp = try http.request(req);
        defer http_resp.deinit();

        return try parseHttpGrpcResponse(self.allocator, &http_resp);
    }
};

fn parseHttpGrpcResponse(allocator: std.mem.Allocator, http_resp: *HttpClient.HttpResponse) !OwnedGrpcResponse {
    var status: GrpcStatusCode = .OK;
    var message: []const u8 = "";

    if (http_resp.headers.get("grpc-status")) |gs| {
        const code = std.fmt.parseInt(u8, gs, 10) catch 2;
        status = GrpcStatusCode.fromCode(code);
    } else if (http_resp.status_code >= 400) {
        status = .UNAVAILABLE;
        message = "http transport error";
    }
    if (http_resp.headers.get("grpc-message")) |gm| {
        message = gm;
    }

    const payload = if (http_resp.body.len >= 5)
        GrpcFrame.decode(http_resp.body) catch &.{}
    else
        http_resp.body;

    return .{
        .payload = try allocator.dupe(u8, payload),
        .status = status,
        .message = try allocator.dupe(u8, message),
        .allocator = allocator,
    };
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "GrpcStatusCode toString" {
    try std.testing.expectEqualStrings("OK", GrpcStatusCode.OK.toString());
    try std.testing.expectEqualStrings("NOT_FOUND", GrpcStatusCode.NOT_FOUND.toString());
    try std.testing.expectEqualStrings("INTERNAL", GrpcStatusCode.INTERNAL.toString());
}

test "GrpcStatusCode toHttpCode" {
    try std.testing.expectEqual(@as(u16, 200), GrpcStatusCode.OK.toHttpCode());
    try std.testing.expectEqual(@as(u16, 404), GrpcStatusCode.NOT_FOUND.toHttpCode());
    try std.testing.expectEqual(@as(u16, 500), GrpcStatusCode.INTERNAL.toHttpCode());
}

test "GrpcFrame encode decode roundtrip" {
    const allocator = std.testing.allocator;
    const framed = try GrpcFrame.encode(allocator, "hello-proto");
    defer allocator.free(framed);
    try std.testing.expectEqual(@as(usize, 16), framed.len);
    const payload = try GrpcFrame.decode(framed);
    try std.testing.expectEqualStrings("hello-proto", payload);
}

test "GrpcServiceRegistry register and find" {
    const allocator = std.testing.allocator;
    var registry = GrpcServiceRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerService("order.OrderService");
    try registry.registerMethod("order.OrderService", "CreateOrder", .unary, struct {
        fn handler(_: GrpcRequest) !GrpcResponse {
            return GrpcResponse{ .payload = "created", .status = .OK, .message = "" };
        }
    }.handler);

    const found = registry.findHandler("/order.OrderService/CreateOrder").?;
    try std.testing.expectEqualStrings("/order.OrderService/CreateOrder", found.method.path);
    try std.testing.expectEqual(GrpcMethod.MethodType.unary, found.method.method_type);
}

test "GrpcServiceRegistry invoke unary" {
    const allocator = std.testing.allocator;
    var registry = GrpcServiceRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerService("echo.Echo");
    try registry.registerMethod("echo.Echo", "Say", .unary, struct {
        fn handler(req: GrpcRequest) !GrpcResponse {
            return .{ .payload = req.payload, .status = .OK, .message = "" };
        }
    }.handler);

    var resp = try registry.invoke("/echo.Echo/Say", "ping");
    defer resp.deinit();
    try std.testing.expectEqual(GrpcStatusCode.OK, resp.status);
    try std.testing.expectEqualStrings("ping", resp.payload);
}

test "GrpcServiceRegistry handleHttpUnary" {
    const allocator = std.testing.allocator;
    var registry = GrpcServiceRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerService("echo.Echo");
    try registry.registerMethod("echo.Echo", "Say", .unary, struct {
        fn handler(req: GrpcRequest) !GrpcResponse {
            return .{ .payload = req.payload, .status = .OK, .message = "" };
        }
    }.handler);

    const framed_in = try GrpcFrame.encode(allocator, "http-ping");
    defer allocator.free(framed_in);
    var result = try registry.handleHttpUnary("/echo.Echo/Say", framed_in);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), result.http_status);
    try std.testing.expectEqual(GrpcStatusCode.OK, result.grpc_status);
    const out = try GrpcFrame.decode(result.body);
    try std.testing.expectEqualStrings("http-ping", out);
}

test "GrpcServiceRegistry list methods" {
    const allocator = std.testing.allocator;
    var registry = GrpcServiceRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerService("test.Service");
    try registry.registerMethod("test.Service", "Ping", .unary, struct {
        fn h(_: GrpcRequest) !GrpcResponse {
            return GrpcResponse{ .payload = "pong", .status = .OK, .message = "" };
        }
    }.h);

    const methods = try registry.listMethods();
    defer allocator.free(methods);
    try std.testing.expectEqual(@as(usize, 1), methods.len);
    try std.testing.expectEqualStrings("Ping", methods[0].method);
}

test "ProtoParser basic" {
    const allocator = std.testing.allocator;
    const proto_content =
        \\service OrderService {
        \\  rpc CreateOrder(CreateOrderRequest) returns (CreateOrderResponse);
        \\  rpc GetOrder(GetOrderRequest) returns (Order);
        \\}
        \\
        \\service PaymentService {
        \\  rpc ProcessPayment(PaymentRequest) returns (PaymentResponse);
        \\}
    ;

    const services = try ProtoParser.parse(allocator, proto_content);
    defer {
        for (services) |svc| {
            allocator.free(svc.name);
            for (svc.methods) |m| {
                allocator.free(m.name);
                allocator.free(m.input_type);
                allocator.free(m.output_type);
            }
            allocator.free(svc.methods);
        }
        allocator.free(services);
    }

    try std.testing.expectEqual(@as(usize, 2), services.len);
    try std.testing.expectEqualStrings("OrderService", services[0].name);
    try std.testing.expectEqual(@as(usize, 2), services[0].methods.len);
    try std.testing.expectEqualStrings("PaymentService", services[1].name);
}

test "GrpcClient local call" {
    const allocator = std.testing.allocator;
    var registry = GrpcServiceRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerService("order.OrderService");
    try registry.registerMethod("order.OrderService", "CreateOrder", .unary, struct {
        fn handler(req: GrpcRequest) !GrpcResponse {
            return .{ .payload = req.payload, .status = .OK, .message = "ok" };
        }
    }.handler);

    var client = GrpcClient.init(allocator);
    defer client.deinit();
    client.bindLocal(&registry);

    var result = try client.call("order.OrderService", "CreateOrder", "order-1");
    defer result.deinit();
    try std.testing.expectEqual(GrpcStatusCode.OK, result.status);
    try std.testing.expectEqualStrings("order-1", result.payload);
}

test "GrpcClient endpoint without io returns IoRequired" {
    const allocator = std.testing.allocator;
    var client = GrpcClient.init(allocator);
    defer client.deinit();
    try client.registerEndpoint("order.OrderService", "127.0.0.1", 50051);
    try std.testing.expectError(error.IoRequired, client.call("order.OrderService", "CreateOrder", ""));
}
