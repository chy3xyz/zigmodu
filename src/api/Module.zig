const std = @import("std");

// ================================================================
// Module Lifecycle Contract
// ================================================================
//
// A ZigModu module is ANY struct that satisfies this contract:
//
//   pub const info: zigmodu.api.Module = .{
//       .name        = "my-module",          // required
//       .description = "What it does",        // required
//       .dependencies = &.{"other-module"},   // optional
//   };
//
//   pub fn init() !void { ... }              // called at startup (dep order)
//   pub fn deinit() void { ... }             // called at shutdown (reverse order)
//
// Lifecycle guarantee:
//   - `init()` is called AFTER all dependency modules have initialized
//   - `deinit()` is called BEFORE any dependency module is deinitialized
//   - If any `init()` returns an error, startup aborts and already-started
//     modules are stopped in reverse order (best-effort cleanup)
//   - `init()`/`deinit()` are called exactly once per Application instance
//
// Dependency resolution:
//   - Dependencies are specified by `info.dependencies` name list
//   - Circular dependencies are detected at validation time (compile error)
//   - Missing dependencies are detected at validation time (compile error)

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
