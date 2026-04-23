const std = @import("std");

/// ModuleContract - Runtime contract verification for modules
/// 模块契约定义
/// 显式声明模块发布/消费的事件、提供的API和依赖的服务
/// 这是架构评估中的高优先级改进项，用于提高模块间的契约清晰度
pub const ModuleContract = struct {
    const Self = @This();

    /// 模块名称
    name: []const u8,

    /// 模块描述
    description: []const u8 = "",

    /// 发布的事件类型（该模块会发送这些事件）
    published_events: []const EventDefinition = &.{},

    /// 消费的事件类型（该模块会监听这些事件）
    consumed_events: []const EventDefinition = &.{},

    /// 提供的API接口
    provided_apis: []const ApiDefinition = &.{},

    /// 依赖的服务接口
    required_services: []const ServiceDependency = &.{},

    /// 配置属性定义
    configuration: []const ConfigProperty = &.{},

    /// 事件定义
    pub const EventDefinition = struct {
        /// 事件类型名称（如 "OrderCreated", "PaymentCompleted"）
        name: []const u8,

        /// 事件描述
        description: []const u8 = "",

        /// 事件负载类型（用类型名称字符串表示，如 "OrderPayload"）
        payload_type: []const u8,

        /// 是否是领域事件（Domain Event）
        is_domain_event: bool = true,

        /// 事件版本（用于事件演进）
        version: u32 = 1,

        /// 是否持久化到事件存储
        persistent: bool = true,
    };

    /// API接口定义
    pub const ApiDefinition = struct {
        /// API名称
        name: []const u8,

        /// API描述
        description: []const u8 = "",

        /// HTTP方法（如果是REST API）
        http_method: HttpMethod = .GET,

        /// API路径
        path: []const u8 = "",

        /// 请求类型名称
        request_type: []const u8 = "void",

        /// 响应类型名称
        response_type: []const u8 = "void",

        /// 是否公开（不需要认证）
        is_public: bool = false,

        /// 所需权限
        required_permissions: []const []const u8 = &.{},
    };

    /// HTTP方法枚举
    pub const HttpMethod = enum {
        GET,
        POST,
        PUT,
        DELETE,
        PATCH,
    };

    /// 服务依赖定义
    pub const ServiceDependency = struct {
        /// 服务名称
        name: []const u8,

        /// 服务描述
        description: []const u8 = "",

        /// 是否是必需的依赖
        required: bool = true,

        /// 服务接口名称
        interface_type: []const u8,
    };

    /// 配置属性定义
    pub const ConfigProperty = struct {
        /// 配置键
        key: []const u8,

        /// 配置描述
        description: []const u8 = "",

        /// 配置类型
        property_type: ConfigType = .String,

        /// 默认值（字符串表示）
        default_value: ?[]const u8 = null,

        /// 是否必需
        required: bool = false,
    };

    /// 配置类型枚举
    pub const ConfigType = enum {
        String,
        Integer,
        Boolean,
        Float,
    };

    /// 契约验证结果
    pub const ValidationResult = struct {
        valid: bool,
        errors: std.array_list.Managed([]const u8),

        pub fn init(allocator: std.mem.Allocator) ValidationResult {
            return .{
                .valid = true,
                .errors = std.array_list.Managed([]const u8).init(allocator),
            };
        }

        pub fn deinit(self: *ValidationResult) void {
            const allocator = self.errors.allocator;
            for (self.errors.items) |err| {
                allocator.free(err);
            }
            self.errors.deinit();
        }

        pub fn addError(self: *ValidationResult, msg: []const u8) !void {
            self.valid = false;
            const allocator = self.errors.allocator;
            const copy = try allocator.dupe(u8, msg);
            try self.errors.append(copy);
        }
    };

    /// 验证契约定义的有效性
    pub fn validate(self: *const Self, allocator: std.mem.Allocator) !ValidationResult {
        var result = ValidationResult.init(allocator);
        errdefer result.deinit();

        // 验证模块名称
        if (self.name.len == 0) {
            try result.addError("模块名称不能为空");
        }

        // 验证发布的事件
        for (self.published_events) |event| {
            if (event.name.len == 0) {
                try result.addError("发布事件的名称不能为空");
            }
            if (event.payload_type.len == 0) {
                try result.addError(try std.fmt.allocPrint(allocator, "事件 '{s}' 的负载类型不能为空", .{event.name}));
            }
        }

        // 验证消费的 事件
        for (self.consumed_events) |event| {
            if (event.name.len == 0) {
                try result.addError("消费事件的名称不能为空");
            }
        }

        // 验证API定义
        for (self.provided_apis) |api| {
            if (api.name.len == 0) {
                try result.addError("API名称不能为空");
            }
        }

        // 验证服务依赖
        for (self.required_services) |service| {
            if (service.name.len == 0) {
                try result.addError("依赖服务的名称不能为空");
            }
            if (service.interface_type.len == 0) {
                try result.addError(try std.fmt.allocPrint(allocator, "服务 '{s}' 的接口类型不能为空", .{service.name}));
            }
        }

        return result;
    }

    /// 生成PlantUML组件图描述
    pub fn generatePlantUml(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();
        const writer = buf.writer();

        try writer.print("component \"{s}\" as {s} {{\n", .{ self.name, self.name });

        // 添加描述
        if (self.description.len > 0) {
            try writer.print("  note right: {s}\n", .{self.description});
        }

        // 添加发布的事件
        if (self.published_events.len > 0) {
            try writer.writeAll("  portout PUBLISHED_EVENTS\n");
        }

        // 添加消费的事件
        if (self.consumed_events.len > 0) {
            try writer.writeAll("  portin CONSUMED_EVENTS\n");
        }

        // 添加API接口
        if (self.provided_apis.len > 0) {
            try writer.writeAll("  portout APIS\n");
        }

        try writer.writeAll("}\n");

        // 添加事件详情注释
        for (self.published_events) |event| {
            try writer.print("note right of {s}::PUBLISHED_EVENTS : publishes {s}({s})\n", .{ self.name, event.name, event.payload_type });
        }

        for (self.consumed_events) |event| {
            try writer.print("note left of {s}::CONSUMED_EVENTS : consumes {s}({s})\n", .{ self.name, event.name, event.payload_type });
        }

        return buf.toOwnedSlice();
    }
};

