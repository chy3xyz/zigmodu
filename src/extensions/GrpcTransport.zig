const std = @import("std");

/// gRPC 服务方法定义
pub const GrpcMethod = struct {
    /// 完整方法名 (e.g. "/order.OrderService/CreateOrder")
    path: []const u8,
    /// 服务名
    service: []const u8,
    /// 方法名
    method: []const u8,
    /// 方法类型
    method_type: MethodType,

    pub const MethodType = enum {
        unary,
        server_streaming,
        client_streaming,
        bidi_streaming,
    };
};

/// gRPC 请求头
pub const GrpcRequest = struct {
    method: GrpcMethod,
    /// 序列化后的 protobuf 载荷
    payload: []const u8,
    /// metadata (key-value pairs)
    metadata: std.StringHashMap([]const u8),
    /// timeout in milliseconds
    timeout_ms: u64,
};

/// gRPC 响应
pub const GrpcResponse = struct {
    /// 序列化后的 protobuf 载荷
    payload: []const u8,
    /// gRPC status code
    status: GrpcStatusCode,
    /// 错误消息 (如果有)
    message: []const u8,
};

/// gRPC 状态码
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

/// gRPC 服务处理器 (单请求/单响应)
pub const UnaryHandler = *const fn (request: GrpcRequest) anyerror!GrpcResponse;

/// gRPC 服务注册表
pub const GrpcServiceRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    services: std.StringHashMap(ServiceEntry),

    pub const ServiceEntry = struct {
        /// 服务名 (如 "order.OrderService")
        name: []const u8,
        /// 方法注册表
        methods: std.StringHashMap(RegisteredMethod),
    };

    pub const RegisteredMethod = struct {
        method: GrpcMethod,
        handler: UnaryHandler,
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
    }

    /// 注册服务
    pub fn registerService(self: *Self, service_name: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, service_name);
        errdefer self.allocator.free(name_copy);

        try self.services.put(name_copy, .{
            .name = name_copy,
            .methods = std.StringHashMap(RegisteredMethod).init(self.allocator),
        });
    }

    /// 注册方法
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

    /// 根据路径查找处理器
    pub fn findHandler(self: *Self, path: []const u8) ?struct { method: GrpcMethod, handler: UnaryHandler } {
        var svc_iter = self.services.iterator();
        while (svc_iter.next()) |svc_entry| {
            if (svc_entry.value_ptr.methods.get(path)) |reg| {
                return .{ .method = reg.method, .handler = reg.handler };
            }
        }
        return null;
    }

    /// 列出所有注册的方法
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
};

/// Proto 文件解析器 (简化版)
/// 解析 .proto 文件提取 service/method/message 定义
pub const ProtoParser = struct {
    /// 解析结果: 服务定义
    pub const ProtoService = struct {
        name: []const u8,
        methods: []const ProtoMethod,
    };

    /// 解析结果: 方法定义
    pub const ProtoMethod = struct {
        name: []const u8,
        input_type: []const u8,
        output_type: []const u8,
        is_streaming: bool = false,
    };

    /// 解析 proto 文件内容
    pub fn parse(allocator: std.mem.Allocator, content: []const u8) ![]const ProtoService {
        var services = std.ArrayList(ProtoService).empty;

        var lines = std.mem.splitScalar(u8, content, '\n');
        var current_service: ?[]const u8 = null;
        var current_methods = std.ArrayList(ProtoMethod).empty;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r;");

            if (std.mem.startsWith(u8, trimmed, "service ")) {
                if (current_service) |svc| {
                    const svc_copy = try allocator.dupe(u8, svc);
                    const methods = try current_methods.toOwnedSlice(allocator);
                    try services.append(allocator, .{ .name = svc_copy, .methods = methods });
                    current_methods = std.ArrayList(ProtoMethod).empty;
                }
                const svc_name = std.mem.trim(u8, trimmed["service ".len..], " \t{");
                current_service = try allocator.dupe(u8, svc_name);
            } else if (std.mem.startsWith(u8, trimmed, "rpc ")) {
                // rpc MethodName(InputType) returns (OutputType);
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

/// gRPC 客户端存根
pub const GrpcClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    endpoints: std.StringHashMap(Endpoint),

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

    pub fn deinit(self: *Self) void {
        var iter = self.endpoints.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.address);
        }
        self.endpoints.deinit();
    }

    /// 注册服务端点
    pub fn registerEndpoint(self: *Self, service_name: []const u8, address: []const u8, port: u16) !void {
        const addr_copy = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(addr_copy);

        try self.endpoints.put(service_name, .{
            .address = addr_copy,
            .port = port,
        });
    }

    /// 调用远程 gRPC 服务 (单请求/响应)
    /// placeholder: 实际实现通过 HTTP/2 + protobuf 序列化
    pub fn call(self: *Self, service: []const u8, method: []const u8) !GrpcResponse {
        const ep = self.endpoints.get(service) orelse return error.EndpointNotFound;

        std.log.info("[gRPC] Calling {s}.{s} at {s}:{d}", .{ service, method, ep.address, ep.port });

        // Placeholder: actual implementation would serialize protobuf + HTTP/2
        // payload and endpoint are available for future transport implementation

        return GrpcResponse{
            .payload = "",
            .status = .UNIMPLEMENTED,
            .message = "gRPC client transport not yet implemented",
        };
    }
};

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

test "GrpcServiceRegistry list methods" {
    const allocator = std.testing.allocator;
    var registry = GrpcServiceRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerService("test.Service");
    try registry.registerMethod("test.Service", "Ping", .unary, struct {
        fn h(_: GrpcRequest) !GrpcResponse { return GrpcResponse{ .payload = "pong", .status = .OK, .message = "" }; }
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

test "GrpcClient endpoint registration" {
    const allocator = std.testing.allocator;
    var client = GrpcClient.init(allocator);
    defer client.deinit();

    try client.registerEndpoint("order.OrderService", "localhost", 50051);
    try std.testing.expectEqualStrings("localhost", client.endpoints.get("order.OrderService").?.address);

    const result = try client.call("order.OrderService", "CreateOrder");
    try std.testing.expectEqual(GrpcStatusCode.UNIMPLEMENTED, result.status);
}
