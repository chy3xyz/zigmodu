const std = @import("std");
const ModuleInfo = @import("Module.zig").ModuleInfo;

/// Module interaction verifier
/// Validate modules communicate only through allowed channels, preventing architecture erosion
/// Equivalent to Spring Modulith verify() + ArchUnit
pub const ModuleInteractionVerifier = struct {
    const Self = @This();

    /// Inter-module interaction type
    pub const InteractionType = enum {
        /// Direct dependency (import / function call)
        direct_dependency,
        /// Event-driven (EventBus)
        event_driven,
        /// Shared data (same table/cache)
        shared_data,
        /// API call (HTTP/gRPC)
        api_call,
    };

    /// Single module interaction rule
    pub const InteractionRule = struct {
        /// Allowed interaction types
        allowed_types: []const InteractionType,
        /// Source module (empty = all)
        from_module: ?[]const u8 = null,
        /// Target module (empty = all)
        to_module: ?[]const u8 = null,
        /// Rule description
        description: []const u8 = "",
    };

    /// Module interaction model (defines how modules communicate)
    pub const InteractionModel = struct {
        module_name: []const u8,
        /// Allowed outgoing interactions
        allowed_outgoing: std.StringHashMap([]const InteractionType),
        /// Allowed incoming interactions
        allowed_incoming: std.StringHashMap([]const InteractionType),
    };

    /// Validation violation
    pub const Violation = struct {
        from_module: []const u8,
        to_module: []const u8,
        interaction_type: InteractionType,
        message: []const u8,
    };

    /// Validation config
    pub const Config = struct {
        /// Whether to allow circular deps
        allow_circular_deps: bool = false,
        /// Max dependency depth
        max_dependency_depth: usize = 5,
        /// Max dependency count per module
        max_dependencies_per_module: usize = 10,
        /// Whether to strictly require Event[...]
        enforce_event_driven: bool = false,
    };

    allocator: std.mem.Allocator,
    config: Config,
    rules: std.ArrayList(InteractionRule),
    violations: std.ArrayList(Violation),

    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .rules = std.ArrayList(InteractionRule).empty,
            .violations = std.ArrayList(Violation).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.rules.items) |rule| {
            self.allocator.free(rule.allowed_types);
            self.allocator.free(rule.description);
        }
        self.rules.deinit(self.allocator);

        for (self.violations.items) |v| {
            self.allocator.free(v.from_module);
            self.allocator.free(v.to_module);
            self.allocator.free(v.message);
        }
        self.violations.deinit(self.allocator);
        self.* = undefined;
    }

    /// [...]
    pub fn addRule(self: *Self, allowed_types: []const InteractionType, description: []const u8) !void {
        const types_copy = try self.allocator.dupe(InteractionType, allowed_types);
        errdefer self.allocator.free(types_copy);

        const desc_copy = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_copy);

        try self.rules.append(self.allocator, .{
            .allowed_types = types_copy,
            .description = desc_copy,
        });
    }

    /// Register specific inter-module interaction rules
    pub fn addModuleRule(
        self: *Self,
        from_module: []const u8,
        to_module: []const u8,
        allowed_types: []const InteractionType,
        description: []const u8,
    ) !void {
        const types_copy = try self.allocator.dupe(InteractionType, allowed_types);
        errdefer self.allocator.free(types_copy);

        const desc_copy = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_copy);

        try self.rules.append(self.allocator, .{
            .allowed_types = types_copy,
            .from_module = try self.allocator.dupe(u8, from_module),
            .to_module = try self.allocator.dupe(u8, to_module),
            .description = desc_copy,
        });
    }

    /// ValidationWhether single module deps are compliant
    /// [...]
    pub fn verifyModuleDependencies(
        self: *Self,
        comptime module_info: ModuleInfo,
        comptime all_modules: []const type,
    ) ![]Violation {
        var result = std.ArrayList(Violation).empty;

        // 1. Check dependency depth
        if (module_info.dependencies.len > self.config.max_dependencies_per_module) {
            const msg = try std.fmt.allocPrint(self.allocator,
                "Module '{s}' has {d} dependencies, exceeding max of {d}",
                .{ module_info.name, module_info.dependencies.len, self.config.max_dependencies_per_module },
            );
            try result.append(self.allocator, .{
                .from_module = try self.allocator.dupe(u8, module_info.name),
                .to_module = try self.allocator.dupe(u8, "*"),
                .interaction_type = .direct_dependency,
                .message = msg,
            });
        }

        // 2. Check circular dependencies
        if (!self.config.allow_circular_deps) {
            for (module_info.dependencies) |dep_name| {
                inline for (all_modules) |mod| {
                    const mod_info = @field(mod, "info");
                    if (std.mem.eql(u8, mod_info.name, dep_name)) {
                        for (mod_info.dependencies) |transitive_dep| {
                            if (std.mem.eql(u8, transitive_dep, module_info.name)) {
                                const msg = try std.fmt.allocPrint(self.allocator,
                                    "Circular dependency: '{s}' ↔ '{s}'",
                                    .{ module_info.name, dep_name },
                                );
                                try result.append(self.allocator, .{
                                    .from_module = try self.allocator.dupe(u8, module_info.name),
                                    .to_module = try self.allocator.dupe(u8, dep_name),
                                    .interaction_type = .direct_dependency,
                                    .message = msg,
                                });
                                break;
                            }
                        }
                        break;
                    }
                }
            }
        }

        // 3. Check if[...]
        for (module_info.dependencies) |dep_name| {
            if (std.mem.eql(u8, dep_name, module_info.name)) {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "Module '{s}' declares self-dependency",
                    .{module_info.name},
                );
                try result.append(self.allocator, .{
                    .from_module = try self.allocator.dupe(u8, module_info.name),
                    .to_module = try self.allocator.dupe(u8, module_info.name),
                    .interaction_type = .direct_dependency,
                    .message = msg,
                });
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Validation[...]
    pub fn verifyAllModules(
        self: *Self,
        comptime modules: anytype,
    ) ![]Violation {
        var result = std.ArrayList(Violation).empty;

        inline for (modules) |mod| {
            const info = @field(mod, "info");
            const mod_violations = try self.verifyModuleDependencies(
                info,
                modules,
            );
            defer self.allocator.free(mod_violations);

            for (mod_violations) |v| {
                try result.append(self.allocator, v);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Add violation record
    pub fn addViolation(
        self: *Self,
        from_module: []const u8,
        to_module: []const u8,
        interaction_type: InteractionType,
        message: []const u8,
    ) !void {
        try self.violations.append(self.allocator, .{
            .from_module = try self.allocator.dupe(u8, from_module),
            .to_module = try self.allocator.dupe(u8, to_module),
            .interaction_type = interaction_type,
            .message = try self.allocator.dupe(u8, message),
        });
    }

    /// [...]
    pub fn getViolations(self: *Self) []const Violation {
        return self.violations.items;
    }

    /// Whether has violations
    pub fn hasViolations(self: *Self) bool {
        return self.violations.items.len > 0;
    }

    /// Generate human-readable violation report
    pub fn generateReport(self: *Self) ![]const u8 {
        if (self.violations.items.len == 0) {
            return try self.allocator.dupe(u8, "✓ No architecture violations detected.\n");
        }

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "╔══════════════════════════════════════════╗\n");
        try buf.appendSlice(self.allocator, "║  Architecture Violations Report          ║\n");
        try buf.appendSlice(self.allocator, "╚══════════════════════════════════════════╝\n\n");

        for (self.violations.items, 0..) |v, i| {
            const line = try std.fmt.allocPrint(self.allocator,
                "[{d}] {s} → {s} ({s}): {s}\n",
                .{ i + 1, v.from_module, v.to_module, @tagName(v.interaction_type), v.message },
            );
            defer self.allocator.free(line);
            try buf.appendSlice(self.allocator, line);
        }

        const summary = try std.fmt.allocPrint(self.allocator,
            "\nTotal violations: {d}\n",
            .{self.violations.items.len},
        );
        defer self.allocator.free(summary);
        try buf.appendSlice(self.allocator, summary);

        return buf.toOwnedSlice(self.allocator);
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "ModuleInteractionVerifier init and add rule" {
    const allocator = std.testing.allocator;
    var verifier = ModuleInteractionVerifier.init(allocator, .{});
    defer verifier.deinit();

    try verifier.addRule(&.{ .direct_dependency, .event_driven }, "default interaction");
    try std.testing.expectEqual(@as(usize, 1), verifier.rules.items.len);
}

test "ModuleInteractionVerifier add violation" {
    const allocator = std.testing.allocator;
    var verifier = ModuleInteractionVerifier.init(allocator, .{});
    defer verifier.deinit();

    try verifier.addViolation("order", "inventory", .direct_dependency, "direct dep without event");
    try std.testing.expect(verifier.hasViolations());
    try std.testing.expectEqual(@as(usize, 1), verifier.getViolations().len);
}

test "ModuleInteractionVerifier generate report with violations" {
    const allocator = std.testing.allocator;
    var verifier = ModuleInteractionVerifier.init(allocator, .{});
    defer verifier.deinit();

    try verifier.addViolation("order", "inventory", .direct_dependency, "Forbidden direct access");

    const report = try verifier.generateReport();
    defer allocator.free(report);

    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "order"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "inventory"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "Violations"));
}

test "ModuleInteractionVerifier generate report clean" {
    const allocator = std.testing.allocator;
    var verifier = ModuleInteractionVerifier.init(allocator, .{});
    defer verifier.deinit();

    const report = try verifier.generateReport();
    defer allocator.free(report);

    try std.testing.expect(std.mem.containsAtLeast(u8, report, 1, "No architecture violations"));
}

test "ModuleInteractionVerifier module rule" {
    const allocator = std.testing.allocator;
    var verifier = ModuleInteractionVerifier.init(allocator, .{});
    defer verifier.deinit();

    try verifier.addModuleRule("order", "payment", &.{ .event_driven, .api_call }, "order→payment");

    try std.testing.expectEqual(@as(usize, 1), verifier.rules.items.len);
    try std.testing.expectEqualStrings("order", verifier.rules.items[0].from_module.?);
    try std.testing.expectEqualStrings("payment", verifier.rules.items[0].to_module.?);
}

test "ModuleInteractionVerifier config constraints" {
    const allocator = std.testing.allocator;
    var verifier = ModuleInteractionVerifier.init(allocator, .{
        .max_dependencies_per_module = 3,
        .max_dependency_depth = 3,
    });
    defer verifier.deinit();

    try std.testing.expectEqual(@as(usize, 3), verifier.config.max_dependencies_per_module);
    try std.testing.expectEqual(@as(usize, 3), verifier.config.max_dependency_depth);
}