/// 契约注册表 - 管理所有模块的契约
pub const ContractRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    contracts: std.StringHashMap(ModuleContract),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .contracts = std.StringHashMap(ModuleContract).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.contracts.deinit();
    }

    /// 注册模块契约
    pub fn register(self: *Self, contract: ModuleContract) !void {
        try self.contracts.put(contract.name, contract);
        std.log.info("已注册模块契约: {s}", .{contract.name});
    }

    /// 获取模块契约
    pub fn get(self: *Self, module_name: []const u8) ?ModuleContract {
        return self.contracts.get(module_name);
    }

    /// 验证所有契约的兼容性
    /// 检查事件发布者和消费者是否匹配
    pub fn validateContracts(self: *Self, allocator: std.mem.Allocator) !ModuleContract.ValidationResult {
        var result = ModuleContract.ValidationResult.init(allocator);
        errdefer result.deinit();

        var iter = self.contracts.iterator();
        while (iter.next()) |entry| {
            const contract = entry.value_ptr.*;

            // 验证每个契约
            var validation = try contract.validate(allocator);
            defer validation.deinit();

            if (!validation.valid) {
                for (validation.errors.items) |err| {
                    const msg = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ contract.name, err });
                    try result.addError(msg);
                    allocator.free(msg);
                }
            }

            // 检查依赖的服务是否存在
            for (contract.required_services) |service| {
                if (self.contracts.get(service.name) == null and service.required) {
                    const msg = try std.fmt.allocPrint(allocator, "[{s}] 依赖的服务 '{s}' 未找到", .{ contract.name, service.name });
                    try result.addError(msg);
                    allocator.free(msg);
                }
            }
        }

        // 检查事件兼容性
        try self.validateEventCompatibility(&result);

        return result;
    }

    /// 验证事件发布/消费的兼容性
    fn validateEventCompatibility(self: *Self, result: *ModuleContract.ValidationResult) !void {
        var consumer_iter = self.contracts.iterator();
        while (consumer_iter.next()) |consumer_entry| {
            const consumer = consumer_entry.value_ptr.*;

            for (consumer.consumed_events) |consumed_event| {
                var found = false;

                var publisher_iter = self.contracts.iterator();
                while (publisher_iter.next()) |publisher_entry| {
                    const publisher = publisher_entry.value_ptr.*;

                    for (publisher.published_events) |published_event| {
                        if (std.mem.eql(u8, consumed_event.name, published_event.name)) {
                            found = true;

                            // 检查负载类型是否匹配
                            if (!std.mem.eql(u8, consumed_event.payload_type, published_event.payload_type)) {
                                const msg = try std.fmt.allocPrint(result.errors.allocator, "[{s}] 消费的事件 '{s}' 负载类型与发布者 [{s}] 不匹配: {s} vs {s}", .{ consumer.name, consumed_event.name, publisher.name, consumed_event.payload_type, published_event.payload_type });
                                try result.addError(msg);
                                result.errors.allocator.free(msg);
                            }
                            break;
                        }
                    }

                    if (found) break;
                }

                if (!found) {
                    const msg = try std.fmt.allocPrint(result.errors.allocator, "[{s}] 消费的事件 '{s}' 没有对应的发布者", .{ consumer.name, consumed_event.name });
                    try result.addError(msg);
                    result.errors.allocator.free(msg);
                }
            }
        }
    }

    /// 生成所有契约的PlantUML图
    pub fn generatePlantUmlDiagram(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();
        const writer = buf.writer();

        try writer.writeAll("@startuml\n");
        try writer.writeAll("!theme plain\n");
        try writer.writeAll("skinparam componentStyle rectangle\n\n");
        try writer.writeAll("title Module Contracts\n\n");

        // 生成每个组件
        var iter = self.contracts.iterator();
        while (iter.next()) |entry| {
            const contract = entry.value_ptr.*;
            const component_uml = try contract.generatePlantUml(allocator);
            defer allocator.free(component_uml);
            try writer.writeAll(component_uml);
            try writer.writeAll("\n");
        }

        // 生成事件依赖关系
        try self.generateEventRelations(writer);

        try writer.writeAll("\n@enduml\n");

        return buf.toOwnedSlice();
    }

    /// 生成事件关系
    fn generateEventRelations(self: *Self, writer: anytype) !void {
        var consumer_iter = self.contracts.iterator();
        while (consumer_iter.next()) |consumer_entry| {
            const consumer = consumer_entry.value_ptr.*;

            for (consumer.consumed_events) |consumed_event| {
                var publisher_iter = self.contracts.iterator();
                while (publisher_iter.next()) |publisher_entry| {
                    const publisher = publisher_entry.value_ptr.*;

                    for (publisher.published_events) |published_event| {
                        if (std.mem.eql(u8, consumed_event.name, published_event.name)) {
                            try writer.print("{s}::PUBLISHED_EVENTS --> {s}::CONSUMED_EVENTS : {s}\n", .{ publisher.name, consumer.name, consumed_event.name });
                        }
                    }
                }
            }
        }
    }
};

