const std = @import("std");

// ⚠️ EXPERIMENTAL: This module is incomplete and not production-ready.
/// ModuleCanvas - Visual representation of module architecture
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;

/// Application Module Canvas - 模块画布
/// 提供模块的完整视图，包括API、依赖、事件等
pub const ModuleCanvas = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    module_name: []const u8,
    module_info: ModuleInfo,

    // API 信息
    public_apis: std.ArrayList(ApiInfo),
    internal_apis: std.ArrayList(ApiInfo),

    // 依赖信息
    dependencies: std.ArrayList(DependencyInfo),
    depended_by: std.ArrayList([]const u8), // 被哪些模块依赖

    // 事件信息
    published_events: std.ArrayList(EventInfo),
    listened_events: std.ArrayList(EventInfo),

    // Spring Modulith 风格：输入/输出端口
    input_ports: std.ArrayList(PortInfo),
    output_ports: std.ArrayList(PortInfo),

    pub const ApiInfo = struct {
        name: []const u8,
        description: []const u8,
        is_public: bool,
    };

    pub const DependencyInfo = struct {
        module_name: []const u8,
        dependency_type: DependencyType,
        description: []const u8,
    };

    pub const DependencyType = enum {
        direct, // 直接依赖（API调用）
        event_based, // 事件驱动
        configuration, // 配置依赖
    };

    pub const EventInfo = struct {
        event_type: []const u8,
        description: []const u8,
        is_published: bool,
    };

    pub const PortInfo = struct {
        name: []const u8,
        direction: PortDirection,
        description: []const u8,
    };

    pub const PortDirection = enum {
        input, // 模块接收的输入
        output, // 模块产生的输出
    };

    pub fn init(allocator: std.mem.Allocator, module_name: []const u8, info: ModuleInfo) Self {
        return .{
            .allocator = allocator,
            .module_name = module_name,
            .module_info = info,
            .public_apis = std.ArrayList(ApiInfo).empty,
            .internal_apis = std.ArrayList(ApiInfo).empty,
            .dependencies = std.ArrayList(DependencyInfo).empty,
            .depended_by = std.ArrayList([]const u8).empty,
            .published_events = std.ArrayList(EventInfo).empty,
            .listened_events = std.ArrayList(EventInfo).empty,
            .input_ports = std.ArrayList(PortInfo).empty,
            .output_ports = std.ArrayList(PortInfo).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.public_apis.deinit(self.allocator);
        self.internal_apis.deinit(self.allocator);
        self.dependencies.deinit(self.allocator);
        self.depended_by.deinit(self.allocator);
        self.published_events.deinit(self.allocator);
        self.listened_events.deinit(self.allocator);
        self.input_ports.deinit(self.allocator);
        self.output_ports.deinit(self.allocator);
    }

    /// 添加公共API
    pub fn addPublicApi(self: *Self, name: []const u8, description: []const u8) !void {
        if (name.len == 0) return error.InvalidApiName;
        try self.public_apis.append(self.allocator, .{
            .name = name,
            .description = description,
            .is_public = true,
        });
    }

    /// 添加内部API
    pub fn addInternalApi(self: *Self, name: []const u8, description: []const u8) !void {
        if (name.len == 0) return error.InvalidApiName;
        try self.internal_apis.append(self.allocator, .{
            .name = name,
            .description = description,
            .is_public = false,
        });
    }

    /// 添加依赖
    pub fn addDependency(self: *Self, module_name: []const u8, dep_type: DependencyType, description: []const u8) !void {
        if (module_name.len == 0) return error.InvalidModuleName;
        try self.dependencies.append(self.allocator, .{
            .module_name = module_name,
            .dependency_type = dep_type,
            .description = description,
        });
    }

    /// 添加发布的事件
    pub fn addPublishedEvent(self: *Self, event_type: []const u8, description: []const u8) !void {
        if (event_type.len == 0) return error.InvalidEventType;
        try self.published_events.append(self.allocator, .{
            .event_type = event_type,
            .description = description,
            .is_published = true,
        });
    }

    /// 添加监听的事件
    pub fn addListenedEvent(self: *Self, event_type: []const u8, description: []const u8) !void {
        if (event_type.len == 0) return error.InvalidEventType;
        try self.listened_events.append(self.allocator, .{
            .event_type = event_type,
            .description = description,
            .is_published = false,
        });
    }

    /// 生成模块画布文档（Markdown格式）
    pub fn generateDocumentation(self: *Self, writer: anytype) !void {
        try writer.print("# Module Canvas: {s}\n\n", .{self.module_name});

        // 模块描述
        try writer.print("## Description\n{s}\n\n", .{self.module_info.desc});

        // 公共API
        try writer.writeAll("## Public APIs\n");
        if (self.public_apis.items.len == 0) {
            try writer.writeAll("*No public APIs defined*\n");
        } else {
            for (self.public_apis.items) |api| {
                try writer.print("- **{s}**: {s}\n", .{ api.name, api.description });
            }
        }
        try writer.writeAll("\n");

        // 内部API
        try writer.writeAll("## Internal APIs\n");
        if (self.internal_apis.items.len == 0) {
            try writer.writeAll("*No internal APIs defined*\n");
        } else {
            for (self.internal_apis.items) |api| {
                try writer.print("- **{s}**: {s}\n", .{ api.name, api.description });
            }
        }
        try writer.writeAll("\n");

        // 依赖
        try writer.writeAll("## Dependencies\n");
        if (self.dependencies.items.len == 0) {
            try writer.writeAll("*No dependencies*\n");
        } else {
            for (self.dependencies.items) |dep| {
                const type_str = switch (dep.dependency_type) {
                    .direct => "Direct",
                    .event_based => "Event-based",
                    .configuration => "Configuration",
                };
                try writer.print("- **{s}** ({s}): {s}\n", .{ dep.module_name, type_str, dep.description });
            }
        }
        try writer.writeAll("\n");

        // 事件
        try writer.writeAll("## Events\n");

        try writer.writeAll("### Published Events\n");
        if (self.published_events.items.len == 0) {
            try writer.writeAll("*No published events*\n");
        } else {
            for (self.published_events.items) |event| {
                try writer.print("- **{s}**: {s}\n", .{ event.event_type, event.description });
            }
        }
        try writer.writeAll("\n");

        try writer.writeAll("### Listened Events\n");
        if (self.listened_events.items.len == 0) {
            try writer.writeAll("*No listened events*\n");
        } else {
            for (self.listened_events.items) |event| {
                try writer.print("- **{s}**: {s}\n", .{ event.event_type, event.description });
            }
        }
        try writer.writeAll("\n");

        // 输入/输出端口（Spring Modulith风格）
        try writer.writeAll("## Ports\n");

        try writer.writeAll("### Input Ports\n");
        if (self.input_ports.items.len == 0) {
            try writer.writeAll("*No input ports*\n");
        } else {
            for (self.input_ports.items) |port| {
                try writer.print("- **{s}**: {s}\n", .{ port.name, port.description });
            }
        }
        try writer.writeAll("\n");

        try writer.writeAll("### Output Ports\n");
        if (self.output_ports.items.len == 0) {
            try writer.writeAll("*No output ports*\n");
        } else {
            for (self.output_ports.items) |port| {
                try writer.print("- **{s}**: {s}\n", .{ port.name, port.description });
            }
        }
    }
};

