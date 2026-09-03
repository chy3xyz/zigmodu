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

pub const ModuleContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Shared per-type event buses (`ThreadSafeEventBus` only).
    events: *EventRegistry,
    /// Application service container. Modules may register during startup;
    /// it is frozen after all modules have started, after which `get` is a
    /// lock-free read safe for concurrent handlers.
    services: *Container,

    /// Get or create the shared bus for event type `T`.
    pub fn eventBus(self: *ModuleContext, comptime T: type) !*@import("EventBus.zig").ThreadSafeEventBus(T) {
        return self.events.bus(T);
    }

    /// Typed service lookup (see `Container.get`).
    pub fn service(self: *ModuleContext, comptime T: type, name: []const u8) ?*T {
        return self.services.get(T, name);
    }
};