/// 示例：创建一个订单模块契约
pub fn createOrderModuleContract() ModuleContract {
    return .{
        .name = "order",
        .description = "订单管理模块",
        .published_events = &.{
            .{
                .name = "OrderCreated",
                .description = "订单已创建",
                .payload_type = "OrderCreatedPayload",
                .is_domain_event = true,
            },
            .{
                .name = "OrderPaid",
                .description = "订单已支付",
                .payload_type = "OrderPaidPayload",
                .is_domain_event = true,
            },
        },
        .consumed_events = &.{
            .{
                .name = "InventoryReserved",
                .description = "库存已预留",
                .payload_type = "InventoryReservedPayload",
            },
            .{
                .name = "PaymentCompleted",
                .description = "支付完成",
                .payload_type = "PaymentCompletedPayload",
            },
        },
        .provided_apis = &.{
            .{
                .name = "createOrder",
                .description = "创建订单",
                .http_method = .POST,
                .path = "/api/orders",
                .request_type = "CreateOrderRequest",
                .response_type = "OrderResponse",
            },
            .{
                .name = "getOrder",
                .description = "获取订单详情",
                .http_method = .GET,
                .path = "/api/orders/{id}",
                .response_type = "OrderResponse",
            },
        },
        .required_services = &.{
            .{
                .name = "inventory",
                .description = "库存服务",
                .interface_type = "InventoryService",
                .required = true,
            },
            .{
                .name = "payment",
                .description = "支付服务",
                .interface_type = "PaymentService",
                .required = true,
            },
        },
        .configuration = &.{
            .{
                .key = "order.timeout_minutes",
                .description = "订单超时时间（分钟）",
                .property_type = .Integer,
                .default_value = "30",
            },
            .{
                .key = "order.max_items",
                .description = "单个订单最大商品数",
                .property_type = .Integer,
                .default_value = "100",
            },
        },
    };
}

// 测试
const testing = std.testing;

test "ModuleContract validation" {
    const allocator = testing.allocator;

    var contract = createOrderModuleContract();
    var result = try contract.validate(allocator);
    defer result.deinit();

    try testing.expect(result.valid);
}

test "ContractRegistry" {
    const allocator = testing.allocator;

    var registry = ContractRegistry.init(allocator);
    defer registry.deinit();

    const order_contract = createOrderModuleContract();
    try registry.register(order_contract);

    const retrieved = registry.get("order");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("order", retrieved.?.name);
}
