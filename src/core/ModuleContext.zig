//! Module startup context — the channel through which modules receive
//! framework facilities during `Application.start()`.
//!
//! Modules opt in by declaring `pub fn initWith(ctx: *ModuleContext) !void`
//! next to (or instead of) the classic `pub fn init() !void`. When both are
//! declared, only `initWith` runs. `Lifecycle.startAllWith` probes the
//! declaration at comptime (`@hasDecl`), so modules without it are unaffected.

const std = @import("std");
const EventRegistry = @import("EventRegistry.zig").EventRegistry;
const Container = @import("../di/Container.zig").Container;
const rt_mod = @import("../runtime.zig");

pub const ModuleContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Shared per-type event buses (`ThreadSafeEventBus` only).
    events: *EventRegistry,
    /// Application service container. Modules may register during startup;
    /// it is frozen after all modules have started, after which `get` is a
    /// lock-free read safe for concurrent handlers.
    services: *Container,
    /// Access to the app's execution runtime (workers / mailboxes / timers).
    /// Supplied by the host; a bare `Lifecycle.startAllWith` harness leaves it
    /// null, and then `runtime()` returns `error.RuntimeUnavailable`.
    runtime_provider: ?RuntimeProvider = null,

    /// Host callback: hand back the app's runtime, creating it on first call.
    /// The host owns the returned runtime and shuts it down, so a module cannot
    /// leak a thread past `Application.stop()`.
    pub const RuntimeProvider = struct {
        ctx: ?*anyopaque = null,
        get: *const fn (ctx: ?*anyopaque) anyerror!*rt_mod.Runtime,
    };

    /// Get or create the shared bus for event type `T`.
    pub fn eventBus(self: *ModuleContext, comptime T: type) !*@import("EventBus.zig").ThreadSafeEventBus(T) {
        return self.events.bus(T);
    }

    /// Typed service lookup (see `Container.get`).
    pub fn service(self: *ModuleContext, comptime T: type, name: []const u8) ?*T {
        return self.services.get(T, name);
    }

    /// The app's execution runtime — spawn a worker from `initWith` and let the
    /// app's lifecycle join it:
    ///
    /// ```zig
    /// pub fn initWith(ctx: *ModuleContext) !void {
    ///     const rt = try ctx.runtime();
    ///     _ = try rt.spawn(OrderBook, .{}, 256);
    /// }
    /// ```
    ///
    /// `Application.stop()` requests stop and joins every worker spawned this
    /// way, in either creation order — see `docs/RUNTIME.md`.
    pub fn runtime(self: *ModuleContext) !*rt_mod.Runtime {
        const provider = self.runtime_provider orelse return error.RuntimeUnavailable;
        return provider.get(provider.ctx);
    }
};
