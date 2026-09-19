//! Application lifecycle — module loading, startup, and shutdown orchestration.

const std = @import("std");
const Time = @import("core/Time.zig");
const api = @import("api/Module.zig");
const ModuleInfo = @import("core/Module.zig").ModuleInfo;
const ApplicationModules = @import("core/Module.zig").ApplicationModules;
const scanModules = @import("core/ModuleScanner.zig").scanModules;
const validateModules = @import("core/ModuleValidator.zig").validateModules;
const Lifecycle = @import("core/Lifecycle.zig");
const Documentation = @import("core/Documentation.zig");
const ModuleRegistry = @import("core/ModuleRegistry.zig").ModuleRegistry;
const ModuleRuntime = @import("core/ModuleRuntime.zig").ModuleRuntime;
const EventRegistry = @import("core/EventRegistry.zig").EventRegistry;
const rt_mod = @import("runtime.zig");
const ModuleGraph = @import("core/ModuleGraph.zig");
const ModuleContext = @import("core/ModuleContext.zig").ModuleContext;
const Container = @import("di/Container.zig").Container;

/// Atomic flag for graceful shutdown coordination (set by signal handler).
var shutdown_requested = std.atomic.Value(bool).init(false);

/// POSIX signal handler — sets the atomic flag.
fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

/// Atomic counter for in-flight requests (used for graceful drain).
var in_flight_requests = std.atomic.Value(u64).init(0);

/// Return a pointer to the global in-flight request counter.
/// Pass this to Server.withGracefulDrain() so the HTTP server
/// participates in Application.run()'s graceful shutdown drain.
pub fn getInFlightCounter() *std.atomic.Value(u64) {
    return &in_flight_requests;
}

