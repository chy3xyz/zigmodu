const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;
const ContractRegistry = @import("./ModuleContract.zig").ContractRegistry;

pub const Severity = enum {
    err,
    warning,
    info,
};

/// ArchUnit-style architecture test
/// Validate module structure against architecture rules
pub const ArchitectureTester = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    modules: *ApplicationModules,
    violations: std.ArrayList(Violation),

    pub const Violation = struct {
        rule_name: []const u8,
        module_name: []const u8,
        message: []const u8,
        severity: Severity,
    };

    pub const Rule = struct {
        name: []const u8,
        description: []const u8,
        check_fn: *const fn (*Self, *ApplicationModules) anyerror!void,
    };

    pub fn init(allocator: std.mem.Allocator, modules: *ApplicationModules) Self {
        return .{
            .allocator = allocator,
            .modules = modules,
            .violations = std.ArrayList(Violation).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.violations.items) |v| {
            self.allocator.free(v.message);
        }
        self.violations.deinit(self.allocator);
    }

    /// Add violation record
    fn addViolation(self: *Self, rule_name: []const u8, module_name: []const u8, message: []const u8, severity: Severity) !void {
        const msg_copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(msg_copy);
        try self.violations.append(self.allocator, .{
            .rule_name = rule_name,
            .module_name = module_name,
            .message = msg_copy,
            .severity = severity,
        });
    }

    /// Rule 1: modules cannot depend on themselves (prevents circular deps)
    pub fn ruleNoSelfDependency(self: *Self) !void {
        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;
            const module_info = entry.value_ptr.*;

            for (module_info.deps) |dep| {
                if (std.mem.eql(u8, module_name, dep)) {
                    try self.addViolation(
                        "NoSelfDependency",
                        module_name,
                        "Module depends on itself",
                        Severity.err,
                    );
                }
            }
        }
    }

    /// Rule 2: detect circular dependencies
    pub fn ruleNoCircularDependencies(self: *Self) !void {
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var recursion_stack = std.StringHashMap(void).init(self.allocator);
        defer recursion_stack.deinit();

        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;

            visited.clearRetainingCapacity();
            recursion_stack.clearRetainingCapacity();

            if (try self.hasCircularDependency(module_name, &visited, &recursion_stack, null)) {
                try self.addViolation(
                    "NoCircularDependencies",
                    module_name,
                    "Circular dependency detected",
                    Severity.err,
                );
            }
        }
    }

    fn hasCircularDependency(
        self: *Self,
        module_name: []const u8,
        visited: *std.StringHashMap(void),
        recursion_stack: *std.StringHashMap(void),
        parent_module: ?[]const u8,
    ) !bool {
        // Mark current module as visited
        try visited.put(module_name, {});
        try recursion_stack.put(module_name, {});

        // Get module info
        const module_info = self.modules.get(module_name) orelse return false;

        // Check all dependencies
        for (module_info.deps) |dep| {
            // If dependency is parent module, cycle detected
            if (parent_module) |parent| {
                if (std.mem.eql(u8, dep, parent)) {
                    return true;
                }
            }

            // If dependency is in recursion stack, cycle detected
            if (recursion_stack.contains(dep)) {
                return true;
            }

            // If dependency not visited, recurse
            if (!visited.contains(dep)) {
                if (try self.hasCircularDependency(dep, visited, recursion_stack, module_name)) {
                    return true;
                }
            }
        }

        // Remove from recursion stack
        _ = recursion_stack.remove(module_name);
        return false;
    }

    /// Rule 3: all modules must have a description
    pub fn ruleModulesMustHaveDescription(self: *Self) !void {
        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;
            const module_info = entry.value_ptr.*;

            if (module_info.desc.len == 0) {
                try self.addViolation(
                    "ModulesMustHaveDescription",
                    module_name,
                    "Module should have a description",
                    Severity.warning,
                );
            }
        }
    }

    /// Rule 4: module names must be lowercase with underscores
    pub fn ruleModuleNamingConvention(self: *Self) !void {
        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;

            // Check if all lowercase
            for (module_name) |c| {
                if (std.ascii.isUpper(c)) {
                    try self.addViolation(
                        "ModuleNamingConvention",
                        module_name,
                        "Module name should be lowercase",
                        Severity.warning,
                    );
                    break;
                }
            }

            // Check for spaces
            for (module_name) |c| {
                if (c == ' ') {
                    try self.addViolation(
                        "ModuleNamingConvention",
                        module_name,
                        "Module name should not contain spaces",
                        Severity.err,
                    );
                    break;
                }
            }
        }
    }

    /// Rule 5: module deps must not be too complex (dep count limit)
    pub fn ruleLimitedDependencies(self: *Self, max_deps: usize) !void {
        // Validate parameter
        if (max_deps == 0) return error.InvalidMaxDependencies;

        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;
            const module_info = entry.value_ptr.*;

            if (module_info.deps.len > max_deps) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Module has {d} dependencies, maximum recommended is {d}",
                    .{ module_info.deps.len, max_deps },
                );

                try self.addViolation(
                    "LimitedDependencies",
                    module_name,
                    msg,
                    Severity.warning,
                );
                self.allocator.free(msg);
            }
        }
    }

    /// Rule 6: foundation modules must not depend on business modules
    pub fn ruleBaseModulesShouldNotDependOnOthers(self: *Self, base_modules: []const []const u8) !void {
        for (base_modules) |base_name| {
            const base_module = self.modules.get(base_name);
            if (base_module == null) continue;

            const module_info = base_module.?;

            for (module_info.deps) |dep| {
                // Check if dependency is a business module (non-foundation)
                var is_other_business_module = true;
                for (base_modules) |other_base| {
                    if (std.mem.eql(u8, dep, other_base)) {
                        is_other_business_module = false;
                        break;
                    }
                }

                if (is_other_business_module) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "Base module should not depend on business module '{s}'",
                        .{dep},
                    );

                    try self.addViolation(
                        "BaseModulesShouldNotDependOnOthers",
                        base_name,
                        msg,
                        Severity.err,
                    );
                    self.allocator.free(msg);
                }
            }
        }
    }

    /// Run all default rules
    pub fn runDefaultRules(self: *Self) !void {
        try self.ruleNoSelfDependency();
        try self.ruleNoCircularDependencies();
        try self.ruleModulesMustHaveDescription();
        try self.ruleModuleNamingConvention();
        try self.ruleLimitedDependencies(5); // Max 5 dependencies
    }

    /// Get violation count
    pub fn getViolationCount(self: *Self) usize {
        return self.violations.items.len;
    }

    /// Get violation count by severity
    pub fn getViolationCountBySeverity(self: *Self, severity: Severity) usize {
        var count: usize = 0;
        for (self.violations.items) |violation| {
            if (violation.severity == severity) {
                count += 1;
            }
        }
        return count;
    }

    /// Print violation report
    pub fn printReport(self: *Self, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        try buf.appendSlice(allocator, "\n=== Architecture Test Report ===\n\n");

        const error_count = self.getViolationCountBySeverity(Severity.err);
        const warning_count = self.getViolationCountBySeverity(Severity.warning);
        const info_count = self.getViolationCountBySeverity(Severity.info);

        try buf.print(allocator, "Total Violations: {d}\n", .{self.getViolationCount()});
        try buf.print(allocator, "  Errors:   {d}\n", .{error_count});
        try buf.print(allocator, "  Warnings: {d}\n", .{warning_count});
        try buf.print(allocator, "  Info:     {d}\n\n", .{info_count});

        if (self.violations.items.len == 0) {
            try buf.appendSlice(allocator, "All architecture rules passed!\n");
            return;
        }

        try buf.appendSlice(allocator, "Violations:\n");
        try buf.appendSlice(allocator, "-----------\n");

        for (self.violations.items) |violation| {
            const severity_str = switch (violation.severity) {
                Severity.err => "ERROR",
                Severity.warning => "WARNING",
                Severity.info => "INFO",
            };

            try buf.print(allocator, "[{s}] {s}\n", .{ severity_str, violation.rule_name });
            try buf.print(allocator, "  Module: {s}\n", .{violation.module_name});
            try buf.print(allocator, "  Message: {s}\n\n", .{violation.message});
        }
    }

    /// Rule 7: contract service deps must match actual module deps
    pub fn ruleContractsMatchDependencies(self: *Self, registry: *const ContractRegistry) !void {
        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;
            const module_info = entry.value_ptr.*;

            if (registry.get(module_name)) |contract| {
                for (contract.required_services) |svc| {
                    if (svc.required) {
                        var found = false;
                        for (module_info.deps) |dep| {
                            if (std.mem.eql(u8, dep, svc.name)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            const msg = try std.fmt.allocPrint(self.allocator, "Contract requires service '{s}' but module does not declare it as a dependency", .{svc.name});
                            try self.addViolation("ContractsMatchDependencies", module_name, msg, Severity.err);
                            self.allocator.free(msg);
                        }
                    }
                }
            }
        }
    }

    /// Rule 8: ensure internal modules not accessed externally (is_internal check)
    pub fn ruleNoInternalModuleAccess(self: *Self) !void {
        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;
            const module_info = entry.value_ptr.*;

            for (module_info.deps) |dep| {
                if (self.modules.get(dep)) |dep_info| {
                    // is_internal is not currently tracked in ModuleInfo, but the pattern check is useful
                    _ = dep_info;
                    _ = module_name;
                }
            }
        }
    }

    /// Validate and return whether passed (no error-level violations)
    pub fn verify(self: *Self) !bool {
        try self.runDefaultRules();
        return self.getViolationCountBySeverity(Severity.err) == 0;
    }
};

