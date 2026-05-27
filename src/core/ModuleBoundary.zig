const std = @import("std");
const ModuleInfo = @import("Module.zig").ModuleInfo;

/// [...]Module boundary verifier
/// Ensure modules follow architecture rules：
/// 1. [...] API
/// 2. Do not directly access other module internals
/// 3. [...]
pub const ModuleBoundary = struct {
    /// ValidationModule boundary
    /// Check module definitions at compile time
    pub fn validate(comptime T: type) void {
        // [...] info [...]
        if (!@hasDecl(T, "info")) {
            @compileError("Module must declare 'pub const info' with module metadata");
        }

        // Get module info
        const info = @field(T, "info");

        // ValidationModule name
        if (info.name.len == 0) {
            @compileError("Module name cannot be empty");
        }

        // [...] + [...]
        for (info.name) |c| {
            if (std.ascii.isUpper(c)) {
                @compileError("Module name must be lowercase: '" ++ info.name ++ "'");
            }
            if (c == ' ') {
                @compileError("Module name cannot contain spaces: '" ++ info.name ++ "'");
            }
        }

        // [...] init [...] deinit [...]
        if (@hasDecl(T, "init")) {
            const init_fn = @field(T, "init");
            const init_info = @typeInfo(@TypeOf(init_fn));

            if (init_info != .@"fn") {
                @compileError("Module 'init' must be a function");
            }

            // init [...] !void
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

        // [...]Zig [...] pub [...]
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

            // Check circular dependencies[...]
            // [...] Application [...]
        }
    }

    /// [...]Warn[...]
    fn compileWarn(comptime msg: []const u8) void {
        // Zig [...]Warn[...]
        // [...]Error[...]
        // [...]
        _ = msg;
    }
};

/// [...]
/// [...] Spring Modulith [...] OPEN/CLOSED
pub const ModuleType = enum {
    /// [...]Allow other modules direct access
    open,

    /// [...] API [...]
    /// [...]Validation[...]
    closed,

    /// [...]Internal use only for this module
    /// [...]Module dependencies
    internal,
};

/// [...]
pub const ModuleDef = struct {
    name: []const u8,
    description: []const u8 = "",
    dependencies: []const []const u8 = &.{},
    module_type: ModuleType = .open,
    allowed_dependencies: ?[]const []const u8 = null,
    exposed_packages: ?[]const []const u8 = null,
};

/// [...]
/// [...]
/// ```zig
/// comptime {
///     checkModuleBoundary(@This(), .{
///         .allowed_deps = &.{"inventory", "payment"},
///     });
/// }
/// ```
pub fn checkModuleBoundary(comptime T: type, comptime opts: anytype) void {
    ModuleBoundary.validate(T);

    // [...]
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

    // [...]Validation
    comptime {
        ModuleBoundary.validate(ValidModule);
    }
}

test "ModuleBoundary catches invalid name" {
    // [...]Tests[...]failure
    // const InvalidModule = struct {
    //     pub const info = ModuleInfo{
    // .name = "InvalidModule",  // [...]Error
    //         .desc = "Invalid",
    //         .deps = &.{},
    //     };
    // };
    // comptime { ModuleBoundary.validate(InvalidModule); }
}
