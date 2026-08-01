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

test "Event tagged union carries payloads" {
    const ev = Event{ .module_init = .{ .module_name = "order", .timestamp = 42 } };
    switch (ev) {
        .module_init => |m| {
            try std.testing.expectEqualStrings("order", m.module_name);
            try std.testing.expectEqual(@as(i64, 42), m.timestamp);
        },
        else => return error.WrongVariant,
    }
    const cfg = Event{ .config_changed = .{ .key = "db", .old_value = null, .new_value = "postgres" } };
    try std.testing.expectEqualStrings("postgres", cfg.config_changed.new_value.?);
    const health = Event{ .health_check = .{ .component = "redis", .status = .degraded, .message = "high latency" } };
    try std.testing.expect(health.health_check.status == .degraded);
}
