//! Config validation and graceful shutdown checklist helpers.

const std = @import("std");

pub const EnvError = error{
    MissingConfig,
};

pub const ShutdownChecklist = struct {
    steps: []const []const u8,

    pub fn logChecklist(self: ShutdownChecklist) void {
        std.log.info("Shutdown checklist ({d} steps):", .{self.steps.len});
        for (self.steps, 0..) |step, i| {
            std.log.info("  {d}. {s}", .{ i + 1, step });
        }
    }
};

/// Return `error.MissingConfig` when any key is absent from `map`.
pub fn requireEnv(map: *const std.StringHashMap([]const u8), keys: []const []const u8) EnvError!void {
    for (keys) |key| {
        if (map.get(key) == null) return error.MissingConfig;
    }
}

test "requireEnv passes when all keys present" {
    var map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer map.deinit();
    try map.put("HTTP_PORT", "8080");
    try map.put("JWT_SECRET", "secret");
    try requireEnv(&map, &.{ "HTTP_PORT", "JWT_SECRET" });
}

test "requireEnv fails on missing key" {
    var map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer map.deinit();
    try map.put("HTTP_PORT", "8080");
    try std.testing.expectError(error.MissingConfig, requireEnv(&map, &.{ "HTTP_PORT", "DB_HOST" }));
}

test "shutdown checklist logs steps" {
    const steps = [_][]const u8{
        "stop accepting connections",
        "drain in-flight requests",
        "flush outbox poller",
        "close database pool",
    };
    const checklist = ShutdownChecklist{ .steps = &steps };
    checklist.logChecklist();
}
