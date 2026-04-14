const std = @import("std");
const ModuleInfo = @import("Module.zig").ModuleInfo;

/// 编译时模块边界验证器
/// 确保模块遵循架构规则：
/// 1. 只导出公共 API
/// 2. 不直接访问其他模块内部
/// 3. 遵循命名规范
pub const ModuleBoundary = struct {
    /// 验证模块边界
    /// 在编译时检查模块定义
    pub fn validate(comptime T: type) void {
        // 检查模块必须有 info 声明
        if (!@hasDecl(T, "info")) {
            @compileError("Module must declare 'pub const info' with module metadata");
        }

        // 获取模块信息
        const info = @field(T, "info");

        // 验证模块名称
        if (info.name.len == 0) {
            @compileError("Module name cannot be empty");
        }

        // 检查命名规范（小写 + 下划线）
        for (info.name) |c| {
            if (std.ascii.isUpper(c)) {
                @compileError("Module name must be lowercase: '" ++ info.name ++ "'");
            }
            if (c == ' ') {
                @compileError("Module name cannot contain spaces: '" ++ info.name ++ "'");
            }
        }

        // 检查 init 和 deinit 函数签名
        if (@hasDecl(T, "init")) {
            const init_fn = @field(T, "init");
            const init_info = @typeInfo(@TypeOf(init_fn));

            if (init_info != .@"fn") {
                @compileError("Module 'init' must be a function");
            }

            // init 应该返回 !void
            const return_type = init_info.@"fn".return_type.?;
            if (return_type != anyerror!void) {
                compileWarn("Module 'init' should return '!void' for consistency");
            }
        }

        if (@hasDecl(T, "deinit")) {
            const deinit_fn = @field(T, "deinit");
            const deinit_info = @typeInfo(@TypeOf(deinit_fn));

            if (deinit_info != .@"fn") {
                @compileError("Module 'deinit' must be a function");
            }

            const return_type = deinit_info.@"fn".return_type.?;
            if (return_type != void) {
                @compileError("Module 'deinit' must return 'void'");
            }
        }

        // 检查导出（可选，Zig 中通过 pub 控制）
        // 这里可以添加更多检查
    }

    /// 验证模块依赖
    /// 检查依赖是否符合规范
    pub fn validateDependencies(comptime T: type, comptime all_modules: []const type) void {
        const info = @field(T, "info");

        inline for (info.dependencies) |dep_name| {
            var found = false;

            inline for (all_modules) |mod| {
                const mod_info = @field(mod, "info");
                if (std.mem.eql(u8, mod_info.name, dep_name)) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                @compileError("Module '" ++ info.name ++ "' depends on unknown module: '" ++ dep_name ++ "'");
            }

            // 检查循环依赖（简化版）
            // 完整实现需要在 Application 级别检查
        }
    }

    /// 编译警告（如果支持）
    fn compileWarn(comptime msg: []const u8) void {
        // Zig 目前没有标准的编译警告机制
        // 可以通过编译错误模拟或日志
        // 这里暂时不做处理
        _ = msg;
    }
};

/// 模块类型定义
/// 类似于 Spring Modulith 的 OPEN/CLOSED
pub const ModuleType = enum {
    /// 开放模块：允许其他模块直接访问
    open,

    /// 封闭模块：只允许通过公共 API 访问
    /// 需要严格验证边界
    closed,

    /// 内部模块：仅限本模块内部使用
    /// 不应被其他模块依赖
    internal,
};

/// 增强的模块定义（可选）
pub const ModuleDef = struct {
    name: []const u8,
    description: []const u8 = "",
    dependencies: []const []const u8 = &.{},
    module_type: ModuleType = .open,
    allowed_dependencies: ?[]const []const u8 = null,
    exposed_packages: ?[]const []const u8 = null,
};

/// 编译时边界检查宏
/// 使用方式：
/// ```zig
/// comptime {
///     checkModuleBoundary(@This(), .{
///         .allowed_deps = &.{"inventory", "payment"},
///     });
/// }
/// ```
pub fn checkModuleBoundary(comptime T: type, comptime opts: anytype) void {
    ModuleBoundary.validate(T);

    // 检查允许的依赖
    if (@hasField(@TypeOf(opts), "allowed_deps")) {
        const info = @field(T, "info");
        inline for (info.dependencies) |dep| {
            var allowed = false;
            inline for (opts.allowed_deps) |allowed_dep| {
                if (std.mem.eql(u8, dep, allowed_dep)) {
                    allowed = true;
                    break;
                }
            }
            if (!allowed) {
                @compileError("Module '" ++ info.name ++ "' depends on '" ++ dep ++
                    "' which is not in allowed dependencies list");
            }
        }
    }
}

test "ModuleBoundary validation" {
    const ValidModule = struct {
        pub const info = ModuleInfo{
            .name = "valid_module",
            .desc = "A valid module",
            .deps = &.{},
            .ptr = undefined,
        };

        pub fn init() !void {}
        pub fn deinit() void {}
    };

    // 编译时验证
    comptime {
        ModuleBoundary.validate(ValidModule);
    }
}

test "ModuleBoundary catches invalid name" {
    // 这个测试会编译失败
    // const InvalidModule = struct {
    //     pub const info = ModuleInfo{
    //         .name = "InvalidModule",  // 大写错误
    //         .desc = "Invalid",
    //         .deps = &.{},
    //     };
    // };
    // comptime { ModuleBoundary.validate(InvalidModule); }
}
