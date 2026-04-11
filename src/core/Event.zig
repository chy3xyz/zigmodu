const std = @import("std");

/// Framework Event - Tagged Union for type safety and performance
/// All domain events are defined here
pub const Event = union(enum) {
    // Framework lifecycle events
    module_init: ModuleLifecycleEvent,
    module_start: ModuleLifecycleEvent,
    module_stop: ModuleLifecycleEvent,

    // Configuration events
    config_changed: ConfigChangedEvent,

    // Health events
    health_check: HealthEvent,

    // Business events can be added here

    pub const ModuleLifecycleEvent = struct {
        module_name: []const u8,
        timestamp: i64,
    };

    pub const ConfigChangedEvent = struct {
        key: []const u8,
        old_value: ?[]const u8,
        new_value: ?[]const u8,
    };

    pub const HealthEvent = struct {
        component: []const u8,
        status: enum { healthy, degraded, unhealthy },
        message: []const u8,
    };
};
