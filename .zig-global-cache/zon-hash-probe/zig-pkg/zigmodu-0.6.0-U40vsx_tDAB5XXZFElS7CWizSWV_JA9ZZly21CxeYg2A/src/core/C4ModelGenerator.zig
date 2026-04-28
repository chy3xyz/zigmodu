// ⚠️ EXPERIMENTAL: This module is incomplete and not production-ready.
const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;

/// C4模型文档生成器
/// 生成C4级别的架构图（Context, Container, Component, Code）
pub const C4ModelGenerator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    modules: *ApplicationModules,

    pub fn init(allocator: std.mem.Allocator, modules: *ApplicationModules) Self {
        return .{
            .allocator = allocator,
            .modules = modules,
        };
    }

    /// 生成C4 Context图（系统上下文）
    pub fn generateContextDiagram(self: *Self, writer: anytype, system_name: []const u8) !void {
        try writer.writeAll("@startuml C4_Context\n");
        try writer.writeAll("!include https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/master/C4_Context.puml\n\n");

        try writer.print("LAYOUT_WITH_LEGEND()\n\n", .{});
        try writer.print("title System Context Diagram for {s}\n\n", .{system_name});

        // 系统
        try writer.print("System_Boundary({s}, \"{s}\") {{\n", .{ system_name, system_name });

        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;
            try writer.print("    System({s}, \"{s}\", \"Application Module\")\n", .{ module_name, module_name });
        }

        try writer.writeAll("}\n\n");

        // 关系
        var rel_iter = self.modules.modules.iterator();
        while (rel_iter.next()) |entry| {
            const module_name = entry.key_ptr.*;
            const module_info = entry.value_ptr.*;

            for (module_info.deps) |dep| {
                try writer.print("Rel({s}, {s}, \"depends on\")\n", .{ module_name, dep });
            }
        }

        try writer.writeAll("\n@enduml\n");
    }

    /// 生成C4 Container图（容器级别）
    pub fn generateContainerDiagram(self: *Self, writer: anytype, system_name: []const u8) !void {
        try writer.writeAll("@startuml C4_Container\n");
        try writer.writeAll("!include https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/master/C4_Container.puml\n\n");

        try writer.print("LAYOUT_WITH_LEGEND()\n\n", .{});
        try writer.print("title Container Diagram for {s}\n\n", .{system_name});

        try writer.print("System_Boundary({s}, \"{s}\") {{\n", .{ system_name, system_name });

        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;
            const module_info = entry.value_ptr.*;

            try writer.print("    Container({s}, \"{s}\", \"Zig Module\", \"{s}\")\n", .{ module_name, module_name, module_info.desc });
        }

        try writer.writeAll("}\n\n");

        // 关系
        var rel_iter = self.modules.modules.iterator();
        while (rel_iter.next()) |entry| {
            const module_name = entry.key_ptr.*;
            const module_info = entry.value_ptr.*;

            for (module_info.deps) |dep| {
                try writer.print("Rel_D({s}, {s}, \"uses\")\n", .{ module_name, dep });
            }
        }

        try writer.writeAll("\n@enduml\n");
    }

    /// 生成C4 Component图（组件级别）
    pub fn generateComponentDiagram(self: *Self, writer: anytype, module_name: []const u8) !void {
        const module_info = self.modules.get(module_name) orelse {
            try writer.print("// Module {s} not found\n", .{module_name});
            return;
        };

        try writer.writeAll("@startuml C4_Component\n");
        try writer.writeAll("!include https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/master/C4_Component.puml\n\n");

        try writer.print("LAYOUT_WITH_LEGEND()\n\n", .{});
        try writer.print("title Component Diagram for {s} Module\n\n", .{module_name});

        try writer.print("Container_Boundary({s}, \"{s} Module\") {{\n", .{ module_name, module_name });

        // API组件
        try writer.writeAll("    Component(api, \"Public API\", \"Zig\", \"Exposed interfaces\")\n");
        try writer.writeAll("    Component(internal, \"Internal Implementation\", \"Zig\", \"Private logic\")\n");
        try writer.writeAll("    Component(events, \"Event Handlers\", \"Zig\", \"Event listeners/publishers\")\n");

        try writer.writeAll("}\n\n");

        // 关系
        try writer.writeAll("Rel(api, internal, \"uses\")\n");
        try writer.writeAll("Rel(internal, events, \"publishes/subscribes\")\n");

        // 外部依赖
        for (module_info.deps) |dep| {
            try writer.print("Rel(internal, {s}_api, \"depends on\")\n", .{dep});
        }

        try writer.writeAll("\n@enduml\n");
    }

    /// 生成所有C4图
    pub fn generateAllDiagrams(self: *Self, output_dir: []const u8, system_name: []const u8) !void {
        // Validate inputs
        if (output_dir.len == 0) return error.InvalidOutputDir;
        if (system_name.len == 0) return error.InvalidSystemName;

        // Ensure output directory exists
        try std.Io.Dir.cwd().makePath(output_dir);
        // Context图
        {
            const context_path = try std.fmt.allocPrint(self.allocator, "{s}/c4-context.puml", .{output_dir});
            defer self.allocator.free(context_path);

            const file = try std.Io.Dir.cwd().createFile(context_path, .{});
            defer file.close(std.testing.io);

            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.allocator);

            try self.generateContextDiagram(buf.writer(self.allocator), system_name);
            try file.writeAll(buf.items);
        }

        // Container图
        {
            const container_path = try std.fmt.allocPrint(self.allocator, "{s}/c4-container.puml", .{output_dir});
            defer self.allocator.free(container_path);

            const file = try std.Io.Dir.cwd().createFile(container_path, .{});
            defer file.close(std.testing.io);

            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.allocator);

            try self.generateContainerDiagram(buf.writer(self.allocator), system_name);
            try file.writeAll(buf.items);
        }

        // 为每个模块生成Component图
        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;

            const component_path = try std.fmt.allocPrint(self.allocator, "{s}/c4-component-{s}.puml", .{ output_dir, module_name });
            defer self.allocator.free(component_path);

            const file = try std.Io.Dir.cwd().createFile(component_path, .{});
            defer file.close(std.testing.io);

            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.allocator);

            try self.generateComponentDiagram(buf.writer(self.allocator), module_name);
            try file.writeAll(buf.items);
        }
    }
};