/// Application Builder Pattern
/// Simplified API for creating and managing modular applications
///
/// Preferred — build through the builder (bind it first: a temporary is `*const`):
/// ```zig
/// var b = zigmodu.builder(allocator, io);
/// defer b.deinit();
/// var app = try b.withName("shop").build(.{ order_module, payment_module });
/// defer app.deinit();
///
/// try app.start();
/// defer app.stop();
/// ```
///
/// Or construct directly — the argument order is `(io, allocator, name, modules, Config)`:
/// ```zig
/// var app = try zigmodu.Application.init(io, allocator, "shop", .{ order_module, payment_module }, .{});
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
    shutdown_hooks: std.ArrayList(*const fn () void),
    registry: ?ModuleRegistry = null,
    /// Shared per-type event buses (`ThreadSafeEventBus` only). Modules grab
    /// buses in `initWith(ctx)`; handlers/tests via `app.eventBus(T)`.
    events: EventRegistry,
    /// Application service container. Modules register during `start()`;
    /// frozen once startup completes — afterwards `get` is a lock-free read
    /// safe for concurrent handlers.
    services: Container,
    /// Opt-in execution runtime (workers / mailboxes / timers), created on first
    /// `runtime()` call and shut down by `stop()`. Null means "this app never
    /// used it" — the module lifecycle is unchanged either way.
    runtime_state: ?*rt_mod.Runtime = null,

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
        /// Advisory startup check, the runtime counterpart of `ModuleGraph`'s
        /// comptime one: a module declaring more than this many dependencies is
        /// logged as a warning by `validate()` (sizing is a smell, never a
        /// reason to refuse to start). `0` disables the check.
        max_dependencies: usize = 8,
        /// Declared upper bound on `.mode = .pooled` workers (docs/RUNTIME.md
        /// §12): the runtime `app.runtime()` creates is sized for it, and its
        /// pool threads appear the first time a pooled worker is spawned. `0` —
        /// the default — means this app has no pool, and `.pooled` is refused at
        /// `spawn` rather than starting a thread nobody declared.
        max_pooled_workers: usize = 0,
        /// How many pool threads that pool runs (docs/RUNTIME.md §12.12). `1` —
        /// the default — is the single-consumer shape, so an app that declares a
        /// pool and no width keeps exactly the scheduling behaviour it had
        /// before. Ignored when `max_pooled_workers` is 0: no pool is created.
        pool_threads: usize = 1,
    };

    /// Initialize application with modules
    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        app_name: []const u8,
        comptime modules_tuple: anytype,
        options: Config,
    ) !Self {
        var modules = try scanModules(allocator, modules_tuple);
        errdefer modules.deinit();

        var registry = ModuleRegistry.init(allocator);
        errdefer registry.deinit();
        try registry.initFromModules(io, &modules);

        return .{
            .io = io,
            .allocator = allocator,
            .modules = modules,
            .config = .{
                .name = app_name,
                .validate_on_start = options.validate_on_start,
                .auto_generate_docs = options.auto_generate_docs,
                .docs_path = options.docs_path,
                .max_dependencies = options.max_dependencies,
                .max_pooled_workers = options.max_pooled_workers,
                .pool_threads = options.pool_threads,
            },
            .state = .initialized,
            .shutdown_hooks = std.ArrayList(*const fn () void).empty,
            .registry = registry,
            .events = EventRegistry.init(allocator, io),
            .services = Container.init(allocator),
        };
    }

    /// Clean up application resources
    pub fn deinit(self: *Self) void {
        if (self.state == .started) {
            self.stop();
        }
        if (self.runtime_state) |rt| {
            rt.deinit();
            self.allocator.destroy(rt);
            self.runtime_state = null;
        }
        if (self.registry) |*r| r.deinit();
        self.events.deinit();
        self.services.deinit();
        self.modules.deinit();
        self.shutdown_hooks.deinit(self.allocator);
        self.state = .stopped;
        self.* = undefined;
    }

    /// Validate module dependencies (cold path — startup only).
    /// Returns error if validation fails
    pub fn validate(self: *Self) !void {
        if (self.state == .validated or self.state == .started) {
            return; // Already validated
        }
        try validateModules(&self.modules);
        if (self.config.max_dependencies > 0) {
            _ = warnOverDependencyLimit(&self.modules, self.config.max_dependencies);
        }
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

        // Start modules — each may declare initWith(ctx) to receive the
        // shared EventRegistry + DI container (classic init() still works), and
        // `ctx.runtime()` to spawn workers that `stop()` will join.
        var module_ctx = ModuleContext{
            .allocator = self.allocator,
            .io = self.io,
            .events = &self.events,
            .services = &self.services,
            .runtime_provider = .{ .ctx = self, .get = provideRuntime },
        };
        try Lifecycle.startAllWith(&self.modules, &module_ctx);
        // Startup wiring complete: further registration is rejected, and
        // service lookups become lock-free reads for concurrent handlers.
        self.services.freeze();
        self.state = .started;

        std.log.info("Application '{s}' started successfully", .{self.config.name});
    }

    /// Stop all modules in reverse dependency order
    pub fn stop(self: *Self) void {
        if (self.state != .started) {
            return; // Not started, nothing to stop
        }

        // Workers before modules: a worker may still be calling module services,
        // and `shutdown` joins them, so this also means "no runtime thread is
        // running while teardown happens".
        if (self.runtime_state) |rt| rt.shutdown();

        // Call shutdown hooks in reverse registration order
        var i: usize = self.shutdown_hooks.items.len;
        while (i > 0) {
            i -= 1;
            self.shutdown_hooks.items[i]();
        }

        Lifecycle.stopAll(&self.modules);
        self.state = .stopped;

        std.log.info("Application '{s}' stopped", .{self.config.name});
    }

    /// Generate documentation
    pub fn generateDocs(self: *Self, path: []const u8) !void {
        try Documentation.generateDocs(&self.modules, path, self.allocator, self.io);
        std.log.info("Documentation generated: {s}", .{path});
    }

    /// Get module by name
    pub fn getModule(self: *Self, name: []const u8) ?ModuleInfo {
        return self.modules.get(name);
    }

    /// Get module runtime by name
    pub fn getModuleRuntime(self: *Self, name: []const u8) ?*ModuleRuntime {
        if (self.registry) |*r| return r.get(name);
        return null;
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

    /// The execution runtime, created on first use **and started** (the ticker
    /// runs, so `handle.after(...)` fires without help). Additive: an app that
    /// never asks for it behaves exactly as before (no threads, no timers).
    ///
    /// ```zig
    /// const rt = try app.runtime();
    /// const worker = try rt.spawn(OrderBook, .{ .symbol = "BTC/USDT" });
    /// try worker.send(.{ .price = 101 });
    /// ```
    ///
    /// Modules reach the same runtime through `ModuleContext.runtime()`, so a
    /// worker spawned in `initWith` is joined by `stop()` like any other.
    pub fn runtime(self: *Self) !*rt_mod.Runtime {
        if (self.runtime_state) |rt| return rt;
        const rt = try self.allocator.create(rt_mod.Runtime);
        errdefer self.allocator.destroy(rt);
        rt.* = try rt_mod.Runtime.initWithOptions(self.allocator, self.io, .{
            .clock = .monotonic,
            .scheduler = .{
                .max_pooled_workers = self.config.max_pooled_workers,
                .pool_threads = self.config.pool_threads,
            },
        });
        errdefer rt.deinit();
        try rt.start();
        self.runtime_state = rt;
        return rt;
    }

    /// Adapter handed to `ModuleContext.RuntimeProvider`: one owner, so
    /// `ctx.runtime()` and `app.runtime()` are the same object.
    fn provideRuntime(ud: ?*anyopaque) anyerror!*rt_mod.Runtime {
        const app: *Application = @ptrCast(@alignCast(ud orelse return error.RuntimeUnavailable));
        return app.runtime();
    }

    /// Get or create the shared thread-safe bus for event type `T`.
    pub fn eventBus(self: *Self, comptime T: type) !*@import("core/EventBus.zig").ThreadSafeEventBus(T) {
        return self.events.bus(T);
    }

    /// Typed service lookup from the application container.
    pub fn service(self: *Self, comptime T: type, name: []const u8) ?*T {
        return self.services.get(T, name);
    }

    /// Run the application blocking until SIGINT/SIGTERM.
    /// Uses Zig 0.16 std.posix APIs (sigaction returns void, sigemptyset for mask).
    pub fn run(self: *Self) !void {
        try self.start();

        std.log.info("Application '{s}' running. Press Ctrl+C to stop.", .{self.config.name});

        shutdown_requested.store(false, .release);

        const handler = std.posix.Sigaction{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &handler, null);
        std.posix.sigaction(std.posix.SIG.TERM, &handler, null);

        // Poll until signal
        const poll_interval = std.posix.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        while (!shutdown_requested.load(.acquire)) {
            _ = std.c.nanosleep(&poll_interval, null);
        }

        std.log.info("Shutdown signal received, draining in-flight requests...", .{});

        const drain_start = Time.monotonicNowMilliseconds();
        const drain_timeout_ms: i64 = 30_000;
        const drain_interval = std.posix.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        while (in_flight_requests.load(.acquire) > 0) {
            if (Time.monotonicNowMilliseconds() - drain_start > drain_timeout_ms) {
                std.log.warn("Drain timeout after {d}ms, forcing stop...", .{drain_timeout_ms});
                break;
            }
            _ = std.c.nanosleep(&drain_interval, null);
        }

        std.log.info("Stopping application '{s}'...", .{self.config.name});
        self.stop();
        std.log.info("Application '{s}' stopped gracefully", .{self.config.name});
    }
};

