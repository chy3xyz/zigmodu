const std = @import("std");

/// ModuleContract - Runtime contract verification for modules
/// Module contract definition
/// Explicitly declares the module's published/consumed events, provided APIs, and dependencies
/// High-priority architecture improvement item for inter-module contract clarity
pub const ModuleContract = struct {
    const Self = @This();

    /// Module name
    name: []const u8,

    /// Module description
    description: []const u8 = "",

    /// Published event types (events this module emits)
    published_events: []const EventDefinition = &.{},

    /// Consumed event types (events this module listens to)
    consumed_events: []const EventDefinition = &.{},

    /// Provided API endpoints
    provided_apis: []const ApiDefinition = &.{},

    /// Dependent service interfaces
    required_services: []const ServiceDependency = &.{},

    /// Configuration properties
    configuration: []const ConfigProperty = &.{},

    /// Event definition
    pub const EventDefinition = struct {
        /// Event type name (e.g. "OrderCreated", "PaymentCompleted")
        name: []const u8,

        /// Event description
        description: []const u8 = "",

        /// Event payload type, given as a type name string (e.g. "OrderPayload")
        payload_type: []const u8,

        /// Whether this is a domain event (Domain Event)
        is_domain_event: bool = true,

        /// Event version (used for event evolution)
        version: u32 = 1,

        /// Whether the event is persisted to the event store
        persistent: bool = true,
    };

    /// API endpoint definition
    pub const ApiDefinition = struct {
        /// API name
        name: []const u8,

        /// API description
        description: []const u8 = "",

        /// HTTP method (for REST APIs)
        http_method: HttpMethod = .GET,

        /// API path
        path: []const u8 = "",

        /// Request type name
        request_type: []const u8 = "void",

        /// Response type name
        response_type: []const u8 = "void",

        /// Whether the endpoint is public (no authentication required)
        is_public: bool = false,

        /// Required permissions
        required_permissions: []const []const u8 = &.{},
    };

    /// HTTP method enum
    pub const HttpMethod = enum {
        GET,
        POST,
        PUT,
        DELETE,
        PATCH,
    };

    /// Service dependency definition
    pub const ServiceDependency = struct {
        /// Service name
        name: []const u8,

        /// Service description
        description: []const u8 = "",

        /// Whether the dependency is required
        required: bool = true,

        /// Service interface name
        interface_type: []const u8,
    };

    /// Configuration property definition
    pub const ConfigProperty = struct {
        /// Configuration key
        key: []const u8,

        /// Configuration description
        description: []const u8 = "",

        /// Configuration type
        property_type: ConfigType = .String,

        /// Default value (string representation)
        default_value: ?[]const u8 = null,

        /// Whether the property is required
        required: bool = false,
    };

    /// Configuration type enum
    pub const ConfigType = enum {
        String,
        Integer,
        Boolean,
        Float,
    };

    /// Contract validation result
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
            self.* = undefined;
        }

        pub fn addError(self: *ValidationResult, msg: []const u8) !void {
            self.valid = false;
            const allocator = self.errors.allocator;
            const copy = try allocator.dupe(u8, msg);
            try self.errors.append(copy);
        }
    };

    /// Validates the contract definition
    pub fn validate(self: *const Self, allocator: std.mem.Allocator) !ValidationResult {
        var result = ValidationResult.init(allocator);
        errdefer result.deinit();

        // Validate module name
        if (self.name.len == 0) {
            try result.addError("Module name cannot be empty");
        }

        // Validate published events
        for (self.published_events) |event| {
            if (event.name.len == 0) {
                try result.addError("Publish event name cannot be empty");
            }
            if (event.payload_type.len == 0) {
                try result.addError(try std.fmt.allocPrint(allocator, "Event '{s}' payload type cannot be empty", .{event.name}));
            }
        }

        // Validate consumed events
        for (self.consumed_events) |event| {
            if (event.name.len == 0) {
                try result.addError("Consume event name cannot be empty");
            }
        }

        // Validate API definitions
        for (self.provided_apis) |api| {
            if (api.name.len == 0) {
                try result.addError("API name cannot be empty");
            }
        }

        // Validate service dependencies
        for (self.required_services) |service| {
            if (service.name.len == 0) {
                try result.addError("Dependent service name cannot be empty");
            }
            if (service.interface_type.len == 0) {
                try result.addError(try std.fmt.allocPrint(allocator, "Service '{s}' interface type cannot be empty", .{service.name}));
            }
        }

        return result;
    }

    /// Generates the PlantUML component diagram description
    pub fn generatePlantUml(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();
        const writer = buf.writer();

        try writer.print("component \"{s}\" as {s} {{\n", .{ self.name, self.name });

        // Add the description
        if (self.description.len > 0) {
            try writer.print("  note right: {s}\n", .{self.description});
        }

        // Add the published events
        if (self.published_events.len > 0) {
            try writer.interface.writeAll("  portout PUBLISHED_EVENTS\n");
        }

        // Add the consumed events
        if (self.consumed_events.len > 0) {
            try writer.interface.writeAll("  portin CONSUMED_EVENTS\n");
        }

        // Add the API endpoints
        if (self.provided_apis.len > 0) {
            try writer.interface.writeAll("  portout APIS\n");
        }

        try writer.interface.writeAll("}\n");

        // Add notes with the event details
        for (self.published_events) |event| {
            try writer.print("note right of {s}::PUBLISHED_EVENTS : publishes {s}({s})\n", .{ self.name, event.name, event.payload_type });
        }

        for (self.consumed_events) |event| {
            try writer.print("note left of {s}::CONSUMED_EVENTS : consumes {s}({s})\n", .{ self.name, event.name, event.payload_type });
        }

        return buf.toOwnedSlice();
    }
};

