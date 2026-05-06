const std = @import("std");
const api = @import("api/Module.zig");
const ModuleInfo = @import("core/Module.zig").ModuleInfo;
const ApplicationModules = @import("core/Module.zig").ApplicationModules;
const scanModules = @import("core/ModuleScanner.zig").scanModules;
const validateModules = @import("core/ModuleValidator.zig").validateModules;
const Lifecycle = @import("core/Lifecycle.zig");
const Documentation = @import("core/Documentation.zig");

/// Atomic flag for graceful shutdown coordination (set by signal handler).
var shutdown_requested = std.atomic.Value(bool).init(false);

/// POSIX signal handler — sets the atomic flag.
fn signalHandler(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

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
    io: std.Io,
    shutdown_hooks: std.ArrayList(*const fn () void) = std.ArrayList(*const fn () void).empty,

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
        io: std.Io,
        allocator: std.mem.Allocator,
        app_name: []const u8,
        comptime modules_tuple: anytype,
        options: Config,
    ) !Self {
        const modules = try scanModules(allocator, modules_tuple);

        return .{
            .io = io,
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
        self.shutdown_hooks.deinit(self.allocator);
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

        // Call shutdown hooks in reverse registration order
        var i: usize = self.shutdown_hooks.items.len;
        while (i > 0) {
            i -= 1;
            self.shutdown_hooks.items[i]();
        }

        Lifecycle.stopAll(&self.modules);
        self.state = .stopped;

        std.log.info("✅ Application '{s}' stopped", .{self.config.name});
    }

    /// Generate documentation
    pub fn generateDocs(self: *Self, path: []const u8) !void {
        try Documentation.generateDocs(&self.modules, path, self.allocator, self.io);
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

    /// Register a hook to be called during graceful shutdown (reverse order).
    pub fn onShutdown(self: *Self, hook: *const fn () void) !void {
        try self.shutdown_hooks.append(self.allocator, hook);
    }

    /// Run the application blocking until SIGINT/SIGTERM.
    /// This is the recommended way to run a production server.
    /// Note: Uses a polling loop since sigtimedwait is not available on macOS.
    pub fn run(self: *Self) !void {
        try self.start();

        std.log.info("🚀 Application '{s}' running. Press Ctrl+C to stop.", .{self.config.name});

        // Install signal handler
        shutdown_requested.store(false, .release);

        const handler = std.posix.Sigaction{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &handler, null) catch {};
        std.posix.sigaction(std.posix.SIG.TERM, &handler, null) catch {};

        // Block until signal
        while (!shutdown_requested.load(.acquire)) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        std.log.info("⚡ Shutdown signal received, stopping '{s}'...", .{self.config.name});
        self.stop();
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
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ApplicationBuilder {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *ApplicationBuilder) void {
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
            self.io,
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
pub fn builder(allocator: std.mem.Allocator, io: std.Io) ApplicationBuilder {
    return ApplicationBuilder.init(allocator, io);
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

    var app = try Application.init(std.testing.io, allocator, "test-app", .{MockModule}, .{});
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

    var b = ApplicationBuilder.init(allocator, std.testing.io);
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

test "Application shutdown hooks" {
    const allocator = std.testing.allocator;

    const MockModule = struct {
        pub const info = api.Module{
            .name = "hook-mock",
            .description = "Hook test",
            .dependencies = &.{},
        };
        pub fn init() !void {}
        pub fn deinit() void {}
    };

    const HookCtx = struct {
        var hook_order: [2]u8 = .{ 0, 0 };
        var hook_idx: u8 = 0;

        fn hook1() void {
            hook_order[hook_idx] = 1;
            hook_idx += 1;
        }
        fn hook2() void {
            hook_order[hook_idx] = 2;
            hook_idx += 1;
        }
    };

    var app = try Application.init(std.testing.io, allocator, "hook-app", .{MockModule}, .{});
    defer app.deinit();

    HookCtx.hook_idx = 0;
    try app.onShutdown(HookCtx.hook1);
    try app.onShutdown(HookCtx.hook2);

    try app.start();
    app.stop();

    // Hooks called in reverse order
    try std.testing.expectEqual(@as(u8, 2), HookCtx.hook_order[0]);
    try std.testing.expectEqual(@as(u8, 1), HookCtx.hook_order[1]);
}

test "Application multi-module with dependencies" {
    const allocator = std.testing.allocator;

    const InitTracker = struct {
        var order: [3]u8 = .{ 0, 0, 0 };
        var idx: u8 = 0;
    };

    const Database = struct {
        pub const info = api.Module{
            .name = "database",
            .description = "Database layer",
            .dependencies = &.{},
        };
        pub fn init() !void {
            InitTracker.order[InitTracker.idx] = 1;
            InitTracker.idx += 1;
        }
        pub fn deinit() void {}
    };

    const Cache = struct {
        pub const info = api.Module{
            .name = "cache",
            .description = "Cache layer",
            .dependencies = &.{"database"},
        };
        pub fn init() !void {
            InitTracker.order[InitTracker.idx] = 2;
            InitTracker.idx += 1;
        }
        pub fn deinit() void {}
    };

    const Api = struct {
        pub const info = api.Module{
            .name = "api",
            .description = "API layer",
            .dependencies = &.{ "database", "cache" },
        };
        pub fn init() !void {
            InitTracker.order[InitTracker.idx] = 3;
            InitTracker.idx += 1;
        }
        pub fn deinit() void {}
    };

    InitTracker.idx = 0;
    var app = try Application.init(std.testing.io, allocator, "multi-app", .{ Database, Cache, Api }, .{});
    defer app.deinit();

    try app.start();

    // Verify all 3 modules started
    try std.testing.expectEqual(@as(u8, 3), InitTracker.idx);

    // database (no deps) must start before cache and api
    try std.testing.expectEqual(@as(u8, 1), InitTracker.order[0]);

    app.stop();
}

test "Application idempotent start and stop" {
    const allocator = std.testing.allocator;

    const MockModule = struct {
        pub const info = api.Module{
            .name = "idempotent",
            .description = "Idempotent test",
            .dependencies = &.{},
        };
        pub fn init() !void {}
        pub fn deinit() void {}
    };

    var app = try Application.init(std.testing.io, allocator, "idem-app", .{MockModule}, .{});
    defer app.deinit();

    // Double start should not error
    try app.start();
    try app.start(); // should be no-op

    // Double stop should not error
    app.stop();
    app.stop(); // should be no-op

    try std.testing.expectEqual(Application.State.stopped, app.getState());
}