/// Fluent API for building applications step by step
///
/// Example:
/// ```zig
/// var builder = zigmodu.ApplicationBuilder.init(allocator, io);
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
    /// Services pre-registered into `Application.services` by `build()`
    /// (borrowed — the caller keeps ownership and must outlive the app).
    pending_services: std.ArrayList(PendingService),
    /// Compile-time module-graph check (see `ModuleGraph`), on by default.
    comptime_graph_check: bool = true,
    /// Advisory threshold for "this module depends on too much".
    max_dependencies: usize = 8,
    /// Declared upper bound on `.pooled` workers, handed to the runtime
    /// `app.runtime()` creates (`Config.max_pooled_workers`). `0` — the default —
    /// means the app has no pool, so a `.mode = .pooled` spawn is refused
    /// (docs/RUNTIME.md §12.8 D2).
    max_pooled_workers: usize = 0,
    /// How many threads that pool runs (`Config.pool_threads`), handed to the same
    /// runtime. `1` — the default — keeps the single-consumer scheduling shape
    /// (docs/RUNTIME.md §12.12).
    pool_threads: usize = 1,

    const PendingService = struct {
        name: []const u8,
        ptr: *anyopaque,
        register_fn: *const fn (*Container, []const u8, *anyopaque) anyerror!void,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ApplicationBuilder {
        return .{
            .allocator = allocator,
            .io = io,
            .pending_services = std.ArrayList(PendingService).empty,
        };
    }

    pub fn deinit(self: *ApplicationBuilder) void {
        for (self.pending_services.items) |p| self.allocator.free(p.name);
        self.pending_services.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn withName(self: *ApplicationBuilder, name: []const u8) *ApplicationBuilder {
        self.app_name = name;
        return self;
    }

    /// Turn off the compile-time module-graph check. Only for setups where the
    /// module set is assembled dynamically (a plugin registry): the runtime
    /// `validateModules` check still runs at startup.
    pub fn withCompileTimeGraphCheck(self: *ApplicationBuilder, enabled: bool) *ApplicationBuilder {
        self.comptime_graph_check = enabled;
        return self;
    }

    /// Advisory threshold checked at **startup** (not comptime — the number is
    /// runtime configuration): a module with more dependencies than this is
    /// logged as a warning by `validate()`. Default 8; `0` disables the check.
    pub fn withMaxDependencies(self: *ApplicationBuilder, max_deps: usize) *ApplicationBuilder {
        self.max_dependencies = max_deps;
        return self;
    }

    pub fn withValidation(self: *ApplicationBuilder, enabled: bool) *ApplicationBuilder {
        self.validate_on_start = enabled;
        return self;
    }

    /// Declare the runtime pool this app may use (docs/RUNTIME.md §12.8 D2): the
    /// runtime behind `app.runtime()` / `ctx.runtime()` is sized for it, and its
    /// pool threads appear with the first `.pooled` spawn. Left alone, the app
    /// has no pool and `.mode = .pooled` is refused at `spawn` — a declaration is
    /// what makes the ready ring's capacity follow the bound.
    pub fn withMaxPooledWorkers(self: *ApplicationBuilder, max_pooled_workers: usize) *ApplicationBuilder {
        self.max_pooled_workers = max_pooled_workers;
        return self;
    }

    /// How many threads the pool declared by `withMaxPooledWorkers` runs
    /// (docs/RUNTIME.md §12.12). The default of 1 is the single-consumer shape,
    /// and it is what an app that does not call this keeps. Widening the pool is
    /// for the long tail (§12.5): a pooled worker's state exclusivity is the
    /// claim, not thread identity, so more threads do not weaken §12.3 — but each
    /// one adds a consumer to the ring, and the ring's capacity follows the
    /// declared width.
    pub fn withPoolThreads(self: *ApplicationBuilder, pool_threads: usize) *ApplicationBuilder {
        self.pool_threads = pool_threads;
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

    /// Create a production `AppSecurity` bundle (wall-clock JWT) using this builder's io + allocator.
    pub fn security(self: *ApplicationBuilder, jwt_secret: []const u8, token_expiry_seconds: i64) @import("security/AppSecurity.zig").AppSecurity {
        return @import("security/AppSecurity.zig").AppSecurity.init(self.allocator, self.io, .{
            .jwt_secret = jwt_secret,
            .token_expiry_seconds = token_expiry_seconds,
        });
    }

    /// Pre-register a borrowed service into the application container.
    /// The instance is caller-owned (stack or externally managed) and must
    /// outlive the application; modules retrieve it in `initWith(ctx)` via
    /// `ctx.service(T, name)`.
    pub fn withService(self: *ApplicationBuilder, comptime T: type, name: []const u8, instance: *T) !*ApplicationBuilder {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.pending_services.append(self.allocator, .{
            .name = owned_name,
            .ptr = instance,
            .register_fn = struct {
                fn f(c: *Container, n: []const u8, p: *anyopaque) anyerror!void {
                    const typed: *T = @ptrCast(@alignCast(p));
                    try c.registerBorrowed(T, n, typed);
                }
            }.f,
        });
        return self;
    }

    pub fn build(self: *ApplicationBuilder, comptime modules: anytype) !Application {
        // Compile-time architecture check: a cyclic or misspelled dependency is a
        // build error with the cycle spelled out, not a startup abort. `Application`
        // still re-checks at startup for the dynamic path.
        if (self.comptime_graph_check) {
            const module_list: []const type = comptime blk: {
                const arr: [modules.len]type = modules;
                break :blk &arr;
            };
            ModuleGraph.validateOrFail(module_list);
        }
        var app = try Application.init(
            self.io,
            self.allocator,
            self.app_name,
            modules,
            .{
                .validate_on_start = self.validate_on_start,
                .auto_generate_docs = self.auto_generate_docs,
                .docs_path = self.docs_path,
                .max_dependencies = self.max_dependencies,
                .max_pooled_workers = self.max_pooled_workers,
                .pool_threads = self.pool_threads,
            },
        );
        errdefer app.deinit();
        for (self.pending_services.items) |p| {
            try p.register_fn(&app.services, p.name, p.ptr);
        }
        return app;
    }
};

/// Convenience function to create ApplicationBuilder
pub fn builder(allocator: std.mem.Allocator, io: std.Io) ApplicationBuilder {
    return ApplicationBuilder.init(allocator, io);
}

/// Log-and-count modules whose declared dependency count exceeds `limit` — the
/// advisory half of startup validation (`ModuleGraph.analyze` cannot run here:
/// the module set is a runtime value by the time `Application` exists). Returns
/// how many modules were over, which is what the tests assert on.
fn warnOverDependencyLimit(modules: *const ApplicationModules, limit: usize) usize {
    var over: usize = 0;
    var iter = modules.modules.iterator();
    while (iter.next()) |entry| {
        const module = entry.value_ptr.*;
        if (module.deps.len > limit) {
            std.log.warn("Module '{s}' declares {d} dependencies (advisory max {d})", .{
                module.name,
                module.deps.len,
                limit,
            });
            over += 1;
        }
    }
    return over;
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

test "advisory max-dependency limit is wired from the builder into startup validation" {
    const allocator = std.testing.allocator;

    const Leaf = struct {
        pub const info = api.Module{ .name = "leaf", .description = "Leaf", .dependencies = &.{} };
        pub fn init() !void {}
        pub fn deinit() void {}
    };
    const Other = struct {
        pub const info = api.Module{ .name = "other-leaf", .description = "Leaf", .dependencies = &.{} };
        pub fn init() !void {}
        pub fn deinit() void {}
    };
    const Wide = struct {
        pub const info = api.Module{
            .name = "wide",
            .description = "Depends on both leaves",
            .dependencies = &.{ "leaf", "other-leaf" },
        };
        pub fn init() !void {}
        pub fn deinit() void {}
    };

    var b = ApplicationBuilder.init(allocator, std.testing.io);
    defer b.deinit();

    var app = try b.withMaxDependencies(1).build(.{ Leaf, Other, Wide });
    defer app.deinit();

    // The builder's number reaches the config `validate()` reads.
    try std.testing.expectEqual(@as(usize, 1), app.config.max_dependencies);
    try std.testing.expectEqual(@as(usize, 1), warnOverDependencyLimit(&app.modules, app.config.max_dependencies));
    try std.testing.expectEqual(@as(usize, 0), warnOverDependencyLimit(&app.modules, 2));

    // ... and `validate()` runs it as part of startup (advisory: no error).
    try app.validate();
    try std.testing.expectEqual(Application.State.validated, app.getState());
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

test "e2e: Application smoke test with events and graceful drain" {
    const allocator = std.testing.allocator;

    const E2eCtx = struct {
        var event_received: bool = false;
        var hook_called: bool = false;

        fn onUserCreated(event: struct { name: []const u8 }) void {
            _ = event;
            event_received = true;
        }

        fn onShutdown() void {
            hook_called = true;
        }
    };

    const ModuleA = struct {
        pub const info = api.Module{
            .name = "module-a",
            .description = "E2E module A",
            .dependencies = &.{},
        };
        pub fn init() !void {}
        pub fn deinit() void {}
    };

    const ModuleB = struct {
        pub const info = api.Module{
            .name = "module-b",
            .description = "E2E module B",
            .dependencies = &.{"module-a"},
        };
        pub fn init() !void {}
        pub fn deinit() void {}
    };

    // Full lifecycle
    var app = try Application.init(std.testing.io, allocator, "e2e-app", .{ ModuleA, ModuleB }, .{
        .validate_on_start = true,
        .auto_generate_docs = false,
    });
    defer app.deinit();

    try std.testing.expectEqual(Application.State.initialized, app.getState());
    try std.testing.expect(app.hasModule("module-a"));
    try std.testing.expect(app.hasModule("module-b"));

    // Register shutdown hook
    try app.onShutdown(E2eCtx.onShutdown);

    // Start
    try app.start();
    try std.testing.expectEqual(Application.State.started, app.getState());

    // Verify shutdown hook not yet called
    try std.testing.expect(!E2eCtx.hook_called);

    // Stop
    app.stop();
    try std.testing.expectEqual(Application.State.stopped, app.getState());
    try std.testing.expect(E2eCtx.hook_called);
}

test "Application builds ModuleRegistry from module runtime options" {
    const allocator = std.testing.allocator;

    const ResilientModule = struct {
        pub const info = api.Module{
            .name = "resilient",
            .description = "Resilient",
            .runtime = .{ .max_concurrent = 5 },
        };
        pub fn init() !void {}
        pub fn deinit() void {}
    };

    var app = try Application.init(std.testing.io, allocator, "runtime-app", .{ResilientModule}, .{});
    defer app.deinit();

    const rt = app.getModuleRuntime("resilient");
    try std.testing.expect(rt != null);
    try std.testing.expect(rt.?.tryEnter());
    rt.?.release();
}

test "e2e: Application events + services wiring through ModuleContext" {
    const allocator = std.testing.allocator;

    const OrderEvent = struct { id: i64 };
    const FakeDb = struct { connected: bool = true };

    const Ctx = struct {
        var saw_db: bool = false;
        var received: i64 = 0;
        fn onOrder(e: OrderEvent) void {
            received = e.id;
        }
    };

    const Orders = struct {
        pub const info = api.Module{
            .name = "orders",
            .description = "Publishes via shared bus",
            .dependencies = &.{},
        };
        pub fn initWith(ctx: *ModuleContext) !void {
            // DI: service pre-registered by the builder is visible
            const db = ctx.service(FakeDb, "db") orelse return error.MissingService;
            Ctx.saw_db = db.connected;
            // Events: shared thread-safe bus from the registry
            const bus = try ctx.eventBus(OrderEvent);
            try bus.subscribe(Ctx.onOrder);
            bus.publish(.{ .id = 9 });
        }
        pub fn deinit() void {}
    };

    var db = FakeDb{};
    var b = ApplicationBuilder.init(allocator, std.testing.io);
    defer b.deinit();

    var app = try (try b.withName("wired-app").withService(FakeDb, "db", &db)).build(.{Orders});
    defer app.deinit();

    try app.start();
    try std.testing.expect(Ctx.saw_db);
    try std.testing.expectEqual(@as(i64, 9), Ctx.received);

    // After start the container is frozen
    try std.testing.expectError(error.ContainerFrozen, app.services.registerBorrowed(FakeDb, "late", &db));

    // The same bus is reachable from outside (handlers, tests)
    const bus = try app.eventBus(OrderEvent);
    bus.publish(.{ .id = 10 });
    try std.testing.expectEqual(@as(i64, 10), Ctx.received);

    app.stop();
}

test "e2e: a module spawns workers through ctx.runtime() and stop() joins them" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        var got_runtime = false;
        var same_runtime = false;
        var total = std.atomic.Value(u32).init(0);
        var seen = std.atomic.Value(u32).init(0);
    };
    Ctx.got_runtime = false;
    Ctx.same_runtime = false;
    Ctx.total.store(0, .monotonic);
    Ctx.seen.store(0, .monotonic);

    const Counter = struct {
        pub const Message = u32;
        pub fn handle(_: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = ctx;
            _ = Ctx.total.fetchAdd(msg, .monotonic);
            _ = Ctx.seen.fetchAdd(1, .monotonic);
        }
    };

    const BookModule = struct {
        pub const info = api.Module{
            .name = "book",
            .description = "Owns a worker, spawned from the module lifecycle",
            .dependencies = &.{},
        };
        pub fn initWith(ctx: *ModuleContext) !void {
            // The app owns the runtime: created on first use, ticker running,
            // joined by `app.stop()`. Modules never build their own.
            const rt = try ctx.runtime();
            Ctx.got_runtime = true;
            Ctx.same_runtime = rt == try ctx.runtime();
            const worker = try rt.spawn(Counter, .{}, 32);
            for (1..4) |i| try worker.send(@intCast(i));
        }
        pub fn deinit() void {}
    };

    var app = try Application.init(std.testing.io, allocator, "worker-app", .{BookModule}, .{});
    defer app.deinit();

    try app.start();
    try std.testing.expect(Ctx.got_runtime);
    try std.testing.expect(Ctx.same_runtime);

    // The worker runs on its own thread: wait for the three sends to land.
    var spins: usize = 0;
    while (Ctx.seen.load(.monotonic) != 3 and spins < 400_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(u32, 3), Ctx.seen.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 6), Ctx.total.load(.monotonic));

    // `stop()` requests stop and joins, so no runtime thread outlives the app —
    // which is what makes the deferred `deinit()` race-free.
    app.stop();
    try std.testing.expectEqual(Application.State.stopped, app.getState());

    // A harness that never wired a provider says so instead of inventing one.
    var bare = ModuleContext{
        .allocator = allocator,
        .io = std.testing.io,
        .events = &app.events,
        .services = &app.services,
    };
    try std.testing.expectError(error.RuntimeUnavailable, bare.runtime());
}

test "e2e: the builder's pool declaration reaches the runtime a module spawns .pooled on" {
    const allocator = std.testing.allocator;

    const Shared = struct {
        var handled = std.atomic.Value(u32).init(0);
    };
    Shared.handled.store(0, .monotonic);

    const Audit = struct {
        pub const Message = u32;
        pub fn handle(_: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = msg;
            _ = ctx;
            _ = Shared.handled.fetchAdd(1, .monotonic);
        }
    };

    const TailModule = struct {
        pub const info = api.Module{
            .name = "tail",
            .description = "Long-tail worker, pooled",
            .dependencies = &.{},
        };
        pub fn initWith(ctx: *ModuleContext) !void {
            const rt = try ctx.runtime();
            // `.pooled` is a configuration error without a declared pool, so this
            // line passing is what says the builder's declaration arrived here.
            const audit = try rt.spawn(Audit, .{}, .{ .capacity = 8, .mode = .pooled });
            for (0..4) |i| try audit.send(@intCast(i));
        }
        pub fn deinit() void {}
    };

    var b = builder(allocator, std.testing.io);
    defer b.deinit();
    var app = try b.withName("pooled-app").withMaxPooledWorkers(1).build(.{TailModule});
    defer app.deinit();
    try app.start();

    const rt = try app.runtime();
    try std.testing.expectEqual(@as(usize, 1), rt.poolStats().?.max_pooled_workers);
    var spins: usize = 0;
    while (Shared.handled.load(.monotonic) != 4 and spins < 400_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(u32, 4), Shared.handled.load(.monotonic));
    // The batches really ran on the pool: the token path was taken, not a thread
    // of the worker's own.
    try std.testing.expect(rt.poolStats().?.dispatches >= 1);
    try std.testing.expectEqual(@as(u64, 0), rt.poolStats().?.ready_push_failures);

    app.stop();
}

test "e2e: the builder's pool *width* reaches the runtime a module spawns .pooled on" {
    const allocator = std.testing.allocator;

    const Shared = struct {
        var handled = std.atomic.Value(u32).init(0);
    };
    Shared.handled.store(0, .monotonic);

    const Audit = struct {
        pub const Message = u32;
        pub fn handle(_: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = msg;
            _ = ctx;
            _ = Shared.handled.fetchAdd(1, .monotonic);
        }
    };

    const TailModule = struct {
        pub const info = api.Module{
            .name = "tail",
            .description = "Long-tail workers, pooled on more than one thread",
            .dependencies = &.{},
        };
        pub fn initWith(ctx: *ModuleContext) !void {
            const rt = try ctx.runtime();
            for (0..2) |_| {
                const audit = try rt.spawn(Audit, .{}, .{ .capacity = 8, .mode = .pooled });
                for (0..4) |i| try audit.send(@intCast(i));
            }
        }
        pub fn deinit() void {}
    };

    var b = builder(allocator, std.testing.io);
    defer b.deinit();
    var app = try b.withName("wide-pooled-app")
        .withMaxPooledWorkers(2)
        .withPoolThreads(3)
        .build(.{TailModule});
    defer app.deinit();
    try app.start();

    const rt = try app.runtime();
    // The width is what the pool reports running — the declaration reached the
    // scheduler, not just the builder's own struct.
    try std.testing.expectEqual(@as(usize, 3), rt.poolStats().?.pool_threads);
    try std.testing.expectEqual(@as(usize, 2), rt.poolStats().?.max_pooled_workers);
    // The ring was sized for both: one token per worker plus one slot per
    // consumer (§12.12).
    try std.testing.expect(rt.poolStats().?.ready_capacity >= 2 + 3);
    var spins: usize = 0;
    while (Shared.handled.load(.monotonic) != 8 and spins < 400_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(u32, 8), Shared.handled.load(.monotonic));
    try std.testing.expect(rt.poolStats().?.dispatches >= 1);
    try std.testing.expectEqual(@as(u64, 0), rt.poolStats().?.ready_push_failures);

    app.stop();
    // Every pool thread is joined by the stop: the count goes back to zero with
    // the pool, not only with the process.
    try std.testing.expectEqual(@as(usize, 0), rt.poolStats().?.pool_threads);
}

test "e2e: in-flight counter tracks request lifecycle" {
    const allocator = std.testing.allocator;

    const MockModule = struct {
        pub const info = api.Module{
            .name = "counter-mock",
            .description = "Counter test module",
            .dependencies = &.{},
        };
        pub fn init() !void {}
        pub fn deinit() void {}
    };

    var app = try Application.init(std.testing.io, allocator, "counter-app", .{MockModule}, .{});
    defer app.deinit();

    const counter = getInFlightCounter();
    try std.testing.expectEqual(@as(u64, 0), counter.load(.monotonic));

    // Simulate in-flight tracking
    _ = counter.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u64, 1), counter.load(.monotonic));

    _ = counter.fetchSub(1, .monotonic);
    try std.testing.expectEqual(@as(u64, 0), counter.load(.monotonic));
}