/// Contract registry - manages the contracts of all modules
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
        self.* = undefined;
    }

    /// Registers a module contract
    pub fn register(self: *Self, contract: ModuleContract) !void {
        try self.contracts.put(contract.name, contract);
        std.log.info("Registered module contract: {s}", .{contract.name});
    }

    /// Gets a module contract
    pub fn get(self: *Self, module_name: []const u8) ?ModuleContract {
        return self.contracts.get(module_name);
    }

    /// Validates the compatibility of all contracts
    /// Checks whether event publishers and consumers match
    pub fn validateContracts(self: *Self, allocator: std.mem.Allocator) !ModuleContract.ValidationResult {
        var result = ModuleContract.ValidationResult.init(allocator);
        errdefer result.deinit();

        var iter = self.contracts.iterator();
        while (iter.next()) |entry| {
            const contract = entry.value_ptr.*;

            // Validate each contract
            var validation = try contract.validate(allocator);
            defer validation.deinit();

            if (!validation.valid) {
                for (validation.errors.items) |err| {
                    const msg = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ contract.name, err });
                    try result.addError(msg);
                    allocator.free(msg);
                }
            }

            // Check if dependent service exists
            for (contract.required_services) |service| {
                if (self.contracts.get(service.name) == null and service.required) {
                    const msg = try std.fmt.allocPrint(allocator, "[{s}] dependency service '{s}' not found", .{ contract.name, service.name });
                    try result.addError(msg);
                    allocator.free(msg);
                }
            }
        }

        // Check event compatibility
        try self.validateEventCompatibility(&result);

        return result;
    }

    /// Validates event publish/consume compatibility
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

                            // Check if load type matches
                            if (!std.mem.eql(u8, consumed_event.payload_type, published_event.payload_type)) {
                                const msg = try std.fmt.allocPrint(result.errors.allocator, "[{s}] consumed event '{s}' payload type mismatch with publisher [{s}] match: {s} vs {s}", .{ consumer.name, consumed_event.name, publisher.name, consumed_event.payload_type, published_event.payload_type });
                                try result.addError(msg);
                                result.errors.allocator.free(msg);
                            }
                            break;
                        }
                    }

                    if (found) break;
                }

                if (!found) {
                    const msg = try std.fmt.allocPrint(result.errors.allocator, "[{s}] consumed event '{s}' has no corresponding publisher", .{ consumer.name, consumed_event.name });
                    try result.addError(msg);
                    result.errors.allocator.free(msg);
                }
            }
        }
    }

    /// Generates the PlantUML diagram of all contracts
    pub fn generatePlantUmlDiagram(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();
        const writer = buf.writer();

        try writer.interface.writeAll("@startuml\n");
        try writer.interface.writeAll("!theme plain\n");
        try writer.interface.writeAll("skinparam componentStyle rectangle\n\n");
        try writer.interface.writeAll("title Module Contracts\n\n");

        // Generate each component
        var iter = self.contracts.iterator();
        while (iter.next()) |entry| {
            const contract = entry.value_ptr.*;
            const component_uml = try contract.generatePlantUml(allocator);
            defer allocator.free(component_uml);
            try writer.interface.writeAll(component_uml);
            try writer.interface.writeAll("\n");
        }

        // Generate the event dependency relations
        try self.generateEventRelations(writer);

        try writer.interface.writeAll("\n@enduml\n");

        return buf.toOwnedSlice();
    }

    /// Generates the event relations
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

/// Example: creates a contract for the order module
pub fn createOrderModuleContract() ModuleContract {
    return .{
        .name = "order",
        .description = "Order management module",
        .published_events = &.{
            .{
                .name = "OrderCreated",
                .description = "Order created",
                .payload_type = "OrderCreatedPayload",
                .is_domain_event = true,
            },
            .{
                .name = "OrderPaid",
                .description = "Order paid",
                .payload_type = "OrderPaidPayload",
                .is_domain_event = true,
            },
        },
        .consumed_events = &.{
            .{
                .name = "InventoryReserved",
                .description = "Inventory reserved",
                .payload_type = "InventoryReservedPayload",
            },
            .{
                .name = "PaymentCompleted",
                .description = "Payment done",
                .payload_type = "PaymentCompletedPayload",
            },
        },
        .provided_apis = &.{
            .{
                .name = "createOrder",
                .description = "Create order",
                .http_method = .POST,
                .path = "/api/orders",
                .request_type = "CreateOrderRequest",
                .response_type = "OrderResponse",
            },
            .{
                .name = "getOrder",
                .description = "Get order details",
                .http_method = .GET,
                .path = "/api/orders/{id}",
                .response_type = "OrderResponse",
            },
        },
        .required_services = &.{
            .{
                .name = "inventory",
                .description = "Inventory service",
                .interface_type = "InventoryService",
                .required = true,
            },
            .{
                .name = "payment",
                .description = "Payment service",
                .interface_type = "PaymentService",
                .required = true,
            },
        },
        .configuration = &.{
            .{
                .key = "order.timeout_minutes",
                .description = "Order timeout (minutes)",
                .property_type = .Integer,
                .default_value = "30",
            },
            .{
                .key = "order.max_items",
                .description = "Max items per order",
                .property_type = .Integer,
                .default_value = "100",
            },
        },
    };
}

// Tests
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
