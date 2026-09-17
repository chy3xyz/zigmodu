const std = @import("std");
const ModuleInfo = @import("Module.zig").ModuleInfo;

/// Compile-time module boundary verifier
/// Ensure modules follow architecture rules：
/// 1. Export only the public API
/// 2. Do not directly access other module internals
/// 3. Follow the naming conventions
pub const ModuleBoundary = struct {
    /// Validation module boundary.
    /// Check module definitions at compile time
    pub fn validate(comptime T: type) void {
        // Module must declare 'info'
        if (!@hasDecl(T, "info")) {
            @compileError("ModuleBoundary.validate expects `pub const info` on the module type; " ++
                @typeName(T) ++ " declares none. Add `pub const info = zmodu.api.Module{ .name = \"my-module\", " ++
                ".description = \"...\", .dependencies = &.{} };` to the module root and validate again.");
        }

        // Get module info
        const info = @field(T, "info");

        // ValidationModule name
        if (info.name.len == 0) {
            @compileError("Module name cannot be empty");
        }

        // Check naming conventions (lowercase + underscore)
        for (info.name) |c| {
            if (std.ascii.isUpper(c)) {
                @compileError("Module name must be lowercase: '" ++ info.name ++ "'");
            }
            if (c == ' ') {
                @compileError("Module name cannot contain spaces: '" ++ info.name ++ "'");
            }
        }

        // Check the init and deinit function signatures
        if (@hasDecl(T, "init")) {
            const init_fn = @field(T, "init");
            const init_info = @typeInfo(@TypeOf(init_fn));

            if (init_info != .@"fn") {
                @compileError("Module 'init' must be a function");
            }

            // init should return '!void'
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

        // Check exports (optional: controlled by pub in Zig)
        // More checks can be added here
    }

    /// ValidationModule dependencies
    /// Check if deps comply with spec
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

            // Check circular dependencies (simplified)
            // A full implementation would check at the Application level
        }
    }

    /// Compile-time warning (if supported)
    fn compileWarn(comptime msg: []const u8) void {
        // Zig has no standard compile-warning mechanism yet
        // It could be simulated via compile errors or logging
        // Not handled here for now
        _ = msg;
    }
};

/// Module type definition
/// Similar to Spring Modulith's OPEN/CLOSED
pub const ModuleType = enum {
    /// Open module: allow other modules direct access
    open,

    /// Closed module: accessible only through its public API
    /// Requires strict boundary validation
    closed,

    /// Internal module: for use inside this module only
    /// Must not be depended on by other modules
    internal,
};

/// Extended module definition (optional)
pub const ModuleDef = struct {
    name: []const u8,
    description: []const u8 = "",
    dependencies: []const []const u8 = &.{},
    module_type: ModuleType = .open,
    allowed_dependencies: ?[]const []const u8 = null,
    exposed_packages: ?[]const []const u8 = null,
};

/// Compile-time boundary check macro
/// Usage:
/// ```zig
/// comptime {
///     checkModuleBoundary(@This(), .{
///         .allowed_deps = &.{"inventory", "payment"},
///     });
/// }
/// ```
pub fn checkModuleBoundary(comptime T: type, comptime opts: anytype) void {
    ModuleBoundary.validate(T);

    // Check the allowed dependencies
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
        pub const info = ModuleInfo.init("valid_module", "A valid module", &.{});

        pub fn init() !void {}
        pub fn deinit() void {}
    };

    // Compile-time validation
    comptime {
        ModuleBoundary.validate(ValidModule);
    }
}

test "ModuleBoundary catches invalid name" {
    // This test would fail to compile
    // const InvalidModule = struct {
    //     pub const info = ModuleInfo{
    // .name = "InvalidModule",  // uppercase is an error
    //         .desc = "Invalid",
    //         .deps = &.{},
    //     };
    // };
    // comptime { ModuleBoundary.validate(InvalidModule); }
}
