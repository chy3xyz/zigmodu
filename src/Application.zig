const std = @import("std");
const api = @import("api/Module.zig");
const ModuleInfo = @import("core/Module.zig").ModuleInfo;
const ApplicationModules = @import("core/Module.zig").ApplicationModules;
const scanModules = @import("core/ModuleScanner.zig").scanModules;
const validateModules = @import("core/ModuleValidator.zig").validateModules;
const Lifecycle = @import("core/Lifecycle.zig");
const Documentation = @import("core/Documentation.zig");

/// Application Builder Pattern
/// Simplified API for creating and managing modular applications
///
/// Example:
/// ```zig
/// var app = try zigmodu.Application.init(allocator, .{
///     .name = "shop",
///     .modules = .{ order_module, payment_module },
/// });
/// defer app.deinit();
///
/// try app.start();
/// defer app.stop();
/// ```
pub const Application = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    modules: ApplicationModules,
    config: Config,
    state: State,

    pub const State = enum {
        initialized,
        validated,
        started,
        stopped,
    };

    pub const Config = struct {
        name: []const u8 = "app",
        validate_on_start: bool = true,
        auto_generate_docs: bool = false,
        docs_path: ?[]const u8 = null,
    };

    /// Initialize application with modules
    pub fn init(
        allocator: std.mem.Allocator,
        app_name: []const u8,
        comptime modules_tuple: anytype,
        options: Config,
    ) !Self {
        const modules = try scanModules(allocator, modules_tuple);

        return .{
            .allocator = allocator,
            .modules = modules,
            .config = .{
                .name = app_name,
                .validate_on_start = options.validate_on_start,
                .auto_generate_docs = options.auto_generate_docs,
                .docs_path = options.docs_path,
            },
            .state = .initialized,
        };
    }

    /// Clean up application resources
    pub fn deinit(self: *Self) void {
        if (self.state == .started) {
            self.stop();
        }
        self.modules.deinit();
        self.state = .stopped;
    }

    /// Validate module dependencies
    /// Returns error if validation fails
    pub fn validate(self: *Self) !void {
        if (self.state == .validated or self.state == .started) {
            return; // Already validated
        }
        try validateModules(&self.modules);
        self.state = .validated;
    }

    /// Start all modules in dependency order
    /// Automatically validates if configured
    pub fn start(self: *Self) !void {
        if (self.state == .started) {
            std.log.warn("Application '{s}' is already started", .{self.config.name});
            return;
        }

        // Validate if needed
        if (self.config.validate_on_start and self.state != .validated) {
            try self.validate();
        }

        // Generate docs if configured
        if (self.config.auto_generate_docs) {
            if (self.config.docs_path) |path| {
                try self.generateDocs(path);
            }
        }

        // Start modules
        try Lifecycle.startAll(&self.modules);
        self.state = .started;

        std.log.info("✅ Application '{s}' started successfully", .{self.config.name});
    }

    /// Stop all modules in reverse dependency order
    pub fn stop(self: *Self) void {
        if (self.state != .started) {
            return; // Not started, nothing to stop
        }

        Lifecycle.stopAll(&self.modules);
        self.state = .stopped;

        std.log.info("✅ Application '{s}' stopped", .{self.config.name});
    }

    /// Generate documentation
    pub fn generateDocs(self: *Self, path: []const u8) !void {
        try Documentation.generateDocs(&self.modules, path, self.allocator);
        std.log.info("✅ Documentation generated: {s}", .{path});
    }

    /// Get module by name
    pub fn getModule(self: *Self, name: []const u8) ?ModuleInfo {
        return self.modules.get(name);
    }

    /// Check if application contains a module
    pub fn hasModule(self: *Self, name: []const u8) bool {
        return self.modules.modules.contains(name);
    }

    /// Get current state
    pub fn getState(self: *Self) State {
        return self.state;
    }
};

/// Fluent API for building applications step by step
///
/// Example:
/// ```zig
/// var builder = zigmodu.ApplicationBuilder.init(allocator);
/// defer builder.deinit();
///
/// var app = try builder
///     .withName("shop")
///     .withValidation(true)
///     .withDocsPath("docs/app.puml")
///     .build(.{ order_module, payment_module });
/// ```
pub const ApplicationBuilder = struct {
    allocator: std.mem.Allocator,
    app_name: []const u8 = "app",
    validate_on_start: bool = true,
    docs_path: ?[]const u8 = null,
    auto_generate_docs: bool = false,

    pub fn init(allocator: std.mem.Allocator) ApplicationBuilder {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ApplicationBuilder) void {
        // Nothing to clean up currently
        _ = self;
    }

    pub fn withName(self: *ApplicationBuilder, name: []const u8) *ApplicationBuilder {
        self.app_name = name;
        return self;
    }

    pub fn withValidation(self: *ApplicationBuilder, enabled: bool) *ApplicationBuilder {
        self.validate_on_start = enabled;
        return self;
    }

    pub fn withDocsPath(self: *ApplicationBuilder, path: []const u8) *ApplicationBuilder {
        self.docs_path = path;
        return self;
    }

    pub fn withAutoDocs(self: *ApplicationBuilder, enabled: bool) *ApplicationBuilder {
        self.auto_generate_docs = enabled;
        return self;
    }

    pub fn build(self: *ApplicationBuilder, comptime modules: anytype) !Application {
        return Application.init(
            self.allocator,
            self.app_name,
            modules,
            .{
                .validate_on_start = self.validate_on_start,
                .auto_generate_docs = self.auto_generate_docs,
                .docs_path = self.docs_path,
            },
        );
    }
};

/// Convenience function to create ApplicationBuilder
pub fn builder(allocator: std.mem.Allocator) ApplicationBuilder {
    return ApplicationBuilder.init(allocator);
}

test "Application lifecycle" {
    const allocator = std.testing.allocator;

    const MockModule = struct {
        pub const info = api.Module{
            .name = "mock",
            .description = "Mock",
            .dependencies = &.{},
        };
        pub fn init() !void {}
        pub fn deinit() void {}
    };

    var app = try Application.init(allocator, "test-app", .{MockModule}, .{});
    defer app.deinit();

    try std.testing.expectEqual(Application.State.initialized, app.getState());
    try std.testing.expect(app.hasModule("mock"));
    try std.testing.expectEqualStrings("mock", app.getModule("mock").?.name);

    try app.validate();
    try std.testing.expectEqual(Application.State.validated, app.getState());

    try app.start();
    try std.testing.expectEqual(Application.State.started, app.getState());

    app.stop();
    try std.testing.expectEqual(Application.State.stopped, app.getState());
}

test "ApplicationBuilder" {
    const allocator = std.testing.allocator;

    const MockModule = struct {
        pub const info = api.Module{
            .name = "builder-mock",
            .description = "Builder Mock",
            .dependencies = &.{},
        };
        pub fn init() !void {}
        pub fn deinit() void {}
    };

    var b = ApplicationBuilder.init(allocator);
    defer b.deinit();

    var app = try b
        .withName("built-app")
        .withValidation(false)
        .withAutoDocs(false)
        .build(.{MockModule});
    defer app.deinit();

    try std.testing.expectEqualStrings("built-app", app.config.name);
    try std.testing.expectEqual(false, app.config.validate_on_start);
    try std.testing.expect(app.hasModule("builder-mock"));
}
