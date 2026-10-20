//! Module contract + registry metadata.
//!
//! The contract lived in `api/Module.zig` until the orthogonal pass: `core`
//! (ModuleRegistry/ModuleRuntime/Lifecycle/ModuleScanner) had to import the API
//! layer to name the very type modules are declared with — the last
//! `core -> api` edge. `api/Module.zig` is now a re-export shim, so
//! `zmodu.api.Module` keeps working.

const std = @import("std");
const ModuleContext = @import("ModuleContext.zig").ModuleContext;

pub const ModuleInfo = struct {
    name: []const u8,
    desc: []const u8,
    deps: []const []const u8,
    /// Module instance pointer. Null for metadata-only registrations (e.g. tests).
    ptr: ?*anyopaque = null,
    init_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    /// Preferred startup hook when a `ModuleContext` is available
    /// (`Lifecycle.startAllWith`): wraps the module's `initWith(ctx)`.
    init_ctx_fn: ?*const fn (?*anyopaque, *ModuleContext) anyerror!void = null,
    deinit_fn: ?*const fn (?*anyopaque) void = null,
    /// Runtime resource options copied from the module's info at scan time.
    runtime_options: RuntimeOptions = .{},

    /// Create a metadata-only ModuleInfo (ptr defaults to null).
    /// Use scanModules() for full registrations with init/deinit function pointers.
    pub fn init(
        name: []const u8,
        desc: []const u8,
        deps: []const []const u8,
    ) ModuleInfo {
        return .{
            .name = name,
            .desc = desc,
            .deps = deps,
            .ptr = null,
            .init_fn = null,
            .deinit_fn = null,
            .runtime_options = .{},
        };
    }
};

pub const ApplicationModules = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(ModuleInfo),
    sorted_order: ?std.ArrayList([]const u8) = null,

    pub fn init(allocator: std.mem.Allocator) ApplicationModules {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(ModuleInfo).init(allocator),
            .sorted_order = null,
        };
    }

    pub fn register(self: *ApplicationModules, info: ModuleInfo) !void {
        try self.modules.put(info.name, info);
        // Invalidate cached topological sort when module set changes
        if (self.sorted_order) |*order| {
            order.deinit(self.allocator);
            self.sorted_order = null;
        }
    }

    pub fn get(self: *ApplicationModules, name: []const u8) ?ModuleInfo {
        return self.modules.get(name);
    }

    pub fn getPtr(self: *ApplicationModules, name: []const u8) ?*ModuleInfo {
        return self.modules.getPtr(name);
    }

    pub fn deinit(self: *ApplicationModules) void {
        if (self.sorted_order) |*order| {
            order.deinit(self.allocator);
        }
        self.modules.deinit();
        self.* = undefined;
    }
};

test "ModuleInfo init" {
    const info = ModuleInfo.init("order", "Order module", &.{"inventory"});
    try std.testing.expectEqualStrings("order", info.name);
    try std.testing.expectEqualStrings("Order module", info.desc);
    try std.testing.expectEqual(@as(usize, 1), info.deps.len);
    try std.testing.expectEqualStrings("inventory", info.deps[0]);
    try std.testing.expect(info.ptr == null);
}

test "ApplicationModules register and get" {
    const allocator = std.testing.allocator;
    var app = ApplicationModules.init(allocator);
    defer app.deinit();

    const info = ModuleInfo.init("user", "User module", &.{});
    try app.register(info);

    const retrieved = app.get("user").?;
    try std.testing.expectEqualStrings("user", retrieved.name);
    try std.testing.expectEqualStrings("User module", retrieved.desc);
    try std.testing.expect(app.getPtr("user") != null);
    try std.testing.expect(app.get("nonexistent") == null);
}

// ================================================================
// Module contract (moved from api/Module.zig)
// ================================================================
//
// A zmodu module is ANY struct that satisfies this contract:
//
//   pub const info: zmodu.core.Module = .{
//       .name        = "my-module",          // required
//       .description = "What it does",        // required
//       .dependencies = &.{"other-module"},   // optional
//   };
//
//   pub fn init() !void { ... }              // called at startup (dep order)
//   pub fn deinit() void { ... }             // called at shutdown (reverse order)

/// Module metadata definition.
/// Annotate your module struct with `pub const info: Module = .{...};`
pub const Module = struct {
    name: []const u8,
    description: []const u8 = "",
    dependencies: []const []const u8 = &.{},
    is_internal: bool = false,
    runtime: RuntimeOptions = .{},
};

/// Per-module runtime resource options.
/// All fields are optional and default to "share global resources" so existing
/// modules keep working without changes.
pub const RuntimeOptions = struct {
    /// Maximum concurrent requests/commands for this module. 0 = unlimited.
    max_concurrent: u32 = 0,
    /// Maximum requests per second for this module. 0 = unlimited.
    max_qps: u32 = 0,
    /// Circuit breaker failure threshold. 0 = disabled.
    cb_failure_threshold: u32 = 0,
    /// Circuit breaker success threshold to close again.
    cb_success_threshold: u32 = 0,
    /// Seconds before the breaker moves from OPEN to HALF_OPEN.
    cb_timeout_seconds: u64 = 0,
    /// Max test calls in HALF_OPEN state.
    cb_half_open_max_calls: u32 = 0,
    /// Number of dedicated async workers for this module. 0 = no dedicated pool.
    worker_count: u32 = 0,
};

/// Application-level configuration
/// Defines the modular application structure
pub const Modulith = struct {
    name: []const u8,
    base_path: []const u8,
    validate: bool = true,
    generate_docs: bool = true,
};

/// Module trait - compile-time interface for modules
/// Any struct with these fields can be used as a module
pub fn ModuleTrait(comptime T: type) type {
    return struct {
        pub const has_info = @hasDecl(T, "info");
        pub const has_init = @hasDecl(T, "init");
        pub const has_deinit = @hasDecl(T, "deinit");
    };
}

test "Module with runtime options" {
    const mod = Module{
        .name = "order",
        .description = "Order module",
        .runtime = .{
            .max_concurrent = 50,
            .max_qps = 1000,
            .cb_failure_threshold = 5,
            .cb_success_threshold = 2,
            .cb_timeout_seconds = 10,
            .cb_half_open_max_calls = 3,
            .worker_count = 4,
        },
    };
    try std.testing.expectEqual(@as(u32, 50), mod.runtime.max_concurrent);
    try std.testing.expectEqual(@as(u32, 1000), mod.runtime.max_qps);
    try std.testing.expectEqual(@as(u32, 4), mod.runtime.worker_count);
}
