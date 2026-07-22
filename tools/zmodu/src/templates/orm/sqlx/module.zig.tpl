//! @initialized by zmodu — AI may modify freely
//!
//! Module: <<MODULE_NAME>>
//! Lifecycle + barrel re-exports + health checks.
//! ✅ Cross-module logic in: src/business/

const std = @import("std");
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "<<MODULE_NAME>>",
    .description = "<<MODULE_NAME>> module",
    .dependencies = <<DEPS>>,
    .is_internal = false,
};

pub fn init() !void {
    std.log.info("[{s}] initializing", .{info.name});
}

pub fn deinit() void {
    std.log.info("[{s}] shutting down", .{info.name});
}

pub fn registerHealthChecks(endpoint: *zigmodu.HealthEndpoint) !void {
    try endpoint.registerCheck("<<MODULE_NAME>>", "<<MODULE_NAME>> module health", zigmodu.HealthEndpoint.alwaysUp);
}

// Barrel re-exports — import from module.zig
pub const model = @import("model.zig");
pub const persistence = @import("persistence.zig");
pub const service = @import("service.zig");
pub const api = @import("api.zig");
