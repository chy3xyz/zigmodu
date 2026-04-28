const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;

pub const Severity = enum {
    err,
    warning,
    info,
};

/// ArchUnit风格的架构测试
/// 验证模块结构是否符合架构规则
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

    /// 添加违规记录
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

    /// 规则1: 模块不能依赖自身（防止循环依赖）
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

    /// 规则2: 检测循环依赖
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
        // 标记当前模块为已访问
        try visited.put(module_name, {});
        try recursion_stack.put(module_name, {});

        // 获取模块信息
        const module_info = self.modules.get(module_name) orelse return false;

        // 检查所有依赖
        for (module_info.deps) |dep| {
            // 如果依赖是父模块，说明有循环
            if (parent_module) |parent| {
                if (std.mem.eql(u8, dep, parent)) {
                    return true;
                }
            }

            // 如果依赖在递归栈中，说明有循环
            if (recursion_stack.contains(dep)) {
                return true;
            }

            // 如果依赖未访问，递归检查
            if (!visited.contains(dep)) {
                if (try self.hasCircularDependency(dep, visited, recursion_stack, module_name)) {
                    return true;
                }
            }
        }

        // 从递归栈中移除
        _ = recursion_stack.remove(module_name);
        return false;
    }

    /// 规则3: 所有模块必须有描述
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

    /// 规则4: 模块名称必须符合命名规范（小写，使用下划线分隔）
    pub fn ruleModuleNamingConvention(self: *Self) !void {
        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;

            // 检查是否全小写
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

            // 检查是否包含空格
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

    /// 规则5: 模块依赖不能过于复杂（依赖数限制）
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

    /// 规则6: 基础模块不应该依赖其他业务模块
    pub fn ruleBaseModulesShouldNotDependOnOthers(self: *Self, base_modules: []const []const u8) !void {
        for (base_modules) |base_name| {
            const base_module = self.modules.get(base_name);
            if (base_module == null) continue;

            const module_info = base_module.?;

            for (module_info.deps) |dep| {
                // 检查依赖是否是其他业务模块（非基础模块）
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

    /// 运行所有默认规则
    pub fn runDefaultRules(self: *Self) !void {
        try self.ruleNoSelfDependency();
        try self.ruleNoCircularDependencies();
        try self.ruleModulesMustHaveDescription();
        try self.ruleModuleNamingConvention();
        try self.ruleLimitedDependencies(5); // 最多5个依赖
    }

    /// 获取违规数量
    pub fn getViolationCount(self: *Self) usize {
        return self.violations.items.len;
    }

    /// 获取特定严重级别的违规数量
    pub fn getViolationCountBySeverity(self: *Self, severity: Severity) usize {
        var count: usize = 0;
        for (self.violations.items) |violation| {
            if (violation.severity == severity) {
                count += 1;
            }
        }
        return count;
    }

    /// 打印违规报告
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

    /// 验证并返回是否通过（无error级别违规）
    pub fn verify(self: *Self) !bool {
        try self.runDefaultRules();
        return self.getViolationCountBySeverity(Severity.err) == 0;
    }
};

test "ArchitectureTester no violations" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    var order_mod: u8 = 0;
    var inv_mod: u8 = 0;
    try modules.register(ModuleInfo.init("order", "Order module", &.{"inventory"}, &order_mod));
    try modules.register(ModuleInfo.init("inventory", "Inventory module", &.{}, &inv_mod));

    var tester = ArchitectureTester.init(allocator, &modules);
    defer tester.deinit();

    try tester.ruleNoSelfDependency();
    try std.testing.expectEqual(@as(usize, 0), tester.getViolationCount());
}

test "ArchitectureTester self dependency violation" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    var bad_mod: u8 = 0;
    try modules.register(ModuleInfo.init("bad", "Bad module", &.{"bad"}, &bad_mod));

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

    var a_mod: u8 = 0;
    var b_mod: u8 = 0;
    try modules.register(ModuleInfo.init("a", "A", &.{"b"}, &a_mod));
    try modules.register(ModuleInfo.init("b", "B", &.{"a"}, &b_mod));

    var tester = ArchitectureTester.init(allocator, &modules);
    defer tester.deinit();

    try tester.ruleNoCircularDependencies();
    try std.testing.expect(tester.getViolationCount() > 0);
}

test "ArchitectureTester naming convention violation" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    var bad_mod: u8 = 0;
    try modules.register(ModuleInfo.init("BadName", "Bad", &.{}, &bad_mod));

    var tester = ArchitectureTester.init(allocator, &modules);
    defer tester.deinit();

    try tester.ruleModuleNamingConvention();
    try std.testing.expect(tester.getViolationCount() > 0);
}

test "ArchitectureTester print report" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    var bad_mod: u8 = 0;
    try modules.register(ModuleInfo.init("bad", "Bad", &.{"bad"}, &bad_mod));

    var tester = ArchitectureTester.init(allocator, &modules);
    defer tester.deinit();

    try tester.ruleNoSelfDependency();

    var buf = std.ArrayList(u8).empty;
    try tester.printReport(&buf, allocator);
    const report = try buf.toOwnedSlice(allocator);
    defer allocator.free(report);

    try std.testing.expect(std.mem.indexOf(u8, report, "Architecture Test Report") != null);
}