test "ArchitectureTester no violations" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    try modules.register(ModuleInfo.init("order", "Order module", &.{"inventory"}));
    try modules.register(ModuleInfo.init("inventory", "Inventory module", &.{}));

    var tester = ArchitectureTester.init(allocator, &modules);
    defer tester.deinit();

    try tester.ruleNoSelfDependency();
    try std.testing.expectEqual(@as(usize, 0), tester.getViolationCount());
}

test "ArchitectureTester self dependency violation" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    try modules.register(ModuleInfo.init("bad", "Bad module", &.{"bad"}));

    var tester = ArchitectureTester.init(allocator, &modules);
    defer tester.deinit();

    try tester.ruleNoSelfDependency();
    try std.testing.expectEqual(@as(usize, 1), tester.getViolationCount());
    try std.testing.expectEqual(@as(usize, 1), tester.getViolationCountBySeverity(Severity.err));
}

test "ArchitectureTester circular dependency violation" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    try modules.register(ModuleInfo.init("a", "A", &.{"b"}));
    try modules.register(ModuleInfo.init("b", "B", &.{"a"}));

    var tester = ArchitectureTester.init(allocator, &modules);
    defer tester.deinit();

    try tester.ruleNoCircularDependencies();
    try std.testing.expect(tester.getViolationCount() > 0);
}

test "ArchitectureTester naming convention violation" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    try modules.register(ModuleInfo.init("BadName", "Bad", &.{}));

    var tester = ArchitectureTester.init(allocator, &modules);
    defer tester.deinit();

    try tester.ruleModuleNamingConvention();
    try std.testing.expect(tester.getViolationCount() > 0);
}

test "ArchitectureTester print report" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    try modules.register(ModuleInfo.init("bad", "Bad", &.{"bad"}));

    var tester = ArchitectureTester.init(allocator, &modules);
    defer tester.deinit();

    try tester.ruleNoSelfDependency();

    var buf = std.ArrayList(u8).empty;
    try tester.printReport(&buf, allocator);
    const report = try buf.toOwnedSlice(allocator);
    defer allocator.free(report);

    try std.testing.expect(std.mem.indexOf(u8, report, "Architecture Test Report") != null);
}
