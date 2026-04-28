//! ZigModu module `<<MODULE_NAME>>` (zmodu: `zmodu module` or `zmodu orm` sqlx).
//! Template: tools/zmodu/src/templates/orm/sqlx/module.zig.tpl

const std = @import("std");
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "<<MODULE_NAME>>",
    .description = "<<MODULE_NAME>> module",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {
    std.log.info("{s} module initialized", .{"<<MODULE_NAME>>"});
}

pub fn deinit() void {
    std.log.info("{s} module cleaned up", .{"<<MODULE_NAME>>"});
}