/// 模块画布生成器 - 为所有模块生成画布
pub const CanvasGenerator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    modules: *ApplicationModules,
    canvases: std.StringHashMap(ModuleCanvas),

    pub fn init(allocator: std.mem.Allocator, modules: *ApplicationModules) Self {
        return .{
            .allocator = allocator,
            .modules = modules,
            .canvases = std.StringHashMap(ModuleCanvas).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.canvases.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.canvases.deinit();
    }

    /// 为所有模块生成画布
    pub fn generateAllCanvases(self: *Self) !void {
        // Clear existing canvases first
        var existing_iter = self.canvases.iterator();
        while (existing_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.canvases.clearRetainingCapacity();

        var iter = self.modules.modules.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;
            const module_info = entry.value_ptr.*;

            var canvas = ModuleCanvas.init(self.allocator, module_name, module_info);

            // 自动分析依赖关系
            for (module_info.deps) |dep| {
                try canvas.addDependency(dep, .direct, "Direct module dependency");
            }

            try self.canvases.put(module_name, canvas);
        }
    }

    /// 获取特定模块的画布
    pub fn getCanvas(self: *Self, module_name: []const u8) ?*ModuleCanvas {
        return self.canvases.getPtr(module_name);
    }

    /// 生成所有画布的文档
    pub fn generateAllDocumentation(self: *Self, output_dir: []const u8) !void {
        var iter = self.canvases.iterator();
        while (iter.next()) |entry| {
            const module_name = entry.key_ptr.*;
            const canvas = entry.value_ptr.*;

            // 创建文件路径
            const filename = try std.fmt.allocPrint(self.allocator, "{s}/{s}-canvas.md", .{ output_dir, module_name });
            defer self.allocator.free(filename);

            // 创建文件
            const file = try std.Io.Dir.cwd().createFile(filename, .{});
            defer file.close(std.testing.io);

            // 生成文档
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.allocator);

            const writer = buf.writer(self.allocator);
            try canvas.generateDocumentation(writer);

            try file.writeAll(buf.items);
        }
    }
};
